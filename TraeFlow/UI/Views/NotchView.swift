//
//  NotchView.swift
//  TraeFlow
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

/// Keeps the compact center message slightly narrower than the full center slot
/// so the closed notch matches the tighter visual balance used elsewhere.
private let compactCenterContentInset: CGFloat = 14
private let minimumClosedNotchFullContentWidth: CGFloat = 96

struct OpenedPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    private static let temporaryReminderMuteDuration: TimeInterval = 10 * 60
    private static let startupDetachmentHintDelay: TimeInterval = 1.8
    private static let detachmentHintRetryDelay: TimeInterval = 0.75

    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var customAreaStore = CustomAreaStore.shared
    // Spec: 观察 CustomAreaHintStore —— 自定义 HTML 通过 JS Bridge 推送提示时
    // 紧凑态左半区需立即切换到提示视图，提示到期后回退到 WebView
    @ObservedObject private var hintStore = CustomAreaHintStore.shared
    // Spec: 紧凑态左半区根据 LeftFeatureStore.compactFeature 分发到对应功能视图
    @ObservedObject private var leftFeatureStore = LeftFeatureStore.shared
    // Spec: 观察 NowPlayingProvider —— `compactFeature` 自动规则依赖 `nowPlaying.isPlaying`，
    // 播放状态变化时需重新渲染紧凑态左半区（决定是否切到音乐视图）
    @ObservedObject private var nowPlayingProvider = NowPlayingProvider.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var manualAttentionTracker = SessionManualAttentionTracker()
    @State private var previousCompletedReadyIds: Set<String> = []
    @State private var completionReadyTimestamps: [String: Date] = [:]
    @State private var taskErrorTimestamps: [String: Date] = [:]
    @State private var isAppActive: Bool = NSApp.isActive
    // Flow 岛固定展示：启动时即应为可见状态，避免窗口已 orderFront 但 SwiftUI
    // 内容因初始 opacity 为 0 而需要等待 .onAppear 或一次点击后才渲染。
    @State private var isVisible: Bool = true
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var hasPrimedSoundTransitions: Bool = false
    @State private var previousProcessingIds: Set<String> = []
    @State private var previousAttentionSoundIds: Set<String> = []
    @State private var previousCompletionSoundIds: Set<String> = []
    @State private var previousTaskErrorIds: Set<String> = []
    @State private var previousResourceLimitIds: Set<String> = []
    @State private var previousCompletionNotificationPhases: [String: SessionPhase] = [:]
    @State private var completionNotificationQueue: [SessionCompletionNotification] = []
    @State private var activeCompletionNotification: SessionCompletionNotification?
    @State private var completionNotificationDismissWorkItem: DispatchWorkItem?
    @State private var shouldDismissCompletionNotificationOnHoverExit: Bool = false
    @State private var isShowingDetachmentHint: Bool = false
    @State private var detachmentHintDismissWorkItem: DispatchWorkItem?
    @State private var detachmentHintPresentationWorkItem: DispatchWorkItem?
    /// 屏幕切换后滑块从顶部向下动画的 Y 偏移。初始值为负将内容推到屏幕上方不可见区域，
    /// OnAppear 时通过 spring 动画回 0 实现下滑效果。
    @State private var slideFromTopOffset: CGFloat = -150
    @State private var hasHandledSlideIn = false

    @Namespace private var activityNamespace

    private let petIconSize: CGFloat = 16

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.needsApprovalResponse }
    }

    /// Whether any session needs explicit human intervention (for example multi-choice questions).
    private var hasHumanIntervention: Bool {
        sessionMonitor.instances.contains {
            $0.phase == .waitingForInput && $0.intervention != nil
        }
    }

    /// Whether any session requires a user decision right now.
    private var hasManualAttentionIndicator: Bool {
        sessionMonitor.instances.contains {
            $0.needsPromptNotification
        }
    }

    private var activeSessions: [SessionState] {
        sessionMonitor.instances.filter(\.phase.isActive)
    }

    private var countedClosedSessions: [SessionState] {
        sessionMonitor.instances.filter { session in
            session.phase.isActive || session.phase.needsAttention
        }
    }

    private var activeSessionCount: Int {
        countedClosedSessions.count
    }

    private var shouldHideForIdleState: Bool {
        settings.autoHideWhenIdle
            && activeSessions.isEmpty
            && !hasPendingPermission
            && !hasHumanIntervention
            && !hasCompletedReadyState
            && activeCompletionNotification == nil
    }

    /// Most recently active live session that has a hook message we can surface in the compact notch.
    private var latestHookMessageSession: SessionState? {
        latestHookMessageSession(from: sessionMonitor.instances)
    }

    private var closedCenterMessage: String? {
        guard settings.notchDisplayMode == .detailed else { return nil }
        return latestHookMessageSession?.compactHookMessage
    }

    /// Whether any tracked session completed and is ready for the user to continue.
    private var hasCompletedReadyState: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = completionReadyTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    private var closedIndicatorTone: NotchIndicatorTone {
        if hasHumanIntervention {
            return .intervention
        }
        if hasPendingPermission {
            return .warning
        }
        return .normal
    }

    private var representativeClosedSession: SessionState? {
        if let attention = sessionMonitor.instances
            .filter({ $0.needsManualAttention })
            .sorted(by: { ($0.attentionRequestedAt ?? $0.lastActivity) > ($1.attentionRequestedAt ?? $1.lastActivity) })
            .first {
            return attention
        }

        if let active = sessionMonitor.instances
            .filter({ $0.phase.isActive })
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first {
            return active
        }

        return sessionMonitor.instances
            .sorted(by: { $0.lastActivity > $1.lastActivity })
            .first
    }

    private var preferredShortcutSession: SessionState? {
        representativeClosedSession ?? latestHookMessageSession
    }

    private var closedMascotKind: MascotKind {
        settings.mascotKind(for: latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient)
    }

    private var completionNotificationMascotKind: MascotKind {
        let client = activeCompletionNotification?.session.mascotClient
            ?? latestMascotSourceSession(from: sessionMonitor.instances)?.mascotClient
        return settings.mascotKind(for: client)
    }

    private var areReminderNotificationsSuppressed: Bool {
        settings.areNotificationsMutedTemporarily
    }

    private var hasRecentTaskError: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30
        return taskErrorTimestamps.values.contains { now.timeIntervalSince($0) < displayDuration }
    }

    private var closedMascotStatus: MascotStatus {
        if viewModel.isDetachmentGestureActive {
            return .dragging
        }
        return MascotStatus.closedNotchStatus(
            representativePhase: representativeClosedSession?.phase,
            hasPendingPermission: hasPendingPermission,
            hasHumanIntervention: hasHumanIntervention,
            hasCompletedReady: hasCompletedReadyState,
            hasRecentTaskError: hasRecentTaskError,
            isAppActive: isAppActive
        )
    }

    private func latestHookMessageSession(from instances: [SessionState]) -> SessionState? {
        instances
            .filter { $0.phase != .ended && $0.compactHookMessage != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private func latestMascotSourceSession(from instances: [SessionState]) -> SessionState? {
        IslandMascotResolver.sourceSession(from: instances)
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        viewModel.closedSize
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width
    }

    private var closedInnerWidth: CGFloat {
        max(0, closedContentWidth - (cornerRadiusInsets.closed.bottom * 2))
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        instrumentedBody
    }

    private var presentedBody: some View {
        bodyContent
            .offset(y: viewModel.closedPresentationOffsetY + slideFromTopOffset)
            .opacity(isVisible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }

    private var lifecycleBody: some View {
        presentedBody
            .onAppear {
                if !SessionMonitor.isRunningUnderXCTest {
                    sessionMonitor.startMonitoring()
                }
                viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)
                isVisible = !viewModel.shouldHideWindowPresentation
                viewModel.setManualAttentionActive(hasManualAttentionIndicator)
                handleProcessingChange()
                primeStartupPresentationState(sessionMonitor.instances)
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.startupDetachmentHintDelay)
                registerAppActiveNotifications()
                handleSlideInAnimation()
            }
            .onDisappear {
                cancelScheduledDetachmentHintPresentation()
                unregisterAppActiveNotifications()
            }
            .onChange(of: viewModel.status) { oldStatus, newStatus in
                handleStatusChange(from: oldStatus, to: newStatus)
            }
    }

    // MARK: - App Active State

    private func registerAppActiveNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            isAppActive = true
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            isAppActive = false
        }
    }

    private func unregisterAppActiveNotifications() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    }

    private var settingsAwareBody: some View {
        lifecycleBody
            .onChange(of: settings.autoOpenCompletionPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .completed || $0 == .ended },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.autoOpenCompactedNotificationPanel) { _, isEnabled in
                if !isEnabled {
                    removeCompletionNotifications(
                        matching: { $0 == .compacted },
                        keepPanelOpen: true
                    )
                } else {
                    maybePresentNextCompletionNotification()
                }
            }
            .onChange(of: settings.temporarilyMuteNotificationsUntil) { _, mutedUntil in
                guard AppSettings.isNotificationMuteActive(until: mutedUntil) else { return }
                clearCompletionNotifications(keepPanelOpen: true)
                if viewModel.openReason == .notification {
                    viewModel.exitChat()
                }
            }
            .onChange(of: settings.autoHideWhenIdle) { _, _ in
                handleProcessingChange()
            }
    }

    private var contentTypeAwareBody: some View {
        settingsAwareBody
            .onChange(of: viewModel.contentType.id) { _, _ in
                maybePresentNextCompletionNotification()
            }
            .onReceive(sessionMonitor.$pendingInstances) { sessions in
                handlePendingSessionsChange(sessions)
            }
            .onReceive(sessionMonitor.$instances) { instances in
                viewModel.setManualAttentionActive(
                    instances.contains { $0.needsPromptNotification }
                )
                handleProcessingChange()
                handleSessionSoundTransitions(instances)
                handleManualAttentionChange(instances)
                handleCompletedReadyChange(instances)
                handleCompletionNotificationChange(instances)
            }
    }

    private var visibilityAwareBody: some View {
        contentTypeAwareBody
            .onChange(of: viewModel.isFullscreenEdgeRevealActive) { _, isActive in
                if isActive && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isFullscreenBrowserHiddenActive) { _, isActive in
                if isActive {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isIdleAutoHiddenActive) { _, isHidden in
                if isHidden && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isQuietBackgroundPresentationActive) { _, isActive in
                if isActive && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleProcessingChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.presentationMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: viewModel.isFullscreenPhysicalNotchCompactActive) { _, isActive in
                if !isActive {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: settings.surfaceMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: settings.notchDetachmentHintPending) { _, isPending in
                if isPending {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                } else {
                    cancelScheduledDetachmentHintPresentation()
                }
            }
    }

    private var shortcutAwareBody: some View {
        visibilityAwareBody
            .onReceive(NotificationCenter.default.publisher(for: .traeFlowOpenActiveSessionShortcut)) { _ in
                handleOpenActiveSessionShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .traeFlowOpenSessionListShortcut)) { _ in
                handleOpenSessionListShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .traeFlowPresentNotchDetachmentHint)) { _ in
                presentDetachmentHintIfNeeded(force: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .traeFlowHookWalkthroughDemoShouldCloseNotch)) { _ in
                closeDockedNotchForHookWalkthroughDemo()
            }
            .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
                guard viewModel.status == .opened else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                    return
                }

                if case .instances = viewModel.contentType {
                    let effectiveHeight = activeCompletionNotification == nil
                        ? height
                        : max(height, SessionCompletionNotificationView.minimumContentHeight)
                    let measuredHeight = height > 0
                        ? closedNotchSize.height + effectiveHeight + 12
                        : nil
                    viewModel.updateOpenedMeasuredHeight(measuredHeight)
                } else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                }
            }
    }

    private func closeDockedNotchForHookWalkthroughDemo() {
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .opened else { return }

        withAnimation(viewModel.animation) {
            viewModel.notchClose()
        }
    }

    private var instrumentedBody: some View {
        shortcutAwareBody
    }

    private var bodyContent: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                styledNotchLayout
            }

            if isShowingDetachmentHint {
                NotchDetachmentHintView()
                    .offset(x: -22, y: 28)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                            removal: .opacity.animation(.easeOut(duration: 0.18))
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var styledNotchLayout: some View {
        let isOpened = viewModel.status == .opened
        let horizontalInset = isOpened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.bottom
        let shadowColor = (isOpened || isHovering) ? Color.black.opacity(0.7) : .clear

        return notchLayout
            .frame(maxWidth: isOpened ? notchSize.width : nil, alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding([.horizontal, .bottom], isOpened ? 12 : 0)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .overlay {
                if isOpened && viewModel.contentType == .customExpanded {
                    panelResizeEdges
                }
            }
            .shadow(color: shadowColor, radius: 6)
            .frame(
                maxWidth: isOpened ? notchSize.width : nil,
                maxHeight: isOpened ? notchSize.height : nil,
                alignment: .top
            )
            .animation(isOpened ? openAnimation : closeAnimation, value: viewModel.status)
            // 手动拖拽调整展开尺寸时禁用弹簧动画，确保尺寸跟随手指/光标实时变化。
            .animation(viewModel.openedSizeOverride == nil ? viewModel.closedNotchResizeAnimation : .none, value: notchSize)
            .animation(.smooth, value: activityCoordinator.expandingActivity)
            .animation(.smooth, value: hasPendingPermission)
            .animation(.smooth, value: hasHumanIntervention)
            .animation(.smooth, value: hasCompletedReadyState)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasHumanIntervention || hasCompletedReadyState
    }

    /// Keep the closed notch footprint stable and always show the leading icon.
    private var showsClosedLeadingIcon: Bool {
        viewModel.status != .opened || showClosedActivity
    }

    /// In fullscreen on physical-notch displays, the closed state should visually
    /// collapse back to the native macOS notch with no Island content shown.
    private var shouldHideClosedContent: Bool {
        viewModel.usesPhysicalNotchClosedPresentation && viewModel.status != .opened
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains pet and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))
                .zIndex(1)

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24)
                    .frame(maxHeight: .infinity)
                    .zIndex(0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if shouldHideClosedContent {
                Color.clear
                    // Preserve the native-notch footprint without letting the
                    // empty closed state expand across the whole window.
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else if usesClosedIconOnlyLayout {
                closedIconOnlyContent
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else {
                HStack(spacing: 0) {
                    // Spec: 紧凑态左半区根据 LeftFeatureStore.compactFeature 分发到对应功能视图
                    // （音乐 / 中转站 / 自定义 HTML）；无功能时显示最小占位。
                    // 展开态不渲染左半区，由 contentView 中的 LeftFeatureContainerView 接管。
                    if viewModel.status != .opened {
                        compactLeftRegion
                            .frame(width: flowIslandLeftCompactWidth, height: settings.compactLeftHeight, alignment: .leading)
                            .clipped()
                    }

                    // Center content
                    if viewModel.status == .opened {
                        // Opened: show header content
                        openedHeaderContent
                    } else {
                        closedCenterContent
                    }

                    // Spec 2.3: Flow 岛右侧 — MascotView 宠物图标 + 活跃会话计数 badge
                    if viewModel.status != .opened {
                        closedRightMascotRegion
                            .frame(width: closedTrailingWidth, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var usesClosedIconOnlyLayout: Bool {
        viewModel.status != .opened
            && closedNotchSize.width < minimumClosedNotchFullContentWidth
    }

    @ViewBuilder
    private var closedIconOnlyContent: some View {
        ZStack {
            if hasManualAttentionIndicator {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: min(16, iconOnlySize), weight: .semibold))
                    .foregroundStyle(closedIndicatorTone.emphasisColor)
                    .accessibilityLabel("需要处理")
            } else if viewModel.presentationMode == .detached {
                // 宠物已分离到桌面：图标态仅保留占位以维持胶囊布局
                Color.clear
                    .frame(width: iconOnlySize, height: iconOnlySize)
            } else {
                MascotView(
                    kind: closedMascotKind,
                    status: closedMascotStatus,
                    size: iconOnlySize
                )
                .environment(\.mascotAnimationsIgnoreEnergyPolicy, true)
                .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var iconOnlySize: CGFloat {
        max(12, min(petIconSize, closedInnerWidth))
    }

    /// Spec 2.3: 关闭态右半区 — MascotView 宠物图标 + 活跃会话计数 badge。
    /// 参考原始 trae-flow 实现：右侧显示一个宠物/品牌图标和 pending 会话数。
    /// 当有手动关注事项时，在宠物右上角叠加铃铛徽章，但不替换宠物。
    @ViewBuilder
    private var closedRightMascotRegion: some View {
        let activeCount = countedClosedSessions.count

        HStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                if viewModel.presentationMode == .detached {
                    // 宠物已分离到桌面：保留占位以维持胶囊布局，仅隐藏宠物视觉
                    Color.clear
                        .frame(width: petIconSize, height: petIconSize)
                } else {
                    MascotView(
                        kind: closedMascotKind,
                        status: closedMascotStatus,
                        size: petIconSize
                    )
                    .environment(\.mascotAnimationsIgnoreEnergyPolicy, true)
                    .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
                }

                if hasManualAttentionIndicator {
                    BellIndicatorIcon(size: 8, color: closedIndicatorTone.emphasisColor)
                        .offset(x: 3, y: -3)
                }
            }

            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .accessibilityLabel("活跃会话 \(activeCount)")
            }
        }
        .padding(.trailing, 4)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    private var closedLeadingWidth: CGFloat {
        flowIslandLeftCompactWidth
    }

    /// Spec: Flow 岛左侧紧凑态宽度 —— 简化为两种模式：
    /// - 有 `compactFeature` 时占满"宠物/任务计数区左侧"剩余空间
    ///   （中间内容仅保留最小宽度以显示截断消息）
    /// - 无 `compactFeature` 时返回 8pt 占位，避免挤占中间内容
    /// - `usesClosedIconOnlyLayout`（极窄关闭态）时也返回 8pt
    private var flowIslandLeftCompactWidth: CGFloat {
        guard !usesClosedIconOnlyLayout else { return 8 }
        return leftFeatureStore.compactFeature != nil ? flowIslandLeftCompactAvailableWidth : 8
    }

    /// Spec: 紧凑态左半区可用宽度 —— 横向占满"宠物/任务计数区左侧"剩余空间，
    /// 中间内容（状态/计时器）保留最小宽度以显示截断消息。
    private var flowIslandLeftCompactAvailableWidth: CGFloat {
        let minimumCenterWidth: CGFloat = 80
        return max(0, closedInnerWidth - closedTrailingWidth - minimumCenterWidth)
    }

    /// Spec: 紧凑态左半区分发入口 —— 优先级：
    /// 1. `showCompactHintEnabled` 开启且 `CustomAreaHintStore` 有活跃提示 → 显示提示（覆盖原选中功能）
    /// 2. `compactFeature` 存在 → 渲染对应功能视图
    /// 3. 无功能 → `placeholderContent`
    /// 提示到期或被清除后自动回退到原选中功能，无需切换 `compactFeatureID`。
    @ViewBuilder
    private var compactLeftRegion: some View {
        if settings.showCompactHintEnabled, let hint = hintStore.mostRecentHint {
            let _ = NSLog("[traeFlowHint] compactLeftRegion 显示提示（覆盖原功能）text=\(hint.text)")
            CustomAreaHintCompactView(hint: hint)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .id(hint.id)
        } else if let feature = leftFeatureStore.compactFeature {
            compactFeatureView(for: feature)
        } else {
            placeholderContent
        }
    }

    /// Spec: 紧凑态左半区功能分发 —— 根据 `LeftFeatureKind` 渲染对应紧凑态视图。
    /// 自定义 HTML 区域若关联目录已被删除则回退到占位视图。
    @ViewBuilder
    private func compactFeatureView(for feature: LeftFeature) -> some View {
        switch feature.kind {
        case .music:
            MusicCompactView()
        case .shelf:
            ShelfCompactView()
        case .customArea(let areaID):
            if let area = customAreaStore.areas.first(where: { $0.id == areaID }) {
                CustomAreaWebView(source: .localArea(area))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                placeholderContent
            }
        case .webURL(let urlString):
            // Spec: 远程 URL 功能紧凑态 —— 构造 .remoteURL 源传入 CustomAreaWebView，
            // frame/clip 与 .customArea 分支保持一致（高度由父级 compactLeftHeight 约束）
            if let url = URL(string: urlString) {
                CustomAreaWebView(source: .remoteURL(url))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                placeholderContent
            }
        case .newsnow:
            NewsNowCompactView()
        }
    }

    /// Spec: 紧凑态左半区占位视图 —— 无 compactFeature 或关联目录缺失时使用。
    /// 仅返回 Color.clear，frame/padding 由调用方统一约束以避免重复包裹。
    @ViewBuilder
    private var placeholderContent: some View {
        Color.clear
    }

    private var closedTrailingWidth: CGFloat {
        sideWidth
    }

    private var closedCenterWidth: CGFloat {
        max(0, closedInnerWidth - closedLeadingWidth - closedTrailingWidth + (isBouncing ? 16 : 0))
    }

    private var compactCenterContentWidth: CGFloat {
        max(0, closedCenterWidth - compactCenterContentInset)
    }

    @ViewBuilder
    private var closedCenterContent: some View {
        HStack {
            if let message = closedCenterMessage {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(showClosedActivity ? 0.9 : 0.74))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 6)
                    .frame(width: compactCenterContentWidth, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityLabel("最新 hooks 消息")
            } else {
                // Preserve the compact notch footprint when there is no hook text to show.
                Color.clear
                    .frame(width: compactCenterContentWidth)
            }
        }
        .frame(width: closedCenterWidth, alignment: .center)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            // 展开态左上角功能切换栏：自定义内容展开时 & 任务列表展开时都显示，
            // 允许在这两种视图间通过点击功能图标快速切换。
            // 任务列表视图中所有图标显示为未选中态，点击后切到对应功能面板。
            if viewModel.contentType == .customExpanded || viewModel.contentType == .instances {
                LeftFeatureSwitcherBar(
                    onSelect: { _ in
                        viewModel.presentCustomExpanded(reason: .click)
                    },
                    showAllUnselected: viewModel.contentType == .instances
                )
            }

            Spacer()

            // 展开态顶部保留固定、声音、设置三个快捷按钮，
            // 自定义内容展开时额外显示"切换到任务列表"按钮。
            HStack(spacing: 8) {
                if viewModel.contentType == .customExpanded {
                    InstanceListToggleButton {
                        viewModel.presentSessionList(reason: .click)
                    }
                }

                NotchPanelPinButton(
                    isPinned: currentPanelPinned,
                    action: toggleKeepIslandOpen
                )

                NotchSoundToggleButton(
                    isOn: settings.soundEnabled,
                    action: { AppSettings.soundEnabled.toggle() }
                )

                NotchSettingsButton(
                    hasUnseenUpdate: updateManager.hasUnseenUpdate,
                    action: openSettingsWindow
                )
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        IslandOpenedContentView(
            sessionMonitor: sessionMonitor,
            viewModel: viewModel,
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            style: .docked,
            activeCompletionNotification: activeCompletionNotification,
            onAttentionActionCompleted: {},
            onCompletionNotificationHoverChanged: handleCompletionNotificationHover,
            onDismissCompletionNotification: {
                clearCompletionNotifications(keepPanelOpen: true)
            }
        )
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Panel Resize Corners

    /// 展开面板左下角/右下角的淡淡圆角拖拽指示器，覆盖在黑边区域上方。
    /// 拖拽时实时调整 `NotchViewModel.openedSizeOverride`，松手后写回当前功能的自定义尺寸。
    private var panelResizeEdges: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ResizeCornerHandle(anchor: .bottomLeading, viewModel: viewModel)
                    .frame(width: 28, height: 28)
                    .position(x: 14, y: size.height - 14)

                ResizeCornerHandle(anchor: .bottomTrailing, viewModel: viewModel)
                    .frame(width: 28, height: 28)
                    .position(x: size.width - 14, y: size.height - 14)
            }
        }
    }

    private var triggerForCurrentPresentation: IslandExpandedTrigger {
        switch viewModel.openReason {
        case .hover:
            return .hover
        case .notification:
            return .notification
        case .click, .boot, .unknown:
            return .click
        }
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)

        if viewModel.shouldHideWindowPresentation {
            isVisible = false
            return
        }

        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasHumanIntervention || hasCompletedReadyState {
            // Keep visible for attention/completion states but stop the active processing animation.
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()
            isVisible = true
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            cancelScheduledDetachmentHintPresentation()
            dismissDetachmentHint()
            if oldStatus != .opened, newStatus == .opened {
                recordIslandOpened()
            }
            // Clear completed-ready timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                completionReadyTimestamps.removeAll()
                clearCompletionNotifications(keepPanelOpen: true)
            }
        case .closed:
            if oldStatus == .opened {
                recordIslandClosed()
            }
            isVisible = !viewModel.shouldHideWindowPresentation
            maybePresentNextCompletionNotification()
            scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
        }
    }

    private func recordIslandOpened() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandOpened(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private func recordIslandClosed() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandClosed(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private var telemetryPresentationMode: String {
        switch viewModel.presentationMode {
        case .docked:
            return "docked"
        case .detached:
            return "detached"
        }
    }

    private func telemetryOpenSource(for reason: NotchOpenReason) -> String {
        switch reason {
        case .click:
            return "click"
        case .hover:
            return "hover"
        case .notification:
            return "notification"
        case .boot:
            return "boot"
        case .unknown:
            return "unknown"
        }
    }

    private func telemetryContentRoute(for contentType: NotchContentType) -> String {
        if activeCompletionNotification != nil {
            return "completion_notification"
        }
        if hasPendingPermission {
            return "approval"
        }
        if hasHumanIntervention {
            return "question"
        }

        switch contentType {
        case .instances:
            return "session_list"
        case .chat:
            return "session_detail"
        case .customExpanded:
            return "custom_expanded"
        }
    }

    private func scheduleDetachmentHintPresentationIfNeeded(force: Bool = false, delay: TimeInterval) {
        guard force || settings.notchDetachmentHintPending else {
            cancelScheduledDetachmentHintPresentation()
            return
        }

        detachmentHintPresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [force] in
            detachmentHintPresentationWorkItem = nil
            presentDetachmentHintIfNeeded(force: force)
        }
        detachmentHintPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledDetachmentHintPresentation() {
        detachmentHintPresentationWorkItem?.cancel()
        detachmentHintPresentationWorkItem = nil
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if areReminderNotificationsSuppressed {
            previousPendingIds = currentIds
            return
        }

        let shouldSuppressAutoOpen = settings.smartSuppression &&
            TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()

        if viewModel.shouldSuppressAutomaticPresentation {
            previousPendingIds = currentIds
            return
        }

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !shouldSuppressAutoOpen {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func primeStartupPresentationState(_ instances: [SessionState]) {
        previousPendingIds = Set(instances.filter(\.needsAttention).map(\.stableId))
        previousCompletedReadyIds = Set(
            instances
                .filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
                .map(\.stableId)
        )
        _ = manualAttentionTracker.consumeNewAttentionSession(from: instances)
        primeCompletionNotificationTracking(instances)
    }

    /// 屏幕切换重建窗口时，ViewModel 的 triggerScreenSlideIn 已被置为 true，
    /// 此处消费该标志并通过 spring 动画将 Flow 岛从屏幕上方滑入原位。
    private func handleSlideInAnimation() {
        guard !hasHandledSlideIn else { return }
        hasHandledSlideIn = true

        if viewModel.triggerScreenSlideIn {
            // 消费标志，避免后续状态刷新重复触发
            viewModel.triggerScreenSlideIn = false
            withAnimation(.easeOut(duration: 0.35)) {
                slideFromTopOffset = 0
            }
        } else {
            // 非屏幕切换场景（如首次启动），内容直接显示在正确位置
            slideFromTopOffset = 0
        }
    }

    private func presentDetachmentHintIfNeeded(force: Bool = false) {
        guard force || settings.notchDetachmentHintPending else { return }
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .closed else { return }
        guard !shouldHideClosedContent else { return }

        cancelScheduledDetachmentHintPresentation()
        settings.notchDetachmentHintPending = false
        detachmentHintDismissWorkItem?.cancel()

        if !isShowingDetachmentHint {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                isShowingDetachmentHint = true
            }
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingDetachmentHint = false
            }
        }
        detachmentHintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func dismissDetachmentHint() {
        detachmentHintDismissWorkItem?.cancel()
        detachmentHintDismissWorkItem = nil
        guard isShowingDetachmentHint else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingDetachmentHint = false
        }
    }

    private func handleManualAttentionChange(_ instances: [SessionState]) {
        guard let targetSession = manualAttentionTracker.consumeNewAttentionSession(from: instances) else {
            return
        }

        if areReminderNotificationsSuppressed {
            return
        }

        clearCompletionNotifications(keepPanelOpen: true)

        if viewModel.shouldSuppressAutomaticPresentation {
            return
        }

        if targetSession.needsPromptNotification {
            viewModel.presentNotificationAttention()
            return
        }

        viewModel.presentNotificationChat(for: targetSession)
    }

    private func handleCompletedReadyChange(_ instances: [SessionState]) {
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let completedIds = Set(completedSessions.map(\.stableId))
        let newCompletedIds = completedIds.subtracting(previousCompletedReadyIds)

        let now = Date()
        for session in completedSessions where newCompletedIds.contains(session.stableId) {
            completionReadyTimestamps[session.stableId] = now
        }

        let staleIds = Set(completionReadyTimestamps.keys).subtracting(completedIds)
        for staleId in staleIds {
            completionReadyTimestamps.removeValue(forKey: staleId)
        }
        previousCompletedReadyIds = completedIds

        if !newCompletedIds.isEmpty {
            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate the temporary completion badge.
                handleProcessingChange()
            }
        }
    }

    private func primeCompletionNotificationTracking(_ instances: [SessionState]) {
        previousCompletionNotificationPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )
        synchronizeCompletionNotifications(with: instances)
    }

    private func handleCompletionNotificationChange(_ instances: [SessionState]) {
        synchronizeCompletionNotifications(with: instances)

        if areReminderNotificationsSuppressed {
            if activeCompletionNotification != nil || !completionNotificationQueue.isEmpty {
                clearCompletionNotifications(keepPanelOpen: true)
            }

            previousCompletionNotificationPhases = Dictionary(
                uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
            )
            return
        }

        let currentPhases = Dictionary(
            uniqueKeysWithValues: instances.map { ($0.stableId, $0.phase) }
        )

        // Ambient popups are one-shot notifications. If the notch is already expanded for
        // some other reason, drop new ones instead of queueing them to appear later on
        // top of the normal expanded UI.
        if viewModel.status == .opened && activeCompletionNotification == nil {
            previousCompletionNotificationPhases = currentPhases
            completionNotificationQueue.removeAll()
            return
        }

        let newNotifications = instances
            .compactMap { session -> SessionCompletionNotification? in
                let previousPhase = previousCompletionNotificationPhases[session.stableId]

                if shouldQueueCompactedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .compacted)
                }

                if shouldQueueCompletedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .completed)
                }

                if shouldQueueEndedNotification(for: session, previousPhase: previousPhase) {
                    return SessionCompletionNotification(session: session, kind: .ended)
                }

                return nil
            }
            .sorted { $0.session.lastActivity < $1.session.lastActivity }

        for notification in newNotifications {
            enqueueCompletionNotification(notification)
        }

        previousCompletionNotificationPhases = currentPhases
        maybePresentNextCompletionNotification()
    }

    private func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompletionPanel
        )
    }

    private func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueEndedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompletionPanel
        )
    }

    private func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?
    ) -> Bool {
        SessionCompletionNotificationPolicy.shouldQueueCompactedNotification(
            for: session,
            previousPhase: previousPhase,
            isEnabled: settings.autoOpenCompactedNotificationPanel
        )
    }

    private func synchronizeCompletionNotifications(with instances: [SessionState]) {
        let sessionsById = Dictionary(uniqueKeysWithValues: instances.map { ($0.stableId, $0) })

        if let active = activeCompletionNotification {
            if let latest = sessionsById[active.session.stableId] {
                activeCompletionNotification?.session = latest
            } else {
                dismissActiveCompletionNotification(closePanel: false, advanceQueue: true)
            }
        }

        completionNotificationQueue = completionNotificationQueue.compactMap { notification in
            guard let latest = sessionsById[notification.session.stableId] else { return nil }
            var updated = notification
            updated.session = latest
            return updated
        }
    }

    private func enqueueCompletionNotification(_ notification: SessionCompletionNotification) {
        if let active = activeCompletionNotification,
           active.session.stableId == notification.session.stableId {
            activeCompletionNotification?.session = notification.session
            return
        }

        if let queuedIndex = completionNotificationQueue.firstIndex(where: {
            $0.session.stableId == notification.session.stableId
        }) {
            var updated = completionNotificationQueue[queuedIndex]
            updated.session = notification.session
            completionNotificationQueue[queuedIndex] = updated
            return
        }

        completionNotificationQueue.append(notification)
    }

    private func maybePresentNextCompletionNotification() {
        guard !areReminderNotificationsSuppressed else { return }
        guard activeCompletionNotification == nil else { return }
        guard !completionNotificationQueue.isEmpty else { return }
        guard !viewModel.shouldSuppressAutomaticPresentation else { return }
        guard !hasPendingPermission && !hasHumanIntervention else { return }
        guard case .instances = viewModel.contentType else { return }

        if viewModel.status == .opened && viewModel.openReason != .notification {
            return
        }

        let nextNotification = completionNotificationQueue.removeFirst()
        activeCompletionNotification = nextNotification
        shouldDismissCompletionNotificationOnHoverExit = false

        if viewModel.status != .opened || viewModel.openReason != .notification {
            viewModel.notchOpen(reason: .notification)
        }

        scheduleCompletionNotificationDismissal(for: nextNotification.id)
    }

    private func scheduleCompletionNotificationDismissal(for notificationID: UUID) {
        completionNotificationDismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [self] in
            guard activeCompletionNotification?.id == notificationID else { return }
            dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
        }

        completionNotificationDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func clearCompletionNotifications(keepPanelOpen: Bool) {
        removeCompletionNotifications(matching: { _ in true }, keepPanelOpen: keepPanelOpen)
    }

    private func removeCompletionNotifications(
        matching shouldRemove: (SessionCompletionNotification.Kind) -> Bool,
        keepPanelOpen: Bool
    ) {
        completionNotificationQueue.removeAll { shouldRemove($0.kind) }

        if let activeCompletionNotification, shouldRemove(activeCompletionNotification.kind) {
            dismissActiveCompletionNotification(closePanel: !keepPanelOpen, advanceQueue: true)
        }
    }

    private func handleCompletionNotificationHover(_ isHovering: Bool) {
        guard activeCompletionNotification != nil else {
            shouldDismissCompletionNotificationOnHoverExit = false
            return
        }

        if isHovering {
            shouldDismissCompletionNotificationOnHoverExit = true
            completionNotificationDismissWorkItem?.cancel()
            completionNotificationDismissWorkItem = nil
            return
        }

        guard shouldDismissCompletionNotificationOnHoverExit else { return }
        shouldDismissCompletionNotificationOnHoverExit = false
        dismissActiveCompletionNotification(closePanel: true, advanceQueue: true)
    }

    private func dismissActiveCompletionNotification(
        closePanel: Bool,
        advanceQueue: Bool
    ) {
        completionNotificationDismissWorkItem?.cancel()
        completionNotificationDismissWorkItem = nil
        shouldDismissCompletionNotificationOnHoverExit = false

        guard activeCompletionNotification != nil else {
            if advanceQueue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    maybePresentNextCompletionNotification()
                }
            }
            return
        }

        activeCompletionNotification = nil

        if closePanel,
           viewModel.status == .opened,
           viewModel.openReason == .notification,
           !hasPendingPermission,
           !hasHumanIntervention {
            viewModel.notchClose()
        }

        if advanceQueue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                maybePresentNextCompletionNotification()
            }
        }
    }

    private func handleSessionSoundTransitions(_ instances: [SessionState]) {
        if !hasPrimedSoundTransitions {
            previousProcessingIds = Set(
                instances
                    .filter(\.phase.contributesToProcessingSoundEdge)
                    .map(\.stableId)
            )
            previousAttentionSoundIds = Set(
                instances
                    .filter(SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge)
                    .map(\.stableId)
            )
            previousCompletionSoundIds = Set(
                instances
                    .filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
                    .map(\.stableId)
            )
            previousTaskErrorIds = Set(
                instances.flatMap { session in
                    session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
                }
            )
            previousResourceLimitIds = Set(
                instances
                    .filter { $0.phase == .compacting }
                    .map(\.stableId)
            )
            hasPrimedSoundTransitions = true
            return
        }

        let processingSessions = instances.filter(\.phase.contributesToProcessingSoundEdge)
        let attentionSessions = instances.filter(
            SessionAttentionSoundEvaluator.shouldContributeToAttentionSoundEdge
        )
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let resourceLimitedSessions = instances.filter {
            $0.phase == .compacting
        }

        let newProcessingIds = Set(processingSessions.map(\.stableId))
        let newAttentionIds = Set(attentionSessions.map(\.stableId))
        let newCompletedIds = Set(completedSessions.map(\.stableId))
        let newTaskErrorIds = Set(
            instances.flatMap { session in
                session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
            }
        )
        let newResourceLimitIds = Set(resourceLimitedSessions.map(\.stableId))
        let errorDeltaIds = newTaskErrorIds.subtracting(previousTaskErrorIds)
        let errorSessions = instances.filter { session in
            session.completedErrorToolIDs.contains { errorDeltaIds.contains("\(session.sessionId):\($0)") }
        }
        let completionDeltaIds = newCompletedIds.subtracting(previousCompletionSoundIds)
        let newlyCompletedSessions = completedSessions.filter { session in
            completionDeltaIds.contains(session.stableId)
        }

        let isNewAttention = !newAttentionIds.subtracting(previousAttentionSoundIds).isEmpty
        let isNewCompletion = !completionDeltaIds.isEmpty
        let isNewTaskError = !errorDeltaIds.isEmpty
        let isNewResourceLimit = !newResourceLimitIds.subtracting(previousResourceLimitIds).isEmpty

        updateTaskErrorTimestamps(errorDeltaIds: errorDeltaIds)

        if isNewTaskError {
            playEventSoundIfNeeded(.taskError, sessions: errorSessions)
        } else if isNewResourceLimit {
            playEventSoundIfNeeded(.resourceLimit, sessions: resourceLimitedSessions)
        } else if isNewAttention {
            playEventSoundIfNeeded(.attentionRequired, sessions: attentionSessions)
        } else if isNewCompletion {
            playEventSoundIfNeeded(.taskCompleted, sessions: newlyCompletedSessions)
        } else if !newProcessingIds.subtracting(previousProcessingIds).isEmpty {
            playEventSoundIfNeeded(.processingStarted, sessions: processingSessions)
        }

        previousProcessingIds = newProcessingIds
        previousAttentionSoundIds = newAttentionIds
        previousCompletionSoundIds = newCompletedIds
        previousTaskErrorIds = newTaskErrorIds
        previousResourceLimitIds = newResourceLimitIds
    }

    private func updateTaskErrorTimestamps(errorDeltaIds: Set<String>) {
        let now = Date()
        let displayDuration: TimeInterval = 30

        for errorId in errorDeltaIds {
            taskErrorTimestamps[errorId] = now
        }

        taskErrorTimestamps = taskErrorTimestamps.filter { _, timestamp in
            now.timeIntervalSince(timestamp) < displayDuration
        }
    }

    private func playEventSoundIfNeeded(_ event: NotificationEvent, sessions: [SessionState]) {
        guard AppSettings.soundEnabled else { return }

        Task {
            let shouldPlaySound = await shouldPlayNotificationSound(for: sessions)
            if shouldPlaySound {
                _ = await MainActor.run {
                    AppSettings.playSound(for: event)
                }
            }
        }
    }

    private func openSettingsWindow() {
        updateManager.markUpdateSeen()
        SettingsWindowController.shared.present()
    }

    private func handleOpenActiveSessionShortcut() {
        guard let session = preferredShortcutSession else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleChat(for: session, reason: .click)
    }

    private func handleOpenSessionListShortcut() {
        NSApp.activate(ignoringOtherApps: true)
        viewModel.toggleSessionList(reason: .click)
    }

    private func activateTemporaryReminderMute() {
        if areReminderNotificationsSuppressed {
            AppSettings.clearReminderNotificationMute()
        } else {
            AppSettings.muteReminderNotifications(for: Self.temporaryReminderMuteDuration)
            clearCompletionNotifications(keepPanelOpen: true)

            if viewModel.openReason == .notification {
                viewModel.exitChat()
            }
        }
    }

    /// 当前面板固定状态：若当前激活功能设置了 `expandedPinned` 则视为已固定，否则跟随全局 `keepIslandOpen`
    private var currentPanelPinned: Bool {
        if let feature = leftFeatureStore.expandedActiveFeature, feature.expandedPinned {
            return true
        }
        return settings.keepIslandOpen
    }

    /// 切换面板固定状态：
    /// - 若当前激活功能设置了 `expandedPinned`，点击 unpin 时清除该字段（用户主动取消固定）
    /// - 否则切换全局 `keepIslandOpen`
    private func toggleKeepIslandOpen() {
        if let feature = leftFeatureStore.expandedActiveFeature, feature.expandedPinned {
            leftFeatureStore.setExpandedPinned(id: feature.id, pinned: false)
            return
        }
        AppSettings.keepIslandOpen.toggle()
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}

