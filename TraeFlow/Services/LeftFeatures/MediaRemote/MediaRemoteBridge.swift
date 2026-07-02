import AppKit
import Foundation

// Spec: 左侧 Flow 岛音乐功能使用 MediaRemote 私有框架（系统级 Now Playing 聚合层）。
// 项目不上架 App Store，可直接使用私有框架。
//
// 实现方式：MediaRemote.framework 的 SDK tbd 仅声明 arm64e 目标，
// 普通 arm64 链接时符号无法解析，因此采用 `dlopen` + `dlsym` 动态加载，
// 运行时从 `/System/Library/PrivateFrameworks/MediaRemote.framework` 解析符号。
// 这样无需在 OTHER_LDFLAGS 配置 `-weak_framework`，也不依赖链接时符号存在。

// MARK: - Now Playing 信息字典 keys（CFString）
// 这些 key 对应 MRMediaRemoteGetNowPlayingInfo 返回的 NSDictionary 中的 key
extension MediaRemoteBridge {
    static let infoTitleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    static let infoArtistKey = "kMRMediaRemoteNowPlayingInfoArtist"
    static let infoAlbumKey = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let infoArtworkDataKey = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let infoDurationKey = "kMRMediaRemoteNowPlayingInfoDuration"
    static let infoElapsedTimeKey = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let infoPlaybackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let infoMediaTypeKey = "kMRMediaRemoteNowPlayingInfoMediaType"
    static let infoAppDisplayIDKey = "kMRMediaRemoteNowPlayingInfoAppDisplayID"
}

// MARK: - 通知名
extension MediaRemoteBridge {
    static let nowPlayingInfoDidChangeNotification = "kMRNowPlayingInfoDidChangeNotification"
    static let nowPlayingPlaybackStateDidChangeNotification = "kMRNowPlayingPlaybackStateDidChangeNotification"
    static let nowPlayingApplicationIsPlayingDidChangeNotification = "kMRNowPlayingApplicationIsPlayingDidChangeNotification"
}

// MARK: - 播放状态枚举
/// 对应 MediaRemote 私有框架的 MRPlaybackState C enum
/// rawValue 必须与 C enum 值一致：stopped=0, paused=1, playing=2
enum MRPlaybackState: Int {
    case stopped = 0
    case paused = 1
    case playing = 2
}

// MARK: - 播放命令枚举（MRCommand）
/// 对应 MediaRemote 私有框架的 MRCommand C enum
/// rawValue 必须与 C enum 值一致：play=0, pause=1, togglePlayPause=2, nextTrack=4, previousTrack=5
enum MRCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

