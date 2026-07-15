import AppKit
import Combine
import Foundation
import WebKit

/// Spec: mineradio-bridge-compat-layer — WKWebView ↔ JSC 桥接协调器。
///
/// 单例 `@MainActor ObservableObject`，持有 `MineradioBridgeEngine` 和专用 `URLSession`（二进制代理）。
/// 负责：
/// 1. 将 WKWebView 的 `mineradioApi` / `mineradioBinary` 消息转发到 JSC 引擎
/// 2. 二进制响应（`/api/audio`、`/api/cover`）直接用 URLSession 代理 + 伪造 Referer
/// 3. 通过 `evaluateJavaScript` 调 `window.__mineradioDeliverJSON` 回传结果
/// 4. 维护三平台 `@Published loginStates`，由 cookie 变化或手动刷新触发
@MainActor
final class MineradioBridgeCoordinator: ObservableObject {

    static let shared = MineradioBridgeCoordinator()

    // MARK: - Published State

    /// 三平台登录状态（UI 观察）
    @Published private(set) var loginStates: [MusicPlatform: MineradioLoginState] = [
        .netease: .unknown,
        .qq: .unknown,
        .kugou: .unknown,
    ]

    /// 当前请求展示登录视图的平台（设置 UI 观察）
    @Published var presentingLoginFor: MusicPlatform?

    /// Spec: mineradio-bridge-compat-layer — 当前播放状态（紧凑态 UI 观察）
    @Published private(set) var playback: MineradioPlaybackState?

    /// Spec: mineradio-bridge-compat-layer — 当前应显示的歌词行（紧凑态 UI 观察）
    @Published private(set) var currentLyric: MineradioLyricLine?

    /// Spec: 当前歌词行的演唱进度 0...1（elapsed - line.time) / (nextLine.time - line.time)）
    /// 由 `updateCurrentLyric` 同步更新，紧凑态 UI 用其驱动 karaoke 高亮动画。
    /// 无歌词或无法计算时为 0。
    @Published private(set) var currentLyricProgress: Double = 0

    /// Spec: mineradio-bridge-compat-layer — 当前歌曲专辑封面图片（紧凑态 UI 观察）
    /// 由 `loadCoverImage` 异步加载（伪造 Referer 处理防盗链）或从 data: URI 解码
    /// 使用 `setCoverImage(_:)` 设置，自动递增 `coverImageRevision` 触发 SwiftUI 刷新
    @Published private(set) var coverImage: NSImage?

    /// Spec: 封面图片的唯一标识，每次设置新封面时递增，用于 SwiftUI 强制刷新 Image
    @Published private(set) var coverImageRevision: Int = 0

    /// Spec: 统一的封面设置入口，自动递增 revision 触发 SwiftUI 刷新
    private func setCoverImage(_ image: NSImage?) {
        coverImage = image
        coverImageRevision += 1
    }

    // MARK: - Private State

    private weak var webView: WKWebView?
    private let engine = MineradioBridgeEngine.shared
    private let binarySession: URLSession
    private var isRefreshingLoginStates = false

    /// 歌词行缓存（按 songId）
    private var lyricLines: [MineradioLyricLine] = []
    /// 已获取歌词的 songId（用于检测歌曲切换）
    private var lastFetchedLyricSongId: String?
    /// 歌词获取中标记（避免重复请求）
    private var isFetchingLyric = false
    /// Spec: 当前正在获取歌词的 songId。用于允许不同 songId 的请求并发 ——
    /// 旧实现用布尔锁 `isFetchingLyric`，第一首歌请求进行中时切到第二首会被
    /// `guard !isFetchingLyric` 挡掉，`lastFetchedLyricSongId` 停在旧值，
    /// 新歌歌词永远不会被请求（旧请求回调被 songId 守卫丢弃）。
    /// 现在改为只阻止对同一 songId 的重复请求，不同 songId 的旧请求回调会被
    /// `parseLyricResponse` 的 songId 守卫自动丢弃。
    private var fetchingLyricSongId: String?

    /// Spec: 订阅 NowPlayingProvider 流式更新 —— mineradio.art 的 `<audio>` 由系统 MediaRemote
    /// 统一 hook（无需依赖 WKWebView 注入脚本），用其 elapsed/duration/isPlaying 驱动歌词 progression。
    /// songId 仍由 WKWebView 脚本异步提供（必须展开过 Mineradio 至少一次）。
    private var nowPlayingCancellable: AnyCancellable?
    /// 标记当前 NowPlaying 是否来自 Mineradio（title 含 "Mineradio" 或 source 是本 app）
    private var isMineradioPlaying = false

    /// Spec: 上次收到 WKWebView playback 消息的时间。用于检测播放状态陈旧 ——
    /// WebView 收起后 JS 事件可能暂停（WKWebView 不在视图层级时 timer 被节流），
    /// 此时用 MediaRemote 的 elapsed/duration 作为回退，避免 UI 卡在旧值。
    private var lastPlaybackMessageTime: Date = .distantPast

    // MARK: - Init

