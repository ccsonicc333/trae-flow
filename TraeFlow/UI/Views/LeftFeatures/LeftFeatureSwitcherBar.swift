import SwiftUI
import UniformTypeIdentifiers

/// 展开态顶部功能切换栏 —— 位于左上角，水平排列图标按钮，支持点击切换 + 拖拽排序
///
/// 布局：`HStack` 仅占按钮所需宽度（不撑满），由父 `VStack(alignment: .leading)`
/// 左对齐到顶部左上角。padding 仅在 leading 侧保留少量间距。
///
/// 拖拽排序：每个按钮既是 drag source 也是 drop target。
/// 拖拽中：被拖拽的按钮半透明；目标按钮显示高亮边框 + 左/右插入指示线。
/// drop 到按钮左半区 → 插入到该位置之前；右半区 → 插入到该位置之后。
/// 用 `store.moveFeatureByID` 基于 ID 重排，避免索引错位。
///
/// - Parameter onSelect: 选中功能后的额外回调（例如从任务列表视图点击时需同时切换
///   `contentType` 到 `.customExpanded`）。在 `store.setExpandedActiveFeature` 之后调用。
/// - Parameter showAllUnselected: 为 true 时所有功能图标显示为未选中态（用于任务列表视图）。
struct LeftFeatureSwitcherBar: View {
    @ObservedObject private var store = LeftFeatureStore.shared
    var onSelect: ((String) -> Void)?
    var showAllUnselected: Bool = false

    /// 当前被拖拽的 feature ID（用于半透明显示）
    @State private var draggingFeatureID: String?

    /// 当前 drop 目标的 feature ID + 位置（左/右）
    @State private var dropTargetID: String?
    @State private var dropBefore: Bool = false

    var body: some View {
        if store.enabledFeatures.count >= 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.enabledFeatures) { feature in
                        FeatureSwitcherButton(
                            feature: feature,
                            onSelect: onSelect,
                            showAllUnselected: showAllUnselected,
                            isDragging: draggingFeatureID == feature.id,
                            isDropTarget: dropTargetID == feature.id,
                            dropBefore: dropBefore,
                            onDragStart: { draggingFeatureID = feature.id },
                            onDropEntered: { before in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    dropTargetID = feature.id
                                    dropBefore = before
                                }
                            },
                            onDropExited: {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if dropTargetID == feature.id {
                                        dropTargetID = nil
                                    }
                                }
                            },
                            onDropReceived: { sourceID, before in
                                handleDrop(sourceID: sourceID, targetID: feature.id, dropBefore: before)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.leading, 4)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.enabledFeatures.map(\.id))
            }
        }
    }

    /// Spec: 处理 drop —— 用 moveFeatureByID 基于 ID 重排，避免索引错位
    private func handleDrop(sourceID: String, targetID: String, dropBefore: Bool) {
        store.moveFeatureByID(sourceID: sourceID, targetID: targetID, dropBefore: dropBefore)
        withAnimation(.easeOut(duration: 0.2)) {
            draggingFeatureID = nil
            dropTargetID = nil
        }
    }
}

// MARK: - Feature Switcher Button

private struct FeatureSwitcherButton: View {
    let feature: LeftFeature
    var onSelect: ((String) -> Void)?
    var showAllUnselected: Bool = false
    var isDragging: Bool
    var isDropTarget: Bool
    var dropBefore: Bool
    var onDragStart: () -> Void
    var onDropEntered: (Bool) -> Void
    var onDropExited: () -> Void
    var onDropReceived: (String, Bool) -> Void

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
        .opacity(isDragging ? 0.4 : 1.0) // 拖拽中半透明
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onDrag {
            onDragStart()
            return NSItemProvider(object: feature.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: FeatureDropDelegate(
                featureID: feature.id,
                onDropEntered: onDropEntered,
                onDropExited: onDropExited,
                onDropReceived: onDropReceived
            )
        )
        .overlay(
            // Drop 指示器：被 targeted 时显示边框
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.9 : 0), lineWidth: 1.5)
                .scaleEffect(isDropTarget ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDropTarget)
        )
        .overlay(alignment: .leading) {
            // 左侧插入指示线（dropBefore 且当前是目标时显示）
            if isDropTarget && dropBefore {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 24)
                    .offset(x: -3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            // 右侧插入指示线（!dropBefore 且当前是目标时显示）
            if isDropTarget && !dropBefore {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 24)
                    .offset(x: 3)
                    .transition(.scale.combined(with: .opacity))
            }
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

// MARK: - Drop Delegate

/// Spec: 功能按钮的 drop delegate —— 根据鼠标在按钮上的水平位置决定插入到左侧还是右侧。
/// drop 到按钮左半区 → 插入到该 feature 之前；右半区 → 插入到该 feature 之后。
/// 用 `moveFeatureByID` 基于 ID 重排，避免索引错位。
private struct FeatureDropDelegate: DropDelegate {
    let featureID: String
    let onDropEntered: (Bool) -> Void  // 参数: dropBefore
    let onDropExited: () -> Void
    let onDropReceived: (String, Bool) -> Void  // 参数: sourceID, dropBefore

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        let dropBefore = info.location.x < 14
        onDropEntered(dropBefore)
    }

    func dropExited(info: DropInfo) {
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        // Spec: 根据鼠标水平位置决定插入到左/右
        // info.location.x 是相对于 drop delegate 关联视图的坐标，范围 0...viewWidth
        // 视图宽度 28pt，左半区 < 14，右半区 >= 14
        let dropBefore = info.location.x < 14

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sourceID = object as? String else { return }
            Task { @MainActor in
                onDropReceived(sourceID, dropBefore)
            }
        }
        return true
    }
}
