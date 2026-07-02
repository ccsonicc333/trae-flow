//
//  SessionState.swift
//  TraeFlow
//
//  Unified state model for a tracked session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

enum SessionScopedApprovalAction: Equatable, Sendable {
    case allowSession
    case autoApprove

    nonisolated var buttonTitleKey: String {
        switch self {
        case .allowSession:
            return "Allow Session"
        case .autoApprove:
            return "Always Allow"
        }
    }

    nonisolated var compactButtonTitleKey: String {
        switch self {
        case .allowSession:
            return "Session"
        case .autoApprove:
            return "Always"
        }
    }
}

/// Complete state for a single tracked session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    private nonisolated static let minimalCompactDelay: TimeInterval = 10 * 60
    private nonisolated static let autoArchiveDelay: TimeInterval = 30 * 60
    private nonisolated static let endedArchiveActionDelay: TimeInterval = 10 * 60

    // MARK: - Identity

    let sessionId: String
    var cwd: String
    var projectName: String
    var provider: SessionProvider
    var clientInfo: SessionClientInfo
    var ingress: SessionIngress
    var sessionName: String?
    var previewText: String?
    var latestHookMessage: String?
    /// Pretty-printed JSON of the most recent bridge envelope for this session.
    var lastEnvelopeJSON: String?
    var suppressInAppPromptControls: Bool
    var intervention: SessionIntervention?
    var pendingInterventions: [SessionIntervention]
    var linkedParentSessionId: String?
    var linkedSubagentDisplayTitle: String?
    var heuristicSubagentDisplayTitle: String?

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    var autoApprovePermissions: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    /// Tool IDs that completed with an actual execution error.
    /// Used for event-specific notifications such as CESP `task.error`.
    var completedErrorToolIDs: Set<String>

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        provider: SessionProvider = .trae,
        clientInfo: SessionClientInfo? = nil,
        ingress: SessionIngress = .hookBridge,
        sessionName: String? = nil,
        previewText: String? = nil,
        latestHookMessage: String? = nil,
        lastEnvelopeJSON: String? = nil,
        suppressInAppPromptControls: Bool = false,
        intervention: SessionIntervention? = nil,
        pendingInterventions: [SessionIntervention] = [],
        linkedParentSessionId: String? = nil,
        linkedSubagentDisplayTitle: String? = nil,
        heuristicSubagentDisplayTitle: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        autoApprovePermissions: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        completedErrorToolIDs: Set<String> = [],
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.provider = provider
        self.clientInfo = clientInfo ?? SessionClientInfo.default(for: provider)
        self.ingress = ingress
        self.sessionName = sessionName
        self.previewText = previewText
        self.latestHookMessage = latestHookMessage
        self.lastEnvelopeJSON = lastEnvelopeJSON
        self.suppressInAppPromptControls = suppressInAppPromptControls
        self.intervention = intervention
        self.pendingInterventions = pendingInterventions
        self.linkedParentSessionId = linkedParentSessionId
        self.linkedSubagentDisplayTitle = linkedSubagentDisplayTitle
        self.heuristicSubagentDisplayTitle = heuristicSubagentDisplayTitle
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.autoApprovePermissions = autoApprovePermissions
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.completedErrorToolIDs = completedErrorToolIDs
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    nonisolated var needsAttention: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether this session should be surfaced before active/background work.
    nonisolated var needsManualAttention: Bool {
        needsAttention
    }

    /// Whether this session should surface an attention notification for a prompt
    /// even when the prompt response itself must stay in the terminal/client.
    nonisolated var needsPromptNotification: Bool {
        needsApprovalResponse || needsQuestionResponse || suppressInAppPromptControls
    }

    /// The active permission context, if any
    nonisolated var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    nonisolated var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    nonisolated var displayTitle: String {
        sessionName
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary)
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.firstUserMessage)
            ?? projectName
    }

    /// 真实任务标题：仅 sessionName 或 summary，不含 firstUserMessage / projectName 回退
    nonisolated var taskTitle: String? {
        sessionName ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary)
    }

    /// 最终用于列表展示的任务标题：TRAE Work / TRAE Work CN（SOLO 系列）支持多任务，
    /// 允许使用 firstUserMessage 作为标题；其他变体只使用 sessionName / summary。
    nonisolated var effectiveTaskTitle: String? {
        guard let variant = TraeVariant.fromBundleIdentifier(clientInfo.bundleIdentifier) else {
            return taskTitle
        }
        switch variant {
        case .traeWork, .traeWorkCN:
            // SOLO 系列支持多任务，允许用 firstUserMessage 回退作为任务标题
            let title = displayTitle
            return title == projectName ? nil : title
        case .trae, .traeCN:
            return taskTitle
        }
    }

    nonisolated var isLinkedSubagentSession: Bool {
        sanitizedSubagentDisplayText(linkedParentSessionId) != nil
    }

    nonisolated var isHeuristicSubagentSession: Bool {
        sanitizedSubagentDisplayText(heuristicSubagentDisplayTitle) != nil
    }

    private nonisolated func sanitizedSubagentDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    nonisolated var shouldHideFromPrimaryUI: Bool {
        return shouldAutoArchiveFromPrimaryUI
    }

    private nonisolated static func isLikelyGenericHookProgressText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[….]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return false }
        guard normalized.count <= 32 else { return false }

        let exactMatches: Set<String> = [
            "working",
            "working on it",
            "processing",
            "thinking",
            "loading",
            "starting",
            "running",
            "busy",
            "work in progress",
            "idle",
            "ready",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "加载中",
            "准备中",
            "运行中"
        ]
        if exactMatches.contains(normalized) {
            return true
        }

        let containsMatches = [
            "still working",
            "working",
            "processing",
            "thinking",
            "loading",
            "running",
            "waiting",
            "工作中",
            "处理中",
            "正在处理",
            "思考中"
        ]
        return containsMatches.contains { normalized.contains($0) }
    }

    /// Provider label for message prefixes and generic copy.
    nonisolated var providerDisplayName: String {
        clientInfo.assistantLabel(for: provider)
    }

    /// Client label for badges and source-aware copy.
    nonisolated var clientDisplayName: String {
        clientInfo.badgeLabel(for: provider)
    }

    nonisolated var messageBadgeDisplayName: String {
        if let variant = TraeVariant.fromBundleIdentifier(clientInfo.bundleIdentifier) {
            return variant.displayName
        }
        return clientDisplayName
    }

    /// 基础 TRAE 变体（或未知变体）不显示徽章；其余变体显示完整名称
    nonisolated var shouldHideVariantBadge: Bool {
        guard let variant = TraeVariant.fromBundleIdentifier(clientInfo.bundleIdentifier) else {
            return true  // 未知变体 → 隐藏（默认视为基础 TRAE）
        }
        return variant == .trae
    }

    /// Human-facing actor for questions/approvals. Prefer the IDE host when present.
    nonisolated var interactionDisplayName: String {
        clientInfo.interactionLabel(for: provider)
    }

    /// Optional terminal-source badge for terminal-hosted sessions such as Ghostty or iTerm2.
    nonisolated var terminalSourceBadgeLabel: String? {
        deduplicatedSecondaryBadgeLabel(clientInfo.terminalSourceDisplayName)
    }

    /// Remote sessions come from the dedicated remote bridge or carry SSH/remote context.
    nonisolated var isRemoteSession: Bool {
        if ingress == .remoteBridge {
            return true
        }

        if clientInfo.remoteHost?.isEmpty == false {
            return true
        }

        guard let transport = clientInfo.transport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !transport.isEmpty else {
            return false
        }

        return transport.contains("ssh") || transport.contains("remote")
    }

    /// Best hint for matching window title
    nonisolated var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    private nonisolated func deduplicatedSecondaryBadgeLabel(_ label: String?) -> String? {
        guard let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedLabel.isEmpty else {
            return nil
        }

        let reservedLabels = [
            messageBadgeDisplayName,
            providerDisplayName,
            clientDisplayName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        guard !reservedLabels.contains(trimmedLabel.lowercased()) else {
            return nil
        }

        return trimmedLabel
    }

    /// Pending tool name if waiting for approval
    nonisolated var pendingToolName: String? {
        activePermission?.toolName ?? intervention?.title
    }

    /// Pending tool use ID
    nonisolated var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    nonisolated var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    nonisolated var lastMessage: String? {
        SessionTextSanitizer.sanitizedDisplayText(conversationInfo.lastMessage)
            ?? (clientInfo.prefersHookMessageAsLastMessageFallback ? compactHookMessage : nil)
            ?? SessionTextSanitizer.sanitizedDisplayText(previewText)
            ?? (!clientInfo.prefersHookMessageAsLastMessageFallback ? compactHookMessage : nil)
            ?? SessionTextSanitizer.sanitizedDisplayText(intervention?.summaryText)
    }

    nonisolated var shouldHideProjectContextInUI: Bool {
        return false
    }

    /// Latest hook bridge message formatted for compact notch display.
    nonisolated var compactHookMessage: String? {
        guard let latestHookMessage else { return nil }
        let normalized = latestHookMessage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("Stop") == .orderedSame {
            return nil
        }
        return normalized.isEmpty ? nil : normalized
    }

    /// Last message role
    nonisolated var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    nonisolated var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    nonisolated var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    nonisolated var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    nonisolated var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    nonisolated var canInteract: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether the session is waiting on a question-like intervention
    nonisolated var needsQuestionResponse: Bool {
        intervention?.kind == .question
    }

    /// Whether the session is waiting on an approval-like decision.
    nonisolated var needsApprovalResponse: Bool {
        phase.isWaitingForApproval || intervention?.kind == .approval
    }

    /// Whether Island has a concrete response target for the active approval.
    nonisolated var canSubmitApprovalFromIsland: Bool {
        if let toolUseId = activePermission?.toolUseId,
           !toolUseId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        guard let intervention,
              intervention.kind == .approval else {
            return false
        }

        return [
            intervention.metadata["originalToolUseId"],
            intervention.metadata["toolUseId"],
            intervention.metadata["tool_use_id"],
            intervention.id
        ].contains { candidate in
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Whether Island should hide prompt response controls and behave as a
    /// notification-only surface for the current prompt.
    nonisolated func shouldSuppressInAppPromptControls(routePromptsToTerminal: Bool) -> Bool {
        let isRoutedToTerminal = routePromptsToTerminal || suppressInAppPromptControls
        guard isRoutedToTerminal else { return false }
        if needsApprovalResponse, canSubmitApprovalFromIsland {
            return false
        }
        return needsApprovalResponse || needsQuestionResponse
    }

    /// 客户端可以在不保持 Island 端干预对象活跃的情况下显示后续问题。当最新完成的工具是 `ask_followup_question` 时，显示重新打开的提示。
    nonisolated var latestCompletedFollowupQuestionTool: ToolCallItem? {
        guard let latestItem = chatItems.last,
              case .toolCall(let tool) = latestItem.type else {
            return nil
        }

        let normalizedName = tool.name
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalizedName == "askfollowupquestion", tool.status == .success else {
            return nil
        }

        return tool
    }

    private nonisolated var latestToolCallIsCompletedFollowupQuestion: Bool {
        latestCompletedFollowupQuestionTool != nil
    }

    nonisolated var shouldShowClientFollowupPrompt: Bool {
        guard phase != .ended else { return false }
        guard clientInfo.prefersAnsweredQuestionFollowupAction else { return false }
        return latestToolCallIsCompletedFollowupQuestion
    }

    nonisolated var scopedApprovalAction: SessionScopedApprovalAction? {
        guard needsApprovalResponse else { return nil }

        if provider == .trae,
           clientInfo.kind == .trae,
           intervention?.offersSessionScopedApproval == true {
            return .autoApprove
        }

        return nil
    }

    nonisolated var supportsSessionScopedApproval: Bool {
        scopedApprovalAction != nil
    }

    nonisolated var isNativeRuntimeSession: Bool {
        ingress == .nativeRuntime
    }

    nonisolated var supportsTmuxCLIMessaging: Bool {
        guard hasTmuxRoutingEvidence else { return false }
        return true
    }

    private nonisolated var hasTmuxRoutingEvidence: Bool {
        isInTmux
            || Self.hasContent(clientInfo.tmuxPaneIdentifier)
            || Self.hasContent(clientInfo.tmuxSessionIdentifier)
    }

    private nonisolated static func hasContent(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    nonisolated var shouldShowTerminateActionInPrimaryUI: Bool {
        isNativeRuntimeSession && phase != .ended
    }

    /// Timestamp used when sorting sessions that need manual attention.
    nonisolated var attentionRequestedAt: Date? {
        if let permission = activePermission {
            return permission.receivedAt
        }
        if needsAttention {
            return lastActivity
        }
        return nil
    }

    /// Timestamp used for recency ordering once attention-demanding sessions are handled.
    /// Keep actively-running sessions anchored to their live activity time so a
    /// backfilled transcript timestamp from the first parsed user message cannot
    /// make the row jump backward during an in-flight update.
    nonisolated var queueSortActivityDate: Date {
        if phase.isActive {
            return lastActivity
        }
        return lastUserMessageDate ?? lastActivity
    }

    /// Sessions with no new activity for long enough should disappear from the primary list
    /// until a new event or message refreshes `lastActivity`.
    /// Ended sessions stay visible until the user explicitly archives them.
    nonisolated var shouldAutoArchiveFromPrimaryUI: Bool {
        if needsManualAttention {
            return false
        }
        if phase == .ended {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.autoArchiveDelay
    }

    /// Whether this session recently completed and should still appear in hover previews.
    nonisolated var isRecentlyCompleted: Bool {
        guard phase == .ended || phase == .idle else { return false }
        return Date().timeIntervalSince(lastActivity) < Self.minimalCompactDelay
    }

    /// Older background sessions collapse to a header-only presentation in compact surfaces.
    nonisolated var shouldUseMinimalCompactPresentation: Bool {
        if shouldAutoArchiveFromPrimaryUI {
            return false
        }
        if phase == .ended, shouldShowArchiveActionInPrimaryUI {
            return false
        }
        if phase.isActive || needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.minimalCompactDelay
    }

    /// Whether the session list should offer a manual archive action for this row.
    nonisolated var shouldShowArchiveActionInPrimaryUI: Bool {
        switch phase {
        case .idle:
            return true
        case .waitingForInput:
            return intervention == nil
        case .ended:
            return Date().timeIntervalSince(lastActivity) >= Self.endedArchiveActionDelay
        case .processing, .compacting, .waitingForApproval:
            return false
        }
    }

    nonisolated func shouldSortBeforeInQueue(_ other: SessionState) -> Bool {
        if phase.isActive != other.phase.isActive {
            return phase.isActive
        }

        if needsManualAttention != other.needsManualAttention {
            return needsManualAttention
        }

        if needsManualAttention, other.needsManualAttention {
            let dateA = attentionRequestedAt ?? createdAt
            let dateB = other.attentionRequestedAt ?? other.createdAt
            if dateA != dateB {
                return dateA < dateB
            }
        }

        let priorityA = queuePhasePriority
        let priorityB = other.queuePhasePriority
        if priorityA != priorityB {
            return priorityA < priorityB
        }

        let dateA = queueSortActivityDate
        let dateB = other.queueSortActivityDate
        if dateA != dateB {
            return dateA > dateB
        }

        return stableId < other.stableId
    }

    private nonisolated var queuePhasePriority: Int {
        if needsManualAttention {
            return 0
        }

        switch phase {
        case .processing, .compacting:
            return 1
        case .idle:
            return 2
        case .ended:
            return 3
        case .waitingForInput, .waitingForApproval:
            return 0
        }
    }

    private nonisolated var normalizedWorkspacePath: String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path.lowercased()
    }

}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
