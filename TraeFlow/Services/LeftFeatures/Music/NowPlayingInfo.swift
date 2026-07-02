import AppKit

/// Now Playing 信息快照
///
/// 通过 MediaRemote 私有框架或 AppleScript 拉取后封装为该结构体，
/// 供紧凑态/展开态视图消费。
/// `artwork` 为 `NSImage`（非 Sendable），但实例仅在主线程流转
///（`NowPlayingProvider` 为 `@MainActor`），故以 `@unchecked Sendable` 满足跨 actor 发布需求。
struct NowPlayingInfo: Equatable, @unchecked Sendable {
    /// 曲目标题
    var title: String?
    /// 艺术家
    var artist: String?
    /// 专辑
    var album: String?
    /// 封面图片
    var artwork: NSImage?
    /// 总时长（秒）
    var duration: TimeInterval
    /// 已播放时长（秒）
    var elapsed: TimeInterval
    /// 是否正在播放
    var isPlaying: Bool
    /// 播放器名（如 "Music"、"Spotify"），由 bundle id 解析得到
    var source: String
    /// 该信息被数据源生成/收到的时间，用于判断 elapsed 是否足够新鲜、可否作为校准依据
    var receivedAt: Date

    /// 忽略 `artwork`（NSImage 对象标识不稳定）和 `elapsed`（进度 Timer 持续平滑推进），
    /// 只比较曲目元数据与播放状态。这样数据源即使每次都返回新的 NSImage 对象，
    /// 或者 elapsed 存在微小偏差，也不会导致 `NowPlayingProvider` 重置已播放进度。
    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying
            && lhs.source == rhs.source
    }

    /// 比较除 `elapsed` 外的所有业务字段（等价于 `==`），语义上更明确。
    func isSameContent(as other: NowPlayingInfo) -> Bool {
        self == other
    }
}
