//
//  TerminalSessionFocuser.swift
//  TraeFlow
//
//  Brings a terminal application (iTerm2, Terminal.app, Ghostty) to the front
//  and selects the tab/pane/window that owns a session.
//

import AppKit
import Foundation

/// A lightweight snapshot of the frontmost Ghostty terminal used for
/// workspace/identifier matching when routing focus back to a session.
struct GhosttyTerminalSnapshot: Equatable, Sendable {
    let terminalSessionIdentifier: String
    let workingDirectory: String

    init(terminalSessionIdentifier: String, workingDirectory: String) {
        self.terminalSessionIdentifier = terminalSessionIdentifier
        self.workingDirectory = workingDirectory
    }
}

actor TerminalSessionFocuser {
    static let shared = TerminalSessionFocuser()

    private init() {}

    // MARK: - Public focus API

    /// Focus the terminal tab/pane/window that owns `sessionId`.
    ///
    /// `terminalPid` is the PID of the terminal application (or a helper process
    /// that will be remapped to its host bundle). `tty` and `candidateProcessIDs`
    /// are best-effort hints for matching the right pane when an explicit
    /// terminal/iTerm session identifier is unavailable.
    func focusSession(
        terminalPid: Int,
        tty: String?,
        candidateProcessIDs: [Int],
        sessionId: String,
        clientInfo: SessionClientInfo,
        workspacePath: String,
        launchURL: String?,
        remoteHostHint: String? = nil
    ) async -> Bool {
        let bundleIdentifier = await Self.resolveTerminalBundleIdentifier(
            terminalPid: terminalPid,
            clientInfo: clientInfo
        )

        guard let bundleIdentifier else {
            await FocusDiagnosticsStore.shared.record(
                "TerminalSessionFocuser focusSession no-bundle session=\(sessionId) pid=\(terminalPid)"
            )
            return false
        }

        let normalizedBundle = TerminalAppRegistry.normalizedHostBundleIdentifier(for: bundleIdentifier).lowercased()

        let activated = await Self.activateApplication(
            bundleIdentifier: normalizedBundle,
            pid: terminalPid
        )

        let didFocus: Bool
        switch normalizedBundle {
        case "com.googlecode.iterm2":
            didFocus = await Self.focusITermSession(
                sessionId: sessionId,
                clientInfo: clientInfo,
                tty: tty
            )
        case "com.apple.terminal":
            didFocus = await Self.focusTerminalAppSession(tty: tty)
        case "com.mitchellh.ghostty", "com.cmuxterm.app":
            didFocus = await Self.focusGhosttySession(
                clientInfo: clientInfo,
                workspacePath: workspacePath
            )
        default:
            didFocus = false
        }

        await FocusDiagnosticsStore.shared.record(
            "TerminalSessionFocuser focusSession session=\(sessionId) bundle=\(normalizedBundle) pid=\(terminalPid) tty=\(tty ?? "nil") activated=\(activated) focused=\(didFocus)"
        )

        return didFocus || activated
    }

    /// Returns a snapshot of the frontmost Ghostty terminal, or `nil` if
    /// Ghostty is not running or the frontmost terminal cannot be queried.
    func frontmostGhosttyTerminalSnapshot() async -> GhosttyTerminalSnapshot? {
        let script = """
        tell application "Ghostty"
            set frontTerminal to front terminal
            set terminalID to id of frontTerminal
            set workingDir to working directory of frontTerminal
            return terminalID & linefeed & workingDir
        end tell
        """

        guard let result = await Self.runAppleScriptReturningString(script),
              !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 2 else {
            let normalized = Self.normalizedGhosttyTerminalIdentifier(result)
            return normalized.map {
                GhosttyTerminalSnapshot(terminalSessionIdentifier: $0, workingDirectory: "")
            }
        }

        let rawIdentifier = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = Self.normalizedGhosttyTerminalIdentifier(rawIdentifier) ?? rawIdentifier
        guard !identifier.isEmpty else { return nil }

        return GhosttyTerminalSnapshot(
            terminalSessionIdentifier: identifier,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - Ghostty identifier helpers

    /// Normalizes a Ghostty terminal identifier into a stable uppercase UUID
    /// string. Returns `nil` for empty values, `ghostty://` URL prefixes that
    /// do not resolve to a UUID, or any non-UUID value.
    nonisolated static func normalizedGhosttyTerminalIdentifier(_ identifier: String?) -> String? {
        guard let raw = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let candidate: String
        if raw.lowercased().hasPrefix("ghostty:") {
            candidate = raw.components(separatedBy: "/").last ?? raw
        } else {
            candidate = raw
        }

        guard Self.isUUID(candidate) else { return nil }
        return candidate.uppercased()
    }

    /// Compares a Ghostty snapshot working directory against a session workspace
    /// path, normalizing for `file://` prefixes, trailing slashes, and symlinks.
    nonisolated static func ghosttyWorkingDirectoryMatches(
        snapshotWorkingDirectory: String,
        workspacePath: String
    ) -> Bool {
        let normalizedSnapshot = Self.normalizedPath(snapshotWorkingDirectory)
        let normalizedWorkspace = Self.normalizedPath(workspacePath)
        guard !normalizedSnapshot.isEmpty, !normalizedWorkspace.isEmpty else {
            return false
        }
        return normalizedSnapshot == normalizedWorkspace
    }

    // MARK: - Ghostty AppleScript generation

    /// Builds the AppleScript lines used to select a Ghostty terminal by stable
    /// identifier (when a UUID is available) and/or by working directory.
    nonisolated static func ghosttySelectionScriptLines(
        terminalSessionIdentifier: String?,
        workspacePath: String
    ) -> [String] {
        let escapedWorkspace = Self.escapeAppleScriptString(workspacePath)
        var lines: [String] = []
        lines.append("tell application \"Ghostty\"")
        lines.append("activate")

        let normalizedID = Self.normalizedGhosttyTerminalIdentifier(terminalSessionIdentifier)

        if let normalizedID {
            lines.append("set targetTerminalID to \"\(normalizedID)\"")
            lines.append("set targetTerminal to first terminal whose id is targetTerminalID")
            lines.append("set targetPath to \"\(escapedWorkspace)\"")
            lines.append("try")
            lines.append("focus targetTerminal")
            lines.append("on error")
            lines.append("set exactMatches to every terminal whose working directory is targetPath")
            lines.append("if (count of exactMatches) > 0 then")
            lines.append("focus (item 1 of exactMatches)")
            lines.append("end if")
            lines.append("end try")
        } else {
            lines.append("set targetPath to \"\(escapedWorkspace)\"")
            lines.append("set exactMatches to every terminal whose working directory is targetPath")
            lines.append("if (count of exactMatches) > 0 then")
            lines.append("focus (item 1 of exactMatches)")
            lines.append("end if")
        }

        lines.append("end tell")
        return lines
    }

    // MARK: - Private focus dispatchers

    nonisolated private static func focusITermSession(
        sessionId: String,
        clientInfo: SessionClientInfo,
        tty: String?
    ) async -> Bool {
        let iTermSessionID = clientInfo.iTermSessionIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard iTermSessionID?.isEmpty == false || tty?.isEmpty == false else {
            return false
        }

        let script = Self.iTermSelectionScript(
            iTermSessionIdentifier: iTermSessionID,
            tty: tty
        )
        return await Self.runAppleScript(script)
    }

    nonisolated private static func focusTerminalAppSession(tty: String?) async -> Bool {
        guard let tty, !tty.isEmpty else { return false }
        let script = Self.terminalAppSelectionScript(tty: tty)
        return await Self.runAppleScript(script)
    }

    nonisolated private static func focusGhosttySession(
        clientInfo: SessionClientInfo,
        workspacePath: String
    ) async -> Bool {
        let terminalSessionID = clientInfo.terminalSessionIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = Self.ghosttySelectionScriptLines(
            terminalSessionIdentifier: terminalSessionID,
            workspacePath: workspacePath
        )
        let script = lines.joined(separator: "\n")
        return await Self.runAppleScript(script)
    }

    // MARK: - AppleScript builders

    nonisolated private static func iTermSelectionScript(
        iTermSessionIdentifier: String?,
        tty: String?
    ) -> String {
        var lines: [String] = []
        lines.append("tell application \"iTerm\"")
        lines.append("activate")

        if let iTermSessionIdentifier, !iTermSessionIdentifier.isEmpty {
            let escaped = Self.escapeAppleScriptString(iTermSessionIdentifier)
            lines.append("set targetSessionID to \"\(escaped)\"")
            lines.append("repeat with aWindow in windows")
            lines.append("repeat with aTab in tabs of aWindow")
            lines.append("repeat with aSession in sessions of aTab")
            lines.append("if (id of aSession as text) is targetSessionID then")
            lines.append("select aTab")
            lines.append("set current session of aTab to aSession")
            lines.append("set index of aWindow to 1")
            lines.append("return")
            lines.append("end if")
            lines.append("end repeat")
            lines.append("end repeat")
            lines.append("end repeat")
        } else if let tty, !tty.isEmpty {
            let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
            let escaped = Self.escapeAppleScriptString(normalizedTTY)
            lines.append("set targetTTY to \"\(escaped)\"")
            lines.append("repeat with aWindow in windows")
            lines.append("repeat with aTab in tabs of aWindow")
            lines.append("repeat with aSession in sessions of aTab")
            lines.append("if (tty of aSession as text) is targetTTY then")
            lines.append("select aTab")
            lines.append("set current session of aTab to aSession")
            lines.append("set index of aWindow to 1")
            lines.append("return")
            lines.append("end if")
            lines.append("end repeat")
            lines.append("end repeat")
            lines.append("end repeat")
        }

        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func terminalAppSelectionScript(tty: String) -> String {
        var lines: [String] = []
        lines.append("tell application \"Terminal\"")
        lines.append("activate")

        let normalizedTTY = tty.replacingOccurrences(of: "/dev/", with: "")
        let escaped = Self.escapeAppleScriptString(normalizedTTY)
        lines.append("set targetTTY to \"\(escaped)\"")
        lines.append("repeat with aWindow in windows")
        lines.append("repeat with i from 1 to count of tabs of aWindow")
        lines.append("set aTab to tab i of aWindow")
        lines.append("if (tty of aTab) is targetTTY then")
        lines.append("set selected of aTab to true")
        lines.append("set index of aWindow to 1")
        lines.append("return")
        lines.append("end if")
        lines.append("end repeat")
        lines.append("end repeat")

        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - Application activation

    nonisolated private static func activateApplication(
        bundleIdentifier: String,
        pid: Int
    ) async -> Bool {
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
               !app.isTerminated {
                return Self.activateRunningApplication(app)
            }

            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated }) {
                return Self.activateRunningApplication(app)
            }

            return false
        }
    }

    @MainActor private static func activateRunningApplication(_ app: NSRunningApplication) -> Bool {
        if app.isHidden {
            app.unhide()
        }
        var options: NSApplication.ActivationOptions = [.activateAllWindows]
        return app.activate(options: options)
    }

    // MARK: - Bundle resolution

    nonisolated private static func resolveTerminalBundleIdentifier(
        terminalPid: Int,
        clientInfo: SessionClientInfo
    ) async -> String? {
        if let bundleIdentifier = clientInfo.terminalBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return await MainActor.run {
            NSRunningApplication(processIdentifier: pid_t(terminalPid))?.bundleIdentifier
        }
    }

    // MARK: - AppleScript execution

    nonisolated private static func runAppleScript(_ source: String) async -> Bool {
        let outcome = await MainActor.run { () -> (success: Bool, errorDescription: String?) in
            guard let script = NSAppleScript(source: source) else {
                return (false, "failed to create NSAppleScript")
            }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return (false, errorInfo.description)
            }
            return (true, nil)
        }

        if !outcome.success {
            await FocusDiagnosticsStore.shared.record(
                "TerminalSessionFocuser apple-script-error error=\(outcome.errorDescription ?? "unknown")"
            )
        }
        return outcome.success
    }

    nonisolated private static func runAppleScriptReturningString(_ source: String) async -> String? {
        await MainActor.run { () -> String? in
            guard let script = NSAppleScript(source: source) else { return nil }
            var errorInfo: NSDictionary?
            let output = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return nil
            }
            return output.stringValue
        }
    }

    // MARK: - String helpers

    nonisolated private static func escapeAppleScriptString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated private static func isUUID(_ candidate: String) -> Bool {
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: candidate.utf16.count)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let withoutFileURL: String
        if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
            withoutFileURL = url.path
        } else {
            withoutFileURL = trimmed
        }

        let standardized = URL(fileURLWithPath: withoutFileURL).standardizedFileURL.path
        let trimmedSlashes = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedSlashes.isEmpty ? "/" : "/" + trimmedSlashes
    }
}
