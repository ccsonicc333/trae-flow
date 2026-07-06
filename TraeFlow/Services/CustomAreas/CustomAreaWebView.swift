import AppKit
import Combine
import SwiftUI
import WebKit

/// Spec: 实现 WKWebView 包装组件，支持加载本地文件目录并正确处理相对路径资源
/// Spec: 实现安全策略：限制 WebView 网络/JS 能力，防止加载外部资源带来的风险
/// Spec: 支持 JS Bridge —— HTML 通过 `window.webkit.messageHandlers.traeFlowHint.postMessage(...)`
/// 向紧凑态 Flow 岛推送提示文本，由 `CustomAreaHintStore` 接收并自动超时清除。
/// Spec: 支持双内容源（本地自定义区域目录 / 远程 URL），按源选择 `loadFileURL` 或 `load(URLRequest)`。
struct CustomAreaWebView: NSViewRepresentable {
    /// JS Bridge 消息处理器名称 —— HTML 端通过 `window.webkit.messageHandlers.traeFlowHint` 调用
    static let hintMessageHandlerName = "traeFlowHint"
    /// JS Bridge 系统指标消息处理器 —— HTML 端通过 `window.webkit.messageHandlers.traeFlowMetrics` 请求指标
    static let metricsMessageHandlerName = "traeFlowMetrics"

    /// WebView 内容源
    enum ContentSource: Equatable {
        /// 本地自定义区域目录
        case localArea(CustomArea)
        /// 远程 URL
        case remoteURL(URL)
        /// Mineradio 网页（注入 Bridge 兼容层 + JSC 引擎）
        /// Spec: mineradio-bridge-compat-layer
        case mineradio(URL)

        /// 关联的区域（仅 .localArea 有值）
        var area: CustomArea? {
            if case .localArea(let area) = self { return area }
            return nil
        }

        /// 是否允许外部网络访问
        /// - `.localArea` 跟随 `CustomArea.allowsNetworkAccess`
        /// - `.remoteURL` / `.mineradio` 恒为 true（远程站点本身即需网络）
        var allowsNetworkAccess: Bool {
            switch self {
            case .localArea(let area): return area.allowsNetworkAccess
            case .remoteURL: return true
            case .mineradio: return true
            }
        }

        /// 用于 JS Bridge 的 areaID（远程 URL / mineradio 无 areaID，hint 不生效）
        var areaID: String? {
            if case .localArea(let area) = self { return area.id }
            return nil
        }

        /// 是否为 Mineradio 源（需注入 Bridge user script + 注册 message handler）
        var isMineradio: Bool {
            if case .mineradio = self { return true }
            return false
        }
    }

    let source: ContentSource
    /// Spec: 远程 URL 功能收起后保活开关 —— 仅展开态传 true 时启用缓存复用。
    /// 开启后 SwiftUI 移除宿主视图时 WKWebView 由 `CustomAreaWebViewCache` 持有强引用继续存活；
    /// 下次 `makeNSView` 从缓存取回同一实例并重新绑定 Coordinator（message handler / delegate）。
    let keepsAlive: Bool

    init(source: ContentSource, keepsAlive: Bool = false) {
        self.source = source
        self.keepsAlive = keepsAlive
    }