    private nonisolated init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        binarySession = URLSession(configuration: config)
    }

    /// Spec: 订阅 NowPlayingProvider —— 主线程启动后调用。
    /// 由 AppDelegate 在 applicationDidFinishLaunching 触发，或首次 attach webView 时懒启动。
    func startNowPlayingSubscription() {
        guard nowPlayingCancellable == nil else { return }
        nowPlayingCancellable = NowPlayingProvider.shared.$nowPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.handleNowPlayingUpdate(info)
            }
    }

    /// Spec: 处理 NowPlayingProvider 更新 —— 检测是否来自 Mineradio 播放。
    /// Mineradio 在 WKWebView 内播放 `<audio>`，系统 MediaRemote 会把 TRAE FLOW app 作为 source，
    /// title 通常是网页 `<title>`（"Mineradio — 在线音乐可视化播放器"）。
    ///
    /// Spec: MediaRemote 仅用于检测"是否有 Mineradio 在播放"（isPlaying）和补全 elapsed/duration。
    /// title/artist/cover 完全不采用 MediaRemote 的值 —— WKWebView 的 `<audio>` 不会向 MediaRemote
    /// 发布歌曲元数据，MediaRemote 报告的 title 可能是：
    ///   1. 网页标题（"Mineradio — 在线音乐可视化播放器"，已被 isNonSongTitleText 过滤）
    ///   2. 上一个 MediaRemote 源的残留 title（如 Music.app 切换到 Mineradio 后 title 仍为旧歌）
    ///   3. 空
    /// 这些都不可靠，title/artist/cover 只从 WKWebView DOM/playQueue 获取。
    /// elapsed/duration 优先用 WKWebView `playback` 消息（最准确），但当 WKWebView 不在视图层级
    /// （Flow 岛收起）时 JS 事件可能暂停，playback 消息停止到达。此时用 MediaRemote 的
    /// elapsed/duration 作为回退，避免 UI 卡在旧值/0 秒。
    private func handleNowPlayingUpdate(_ info: NowPlayingInfo?) {
        guard let info = info else {
            // 播放停止：若之前是 Mineradio 在播，清空状态
            if isMineradioPlaying {
                isMineradioPlaying = false
                if var state = playback {
                    state.isPlaying = false
                    playback = state
                }
            }
            return
        }

        // 判断是否来自 Mineradio：title 含 "Mineradio" 或 source 含 "TRAE FLOW"/本 app bundle id
        let isMineradioSource = isMineradioNowPlayingInfo(info)
        if !isMineradioSource {
            // 非 Mineradio 播放：若之前是 Mineradio 在播，不强制清空（避免短暂切换抖动）
            return
        }

        isMineradioPlaying = info.isPlaying

        var state = playback ?? MineradioPlaybackState(
            elapsed: 0, duration: 0, isPlaying: false,
            songId: nil, provider: "netease", title: nil, artist: nil)
        state.isPlaying = info.isPlaying

        // Spec: 播放状态陈旧检测 —— WKWebView 不在视图层级时 JS 事件暂停，
        // playback 消息停止到达。超过 3 秒无消息时用 MediaRemote 的 elapsed/duration 回退。
        let playbackStale = Date().timeIntervalSince(lastPlaybackMessageTime) > 3.0
        if playbackStale {
            // Spec: 陈旧回退 —— 用 MediaRemote 的 elapsed/duration
            // 仅当 MediaRemote 的值比当前 state 的值更"新"时才更新
            if info.elapsed > state.elapsed || state.duration == 0 {
                state.elapsed = info.elapsed
            }
            if info.duration > 0 && (state.duration == 0 || abs(info.duration - state.duration) > 1) {
                state.duration = info.duration
            }
        } else {
            // Spec: WKWebView playback 消息活跃 —— 仅在 state 为 0 时用 MediaRemote 兜底（首次启动）
            if state.elapsed == 0 { state.elapsed = info.elapsed }
            if state.duration == 0 { state.duration = info.duration }
        }

        // Spec: 不从 MediaRemote 设置 title/artist —— MediaRemote 对 WKWebView `<audio>` 的
        // title 报告不可靠（可能是网页标题、上一个源的残留、或空）。title/artist 只从
        // WKWebView DOM/playQueue 获取（trackChanged/song 消息/queryCurrentTrackFromWebView）。
        playback = state

        // Spec: 不在 MediaRemote 更新里驱动歌词 —— 由 WKWebView playback 消息驱动
        // 例外 1：WKWebView 未展开时（webView == nil），playback 消息不会到达
        // 例外 2：playback 消息陈旧（>3s），用 MediaRemote 的 elapsed 兜底驱动歌词
        if webView == nil || playbackStale {
            updateCurrentLyric()
        }

        // Spec: 主动向 WKWebView 注入脚本查询封面。
        queryCoverAndSongFromWebView()
    }

    /// Spec: 向 WKWebView 注入脚本查询 `#thumb-cover` 的 src 和 `#control-cover` 的 background-image，
    /// 以及 `#control-title` / `#control-artist` 的文本。查询结果通过 `evaluateJavaScript` completion handler 回传。
    /// 每次调用节流 1 秒，避免 MediaRemote 高频更新导致过载。
    private var lastWebViewQueryTime: Date = .distantPast

    /// Spec: 上次查询到的歌曲标题，用于检测歌曲切换并强制重新加载封面
    private var lastQueriedTitle: String?

    /// Spec: 上次查询到的 songId，用于检测歌曲切换
    private var lastQueriedSongId: String?
    /// Spec: queryCurrentTrackFromWebView 的代数计数器，防止旧回调覆盖新状态。
    /// 每次 trackChanged 发起新查询时递增；回调返回时若 generation 已过期则丢弃结果。
    private var trackQueryGeneration: UInt64 = 0

    /// Spec: trackChanged 信号到达后，主动查询 playQueue[currentIdx] 获取当前歌曲完整信息。
    /// 这是切歌时获取 songId 的最可靠方式 —— playQueue 在 audio.src 变化时已推进到新歌。
    /// 查询结果用于：更新 songId/title/artist/cover、触发歌词获取、加载封面。
    private func queryCurrentTrackFromWebView() {
        guard let webView = webView else {
            NSLog("[MineradioPlayback] queryCurrentTrack: webView nil, retry in 500ms")
            // WKWebView 未就绪，延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.queryCurrentTrackFromWebView()
            }
            return
        }

        // Spec: 每次发起新查询时递增 generation，防止旧查询回调覆盖新状态。
        // 典型场景：切歌后旧查询刚好返回，若不用 generation 过滤会把上一首歌的 title 写回来。
        trackQueryGeneration += 1
        let currentGeneration = trackQueryGeneration

        // Spec: 只查询 mineradio.art 明确的 playQueue + currentIdx。
        // 之前扫描过多通用变量名（list/songs/queue 等）导致误匹配页面里的推荐/搜索/导航数组，
        // 取到错误的 songId/title。mineradio 的播放队列就是 window.playQueue，用明确名称即可。
        let trackScript = """
        (function() {
            var result = { songId: null, title: null, artist: null, provider: null, coverURL: null, coverType: 'none', debug: '' };
            var queueNames = ['playQueue'];
            var idxNames = ['currentIdx','currentIndex','curIndex','idx','index','playingIdx','playIndex','currentSongIdx','songIndex'];
            try {
                for (var qi = 0; qi < queueNames.length; qi++) {
                    var q = window[queueNames[qi]];
                    if (!q || !Array.isArray(q) || q.length === 0) continue;
                    for (var ii = 0; ii < idxNames.length; ii++) {
                        var idx = window[idxNames[ii]];
                        if (typeof idx !== 'number' || idx < 0 || idx >= q.length) continue;
                        var s = q[idx];
                        if (s && typeof s === 'object') {
                            result.debug = 'queue=' + queueNames[qi] + ' idx=' + idxNames[ii] + ' keys=' + Object.keys(s).slice(0,15).join(',');
                            if (s.id != null) { result.songId = String(s.id); }
                            if (s.name) { result.title = s.name; }
                            else if (s.title) { result.title = s.title; }
                            if (s.artist) { result.artist = s.artist; }
                            else if (s.artists) {
                                if (typeof s.artists === 'string') { result.artist = s.artists; }
                                else if (Array.isArray(s.artists) && s.artists.length > 0) {
                                    var first = s.artists[0];
                                    result.artist = typeof first === 'string' ? first : (first.name || '');
                                }
                            }
                            if (s.provider) { result.provider = s.provider; }
                            else if (s.source) { result.provider = s.source; }
                            var cover = s.cover || s.picUrl || s.albumimg || s.pic || s.albumPic || s.coverUrl || s.cover_url || s.imgurl || s.img || s.artwork || s.thumbnail || '';
                            if (cover && cover.indexOf('http') === 0) {
                                result.coverURL = cover;
                                result.coverType = 'http';
                            } else if (cover && cover.indexOf('data:image/') === 0) {
                                result.coverURL = cover;
                                result.coverType = 'data';
                            }
                            break;
                        }
                    }
                    if (result.songId) break;
                }
            } catch (e) { result.debug = 'error: ' + (e && e.message || e); }
            return JSON.stringify(result);
        })();
        """

        webView.evaluateJavaScript(trackScript) { [weak self] result, error in
            guard let self = self, let jsonString = result as? String else {
                if let error = error {
                    NSLog("[MineradioPlayback] queryCurrentTrack JS error: %@", error.localizedDescription)
                }
                return
            }
            guard let data = jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                NSLog("[MineradioPlayback] queryCurrentTrack parse failed: %@", String(jsonString.prefix(200)))
                return
            }

            let songId = dict["songId"]
            let title = dict["title"]
            let artist = dict["artist"]
            let provider = dict["provider"]
            let coverURL = dict["coverURL"]
            let coverType = dict["coverType"] ?? "none"
            let debug = dict["debug"] ?? ""

            NSLog("[MineradioPlayback] queryCurrentTrack: songId=%@ title=%@ provider=%@ coverType=%@ debug=%@",
                  songId ?? "nil", title ?? "nil", provider ?? "nil", coverType, String(debug.prefix(200)))

            // Spec: 丢弃过期查询回调 —— trackChanged 后可能已有新查询，旧回调返回的是上一首歌数据。
            if currentGeneration != self.trackQueryGeneration {
                NSLog("[MineradioPlayback] queryCurrentTrack: generation %llu expired (current %llu), dropping",
                      currentGeneration, self.trackQueryGeneration)
                return
            }

            guard let songId = songId, !songId.isEmpty else {
                NSLog("[MineradioPlayback] queryCurrentTrack: no songId, retry in 500ms")
                // playQueue 可能还没更新，延迟重试
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.queryCurrentTrackFromWebView()
                }
                return
            }

            // Spec: 如果当前 playback 已经有 songId，必须和查询结果一致才接受更新。
            // 防止 playQueue 提前推进到下一首（Mineradio 预缓冲）或误匹配导致错误数据覆盖。
            let currentSongId = self.playback?.songId
            if let currentSongId = currentSongId, !currentSongId.isEmpty, currentSongId != songId {
                NSLog("[MineradioPlayback] queryCurrentTrack: songId mismatch (current %@, got %@), drop update",
                      currentSongId, songId)
                return
            }

            // 更新 playback 状态
            // Spec: queryCurrentTrackFromWebView 更新 songId/provider/title/artist/cover。
            // songId guard 已确保 playQueue[currentIdx] 与当前 playback.songId 一致 ——
            // 在 trackChanged 调用路径下，playQueue[currentIdx] 在 audio.src 变化时已对齐到
            // 实际播放歌曲，title/artist 可安全采用。这是 postSong 之外的第二条 title/artist
            // 补全路径，当 postSong 读到的 DOM 还未更新时由此路径兜底。
            var state = self.playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: provider ?? "netease", title: nil, artist: nil, coverURL: nil)
            state.songId = songId
            if let provider = provider, !provider.isEmpty { state.provider = provider }
            // Spec: 补全 title/artist（仅当查询结果非空且为合法歌曲标题时）
            if let title = title, !title.isEmpty, !self.isNonSongTitleText(title) {
                if state.title != title { state.title = title }
            }
            if let artist = artist, !artist.isEmpty, state.artist != artist {
                state.artist = artist
            }

            // 触发歌词获取（仅当 songId 变化）
            if songId != self.lastFetchedLyricSongId {
                self.fetchLyric(for: songId)
            }

            // Spec: 加载封面 —— coverURL 变化时也重新加载（修正 trackChanged 阶段可能加载的错误封面）
            if coverType != "none" && coverType != "blob" {
                if coverType == "data" {
                    self.fetchCoverDataFromWebView(webView)
                } else if coverType == "http" {
                    if let url = coverURL {
                        if let normalized = self.normalizeCoverURL(url, provider: state.provider) {
                            let currentCoverURL = state.coverURL
                            if currentCoverURL == nil || currentCoverURL != normalized || self.coverImage == nil {
                                state.coverURL = normalized
                                self.loadCoverImage(from: normalized, provider: state.provider)
                            }
                        }
                    }
                }
            }

            self.playback = state
            self.updateCurrentLyric()
        }
    }

    private func queryCoverAndSongFromWebView() {
        // 节流：1 秒内不重复查询
        let now = Date()
        if now.timeIntervalSince(lastWebViewQueryTime) < 1.0 { return }
        lastWebViewQueryTime = now

        guard let webView = webView else { return }

        // Spec: 优先从 JS 内存读原始封面 URL，绕过 WKWebView 渲染时序。
        // mineradio.art 的"我的歌单"曲目（handlePlaylistTracks）不调 backfillSongCovers，
        // 部分曲目 al.picUrl 为空，DOM #thumb-cover.src 也为空。但播放队列里的 song 对象
        // 可能仍带 cover/picUrl/albumimg 字段（来自 mapSongRecord）。
        //
        // 探测策略：mineradio.art 的全局变量名未公开，枚举常见候选名
        // (playQueue/playlist/playList/queue/songs/list/trackList/currentList/playerQueue) +
        // 索引变量名 (currentIdx/currentIndex/curIndex/idx/index/playingIdx)。
        // 找到首个 Array 且 [idx] 是 object 的组合即用。
        // 同时 dump 候选变量名和 song 对象字段名到日志，便于后续校准。
        let metaScript = """
        (function() {
            var result = { coverURL: null, coverType: 'none', title: null, artist: null, songId: null, provider: null, debug: '' };

            // 候选队列变量名 + 候选索引变量名
            var queueNames = ['playQueue','playlist','playList','queue','songs','list','trackList','currentList','playerQueue','playingList','songList'];
            var idxNames = ['currentIdx','currentIndex','curIndex','idx','index','playingIdx','playIndex','currentSongIdx','songIndex'];
            var foundQueue = null, foundIdx = null, foundSong = null;

            try {
                for (var qi = 0; qi < queueNames.length && !foundSong; qi++) {
                    var qn = queueNames[qi];
                    var q = window[qn];
                    if (!q || !Array.isArray(q) || q.length === 0) continue;
                    for (var ii = 0; ii < idxNames.length; ii++) {
                        var iname = idxNames[ii];
                        var idx = window[iname];
                        if (typeof idx !== 'number' || idx < 0 || idx >= q.length) continue;
                        var s = q[idx];
                        if (s && typeof s === 'object') {
                            foundQueue = qn; foundIdx = iname; foundSong = s;
                            break;
                        }
                    }
                }
            } catch (e) {
                result.debug = 'probe error: ' + (e && e.message || String(e));
            }

            if (foundSong) {
                result.debug += 'queue=' + foundQueue + ' idx=' + foundIdx + ' keys=' + Object.keys(foundSong).join(',');
                var s = foundSong;
                // 候选封面字段（不同 provider 命名不同）
                var coverFields = ['cover','picUrl','albumimg','pic','albumPic','coverUrl','cover_url','imgurl','img','artwork','thumbnail'];
                for (var ci = 0; ci < coverFields.length; ci++) {
                    var v = s[coverFields[ci]];
                    if (v && typeof v === 'string') {
                        if (v.indexOf('http') === 0) {
                            result.coverURL = v; result.coverType = 'http'; break;
                        }
                        if (v.indexOf('data:image/') === 0) {
                            result.coverURL = v; result.coverType = 'data'; break;
                        }
                    }
                }
                if (s.name) { result.title = s.name; }
                else if (s.title) { result.title = s.title; }
                if (s.artist) { result.artist = s.artist; }
                else if (s.artists) {
                    var arts = s.artists;
                    if (Array.isArray(arts)) { result.artist = arts.map(function(a){return a.name||a;}).join(' / '); }
                }
                if (s.id != null) { result.songId = String(s.id); }
                if (s.provider) { result.provider = s.provider; }
                else if (s.source) { result.provider = s.source; }
            } else {
                // 没找到队列，dump window 上疑似变量名便于校准
                var allKeys = Object.keys(window).filter(function(k){
                    return /queue|list|player|song|track|idx|current|play/i.test(k) && typeof window[k] !== 'function';
                });
                result.debug += 'no queue found, window candidates: ' + allKeys.slice(0, 40).join(',');
            }

            // 回退：从 DOM 查询渲染后的封面
            if (result.coverType === 'none') {
                var thumb = document.getElementById('thumb-cover');
                if (thumb && thumb.src) {
                    result.coverType = thumb.src.indexOf('data:image/') === 0 ? 'data' :
                                       (thumb.src.indexOf('http') === 0 ? 'http' :
                                       (thumb.src.indexOf('blob:') === 0 ? 'blob' : 'other'));
                    if (result.coverType === 'http') { result.coverURL = thumb.src; }
                }
            }
            if (result.coverType === 'none' || result.coverType === 'other') {
                var coverDiv = document.getElementById('control-cover');
                if (coverDiv) {
                    var bg = coverDiv.style.backgroundImage || '';
                    var m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
                    if (m && m[1]) {
                        var src = m[1];
                        result.coverType = src.indexOf('data:image/') === 0 ? 'data' :
                                           (src.indexOf('http') === 0 ? 'http' :
                                           (src.indexOf('blob:') === 0 ? 'blob' : 'other'));
                        if (result.coverType === 'http') { result.coverURL = src; }
                    }
                }
            }
            // 若队列没提供 title/artist，从 DOM 补
            if (!result.title) {
                var titleEl = document.getElementById('control-title');
                if (titleEl && titleEl.textContent.trim()) { result.title = titleEl.textContent.trim(); }
            }
            if (!result.artist) {
                var artistEl = document.getElementById('control-artist');
                if (artistEl && artistEl.textContent.trim()) { result.artist = artistEl.textContent.trim(); }
            }
            return JSON.stringify(result);
        })();
        """

        webView.evaluateJavaScript(metaScript) { [weak self] result, error in
            guard let self = self, let jsonString = result as? String else {
                if let error = error {
                    NSLog("[MineradioPlayback] queryMeta JS error: %@", error.localizedDescription)
                }
                return
            }
            guard let data = jsonString.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                NSLog("[MineradioPlayback] queryMeta parse failed: %@", String(jsonString.prefix(200)))
                return
            }

            let coverType = dict["coverType"] ?? "none"
            let coverURL = dict["coverURL"]
            let queriedSongId = dict["songId"]
            let queriedTitle = dict["title"]
            let queriedArtist = dict["artist"]
            let debug = dict["debug"] ?? ""

            NSLog("[MineradioPlayback] queryMeta: coverType=%@ coverURL=%@ songId=%@ title=%@ debug=%@",
                  coverType,
                  coverURL != nil ? String(coverURL!.prefix(60)) : "nil",
                  queriedSongId ?? "nil",
                  queriedTitle ?? "nil",
                  String(debug.prefix(300)))

            let provider = self.playback?.provider
            var state = self.playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: provider ?? "netease", title: nil, artist: nil, coverURL: nil)

            // Spec: songId guard —— 仅当查询到的 songId 与当前 playback.songId 一致
            // （或当前 songId 为 nil/空，或查询未拿到 songId 即纯 DOM 回退）时才更新 title/artist。
            // mineradio.art 会在当前歌曲播放到后半段时提前推进 playQueue[currentIdx] 到下一首歌，
            // 若不加 guard 会把下一首歌的 title/artist 提前写到 UI，导致歌词/标题错位。
            // 当 queriedSongId 为 nil（playQueue 未命中，title 来自 DOM #control-title）时，
            // DOM 显示的是实际正在播放的歌曲，可安全采用。
            let currentSongId = state.songId
            let currentIsEmpty = currentSongId == nil || currentSongId?.isEmpty == true
            let queriedIsEmpty = queriedSongId == nil || queriedSongId?.isEmpty == true
            let songIdMatches = currentIsEmpty || queriedIsEmpty || currentSongId == queriedSongId

            var didUpdate = false
            if songIdMatches {
                if let title = queriedTitle, !title.isEmpty, !self.isNonSongTitleText(title),
                   state.title != title {
                    state.title = title
                    didUpdate = true
                }
                if let artist = queriedArtist, !artist.isEmpty, state.artist != artist {
                    state.artist = artist
                    didUpdate = true
                }
            }

            // Spec: 封面加载 —— coverURL 变化时重新加载（修正旧封面），或 coverImage 为 nil 时加载。
            // 旧实现仅在 coverImage == nil 时加载，导致切歌后若已加载错误封面则无法修正。
            if coverType != "none" && coverType != "blob" {
                if coverType == "data" {
                    // data URI 不易做变化检测，仅在 coverImage 为 nil 时加载
                    if self.coverImage == nil {
                        NSLog("[MineradioPlayback] coverImage nil, fetching: type=data")
                        self.fetchCoverDataFromWebView(webView)
                    }
                } else if coverType == "http" {
                    if let url = coverURL {
                        if let normalized = self.normalizeCoverURL(url, provider: state.provider) {
                            let currentCoverURL = state.coverURL
                            if currentCoverURL == nil || currentCoverURL != normalized || self.coverImage == nil {
                                NSLog("[MineradioPlayback] loading cover: type=http changed=%@",
                                      currentCoverURL != normalized ? "yes" : "no")
                                state.coverURL = normalized
                                didUpdate = true
                                self.loadCoverImage(from: normalized, provider: state.provider)
                            }
                        }
                    }
                }
            }

            if didUpdate {
                self.playback = state
            }
        }
    }

    /// Spec: 从 WKWebView 提取 `#thumb-cover` 的 data URL，解码 base64 为 NSImage
    private func fetchCoverDataFromWebView(_ webView: WKWebView) {
        let script = """
        (function() {
            var thumb = document.getElementById('thumb-cover');
            if (thumb && thumb.src && thumb.src.indexOf('data:image/') === 0) {
                return thumb.src;
            }
            var coverDiv = document.getElementById('control-cover');
            if (coverDiv) {
                var bg = coverDiv.style.backgroundImage || '';
                var m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
                if (m && m[1] && m[1].indexOf('data:image/') === 0) { return m[1]; }
            }
            var bgDiv = document.getElementById('album-bg');
            if (bgDiv) {
                var bg2 = bgDiv.style.backgroundImage || '';
                var m2 = bg2.match(/url\\(["']?([^"')]+)["']?\\)/);
                if (m2 && m2[1] && m2[1].indexOf('data:image/') === 0) { return m2[1]; }
            }
            return '';
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self, let dataURL = result as? String, !dataURL.isEmpty else {
                NSLog("[MineradioPlayback] fetchCoverData empty or error: %@", error?.localizedDescription ?? "nil")
                return
            }
            NSLog("[MineradioPlayback] fetchCoverData got data URL, len=%lu", dataURL.count)
            self.loadCoverImage(from: dataURL, provider: nil)
        }
    }

    /// Spec: 从 WKWebView 提取 http(s) 封面直链，用 URLSession + 伪造 Referer 加载
    private func fetchCoverHTTPURLFromWebView(_ webView: WKWebView, provider: String?) {
        let script = """
        (function() {
            var thumb = document.getElementById('thumb-cover');
            if (thumb && thumb.src && thumb.src.indexOf('http') === 0) {
                var path = thumb.src.replace(/^https?:\\/\\/[^\\/]+/, '');
                if (path !== '/' && path !== '') { return thumb.src; }
            }
            var coverDiv = document.getElementById('control-cover');
            if (coverDiv) {
                var bg = coverDiv.style.backgroundImage || '';
                var m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
                if (m && m[1] && m[1].indexOf('http') === 0) {
                    var path = m[1].replace(/^https?:\\/\\/[^\\/]+/, '');
                    if (path !== '/' && path !== '') { return m[1]; }
                }
            }
            return '';
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self, let httpURL = result as? String, !httpURL.isEmpty else {
                NSLog("[MineradioPlayback] fetchCoverHTTP empty or error: %@", error?.localizedDescription ?? "nil")
                return
            }
            NSLog("[MineradioPlayback] fetchCoverHTTP got URL: %@", String(httpURL.prefix(80)))
            if let normalized = self.normalizeCoverURL(httpURL, provider: provider) {
                self.loadCoverImage(from: normalized, provider: provider)
            }
        }
    }

    /// 判断 NowPlayingInfo 是否来自 Mineradio 播放
    private func isMineradioNowPlayingInfo(_ info: NowPlayingInfo) -> Bool {
        // 1. title 含 "Mineradio"（网页标题回退情况）
        if let title = info.title, title.lowercased().contains("mineradio") {
            return true
        }
        // 2. source 是本 app（TRAE FLOW 在 WKWebView 播放 audio，MediaRemote 会归属到本 app）
        let sourceLower = info.source.lowercased()
        if sourceLower.contains("trae") || sourceLower.contains("flow") {
            return true
        }
        return false
    }

    /// 判断文本是否是非歌曲标题（页面标题 "Mineradio — 在线音乐可视化播放器"、"本地歌曲" 等）
    private func isNonSongTitleText(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("mineradio") && (lower.contains("播放器") || lower.contains("在线音乐")) {
            return true
        }
        if text.contains("本地歌曲") {
            return true
        }
        return false
    }

    // MARK: - WebView Attachment

    /// 绑定 WKWebView，注册 `mineradioApi` / `mineradioBinary` message handler。
    /// 由 `CustomAreaWebView.makeNSView` 在 `.mineradio` 源时调用。
    func attach(to webView: WKWebView) {
        self.webView = webView
        // 初始刷新一次登录态（cookie 变化由 MineradioLoginView 主动触发 refresh）
        refreshAllLoginStates()
        // 懒启动 NowPlayingProvider 订阅（用于 MediaRemote 驱动歌词 progression）
        startNowPlayingSubscription()
    }

    /// 解绑 WebView（关闭时调用）
    func detach() {
        webView = nil
    }

    // MARK: - Message Handling

    /// 处理 `mineradioApi` 消息（普通 API 请求 → JSC 引擎）
    func handleApiMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let payload = body["payload"] as? [String: Any] else {
            NSLog("[MineradioBridge] Invalid API message: \(message.body)")
            return
        }

        engine.handleApi(payload) { [weak self] result in
            DispatchQueue.main.async {
                self?.deliverResult(id: id, result: result)
            }
        }
    }

    /// 处理 `mineradioBinary` 消息（/api/audio、/api/cover → URLSession 代理 + 伪造 Referer）
    func handleBinaryMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let payload = body["payload"] as? [String: Any] else {
            NSLog("[MineradioBridge] Invalid binary message: \(message.body)")
            return
        }

        let query = payload["query"] as? [String: Any] ?? [:]
        guard let urlString = query["url"] as? String, let url = URL(string: urlString) else {
            deliverError(id: id, error: "Missing or invalid url in binary request")
            return
        }

        let method = (payload["method"] as? String ?? "GET").uppercased()
        let extraHeaders = payload["headers"] as? [String: String] ?? [:]

        var request = URLRequest(url: url)
        request.httpMethod = method
        // 伪造 Referer 防盗链
        request.setValue(proxyRefererFor(urlString), forHTTPHeaderField: "Referer")
        // 桌面 Chrome UA
        request.setValue(MineradioBridgeUserScript.desktopChromeUserAgent, forHTTPHeaderField: "User-Agent")
        // 额外 headers（payload.headers 可覆盖默认）
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = binarySession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.deliverError(id: id, error: error.localizedDescription)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.deliverError(id: id, error: "Non-HTTP response")
                    return
                }
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                let bufferBase64 = data?.base64EncodedString() ?? ""
                let result: [String: Any] = [
                    "__binary": true,
                    "status": httpResponse.statusCode,
                    "contentType": contentType,
                    "buffer": bufferBase64,
                ]
                self.deliverResult(id: id, result: .success(result))
            }
        }
        task.resume()
    }

    // MARK: - Playback & Lyrics

    /// Spec: mineradio-bridge-compat-layer — 处理 `mineradioPlayback` 消息。
    ///
    /// 消息类型：
    /// - `{ type: 'trackChanged', songId, provider }` —— audio.src 变化，实际切歌信号
    ///   据此更新 songId、清除旧封面/歌词、触发新歌词获取
    /// - `{ type: 'song', songId, provider, title, artist, coverURL }` —— 歌曲元数据补全
    ///   由 trackChanged 延迟 300ms 后触发，携带 DOM 提取的 title/artist/coverURL
    /// - `{ type: 'playback', elapsed, duration, isPlaying, songId, provider }` —— 音频事件驱动
    ///
    /// Spec: 切歌信号只认 trackChanged（audio.src 变化），不认 MINERADIO_API 拦截的 songId。
    /// mineradio.art 会在当前歌曲后半段提前请求下一首歌的 URL/lyric（预缓冲），此时
    /// MINERADIO_API 拦截到的 songId 是下一首歌的，但 audio.src 还没变，不是实际切歌。
    func handlePlaybackMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            NSLog("[MineradioPlayback] invalid message: \(message.body)")
            return
        }

        if type == "trackChanged" {
            // Spec: trackChanged 携带 playQueue[currentIdx] 查询到的 songId/title/artist/coverURL。
            // JS 端优先从 playQueue 获取（比 pendingSongId 更可靠 —— 用户手动选歌时
            // pendingSongId 可能停留在旧值）。
            let trackSongId = body["songId"] as? String
            let trackProvider = body["provider"] as? String
            let trackTitle = body["title"] as? String
            let trackArtist = body["artist"] as? String
            let trackCoverURL = body["coverURL"] as? String
            NSLog("[MineradioPlayback] trackChanged signal received, songId=%@ provider=%@ title=%@",
                  trackSongId ?? "nil", trackProvider ?? "nil", trackTitle ?? "nil")

            // 清除旧封面和歌词（切歌瞬间）
            setCoverImage(nil)
            lyricLines = []
            currentLyric = nil
            currentLyricProgress = 0

            // Spec: 使用 trackChanged 携带的 title/artist/coverURL（来自 playQueue[currentIdx]）。
            // 旧实现清空 title/artist/coverURL，等 postSong（300ms 后）补全 —— 但 postSong 只
            // 运行一次，若 DOM 未更新则 title 长时间为 nil，紧凑态空白。现在 trackChanged 立即
            // 携带 playQueue 数据，紧凑态切歌瞬间即可显示。
            var state = playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: trackProvider ?? "netease", title: nil, artist: nil, coverURL: nil)
            if let title = trackTitle, !title.isEmpty, !isNonSongTitleText(title) {
                state.title = title
            } else {
                state.title = nil
            }
            if let artist = trackArtist, !artist.isEmpty {
                state.artist = artist
            } else {
                state.artist = nil
            }
            if let coverURL = trackCoverURL, !coverURL.isEmpty {
                state.coverURL = normalizeCoverURL(coverURL, provider: trackProvider)
            } else {
                state.coverURL = nil
            }
            // Spec: 保留 elapsed/duration/isPlaying —— 切歌瞬间 audio.currentTime 会重置为 0，
            // 但 isPlaying 状态可以保留，避免 UI 闪烁。
            if let songId = trackSongId, !songId.isEmpty {
                state.songId = songId
                if let provider = trackProvider, !provider.isEmpty {
                    state.provider = provider
                }
                playback = state
                // Spec: 立即获取歌词，不等异步查询
                if songId != lastFetchedLyricSongId {
                    fetchLyric(for: songId)
                }
                // Spec: 立即加载封面（trackChanged 携带的 coverURL 来自 playQueue）
                if let coverURL = state.coverURL {
                    loadCoverImage(from: coverURL, provider: state.provider)
                }
            } else {
                // trackChanged 未携带 songId（playQueue 不可用且 pendingSongId 为空）
                // 清空 songId，等 queryCurrentTrackFromWebView 查询
                state.songId = nil
                playback = state
            }

            // Spec: 仍查询 playQueue 补全/修正 —— JS 端 queryPlayQueueCurrent 可能因时序问题
            // 未拿到数据，Swift 端异步查询作为备份。songId guard 防止预缓冲污染。
            queryCurrentTrackFromWebView()
        } else if type == "song" {
            let songId = body["songId"] as? String
            let title = body["title"] as? String
            let artist = body["artist"] as? String
            let provider = body["provider"] as? String
            let coverURL = body["coverURL"] as? String

            NSLog("[MineradioPlayback] song msg: songId=%@ title=%@ provider=%@ cover=%@", songId ?? "nil", title ?? "nil", provider ?? "nil", coverURL ?? "nil")

            // Spec: song 消息只补全 title/artist/coverURL，不更新 songId（songId 由 trackChanged 触发查询）
            // 且只在 songId 与当前 playback.songId 匹配时才更新（避免预缓冲的过期 song 消息污染）
            var state = playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: nil, title: nil, artist: nil, coverURL: nil)

            // Spec: 只处理与当前 songId 匹配的 song 消息
            if let songId = songId, !songId.isEmpty, let currentSid = state.songId, songId != currentSid {
                NSLog("[MineradioPlayback] song msg dropped: songId %@ != current %@", songId, currentSid)
                return
            }

            var didUpdate = false
            if let title = title, !title.isEmpty, !isNonSongTitleText(title) {
                if state.title != title { state.title = title; didUpdate = true }
            }
            if let artist = artist, !artist.isEmpty, state.artist != artist {
                state.artist = artist; didUpdate = true
            }
            if let provider = provider, !provider.isEmpty {
                state.provider = provider; didUpdate = true
            }
            if let coverURL = coverURL, !coverURL.isEmpty {
                let normalized = normalizeCoverURL(coverURL, provider: provider)
                if state.coverURL != normalized {
                    state.coverURL = normalized
                    didUpdate = true
                    // Spec: coverURL 变化时重新加载封面 —— 旧实现仅在 coverImage == nil 时加载，
                    // 导致切歌瞬间若 postSong 读到旧 DOM 的 coverURL 并加载了错误封面，
                    // 后续重试拿到正确 coverURL 也无法修正（coverImage 已非 nil）。
                    // 现在只要 coverURL 变化就重新加载，确保封面与实际播放歌曲一致。
                    if let normalized = normalized {
                        loadCoverImage(from: normalized, provider: provider)
                    }
                } else if let normalized = normalized, coverImage == nil {
                    // coverURL 未变但封面还没加载（首次加载）
                    loadCoverImage(from: normalized, provider: provider)
                }
            }
            if didUpdate {
                playback = state
            }
        } else if type == "playback" {
            let elapsed = (body["elapsed"] as? Double)
                ?? (body["elapsed"] as? NSNumber)?.doubleValue ?? 0
            let duration = (body["duration"] as? Double)
                ?? (body["duration"] as? NSNumber)?.doubleValue ?? 0
            let isPlaying = (body["isPlaying"] as? Bool) ?? false
            let provider = body["provider"] as? String
            let msgSongId = body["songId"] as? String

            // Spec: 记录上次收到 WKWebView playback 消息的时间，用于检测陈旧状态
            lastPlaybackMessageTime = Date()

            var state = playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: nil, title: nil, artist: nil)
            state.elapsed = elapsed
            state.duration = duration
            state.isPlaying = isPlaying
            if let provider = provider { state.provider = provider }
            // Spec: 当 state.songId 为空时从 playback 消息补全 —— JS 端在 notifyTrackChanged
            // 时已将 pendingSongId 提升为 currentSongId，playback 消息携带的 songId 可靠。
            // 仅在 songId 为空时补全，避免覆盖 trackChanged/queryCurrentTrack 设置的值。
            if state.songId == nil, let songId = msgSongId, !songId.isEmpty {
                state.songId = songId
                if songId != lastFetchedLyricSongId {
                    fetchLyric(for: songId)
                }
            }
            playback = state

            updateCurrentLyric()
        }
    }

    /// Spec: 规范化封面 URL。
    /// - `data:image/...;base64,...` → 原样返回（直接解码）
    /// - `/api/cover?url=<encoded>&v=<ts>` → 解码出原始直链 `https://...`
    /// - `https://...` 直链 → 原样返回，但排除网站根 URL（如 `https://mineradio.art/`）
    /// - `http://...` 直链 → 升级为 `https://`（ATS 拒绝明文 http，且音乐 CDN 同时支持 https）
    /// - `blob:...` → 返回 nil（无法直接加载）
    private func normalizeCoverURL(_ raw: String, provider: String?) -> String? {
        if raw.hasPrefix("data:image/") {
            return raw
        }
        if raw.hasPrefix("blob:") {
            return nil
        }
        if raw.hasPrefix("http://") {
            // 升级为 https（ATS 策略要求）
            let https = "https://" + raw.dropFirst("http://".count)
            // 排除网站根 URL
            if let url = URL(string: https) {
                let path = url.path
                if path.isEmpty || path == "/" {
                    return nil
                }
            }
            return https
        }
        if raw.hasPrefix("https://") {
            // 排除网站根 URL（如 https://mineradio.art/）
            if let url = URL(string: raw) {
                let path = url.path
                if path.isEmpty || path == "/" {
                    return nil
                }
            }
            return raw
        }
        // /api/cover?url=<encoded>&v=<ts> 代理路径
        if raw.contains("/api/cover?url=") || raw.hasPrefix("/api/cover?url=") {
            // 提取 url 参数值
            if let questionIdx = raw.range(of: "url=") {
                let afterUrl = String(raw[questionIdx.upperBound...])
                // 截取到下一个 & 或字符串结束
                let endIdx = afterUrl.firstIndex(of: "&") ?? afterUrl.endIndex
                let encoded = String(afterUrl[..<endIdx])
                if let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("http") {
                    // 递归规范化（处理解码后的 http:// 升级为 https://）
                    return normalizeCoverURL(decoded, provider: provider)
                }
            }
        }
        return nil
    }

    /// Spec: 异步加载封面图片。
    /// - `data:image/...;base64,...` → 直接解码 base64
    /// - `https://...` → URLSession 请求 + 伪造 Referer（防盗链）
    /// 成功后写入 `@Published coverImage`
    private func loadCoverImage(from coverURL: String, provider: String?) {
        NSLog("[MineradioPlayback] loadCoverImage: type=%@ prefix=%@",
              coverURL.hasPrefix("data:") ? "data" : (coverURL.hasPrefix("http") ? "http" : "other"),
              String(coverURL.prefix(60)))

        // data: URI 直接解码
        if coverURL.hasPrefix("data:") {
            // 格式：data:image/png;base64,<base64>
            if let semIdx = coverURL.range(of: ";base64,") {
                let base64 = String(coverURL[semIdx.upperBound...])
                if let data = Data(base64Encoded: base64) {
                    NSLog("[MineradioPlayback] data URI decoded: %lu bytes", data.count)
                    if let image = NSImage(data: data) {
                        setCoverImage(image)
                        NSLog("[MineradioPlayback] coverImage set from data URI, rev=%d", coverImageRevision)
                        return
                    } else {
                        NSLog("[MineradioPlayback] NSImage(data:) failed")
                    }
                } else {
                    NSLog("[MineradioPlayback] base64 decode failed, len=%lu", base64.count)
                }
            } else {
                NSLog("[MineradioPlayback] data URI without ;base64,")
            }
            setCoverImage(nil)
            return
        }

        guard let url = URL(string: coverURL) else {
            NSLog("[MineradioPlayback] URL(string:) failed: %@", String(coverURL.prefix(80)))
            setCoverImage(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(proxyRefererFor(coverURL), forHTTPHeaderField: "Referer")
        request.setValue(MineradioBridgeUserScript.desktopChromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        NSLog("[MineradioPlayback] fetching cover from: %@", String(coverURL.prefix(80)))

        let task = binarySession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    NSLog("[MineradioPlayback] cover fetch error: %@", error.localizedDescription)
                    self.setCoverImage(nil)
                    return
                }
                guard let data = data else {
                    NSLog("[MineradioPlayback] cover fetch no data")
                    self.setCoverImage(nil)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    NSLog("[MineradioPlayback] cover fetch status=%d bytes=%lu", httpResponse.statusCode, data.count)
                }
                guard let image = NSImage(data: data) else {
                    NSLog("[MineradioPlayback] NSImage(data:) failed for fetched data")
                    self.setCoverImage(nil)
                    return
                }
                self.setCoverImage(image)
                NSLog("[MineradioPlayback] coverImage set from HTTP, rev=%d", self.coverImageRevision)
            }
        }
        task.resume()
    }

    /// 调用 `/api/lyric?id=<songId>` 获取 LRC 歌词，解析后缓存。
    /// 仅支持网易云（netease）歌曲 ID；其他平台跳过。
    /// Spec: 入口处立即清空旧 `lyricLines` 和 `currentLyric`，避免异步请求期间
    /// 旧歌词继续被 `updateCurrentLyric` 用新 elapsed（已是下一首歌的进度）匹配，
    /// 导致"快到下一首歌时闪下一首歌的歌词"。
    private func fetchLyric(for songId: String) {
        // 仅 netease 平台走 /api/lyric
        if let provider = playback?.provider, provider != "netease" {
            lastFetchedLyricSongId = songId
            lyricLines = []
            currentLyric = nil
            currentLyricProgress = 0
            return
        }
        // Spec: 只阻止对同一 songId 的重复请求。不同 songId 的请求允许并发 ——
        // 旧请求的回调会被 parseLyricResponse 的 songId 守卫自动丢弃。
        // 旧实现用 `guard !isFetchingLyric` 会挡掉切歌期间的新请求，导致前几首歌词不显示。
        if fetchingLyricSongId == songId { return }
        // Spec: 不缓存空歌词 songId —— 之前缓存会导致后续切到同一首歌时不重新请求，
        // 若首次失败是网络问题，后续永远拿不到歌词。每次切歌都重新请求。

        // Spec: 立即清空旧歌词，避免异步请求期间旧歌词被新 elapsed 错误匹配
        lyricLines = []
        currentLyric = nil
        currentLyricProgress = 0

        isFetchingLyric = true
        fetchingLyricSongId = songId
        lastFetchedLyricSongId = songId

        let payload: [String: Any] = [
            "path": "/api/lyric",
            "method": "GET",
            "query": ["id": songId],
        ]
        engine.handleApi(payload) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetchingLyric = false
                // Spec: 仅当此次请求是最后一个发起的请求时才清空 fetchingLyricSongId。
                // 若切歌后又发起了新请求，fetchingLyricSongId 已是新 songId，不应清空。
                if self.fetchingLyricSongId == songId {
                    self.fetchingLyricSongId = nil
                }
                switch result {
                case .success(let data):
                    self.parseLyricResponse(data, songId: songId)
                case .failure(let error):
                    NSLog("[MineradioBridge] fetchLyric(%@) failed: %@", songId, error.localizedDescription)
                    // Spec: 仅当当前仍是这首歌时才清空（避免清掉新歌的歌词）
                    if self.playback?.songId == songId {
                        self.lyricLines = []
                        self.currentLyric = nil
                        self.currentLyricProgress = 0
                    }
                }
            }
        }
    }

    /// 解析 `/api/lyric` 响应：`{ lyric: "<LRC>", tlyric, yrc, source }`
    /// Spec: 仅当响应 songId 与当前 playback.songId 一致时才写入 lyricLines，
    /// 避免异步请求期间已切到下一首歌时把上一首歌的歌词塞进去。
    private func parseLyricResponse(_ data: Any?, songId: String) {
        // Spec: songId 守卫 —— 若已切到下一首歌，丢弃过期的歌词响应
        guard playback?.songId == songId else {
            NSLog("[MineradioBridge] lyric response for %@ dropped (current song: %@)", songId, playback?.songId ?? "nil")
            return
        }
        guard let dict = data as? [String: Any] else {
            lyricLines = []
            currentLyric = nil
            currentLyricProgress = 0
            return
        }
        // 优先用 lyric（标准 LRC），若空则尝试 yrc（逐字格式近似解析）
        let lrc = (dict["lyric"] as? String) ?? ""
        let yrc = (dict["yrc"] as? String) ?? ""
        let raw = lrc.isEmpty ? yrc : lrc

        if raw.isEmpty {
            NSLog("[MineradioBridge] lyric empty for song %@", songId)
            lyricLines = []
            currentLyric = nil
            currentLyricProgress = 0
            return
        }

        lyricLines = MineradioLyricParser.parse(raw)
        NSLog("[MineradioBridge] lyric parsed: %d lines for song %@", lyricLines.count, songId)
        updateCurrentLyric()
    }

    /// 根据当前 `playback.elapsed` 和 `lyricLines` 更新 `currentLyric` 和 `currentLyricProgress`
    /// Spec: songId 守卫 —— 仅当 `playback.songId == lastFetchedLyricSongId` 时才计算，
    /// 避免用旧 elapsed 在新歌词数组里查找导致显示错误的歌词行。
    /// songId 只由 "song" 消息路径更新（由实际音频播放的 MINERADIO_API 拦截触发），
    /// 不由 queryCoverAndSongFromWebView 的 playQueue 轮询更新（playQueue 可能提前推进）。
    private func updateCurrentLyric() {
        // Spec: songId 不匹配时清空
        if let songId = playback?.songId, songId != lastFetchedLyricSongId {
            if currentLyric != nil { currentLyric = nil }
            if currentLyricProgress != 0 { currentLyricProgress = 0 }
            return
        }
        guard !lyricLines.isEmpty else {
            if currentLyric != nil { currentLyric = nil }
            if currentLyricProgress != 0 { currentLyricProgress = 0 }
            return
        }
        let elapsed = playback?.elapsed ?? 0
        let newLine = MineradioLyricParser.currentLine(in: lyricLines, at: elapsed)
        // 仅在行变化时更新 currentLyric（减少 SwiftUI 重建）
        if newLine?.id != currentLyric?.id {
            currentLyric = newLine
        }
        // Spec: 始终更新 progress（驱动 karaoke 高亮动画）。
        if let line = newLine {
            let raw = MineradioLyricParser.lineProgress(line: line, in: lyricLines, at: elapsed)
            // 量化到 0.02 精度（约每 2% 跳一档），减少 @Published 频繁触发重绘
            let quantized = (raw * 50).rounded() / 50
            if abs(quantized - currentLyricProgress) > 0.001 {
                currentLyricProgress = quantized
            }
        } else if currentLyricProgress != 0 {
            currentLyricProgress = 0
        }
    }

    /// 根据目标 URL 选择伪造的 Referer（与扩展 content-bridge.js 一致）
    private func proxyRefererFor(_ urlString: String) -> String {
        let lower = urlString.lowercased()
        if lower.contains("qqmusic") || lower.contains("gtimg") || lower.contains("qpic") || lower.contains("y.qq") {
            return "https://y.qq.com/"
        }
        if lower.contains("kugou") {
            return "https://www.kugou.com/"
        }
        return "https://music.163.com/"
    }

    // MARK: - Delivery to WebView

    private func deliverResult(id: String, result: Result<Any?, Error>) {
        guard let webView = webView else { return }
        switch result {
        case .success(let data):
            let js = MineradioBridgeDelivery.makeDeliverCall(id: id, ok: true, data: data, error: nil)
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    NSLog("[MineradioBridge] deliverJS error (ok): %@", error.localizedDescription)
                }
            }
        case .failure(let error):
            let js = MineradioBridgeDelivery.makeDeliverCall(id: id, ok: false, data: nil, error: error.localizedDescription)
            webView.evaluateJavaScript(js) { _, evalError in
                if let evalError = evalError {
                    NSLog("[MineradioBridge] deliverJS error (fail): %@", evalError.localizedDescription)
                }
            }
        }
    }

    private func deliverError(id: String, error: String) {
        deliverResult(id: id, result: .failure(MineradioBridgeError.apiError(error)))
    }

    // MARK: - Login State

    /// 刷新所有平台登录态（通过 `getBridgeStatus` 一次性获取）
    func refreshAllLoginStates() {
        guard !isRefreshingLoginStates else { return }
        isRefreshingLoginStates = true

        engine.handleBridgeStatus { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshingLoginStates = false
                switch result {
                case .success(let data):
                    self.parseBridgeStatus(data)
                case .failure(let error):
                    NSLog("[MineradioBridge] refreshLoginStates failed: %@", error.localizedDescription)
                    // 保持现有状态，不清空
                }
            }
        }
    }

    /// 刷新单个平台登录态
    func refreshLoginState(for platform: MusicPlatform) {
        let payload: [String: Any] = [
            "path": platform.loginStatusPath,
            "method": "GET",
            "query": [:],
        ]
        engine.handleApi(payload) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    self.parseLoginStatus(platform: platform, data: data)
                case .failure(let error):
                    NSLog("[MineradioBridge] refreshLoginState(%@) failed: %@", platform.rawValue, error.localizedDescription)
                }
            }
        }
    }

    private func parseBridgeStatus(_ data: Any?) {
        guard let dict = data as? [String: Any] else { return }

        if let netease = dict["netease"] as? [String: Any] {
            let loggedIn = netease["loggedIn"] as? Bool ?? false
            let nickname = netease["nickname"] as? String ?? ""
            loginStates[.netease] = loggedIn ? .loggedIn(nickname: nickname) : .loggedOut
        }

        if let qq = dict["qq"] as? [String: Any] {
            let loggedIn = qq["loggedIn"] as? Bool ?? false
            let nickname = qq["nickname"] as? String ?? ""
            loginStates[.qq] = loggedIn ? .loggedIn(nickname: nickname) : .loggedOut
        }

        if let kg = dict["kg"] as? [String: Any] {
            let loggedIn = kg["loggedIn"] as? Bool ?? false
            let nickname = kg["nickname"] as? String ?? ""
            loginStates[.kugou] = loggedIn ? .loggedIn(nickname: nickname) : .loggedOut
        }
    }

    private func parseLoginStatus(platform: MusicPlatform, data: Any?) {
        // router.js 的 /api/login/status 返回 { ok, loggedIn, nickname, avatar, ... }
        guard let dict = data as? [String: Any] else {
            loginStates[platform] = .unknown
            return
        }
        let loggedIn = dict["loggedIn"] as? Bool ?? (dict["ok"] as? Bool ?? false)
        let nickname = dict["nickname"] as? String ?? ""
        loginStates[platform] = loggedIn ? .loggedIn(nickname: nickname) : .loggedOut
    }

    // MARK: - Login / Logout Actions

    /// 请求展示登录视图（设置 UI 观察 `presentingLoginFor` 弹 sheet）
    func presentLogin(for platform: MusicPlatform) {
        presentingLoginFor = platform
    }

    /// 退出登录（清除对应平台 cookie）
    func logout(_ platform: MusicPlatform) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let domainPatterns = self.cookieDomains(for: platform)
            let toDelete = cookies.filter { cookie in
                domainPatterns.contains { pattern in
                    cookie.domain.lowercased().contains(pattern)
                }
            }
            for cookie in toDelete {
                store.delete(cookie)
            }
            DispatchQueue.main.async {
                self.loginStates[platform] = .loggedOut
            }
        }
    }

    private func cookieDomains(for platform: MusicPlatform) -> [String] {
        switch platform {
        case .netease:
            return ["163.com", "126.net", "music.163"]
        case .qq:
            return ["qq.com", "gtimg", "tencent"]
        case .kugou:
            return ["kugou.com", "kugou.net"]
        }
    }
}
