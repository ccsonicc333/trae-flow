import AppKit
import Foundation

/// 清除所有缓存并恢复到首次安装状态。
///
/// 该流程会：
/// 1. 卸载所有 Hook 安装（managed + custom）
/// 2. 清空当前 App Bundle 的 UserDefaults 持久域
/// 3. 删除 App 自有的所有文件目录（Application Support、Caches、Logs、Bridge、调试日志、Sparkle 缓存、用户同步宠物主题包）
/// 4. 清理 Sparkle 运行时键
/// 5. 退出应用，等待用户手动重启
///
/// 不删除：
/// - `~/.codex/pets/`（codex CLI 外部资产）
/// - `~/.claude/settings.json`（由 `HookInstaller.uninstall()` 清理而非直接删除）
/// - 崩溃报告（由 macOS 管理）
@MainActor
enum AppCacheResetManager {
    /// 执行完整的缓存清除与首装状态恢复。
    /// 调用方负责在调用前后展示 UI 提示，并在调用后让用户手动重启应用。
    static func performFullReset() {
        // 1. 卸载所有 Hook 安装（managed + custom）
        HookInstaller.uninstall()
        for installation in HookInstaller.customInstallations() {
            HookInstaller.uninstallCustom(id: installation.id)
        }

        // 2. 清空当前 App Bundle 的 UserDefaults 持久域
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.traeflow.app"
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // 3. 清理 Sparkle 运行时键（removePersistentDomain 通常会一并清理，
        //    这里显式再清一次以应对 Sparkle 在 framework 域写入的情况）
        for key in sparkleRuntimeKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()

        // 4. 删除 App 自有的所有文件目录
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for url in directoriesToRemove(bundleID: bundleID, home: home) {
            try? fm.removeItem(at: url)
        }

        // 5. 删除 Unix socket
        try? fm.removeItem(atPath: BridgeRuntimePaths.socketPath)
    }

    /// 退出应用。调用方应先弹出提示让用户确认。
    static func terminateApp(afterDelay seconds: TimeInterval = 0.4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.terminate(nil)
        }
    }

    private static let sparkleRuntimeKeys: [String] = [
        "SULastCheckTime",
        "SUSkippedVersion",
        "SUUpdateGroupIdentifier",
        "SUFeedURL",
        "SUAutomaticallyUpdate",
        "SUEnableAutomaticChecks",
    ]

    private static func directoriesToRemove(bundleID: String, home: URL) -> [URL] {
        var paths: [URL] = [
            // BridgeRuntimePaths 管理的运行时目录
            BridgeRuntimePaths.runtimeDirectoryURL,
            BridgeRuntimePaths.customAreasDirectoryURL,
            BridgeRuntimePaths.iconsDirectoryURL,
            BridgeRuntimePaths.logsDirectoryURL,
            BridgeRuntimePaths.cachesDirectoryURL,
            BridgeRuntimePaths.hookInstallDirectoryURL,
            // SessionAssociationStore（CamelCase 目录，区别于 kebab-case 的 tre-flow/）
            home.appendingPathComponent("Library/Application Support/TraeFlow", isDirectory: true),
            // HookInstaller 管理的 Bridge 二进制支持目录 ~/.trae-flow/
            home.appendingPathComponent(".trae-flow", isDirectory: true),
            // 调试日志 ~/.trae-flow-debug/
            home.appendingPathComponent(".trae-flow-debug", isDirectory: true),
            // 用户同步/安装的宠物主题包目录 ~/.traeflow/pets/（由 MascotThemeScanner 维护）
            home.appendingPathComponent(".traeflow", isDirectory: true),
        ]

        // Sparkle 下载缓存 ~/Library/Caches/<bundleID>/Sparkle/ 以及外层 bundleID 目录
        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        paths.append(cachesRoot.appendingPathComponent(bundleID, isDirectory: true))

        return paths
    }
}
