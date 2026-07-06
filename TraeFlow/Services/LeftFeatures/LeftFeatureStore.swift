import Combine
import Foundation
import SwiftUI

/// 左侧 Flow 岛"功能系统"注册中心
/// 管理内置功能（音乐 / 中转站）与自定义 HTML 区域功能的启用/禁用、排序、
/// 紧凑态与展开态各自的选择（`compactFeatureID` / `expandedActiveFeatureID`）。
/// 持久化：
/// - 功能列表 → `~/Library/Application Support/trae-flow/left-features.json`
/// - 紧凑态选择 → UserDefaults key `leftFeatureCompactID`
/// - 展开态选择 → UserDefaults key `leftFeatureExpandedActiveID`
@MainActor
final class LeftFeatureStore: ObservableObject {
    static let shared = LeftFeatureStore()

    /// 持久化文件位于 `~/Library/Application Support/trae-flow/left-features.json`
    private static var persistenceURL: URL {
        BridgeRuntimePaths.runtimeDirectoryURL
            .appendingPathComponent("left-features.json")
    }

    /// 当前所有功能项（按存储顺序，未排序）
    @Published private(set) var features: [LeftFeature] = []

    /// 紧凑态当前选中的功能 id；nil 表示"自动"（按自动规则解析）
    @Published var compactFeatureID: String? {
        didSet {
            defaults.set(compactFeatureID, forKey: Keys.compactFeatureID)
        }
    }

    /// 展开态当前激活的功能 id；nil 表示回退到第一个已启用功能
    @Published var expandedActiveFeatureID: String? {
        didSet {
            defaults.set(expandedActiveFeatureID, forKey: Keys.expandedActiveFeatureID)
        }
    }

    private let defaults: UserDefaults

    // MARK: - Keys

    private enum Keys {
        static let compactFeatureID = "leftFeatureCompactID"
        static let expandedActiveFeatureID = "leftFeatureExpandedActiveID"
    }

    /// 旧版 CustomAreaStore 的 UserDefaults 键，仅用于首次升级迁移
    private enum LegacyKeys {
        static let customAreaCompactID = "customAreaCompactID"
        static let customAreaExpandedID = "customAreaExpandedID"
        static let customAreaSelectedID = "customAreaSelectedID"
    }

    // MARK: - Computed Properties

