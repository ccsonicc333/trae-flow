import Foundation
import IslandShared
@testable import IslandApp
import Testing

@Test
func sessionStorePrioritizesAttentionSessions() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "PostToolUse",
            sessionKey: "trae:1",
            title: "Regular",
            preview: "working",
            status: SessionStatus(kind: .active)
        )
    )
    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "PermissionRequest",
            sessionKey: "trae:2",
            title: "Needs approval",
            preview: "approve",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: InterventionRequest(sessionID: "trae:2", kind: .approval, title: "Approval", message: "Approve?")
        )
    )

    let sessions = await MainActor.run { recorder.sessions }
    #expect(sessions.first?.id == "trae:2")
}

@Test
func sessionStoreClearingInterventionResetsStatusButKeepsSessionVisible() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }
    let request = InterventionRequest(
        sessionID: "trae:approval",
        kind: .approval,
        title: "Approval",
        message: "Approve?"
    )

    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "PermissionRequest",
            sessionKey: "trae:approval",
            title: "Approval",
            preview: "Approve?",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: request,
            expectsResponse: true
        )
    )
    await store.clearIntervention(for: "trae:approval")

    let session = try await MainActor.run {
        try #require(recorder.sessions.first(where: { $0.id == "trae:approval" }))
    }
    #expect(session.intervention == nil)
    #expect(session.status.kind == .active)
}

@Test
func sessionStoreKeepsAttentionSnapshotsExpandedEvenAfterManualCollapse() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "PermissionRequest",
            sessionKey: "trae:attention",
            title: "Approval",
            preview: "Approve?",
            status: SessionStatus(kind: .waitingForApproval),
            intervention: InterventionRequest(
                sessionID: "trae:attention",
                kind: .approval,
                title: "Approval",
                message: "Approve?"
            ),
            expectsResponse: true
        )
    )
    await store.setExpanded(false)

    let snapshot = await MainActor.run { recorder.snapshot }
    #expect(snapshot.isExpanded)
    #expect(snapshot.highlightedIntervention?.sessionID == "trae:attention")
}

@Test
func sessionStoreMergesMetadataAcrossUpdates() async throws {
    let recorder = await MainActor.run { SnapshotRecorder() }
    let store = SessionStore { snapshot in
        recorder.snapshot = snapshot
    }

    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "SessionStart",
            sessionKey: "trae:merge",
            title: "Session",
            preview: "Started",
            cwd: "/tmp/one",
            status: SessionStatus(kind: .thinking),
            metadata: ["client_kind": "trae"],
            sentAt: .distantPast
        )
    )
    await store.ingest(
        BridgeEnvelope(
            provider: .trae,
            eventType: "PostToolUse",
            sessionKey: "trae:merge",
            preview: "Updated",
            cwd: "/tmp/two",
            status: SessionStatus(kind: .active),
            terminalContext: TerminalContext(terminalProgram: "iTerm.app"),
            metadata: ["client_name": "Trae"]
        )
    )

    let session = try await MainActor.run {
        try #require(recorder.sessions.first(where: { $0.id == "trae:merge" }))
    }
    #expect(session.preview == "Updated")
    #expect(session.cwd == "/tmp/two")
    #expect(session.terminalContext.terminalProgram == "iTerm.app")
    #expect(session.metadata["client_kind"] == "trae")
    #expect(session.metadata["client_name"] == "Trae")
}
