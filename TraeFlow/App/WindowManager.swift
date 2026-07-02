//
//  WindowManager.swift
//  TraeFlow
//
//  Manages the notch window lifecycle
//

import AppKit
import Combine
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "ai.traeflow.app", category: "Window")

@MainActor
class WindowManager {
    private(set) var presentationCoordinator: IslandPresentationCoordinator?
    private var activeScreenNumber: NSNumber?
    private var cancellables = Set<AnyCancellable>()
    private var lastMigrationTime: Date = .distantPast
    private var isSettingUpNotchWindow = false
    private var hasPendingSetupNotchWindow = false

    init() {
        startFocusTracking()
    }

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // 多屏切换时屏幕配置可能连续变化，串行化 setup 避免创建多个 coordinator 导致旧窗口残留。
        guard !isSettingUpNotchWindow else {
            hasPendingSetupNotchWindow = true
            logger.info("setupNotchWindow already in progress, queuing retry")
            return nil
        }
        isSettingUpNotchWindow = true
        defer {
            isSettingUpNotchWindow = false
            if hasPendingSetupNotchWindow {
                hasPendingSetupNotchWindow = false
                logger.info("Processing pending setupNotchWindow")
                _ = setupNotchWindow()
            }
        }

        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let screenFrame = screen.frame
        logger.info("setupNotchWindow selectedScreen=\(screen.localizedName, privacy: .public) id=\(screenNumber?.stringValue ?? "nil", privacy: .public) frame=\(screenFrame.debugDescription, privacy: .public) screens=\(NSScreen.screens.map { "\($0.localizedName):\($0.frame.debugDescription)" }, privacy: .public)")

        let isSameScreen: Bool
        if let active = activeScreenNumber, let current = screenNumber {
            isSameScreen = active == current
        } else {
            // screen number 不可用时用 frame 兜底比较，避免 nil == nil 误判为同屏。
            isSameScreen = presentationCoordinator?.currentScreen.frame == screen.frame
        }

        if isSameScreen {
            logger.info("Same screen, updating geometry")
            presentationCoordinator?.updateScreen(screen)
            return nil
        }

        let previousViewModel = presentationCoordinator?.viewModel
        presentationCoordinator?.invalidate()
        let presentationCoordinator = IslandPresentationCoordinator(screen: screen, previousViewModel: previousViewModel)
        self.presentationCoordinator = presentationCoordinator
        activeScreenNumber = screenNumber
        logger.info("Created new IslandPresentationCoordinator for screen \(screen.localizedName, privacy: .public)")
        return nil
    }

    // MARK: - Focus-based screen migration

    /// Track application focus changes. When the user activates an app on a
    /// different screen, migrate the notch to follow.
    private func startFocusTracking() {
        // Track app-level focus changes
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.handleFocusChange()
            }
            .store(in: &cancellables)

        // Track window-level focus changes (covers same-app window switches)
        NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in
                self?.handleFocusChange()
            }
            .store(in: &cancellables)
    }

    private func handleFocusChange() {
        let selector = ScreenSelector.shared
        guard selector.selectionMode == .automatic else { return }

        // Debounce
        let now = Date()
        guard now.timeIntervalSince(lastMigrationTime) > 1.0 else { return }

        // Determine target screen from cursor position
        guard let targetScreen = selector.screenContaining(NSEvent.mouseLocation),
              let currentScreen = selector.selectedScreen else { return }

        let targetID = selector.screenID(of: targetScreen)
        let currentID = selector.screenID(of: currentScreen)

        guard targetID != currentID else { return }

        lastMigrationTime = now
        logger.info("Focus changed, migrating notch to cursor screen")
        selector.migrateToScreen(targetScreen)
        _ = setupNotchWindow()
    }
}
