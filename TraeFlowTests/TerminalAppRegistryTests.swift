import XCTest
@testable import TRAE_FLOW

final class TerminalAppRegistryTests: XCTestCase {
    func testInfersITermBundleIdentifierFromHelperCommand() {
        XCTAssertEqual(
            TerminalAppRegistry.inferredBundleIdentifier(
                forCommand: "/Users/example/Library/Application Support/iTerm2/iTermServer-3.6.9 socket"
            ),
            "com.googlecode.iterm2"
        )
    }
}
