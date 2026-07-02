import Foundation

/// codex 兼容的 pet.json 清单
/// 描述一个主题包的元数据，对应 `$HOME/.codex/pets/<pet-id>/pet.json`
struct MascotThemeManifest: Codable, Equatable, Sendable {
    /// 主题包唯一标识（对应 codex `<pet-id>`）
    let id: String
    /// 用户可读名称
    let displayName: String
    /// 描述文本（可选）
    let description: String?
    /// sprite sheet 相对主题包根目录的路径（可选，缺失或空白时走 `resolvedSpritesheetPath`）
    let spritesheetPath: String?
    /// 宠物种类（可选；codex 仅使用 `person` / `animal`，缺失或无法识别时视为 `.unknown`）
    let kind: MascotPetKind?
    /// trae-flow 扩展字段：单帧像素宽度（可选）
    let frameWidth: Int?
    /// trae-flow 扩展字段：单帧像素高度（可选）
    let frameHeight: Int?
    /// trae-flow 扩展字段：sprite sheet 总帧数（可选，仅作元数据）
    let frameCount: Int?
    /// trae-flow 扩展字段：动画播放帧率（可选）
    let fps: Int?
    /// trae-flow 扩展字段：各状态的行映射与帧数（可选）
    let animations: MascotThemeAnimations?

    /// 便捷构造：仅核心字段，扩展字段默认 nil
    init(
        id: String,
        displayName: String,
        description: String? = nil,
        spritesheetPath: String? = nil,
        kind: MascotPetKind? = nil,
        frameWidth: Int? = nil,
        frameHeight: Int? = nil,
        frameCount: Int? = nil,
        fps: Int? = nil,
        animations: MascotThemeAnimations? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.kind = kind
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.frameCount = frameCount
        self.fps = fps
        self.animations = animations
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case spritesheetPath
        case kind
        case frameWidth
        case frameHeight
        case frameCount
        case fps
        case animations
    }

    /// 自定义解码：`kind` 缺失或无法识别时安全降级为 `.unknown`，与 codex 约定一致
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        spritesheetPath = try container.decodeIfPresent(String.self, forKey: .spritesheetPath)
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) {
            kind = MascotPetKind(rawValue: rawKind) ?? .unknown
        } else {
            kind = .unknown
        }
        frameWidth = try container.decodeIfPresent(Int.self, forKey: .frameWidth)
        frameHeight = try container.decodeIfPresent(Int.self, forKey: .frameHeight)
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount)
        fps = try container.decodeIfPresent(Int.self, forKey: .fps)
        animations = try container.decodeIfPresent(MascotThemeAnimations.self, forKey: .animations)
    }
}

extension MascotThemeManifest {
    /// 解析后的 sprite sheet 相对路径
    /// 优先使用 manifest 显式声明的 `spritesheetPath`，空白或缺失时回退到 codex 默认 `spritesheet.webp`
    var resolvedSpritesheetPath: String {
        let declared = spritesheetPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return declared.isEmpty ? "spritesheet.webp" : declared
    }
}

/// 宠物种类（codex pet.json 中的 `kind` 字段）
enum MascotPetKind: String, Codable, Sendable {
    case person
    case animal
    case unknown
}

/// 主题包动画行映射（trae-flow 扩展字段）
/// 描述 codex 9 种状态各自对应的 sprite sheet 行号与帧数
struct MascotThemeAnimations: Codable, Equatable, Sendable {
    let idle: MascotThemeAnimationRow?
    let runRight: MascotThemeAnimationRow?
    let runLeft: MascotThemeAnimationRow?
    let waving: MascotThemeAnimationRow?
    let jumping: MascotThemeAnimationRow?
    let failed: MascotThemeAnimationRow?
    let waiting: MascotThemeAnimationRow?
    let running: MascotThemeAnimationRow?
    let review: MascotThemeAnimationRow?
    let dragging: MascotThemeAnimationRow?

    init(
        idle: MascotThemeAnimationRow? = nil,
        runRight: MascotThemeAnimationRow? = nil,
        runLeft: MascotThemeAnimationRow? = nil,
        waving: MascotThemeAnimationRow? = nil,
        jumping: MascotThemeAnimationRow? = nil,
        failed: MascotThemeAnimationRow? = nil,
        waiting: MascotThemeAnimationRow? = nil,
        running: MascotThemeAnimationRow? = nil,
        review: MascotThemeAnimationRow? = nil,
        dragging: MascotThemeAnimationRow? = nil
    ) {
        self.idle = idle
        self.runRight = runRight
        self.runLeft = runLeft
        self.waving = waving
        self.jumping = jumping
        self.failed = failed
        self.waiting = waiting
        self.running = running
        self.review = review
        self.dragging = dragging
    }
}

/// 单个动画行的描述（trae-flow 扩展字段）
struct MascotThemeAnimationRow: Codable, Equatable, Sendable {
    /// sprite sheet 中的行号（从 0 开始）
    let row: Int
    /// 该行包含的帧数
    let frames: Int
}
