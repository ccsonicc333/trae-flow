import Foundation
import XCTest
@testable import TRAE_FLOW

final class RecentInterventionResponseStoreTests: XCTestCase {
    func testTraeAnswerCanBeReplayedForDuplicateAskUserQuestionPermissionRequest() {
        var store = RecentInterventionResponseStore(ttl: 30)

        let questionEvent = HookEvent(
            sessionId: "trae-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .trae,
            clientInfo: SessionClientInfo(
                kind: .trae,
                profileID: "trae",
                name: "TRAE",
                bundleIdentifier: "com.trae.app"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        let duplicatePermissionEvent = HookEvent(
            sessionId: "trae-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .trae,
            clientInfo: SessionClientInfo(
                kind: .trae,
                profileID: "trae",
                name: "TRAE",
                bundleIdentifier: "com.trae.app"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: questionEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["project": "会话层"])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: duplicatePermissionEvent,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(replay?.updatedInput?["answers"]?.value as? [String: String], ["project": "会话层"])
    }

    func testRecordedAnswerExpiresAfterTTL() {
        var store = RecentInterventionResponseStore(ttl: 5)

        let event = HookEvent(
            sessionId: "trae-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .trae,
            clientInfo: SessionClientInfo(
                kind: .trae,
                profileID: "trae",
                name: "TRAE",
                bundleIdentifier: "com.trae.app"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？"
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: event,
            decision: "answer",
            reason: nil,
            updatedInput: ["answers": AnyCodable(["drink": "绿茶"])],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(store.response(for: event, now: Date(timeIntervalSince1970: 106)))
    }
}
