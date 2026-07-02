import XCTest

/// Spec: refactor-left-island-boringnotch-features —— Task 18.3
/// 验证 LeftFeatureStore 与 CustomAreaStore 的 add/remove 联动算法。
final class LeftFeatureStoreCustomAreaLifecycleTests: XCTestCase {

    struct TestFeature: Equatable {
        let id: String
        let kind: String
        var isEnabled: Bool
        var sortOrder: Int
    }

    /// appendCustomAreaFeature 算法
    func appendCustomArea(to features: inout [TestFeature], areaID: String) {
        let maxSort = features.map(\.sortOrder).max() ?? -1
        features.append(TestFeature(
            id: "feature-\(areaID)",
            kind: "customArea:\(areaID)",
            isEnabled: true,
            sortOrder: maxSort + 1
        ))
    }

    /// removeCustomAreaFeature 算法（含选择回退）
    func removeCustomArea(from features: inout [TestFeature],
                          areaID: String,
                          compactFeatureID: inout String?,
                          expandedActiveFeatureID: inout String?) {
        let removedIDs = Set(
            features.compactMap { f -> String? in
                if f.kind == "customArea:\(areaID)" { return f.id }
                return nil
            }
        )
        guard !removedIDs.isEmpty else { return }
        features.removeAll { removedIDs.contains($0.id) }
        if let c = compactFeatureID, removedIDs.contains(c) { compactFeatureID = nil }
        if let e = expandedActiveFeatureID, removedIDs.contains(e) { expandedActiveFeatureID = nil }
    }

    func test_appendCustomArea_追加到末尾sortOrder递增() {
        var features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        appendCustomArea(to: &features, areaID: "weather")
        XCTAssertEqual(features.count, 3)
        XCTAssertEqual(features[2].id, "feature-weather")
        XCTAssertEqual(features[2].sortOrder, 2)

        appendCustomArea(to: &features, areaID: "cpu")
        XCTAssertEqual(features.count, 4)
        XCTAssertEqual(features[3].id, "feature-cpu")
        XCTAssertEqual(features[3].sortOrder, 3)
    }

    func test_removeCustomArea_移除对应feature() {
        var features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "feature-weather", kind: "customArea:weather", isEnabled: true, sortOrder: 1)
        ]
        var compactID: String? = nil
        var expandedID: String? = nil
        removeCustomArea(from: &features, areaID: "weather",
                         compactFeatureID: &compactID,
                         expandedActiveFeatureID: &expandedID)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].id, "music")
    }

    func test_removeCustomArea_选择指向被删功能_置nil() {
        var features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "feature-weather", kind: "customArea:weather", isEnabled: true, sortOrder: 1)
        ]
        var compactID: String? = "feature-weather"
        var expandedID: String? = "feature-weather"
        removeCustomArea(from: &features, areaID: "weather",
                         compactFeatureID: &compactID,
                         expandedActiveFeatureID: &expandedID)
        XCTAssertNil(compactID)
        XCTAssertNil(expandedID)
    }

    func test_removeCustomArea_选择未指向被删功能_保持不变() {
        var features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "feature-weather", kind: "customArea:weather", isEnabled: true, sortOrder: 1)
        ]
        var compactID: String? = "music"
        var expandedID: String? = "music"
        removeCustomArea(from: &features, areaID: "weather",
                         compactFeatureID: &compactID,
                         expandedActiveFeatureID: &expandedID)
        XCTAssertEqual(compactID, "music")
        XCTAssertEqual(expandedID, "music")
    }

    func test_removeCustomArea_不存在的areaID_无操作() {
        var features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "feature-weather", kind: "customArea:weather", isEnabled: true, sortOrder: 1)
        ]
        var compactID: String? = "feature-weather"
        var expandedID: String? = "feature-weather"
        removeCustomArea(from: &features, areaID: "non-existent",
                         compactFeatureID: &compactID,
                         expandedActiveFeatureID: &expandedID)
        XCTAssertEqual(features.count, 2)
        XCTAssertEqual(compactID, "feature-weather")
        XCTAssertEqual(expandedID, "feature-weather")
    }
}
