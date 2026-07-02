import SwiftUI

/// Spec: Flow 岛紧凑态布局：右侧固定 TRAE 图标/任务计数区
/// Spec: Flow 岛展开态：右侧展开四个变体任务数列表与"跳回 IDE"入口
///
/// 右侧区域：展示 4 个 Trae 变体的任务计数（等待用户干预的会话数），
/// 点击展开后可看到各变体详情并跳回对应 IDE。
struct FlowIslandRightRegion: View {
    @ObservedObject private var sessionMonitor: SessionMonitor

    let isExpanded: Bool

    init(isExpanded: Bool, sessionMonitor: SessionMonitor) {
        self.isExpanded = isExpanded
        self.sessionMonitor = sessionMonitor
    }

    var body: some View {
        if isExpanded {
            expandedContent
        } else {
            compactContent
        }
    }

    // MARK: - Compact

    /// Spec: 紧凑态右侧 — TRAE 图标 + 总任务数
    private var compactContent: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)

            let totalPending = pendingCountSum
            if totalPending > 0 {
                Text("\(totalPending)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 28)
    }

    // MARK: - Expanded

    /// Spec: 展开态右侧 — 四个变体任务数列表与"跳回 IDE"入口
    private var expandedContent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(TraeVariant.allCases) { variant in
                variantRow(variant)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func variantRow(_ variant: TraeVariant) -> some View {
        let count = pendingCount(for: variant)

        HStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(count > 0 ? .white : .secondary)

            Image(systemName: variant.iconSymbolName)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.85))

            Text(variant.displayName)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            // Spec: 跳回对应变体 IDE 入口
            if count > 0 {
                Button {
                    TraeSessionLauncher.activate(variant)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("跳回 \(variant.displayName)")
            }
        }
        .opacity(count > 0 ? 1.0 : 0.5)
    }

    // MARK: - Session Counting

    /// Spec: 任务数定义 —— 该变体当前处于"等待用户干预"状态的会话数量
    private func pendingCount(for variant: TraeVariant) -> Int {
        sessionMonitor.instances.filter { session in
            guard let resolved = TraeVariant.fromBundleIdentifier(session.clientInfo.bundleIdentifier) else {
                return false
            }
            return resolved == variant && session.needsAttention
        }.count
    }

    private var pendingCountSum: Int {
        TraeVariant.allCases.map { pendingCount(for: $0) }.reduce(0, +)
    }
}
