import AppKit
import Foundation

/// 直接复用 boring.notch 的 mediaremote-adapter.pl + MediaRemoteAdapter.framework
/// 通过 Perl 子进程读取系统 Now Playing 信息。
///
/// 这是 boring.notch 的原生实现方式：把 MediaRemote 私有框架的调用隔离到独立
/// 子进程中，避免主 App 直接调用 MediaRemote 时遇到的权限 / arm64e 问题。
///
/// 资源要求：
    /// - `TraeFlow/Resources/MediaRemoteAdapter.zip`
    ///
    /// 注：Xcode 的 PBXFileSystemSynchronizedRootGroup 会扁平化 Resources 子目录，
    /// 因此把脚本 + 框架整体打包为 zip，运行时解压到
    /// `~/Library/Application Support/trae-flow/MediaRemoteAdapter/`。
@MainActor
final class BoringNotchMediaRemoteAdapter: PlayerSource {
    var name: String { "BoringNotchMediaRemote" }

    /// 流式收到新的 Now Playing 信息时主动推送
    var onNowPlayingUpdate: ((NowPlayingInfo) -> Void)?

    /// 最近一次收到的 Now Playing 信息
    private(set) var lastInfo: NowPlayingInfo?

    /// 是否有流式进程在运行
    private(set) var isRunning = false

    /// 是否已初始化失败（资源缺失等）
    private(set) var isUnavailable = false

    /// 解压后的运行时目录
    private let runtimeDir: URL
    /// 流式子进程
    /// 标记为 `nonisolated(unsafe)` 以便 `deinit` 能安全终止进程。
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var pipe: Pipe?
    nonisolated(unsafe) private var readTask: Task<Void, Never>?

    init?() {
        guard let extracted = Self.extractResourcesIfNeeded() else {
            NSLog("[BoringNotchMediaRemoteAdapter] 资源缺失或解压失败，无法初始化")
            return nil
        }
        self.runtimeDir = extracted.runtimeDir
        startStream(scriptURL: extracted.scriptURL, frameworkURL: extracted.frameworkURL)
    }

    deinit {
        stopStream()
    }

    // MARK: - Resource Extraction

    private static func extractResourcesIfNeeded() -> (runtimeDir: URL, scriptURL: URL, frameworkURL: URL)? {
        guard let zipURL = Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "zip") else {
            NSLog("[BoringNotchMediaRemoteAdapter] 未找到 MediaRemoteAdapter.zip")
            return nil
        }

        let fm = FileManager.default
        let runtimeDir = BridgeRuntimePaths.runtimeDirectoryURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
        let scriptURL = runtimeDir.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = runtimeDir.appendingPathComponent("MediaRemoteAdapter.framework.d")

        // 如果已解压且完整，直接复用
        if fm.fileExists(atPath: scriptURL.path) && fm.fileExists(atPath: frameworkURL.path) {
            return (runtimeDir, scriptURL, frameworkURL)
        }

