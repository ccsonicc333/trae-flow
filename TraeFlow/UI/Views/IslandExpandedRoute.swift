import Foundation

enum IslandExpandedSurface: Equatable {
    case docked
    case floating
}

enum IslandExpandedTrigger: Equatable {
    case click
    case hover
    case notification
    case pinnedList
}

enum IslandExpandedRoute: Equatable {
    case sessionList
    case hoverDashboard
    case attentionNotification(SessionState)
    case completionNotification(SessionCompletionNotification)
    case chat(SessionState)
    /// Spec 2.4: 自定义内容全屏面板，由点击 Flow 岛左半区触发
    case customExpanded
}

enum IslandExpandedRouteResolver {
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType,
        sessions: [SessionState],
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> IslandExpandedRoute {
        switch trigger {
        case .notification:
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
        case .click, .hover, .pinnedList:
            break
        }

        if case .chat(let session) = contentType {
            return .chat(session)
        }

        // Spec 2.4: 自定义内容全屏面板优先于默认列表/看板路由
        if case .customExpanded = contentType {
            return .customExpanded
        }

        switch (surface, trigger) {
        case (.docked, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            return .sessionList
        case (.docked, .hover), (.floating, .hover):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            // 没有任务时统一显示 hover 预览空状态；有任务时显示任务列表
            return sessions.isEmpty ? .hoverDashboard : .sessionList
        case (.floating, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            // 没有任务时统一显示 hover 预览空状态；有任务时显示任务列表
            return sessions.isEmpty ? .hoverDashboard : .sessionList
        case (_, .click), (_, .pinnedList):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            // 没有任务时统一显示 hover 预览空状态；有任务时显示任务列表
            return sessions.isEmpty ? .hoverDashboard : .sessionList
        }
    }

    nonisolated static func orderedSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    nonisolated static func activePreviewSessions(from sessions: [SessionState]) -> [SessionState] {
        orderedSessions(from: sessions).filter {
            $0.phase.isActive || $0.phase == .waitingForInput || $0.isRecentlyCompleted
        }
    }

    nonisolated static func highestPriorityAttentionSession(from sessions: [SessionState]) -> SessionState? {
        orderedSessions(from: sessions)
            .filter(\.needsPromptNotification)
            .sorted(by: attentionSort)
            .first
    }

    nonisolated private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}
