import AppKit
import Combine

@MainActor
final class IslandPresentationCoordinator {
    private static let dockedWindowHeight: CGFloat = 750

    let sessionMonitor = SessionMonitor()
    let viewModel: NotchViewModel
    var currentScreen: NSScreen { screen }

    private var screen: NSScreen
    private var dockedWindowController: NotchWindowController?
    private var detachedWindowController: DetachedIslandWindowController?
    private var activeDetachmentPayload: IslandDetachmentPayload?
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, previousViewModel: NotchViewModel? = nil) {
        self.screen = screen
        self.viewModel = previousViewModel ?? Self.makeViewModel(for: screen)

        // 屏幕切换后复用 viewModel 时，必须先把几何信息更新到当前屏幕，
        // 否则 closedScreenRect / deviceNotchRect 仍是旧屏幕数据，导致大小/位置异常且无法点击展开。
        let geometry = Self.makeDockedScreenGeometry(for: screen)
        viewModel.updateScreenGeometry(
            deviceNotchRect: geometry.deviceNotchRect,
            screenRect: geometry.screenRect,
            windowHeight: geometry.windowHeight,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )

        // Flow 岛固定展示，但启动时不默认展开；屏幕切换后也不恢复展开态。
        bindViewModel()
        bindSettings()
        applySurfaceMode(AppSettings.surfaceMode, activationPolicy: .silent)
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        let geometry = Self.makeDockedScreenGeometry(for: screen)
        viewModel.updateScreenGeometry(
            deviceNotchRect: geometry.deviceNotchRect,
            screenRect: geometry.screenRect,
            windowHeight: geometry.windowHeight,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )
        applySurfaceMode(AppSettings.surfaceMode, performBootAnimation: false)
    }

    /// 强制刷新 docked Flow 岛窗口的可见性。
    /// 启动时窗口可能因应用未激活而未被 window server 完成渲染，
    /// 调用此方法重新执行 orderFrontRegardless 以确保窗口可见。
    /// 宠物分离态下 Flow 岛依然展示，同样需要刷新。
    func requestDockedWindowVisibilityRefresh() {
        dockedWindowController?.refreshVisibility()
    }

    func beginDetachment(from request: IslandDetachmentRequest) {
        let resolvedContent = IslandDetachedContentResolver.resolve(
            status: viewModel.status,
            openReason: viewModel.openReason,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances
        )

        viewModel.beginDetachedPresentation(contentType: resolvedContent, playSound: true)

        let windowSize = DetachedIslandWindowController.windowSize(
            for: viewModel,
            sessionMonitor: sessionMonitor
        )
        let cursorWindowOffset = CGPoint(
            x: windowSize.width / 2,
            y: max(viewModel.closedHeight + 18, windowSize.height - 24)
        )

        let payload = IslandDetachmentPayload(
            contentType: resolvedContent,
            dragStartScreenLocation: request.dragStartScreenLocation,
            initialCursorScreenLocation: request.currentScreenLocation,
            cursorWindowOffset: cursorWindowOffset
        )
        activeDetachmentPayload = payload

        // 宠物分离到桌面后 Flow 岛继续展示（仅隐藏宠物），无需重建 docked 窗口，
        // 用户可随时将宠物拖回；仅在 docked 窗口不存在时补建
        if dockedWindowController == nil {
            recreateDockedWindow(performBootAnimation: false)
        }

        let detachedWindowController = ensureDetachedWindowController()

        let origin = DetachedIslandWindowController.windowOrigin(
            for: payload.initialCursorScreenLocation,
            cursorWindowOffset: payload.cursorWindowOffset,
            windowSize: windowSize
        )
        detachedWindowController.present(at: origin)
        AppSettings.surfaceMode = .floatingPet
    }

    func updateDetachment(cursorLocation: CGPoint) {
        guard let payload = activeDetachmentPayload else { return }
        detachedWindowController?.updateDragPosition(
            cursorLocation: cursorLocation,
            cursorWindowOffset: payload.cursorWindowOffset
        )
    }

    func finishDetachment(cursorLocation: CGPoint?) {
        if let cursorLocation {
            updateDetachment(cursorLocation: cursorLocation)
        }

        DispatchQueue.main.async { [weak self] in
            self?.detachedWindowController?.endWindowDrag()
            self?.persistCurrentFloatingPetAnchor()
        }
    }

    func applySurfaceMode(
        _ mode: IslandSurfaceMode,
        performBootAnimation: Bool = false,
        activationPolicy: IslandPresentationActivationPolicy = .interactive
    ) {
        switch mode {
        case .notch:
            showDockedIsland(performBootAnimation: performBootAnimation)
        case .floatingPet:
            presentFloatingPet(
                playSound: false,
                activationPolicy: activationPolicy
            )
        }
    }

    func redockDetached() {
        detachedWindowController?.dismiss()
        detachedWindowController = nil
        activeDetachmentPayload = nil

        AppSettings.surfaceMode = .notch
        viewModel.redockAfterDetached()
        recreateDockedWindow(performBootAnimation: false)
    }

    func invalidate() {
        cancellables.removeAll()
        activeDetachmentPayload = nil
        detachedWindowController?.dismiss()
        detachedWindowController = nil
        // 彻底释放旧 docked 窗口，避免多屏切换时旧窗口残留。
        if let controller = dockedWindowController {
            controller.window?.contentViewController = nil
            controller.window?.orderOut(nil)
            controller.close()
        }
        dockedWindowController = nil
    }

    private func bindViewModel() {
        viewModel.onDetachmentRequested = { [weak self] request in
            self?.beginDetachment(from: request)
        }
        viewModel.onDetachmentUpdated = { [weak self] location in
            self?.updateDetachment(cursorLocation: location)
        }
        viewModel.onDetachmentFinished = { [weak self] location in
            self?.finishDetachment(cursorLocation: location)
        }
    }

    private func bindSettings() {
        AppSettings.shared.$surfaceMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applySurfaceMode(mode)
            }
            .store(in: &cancellables)
    }

    private func showDockedIsland(performBootAnimation: Bool) {
        activeDetachmentPayload = nil

        if viewModel.presentationMode == .detached || detachedWindowController != nil {
            detachedWindowController?.dismiss()
            detachedWindowController = nil
            viewModel.redockAfterDetached()
        }

        recreateDockedWindow(performBootAnimation: performBootAnimation)
    }

    private func presentFloatingPet(
        playSound: Bool,
        activationPolicy: IslandPresentationActivationPolicy = .interactive
    ) {
        if viewModel.presentationMode == .detached, detachedWindowController != nil {
            return
        }

        // 拖拽分离后保留 Flow 岛，不销毁 docked 窗口
        activeDetachmentPayload = nil

        // 宠物分离到桌面时 Flow 岛依然展示（仅隐藏宠物），确保 docked 窗口存在
        if dockedWindowController == nil {
            recreateDockedWindow(performBootAnimation: false)
        }

        let resolvedContent = IslandDetachedContentResolver.resolve(
            status: viewModel.status,
            openReason: viewModel.openReason,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances
        )

        viewModel.beginDetachedPresentation(
            contentType: resolvedContent,
            playSound: playSound
        )

        let detachedWindowController = ensureDetachedWindowController()
        let visibleFrame = screen.visibleFrame
        let activeWindowFrame = ActiveWindowFrameResolver.currentActiveWindowFrame()
        let petAnchor = DetachedIslandWindowController.petAnchor(
            from: AppSettings.floatingPetAnchor,
            in: visibleFrame,
            defaultWindowFrame: activeWindowFrame
        )
        detachedWindowController.present(
            atPetAnchor: petAnchor,
            activatesApplication: activationPolicy.activatesApplication,
            presentsAutomaticContent: activationPolicy.presentsAutomaticContent
        )
        detachedWindowController.activateInteraction()
    }

    private func ensureDetachedWindowController() -> DetachedIslandWindowController {
        if let detachedWindowController {
            return detachedWindowController
        }

        let detachedWindowController = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: { [weak self] in
                AppSettings.surfaceMode = .notch
                self?.activeDetachmentPayload = nil
            },
            onPetAnchorChanged: { [weak self] petAnchor in
                self?.persistFloatingPetAnchor(petAnchor)
            }
        )
        detachedWindowController.onRedockRequested = { [weak self] in
            self?.redockDetached()
        }
        self.detachedWindowController = detachedWindowController
        return detachedWindowController
    }

    private func persistCurrentFloatingPetAnchor() {
        guard let petAnchor = detachedWindowController?.currentPetAnchor else { return }
        persistFloatingPetAnchor(petAnchor)
    }

    private func persistFloatingPetAnchor(_ petAnchor: CGPoint) {
        AppSettings.floatingPetAnchor = DetachedIslandWindowController.floatingPetAnchor(
            from: petAnchor,
            in: screen.visibleFrame
        )
    }

    private func recreateDockedWindow(performBootAnimation: Bool) {
        if let controller = dockedWindowController {
            controller.window?.contentViewController = nil
            controller.window?.orderOut(nil)
            controller.close()
        }

        // 非启动动画场景（如屏幕切换、redock）预置滑块下降动画，
        // NotchView.onAppear 消费此标志并通过 spring 动画将 Flow 岛从屏幕上方滑入。
        if !performBootAnimation {
            viewModel.prepareScreenSlideIn()
        }

        let controller = NotchWindowController(
            screen: screen,
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            performBootAnimation: performBootAnimation
        )
        dockedWindowController = controller
        controller.showWindow(nil as Any?)
    }

    private static func makeViewModel(for screen: NSScreen) -> NotchViewModel {
        let geometry = makeDockedScreenGeometry(for: screen)

        return NotchViewModel(
            deviceNotchRect: geometry.deviceNotchRect,
            screenRect: geometry.screenRect,
            windowHeight: geometry.windowHeight,
            hasPhysicalNotch: geometry.hasPhysicalNotch,
            notchModuleWidthProvider: { AppSettings.notchModuleWidth }
        )
    }

    private struct DockedScreenGeometry {
        let deviceNotchRect: CGRect
        let screenRect: CGRect
        let windowHeight: CGFloat
        let hasPhysicalNotch: Bool
    }

    private static func makeDockedScreenGeometry(for screen: NSScreen) -> DockedScreenGeometry {
        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        return DockedScreenGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: dockedWindowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )
    }
}
