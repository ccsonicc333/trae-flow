import AppKit
import Foundation

/// 音乐播放器数据源协议。
///
/// 实现者可从系统级聚合（MediaRemote）或具体播放器脚本（AppleScript/ScriptingBridge）
/// 读取当前播放信息。`NowPlayingProvider` 按优先级组合多个数据源。
protocol PlayerSource: AnyObject {
    /// 数据源名称，仅用于日志
    var name: String { get }

    /// 流式数据源在收到新的 Now Playing 信息时通过此回调主动推送。
    /// 轮询式数据源可不实现（保持 nil）。
    var onNowPlayingUpdate: ((NowPlayingInfo) -> Void)? { get set }

    /// 异步拉取当前播放信息
    func fetchNowPlaying(completion: @escaping (NowPlayingInfo?) -> Void)

    /// 发送播放控制命令
    /// - Returns: 是否成功执行（AppleScript 返回是否成功；MediaRemote 总是 true）
    func sendCommand(_ command: PlayerCommand) -> Bool
}

/// 播放控制命令
enum PlayerCommand {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    /// 跳转到指定时间（秒）
    case seek(position: TimeInterval)
}
