import Combine
import Foundation
import OSLog

/// Spec: 实现目录/入口文件监听器（FSEvents），自动检测 HTML 文件创建/修改并刷新 Flow 岛与设置页预览
///
/// 使用 DispatchSource 监听每个自定义区域目录的文件变化，触发回调。
/// 适配沙箱外目录（用户选择 ~/Documents 等场景）需要 Security-Scoped Bookmark；
/// 在非沙箱构建（默认 Developer ID 渠道）下直接使用 path 即可。
final class CustomAreaWatcher {
    static let shared = CustomAreaWatcher()

    private static let logger = OSLog(subsystem: "ai.traeflow.app", category: "CustomAreaWatcher")

    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var directorySources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "ai.traeflow.app.custom-area-watcher", qos: .utility)

    /// 当某个区域的入口 HTML 文件变化时触发（参数：areaID）
    let entryPointDidChange = PassthroughSubject<String, Never>()
    /// 当某个区域目录结构变化时触发（参数：areaID）
    let directoryDidChange = PassthroughSubject<String, Never>()

    private init() {}

    /// 监听指定区域
    /// - 监听入口 HTML 文件本身的修改（DispatchSource.makeFileSystemObjectSource）
    /// - 监听目录中文件创建/删除（DispatchSource.makeFileSystemObjectSource on directory）
    func observe(area: CustomArea) {
        observeEntryFile(area: area)
        observeDirectory(area: area)
    }

    /// 重新观察所有区域（store 变化时调用）
    func observeAll(areas: [CustomArea]) {
        cancelAll()
        for area in areas {
            observe(area: area)
        }
    }

    func cancel(areaID: String) {
        fileSources[areaID]?.cancel()
        fileSources[areaID] = nil
        directorySources[areaID]?.cancel()
        directorySources[areaID] = nil
    }

    func cancelAll() {
        for source in fileSources.values { source.cancel() }
        for source in directorySources.values { source.cancel() }
        fileSources.removeAll()
        directorySources.removeAll()
    }

    // MARK: - Private

    private func observeEntryFile(area: CustomArea) {
        let url = area.entryPointURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log(.error, log: Self.logger, "Entry file does not exist for area %{public}@: %{public}@", area.id, url.path)
            return
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            os_log(.error, log: Self.logger, "Failed to open entry file for area %{public}@: %{public}@ (errno: %{public}@)", area.id, url.path, err)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, areaID = area.id] in
            self?.entryPointDidChange.send(areaID)
            self?.directoryDidChange.send(areaID)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileSources[area.id] = source
    }

    private func observeDirectory(area: CustomArea) {
        let url = area.directoryURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log(.error, log: Self.logger, "Directory does not exist for area %{public}@: %{public}@", area.id, url.path)
            return
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            os_log(.error, log: Self.logger, "Failed to open directory for area %{public}@: %{public}@ (errno: %{public}@)", area.id, url.path, err)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, areaID = area.id] in
            self?.directoryDidChange.send(areaID)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySources[area.id] = source
    }
}
