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
    /// 歌词为空的 songId 集合（避免重复请求空歌词）
    private var emptyLyricSongIds: Set<String> = []

    /// Spec: 订阅 NowPlayingProvider 流式更新 —— mineradio.art 的 `<audio>` 由系统 MediaRemote
    /// 统一 hook（无需依赖 WKWebView 注入脚本），用其 elapsed/duration/isPlaying 驱动歌词 progression。
    /// songId 仍由 WKWebView 脚本异步提供（必须展开过 Mineradio 至少一次）。
    private var nowPlayingCancellable: AnyCancellable?
    /// 标记当前 NowPlaying 是否来自 Mineradio（title 含 "Mineradio" 或 source 是本 app）
    private var isMineradioPlaying = false

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
    /// 一旦确认是 Mineradio 播放，用其 elapsed/duration/isPlaying 更新 `playback` 并驱动歌词 progression。
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

        // 用 MediaRemote 的 elapsed/duration/isPlaying 更新 playback（保留 songId/title/artist）
        var state = playback ?? MineradioPlaybackState(
            elapsed: 0, duration: 0, isPlaying: false,
            songId: nil, provider: "netease", title: nil, artist: nil)
        state.elapsed = info.elapsed
        state.duration = info.duration
        state.isPlaying = info.isPlaying
        // 若 WKWebView 脚本未提供 songId，且 title 不是页面标题，则用 MediaRemote 的 title
        if state.songId == nil, let title = info.title, !title.isEmpty {
            // 过滤页面标题 "Mineradio — 在线音乐可视化播放器" 和 "本地歌曲"
            if !isNonSongTitleText(title) {
                // Spec: 检测 MediaRemote title 变化（切歌），清除旧封面触发重新加载
                if state.title != title {
                    NSLog("[MineradioPlayback] MediaRemote title changed: %@ → %@", state.title ?? "nil", title)
                    state.title = title
                    if coverImage != nil {
                        setCoverImage(nil)
                        state.coverURL = nil
                        lastQueriedTitle = title
                    }
                }
            }
        }
        if state.artist == nil, let artist = info.artist, !artist.isEmpty {
            state.artist = artist
        }
        playback = state

        updateCurrentLyric()

        // Spec: 主动向 WKWebView 注入脚本查询封面和歌曲信息。
        // MediaRemote 不提供 songId/coverURL，必须从 DOM 提取。每秒查询一次（节流），
        // 直到拿到 coverURL 或 songId 为止。WKWebView 不存在时跳过（未展开过 Mineradio）。
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
            let title = dict["title"]
            let artist = dict["artist"]
            let songId = dict["songId"]
            let provider = dict["provider"]
            let debug = dict["debug"] ?? ""

            NSLog("[MineradioPlayback] queryMeta: coverType=%@ coverURL=%@ title=%@ artist=%@ songId=%@ provider=%@ debug=%@",
                  coverType,
                  coverURL != nil ? String(coverURL!.prefix(60)) : "nil",
                  title ?? "nil", artist ?? "nil", songId ?? "nil", provider ?? "nil",
                  String(debug.prefix(300)))

            var state = self.playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: provider ?? "netease", title: nil, artist: nil, coverURL: nil)

            // Spec: 检测歌曲切换 —— title 或 songId 变化时强制清除旧封面，重新加载
            let titleChanged = title != nil && title != self.lastQueriedTitle
            let songIdChanged = songId != nil && songId != self.lastQueriedSongId
            if titleChanged || songIdChanged {
                NSLog("[MineradioPlayback] song changed: title %@ → %@ / songId %@ → %@",
                      self.lastQueriedTitle ?? "nil", title ?? "nil",
                      self.lastQueriedSongId ?? "nil", songId ?? "nil")
                if let title = title { self.lastQueriedTitle = title }
                if let songId = songId { self.lastQueriedSongId = songId }
                self.setCoverImage(nil)
                state.coverURL = nil
            } else if title != nil && self.lastQueriedTitle == nil {
                self.lastQueriedTitle = title
            }

            var didUpdate = false

            // 更新 songId（playQueue 提供的比 MINERADIO_API 拦截更可靠）
            if let songId = songId, !songId.isEmpty, state.songId != songId {
                state.songId = songId
                didUpdate = true
                // 若新 songId 有歌词未获取，触发歌词获取
                if songId != lastFetchedLyricSongId {
                    fetchLyric(for: songId)
                }
            }
            if let provider = provider, !provider.isEmpty {
                state.provider = provider
            }

            // Spec: 若 coverImage 为 nil（未加载或歌曲切换后清除），根据 coverType 发起加载
            if self.coverImage == nil && coverType != "none" && coverType != "blob" {
                NSLog("[MineradioPlayback] coverImage nil, fetching: type=%@", coverType)
                if coverType == "data" {
                    self.fetchCoverDataFromWebView(webView)
                } else if coverType == "http" {
                    // http 直链 → 用 URLSession + 伪造 Referer 加载（处理防盗链）
                    if let url = coverURL {
                        if let normalized = self.normalizeCoverURL(url, provider: state.provider) {
                            self.loadCoverImage(from: normalized, provider: state.provider)
                        }
                    }
                }
            }

            if let title = title, !title.isEmpty, !self.isNonSongTitleText(title) {
                if state.title != title {
                    state.title = title
                    didUpdate = true
                }
            }
            if let artist = artist, !artist.isEmpty, state.artist == nil {
                state.artist = artist
                didUpdate = true
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
    /// - `{ type: 'playback', elapsed, duration, isPlaying, songId, provider }` —— 音频事件驱动
    /// - `{ type: 'song', songId, provider, title, artist }` —— 歌曲切换
    ///
    /// 收到 playback 时更新 `playback`，并根据 `elapsed` 更新 `currentLyric`。
    /// 收到 song 时更新 `playback.title/artist/songId`，若 songId 变化则触发歌词获取。
    func handlePlaybackMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            NSLog("[MineradioPlayback] invalid message: \(message.body)")
            return
        }

        if type == "playback" {
            let elapsed = (body["elapsed"] as? Double)
                ?? (body["elapsed"] as? NSNumber)?.doubleValue ?? 0
            let duration = (body["duration"] as? Double)
                ?? (body["duration"] as? NSNumber)?.doubleValue ?? 0
            let isPlaying = (body["isPlaying"] as? Bool) ?? false
            let songId = body["songId"] as? String
            let provider = body["provider"] as? String

            var state = playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: nil, title: nil, artist: nil)
            state.elapsed = elapsed
            state.duration = duration
            state.isPlaying = isPlaying
            if let songId = songId, !songId.isEmpty { state.songId = songId }
            if let provider = provider { state.provider = provider }
            playback = state

            updateCurrentLyric()

            // 检测歌曲切换 → 获取歌词
            if let sid = state.songId, !sid.isEmpty, sid != lastFetchedLyricSongId {
                fetchLyric(for: sid)
            }
        } else if type == "song" {
            let songId = body["songId"] as? String
            let title = body["title"] as? String
            let artist = body["artist"] as? String
            let provider = body["provider"] as? String
            let coverURL = body["coverURL"] as? String

            NSLog("[MineradioPlayback] song msg: songId=%@ title=%@ provider=%@ cover=%@", songId ?? "nil", title ?? "nil", provider ?? "nil", coverURL ?? "nil")

            var state = playback ?? MineradioPlaybackState(
                elapsed: 0, duration: 0, isPlaying: false,
                songId: nil, provider: nil, title: nil, artist: nil, coverURL: nil)
            if let songId = songId, !songId.isEmpty { state.songId = songId }
            // Spec: 过滤"本地歌曲"等非歌曲标题文本
            if let title = title, !title.isEmpty, !isNonSongTitleText(title) {
                state.title = title
            }
            if let artist = artist, !artist.isEmpty { state.artist = artist }
            if let provider = provider { state.provider = provider }
            if let coverURL = coverURL, !coverURL.isEmpty {
                // Spec: 规范化封面 URL —— 处理 /api/cover?url=<encoded> 代理路径，过滤无效 URL
                let normalized = normalizeCoverURL(coverURL, provider: provider)
                state.coverURL = normalized
                // Spec: 若规范化后为 nil（如网站根 URL），清除旧封面
                if normalized == nil {
                    setCoverImage(nil)
                }
            }
            playback = state

            // Spec: 歌曲切换时清除旧封面，避免显示上一首歌的封面
            setCoverImage(nil)
            // Spec: 更新 lastQueriedTitle，让后续 queryCoverAndSongFromWebView 能检测到下次切歌
            if let title = title, !title.isEmpty, !isNonSongTitleText(title) {
                lastQueriedTitle = title
            }
            // Spec: 若封面是 data: URI，立即解码为 NSImage；若是 http(s) 直链，异步加载（伪造 Referer）
            if let coverURL = state.coverURL {
                loadCoverImage(from: coverURL, provider: provider)
            }

            if let sid = songId, !sid.isEmpty, sid != lastFetchedLyricSongId {
                fetchLyric(for: sid)
            }

            // Spec: song 消息触发后，延迟 500ms 再查询 DOM 获取封面
            // 等待 #thumb-cover.src 更新完成，避免拿到旧 data URL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.lastWebViewQueryTime = .distantPast
                self.queryCoverAndSongFromWebView()
            }
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
    private func fetchLyric(for songId: String) {
        // 仅 netease 平台走 /api/lyric
        if let provider = playback?.provider, provider != "netease" {
            lastFetchedLyricSongId = songId
            lyricLines = []
            currentLyric = nil
            return
        }
        guard !isFetchingLyric else { return }
        // 已知该歌曲无歌词，跳过
        if emptyLyricSongIds.contains(songId) {
            lastFetchedLyricSongId = songId
            lyricLines = []
            currentLyric = nil
            return
        }

        isFetchingLyric = true
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
                switch result {
                case .success(let data):
                    self.parseLyricResponse(data, songId: songId)
                case .failure(let error):
                    NSLog("[MineradioBridge] fetchLyric(%@) failed: %@", songId, error.localizedDescription)
                    self.lyricLines = []
                    self.currentLyric = nil
                }
            }
        }
    }

    /// 解析 `/api/lyric` 响应：`{ lyric: "<LRC>", tlyric, yrc, source }`
    private func parseLyricResponse(_ data: Any?, songId: String) {
        guard let dict = data as? [String: Any] else {
            lyricLines = []
            currentLyric = nil
            return
        }
        // 优先用 lyric（标准 LRC），若空则尝试 yrc（逐字格式近似解析）
        let lrc = (dict["lyric"] as? String) ?? ""
        let yrc = (dict["yrc"] as? String) ?? ""
        let raw = lrc.isEmpty ? yrc : lrc

        if raw.isEmpty {
            NSLog("[MineradioBridge] lyric empty for song %@", songId)
            emptyLyricSongIds.insert(songId)
            lyricLines = []
            currentLyric = nil
            return
        }

        lyricLines = MineradioLyricParser.parse(raw)
        NSLog("[MineradioBridge] lyric parsed: %d lines for song %@", lyricLines.count, songId)
        updateCurrentLyric()
    }

    /// 根据当前 `playback.elapsed` 和 `lyricLines` 更新 `currentLyric` 和 `currentLyricProgress`
    private func updateCurrentLyric() {
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
        // 用 floor(0.5s 精度) 降低更新频率，避免 MediaRemote 高频回调导致动画抖动。
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
