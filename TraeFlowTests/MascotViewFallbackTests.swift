import XCTest
import SwiftUI
@testable import TRAE_FLOW

/// MascotView 主题包缺失回退行为测试
///
/// 验证当用户选中的非 claude 主题包在下次启动时已不存在（被删除或移动）时：
/// - settings 层：`globalMascotKind` 仍返回该失效 ID（不静默清除），由视图层回退
/// - view 层：`drawMascot` 不再依赖 `kind == .claude` 守卫，始终调用 `drawClaude`，
///   确保 scanner 未命中时也能渲染出内置橘猫，而不是空白
///
/// `drawMascot` 是 SwiftUI Canvas 内的私有方法，无法直接单测；
/// 这里覆盖回退链路的可测部分（MascotKind 语义 + Settings 行为 + View 构造不崩溃），
/// 并以文档化测试形式记录视图层回退契约。
@MainActor
final class MascotViewFallbackTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TraeFlowTests.MascotViewFallback.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    // MARK: - MascotKind 回退语义

    func testNonExistentThemeIDIsNotClaude() {
        // 失效主题包的 kind 不等于 .claude —— 这是触发原 bug 的前提
        let stale = MascotKind(themeID: "nonexistent-pet")
        XCTAssertNotEqual(stale, .claude)
        XCTAssertEqual(stale.themeID, "nonexistent-pet")
    }

    func testClaudeKindIsFallbackTarget() {
        // 内置 claude 是回退目标，且与 themeID == "claude" 等价
        XCTAssertEqual(MascotKind.claude, MascotKind(themeID: "claude"))
        XCTAssertEqual(MascotKind.claude.themeID, "claude")
    }

    // MARK: - Settings 层：失效 ID 不会被静默清除

    func testGlobalMascotKindReturnsStaleIDWhenSet() {
        // 用户选了 frieren，下次启动时 frieren 被删除，
        // settings 仍返回 frieren（不静默回退），由视图层处理回退
        let store = makeStore(defaults: makeDefaults())
        store.setGlobalMascotThemeID("frieren")
        XCTAssertEqual(store.selectedMascotThemeID, "frieren")
        XCTAssertEqual(store.globalMascotKind, MascotKind(themeID: "frieren"))
        XCTAssertNotEqual(store.globalMascotKind, .claude)
    }

    func testClearGlobalMascotThemeIDRestoresClaude() {
        // "恢复默认"按钮：清除失效 ID，回退到内置 claude
        let store = makeStore(defaults: makeDefaults())
        store.setGlobalMascotThemeID("frieren")
        XCTAssertNotNil(store.selectedMascotThemeID)
        store.setGlobalMascotThemeID(nil)
        XCTAssertNil(store.selectedMascotThemeID)
        XCTAssertEqual(store.globalMascotKind, .claude)
    }

    // MARK: - View 层：构造不崩溃

    func testMascotViewConstructsWithNonExistentThemeID() {
        // 即使 themeID 在 scanner 中不存在，MascotView 也能正常构造；
        // 渲染时由 themePackCanvasScene 的 else 分支 + drawMascot 强制回退到 drawClaude
        let view = MascotView(
            kind: MascotKind(themeID: "nonexistent-pet"),
            status: .idle,
            size: 32
        )
        XCTAssertEqual(view.kind, MascotKind(themeID: "nonexistent-pet"))
        XCTAssertNotEqual(view.kind, .claude)
    }

    // MARK: - Fallback behavior 契约（文档化）
    //
    // 以下契约由 MascotView.themePackCanvasScene + drawMascot 保证，无法直接单测，
    // 这里记录回退链路以便回归时审查：
    //
    // 1. 当 themeScanner.theme(forID: kind.themeID) 返回 nil（主题包被删除）：
    //    themePackCanvasScene 走 else 分支，调用 canvasFrame → drawMascot
    //
    // 2. drawMascot 不再判断 kind == .claude，始终调用 drawClaude：
    //    这保证失效的非 claude 主题包也能渲染出内置橘猫，而不是空白
    //
    // 3. 设置页 MascotSettingsView.staleThemeSection 检测 selectedMascotThemeID
    //    不在 scanner.themes 中时，显示"之前选择的宠物已不可用，已切换为默认"提示，
    //    并提供"恢复默认"按钮调用 setGlobalMascotThemeID(nil) 清除失效 ID
}
