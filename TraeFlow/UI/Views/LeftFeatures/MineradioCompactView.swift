import SwiftUI

/// Spec: mineradio-bridge-compat-layer — Mineradio 功能紧凑态视图。
///
/// 原生 SwiftUI 渲染 `antenna.radiowaves.left.and.right` 图标 + `Mineradio` 文字（深色圆角胶囊），
/// 对齐 Flow 岛紧凑态风格。根据 `coordinator.loginStates[.netease]` 显示登录指示：
/// - 未登录 / `.unknown`：仅图标 + 文字
/// - 已登录：追加小绿点
/// 不加载 WebView、不发起网络请求 —— 完整内容在展开态通过 CustomAreaWebView 加载。
struct MineradioCompactView: View {
    @ObservedObject private var coordinator = MineradioBridgeCoordinator.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Text("Mineradio")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if coordinator.loginStates[.netease]?.isLoggedIn == true {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .accessibilityLabel("Mineradio 矿石电台")
    }
}
