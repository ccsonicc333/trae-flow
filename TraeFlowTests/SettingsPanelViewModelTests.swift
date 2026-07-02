import XCTest
@testable import TRAE_FLOW

@MainActor
private final class AccessibilityStatusProbe {
    var isTrusted = false
    var promptValues: [Bool] = []

    func currentStatus(prompt: Bool) -> Bool {
        promptValues.append(prompt)
        return isTrusted
    }
}

final class SettingsPanelViewModelTests: XCTestCase {
    func testRefreshAccessibilityStatusUsesLatestProviderValue() async {
        await MainActor.run {
            let probe = AccessibilityStatusProbe()
            let viewModel = SettingsPanelViewModel(
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: {}
            )

            viewModel.refreshAccessibilityStatus()
            XCTAssertFalse(viewModel.accessibilityEnabled)

            probe.isTrusted = true
            viewModel.refreshAccessibilityStatus()

            XCTAssertTrue(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [false, false])
        }
    }

    func testOpenAccessibilitySettingsPromptsBeforeOpeningSystemSettings() async {
        await MainActor.run {
            let probe = AccessibilityStatusProbe()
            var openSettingsCount = 0
            let viewModel = SettingsPanelViewModel(
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: { openSettingsCount += 1 }
            )

            viewModel.openAccessibilitySettings()

            XCTAssertFalse(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [true])
            XCTAssertEqual(openSettingsCount, 1)
        }
    }

    func testOpenAccessibilitySettingsDoesNotOpenSystemSettingsWhenPromptRefreshFindsAccess() async {
        await MainActor.run {
            let probe = AccessibilityStatusProbe()
            probe.isTrusted = true
            var openSettingsCount = 0
            let viewModel = SettingsPanelViewModel(
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: { openSettingsCount += 1 }
            )

            viewModel.openAccessibilitySettings()

            XCTAssertTrue(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [true])
            XCTAssertEqual(openSettingsCount, 0)
        }
    }
}
