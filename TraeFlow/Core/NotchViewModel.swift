//
//  NotchViewModel.swift
//  TraeFlow
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)
    /// Spec 2.4: 展开态自定义内容全屏面板，由点击 Flow 岛左半区触发
    case customExpanded

    var id: String {
        switch self {
        case .instances: return "instances"
        case .chat(let session): return "chat-\(session.sessionId)"
        case .customExpanded: return "customExpanded"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published private(set) var presentationMode: IslandPresentationMode = .docked
    @Published private(set) var detachedDisplayMode: DetachedIslandDisplayMode = .compact
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published private(set) var openedMeasuredHeight: CGFloat?
    /// 分离态专用内容类型，与 docked 的 contentType 完全解耦，
    /// 避免 detach 腐蚀 docked Flow 岛的会话/内容状态。
    @Published private(set) var detachedContentType: NotchContentType = .instances
    /// 分离态专用测量高度，与 docked 的 openedMeasuredHeight 解耦。
    @Published private(set) var detachedOpenedMeasuredHeight: CGFloat?
    @Published private(set) var isFullscreenEdgeRevealActive = false
    @Published private(set) var isFullscreenPhysicalNotchCompactActive = false
    @Published private(set) var isFullscreenBrowserHiddenActive = false
    @Published private(set) var isIdleAutoHiddenActive = false
    @Published private(set) var isQuietBackgroundPresentationActive = false
    @Published private(set) var isSettingsPopoverPresented = false
    @Published private(set) var isInlineTextInputActive = false
    /// 屏幕切换后触发滑块从顶部向下动画的标志，由 IslandPresentationCoordinator 设置，NotchView 消费后复位
    @Published var triggerScreenSlideIn = false

    // MARK: - Geometry

    @Published private(set) var geometry: NotchGeometry
    let spacing: CGFloat = 12
    @Published private(set) var hasPhysicalNotch: Bool

    private static let defaultClosedHeight = ScreenNotchMetrics.fallbackClosedHeight
    /// 任务列表点击展开时的面板最大宽度比例（仅受屏幕限制，不跟随面板宽度设置）
    private static let clickedInstancesPanelWidthRatio: CGFloat = 0.6
    private static let clickedInstancesPanelMaximumWidth: CGFloat = 700
    private static let detachmentLongPressNarrowedWidthScale: CGFloat = 0.82
    private static let detachmentLongPressMaximumShrink: CGFloat = 56
    @Published private(set) var closedWidth: CGFloat

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    var closedHeight: CGFloat {
        usesPhysicalNotchClosedPresentation
            ? deviceNotchRect.height
            : detectedClosedHeight
    }
    var usesPhysicalNotchClosedPresentation: Bool {
        hasPhysicalNotch && isFullscreenPhysicalNotchCompactActive
    }
    var closedSize: CGSize {
        if usesPhysicalNotchClosedPresentation {
            return deviceNotchRect.size
        }
        // Spec: 紧凑态左半区高度可配置（Settings.compactLeftHeight），Flow 岛整体高度跟随
        // 该值动态扩展以容纳更高的自定义 HTML 内容（如歌词）。取 max 确保不会因
        // compactLeftHeight 小于原默认高度而缩小 Flow 岛。
        let height = max(closedHeight, AppSettings.compactLeftHeight)
        return CGSize(width: closedWidth, height: height)
    }
    var closedScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - closedSize.width / 2,
            y: screenRect.maxY - closedSize.height,
            width: closedSize.width,
            height: closedSize.height
        )
    }

    private var detectedClosedHeight: CGFloat {
        guard hasPhysicalNotch else { return Self.defaultClosedHeight }
        let systemHeight = ceil(deviceNotchRect.height)
        return systemHeight > 0 ? systemHeight : Self.defaultClosedHeight
    }

    private func resolvedClosedWidth(preferredModuleWidthOverride: CGFloat? = nil) -> CGFloat {
        preferredModuleWidthOverride ?? preferredModuleWidth
    }

    private var preferredModuleWidth: CGFloat {
        CGFloat(AppSettingsStore.normalizedNotchModuleWidth(notchModuleWidthProvider()))
    }

    static func shouldAutoCollapseHoverPreview(
        isHovering: Bool,
        status: NotchStatus,
        openReason: NotchOpenReason,
        isSettingsPopoverPresented: Bool,
        isInlineTextInputActive: Bool,
        autoCollapseOnLeave: Bool,
        keepIslandOpen: Bool = false
    ) -> Bool {
        !isHovering
            && status == .opened
            && openReason == .hover
            && !isSettingsPopoverPresented
            && !isInlineTextInputActive
            && autoCollapseOnLeave
            && !keepIslandOpen
    }

    private func narrowedClosedWidth(for baseWidth: CGFloat) -> CGFloat {
        return max(
            CGFloat(AppSettingsStore.minimumNotchModuleWidth),
            baseWidth * Self.detachmentLongPressNarrowedWidthScale,
            baseWidth - Self.detachmentLongPressMaximumShrink
        )
    }

    private func dockedClosedWidthTarget(preferredModuleWidthOverride: CGFloat? = nil) -> CGFloat {
        let baseWidth = resolvedClosedWidth(preferredModuleWidthOverride: preferredModuleWidthOverride)
        guard presentationMode == .docked, detachmentTracking != nil else {
            return baseWidth
        }
        return narrowedClosedWidth(for: baseWidth)
    }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        panelSize(for: .docked)
    }

    var detachedSize: CGSize {
        switch detachedDisplayMode {
        case .compact:
            return compactDetachedSize
        case .hoverExpanded:
            return expandedDetachedSize
        }
    }

    func panelSize(for style: IslandOpenedPresentationStyle) -> CGSize {
        let maxAllowedHeight = maximumOpenedHeight

        // 读取当前激活功能的 per-feature 展开尺寸覆盖（nil = 跟随全局）
        let activeFeature = LeftFeatureStore.shared.expandedActiveFeature
        let featureWidth: Double = activeFeature?.expandedWidth ?? AppSettings.expandedPanelWidth
        let featureHeight: Double = activeFeature?.expandedHeight ?? AppSettings.maxPanelHeight
        let resolvedMaxHeight: CGFloat = min(maxAllowedHeight, CGFloat(featureHeight))

        // docked 与 detached 使用各自的内容类型与测量高度，互不腐蚀
        let resolvedContentType: NotchContentType = style == .detached ? detachedContentType : contentType
        let resolvedOpenReason: NotchOpenReason = style == .detached ? .click : openReason
        let resolvedMeasuredHeight: CGFloat? = style == .detached ? detachedOpenedMeasuredHeight : openedMeasuredHeight

        switch resolvedContentType {
        case .chat, .customExpanded:
            // Spec 2.4: 自定义内容全屏面板采用与会话详情一致的尺寸
            switch style {
            case .docked:
                return CGSize(
                    width: min(screenRect.width - 64, CGFloat(featureWidth)),
                    height: resolvedMaxHeight
                )
            case .detached:
                return CGSize(
                    width: min(screenRect.width - 96, CGFloat(featureWidth)),
                    height: min(resolvedMaxHeight, screenRect.height - 180)
                )
            }
        case .instances:
            let fallbackHeight: CGFloat = resolvedOpenReason == .hover ? 150 : 170
            let measuredHeight = resolvedMeasuredHeight ?? fallbackHeight

            switch style {
            case .docked:
                return CGSize(
                    width: resolvedOpenReason == .hover
                        ? min(screenRect.width - 64, 600)
                        : min(
                            screenRect.width * Self.clickedInstancesPanelWidthRatio,
                            Self.clickedInstancesPanelMaximumWidth
                        ),
                    // 任务列表高度仅受屏幕限制，不跟随面板高度设置；
                    // 实际高度由内容测量驱动（OpenedPanelContentHeightPreferenceKey）。
                    height: min(screenRect.height - 120, max(closedHeight + 24, measuredHeight))
                )
            case .detached:
                return CGSize(
                    width: min(screenRect.width - 112, 600),
                    height: min(
                        screenRect.height - 180,
                        max(closedHeight + 24, min(measuredHeight, 400))
                    )
                )
            }
        }
    }

    private var compactDetachedSize: CGSize {
        if AppSettings.notchDisplayMode == .detailed {
            return closedSize
        }

        let orbEdge = max(closedSize.height, 40)
        return CGSize(width: orbEdge, height: orbEdge)
    }

    private var expandedDetachedSize: CGSize {
        let maxAllowedHeight = maximumOpenedHeight
        let fallbackHeight: CGFloat = 220

        return CGSize(
            width: min(screenRect.width - 112, CGFloat(AppSettings.expandedPanelWidth)),
            height: min(maxAllowedHeight, max(closedHeight + 24, fallbackHeight))
        )
    }

    private var maximumOpenedHeight: CGFloat {
        // 读取当前激活功能的 per-feature 展开高度覆盖（nil = 跟随全局）
        let activeFeature = LeftFeatureStore.shared.expandedActiveFeature
        let featureHeight: Double = activeFeature?.expandedHeight ?? AppSettings.maxPanelHeight
        let maxPanelHeight = CGFloat(featureHeight)
        let screenLimit = screenRect.height - 120

        if openReason == .hover {
            return min(screenLimit, maxPanelHeight)
        }

        switch contentType {
        case .chat, .customExpanded:
            return min(screenLimit, maxPanelHeight)
        case .instances:
            // 任务列表高度仅受屏幕限制，不受面板最大高度设置约束
            return screenLimit
        }
    }

    /// 当前面板固定状态：若当前激活功能设置了 `expandedPinned` 则视为已固定，否则跟随全局 `keepIslandOpen`。
    /// 用于 hover 离开时是否自动收起面板的判定，确保 per-feature 固定仅作用于当前功能。
    private var currentPanelPinned: Bool {
        if let feature = LeftFeatureStore.shared.expandedActiveFeature, feature.expandedPinned {
            return true
        }
        return AppSettings.keepIslandOpen
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    var closedNotchResizeAnimation: Animation {
        if isDetachmentNarrowingClosedNotch {
            return .linear(duration: detachmentLongPressNarrowAnimationDuration)
        }
        return .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    }

    var isDetachmentNarrowingClosedNotch: Bool {
        presentationMode == .docked && detachmentTracking != nil && status != .opened
    }

    var isDetachmentGestureActive: Bool {
        presentationMode == .docked && detachmentTracking != nil
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events: EventMonitors?
    private let fullscreenActivityProvider: @MainActor (CGRect) -> Bool
    private let fullscreenBrowserHiddenProvider: @MainActor (CGRect) -> Bool
    private let hideInFullscreenProvider: @MainActor () -> Bool
    private let autoHideWhenIdleProvider: @MainActor () -> Bool
    private let notchModuleWidthProvider: @MainActor () -> Double
    private var hoverTimer: DispatchWorkItem?
    private let fullscreenRevealZoneHeight: CGFloat = 8
    private let fullscreenRevealZoneHorizontalInset: CGFloat = 36
    private let fullscreenStateSettleDelay: TimeInterval
    private var fullscreenPhysicalNotchCollapseWorkItem: DispatchWorkItem?
    private let detachmentLongPressDuration = IslandDetachmentGestureGate.defaultLongPressDuration
    private let detachmentLongPressNarrowAnimationDuration =
        IslandDetachmentGestureGate.defaultLongPressDuration * 20
    private let detachmentLongPressResetDuration: TimeInterval = 0.18
    private let detachmentTapMovementTolerance: CGFloat = 8
    private var detachmentLongPressWorkItem: DispatchWorkItem?

    var onDetachmentRequested: ((IslandDetachmentRequest) -> Void)?
    var onDetachmentUpdated: ((CGPoint) -> Void)?
    var onDetachmentFinished: ((CGPoint?) -> Void)?

    private struct DockedDetachmentTracking {
        let id: UUID
        let source: IslandDetachmentSource
        let startLocation: CGPoint
        var isLongPressSatisfied: Bool
        var hasExceededTapMovementTolerance: Bool
        var hasTriggeredDetachment: Bool
    }

    private var detachmentTracking: DockedDetachmentTracking?

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool,
        enableEventMonitoring: Bool = true,
        observeSystemEnvironment: Bool = true,
        fullscreenActivityProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenAppActive,
        hideInFullscreenProvider: @escaping @MainActor () -> Bool = { AppSettings.hideInFullscreen },
        fullscreenBrowserHiddenProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenBrowserActive,
        autoHideWhenIdleProvider: @escaping @MainActor () -> Bool = { AppSettings.autoHideWhenIdle },
        notchModuleWidthProvider: @escaping @MainActor () -> Double = { AppSettingsStore.defaultNotchModuleWidth },
        fullscreenStateSettleDelay: TimeInterval = 0.18
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedWidth = CGFloat(AppSettingsStore.normalizedNotchModuleWidth(notchModuleWidthProvider()))
        self.events = enableEventMonitoring ? EventMonitors.shared : nil
        self.fullscreenActivityProvider = fullscreenActivityProvider
        self.fullscreenBrowserHiddenProvider = fullscreenBrowserHiddenProvider
        self.hideInFullscreenProvider = hideInFullscreenProvider
        self.autoHideWhenIdleProvider = autoHideWhenIdleProvider
        self.notchModuleWidthProvider = notchModuleWidthProvider
        self.fullscreenStateSettleDelay = fullscreenStateSettleDelay
        if enableEventMonitoring {
            setupEventHandlers()
        }
        if observeSystemEnvironment {
            observeEnvironment()
        }
        refreshFullscreenPresentationState()
    }

    #if compiler(>=6.3)
    // Keep teardown outside MainActor isolation; Xcode 26 can otherwise abort
    // while destroying this view model in unit-test scope teardown.
    nonisolated deinit {}
    #endif

    func updateScreenGeometry(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool
    ) {
        let updatedGeometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        let geometryChanged = updatedGeometry != geometry || hasPhysicalNotch != self.hasPhysicalNotch
        guard geometryChanged else { return }

        geometry = updatedGeometry
        self.hasPhysicalNotch = hasPhysicalNotch
        openedMeasuredHeight = nil
        syncClosedWidth(animated: false)
        refreshFullscreenPresentationState()
    }

    private func observeEnvironment() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$hideInFullscreen
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideWhenIdle
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$maxPanelHeight
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$expandedPanelWidth
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$notchModuleWidth
            .sink { [weak self] width in
                self?.syncClosedWidth(
                    animated: true,
                    animation: .easeOut(duration: 0.12),
                    preferredModuleWidth: width
                )
            }
            .store(in: &cancellables)

        // Spec: compactLeftHeight 变化时触发 closedSize 重算与 Flow 岛窗口尺寸更新
        AppSettings.shared.$compactLeftHeight
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Spec: LeftFeatureStore 变化时（功能列表/选择/per-feature 尺寸）触发 panelSize 重算
        LeftFeatureStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func refreshFullscreenPresentationState() {
        // 应用尚未被激活时（例如刚启动），frontmostApplication 可能是其他应用，
        // 此时若前方有全屏窗口会被误判为当前屏幕处于全屏，导致 Flow 岛启动即隐藏。
        // 固定展示策略：未激活时不进入任何全屏隐藏/edge-reveal 状态，等应用被激
        // 活后再重新评估。
        let isAppActive = NSApp.isActive
        let isFullscreenActive = isAppActive && fullscreenActivityProvider(screenRect)
        let shouldHideForFullscreenBrowser = isAppActive && fullscreenBrowserHiddenProvider(screenRect)
        let shouldUseEdgeReveal = shouldUseFullscreenEdgeReveal(isFullscreenActive: isFullscreenActive)
        let shouldUsePhysicalNotchCompact = shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive)

        if shouldHideForFullscreenBrowser != isFullscreenBrowserHiddenActive {
            isFullscreenBrowserHiddenActive = shouldHideForFullscreenBrowser
        }

        applyPhysicalNotchFullscreenState(shouldUsePhysicalNotchCompact)

        guard shouldUseEdgeReveal != isFullscreenEdgeRevealActive else { return }
        isFullscreenEdgeRevealActive = shouldUseEdgeReveal

        if shouldUseEdgeReveal {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }

        if shouldHideForFullscreenBrowser {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }
    }

    func refreshFullscreenPresentationStateForTesting() {
        refreshFullscreenPresentationState()
    }

    private func applyPhysicalNotchFullscreenState(_ shouldUsePhysicalNotchCompact: Bool) {
        if shouldUsePhysicalNotchCompact {
            fullscreenPhysicalNotchCollapseWorkItem?.cancel()
            fullscreenPhysicalNotchCollapseWorkItem = nil
            if !isFullscreenPhysicalNotchCompactActive {
                isFullscreenPhysicalNotchCompactActive = true
            }
            return
        }

        guard isFullscreenPhysicalNotchCompactActive else { return }

        fullscreenPhysicalNotchCollapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenPhysicalNotchCollapseWorkItem = nil
            let isFullscreenActive = self.fullscreenActivityProvider(self.screenRect)
            if self.shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive) {
                self.isFullscreenPhysicalNotchCompactActive = true
            } else {
                self.isFullscreenPhysicalNotchCompactActive = false
            }
        }
        fullscreenPhysicalNotchCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenStateSettleDelay, execute: workItem)
    }

    private func shouldUseFullscreenEdgeReveal(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider() && !hasPhysicalNotch && isFullscreenActive
    }

    private func shouldUsePhysicalNotchCompact(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider()
            && hasPhysicalNotch
            && isFullscreenActive
            && !isFullscreenBrowserHiddenActive
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        guard let events else { return }

        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDown(event)
            }
            .store(in: &cancellables)

        events.mouseDragged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDragged(event)
            }
            .store(in: &cancellables)

        events.mouseUp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseUp(event)
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode.
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're currently presenting while the island stays open.
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        // Flow 岛始终保持交互：宠物分离态下 docked 窗口仍需响应 hover/展开
        guard presentationMode != .detached || status != .opened || !isInlineTextInputActive else { return }

        let inNotch = isPointInHoverTrigger(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        if Self.shouldAutoCollapseHoverPreview(
            isHovering: newHovering,
            status: status,
            openReason: openReason,
            isSettingsPopoverPresented: isSettingsPopoverPresented,
            isInlineTextInputActive: isInlineTextInputActive,
            autoCollapseOnLeave: AppSettings.autoCollapseOnLeave,
            keepIslandOpen: currentPanelPinned
        ) {
            notchClose()
        }

        // Start hover timer to auto-expand after a short dwell
        // openOnHover 关闭时不启动 hover 展开计时器，仅保留点击展开入口
        if AppSettings.openOnHover && isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.performDeferredHoverOpenIfNeeded()
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverActivationDelay, execute: workItem)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        // Flow 岛始终保持交互：宠物分离态下点击 docked 窗口仍可展开/关闭
        guard presentationMode != .detached || status != .opened || !isInlineTextInputActive else { return }

        if isSettingsPopoverPresented {
            return
        }

        if MouseEventReplay.isReplayed(event) {
            return
        }

        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            // 展开态 header 行承载功能切换栏/固定/声音/设置按钮，不再把 header 区域
            // 当作分离/关闭触发区；避免点击/拖拽这些按钮时误收面板或触发分离。
            // 分离仍可在闭合态通过长按 notch 触发。
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                // The panel window already handles click-through replay for intercepted clicks.
                notchClose()
            }
        case .closed, .popping:
            if detachmentTriggerScreenRect.contains(location) {
                beginDockedDetachmentTracking(source: .closed, startLocation: location)
            } else if isPointInHoverTrigger(location) {
                // Spec 2.4: 左半区展开自定义内容面板，右半区展开会话列表。
                if location.x < closedScreenRect.midX {
                    presentCustomExpanded()
                } else {
                    presentSessionList(reason: .click)
                }
            }
        }
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }

        let location = NSEvent.mouseLocation

        // 文件拖拽经过 Flow 岛时自动展开并切换到中转站
        handleFileDragHover(at: location)

        guard var tracking = detachmentTracking else { return }

        if !tracking.isLongPressSatisfied {
            let horizontalDistance = abs(location.x - tracking.startLocation.x)
            let verticalDistance = abs(location.y - tracking.startLocation.y)
            if max(horizontalDistance, verticalDistance) > detachmentTapMovementTolerance {
                tracking.hasExceededTapMovementTolerance = true
            }
            detachmentTracking = tracking
            return
        }

        guard IslandDetachmentGestureGate.qualifies(
            start: tracking.startLocation,
            current: location,
            hasSatisfiedLongPress: tracking.isLongPressSatisfied
        ) else {
            detachmentTracking = tracking
            return
        }

        if tracking.hasTriggeredDetachment {
            onDetachmentUpdated?(location)
        } else {
            tracking.hasTriggeredDetachment = true
            onDetachmentRequested?(
                IslandDetachmentRequest(
                    source: tracking.source,
                    dragStartScreenLocation: tracking.startLocation,
                    currentScreenLocation: location
                )
            )
        }

        detachmentTracking = tracking
    }

    // MARK: - File Drag Auto-Open Shelf

    /// 当检测到文件拖拽经过闭合 notch 或已展开面板时，自动展开并切换到中转站功能。
    /// 注意：中转站被用户在设置里手动关闭后，不会自动启用、也不会自动展开，
    /// 需用户前往设置手动打开后才会再次响应文件拖拽。
    private func handleFileDragHover(at location: CGPoint) {
        guard hasFileURLsOnDragPasteboard else { return }

        let overClosedNotch = (status == .closed || status == .popping) && isPointInHoverTrigger(location)
        let overOpenedPanel = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)
        guard overClosedNotch || overOpenedPanel else { return }

        // 中转站被手动关闭后不自动启用；找不到或未启用则跳过整个拖拽响应流程
        guard let shelf = LeftFeatureStore.shared.features.first(where: {
            if case .shelf = $0.kind { return true }
            return false
        }), shelf.isEnabled else { return }

        if LeftFeatureStore.shared.expandedActiveFeature?.id != shelf.id {
            LeftFeatureStore.shared.setExpandedActiveFeature(id: shelf.id)
        }

        if status != .opened {
            presentCustomExpanded(reason: .click)
        }
    }

    private var hasFileURLsOnDragPasteboard: Bool {
        let pasteboard = NSPasteboard(name: .dragPboard)
        let fileURLType = NSPasteboard.PasteboardType(UTType.fileURL.identifier)
        return pasteboard.availableType(from: [fileURLType]) != nil
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }
        guard let tracking = detachmentTracking else { return }

        let location = NSEvent.mouseLocation
        if tracking.hasTriggeredDetachment {
            onDetachmentFinished?(location)
        } else if tracking.source == .closed,
                  !tracking.isLongPressSatisfied {
            // 关闭态下没有触发分离手势的点击/抬起视为展开面板。
            // 不再要求 mouseUp 必须落在 closedScreenRect 内，也不检查轻微移动，
            // 避免正常点击因手抖或高 DPI 下的微小位移而无法展开。
            // Spec 2.4: 左半区展开自定义内容面板，右半区展开会话列表。
            if location.x < closedScreenRect.midX {
                presentCustomExpanded()
            } else {
                presentSessionList(reason: .click)
            }
        } else if tracking.source == .opened,
                  !tracking.isLongPressSatisfied,
                  !tracking.hasExceededTapMovementTolerance,
                  detachmentTriggerScreenRect.contains(location),
                  !isInChatMode {
            // 展开态 header 区域现在承载功能切换栏/固定/声音/设置等按钮，
            // 继续把点击 notch 区域视为关闭会与这些按钮冲突。保留 hover 离开/点击面板外关闭，
            // 不再因点击 header 中央 notch 区域而收起面板。
        }

        cancelDockedDetachmentTracking()
    }

    private func beginDockedDetachmentTracking(
        source: IslandDetachmentSource,
        startLocation: CGPoint
    ) {
        hoverTimer?.cancel()
        hoverTimer = nil
        cancelDockedDetachmentTracking()

        let trackingID = UUID()
        detachmentTracking = DockedDetachmentTracking(
            id: trackingID,
            source: source,
            startLocation: startLocation,
            isLongPressSatisfied: false,
            hasExceededTapMovementTolerance: false,
            hasTriggeredDetachment: false
        )
        syncClosedWidth(
            animated: true,
            animation: .linear(duration: detachmentLongPressNarrowAnimationDuration)
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var tracking = self.detachmentTracking, tracking.id == trackingID else { return }
            tracking.isLongPressSatisfied = true
            self.detachmentTracking = tracking
            self.detachmentLongPressWorkItem = nil
            if tracking.source == .opened {
                self.notchClose()
            }
        }
        detachmentLongPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + detachmentLongPressDuration, execute: workItem)
    }

    private func cancelDockedDetachmentTracking() {
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(
            animated: true,
            animation: .easeOut(duration: detachmentLongPressResetDuration)
        )
    }

    private var hoverActivationDelay: TimeInterval {
        // 使用设置里的 hover 展开延迟；全屏边缘揭示场景保持同样延迟，由用户统一配置。
        TimeInterval(AppSettings.hoverOpenDelayMs) / 1000.0
    }

    var shouldHideWindowPresentation: Bool {
        // 宠物分离态不再隐藏 Flow 岛：胶囊继续展示，仅在 NotchView 中隐藏宠物。
        if isFullscreenBrowserHiddenActive {
            return true
        }
        if isFullscreenEdgeRevealActive && status != .opened {
            return true
        }
        // Flow 岛固定展示：关闭态胶囊始终可见，不受 idle/low-power 策略影响。
        return false
    }

    var shouldHideClosedPresentation: Bool {
        shouldHideWindowPresentation
    }

    var shouldSuppressAutomaticPresentation: Bool {
        // 宠物分离态下 Flow 岛保持正常交互（hover/通知自动展开等），不再抑制。
        isFullscreenBrowserHiddenActive
            || (isFullscreenEdgeRevealActive && status != .opened)
    }

    var closedPresentationOffsetY: CGFloat {
        shouldHideWindowPresentation ? -(closedHeight + 12) : 0
    }

    func isPointInHoverTrigger(_ point: CGPoint) -> Bool {
        if shouldHideClosedPresentation {
            return fullscreenRevealTriggerRect.contains(point)
        }
        return isPointInClosedNotch(point)
    }

    private func isPointInClosedNotch(_ point: CGPoint) -> Bool {
        closedScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    func updateIdleAutoHiddenState(hasVisibleSessionActivity: Bool) {
        // Flow 岛固定展示：即使没有活跃任务或开启 autoHideWhenIdle，也不让关闭态胶囊隐藏。
        _ = hasVisibleSessionActivity
        if isIdleAutoHiddenActive {
            isIdleAutoHiddenActive = false
        }
    }

    func updateQuietBackgroundPresentationState(isActive: Bool) {
        guard isQuietBackgroundPresentationActive != isActive else { return }
        isQuietBackgroundPresentationActive = isActive
    }

    private var fullscreenRevealTriggerRect: CGRect {
        let width = closedSize.width + (fullscreenRevealZoneHorizontalInset * 2)
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - fullscreenRevealZoneHeight,
            width: width,
            height: fullscreenRevealZoneHeight
        )
    }

    var detachmentTriggerScreenRect: CGRect {
        closedScreenRect
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        hoverTimer?.cancel()
        hoverTimer = nil

        if reason == .notification && shouldSuppressAutomaticPresentation {
            return
        }

        openReason = reason
        status = .opened
        if case .instances = contentType {
            openedMeasuredHeight = nil
        }

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Hover opens a lightweight preview instead of restoring the full chat view.
        if reason == .hover {
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func performDeferredHoverOpenIfNeeded() {
        guard isHovering else { return }
        guard status == .closed || status == .popping else { return }
        // Spec 2.4: hover 时左半侧展开自定义内容面板，右半侧展开会话列表。
        let location = NSEvent.mouseLocation
        if location.x < closedScreenRect.midX {
            presentCustomExpanded(reason: .hover)
        } else {
            presentSessionList(reason: .hover)
        }
    }

    func notchClose() {
        // “固定显示 Flow 岛”或当前功能设置「展开即固定」时，保持面板展开直到用户取消固定。
        // per-feature 的 expandedPinned 仅对当前激活功能生效，切换到其他功能时自动跟随全局配置。
        guard !currentPanelPinned else { return }
        status = .closed
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
        isInlineTextInputActive = false
    }

    func beginDetachedPresentation(contentType: NotchContentType, playSound: Bool = true) {
        // 仅取消 docked 的悬停计时器（拖拽手势应中止待触发的 hover-open）
        hoverTimer?.cancel()
        hoverTimer = nil
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(animated: false)

        // 分离态专用状态：写入 detached twins，绝不触碰 docked 共享状态
        // （contentType / currentChatSession / openedMeasuredHeight / isHovering）
        detachedDisplayMode = .compact
        detachedContentType = contentType
        detachedOpenedMeasuredHeight = nil
        presentationMode = .detached

        if playSound {
            AppSettings.playDetachedCapsuleSound()
        }
    }

    func setDetachedDisplayMode(_ mode: DetachedIslandDisplayMode) {
        guard presentationMode == .detached else { return }
        guard detachedDisplayMode != mode else { return }
        detachedDisplayMode = mode
        if mode == .compact {
            detachedOpenedMeasuredHeight = nil
        }
    }

    func redockAfterDetached() {
        cancelDockedDetachmentTracking()
        detachedDisplayMode = .compact
        detachedContentType = .instances
        detachedOpenedMeasuredHeight = nil
        presentationMode = .docked

        // 宠物拖回 Flow 岛后，若 docked 面板仍处于展开态，需将其收合，
        // 否则展开的透明窗口会继续占据屏幕上半区域，导致其他窗口无法点击。
        if status == .opened {
            status = .closed
        }
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func setSettingsPopoverPresented(_ isPresented: Bool) {
        isSettingsPopoverPresented = isPresented
    }

    func setInlineTextInputActive(_ isActive: Bool) {
        guard isInlineTextInputActive != isActive else { return }
        isInlineTextInputActive = isActive
    }

    func showChat(for session: SessionState) {
        currentChatSession = session
        openedMeasuredHeight = nil

        // Avoid unnecessary updates only when the snapshot is already current.
        if case .chat(let current) = contentType, current == session {
            return
        }
        contentType = .chat(session)
    }

    func presentChat(for session: SessionState, reason: NotchOpenReason = .click) {
        notchOpen(reason: reason)
        showChat(for: session)
    }

    func toggleChat(for session: SessionState, reason: NotchOpenReason = .click) {
        if status == .opened,
           case .chat(let currentSession) = contentType,
           currentSession.sessionId == session.sessionId {
            notchClose()
            return
        }

        presentChat(for: session, reason: reason)
    }

    /// Surface a session from an automatic notification without collapsing first.
    /// This keeps attention-driven panel refreshes stable when the notch is already open.
    func presentNotificationChat(for session: SessionState) {
        notchOpen(reason: .notification)
        showChat(for: session)
    }

    /// Surface manual-attention content through the route resolver instead of forcing chat.
    /// Approval cards should take priority over the underlying session detail view.
    func presentNotificationAttention() {
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
        notchOpen(reason: .notification)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
        openedMeasuredHeight = nil
    }

    /// Spec 2.4: 切换到自定义内容全屏面板，并确保展开态可见
    func presentCustomExpanded(reason: NotchOpenReason = .click) {
        contentType = .customExpanded
        openReason = reason
        if status != .opened {
            status = .opened
        }
    }

    func presentSessionList(reason: NotchOpenReason = .click) {
        exitChat()
        notchOpen(reason: reason)
    }

    func toggleSessionList(reason: NotchOpenReason = .click) {
        if status == .opened,
           reason == .click,
           openReason == .click,
           case .instances = contentType {
            notchClose()
            return
        }

        presentSessionList(reason: reason)
    }

    func updateOpenedMeasuredHeight(_ height: CGFloat?) {
        let sanitized = height.map { max(closedHeight, ceil($0)) }

        guard sanitized != openedMeasuredHeight else { return }
        openedMeasuredHeight = sanitized
    }

    /// 分离态专用测量高度更新，与 docked 的 openedMeasuredHeight 解耦。
    func updateDetachedOpenedMeasuredHeight(_ height: CGFloat?) {
        let sanitized = height.map { max(closedHeight, ceil($0)) }

        guard sanitized != detachedOpenedMeasuredHeight else { return }
        detachedOpenedMeasuredHeight = sanitized
    }

    func setManualAttentionActive(_ isActive: Bool) {
        syncClosedWidth(animated: false)
    }

    /// Boot presentation. The closed notch stays visible by default.
    /// 当用户开启“固定显示 Flow 岛”时，启动后直接展开面板并保持打开。
    func performBootAnimation() {
        guard !shouldSuppressAutomaticPresentation else { return }
        if AppSettings.keepIslandOpen {
            notchOpen(reason: .boot)
        }
    }

    /// 预置屏幕切换后的滑块下降动画标志。
    /// IslandPresentationCoordinator 在重建 docked 窗口前调用，NotchView.onAppear 消费并复位。
    func prepareScreenSlideIn() {
        triggerScreenSlideIn = true
    }

    private func syncClosedWidth(
        animated: Bool,
        animation: Animation? = nil,
        preferredModuleWidth: Double? = nil
    ) {
        let targetWidth = dockedClosedWidthTarget(
            preferredModuleWidthOverride: preferredModuleWidth.map {
                CGFloat(AppSettingsStore.normalizedNotchModuleWidth($0))
            }
        )
        guard closedWidth != targetWidth else { return }

        if animated, let animation {
            withAnimation(animation) {
                closedWidth = targetWidth
            }
        } else {
            closedWidth = targetWidth
        }
    }

#if DEBUG
    func beginDockedDetachmentTrackingForTesting(
        source: IslandDetachmentSource = .closed,
        startLocation: CGPoint = .zero
    ) {
        beginDockedDetachmentTracking(source: source, startLocation: startLocation)
    }

    func cancelDockedDetachmentTrackingForTesting() {
        cancelDockedDetachmentTracking()
    }

    func syncClosedWidthForTesting(preferredModuleWidth: Double) {
        syncClosedWidth(animated: false, preferredModuleWidth: preferredModuleWidth)
    }
#endif
}
