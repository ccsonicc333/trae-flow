import XCTest
import AppKit
@testable import TRAE_FLOW

/// `ShelfStore` 行为测试
///
/// 验证拖入文件添加、按 id 移除、清空以及 AirDrop 空集合守卫等行为。
/// 由于 `ShelfStore` 是 `@MainActor` 单例（`private init`），测试通过 `shared`
/// 实例操作并在 `tearDown` 中调用 `clear()` 还原状态。
@MainActor
final class ShelfStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var createdURLs: [URL] = []

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempDirectory = tmp
        // 起始状态：确保 shared 实例无残留
        ShelfStore.shared.clear()
    }

    override func tearDownWithError() throws {
        ShelfStore.shared.clear()
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        createdURLs.removeAll()
    }

    // MARK: - Helpers

    /// 在临时目录中写入一个小的文本文件，返回文件 URL。
    private func makeTextFile(named name: String, contents: String = "shelf-test") throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        createdURLs.append(url)
        return url
    }

    // MARK: - add(url:)

    func testAddAppendsItemWithCorrectMetadata() throws {
        let url = try makeTextFile(named: "alpha.txt", contents: "hello-shelf")

        ShelfStore.shared.add(url: url)

        let items = ShelfStore.shared.items
        XCTAssertEqual(items.count, 1, "add(url:) should append a single item")

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.name, "alpha.txt", "name should be the last path component")
        XCTAssertEqual(item.fileURL, url, "fileURL should match the URL passed to add")
        XCTAssertGreaterThan(item.size, 0, "size should be read from disk and be positive for non-empty file")
        XCTAssertNotNil(item.bookmarkData, "bookmarkData should be populated for an accessible file")
    }

    func testAddIgnoresDuplicateURL() throws {
        let url = try makeTextFile(named: "dup.txt")

        ShelfStore.shared.add(url: url)
        ShelfStore.shared.add(url: url)

        XCTAssertEqual(ShelfStore.shared.items.count, 1, "adding the same URL twice should not duplicate")
    }

    // MARK: - remove(id:)

    func testRemoveByIDRemovesMatchingItem() throws {
        let urlA = try makeTextFile(named: "a.txt")
        let urlB = try makeTextFile(named: "b.txt")

        ShelfStore.shared.add(url: urlA)
        ShelfStore.shared.add(url: urlB)

        let idToRemove = ShelfStore.shared.items.first(where: { $0.fileURL == urlA })?.id
        let id = try XCTUnwrap(idToRemove)

        ShelfStore.shared.remove(id: id)

        let remaining = ShelfStore.shared.items
        XCTAssertEqual(remaining.count, 1, "remove(id:) should remove exactly one item")
        XCTAssertFalse(remaining.contains(where: { $0.id == id }), "removed id should not be present")
        XCTAssertTrue(remaining.contains(where: { $0.fileURL == urlB }), "other item should remain")
    }

    func testRemoveWithUnknownIDIsNoOp() throws {
        let url = try makeTextFile(named: "keep.txt")
        ShelfStore.shared.add(url: url)

        ShelfStore.shared.remove(id: UUID())

        XCTAssertEqual(ShelfStore.shared.items.count, 1, "unknown id should not change items")
    }

    // MARK: - clear()

    func testClearEmptiesItems() throws {
        let urlA = try makeTextFile(named: "x.txt")
        let urlB = try makeTextFile(named: "y.txt")
        let urlC = try makeTextFile(named: "z.txt")

        ShelfStore.shared.add(url: urlA)
        ShelfStore.shared.add(url: urlB)
        ShelfStore.shared.add(url: urlC)

        XCTAssertEqual(ShelfStore.shared.items.count, 3)

        ShelfStore.shared.clear()

        XCTAssertTrue(ShelfStore.shared.items.isEmpty, "clear() should remove all items")
    }

    // MARK: - AirDrop guards

    func testAirDropAllWithEmptyItemsDoesNotCrash() {
        // guard clause should short-circuit before invoking NSSharingService
        ShelfStore.shared.airDropAll()
        XCTAssertTrue(ShelfStore.shared.items.isEmpty)
    }

    func testAirDropWithEmptyIDsDoesNotCrash() {
        ShelfStore.shared.airDrop(ids: [UUID(), UUID()])
        XCTAssertTrue(ShelfStore.shared.items.isEmpty)
    }

    func testAirDropAllWithItemsDoesNotInvokeSharingService() throws {
        // 添加条目后调用 airDropAll 在测试环境不应崩溃；
        // NSSharingService(named: .sendViaAirDrop) 在无 AirDrop 支持的环境下会返回 nil 而提前返回，
        // 因此不会真正弹出系统分享面板。
        let url = try makeTextFile(named: "share.txt")
        ShelfStore.shared.add(url: url)

        ShelfStore.shared.airDropAll()

        XCTAssertEqual(ShelfStore.shared.items.count, 1, "airDropAll should not mutate items")
    }

    // MARK: - Multiple items count integrity

    func testAddAndRemoveMultipleMaintainsCount() throws {
        let urls = try (0..<5).map { index -> URL in
            try makeTextFile(named: "file-\(index).txt", contents: "payload-\(index)")
        }

        for url in urls {
            ShelfStore.shared.add(url: url)
        }
        XCTAssertEqual(ShelfStore.shared.items.count, 5, "all five items should be added")

        // 移除偶数索引对应的条目
        let idsToRemove = ShelfStore.shared.items.enumerated()
            .filter { $0.offset % 2 == 0 }
            .map { $0.element.id }

        for id in idsToRemove {
            ShelfStore.shared.remove(id: id)
        }
        XCTAssertEqual(ShelfStore.shared.items.count, 5 - idsToRemove.count,
                       "removing \(idsToRemove.count) items should leave the remainder")

        // 再次添加不会与既有文件重复
        for url in urls {
            ShelfStore.shared.add(url: url)
        }
        XCTAssertEqual(ShelfStore.shared.items.count, 5,
                       "re-adding existing URLs should be deduped to original count")
    }
}
