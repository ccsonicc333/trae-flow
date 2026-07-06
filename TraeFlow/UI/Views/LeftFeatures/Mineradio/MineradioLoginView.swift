import AppKit
import Combine
import SwiftUI
import WebKit

/// Spec: mineradio-bridge-compat-layer — Mineradio 平台登录视图。
///
/// SwiftUI 包装独立 WKWebView，加载对应平台登录页（网易云 / QQ 音乐 / 酷狗），
/// 使用 `WKWebsiteDataStore.default()` 与 mineradio 功能 WebView 共享 cookie。
/// 监听 `WKHTTPCookieStore` cookie 变化，检测到登录 cookie 后调
/// `coordinator.refreshLoginState(for:)` 确认登录态，然后关闭视图。
struct MineradioLoginView: View {
    let platform: MusicPlatform
    @Binding var isPresented: Bool
    @ObservedObject private var coordinator = MineradioBridgeCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 12) {
                Image(systemName: platform.systemImageName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(platform.loginTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 登录 WebView
            MineradioLoginWebView(platform: platform)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 底部提示
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(platform.loginHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.loginStates[platform]?.isLoggedIn == true {
                    Label("已登录", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// 登录 WKWebView 包装 —— 加载平台登录页，轮询 cookie 检测登录。
/// 检测到 `platform.loginCookieKeys` 中任一 cookie 后触发 `refreshLoginState` 并通知父视图关闭。
private struct MineradioLoginWebView: NSViewRepresentable {
    let platform: MusicPlatform

    func makeCoordinator() -> Coordinator {
        Coordinator(platform: platform)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 与 mineradio 功能 WebView 共享 cookie / localStorage
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.preferences = WKPreferences()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 桌面 Chrome UA（避免平台返回移动端登录页）
        configuration.applicationNameForUserAgent = "Chrome/124.0.0.0"
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.customUserAgent = MineradioBridgeUserScript.desktopChromeUserAgent

        context.coordinator.webView = webView
        context.coordinator.startPollingCookies()

        webView.load(URLRequest(url: platform.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // no-op —— 登录页加载一次即可，platform 不变
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let platform: MusicPlatform
        private var pollTimer: Timer?

        init(platform: MusicPlatform) {
            self.platform = platform
        }

        deinit {
            pollTimer?.invalidate()
        }

        /// 轮询 `WKHTTPCookieStore` cookie 变化，检测到登录 cookie 后刷新登录态。
        /// 每 2 秒采样一次；`WKHTTPCookieStore` 无公开的变更通知 API，轮询是最可靠的方式。
        func startPollingCookies() {
            pollTimer?.invalidate()
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.checkLoginCookies()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            // 立即检查一次
            checkLoginCookies()
        }

        /// 检查当前 cookie store 中是否已写入平台登录 cookie。
        /// 检测到任一关键 cookie 即视为登录成功 → 调 `refreshLoginState` 确认。
        private func checkLoginCookies() {
            let store = WKWebsiteDataStore.default().httpCookieStore
            let targetKeys = Set(platform.loginCookieKeys)
            store.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let matched = cookies.contains { targetKeys.contains($0.name) }
                    guard matched else { return }
                    // 检测到登录 cookie —— 刷新登录态（Coordinator 会更新 loginStates）
                    MineradioBridgeCoordinator.shared.refreshLoginState(for: self.platform)
                    NSLog("[MineradioLogin] 检测到 %@ 登录 cookie，已触发 refreshLoginState", self.platform.rawValue)
                    // 停止轮询
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // 登录流程允许所有 http/https 导航（含跨 host 跳转，OAuth 回调）
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        /// 允许 `target="_blank"` 链接在当前 WebView 内打开（部分登录页使用）
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // 让新窗口请求在当前 webView 内加载
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

// MARK: - MusicPlatform UI Helpers

extension MusicPlatform {
    /// 紧凑态 / 设置 UI 使用的 SF Symbol 图标
    var systemImageName: String {
        switch self {
        case .netease: return "music.note"
        case .qq: return "music.note.tv"
        case .kugou: return "music.mic"
        }
    }

    /// 登录视图标题
    var loginTitle: String {
        "登录\(displayName)"
    }

    /// 登录视图底部提示文案
    var loginHint: String {
        switch self {
        case .netease:
            return "扫码或账密登录后 cookie 将自动共享给 Mineradio"
        case .qq:
            return "扫码登录后 cookie 将自动共享给 Mineradio"
        case .kugou:
            return "登录后 cookie 将自动共享给 Mineradio"
        }
    }
}
