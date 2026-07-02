import Foundation

enum SessionProvider: String, Codable, Equatable, Sendable {
    case trae

    nonisolated var displayName: String {
        return "TRAE"
    }

    // 兼容旧持久化数据：旧 rawValue "claude" 仍解码为 .trae
    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "trae", "claude": self = .trae
        default: return nil
        }
    }
}

enum SessionIngress: String, Equatable, Sendable {
    case hookBridge
    case remoteBridge
    case nativeRuntime
    case desktopAppMonitor
}

enum SessionClientKind: String, Codable, Equatable, Sendable {
    case trae
    case custom
    case unknown

    // 兼容旧持久化数据：旧 rawValue "claudeCode" 仍解码为 .trae
    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "trae", "claudecode": self = .trae
        case "custom": self = .custom
        case "unknown": self = .unknown
        default: return nil
        }
    }
}

struct SessionClientInfo: Codable, Equatable, Sendable {
    var kind: SessionClientKind
    var profileID: String?
    var name: String?
    var bundleIdentifier: String?
    var launchURL: String?
    var origin: String?
    var originator: String?
    var threadSource: String?
    var transport: String?
    var remoteHost: String?
    var sessionFilePath: String?
    var terminalBundleIdentifier: String?
    var terminalProgram: String?
    var terminalSessionIdentifier: String?
    var iTermSessionIdentifier: String?
    var tmuxSessionIdentifier: String?
    var tmuxPaneIdentifier: String?
    var processName: String?

    nonisolated init(
        kind: SessionClientKind,
        profileID: String? = nil,
        name: String? = nil,
        bundleIdentifier: String? = nil,
        launchURL: String? = nil,
        origin: String? = nil,
        originator: String? = nil,
        threadSource: String? = nil,
        transport: String? = nil,
        remoteHost: String? = nil,
        sessionFilePath: String? = nil,
        terminalBundleIdentifier: String? = nil,
        terminalProgram: String? = nil,
        terminalSessionIdentifier: String? = nil,
        iTermSessionIdentifier: String? = nil,
        tmuxSessionIdentifier: String? = nil,
        tmuxPaneIdentifier: String? = nil,
        processName: String? = nil
    ) {
        self.kind = kind
        self.profileID = profileID?.nonEmpty
        self.name = name?.nonEmpty
        self.bundleIdentifier = bundleIdentifier?.nonEmpty
        self.launchURL = launchURL?.nonEmpty
        self.origin = origin?.nonEmpty
        self.originator = originator?.nonEmpty
        self.threadSource = threadSource?.nonEmpty
        self.transport = transport?.nonEmpty
        self.remoteHost = remoteHost?.nonEmpty
        self.sessionFilePath = sessionFilePath?.nonEmpty
        self.terminalBundleIdentifier = terminalBundleIdentifier?.nonEmpty
        self.terminalProgram = terminalProgram?.nonEmpty
        self.terminalSessionIdentifier = terminalSessionIdentifier?.nonEmpty
        self.iTermSessionIdentifier = iTermSessionIdentifier?.nonEmpty
        self.tmuxSessionIdentifier = tmuxSessionIdentifier?.nonEmpty
        self.tmuxPaneIdentifier = tmuxPaneIdentifier?.nonEmpty
        self.processName = processName?.nonEmpty
    }

    nonisolated static func `default`(for provider: SessionProvider) -> SessionClientInfo {
        if let profile = ClientProfileRegistry.defaultRuntimeProfile(for: provider) {
            return SessionClientInfo(
                kind: profile.kind,
                profileID: profile.id,
                name: profile.displayName,
                bundleIdentifier: profile.defaultBundleIdentifier,
                origin: profile.defaultOrigin
            )
        }
        return SessionClientInfo(kind: .trae, name: "TRAE")
    }

