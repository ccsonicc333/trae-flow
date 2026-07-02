import XCTest
@testable import TRAE_FLOW

final class TerminalAutomationPermissionCoordinatorTests: XCTestCase {
    func testScriptableTerminalBundleIdentifierIncludesTerminalApp() {
        let clientInfo = SessionClientInfo(
            kind: .trae,
            terminalBundleIdentifier: "com.apple.Terminal",
            terminalProgram: "Apple_Terminal"
        )

        XCTAssertEqual(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: clientInfo),
            "com.apple.Terminal"
        )
    }

    func testScriptableTerminalBundleIdentifierRequiresTrackedITermSession() {
        let missingIdentifiers = SessionClientInfo(
            kind: .trae,
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app"
        )
        let trackedSession = SessionClientInfo(
            kind: .trae,
            terminalBundleIdentifier: "com.googlecode.iterm2",
            terminalProgram: "iTerm.app",
            terminalSessionIdentifier: "iterm-session-1"
        )

        XCTAssertNil(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: missingIdentifiers)
        )
        XCTAssertEqual(
            TerminalAutomationPermissionCoordinator.scriptableTerminalBundleIdentifier(for: trackedSession),
            "com.googlecode.iterm2"
        )
    }

    func testAutomationPermissionRequirementMatchesScriptedTerminalBundles() {
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.apple.Terminal"
            )
        )
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.googlecode.iterm2"
            )
        )
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.mitchellh.ghostty"
            )
        )
        XCTAssertTrue(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.cmuxterm.app"
            )
        )
        XCTAssertFalse(
            TerminalAutomationPermissionCoordinator.isAutomationPermissionRequired(
                bundleIdentifier: "com.trae.app"
            )
        )
    }
}
