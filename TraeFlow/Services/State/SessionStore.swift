//
//  SessionStore.swift
//  TraeFlow
//
//  Central state manager for all tracked sessions.
//  Single source of truth - all state mutations flow through process().
//

import AppKit
import Combine
import Darwin
import Foundation
import os.log

/// Central state manager for all tracked sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    struct SessionDiagnosticsSnapshot: Codable, Sendable {
        let sessionId: String
        let provider: String
        let ingress: String
        let phase: String
        let cwd: String
        let projectName: String
        let displayTitle: String
        let effectiveDisplayTitle: String
        let sessionName: String?
        let previewText: String?
        let lastMessage: String?
        let clientKind: String
        let clientName: String?
        let sessionFilePath: String?
        let presentationMode: String
        let usesTitleOnlySubagentPresentation: Bool
        let linkedParentSessionId: String?
        let linkedSubagentDisplayTitle: String?
        let hasIntervention: Bool
        let chatItemCount: Int
        let lastActivity: Date
        let createdAt: Date
    }

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "ai.traeflow.app", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Persisted session associations used to restore client routing across relaunches.
    private var persistedAssociations: [String: PersistedSessionAssociation] = [:]
    private var didLoadPersistedAssociations = false
    private var pendingAssociationSave: Task<Void, Never>?
    private var pendingHookResponseCancellationHandler: @Sendable (String, SessionIngress) -> Void = {
        SessionStore.cancelPendingHookResponse(toolUseId: $0, ingress: $1)
    }

    /// Periodic sweep that removes sessions whose Claude process has died
    /// without delivering `SessionEnd` (Ctrl-C kill, OOM, terminal closed) and
    /// garbage-collects sessions already in `.ended` phase. Borrowed from
    /// `farouqaldori/vibe-notch`'s liveness check; runs every 5 s while the
    /// monitor is started.
    private var livenessSweepTask: Task<Void, Never>?
    private let livenessSweepIntervalNs: UInt64 = 5_000_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])
    private var lastPublishedSessions: [SessionState] = []

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        if event.shouldEmitProcessingLog {
            if let sessionPrefix = event.processingLogSessionPrefix {
                Self.logger.debug(
                    "Processing event=\(event.processingLogName, privacy: .public) session=\(sessionPrefix, privacy: .public)"
                )
            } else {
                Self.logger.debug("Processing event=\(event.processingLogName, privacy: .public)")
            }
        }

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionAutoApprovalChanged(let sessionId, let isEnabled):
            processPermissionAutoApprovalChanged(sessionId: sessionId, isEnabled: isEnabled)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .interventionResolved(let sessionId, let nextPhase, let submittedAnswers):
            await processInterventionResolved(
                sessionId: sessionId,
                nextPhase: nextPhase,
                submittedAnswers: submittedAnswers
            )

        case .pruneTimedOutExternalContinuations(let now):
            await processTimedOutExternalContinuations(now: now)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .sessionArchived(let sessionId):
            await archiveSession(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    func setPendingHookResponseCancellationHandlerForTesting(
        _ handler: (@Sendable (String, SessionIngress) -> Void)?
    ) {
        pendingHookResponseCancellationHandler = handler ?? {
            SessionStore.cancelPendingHookResponse(toolUseId: $0, ingress: $1)
        }
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId

        if shouldIgnoreClaudeAskUserQuestionPermissionRequest(event) {
            Self.logger.notice(
                "Ignoring duplicate Claude AskUserQuestion permission session=\(sessionId, privacy: .public)"
            )
            return
        }
        var session = sessions[sessionId] ?? createSession(from: event)

        // Persist the session before await points so concurrent events (via actor
        // reentrancy) find it instead of creating a duplicate.  This avoids the
        // race where a Stop event runs during a Notification's await, ends its own
        // fresh copy, and then the Notification resumes against an already-ended
        // session.
        let isNewSession = sessions[sessionId] == nil
        if isNewSession {
            sessions[sessionId] = session
            endOrphanedSessions(sameProviderAs: session, newSessionId: sessionId)
            Task {
                await TelemetryService.shared.recordSessionDetected(session)
            }
        }

        let tree = (event.pid != nil || event.tty != nil) ? ProcessTreeBuilder.shared.buildTree() : [:]

        session.provider = event.provider
        session.clientInfo = session.clientInfo.merged(with: event.clientInfo)
        session.ingress = event.ingress
        applyHookWorkspace(event.cwd, to: &session)
        session.pid = event.pid
        if let pid = event.pid {
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        if let runtimeClientInfo = await runtimeClientInfo(for: session, tree: tree) {
            session.clientInfo = session.clientInfo.merged(with: runtimeClientInfo)
        }
        await TerminalAutomationPermissionCoordinator.shared.prepareIfNeeded(
            provider: event.provider,
            clientInfo: session.clientInfo,
            sessionId: sessionId
        )

        // After the await points another event may have mutated the persisted
        // copy (actor reentrancy).  Merge the enriched client info into the
        // latest snapshot so we don't silently discard phase / chatItem changes
        // made by the concurrent event.
        if let latest = sessions[sessionId], latest.lastActivity > session.lastActivity {
            session = latest
            // Re-apply enrichment
            session.clientInfo = session.clientInfo.merged(with: event.clientInfo)
            applyHookWorkspace(event.cwd, to: &session)
        }

        let previousLastActivity = session.lastActivity
        if !(event.status == "ended" && session.phase == .ended) {
            session.lastActivity = Date()
        }
        if let hookMessage = Self.normalizedHookMessage(event.message) {
            session.latestHookMessage = hookMessage
        }
        if let envelopeJSON = event.lastEnvelopeJSON {
            session.lastEnvelopeJSON = envelopeJSON
        }

        let shouldPreserveEndedStopForAnsweredQuestion =
            event.status == "ended"
            && event.event == "Stop"
            && session.intervention?.awaitsExternalContinuation == true
            && session.clientInfo.prefersAnsweredQuestionFollowupAction

        let previousPendingHookResponse = pendingHookResponse(in: session)

        if event.status == "ended", !shouldPreserveEndedStopForAnsweredQuestion {
            markSessionEnded(&session)
            cancelOrphanedPendingHookResponse(
                previousPendingHookResponse,
                in: &session,
                reason: event.event
            )
            sessions[sessionId] = session
            scheduleFinalSessionSync(for: session)
            Task {
                await TelemetryService.shared.recordSessionCompleted(session)
            }
            return
        }

        let newPhase: SessionPhase = shouldPreserveEndedStopForAnsweredQuestion
            ? .waitingForInput
            : event.determinePhase()
        let intervention = event.intervention
        let preservedPendingApproval = preservedPendingApprovalContext(
            for: event,
            session: session,
            newPhase: newPhase
        )
        let shouldSuppressPendingApprovalCompletion = shouldSuppressPendingApprovalCompletion(
            for: event,
            session: session
        )
        let shouldClearCurrentIntervention = shouldClearIntervention(
            for: event,
            newPhase: newPhase,
            currentIntervention: session.intervention
        )
        let hasIncomingIntervention: Bool
        if case .some = intervention {
            hasIncomingIntervention = true
        } else {
            hasIncomingIntervention = false
        }
        let shouldPreserveActiveQuestionIntervention = session.intervention?.kind == .question
            && !hasIncomingIntervention
            && newPhase != .waitingForInput
            && !shouldClearCurrentIntervention

        if let preservedPendingApproval {
            Self.logger.debug(
                "Preserving waitingForApproval for \(sessionId.prefix(8), privacy: .public) on \(event.event, privacy: .public)"
            )
            session.phase = .waitingForApproval(preservedPendingApproval)
        } else if shouldPreserveActivePhaseDuringApparentIdle(
            session: session,
            incomingPhase: newPhase,
            referenceDate: Date(),
            previousLastActivity: previousLastActivity
        ) {
            session.lastActivity = previousLastActivity
        } else if let resumedPhase = resumedPhaseForFreshHookActivity(
            currentPhase: session.phase,
            incomingPhase: newPhase,
            event: event
        ) {
            session.phase = resumedPhase
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug(
                "Invalid transition current=\(session.phase.description, privacy: .public) next=\(newPhase.description, privacy: .public), ignoring"
            )
        }

        if let intervention {
            if shouldQueuePendingQuestionIntervention(intervention, in: session) {
                enqueuePendingQuestionIntervention(intervention, in: &session)
            } else if shouldPreserveInlineIntervention(
                current: session.intervention,
                proposed: intervention
            ) {
                // A parsed inline question should win over a fallback notification reminder.
            } else {
                session.intervention = intervention
            }

            if intervention.kind == .question {
                session.phase = .waitingForInput
            }
        } else if shouldPreserveActiveQuestionIntervention {
            session.phase = .waitingForInput
        } else if shouldClearCurrentIntervention {
            clearCurrentIntervention(in: &session, nextPhase: session.phase)
        }

        if event.suppressInAppPrompt {
            session.suppressInAppPromptControls =
                session.needsApprovalResponse || session.phase == .waitingForInput || session.intervention != nil
        } else if !session.needsApprovalResponse, case .none = session.intervention {
            session.suppressInAppPromptControls = false
        } else if event.expectsResponse || hasIncomingIntervention {
            session.suppressInAppPromptControls = false
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(
            event: event,
            session: &session,
            preservingPendingApproval: shouldSuppressPendingApprovalCompletion
        )
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        cancelOrphanedPendingHookResponse(
            previousPendingHookResponse,
            in: &session,
            reason: event.event
        )

        sessions[sessionId] = session

        if event.shouldSyncFile {
            scheduleFileSync(
                sessionId: sessionId,
                cwd: event.cwd,
                explicitFilePath: session.clientInfo.sessionFilePath
            )
        }
    }

    private nonisolated func shouldPreserveInlineIntervention(
        current: SessionIntervention?,
        proposed: SessionIntervention
    ) -> Bool {
        false
    }

    private func createSession(from event: HookEvent) -> SessionState {
        let restoredAssociation = persistedAssociation(for: event.provider, sessionId: event.sessionId)
        let resolvedCwd = event.cwd.isEmpty ? (restoredAssociation?.cwd ?? "") : event.cwd
        let restoredCwdMatches = Self.normalizedPath(restoredAssociation?.cwd ?? "")
            == Self.normalizedPath(resolvedCwd)
        let projectName = (restoredCwdMatches ? restoredAssociation?.projectName : nil)
            ?? Self.projectName(for: resolvedCwd, fallback: event.provider.displayName)
        let restoredClientInfo = restoredAssociation?.clientInfo ?? SessionClientInfo.default(for: event.provider)
        let resolvedClientInfo = restoredClientInfo.merged(with: event.clientInfo)

        return SessionState(
            sessionId: event.sessionId,
            cwd: resolvedCwd,
            projectName: projectName,
            provider: event.provider,
            clientInfo: resolvedClientInfo,
            ingress: event.ingress,
            sessionName: restoredCwdMatches ? restoredAssociation?.sessionName : nil,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private nonisolated func applyHookWorkspace(_ incomingCwd: String, to session: inout SessionState) {
        guard Self.shouldAdoptHookWorkspace(current: session.cwd, incoming: incomingCwd) else {
            return
        }

        let previousProjectName = session.projectName
        let previousCwd = session.cwd
        session.cwd = incomingCwd
        session.projectName = Self.projectName(for: incomingCwd, fallback: session.provider.displayName)
        if session.sessionName == previousProjectName
            || session.sessionName == Self.projectName(for: previousCwd, fallback: previousProjectName) {
            session.sessionName = nil
        }
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        processToolTracking(event: event, session: &session, preservingPendingApproval: false)
    }

    private func processToolTracking(
        event: HookEvent,
        session: inout SessionState,
        preservingPendingApproval: Bool
    ) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if preservingPendingApproval {
                return
            }
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func shouldSuppressPendingApprovalCompletion(for event: HookEvent, session: SessionState) -> Bool {
        guard event.event == "PostToolUse",
              let activePermission = session.activePermission,
              let toolUseId = event.toolUseId
        else {
            return false
        }

        return activePermission.toolUseId == toolUseId
    }

    private func preservedPendingApprovalContext(
        for event: HookEvent,
        session: SessionState,
        newPhase: SessionPhase
    ) -> PermissionContext? {
        guard !newPhase.isWaitingForApproval,
              event.event != "PermissionRequest",
              event.event != "SessionEnd",
              event.event != "Stop",
              event.status != "ended",
              !event.isAskUserQuestionRequest,
              case .none = event.intervention else {
            return nil
        }

        if let activePermission = session.activePermission {
            return activePermission
        }

        return pendingApprovalContext(in: session, preferring: event.toolUseId)
    }

    private func pendingApprovalContext(
        in session: SessionState,
        preferring toolUseId: String?
    ) -> PermissionContext? {
        if let toolUseId,
           let preferredMatch = pendingApprovalItem(in: session, matching: toolUseId) {
            return preferredMatch
        }

        return pendingApprovalItem(in: session)
    }

    private func pendingApprovalItem(
        in session: SessionState,
        matching toolUseId: String? = nil
    ) -> PermissionContext? {
        let pendingTool = session.chatItems
            .reversed()
            .first { item in
                guard case .toolCall(let tool) = item.type,
                      tool.status == .waitingForApproval else {
                    return false
                }
                guard let toolUseId else {
                    return true
                }
                return item.id == toolUseId
            }

        guard let pendingTool,
              case .toolCall(let tool) = pendingTool.type else {
            return nil
        }

        return PermissionContext(
            toolUseId: pendingTool.id,
            toolName: tool.name,
            toolInput: nil,
            receivedAt: pendingTool.timestamp
        )
    }

    private struct PendingHookResponse {
        let toolUseId: String
        let kind: SessionInterventionKind
        let ingress: SessionIngress
    }

    private nonisolated static func cancelPendingHookResponse(
        toolUseId: String,
        ingress: SessionIngress
    ) {
        Task { @MainActor in
            switch ingress {
            case .remoteBridge:
                break
            case .hookBridge:
                HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
            case .nativeRuntime, .desktopAppMonitor:
                break
            }
        }
    }

    private nonisolated func shouldQueuePendingQuestionIntervention(
        _ intervention: SessionIntervention,
        in session: SessionState
    ) -> Bool {
        intervention.kind == .question
            && intervention.supportsInlineResponse
            && session.clientInfo.kind == .trae
    }

    private func enqueuePendingQuestionIntervention(
        _ intervention: SessionIntervention,
        in session: inout SessionState
    ) {
        if let current = session.intervention,
           shouldQueuePendingQuestionIntervention(current, in: session),
           !session.pendingInterventions.contains(where: { interventionsMatch($0, current) }) {
            session.pendingInterventions.insert(current, at: 0)
        }

        if let index = session.pendingInterventions.firstIndex(where: { interventionsMatch($0, intervention) }) {
            session.pendingInterventions[index] = intervention
        } else {
            session.pendingInterventions.append(intervention)
        }

        if let current = session.intervention,
           shouldQueuePendingQuestionIntervention(current, in: session),
           interventionsMatch(current, intervention) {
            session.intervention = intervention
            return
        }

        if let current = session.intervention,
           shouldQueuePendingQuestionIntervention(current, in: session),
           session.pendingInterventions.contains(where: { interventionsMatch($0, current) }) {
            return
        }

        session.intervention = session.pendingInterventions.first
    }

    private func clearCurrentIntervention(
        in session: inout SessionState,
        nextPhase: SessionPhase
    ) {
        if let intervention = session.intervention {
            removePendingIntervention(intervention, from: &session)
        }

        if let nextIntervention = session.pendingInterventions.first {
            session.intervention = nextIntervention
            if nextIntervention.kind == .question {
                session.phase = .waitingForInput
            }
            return
        }

        session.intervention = nil
        if session.phase.canTransition(to: nextPhase) || session.phase == nextPhase {
            session.phase = nextPhase
        }
    }

    private func removePendingIntervention(
        _ intervention: SessionIntervention,
        from session: inout SessionState
    ) {
        session.pendingInterventions.removeAll { queued in
            interventionsMatch(queued, intervention)
        }
    }

    private nonisolated func interventionsMatch(
        _ lhs: SessionIntervention,
        _ rhs: SessionIntervention
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsToolUseIds = Set(pendingHookResponseToolUseIdCandidates(for: lhs))
        guard !lhsToolUseIds.isEmpty else { return false }
        let rhsToolUseIds = Set(pendingHookResponseToolUseIdCandidates(for: rhs))
        return !lhsToolUseIds.isDisjoint(with: rhsToolUseIds)
    }

    private nonisolated func pendingHookResponseToolUseIdCandidates(for intervention: SessionIntervention) -> [String] {
        [
            intervention.metadata["originalToolUseId"],
            intervention.metadata["toolUseId"],
            intervention.metadata["tool_use_id"],
            intervention.id
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func pendingHookResponse(in session: SessionState) -> PendingHookResponse? {
        if let activePermission = session.activePermission,
           !activePermission.toolUseId.isEmpty {
            return PendingHookResponse(
                toolUseId: activePermission.toolUseId,
                kind: .approval,
                ingress: session.ingress
            )
        }

        guard let intervention = session.intervention,
              intervention.supportsInlineResponse,
              let toolUseId = pendingHookResponseToolUseId(for: intervention) else {
            return nil
        }

        return PendingHookResponse(
            toolUseId: toolUseId,
            kind: intervention.kind,
            ingress: session.ingress
        )
    }

    private nonisolated func pendingHookResponseToolUseId(for intervention: SessionIntervention) -> String? {
        pendingHookResponseToolUseIdCandidates(for: intervention).first
    }

    private func cancelOrphanedPendingHookResponse(
        _ previous: PendingHookResponse?,
        in session: inout SessionState,
        reason: String
    ) {
        guard let previous,
              !isPendingHookResponseVisible(previous, in: session) else {
            return
        }

        let sessionIdPrefix = String(session.sessionId.prefix(8))
        let toolUseIdPrefix = String(previous.toolUseId.prefix(12))
        Self.logger.notice(
            "Cancelling orphaned pending hook response session=\(sessionIdPrefix, privacy: .public) tool=\(toolUseIdPrefix, privacy: .public) reason=\(reason, privacy: .public)"
        )
        if previous.kind == .approval {
            updateToolStatus(in: &session, toolId: previous.toolUseId, status: .error)
            clearResolvedApprovalIntervention(in: &session, toolUseId: previous.toolUseId)
        }
        pendingHookResponseCancellationHandler(previous.toolUseId, previous.ingress)
    }

    private func isPendingHookResponseVisible(
        _ pending: PendingHookResponse,
        in session: SessionState
    ) -> Bool {
        if pending.kind == .approval,
           session.activePermission?.toolUseId == pending.toolUseId {
            return true
        }

        guard let intervention = session.intervention,
              intervention.kind == pending.kind,
              intervention.supportsInlineResponse else {
            return session.pendingInterventions.contains { intervention in
                intervention.kind == pending.kind
                    && intervention.supportsInlineResponse
                    && intervention.matchesResolvedToolUseId(pending.toolUseId)
            }
        }

        return intervention.matchesResolvedToolUseId(pending.toolUseId)
            || session.pendingInterventions.contains { intervention in
                intervention.kind == pending.kind
                    && intervention.supportsInlineResponse
                    && intervention.matchesResolvedToolUseId(pending.toolUseId)
            }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        if status == .error {
            session.completedErrorToolIDs.insert(toolId)
        }
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionAutoApprovalChanged(sessionId: String, isEnabled: Bool) {
        guard var session = sessions[sessionId] else { return }
        session.autoApprovePermissions = isEnabled
        sessions[sessionId] = session
    }

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        clearResolvedApprovalIntervention(in: &session, toolUseId: toolUseId)
        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            _ = clearResolvedToolCompletionIntervention(in: &session, toolUseId: toolUseId)
            sessions[sessionId] = session
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug(
                    "Tool \(toolUseId.prefix(12), privacy: .public) completed with status=\(result.status.description, privacy: .public)"
                )
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        if result.status == .error {
            session.completedErrorToolIDs.insert(toolUseId)
        }

        _ = clearResolvedToolCompletionIntervention(in: &session, toolUseId: toolUseId)
        sessions[sessionId] = session
    }

    private func clearResolvedApprovalIntervention(in session: inout SessionState, toolUseId: String) {
        guard let intervention = session.intervention,
              intervention.kind == .approval,
              intervention.matchesResolvedToolUseId(toolUseId) else {
            return
        }

        session.intervention = nil
    }

    @discardableResult
    private func clearResolvedToolCompletionIntervention(in session: inout SessionState, toolUseId: String) -> Bool {
        guard let intervention = session.intervention,
              intervention.matchesResolvedToolUseId(toolUseId) else {
            return false
        }

        switch intervention.kind {
        case .approval:
            session.intervention = nil
            return true
        case .question:
            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
            return true
        }
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        clearResolvedApprovalIntervention(in: &session, toolUseId: toolUseId)
        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    private func processInterventionResolved(
        sessionId: String,
        nextPhase: SessionPhase,
        submittedAnswers: [String: [String]]?
    ) async {
        guard var session = sessions[sessionId] else { return }
        if let intervention = session.intervention,
           shouldAwaitExternalContinuationAfterResolving(intervention, in: session) {
            removePendingIntervention(intervention, from: &session)
            session.intervention = intervention.markingAwaitingExternalContinuation(
                actorName: session.interactionDisplayName,
                selectedAnswers: submittedAnswers
            )
            session.phase = .waitingForInput
        } else {
            clearCurrentIntervention(in: &session, nextPhase: nextPhase)
        }
        session.lastActivity = Date()
        sessions[sessionId] = session
        publishState()
    }

    private nonisolated func shouldAwaitExternalContinuationAfterResolving(
        _ intervention: SessionIntervention,
        in session: SessionState
    ) -> Bool {
        guard intervention.kind == .question else { return false }
        if session.clientInfo.prefersAnsweredQuestionFollowupAction {
            return true
        }
        if !intervention.supportsInlineResponse {
            return true
        }
        return false
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        if !payload.messages.isEmpty {
            let shouldResumeEndedSession = payload.isIncremental
                && payload.messages.contains(where: { $0.role == .user })
            if session.phase != .ended || shouldResumeEndedSession {
                session.lastActivity = Date()
            }
            promoteSessionForTranscriptActivity(
                &session,
                allowEndedResume: shouldResumeEndedSession
            )
        }

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd,
            explicitFilePath: session.clientInfo.sessionFilePath
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        applyClaudeTranscriptQuestionFallback(to: &session)

        if payload.isIncremental,
           let continuationAnsweredAt = session.intervention?.externalContinuationAnsweredAt,
           session.intervention?.awaitsExternalContinuation == true,
           session.clientInfo.retainsAnsweredQuestionFollowupActionOnTranscriptUpdates == false,
           payload.messages.contains(where: { $0.timestamp >= continuationAnsweredAt }) {
            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
        }

        sessions[payload.sessionId] = session
        publishState()

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Transcript updates are the strongest signal that a previously dormant session
    /// has resumed doing work. Promote recoverable idle/waiting states back into the
    /// active lane immediately so the primary list and hover dashboard react without
    /// waiting for a later hook heartbeat.
    private func promoteSessionForTranscriptActivity(
        _ session: inout SessionState,
        allowEndedResume: Bool = false
    ) {
        if session.phase == .ended {
            guard allowEndedResume else { return }
            session.phase = .processing
            return
        }
        guard !session.phase.isActive else { return }
        guard !session.needsApprovalResponse else { return }
        guard session.intervention == nil else { return }

        switch session.phase {
        case .idle, .waitingForInput:
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        case .processing, .compacting, .waitingForApproval, .ended:
            break
        }
    }

    private func resumedPhaseForFreshHookActivity(
        currentPhase: SessionPhase,
        incomingPhase: SessionPhase,
        event: HookEvent
    ) -> SessionPhase? {
        guard currentPhase == .ended else { return nil }
        guard event.event != "Stop", event.event != "SessionEnd", event.status != "ended" else {
            return nil
        }

        if incomingPhase.isActive || incomingPhase.needsAttention {
            return incomingPhase
        }

        if event.event == "UserPromptSubmit" {
            return .processing
        }

        return nil
    }

    private func shouldPreserveActivePhaseDuringApparentIdle(
        session: SessionState,
        incomingPhase: SessionPhase,
        referenceDate: Date,
        previousLastActivity: Date?
    ) -> Bool {
        guard session.phase.isActive else { return false }
        guard incomingPhase == .idle else { return false }
        return sessionHasLiveExecutionEvidence(session)
    }

    private func sessionHasLiveExecutionEvidence(_ session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .thinking:
                return true
            case .toolCall(let tool):
                return tool.status == .running
            case .assistant, .user, .interrupted:
                return false
            }
        }

        return false
    }

    private func mergedLastActivity(
        existing currentValue: Date?,
        incoming newValue: Date
    ) -> Date {
        guard let currentValue else { return newValue }
        return max(currentValue, newValue)
    }

    private func mergedCreatedAt(
        existing currentValue: Date,
        incoming newValue: Date
    ) -> Date {
        min(currentValue, newValue)
    }

    private func processTimedOutExternalContinuations(now: Date) async {
        var didChange = false

        for sessionId in sessions.keys {
            guard var session = sessions[sessionId],
                  session.intervention?.awaitsExternalContinuation == true,
                  session.intervention?.hasTimedOutExternalContinuation(now: now) == true else {
                continue
            }

            session.intervention = nil
            if session.phase == .waitingForInput {
                session.phase = .processing
            }
            session.lastActivity = now
            sessions[sessionId] = session
            didChange = true
        }

        if didChange {
            publishState()
        }
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        var emittedToolIds: Set<String> = []

        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Emit for pending tools, plus stale interventions whose tool item
            // already looks complete but still needs UI cleanup.
            let isPendingTool = tool.status == .running || tool.status == .waitingForApproval
            let matchesCurrentIntervention = session.intervention?.matchesResolvedToolUseId(item.id) == true
            guard isPendingTool || matchesCurrentIntervention else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            emittedToolIds.insert(item.id)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }

        guard let intervention = session.intervention else { return }
        for toolUseId in completedToolIds where !emittedToolIds.contains(toolUseId) {
            guard intervention.matchesResolvedToolUseId(toolUseId) else { continue }
            let result = ToolCompletionResult.from(
                parserResult: toolResults[toolUseId],
                structuredResult: structuredResults[toolUseId]
            )
            await process(.toolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    private func shouldClearIntervention(for event: HookEvent, newPhase: SessionPhase, currentIntervention: SessionIntervention?) -> Bool {
        guard currentIntervention?.kind == .question else { return false }
        if currentIntervention?.awaitsExternalContinuation == true,
           event.clientInfo.prefersAnsweredQuestionFollowupAction {
            if event.event == "SessionEnd" {
                return true
            }
            return false
        }
        if event.event == "PostToolUse" {
            return isQuestionToolPostToolUse(event, matching: currentIntervention)
        }
        if event.event == "Stop" || event.event == "SessionEnd" {
            return true
        }
        if event.isAskUserQuestionRequest {
            return false
        }
        return newPhase != .waitingForInput
    }

    private func isQuestionToolPostToolUse(
        _ event: HookEvent,
        matching intervention: SessionIntervention?
    ) -> Bool {
        guard event.event == "PostToolUse" else { return false }
        let normalizedTool = event.tool?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalizedTool == "askuserquestion" || normalizedTool == "askfollowupquestion" else {
            return false
        }
        guard let toolUseId = event.toolUseId else {
            return true
        }
        return intervention?.matchesResolvedToolUseId(toolUseId) == true
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        session.lastActivity = Date()
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        guard var session = sessions[sessionId] else {
            cancelPendingSync(sessionId: sessionId)
            return
        }

        markSessionEnded(&session)
        sessions[sessionId] = session
        scheduleFinalSessionSync(for: session)
        Task {
            await TelemetryService.shared.recordSessionCompleted(session)
        }
    }

    private func archiveSession(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
    }

    /// When a new session starts for a provider, archive any active sessions from the
    /// same provider + cwd that look orphaned (process died without sending Stop).
    /// This prevents duplicate-looking sessions in the expanded list when the user
    /// quits and restarts Claude in the same project.
    private func endOrphanedSessions(
        sameProviderAs session: SessionState,
        newSessionId: String
    ) {
        let provider = session.provider
        let cwd = session.cwd
        guard !cwd.isEmpty else { return }
        guard provider == .trae else { return }
        guard session.ingress != .nativeRuntime else { return }

        var idsToArchive: [String] = []
        for (existingId, existing) in sessions {
            guard existingId != newSessionId else { continue }
            guard existing.provider == provider else { continue }
            guard existing.cwd == cwd else { continue }
            guard existing.phase != .ended else { continue }
            guard !existing.needsManualAttention else { continue }

            // Don't archive a session that still has live execution evidence
            // (running tools or thinking in progress) — it may be a legitimate
            // concurrent instance, like a parent session with a child.
            if sessionHasLiveExecutionEvidence(existing) { continue }

            // Don't archive sessions whose process is still alive — two
            // legitimate Claude instances can run in the same cwd concurrently.
            if let pid = existing.pid, pid > 0,
               Darwin.kill(pid_t(pid), 0) == 0 {
                continue
            }

            idsToArchive.append(existingId)
        }

        for id in idsToArchive {
            sessions.removeValue(forKey: id)
            cancelPendingSync(sessionId: id)
        }
    }

    /// Periodically check active Claude sessions whose bridge process has died without
    /// sending a Stop event (crash, SIGKILL, terminal closed). End them so the bar
    /// doesn't keep showing dead sessions as still working.
    ///
    /// Two distinct thresholds:
    /// - PID-tracked sessions: 30 s idle → end if process is truly dead.
    /// - No-PID sessions (hook-only): 5 min idle → demote to idle only as a last-resort
    ///   safety net.  Hooks often arrive without a PID and chatItems lag behind (JSONL
    ///   sync), so a short timeout would prematurely flip ".processing" to ".idle"
    ///   while Trae is still working — the status then disappears from the Flow Island.
    func pruneOrphanedSessions() {
        for (sessionId, var session) in sessions {
            guard session.provider == .trae else { continue }
            guard session.ingress != .nativeRuntime else { continue }
            guard session.phase != .ended else { continue }
            guard !session.needsManualAttention else { continue }

            let idleSeconds = Date().timeIntervalSince(session.lastActivity)

            if let pid = session.pid, pid > 0 {
                guard idleSeconds >= 30 else { continue }
                if Darwin.kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                    markSessionEnded(&session)
                    sessions[sessionId] = session
                }
            } else if session.phase.isActive, !sessionHasLiveExecutionEvidence(session) {
                // No PID available — session is driven purely by hooks.
                // chatItems (thinking / tool calls) arrive asynchronously via
                // JSONL file sync, so a short timeout would falsely flag an
                // actively-processing session as idle.  Use a generous 5 min
                // fallback to avoid premature state transitions.
                guard idleSeconds >= 300 else { continue }
                if session.phase.canTransition(to: .idle) {
                    session.phase = .idle
                    sessions[sessionId] = session
                }
            }
        }
    }

    private func markSessionEnded(_ session: inout SessionState) {
        let wasAlreadyEnded = session.phase == .ended
        session.phase = .ended
        session.intervention = nil
        session.pendingInterventions.removeAll()
        session.autoApprovePermissions = false
        if !wasAlreadyEnded {
            session.lastActivity = Date()
        }
    }

    // MARK: - Liveness Sweep

    /// Start the periodic sweep that removes sessions whose process is no
    /// longer alive and garbage-collects `.ended` sessions. Idempotent.
    /// Wired from `SessionMonitor.startMonitoring()`.
    func startLivenessSweep() {
        guard livenessSweepTask == nil else { return }
        let intervalNs = livenessSweepIntervalNs
        livenessSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { break }
                await self?.sweepDeadOrEndedSessions()
            }
        }
    }

    /// Stop the periodic liveness sweep. Wired from
    /// `SessionMonitor.stopMonitoring()`.
    func stopLivenessSweep() {
        livenessSweepTask?.cancel()
        livenessSweepTask = nil
    }

    /// Remove sessions whose tracked `pid` is confirmed dead via `kill(pid, 0)`.
    /// Sessions in `.ended` phase are kept visible until the user explicitly
    /// archives them. Sessions without a `pid` are left alone (we cannot assert
    /// they are dead). Per-session pending tasks are cancelled to avoid orphan work.
    func sweepDeadOrEndedSessions() {
        var removedAny = false
        for (sessionId, session) in Array(sessions) {
            // Ended sessions stay in the expanded list until manually removed.
            guard session.phase != .ended else { continue }

            let pidIsDead: Bool = {
                guard let pid = session.pid, pid > 0 else { return false }
                return Darwin.kill(pid_t(pid), 0) != 0 && errno == ESRCH
            }()
            guard pidIsDead else { continue }

            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            removedAny = true
        }
        if removedAny {
            publishState()
        }
    }

    private func scheduleFinalSessionSync(for session: SessionState) {
        if let sessionFilePath = session.clientInfo.sessionFilePath, !sessionFilePath.isEmpty {
            scheduleFileSync(
                sessionId: session.sessionId,
                cwd: session.cwd,
                explicitFilePath: sessionFilePath
            )
            return
        }

        if session.provider == .trae, !session.cwd.isEmpty {
            scheduleFileSync(sessionId: session.sessionId, cwd: session.cwd)
        }
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: sessions[sessionId]?.clientInfo.sessionFilePath
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd,
            explicitFilePath: sessions[sessionId]?.clientInfo.sessionFilePath
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        applyClaudeTranscriptQuestionFallback(to: &session)

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String, explicitFilePath: String? = nil) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd,
                explicitFilePath: explicitFilePath
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            let hasPendingCompletedToolResult = await self?.hasPendingCompletedToolResult(
                sessionId: sessionId,
                completedToolIds: result.completedToolIds
            ) ?? false

            guard !result.newMessages.isEmpty || result.clearDetected || hasPendingCompletedToolResult else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func hasPendingCompletedToolResult(sessionId: String, completedToolIds: Set<String>) -> Bool {
        guard !completedToolIds.isEmpty,
              let session = sessions[sessionId] else {
            return false
        }

        if let intervention = session.intervention,
           completedToolIds.contains(where: { intervention.matchesResolvedToolUseId($0) }) {
            return true
        }

        return session.chatItems.contains { item in
            guard completedToolIds.contains(item.id),
                  case .toolCall(let tool) = item.type else {
                return false
            }
            return tool.status == .running || tool.status == .waitingForApproval
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { lhs, rhs in
            lhs.shouldSortBeforeInQueue(rhs)
        }

        var shouldPersistAssociations = false
        for session in sortedSessions {
            if updatePersistedAssociationIfNeeded(from: session) {
                shouldPersistAssociations = true
            }
        }

        if shouldPersistAssociations {
            scheduleAssociationSave()
        }

        guard sortedSessions != lastPublishedSessions else { return }
        lastPublishedSessions = sortedSessions
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        return sessions[sessionId]
    }

    /// Check whether a session exists without requiring `SessionState` equality.
    func containsSession(_ sessionId: String) -> Bool {
        return sessions.keys.contains(sessionId)
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }

    func requestFileSync(for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        guard session.ingress != .remoteBridge else { return }

        scheduleFileSync(
            sessionId: sessionId,
            cwd: session.cwd,
            explicitFilePath: session.clientInfo.sessionFilePath
        )
    }

    func diagnosticsSnapshot() -> [SessionDiagnosticsSnapshot] {
        sessions.values
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { session in
                SessionDiagnosticsSnapshot(
                    sessionId: session.sessionId,
                    provider: session.provider.rawValue,
                    ingress: session.ingress.rawValue,
                    phase: String(describing: session.phase),
                    cwd: session.cwd,
                    projectName: session.projectName,
                    displayTitle: session.displayTitle,
                    effectiveDisplayTitle: session.displayTitle,
                    sessionName: session.sessionName,
                    previewText: session.previewText,
                    lastMessage: session.lastMessage,
                    clientKind: session.clientInfo.kind.rawValue,
                    clientName: session.clientInfo.name,
                    sessionFilePath: session.clientInfo.sessionFilePath,
                    presentationMode: "standard",
                    usesTitleOnlySubagentPresentation: false,
                    linkedParentSessionId: session.linkedParentSessionId,
                    linkedSubagentDisplayTitle: session.linkedSubagentDisplayTitle,
                    hasIntervention: session.intervention != nil,
                    chatItemCount: session.chatItems.count,
                    lastActivity: session.lastActivity,
                    createdAt: session.createdAt
                )
            }
    }

    private nonisolated static func projectName(for cwd: String, fallback: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? fallback : name
    }

    private nonisolated static func shouldAdoptHookWorkspace(current: String, incoming: String) -> Bool {
        let normalizedIncoming = normalizedPath(incoming)
        guard !normalizedIncoming.isEmpty, normalizedIncoming != "/" else {
            return false
        }

        let normalizedCurrent = normalizedPath(current)
        guard normalizedCurrent != normalizedIncoming else {
            return false
        }

        if isTopLevelClientConfigDirectory(normalizedIncoming),
           !normalizedCurrent.isEmpty,
           !isTopLevelClientConfigDirectory(normalizedCurrent) {
            return false
        }

        return true
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private nonisolated static func isTopLevelClientConfigDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let knownClientDirectories: Set<String> = [
            ".claude"
        ]
        guard knownClientDirectories.contains(url.lastPathComponent) else {
            return false
        }

        return url.deletingLastPathComponent().path
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private nonisolated static func normalizedHookMessage(_ message: String?) -> String? {
        SessionTextSanitizer.sanitizedDisplayText(message)
    }

    private func persistedAssociation(for provider: SessionProvider, sessionId: String) -> PersistedSessionAssociation? {
        ensurePersistedAssociationsLoaded()
        return persistedAssociations[SessionAssociationStore.cacheKey(provider: provider, sessionId: sessionId)]
    }

    private func applyClaudeTranscriptQuestionFallback(to session: inout SessionState) {
        guard session.provider == .trae,
              session.clientInfo.brand == .trae,
              session.ingress != .remoteBridge else { return }

        let fallbackSource = "claudeTranscriptQuestion"
        let currentSource = session.intervention?.metadata["source"]
        if let currentSource, currentSource != fallbackSource {
            return
        }

        guard let pendingQuestionTool = session.chatItems.reversed().compactMap({ item -> (id: String, tool: ToolCallItem)? in
            guard case .toolCall(let tool) = item.type else { return nil }
            let normalizedName = tool.name
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            guard normalizedName == "askuserquestion" else { return nil }
            guard tool.status == .running || tool.status == .waitingForApproval else { return nil }
            return (item.id, tool)
        }).first else {
            if currentSource == fallbackSource {
                session.intervention = nil
                if session.phase == .waitingForInput {
                    session.phase = .processing
                }
            }
            return
        }

        guard let intervention = claudeTranscriptQuestionIntervention(
            toolUseId: pendingQuestionTool.id,
            tool: pendingQuestionTool.tool,
            session: session
        ) else {
            return
        }

        session.intervention = intervention
        session.phase = .waitingForInput
        session.lastActivity = Date()
    }

    private func claudeTranscriptQuestionIntervention(
        toolUseId: String,
        tool: ToolCallItem,
        session: SessionState
    ) -> SessionIntervention? {
        guard let rawQuestions = tool.input["questions"],
              let data = rawQuestions.data(using: .utf8),
              let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !questions.isEmpty else {
            return nil
        }

        let parsedQuestions = questions.enumerated().compactMap { index, question -> SessionInterventionQuestion? in
            let prompt = (question["question"] as? String)
                ?? (question["prompt"] as? String)
                ?? (question["label"] as? String)
            guard let prompt, !prompt.isEmpty else { return nil }

            let objectOptions = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { optionIndex, option -> SessionInterventionOption? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return SessionInterventionOption(
                    id: option["id"] as? String ?? "\(index)-option-\(optionIndex)",
                    title: label,
                    detail: option["description"] as? String
                )
            }

            let normalizedOptions: [SessionInterventionOption]
            if !objectOptions.isEmpty {
                normalizedOptions = objectOptions
            } else if let stringOptions = question["options"] as? [String], !stringOptions.isEmpty {
                normalizedOptions = stringOptions.enumerated().map { optionIndex, label in
                    SessionInterventionOption(
                        id: "\(index)-option-\(optionIndex)",
                        title: label,
                        detail: nil
                    )
                }
            } else {
                normalizedOptions = []
            }
            let allowsOther = (question["isOther"] as? Bool)
                ?? (question["allowsOther"] as? Bool)
                ?? false

            return SessionInterventionQuestion(
                id: question["id"] as? String ?? prompt,
                header: question["header"] as? String ?? "\(index + 1).",
                prompt: prompt,
                detail: question["description"] as? String,
                options: normalizedOptions,
                allowsMultiple: question["isMultiple"] as? Bool
                    ?? question["allowsMultiple"] as? Bool
                    ?? question["multiSelect"] as? Bool
                    ?? question["multiple"] as? Bool
                    ?? false,
                allowsOther: allowsOther || session.clientInfo.supportsCustomAskUserQuestionInput,
                isSecret: question["isSecret"] as? Bool
                    ?? question["secret"] as? Bool
                    ?? false
            )
        }

        guard !parsedQuestions.isEmpty else { return nil }

        let actorName = session.interactionDisplayName
        let title = parsedQuestions.count == 1
            ? "\(actorName) 的提问"
            : "\(actorName) 的提问（\(parsedQuestions.count) 个问题）"
        let payload: [String: Any] = ["questions": questions]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return nil
        }

        return SessionIntervention(
            id: toolUseId,
            kind: .question,
            title: title,
            message: "\(actorName) 需要你补充回答，提交后会继续执行当前会话。",
            options: [],
            questions: parsedQuestions,
            supportsSessionScope: false,
            metadata: [
                "toolName": "AskUserQuestion",
                "toolInputJSON": payloadJSON,
                "originalToolUseId": toolUseId,
                "source": "claudeTranscriptQuestion"
            ]
        )
    }

    private func ensurePersistedAssociationsLoaded() {
        guard !didLoadPersistedAssociations else { return }
        persistedAssociations = SessionAssociationStore.load()
        didLoadPersistedAssociations = true
    }

    private func updatePersistedAssociationIfNeeded(from session: SessionState) -> Bool {
        ensurePersistedAssociationsLoaded()
        let key = SessionAssociationStore.cacheKey(provider: session.provider, sessionId: session.sessionId)
        let updatedAssociation = PersistedSessionAssociation(session: session)
        guard persistedAssociations[key] != updatedAssociation else {
            return false
        }

        persistedAssociations[key] = updatedAssociation
        return true
    }

    private func scheduleAssociationSave() {
        let snapshot = persistedAssociations
        pendingAssociationSave?.cancel()
        pendingAssociationSave = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            SessionAssociationStore.save(snapshot)
        }
    }

    private func removePersistedAssociation(provider: SessionProvider, sessionId: String) -> Bool {
        ensurePersistedAssociationsLoaded()
        let key = SessionAssociationStore.cacheKey(provider: provider, sessionId: sessionId)
        return persistedAssociations.removeValue(forKey: key) != nil
    }

    private func runtimeClientInfo(for session: SessionState, tree: [Int: ProcessInfo]) async -> SessionClientInfo? {
        let resolvedTTY = session.tty?.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalPid =
            resolvedTTY.flatMap { ProcessTreeBuilder.shared.findTerminalPid(forTTY: $0, tree: tree) }
            ?? session.pid.flatMap { ProcessTreeBuilder.shared.findTerminalPid(forProcess: $0, tree: tree) }

        guard let terminalPid,
              let appIdentity = await runningApplicationIdentity(forProcess: terminalPid, tree: tree) else {
            return nil
        }

        let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: appIdentity.bundleIdentifier)
        let appName = appIdentity.name
        let workspaceLaunchURL = SessionClientInfo.appLaunchURL(
            bundleIdentifier: normalizedBundleIdentifier,
            workspacePath: session.cwd
        )

        var runtimeInfo = SessionClientInfo(
            kind: session.clientInfo.kind,
            launchURL: workspaceLaunchURL,
            originator: appName,
            threadSource: TerminalAppRegistry.isIDEBundle(normalizedBundleIdentifier)
                ? (session.clientInfo.threadSource ?? "ide-terminal")
                : session.clientInfo.threadSource,
            terminalBundleIdentifier: normalizedBundleIdentifier
        )

        return runtimeInfo
    }



    private func normalizedClientInfo(
        _ clientInfo: SessionClientInfo,
        provider: SessionProvider,
        sessionId: String
    ) -> SessionClientInfo {
        return clientInfo
    }

    private func runningApplicationIdentity(
        forProcess pid: Int,
        tree: [Int: ProcessInfo]
    ) async -> (bundleIdentifier: String, name: String)? {
        var currentPid = pid
        var depth = 0

        while currentPid > 1 && depth < 20 {
            let lookupPid = currentPid
            if let identity = await MainActor.run(resultType: (bundleIdentifier: String, name: String)?.self, body: {
                guard let app = NSRunningApplication(processIdentifier: pid_t(lookupPid)),
                      let bundleIdentifier = app.bundleIdentifier else {
                    return nil
                }

                let normalizedBundleIdentifier = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier)
                let hostName = NSRunningApplication.runningApplications(withBundleIdentifier: normalizedBundleIdentifier)
                    .first?
                    .localizedName
                return (
                    bundleIdentifier: normalizedBundleIdentifier,
                    name: hostName ?? app.localizedName ?? bundleIdentifier
                )
            }) {
                return identity
            }

            guard let processInfo = tree[currentPid] else { break }
            currentPid = processInfo.ppid
            depth += 1
        }

        return nil
    }

    private func shouldIgnoreClaudeAskUserQuestionPermissionRequest(_ event: HookEvent) -> Bool {
        guard event.provider == .trae,
              event.event == "PermissionRequest" else {
            return false
        }

        let normalizedTool = event.tool?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        let isQuestionTool = normalizedTool == "askuserquestion"
            || normalizedTool == "askfollowupquestion"
        guard isQuestionTool, event.toolInput?["questions"] != nil else {
            return false
        }

        return normalizedTool == "askuserquestion"
    }

}