private struct NotchDetachmentHintView: View {
    @State private var isArrowNudging = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StraightDetachHintArrow()
                .stroke(
                    Color.white.opacity(0.86),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 76, height: 40)
                .offset(
                    x: -36 + (isArrowNudging ? -4 : 4),
                    y: 2 + (isArrowNudging ? -3 : 3)
                )
                .onAppear {
                    isArrowNudging = false
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isArrowNudging = true
                    }
                }
                .onDisappear {
                    isArrowNudging = false
                }

            Text(appLocalized: "拖动宠物，让宠物离岛工作")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.96))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
                .offset(y: 62)
        }
        .frame(width: 242, height: 118, alignment: .topTrailing)
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.string("拖动宠物，让宠物离岛工作")))
    }
}

private struct StraightDetachHintArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.maxX - 14, y: rect.maxY - 14)
        let end = CGPoint(x: rect.minX + 14, y: rect.minY + 16)

        path.move(to: start)
        path.addQuadCurve(
            to: end,
            control: CGPoint(x: rect.midX + 4, y: rect.midY + 6)
        )

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 12, y: end.y - 2))

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 6, y: end.y + 11))

        return path
    }
}

private struct NotchSettingsButton: View {
    let hasUnseenUpdate: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? .black : .white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                    )

                if hasUnseenUpdate {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black, lineWidth: 1.5)
                        )
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

