import AppKit
import Foundation

/// 使用 MediaRemote 私有框架作为数据源。
///
/// 已知限制：在 arm64 进程中调用 `registerForNowPlayingNotifications` 会崩溃，
/// 因此不注册通知，仅轮询 `getNowPlayingInfo`。某些系统版本/签名环境下，
/// 非沙盒 App 调用 `getNowPlayingInfo` 会返回 `Operation not permitted`。
/// `NowPlayingProvider` 在此情况下会回退到 `AppleScriptPlayerSource`。
@MainActor
final class MediaRemotePlayerSource: PlayerSource {
    var name: String { "MediaRemote" }

    /// 当前未使用流式回调
    var onNowPlayingUpdate: ((NowPlayingInfo) -> Void)?

    /// 记录最近一次错误，用于 `NowPlayingProvider` 判断是否永久不可用
    private(set) var lastErrorDomain: String?

    func fetchNowPlaying(completion: @escaping (NowPlayingInfo?) -> Void) {
        guard MediaRemoteBridge.isAvailable else {
            completion(nil)
            return
        }
        MediaRemoteBridge.getNowPlayingInfo(dispatchQueue: .main) { [weak self] info in
            guard let self, let info = info else {
                completion(nil)
                return
            }
            MediaRemoteBridge.getPlaybackState(dispatchQueue: .main) { [weak self] rawState in
                guard let self else {
                    completion(nil)
                    return
                }
                let state = MRPlaybackState(rawValue: rawState) ?? .stopped
                let isPlaying = (state == .playing)
                let artworkData = info[MediaRemoteBridge.infoArtworkDataKey] as? Data
                let artwork = artworkData.flatMap { NSImage(data: $0) }
                let duration = (info[MediaRemoteBridge.infoDurationKey] as? Double) ?? 0
                let elapsed = (info[MediaRemoteBridge.infoElapsedTimeKey] as? Double) ?? 0
                let appDisplayID = (info[MediaRemoteBridge.infoAppDisplayIDKey] as? String) ?? ""
                let source = self.appName(forBundleID: appDisplayID) ?? appDisplayID

                // 检查 MediaRemote 是否返回了授权错误
                if let error = info["error"] as? NSError {
                    self.lastErrorDomain = error.domain
                    if error.domain == "kMRMediaRemoteFrameworkErrorDomain" {
                        NSLog("[MediaRemotePlayerSource] MediaRemote 返回错误: \(error)")
                    }
                } else {
                    self.lastErrorDomain = nil
                }

                completion(NowPlayingInfo(
                    title: info[MediaRemoteBridge.infoTitleKey] as? String,
                    artist: info[MediaRemoteBridge.infoArtistKey] as? String,
                    album: info[MediaRemoteBridge.infoAlbumKey] as? String,
                    artwork: artwork,
                    duration: duration,
                    elapsed: elapsed,
                    isPlaying: isPlaying,
                    source: source,
                    receivedAt: Date()
                ))
            }
        }
    }

    func sendCommand(_ command: PlayerCommand) -> Bool {
        guard MediaRemoteBridge.isAvailable else { return false }
        switch command {
        case .seek:
            // MediaRemoteBridge 当前未封装 seek 符号；如未来需要可补充 MRMediaRemoteSetElapsedTime
            return false
        default:
            MediaRemoteBridge.sendCommand(command: command.mrCommand, options: nil)
            return true
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

extension PlayerCommand {
    fileprivate var mrCommand: MRCommand {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .togglePlayPause: return .togglePlayPause
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .seek:
            // seek 在 sendCommand 中单独处理，不会走到这里
            return .play
        }
    }
}
