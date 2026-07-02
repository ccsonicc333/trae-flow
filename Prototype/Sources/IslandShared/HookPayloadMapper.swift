import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

public enum HookPayloadMapper {
    private static let questionToolNames: Set<String> = [
        "askuserquestion",
        "askfollowupquestion"
    ]

    public static func makeEnvelope(
        source: AgentProvider,
        arguments: [String],
        environment: [String: String],
        stdinData: Data,
        runtimeConfig: BridgeRuntimeConfig = .default
    ) -> BridgeEnvelope {
        let rawPayload = BridgeCodec.readJSONObject(from: stdinData) ?? [:]
        let payload = normalizedPayload(rawPayload, source: source)
        let effectiveEnvironment = bridgedEnvironment(environment: environment, payload: payload)
        let eventType = detectEventType(arguments: arguments, payload: payload)
        let terminalContext = makeTerminalContext(environment: effectiveEnvironment, payload: payload)
        let sessionKey = detectSessionKey(payload: payload, environment: effectiveEnvironment, provider: source)
        var metadata = mergedMetadata(arguments: arguments, payload: payload, environment: effectiveEnvironment, terminalContext: terminalContext)
        if runtimeConfig.routePromptsToTerminal {
            // Marker the app side reads to skip building an in-app prompt for
            // this event. Keeps the envelope flowing for status updates only.
            metadata["suppress_in_app_prompt"] = "true"
        }
        let clientKind = normalizedClientKind(from: metadata)
        let detectedIntervention = detectIntervention(
            provider: source,
            eventType: eventType,
            sessionKey: sessionKey,
            payload: payload,
            clientKind: clientKind
        )
        // When the user has opted to keep prompts in the terminal, drop the
        // intervention before status/expectsResponse are computed so the bridge
        // does not block and the app does not surface a prompt UI.
        let intervention: InterventionRequest? = runtimeConfig.routePromptsToTerminal
            ? nil
            : detectedIntervention
        let status = detectStatus(
            eventType: eventType,
            payload: payload,
            clientKind: clientKind,
            intervention: intervention
        )
        let expectsResponse = runtimeConfig.routePromptsToTerminal
            ? false
            : detectExpectsResponse(
                eventType: eventType,
                payload: payload,
                clientKind: clientKind,
                intervention: intervention
            )

        return BridgeEnvelope(
            provider: source,
            eventType: eventType,
            sessionKey: sessionKey,
            title: detectTitle(payload: payload),
            preview: detectPreview(payload: payload),
            cwd: detectCWD(payload: payload, environment: effectiveEnvironment),
            status: status,
            terminalContext: terminalContext,
            intervention: intervention,
            expectsResponse: expectsResponse,
            metadata: metadata
        )
    }

    public static func shouldDeliverEnvelope(_ envelope: BridgeEnvelope) -> Bool {
        return true
    }