        // 创建运行时目录
        try? fm.createDirectory(at: BridgeRuntimePaths.runtimeDirectoryURL, withIntermediateDirectories: true)
        try? fm.removeItem(at: runtimeDir)
        try? fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        // 解压 zip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", runtimeDir.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            NSLog("[BoringNotchMediaRemoteAdapter] 解压失败: \(error)")
            return nil
        }

        // zip 内部有一级 MediaRemoteAdapter/ 目录，把它内部文件提升到 runtimeDir
        let innerDir = runtimeDir.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
        if fm.fileExists(atPath: innerDir.path) {
            let innerScript = innerDir.appendingPathComponent("mediaremote-adapter.pl")
            let innerFramework = innerDir.appendingPathComponent("MediaRemoteAdapter.framework.d")
            if fm.fileExists(atPath: innerScript.path) && fm.fileExists(atPath: innerFramework.path) {
                try? fm.moveItem(at: innerScript, to: scriptURL)
                try? fm.moveItem(at: innerFramework, to: frameworkURL)
                try? fm.removeItem(at: innerDir)
            }
        }

        // 设置可执行权限
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let executable = frameworkURL.appendingPathComponent("MediaRemoteAdapter")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // 清除 quarantine 属性
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", runtimeDir.path]
        try? xattr.run()
        xattr.waitUntilExit()

        guard fm.fileExists(atPath: scriptURL.path) && fm.fileExists(atPath: frameworkURL.path) else {
            NSLog("[BoringNotchMediaRemoteAdapter] 解压后文件不完整")
            return nil
        }
        return (runtimeDir, scriptURL, frameworkURL)
    }

    // MARK: - PlayerSource

    func fetchNowPlaying(completion: @escaping (NowPlayingInfo?) -> Void) {
        completion(lastInfo)
    }

    func sendCommand(_ command: PlayerCommand) -> Bool {
        let scriptURL = runtimeDir.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = runtimeDir.appendingPathComponent("MediaRemoteAdapter.framework.d")
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        switch command {
        case .play:
            process.arguments = [scriptURL.path, frameworkURL.path, "send", "0"]
        case .pause:
            process.arguments = [scriptURL.path, frameworkURL.path, "send", "1"]
        case .togglePlayPause:
            process.arguments = [scriptURL.path, frameworkURL.path, "send", "2"]
        case .nextTrack:
            process.arguments = [scriptURL.path, frameworkURL.path, "send", "4"]
        case .previousTrack:
            process.arguments = [scriptURL.path, frameworkURL.path, "send", "5"]
        case .seek(let position):
            // mediaremote-adapter.pl 的 seek 参数为微秒
            let micros = max(0, Int(position * 1_000_000))
            process.arguments = [scriptURL.path, frameworkURL.path, "seek", "\(micros)"]
        }

        do {
            try process.run()
            return true
        } catch {
            NSLog("[BoringNotchMediaRemoteAdapter] sendCommand 启动失败: \(error)")
            return false
        }
    }

    // MARK: - Stream

    private func startStream(scriptURL: URL, frameworkURL: URL) {
        stopStream()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "stream", "--no-diff"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        self.process = process
        self.pipe = pipe

        readTask = Task { [weak self] in
            await self?.readJSONLines(from: pipe)
        }

        do {
            try process.run()
            isRunning = true
            NSLog("[BoringNotchMediaRemoteAdapter] 流式子进程已启动")
        } catch {
            isUnavailable = true
            NSLog("[BoringNotchMediaRemoteAdapter] 启动失败: \(error)")
        }
    }

    nonisolated private func stopStream() {
        readTask?.cancel()
        process?.terminate()
    }

    private func readJSONLines(from pipe: Pipe) async {
        let handle = pipe.fileHandleForReading
        // 行缓冲：一次 read 可能跨多行 / 截断半行，累积后按换行符切分完整行
        var buffer = ""

        // 循环读取直到任务被取消或 EOF
        while !Task.isCancelled {
            do {
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    handle.readabilityHandler = { h in
                        let available = h.availableData
                        h.readabilityHandler = nil
                        continuation.resume(returning: available)
                    }
                }

                guard !data.isEmpty else {
                    // EOF
                    break
                }

                if let text = String(data: data, encoding: .utf8) {
                    buffer.append(text)
                    // 按换行符切分；最后一个片段可能不完整，保留到下次
                    let lines = buffer.components(separatedBy: .newlines)
                    if lines.count > 1 {
                        // lines.last 是未结尾片段（可能为空字符串），保留到下次拼接
                        buffer = lines.last ?? ""
                        for line in lines.dropLast() where !line.isEmpty {
                            await handleJSONLine(line)
                        }
                    }
                    // lines.count == 1 表示本次 read 没有完整行，继续累积
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("[BoringNotchMediaRemoteAdapter] 读取流失败: \(error)")
                }
                break
            }
        }

        // EOF 后处理 buffer 中残留的最后一行
        let trailing = buffer.trimmingCharacters(in: .newlines)
        if !trailing.isEmpty {
            await handleJSONLine(trailing)
        }

        handle.readabilityHandler = nil
        isRunning = false
    }

    private func handleJSONLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else { return }

        do {
            let update = try JSONDecoder().decode(BoringNotchNowPlayingUpdate.self, from: data)
            let payload = update.payload

            let bundleID = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
            let source = appName(forBundleID: bundleID) ?? bundleID
            let artworkData = payload.artworkData.flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let artwork = artworkData.flatMap { NSImage(data: $0) }
            let isPlaying = payload.playing ?? false

            // boring.notch 的 elapsedTime 是快照时间点的值；结合 timestamp 计算当前已播放时间
            let snapshotElapsed = payload.elapsedTime ?? 0
            var currentElapsed = snapshotElapsed
            if let timestampString = payload.timestamp {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let timestampDate = formatter.date(from: timestampString) {
                    currentElapsed = snapshotElapsed + Date().timeIntervalSince(timestampDate)
                }
            }
            currentElapsed = max(0, min(currentElapsed, payload.duration ?? 0))

            let receivedAt = Date()
            let info = NowPlayingInfo(
                title: payload.title,
                artist: payload.artist,
                album: payload.album,
                artwork: artwork,
                duration: payload.duration ?? 0,
                elapsed: currentElapsed,
                isPlaying: isPlaying,
                source: source,
                receivedAt: receivedAt
            )

            // 始终保存最新快照并推送给 Provider，保证 elapsed 能持续校准；
            // 日志只在曲目元数据或播放状态变化时输出，避免 elapsed 微调刷屏。
            let contentChanged = lastInfo != info
            lastInfo = info
            onNowPlayingUpdate?(info)
            if contentChanged {
                NSLog("[BoringNotchMediaRemoteAdapter] 更新: \(info.title ?? "nil") elapsed=\(info.elapsed) duration=\(info.duration) playing=\(info.isPlaying)")
            }
        } catch {
            NSLog("[BoringNotchMediaRemoteAdapter] JSON 解析失败: \(error) line=\(line.prefix(200))")
        }
    }

    private func appName(forBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}

// MARK: - JSON Models

/// 对应 boring.notch 的 `NowPlayingUpdate`
private struct BoringNotchNowPlayingUpdate: Codable {
    let payload: BoringNotchNowPlayingPayload
    let diff: Bool?
}

/// 对应 boring.notch 的 `NowPlayingPayload`
private struct BoringNotchNowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}
