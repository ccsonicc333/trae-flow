import Foundation

/// 内置主题包定义
///
/// 内置主题包从 App Bundle 的 `Resources/BuiltInPets/` 目录加载，
/// 每个主题包子目录包含 `pet.json` 与 `spritesheet` 文件。
/// `traeflow` 主题包作为默认选中宠物，显示名为 "TRAE FLOW"。
enum BuiltInMascotThemes {
    /// 默认选中的内置主题包 ID（须与 `BuiltInPets/traeflow/pet.json` 中的 `id` 一致）
    static let defaultThemeID = "traeflow"

    /// 所有内置主题包（从 Bundle 加载，默认主题包排第一位，其余按目录名排序）
    static let allThemes: [MascotTheme] = loadBuiltInThemes()

    /// 默认主题包（traeflow / TRAE FLOW）
    static let defaultTheme: MascotTheme? = allThemes.first { $0.id == defaultThemeID }

    // MARK: - Private

    /// 从 App Bundle 的 `Resources/BuiltInPets/` 加载内置主题包
    private static func loadBuiltInThemes() -> [MascotTheme] {
        guard let bundleRoot = Bundle.main.resourceURL?
            .appendingPathComponent("BuiltInPets", isDirectory: true) else {
            return []
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundleRoot.path) else { return [] }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: bundleRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var themes: [MascotTheme] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            let manifestURL = entry.appendingPathComponent("pet.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL) else { continue }

            guard var manifest = try? JSONDecoder().decode(MascotThemeManifest.self, from: data) else {
                continue
            }

            // 默认主题包作为默认宠物：改名为 TRAE FLOW，去掉描述
            if manifest.id == defaultThemeID {
                manifest = MascotThemeManifest(
                    id: manifest.id,
                    displayName: "TRAE FLOW",
                    description: nil,
                    spritesheetPath: manifest.spritesheetPath,
                    kind: manifest.kind,
                    frameWidth: manifest.frameWidth,
                    frameHeight: manifest.frameHeight,
                    frameCount: manifest.frameCount,
                    fps: manifest.fps,
                    animations: manifest.animations
                )
            }

            // 校验 spritesheet 文件存在
            let theme = MascotTheme(
                manifest: manifest,
                rootURL: entry,
                source: .builtin
            )
            guard fileManager.fileExists(atPath: theme.spritesheetURL.path) else { continue }

            themes.append(theme)
        }

        return themes.sorted { lhs, rhs in
            if lhs.manifest.id == defaultThemeID { return true }
            if rhs.manifest.id == defaultThemeID { return false }
            return lhs.manifest.id < rhs.manifest.id
        }
    }
}
