import Combine
import Foundation
import IslandShared

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()

    private weak var socketServer: SocketServer?
    private var sessionStore: SessionStore?
    private weak var approvalCoordinator: ApprovalCoordinator?
    private weak var terminalLocator: AppleTerminalLocator?

    func bind(
        sessionStore: SessionStore,
        approvalCoordinator: ApprovalCoordinator,
        socketServer: SocketServer,
        terminalLocator: AppleTerminalLocator
    ) {
        self.sessionStore = sessionStore
        self.approvalCoordinator = approvalCoordinator
        self.socketServer = socketServer
        self.terminalLocator = terminalLocator
    }

    func update(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
    }

    func toggleExpanded() {
        Task {
            await sessionStore?.setExpanded(!snapshot.isExpanded)
        }
    }

    func collapse() {
        Task {
            await sessionStore?.setExpanded(false)
        }
    }

    func select(sessionID: String) {
        Task {
            await sessionStore?.select(sessionID: sessionID)
        }
    }

    func focus(_ session: AgentSession) {
        Task {
            _ = await terminalLocator?.focus(session: session)
        }
    }

    func focus(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        focus(session)
    }

    func approve(_ request: InterventionRequest, forSession: Bool = false) {
        Task {
            let decision: InterventionDecision = forSession ? .approveForSession : .approve
            await approvalCoordinator?.resolve(requestID: request.id, decision: decision)
            await sessionStore?.clearIntervention(for: request.sessionID)
        }
    }

    func deny(_ request: InterventionRequest) {
        Task {
            await approvalCoordinator?.resolve(requestID: request.id, decision: .deny)
            await sessionStore?.clearIntervention(for: request.sessionID)
        }
    }

    func answer(_ request: InterventionRequest, option: InterventionOption) {
        Task {
            await approvalCoordinator?.resolve(
                requestID: request.id,
                decision: .answer([option.id: option.title])
            )
            await sessionStore?.clearIntervention(for: request.sessionID)
        }
    }
}