    nonisolated func resolvedProfile(for provider: SessionProvider) -> SessionClientProfile? {
        if let inferredProfileID {
            return ClientProfileRegistry.runtimeProfile(id: inferredProfileID)
        }

        return ClientProfileRegistry.runtimeProfile(id: profileID)
            ?? ClientProfileRegistry.defaultRuntimeProfile(for: provider, kind: kind)
    }

    nonisolated var brand: SessionClientBrand {
        if let inferredProfileID,
           let profile = ClientProfileRegistry.runtimeProfile(id: inferredProfileID) {
            return profile.brand
        }

        if let profile = ClientProfileRegistry.runtimeProfile(id: profileID) {
            return profile.brand
        }

        return .trae
    }

    nonisolated var supportsCustomAskUserQuestionInput: Bool {
        return true
    }

    nonisolated var prefersHookMessageAsLastMessageFallback: Bool {
        false
    }

    nonisolated var suppressesActivationNavigation: Bool {
        false
    }

    nonisolated func badgeLabel(for provider: SessionProvider) -> String {
        let profile = resolvedProfile(for: provider)
        if let inferredProfileID,
           let inferredProfile = ClientProfileRegistry.runtimeProfile(id: inferredProfileID) {
            return inferredProfile.displayName
        }
        if let name {
            return Self.normalizedBadgeLabel(name, provider: provider, kind: kind) ?? name
        }
        if let originator {
            return Self.normalizedBadgeLabel(originator, provider: provider, kind: kind) ?? originator
        }
        return profile?.displayName ?? provider.displayName
    }

    nonisolated func subagentClientTypeLabel(for provider: SessionProvider) -> String {
        if let inferredProfileID,
           let inferredProfile = ClientProfileRegistry.runtimeProfile(id: inferredProfileID) {
            return inferredProfile.displayName
        }

        if let profile = resolvedProfile(for: provider) {
            return profile.displayName
        }

        if let name {
            return Self.normalizedBadgeLabel(name, provider: provider, kind: kind) ?? name
        }

        if let originator {
            return Self.normalizedBadgeLabel(originator, provider: provider, kind: kind) ?? originator
        }

        return provider.displayName
    }

    nonisolated func assistantLabel(for provider: SessionProvider) -> String {
        switch resolvedProfile(for: provider)?.assistantLabelMode {
        case .badgeLabel:
            return badgeLabel(for: provider)
        case .providerDisplayName, .none:
            return provider.displayName
        }
    }

    nonisolated func interactionLabel(for provider: SessionProvider) -> String {
        badgeLabel(for: provider)
    }

    nonisolated var prefersAnsweredQuestionFollowupAction: Bool {
        false
    }

    nonisolated var retainsAnsweredQuestionFollowupActionOnTranscriptUpdates: Bool {
        false
    }

    nonisolated var terminalSourceDisplayName: String? {
        Self.canonicalTerminalDisplayName(
            bundleIdentifier: terminalBundleIdentifier,
            program: terminalProgram,
            fallbackName: originator
        )
    }

    nonisolated var prefersAppNavigation: Bool {
        launchURL != nil || (bundleIdentifier?.lowercased().contains("trae") == true)
    }

    nonisolated func normalizedForClaudeRouting() -> SessionClientInfo {
        return self
    }

    private nonisolated var inferredProfileID: String? {
        return nil
    }

