import XCTest
@testable import TRAE_FLOW

final class SessionManualAttentionTrackerTests: XCTestCase {
    func testTerminalRoutedPromptTriggersAttentionNotification() {
        var tracker = SessionManualAttentionTracker()
        let session = SessionState(
            sessionId: "terminal-routed-question",
            cwd: "/tmp/project",
            suppressInAppPromptControls: true,
            phase: .waitingForInput
        )

        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [session])?.stableId,
            session.stableId
        )
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [session]))
    }

    func testApprovalToolUseRefreshInSameSessionTriggersAttentionAgain() {
        var tracker = SessionManualAttentionTracker()
        let firstApproval = makeApprovalSession(toolUseId: "tool-1")
        let secondApproval = makeApprovalSession(toolUseId: "tool-2")

        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [firstApproval])?.stableId,
            firstApproval.stableId
        )
        XCTAssertNil(tracker.consumeNewAttentionSession(from: [firstApproval]))
        XCTAssertEqual(
            tracker.consumeNewAttentionSession(from: [secondApproval])?.stableId,
            secondApproval.stableId
        )
    }

    private func makeApprovalSession(toolUseId: String) -> SessionState {
        SessionState(
            sessionId: "trae-session",
            cwd: "/tmp/project",
            provider: .trae,
            clientInfo: SessionClientInfo(
                kind: .trae,
                profileID: "trae",
                name: "TRAE"
            ),
            phase: .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: "ExitPlanMode",
                toolInput: ["plan": AnyCodable("Plan text")],
                receivedAt: Date()
            ))
        )
    }
}
