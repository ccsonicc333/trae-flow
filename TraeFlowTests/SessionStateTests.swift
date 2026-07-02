import Foundation
import XCTest
@testable import TRAE_FLOW

final class SessionStateTests: XCTestCase {
    func testClosedNotchMascotStatusReturnsRunRightForActiveSession() {
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

    func testClosedNotchMascotStatusReturnsWaitingWhileApprovalIsPending() {
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

    func testClosedNotchMascotStatusReturnsIdleWhenOnlyEndedSessionRemains() {
        XCTAssertEqual(
            MascotStatus.closedNotchStatus(
                representativePhase: .ended,
                hasPendingPermission: false,
                hasHumanIntervention: false,
                hasCompletedReady: false,
                hasRecentTaskError: false,
                isAppActive: false
            ),
            .idle
        )
    }

    func testDisplayTitleFallsBackToSummaryThenFirstUserMessage() {
        let withSummary = SessionState(
            sessionId: "summary-session",
            cwd: "/tmp/project",
            conversationInfo: ConversationInfo(
                summary: "Ship release",
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: "Help me ship",
                lastUserMessageDate: nil
            )
        )
        let withFirstUserMessage = SessionState(
            sessionId: "first-user-session",
            cwd: "/tmp/project",
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: "Fix the menu bar bug",
                lastUserMessageDate: nil
            )
        )

        XCTAssertEqual(withSummary.displayTitle, "Ship release")
        XCTAssertEqual(withFirstUserMessage.displayTitle, "Fix the menu bar bug")
    }

    func testActiveQueueSortActivityDatePrefersLiveActivityOverOlderTranscriptUserTimestamp() {
        let now = Date()
        let session = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Working",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do the work",
                lastUserMessageDate: now.addingTimeInterval(-120)
            ),
            lastActivity: now
        )

