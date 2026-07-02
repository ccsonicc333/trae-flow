import AppKit
import Foundation
import os.log

/// Spec: 实现"跳回对应变体 IDE"的窗口激活与会话定位逻辑
/// Spec: 实现"在 Trae 中打开"按钮，使用指定变体以该目录为工作区启动 Trae
///
/// Trae 专用启动器：通过 Bundle ID 激活对应变体的 IDE 窗口，
/// 或通过 URL Scheme 以指定目录为工作区打开新会话。
enum TraeSessionLauncher {
    nonisolated private static let logger = Logger(subsystem: "ai.traeflow.app", category: "TraeSessionLauncher")

    /// Spec: 跳回对应变体 IDE — 激活已运行的应用窗口
    @discardableResult
    static func activate(_ variant: TraeVariant) -> Bool {
        let bundleID = variant.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if let app = apps.first(where: { $0.isActive == false }) ?? apps.first {
            app.activate(options: [.activateAllWindows])
            logger.info("Activated \(variant.displayName) via running app")
            return true
        }

        // 未运行则通过 launchApplication 启动
        let success = NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
        if success {
            logger.info("Launched \(variant.displayName) via bundle ID")
        } else {
            logger.error("Failed to activate/launch \(variant.displayName)")
        }
        return success
    }

    /// Spec: 在 Trae 中打开 — 以指定目录为工作区启动对应变体
    @discardableResult
    static func openWorkspace(_ variant: TraeVariant, directoryURL: URL) -> Bool {
        // 通过 URL Scheme 以指定目录为工作区打开 IDE（与 SessionClientInfo.appLaunchURL 格式一致）
        let scheme = variant.urlScheme
        let encodedPath = directoryURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directoryURL.path
        let urlString = "\(scheme)://file\(encodedPath)"

        if let url = URL(string: urlString) {
            if NSWorkspace.shared.open(url) {
                logger.info("Opened workspace in \(variant.displayName) via URL scheme: \(urlString)")
                return true
            }
        }

        // 回退：仅激活应用
        let bundleID = variant.bundleIdentifier
        let success = NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
        if success {
            logger.info("Launched \(variant.displayName) as fallback for workspace open")
        }
        return success
    }

    /// Spec: 跳回对应变体 IDE 并定位到相关会话
    @discardableResult
    static func activateAndFocusSession(_ variant: TraeVariant, sessionID: String? = nil) -> Bool {
        // 先激活应用窗口
        let activated = activate(variant)
        guard activated else { return false }

        // 如果有 sessionID，尝试通过 URL Scheme 定位到会话
        if let sessionID {
            let scheme = variant.urlScheme
            let urlString = "\(scheme)://session?id=\(sessionID)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }

        return true
    }
}
