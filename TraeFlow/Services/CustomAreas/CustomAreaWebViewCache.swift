import AppKit
import Foundation
import WebKit

/// Spec: 远程 URL 功能 WKWebView 保活缓存。
///
/// 当 `Settings.keepWebURLAliveWhenCollapsed` 开启时，`CustomAreaWebView`（展开态）
/// 在 `makeNSView` 中将创建的 WKWebView 存入此缓存；SwiftUI 移除宿主视图时，
/// 缓存持有的强引用使 WKWebView 继续存活。下次展开时 `makeNSView` 从缓存取回
/// 同一实例并重新绑定 Coordinator。
///
/// Spec: 离屏窗口保活 —— 仅持有强引用不足以保持 WKWebView 的 JS 正常运行。
/// macOS WKWebView 在不在任何 NSWindow 中时会挂起/节流 JS 执行（timer、事件回调），
/// 导致 mineradio.art 播完一首歌后无法自动播放下一首（自动切歌逻辑依赖 JS）。
/// `dismantleNSView` 时将 WebView 移入离屏窗口，使其仍在窗口层级中，
/// web process 继续正常运行 JS。下次展开时 `makeNSView` 的 `removeFromSuperview()`
/// 会将其从离屏窗口移出。
///
/// 缓存键为 URL 的 `absoluteString`，仅 `.remoteURL` / `.mineradio` 源使用。
/// `.localArea` 源不经过缓存。
@MainActor
final class CustomAreaWebViewCache {
    static let shared = CustomAreaWebViewCache()

    /// 缓存的 WKWebView，键为 URL absoluteString
    private var cache: [String: WKWebView] = [:]

    /// Spec: 离屏宿主窗口 —— 持有收起后的保活 WebView，使其仍在窗口层级中，
    /// 避免 macOS 挂起 WKWebView 的 JS 执行。
    private var offscreenHostWindow: NSWindow?

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
        if let webView = cache.removeValue(forKey: url.absoluteString) {
            webView.removeFromSuperview()
        }
    }

    /// 清空所有缓存 WKWebView。关闭保活设置或应用退出时调用。
    func clearAll() {
        for webView in cache.values {
            webView.removeFromSuperview()
        }
        cache.removeAll()
        offscreenHostWindow?.orderOut(nil)
        offscreenHostWindow = nil
    }

    /// Spec: 将 WebView 移入离屏宿主窗口，使其仍在窗口层级中。
    /// 由 `CustomAreaWebView.dismantleNSView` 在 Flow 岛收起时调用。
    /// 若 WebView 仍在某个窗口中（尚未被 SwiftUI 移除）则不做任何操作。
    func hostInOffscreenWindow(_ webView: WKWebView) {
        guard webView.window == nil else { return }
        let window = ensureOffscreenHostWindow()
        window.contentView?.addSubview(webView)
        // 给一个非零 frame，确保 WebView 不因 zero-size 被系统判定为不可见
        webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Spec: 懒创建离屏宿主窗口。窗口无边框、透明、不可交互、定位在屏幕外，
    /// 但保持 ordered-in 状态（非 orderOut），使 WKWebView 被 macOS 视为"在可见窗口中"，
    /// web process 的 JS 正常运行。
    private func ensureOffscreenHostWindow() -> NSWindow {
        if let window = offscreenHostWindow {
            return window
        }
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // stationary: 不出现在 Mission Control / Exposé 中
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // borderless 窗口默认 canBecomeKey/canBecomeMain 为 false，不会抢焦点
        // orderFront 使窗口 ordered-in（非 orderOut），WKWebView 被视为在窗口层级中
        window.orderFront(nil)
        offscreenHostWindow = window
        return window
    }
}
