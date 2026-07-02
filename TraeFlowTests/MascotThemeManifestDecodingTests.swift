import XCTest
@testable import TRAE_FLOW

final class MascotThemeManifestDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> MascotThemeManifest {
        let data = json.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(MascotThemeManifest.self, from: data)
    }

    // 1. 标准 codex pet.json（frieren 格式）
    func testDecodesStandardCodexPetJSON() throws {
        let json = """
        {
            "id": "frieren",
            "displayName": "Frieren",
            "description": "Uma pequena maga elfa inspirada na Frieren, calma e curiosa.",
            "spritesheetPath": "spritesheet.webp",
            "kind": "person"
        }
        """
        let manifest = try decode(json)

        XCTAssertEqual(manifest.id, "frieren")
        XCTAssertEqual(manifest.displayName, "Frieren")
        XCTAssertEqual(manifest.description, "Uma pequena maga elfa inspirada na Frieren, calma e curiosa.")
        XCTAssertEqual(manifest.spritesheetPath, "spritesheet.webp")
        XCTAssertEqual(manifest.kind, .person)
        // 扩展字段缺失时为 nil
        XCTAssertNil(manifest.frameWidth)
        XCTAssertNil(manifest.frameHeight)
        XCTAssertNil(manifest.frameCount)
        XCTAssertNil(manifest.fps)
        XCTAssertNil(manifest.animations)
        // resolvedSpritesheetPath 优先用显式声明
        XCTAssertEqual(manifest.resolvedSpritesheetPath, "spritesheet.webp")
    }

    // 2. 缺失 kind 字段
    func testMissingKindDefaultsToUnknown() throws {
        let json = """
        {
            "id": "noid",
            "displayName": "No Kind Pet"
        }
        """
        let manifest = try decode(json)

        XCTAssertEqual(manifest.id, "noid")
        XCTAssertEqual(manifest.displayName, "No Kind Pet")
        // 缺失 kind 时视为 .unknown
        XCTAssertEqual(manifest.kind, .unknown)
        // 缺失 description 时为 nil
        XCTAssertNil(manifest.description)
        // 缺失 spritesheetPath 时回退到默认
        XCTAssertEqual(manifest.resolvedSpritesheetPath, "spritesheet.webp")
    }

    // 3. 缺失 spritesheetPath 字段（验证 resolvedSpritesheetPath 默认值）
    func testMissingSpritesheetPathResolvesToDefault() throws {
        let json = """
        {
            "id": "nopath",
            "displayName": "No Path Pet",
            "kind": "animal"
        }
        """
        let manifest = try decode(json)

        XCTAssertNil(manifest.spritesheetPath)
        // 缺失 spritesheetPath 时回退到 codex 默认 spritesheet.webp
        XCTAssertEqual(manifest.resolvedSpritesheetPath, "spritesheet.webp")
        XCTAssertEqual(manifest.kind, .animal)
    }

    // 4. 带 trae-flow 扩展字段（frameWidth/frameHeight/animations）
    func testDecodesTraeFlowExtensionFields() throws {
        let json = """
        {
            "id": "ikun",
            "displayName": "Ikun",
            "description": "扩展字段示例",
            "spritesheetPath": "spritesheet.webp",
            "kind": "person",
            "frameWidth": 48,
            "frameHeight": 48,
            "frameCount": 1248,
            "fps": 12,
            "animations": {
                "idle": {"row": 0, "frames": 32},
                "running": {"row": 1, "frames": 32},
                "waiting": {"row": 2, "frames": 32},
                "dragging": {"row": 3, "frames": 32}
            }
        }
        """
        let manifest = try decode(json)

        XCTAssertEqual(manifest.frameWidth, 48)
        XCTAssertEqual(manifest.frameHeight, 48)
        XCTAssertEqual(manifest.frameCount, 1248)
        XCTAssertEqual(manifest.fps, 12)

        let animations = try XCTUnwrap(manifest.animations)
        XCTAssertEqual(animations.idle, MascotThemeAnimationRow(row: 0, frames: 32))
        XCTAssertEqual(animations.running, MascotThemeAnimationRow(row: 1, frames: 32))
        XCTAssertEqual(animations.waiting, MascotThemeAnimationRow(row: 2, frames: 32))
        XCTAssertEqual(animations.dragging, MascotThemeAnimationRow(row: 3, frames: 32))
    }

    // 额外：无法识别的 kind 值也安全降级为 .unknown
    func testUnrecognizedKindValueDefaultsToUnknown() throws {
        let json = """
        {
            "id": "weird",
            "displayName": "Weird Pet",
            "kind": "dragon"
        }
        """
        let manifest = try decode(json)
        XCTAssertEqual(manifest.kind, .unknown)
    }

    // 额外：空白 spritesheetPath 也走默认值
    func testBlankSpritesheetPathResolvesToDefault() throws {
        let json = """
        {
            "id": "blank",
            "displayName": "Blank Path",
            "spritesheetPath": "   "
        }
        """
        let manifest = try decode(json)
        XCTAssertEqual(manifest.resolvedSpritesheetPath, "spritesheet.webp")
    }
}
