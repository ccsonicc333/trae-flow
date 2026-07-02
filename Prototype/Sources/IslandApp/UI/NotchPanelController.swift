import AppKit
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController {
    private let appModel: AppModel
    private let panel: NotchPanel

    init(appModel: AppModel) {
        self.appModel = appModel
        self.panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: NotchRootView(appModel: appModel))
        reposition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let width: CGFloat = appModel.snapshot.isExpanded ? 460 : 360
        let height: CGFloat = appModel.snapshot.isExpanded ? 420 : 110
        let frame = screen.visibleFrame
        let origin = CGPoint(
            x: frame.midX - width / 2,
            y: frame.maxY - height - 12
        )
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
