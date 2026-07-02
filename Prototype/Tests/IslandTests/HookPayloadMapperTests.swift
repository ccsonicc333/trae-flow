import Foundation
import IslandShared
import Testing

@Test
func mapsApprovalEventFromHookPayload() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "reason": "Needs to run tests",
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "iterm-1", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.provider == .trae)
    #expect(envelope.eventType == "PermissionRequest")
    #expect(envelope.intervention?.kind == .approval)
    #expect(envelope.status?.kind == .waitingForApproval)
    #expect(envelope.sessionKey == "trae:abc123")
}

@Test
func routePromptsToTerminalDropsApprovalIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "reason": "Needs to run tests",
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload,
        runtimeConfig: BridgeRuntimeConfig(routePromptsToTerminal: true)
    )

    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
}

@Test
func routePromptsToTerminalDropsAskUserQuestionIntervention() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {"id": "q1", "question": "Pick one", "options": ["A", "B"]}
        ]
      },
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload,
        runtimeConfig: BridgeRuntimeConfig(routePromptsToTerminal: true)
    )

    #expect(envelope.intervention == nil)
    #expect(envelope.expectsResponse == false)
}

@Test
func bridgeRuntimeConfigLoadsFromEnvironmentPath() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "routePromptsToTerminal": true
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = BridgeRuntimeConfig.load(
            environment: [BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path()]
        )

        #expect(config.routePromptsToTerminal)
    }
}

@Test
func bridgeRuntimeConfigLoadedFromEnvironmentDropsApprovalIntervention() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "routePromptsToTerminal": true
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let environment = [
            BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path(),
            "TERM_PROGRAM": "iTerm.app",
            "PWD": "/tmp/demo"
        ]
        let payload = """
        {
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "reason": "Needs to run tests",
          "session_id": "abc123"
        }
        """.data(using: .utf8)!

        let envelope = HookPayloadMapper.makeEnvelope(
            source: .trae,
            arguments: ["island-bridge", "--source", "trae"],
            environment: environment,
            stdinData: payload,
            runtimeConfig: BridgeRuntimeConfig.load(environment: environment)
        )

        #expect(envelope.intervention == nil)
        #expect(envelope.expectsResponse == false)
        #expect(envelope.metadata["suppress_in_app_prompt"] == "true")
    }
}

@Test
func mapsGhosttyTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "ghostty-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: [
            "TERM_PROGRAM": "ghostty",
            "TERM_SESSION_ID": "ghostty-terminal-1",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "ghostty")
    #expect(envelope.terminalContext.terminalBundleID == "com.mitchellh.ghostty")
    #expect(envelope.terminalContext.terminalSessionID == "ghostty-terminal-1")
}

@Test
func mapsCmuxTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "cmux-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: [
            "TERM_PROGRAM": "cmux",
            "TERM_SESSION_ID": "65a2028f-a93c-48e0-b46a-3f4c20c94b81",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "cmux")
    #expect(envelope.terminalContext.terminalBundleID == "com.cmuxterm.app")
    #expect(envelope.terminalContext.terminalSessionID == "65a2028f-a93c-48e0-b46a-3f4c20c94b81")
}

@Test
func mapsWezTermTerminalContextFromEnvironment() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "wezterm-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "WezTerm", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.terminalContext.terminalProgram == "WezTerm")
    #expect(envelope.terminalContext.terminalBundleID == "com.github.wez.wezterm")
}

