import Foundation
@testable import IslandApp
import Testing

@Test
func installerMergesTraeHooksWithoutDroppingExistingValues() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settingsURL = root.appending(path: ".claude/settings.json")
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
    {
      "env": {"EXISTING_VAR": "1"},
      "hooks": {
        "SessionStart": [{
          "hooks": [{"type": "command", "command": "/usr/bin/true"}],
          "matcher": "*"
        }]
      }
    }
    """
    try Data(existing.utf8).write(to: settingsURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installTRAEHookAssets()

    let data = try Data(contentsOf: settingsURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(json["env"] as? [String: Any])
    #expect(env["EXISTING_VAR"] as? String == "1")
    #expect(env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] as? String == "1")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
    #expect(sessionStart.count >= 2)
    let sessionStartCommands = sessionStart.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(sessionStartCommands.contains { $0.contains("/.trae-flow/bin/trae-flow-bridge --source claude") })

    let permissionRequest = try #require(hooks["PermissionRequest"] as? [[String: Any]])
    let installedHook = try #require(permissionRequest.last?["hooks"] as? [[String: Any]])
    #expect(installedHook.first?["timeout"] as? Int == 86_400)
    #expect(hooks["SessionEnd"] != nil)
    #expect(hooks["PreCompact"] != nil)
}

@Test
func installerCreatesLauncherUnderTraeFlowSupportDirectory() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let installer = HookInstaller(homeDirectory: root)
    try installer.installTRAEHookAssets()

    let launcherURL = root.appending(path: ".trae-flow/bin/trae-flow-bridge")
    #expect(FileManager.default.fileExists(atPath: launcherURL.path()))

    let launcher = try String(contentsOf: launcherURL, encoding: .utf8)
    #expect(launcher.contains("TraeFlowBridge"))
    #expect(launcher.contains("IslandBridge"))
}

@Test
func installerAcceptsJSONCSettingsFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settingsURL = root.appending(path: ".claude/settings.json")
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
    {
      // user-defined environment should be preserved
      "env": {
        "EXISTING_VAR": "1",
      },
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/bin/true",
              },
            ],
            "matcher": "*",
          },
        ],
      },
    }
    """
    try Data(existing.utf8).write(to: settingsURL)

    let installer = HookInstaller(homeDirectory: root)
    try installer.installTRAEHookAssets()

    let data = try Data(contentsOf: settingsURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let env = try #require(json["env"] as? [String: Any])
    #expect(env["EXISTING_VAR"] as? String == "1")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
    let commands = sessionStart.compactMap { hook in
        ((hook["hooks"] as? [[String: Any]])?.first?["command"] as? String)
    }
    #expect(commands.contains("/usr/bin/true"))
    #expect(commands.contains { $0.contains("/.trae-flow/bin/trae-flow-bridge --source claude") })
}
