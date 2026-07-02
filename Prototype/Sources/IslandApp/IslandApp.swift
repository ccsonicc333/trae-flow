import AppKit
import SwiftUI

@main
struct IslandDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(appModel: appDelegate.appModel)
                .frame(width: 420, height: 300)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()
    private var lifecycleCoordinator: LifecycleCoordinator?
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panelController = NotchPanelController(appModel: appModel)
        panelController.showWindow(nil)
        panelController.window?.orderFrontRegardless()
        self.panelController = panelController

        lifecycleCoordinator = LifecycleCoordinator(appModel: appModel)
        lifecycleCoordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleCoordinator?.stop()
    }
}
