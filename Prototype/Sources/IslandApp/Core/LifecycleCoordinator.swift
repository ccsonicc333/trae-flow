import Foundation
import IslandShared

@MainActor
final class LifecycleCoordinator {
    private let appModel: AppModel
    private let approvalCoordinator: ApprovalCoordinator
    private let sessionStore: SessionStore
    private let socketServer: SocketServer
    private let terminalLocator: AppleTerminalLocator
    private let hookInstaller: HookInstaller
    private let traeAdapter: TraeProviderAdapter

    init(appModel: AppModel) {
        self.appModel = appModel
        let approvalCoordinator = ApprovalCoordinator()
        let terminalLocator = AppleTerminalLocator()
        let sessionStore = SessionStore { snapshot in
            appModel.update(snapshot: snapshot)
        }
        let socketServer = SocketServer(
            socketPath: "/tmp/island.sock",
            sessionStore: sessionStore,
            approvalCoordinator: approvalCoordinator
        )
        let hookInstaller = HookInstaller()

        self.approvalCoordinator = approvalCoordinator
        self.terminalLocator = terminalLocator
        self.sessionStore = sessionStore
        self.socketServer = socketServer
        self.hookInstaller = hookInstaller
        self.traeAdapter = TraeProviderAdapter(installer: hookInstaller)
        appModel.bind(
            sessionStore: sessionStore,
            approvalCoordinator: approvalCoordinator,
            socketServer: socketServer,
            terminalLocator: terminalLocator
        )
    }

    func start() {
        Task {
            do {
                try await traeAdapter.installHooks()
                try await socketServer.start()
                await traeAdapter.startMonitoring()
            } catch {
                // Startup errors are non-fatal; the socket server will retry on the next hook.
            }
        }
    }

    func stop() {
        Task {
            await socketServer.stop()
        }
    }
}
