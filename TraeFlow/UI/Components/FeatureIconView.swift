import SwiftUI
import AppKit

/// 功能图标统一渲染组件 —— 支持 SF Symbol / 文字 / 图片三种类型。
/// 通过 `iconID`（前缀约定 `sf:`/`text:`/`img:`）解析后渲染；
/// `iconID` 为 nil 或 `.none` 时回退到 `fallbackSymbol`。
struct FeatureIconView: View {
    let iconID: String?
    /// 当 iconID 为 nil/none 时的回退 SF Symbol
    let fallbackSymbol: String
    let size: CGFloat
    /// 图标颜色（默认白色，与功能列表文字一致）
    var color: Color = .white

    var body: some View {
        renderContent(effectiveKind)
    }

    /// Spec: fallbackSymbol 也支持 `sf:`/`text:`/`img:` 前缀（与 iconID 一致），
    /// 例如 `.webURL` 默认 `systemImage = "text:U"` 应渲染为文字「U」而非 SF Symbol。
    /// 当 iconID 为 nil/空/none 时，用 resolveIconKind(fallbackSymbol) 解析。
    private var effectiveKind: IconKind {
        let resolved = resolveIconKind(iconID)
        if case .none = resolved {
            return resolveIconKind(fallbackSymbol)
        }
        return resolved
    }

    @ViewBuilder
    private func renderContent(_ kind: IconKind) -> some View {
        switch kind {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundColor(color)
        case .text(let str):
            Text(str)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .frame(maxWidth: size * 1.6)
        case .image(let filename):
            if let nsImage = IconImageStore.nsImage(for: "img:\(filename)") {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                // 图片加载失败回退到 SF Symbol "globe"
                Image(systemName: "globe")
                    .font(.system(size: size))
                    .foregroundColor(color)
            }
        case .none:
            // iconID 与 fallbackSymbol 都为空 → 最终兜底 "globe"
            Image(systemName: "globe")
                .font(.system(size: size))
                .foregroundColor(color)
        }
    }
}

/// 便捷初始化：从 LeftFeature 取 iconID 与默认图标
extension FeatureIconView {
    init(feature: LeftFeature, size: CGFloat, color: Color = .white) {
        self.init(
            iconID: feature.customIconName,
            fallbackSymbol: feature.systemImage,
            size: size,
            color: color
        )
    }

    /// 便捷初始化：从 CustomArea 取 iconID，fallback 用 "globe"
    init(area: CustomArea, size: CGFloat, color: Color = .white) {
        self.init(
            iconID: area.iconName,
            fallbackSymbol: "globe",
            size: size,
            color: color
        )
    }
}
