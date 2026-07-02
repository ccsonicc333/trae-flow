import XCTest
@testable import TRAE_FLOW

final class HookInstallerTemporarySettingsTests: XCTestCase {
    func testCreateTemporarySettingsFileIncludesTraeHookEvents() throws {
        let settingsURL = try XCTUnwrap(HookInstaller.createTemporarySettingsFile(for: "trae"))
        defer { HookInstaller.removeTemporarySettingsFile(at: settingsURL) }

        let data = try Data(contentsOf: settingsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["Stop"])
    }
}
