import Foundation
import Combine

// 非 TRAE 客户端已移除，SessionProvider 仅保留 .claude（与真实代码一致）
enum SessionProvider {
    case claude
}

enum AnimationLevel {
    case full
    case reduced
    case staticFrames
}

struct EnergyPolicy {
    var animationLevel: AnimationLevel = .full
}

final class EnergyGovernor: ObservableObject {
    static let shared = EnergyGovernor()

    @Published var policy = EnergyPolicy()
}

final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @Published var idleAutoRoutePromptsToTerminalActive = false
}

// 真实 SessionClientBrand 仅保留 .trae / .neutral（与 ClientProfile.swift 一致）
enum SessionClientBrand {
    case trae
    case neutral
}

struct SessionClientProfile {
    let id: String
}

struct SessionClientInfo {
    var brand: SessionClientBrand = .neutral

    func resolvedProfile(for provider: SessionProvider) -> SessionClientProfile? {
        nil
    }
}

enum SessionPhase {
    case idle
    case ended
    case waitingForApproval
    case waitingForInput
    case processing
    case compacting

    var isActive: Bool {
        switch self {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return true
        case .idle, .ended:
            return false
        }
    }
}

struct SessionState {
    var needsManualAttention = false
    var phase: SessionPhase = .idle
    var clientInfo: SessionClientInfo = .init()
    var provider: SessionProvider = .claude
}

// 导出脚本用的 MascotThemeScanner stub
// 同步扫描 codex/user pets 目录，不依赖 FSEvents 与沙盒书签（导出脚本运行在非沙盒环境）
@MainActor
final class MascotThemeScanner: ObservableObject {
    static let shared = MascotThemeScanner()

    /// 已扫描到的主题包（内置 + codex + user，按 ID 去重后排序）
    private(set) var themes: [MascotTheme] = []

    private init() {
        var merged: [String: MascotTheme] = [:]

        // 1. 内置主题包
        for theme in BuiltInMascotThemes.allThemes {
            merged[theme.id] = theme
        }

        // 2. codex 已安装（$HOME/.codex/pets/）
        let codexPetsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
        let codexResult = Self.scanDirectory(at: codexPetsDir, source: .codex)
        for theme in codexResult.themes { merged[theme.id] = theme }

        // 3. 用户自装（$HOME/.traeflow/pets/）
        let userPetsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".traeflow", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
        let userResult = Self.scanDirectory(at: userPetsDir, source: .user)
        for theme in userResult.themes { merged[theme.id] = theme }

        themes = merged.values.sorted { $0.manifest.id < $1.manifest.id }
    }

    /// 按 ID 查找主题包
    func theme(forID id: String) -> MascotTheme? {
        themes.first { $0.id == id }
    }

    /// 扫描单个根目录下的所有一级子目录（与真实 Scanner 逻辑一致）
    nonisolated static func scanDirectory(
        at rootURL: URL,
        source: MascotThemeSource
    ) -> (themes: [MascotTheme], skipped: Int) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return (themes: [], skipped: 0)
        }

        var themeEntries: [MascotTheme] = []
        var skipped = 0

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (themes: [], skipped: 0)
        }

        var visited: Set<String> = []
        let rootPath = rootURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            // 只处理 rootURL 的直接子目录
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            guard parentPath == rootPath else { continue }

            let standardizedPath = url.standardizedFileURL.path
            guard !visited.contains(standardizedPath) else { continue }
            visited.insert(standardizedPath)

            // 跳过非目录文件（.DS_Store 等）
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else {
                skipped += 1
                continue
            }

            // 读 pet.json
            let manifestURL = url.appendingPathComponent("pet.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL) else {
                skipped += 1
                continue
            }

            // 解析 manifest
            let manifest: MascotThemeManifest
            do {
                manifest = try JSONDecoder().decode(MascotThemeManifest.self, from: data)
            } catch {
                skipped += 1
                continue
            }

            // 校验 spritesheet 文件存在
            let theme = MascotTheme(manifest: manifest, rootURL: url, source: source)
            guard fileManager.fileExists(atPath: theme.spritesheetURL.path) else {
                skipped += 1
                continue
            }

            themeEntries.append(theme)
        }

        return (themes: themeEntries, skipped: skipped)
    }
}

enum AppLocalization {
    static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, arguments: arguments)
    }
}
