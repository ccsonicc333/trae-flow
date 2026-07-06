import Foundation

/// 功能图标解析后的类型
/// - sfSymbol: SF Symbols 图标名（如 `music.note`）
/// - text: 文字图标（emoji 或最多 2 字符的字符串，如 `🔥` 或 `AB`）
/// - image: 图片文件名，位于 `BridgeRuntimePaths.iconsDirectoryURL`（如 `custom-area-1.png`）
/// - none: 无图标标识，回退 kind 默认 SF Symbol
enum IconKind: Equatable {
    case sfSymbol(String)
    case text(String)
    case image(String)
    case none
}

/// 解析图标标识符字符串为 `IconKind`
/// - `sf:<name>` → `.sfSymbol(name)`（如 `sf:music.note`）
/// - `text:<str>` → `.text(str)`（截断到 2 字符，保留 emoji 与双字节字符）
/// - `img:<filename>` → `.image(filename)`（文件位于 `BridgeRuntimePaths.iconsDirectoryURL`）
/// - 无前缀且非空 → `.sfSymbol(原字符串)`（兼容老数据，按 SF Symbol 处理）
/// - nil 或空 → `.none`（回退 kind 默认 SF Symbol）
///
/// 该函数为顶层函数（非 `LeftFeature` 成员），便于 `CustomArea.swift` 等同 module 内其他文件复用。
func resolveIconKind(_ identifier: String?) -> IconKind {
    guard let id = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
        return .none
    }
    if id.hasPrefix("sf:") {
        let name = String(id.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? .none : .sfSymbol(name)
    }
    if id.hasPrefix("text:") {
        let text = String(id.dropFirst(5))
        // 截断到 2 字符（保留 emoji 与双字节字符）
        return .text(String(text.prefix(2)))
    }
    if id.hasPrefix("img:") {
        let filename = String(id.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? .none : .image(filename)
    }
    // 无前缀非空 → 兼容老数据，按 SF Symbol 处理
    return .sfSymbol(id)
}

/// 左侧 Flow 岛"功能系统"的功能类型
/// - music: 内置音乐功能
/// - shelf: 内置中转站（暂存消息/片段）
/// - customArea: 用户自定义 HTML 区域，关联 CustomArea.id
/// - webURL: 远程网站 URL 功能（Task: extend-left-features-url-icons-jump）
/// - newsnow: 内置 NewsNow 热点新闻功能，关联实例 baseURL（Spec: add-newsnow-built-in-feature）
/// - mineradio: 内置 Mineradio 矿石电台，关联 pageURL，注入 Bridge 兼容层 + JSC 引擎（Spec: mineradio-bridge-compat-layer）
enum LeftFeatureKind: Codable, Equatable, Hashable {
    case music
    case shelf
    case customArea(areaID: String)
    case webURL(url: String)
    case newsnow(baseURL: String)
    case mineradio(pageURL: String)
}

/// 左侧 Flow 岛"功能系统"基础数据模型
/// 描述一个可在紧凑态/展开态展示的功能项（音乐 / 中转站 / 自定义 HTML / 网站 URL）
struct LeftFeature: Codable, Equatable, Identifiable, Sendable {
    /// 稳定唯一 ID；内置功能使用 `LeftFeature.musicID` / `LeftFeature.shelfID`
    let id: String
    /// 功能类型
    var kind: LeftFeatureKind
    /// 是否启用；禁用的功能不出现在 `enabledFeatures`，也不会被自动规则选中
    var isEnabled: Bool
    /// 排序权重（越小越靠前）
    var sortOrder: Int
    /// 创建时间
    var createdAt: Date
    /// 自定义 SF Symbol 图标名；非空时覆盖 kind 默认图标（适用所有 kind）
    var customIconName: String?
    /// 自定义显示名称；仅 `.webURL` 使用，其他 kind 当前忽略
    var customDisplayName: String?
    /// 自定义展开宽度（pt）；nil = 跟随全局 `Settings.expandedPanelWidth`
    var expandedWidth: Double?
    /// 自定义展开高度（pt）；nil = 跟随全局 `Settings.maxPanelHeight`
    var expandedHeight: Double?
    /// 展开即固定开关；true = 切换到该功能时面板自动 pin
    var expandedPinned: Bool

    init(id: String = UUID().uuidString,
         kind: LeftFeatureKind,
         isEnabled: Bool = true,
         sortOrder: Int = 0,
         createdAt: Date = Date(),
         customIconName: String? = nil,
         customDisplayName: String? = nil,
         expandedWidth: Double? = nil,
         expandedHeight: Double? = nil,
         expandedPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.customIconName = customIconName
        self.customDisplayName = customDisplayName
        self.expandedWidth = expandedWidth
        self.expandedHeight = expandedHeight
        self.expandedPinned = expandedPinned
    }

    // MARK: - Codable（向后兼容老 left-features.json）

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case isEnabled
        case sortOrder
        case createdAt
        case customIconName
        case customDisplayName
        case expandedWidth
        case expandedHeight
        case expandedPinned
    }

    /// 自定义解码：容忍老 `left-features.json` 缺少新增字段，
    /// 缺失时回退 nil / false，保证老数据解析不失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(LeftFeatureKind.self, forKey: .kind)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.customIconName = try c.decodeIfPresent(String.self, forKey: .customIconName)
        self.customDisplayName = try c.decodeIfPresent(String.self, forKey: .customDisplayName)
        self.expandedWidth = try c.decodeIfPresent(Double.self, forKey: .expandedWidth)
        self.expandedHeight = try c.decodeIfPresent(Double.self, forKey: .expandedHeight)
        self.expandedPinned = try c.decodeIfPresent(Bool.self, forKey: .expandedPinned) ?? false
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
        try c.encodeIfPresent(expandedWidth, forKey: .expandedWidth)
        try c.encodeIfPresent(expandedHeight, forKey: .expandedHeight)
        try c.encode(expandedPinned, forKey: .expandedPinned)
    }
}

extension LeftFeature {
    /// 内置功能的稳定 id
    static let musicID = "music"
    static let shelfID = "shelf"
    static let newsnowID = "newsnow"
    static let mineradioID = "mineradio"

    /// 系统图标名（SF Symbols）。优先使用 `customIconName`（非空时覆盖所有 kind 默认图标）。
    var systemImage: String {
        if let customIconName, !customIconName.isEmpty {
            return customIconName
        }
        switch kind {
        case .music:
            return "music.note"
        case .shelf:
            return "tray.full"
        case .customArea:
            return "globe"
        case .webURL:
            // webURL 默认图标为文字「U」（由 FeatureIconView 解析为文字图标）
            return "text:U"
        case .newsnow:
            return "newspaper"
        case .mineradio:
            return "antenna.radiowaves.left.and.right"
        }
    }

    /// 显示名称。优先使用 `customDisplayName`（非空时覆盖所有 kind 默认名）；
    /// 自定义 HTML 从 CustomAreaStore 查询目录名。
    /// 因 CustomAreaStore.shared 是 @MainActor，故此处也标注 @MainActor；
    /// 调用方需保证在主线程访问。
    @MainActor
    var displayName: String {
        if let customDisplayName, !customDisplayName.isEmpty {
            return customDisplayName
        }
        switch kind {
        case .music:
            return "音乐"
        case .shelf:
            return "中转站"
        case .customArea(let areaID):
            return CustomAreaStore.shared.areas.first { $0.id == areaID }?.name ?? "自定义 HTML"
        case .webURL:
            return "网站"
        case .newsnow:
            return "热点新闻"
        case .mineradio:
            return "Mineradio"
        }
    }
}
