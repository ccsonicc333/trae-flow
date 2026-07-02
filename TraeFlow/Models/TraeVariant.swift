import Foundation

/// Spec: TRAE FLOW 第一阶段同时支持以下四种 Trae 系产品变体。
/// 每个变体在 Hook 事件 JSON 中携带 `variant` 字段以区分来源，
/// App 端按该字段将事件归入对应产品会话，并在"跳回 IDE"时激活对应应用实例。
enum TraeVariant: String, Codable, Equatable, Hashable, Sendable, CaseIterable, Identifiable {
    /// TRAE — 本地应用 `Trae.app`，Bundle ID `com.trae.app`，URL Scheme `trae://`
    case trae
    /// TRAE CN — 本地应用 `Trae CN.app`，Bundle ID `cn.trae.app`，URL Scheme `trae-cn://`
    case traeCN = "trae-cn"
    /// TRAE WORK — 本地应用 `TRAE SOLO.app`，Bundle ID `com.trae.solo.app`，URL Scheme `solo://`
    case traeWork = "trae-work"
    /// TRAE WORK CN — 本地应用 `TRAE SOLO CN.app`，Bundle ID `cn.trae.solo.app`，URL Scheme `solo-cn://`
    case traeWorkCN = "trae-work-cn"

    var id: String { rawValue }

    /// 用于 ManagedHookClientProfile.id 与运行时 profile id
    var profileID: String { rawValue }

    /// 用户可见的产品名称
    var displayName: String {
        switch self {
        case .trae: return "TRAE"
        case .traeCN: return "TRAE CN"
        case .traeWork: return "TRAE Work"
        case .traeWorkCN: return "TRAE Work CN"
        }
    }

    /// 用户设备上 `.app` 的实际名称（spec 说明 TRAE SOLO 即对应 TRAE WORK）
    var localAppName: String {
        switch self {
        case .trae: return "Trae"
        case .traeCN: return "Trae CN"
        case .traeWork: return "TRAE SOLO"
        case .traeWorkCN: return "TRAE SOLO CN"
        }
    }

    /// Spec 表格中的 Bundle Identifier
    var bundleIdentifier: String {
        switch self {
        case .trae: return "com.trae.app"
        case .traeCN: return "cn.trae.app"
        case .traeWork: return "com.trae.solo.app"
        case .traeWorkCN: return "cn.trae.solo.app"
        }
    }

    /// Spec 表格中的安装路径
    var installPath: String {
        switch self {
        case .trae: return "/Applications/Trae.app"
        case .traeCN: return "/Applications/Trae CN.app"
        case .traeWork: return "/Applications/TRAE SOLO.app"
        case .traeWorkCN: return "/Applications/TRAE SOLO CN.app"
        }
    }

    /// Spec 表格中的 URL Scheme
    var urlScheme: String {
        switch self {
        case .trae: return "trae"
        case .traeCN: return "trae-cn"
        case .traeWork: return "solo"
        case .traeWorkCN: return "solo-cn"
        }
    }

    /// 全局 hooks 配置相对路径（基于 `~`）。
    /// TRAE IDE 系列遵循官方 Hook 协议，配置在 `~/.trae(-cn)/hooks.json`；
    /// TRAE WORK 系列官方暂无 Hook 机制，预留 `~/.trae-solo(-cn)/hooks.json` 作为
    /// 未来扩展入口，安装器会写入该路径，但 IDE 当前可能不读取——
    /// 在 Spec 中允许通过 bridge 命令参数显式区分变体来源。
    var globalHooksConfigurationRelativePath: String {
        switch self {
        case .trae: return ".trae/hooks.json"
        case .traeCN: return ".trae-cn/hooks.json"
        case .traeWork: return ".trae-solo/hooks.json"
        case .traeWorkCN: return ".trae-solo-cn/hooks.json"
        }
    }

    /// 项目级 hooks 配置相对路径（基于工作区根目录）
    var projectHooksConfigurationRelativePath: String {
        switch self {
        case .trae, .traeCN: return ".trae/hooks.json"
        case .traeWork, .traeWorkCN: return ".trae-solo/hooks.json"
        }
    }

    /// 是否使用 TRAE 官方 Hook 协议（IDE 系列为 true，SOLO/WORK 系列为 false）
    var supportsOfficialTraeHook: Bool {
        switch self {
        case .trae, .traeCN: return true
        case .traeWork, .traeWorkCN: return false
        }
    }

    /// 用于设置面板的图标符号
    var iconSymbolName: String {
        switch self {
        case .trae: return "sparkles"
        case .traeCN: return "star.fill"
        case .traeWork: return "rectangle.stack.fill"
        case .traeWorkCN: return "gearshape.2"
        }
    }

    /// Spec: 任务数定义 —— 该变体当前处于"等待用户干预"状态的会话数量
    /// （包含审批中、追问中），由 SessionStore 按变体聚合计算
    static func fromBundleIdentifier(_ bundleIdentifier: String?) -> TraeVariant? {
        guard let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return allCases.first { $0.bundleIdentifier.lowercased() == bundle }
    }

    static func fromProfileID(_ profileID: String?) -> TraeVariant? {
        guard let id = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return allCases.first { $0.profileID == id }
    }
}

/// Spec 路径约定：用户可见、可配置或可排查的路径均使用小写 `trae-flow` 作为标识。
/// 该扩展集中所有 trae-flow 运行时路径，便于在 UI / 日志 / 诊断中引用。
extension TraeVariant {
    /// Bridge 命令行额外参数。与 TRAEFLOW 对齐：仅通过 `--client-name` 区分 Trae / Trae CN，
    /// 不再使用 `--variant` 参数。变体路由依赖终端 bundle ID（见 HookSocketServer）。
    var bridgeExtraArguments: [String] {
        ["--client-kind", "trae", "--client-name", displayName, "--client-originator", localAppName]
    }
}
