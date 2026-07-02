import Foundation

struct SessionConversationPreviewSnapshot: Equatable {
    let userText: String?
    let assistantText: String?
}

enum SessionConversationPreviewBuilder {
    static func snapshot(for session: SessionState) -> SessionConversationPreviewSnapshot {
        SessionConversationPreviewSnapshot(
            userText: latestUserText(for: session),
            assistantText: latestAssistantText(for: session)
        )
    }

    static func attentionSummary(for session: SessionState) -> String? {
        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        if let preview = sanitized(session.previewText) {
            return preview
        }

        if let lastMessage = sanitized(session.lastMessage) {
            return lastMessage
        }

        if let toolName = sanitized(session.phase.approvalToolName) {
            return "Waiting for approval: \(toolName)"
        }

        return session.needsApprovalResponse
            ? "Waiting for approval"
            : nil
    }

    static func fallbackPreview(for session: SessionState) -> String? {
        if session.needsApprovalResponse || session.needsQuestionResponse {
            return attentionSummary(for: session)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage)
    }

    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? nil : collapsed
    }

    private static func latestUserText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    private static func latestAssistantText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                return sanitized(text)
            case .thinking(let text):
                return sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                return preview.map { "\(label) \($0)" } ?? label
            case .interrupted:
                return "已中断"
            case .user:
                continue
            }
        }

        if session.needsApprovalResponse || session.needsQuestionResponse {
            return attentionSummary(for: session)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage)
    }
}