// MARK: - MediaRemote 私有框架桥接（dlopen 动态加载）
/// 通过 `dlopen` + `dlsym` 运行时加载 MediaRemote.framework 的私有 C 函数符号，
/// 避免链接时对 arm64e-only tbd 的符号解析失败。
///
/// 性能与安全说明：
/// - `dispatch_queue_t` 参数直接用 `DispatchQueue` 类型声明，由 Swift 处理 ARC 桥接，
///   不再用 `UnsafeRawPointer` + `Unmanaged`（前者会导致 ARC 失配，可能触发
///   MediaRemote 内部 `MRNotificationClient` 的指针解引用崩溃）。
/// - `MRMediaRemoteRegisterForNowPlayingNotifications` 在 arm64 进程中调用会触发
///   `EXC_BAD_ACCESS`（arm64e PAC 失配），因此默认不注册通知，改用轮询拉取数据。
enum MediaRemoteBridge {
    /// MediaRemote.framework 的路径
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    /// dlopen 句柄；懒加载，进程生命周期内持有
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen(frameworkPath, RTLD_NOW)
    }()

    /// 框架是否可用（dlopen 成功）—— 调用方用来决定是否启动轮询
    static var isAvailable: Bool { handle != nil }

    /// 通过符号名查找 C 函数指针
    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle else { return nil }
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: - C 函数类型别名

    /// void MRMediaRemoteRegisterForNowPlayingNotifications(void)
    private typealias RegisterForNowPlayingNotificationsFunc = @convention(c) () -> Void

    /// void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^handler)(NSDictionary *info))
    /// `dispatch_queue_t` 在 Swift 中桥接为 `DispatchQueue`（Objective-C 对象），
    /// 由 Swift 处理 ARC retain/release；block 参数必须显式 `@escaping`，
    /// 否则 Swift 会将其作为 `@noescape` 传递给 C，导致异步回调返回前 block 被释放、
    /// 触发 `closure argument passed as @noescape to Objective-C` 运行时崩溃。
    private typealias GetNowPlayingInfoFunc = @convention(c) (
        DispatchQueue?,
        @escaping @convention(block) (NSDictionary?) -> Void
    ) -> Void

    /// void MRMediaRemoteGetPlaybackState(dispatch_queue_t queue, void (^handler)(MRPlaybackState state))
    /// 回调用 Int 接收 C enum 值
    private typealias GetPlaybackStateFunc = @convention(c) (
        DispatchQueue?,
        @escaping @convention(block) (Int) -> Void
    ) -> Void

    /// void MRMediaRemoteSendCommand(MRCommand command, NSDictionary *options)
    /// command 为 Int（C enum 按 int 传递）
    private typealias SendCommandFunc = @convention(c) (Int, NSDictionary?) -> Void

    // MARK: - 公开 API

    /// 注册 Now Playing 通知。
    ///
    /// ⚠️ **已知崩溃风险**：在 arm64 进程中调用此函数会触发 `EXC_BAD_ACCESS`
    /// （MediaRemote.framework 的 arm64e slice 内部使用 PAC 签名指针，
    /// `MRNotificationClient registerForNowPlayingNotificationsWithQueue:force:`
    /// 解引用非 PAC 指针时崩溃）。
    ///
    /// 默认不调用 —— `NowPlayingProvider` 改用 `getNowPlayingInfo` 轮询。
    /// 保留此方法仅供调试或未来 arm64e 构建使用。
    static func registerForNowPlayingNotifications() {
        guard let fn = lookup("MRMediaRemoteRegisterForNowPlayingNotifications",
                               as: RegisterForNowPlayingNotificationsFunc.self) else { return }
        fn()
    }

    /// 获取当前 Now Playing 信息字典（异步，通过 callback 回调）
    /// C 签名：`void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^handler)(NSDictionary *info))`
    /// 失败时以 nil 回调
    static func getNowPlayingInfo(dispatchQueue: DispatchQueue, completion: @escaping (NSDictionary?) -> Void) {
        guard let fn = lookup("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFunc.self) else {
            completion(nil)
            return
        }
        // 直接传 DispatchQueue，Swift 处理 ARC 桥接与 block 构造
        fn(dispatchQueue, completion)
    }

    /// 获取当前播放状态（异步）
    /// 回调返回 Int，调用方通过 `MRPlaybackState(rawValue:)` 转换
    /// C 签名：`void MRMediaRemoteGetPlaybackState(dispatch_queue_t queue, void (^handler)(MRPlaybackState state))`
    static func getPlaybackState(dispatchQueue: DispatchQueue, completion: @escaping (Int) -> Void) {
        guard let fn = lookup("MRMediaRemoteGetPlaybackState", as: GetPlaybackStateFunc.self) else {
            completion(MRPlaybackState.stopped.rawValue)
            return
        }
        fn(dispatchQueue, completion)
    }

    /// 发送播放控制命令
    /// C 签名：`void MRMediaRemoteSendCommand(MRCommand command, NSDictionary *options)`
    /// `options` 通常传 nil
    static func sendCommand(command: MRCommand, options: NSDictionary?) {
        guard let fn = lookup("MRMediaRemoteSendCommand", as: SendCommandFunc.self) else { return }
        fn(command.rawValue, options)
    }
}
