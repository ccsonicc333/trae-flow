import SwiftUI

/// Spec: 自定义 HTML 提示紧凑态视图 —— 当 `CustomAreaHintStore` 中存在该 areaID 的活跃提示时，
/// 在 Flow 岛紧凑态左半区替代 `CustomAreaWebView` 显示提示文本（带 bell.badge 图标）。
/// 提示到期或被清除后自动回退到 `CustomAreaWebView`。
struct CustomAreaHintCompactView: View {
    let hint: CustomAreaHint

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 9))
                .foregroundColor(.accentColor)
            Text(hint.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.35))
        )
    }
}
