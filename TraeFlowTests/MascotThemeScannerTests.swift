import XCTest
@testable import TRAE_FLOW

/// `MascotThemeScanner.scanDirectory(at:source:)` 纯函数单元测试
///
/// 直接测静态纯函数，避免单例 `MascotThemeScanner.shared` 污染。
/// 用临时目录构造多个 `pet.json` + spritesheet 文件，验证：
/// 1. 扫描能解析多个有效主题包
/// 2. 跳过 pet.json 缺失的目录
/// 3. 跳过 pet.json JSON 解析失败的目录
/// 4. 跳过 spritesheet 文件不存在的目录
/// 5. 同 ID 去重（后加载者覆盖）由 `rescan()` 负责，此处只验证单目录扫描的纯函数行为
final class MascotThemeScannerTests: XCTestCase {
    /// 临时根目录（每个测试创建独立子目录树）
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mascot-theme-scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempRoot = tmp
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // 1. 扫描能解析多个有效主题包
    func testScansMultipleValidThemes() throws {
        // pet A: frieren（person，显式 spritesheetPath）
        try writePet(
            id: "frieren",
            displayName: "Frieren",
            description: "精灵魔法使",
            spritesheetPath: "spritesheet.webp",
            kind: "person",
            spriteSheetName: "spritesheet.webp"
        )
        // pet B: ikun（animal，默认 spritesheetPath）
        try writePet(
            id: "ikun",
            displayName: "Ikun",
            description: nil,
            spritesheetPath: nil,
            kind: "animal",
            spriteSheetName: "spritesheet.webp"
        )

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .codex)

        XCTAssertEqual(result.themes.count, 2)
        XCTAssertEqual(result.skipped, 0)

