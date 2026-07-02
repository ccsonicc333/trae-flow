import AppKit
import Combine
import Foundation

/// Now Playing 数据提供者
///
/// 按优先级组合多个数据源：
/// 1. `BoringNotchMediaRemoteAdapter`：直接复用 boring.notch 的 `mediaremote-adapter.pl`
///    + `MediaRemoteAdapter.framework`，在独立 Perl 子进程中读取系统 Now Playing。
///    这是 boring.notch 的原生实现方式，能覆盖 Music.app / Spotify / 网易云 / QQ音乐等。
/// 2. `AppleScriptPlayerSource`：查询具体播放器，作为适配器不可用时/无权限时的回退。
///
/// `init()` 不初始化任何数据源。由 `AppDelegate` 延迟调用 `start()`。
@MainActor
final class NowPlayingProvider: ObservableObject {
    static let shared = NowPlayingProvider()

    @Published private(set) var nowPlaying: NowPlayingInfo?
    @Published private(set) var isStarted = false

    /// 主数据源：boring.notch 适配器
    private lazy var boringNotchSource = BoringNotchMediaRemoteAdapter()
    /// 备用数据源：AppleScript
    private lazy var appleScriptSource = AppleScriptPlayerSource()

    /// 轮询 Timer —— 每 2 秒从主数据源同步一次 Now Playing 信息
    private var pollTimer: AnyCancellable?
    /// 进度 Timer —— 平滑推进 `elapsed`（仅 `isPlaying == true` 时运行）
    private var progressTimer: AnyCancellable?
    /// 进度 Timer 启动时间，用于基于真实时间差计算 elapsed
    private var progressTimerStartDate: Date?
    /// 进度 Timer 启动时的 elapsed 基准
    private var progressTimerBaselineElapsed: TimeInterval = 0

    private init() {
        // 由 AppDelegate 在 applicationDidFinishLaunching 后显式调用 start()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NSLog("[NowPlayingProvider] 启动")
        // 在启动轮询前先注册流式回调，避免错过首批推送
        boringNotchSource?.onNowPlayingUpdate = { [weak self] info in
            self?.handleStreamUpdate(info)
        }
        startPolling()
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        stopProgressTimer()
        boringNotchSource?.onNowPlayingUpdate = nil
        isStarted = false
    }

    // MARK: - Polling

    private func startPolling() {
        // 每 2 秒轮询一次
        pollTimer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshNowPlaying()
            }
        // 立即拉取一次
        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        // 主数据源：boring.notch 适配器（流式推送已持续更新 lastInfo）
        if let boringNotch = boringNotchSource, !boringNotch.isUnavailable {
            boringNotch.fetchNowPlaying { [weak self] info in
                self?.updateNowPlaying(info)
            }
            return
        }

        // 回退：AppleScript
        appleScriptSource.fetchNowPlaying { [weak self] info in
            self?.updateNowPlaying(info)
        }
    }

    private func updateNowPlaying(_ info: NowPlayingInfo?) {
        guard let info else {
            let hadTrack = nowPlaying != nil
            nowPlaying = nil
            stopProgressTimer()
            if hadTrack {
                NSLog("[NowPlayingProvider] 播放停止")
            }
            return
        }

        // `NowPlayingInfo.==` 已忽略 `elapsed`，这里判断的是曲目元数据或播放状态变化。
        // 轮询结果只在内容变化时更新；同曲目的 elapsed 由流式回调和进度 Timer 负责，
        // 避免用轮询快照重置 Timer 导致进度条来回跳动。
        let contentChanged = nowPlaying != info

        if contentChanged {
            nowPlaying = info
            NSLog("[NowPlayingProvider] 轮询更新: \(info.title ?? "nil") playing=\(info.isPlaying)")
        }

        if info.isPlaying {
            startProgressTimer(resettingBaseline: contentChanged)
        } else {
            stopProgressTimer()
        }
    }

    /// 处理流式数据源主动推送的更新。
    /// 流式数据是最新的权威时间，因此总是更新 `nowPlaying` 并同步 Timer 基准。
    private func handleStreamUpdate(_ info: NowPlayingInfo) {
        let contentChanged = nowPlaying != info
        nowPlaying = info
        if contentChanged {
            NSLog("[NowPlayingProvider] 流式更新: \(info.title ?? "nil") playing=\(info.isPlaying)")
        }

        if info.isPlaying {
            startProgressTimer(resettingBaseline: true)
        } else {
            stopProgressTimer()
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer(resettingBaseline: Bool = false) {
        if resettingBaseline || progressTimer == nil {
            progressTimer?.cancel()
            progressTimerStartDate = Date()
            progressTimerBaselineElapsed = nowPlaying?.elapsed ?? 0
            progressTimer = Timer.publish(every: 0.2, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self, var np = self.nowPlaying, np.isPlaying else { return }
                    let delta = Date().timeIntervalSince(self.progressTimerStartDate ?? Date())
                    np.elapsed = min(self.progressTimerBaselineElapsed + delta, np.duration)
                    self.nowPlaying = np
                }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
        progressTimerStartDate = nil
    }

    // MARK: - Playback Control
    ///
    /// 优先使用 boring.notch 适配器发送系统级命令，失败则回退到 AppleScript。

    func play() {
        _ = (boringNotchSource?.sendCommand(.play) ?? false) || appleScriptSource.sendCommand(.play)
    }

    func pause() {
        _ = (boringNotchSource?.sendCommand(.pause) ?? false) || appleScriptSource.sendCommand(.pause)
    }

    func skipToNext() {
        _ = (boringNotchSource?.sendCommand(.nextTrack) ?? false) || appleScriptSource.sendCommand(.nextTrack)
    }

    func skipToPrevious() {
        _ = (boringNotchSource?.sendCommand(.previousTrack) ?? false) || appleScriptSource.sendCommand(.previousTrack)
    }

    func togglePlayPause() {
        _ = (boringNotchSource?.sendCommand(.togglePlayPause) ?? false) || appleScriptSource.sendCommand(.togglePlayPause)
    }

    /// 跳转到指定时间（秒），优先使用 boring.notch 适配器，失败则回退到 AppleScript。
    /// 跳转后立即用目标位置刷新本地 elapsed，避免进度条在等待流式更新期间停滞。
    func seek(to position: TimeInterval) {
        let target = max(0, min(position, nowPlaying?.duration ?? position))
        let sent = (boringNotchSource?.sendCommand(.seek(position: target)) ?? false)
            || appleScriptSource.sendCommand(.seek(position: target))
        guard sent else { return }
        if var np = nowPlaying {
            np.elapsed = target
            nowPlaying = np
            startProgressTimer(resettingBaseline: true)
        }
    }
}
