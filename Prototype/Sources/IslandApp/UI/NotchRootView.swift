import IslandShared
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        let snapshot = appModel.snapshot
        VStack(spacing: 12) {
            header(snapshot: snapshot)
            if snapshot.isExpanded {
                Divider()
                    .overlay(.white.opacity(0.08))
                bodyContent(snapshot: snapshot)
            }
        }
        .padding(snapshot.isExpanded ? 18 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: snapshot.isExpanded ? 28 : 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: snapshot.isExpanded ? 28 : 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: snapshot.isExpanded)
    }

    private func header(snapshot: SessionSnapshot) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(snapshot.highlightedIntervention == nil ? Color.green.opacity(0.9) : Color.orange.opacity(0.95))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.highlightedIntervention?.title ?? "Island")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(summaryText(snapshot: snapshot))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer()
            Button(snapshot.isExpanded ? "Collapse" : "Expand") {
                appModel.toggleExpanded()
            }
            .buttonStyle(PillButtonStyle(accent: snapshot.highlightedIntervention == nil ? .white.opacity(0.08) : .orange.opacity(0.18)))
        }
    }

    private func bodyContent(snapshot: SessionSnapshot) -> some View {
        VStack(spacing: 14) {
            if let request = snapshot.highlightedIntervention {
                interventionCard(
                    request,
                    session: snapshot.sessions.first(where: { $0.id == request.sessionID })
                )
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(snapshot.sessions) { session in
                        SessionRow(session: session, isSelected: snapshot.selectedSessionID == session.id) {
                            appModel.select(sessionID: session.id)
                            appModel.focus(session)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func interventionCard(_ request: InterventionRequest, session: AgentSession?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(request.message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(5)

            let details = interventionDetails(for: request, session: session)
            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details) { detail in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(detail.label)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.48))
                            Text(detail.value)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(detail.lineLimit)
                        }
                    }
                }
            }

            if request.kind == .approval {
                HStack(spacing: 8) {
                    Button("Allow Once") { appModel.approve(request) }
                        .buttonStyle(PillButtonStyle(accent: .green.opacity(0.28)))
                    if supportsSessionScope(request, session: session) {
                        Button("Allow Session") { appModel.approve(request, forSession: true) }
                            .buttonStyle(PillButtonStyle(accent: .blue.opacity(0.24)))
                    }
                    Button("Deny") { appModel.deny(request) }
                        .buttonStyle(PillButtonStyle(accent: .red.opacity(0.22)))
                    if canFocus(session) {
                        Button("Terminal") { appModel.focus(sessionID: request.sessionID) }
                            .buttonStyle(PillButtonStyle(accent: .white.opacity(0.08)))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(request.options) { option in
                            Button {
                                appModel.answer(request, option: option)
                            } label: {
                                Text(option.title)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PillButtonStyle(accent: .white.opacity(0.08)))
                        }
                    }
                    if canFocus(session) {
                        Button("Open Terminal") { appModel.focus(sessionID: request.sessionID) }
                            .buttonStyle(PillButtonStyle(accent: .white.opacity(0.08)))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    private func summaryText(snapshot: SessionSnapshot) -> String {
        if let intervention = snapshot.highlightedIntervention {
            return intervention.message
        }
        if let first = snapshot.sessions.first {
            return "\(first.provider.rawValue.capitalized) · \(first.status.kind.rawValue)"
        }
        return "The island awaits"
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.12),
                Color(red: 0.03, green: 0.04, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Color.orange.opacity(0.16), .clear],
                center: .top,
                startRadius: 16,
                endRadius: 220
            )
        )
    }

    private func interventionDetails(for request: InterventionRequest, session: AgentSession?) -> [InterventionDetail] {
        var details: [InterventionDetail] = []

        if let tool = request.rawContext["tool_name"] ?? request.rawContext["tool"] {
            details.append(InterventionDetail(label: "Tool", value: tool, lineLimit: 1))
        }
        if let command = request.rawContext["command"] {
            details.append(InterventionDetail(label: "Command", value: command, lineLimit: 3))
        }
        if let input = request.rawContext["tool_input"] {
            details.append(InterventionDetail(label: "Input", value: input, lineLimit: 4))
        }
        if let cwd = session?.cwd ?? request.rawContext["cwd"] ?? request.rawContext["workspace"] {
            details.append(InterventionDetail(label: "Workspace", value: cwd, lineLimit: 1))
        }

        return details
    }

    private func supportsSessionScope(_ request: InterventionRequest, session: AgentSession?) -> Bool {
        return true
    }

    private func canFocus(_ session: AgentSession?) -> Bool {
        guard let session else { return false }
        let context = session.terminalContext
        return context.terminalBundleID != nil
            || context.terminalProgram != nil
            || context.iTermSessionID != nil
            || context.tty != nil
    }
}

private struct InterventionDetail: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let lineLimit: Int
}

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(session.status.kind.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(session.status.requiresAttention ? Color.orange : .white.opacity(0.52))
                    }
                    Text(session.preview)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                    if let cwd = session.cwd {
                        Text(cwd)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? .white.opacity(0.12) : .white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PillButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.65 : 1))
            )
    }
}
