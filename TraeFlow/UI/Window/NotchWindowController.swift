//
//  NotchWindowController.swift
//  TraeFlow
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let fullWindowFrame: NSRect
    private var cancellables = Set<AnyCancellable>()

    init(
        screen: NSScreen,
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        performBootAnimation: Bool
    ) {
        self.viewModel = viewModel

        let screenFrame = screen.frame

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )
        self.fullWindowFrame = windowFrame

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view
        let hostingController = NotchViewController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor
        )
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Start dynamic mouse-event-ignoring management before any other
        // subscription so that ignoresMouseEvents is correct from the start.
        startDynamicMouseEventIgnoring(window: notchWindow, viewModel: viewModel)

        setupPresentationSubscriptions(window: notchWindow, viewModel: viewModel)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true
        updateWindowPresentation(window: notchWindow, viewModel: viewModel)

        // Perform boot animation after a brief delay
        if performBootAnimation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        guard let window = window as? NotchPanel else {
            super.showWindow(sender)
            return
        }
        window.orderFrontRegardless()
        updateWindowPresentation(window: window, viewModel: viewModel)
    }

    func refreshVisibility() {
        guard let window = window as? NotchPanel else { return }
        if window.frame != fullWindowFrame {
            window.setFrame(fullWindowFrame, display: true)
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        updateWindowPresentation(window: window, viewModel: viewModel)
    }

    // MARK: - Dynamic mouse-event ignoring

    /// Observes the global mouse position and updates `ignoresMouseEvents`
    /// so that events inside the Flow Island content area reach the panel,
    /// while events outside pass through to windows behind it.
    ///
    /// This is the primary mechanism for click-through.  The previous
    /// approach (CGEvent reposting from within `sendEvent`) did not work
    /// because `CGEvent.post(tap:)` is asynchronous — by the time the
    /// window server processed the reposted event, `ignoresMouseEvents`
    /// had already been restored to `false`.
    private func startDynamicMouseEventIgnoring(
        window: NotchPanel,
        viewModel: NotchViewModel
    ) {
        EventMonitors.shared.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] location in
                guard let self, let window else { return }
                self.applyMouseEventIgnoring(
                    window: window,
                    viewModel: viewModel,
                    mouseLocation: location
                )
            }
            .store(in: &cancellables)
    }

    private func applyMouseEventIgnoring(
        window: NotchPanel,
        viewModel: NotchViewModel,
        mouseLocation: CGPoint
    ) {
        guard viewModel.status == .opened,
              !viewModel.shouldHideWindowPresentation
        else {
            // Closed or hidden — always pass through.
            window.ignoresMouseEvents = true
            return
        }

        let inContent = viewModel.isPointInHoverTrigger(mouseLocation)
            || viewModel.geometry.isPointInOpenedPanel(
                mouseLocation,
                size: viewModel.openedSize
            )

        window.ignoresMouseEvents = !inContent
    }

    /// Re-evaluate ignoresMouseEvents after a status change.
    /// This handles the case where the panel opens but the mouse has not
    /// moved yet — we immediately check the current position.
    private func reevaluateMouseEventIgnoringAfterStatusChange(
        window: NotchPanel,
        viewModel: NotchViewModel
    ) {
        let location = EventMonitors.shared.mouseLocation.value
        applyMouseEventIgnoring(
            window: window,
            viewModel: viewModel,
            mouseLocation: location
        )
    }

    // MARK: - Subscriptions

    private func setupPresentationSubscriptions(
        window: NotchPanel,
        viewModel: NotchViewModel
    ) {
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window, weak viewModel] _ in
                guard let self, let window, let viewModel else { return }
                self.updateWindowPresentation(window: window, viewModel: viewModel)
                self.reevaluateMouseEventIgnoringAfterStatusChange(
                    window: window,
                    viewModel: viewModel
                )
            }
            .store(in: &cancellables)

        viewModel.$openReason
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window, weak viewModel] _ in
                guard let self, let window, let viewModel else { return }
                self.updateWindowPresentation(window: window, viewModel: viewModel)
            }
            .store(in: &cancellables)

        let auxiliaryPresentations: [AnyPublisher<Void, Never>] = [
            viewModel.$isFullscreenEdgeRevealActive
                .map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isFullscreenBrowserHiddenActive
                .map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isIdleAutoHiddenActive
                .map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isQuietBackgroundPresentationActive
                .map { _ in () }.eraseToAnyPublisher(),
            viewModel.$presentationMode
                .map { _ in () }.eraseToAnyPublisher(),
        ]

        for publisher in auxiliaryPresentations {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak window, weak viewModel] _ in
                    guard let self, let window, let viewModel else { return }
                    self.updateWindowPresentation(window: window, viewModel: viewModel)
                }
                .store(in: &cancellables)
        }

        EnergyGovernor.shared.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window, weak viewModel] mode in
                guard let self, let window, let viewModel else { return }
                viewModel.updateQuietBackgroundPresentationState(isActive: mode == .quietBackground)
                self.updateWindowPresentation(window: window, viewModel: viewModel)
            }
            .store(in: &cancellables)
    }

    // MARK: - Window presentation

    private func updateWindowPresentation(window: NotchPanel, viewModel: NotchViewModel) {
        let shouldHideWindow = viewModel.shouldHideWindowPresentation

        if shouldHideWindow {
            window.ignoresMouseEvents = true
            if window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        if window.frame != fullWindowFrame {
            window.setFrame(fullWindowFrame, display: true)
        }

        if !window.isVisible {
            window.orderFrontRegardless()
        }

        // ignoresMouseEvents is managed dynamically by the mouse-position
        // observer (startDynamicMouseEventIgnoring).  Do NOT set it here
        // for the .opened state — the observer picks up the correct value
        // on the next mouse-location update (and immediately after this
        // method returns, via reevaluateMouseEventIgnoringAfterStatusChange).
        switch viewModel.status {
        case .closed, .popping:
            window.ignoresMouseEvents = true
        case .opened:
            break // dynamic management handles this
        }
    }
}
