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

    // MARK: - Private State

    private weak var webView: WKWebView?
    private let engine = MineradioBridgeEngine.shared
    private let binarySession: URLSession
    private var isRefreshingLoginStates = false

    // MARK: - Init

    private nonisolated init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        binarySession = URLSession(configuration: config)
    }

    // MARK: - WebView Attachment

    /// 绑定 WKWebView，注册 `mineradioApi` / `mineradioBinary` message handler。
    /// 由 `CustomAreaWebView.makeNSView` 在 `.mineradio` 源时调用。
    func attach(to webView: WKWebView) {
        self.webView = webView
        // 初始刷新一次登录态（cookie 变化由 MineradioLoginView 主动触发 refresh）
        refreshAllLoginStates()
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
