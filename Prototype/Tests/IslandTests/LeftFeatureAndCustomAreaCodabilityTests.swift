import Foundation
import XCTest

/// Spec: extend-left-features-url-icons-jump —— Task 1.4
/// 验证 `LeftFeature` / `CustomArea` 的 Codable 向后兼容性：
/// 1. 老 JSON 缺少 `customIconName` / `customDisplayName` / `iconName` / `allowsNetworkAccess` 字段时解码不崩溃
/// 2. 新字段缺失时回退默认值（nil / false）
/// 3. `.webURL` kind 的编解码往返（encode → decode 相等）
///
/// Prototype 包不含 `LeftFeature` / `CustomArea` 类型，因此用本地 `TestLeftFeature` /
/// `TestCustomArea` 镜像真实 `Codable` 行为（`decodeIfPresent` 模式），验证逻辑等价性。
final class LeftFeatureAndCustomAreaCodabilityTests: XCTestCase {

    // MARK: - 镜像类型（与 TraeFlow/LeftFeature.swift 的 Codable 逻辑等价）

    /// 镜像 `LeftFeatureKind`，含 `.webURL(url:)` / `.newsnow(baseURL:)` 新 case
    enum TestLeftFeatureKind: Codable, Equatable, Hashable {
        case music
        case shelf
        case customArea(areaID: String)
        case webURL(url: String)
        case newsnow(baseURL: String)
    }

    /// 镜像 `LeftFeature`：新增 `customIconName` / `customDisplayName` 可选字段，
    /// 自定义 `init(from:)` 用 `decodeIfPresent` 容忍缺字段。
    struct TestLeftFeature: Codable, Equatable {
        let id: String
        var kind: TestLeftFeatureKind
        var isEnabled: Bool
        var sortOrder: Int
        var createdAt: Date
        var customIconName: String?
        var customDisplayName: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, isEnabled, sortOrder, createdAt
            case customIconName
            case customDisplayName
        }

