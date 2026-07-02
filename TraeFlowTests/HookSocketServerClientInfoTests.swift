import XCTest
@testable import TRAE_FLOW

final class HookSocketServerClientInfoTests: XCTestCase {
    func testTerminalHostBundlePrefersStandaloneTerminalOverIDEHint() {
        XCTAssertEqual(
            HookSocketServer.resolvedTerminalHostBundleIdentifier(
                terminalBundleID: "com.googlecode.iterm2",
                ideBundleID: "com.trae.app"
            ),
            "com.googlecode.iterm2"
        )
    }

    func testTerminalHostBundleKeepsIDEWhenTerminalIsIDEHost() {
        XCTAssertEqual(
            HookSocketServer.resolvedTerminalHostBundleIdentifier(
                terminalBundleID: "com.trae.app",
                ideBundleID: "com.trae.app"
            ),
            "com.trae.app"
        )
    }
}
