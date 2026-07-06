import Foundation
import JavaScriptCore
import WebKit

/// Spec: mineradio-bridge-compat-layer — JavaScriptCore 引擎。
///
/// 在进程内的 `JSContext` 中运行 esbuild 打包的 Mineradio Bridge 扩展原始代码
///（`bridge-bundle.js` + `bridge-polyfills.js`），通过原生回调桥接 `fetch` → URLSession
/// 与 `chrome.cookies` → `WKHTTPCookieStore`。零移植，100% 路由覆盖。
///
/// **线程模型**：所有 JSC 调用在主线程执行。原生 block 从 JSC 同步调用（主线程），
/// 启动异步 URLSession / WKHTTPCookieStore 任务后立即返回；完成回调 `DispatchQueue.main.async`
/// 回到主线程再调 JSC resolve。
///
/// **注意**：此类非 `@MainActor` 标注（避免 `@convention(block)` 闭包的 actor 隔离问题），
/// 但所有方法应在主线程调用。`MineradioBridgeCoordinator`（`@MainActor`）负责调度。
final class MineradioBridgeEngine {

    // MARK: - Singleton

    static let shared = MineradioBridgeEngine()

    // MARK: - State

    private var jsContext: JSContext?
    private let urlSession: URLSession
    private var apiCallbacks: [String: (Result<Any?, Error>) -> Void] = [:]
    private let lock = NSLock()