        init(id: String = UUID().uuidString,
             kind: TestLeftFeatureKind,
             isEnabled: Bool = true,
             sortOrder: Int = 0,
             createdAt: Date = Date(),
             customIconName: String? = nil,
             customDisplayName: String? = nil) {
            self.id = id
            self.kind = kind
            self.isEnabled = isEnabled
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.customIconName = customIconName
            self.customDisplayName = customDisplayName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.kind = try c.decode(TestLeftFeatureKind.self, forKey: .kind)
            self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
            self.sortOrder = try c.decode(Int.self, forKey: .sortOrder)
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
            self.customIconName = try c.decodeIfPresent(String.self, forKey: .customIconName)
            self.customDisplayName = try c.decodeIfPresent(String.self, forKey: .customDisplayName)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(isEnabled, forKey: .isEnabled)
            try c.encode(sortOrder, forKey: .sortOrder)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encodeIfPresent(customIconName, forKey: .customIconName)
            try c.encodeIfPresent(customDisplayName, forKey: .customDisplayName)
        }
    }

    // MARK: - 镜像类型（与 TraeFlow/CustomArea.swift 的 Codable 逻辑等价）

    /// 镜像 `TraeVariant`（仅 4 个 case + rawValue，足够测试 Codable 行为）
    enum TestTraeVariant: String, Codable, Equatable, Hashable {
        case trae
        case traeCN = "trae-cn"
        case traeWork = "trae-work"
        case traeWorkCN = "trae-work-cn"
    }

    /// 镜像 `CustomArea`：新增 `iconName` / `allowsNetworkAccess` 字段，
    /// `defaultVariant` 默认值改为 `.traeWorkCN`，自定义 `init(from:)` 容忍缺字段。
    struct TestCustomArea: Codable, Equatable {
        let id: String
        var name: String
        var directoryPath: String
        var entryPointRelativePath: String
        var autoDetectEntryPoint: Bool
        var defaultVariant: TestTraeVariant
        var isBuiltIn: Bool
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date
        var iconName: String?
        var allowsNetworkAccess: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, directoryPath, entryPointRelativePath
            case autoDetectEntryPoint, defaultVariant, isBuiltIn, sortOrder
            case createdAt, updatedAt
            case iconName, allowsNetworkAccess
        }

        init(id: String = UUID().uuidString,
             name: String,
             directoryPath: String,
             entryPointRelativePath: String = "index.html",
             autoDetectEntryPoint: Bool = true,
             defaultVariant: TestTraeVariant = .traeWorkCN,
             isBuiltIn: Bool = false,
             sortOrder: Int = 0,
             createdAt: Date = Date(),
             updatedAt: Date = Date(),
             iconName: String? = nil,
             allowsNetworkAccess: Bool = false) {
            self.id = id
            self.name = name
            self.directoryPath = directoryPath
            self.entryPointRelativePath = entryPointRelativePath
            self.autoDetectEntryPoint = autoDetectEntryPoint
            self.defaultVariant = defaultVariant
            self.isBuiltIn = isBuiltIn
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.iconName = iconName
            self.allowsNetworkAccess = allowsNetworkAccess
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.directoryPath = try c.decode(String.self, forKey: .directoryPath)
            self.entryPointRelativePath = try c.decodeIfPresent(String.self, forKey: .entryPointRelativePath) ?? "index.html"
            self.autoDetectEntryPoint = try c.decodeIfPresent(Bool.self, forKey: .autoDetectEntryPoint) ?? true
            self.defaultVariant = try c.decodeIfPresent(TestTraeVariant.self, forKey: .defaultVariant) ?? .traeWorkCN
            self.isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
            self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
            self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
            self.iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
            self.allowsNetworkAccess = try c.decodeIfPresent(Bool.self, forKey: .allowsNetworkAccess) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(directoryPath, forKey: .directoryPath)
            try c.encode(entryPointRelativePath, forKey: .entryPointRelativePath)
            try c.encode(autoDetectEntryPoint, forKey: .autoDetectEntryPoint)
            try c.encode(defaultVariant, forKey: .defaultVariant)
            try c.encode(isBuiltIn, forKey: .isBuiltIn)
            try c.encode(sortOrder, forKey: .sortOrder)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encodeIfPresent(iconName, forKey: .iconName)
            try c.encode(allowsNetworkAccess, forKey: .allowsNetworkAccess)
        }
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
    }

    // MARK: - LeftFeature 老数据兼容性

    func test_LeftFeature_老JSON缺新字段_解码不崩溃且回退nil() throws {
        // 老 left-features.json 仅含 id/kind/isEnabled/sortOrder/createdAt，无 customIconName / customDisplayName
        let oldJSON = """
        {
          "id": "music",
          "kind": { "music": {} },
          "isEnabled": true,
          "sortOrder": 0,
          "createdAt": 0
        }
        """
        let feature = try decode(TestLeftFeature.self, from: oldJSON)
        XCTAssertEqual(feature.id, "music")
        XCTAssertEqual(feature.kind, .music)
        XCTAssertTrue(feature.isEnabled)
        XCTAssertEqual(feature.sortOrder, 0)
        XCTAssertNil(feature.customIconName, "老数据缺 customIconName 应回退 nil")
        XCTAssertNil(feature.customDisplayName, "老数据缺 customDisplayName 应回退 nil")
    }

    func test_LeftFeature_新字段填充后正常解码() throws {
        let json = """
        {
          "id": "site-1",
          "kind": { "webURL": { "url": "https://example.com" } },
          "isEnabled": true,
          "sortOrder": 3,
          "createdAt": 100,
          "customIconName": "star.fill",
          "customDisplayName": "示例站"
        }
        """
        let feature = try decode(TestLeftFeature.self, from: json)
        XCTAssertEqual(feature.kind, .webURL(url: "https://example.com"))
        XCTAssertEqual(feature.customIconName, "star.fill")
        XCTAssertEqual(feature.customDisplayName, "示例站")
    }

    // MARK: - webURL kind 编解码往返

    func test_webURLKind_编解码往返相等() throws {
        let original = TestLeftFeature(
            id: "web-1",
            kind: .webURL(url: "https://trae.flow"),
            isEnabled: true,
            sortOrder: 2,
            customIconName: "globe",
            customDisplayName: "TRAE Flow 官网"
        )
        let json = try encode(original)
        let decoded = try decode(TestLeftFeature.self, from: json)
        XCTAssertEqual(decoded, original, "webURL kind 经 encode → decode 应保持相等")
        XCTAssertEqual(decoded.kind, .webURL(url: "https://trae.flow"))
        XCTAssertEqual(decoded.customDisplayName, "TRAE Flow 官网")
    }

    func test_webURLKind_数组编解码往返() throws {
        let originals = [
            TestLeftFeature(id: "music", kind: .music, sortOrder: 0),
            TestLeftFeature(id: "shelf", kind: .shelf, sortOrder: 1),
            TestLeftFeature(id: "a1", kind: .customArea(areaID: "area-1"), sortOrder: 2),
            TestLeftFeature(id: "w1", kind: .webURL(url: "https://api.example.com"), sortOrder: 3,
                            customIconName: "network", customDisplayName: "接口站")
        ]
        let json = try encode(originals)
        let decoded = try decode([TestLeftFeature].self, from: json)
        XCTAssertEqual(decoded, originals)
        XCTAssertEqual(decoded.last?.kind, .webURL(url: "https://api.example.com"))
    }

    // MARK: - CustomArea 老数据兼容性

    func test_CustomArea_老JSON缺新字段_解码不崩溃且iconName为nil_allowsNetworkAccess为false() throws {
        // 老 custom-areas.json 不含 iconName / allowsNetworkAccess
        let oldJSON = """
        {
          "id": "area-1",
          "name": "我的站点",
          "directoryPath": "/tmp/area-1",
          "entryPointRelativePath": "index.html",
          "autoDetectEntryPoint": true,
          "defaultVariant": "trae",
          "isBuiltIn": false,
          "sortOrder": 5,
          "createdAt": 0,
          "updatedAt": 0
        }
        """
        let area = try decode(TestCustomArea.self, from: oldJSON)
        XCTAssertEqual(area.id, "area-1")
        XCTAssertEqual(area.name, "我的站点")
        XCTAssertEqual(area.defaultVariant, .trae, "老数据 defaultVariant 字段存在时应保留原值（不迁移）")
        XCTAssertEqual(area.sortOrder, 5)
        XCTAssertNil(area.iconName, "老数据缺 iconName 应回退 nil")
        XCTAssertFalse(area.allowsNetworkAccess, "老数据缺 allowsNetworkAccess 应回退 false")
    }

    func test_CustomArea_老JSON完全缺失defaultVariant_回退traeWorkCN() throws {
        // 极端情况：defaultVariant 字段也缺失（理论上老数据总有该字段，但 decodeIfPresent 应安全兜底）
        let oldJSON = """
        {
          "id": "area-2",
          "name": "新建站",
          "directoryPath": "/tmp/area-2"
        }
        """
        let area = try decode(TestCustomArea.self, from: oldJSON)
        XCTAssertEqual(area.id, "area-2")
        XCTAssertEqual(area.entryPointRelativePath, "index.html", "缺失 entryPointRelativePath 应回退默认 index.html")
        XCTAssertTrue(area.autoDetectEntryPoint, "缺失 autoDetectEntryPoint 应回退 true")
        XCTAssertEqual(area.defaultVariant, .traeWorkCN, "缺失 defaultVariant 应回退 .traeWorkCN")
        XCTAssertFalse(area.isBuiltIn)
        XCTAssertEqual(area.sortOrder, 0)
        XCTAssertNil(area.iconName)
        XCTAssertFalse(area.allowsNetworkAccess)
    }

    // MARK: - CustomArea 新字段编解码

    func test_CustomArea_新字段填充后正常解码() throws {
        let json = """
        {
          "id": "area-3",
          "name": "接口演示",
          "directoryPath": "/tmp/area-3",
          "entryPointRelativePath": "index.html",
          "autoDetectEntryPoint": false,
          "defaultVariant": "trae-work-cn",
          "isBuiltIn": false,
          "sortOrder": 10,
          "createdAt": 0,
          "updatedAt": 0,
          "iconName": "bolt.fill",
          "allowsNetworkAccess": true
        }
        """
        let area = try decode(TestCustomArea.self, from: json)
        XCTAssertEqual(area.defaultVariant, .traeWorkCN)
        XCTAssertEqual(area.iconName, "bolt.fill")
        XCTAssertTrue(area.allowsNetworkAccess)
    }

    func test_CustomArea_编解码往返相等() throws {
        let original = TestCustomArea(
            id: "area-4",
            name: "GitHub 仪表盘",
            directoryPath: "/tmp/area-4",
            entryPointRelativePath: "index.html",
            autoDetectEntryPoint: false,
            defaultVariant: .traeWorkCN,
            isBuiltIn: false,
            sortOrder: 7,
            iconName: "network",
            allowsNetworkAccess: true
        )
        let json = try encode(original)
        let decoded = try decode(TestCustomArea.self, from: json)
        XCTAssertEqual(decoded, original, "CustomArea 经 encode → decode 应保持相等")
        XCTAssertEqual(decoded.iconName, "network")
        XCTAssertTrue(decoded.allowsNetworkAccess)
        XCTAssertEqual(decoded.defaultVariant, .traeWorkCN)
    }

    // MARK: - 数组级向后兼容（模拟真实持久化文件）

    func test_CustomArea数组_老JSON混入新字段_全量解码成功() throws {
        // 模拟升级期间 custom-areas.json：第 1 条老数据缺新字段，第 2 条新数据含新字段
        let json = """
        [
          {
            "id": "old-1",
            "name": "老目录",
            "directoryPath": "/tmp/old-1",
            "entryPointRelativePath": "index.html",
            "autoDetectEntryPoint": true,
            "defaultVariant": "trae",
            "isBuiltIn": true,
            "sortOrder": 100,
            "createdAt": 0,
            "updatedAt": 0
          },
          {
            "id": "new-1",
            "name": "新目录",
            "directoryPath": "/tmp/new-1",
            "entryPointRelativePath": "index.html",
            "autoDetectEntryPoint": false,
            "defaultVariant": "trae-work-cn",
            "isBuiltIn": false,
            "sortOrder": 101,
            "createdAt": 0,
            "updatedAt": 0,
            "iconName": "star",
            "allowsNetworkAccess": true
          }
        ]
        """
        let areas = try decode([TestCustomArea].self, from: json)
        XCTAssertEqual(areas.count, 2)
        XCTAssertNil(areas[0].iconName)
        XCTAssertFalse(areas[0].allowsNetworkAccess)
        XCTAssertEqual(areas[0].defaultVariant, .trae, "老数据 defaultVariant 保留原值")
        XCTAssertEqual(areas[1].iconName, "star")
        XCTAssertTrue(areas[1].allowsNetworkAccess)
        XCTAssertEqual(areas[1].defaultVariant, .traeWorkCN)
    }

    // MARK: - NewsNow Codable 往返（Spec: add-newsnow-built-in-feature Task 1.5）

    func test_newsnow_kind_codable往返() {
        let feature = TestLeftFeature(
            id: "newsnow",
            kind: .newsnow(baseURL: "https://newsnow.busiyi.world"),
            isEnabled: true,
            sortOrder: 2
        )
        let decoded = try! decode(TestLeftFeature.self, from: try encode(feature))
        XCTAssertEqual(decoded, feature)
        if case .newsnow(let baseURL) = decoded.kind {
            XCTAssertEqual(baseURL, "https://newsnow.busiyi.world")
        } else {
            XCTFail("期望 .newsnow kind")
        }
    }

    func test_newsnow_kind_自定义baseURL往返() {
        let feature = TestLeftFeature(
            id: "newsnow",
            kind: .newsnow(baseURL: "https://my-newsnow.example.com"),
            isEnabled: false,
            sortOrder: 5,
            customDisplayName: "我的新闻"
        )
        let decoded = try! decode(TestLeftFeature.self, from: try encode(feature))
        XCTAssertEqual(decoded, feature)
        if case .newsnow(let baseURL) = decoded.kind {
            XCTAssertEqual(baseURL, "https://my-newsnow.example.com")
        } else {
            XCTFail("期望 .newsnow kind")
        }
    }
}
