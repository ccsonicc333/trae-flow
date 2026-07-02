import SwiftUI
import UniformTypeIdentifiers

/// 展开态顶部功能切换栏 —— 位于左上角，水平排列图标按钮，支持点击切换 + 拖拽排序
///
/// 布局：`HStack` 仅占按钮所需宽度（不撑满），由父 `VStack(alignment: .leading)`
/// 左对齐到顶部左上角。padding 仅在 leading 侧保留少量间距。
///
/// - Parameter onSelect: 选中功能后的额外回调（例如从任务列表视图点击时需同时切换
///   `contentType` 到 `.customExpanded`）。在 `store.setExpandedActiveFeature` 之后调用。
/// - Parameter showAllUnselected: 为 true 时所有功能图标显示为未选中态（用于任务列表视图）。
struct LeftFeatureSwitcherBar: View {
    @ObservedObject private var store = LeftFeatureStore.shared
    var onSelect: ((String) -> Void)?
    var showAllUnselected: Bool = false

    var body: some View {
        if store.enabledFeatures.count >= 1 {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(store.enabledFeatures) { feature in
                        FeatureSwitcherButton(feature: feature, onSelect: onSelect, showAllUnselected: showAllUnselected)
                    }
                }
                .padding(.vertical, 4)
                .padding(.leading, 4)
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sourceID = object as? String else { return }
            Task { @MainActor in
                guard let sourceIndex = store.enabledFeatures.firstIndex(where: { $0.id == sourceID }) else { return }
                // drop 到栏上，destination 取末尾（简化：拖到栏末尾）
                let destination = store.enabledFeatures.count
                store.moveFeature(from: IndexSet([sourceIndex]), to: destination)
            }
        }
    }
}

// MARK: - Feature Switcher Button

private struct FeatureSwitcherButton: View {
    let feature: LeftFeature
    var onSelect: ((String) -> Void)?
    var showAllUnselected: Bool = false
    @ObservedObject private var store = LeftFeatureStore.shared
    @State private var isHovering = false

    private var isActive: Bool {
        guard !showAllUnselected else { return false }
        return store.expandedActiveFeature?.id == feature.id
    }

    var body: some View {
        Button {
            store.setExpandedActiveFeature(id: feature.id)
            onSelect?(feature.id)
        } label: {
            FeatureIconView(feature: feature, size: 14, color: foregroundColor)
                .frame(width: 28, height: 28)
                .background(backgroundFill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(feature.displayName)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onDrag {
            NSItemProvider(object: feature.id as NSString)
        }
    }

    private var foregroundColor: Color {
        isActive ? .white : (isHovering ? .white : .secondary)
    }

    @ViewBuilder
    private var backgroundFill: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color.accentColor : (isHovering ? Color.white.opacity(0.15) : Color.clear))
    }
}
