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

        /// 关联的区域（仅 .localArea 有值）
        var area: CustomArea? {
            if case .localArea(let area) = self { return area }
            return nil
        }

        /// 是否允许外部网络访问
        /// - `.localArea` 跟随 `CustomArea.allowsNetworkAccess`
        /// - `.remoteURL` 恒为 true（远程站点本身即需网络）
        var allowsNetworkAccess: Bool {
            switch self {
            case .localArea(let area): return area.allowsNetworkAccess
            case .remoteURL: return true
            }
        }

        /// 用于 JS Bridge 的 areaID（远程 URL 无 areaID 时返回 nil，hint 不生效）
        var areaID: String? {
            if case .localArea(let area) = self { return area.id }
            return nil
        }
    }

    let source: ContentSource

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences = WKPreferences()

        // Spec: 限制 WebView 网络/JS 能力
        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(macOS 13.0, *) {
            preferences.isElementFullscreenEnabled = false
        }

        // Spec: 仅在不允许外部网络时注册本地 scheme handler（限制外部资源）
        if !source.allowsNetworkAccess {
            configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: "trae-flow-local")
        }

        // Spec: 注册 JS Bridge —— 自定义 HTML 提示消息通道
        configuration.userContentController.add(context.coordinator, name: Self.hintMessageHandlerName)
        // Spec: 注册 JS Bridge —— 系统指标查询通道（HTML 可通过此通道获取真实 CPU/内存/负载数据）
        configuration.userContentController.add(context.coordinator, name: Self.metricsMessageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground") // 透明背景
        webView.underPageBackgroundColor = .clear

        // Spec: 禁用内置缩放、强制可访问性
        if #available(macOS 13.0, *) {
            webView.pageZoom = 1.0
        }

        context.coordinator.webView = webView
        // 同步当前 areaID 与网络访问策略（区域/源切换时 JS Bridge 与导航策略需引用最新值）
        context.coordinator.currentAreaID = source.areaID
        context.coordinator.allowsNetworkAccess = source.allowsNetworkAccess
        // 同步源类型：`.remoteURL` 设 true，`.localArea` 设 false —— decidePolicyFor 据此区分同 host 跳转策略
        if case .remoteURL = source {
            context.coordinator.isRemoteSource = true
        } else {
            context.coordinator.isRemoteSource = false
        }
        loadArea(into: webView, context: context)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        // 同步当前 areaID 与网络访问策略（区域/源切换时 JS Bridge 与导航策略需引用最新值）
        context.coordinator.currentAreaID = source.areaID
        context.coordinator.allowsNetworkAccess = source.allowsNetworkAccess
        // 同步源类型：`.remoteURL` 设 true，`.localArea` 设 false —— decidePolicyFor 据此区分同 host 跳转策略
        if case .remoteURL = source {
            context.coordinator.isRemoteSource = true
        } else {
            context.coordinator.isRemoteSource = false
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
        }
    }

    /// Spec: 按内容源选择加载方式
    /// - `.localArea` → `loadFileURL(_:allowingReadAccessTo:)` 加载目录入口 HTML
    /// - `.remoteURL` → `load(URLRequest(url:))` 加载远程站点
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
        /// - 子框架/资源请求（图片/JS/css/fetch 等）按 `allowsNetworkAccess` 决定；
        /// - `file` / `trae-flow-local` 始终放行；其他 scheme 一律取消。
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
                    // 主框架导航 —— 外部链接转系统默认浏览器，避免在 WebView 内跳走
                    if isRemoteSource {
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
