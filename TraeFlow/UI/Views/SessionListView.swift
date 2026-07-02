//
//  SessionListView.swift
//  TraeFlow
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

struct SessionListView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    var enableKeyboardNavigation = true
    var highlightedSessionStableID: String? = nil
    @State private var expandedSessionStableID: String?
    @State private var selectedSessionStableID: String?
    @State private var keyEventMonitor: Any?
    @State private var isYabaiAvailable = false

    var body: some View {
        Group {
            if sessionMonitor.instances.isEmpty {
                emptyState
            } else {
                instancesList
            }
        }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Start a task in TRAE Builder")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    // MARK: - Instances List

    private var sortedInstances: [SessionState] {
        sessionMonitor.instances
    }

    private var sessionGroups: [PrimarySessionGroup] {
        PrimarySessionGroup.groups(from: sortedInstances)
    }

    private var displayedInstances: [SessionState] {
        sessionGroups.flatMap { [$0.session] + $0.childSessions }
    }

    private var displayedStableIDs: [String] {
        displayedInstances.map(\.stableId)
    }

    private var shouldUseScrollContainer: Bool {
        displayedInstances.count > 3 || expandedSessionStableID != nil
    }

    private var listContent: some View {
        LazyVStack(spacing: 2) {
            ForEach(sessionGroups) { group in
                VStack(spacing: 0) {
                    InstanceRow(
                        session: group.session,
                        isExpanded: expandedSessionStableID == group.session.stableId,
                        isSelected: selectedSessionStableID == group.session.stableId,
                        isHighlighted: highlightedSessionStableID == group.session.stableId,
                        isYabaiAvailable: isYabaiAvailable,
                        onSelect: { selectSession(group.session) },
                        onActivate: { activateSession(group.session) },
                        onToggleExpanded: { toggleExpanded(group.session) },
                        onFocus: { activateSession(group.session) },
                        onChat: { openChat(group.session) },
                        onOpenClient: { openClient(group.session) },
                        onArchive: { archiveSession(group.session) },
                        onApprove: { approveSession(group.session) },
                        onApproveForSession: { approveSessionForScope(group.session) },
                        onReject: { rejectSession(group.session) }
                    )
                    .id(group.session.stableId)

                    if !group.childSessions.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(group.childSessions) { childSession in
                                SubagentAttachmentRow(
                                    session: childSession,
                                    isSelected: selectedSessionStableID == childSession.stableId,
                                    isHighlighted: highlightedSessionStableID == childSession.stableId,
                                    onSelect: { selectSession(childSession) },
                                    onActivate: { activateSession(childSession) },
                                    onChat: { openChat(childSession) }
                                )
                                .id(childSession.stableId)
                            }
                        }
                        .padding(.leading, 46)
                        .padding(.trailing, 0)
                        .padding(.top, 3)
                        .padding(.bottom, 5)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            Group {
                if shouldUseScrollContainer {
                    ScrollView(.vertical, showsIndicators: false) {
                        listContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    listContent
                }
            }
            .onAppear {
                selectedSessionStableID = nil
                if enableKeyboardNavigation {
                    installKeyEventMonitorIfNeeded()
                }
            }
            .onDisappear {
                removeKeyEventMonitor()
            }
            .onChange(of: displayedStableIDs) { _, stableIDs in
                if let expandedSessionStableID, !stableIDs.contains(expandedSessionStableID) {
                    self.expandedSessionStableID = nil
                }
                syncSelection(with: displayedInstances)
            }
            .onChange(of: selectedSessionStableID) { _, stableID in
                guard let stableID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(stableID, anchor: .center)
                }
            }
            .onChange(of: highlightedSessionStableID) { _, stableID in
                guard let stableID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(stableID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Actions

    private func activateSession(_ session: SessionState) {
        guard !session.clientInfo.suppressesActivationNavigation else { return }
        selectSession(session)
        viewModel.notchClose()
        Task {
            let targetSession = await interactionTargetSession(for: session)
            _ = await SessionLauncher.shared.activate(targetSession)
        }
    }

    private func toggleExpanded(_ session: SessionState) {
        selectSession(session)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            if expandedSessionStableID == session.stableId {
                expandedSessionStableID = nil
            } else {
                expandedSessionStableID = session.stableId
            }
        }
    }

    private func openChat(_ session: SessionState) {
        selectSession(session)
        Task {
            let targetSession = await interactionTargetSession(for: session)
            await MainActor.run {
                viewModel.showChat(for: targetSession)
            }
        }
    }

    private func openClient(_ session: SessionState) {
        selectSession(session)
        Task {
            _ = await SessionLauncher.shared.activateClientApplication(session)
        }
    }

    private func approveSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func approveSessionForScope(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
    }

    private func rejectSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        selectSession(session)
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    private func selectSession(_ session: SessionState) {
        guard selectedSessionStableID != session.stableId else { return }
        selectedSessionStableID = session.stableId
    }

    private func syncSelection(with sessions: [SessionState]) {
        guard !sessions.isEmpty else {
            selectedSessionStableID = nil
            return
        }

        guard let selectedSessionStableID else {
            return
        }

        guard sessions.contains(where: { $0.stableId == selectedSessionStableID }) else {
            self.selectedSessionStableID = nil
            return
        }
    }

    private func installKeyEventMonitorIfNeeded() {
        guard enableKeyboardNavigation else { return }
        guard keyEventMonitor == nil else { return }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyEventMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard viewModel.status == .opened else { return false }
        guard case .instances = viewModel.contentType else { return false }
        guard NSApp.keyWindow is NotchPanel else { return false }

        let sessions = displayedInstances
        guard !sessions.isEmpty else { return false }

        switch event.keyCode {
        case UInt16(kVK_UpArrow):
            moveSelection(delta: -1, in: sessions)
            return true
        case UInt16(kVK_DownArrow):
            moveSelection(delta: 1, in: sessions)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            activateSelectedSession(in: sessions)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int, in sessions: [SessionState]) {
        guard !sessions.isEmpty else { return }

        let currentIndex: Int
        if let selectedSessionStableID,
           let existingIndex = sessions.firstIndex(where: { $0.stableId == selectedSessionStableID }) {
            currentIndex = existingIndex
        } else {
            currentIndex = delta > 0 ? -1 : sessions.count
        }

        let targetIndex = min(max(currentIndex + delta, 0), sessions.count - 1)
        selectedSessionStableID = sessions[targetIndex].stableId
    }

    private func activateSelectedSession(in sessions: [SessionState]) {
        guard let selectedSessionStableID,
              let targetSession = sessions.first(where: { $0.stableId == selectedSessionStableID }) else {
            return
        }

        viewModel.notchClose()

        Task {
            let interactionTarget = await interactionTargetSession(for: targetSession)
            _ = await SessionLauncher.shared.activate(interactionTarget)
        }
    }

    private func interactionTargetSession(for session: SessionState) async -> SessionState {
        if let linkedParentSessionId = session.linkedParentSessionId,
           let linkedParentSession = await SessionStore.shared.session(for: linkedParentSessionId) {
            return linkedParentSession
        }

        return session
    }
}

struct PrimarySessionGroup: Identifiable, Equatable {
    let session: SessionState
    let childSessions: [SessionState]

    var id: String { session.stableId }

    static func groups(from sortedSessions: [SessionState]) -> [PrimarySessionGroup] {
        let sessionsById = Dictionary(uniqueKeysWithValues: sortedSessions.map { ($0.sessionId, $0) })
        var childrenByParentId: [String: [SessionState]] = [:]
        var nestedChildIds = Set<String>()

        for session in sortedSessions {
            guard let parentId = attachmentParentId(for: session, sessionsById: sessionsById) else {
                continue
            }

            childrenByParentId[parentId, default: []].append(session)
            nestedChildIds.insert(session.sessionId)
        }

        return sortedSessions
            .filter { !nestedChildIds.contains($0.sessionId) }
            .map { session in
                PrimarySessionGroup(
                    session: session,
                    childSessions: childrenByParentId[session.sessionId] ?? []
                )
            }
    }

    private static func attachmentParentId(
        for session: SessionState,
        sessionsById: [String: SessionState]
    ) -> String? {
        return nil
    }
}

private struct SubagentAttachmentRow: View {
    let session: SessionState
    let isSelected: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onChat: () -> Void

    @State private var isHovered = false

    private var title: String {
        if false {
            let role = sanitized(nil).map(Self.titleCased(_:))
            let title = sanitized(session.sessionName)
                ?? sanitized(session.firstUserMessage)
                ?? sanitized(session.previewText)
                ?? sanitized(session.displayTitle)
                ?? sanitized(nil)

            if let role, let title, role.caseInsensitiveCompare(title) != .orderedSame {
                return "\(role) (\(title))"
            }

            return role
                ?? sanitized(nil)
                ?? sanitized(nil)
                ?? session.displayTitle
        }

        return sanitized(session.linkedSubagentDisplayTitle)
            ?? sanitized(session.heuristicSubagentDisplayTitle)
            ?? sanitized(nil)
            ?? session.displayTitle
    }

    private var detail: String? {
        if let latestTool = latestToolCall {
            let preview = latestTool.inputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                return "\(latestTool.name): \(preview)"
            }
            let statusText = latestTool.statusDisplay.text
            let localizedStatus = localizedOrOriginal(statusText) ?? statusText
            return localizedStatus
        }

        if let lastToolName = sanitized(session.lastToolName) {
            return lastToolName
        }

        if let lastMessage = localizedOrOriginal(sanitized(session.lastMessage)) {
            return lastMessage
        }

        switch session.phase {
        case .processing:
            return AppLocalization.string("工作中...")
        case .compacting:
            return AppLocalization.string("正在压缩上下文...")
        case .waitingForApproval:
            return session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待批准")
        case .waitingForInput:
            return AppLocalization.string("等待你的下一条消息")
        case .ended:
            return AppLocalization.string("会话已结束")
        case .idle:
            return nil
        }
    }

    private var latestToolCall: ToolCallItem? {
        for item in session.chatItems.reversed() {
            if case .toolCall(let tool) = item.type {
                return tool
            }
        }
        return nil
    }

    private var ageLabel: String {
        formattedTime(from: session.lastActivity)
    }

    private var needsInAppResponse: Bool {
        session.needsQuestionResponse || session.needsApprovalResponse
    }

    private var rowFill: Color {
        if isSelected {
            return Color.white.opacity(isHovered ? 0.11 : 0.08)
        }
        if isHighlighted {
            return Color.white.opacity(isHovered ? 0.09 : 0.06)
        }
        return isHovered ? Color.white.opacity(0.055) : Color.clear
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("└")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.18))
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 5) {
                Text(ageLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.34))

                Text("SUBAGENT")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.top, 1)
            .fixedSize()
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
            perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
        }
        .onTapGesture {
            onSelect()
            onActivate()
        }
        .onHover {
            isHovered = $0
            if $0 {
                onSelect()
            }
        }
    }

    private func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func perform(_ action: SessionListRowClickAction) {
        switch action {
        case .activate:
            onActivate()
        case .chat:
            onChat()
        case .toggleExpanded:
            break
        }
    }

    nonisolated private static func titleCased(_ text: String) -> String {
        text
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let isExpanded: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let isYabaiAvailable: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onChat: () -> Void
    let onOpenClient: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.needsApprovalResponse
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        if session.needsQuestionResponse {
            return true
        }
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    private var providerLabel: String {
        session.messageBadgeDisplayName
    }

    private var interactionLabel: String {
        session.interactionDisplayName
    }

    private var providerColor: Color {
        session.clientTintColor
    }

    private var terminalSourceLabel: String? {
        session.terminalSourceBadgeLabel
    }

    private var showsNativeRuntimeBadge: Bool {
        session.ingress == .nativeRuntime
    }

    private var titleFontSize: CGFloat {
        CGFloat(settings.contentFontSize)
    }

    private var detailFontSize: CGFloat {
        max(11, titleFontSize - 2)
    }

    private var detailsEnabled: Bool {
        settings.showAgentDetail
    }

    private var isMinimalCompactPresentation: Bool {
        session.shouldUseMinimalCompactPresentation
    }

    private var usesSingleLineCompactLayout: Bool {
        isCollapsedCompactPresentation
    }

    private var isCollapsedCompactPresentation: Bool {
        isMinimalCompactPresentation && !isExpanded
    }

    private var usesCodexSubagentTitleOnlyPresentation: Bool {
        false
    }

    private var needsInAppResponse: Bool {
        session.needsQuestionResponse || isWaitingForApproval
    }

    private var projectTitleFontSize: CGFloat {
        max(11, titleFontSize - 1)
    }

    private var sessionTitleFontSize: CGFloat {
        if usesSingleLineCompactLayout {
            return max(11, titleFontSize - 1)
        }
        return max(12, titleFontSize + 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingContent

            if usesCodexSubagentTitleOnlyPresentation {
                VStack(alignment: .trailing, spacing: 6) {
                    subagentCompactBadgeLine

                    trailingActions
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            } else if isCollapsedCompactPresentation {
                compactMetaLine
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        metaBadge(
                            timeLabel,
                            tint: Color.white.opacity(0.1),
                            foreground: .white.opacity(0.64),
                            fontDesign: .monospaced
                        )
                        metaBadge(providerLabel, tint: providerColor.opacity(0.2))
                    }

                    trailingActions
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, usesSingleLineCompactLayout ? 5 : 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: session.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
        .saturation(isCollapsedCompactPresentation ? 0 : 1)
        .opacity(isCollapsedCompactPresentation ? 0.72 : 1)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(rowBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(rowBorderColor, lineWidth: 1)
                )
        )
        .onHover {
            isHovered = $0
            if $0 {
                onSelect()
            }
        }
    }

    private var leadingContent: some View {
        Group {
            if isMinimalCompactPresentation {
                baseLeadingContent
                    .onTapGesture(count: 2) {
                        onSelect()
                        perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
                    }
                    .onTapGesture {
                        onSelect()
                        perform(SessionListRowClickBehavior.primaryTapAction(
                            isMinimalCompactPresentation: isMinimalCompactPresentation
                        ))
                    }
            } else {
                baseLeadingContent
                    .onTapGesture(count: 2) {
                        onSelect()
                        perform(SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: needsInAppResponse))
                    }
                    .onTapGesture {
                        onSelect()
                        perform(SessionListRowClickBehavior.primaryTapAction(
                            isMinimalCompactPresentation: isMinimalCompactPresentation
                        ))
                    }
            }
        }
    }

    private var baseLeadingContent: some View {
        HStack(alignment: .center, spacing: 10) {
            avatarView

            leadingTextContent

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var leadingTextContent: some View {
        VStack(alignment: .leading, spacing: usesSingleLineCompactLayout ? 0 : 5) {
            if shouldReserveIncomingPreviewLineHeight {
                reservedPreviewCenteringSpacer
            }

            titleLine
                .lineLimit(1)
                .truncationMode(.tail)

            if shouldShowExpandedDetails {
                previewLinesView
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }

            if shouldReserveIncomingPreviewLineHeight {
                reservedPreviewCenteringSpacer
            }
        }
    }

    private var reservedPreviewCenteringSpacer: some View {
        Color.clear
            .frame(height: reservedPreviewLineHeight / 2)
            .accessibilityHidden(true)
    }

    private var titleLine: Text {
        if usesCodexSubagentTitleOnlyPresentation || session.shouldHideProjectContextInUI {
            return Text(session.displayTitle)
                .font(.system(size: sessionTitleFontSize, weight: .bold))
                .foregroundColor(.white)
        }

        if let taskTitle = session.effectiveTaskTitle, !taskTitle.isEmpty {
            // 有真实任务标题：项目名 · 任务标题
            return Text(session.projectName)
                .font(.system(size: projectTitleFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))
            + Text(" · ")
                .font(.system(size: projectTitleFontSize, weight: .bold))
                .foregroundColor(.white.opacity(0.34))
            + Text(taskTitle)
                .font(.system(size: sessionTitleFontSize, weight: .bold))
                .foregroundColor(.white)
        }

        // 无真实任务标题（如 TRAE CN 无多任务）：仅项目名
        return Text(session.projectName)
            .font(.system(size: sessionTitleFontSize, weight: .semibold))
            .foregroundColor(.white.opacity(0.84))
    }

    @ViewBuilder
    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))

            MascotView(
                kind: settings.mascotKind(for: session.mascotClient),
                status: MascotStatus(session: session),
                size: usesSingleLineCompactLayout ? 16 : 18,
                animationTime: 0
            )
            .padding(6)

            avatarStatusBadge
                .offset(x: 2, y: 2)
        }
        .frame(width: usesSingleLineCompactLayout ? 30 : 34, height: usesSingleLineCompactLayout ? 30 : 34)
    }

    @ViewBuilder
    private var avatarStatusBadge: some View {
        switch session.phase {
        case .processing, .compacting, .waitingForApproval:
            animatedStatusBadge
        case .waitingForInput:
            Circle()
                .fill(statusAccentColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.8), lineWidth: 2)
                )
        case .idle, .ended:
            EmptyView()
        }
    }

    @ViewBuilder
    private var animatedStatusBadge: some View {
        if energyGovernor.policy.animationLevel == .staticFrames {
            statusBadge(symbol: spinnerSymbols[0])
        } else {
            TimelineView(.periodic(from: .now, by: statusBadgeInterval)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / statusBadgeInterval)
                statusBadge(symbol: spinnerSymbols[phase % spinnerSymbols.count])
            }
        }
    }

    private func statusBadge(symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 8, weight: .black))
            .foregroundColor(statusAccentColor)
            .frame(width: 14, height: 14)
            .background(Color.black.opacity(0.92))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(statusAccentColor.opacity(0.35), lineWidth: 1)
            )
    }

    private var statusBadgeInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            0.15
        case .reduced:
            0.375
        case .staticFrames:
            0.15
        }
    }

    private var statusAccentColor: Color {
        if session.needsQuestionResponse {
            return TerminalColors.blue
        }
        if isWaitingForApproval {
            return TerminalColors.amber
        }
        switch session.phase {
        case .processing:
            return providerColor
        case .compacting:
            return TerminalColors.magenta
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return Color.white.opacity(0.28)
        case .waitingForApproval:
            return TerminalColors.amber
        }
    }

    private var timeLabel: String {
        formattedTime(from: session.lastActivity)
    }

    private var terminalBadgeTint: Color {
        Color.white.opacity(0.1)
    }

    private enum SupplementaryBadge {
        case text(String, tint: Color, foreground: Color, fontDesign: Font.Design)
        case remote
    }

    private var primarySupplementaryBadge: SupplementaryBadge? {
        if showsNativeRuntimeBadge {
            return .text(
                "NATIVE",
                tint: Color.white.opacity(0.12),
                foreground: .white.opacity(0.92),
                fontDesign: .monospaced
            )
        }
        if session.isRemoteSession {
            return .remote
        }
        if let terminalSourceLabel {
            return .text(
                terminalSourceLabel,
                tint: terminalBadgeTint,
                foreground: .white.opacity(0.9),
                fontDesign: .default
            )
        }
        return nil
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.23 : 0.19)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.22 : 0.17)
            }
            return Color.white.opacity(isHovered ? 0.14 : 0.11)
        }
        if isHighlighted {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.2 : 0.16)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.2 : 0.15)
            }
            return Color.white.opacity(isHovered ? 0.11 : 0.08)
        }
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(isHovered ? 0.2 : 0.16)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(isHovered ? 0.18 : 0.13)
            }
            return Color.white.opacity(isHovered ? 0.1 : 0.07)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(isHovered ? 0.16 : 0.11)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(isHovered ? 0.15 : 0.09)
        }
        if session.phase.isActive {
            return Color.white.opacity(isHovered ? 0.08 : 0.04)
        }
        return isHovered ? Color.white.opacity(0.06) : Color.clear
    }

    private var rowBorderColor: Color {
        if isSelected {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.34)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.32)
            }
            return TerminalColors.green.opacity(isHovered ? 0.34 : 0.28)
        }
        if isHighlighted {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.32)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.3)
            }
            return Color.white.opacity(isHovered ? 0.2 : 0.16)
        }
        if isExpanded {
            if session.needsQuestionResponse {
                return TerminalColors.blue.opacity(0.28)
            }
            if isWaitingForApproval {
                return TerminalColors.amber.opacity(0.26)
            }
            return Color.white.opacity(isHovered ? 0.16 : 0.12)
        }
        if session.needsQuestionResponse {
            return TerminalColors.blue.opacity(0.16)
        }
        if isWaitingForApproval {
            return TerminalColors.amber.opacity(0.16)
        }
        return Color.white.opacity(isHovered ? 0.08 : 0.04)
    }

    private var shouldShowExpandedDetails: Bool {
        guard !usesCodexSubagentTitleOnlyPresentation else { return false }
        return !isMinimalCompactPresentation || isExpanded
    }

    private var compactMetaLine: some View {
        HStack(spacing: 5) {
            metaBadge(
                timeLabel,
                tint: Color.white.opacity(0.08),
                foreground: .white.opacity(0.6),
                fontDesign: .monospaced,
                compact: true
            )

            metaBadge(
                providerLabel,
                tint: providerColor.opacity(0.18),
                foreground: .white.opacity(0.86),
                compact: true
            )
        }
    }

    @ViewBuilder
    private var subagentCompactBadgeLine: some View {
        HStack(spacing: 5) {
            EmptyView()
        }
    }

    @ViewBuilder
    private var previewLinesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let prefix = line.prefix {
                        Text(prefix)
                            .font(.system(size: detailFontSize, weight: .semibold))
                            .foregroundColor(line.prefixColor)
                    }

                    Text(line.text)
                        .font(.system(size: detailFontSize, weight: .medium))
                        .foregroundColor(line.textColor)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Active sessions often start with a single transient status line ("working...")
    /// and then immediately grow to user + assistant preview lines once the first
    /// durable message lands. Reserve the second line height up front so the list
    /// and opened-notch measurement stay stable during that first content update.
    private var shouldReserveIncomingPreviewLineHeight: Bool {
        guard detailsEnabled else { return false }
        guard shouldShowExpandedDetails else { return false }
        guard session.phase.isActive else { return false }
        guard latestUserLine == nil else { return false }
        return previewLines.count == 1
    }

    private var reservedPreviewLineHeight: CGFloat {
        detailFontSize + 3
    }

    private var previewLines: [QueuePreviewLine] {
        var lines: [QueuePreviewLine] = []

        if let userLine = latestUserLine {
            lines.append(
                QueuePreviewLine(
                    id: "user",
                    prefix: AppLocalization.string("你："),
                    prefixColor: .white.opacity(0.52),
                    text: userLine,
                    textColor: .white.opacity(0.62)
                )
            )
        }

        if let assistantLine = latestAssistantLine {
            lines.append(
                QueuePreviewLine(
                    id: "assistant",
                    prefix: previewAssistantPrefix,
                    prefixColor: assistantPrefixColor,
                    text: assistantLine,
                    textColor: assistantTextColor
                )
            )
        }

        if lines.isEmpty, let fallback = compactDetailSummary {
            lines.append(
                QueuePreviewLine(
                    id: "fallback",
                    prefix: AppLocalization.string("状态："),
                    prefixColor: .white.opacity(0.48),
                    text: fallback,
                    textColor: .white.opacity(0.56)
                )
            )
        }

        return Array(lines.prefix(detailsEnabled ? 2 : 1))
    }

    private var assistantPrefixLabel: String {
        if session.needsQuestionResponse || isWaitingForApproval {
            return interactionLabel
        }
        return session.providerDisplayName
    }

    private var previewAssistantPrefix: String? {
        let badgeLabel = providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLabel = assistantPrefixLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixLabel.isEmpty, prefixLabel.caseInsensitiveCompare(badgeLabel) == .orderedSame {
            return nil
        }
        return prefixLabel.isEmpty ? nil : prefixLabel + "："
    }

    private var assistantPrefixColor: Color {
        providerColor.opacity(session.phase.isActive ? 0.96 : 0.92)
    }

    private var assistantTextColor: Color {
        if session.needsQuestionResponse {
            return .white.opacity(0.88)
        }
        if isWaitingForApproval {
            return .white.opacity(0.74)
        }
        if session.phase.isActive {
            return .white.opacity(0.66)
        }
        return .white.opacity(0.52)
    }

    private var latestUserLine: String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    private var latestAssistantLine: String? {
        if session.needsQuestionResponse {
            return sanitized(session.intervention?.summaryText) ?? AppLocalization.string("需要你的输入")
        }

        if isWaitingForApproval {
            if isInteractiveTool {
                return AppLocalization.string("等待你补充输入")
            }
            if let toolName = session.pendingToolName {
                return AppLocalization.format(
                    "等待批准 %@",
                    MCPToolFormatter.formatToolName(toolName)
                )
            }
            return AppLocalization.string("等待批准")
        }

        if session.phase == .processing {
            if session.isNativeRuntimeSession {
                return localizedOrOriginal(sanitized(session.lastMessage)) ?? AppLocalization.string("Native runtime 正在处理…")
            }
            return localizedOrOriginal(sanitized(session.lastMessage)) ?? AppLocalization.string("工作中...")
        }

        if session.phase == .compacting {
            return AppLocalization.string("正在压缩上下文...")
        }

        if session.phase == .waitingForInput, session.intervention == nil {
            if session.isNativeRuntimeSession {
                return localizedOrOriginal(sanitized(session.lastMessage)) ?? AppLocalization.string("Native session 已就绪")
            }
            return localizedOrOriginal(sanitized(session.lastMessage)) ?? AppLocalization.string("等待你的下一条消息")
        }

        if let lastMessage = localizedOrOriginal(sanitized(session.lastMessage)) {
            return lastMessage
        }

        return compactDetailSummary
    }

    @ViewBuilder
    private var trailingActions: some View {
        if session.shouldSuppressInAppPromptControls(
            routePromptsToTerminal: settings.effectiveRoutePromptsToTerminal
        ) {
            EmptyView()
        } else if session.needsQuestionResponse {
            HStack(spacing: 6) {
                IconButton(icon: "bubble.left") {
                    onChat()
                }

                if session.clientInfo.prefersAnsweredQuestionFollowupAction {
                    Button {
                        onOpenClient()
                    } label: {
                        Text(verbatim: AppLocalization.format("打开 %@", interactionLabel))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "terminal") {
                        onFocus()
                    }
                }
            }
        } else if isWaitingForApproval {
            InlineApprovalButtons(
                sessionAction: session.scopedApprovalAction,
                onChat: onChat,
                onApprove: onApprove,
                onApproveForSession: onApproveForSession,
                onReject: onReject
            )
        } else {
            HStack(spacing: 6) {
                IconButton(icon: "bubble.left") {
                    onChat()
                }

                if session.isInTmux && isYabaiAvailable {
                    IconButton(icon: "eye") {
                        onFocus()
                    }
                }

                if session.shouldShowArchiveActionInPrimaryUI {
                    IconButton(icon: "archivebox") {
                        onArchive()
                    }
                }
            }
        }
    }

    private func metaBadge(
        _ text: String,
        tint: Color,
        foreground: Color = .white.opacity(0.92),
        fontDesign: Font.Design = .default,
        compact: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: compact ? 7 : 8, weight: .semibold, design: fontDesign))
            .monospacedDigit()
            .foregroundColor(foreground)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1 : 3)
            .background(tint)
            .clipShape(Capsule())
    }

    private func remoteSessionBadge(compact: Bool = false) -> some View {
        Image(systemName: "cloud.fill")
            .font(.system(size: compact ? 8 : 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            .background(Color(red: 0.42, green: 0.70, blue: 0.98).opacity(compact ? 0.22 : 0.26))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .help(AppLocalization.string("远程连接"))
    }

    @ViewBuilder
    private func supplementaryBadgeView(
        _ badge: SupplementaryBadge,
        compact: Bool = false
    ) -> some View {
        switch badge {
        case .text(let text, let tint, let foreground, let fontDesign):
            metaBadge(
                text,
                tint: tint,
                foreground: foreground,
                fontDesign: fontDesign,
                compact: compact
            )
        case .remote:
            remoteSessionBadge(compact: compact)
        }
    }

    private var compactDetailSummary: String? {
        switch session.phase {
        case .processing:
            return session.isNativeRuntimeSession
                ? AppLocalization.string("Native runtime 正在处理…")
                : AppLocalization.string("工作中...")
        case .compacting:
            return AppLocalization.string("正在压缩上下文...")
        case .waitingForApproval:
            return session.needsQuestionResponse
                ? AppLocalization.string("需要你的输入")
                : AppLocalization.string("等待批准")
        case .waitingForInput:
            if session.needsQuestionResponse {
                return AppLocalization.string("需要你的输入")
            }
            return session.isNativeRuntimeSession
                ? AppLocalization.string("Native session 已就绪")
                : AppLocalization.string("等待你的下一条消息")
        case .ended:
            return session.isNativeRuntimeSession
                ? AppLocalization.string("Native session 已结束")
                : AppLocalization.string("会话已结束")
        case .idle:
            return sanitized(session.lastMessage) ?? (session.shouldHideProjectContextInUI ? nil : session.projectName)
        }
    }

    private func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private func perform(_ action: SessionListRowClickAction) {
        switch action {
        case .activate:
            onActivate()
        case .chat:
            onChat()
        case .toggleExpanded:
            onToggleExpanded()
        }
    }
}

enum SessionListRowClickAction: Equatable {
    case activate
    case chat
    case toggleExpanded
}

enum SessionListRowClickBehavior {
    nonisolated static func primaryTapAction(
        isMinimalCompactPresentation: Bool
    ) -> SessionListRowClickAction {
        isMinimalCompactPresentation ? .toggleExpanded : .activate
    }

    nonisolated static func doubleTapAction(
        needsInAppResponse: Bool
    ) -> SessionListRowClickAction {
        needsInAppResponse ? .chat : .activate
    }
}

private struct QueuePreviewLine: Identifiable {
    let id: String
    let prefix: String?
    let prefixColor: Color
    let text: String
    let textColor: Color
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let sessionAction: SessionScopedApprovalAction?
    let onChat: () -> Void
    let onApprove: () -> Void
    let onApproveForSession: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var showSessionButton = false

    var body: some View {
        HStack(spacing: 5) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text(AppLocalization.string("Deny"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            if let sessionAction {
                Button {
                    onApproveForSession()
                } label: {
                    Text(AppLocalization.string(sessionAction.compactButtonTitleKey))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TerminalColors.blue.opacity(0.24))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showSessionButton ? 1 : 0)
                .scaleEffect(showSessionButton ? 1 : 0.8)
            }

            Button {
                onApprove()
            } label: {
                Text(AppLocalization.string("Allow"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showSessionButton = sessionAction != nil
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Localization Helper

private func formattedTime(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func localizedOrOriginal(_ text: String?) -> String? {
    guard let text else { return nil }
    switch text {
    case "Agent has completed the task":
        return "Agent 已完成任务"
    case "Task completed":
        return "任务已完成"
    case "Task finished":
        return "任务已完成"
    case "Task completed successfully":
        return "任务已成功完成"
    case "Subagent completed":
        return "子代理已完成"
    case "Subagent finished":
        return "子代理已完成"
    case "Task started":
        return "任务已开始"
    case "Task was interrupted":
        return "任务已中断"
    case "Task was cancelled":
        return "任务已取消"
    case "Task was stopped":
        return "任务已停止"
    case "Agent has finished":
        return "Agent 已完成"
    case "Agent completed":
        return "Agent 已完成"
    default:
        return text
    }
}
