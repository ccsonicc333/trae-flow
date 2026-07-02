import AppKit
import XCTest
@testable import TRAE_FLOW

/// 宠物主题包系统 AppSettings 持久化与迁移测试（Task 5.4）
///
/// 独立于 `AppSettingsPersistenceTests`，这里只覆盖新增的 `selectedMascotThemeID` / `mascotThemeOverrides` /
/// `mascotPerClientOverrideEnabled` 键与旧 `mascotOverrides` / `previewMascotKind` 的迁移。
@MainActor
final class MascotSettingsMigrationTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TraeFlowTests.MascotSettingsMigration.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    // MARK: - 迁移：previewMascotKind → selectedMascotThemeID

    func testSelectedMascotThemeIDMigrationFromPreviewMascotKind() throws {
        let defaults = makeDefaults()
        // 注入旧键：全局预览宠物为 frieren（非内置 claude）
        defaults.set("frieren", forKey: "previewMascotKind")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.selectedMascotThemeID, "frieren")
        XCTAssertEqual(store.globalMascotKind, MascotKind(themeID: "frieren"))
        // 旧键应已清除
        XCTAssertNil(defaults.object(forKey: "previewMascotKind"))
        // 新键应已写入，保证下次启动直接命中新键
        XCTAssertEqual(defaults.string(forKey: "selectedMascotThemeID"), "frieren")
    }

    func testPreviewMascotKindClaudeDoesNotMigrateToNonNilThemeID() throws {
        let defaults = makeDefaults()
        // 旧值为内置 claude，迁移后应保持 nil（claude 是回退，不写入新键）
        defaults.set("claude", forKey: "previewMascotKind")

        let store = makeStore(defaults: defaults)

        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertEqual(store.globalMascotKind, .claude)
        XCTAssertNil(defaults.object(forKey: "previewMascotKind"))
    }

    // MARK: - 迁移：mascotOverrides → mascotThemeOverrides

    func testMascotThemeOverridesMigrationFromMascotOverrides() throws {
        let defaults = makeDefaults()
        // 注入旧键：trae 客户端覆盖为 ikun
        defaults.set([MascotClient.trae.rawValue: "ikun"], forKey: "mascotOverrides")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.mascotThemeOverrides, [MascotClient.trae.rawValue: "ikun"])
        // 旧覆盖非空时应自动开启 per-client
        XCTAssertTrue(store.mascotPerClientOverrideEnabled)
        // 旧键应已清除
        XCTAssertNil(defaults.object(forKey: "mascotOverrides"))
        // 新键应已写入
        XCTAssertNotNil(defaults.data(forKey: "mascotThemeOverrides"))
        XCTAssertEqual(defaults.bool(forKey: "mascotPerClientOverrideEnabled"), true)
    }

    func testMascotOverridesLegacyDictionaryMigratesAndPerClientResolves() throws {
        let defaults = makeDefaults()
        defaults.set([MascotClient.trae.rawValue: "ikun"], forKey: "mascotOverrides")

        let store = makeStore(defaults: defaults)

        // 迁移后通过查询接口应能解析到 per-client 覆盖
        XCTAssertEqual(store.mascotOverride(for: .trae), MascotKind(themeID: "ikun"))
        XCTAssertEqual(store.mascotKind(for: MascotClient.trae), MascotKind(themeID: "ikun"))
        XCTAssertTrue(store.hasCustomMascot(for: .trae))
    }

    // MARK: - 迁移幂等性

    func testMigrationIsIdempotentAcrossReinits() throws {
        let defaults = makeDefaults()
        defaults.set("frieren", forKey: "previewMascotKind")
        defaults.set([MascotClient.trae.rawValue: "ikun"], forKey: "mascotOverrides")

        // 第一次 init 触发迁移
        let firstStore = makeStore(defaults: defaults)
        XCTAssertEqual(firstStore.selectedMascotThemeID, "frieren")
        XCTAssertEqual(firstStore.mascotThemeOverrides, [MascotClient.trae.rawValue: "ikun"])
        XCTAssertTrue(firstStore.mascotPerClientOverrideEnabled)

        // 第二次 init 应直接命中新键，不重复迁移，值不变
        let secondStore = makeStore(defaults: defaults)
        XCTAssertEqual(secondStore.selectedMascotThemeID, "frieren")
        XCTAssertEqual(secondStore.mascotThemeOverrides, [MascotClient.trae.rawValue: "ikun"])
        XCTAssertTrue(secondStore.mascotPerClientOverrideEnabled)
        // 旧键依然不存在
        XCTAssertNil(defaults.object(forKey: "previewMascotKind"))
        XCTAssertNil(defaults.object(forKey: "mascotOverrides"))
    }

    // MARK: - globalMascotKind 回退

    func testGlobalMascotKindFallbackToClaude() throws {
        let defaults = makeDefaults()
        // 不设置任何主题包键
        let store = makeStore(defaults: defaults)

        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertEqual(store.globalMascotKind, .claude)
        // client 为 nil 时也应回退到全局（claude）
        XCTAssertEqual(store.mascotKind(for: MascotClient?.none), .claude)
    }

    func testGlobalMascotKindResolvesNonClaudeThemeID() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.setGlobalMascotThemeID("shinchan")

        XCTAssertEqual(store.selectedMascotThemeID, "shinchan")
        XCTAssertEqual(store.globalMascotKind, MascotKind(themeID: "shinchan"))
    }

    // MARK: - setGlobalMascotThemeID

    func testSetGlobalMascotThemeIDClearsOnClaude() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.setGlobalMascotThemeID("frieren")
        XCTAssertEqual(store.selectedMascotThemeID, "frieren")

        // 传入 claude 应清除（回退到内置）
        store.setGlobalMascotThemeID(MascotKind.claude.themeID)
        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertEqual(store.globalMascotKind, .claude)
        XCTAssertNil(defaults.string(forKey: "selectedMascotThemeID"))
    }

    func testSetGlobalMascotThemeIDClearsOnNil() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.setGlobalMascotThemeID("frieren")
        XCTAssertEqual(store.selectedMascotThemeID, "frieren")

        store.setGlobalMascotThemeID(nil)
        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertEqual(store.globalMascotKind, .claude)
    }

    // MARK: - per-client 开关

    func testPerClientOverrideRespectsEnabledFlag() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        // 关闭开关时，即便有覆盖映射也不生效
        store.mascotPerClientOverrideEnabled = false
        store.setMascotOverride(MascotKind(themeID: "ikun"), for: .trae)
        XCTAssertNil(store.mascotOverride(for: .trae))
        XCTAssertEqual(store.mascotKind(for: .trae), store.globalMascotKind)
        XCTAssertFalse(store.hasCustomMascot(for: .trae))
        XCTAssertEqual(store.customizedMascotClientCount, 0)

        // 开启开关后覆盖生效
        store.mascotPerClientOverrideEnabled = true
        store.setMascotOverride(MascotKind(themeID: "ikun"), for: .trae)
        XCTAssertEqual(store.mascotOverride(for: .trae), MascotKind(themeID: "ikun"))
        XCTAssertTrue(store.hasCustomMascot(for: .trae))
        XCTAssertEqual(store.customizedMascotClientCount, 1)
    }

    func testSetMascotOverrideClaudeRemovesEntry() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.mascotPerClientOverrideEnabled = true

        store.setMascotOverride(MascotKind(themeID: "ikun"), for: .trae)
        XCTAssertEqual(store.mascotThemeOverrides[MascotClient.trae.rawValue], "ikun")

        // 传入 claude（内置回退）应移除该条目
        store.setMascotOverride(.claude, for: .trae)
        XCTAssertNil(store.mascotThemeOverrides[MascotClient.trae.rawValue])
    }

    // MARK: - resetMascotOverrides

    func testResetMascotOverridesClearsAllNewKeys() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.setGlobalMascotThemeID("frieren")
        store.mascotPerClientOverrideEnabled = true
        store.setMascotOverride(MascotKind(themeID: "ikun"), for: .trae)

        store.resetMascotOverrides()

        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertTrue(store.mascotThemeOverrides.isEmpty)
        XCTAssertFalse(store.mascotPerClientOverrideEnabled)
        XCTAssertEqual(store.customizedMascotClientCount, 0)
        XCTAssertNil(defaults.string(forKey: "selectedMascotThemeID"))
    }

    // MARK: - 兼容入口转发

    func testPreviewMascotKindSetterForwardsToSelectedMascotThemeID() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        // 旧入口写入非 claude 应转发到新键
        store.previewMascotKind = MascotKind(themeID: "frieren")
        XCTAssertEqual(store.selectedMascotThemeID, "frieren")
        XCTAssertEqual(defaults.string(forKey: "selectedMascotThemeID"), "frieren")
        // 旧键不应被写入（兼容层不再持久化旧键）
        XCTAssertNil(defaults.object(forKey: "previewMascotKind"))
    }

    func testPreviewMascotKindSetterClaudeForwardsToNil() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.previewMascotKind = MascotKind(themeID: "frieren")
        XCTAssertEqual(store.selectedMascotThemeID, "frieren")

        // 旧入口写 claude 应转发为 nil
        store.previewMascotKind = .claude
        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertNil(defaults.string(forKey: "selectedMascotThemeID"))
    }

    func testMascotOverridesSetterForwardsToMascotThemeOverrides() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        // 旧入口写入应转发到新键
        store.mascotOverrides = [MascotClient.trae.rawValue: "ikun"]
        XCTAssertEqual(store.mascotThemeOverrides, [MascotClient.trae.rawValue: "ikun"])
        XCTAssertNotNil(defaults.data(forKey: "mascotThemeOverrides"))
        // 旧键不应被写入
        XCTAssertNil(defaults.object(forKey: "mascotOverrides"))
    }

    // MARK: - 跨重启持久化

    func testSelectedMascotThemeIDPersistsAcrossReinits() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.setGlobalMascotThemeID("frieren")

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.selectedMascotThemeID, "frieren")
        XCTAssertEqual(reloadedStore.globalMascotKind, MascotKind(themeID: "frieren"))
    }

    func testMascotThemeOverridesPersistsAcrossReinits() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.mascotPerClientOverrideEnabled = true
        store.setMascotOverride(MascotKind(themeID: "ikun"), for: .trae)

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.mascotPerClientOverrideEnabled)
        XCTAssertEqual(reloadedStore.mascotThemeOverrides, [MascotClient.trae.rawValue: "ikun"])
        XCTAssertEqual(reloadedStore.mascotOverride(for: .trae), MascotKind(themeID: "ikun"))
    }
}
