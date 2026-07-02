import XCTest
@testable import TRAE_FLOW

/// MascotStatus 映射规则测试
///
/// 验证：
/// - 单个会话状态按 Codex 规范映射
/// - Flow 岛关闭态右侧聚合状态优先级正确
/// - `.runRight` 作为 running 状态的 canonical 表示
final class MascotStatusTests: XCTestCase {

    // MARK: - Session → MascotStatus

    func testActiveSessionMapsToRunRight() {
        let session = SessionState(
            sessionId: "active",
            cwd: "/tmp/project",
            phase: .processing
        )

        XCTAssertEqual(MascotStatus(session: session), .runRight)
    }

    func testCompactingSessionMapsToRunRight() {
        let session = SessionState(
            sessionId: "compacting",
            cwd: "/tmp/project",
            phase: .compacting
        )

        XCTAssertEqual(MascotStatus(session: session), .runRight)
    }

    func testWaitingForApprovalMapsToWaiting() {
        let session = SessionState(
            sessionId: "approval",
            cwd: "/tmp/project",
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertEqual(MascotStatus(session: session), .waiting)
    }

    func testWaitingForInputMapsToReview() {
        let session = SessionState(
            sessionId: "input",
            cwd: "/tmp/project",
            phase: .waitingForInput
        )

        XCTAssertEqual(MascotStatus(session: session), .review)
    }

    func testEndedWithErrorMapsToFailed() {
        let session = SessionState(
            sessionId: "error",
            cwd: "/tmp/project",
            phase: .ended,
            completedErrorToolIDs: ["tool-1"]
        )

        XCTAssertEqual(MascotStatus(session: session), .failed)
    }

    func testIdleSessionMapsToIdle() {
        let session = SessionState(
            sessionId: "idle",
            cwd: "/tmp/project",
            phase: .idle
        )

        XCTAssertEqual(MascotStatus(session: session), .idle)
    }

    // MARK: - Closed Notch Aggregate Status

    func testClosedNotchReturnsFailedForRecentTaskError() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: true,
                isAppActive: false
            ),
            .failed
        )
    }

    func testClosedNotchReturnsWavingForCompletedReady() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: true,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .waving
        )
    }

    func testClosedNotchReturnsWaitingForPendingPermission() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: true,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .waiting
        )
    }

    func testClosedNotchReturnsReviewForHumanIntervention() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: false,
                hasHumanIntervention: true,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .review
        )
    }

    func testClosedNotchReturnsRunRightForActivePhase() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .processing,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .runRight
        )
    }

    func testClosedNotchReturnsJumpingWhenAppActiveAndIdle() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .idle,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: true
            ),
            .jumping
        )
    }

    func testClosedNotchReturnsIdleWhenTrulyIdle() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .idle,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .idle
        )
    }
}
