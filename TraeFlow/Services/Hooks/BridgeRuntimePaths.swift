import Foundation

enum BridgeRuntimePaths {
    nonisolated static let appGroupIdentifier = "group.ai.traeflow.app"
    nonisolated static let legacySocketPath = "/tmp/trae-flow.sock"
    nonisolated static let bridgeConfigEnvironmentKey = "TRAE_FLOW_BRIDGE_CONFIG"
    nonisolated static let socketPathEnvironmentKey = "TRAE_FLOW_SOCKET_PATH"

    /// Spec: 应用支持目录 `~/Library/Application Support/trae-flow/`
    nonisolated private static let appSupportRelativePath = "Library/Application Support/trae-flow"
    /// Spec: 本地 socket `/tmp/trae-flow.sock`
    /// 与 TRAEFLOW 项目对齐：使用 `/tmp/` 下的固定路径，
    /// 避免 `~/Library/Application Support/` 路径在沙盒/权限场景下不可访问。
    nonisolated static let socketRelativePath = "tmp/trae-flow.sock"
    /// Spec: Hook 安装目录 `~/.config/trae-flow/hooks/`
    nonisolated static let hookInstallDirectoryRelativePath = ".config/trae-flow/hooks"
    /// Spec: 日志目录 `~/Library/Logs/trae-flow/`
    nonisolated static let logsRelativePath = "Library/Logs/trae-flow"
    /// Spec: 缓存目录 `~/Library/Caches/trae-flow/`
    nonisolated static let cachesRelativePath = "Library/Caches/trae-flow"
    /// Spec: 自定义区域目录根 `~/Library/Application Support/trae-flow/custom-areas/`
    nonisolated static let customAreasRelativePath = "Library/Application Support/trae-flow/custom-areas"
    /// Spec: 功能图标图片目录 `~/Library/Application Support/trae-flow/icons/`
    nonisolated static let iconsRelativePath = "Library/Application Support/trae-flow/icons"

    nonisolated static var socketPath: String {
        legacySocketPath
    }

    nonisolated static var runtimeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(appSupportRelativePath)
            .appendingPathComponent("bridge-config.json")
    }

    nonisolated static var runtimeDirectoryURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(appSupportRelativePath, isDirectory: true)
    }

    /// Spec: 自定义区域目录根
    nonisolated static var customAreasDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(customAreasRelativePath, isDirectory: true)
    }

    /// Spec: 功能图标图片目录 `~/Library/Application Support/trae-flow/icons/`
    nonisolated static var iconsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(iconsRelativePath, isDirectory: true)
    }

    /// Spec: 内置默认目录 `~/Library/Application Support/trae-flow/custom-areas/{weather,cpu,stock,pomodoro}/`
    nonisolated static var builtInCustomAreasURLs: [URL] {
        ["weather", "cpu", "stock", "pomodoro"].map {
            customAreasDirectoryURL.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Spec: 日志目录 `~/Library/Logs/trae-flow/`
    nonisolated static var logsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(logsRelativePath, isDirectory: true)
    }

    /// Spec: 缓存目录 `~/Library/Caches/trae-flow/`
    nonisolated static var cachesDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(cachesRelativePath, isDirectory: true)
    }

    /// Spec: Hook 安装目录 `~/.config/trae-flow/hooks/`
    nonisolated static var hookInstallDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(hookInstallDirectoryRelativePath, isDirectory: true)
    }

    nonisolated static func prepareRuntimeDirectory() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for relative in [appSupportRelativePath, logsRelativePath, cachesRelativePath, customAreasRelativePath, iconsRelativePath] {
            try? fm.createDirectory(
                at: home.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    nonisolated static var launcherEnvironment: [String: String] {
        [
            socketPathEnvironmentKey: socketPath,
            bridgeConfigEnvironmentKey: runtimeConfigURL.path
        ]
    }
}