    public static func stdoutPayload(
        for provider: AgentProvider,
        response: BridgeResponse,
        eventType: String,
        metadata: [String: String]
    ) -> String {
        guard let decision = response.decision else {
            return "{}"
        }

        switch provider {
        case .trae:
            switch decision {
            case .approve:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
                """#
            case .approveForSession:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
                """#
            case .deny, .cancel:
                return #"""
                {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Island"}}}
                """#
            case .answer(let answers):
                let usesFullUpdatedInput = shouldPreserveFullUpdatedInputForTraeAnswer(
                    response: response,
                    metadata: metadata
                )
                let payloadObject: Any = usesFullUpdatedInput
                    ? (response.updatedInput?.mapValues(\.foundationObject) ?? answers)
                    : answers

                guard JSONSerialization.isValidJSONObject(payloadObject),
                      let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]),
                      let payloadJson = String(data: payloadData, encoding: .utf8) else {
                    return "{}"
                }

                if eventType.contains("Question") || eventType == "UserInputRequest" || eventType == "UserPromptSubmit" {
                    return """
                    {"hookSpecificOutput":{"hookEventName":"\(eventType)","permissionDecision":"allow","updatedInput":\(payloadJson)}}
                    """
                }

                return """
                {"hookSpecificOutput":{"hookEventName":"\(eventType)","decision":{"behavior":"allow","updatedInput":\(payloadJson)}}}
                """
            }
        }
    }

    private static func shouldPreserveFullUpdatedInputForTraeAnswer(
        response: BridgeResponse,
        metadata: [String: String]
    ) -> Bool {
        guard let updatedInput = response.updatedInput else {
            return false
        }

        if updatedInput["questions"] != nil {
            return true
        }

        let normalizedToolName = metadata["tool_name"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()

        return normalizedToolName.map(questionToolNames.contains) ?? false
    }

    private static func detectEventType(arguments: [String], payload: [String: Any]) -> String {
        // Check explicit fields first
        if let explicit = payload["hook_event_name"] as? String { return explicit }
        if let explicit = payload["event"] as? String { return explicit }
        if let explicit = payload["type"] as? String { return explicit }
        
        // Check arguments
        if let index = arguments.firstIndex(of: "--event"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        
        // Check for questions/user input
        if payload["questions"] != nil { return "UserInputRequest" }
        
        // Check for permission request indicators
        if let reason = payload["reason"] as? String, reason.lowercased().contains("permission") {
            return "PermissionRequest"
        }
        
        // Check for tool use events
        if payload["tool_input"] != nil || payload["tool_name"] != nil { return "PreToolUse" }
        
        return "UnknownEvent"
    }

    private static func detectSessionKey(
        payload: [String: Any],
        environment: [String: String],
        provider: AgentProvider
    ) -> String {
        let candidates = [
            payload["session_id"] as? String,
            payload["sessionId"] as? String,
            payload["thread_id"] as? String,
            payload["threadId"] as? String,
            environment["CLAUDE_SESSION_ID"],
            environment["CODEX_THREAD_ID"],
            environment["ITERM_SESSION_ID"],
            environment["TERM_SESSION_ID"],
            environment["TTY"]
        ]
        if let value = candidates.compactMap({ $0 }).first, !value.isEmpty {
            return "\(provider.rawValue):\(value)"
        }
        let cwd = detectCWD(payload: payload, environment: environment) ?? "unknown"
        return "\(provider.rawValue):\(cwd)"
    }

    private static func detectStatus(
        eventType: String,
        payload: [String: Any],
        clientKind: String?,
        intervention: InterventionRequest?
    ) -> SessionStatus? {
        if let text = payload["status"] as? String {
            if hasAnsweredQuestionPayload(payload) {
                return answeredQuestionStatus(eventType: eventType)
            }
            return mapStatusString(text)
        }
        if hasAnsweredQuestionPayload(payload) {
            return answeredQuestionStatus(eventType: eventType)
        }
        if let intervention {
            switch intervention.kind {
            case .approval:
                return SessionStatus(kind: .waitingForApproval)
            case .question:
                return SessionStatus(kind: .waitingForInput)
            }
        }
        let lowered = eventType.lowercased()
        if lowered.contains("permission") || lowered.contains("approval") {
            return SessionStatus(kind: .waitingForApproval)
        }
        if lowered.contains("question") || lowered.contains("userinput") {
            return SessionStatus(kind: .waitingForInput)
        }
        if lowered.contains("notification") {
            return SessionStatus(kind: .notification)
        }
        // Sub-agent events have to be matched before pretool/posttool/start/end
        // because their names contain those substrings ("subagentstart" matches
        // "start"). The parent session continues processing regardless.
        if lowered == "subagentstart" || lowered == "subagentstop" {
            return SessionStatus(kind: .runningTool)
        }
        if lowered.contains("pretool") {
            return SessionStatus(kind: .runningTool)
        }
        if lowered.contains("posttool") {
            if payload["error"] != nil {
                return SessionStatus(kind: .error)
            }
            return SessionStatus(kind: .active)
        }
        if lowered.contains("stop") || lowered.contains("end") {
            // Per Anthropic hook docs: Stop / StopFailure mean "the agent
            // finished its turn and is waiting for the next user input"; only
            // SessionEnd actually terminates the session.
            switch lowered {
            case "sessionend":
                return SessionStatus(kind: .completed)
            case "stop", "stopfailure":
                return SessionStatus(kind: .waitingForInput)
            default:
                // Unknown stop/end variant from a future client we have not
                // audited: stay conservative so we don't accumulate ghost
                // sessions. The periodic liveness sweep is the safety net if
                // we guessed wrong.
                return SessionStatus(kind: .completed)
            }
        }
        if lowered.contains("compact") {
            return SessionStatus(kind: .compacting)
        }
        if lowered.contains("start") || lowered.contains("submit") {
            return SessionStatus(kind: .thinking)
        }
        return SessionStatus(kind: .active)
    }

    private static func detectExpectsResponse(
        eventType: String,
        payload: [String: Any],
        clientKind: String?,
        intervention: InterventionRequest?
    ) -> Bool {
        if hasAnsweredQuestionPayload(payload) {
            return false
        }

        if let intervention {
            switch intervention.kind {
            case .approval:
                return true
            case .question:
                return shouldSurfaceQuestionIntervention(
                    eventType: eventType,
                    payload: payload,
                    clientKind: clientKind
                )
            }
        }

        return false
    }

    private static func mapStatusString(_ string: String) -> SessionStatus {
        let lowered = string.lowercased()
        switch lowered {
        case let text where text.contains("approval"):
            return SessionStatus(kind: .waitingForApproval, detail: string)
        case let text where text.contains("input") || text.contains("question"):
            return SessionStatus(kind: .waitingForInput, detail: string)
        case let text where text.contains("tool"):
            return SessionStatus(kind: .runningTool, detail: string)
        case let text where text.contains("think"):
            return SessionStatus(kind: .thinking, detail: string)
        case let text where text.contains("compact"):
            return SessionStatus(kind: .compacting, detail: string)
        case let text where text.contains("done") || text.contains("idle"):
            return SessionStatus(kind: .completed, detail: string)
        case let text where text.contains("error") || text.contains("fail"):
            return SessionStatus(kind: .error, detail: string)
        default:
            return SessionStatus(kind: .active, detail: string)
        }
    }

    private static func detectTitle(payload: [String: Any]) -> String? {
        [
            payload["title"] as? String,
            payload["session_title"] as? String,
            payload["tool_name"] as? String,
            payload["hook_event_name"] as? String,
            payload["event"] as? String
        ].compactMap { $0 }.first
    }

    private static func detectPreview(payload: [String: Any]) -> String? {
        if let toolName = payload["tool_name"] as? String {
            if let input = summarizeValue(payload["tool_input"]) {
                return "\(toolName) \(input)"
            }
            return toolName
        }
        return [
            payload["prompt"] as? String,
            payload["message"] as? String,
            payload["last_assistant_message"] as? String,
            payload["command"] as? String,
            summarizeValue(payload["tool_result"]),
            summarizeValue(payload["tool_input"])
        ].compactMap { sanitizedDisplayText($0) }.first
    }

    private static func detectCWD(payload: [String: Any], environment: [String: String]) -> String? {
        let candidateCWD = [
            payload["cwd"] as? String,
            payload["workspace"] as? String,
            environment["PWD"]
        ].compactMap { nonEmpty($0) }.first
        let sessionFileWorkspace = workspacePathFromSessionFilePath(firstNonEmptyString(
            payload["session_file_path"],
            payload["rollout_path"],
            payload["transcript_path"]
        ))

        if shouldPreferSessionFileWorkspace(sessionFileWorkspace, over: candidateCWD) {
            return sessionFileWorkspace
        }

        return candidateCWD ?? sessionFileWorkspace
    }

    private static func makeTerminalContext(environment: [String: String], payload: [String: Any]) -> TerminalContext {
        let terminalProgram = environment["TERM_PROGRAM"]
        let ideContext = detectIDEContext(environment: environment)
        let remoteContext = detectRemoteContext(environment: environment)
        let inferredBundleID = inferredTerminalBundleID(
            for: terminalProgram,
            fallbackIDEBundleID: ideContext.bundleID
        )

        return TerminalContext(
            terminalProgram: terminalProgram,
            terminalBundleID: environment["__CFBundleIdentifier"]
                ?? payload["terminalBundleID"] as? String
                ?? inferredBundleID,
            ideName: ideContext.name,
            ideBundleID: ideContext.bundleID,
            iTermSessionID: environment["ITERM_SESSION_ID"],
            terminalSessionID: environment["TERM_SESSION_ID"],
            tty: environment["TTY"],
            currentDirectory: detectCWD(payload: payload, environment: environment),
            transport: remoteContext.transport,
            remoteHost: remoteContext.remoteHost,
            tmuxSession: environment["TMUX"],
            tmuxPane: environment["TMUX_PANE"]
        )
    }

    private static func inferredTerminalBundleID(
        for program: String?,
        fallbackIDEBundleID: String?
    ) -> String? {
        let normalizedProgram = program?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedProgram {
        case "iterm2", "iterm", "iterm.app":
            return "com.googlecode.iterm2"
        case "apple_terminal", "terminal", "terminal.app":
            return "com.apple.Terminal"
        case "ghostty":
            return "com.mitchellh.ghostty"
        case "cmux":
            return "com.cmuxterm.app"
        case "alacritty":
            return "io.alacritty"
        case "kitty":
            return "net.kovidgoyal.kitty"
        case "hyper":
            return "co.zeit.hyper"
        case "warp", "warpterminal":
            return "dev.warp.Warp-Stable"
        case "wezterm", "wezterm-gui":
            return "com.github.wez.wezterm"
        default:
            return fallbackIDEBundleID
        }
    }

    private static func detectIDEContext(environment: [String: String]) -> (name: String?, bundleID: String?) {
        let bundleIdentifier = environment["__CFBundleIdentifier"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hintKeys = [
            "TERM_PROGRAM",
            "TERM_PROGRAM_VERSION",
            "__CFBundleIdentifier",
            "TRAE_TRACE_ID",
            "TRAE_AGENT",
        ]
        let hints = hintKeys
            .compactMap { environment[$0]?.lowercased() }
            .joined(separator: " ")

        // 与 TRAEFLOW 对齐：先按 bundle-identifier 前缀区分 Trae / Trae CN / SOLO / Work，
        // 保证变体识别正确，避免所有 TRAE 事件都坍缩到基础 Trae profile。
        if let bundleIdentifier {
            switch bundleIdentifier {
            case let id where id.hasPrefix("cn.trae."):
                return ("Trae CN", id)
            case let id where id.hasPrefix("com.trae."):
                return ("Trae", id)
            default:
                break
            }
        }
        if hints.contains("trae-cn") || environment.keys.contains(where: { $0.hasPrefix("TRAE_CN_") }) {
            return ("Trae CN", "cn.trae.app")
        }
        if hints.contains("trae") || environment.keys.contains(where: { $0.hasPrefix("TRAE_") }) {
            return ("Trae", "com.trae.app")
        }

        return (nil, nil)
    }

    private static func detectRemoteContext(environment: [String: String]) -> (transport: String?, remoteHost: String?) {
        let authority = environment["VSCODE_CLI_REMOTE_AUTHORITY"]
            ?? environment["VSCODE_REMOTE_AUTHORITY"]
            ?? environment["REMOTE_CONTAINERS_IPC"]
        let sshConnection = environment["SSH_CONNECTION"] ?? environment["SSH_CLIENT"]

        if let authority, authority.contains("ssh-remote+") {
            return ("ssh-remote", authority.components(separatedBy: "ssh-remote+").last.flatMap(nonEmpty))
        }

        if let sshConnection {
            let preferredHost = nonEmpty(environment["HOSTNAME"])
                ?? nonEmpty(environment["HOST"])
                ?? nonEmpty(ProcessInfo.processInfo.hostName)
            if let preferredHost {
                return ("ssh", preferredHost)
            }

            let parts = sshConnection.split(separator: " ").map(String.init)
            if parts.count >= 3 {
                return ("ssh", nonEmpty(parts[2]))
            }
            return ("ssh", nonEmpty(environment["SSH_TTY"]))
        }

        return (nil, nil)
    }

    private static func detectIntervention(
        provider: AgentProvider,
        eventType: String,
        sessionKey: String,
        payload: [String: Any],
        clientKind: String?
    ) -> InterventionRequest? {
        if hasAnsweredQuestionPayload(payload) {
            return nil
        }

        if let questions = questionPayloads(from: payload), !questions.isEmpty {
            guard shouldSurfaceQuestionIntervention(
                eventType: eventType,
                payload: payload,
                clientKind: clientKind
            ) else {
                return nil
            }
            let options = questions.flatMap { question -> [InterventionOption] in
                let baseID = (question["id"] as? String) ?? UUID().uuidString
                let objectEntries = question["options"] as? [[String: Any]] ?? []
                if !objectEntries.isEmpty {
                    return objectEntries.enumerated().map { index, option in
                        InterventionOption(
                            id: "\(baseID):\(index)",
                            title: option["label"] as? String ?? "Option \(index + 1)",
                            detail: option["description"] as? String
                        )
                    }
                }

                let stringEntries = question["options"] as? [String] ?? []
                if !stringEntries.isEmpty {
                    return stringEntries.enumerated().map { index, option in
                        InterventionOption(
                            id: "\(baseID):\(index)",
                            title: option,
                            detail: nil
                        )
                    }
                }

                if let prompt = (question["question"] as? String) ?? (question["title"] as? String) {
                    return [InterventionOption(id: baseID, title: prompt)]
                }
                return [InterventionOption(id: baseID, title: "Answer")]
            }
            return InterventionRequest(
                sessionID: sessionKey,
                kind: .question,
                title: "\(provider.displayName) needs input",
                message: (questions.first?["question"] as? String)
                    ?? (questions.first?["title"] as? String)
                    ?? "Answer required",
                options: options,
                rawContext: flattenMetadata(payload: payload)
            )
        }

        let lowered = eventType.lowercased()
        guard lowered.contains("permission") || lowered.contains("approval") else {
            return nil
        }
        let message = (payload["reason"] as? String)
            ?? (payload["tool_name"] as? String)
            ?? (payload["command"] as? String)
            ?? "The agent is waiting for permission."
        return InterventionRequest(
            sessionID: sessionKey,
            kind: .approval,
            title: "\(provider.displayName) needs approval",
            message: message,
            options: [
                InterventionOption(id: "approve", title: "Allow Once"),
                InterventionOption(id: "approveForSession", title: "Allow for Session"),
                InterventionOption(id: "deny", title: "Deny")
            ],
            rawContext: flattenMetadata(payload: payload)
        )
    }

    private static func mergedMetadata(
        arguments: [String],
        payload: [String: Any],
        environment: [String: String],
        terminalContext: TerminalContext
    ) -> [String: String] {
        var metadata = flattenMetadata(payload: payload)
        for (key, value) in argumentMetadata(arguments: arguments) {
            metadata[key] = value
        }
        if let toolInput = payload["tool_input"] as? [String: Any],
           JSONSerialization.isValidJSONObject(toolInput),
           let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            metadata["tool_input_json"] = json.replacingOccurrences(of: "\\/", with: "/")
        }
        // Fall back to the host process bundle identifier so IDE-hosted sessions
        // route to the correct app even when the hook profile doesn't explicitly
        // pass --client-bundle-id (e.g. Trae CN vs Trae).
        if let clientBundleID = nonEmpty(environment["__CFBundleIdentifier"]), metadata["client_bundle_id"] == nil {
            metadata["client_bundle_id"] = clientBundleID
        }
        if let terminalBundleID = nonEmpty(terminalContext.terminalBundleID), metadata["terminal_bundle_id"] == nil {
            metadata["terminal_bundle_id"] = terminalBundleID
        }
        if let terminalProgram = nonEmpty(terminalContext.terminalProgram), metadata["terminal_program"] == nil {
            metadata["terminal_program"] = terminalProgram
        }
        if let ideName = nonEmpty(terminalContext.ideName), metadata["client_originator"] == nil {
            metadata["client_originator"] = ideName
        }
        if let transport = nonEmpty(terminalContext.transport), metadata["connection_transport"] == nil {
            metadata["connection_transport"] = transport
        }
        if let remoteHost = nonEmpty(terminalContext.remoteHost), metadata["remote_host"] == nil {
            metadata["remote_host"] = remoteHost
        }
        if let processName = detectedSourceProcessName(), metadata["source_process_name"] == nil {
            metadata["source_process_name"] = processName
        }
        if let resolvedCWD = nonEmpty(terminalContext.currentDirectory) {
            metadata["cwd"] = resolvedCWD
        }
        return metadata
    }

    private static func detectedSourceProcessName() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(getppid()), "-o", "comm="]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return nonEmpty(String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }

    private static func argumentMetadata(arguments: [String]) -> [String: String] {
        let mappings: [String: String] = [
            "--client-kind": "client_kind",
            "--client-name": "client_name",
            "--client-bundle-id": "client_bundle_id",
            "--client-origin": "client_origin",
            "--client-originator": "client_originator",
            "--thread-source": "thread_source",
            "--launch-url": "launch_url",
            // Spec: 通过 Bridge 命令参数 `--variant <value>` 区分四个 Trae 变体事件来源
            "--variant": "variant"
        ]

        var metadata: [String: String] = [:]
        for (flag, key) in mappings {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                continue
            }

            let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                metadata[key] = value
            }
        }

        return metadata
    }

    private static func flattenMetadata(payload: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in payload {
            guard let stringValue = summarizeValue(value) else { continue }
            result[key] = stringValue
        }
        return result
    }

    private static func normalizedPayload(
        _ payload: [String: Any],
        source: AgentProvider
    ) -> [String: Any] {
        return payload
    }

    private static func bridgedEnvironment(
        environment: [String: String],
        payload: [String: Any]
    ) -> [String: String] {
        var merged = environment

        if let bridgedEnvironment = payload["_env"] as? [String: Any] {
            for (key, value) in bridgedEnvironment {
                guard let value = nonEmpty(summarizeValue(value)) else { continue }
                merged[key] = value
            }
        }

        if let bridgedTTY = nonEmpty(payload["_tty"] as? String) {
            merged["TTY"] = bridgedTTY
        }

        return merged
    }

    private static func summarizeValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let string as String:
            return sanitizedDisplayText(string)
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            guard JSONSerialization.isValidJSONObject(array),
                  let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string.replacingOccurrences(of: "\\/", with: "/")
        case let object as [String: Any]:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string.replacingOccurrences(of: "\\/", with: "/")
        default:
            return nil
        }
    }

    private static func decodedJSONObject(from rawValue: Any?) -> [String: Any]? {
        guard let rawValue else { return nil }

        if let object = rawValue as? [String: Any] {
            return object
        }

        if let string = rawValue as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        values.compactMap { summarizeValue($0) }.first
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func workspacePathFromSessionFilePath(_ sessionFilePath: String?) -> String? {
        guard let sessionFilePath = nonEmpty(sessionFilePath) else { return nil }
        let components = URL(fileURLWithPath: sessionFilePath)
            .standardizedFileURL
            .pathComponents
        guard let projectsIndex = components.lastIndex(of: "projects"),
              components.indices.contains(projectsIndex + 1),
              projectsIndex > 0,
              components[projectsIndex - 1].hasPrefix(".") else {
            return nil
        }

        let slug = components[projectsIndex + 1]
        return candidateWorkspacePaths(fromProjectSlug: slug).first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private static func shouldPreferSessionFileWorkspace(
        _ sessionFileWorkspace: String?,
        over candidateCWD: String?
    ) -> Bool {
        guard let sessionFileWorkspace else { return false }
        guard let candidateCWD = nonEmpty(candidateCWD) else { return true }

        let normalizedCandidate = URL(fileURLWithPath: candidateCWD).standardizedFileURL.path
        let normalizedWorkspace = URL(fileURLWithPath: sessionFileWorkspace).standardizedFileURL.path
        guard normalizedCandidate != normalizedWorkspace else { return false }

        var candidateIsDirectory: ObjCBool = false
        let candidateExists = FileManager.default.fileExists(
            atPath: normalizedCandidate,
            isDirectory: &candidateIsDirectory
        ) && candidateIsDirectory.boolValue

        if !candidateExists {
            return true
        }

        return isTopLevelClientConfigDirectory(normalizedCandidate)
    }

    private static func isTopLevelClientConfigDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let knownClientDirectories: Set<String> = [
            ".claude",
            ".codex"
        ]
        guard knownClientDirectories.contains(url.lastPathComponent) else {
            return false
        }

        return url.deletingLastPathComponent().path
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private static func candidateWorkspacePaths(fromProjectSlug slug: String) -> [String] {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSlug = trimmedSlug.hasPrefix("-")
            ? String(trimmedSlug.dropFirst())
            : trimmedSlug
        let parts = normalizedSlug
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count >= 2, parts.count <= 12 else {
            return []
        }

        var candidates: [String] = []
        var seen: Set<String> = []

        func appendCandidates(startIndex: Int, pathComponents: [String]) {
            if startIndex == parts.count {
                let path = "/" + pathComponents.joined(separator: "/")
                if seen.insert(path).inserted {
                    candidates.append(path)
                }
                return
            }

            var component = ""
            for index in startIndex..<parts.count {
                component = component.isEmpty ? parts[index] : component + "-" + parts[index]
                appendCandidates(
                    startIndex: index + 1,
                    pathComponents: pathComponents + [component]
                )
            }
        }

        appendCandidates(startIndex: 0, pathComponents: [])
        return candidates.sorted { lhs, rhs in
            lhs.split(separator: "/").count > rhs.split(separator: "/").count
        }
    }

    private static func normalizedClientKind(from metadata: [String: String]) -> String? {
        let explicitClientKind = metadata["client_kind"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let explicitClientKind, !explicitClientKind.isEmpty {
            return explicitClientKind
        }
        return nil
    }

    private static func questionPayloads(from payload: [String: Any]) -> [[String: Any]]? {
        if let questions = payload["questions"] as? [[String: Any]], !questions.isEmpty {
            return questions
        }
        if let questions = decodedQuestions(from: payload["questions"]) {
            return questions
        }
        if let toolInput = payload["tool_input"] as? [String: Any],
           let questions = toolInput["questions"] as? [[String: Any]],
           !questions.isEmpty {
            return questions
        }
        if let toolInput = payload["tool_input"] as? [String: Any],
           let questions = decodedQuestions(from: toolInput["questions"]) {
            return questions
        }
        return nil
    }

    private static func hasAnsweredQuestionPayload(_ payload: [String: Any]) -> Bool {
        guard questionToolNames.contains(normalizedToolName(from: payload) ?? "") else {
            return false
        }

        let answersCandidate =
            (payload["tool_input"] as? [String: Any])?["answers"]
            ?? payload["answers"]

        guard let answersCandidate else { return false }

        if let answers = answersCandidate as? [String: Any] {
            return !answers.isEmpty
        }
        if let answers = answersCandidate as? [String: String] {
            return !answers.isEmpty
        }
        return false
    }

    private static func answeredQuestionStatus(eventType: String) -> SessionStatus {
        switch eventType {
        case "PreToolUse":
            return SessionStatus(kind: .runningTool)
        case "PostToolUse":
            return SessionStatus(kind: .active)
        default:
            return SessionStatus(kind: .active)
        }
    }

    private static func normalizedToolName(from payload: [String: Any]) -> String? {
        guard let toolName = payload["tool_name"] as? String else { return nil }
        return toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func shouldSurfaceQuestionIntervention(
        eventType: String,
        payload: [String: Any],
        clientKind: String?
    ) -> Bool {
        if hasAnsweredQuestionPayload(payload) {
            return false
        }

        return eventType == "PreToolUse" || eventType == "UserInputRequest"
    }

    private static func decodedQuestions(from rawValue: Any?) -> [[String: Any]]? {
        guard let rawValue else { return nil }

        if let questions = rawValue as? [[String: Any]], !questions.isEmpty {
            return questions
        }

        if let question = rawValue as? [String: Any] {
            return [question]
        }

        if let string = rawValue as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let questions = json as? [[String: Any]], !questions.isEmpty {
                return questions
            }
            if let question = json as? [String: Any] {
                return [question]
            }
        }

        return nil
    }

    private static func sanitizedDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }

        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*?</system-reminder>"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*$"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }
}

private extension AgentProvider {
    var displayName: String {
        switch self {
        case .trae:
            return "Trae"
        }
    }
}
