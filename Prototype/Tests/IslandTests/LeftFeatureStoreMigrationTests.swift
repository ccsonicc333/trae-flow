import XCTest

/// Spec: refactor-left-island-boringnotch-features —— Task 18.1
/// 验证 LeftFeatureStore 迁移逻辑的算法等价实现（纯函数版本，不依赖 App 层单例）。
final class LeftFeatureStoreMigrationTests: XCTestCase {

    // MARK: - 测试用的简化模型（与 TraeFlow/LeftFeature.swift 等价，但无 AppKit 依赖）

    struct TestFeature: Equatable {
        let id: String
        let kind: String  // "music" / "shelf" / "customArea:<areaID>"
        let isEnabled: Bool
        let sortOrder: Int
    }

    struct TestArea: Equatable {
        let id: String
        let sortOrder: Int
    }

    /// 迁移逻辑的纯函数实现（与 LeftFeatureStore.migrateFromLegacy 等价）
    /// 注意：CustomArea 按 sortOrder 降序排列（与 CustomAreaStore.load 及
    /// LeftFeatureStore.migrateFromLegacy 的实际实现一致）。
    func planMigration(areas: [TestArea],
                       legacyCompactAreaID: String?,
                       legacyExpandedAreaID: String?,
                       legacySelectedAreaID: String?) -> (features: [TestFeature], compactFeatureID: String?, expandedActiveFeatureID: String?) {
        var features: [TestFeature] = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        // CustomArea 按 sortOrder 降序（与 CustomAreaStore.load 一致）
        let sortedAreas = areas.sorted { $0.sortOrder > $1.sortOrder }
        for (index, area) in sortedAreas.enumerated() {
            features.append(TestFeature(
                id: "feature-\(area.id)",
                kind: "customArea:\(area.id)",
                isEnabled: true,
                sortOrder: 2 + index
            ))
        }

        var compactFeatureID: String?
        if let legacyCompactAreaID {
            if let f = features.first(where: { $0.kind == "customArea:\(legacyCompactAreaID)" }) {
                compactFeatureID = f.id
            }
        }

        var expandedActiveFeatureID: String?
        let legacyExpanded = legacyExpandedAreaID ?? legacySelectedAreaID
        if let legacyExpanded {
            if let f = features.first(where: { $0.kind == "customArea:\(legacyExpanded)" }) {
                expandedActiveFeatureID = f.id
            }
        }

        return (features, compactFeatureID, expandedActiveFeatureID)
    }

    // MARK: - Tests

    func test_新用户初始化_无旧数据_无自定义HTML() {
        let result = planMigration(areas: [],
                                   legacyCompactAreaID: nil,
                                   legacyExpandedAreaID: nil,
                                   legacySelectedAreaID: nil)
        XCTAssertEqual(result.features.count, 2)
        XCTAssertEqual(result.features[0].id, "music")
        XCTAssertEqual(result.features[0].sortOrder, 0)
        XCTAssertEqual(result.features[1].id, "shelf")
        XCTAssertEqual(result.features[1].sortOrder, 1)
        XCTAssertNil(result.compactFeatureID)
        XCTAssertNil(result.expandedActiveFeatureID)
    }

    func test_老用户迁移_有自定义HTML_无旧选择() {
        let areas = [
            TestArea(id: "weather", sortOrder: 0),
            TestArea(id: "cpu", sortOrder: 1)
        ]
        let result = planMigration(areas: areas,
                                   legacyCompactAreaID: nil,
                                   legacyExpandedAreaID: nil,
                                   legacySelectedAreaID: nil)
        XCTAssertEqual(result.features.count, 4)
        // 降序后：cpu(sortOrder=1) 在前，weather(sortOrder=0) 在后
        XCTAssertEqual(result.features[2].id, "feature-cpu")
        XCTAssertEqual(result.features[2].sortOrder, 2)
        XCTAssertEqual(result.features[3].id, "feature-weather")
        XCTAssertEqual(result.features[3].sortOrder, 3)
        XCTAssertNil(result.compactFeatureID)
        XCTAssertNil(result.expandedActiveFeatureID)
    }

    func test_老用户迁移_旧compactAreaID迁移到compactFeatureID() {
        let areas = [TestArea(id: "weather", sortOrder: 0)]
        let result = planMigration(areas: areas,
                                   legacyCompactAreaID: "weather",
                                   legacyExpandedAreaID: nil,
                                   legacySelectedAreaID: nil)
        XCTAssertEqual(result.compactFeatureID, "feature-weather")
        XCTAssertNil(result.expandedActiveFeatureID)
    }

    func test_老用户迁移_旧expandedAreaID迁移到expandedActiveFeatureID() {
        let areas = [TestArea(id: "weather", sortOrder: 0)]
        let result = planMigration(areas: areas,
                                   legacyCompactAreaID: nil,
                                   legacyExpandedAreaID: "weather",
                                   legacySelectedAreaID: nil)
        XCTAssertNil(result.compactFeatureID)
        XCTAssertEqual(result.expandedActiveFeatureID, "feature-weather")
    }

    func test_老用户迁移_旧selectedID回退迁移到expandedActiveFeatureID() {
        let areas = [TestArea(id: "weather", sortOrder: 0)]
        let result = planMigration(areas: areas,
                                   legacyCompactAreaID: nil,
                                   legacyExpandedAreaID: nil,
                                   legacySelectedAreaID: "weather")
        XCTAssertNil(result.compactFeatureID)
        XCTAssertEqual(result.expandedActiveFeatureID, "feature-weather")
    }

    func test_老用户迁移_旧ID指向不存在的area() {
        let areas = [TestArea(id: "weather", sortOrder: 0)]
        let result = planMigration(areas: areas,
                                   legacyCompactAreaID: "non-existent",
                                   legacyExpandedAreaID: "non-existent",
                                   legacySelectedAreaID: nil)
        XCTAssertNil(result.compactFeatureID)
        XCTAssertNil(result.expandedActiveFeatureID)
    }

    func test_迁移幂等性_多次调用结果一致() {
        let areas = [TestArea(id: "weather", sortOrder: 0)]
        let r1 = planMigration(areas: areas,
                               legacyCompactAreaID: "weather",
                               legacyExpandedAreaID: nil,
                               legacySelectedAreaID: nil)
        let r2 = planMigration(areas: areas,
                               legacyCompactAreaID: "weather",
                               legacyExpandedAreaID: nil,
                               legacySelectedAreaID: nil)
        XCTAssertEqual(r1.features, r2.features)
        XCTAssertEqual(r1.compactFeatureID, r2.compactFeatureID)
        XCTAssertEqual(r1.expandedActiveFeatureID, r2.expandedActiveFeatureID)
    }
}
