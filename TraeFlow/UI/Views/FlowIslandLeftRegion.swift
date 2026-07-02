import SwiftUI
import WebKit

/// Spec: Flow 岛左半区 —— 紧凑态由 `NotchView.headerRow` 分发到功能视图，
/// 展开态由本视图根据活跃会话优先级渲染：有活跃会话时显示会话详情，
/// 无活跃会话时显示 `LeftFeatureContainerView`（功能切换栏 + 主内容区）。
///
/// 展开态功能容器的选择（`LeftFeatureStore.expandedActiveFeatureID`）由
/// `LeftFeatureContainerView` 内部 `@ObservedObject` 自动处理，本视图不再
/// 手动监听 `expandedAreaID` / FSEvents。
struct FlowIslandLeftRegion: View {
    @ObservedObject private var sessionMonitor: SessionMonitor

    let isExpanded: Bool
    let activeSession: SessionState?

    init(isExpanded: Bool, activeSession: SessionState?, sessionMonitor: SessionMonitor) {
        self.isExpanded = isExpanded
        self.activeSession = activeSession
        self.sessionMonitor = sessionMonitor
    }

    var body: some View {
        Group {
            if let session = activeSession {
                // Spec: 有活跃会话时左侧展示会话详情/审批/追问
                activeSessionContent(session)
            } else {
                // Spec: 无活跃会话时展示功能容器（切换栏 + 主内容区），
                // 由 LeftFeatureContainerView 内部 @ObservedObject 处理功能切换。
                LeftFeatureContainerView()
            }
        }
    }

    // MARK: - Active Session Content

    @ViewBuilder
    private func activeSessionContent(_ session: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.clientInfo.name ?? session.clientInfo.profileID ?? "TRAE")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            if let lastMessage = session.lastMessage {
                Text(lastMessage)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}