    /// Spec: 缓存复用 —— `.remoteURL` / `.mineradio` 源 + `keepsAlive == true` 时查缓存。
    /// 命中缓存时复用 WKWebView（重新绑定 Coordinator），否则新建并存入缓存。
    /// `.localArea` 源不经过缓存（本地文件资源开销低，无需保活）。
    private func cachedURL() -> URL? {
        guard keepsAlive else { return nil }
        switch source {
        case .remoteURL(let url): return url
        case .mineradio(let url): return url
        case .localArea: return nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        // Spec: 保活缓存命中 —— 复用已存在的 WKWebView，重新绑定 Coordinator 后返回
        if let cachedURL = cachedURL(),
           let cached = CustomAreaWebViewCache.shared.webView(for: cachedURL) {
            rebindCoordinator(to: cached, context: context)
            cached.removeFromSuperview()
            loadAreaIfNeeded(into: cached, context: context)
            return cached
        }

        let configuration = WKWebViewConfiguration()
        configuration.preferences = WKPreferences()

        // Spec: 限制 WebView 网络/JS 能力
        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 13.0, *) {
            preferences.isElementFullscreenEnabled = false
        }

        // Spec: mineradio-bridge-compat-layer —— Mineradio 源特殊配置
        if source.isMineradio {
            // 使用 default dataStore 共享 cookie（登录 WebView 与 mineradio WebView 共用）
            configuration.websiteDataStore = WKWebsiteDataStore.default()
            // 桌面 Chrome UA（避免 mineradio.art 检测为移动端）
            configuration.applicationNameForUserAgent = "Chrome/124.0.0.0"
            // 允许自动播放媒体（mineradio 是音乐播放器）
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }

        // Spec: 仅在不允许外部网络时注册本地 scheme handler（限制外部资源）
        if !source.allowsNetworkAccess {
            configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: "trae-flow-local")
        }

        // Spec: 注册 JS Bridge —— 自定义 HTML 提示消息通道
        configuration.userContentController.add(context.coordinator, name: Self.hintMessageHandlerName)
        // Spec: 注册 JS Bridge —— 系统指标查询通道（HTML 可通过此通道获取真实 CPU/内存/负载数据）
        configuration.userContentController.add(context.coordinator, name: Self.metricsMessageHandlerName)

        // Spec: mineradio-bridge-compat-layer —— 注入 Bridge user script + 注册 message handler
        if source.isMineradio {
            let bridgeScript = MineradioBridgeUserScript.makeUserScript()
            configuration.userContentController.addUserScript(bridgeScript)
            configuration.userContentController.add(context.coordinator, name: MineradioBridgeUserScript.apiMessageHandlerName)
            configuration.userContentController.add(context.coordinator, name: MineradioBridgeUserScript.binaryMessageHandlerName)
            // Spec: mineradio-bridge-compat-layer —— 播放状态 handler（歌词显示用）
            configuration.userContentController.add(context.coordinator, name: MineradioBridgeUserScript.playbackMessageHandlerName)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground") // 透明背景
        webView.underPageBackgroundColor = .clear

        // Spec: mineradio 桌面 Chrome UA
        if source.isMineradio {
            webView.customUserAgent = MineradioBridgeUserScript.desktopChromeUserAgent
        }

        // Spec: 禁用内置缩放、强制可访问性
        if #available(macOS 13.0, *) {
            webView.pageZoom = 1.0
        }

        context.coordinator.webView = webView
        // 同步当前 areaID 与网络访问策略（区域/源切换时 JS Bridge 与导航策略需引用最新值）
        context.coordinator.currentAreaID = source.areaID
        context.coordinator.allowsNetworkAccess = source.allowsNetworkAccess
        // 同步源类型 —— decidePolicyFor 据此区分跳转策略：
        // - `.remoteURL`：同 host 在 WebView 内导航，不同 host 转系统浏览器
        // - `.mineradio`：所有 http/https 主框架导航在 WebView 内（允许跨 host）
        // - `.localArea`：所有 http/https 主框架导航转系统浏览器
        if case .remoteURL = source {
            context.coordinator.isRemoteSource = true
            context.coordinator.isMineradioSource = false
        } else if source.isMineradio {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = true
        } else {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = false
        }

        // Spec: mineradio-bridge-compat-layer —— 绑定 Coordinator
        if source.isMineradio {
            MineradioBridgeCoordinator.shared.attach(to: webView)
        }

        // Spec: 保活缓存存入 —— `.remoteURL` / `.mineradio` 源 + `keepsAlive == true` 时存
        if let cachedURL = cachedURL() {
            CustomAreaWebViewCache.shared.storeWebView(webView, for: cachedURL)
        }

