import XCTest
import SwiftUI
@testable import TRAE_FLOW

/// MascotView 渲染管线相关测试
///
/// SwiftUI Canvas 难以单测，这里只覆盖 `MascotKind` struct 的核心行为：
/// - `.claude` 内置回退
/// - `rawValue` 往返
/// - 相等性
/// - 从 SessionProvider 构造
/// - 非 claude 主题包的 title/alertColor 回退
final class MascotViewRenderingTests: XCTestCase {
    func testMascotKindClaudeStatic() {
        XCTAssertEqual(MascotKind.claude.themeID, "claude")
        XCTAssertEqual(MascotKind.claude.id, "claude")
        XCTAssertEqual(MascotKind.claude.title, "TRAE")
        XCTAssertEqual(MascotKind.claude.subtitle, "TRAE 默认宠物")
    }

    func testMascotKindRawValueRoundTrip() {
        let kind = MascotKind(themeID: "frieren")
        XCTAssertEqual(kind.rawValue, "frieren")
        XCTAssertEqual(MascotKind(rawValue: "frieren")?.themeID, "frieren")
        XCTAssertEqual(MascotKind(rawValue: "frieren"), kind)
    }

    func testMascotKindEquality() {
        XCTAssertEqual(MascotKind(themeID: "a"), MascotKind(themeID: "a"))
        XCTAssertNotEqual(MascotKind(themeID: "a"), MascotKind(themeID: "b"))
        XCTAssertEqual(MascotKind.claude, MascotKind(themeID: "claude"))
    }

    func testMascotKindFromProvider() {
        let kind = MascotKind(provider: .trae)
        XCTAssertEqual(kind, .claude)
    }

    func testMascotKindNonClaudeTitleUsesThemeID() {
        let kind = MascotKind(themeID: "ikun")
        XCTAssertEqual(kind.title, "ikun")
        XCTAssertEqual(kind.alertColor, .orange)
    }
}