        // 按 id 排序后断言（scanDirectory 返回顺序为遍历顺序，不保证排序）
        let byID = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0) })

        let frieren = try XCTUnwrap(byID["frieren"])
        XCTAssertEqual(frieren.displayName, "Frieren")
        XCTAssertEqual(frieren.description, "精灵魔法使")
        XCTAssertEqual(frieren.manifest.kind, .person)
        XCTAssertEqual(frieren.manifest.spritesheetPath, "spritesheet.webp")
        XCTAssertEqual(frieren.source, .codex)
        XCTAssertEqual(
            frieren.spritesheetURL.lastPathComponent,
            "spritesheet.webp"
        )

        let ikun = try XCTUnwrap(byID["ikun"])
        XCTAssertEqual(ikun.displayName, "Ikun")
        XCTAssertEqual(ikun.manifest.kind, .animal)
        // spritesheetPath 缺失时 resolvedSpritesheetPath 回退到 spritesheet.webp
        XCTAssertNil(ikun.manifest.spritesheetPath)
        XCTAssertEqual(ikun.manifest.resolvedSpritesheetPath, "spritesheet.webp")
    }

    // 2. 跳过 pet.json 缺失的目录
    func testSkipsDirectoryWithoutPetJSON() throws {
        // 有效主题包
        try writePet(
            id: "valid",
            displayName: "Valid",
            spritesheetPath: "spritesheet.webp",
            kind: "person",
            spriteSheetName: "spritesheet.webp"
        )
        // 缺 pet.json 的目录（仅放一个 spritesheet 文件）
        let noManifestDir = tempRoot.appendingPathComponent("no-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: noManifestDir, withIntermediateDirectories: true)
        try Data("fake-image".utf8).write(
            to: noManifestDir.appendingPathComponent("spritesheet.webp")
        )

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .codex)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "valid")
        XCTAssertEqual(result.skipped, 1)
    }

    // 3. 跳过 pet.json JSON 解析失败的目录
    func testSkipsDirectoryWithInvalidPetJSON() throws {
        try writePet(
            id: "valid",
            displayName: "Valid",
            spritesheetPath: "spritesheet.webp",
            kind: "person",
            spriteSheetName: "spritesheet.webp"
        )
        // 写入损坏的 pet.json（非合法 JSON）
        let brokenDir = tempRoot.appendingPathComponent("broken-json", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data("not-a-json".utf8).write(to: brokenDir.appendingPathComponent("pet.json"))
        try Data("fake-image".utf8).write(
            to: brokenDir.appendingPathComponent("spritesheet.webp")
        )

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .codex)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "valid")
        XCTAssertEqual(result.skipped, 1)
    }

    // 4. 跳过 spritesheet 文件不存在的目录
    func testSkipsDirectoryWithMissingSpritesheet() throws {
        try writePet(
            id: "valid",
            displayName: "Valid",
            spritesheetPath: "spritesheet.webp",
            kind: "person",
            spriteSheetName: "spritesheet.webp"
        )
        // pet.json 存在但声明了不存在的 spritesheetPath
        let missingSpriteDir = tempRoot.appendingPathComponent("missing-sprite", isDirectory: true)
        try FileManager.default.createDirectory(at: missingSpriteDir, withIntermediateDirectories: true)
        let json = """
        {
            "id": "missing-sprite",
            "displayName": "Missing Sprite",
            "spritesheetPath": "does-not-exist.webp",
            "kind": "person"
        }
        """
        try Data(json.utf8).write(to: missingSpriteDir.appendingPathComponent("pet.json"))

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .codex)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "valid")
        XCTAssertEqual(result.skipped, 1)
    }

    // 5. 跳过非目录文件（如 .DS_Store）—— 注意 enumerator 默认 skipsHiddenFiles 已过滤 .DS_Store，
    //    此处用一个非隐藏的普通文件验证非目录条目被跳过并计数
    func testSkipsNonDirectoryEntries() throws {
        try writePet(
            id: "valid",
            displayName: "Valid",
            spritesheetPath: "spritesheet.webp",
            kind: "person",
            spriteSheetName: "spritesheet.webp"
        )
        // 在根目录放一个普通文件（非隐藏，非目录）
        try Data("stray-file".utf8).write(to: tempRoot.appendingPathComponent("stray-file.txt"))

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .user)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.id, "valid")
        XCTAssertEqual(result.themes.first?.source, .user)
        XCTAssertEqual(result.skipped, 1)
    }

    // 6. 根目录不存在时返回空结果且不计数
    func testReturnsEmptyWhenRootDirectoryMissing() {
        let nonexistent = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = MascotThemeScanner.scanDirectory(at: nonexistent, source: .codex)

        XCTAssertEqual(result.themes.count, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    // 7. trae-flow 扩展字段被正确解析（frameWidth/frameHeight/fps/animations）
    func testParsesTraeFlowExtensionFields() throws {
        let petDir = tempRoot.appendingPathComponent("full-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        let json = """
        {
            "id": "full",
            "displayName": "Full",
            "description": "扩展字段示例",
            "spritesheetPath": "spritesheet.webp",
            "kind": "person",
            "frameWidth": 64,
            "frameHeight": 64,
            "frameCount": 96,
            "fps": 8,
            "animations": {
                "idle": {"row": 0, "frames": 24},
                "runRight": {"row": 1, "frames": 24},
                "failed": {"row": 2, "frames": 24},
                "dragging": {"row": 3, "frames": 24}
            }
        }
        """
        try Data(json.utf8).write(to: petDir.appendingPathComponent("pet.json"))
        try Data("fake-image".utf8).write(to: petDir.appendingPathComponent("spritesheet.webp"))

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .user)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.skipped, 0)

        let theme = try XCTUnwrap(result.themes.first)
        XCTAssertEqual(theme.id, "full")
        XCTAssertEqual(theme.manifest.frameWidth, 64)
        XCTAssertEqual(theme.manifest.frameHeight, 64)
        XCTAssertEqual(theme.manifest.frameCount, 96)
        XCTAssertEqual(theme.manifest.fps, 8)

        let animations = try XCTUnwrap(theme.manifest.animations)
        XCTAssertEqual(animations.idle, MascotThemeAnimationRow(row: 0, frames: 24))
        XCTAssertEqual(animations.runRight, MascotThemeAnimationRow(row: 1, frames: 24))
        XCTAssertEqual(animations.failed, MascotThemeAnimationRow(row: 2, frames: 24))
        XCTAssertEqual(animations.dragging, MascotThemeAnimationRow(row: 3, frames: 24))

        // frameLayout 从 manifest 扩展字段构建
        XCTAssertEqual(theme.frameLayout.frameWidth, 64)
        XCTAssertEqual(theme.frameLayout.fps, 8)
        XCTAssertEqual(theme.frameLayout.row(for: .idle), 0)
        XCTAssertEqual(theme.frameLayout.row(for: .runRight), 1)
    }

    // 8. 缺失 kind 字段时降级为 .unknown，主题包仍可加载
    func testMissingKindDefaultsToUnknown() throws {
        let petDir = tempRoot.appendingPathComponent("no-kind", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        let json = """
        {
            "id": "no-kind",
            "displayName": "No Kind Pet"
        }
        """
        try Data(json.utf8).write(to: petDir.appendingPathComponent("pet.json"))
        // 缺失 spritesheetPath 时回退到 spritesheet.webp，需要文件存在
        try Data("fake-image".utf8).write(to: petDir.appendingPathComponent("spritesheet.webp"))

        let result = MascotThemeScanner.scanDirectory(at: tempRoot, source: .codex)

        XCTAssertEqual(result.themes.count, 1)
        XCTAssertEqual(result.themes.first?.manifest.kind, .unknown)
        XCTAssertEqual(result.themes.first?.manifest.resolvedSpritesheetPath, "spritesheet.webp")
    }

    // MARK: - Helpers

    /// 在 tempRoot 下创建一个 `<id>/` 子目录，写入 pet.json 与 spritesheet 文件
    private func writePet(
        id: String,
        displayName: String,
        description: String? = nil,
        spritesheetPath: String? = nil,
        kind: String? = nil,
        spriteSheetName: String
    ) throws {
        let petDir = tempRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)

        var jsonDict: [String: Any] = [
            "id": id,
            "displayName": displayName
        ]
        if let description { jsonDict["description"] = description }
        if let spritesheetPath { jsonDict["spritesheetPath"] = spritesheetPath }
        if let kind { jsonDict["kind"] = kind }

        let data = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
        try data.write(to: petDir.appendingPathComponent("pet.json"))

        // 写入一个占位 spritesheet 文件（内容无关，仅用于文件存在性校验）
        try Data("fake-sprite-data".utf8).write(
            to: petDir.appendingPathComponent(spriteSheetName)
        )
    }
}
