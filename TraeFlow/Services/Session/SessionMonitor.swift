//
//  SessionMonitor.swift
//  TraeFlow
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class SessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    nonisolated static var isRunningUnderXCTest: Bool {
        Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var allSessions: [SessionState] = []
    private var maintenanceTask: Task<Void, Never>?
    private var questionDraftCache = SessionQuestionDraftCache()
    private var telemetryPendingAttentionSessionIDs: Set<String> = []

    init(observeSharedState: Bool = true) {
        guard observeSharedState else { return }

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        startEnergyAwareMaintenanceLoop()

        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisibleSessions()
            }
            .store(in: &cancellables)
    }

    deinit {
        maintenanceTask?.cancel()
    }

    // MARK: - Monitoring Lifecycle

    func questionDraft(sessionId: String, interventionId: String) -> SessionQuestionFormDraft? {
        questionDraftCache.draft(sessionId: sessionId, interventionId: interventionId)
    }

    func updateQuestionDraft(
        sessionId: String,
        interventionId: String,
        draft: SessionQuestionFormDraft
    ) {
        questionDraftCache.update(
            sessionId: sessionId,
            interventionId: interventionId,
            draft: draft
        )
    }

    func clearQuestionDraft(sessionId: String, interventionId: String) {
        questionDraftCache.clear(sessionId: sessionId, interventionId: interventionId)
    }

    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true
        if maintenanceTask == nil {
            startEnergyAwareMaintenanceLoop()
        }

        // Periodic liveness sweep: removes sessions whose Claude process has
        // died without delivering SessionEnd, plus garbage-collects sessions
        // already in .ended phase. See SessionStore.startLivenessSweep for
        // details.
        Task {
            await SessionStore.shared.startLivenessSweep()
        }

        let handleHookEvent: @Sendable (HookEvent) -> Void = { [self] event in
            Task { @MainActor in
                await self.handleIncomingHookEvent(event)
            }
        }

        HookSocketServer.shared.start(
            onEvent: handleHookEvent,
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func handleIncomingHookEvent(_ event: HookEvent) async {
        let effectiveEvent = event

        await SessionStore.shared.process(.hookReceived(effectiveEvent))

        if effectiveEvent.event == "PostToolUse",
           let toolUseId = effectiveEvent.toolUseId,
           let session = await SessionStore.shared.session(for: effectiveEvent.sessionId) {
            if session.activePermission?.toolUseId == toolUseId {
                HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                // Tool was approved externally (e.g. terminal) and completed.
                // Resolve the pending Island-side intervention.
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: effectiveEvent.sessionId, toolUseId: toolUseId)
                )
            } else if session.activePermission?.toolUseId != toolUseId {
                HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
            }
        }

        if effectiveEvent.event == "Stop", effectiveEvent.ingress != .remoteBridge {
            HookSocketServer.shared.cancelPendingPermissions(sessionId: effectiveEvent.sessionId)
        }
    }

    func stopMonitoring() {
        hasStarted = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        Task {
            await SessionStore.shared.stopLivenessSweep()
        }
        HookSocketServer.shared.stop()
    }

    private func startEnergyAwareMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let policy = await MainActor.run {
                    EnergyGovernor.shared.policy
                }

                guard let interval = policy.sessionMaintenanceInterval else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }

                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    guard let self else { return }
                    self.refreshVisibleSessions()
                }

                await SessionStore.shared.process(
                    .pruneTimedOutExternalContinuations(now: Date())
                )
                await SessionStore.shared.pruneOrphanedSessions()
            }
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String, forSession: Bool = false) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }
            let permission = Self.approvalToolUseId(for: session)
            await clearApprovalNotification(
                for: session,
                toolUseId: permission,
                decision: .approve
            )

            guard let permission else { return }

            if forSession, session.scopedApprovalAction == .autoApprove {
                await SessionStore.shared.process(
                    .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
                )
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission,
                    decision: "approveForSession"
                )
                await TelemetryService.shared.recordAttentionResolved(session, resolution: "approve_for_session")
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission,
                decision: "allow"
            )

            await TelemetryService.shared.recordAttentionResolved(session, resolution: "approve")
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }
            let permission = Self.approvalToolUseId(for: session)
            await clearApprovalNotification(
                for: session,
                toolUseId: permission,
                decision: .deny(reason: reason)
            )

            guard let permission else { return }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission,
                decision: "deny",
                reason: reason
            )

            await TelemetryService.shared.recordAttentionResolved(session, resolution: "deny")
        }
    }

    private enum ApprovalDecision {
        case approve
        case deny(reason: String?)
    }

    private nonisolated static func approvalToolUseId(for session: SessionState) -> String? {
        if let toolUseId = session.activePermission?.toolUseId,
           !toolUseId.isEmpty {
            return toolUseId
        }

        guard let intervention = session.intervention,
              intervention.kind == .approval else {
            return nil
        }

        return [
            intervention.metadata["originalToolUseId"],
            intervention.metadata["toolUseId"],
            intervention.metadata["tool_use_id"],
            intervention.id
        ].compactMap { candidate -> String? in
            guard let candidate else { return nil }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private func clearApprovalNotification(
        for session: SessionState,
        toolUseId: String?,
        decision: ApprovalDecision
    ) async {
        guard session.needsApprovalResponse else { return }
        guard let toolUseId else { return }

        switch decision {
        case .approve:
            await SessionStore.shared.process(
                .permissionApproved(sessionId: session.sessionId, toolUseId: toolUseId)
            )
        case .deny(let reason):
            await SessionStore.shared.process(
                .permissionDenied(sessionId: session.sessionId, toolUseId: toolUseId, reason: reason)
            )
        }
    }

    func answerIntervention(sessionId: String, answers: [String: [String]]) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else {
                return
            }

            guard let intervention = session.intervention,
                  intervention.kind == .question,
                  let updatedInput = updatedHookToolInput(
                    for: intervention,
                    answers: answers,
                    clientInfo: session.clientInfo
                  )
            else {
                return
            }

            // 使用正确的 toolUseId：优先使用 metadata 中保存的原始值
            let toolUseId = intervention.metadata["originalToolUseId"] ?? intervention.id
            HookSocketServer.shared.respondToIntervention(
                toolUseId: toolUseId,
                decision: "answer",
                updatedInput: updatedInput
            )

            await SessionStore.shared.process(
                .interventionResolved(
                    sessionId: sessionId,
                    nextPhase: .processing,
                    submittedAnswers: answers
                )
            )
            await TelemetryService.shared.recordAttentionResolved(session, resolution: "answer")
            HookWalkthroughDemoRunner.shared.completeIfNeeded(
                sessionId: sessionId,
                intervention: intervention
            )
        }
    }

    func sendSessionMessage(sessionId: String, text: String, expectedTurnId: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let session = await SessionStore.shared.session(for: sessionId) else {
            throw NSError(
                domain: "TraeFlow.SessionMonitor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Session not found."]
            )
        }

        if session.supportsTmuxCLIMessaging {
            guard let target = await findTmuxTarget(for: session) else {
                throw NSError(
                    domain: "TraeFlow.SessionMonitor",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Could not find the terminal pane for this session."]
                )
            }

            guard await ToolApprovalHandler.shared.sendMessage(trimmed, to: target) else {
                throw NSError(
                    domain: "TraeFlow.SessionMonitor",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to send the follow-up message to the terminal session."]
                )
            }

            return
        }

        guard session.isInTmux, let tty = session.tty else {
            throw NSError(
                domain: "TraeFlow.SessionMonitor",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Inline follow-up requires an active tmux-backed terminal session."]
            )
        }

        guard let target = await findTmuxTarget(tty: tty) else {
            throw NSError(
                domain: "TraeFlow.SessionMonitor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Could not find the terminal pane for this session."]
            )
        }

        guard await ToolApprovalHandler.shared.sendMessage(trimmed, to: target) else {
            throw NSError(
                domain: "TraeFlow.SessionMonitor",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to send the follow-up message to the terminal session."]
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionArchived(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        guard sessions != allSessions else { return }
        allSessions = sessions
        refreshVisibleSessions()
    }

    private func refreshVisibleSessions() {
        let visibleSessions = filteredVisibleSessions(from: allSessions)
        let pendingSessions = visibleSessions.filter { $0.needsAttention }
        recordNewAttentionRequests(in: pendingSessions)
        if visibleSessions != instances {
            instances = visibleSessions
        }
        if pendingSessions != pendingInstances {
            pendingInstances = pendingSessions
        }
    }

    private func recordNewAttentionRequests(in pendingSessions: [SessionState]) {
        let currentIDs = Set(pendingSessions.map(\.sessionId))
        let newSessions = pendingSessions.filter { !telemetryPendingAttentionSessionIDs.contains($0.sessionId) }
        telemetryPendingAttentionSessionIDs = currentIDs

        for session in newSessions {
            Task {
                await TelemetryService.shared.recordAttentionRequested(session)
            }
        }
    }

    private func filteredVisibleSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.filter { !$0.shouldHideFromPrimaryUI }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTTY = parts[1].replacingOccurrences(of: "/dev/", with: "")
                if paneTTY == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func findTmuxTarget(for session: SessionState) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        let normalizedTTY = session.tty?
            .replacingOccurrences(of: "/dev/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPaneID = session.clientInfo.tmuxPaneIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: [
                    "list-panes",
                    "-a",
                    "-F",
                    "#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_tty}"
                ]
            )

            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneID = parts[1]
                let paneTTY = parts.count >= 3
                    ? parts[2].replacingOccurrences(of: "/dev/", with: "")
                    : ""

                if normalizedPaneID?.isEmpty == false,
                   paneID == normalizedPaneID,
                   let target = TmuxTarget(from: target) {
                    return target
                }

                if normalizedTTY?.isEmpty == false,
                   paneTTY == normalizedTTY,
                   let target = TmuxTarget(from: target) {
                    return target
                }
            }
        } catch {
            // Fall back to the older pid/cwd matching path below.
        }

        if let pid = session.pid,
           let target = await TmuxController.shared.findTmuxTarget(forSessionPid: pid) {
            return target
        }

        return nil
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private enum HookAnswerEncodingStrategy {
        case questionText
    }

    private nonisolated static func answerEncodingStrategy(for clientInfo: SessionClientInfo?) -> HookAnswerEncodingStrategy {
        .questionText
    }

    nonisolated static func updatedHookToolInput(
        rawJSON: String,
        answers: [String: [String]],
        clientInfo: SessionClientInfo? = nil
    ) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var updated = payload
        let questions = payload["questions"] as? [[String: Any]] ?? []
        var encodedAnswers: [String: Any] = [:]

        let encodingStrategy = answerEncodingStrategy(for: clientInfo)

        for (index, question) in questions.enumerated() {
            let lookupKeys = [
                question["id"] as? String,
                question["question"] as? String,
                "\(index)"
            ].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            guard let values = lookupKeys.compactMap({ answers[$0] }).first, !values.isEmpty else { continue }
            let encodedValue: Any = values.count == 1 ? values[0] : values
            switch encodingStrategy {
            case .questionText:
                let outputKey = (question["question"] as? String)
                    ?? (question["prompt"] as? String)
                    ?? (question["id"] as? String)
                    ?? "\(index)"
                guard !outputKey.isEmpty else { continue }
                encodedAnswers[outputKey] = encodedValue
            }
        }

        updated["answers"] = encodedAnswers
        return updated
    }

    private func updatedHookToolInput(
        for intervention: SessionIntervention,
        answers: [String: [String]],
        clientInfo: SessionClientInfo
    ) -> [String: Any]? {
        guard let rawJSON = intervention.metadata["toolInputJSON"] else {
            return nil
        }

        var updatedInput = Self.updatedHookToolInput(rawJSON: rawJSON, answers: answers, clientInfo: clientInfo)
        if let transcriptCallId = intervention.metadata["transcriptCallId"], !transcriptCallId.isEmpty {
            updatedInput?["tool_call_id"] = transcriptCallId
            updatedInput?["call_id"] = transcriptCallId
        }
        return updatedInput
    }

    nonisolated static func defaultAnswers(for intervention: SessionIntervention) -> [String: [String]] {
        intervention.questions.reduce(into: [String: [String]]()) { partial, question in
            guard let firstOption = question.options.first?.title, !firstOption.isEmpty else { return }
            partial[question.id] = [firstOption]
        }
    }

    private nonisolated static func resolvePendingApprovalToolUseId(
        for sessionId: String,
        fallback: String?
    ) async -> String? {
        if let toolUseId = await SessionStore.shared.session(for: sessionId)?.activePermission?.toolUseId,
           !toolUseId.isEmpty {
            return toolUseId
        }

        guard let fallback, !fallback.isEmpty else { return nil }
        return fallback
    }

}
