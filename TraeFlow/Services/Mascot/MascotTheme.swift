import Foundation

/// 主题包来源
enum MascotThemeSource: String, Sendable, Equatable {
    /// App Bundle 内置
    case builtin
    /// `$HOME/.codex/pets/`
    case codex
    /// `$HOME/.traeflow/pets/` 或用户自选
    case user
}

/// 完整主题包：manifest + 根目录 URL + 来源
struct MascotTheme: Identifiable, Equatable, Sendable {
    /// 主题包清单
    let manifest: MascotThemeManifest
    /// 主题包根目录（包含 pet.json 与 sprite sheet）
    let rootURL: URL
    /// 主题包来源
    let source: MascotThemeSource

    var id: String { manifest.id }
    var displayName: String { manifest.displayName }
    var description: String { manifest.description ?? "" }
    /// sprite sheet 文件 URL（根目录 + resolvedSpritesheetPath）
    var spritesheetURL: URL {
        rootURL.appendingPathComponent(manifest.resolvedSpritesheetPath)
    }
    /// 帧布局（基于 manifest 扩展字段或默认约定）
    var frameLayout: MascotFrameLayout {
        MascotFrameLayout.from(manifest: manifest)
    }
}
