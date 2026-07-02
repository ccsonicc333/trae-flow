import SwiftUI

/// Spec: add-newsnow-built-in-feature —— Task 3.1
/// 内置 NewsNow 功能的紧凑态视图。
/// 原生 SwiftUI 渲染 `newspaper` 图标 + `NewsNow` 文字（深色圆角胶囊，对齐 Flow 岛紧凑态风格）。
/// 不加载 WebView、不发起网络请求 —— 完整新闻内容在展开态通过 CustomAreaWebView 加载。
struct NewsNowCompactView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "newspaper")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Text("NewsNow")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .accessibilityLabel("NewsNow 热点新闻")
    }
}