/// 展开态头部固定按钮：点击切换面板固定状态，
/// 固定后 hover 离开不再自动收起、低功耗/空闲策略也不再隐藏面板。
private struct NotchPanelPinButton: View {
    let isPinned: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: isPinned ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "取消固定" : "固定面板")
        .accessibilityLabel(isPinned ? "取消固定" : "固定面板")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconForegroundStyle: AnyShapeStyle {
        // 固定按钮开启后使用与声音/设置按钮一致的样式：
        // 非 hover 白字透明底，hover 黑字白底。
        AnyShapeStyle(isHovering ? Color.black : Color.white.opacity(0.92))
    }

    private var backgroundFillColor: Color {
        isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }

    private var borderColor: Color {
        .clear
    }
}

/// 展开态头部"切换到任务列表"按钮：自定义内容面板右上角入口，点击回到任务列表。
private struct InstanceListToggleButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFillColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("任务列表")
        .accessibilityLabel("任务列表")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconForegroundStyle: AnyShapeStyle {
        AnyShapeStyle(isHovering ? Color.black : Color.white.opacity(0.92))
    }

    private var backgroundFillColor: Color {
        isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
    }
}

/// 展开态头部声音开关按钮：绑定设置里的 soundEnabled，控制所有提示音是否播放。
private struct NotchSoundToggleButton: View {
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconForegroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundFillColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "关闭声音" : "开启声音")
        .accessibilityLabel(isOn ? "关闭声音" : "开启声音")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var iconForegroundStyle: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(isHovering ? Color.black : Color.white.opacity(0.92))
        }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.8 : 0.6))
    }

    private var backgroundFillColor: Color {
        if isOn {
            return isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1)
        }
        return Color.white.opacity(isHovering ? 0.12 : 0.06)
    }
}

