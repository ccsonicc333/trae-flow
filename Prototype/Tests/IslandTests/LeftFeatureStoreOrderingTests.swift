import XCTest

/// Spec: refactor-left-island-boringnotch-features —— Task 18.2
/// 验证 LeftFeatureStore 排序与选择回退逻辑的算法等价实现。
final class LeftFeatureStoreOrderingTests: XCTestCase {

    struct TestFeature: Equatable {
        let id: String
        let kind: String
        var isEnabled: Bool
        var sortOrder: Int
    }

    /// enabledFeatures 计算（与 LeftFeatureStore.enabledFeatures 等价）
    func computeEnabled(_ features: [TestFeature]) -> [TestFeature] {
        features.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// compactFeature 自动规则（与 LeftFeatureStore.compactFeature 等价）
    /// musicIsPlaying 模拟 NowPlayingProvider.shared.nowPlaying?.isPlaying
    func resolveCompact(features: [TestFeature], compactFeatureID: String?, musicIsPlaying: Bool) -> TestFeature? {
        if let id = compactFeatureID,
           let f = features.first(where: { $0.id == id && $0.isEnabled }) {
            return f
        }
        let enabled = computeEnabled(features)
        if musicIsPlaying, let music = enabled.first(where: { $0.kind == "music" }) {
            return music
        }
        return enabled.first
    }

    /// expandedActiveFeature 回退规则
    func resolveExpanded(features: [TestFeature], expandedActiveFeatureID: String?) -> TestFeature? {
        if let id = expandedActiveFeatureID,
           let f = features.first(where: { $0.id == id && $0.isEnabled }) {
            return f
        }
        return computeEnabled(features).first
    }

    /// moveFeature 排序算法（与 LeftFeatureStore.moveFeature 等价）
    func moveFeature(_ features: inout [TestFeature], from source: IndexSet, to destination: Int) {
        features.move(fromOffsets: source, toOffset: destination)
        for i in features.indices {
            features[i].sortOrder = i
        }
    }

    // MARK: - enabledFeatures

    func test_enabledFeatures_过滤禁用项并按sortOrder升序() {
        let features = [
            TestFeature(id: "a", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "b", kind: "shelf", isEnabled: false, sortOrder: 1),
            TestFeature(id: "c", kind: "custom", isEnabled: true, sortOrder: 2)
        ]
        let enabled = computeEnabled(features)
        XCTAssertEqual(enabled.map(\.id), ["a", "c"])
    }

    // MARK: - compactFeature 自动规则

    func test_compactFeature_显式选择优先() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: "shelf", musicIsPlaying: true)
        XCTAssertEqual(result?.id, "shelf")
    }

    func test_compactFeature_自动模式_音乐播放中() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: nil, musicIsPlaying: true)
        XCTAssertEqual(result?.id, "music")
    }

    func test_compactFeature_自动模式_音乐未播放_回退首项() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: nil, musicIsPlaying: false)
        XCTAssertEqual(result?.id, "music")  // music 仍是首项
    }

    func test_compactFeature_自动模式_音乐禁用_回退首项() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: false, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: nil, musicIsPlaying: true)
        XCTAssertEqual(result?.id, "shelf")
    }

    func test_compactFeature_显式选择指向已禁用功能_回退自动规则() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: false, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: "music", musicIsPlaying: false)
        XCTAssertEqual(result?.id, "shelf")  // music 禁用，回退到首项 shelf
    }

    func test_compactFeature_无已启用功能_返回nil() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: false, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: false, sortOrder: 1)
        ]
        let result = resolveCompact(features: features, compactFeatureID: nil, musicIsPlaying: false)
        XCTAssertNil(result)
    }

    // MARK: - expandedActiveFeature 回退

    func test_expandedActiveFeature_显式选择优先() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveExpanded(features: features, expandedActiveFeatureID: "shelf")
        XCTAssertEqual(result?.id, "shelf")
    }

    func test_expandedActiveFeature_显式选择指向已禁用_回退首项() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: false, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveExpanded(features: features, expandedActiveFeatureID: "music")
        XCTAssertEqual(result?.id, "shelf")
    }

    func test_expandedActiveFeature_显式选择指向已删除_回退首项() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveExpanded(features: features, expandedActiveFeatureID: "non-existent")
        XCTAssertEqual(result?.id, "music")
    }

    func test_expandedActiveFeature_nil_回退首项() {
        let features = [
            TestFeature(id: "music", kind: "music", isEnabled: true, sortOrder: 0),
            TestFeature(id: "shelf", kind: "shelf", isEnabled: true, sortOrder: 1)
        ]
        let result = resolveExpanded(features: features, expandedActiveFeatureID: nil)
        XCTAssertEqual(result?.id, "music")
    }

    // MARK: - moveFeature 排序

    func test_moveFeature_移动单项_重写sortOrder() {
        var features = [
            TestFeature(id: "a", kind: "", isEnabled: true, sortOrder: 0),
            TestFeature(id: "b", kind: "", isEnabled: true, sortOrder: 1),
            TestFeature(id: "c", kind: "", isEnabled: true, sortOrder: 2)
        ]
        // Array.move(fromOffsets: [0], toOffset: 2) 语义：toOffset 是原始数组坐标，
        // 移除 a 后 [b, c]，destination 2 调整为 2-1=1（扣除移动元素中位于 destination 之前的数量），
        // 插入 a 得 [b, a, c]
        moveFeature(&features, from: IndexSet([0]), to: 2)
        XCTAssertEqual(features.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(features.map(\.sortOrder), [0, 1, 2])
    }

    func test_moveFeature_移动多项_重写sortOrder() {
        var features = [
            TestFeature(id: "a", kind: "", isEnabled: true, sortOrder: 0),
            TestFeature(id: "b", kind: "", isEnabled: true, sortOrder: 1),
            TestFeature(id: "c", kind: "", isEnabled: true, sortOrder: 2),
            TestFeature(id: "d", kind: "", isEnabled: true, sortOrder: 3)
        ]
        moveFeature(&features, from: IndexSet([0, 2]), to: 4)
        XCTAssertEqual(features.map(\.id), ["b", "d", "a", "c"])
        XCTAssertEqual(features.map(\.sortOrder), [0, 1, 2, 3])
    }
}
