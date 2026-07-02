import Darwin
import Foundation

enum UserHomeDirectoryResolver {
    nonisolated static var hookConfigurationHomeDirectory: URL {
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `$HOME/.codex/pets/` —— codex CLI 已安装宠物目录
    /// 与 codex 共享同一目录约定：每个子目录 `<pet-id>/` 下放 `pet.json` 与 sprite sheet
    nonisolated static var codexPetsDirectory: URL {
        hookConfigurationHomeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
    }

    /// `$HOME/.traeflow/pets/` —— TRAE FLOW 用户自装宠物目录
    /// 优先级高于 codex 已安装主题包，用于让用户在不污染 codex 目录的前提下覆盖同名主题包
    nonisolated static var traeFlowPetsDirectory: URL {
        hookConfigurationHomeDirectory
            .appendingPathComponent(".traeflow", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
    }
}

enum HookProtocolFamily: Sendable {
    case traeHooks

    // 兼容旧持久化数据：旧 rawValue "claudeHooks" 仍解码为 .traeHooks
    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "traehooks", "claudehooks": self = .traeHooks
        default: return nil
        }
    }
}

enum SessionClientBrand: String, Codable, Equatable, Sendable {
    case trae
    case neutral
}

enum SessionAssistantLabelMode: String, Sendable {
    case providerDisplayName
    case badgeLabel
}

enum HookInstallEntryTemplate: Sendable {
    case plain
    case matcher(String)
}

enum ManagedHookInstallationKind: Sendable, Equatable {
    case jsonHooks
    case pluginFile
    case pluginDirectory
    case hookDirectory
    case tomlHooks
}

struct HookInstallEventDescriptor: Sendable {
    let name: String
    let templates: [HookInstallEntryTemplate]
    let timeout: Int?

    init(name: String, templates: [HookInstallEntryTemplate], timeout: Int? = nil) {
        self.name = name
        self.templates = templates
        self.timeout = timeout
    }

    nonisolated var category: HookInstallEventCategory {
        HookInstallEventCategory.category(forEventName: name)
    }
}

enum HookInstallEventCategory: String, CaseIterable, Sendable, Identifiable {
    case approvals
    case notifications
    case lifecycle
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approvals: return "审批"
        case .notifications: return "通知"
        case .lifecycle: return "生命周期"
        case .activity: return "活动追踪"
        }
    }

    var subtitle: String {
        switch self {
        case .approvals: return "工具调用审批与权限请求，可能需要用户回应"
        case .notifications: return "用户提示与通知事件"
        case .lifecycle: return "会话开始/结束与子任务事件"
        case .activity: return "工具完成、压缩等后台事件"
        }
    }

    var iconSymbolName: String {
        switch self {
        case .approvals: return "checkmark.shield.fill"
        case .notifications: return "bell.fill"
        case .lifecycle: return "circle.lefthalf.filled"
        case .activity: return "waveform.path"
        }
    }

    static func category(forEventName name: String) -> HookInstallEventCategory {
        switch name {
        case "PreToolUse", "PermissionRequest":
            return .approvals
        case "Notification", "UserPromptSubmit", "userPromptSubmitted":
            return .notifications
        case "SessionStart", "SessionEnd", "Stop", "SubagentStart", "SubagentStop",
             "BeforeAgent", "AfterAgent",
             "sessionStart", "sessionEnd", "agentStop", "subagentStop",
             "command:new", "command:reset", "command:stop":
            return .lifecycle
        case "PostToolUse", "PostToolUseFailure", "PreCompact", "PreCompress",
             "BeforeTool", "AfterTool",
             "preToolUse", "postToolUse", "errorOccurred",
             "message:received", "message:sent",
             "session:compact:before", "session:compact:after", "session:patch":
            return .activity
        default:
            return .activity
        }
    }
}

struct HookInstallSelection: Sendable, Equatable {
    var enabledEventNames: Set<String>

    static func defaultSelection(for profile: ManagedHookClientProfile) -> HookInstallSelection {
        HookInstallSelection(enabledEventNames: Set(profile.events.map(\.name)))
    }

    func filteredEvents(for profile: ManagedHookClientProfile) -> [HookInstallEventDescriptor] {
        profile.events.filter { enabledEventNames.contains($0.name) }
    }