private struct SessionCountIndicator: View {
    let count: Int
    private let closedNotchRightShift: CGFloat = 4

    var body: some View {
        PixelNumberView(
            value: count,
            color: .white.opacity(0.92),
            fontSize: count >= 10 ? 8.8 : 9.6,
            weight: .semibold,
            tracking: count >= 10 ? -0.15 : -0.05
        )
        .frame(minWidth: 18)
        .offset(x: closedNotchRightShift)
    }
}

// MARK: - Panel Resize Corner Handle

/// 展开面板左下角/右下角的圆角拖拽指示器。显示淡淡的四分之一圆角，
/// 拖拽时通过 `NotchViewModel.openedSizeOverride` 实时预览尺寸，拖拽结束时将尺寸持久化到
/// `LeftFeatureStore` 当前功能的 `expandedWidth` / `expandedHeight`。
private struct ResizeCornerHandle: View {
    enum Anchor {
        case bottomLeading
        case bottomTrailing
    }

    let anchor: Anchor
    @ObservedObject var viewModel: NotchViewModel

    @ObservedObject private var featureStore = LeftFeatureStore.shared
    @State private var startSize: CGSize = .zero
    @State private var isDragging: Bool = false

    private var isLeading: Bool { anchor == .bottomLeading }
    private var currentFeature: LeftFeature? { featureStore.expandedActiveFeature }

