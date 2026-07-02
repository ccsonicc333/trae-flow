import XCTest

/// Spec: add-newsnow-built-in-feature —— Task 2.4
/// 验证 `ensureBuiltinNewsNowFeature` 的幂等性逻辑（纯函数镜像，不依赖 App 层 @MainActor 单例）。
final class NewsNowBuiltinEnsuranceTests: XCTestCase {

    struct TestFeature: Equatable {
        let id: String
        let kind: String  // "music" / "shelf" / "newsnow"
        let isEnabled: Bool
        let sortOrder: Int
    }

    /// 镜像 `LeftFeatureStore.ensureBuiltinNewsNowFeature` 的逻辑：
    /// 若 features 不含 id == "newsnow" 则追加（sortOrder = max+1，启用），返回新数组；
    /// 已存在则原样返回。
    func ensureNewsNow(features: [TestFeature]) -> [TestFeature] {
        if features.contains(where: { $0.id == "newsnow" }) {
            return features
        }
        let maxSort = features.map(\.sortOrder).max() ?? -1
        return features + [TestFeature(id: "newsnow", kind: "newsnow", isEnabled: true, sortOrder: maxSort + 1)]
    }

    func test_缺失时追加() {
        let initial = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = ensureNewsNow(features: initial)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[2].id, "newsnow")
        XCTAssertEqual(result[2].sortOrder, 2)
        XCTAssertTrue(result[2].isEnabled)
    }

    func test_已存在不覆盖() {
        let initial = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "newsnow", kind: "newsnow", isEnabled: false, sortOrder: 5)
        ]
        let result = ensureNewsNow(features: initial)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].id, "newsnow")
        XCTAssertEqual(result[1].sortOrder, 5)  // 未被覆盖
        XCTAssertFalse(result[1].isEnabled)     // 未被覆盖
    }

    func test_空列表追加sortOrder0() {
        let result = ensureNewsNow(features: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "newsnow")
        XCTAssertEqual(result[0].sortOrder, 0)
    }
}