    var isEmpty: Bool { enabledEventNames.isEmpty }
}

struct ManagedHookClientProfile: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let installationKind: ManagedHookInstallationKind
    let alwaysVisibleInSettings: Bool
    let logoAssetName: String?
    let prefersBundledLogoOverAppIcon: Bool
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String
    let configurationRelativePaths: [String]
    let activationConfigurationRelativePath: String?
    let activationEntryName: String?
    let bridgeSource: String
    let bridgeExtraArguments: [String]
    let defaultEnabled: Bool
    let brand: SessionClientBrand
    let events: [HookInstallEventDescriptor]
    let supportsOfficialTraeHook: Bool

    init(
        id: String,
        title: String,
        subtitle: String,
        installationKind: ManagedHookInstallationKind = .jsonHooks,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePath: String,
        activationConfigurationRelativePath: String? = nil,
        activationEntryName: String? = nil,
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor],
        supportsOfficialTraeHook: Bool = true
    ) {
        self.init(
            id: id,
            title: title,
            subtitle: subtitle,
            installationKind: installationKind,
            alwaysVisibleInSettings: alwaysVisibleInSettings,
            logoAssetName: logoAssetName,
            prefersBundledLogoOverAppIcon: prefersBundledLogoOverAppIcon,
            localAppBundleIdentifiers: localAppBundleIdentifiers,
            iconSymbolName: iconSymbolName,
            configurationRelativePaths: [configurationRelativePath],
            activationConfigurationRelativePath: activationConfigurationRelativePath,
            activationEntryName: activationEntryName,
            bridgeSource: bridgeSource,
            bridgeExtraArguments: bridgeExtraArguments,
            defaultEnabled: defaultEnabled,
            brand: brand,
            events: events,
            supportsOfficialTraeHook: supportsOfficialTraeHook
        )
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        installationKind: ManagedHookInstallationKind = .jsonHooks,
        alwaysVisibleInSettings: Bool = false,
        logoAssetName: String? = nil,
        prefersBundledLogoOverAppIcon: Bool = false,
        localAppBundleIdentifiers: [String] = [],
        iconSymbolName: String,
        configurationRelativePaths: [String],
        activationConfigurationRelativePath: String? = nil,
        activationEntryName: String? = nil,
        bridgeSource: String,
        bridgeExtraArguments: [String],
        defaultEnabled: Bool,
        brand: SessionClientBrand,
        events: [HookInstallEventDescriptor],
        supportsOfficialTraeHook: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.installationKind = installationKind
        self.alwaysVisibleInSettings = alwaysVisibleInSettings
        self.logoAssetName = logoAssetName
        self.prefersBundledLogoOverAppIcon = prefersBundledLogoOverAppIcon
        self.localAppBundleIdentifiers = localAppBundleIdentifiers
        self.iconSymbolName = iconSymbolName
        self.configurationRelativePaths = configurationRelativePaths
        self.activationConfigurationRelativePath = activationConfigurationRelativePath
        self.activationEntryName = activationEntryName
        self.bridgeSource = bridgeSource
        self.bridgeExtraArguments = bridgeExtraArguments
        self.defaultEnabled = defaultEnabled
        self.brand = brand
        self.events = events
        self.supportsOfficialTraeHook = supportsOfficialTraeHook
    }

    nonisolated var configurationURLs: [URL] {
        configurationURLs(homeDirectory: UserHomeDirectoryResolver.hookConfigurationHomeDirectory)
    }

    nonisolated var primaryConfigurationURL: URL {
        configurationURLs[0]
    }

    nonisolated var activationConfigurationURL: URL? {
        guard let activationConfigurationRelativePath else {
            return nil
        }
        return Self.resolveConfigurationURL(relativePath: activationConfigurationRelativePath)
    }

    nonisolated func configurationURLs(homeDirectory: URL) -> [URL] {
        configurationRelativePaths.map {
            Self.resolveConfigurationURL(relativePath: $0, homeDirectory: homeDirectory)
        }
    }

    nonisolated func primaryConfigurationURL(homeDirectory: URL) -> URL {
        configurationURLs(homeDirectory: homeDirectory)[0]
    }

    nonisolated func activationConfigurationURL(homeDirectory: URL) -> URL? {
        guard let activationConfigurationRelativePath else {
            return nil
        }
        return Self.resolveConfigurationURL(
            relativePath: activationConfigurationRelativePath,
            homeDirectory: homeDirectory
        )
    }

    nonisolated var supportsEventSelection: Bool {
        installationKind == .jsonHooks && !events.isEmpty
    }

    nonisolated var availableEventCategories: [HookInstallEventCategory] {
        let present = Set(events.map(\.category))
        return HookInstallEventCategory.allCases.filter { present.contains($0) }
    }

    nonisolated func events(in category: HookInstallEventCategory) -> [HookInstallEventDescriptor] {
        events.filter { $0.category == category }
    }

    nonisolated var reinstallDescriptionFormat: String {
        switch installationKind {
        case .jsonHooks:
            return "这会重新写入 %@ 的 TRAE FLOW hooks 配置，并保留其他非 TRAE FLOW hooks。"
        case .pluginFile:
            return "这会重新生成 %@ 的 TRAE FLOW 插件文件，并覆盖旧的 TRAE FLOW 托管版本。"
        case .pluginDirectory:
            return "这会重新生成 %@ 的 TRAE FLOW 插件目录，并覆盖旧的 TRAE FLOW 托管版本。"
        case .hookDirectory:
            return "这会重新生成 %@ 的 TRAE FLOW hook 目录。"
        case .tomlHooks:
            return "这会重新写入 %@ 的 TRAE FLOW hooks TOML 配置，并保留其他非 TRAE FLOW 设置。"
        }
    }

    nonisolated private static func resolveConfigurationURL(relativePath: String) -> URL {
        resolveConfigurationURL(
            relativePath: relativePath,
            homeDirectory: UserHomeDirectoryResolver.hookConfigurationHomeDirectory
        )
    }

    nonisolated private static func resolveConfigurationURL(
        relativePath: String,
        homeDirectory: URL
    ) -> URL {
        return relativePath
            .split(separator: "/")
            .reduce(homeDirectory) { partialURL, component in
                partialURL.appendingPathComponent(String(component))
            }
    }
}

