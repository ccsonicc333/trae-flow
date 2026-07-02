import XCTest
@testable import TRAE_FLOW

/// `NowPlayingProvider` 轻量测试
///
/// `NowPlayingProvider` 通过 `MediaRemotePlayerSource` 或 `AppleScriptPlayerSource`
/// 轮询系统 Now Playing 状态。
///
/// 安全性：`init()` 不触碰 MediaRemote（仅初始化空状态），因此 `.shared` 访问在测试
/// runner 中也是安全的。`start()` 才会触发 MediaRemote 调用 —— 测试不调用 `start()`，
/// 仅验证单例可访问、数据模型可构造、控制方法签名正确（`sendCommand` 在框架不可用时
/// 静默返回，不会崩溃）。
@MainActor
final class NowPlayingProviderTests: XCTestCase {

    // MARK: - Class & model metadata

    func testNowPlayingProviderClassExists() {
        let cls = NSClassFromString("TRAE_FLOW.NowPlayingProvider")
            ?? NSClassFromString("NowPlayingProvider")
        XCTAssertNotNil(cls, "NowPlayingProvider class should be registered in the ObjC runtime")
    }

    func testNowPlayingInfoStructShape() {
        let info = NowPlayingInfo(
            title: "Title",
            artist: "Artist",
            album: "Album",
            artwork: nil,
            duration: 180.0,
            elapsed: 42.0,
            isPlaying: true,
            source: "Music",
            receivedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(info.title, "Title")
        XCTAssertEqual(info.artist, "Artist")
        XCTAssertEqual(info.album, "Album")
        XCTAssertNil(info.artwork)
        XCTAssertEqual(info.duration, 180.0)
        XCTAssertEqual(info.elapsed, 42.0)
        XCTAssertTrue(info.isPlaying)
        XCTAssertEqual(info.source, "Music")
    }

    func testNowPlayingInfoEqualitySemantics() {
        // `receivedAt` 不参与 `==` 比较，统一用固定日期避免引入不确定性
        let date = Date(timeIntervalSince1970: 0)
        let a = NowPlayingInfo(title: "t", artist: "a", album: "al",
                               artwork: nil, duration: 1, elapsed: 0,
                               isPlaying: false, source: "Music", receivedAt: date)
        let b = NowPlayingInfo(title: "t", artist: "a", album: "al",
                               artwork: nil, duration: 1, elapsed: 0,
                               isPlaying: false, source: "Music", receivedAt: date)
        let c = NowPlayingInfo(title: "different", artist: "a", album: "al",
                               artwork: nil, duration: 1, elapsed: 0,
                               isPlaying: false, source: "Music", receivedAt: date)
        XCTAssertEqual(a, b, "identical field values should be equal")
        XCTAssertNotEqual(a, c, "differing title should break equality")
    }

    // MARK: - Singleton & playback control
    //
    // `init()` 现在是安全的（不调用 MediaRemote），`.shared` 访问不会崩溃。
    // `start()` 才会启动轮询 —— 测试不调用 `start()`，避免 MediaRemote ABI 风险。
    // 控制方法（play/pause/...）调用 `MediaRemoteBridge.sendCommand`，在框架不可用
    // 或符号缺失时静默返回，不会崩溃。

    func testSharedInstanceIsAccessible() {
        let first = NowPlayingProvider.shared
        let second = NowPlayingProvider.shared
        XCTAssertTrue(first === second, "shared should return the same singleton instance")
    }

    func testNowPlayingAccessDoesNotCrash() {
        // 未调用 start() 时 nowPlaying 应为 nil（数据源尚未轮询）
        let value = NowPlayingProvider.shared.nowPlaying
        XCTAssertNil(value, "nowPlaying should be nil before start() is called")
    }

    func testIsStartedFalseBeforeStart() {
        XCTAssertFalse(NowPlayingProvider.shared.isStarted, "isStarted should be false before start()")
    }

    func testPlaybackControlMethodsDoNotCrash() {
        // sendCommand 在 MediaRemote 不可用时静默返回，不会崩溃
        NowPlayingProvider.shared.play()
        NowPlayingProvider.shared.pause()
        NowPlayingProvider.shared.skipToNext()
        NowPlayingProvider.shared.skipToPrevious()
        NowPlayingProvider.shared.togglePlayPause()
    }
}