        XCTAssertEqual(session.queueSortActivityDate, now)
    }

    func testBoundedDisplayTextKeepsShortTextUnchanged() {
        XCTAssertEqual(
            SessionTextSanitizer.boundedDisplayText(
                "short detail",
                maxCharacters: 20,
                truncationNotice: "[truncated]"
            ),
            "short detail"
        )
    }

    func testBoundedDisplayTextTruncatesLongTextWithNotice() {
        let result = SessionTextSanitizer.boundedDisplayText(
            "abcdefghijklmnopqrstuvwxyz",
            maxCharacters: 8,
            truncationNotice: "[truncated]"
        )

        XCTAssertEqual(result, "abcdefgh\n\n[truncated]")
    }

    func testIdleQueueSortActivityDateStillUsesLastUserMessageDateWhenPresent() {
        let now = Date()
        let lastUserMessageDate = now.addingTimeInterval(-60)
        let session = SessionState(
            sessionId: "idle-session",
            cwd: "/tmp/project",
            phase: .idle,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Done",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Finish the task",
                lastUserMessageDate: lastUserMessageDate
            ),
            lastActivity: now
        )

        XCTAssertEqual(session.queueSortActivityDate, lastUserMessageDate)
    }

    func testActiveSessionSortDoesNotDropBehindOlderIdleSessionWhenTranscriptBackfills() {
        let now = Date()
        let activeSession = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            conversationInfo: ConversationInfo(
                summary: nil,
                lastMessage: "Working",
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: "Do the work",
                lastUserMessageDate: now.addingTimeInterval(-120)
            ),
            lastActivity: now
        )
        let idleSession = SessionState(
            sessionId: "idle-session",
            cwd: "/tmp/project",
            phase: .idle,
            lastActivity: now.addingTimeInterval(-20)
        )

        XCTAssertTrue(activeSession.shouldSortBeforeInQueue(idleSession))
    }

    func testActiveSessionSortsAheadOfWaitingForInputSession() {
        let now = Date()
        let activeSession = SessionState(
            sessionId: "active-session",
            cwd: "/tmp/project",
            phase: .processing,
            lastActivity: now
        )
        let waitingSession = SessionState(
            sessionId: "waiting-session",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            lastActivity: now.addingTimeInterval(-5)
        )

        XCTAssertTrue(activeSession.shouldSortBeforeInQueue(waitingSession))
        XCTAssertFalse(waitingSession.shouldSortBeforeInQueue(activeSession))
    }

    func testCompactHookMessageNormalizesWhitespace() {
        let session = SessionState(
            sessionId: "hook-message",
            cwd: "/tmp/project",
            latestHookMessage: "  Claude\n   needs   approval  "
        )

        XCTAssertEqual(session.compactHookMessage, "Claude needs approval")
    }

    func testCompactHookMessageHidesStopMessage() {
        let session = SessionState(
            sessionId: "stop-hook-message",
            cwd: "/tmp/project",
            latestHookMessage: "  Stop  "
        )

        XCTAssertNil(session.compactHookMessage)
    }

    func testWaitingForApprovalPhaseSurfacesPendingToolDetails() {
        let permission = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: [
                "command": AnyCodable("swift test"),
                "timeout": AnyCodable(30)
            ],
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let session = SessionState(
            sessionId: "approval-session",
            cwd: "/tmp/project",
            phase: .waitingForApproval(permission)
        )

        XCTAssertTrue(session.needsApprovalResponse)
        XCTAssertEqual(session.pendingToolName, "Bash")
        XCTAssertEqual(session.pendingToolId, "tool-1")
        XCTAssertEqual(session.pendingToolInput, "command: swift test\ntimeout: 30")
    }

    func testRoutePromptsToTerminalKeepsApprovalControlsWhenIslandCanRespond() {
        let session = SessionState(
            sessionId: "approval-session",
            cwd: "/tmp/project",
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertFalse(session.shouldSuppressInAppPromptControls(routePromptsToTerminal: false))
        XCTAssertFalse(session.shouldSuppressInAppPromptControls(routePromptsToTerminal: true))
    }

    func testRoutePromptsToTerminalSuppressesApprovalControlsWithoutResponseTarget() {
        let session = SessionState(
            sessionId: "approval-session",
            cwd: "/tmp/project",
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertFalse(session.canSubmitApprovalFromIsland)
        XCTAssertTrue(session.shouldSuppressInAppPromptControls(routePromptsToTerminal: true))
    }

    func testRoutePromptsToTerminalStillSuppressesQuestionControls() {
        let intervention = SessionIntervention(
            id: "question-1",
            kind: .question,
            title: "Question",
            message: "Pick one",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
        let session = SessionState(
            sessionId: "question-session",
            cwd: "/tmp/project",
            intervention: intervention,
            phase: .waitingForInput
        )

        XCTAssertTrue(session.shouldSuppressInAppPromptControls(routePromptsToTerminal: true))
    }

    func testEventSuppressedPromptControlsRemainNotificationEligible() {
        let session = SessionState(
            sessionId: "terminal-routed-question",
            cwd: "/tmp/project",
            suppressInAppPromptControls: true,
            phase: .waitingForInput
        )

        XCTAssertTrue(session.needsPromptNotification)
        XCTAssertFalse(session.needsApprovalResponse)
        XCTAssertFalse(session.needsQuestionResponse)
    }

    func testTraeWaitingForApprovalWithoutSessionScopeDoesNotExposeAutoApproveAction() {
        let session = SessionState(
            sessionId: "trae-no-session-scope",
            cwd: "/tmp/project",
            provider: .trae,
            clientInfo: SessionClientInfo(kind: .trae, name: "TRAE"),
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertNil(session.scopedApprovalAction)
        XCTAssertFalse(session.supportsSessionScopedApproval)
    }

    func testTraeWaitingForApprovalUsesBridgeSessionScopeFlagForAutoApproveAction() {
        let intervention = SessionIntervention(
            id: "tool-1",
            kind: .approval,
            title: "TRAE needs approval",
            message: "Run Bash?",
            options: [],
            questions: [],
            supportsSessionScope: true,
            metadata: [:]
        )
        let session = SessionState(
            sessionId: "trae-auto-approve",
            cwd: "/tmp/project",
            provider: .trae,
            clientInfo: SessionClientInfo(kind: .trae, name: "TRAE"),
            intervention: intervention,
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertEqual(session.scopedApprovalAction, .autoApprove)
        XCTAssertTrue(session.supportsSessionScopedApproval)
        XCTAssertEqual(SessionScopedApprovalAction.autoApprove.buttonTitleKey, "Always Allow")
        XCTAssertEqual(SessionScopedApprovalAction.autoApprove.compactButtonTitleKey, "Always")
    }

    func testTraeWaitingForApprovalUsesBridgeApproveForSessionOptionForAutoApproveAction() {
        let intervention = SessionIntervention(
            id: "tool-1",
            kind: .approval,
            title: "TRAE needs approval",
            message: "Run Bash?",
            options: [
                SessionInterventionOption(id: "approve", title: "Allow Once", detail: nil),
                SessionInterventionOption(id: "approveForSession", title: "Allow for Session", detail: nil),
                SessionInterventionOption(id: "deny", title: "Deny", detail: nil)
            ],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
        let session = SessionState(
            sessionId: "trae-auto-approve-from-option",
            cwd: "/tmp/project",
            provider: .trae,
            clientInfo: SessionClientInfo(kind: .trae, name: "TRAE"),
            intervention: intervention,
            phase: .waitingForApproval(
                PermissionContext(toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )
        )

        XCTAssertEqual(session.scopedApprovalAction, .autoApprove)
        XCTAssertTrue(session.supportsSessionScopedApproval)
    }

    func testIdleSessionAutoArchivesFromPrimaryUIAfterThirtyMinutes() {
        let session = SessionState(
            sessionId: "idle-auto-archive",
            cwd: "/tmp/project",
            lastActivity: Date().addingTimeInterval(-(31 * 60))
        )

        XCTAssertTrue(session.shouldAutoArchiveFromPrimaryUI)
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
        XCTAssertFalse(session.shouldUseMinimalCompactPresentation)
    }

    func testAttentionSessionStaysVisibleAfterThirtyMinutes() {
        let permission = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let session = SessionState(
            sessionId: "attention-visible",
            cwd: "/tmp/project",
            phase: .waitingForApproval(permission),
            lastActivity: Date().addingTimeInterval(-(31 * 60))
        )

        XCTAssertFalse(session.shouldAutoArchiveFromPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    func testEndedSessionShowsArchiveActionAfterTenMinutes() {
        let session = SessionState(
            sessionId: "ended-archive-eligible",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: Date().addingTimeInterval(-(11 * 60))
        )

        XCTAssertTrue(session.shouldShowArchiveActionInPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
        XCTAssertFalse(session.shouldUseMinimalCompactPresentation)
    }

    func testRecentlyEndedSessionDoesNotShowArchiveActionYet() {
        let session = SessionState(
            sessionId: "ended-archive-waiting",
            cwd: "/tmp/project",
            phase: .ended,
            lastActivity: Date().addingTimeInterval(-(9 * 60))
        )

        XCTAssertFalse(session.shouldShowArchiveActionInPrimaryUI)
        XCTAssertFalse(session.shouldHideFromPrimaryUI)
    }

    func testIdleSessionStillShowsArchiveActionImmediately() {
        let session = SessionState(
            sessionId: "idle-archive-immediate",
            cwd: "/tmp/project",
            phase: .idle,
            lastActivity: Date().addingTimeInterval(-60)
        )

        XCTAssertTrue(session.shouldShowArchiveActionInPrimaryUI)
    }

    func testNativeRuntimeSessionExposesTerminateActionUntilEnded() {
        let activeSession = SessionState(
            sessionId: "native-active",
            cwd: "/tmp/project",
            ingress: .nativeRuntime,
            phase: .processing
        )
        let endedSession = SessionState(
            sessionId: "native-ended",
            cwd: "/tmp/project",
            ingress: .nativeRuntime,
            phase: .ended
        )

        XCTAssertTrue(activeSession.isNativeRuntimeSession)
        XCTAssertTrue(activeSession.shouldShowTerminateActionInPrimaryUI)
        XCTAssertTrue(endedSession.isNativeRuntimeSession)
        XCTAssertFalse(endedSession.shouldShowTerminateActionInPrimaryUI)
    }

    func testRemoteBridgeSessionIsMarkedRemote() {
        let session = SessionState(
            sessionId: "remote-bridge-session",
            cwd: "/tmp/project",
            ingress: .remoteBridge
        )

        XCTAssertTrue(session.isRemoteSession)
    }

    func testSSHContextSessionIsMarkedRemote() {
        let session = SessionState(
            sessionId: "ssh-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .trae,
                name: "TRAE",
                transport: "ssh-remote",
                remoteHost: "devbox"
            )
        )

        XCTAssertTrue(session.isRemoteSession)
    }

    func testLocalSessionIsNotMarkedRemote() {
        let session = SessionState(
            sessionId: "local-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .trae,
                name: "TRAE",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertFalse(session.isRemoteSession)
    }

    func testSessionListPrimaryTapKeepsCompactRowsExpandable() {
        XCTAssertEqual(
            SessionListRowClickBehavior.primaryTapAction(isMinimalCompactPresentation: true),
            .toggleExpanded
        )
        XCTAssertEqual(
            SessionListRowClickBehavior.primaryTapAction(isMinimalCompactPresentation: false),
            .activate
        )
    }

    func testSessionListDoubleTapActivatesWhenNoInAppResponseIsPending() {
        XCTAssertEqual(
            SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: false),
            .activate
        )
        XCTAssertEqual(
            SessionListRowClickBehavior.doubleTapAction(needsInAppResponse: true),
            .chat
        )
    }

    func testTerminalHostedGhosttySessionShowsSourceBadge() {
        let session = SessionState(
            sessionId: "ghostty-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .trae,
                name: "TRAE",
                originator: "Ghostty",
                terminalBundleIdentifier: "com.mitchellh.ghostty",
                terminalProgram: "ghostty"
            )
        )

        XCTAssertEqual(session.terminalSourceBadgeLabel, "Ghostty")
        XCTAssertEqual(session.clientInfo.terminalContextSummary, "Ghostty")
    }

    func testTerminalHostedWezTermSessionShowsSourceBadge() {
        let session = SessionState(
            sessionId: "wezterm-session",
            cwd: "/tmp/project",
            clientInfo: SessionClientInfo(
                kind: .trae,
                name: "TRAE",
                originator: "WezTerm",
                terminalBundleIdentifier: "com.github.wez.wezterm",
                terminalProgram: "WezTerm"
            )
        )

        XCTAssertEqual(session.terminalSourceBadgeLabel, "WezTerm")
        XCTAssertEqual(session.clientInfo.terminalContextSummary, "WezTerm")
    }

    func testTerminalContextSummaryDeduplicatesTerminalOriginatorAndRemoteContext() {
        let clientInfo = SessionClientInfo(
            kind: .trae,
            name: "TRAE",
            originator: "Ghostty",
            transport: "ssh-remote",
            remoteHost: "devbox",
            terminalBundleIdentifier: "com.mitchellh.ghostty",
            terminalProgram: "ghostty"
        )

        XCTAssertEqual(clientInfo.terminalContextSummary, "Ghostty · ssh-remote@devbox")
    }

    func testTerminalFallbackActivationRestoresGhosttyFamilyWindows() {
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.cmuxterm.app"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldActivateAllWindowsForTerminalFallback(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
    }

    func testTerminalFallbackDoesNotClaimExactITermOrTerminalActivation() {
        XCTAssertFalse(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertFalse(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.apple.Terminal"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertTrue(
            SessionLauncher.shouldUseProcessActivationForTerminalFallback(
                bundleIdentifier: nil
            )
        )
    }

    func testGhosttySelectionScriptPrefersStableTerminalIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertTrue(script.contains("set targetTerminalID to \"65A2028F-A93C-48E0-B46A-3F4C20C94B81\""))
        XCTAssertTrue(script.contains("set targetTerminal to first terminal whose id is targetTerminalID"))
        XCTAssertTrue(script.contains("focus targetTerminal"))

        let identifierIndex = try! XCTUnwrap(lines.firstIndex(of: "set targetTerminalID to \"65A2028F-A93C-48E0-B46A-3F4C20C94B81\""))
        let workspaceIndex = try! XCTUnwrap(lines.firstIndex(of: "set targetPath to \"/tmp/demo\""))
        XCTAssertLessThan(identifierIndex, workspaceIndex)
    }

    func testGhosttySelectionScriptFallsBackToWorkspaceMatchingWithoutIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: nil,
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("targetTerminalID"))
        XCTAssertTrue(script.contains("set targetPath to \"/tmp/demo\""))
        XCTAssertTrue(script.contains("focus (item 1 of exactMatches)"))
    }

    func testGhosttySelectionScriptIgnoresNonUUIDTerminalIdentifier() {
        let lines = TerminalSessionFocuser.ghosttySelectionScriptLines(
            terminalSessionIdentifier: "ghostty-terminal-1",
            workspacePath: "/tmp/demo"
        )
        let script = lines.joined(separator: "\n")

        XCTAssertFalse(script.contains("targetTerminalID"))
        XCTAssertTrue(script.contains("set targetPath to \"/tmp/demo\""))
    }
}
