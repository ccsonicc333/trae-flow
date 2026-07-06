import Foundation
import WebKit

/// Spec: 远程 URL 功能 WKWebView 保活缓存。
///
/// 当 `Settings.keepWebURLAliveWhenCollapsed` 开启时，`CustomAreaWebView`（展开态）
/// 在 `makeNSView` 中将创建的 WKWebView 存入此缓存；SwiftUI 移除宿主视图时，
/// 缓存持有的强引用使 WKWebView 继续存活（音频/JS/网络不中断）。下次展开时
/// `makeNSView` 从缓存取回同一实例并重新绑定 Coordinator。
///
/// 缓存键为 URL 的 `absoluteString`，仅 `.remoteURL` 源使用（`.webURL` / `.newsnow`）。
/// `.localArea` / `.mineradio` 源不经过缓存。
@MainActor
final class CustomAreaWebViewCache {
    static let shared = CustomAreaWebViewCache()

    /// 缓存的 WKWebView，键为 URL absoluteString
    private var cache: [String: WKWebView] = [:]

    private init() {}

    /// 返回指定 URL 的缓存 WKWebView（若存在）。
    func webView(for url: URL) -> WKWebView? {
        cache[url.absoluteString]
    }

    /// 将 WKWebView 存入缓存。若已有同键实例则被替换（旧实例释放）。
    func storeWebView(_ webView: WKWebView, for url: URL) {
        cache[url.absoluteString] = webView
    }

    /// 驱逐并释放指定 URL 的缓存 WKWebView。
    func evict(for url: URL) {
        cache.removeValue(forKey: url.absoluteString)
    }

    /// 清空所有缓存 WKWebView。关闭保活设置或应用退出时调用。
    func clearAll() {
        cache.removeAll()
    }
}
