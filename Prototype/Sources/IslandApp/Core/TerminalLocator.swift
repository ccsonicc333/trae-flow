import AppKit
import Foundation
import IslandShared

protocol TerminalLocator: Sendable {
    func register(context: TerminalContext, for sessionID: String) async
    func focus(session: AgentSession) async -> Bool
}

actor AppleTerminalLocator: TerminalLocator {
    private var contexts: [String: TerminalContext] = [:]

    func register(context: TerminalContext, for sessionID: String) async {
        contexts[sessionID] = context
    }

    func focus(session: AgentSession) async -> Bool {
        let context = contexts[session.id] ?? session.terminalContext
        if let bundle = targetBundle(for: context) {
            return await runAppleScript(scriptFor(bundleID: bundle, context: context))
        }
        return false
    }

    private func targetBundle(for context: TerminalContext) -> String? {
        if let bundleID = context.terminalBundleID {
            return bundleID
        }
        switch context.terminalProgram?.lowercased() {
        case "iterm2", "iterm", "iterm.app":
            return "com.googlecode.iterm2"
        case "apple_terminal", "terminal", "apple terminal":
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
            return nil
        }
    }

    private func scriptFor(bundleID: String, context: TerminalContext) -> String {
        if bundleID == "com.googlecode.iterm2", let sessionID = context.iTermSessionID {
            return """
            tell application id "com.googlecode.iterm2"
                activate
                try
                    set targetSession to first session of (every tab of every window whose id is not missing value) whose id is "\(sessionID)"
                    select targetSession
                end try
            end tell
            """
        }

        if bundleID == "com.apple.Terminal", let tty = context.tty {
            return """
            tell application id "com.apple.Terminal"
                activate
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        try
                            if tty of theTab is "\(tty)" then
                                set frontmost of theWindow to true
                                set selected of theTab to true
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
        }

        return """
        tell application id "\(bundleID)"
            activate
        end tell
        """
    }

    private func runAppleScript(_ source: String) async -> Bool {
        await MainActor.run {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil
        }
    }
}