    // MARK: - Init

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil       // 扩展代码已通过 Cookie header 显式传递 cookie
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
        setupContext()
    }

    // MARK: - Setup

    private func setupContext() {
        let context = JSContext()!
        context.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "nil"
            NSLog("[MineradioBridge] JSC exception: \(msg)")
            self?.collectExceptionTrace(exception)
        }

        // 1. 加载 polyfills（fetch / chrome.cookies / URL / 等）
        if let polyfills = loadScript(name: "bridge-polyfills") {
            context.evaluateScript(polyfills)
        } else {
            NSLog("[MineradioBridge] bridge-polyfills.js not found in bundle")
        }

        // 2. 加载扩展打包代码（router.js + api/*.js + crypto-es + node-forge）
        if let bundle = loadScript(name: "bridge-bundle") {
            context.evaluateScript(bundle)
        } else {
            NSLog("[MineradioBridge] bridge-bundle.js not found in bundle")
        }

        // 3. 注册原生回调
        registerNativeCallbacks(context)

        // 4. 注入 API 调用辅助函数（Promise → 原生回调）
        context.evaluateScript("""
        (function() {
          globalThis.__mineradioApiCallbacks = globalThis.__mineradioApiCallbacks || new Map();
          globalThis.__mineradioInvokeApi = function(requestId, payload) {
            return globalThis.__mineradioHandleApiRequest(payload)
              .then(function(result) {
                if (globalThis.__mineradioApiResolve) globalThis.__mineradioApiResolve(requestId, result);
              })
              .catch(function(err) {
                var msg = (err && err.message) || String(err) || 'unknown error';
                if (globalThis.__mineradioApiReject) globalThis.__mineradioApiReject(requestId, msg);
              });
          };
          globalThis.__mineradioInvokeBridgeStatus = function(requestId) {
            return globalThis.__mineradioGetBridgeStatus()
              .then(function(result) {
                if (globalThis.__mineradioApiResolve) globalThis.__mineradioApiResolve(requestId, result);
              })
              .catch(function(err) {
                var msg = (err && err.message) || String(err) || 'unknown error';
                if (globalThis.__mineradioApiReject) globalThis.__mineradioApiReject(requestId, msg);
              });
          };
        })();
        """)

        self.jsContext = context
        NSLog("[MineradioBridge] JSContext ready, polyfills loaded=\(context.objectForKeyedSubscript("__mineradioPolyfillsLoaded")?.toBool() ?? false)")
    }

    private func collectExceptionTrace(_ exception: JSValue?) {
        guard let exception = exception else { return }
        let stack = exception.objectForKeyedSubscript("stack")?.toString()
        if let stack = stack, !stack.isEmpty {
            NSLog("[MineradioBridge] JSC stack: %@", stack)
        }
    }

    private func loadScript(name: String) -> String? {
        // 尝试子目录（如果在 Xcode 中以 folder reference 添加）
        if let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "MineradioBridge"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        // 尝试 bundle 根目录
        if let url = Bundle.main.url(forResource: name, withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return nil
    }

    // MARK: - Native Callback Registration

    private func registerNativeCallbacks(_ context: JSContext) {
        // __mineradioNativeFetch(requestId, url, optionsJson)
        let fetchBlock: @convention(block) (String, String, String) -> Void = { [weak self] requestId, urlString, optionsJson in
            self?.handleNativeFetch(requestId: requestId, urlString: urlString, optionsJson: optionsJson)
        }
        context.setObject(fetchBlock, forKeyedSubscript: "__mineradioNativeFetch" as NSString)

        // __mineradioNativeCookiesGetAll(requestId, detailsJson)
        let cookiesGetAllBlock: @convention(block) (String, String) -> Void = { [weak self] requestId, detailsJson in
            self?.handleNativeCookiesGetAll(requestId: requestId, detailsJson: detailsJson)
        }
        context.setObject(cookiesGetAllBlock, forKeyedSubscript: "__mineradioNativeCookiesGetAll" as NSString)

        // __mineradioNativeCookiesGet(requestId, detailsJson)
        let cookiesGetBlock: @convention(block) (String, String) -> Void = { [weak self] requestId, detailsJson in
            self?.handleNativeCookiesGet(requestId: requestId, detailsJson: detailsJson)
        }
        context.setObject(cookiesGetBlock, forKeyedSubscript: "__mineradioNativeCookiesGet" as NSString)

        // __mineradioNativeCookiesSet(requestId, detailsJson)
        let cookiesSetBlock: @convention(block) (String, String) -> Void = { [weak self] requestId, detailsJson in
            self?.handleNativeCookiesSet(requestId: requestId, detailsJson: detailsJson)
        }
        context.setObject(cookiesSetBlock, forKeyedSubscript: "__mineradioNativeCookiesSet" as NSString)

        // __mineradioNativeLog(level, message)
        let logBlock: @convention(block) (String, String) -> Void = { level, message in
            NSLog("[MineradioBridge][%@] %@", level, message)
        }
        context.setObject(logBlock, forKeyedSubscript: "__mineradioNativeLog" as NSString)

        // __mineradioApiResolve(requestId, result) — JSC Promise resolve 回调
        let apiResolveBlock: @convention(block) (String, Any) -> Void = { [weak self] requestId, result in
            self?.resolveApiCallback(requestId: requestId, result: result)
        }
        context.setObject(apiResolveBlock, forKeyedSubscript: "__mineradioApiResolve" as NSString)

        // __mineradioApiReject(requestId, errorMessage) — JSC Promise reject 回调
        let apiRejectBlock: @convention(block) (String, String) -> Void = { [weak self] requestId, errorMessage in
            self?.rejectApiCallback(requestId: requestId, error: MineradioBridgeError.apiError(errorMessage))
        }
        context.setObject(apiRejectBlock, forKeyedSubscript: "__mineradioApiReject" as NSString)
    }

    // MARK: - Public API

    /// 调用扩展 `handleApiRequest(payload)`，resolve 后调 completion。
    func handleApi(_ payload: [String: Any], completion: @escaping (Result<Any?, Error>) -> Void) {
        guard let context = jsContext else {
            completion(.failure(MineradioBridgeError.contextNotReady))
            return
        }
        let requestId = "api_\(UUID().uuidString.prefix(8))"
        lock.lock()
        apiCallbacks[requestId] = completion
        lock.unlock()

        guard let invokeFn = context.objectForKeyedSubscript("__mineradioInvokeApi") else {
            self.rejectApiCallback(requestId: requestId, error: MineradioBridgeError.invokeFunctionMissing)
            return
        }

        // 将 payload 转换为 JSValue
        let payloadValue = JSValue(object: payload, in: context) ?? JSValue(object: [:], in: context)
        invokeFn.call(withArguments: [requestId, payloadValue])

        // 如果 Promise 已经同步 resolve（不太可能），回调已触发
    }

    /// 调用扩展 `getBridgeStatus()`，返回三平台登录状态。
    func handleBridgeStatus(completion: @escaping (Result<Any?, Error>) -> Void) {
        guard let context = jsContext else {
            completion(.failure(MineradioBridgeError.contextNotReady))
            return
        }
        let requestId = "status_\(UUID().uuidString.prefix(8))"
        lock.lock()
        apiCallbacks[requestId] = completion
        lock.unlock()

        guard let invokeFn = context.objectForKeyedSubscript("__mineradioInvokeBridgeStatus") else {
            self.rejectApiCallback(requestId: requestId, error: MineradioBridgeError.invokeFunctionMissing)
            return
        }
        invokeFn.call(withArguments: [requestId])
    }

    // MARK: - API Callback Resolution

    private func resolveApiCallback(requestId: String, result: Any) {
        lock.lock()
        let callback = apiCallbacks.removeValue(forKey: requestId)
        lock.unlock()
        callback?(.success(result))
    }

    private func rejectApiCallback(requestId: String, error: Error) {
        lock.lock()
        let callback = apiCallbacks.removeValue(forKey: requestId)
        lock.unlock()
        callback?(.failure(error))
    }

    // MARK: - Native fetch Polyfill

    private func handleNativeFetch(requestId: String, urlString: String, optionsJson: String) {
        guard let url = URL(string: urlString) else {
            callJSCResolveFetch(requestId: requestId, status: 0, headers: [:], bodyText: nil, bodyBase64: nil, error: "Invalid URL: \(urlString)")
            return
        }

        var method = "GET"
        var headers: [String: String] = [:]
        var body: Data? = nil

        if let optionsData = optionsJson.data(using: .utf8),
           let options = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any] {
            if let m = options["method"] as? String { method = m.uppercased() }
            if let h = options["headers"] as? [String: String] {
                headers = h
            } else if let h = options["headers"] as? [String: Any] {
                for (k, v) in h { headers[k] = String(describing: v) }
            }
            if let bodyStr = options["body"] as? String, !bodyStr.isEmpty {
                body = bodyStr.data(using: .utf8)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        // 默认 UA（如果未在 headers 中指定）
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        }

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.callJSCResolveFetch(requestId: requestId, status: 0, headers: [:], bodyText: nil, bodyBase64: nil, error: error.localizedDescription)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.callJSCResolveFetch(requestId: requestId, status: 0, headers: [:], bodyText: nil, bodyBase64: nil, error: "Non-HTTP response")
                    return
                }
                var responseHeaders: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    if let key = key as? String, let value = value as? String {
                        responseHeaders[key.lowercased()] = value
                    }
                }
                let contentType = (responseHeaders["content-type"] ?? "").lowercased()
                let isBinary = contentType.hasPrefix("image/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("video/") || contentType.hasPrefix("application/octet-stream")

                var bodyText: String? = nil
                var bodyBase64: String? = nil
                if let data = data {
                    if isBinary {
                        bodyBase64 = data.base64EncodedString()
                    } else {
                        bodyText = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                        // 如果 UTF-8 解码失败，使用 base64
                        if String(data: data, encoding: .utf8) == nil {
                            bodyText = nil
                            bodyBase64 = data.base64EncodedString()
                        }
                    }
                }
                self.callJSCResolveFetch(requestId: requestId, status: httpResponse.statusCode, headers: responseHeaders, bodyText: bodyText, bodyBase64: bodyBase64, error: nil)
            }
        }
        task.resume()
    }

    private func callJSCResolveFetch(requestId: String, status: Int, headers: [String: String], bodyText: String?, bodyBase64: String?, error: String?) {
        guard let context = jsContext else { return }
        if let error = error {
            let escaped = error.replacingOccurrences(of: "'", with: "\\'")
            context.evaluateScript("globalThis.__mineradioRejectFetch('\(requestId)', '\(escaped)');")
            return
        }
        var result: [String: Any] = ["status": status, "headers": headers]
        if let bodyText = bodyText { result["bodyText"] = bodyText }
        if let bodyBase64 = bodyBase64 { result["bodyBase64"] = bodyBase64 }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            NSLog("[MineradioBridge] fetch result serialization failed for %@", requestId)
            return
        }
        let escaped = MineradioBridgeDelivery.escapeForJSSingleQuotedString(jsonStr)
        context.evaluateScript("globalThis.__mineradioResolveFetch('\(requestId)', '\(escaped)');")
    }

    // MARK: - Native chrome.cookies Polyfill

    private func handleNativeCookiesGetAll(requestId: String, detailsJson: String) {
        var details: [String: Any] = [:]
        if let data = detailsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            details = parsed
        }
        let domain = details["domain"] as? String
        let url = details["url"] as? String

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let filtered = self.filterCookies(cookies, domain: domain, url: url)
                let cookieArray = filtered.map { self.cookieToDict($0) }
                self.callJSCResolveCookies(requestId: requestId, result: cookieArray)
            }
        }
    }

    private func handleNativeCookiesGet(requestId: String, detailsJson: String) {
        var details: [String: Any] = [:]
        if let data = detailsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            details = parsed
        }
        let url = details["url"] as? String
        let name = details["name"] as? String

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let filtered = self.filterCookies(cookies, url: url)
                let found = filtered.first { $0.name == name }
                if let found = found {
                    self.callJSCResolveCookies(requestId: requestId, result: self.cookieToDict(found))
                } else {
                    self.callJSCResolveCookies(requestId: requestId, result: NSNull())
                }
            }
        }
    }

    private func handleNativeCookiesSet(requestId: String, detailsJson: String) {
        var details: [String: Any] = [:]
        if let data = detailsJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            details = parsed
        }
        guard let url = details["url"] as? String,
              let name = details["name"] as? String,
              let value = details["value"] as? String,
              let cookieURL = URL(string: url) else {
            callJSCResolveCookies(requestId: requestId, result: NSNull())
            return
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: (details["path"] as? String) ?? "/",
            .domain: cookieURL.host ?? "",
        ]
        if (details["secure"] as? Bool) == true {
            properties[.secure] = "TRUE"
        }
        if let expires = details["expirationDate"] as? TimeInterval {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        if let httpOnly = details["httpOnly"] as? Bool, httpOnly {
            properties[.discard] = "TRUE"
        }

        let cookie = HTTPCookie(properties: properties)
        if let cookie = cookie {
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
                DispatchQueue.main.async {
                    self?.callJSCResolveCookies(requestId: requestId, result: NSNull())
                }
            }
        } else {
            callJSCResolveCookies(requestId: requestId, result: NSNull())
        }
    }

    /// Cookie 过滤：按 domain 或 url 匹配（模拟 chrome.cookies.getAll 语义）
    private func filterCookies(_ cookies: [HTTPCookie], domain: String? = nil, url: String? = nil) -> [HTTPCookie] {
        if domain == nil && url == nil {
            return cookies
        }
        return cookies.filter { cookie in
            if let domain = domain {
                return matchesDomain(cookieDomain: cookie.domain, targetDomain: domain)
            }
            if let url = url, let targetURL = URL(string: url), let host = targetURL.host {
                return matchesDomain(cookieDomain: cookie.domain, targetDomain: host)
                    && matchesPath(cookiePath: cookie.path, targetPath: targetURL.path)
                    && (!cookie.isSecure || targetURL.scheme == "https")
            }
            return true
        }
    }

    /// Chrome cookie domain 匹配规则：
    /// - cookie domain 以 `.` 开头（如 `.163.com`）→ 匹配该域及所有子域
    /// - cookie domain 不以 `.` 开头（如 `music.163.com`）→ 精确匹配或子域匹配
    private func matchesDomain(cookieDomain: String, targetDomain: String) -> Bool {
        let cd = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let td = targetDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cd == td { return true }
        // cookie domain 是 target domain 的后缀（子域匹配）
        if td.hasSuffix(".\(cd)") { return true }
        // cookie domain 以 . 开头时，target 是 cookie domain 的子域
        if cookieDomain.hasPrefix(".") && td.hasSuffix(cd) && td.count > cd.count {
            return td.hasSuffix(".\(cd)") || td == cd
        }
        return false
    }

    /// Cookie path 匹配：cookie path 是 target path 的前缀
    private func matchesPath(cookiePath: String, targetPath: String) -> Bool {
        if cookiePath == "/" || cookiePath.isEmpty { return true }
        if targetPath.hasPrefix(cookiePath) { return true }
        // 如果 cookie path 是 /a/b，target 是 /a/b/c → match
        // 如果 cookie path 是 /a/b，target 是 /a/bc → no match
        return false
    }

    private func cookieToDict(_ cookie: HTTPCookie) -> [String: Any] {
        var dict: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
        ]
        if let expires = cookie.expiresDate {
            dict["expirationDate"] = expires.timeIntervalSince1970
            dict["session"] = false
        } else {
            dict["session"] = true
        }
        return dict
    }

    private func callJSCResolveCookies(requestId: String, result: Any) {
        guard let context = jsContext else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            NSLog("[MineradioBridge] cookies result serialization failed for %@", requestId)
            return
        }
        let escaped = MineradioBridgeDelivery.escapeForJSSingleQuotedString(jsonStr)
        context.evaluateScript("globalThis.__mineradioResolveCookies('\(requestId)', '\(escaped)');")
    }
}

// MARK: - Errors

enum MineradioBridgeError: LocalizedError {
    case contextNotReady
    case invokeFunctionMissing
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .contextNotReady: return "JSContext not ready"
        case .invokeFunctionMissing: return "Bridge invoke function not found in JSContext"
        case .apiError(let msg): return "Bridge API error: \(msg)"
        }
    }
}