    var body: some View {
        ZStack {
            ResizeCornerIndicator(anchor: anchor)
                .fill(Color.white.opacity(0.16))
                .frame(width: 18, height: 18)

            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    startSize = viewModel.openedSize
                    viewModel.setResizingOpenedPanel(true)
                }

                let widthDelta = isLeading ? -value.translation.width : value.translation.width
                let heightDelta = value.translation.height
                let next = CGSize(
                    width: startSize.width + widthDelta,
                    height: startSize.height + heightDelta
                )
                viewModel.setOpenedSizeOverride(clampedSize(next))
            }
            .onEnded { _ in
                let finalSize = viewModel.openedSizeOverride ?? viewModel.openedSize
                persistSize(finalSize)
                startSize = .zero
                isDragging = false
                viewModel.setOpenedSizeOverride(nil)
                viewModel.setResizingOpenedPanel(false)
            }
    }

    private func clampedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, 200), viewModel.screenRect.width - 64),
            height: min(max(size.height, 120), viewModel.screenRect.height - 120)
        )
    }

    private func persistSize(_ size: CGSize) {
        guard let feature = currentFeature else { return }

        let globalWidth = CGFloat(AppSettings.expandedPanelWidth)
        let globalHeight = CGFloat(AppSettings.maxPanelHeight)

        let width: Double? = abs(size.width - globalWidth) > 0.5 ? Double(size.width) : nil
        let height: Double? = abs(size.height - globalHeight) > 0.5 ? Double(size.height) : nil

        featureStore.setExpandedSize(id: feature.id, width: width, height: height)
    }
}

/// 左下角/右下角四分之一圆角指示器。
private struct ResizeCornerIndicator: Shape {
    let anchor: ResizeCornerHandle.Anchor

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height)

        switch anchor {
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addArc(
                center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(
                center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }

        return path
    }
}
