import Foundation

/// Spec: 自定义区域目录数据模型
/// 字段：目录路径、入口文件、名称、默认变体、自动检测开关、是否内置、
///       自定义图标覆盖（Task: extend-left-features-url-icons-jump）、外部网络开关
struct CustomArea: Codable, Equatable, Identifiable, Sendable {
    /// 稳定唯一 ID，使用 UUID
    let id: String
    /// 用户可读名称
    var name: String
    /// 目录绝对路径
    /// 内置目录位于 `~/Library/Application Support/trae-flow/custom-areas/<name>/`
    /// 用户自选目录可能位于沙箱外（如 ~/Documents、~/Projects）
    var directoryPath: String
    /// 入口 HTML 文件相对路径（默认 `index.html`）。
    /// 当 `autoDetectEntryPoint` 为 true 时，此字段会被自动更新为新检测到的入口。
    var entryPointRelativePath: String
    /// 是否自动检测目录中新增/修改的 HTML 入口
    var autoDetectEntryPoint: Bool
    /// 用户在"在 Trae 中打开"按钮上选定的默认变体
    var defaultVariant: TraeVariant
    /// 是否为内置默认目录（天气、CPU、股市、番茄时钟等）
    /// 内置目录允许用户删除引用，但不删除文件夹本身
    var isBuiltIn: Bool
    /// 排序权重（越大越靠前）
    var sortOrder: Int
    /// 创建时间
    var createdAt: Date
    /// 最后更新时间
    var updatedAt: Date
    /// 自定义 SF Symbol 图标名；非空时覆盖默认 `globe` 图标
    var iconName: String?
    /// 是否允许该区域访问外部网络（fetch / 子资源 http/https）。
    /// 默认 false，与沙箱本地 HTML 默认拦截策略一致。
    var allowsNetworkAccess: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        directoryPath: String,
        entryPointRelativePath: String = "index.html",
        autoDetectEntryPoint: Bool = true,
        defaultVariant: TraeVariant = .traeWorkCN,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        iconName: String? = nil,
        allowsNetworkAccess: Bool = false
    ) {
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

    // MARK: - Codable（向后兼容老 custom-areas.json）

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case directoryPath
        case entryPointRelativePath
        case autoDetectEntryPoint
        case defaultVariant
        case isBuiltIn
        case sortOrder
        case createdAt
        case updatedAt
        case iconName
        case allowsNetworkAccess
    }

    /// 自定义解码：容忍老 `custom-areas.json` 缺少 `iconName` / `allowsNetworkAccess` 字段，
    /// 缺失时分别回退 nil / false，保证老数据解析不失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.directoryPath = try c.decode(String.self, forKey: .directoryPath)
        self.entryPointRelativePath = try c.decodeIfPresent(String.self, forKey: .entryPointRelativePath) ?? "index.html"
        self.autoDetectEntryPoint = try c.decodeIfPresent(Bool.self, forKey: .autoDetectEntryPoint) ?? true
        self.defaultVariant = try c.decodeIfPresent(TraeVariant.self, forKey: .defaultVariant) ?? .traeWorkCN
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

extension CustomArea {
    /// 目录 URL（标准化）
    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
    }

    /// 入口 HTML 文件 URL（目录 + 相对路径）
    var entryPointURL: URL {
        directoryURL.appendingPathComponent(entryPointRelativePath)
    }

    /// 用于 WKWebView 加载的 file URL
    var loadableFileURL: URL {
        entryPointURL.standardizedFileURL
    }

    /// 安全判断：是否位于内置目录根下
    var isInsideBuiltInRoot: Bool {
        let builtInRoot = BridgeRuntimePaths.customAreasDirectoryURL.standardizedFileURL.path
        let directory = directoryURL.path
        return directory.hasPrefix(builtInRoot + "/") || directory == builtInRoot
    }

    /// 解析后的图标类型（与 LeftFeature 共用顶层 `resolveIconKind` 函数）
    /// - `sf:xxx` → `.sfSymbol`
    /// - `text:xxx` → `.text`
    /// - `img:xxx` → `.image`（文件位于 `BridgeRuntimePaths.iconsDirectoryURL`）
    /// - 无前缀非空 → `.sfSymbol`（兼容老数据）
    /// - nil / 空 → `.none`（回退默认 `globe` SF Symbol）
    var resolvedIcon: IconKind {
        resolveIconKind(iconName)
    }
}
