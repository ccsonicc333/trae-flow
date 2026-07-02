import XCTest
@testable import TRAE_FLOW

/// `MascotThemeScanner` 沙盒访问支持的单测
///
/// 由于 APP_STORE 编译条件在主 scheme 的 Debug 构建中不生效，本测试主要验证：
/// 1. `SecurityScopedBookmarkStore` 的 codex pets bookmark 存取逻辑（save / resolve / remove）
/// 2. `CodexPetsAccessStatus` 枚举的 Equatable 行为
///
/// 注意：bookmark 数据写入真实 `UserDefaults.standard`，setUp/tearDown 必须清除 key 避免污染。
final class MascotThemeScannerSandboxTests: XCTestCase {
    /// codex 宠物目录书签在 UserDefaults 中的 key（与实现保持一致）
    private let codexPetsBookmarkKey = "traeFlowCodexPetsBookmark"
    /// 临时目录（用于创建真实书签，bookmarkData 要求 URL 存在）
    private var tempDir: URL!

    override func setUpWithError() throws {
        // 清除可能残留的书签数据，避免与其他测试或历史运行互相污染
        UserDefaults.standard.removeObject(forKey: codexPetsBookmarkKey)

        // 创建临时目录用于书签测试（bookmarkData 要求 URL 指向真实存在的文件系统对象）
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mascot-sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempDir = tmp
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: codexPetsBookmarkKey)
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // 1. saveCodexPetsBookmark 后 resolveCodexPetsBookmark 能恢复
    func testCodexPetsBookmarkSaveAndResolve() throws {
        let saved = SecurityScopedBookmarkStore.saveCodexPetsBookmark(for: tempDir)
        XCTAssertTrue(saved, "保存 codex 宠物目录书签应成功")

        let resolved = SecurityScopedBookmarkStore.resolveCodexPetsBookmark()
        XCTAssertNotNil(resolved, "应能解析已保存的书签")

        // 路径可能因 /var -> /private/var 符号链接解析不一致，用 resolvingSymlinksInPath 比较
        XCTAssertEqual(
            resolved?.url.resolvingSymlinksInPath().path,
            tempDir.resolvingSymlinksInPath().path,
            "解析出的 URL 应指向原目录"
        )
    }

    // 2. removeCodexPetsBookmark 后 resolve 返回 nil
    func testCodexPetsBookmarkRemove() {
        XCTAssertTrue(SecurityScopedBookmarkStore.saveCodexPetsBookmark(for: tempDir))
        XCTAssertNotNil(SecurityScopedBookmarkStore.resolveCodexPetsBookmark())

        SecurityScopedBookmarkStore.removeCodexPetsBookmark()

        XCTAssertNil(
            SecurityScopedBookmarkStore.resolveCodexPetsBookmark(),
            "移除书签后 resolve 应返回 nil"
        )
    }

    // 3. CodexPetsAccessStatus 枚举的 Equatable 行为
    func testCodexPetsAccessStatusEnumEquatable() {
        let url1 = URL(fileURLWithPath: "/tmp/codex-pets-1", isDirectory: true)
        let url2 = URL(fileURLWithPath: "/tmp/codex-pets-2", isDirectory: true)

        // 同 case 无关联值时相等
        XCTAssertEqual(CodexPetsAccessStatus.notRequired, .notRequired)
        XCTAssertEqual(CodexPetsAccessStatus.notAuthorized, .notAuthorized)
        XCTAssertNotEqual(CodexPetsAccessStatus.notRequired, .notAuthorized)

        // authorized: 同 URL 相等，不同 URL 不等
        XCTAssertEqual(CodexPetsAccessStatus.authorized(url1), .authorized(url1))
        XCTAssertNotEqual(CodexPetsAccessStatus.authorized(url1), .authorized(url2))

        // stale: 同 URL 相等，不同 URL 不等
        XCTAssertEqual(CodexPetsAccessStatus.stale(url1), .stale(url1))
        XCTAssertNotEqual(CodexPetsAccessStatus.stale(url1), .stale(url2))

        // 不同 case 即使 URL 相同也不等
        XCTAssertNotEqual(CodexPetsAccessStatus.authorized(url1), .stale(url1))
        XCTAssertNotEqual(CodexPetsAccessStatus.authorized(url1), .notRequired)
        XCTAssertNotEqual(CodexPetsAccessStatus.stale(url1), .notAuthorized)
    }
}