    /// 已启用功能，按 `sortOrder` 升序排列
    var enabledFeatures: [LeftFeature] {
        features
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 紧凑态当前功能：
    /// 1. 若 `compactFeatureID` 解析到已启用功能 → 返回该功能
    /// 2. 否则走自动规则：
    ///    a. 音乐已启用且 `NowPlayingProvider.shared.nowPlaying?.isPlaying == true` → 音乐
    ///    b. 否则 `enabledFeatures.first`
    ///    c. 都无则 nil
    var compactFeature: LeftFeature? {
        // 1. 显式选择优先
        if let id = compactFeatureID,
           let feature = features.first(where: { $0.id == id && $0.isEnabled }) {
            return feature
        }
        // 2a. 音乐自动检测（NowPlayingProvider 由后续任务提供，此处为前向引用）
        if let music = features.first(where: { $0.kind == .music && $0.isEnabled }),
           NowPlayingProvider.shared.nowPlaying?.isPlaying == true {
            return music
        }
        // 2b. 第一个已启用功能
        return enabledFeatures.first
    }

    /// 展开态当前激活功能：
    /// 1. 若 `expandedActiveFeatureID` 解析到已启用功能 → 返回该功能
    /// 2. 指向已禁用/删除功能时回退到 `enabledFeatures.first`
    var expandedActiveFeature: LeftFeature? {
        if let id = expandedActiveFeatureID,
           let feature = features.first(where: { $0.id == id && $0.isEnabled }) {
            return feature
        }
        return enabledFeatures.first
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        compactFeatureID = defaults.string(forKey: Keys.compactFeatureID)
        expandedActiveFeatureID = defaults.string(forKey: Keys.expandedActiveFeatureID)
        migrateFromLegacy()
        ensureBuiltinNewsNowFeature()
        ensureBuiltinMineradioFeature()
    }

    // MARK: - Loading & Persistence

    private func load() {
        let url = Self.persistenceURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LeftFeature].self, from: data) else {
            // 首次启动：由 migrateFromLegacy 填充
            features = []
            return
        }
        features = decoded
    }

    private func persist() {
        let url = Self.persistenceURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(features)
            try data.write(to: url, options: [.atomic])
        } catch {
            // 持久化失败不应阻塞 UI；下次启动会重新尝试
        }
    }

    // MARK: - Legacy Migration

    /// 老用户迁移 —— 首次升级时（`left-features.json` 不存在）：
    /// 1. 创建内置音乐 / 中转站功能
    /// 2. 为每个 CustomArea 创建对应功能
    /// 3. 迁移旧 UserDefaults 键（customAreaCompactID / customAreaExpandedID / customAreaSelectedID）
    /// 4. 清除旧键并持久化
    /// 幂等：若 `left-features.json` 已存在则跳过
    private func migrateFromLegacy() {
        let url = Self.persistenceURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        // 1. 内置功能：音乐 (sortOrder: 0) / 中转站 (sortOrder: 1) / NewsNow (sortOrder: 2) / Mineradio (sortOrder: 3)
        // 设置较小的默认展开高度，避免展开时占用过多屏幕空间
        features = [
            LeftFeature(
                id: LeftFeature.musicID,
                kind: .music,
                isEnabled: true,
                sortOrder: 0,
                expandedHeight: 280
            ),
            LeftFeature(
                id: LeftFeature.shelfID,
                kind: .shelf,
                isEnabled: true,
                sortOrder: 1,
                expandedHeight: 280
            ),
            LeftFeature(
                id: LeftFeature.newsnowID,
                kind: .newsnow(baseURL: "https://newsnow.busiyi.world"),
                isEnabled: true,
                sortOrder: 2,
                expandedHeight: 420
            ),
            LeftFeature(
                id: LeftFeature.mineradioID,
                kind: .mineradio(pageURL: "https://mineradio.art/"),
                isEnabled: true,
                sortOrder: 3,
                expandedWidth: 900,
                expandedHeight: 600
            )
        ]

        // 2. 为每个 CustomArea 创建功能（按 sortOrder 降序，与 CustomAreaStore.load 排序一致）
        // mineradio 占用 sortOrder 3，自定义区域从 4 起步
        let sortedAreas = CustomAreaStore.shared.areas.sorted { $0.sortOrder > $1.sortOrder }
        for (index, area) in sortedAreas.enumerated() {
            features.append(LeftFeature(
                kind: .customArea(areaID: area.id),
                isEnabled: true,
                sortOrder: 4 + index
            ))
        }

        // 3. 迁移旧 UserDefaults 键
        // 3a. customAreaCompactID → compactFeatureID
        if let legacyCompactAreaID = defaults.string(forKey: LegacyKeys.customAreaCompactID) {
            if let feature = features.first(where: {
                if case .customArea(let areaID) = $0.kind { return areaID == legacyCompactAreaID }
                return false
            }) {
                compactFeatureID = feature.id
            }
        }

        // 3b. customAreaExpandedID 或 customAreaSelectedID → expandedActiveFeatureID
        let legacyExpandedAreaID = defaults.string(forKey: LegacyKeys.customAreaExpandedID)
            ?? defaults.string(forKey: LegacyKeys.customAreaSelectedID)
        if let legacyExpandedAreaID {
            if let feature = features.first(where: {
                if case .customArea(let areaID) = $0.kind { return areaID == legacyExpandedAreaID }
                return false
            }) {
                expandedActiveFeatureID = feature.id
            }
        }

        // 4. 清除旧键
        defaults.removeObject(forKey: LegacyKeys.customAreaCompactID)
        defaults.removeObject(forKey: LegacyKeys.customAreaExpandedID)
        defaults.removeObject(forKey: LegacyKeys.customAreaSelectedID)

        // 5. 持久化 features 与新选择键
        persist()
    }

    /// 老用户升级幂等追加：若 features 不含 id == newsnowID 的项则追加默认 newsnow 功能。
    /// 已存在则不动（保留用户编辑过的 baseURL / isEnabled / sortOrder）。
    /// 在 init 末尾 load() 之后调用。
    /// Spec: 内置 newsnow 功能自动获取网站 favicon（若 customIconName 为 nil）
    private func ensureBuiltinNewsNowFeature() {
        if features.contains(where: { $0.id == LeftFeature.newsnowID }) {
            // 已存在：补获 favicon（若未设置自定义图标）
            fetchBuiltinFaviconIfNeeded(LeftFeature.newsnowID)
            return
        }
        let maxSortOrder = features.map(\.sortOrder).max() ?? -1
        features.append(LeftFeature(
            id: LeftFeature.newsnowID,
            kind: .newsnow(baseURL: "https://newsnow.busiyi.world"),
            isEnabled: true,
            sortOrder: maxSortOrder + 1,
            expandedHeight: 420
        ))
        persist()
        fetchBuiltinFaviconIfNeeded(LeftFeature.newsnowID)
    }

    /// 老用户升级幂等追加：若 features 不含 id == mineradioID 的项则追加默认 mineradio 功能。
    /// 已存在则不动（保留用户编辑过的 pageURL / isEnabled / sortOrder）。
    /// Spec: mineradio-bridge-compat-layer
    /// Spec: 内置 mineradio 功能自动获取网站 favicon（若 customIconName 为 nil）
    private func ensureBuiltinMineradioFeature() {
        if let idx = features.firstIndex(where: { $0.id == LeftFeature.mineradioID }) {
            // 已存在：确保 kind 是 .mineradio(pageURL:)（兼容未来可能的 kind 变更）
            if case .mineradio = features[idx].kind {
                // 补获 favicon（若未设置自定义图标）
                fetchBuiltinFaviconIfNeeded(LeftFeature.mineradioID)
                return
            }
            // kind 不匹配，重写为默认 pageURL
            features[idx].kind = .mineradio(pageURL: "https://mineradio.art/")
            persist()
            fetchBuiltinFaviconIfNeeded(LeftFeature.mineradioID)
            return
        }
        let maxSortOrder = features.map(\.sortOrder).max() ?? -1
        features.append(LeftFeature(
            id: LeftFeature.mineradioID,
            kind: .mineradio(pageURL: "https://mineradio.art/"),
            isEnabled: true,
            sortOrder: maxSortOrder + 1,
            expandedWidth: 900,
            expandedHeight: 600
        ))
        persist()
        fetchBuiltinFaviconIfNeeded(LeftFeature.mineradioID)
    }

    /// Spec: 为内置 newsnow/mineradio 功能自动获取网站 favicon。
    /// 仅当 `customIconName` 为 nil 时触发（首次安装或老用户升级时补获）。
    /// 已获取过 favicon（`img:favicon-` 前缀）或用户已自定义图标则跳过，避免每次启动发网络请求。
    private func fetchBuiltinFaviconIfNeeded(_ featureID: String) {
        guard let feature = features.first(where: { $0.id == featureID }) else { return }
        // 已有图标（favicon 或用户自定义）则跳过
        if let icon = feature.customIconName, !icon.isEmpty {
            return
        }
        let url: URL?
        switch feature.kind {
        case .newsnow(let baseURL):
            url = URL(string: baseURL)
        case .mineradio(let pageURL):
            url = URL(string: pageURL)
        default:
            return
        }
        guard let url = url else { return }
        fetchFaviconForFeature(id: featureID, url: url)
    }

    // MARK: - Mutation API

    /// 启用/禁用某个功能
    func setFeatureEnabled(id: String, isEnabled: Bool) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        // Spec: 禁用远程 URL / Mineradio 功能时驱逐保活缓存，避免 WKWebView 残留占用资源
        if !isEnabled {
            switch features[index].kind {
            case .webURL(let urlString):
                if let url = URL(string: urlString) {
                    CustomAreaWebViewCache.shared.evict(for: url)
                }
            case .mineradio(let pageURL):
                if let url = URL(string: pageURL) {
                    CustomAreaWebViewCache.shared.evict(for: url)
                }
            default:
                break
            }
        }
        features[index].isEnabled = isEnabled
        persist()
    }

    /// 重排功能顺序；重排后按新顺序重写所有 `sortOrder`
    /// `source` 为待移动元素的原始索引集合，`destination` 为目标位置
    /// （遵循 SwiftUI `.onMove` 的语义：destination 指向插入后的起始索引）。
    func moveFeature(from source: IndexSet, to destination: Int) {
        features.move(fromOffsets: source, toOffset: destination)
        for (index, _) in features.enumerated() {
            features[index].sortOrder = index
        }
        persist()
    }

    /// 设置紧凑态当前功能；nil 表示"自动"
    func setCompactFeature(id: String?) {
        compactFeatureID = id
    }

    /// 设置展开态当前激活功能；nil 表示回退到第一个已启用功能
    func setExpandedActiveFeature(id: String?) {
        expandedActiveFeatureID = id
    }

    /// 为自定义 HTML 区域追加对应功能（由 CustomAreaStore.addArea 联动调用）。
    /// `isEnabled` 默认 true；预设注入时（如「TRAE Flow 演示」）可传 false 使其默认不启用。
    func appendCustomAreaFeature(areaID: String, isEnabled: Bool = true) {
        let maxSortOrder = features.map(\.sortOrder).max() ?? -1
        features.append(LeftFeature(
            kind: .customArea(areaID: areaID),
            isEnabled: isEnabled,
            sortOrder: maxSortOrder + 1
        ))
        persist()
    }

    /// 移除自定义 HTML 区域对应功能（由 CustomAreaStore.removeArea 联动调用）
    /// 若 `compactFeatureID` / `expandedActiveFeatureID` 指向被移除的功能则置 nil
    func removeCustomAreaFeature(areaID: String) {
        // 找到被移除的 feature id 集合
        let removedFeatureIDs = Set(
            features.compactMap { feature -> String? in
                if case .customArea(let id) = feature.kind, id == areaID {
                    return feature.id
                }
                return nil
            }
        )
        guard !removedFeatureIDs.isEmpty else { return }

        // 移除
        features.removeAll { removedFeatureIDs.contains($0.id) }

        // 若选择指向被移除的功能，置 nil
        if let compactID = compactFeatureID, removedFeatureIDs.contains(compactID) {
            compactFeatureID = nil
        }
        if let expandedID = expandedActiveFeatureID, removedFeatureIDs.contains(expandedID) {
            expandedActiveFeatureID = nil
        }

        persist()
    }

    // MARK: - Web URL Feature API

    /// 新建 URL 网站功能项。
    /// `variant` 参数当前对 `.webURL` 无实际用途（仅 `.customArea` 用 `defaultVariant` 跳转 IDE），
    /// 保留参数以便新建/编辑表单对两种类型统一调用，此处忽略。
    ///
    /// Spec: 若 `iconName` 为 nil（用户未指定自定义图标），则异步获取网站 favicon 并写入 `customIconName`。
    /// 失败时不写入，回退到 `systemImage` 默认文字图标「U」。
    @discardableResult
    func appendWebURLFeature(name: String, url: String, iconName: String?, variant: TraeVariant) -> LeftFeature {
        let maxSortOrder = features.map(\.sortOrder).max() ?? -1
        let feature = LeftFeature(
            kind: .webURL(url: url),
            isEnabled: true,
            sortOrder: maxSortOrder + 1,
            customIconName: iconName,
            customDisplayName: name
        )
        features.append(feature)
        persist()

        // Spec: 自动获取 favicon（仅当用户未指定自定义图标时）
        if iconName == nil, let url = URL(string: url) {
            fetchFaviconForFeature(id: feature.id, url: url)
        }
        return feature
    }

    /// 编辑 URL 功能元数据。
    /// 仅传入非 nil 的字段才会被更新；`variant` 参数当前忽略（见 `appendWebURLFeature`）。
    ///
    /// Spec: URL 变化时若当前图标是自动获取的 favicon（`img:favicon-` 前缀），清空 `customIconName` 并触发重新获取；
    /// 用户显式设置过 `iconName`（非 favicon 前缀）则保留不动。
    func updateWebURLFeature(id: String,
                             name: String?,
                             url: String?,
                             iconName: String?,
                             variant: TraeVariant?) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        var copy = features[index]
        if let name { copy.customDisplayName = name }

        var urlChanged = false
        var newURLString: String?
        if let url {
            if case .webURL(let oldURLString) = copy.kind {
                if oldURLString != url {
                    urlChanged = true
                }
                // Spec: URL 变化时驱逐旧 URL 的保活缓存，避免残留 WKWebView
                if let oldURL = URL(string: oldURLString) {
                    CustomAreaWebViewCache.shared.evict(for: oldURL)
                }
            }
            copy.kind = .webURL(url: url)
            newURLString = url
        }

        // iconName 显式传入（非 nil）才覆盖；nil 表示用户未在表单修改图标字段
        if let iconName {
            copy.customIconName = iconName
        }

        // Spec: URL 变化且用户未显式传 iconName 时，清掉自动获取的 favicon 以触发重新获取
        var needsRefetch = false
        if urlChanged, iconName == nil,
           let currentIcon = copy.customIconName,
           currentIcon.hasPrefix("img:favicon-") {
            copy.customIconName = nil
            needsRefetch = true
        }

        features[index] = copy
        persist()

        if needsRefetch, let urlString = newURLString, let url = URL(string: urlString) {
            fetchFaviconForFeature(id: id, url: url)
        }
    }

    /// 删除 URL 功能项；若 `compactFeatureID` / `expandedActiveFeatureID` 指向被删功能则置 nil
    func removeWebURLFeature(id: String) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        // Spec: 驱逐该 URL 的保活缓存，释放 WKWebView
        if case .webURL(let urlString) = features[index].kind,
           let url = URL(string: urlString) {
            CustomAreaWebViewCache.shared.evict(for: url)
        }
        features.remove(at: index)
        if compactFeatureID == id { compactFeatureID = nil }
        if expandedActiveFeatureID == id { expandedActiveFeatureID = nil }
        persist()
    }

    /// Spec: 异步获取网站 favicon 并写入 `customIconName`。
    /// 主线程回调，避免非主线程修改 @Published。失败时不写入（回退到默认文字图标）。
    /// 仅当当前 `customIconName` 为 nil 或仍是自动获取的 favicon（`img:favicon-` 前缀）时才覆盖，
    /// 避免覆盖用户显式设置的图标。
    private func fetchFaviconForFeature(id: String, url: URL) {
        FaviconFetcher.fetch(for: url) { [weak self] iconID in
            guard let self, let iconID else { return }
            guard let index = self.features.firstIndex(where: { $0.id == id }) else { return }
            let current = self.features[index].customIconName
            // 仅当未设置图标，或当前图标是自动获取的 favicon 时覆盖
            let shouldApply = current == nil
                || (current?.hasPrefix("img:favicon-") ?? false)
            guard shouldApply else { return }
            self.features[index].customIconName = iconID
            self.persist()
        }
    }

    // MARK: - NewsNow Feature API

    /// 更新内置 NewsNow 功能的实例 baseURL。
    /// 仅当该 feature 为 `.newsnow` 时重写 kind 并 persist；非 `.newsnow` 调用无效。
    func updateNewsNowBaseURL(id: String, baseURL: String) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        guard case .newsnow = features[index].kind else { return }
        features[index].kind = .newsnow(baseURL: baseURL)
        persist()
    }

    // MARK: - Mineradio Feature API

    /// 更新内置 Mineradio 功能的 pageURL。
    /// 仅当该 feature 为 `.mineradio` 时重写 kind 并 persist；非 `.mineradio` 调用无效。
    /// Spec: mineradio-bridge-compat-layer
    func updateMineradioPageURL(id: String, pageURL: String) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        guard case .mineradio(let oldPageURL) = features[index].kind else { return }
        // Spec: pageURL 变化时驱逐旧 URL 的保活缓存，避免残留 WKWebView
        if let oldURL = URL(string: oldPageURL) {
            CustomAreaWebViewCache.shared.evict(for: oldURL)
        }
        features[index].kind = .mineradio(pageURL: pageURL)
        persist()
    }

    // MARK: - Generic Icon / Display Name Overrides

    /// 通用：设置任意功能的自定义图标名（覆盖 kind 默认图标，适用所有 kind）。
    /// 传 nil 清除覆盖，回退 kind 默认。
    func setCustomIconName(id: String, name: String?) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        features[index].customIconName = name
        persist()
    }

    /// 通用：设置任意功能的自定义显示名。
    /// 当前仅 `.webURL` 在 `displayName` getter 中读取该字段；
    /// 其他 kind 设置该字段不会影响显示，但会持久化以便未来扩展。
    func setCustomDisplayName(id: String, name: String?) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        features[index].customDisplayName = name
        persist()
    }

    /// 设置功能的自定义展开尺寸；传 nil 清除覆盖，回退全局 `Settings.expandedPanelWidth` / `maxPanelHeight`
    func setExpandedSize(id: String, width: Double?, height: Double?) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        features[index].expandedWidth = width
        features[index].expandedHeight = height
        persist()
    }

    /// 设置功能的「展开即固定」开关；true = 切换到该功能时面板自动 pin
    func setExpandedPinned(id: String, pinned: Bool) {
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        features[index].expandedPinned = pinned
        persist()
    }
}