    nonisolated var terminalContextSummary: String? {
        let transportLabel: String?
        if let transport {
            if let remoteHost {
                transportLabel = "\(transport)@\(remoteHost)"
            } else {
                transportLabel = transport
            }
        } else {
            transportLabel = remoteHost
        }

        let parts = Self.uniqueDisplayParts([
            originator,
            threadSource,
            transportLabel,
            terminalSourceDisplayName ?? Self.canonicalTerminalDisplayName(
                bundleIdentifier: terminalBundleIdentifier,
                program: terminalProgram
            ),
            tmuxPaneIdentifier
        ])

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    nonisolated func merged(with newer: SessionClientInfo) -> SessionClientInfo {
        var merged = self

        if merged.kind == .unknown || newer.kind != .unknown {
            merged.kind = newer.kind
        }
        if let profileID = newer.profileID?.nonEmpty {
            merged.profileID = profileID
        }

        if let name = newer.name?.nonEmpty {
            merged.name = name
        }
        if let bundleIdentifier = newer.bundleIdentifier?.nonEmpty {
            merged.bundleIdentifier = bundleIdentifier
        }
        if let launchURL = newer.launchURL?.nonEmpty {
            merged.launchURL = launchURL
        }
        if let origin = newer.origin?.nonEmpty {
            merged.origin = origin
        }
        if let originator = newer.originator?.nonEmpty {
            merged.originator = originator
        }
        if let threadSource = newer.threadSource?.nonEmpty {
            merged.threadSource = threadSource
        }
        if let transport = newer.transport?.nonEmpty {
            merged.transport = transport
        }
        if let remoteHost = newer.remoteHost?.nonEmpty {
            merged.remoteHost = remoteHost
        }
        if let sessionFilePath = newer.sessionFilePath?.nonEmpty {
            merged.sessionFilePath = sessionFilePath
        }
        if let terminalBundleIdentifier = newer.terminalBundleIdentifier?.nonEmpty {
            merged.terminalBundleIdentifier = terminalBundleIdentifier
        }
        if let terminalProgram = newer.terminalProgram?.nonEmpty {
            merged.terminalProgram = terminalProgram
        }
        if let terminalSessionIdentifier = newer.terminalSessionIdentifier?.nonEmpty {
            merged.terminalSessionIdentifier = terminalSessionIdentifier
        }
        if let iTermSessionIdentifier = newer.iTermSessionIdentifier?.nonEmpty {
            merged.iTermSessionIdentifier = iTermSessionIdentifier
        }
        if let tmuxSessionIdentifier = newer.tmuxSessionIdentifier?.nonEmpty {
            merged.tmuxSessionIdentifier = tmuxSessionIdentifier
        }
        if let tmuxPaneIdentifier = newer.tmuxPaneIdentifier?.nonEmpty {
            merged.tmuxPaneIdentifier = tmuxPaneIdentifier
        }
        if let processName = newer.processName?.nonEmpty {
            merged.processName = processName
        }

        return merged
    }

    private nonisolated static func normalizedBadgeLabel(
        _ rawValue: String,
        provider: SessionProvider,
        kind: SessionClientKind
    ) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let canonical = ClientProfileRegistry.canonicalDisplayName(for: trimmed, provider: provider, kind: kind) {
            return canonical
        }

        return nil
    }

    private nonisolated static func canonicalTerminalDisplayName(
        bundleIdentifier: String?,
        program: String?,
        fallbackName: String? = nil
    ) -> String? {
        TerminalAppRegistry.canonicalDisplayName(
            bundleIdentifier: bundleIdentifier,
            program: program,
            fallbackName: fallbackName
        )
    }

    private nonisolated static func uniqueDisplayParts(_ values: [String?]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for value in values {
            guard let trimmed = value?.nonEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(trimmed)
        }

        return ordered
    }

    nonisolated static func appLaunchURL(
        bundleIdentifier: String,
        sessionId: String? = nil,
        workspacePath: String? = nil
    ) -> String? {
        let normalizedBundleIdentifier = bundleIdentifier.lowercased()

        // 按变体 bundle ID 精确匹配 URL Scheme（trae / trae-cn / solo / solo-cn）
        if let variant = TraeVariant.fromBundleIdentifier(normalizedBundleIdentifier) {
            return workspacePath.flatMap { workspaceURL(scheme: variant.urlScheme, path: $0) }
        }

        // 兜底：未识别的 TRAE 系 bundle ID 仍用 trae:// scheme
        if normalizedBundleIdentifier.contains("trae") {
            return workspacePath.flatMap { workspaceURL(scheme: "trae", path: $0) }
        }

        return nil
    }

