import Combine
import Foundation

/// 监听 codex/user pets 目录变更，触发扫描器重扫
///
/// 参考 `CustomAreaWatcher` 的实现模式，使用 `DispatchSource.makeFileSystemObjectSource`
/// 监听目录层的文件系统事件。`didChange` 会在 30 秒节流后被 `MascotThemeScanner` 消费。
///
/// 注意：
/// - 本类不是 `@MainActor`，与 `CustomAreaWatcher` 保持一致
/// - 目录不存在时跳过监听（避免崩溃）；目录后续创建后不会自动开始监听，
///   需要用户触发"重新扫描"以重建监听列表，这是可接受的取舍
final class MascotThemeWatcher {
    static let shared = MascotThemeWatcher()

    /// 目录变更事件（节流后由扫描器消费）
    let didChange = PassthroughSubject<Void, Never>()

    private var directorySources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "ai.traeflow.app.mascot-theme-watcher", qos: .utility)

    private init() {}

    /// 开始监听给定目录列表（替换之前的监听）
    func observe(directories: [URL]) {
        cancelAll()
        for url in directories {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            observeDirectory(url)
        }
    }

    /// 取消所有监听
    func cancelAll() {
        for source in directorySources { source.cancel() }
        directorySources.removeAll()
    }

    // MARK: - Private

    private func observeDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        // macOS DispatchSource.FileSystemEvent 没有 .create；新文件创建会触发父目录的 .write
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.didChange.send(())
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySources.append(source)
    }
}