        loadArea(into: webView, context: context)
        return webView
    }

    /// Spec: 保活复用时重新绑定 Coordinator —— 旧 message handler 指向已释放的旧 Coordinator，
    /// 需先移除再添加新的；navigationDelegate / uiDelegate 也更新为新 Coordinator。
    /// Mineradio 源额外重新绑定 Bridge message handler 并重新 attach `MineradioBridgeCoordinator`。
    private func rebindCoordinator(to webView: WKWebView, context: Context) {
        let controller = webView.configuration.userContentController
        // 移除旧 handler（释放旧 Coordinator）
        controller.removeScriptMessageHandler(forName: Self.hintMessageHandlerName)
        controller.removeScriptMessageHandler(forName: Self.metricsMessageHandlerName)
        if source.isMineradio {
            controller.removeScriptMessageHandler(forName: MineradioBridgeUserScript.apiMessageHandlerName)
            controller.removeScriptMessageHandler(forName: MineradioBridgeUserScript.binaryMessageHandlerName)
            controller.removeScriptMessageHandler(forName: MineradioBridgeUserScript.playbackMessageHandlerName)
        }
        // 添加新 handler
        controller.add(context.coordinator, name: Self.hintMessageHandlerName)
        controller.add(context.coordinator, name: Self.metricsMessageHandlerName)
        if source.isMineradio {
            controller.add(context.coordinator, name: MineradioBridgeUserScript.apiMessageHandlerName)
            controller.add(context.coordinator, name: MineradioBridgeUserScript.binaryMessageHandlerName)
            controller.add(context.coordinator, name: MineradioBridgeUserScript.playbackMessageHandlerName)
        }
        // 更新 delegate
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 同步 Coordinator 状态
        context.coordinator.webView = webView
        context.coordinator.currentAreaID = source.areaID
        context.coordinator.allowsNetworkAccess = source.allowsNetworkAccess
        if case .remoteURL = source {
            context.coordinator.isRemoteSource = true
            context.coordinator.isMineradioSource = false
        } else if source.isMineradio {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = true
            // Spec: mineradio-bridge-compat-layer —— 重新 attach Coordinator
            //（attach 只更新 webView 引用 + 刷新登录态，不重置页面状态）
            MineradioBridgeCoordinator.shared.attach(to: webView)
        } else {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = false
        }
    }

    /// Spec: 保活复用时仅在 URL 变化或未加载时重新 load，避免重置页面状态（音频/滚动/会话）。
    /// 新 Coordinator 无 `lastRemoteURLString` 状态，直接比对 WebView 当前 URL。
    private func loadAreaIfNeeded(into webView: WKWebView, context: Context) {
        switch source {
        case .localArea:
            // 本地源不经过保活缓存（cachedRemoteURL 只返回 .remoteURL），此分支不会命中
            loadArea(into: webView, context: context)
        case .remoteURL(let url):
            if webView.url?.absoluteString != url.absoluteString {
                loadArea(into: webView, context: context)
            } else {
                // URL 一致：同步 Coordinator 状态，避免 updateNSView 误判需要 reload
                context.coordinator.lastRemoteURLString = url.absoluteString
                context.coordinator.lastAreaID = nil
                context.coordinator.lastEntryPointURL = nil
            }
        case .mineradio(let url):
            if webView.url?.absoluteString != url.absoluteString {
                loadArea(into: webView, context: context)
            } else {
                context.coordinator.lastRemoteURLString = url.absoluteString
                context.coordinator.lastAreaID = nil
                context.coordinator.lastEntryPointURL = nil
            }
        }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        // 同步当前 areaID 与网络访问策略（区域/源切换时 JS Bridge 与导航策略需引用最新值）
        context.coordinator.currentAreaID = source.areaID
        context.coordinator.allowsNetworkAccess = source.allowsNetworkAccess
        // 同步源类型 —— decidePolicyFor 据此区分跳转策略
        if case .remoteURL = source {
            context.coordinator.isRemoteSource = true
            context.coordinator.isMineradioSource = false
        } else if source.isMineradio {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = true
        } else {
            context.coordinator.isRemoteSource = false
            context.coordinator.isMineradioSource = false
        }

        // 仅当源标识或入口 URL 变化时重新加载
        switch source {
        case .localArea(let area):
            let needsReload = context.coordinator.lastAreaID != area.id
                || context.coordinator.lastRemoteURLString != nil
                || context.coordinator.lastEntryPointURL?.path != area.entryPointURL.path
            if needsReload {
                loadArea(into: webView, context: context)
            }
        case .remoteURL(let url):
            let urlString = url.absoluteString
            let needsReload = context.coordinator.lastRemoteURLString != urlString
                || context.coordinator.lastAreaID != nil
            if needsReload {
                loadArea(into: webView, context: context)
            }
        case .mineradio(let url):
            let urlString = url.absoluteString
            let needsReload = context.coordinator.lastRemoteURLString != urlString
                || context.coordinator.lastAreaID != nil
            if needsReload {
                loadArea(into: webView, context: context)
            }
        }
    }

    /// Spec: 按内容源选择加载方式
    /// - `.localArea` → `loadFileURL(_:allowingReadAccessTo:)` 加载目录入口 HTML
    /// - `.remoteURL` / `.mineradio` → `load(URLRequest(url:))` 加载远程站点
    private func loadArea(into webView: WKWebView, context: Context) {
        switch source {
        case .localArea(let area):
            let url = area.loadableFileURL
            webView.loadFileURL(url, allowingReadAccessTo: area.directoryURL)
            context.coordinator.lastAreaID = area.id
            context.coordinator.lastEntryPointURL = area.entryPointURL
            context.coordinator.lastRemoteURLString = nil
        case .remoteURL(let url):
            webView.load(URLRequest(url: url))
            context.coordinator.lastAreaID = nil
            context.coordinator.lastEntryPointURL = nil
            context.coordinator.lastRemoteURLString = url.absoluteString
        case .mineradio(let url):
            webView.load(URLRequest(url: url))
            context.coordinator.lastAreaID = nil
            context.coordinator.lastEntryPointURL = nil
            context.coordinator.lastRemoteURLString = url.absoluteString
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        /// 上次加载的本地区域 ID（UUID）
        var lastAreaID: String?
        /// 上次加载的本地入口 URL（用于检测入口文件变化）
        var lastEntryPointURL: URL?
        /// 上次加载的远程 URL（absoluteString，用于检测远程源变化）
        var lastRemoteURLString: String?
        /// 当前关联的自定义区域 ID —— JS Bridge 回调时用于定位 `CustomAreaHintStore`；
        /// 远程 URL 源为 nil，hint 丢弃
        var currentAreaID: String?
        /// 当前内容源是否允许外部网络访问 —— `decidePolicyFor` 据此放行/拦截 http/https。
        /// 在 makeNSView / updateNSView 中由 source.allowsNetworkAccess 同步。
        var allowsNetworkAccess: Bool = false
        /// 当前内容源是否为远程 URL —— `decidePolicyFor` 据此区分同 host 跳转策略：
        /// `.remoteURL` 源同 host 链接在 WebView 内导航、不同 host 转系统浏览器；
        /// `.localArea` 源所有 http/https 主框架导航一律转系统浏览器。在 makeNSView / updateNSView 中同步。
        var isRemoteSource: Bool = false
        /// 当前内容源是否为 Mineradio —— `decidePolicyFor` 据此放行跨 host 主框架导航
        ///（mineradio.art 可能跳转 OAuth 回调或其他 host）。
        /// Spec: mineradio-bridge-compat-layer
        var isMineradioSource: Bool = false

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // 源标识在 loadArea 中同步，无需在此推导
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Spec: 阻止外部链接跳转（由 decidePolicyFor 处理）
        }

        /// Spec: 根据内容源决定导航策略 ——
        /// - 主框架 http/https 导航到不同 host 的外部链接转交系统默认浏览器打开（避免在 WebView 内跳走）；
        /// - `.remoteURL` 源同 host 的主框架导航在 WebView 内继续；
        /// - `.localArea` 源所有 http/https 主框架导航一律转系统浏览器（本地 HTML 不会与外部站点同源）；
        /// - `.mineradio` 源所有 http/https 主框架导航在 WebView 内（允许跨 host，OAuth 回调可能跳转其他 host）；
        /// - 子框架/资源请求（图片/JS/css/fetch 等）按 `allowsNetworkAccess` 决定；
        /// - `file` / `trae-flow-local` 始终放行；其他 scheme 一律取消。
        /// Spec: mineradio-bridge-compat-layer
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            let currentURL = webView.url
            // 主框架导航：targetFrame == nil（target="_blank"）或链接点击
            let isMainFrameNavigation = navigationAction.targetFrame == nil
                || navigationAction.navigationType == .linkActivated

            // file / trae-flow-local scheme → 始终放行（本地资源）
            if scheme == "file" || scheme == "trae-flow-local" {
                decisionHandler(.allow)
                return
            }

            // http / https 处理
            if scheme == "http" || scheme == "https" {
                if isMainFrameNavigation {
                    if isMineradioSource {
                        // mineradio 源：跨 host 主框架导航一律放行（OAuth 回调 / 第三方登录可能跳转其他 host）
                        decisionHandler(.allow)
                    } else if isRemoteSource {
                        // 远程 URL 源：同 host 在 WebView 内导航，不同 host 转系统浏览器
                        if isSameHost(currentURL, url) {
                            decisionHandler(.allow)
                        } else {
                            NSWorkspace.shared.open(url)
                            decisionHandler(.cancel)
                        }
                    } else {
                        // 本地区域源：本地 HTML 不会与 http/https 同源，主框架导航一律转系统浏览器
                        NSWorkspace.shared.open(url)
                        decisionHandler(.cancel)
                    }
                } else {
                    // 子框架/资源请求（图片/JS/css/fetch 等，非链接点击）按 allowsNetworkAccess 决定
                    if allowsNetworkAccess {
                        decisionHandler(.allow)
                    } else {
                        decisionHandler(.cancel)
                    }
                }
                return
            }

            // 其他 scheme（tel/mailto 等）→ 取消
            decisionHandler(.cancel)
        }

        /// Spec: 判断两个 URL 是否同 host —— 用于 `decidePolicyFor` 区分远程源同站跳转与外部链接。
        /// 任一为 nil 或无 host 时返回 false（保守视为不同 host）。
        private func isSameHost(_ url1: URL?, _ url2: URL?) -> Bool {
            guard let h1 = url1?.host, let h2 = url2?.host else { return false }
            return h1 == h2
        }

        /// Spec: 阻止新窗口打开
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        /// Spec: 响应网页 `<input type="file">` 点击 —— 默认 WKUIDelegate 不实现此方法时
        /// 文件选择器不会弹出（点击无反应）。Mineradio 背景媒体上传等场景需要此回调。
        /// 根据 `accept` MIME 类型构造 NSOpenPanel 允许的文件类型，用户选择后通过
        /// `completionHandler` 回传 URL 数组；取消则回传空数组（必须调用 completionHandler，
        /// 否则网页端 Promise 永久挂起）。
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection

            // Spec: 根据 WKOpenPanelParameters.allowedFileTypes 过滤（macOS 13+ 不再提供该属性，
            // 由网页 accept 属性解析已不可得，这里直接允许所有文件类型，交给用户自行选择）
            panel.allowsOtherFileTypes = true

            panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? webView.window ?? NSWindow()) { response in
                if response == .OK {
                    completionHandler(panel.urls)
                } else {
                    // 必须回传空数组而非 nil，避免网页端 Promise 挂起
                    completionHandler([])
                }
            }
        }

        // MARK: - JS Bridge: traeFlowHint

        /// Spec: 接收自定义 HTML 通过 `window.webkit.messageHandlers.traeFlowHint.postMessage(...)` 推送的提示。
        /// 消息体格式（JSON）：
        /// ```
        /// { "text": "提醒内容", "duration": 3000 }  // duration 可选，毫秒，默认 5000
        /// { "action": "clear" }                     // 清除当前区域所有提示
        /// ```
        /// 也可直接传字符串：`postMessage("提醒内容")`。
        /// 注意：远程 URL 源无 areaID，消息将被丢弃。
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // Spec: mineradio-bridge-compat-layer —— Bridge API / 二进制消息路由到 MineradioBridgeCoordinator
            if message.name == MineradioBridgeUserScript.apiMessageHandlerName {
                MineradioBridgeCoordinator.shared.handleApiMessage(message)
                return
            }
            if message.name == MineradioBridgeUserScript.binaryMessageHandlerName {
                MineradioBridgeCoordinator.shared.handleBinaryMessage(message)
                return
            }
            // Spec: mineradio-bridge-compat-layer —— 播放状态路由（歌词显示用）
            if message.name == MineradioBridgeUserScript.playbackMessageHandlerName {
                MineradioBridgeCoordinator.shared.handlePlaybackMessage(message)
                return
            }

            // 系统指标查询
            if message.name == CustomAreaWebView.metricsMessageHandlerName {
                handleMetricsRequest()
                return
            }

            guard message.name == CustomAreaWebView.hintMessageHandlerName else {
                return
            }
            guard let areaID = currentAreaID else {
                NSLog("[traeFlowHint] 收到消息但 currentAreaID 为 nil（可能是远程 URL 源），丢弃：\(message.body)")
                return
            }

            NSLog("[traeFlowHint] 收到消息 areaID=\(areaID) body=\(message.body)")

            if let str = message.body as? String {
                guard !str.isEmpty else { return }
                CustomAreaHintStore.shared.postHint(areaID: areaID, text: str, durationMs: CustomAreaHintStore.defaultDurationMs)
                return
            }

            guard let dict = message.body as? [String: Any] else { return }

            // 清除动作
            if let action = dict["action"] as? String, action == "clear" {
                CustomAreaHintStore.shared.clearHint(for: areaID)
                return
            }

            guard let text = dict["text"] as? String, !text.isEmpty else { return }
            var durationMs = CustomAreaHintStore.defaultDurationMs
            if let d = dict["duration"] as? Int {
                durationMs = d
            } else if let d = dict["duration"] as? Double {
                durationMs = Int(d)
            } else if let d = dict["durationMs"] as? Int {
                durationMs = d
            }
            NSLog("[traeFlowHint] 发布提示 areaID=\(areaID) text=\(text) durationMs=\(durationMs)")
            CustomAreaHintStore.shared.postHint(areaID: areaID, text: text, durationMs: durationMs)
        }

        // MARK: - JS Bridge: traeFlowMetrics

        /// 响应自定义 HTML 通过 `window.webkit.messageHandlers.traeFlowMetrics.postMessage(...)` 发起的系统指标查询。
        /// 采样真实的 CPU / 内存 / 负载数据，通过 `evaluateJavaScript` 回调 `window.receiveMetrics(json)`。
        private func handleMetricsRequest() {
            guard let webView = webView else { return }
            let json = SystemMetricsProvider.shared.sampleAsJSON()
            webView.evaluateJavaScript("if (window.receiveMetrics) { window.receiveMetrics(\(json)); }")
        }
    }
}

/// Spec: 安全策略 —— 禁止外部网络请求
/// 简单占位 scheme handler；本地资源由 loadFileURL(allowingReadAccessTo:) 处理
private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // no-op
    }
}