    private nonisolated static func workspaceURL(scheme: String, path: String) -> String? {
        let trimmedPath = path.nonEmpty ?? ""
        guard !trimmedPath.isEmpty else { return nil }
        let encodedPath = trimmedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedPath
        return "\(scheme)://file\(encodedPath)"
    }
}

enum SessionInterventionKind: String, Sendable {
    case approval
    case question
}

struct SessionInterventionOption: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String?

    nonisolated var mergeSignature: String {
        [id, title, detail ?? ""].joined(separator: "|")
    }
}

struct SessionInterventionQuestion: Equatable, Identifiable, Sendable {
    let id: String
    let header: String
    let prompt: String
    let detail: String?
    let options: [SessionInterventionOption]
    let allowsMultiple: Bool
    let allowsOther: Bool
    let isSecret: Bool

    nonisolated var mergeSignature: String {
        let optionSignature = options.map(\.mergeSignature).joined(separator: "||")
        return [
            id,
            header,
            prompt,
            detail ?? "",
            allowsMultiple ? "1" : "0",
            allowsOther ? "1" : "0",
            isSecret ? "1" : "0",
            optionSignature
        ].joined(separator: "|")
    }
}

struct SessionQuestionFormDraft: Equatable, Sendable {
    let answers: [String: [String]]
    let otherAnswers: [String: String]