@Test
func mapsSSHRemoteHostFromHostnameEnvironmentBeforeConnectionIP() throws {
    let payload = """
    {
      "hook_event_name": "UserPromptSubmit",
      "session_id": "ssh-hostname-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: [
            "SSH_CONNECTION": "192.168.1.2 49822 10.0.0.10 22",
            "HOSTNAME": "devbox",
            "PWD": "/tmp/demo"
        ],
        stdinData: payload
    )

    #expect(envelope.terminalContext.transport == "ssh")
    #expect(envelope.terminalContext.remoteHost == "devbox")
    #expect(envelope.metadata["remote_host"] == "devbox")
}

@Test
func mapsQuestionEventOptions() throws {
    let payload = """
    {
      "questions": [{
        "id": "terminal_scope",
        "question": "Which terminal?",
        "options": [
          {"label": "iTerm2", "description": "Primary recommendation"},
          {"label": "Terminal", "description": "Fallback"}
        ]
      }]
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.intervention?.kind == .question)
    #expect(envelope.intervention?.options.count == 2)
    #expect(envelope.status?.kind == .waitingForInput)
}

@Test
func claudePermissionPayloadUsesHookSpecificOutput() throws {
    let payload = HookPayloadMapper.stdoutPayload(
        for: .trae,
        response: BridgeResponse(requestID: UUID(), decision: .approve),
        eventType: "PermissionRequest",
        metadata: [:]
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
}

@Test
func claudeQuestionAnswerPayloadPreservesFullUpdatedInputForPermissionRequests() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "id": .string("terminal_scope"),
                    "question": .string("Which terminal?"),
                    "options": .array([
                        .object(["label": .string("iTerm2")]),
                        .object(["label": .string("Terminal")])
                    ])
                ])
            ]),
            "answers": .object([
                "Which terminal?": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .trae,
        response: response,
        eventType: "PermissionRequest",
        metadata: [:]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")

    let updatedInput = try #require(decision["updatedInput"] as? [String: Any])
    let questions = try #require(updatedInput["questions"] as? [[String: Any]])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(questions.first?["question"] as? String == "Which terminal?")
    #expect(answers["Which terminal?"] == "iTerm2")
}

@Test
func bridgeAnswerPayloadExtractsNestedAnswersForRemoteQuestionResponses() {
    let extracted = BridgeAnswerPayload.extractAnswers(from: [
        "questions": .array([
            .object([
                "id": .string("terminal_scope"),
                "question": .string("Which terminal?")
            ])
        ]),
        "answers": .object([
            "Which terminal?": .string("iTerm2"),
            "selection_index": .int(1),
            "confirmed": .bool(true),
            "choices": .array([
                .string("iTerm2"),
                .string("Terminal")
            ])
        ])
    ])

    #expect(extracted["Which terminal?"] == "iTerm2")
    #expect(extracted["selection_index"] == "1")
    #expect(extracted["confirmed"] == "true")
    #expect(extracted["choices"] == "iTerm2, Terminal")
}

@Test
func claudeUserInputAnswerPayloadPreservesFullUpdatedInput() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([:]),
        updatedInput: [
            "questions": .array([
                .object([
                    "question": .string("Which terminal?")
                ])
            ]),
            "answers": .object([
                "Which terminal?": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .trae,
        response: response,
        eventType: "UserInputRequest",
        metadata: [:]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    #expect(hookSpecificOutput["permissionDecision"] as? String == "allow")

    let updatedInput = try #require(hookSpecificOutput["updatedInput"] as? [String: Any])
    let questions = try #require(updatedInput["questions"] as? [[String: Any]])
    let answers = try #require(updatedInput["answers"] as? [String: String])
    #expect(questions.first?["question"] as? String == "Which terminal?")
    #expect(answers["Which terminal?"] == "iTerm2")
}

@Test
func claudeNonQuestionAnswerPayloadKeepsLegacyFlattenedShape() throws {
    let response = BridgeResponse(
        requestID: UUID(),
        decision: .answer([
            "terminal_scope": "iTerm2"
        ]),
        updatedInput: [
            "answers": .object([
                "terminal_scope": .string("iTerm2")
            ])
        ]
    )

    let payload = HookPayloadMapper.stdoutPayload(
        for: .trae,
        response: response,
        eventType: "PermissionRequest",
        metadata: ["tool_name": "Bash"]
    )

    let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let hookSpecificOutput = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(hookSpecificOutput["decision"] as? [String: Any])
    let updatedInput = try #require(decision["updatedInput"] as? [String: String])
    #expect(updatedInput["terminal_scope"] == "iTerm2")
}

@Test
func previewFallsBackToStructuredToolInput() throws {
    let payload = """
    {
      "hook_event_name": "PreToolUse",
      "tool_name": "Bash",
      "tool_input": {"command": "npm test"},
      "session_id": "abc123"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.preview == #"Bash {"command":"npm test"}"#)
}

@Test
func claudePostToolUseResolvedQuestionDoesNotKeepSocketOpen() throws {
    let payload = """
    {
      "hook_event_name": "PostToolUse",
      "session_id": "claude-resolved-question",
      "tool_name": "AskUserQuestion",
      "tool_input": {
        "questions": [
          {
            "header": "任务",
            "question": "你想先处理哪个部分？",
            "options": [{"label": "SessionStore"}]
          }
        ],
        "answers": {
          "你想先处理哪个部分？": "SessionStore"
        }
      },
      "tool_response": {
        "questions": [
          {
            "header": "任务",
            "question": "你想先处理哪个部分？",
            "options": [{"label": "SessionStore"}]
          }
        ],
        "answers": {
          "你想先处理哪个部分？": "SessionStore"
        }
      },
      "transcript_path": "/tmp/claude-resolved-question.jsonl"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "PostToolUse")
    #expect(envelope.status?.kind == .active)
    #expect(envelope.expectsResponse == false)
    #expect(envelope.intervention == nil)
    #expect(envelope.metadata["tool_response"]?.contains("SessionStore") == true)
}

// MARK: - Stop family mapping (fix-claude-sound-triggers)

@Test
func claudeStopMapsToWaitingForInput() throws {
    let payload = """
    {
      "hook_event_name": "Stop",
      "session_id": "claude-stop-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "Stop")
    #expect(envelope.status?.kind == .waitingForInput)
    #expect(envelope.intervention == nil)
}

@Test
func claudeSubagentStopMapsToRunningTool() throws {
    let payload = """
    {
      "hook_event_name": "SubagentStop",
      "session_id": "claude-subagent-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SubagentStop")
    #expect(envelope.status?.kind == .runningTool)
}

@Test
func claudeSubagentStartMapsToRunningTool() throws {
    let payload = """
    {
      "hook_event_name": "SubagentStart",
      "session_id": "claude-subagent-2"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SubagentStart")
    #expect(envelope.status?.kind == .runningTool)
}

@Test
func claudeStopFailureMapsToWaitingForInput() throws {
    let payload = """
    {
      "hook_event_name": "StopFailure",
      "session_id": "claude-stopfail-1",
      "error": "rate_limit"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "StopFailure")
    #expect(envelope.status?.kind == .waitingForInput)
}

@Test
func claudeSessionEndMapsToCompleted() throws {
    let payload = """
    {
      "hook_event_name": "SessionEnd",
      "session_id": "claude-end-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "SessionEnd")
    #expect(envelope.status?.kind == .completed)
}

@Test
func unknownStopVariantFallsBackToCompleted() throws {
    // Conservative default: an unknown stop/end-substring event we have not
    // audited stays mapped to .completed so we don't accumulate ghost sessions.
    let payload = """
    {
      "hook_event_name": "MysteryStopThing",
      "session_id": "claude-mystery-1"
    }
    """.data(using: .utf8)!

    let envelope = HookPayloadMapper.makeEnvelope(
        source: .trae,
        arguments: ["island-bridge", "--source", "trae"],
        environment: ["TERM_PROGRAM": "iTerm.app", "PWD": "/tmp/demo"],
        stdinData: payload
    )

    #expect(envelope.eventType == "MysteryStopThing")
    #expect(envelope.status?.kind == .completed)
}
