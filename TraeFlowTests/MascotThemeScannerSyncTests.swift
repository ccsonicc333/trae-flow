import XCTest
@testable import TRAE_FLOW

/// `MascotThemeScanner.performSyncFromCodex` 纯函数测试
///
/// 直接测静态纯函数，避免单例 `MascotThemeScanner.shared` 污染。
/// 用临时目录构造 codex 源与 trae-flow 目标，验证：
/// 1. codexURL 为 nil 时返回空结果（沙盒未授权场景）
/// 2. codex 目录不存在时返回空结果
/// 3. 目标已存在时跳过以保留用户自定义
/// 4. 有效目录被复制，非目录文件被忽略且不计入 failed
final class MascotThemeScannerSyncTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mascot-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempRoot = tmp
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // 1. codexURL 为 nil 时返回空结果
    func testSyncReturnsEmptyWhenCodexURLIsNil() async {
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let result = await MascotThemeScanner.performSyncFromCodex(codexURL: nil, destinationURL: dest)
        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.failed.isEmpty)
    }

    // 2. codex 目录不存在时返回空结果
    func testSyncReturnsEmptyWhenCodexDirectoryMissing() async {
        let codex = tempRoot.appendingPathComponent("nonexistent-codex", isDirectory: true)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let result = await MascotThemeScanner.performSyncFromCodex(codexURL: codex, destinationURL: dest)
        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    // 3. 目标已存在时跳过
    func testSyncSkipsExistingDestination() async throws {
        let codex = tempRoot.appendingPathComponent("codex", isDirectory: true)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // codex 下放一个 pet 目录
        let petDir = codex.appendingPathComponent("frieren", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        try " {}".write(to: petDir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)

        // dest 下已存在同名
        let existingDest = dest.appendingPathComponent("frieren", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDest, withIntermediateDirectories: true)

        let result = await MascotThemeScanner.performSyncFromCodex(codexURL: codex, destinationURL: dest)
        XCTAssertEqual(result.synced, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.failed.isEmpty)
    }

    // 4. 有效目录被复制
    func testSyncCopiesValidDirectories() async throws {
        let codex = tempRoot.appendingPathComponent("codex", isDirectory: true)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

        // codex 下放两个 pet 目录
        for name in ["frieren", "ikun"] {
            let petDir = codex.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
            try "{}".write(to: petDir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        }
        // 放一个非目录文件，应被跳过且不计入 failed
        try "noise".write(to: codex.appendingPathComponent("noise.txt"), atomically: true, encoding: .utf8)

        let result = await MascotThemeScanner.performSyncFromCodex(codexURL: codex, destinationURL: dest)
        XCTAssertEqual(result.synced, 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.failed.isEmpty)

        // 验证复制结果
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("frieren/pet.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("ikun/pet.json").path))
    }
}