struct SessionClientProfile: Identifiable, Sendable {
    let id: String
    let provider: SessionProvider
    let family: HookProtocolFamily
    let kind: SessionClientKind
    let displayName: String
    let assistantLabelMode: SessionAssistantLabelMode
    let brand: SessionClientBrand
    let defaultBundleIdentifier: String?
    let defaultOrigin: String?
    let recognizedKinds: Set<String>
    let exactAliases: Set<String>
    let keywordAliases: Set<String>
    let bundleIdentifiers: Set<String>

    nonisolated func matchScore(
        explicitKind: String?,
        explicitName: String?,
        explicitBundleIdentifier: String?,
        terminalBundleIdentifier: String?,
        origin: String?,
        originator: String?,
        threadSource: String?,
        processName: String?
    ) -> Int {
        var score = 0

        if let normalizedKind = Self.normalize(explicitKind), recognizedKinds.contains(normalizedKind) {
            score += 100
        }

        let bundleCandidates = [explicitBundleIdentifier, terminalBundleIdentifier]
            .compactMap(Self.normalize)
        if bundleCandidates.contains(where: bundleIdentifiers.contains) {
            score += 90
        }

        let exactCandidates = [explicitName, originator, processName, origin, threadSource]
            .compactMap(Self.normalize)
        if exactCandidates.contains(where: exactAliases.contains) {
            score += 60
        }

        if exactCandidates.contains(where: containsKeywordAlias(_:)) {
            score += 20
        }

        return score
    }

    nonisolated func matchesLabelAlias(_ rawValue: String) -> Bool {
        guard let normalized = Self.normalize(rawValue) else {
            return false
        }
        return exactAliases.contains(normalized)
            || recognizedKinds.contains(normalized)
            || containsKeywordAlias(normalized)
    }

    nonisolated func labelAliasScore(_ rawValue: String) -> Int {
        guard let normalized = Self.normalize(rawValue) else {
            return 0
        }
        if exactAliases.contains(normalized) || recognizedKinds.contains(normalized) {
            return 2
        }
        if containsKeywordAlias(normalized) {
            return 1
        }
        return 0
    }

