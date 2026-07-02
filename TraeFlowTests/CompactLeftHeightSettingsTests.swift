import XCTest
@testable import TRAE_FLOW

/// Spec: split-left-content-compact-expanded —— Task 8.6
///
/// 覆盖 `AppSettingsStore.compactLeftHeight`（默认 24，范围 24–80，步长 1）的：
/// - 默认值
/// - didSet 自动 clamp 到 [24, 80]
/// - 持久化到 UserDefaults 键 `compactLeftHeight`
/// - init 时对越界持久化值进行 clamp
/// - 跨重启读取
///
/// `AppSettingsStore` 通过 `init(defaults:)` 接受注入的 `UserDefaults`，
/// 测试使用临时 suite，避免污染全局 `UserDefaults.standard`。
@MainActor
final class CompactLeftHeightSettingsTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TraeFlowTests.CompactLeftHeight.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    override func tearDownWithError() throws {
        Self.retainedStores.removeAll()
    }

    // MARK: - 默认值

    func testCompactLeftHeightDefaultsTo24() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.compactLeftHeight, 24)
    }

    // MARK: - didSet clamp

    func testCompactLeftHeightClampsToLowerBound() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 10

        XCTAssertEqual(store.compactLeftHeight, 24)
    }

    func testCompactLeftHeightClampsToUpperBound() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 100

        XCTAssertEqual(store.compactLeftHeight, 80)
    }

    func testCompactLeftHeightAcceptsLowerBound() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 24

        XCTAssertEqual(store.compactLeftHeight, 24)
    }

    func testCompactLeftHeightAcceptsUpperBound() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 80

        XCTAssertEqual(store.compactLeftHeight, 80)
    }

    func testCompactLeftHeightAcceptsNormalValue() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 50

        XCTAssertEqual(store.compactLeftHeight, 50)
    }

    // MARK: - 持久化

    func testCompactLeftHeightPersistsToDefaults() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.compactLeftHeight = 50

        XCTAssertEqual(defaults.double(forKey: "compactLeftHeight"), 50.0)
    }

    func testCompactLeftHeightClampPersistsClampedValue() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        // 越界值 10 被 clamp 到 24，clamp 后的值应被持久化
        store.compactLeftHeight = 10
        XCTAssertEqual(defaults.double(forKey: "compactLeftHeight"), 24.0)

        // 越界值 100 被 clamp 到 80
        store.compactLeftHeight = 100
        XCTAssertEqual(defaults.double(forKey: "compactLeftHeight"), 80.0)
    }

    // MARK: - init 时 clamp 持久化值

    func testCompactLeftHeightClampsLowerBoundOnLoad() {
        let defaults = makeDefaults()
        // 直接写入越界值，验证 init 时的 clamp
        defaults.set(5.0, forKey: "compactLeftHeight")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.compactLeftHeight, 24)
    }

    func testCompactLeftHeightClampsUpperBoundOnLoad() {
        let defaults = makeDefaults()
        defaults.set(120.0, forKey: "compactLeftHeight")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.compactLeftHeight, 80)
    }

    // MARK: - 跨重启读取

    func testCompactLeftHeightRestoresFromDefaultsAcrossReinits() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.compactLeftHeight = 60

        let reloadedStore = makeStore(defaults: defaults)

        XCTAssertEqual(reloadedStore.compactLeftHeight, 60)
    }

    func testCompactLeftHeightDefaultWhenKeyAbsent() {
        let defaults = makeDefaults()
        // 不设置 compactLeftHeight 键

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.compactLeftHeight, 24)
        // 未写入时 defaults 不应包含该键
        XCTAssertNil(defaults.object(forKey: "compactLeftHeight"))
    }
}
