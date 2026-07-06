import SwiftUI

/// Spec: mineradio-bridge-compat-layer — Mineradio 功能紧凑态视图。
///
/// 显示优先级：
/// 1. 当前歌词行（`coordinator.currentLyric?.text`，非空时显示）
/// 2. 空白（无歌词时不显示任何文本，不回退到歌曲标题或静态文本）
///
/// 歌词渲染：karaoke 高亮 —— 整行文本用暗色绘制，叠加一层亮色文本用 `mask`
/// 按 `currentLyricProgress` 从左到右渐变填充，模拟 Mineradio 网页的逐字进度效果。
///
/// 左侧图标显示优先级：
/// 1. 当前歌曲专辑封面（`coordinator.coverImage`）
/// 2. LeftFeature.customIconName（通常是 Mineradio 网站 favicon）
/// 3. `antenna.radiowaves.left.and.right` SF Symbol（最终回退）
///
/// 无背景包裹、无登录指示点 —— 紧凑态直接悬浮在 Flow 岛上。
struct MineradioCompactView: View {
    @ObservedObject private var coordinator = MineradioBridgeCoordinator.shared
    private let feature = LeftFeatureStore.shared.features.first { $0.id == LeftFeature.mineradioID }

    /// 当前紧凑态应显示的文本（无歌词时返回 nil，不回退到标题或静态文本）
    private var displayText: String? {
        if let lyric = coordinator.currentLyric?.text, !lyric.isEmpty {
            return lyric
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            // 左侧图标：专辑封面 → feature 自定义图标（favicon）→ SF Symbol 回退
            // 用 .id(coverImageRevision) 强制 SwiftUI 在封面变化时重建 Image
            if let coverImage = coordinator.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .id(coordinator.coverImageRevision)
                    .accessibilityHidden(true)
            } else if let iconID = feature?.customIconName, !iconID.isEmpty {
                FeatureIconView(iconID: iconID, fallbackSymbol: "antenna.radiowaves.left.and.right", size: 16, color: .white.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }

            if let text = displayText {
                // Spec: karaoke 高亮歌词 —— 暗色底 + 亮色高亮层用 mask 按 progress 渐变填充
                karaokeLyricText(text)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Spec: karaoke 歌词文本视图
    /// 底层：暗色整行文本（白色 0.45 透明度）
    /// 上层：亮色整行文本（白色 0.95 透明度），用线性渐变 mask 控制可见范围
    /// mask 的渐变停止点由 `coordinator.currentLyricProgress` 驱动
    @ViewBuilder
    private func karaokeLyricText(_ text: String) -> some View {
        let progress = coordinator.currentLyricProgress
        let font = Font.system(size: 10.5, weight: .semibold, design: .rounded)

        // 底层暗色文本
        Text(text)
            .font(font)
            .foregroundColor(.white.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .overlay(alignment: .leading) {
                // 上层亮色文本，用 mask 渐变控制可见范围
                Text(text)
                    .font(font)
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .mask(
                        // Spec: 线性渐变 mask —— 0...progress 区域不透明，progress...1 区域透明
                        // 用三段渐变制造"硬边"效果：progress 之前全黑，progress 之后全透明
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .black, location: max(progress - 0.001, 0)),
                                .init(color: .black, location: progress),
                                .init(color: .clear, location: min(progress + 0.001, 1)),
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .animation(.linear(duration: 0.2), value: progress)
            }
    }

    private var accessibilityLabel: String {
        if let lyric = coordinator.currentLyric?.text, !lyric.isEmpty {
            return "Mineradio 歌词：\(lyric)"
        }
        return "Mineradio 矿石电台"
    }
}