    nonisolated var isEmpty: Bool {
        let hasSelectedAnswers = answers.values.contains { values in
            values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let hasCustomAnswers = otherAnswers.values.contains { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !hasSelectedAnswers && !hasCustomAnswers
    }
}

struct SessionQuestionDraftCache: Equatable, Sendable {
    private var drafts: [String: SessionQuestionFormDraft] = [:]

    nonisolated func draft(sessionId: String, interventionId: String) -> SessionQuestionFormDraft? {
        drafts[Self.key(sessionId: sessionId, interventionId: interventionId)]
    }

    mutating func update(
        sessionId: String,
        interventionId: String,
        draft: SessionQuestionFormDraft
    ) {
        let key = Self.key(sessionId: sessionId, interventionId: interventionId)
        if draft.isEmpty {
            drafts[key] = nil
        } else {
            drafts[key] = draft
        }
    }

    mutating func clear(sessionId: String, interventionId: String) {
        drafts[Self.key(sessionId: sessionId, interventionId: interventionId)] = nil
    }

    private nonisolated static func key(sessionId: String, interventionId: String) -> String {
        "\(sessionId)|\(interventionId)"
    }
}

struct SessionIntervention: Equatable, Identifiable, Sendable {
    private nonisolated static let externalContinuationTimeout: TimeInterval = 5 * 60
    private nonisolated static let submittedAnswersMetadataKey = "submittedAnswersJSON"

    let id: String
    let kind: SessionInterventionKind
    let title: String
    let message: String
    let options: [SessionInterventionOption]
    let questions: [SessionInterventionQuestion]
    let supportsSessionScope: Bool
    let metadata: [String: String]

    nonisolated var supportsInlineResponse: Bool {
        metadata["responseMode"] != "external_only"
    }

    nonisolated var offersSessionScopedApproval: Bool {
        supportsSessionScope || options.contains { option in
            let normalizedId = Self.normalizedApprovalOptionIdentifier(option.id)
            if normalizedId == "approveforsession" || normalizedId == "allowforsession" {
                return true
            }

            let normalizedTitle = Self.normalizedApprovalOptionIdentifier(option.title)
            return normalizedTitle == "approveforsession" || normalizedTitle == "allowforsession"
        }
    }

    nonisolated var resolvedQuestions: [SessionInterventionQuestion] {
        if !questions.isEmpty {
            return questions
        }

        guard let rawJSON = metadata["toolInputJSON"] ?? metadata["tool_input_json"],
              let data = rawJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuestions = payload["questions"] as? [[String: Any]] else {
            return []
        }

        return rawQuestions.indices.compactMap { index -> SessionInterventionQuestion? in
            let question = rawQuestions[index]
            let prompt = (question["question"] as? String)
                ?? (question["prompt"] as? String)
                ?? (question["label"] as? String)
            guard let prompt, !prompt.isEmpty else { return nil }

            let rawOptionObjects = question["options"] as? [[String: Any]] ?? []
            let objectOptions = rawOptionObjects.indices.compactMap { optionIndex -> SessionInterventionOption? in
                let option = rawOptionObjects[optionIndex]
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
                allowsOther: question["isOther"] as? Bool
                    ?? question["allowsOther"] as? Bool
                    ?? false,
                isSecret: question["isSecret"] as? Bool
                    ?? question["secret"] as? Bool
                    ?? false
            )
        }
    }

    nonisolated var awaitsExternalContinuation: Bool {
        metadata["continuationState"] == "awaiting_client_followup"
    }

    nonisolated var externalContinuationAnsweredAt: Date? {
        guard let rawValue = metadata["continuationAnsweredAt"],
              let timestamp = TimeInterval(rawValue) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    nonisolated var externalContinuationDeadline: Date? {
        guard let answeredAt = externalContinuationAnsweredAt else { return nil }
        return answeredAt.addingTimeInterval(Self.externalContinuationTimeout)
    }

    nonisolated var externalContinuationStatusMessage: String? {
        guard awaitsExternalContinuation else { return nil }
        let actorName = metadata["continuationActorName"] ?? "客户端"
        return "\(actorName) 有问题需要介入处理，可通过上方按钮快速打开并继续操作"
    }

    nonisolated var submittedAnswers: [String: [String]] {
        guard let rawJSON = metadata[Self.submittedAnswersMetadataKey],
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        return object.reduce(into: [String: [String]]()) { partial, entry in
            switch entry.value {
            case let value as String:
                guard !value.isEmpty else { return }
                partial[entry.key] = [value]
            case let values as [String]:
                let filtered = values.filter { !$0.isEmpty }
                guard !filtered.isEmpty else { return }
                partial[entry.key] = filtered
            default:
                break
            }
        }
    }

    nonisolated func hasTimedOutExternalContinuation(now: Date = Date()) -> Bool {
        guard let deadline = externalContinuationDeadline else { return false }
        return now >= deadline
    }

    nonisolated func matchesResolvedToolUseId(_ toolUseId: String) -> Bool {
        id == toolUseId
            || metadata["originalToolUseId"] == toolUseId
            || metadata["toolUseId"] == toolUseId
            || metadata["tool_use_id"] == toolUseId
    }

    nonisolated func markingAwaitingExternalContinuation(
        actorName: String,
        answeredAt: Date = Date(),
        selectedAnswers: [String: [String]]? = nil
    ) -> SessionIntervention {
        var updatedMetadata = metadata
        updatedMetadata["continuationState"] = "awaiting_client_followup"
        updatedMetadata["continuationAnsweredAt"] = String(answeredAt.timeIntervalSince1970)
        updatedMetadata["continuationActorName"] = actorName
        if let selectedAnswers = selectedAnswers,
           let data = try? JSONSerialization.data(withJSONObject: selectedAnswers, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            updatedMetadata[Self.submittedAnswersMetadataKey] = json
        }

        return SessionIntervention(
            id: id,
            kind: kind,
            title: title,
            message: message,
            options: options,
            questions: questions,
            supportsSessionScope: supportsSessionScope,
            metadata: updatedMetadata
        )
    }

    nonisolated var summaryText: String {
        if kind == .question, let firstQuestion = resolvedQuestions.first {
            return firstQuestion.prompt
        }
        if !message.isEmpty {
            return message
        }
        if let firstQuestion = resolvedQuestions.first {
            return firstQuestion.prompt
        }
        if let firstOption = options.first {
            return firstOption.title
        }
        return title
    }

    private nonisolated static func normalizedApprovalOptionIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