    nonisolated private func containsKeywordAlias(_ normalizedValue: String) -> Bool {
        keywordAliases.contains { normalizedValue.contains($0) }
    }

    nonisolated private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

enum ClientProfileRegistry {
    // 四个 managedHookProfile 覆盖全部四个 TRAE 变体，每个变体写入独立的 hooks.json：
    // - trae-hooks      覆盖 Trae      （com.trae.app），      写入 ~/.trae/hooks.json
    // - trae-cn-hooks   覆盖 Trae CN   （cn.trae.app），       写入 ~/.trae-cn/hooks.json
    // - trae-solo-hooks 覆盖 TRAE SOLO （com.trae.solo.app）， 写入 ~/.trae-solo/hooks.json
    // - trae-solo-cn-hooks 覆盖 TRAE SOLO CN（cn.trae.solo.app），写入 ~/.trae-solo-cn/hooks.json
    // TRAE SOLO / TRAE SOLO CN 即 Spec 中的 TRAE Work / TRAE Work CN（本地 .app 名为 TRAE SOLO）。
    // 变体区分通过 bridge 命令的 `--client-name` 与终端 bundle ID 完成，不再使用 `--variant` 参数。
    nonisolated static let managedHookProfiles: [ManagedHookClientProfile] = [
        ManagedHookClientProfile(
            id: "trae-hooks",
            title: "Trae",
            subtitle: "管理 ~/.trae/hooks.json，按 Trae 官方 Hook 协议接入 Trae",
            alwaysVisibleInSettings: true,
            localAppBundleIdentifiers: [
                "com.trae.app"
            ],
            iconSymbolName: "bolt.square.fill",
            configurationRelativePath: ".trae/hooks.json",
            bridgeSource: "trae",
            bridgeExtraArguments: [
                "--client-kind", "trae",
                "--client-name", "Trae",
                "--client-originator", "Trae"
            ],
            defaultEnabled: true,
            brand: .trae,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ],
            supportsOfficialTraeHook: true
        ),
        ManagedHookClientProfile(
            id: "trae-cn-hooks",
            title: "Trae CN",
            subtitle: "管理 ~/.trae-cn/hooks.json，按 Trae 官方 Hook 协议接入 Trae CN",
            alwaysVisibleInSettings: true,
            localAppBundleIdentifiers: [
                "cn.trae.app"
            ],
            iconSymbolName: "bolt.square.fill",
            configurationRelativePath: ".trae-cn/hooks.json",
            bridgeSource: "trae",
            bridgeExtraArguments: [
                "--client-kind", "trae",
                "--client-name", "Trae CN",
                "--client-originator", "Trae CN"
            ],
            defaultEnabled: true,
            brand: .trae,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ],
            supportsOfficialTraeHook: true
        ),
        ManagedHookClientProfile(
            id: "trae-solo-hooks",
            title: "TRAE Work",
            subtitle: "管理 ~/.trae-solo/hooks.json，按 Trae 官方 Hook 协议接入 TRAE Work",
            alwaysVisibleInSettings: false,
            localAppBundleIdentifiers: [
                "com.trae.solo.app"
            ],
            iconSymbolName: "bolt.square.fill",
            configurationRelativePath: ".trae-solo/hooks.json",
            bridgeSource: "trae",
            bridgeExtraArguments: [
                "--client-kind", "trae",
                "--client-name", "TRAE Work",
                "--client-originator", "TRAE SOLO"
            ],
            defaultEnabled: true,
            brand: .trae,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ],
            supportsOfficialTraeHook: false
        ),
        ManagedHookClientProfile(
            id: "trae-solo-cn-hooks",
            title: "TRAE Work CN",
            subtitle: "管理 ~/.trae-solo-cn/hooks.json，按 Trae 官方 Hook 协议接入 TRAE Work CN",
            alwaysVisibleInSettings: false,
            localAppBundleIdentifiers: [
                "cn.trae.solo.app"
            ],
            iconSymbolName: "bolt.square.fill",
            configurationRelativePath: ".trae-solo-cn/hooks.json",
            bridgeSource: "trae",
            bridgeExtraArguments: [
                "--client-kind", "trae",
                "--client-name", "TRAE Work CN",
                "--client-originator", "TRAE SOLO CN"
            ],
            defaultEnabled: true,
            brand: .trae,
            events: [
                HookInstallEventDescriptor(name: "SessionStart", templates: [.plain]),
                HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.plain]),
                HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Notification", templates: [.matcher("*")]),
                HookInstallEventDescriptor(name: "Stop", templates: [.plain]),
            ],
            supportsOfficialTraeHook: false
        ),
    ]

    // 与 TRAEFLOW 对齐：单个 runtimeProfile（id: "trae"）覆盖全部 TRAE 变体。
    // 变体区分（Trae / Trae CN / SOLO / Work）由 `clientInfo.bundleIdentifier` 经
    // `TraeVariant.fromBundleIdentifier` 解析，不再依赖 runtimeProfile id。
    nonisolated static let runtimeProfiles: [SessionClientProfile] = [
        SessionClientProfile(
            id: "trae",
            provider: .trae,
            family: .traeHooks,
            kind: .trae,
            displayName: "Trae",
            assistantLabelMode: .badgeLabel,
            brand: .trae,
            defaultBundleIdentifier: nil,
            defaultOrigin: "ide",
            recognizedKinds: [
                "trae", "trae-ide", "trae ide", "trae-ai", "trae ai",
                "trae-cn", "trae-cn-ide", "trae cn", "trae-cn-ai", "trae cn ai",
                "trae-solo", "trae solo",
                "trae-solo-cn", "trae solo cn",
                "trae-work", "trae work",
                "trae-work-cn", "trae work cn"
            ],
            exactAliases: [
                "trae", "trae-ide", "trae ide", "trae-ai", "trae ai",
                "trae-cn", "trae-cn-ide", "trae cn", "trae-cn-ai", "trae cn ai",
                "trae-solo", "trae solo",
                "trae-solo-cn", "trae solo cn",
                "trae-work", "trae work",
                "trae-work-cn", "trae work cn"
            ],
            keywordAliases: ["trae"],
            bundleIdentifiers: [
                "com.trae.app",
                "cn.trae.app",
                "com.trae.solo.app",
                "cn.trae.solo.app"
            ]
        ),
    ]

    nonisolated static func managedHookProfile(id: String) -> ManagedHookClientProfile? {
        managedHookProfiles.first { $0.id == id }
    }

    nonisolated static func runtimeProfile(id: String?) -> SessionClientProfile? {
        guard let id else { return nil }
        return runtimeProfiles.first { $0.id == id }
    }

    nonisolated static func defaultManagedHookProfileIDs() -> Set<String> {
        Set(managedHookProfiles.filter(\.defaultEnabled).map(\.id))
    }

    nonisolated static func defaultRuntimeProfile(for provider: SessionProvider, kind: SessionClientKind? = nil) -> SessionClientProfile? {
        runtimeProfile(id: "trae")
    }

    nonisolated static func matchRuntimeProfile(
        provider: SessionProvider,
        explicitKind: String?,
        explicitName: String?,
        explicitBundleIdentifier: String?,
        terminalBundleIdentifier: String?,
        origin: String?,
        originator: String?,
        threadSource: String?,
        processName: String?
    ) -> SessionClientProfile? {
        (
            runtimeProfiles
            .filter { $0.provider == provider }
            .map { profile in
                (
                    profile: profile,
                    score: profile.matchScore(
                        explicitKind: explicitKind,
                        explicitName: explicitName,
                        explicitBundleIdentifier: explicitBundleIdentifier,
                        terminalBundleIdentifier: terminalBundleIdentifier,
                        origin: origin,
                        originator: originator,
                        threadSource: threadSource,
                        processName: processName
                    )
                )
            }
            .filter { $0.score > 0 }
            .max { lhs, rhs in lhs.score < rhs.score }
        )?.profile
    }

    nonisolated static func canonicalDisplayName(
        for rawValue: String,
        provider: SessionProvider,
        kind: SessionClientKind
    ) -> String? {
        let profiles = runtimeProfiles.filter { $0.provider == provider || $0.kind == kind }
        return profiles
            .map { profile in
                (profile: profile, score: profile.labelAliasScore(rawValue))
            }
            .filter { $0.score > 0 }
            .max { lhs, rhs in lhs.score < rhs.score }?
            .profile
            .displayName
    }
}
