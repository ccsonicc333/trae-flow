import SwiftUI
import UniformTypeIdentifiers

/// 自定义区域 / 网站 URL / 内置功能编辑表单。
/// 在设置页功能列表的「编辑」按钮以及添加 sheet 中复用。
/// 通过 `EditMode` 区分三种字段集：
/// - `.customArea`: 本地目录（名称 / 图标 / 网络开关）
/// - `.webURL`: 网站 URL（名称 / 图标 / URL）
/// - `.builtin`: 内置功能 music/shelf（名称 / 图标）
struct EditableCustomAreaView: View {
    /// 编辑模式
    enum EditMode {
        case customArea(CustomArea)
        case webURL(feature: LeftFeature)
        case builtin(feature: LeftFeature)
    }

    @State private var mode: EditMode
    @Environment(\.dismiss) private var dismiss
    private let onSaveCustomArea: (CustomArea) -> Void
    private let onSaveWebURL: (LeftFeature) -> Void
    private let onSaveBuiltin: (LeftFeature) -> Void

    // 共享字段
    @State private var name: String
    // 图标：文字输入 / 图片标识符二选一（图片优先）
    @State private var iconText: String
    @State private var iconImage: String?
    @State private var showingIconImagePicker = false
    @State private var iconImageError: String?

    // customArea 模式专用
    @State private var allowsNetwork: Bool

    // webURL 模式专用
    @State private var url: String

    // 展开尺寸 + 固定开关（两模式共用）
    @State private var expandedPinned: Bool
    @State private var useCustomExpandedSize: Bool
    @State private var expandedWidth: Double
    @State private var expandedHeight: Double

    // Spec: webURL 模式自动获取图标/名称的 debounce state
    @State private var metadataFetchToken: UUID?
    @State private var autoFilledName: String?
    @State private var autoFilledIconImage: String?
    @State private var isFetchingMetadata = false

    /// 本地目录模式初始化
    init(area: CustomArea, onSave: @escaping (CustomArea) -> Void) {
        _mode = State(initialValue: .customArea(area))
        self.onSaveCustomArea = onSave
        self.onSaveWebURL = { _ in }
        self.onSaveBuiltin = { _ in }
        _name = State(initialValue: area.name)
        let parsed = Self.parseIconID(area.iconName)
        _iconText = State(initialValue: parsed.text)
        _iconImage = State(initialValue: parsed.image)
        _allowsNetwork = State(initialValue: area.allowsNetworkAccess)
        _url = State(initialValue: "")
        // 从 LeftFeatureStore 查 areaID 对应 feature 的展开尺寸/固定字段
        let feature = LeftFeatureStore.shared.features.first {
            if case .customArea(let areaID) = $0.kind { return areaID == area.id }
            return false
        }
        _expandedPinned = State(initialValue: feature?.expandedPinned ?? false)
        _useCustomExpandedSize = State(initialValue: feature?.expandedWidth != nil)
        _expandedWidth = State(initialValue: feature?.expandedWidth ?? AppSettings.shared.expandedPanelWidth)
        _expandedHeight = State(initialValue: feature?.expandedHeight ?? AppSettings.shared.maxPanelHeight)
    }

    /// 网站 URL 功能模式初始化
    init(feature: LeftFeature, onSave: @escaping (LeftFeature) -> Void) {
        _mode = State(initialValue: .webURL(feature: feature))
        self.onSaveCustomArea = { _ in }
        self.onSaveWebURL = onSave
        self.onSaveBuiltin = { _ in }
        _name = State(initialValue: feature.customDisplayName ?? "")
        let parsed = Self.parseIconID(feature.customIconName)
        _iconText = State(initialValue: parsed.text)
        _iconImage = State(initialValue: parsed.image)
        _allowsNetwork = State(initialValue: false)
        _url = State(initialValue: {
            if case .webURL(let u) = feature.kind { return u }
            return ""
        }())
        _expandedPinned = State(initialValue: feature.expandedPinned)
        _useCustomExpandedSize = State(initialValue: feature.expandedWidth != nil)
        _expandedWidth = State(initialValue: feature.expandedWidth ?? AppSettings.shared.expandedPanelWidth)
        _expandedHeight = State(initialValue: feature.expandedHeight ?? AppSettings.shared.maxPanelHeight)
        // Spec: 若已有图标是自动获取的 favicon（img:favicon- 前缀），记为 autoFilledIconImage，
        // 这样 URL 变化时允许覆盖；用户手动设置的图标不会被覆盖。
        if let img = parsed.image, img.hasPrefix("img:favicon-") {
            _autoFilledIconImage = State(initialValue: img)
        }
    }

    /// 内置功能（music / shelf）模式初始化
    init(builtinFeature feature: LeftFeature, onSave: @escaping (LeftFeature) -> Void) {
        _mode = State(initialValue: .builtin(feature: feature))
        self.onSaveCustomArea = { _ in }
        self.onSaveWebURL = { _ in }
        self.onSaveBuiltin = onSave
        // 内置功能无 customDisplayName 时回退到默认名，避免 name 为空导致保存按钮 disabled
        let defaultName: String
        switch feature.kind {
        case .music: defaultName = "音乐"
        case .shelf: defaultName = "中转站"
        case .newsnow: defaultName = "热点新闻"
        case .mineradio: defaultName = "Mineradio"
        default: defaultName = ""
        }
        _name = State(initialValue: feature.customDisplayName ?? defaultName)
        let parsed = Self.parseIconID(feature.customIconName)
        _iconText = State(initialValue: parsed.text)
        _iconImage = State(initialValue: parsed.image)
        _allowsNetwork = State(initialValue: false)
        _url = State(initialValue: "")
        _expandedPinned = State(initialValue: feature.expandedPinned)
        _useCustomExpandedSize = State(initialValue: feature.expandedWidth != nil)
        _expandedWidth = State(initialValue: feature.expandedWidth ?? AppSettings.shared.expandedPanelWidth)
        _expandedHeight = State(initialValue: feature.expandedHeight ?? AppSettings.shared.maxPanelHeight)
    }

    /// 解析已有图标标识符为 (text, image) 二元组：
    /// - `img:xxx` → text="", image=iconID（图片优先，文本清空）
    /// - `text:xxx` → text=去掉前缀的内容, image=nil
    /// - 其他（含 nil / 无前缀旧值）→ text=原值, image=nil
    private static func parseIconID(_ iconID: String?) -> (text: String, image: String?) {
        guard let id = iconID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return ("", nil)
        }
        if id.hasPrefix("img:") {
            return ("", id)
        }
        if id.hasPrefix("text:") {
            return (String(id.dropFirst(5)), nil)
        }
        return (id, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.headline)

            // Spec: 按模式渲染不同字段顺序
            switch mode {
            case .customArea:
                // 本地目录：图标 → 名称 → 网络开关
                iconRow
                nameRow
                Toggle("允许请求外部接口", isOn: $allowsNetwork)
                    .font(.caption)

            case .webURL:
                // Spec: webURL 模式 URL 放第一位 → 名称 → 图标
                urlRow
                nameRow
                iconRow

            case .builtin:
                // 内置功能：图标 → 名称
                iconRow
                nameRow
            }

            // 展开尺寸 + 固定开关（所有模式共用）
            VStack(alignment: .leading, spacing: 8) {
                Toggle("展开即固定", isOn: $expandedPinned)
                    .font(.caption)
                Toggle("自定义展开尺寸", isOn: $useCustomExpandedSize)
                    .font(.caption)
                if useCustomExpandedSize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("展开宽度：\(Int(expandedWidth)) pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $expandedWidth, in: 470...1600, step: 10)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("展开高度：\(Int(expandedHeight)) pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $expandedHeight, in: 200...1000, step: 10)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .fileImporter(
            isPresented: $showingIconImagePicker,
            allowedContentTypes: [UTType.image]
        ) { result in
            switch result {
            case .success(let url):
                iconImageError = nil
                Task { @MainActor in
                    let didStartAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        let ext = url.pathExtension
                        // 编辑场景：用 name 字段做文件名（兜底 "icon"）
                        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let featureID = safeName.isEmpty ? "icon-\(UUID().uuidString.prefix(8))" : safeName
                        if let iconID = IconImageStore.saveImage(
                            data: data,
                            for: featureID,
                            ext: ext
                        ) {
                            iconImage = iconID
                            // 选了图片后清空文字输入，避免歧义
                            iconText = ""
                        } else {
                            iconImageError = "图片保存失败"
                        }
                    } catch {
                        iconImageError = "读取图片失败：\(error.localizedDescription)"
                    }
                }
            case .failure:
                break
            }
        }
    }

    // MARK: - Helpers

    /// Spec: URL 输入行（webURL 模式第一位）。URL 合法时 debounce 600ms 后自动获取网站 favicon + 标题。
    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isFetchingMetadata {
                    ProgressView()
                        .controlSize(.mini)
                    Text("获取图标和名称…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            TextField("https://example.com", text: $url)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onChange(of: url) { newValue in
                    scheduleMetadataFetch(for: newValue)
                }
            if !url.isEmpty, !isURLValid {
                Text("请输入合法的 http 或 https 链接")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// 名称输入行。
    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("名称")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// 图标输入行（文字 + 图片选择 + 实时预览）。
    private var iconRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("图标")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                FeatureIconView(iconID: resolvedIconID, fallbackSymbol: "globe", size: 18, color: .accentColor)
                    .frame(width: 22)
                TextField("输入文字或选择图片", text: $iconText)
                    .textFieldStyle(.roundedBorder)
                Button("选择图片…") {
                    showingIconImagePicker = true
                }
                if iconImage != nil {
                    Button("删除图片") {
                        iconImage = nil
                        autoFilledIconImage = nil
                        iconImageError = nil
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            if let iconImageError {
                Text(iconImageError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// Spec: debounce 600ms 后触发 `FaviconFetcher.fetchMetadata`。
    /// 名称覆盖规则：当前名称为空，或等于上次自动填入的 `autoFilledName` 时才覆盖；
    /// 用户手动修改过则保留。
    /// 图标覆盖规则：当前无图片，或图片等于上次自动填入的 `autoFilledIconImage` 时才覆盖；
    /// 用户手动选择过图片则保留。
    private func scheduleMetadataFetch(for urlString: String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            isFetchingMetadata = false
            return
        }
        let token = UUID()
        metadataFetchToken = token
        isFetchingMetadata = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard token == metadataFetchToken else { return }
            FaviconFetcher.fetchMetadata(for: url) { metadata in
                guard token == metadataFetchToken else { return }
                isFetchingMetadata = false
                // 名称：仅当为空或等于上次自动填入值时覆盖
                if let title = metadata.title, !title.isEmpty {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedName.isEmpty || trimmedName == autoFilledName {
                        name = title
                        autoFilledName = title
                    }
                }
                // 图标：仅当无图片或图片是上次自动填入的 favicon 时覆盖
                if let iconID = metadata.iconID {
                    if iconImage == nil || iconImage == autoFilledIconImage {
                        iconImage = iconID
                        autoFilledIconImage = iconID
                        iconText = ""
                    }
                }
            }
        }
    }

    private var titleText: String {
        switch mode {
        case .customArea: return "编辑自定义功能"
        case .webURL: return "编辑网站功能"
        case .builtin: return "编辑内置功能"
        }
    }

    /// 图标预览标识符：图片优先，否则文字加 text: 前缀；均空返回 nil（FeatureIconView 回退 globe）
    private var resolvedIconID: String? {
        if let img = iconImage { return img }
        let trimmed = iconText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "text:\(trimmed)"
    }

    /// URL 合法性校验（仅 webURL 模式使用）。
    private var isURLValid: Bool {
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return true
    }

    /// 表单「保存」按钮可用条件：名称非空；webURL 模式 URL 需合法。
    /// builtin 模式名称可为空（回退默认名），仅校验图标/展开设置。
    private var isFormValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .customArea:
            guard !trimmedName.isEmpty else { return false }
            return true
        case .builtin:
            return true
        case .webURL:
            guard !trimmedName.isEmpty else { return false }
            return isURLValid
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 图标标识符合并：图片优先，否则文字加 text: 前缀；均空返回 nil
        let iconName: String? = {
            if let img = iconImage { return img }
            let trimmed = iconText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "text:\(trimmed)"
        }()

        // 展开尺寸写回：useCustomExpandedSize == false 时传 nil 跟随全局
        let resolvedWidth: Double? = useCustomExpandedSize ? expandedWidth : nil
        let resolvedHeight: Double? = useCustomExpandedSize ? expandedHeight : nil

        switch mode {
        case .customArea(let area):
            var updated = area
            updated.name = trimmedName
            updated.iconName = iconName
            updated.allowsNetworkAccess = allowsNetwork
            updated.updatedAt = Date()
            onSaveCustomArea(updated)
            // 写回 per-feature 展开尺寸 / 固定开关
            if let feature = LeftFeatureStore.shared.features.first(where: {
                if case .customArea(let areaID) = $0.kind { return areaID == area.id }
                return false
            }) {
                LeftFeatureStore.shared.setExpandedSize(id: feature.id, width: resolvedWidth, height: resolvedHeight)
                LeftFeatureStore.shared.setExpandedPinned(id: feature.id, pinned: expandedPinned)
            }
        case .webURL(let feature):
            var updated = feature
            updated.customDisplayName = trimmedName
            updated.customIconName = iconName
            updated.kind = .webURL(url: url)
            onSaveWebURL(updated)
            LeftFeatureStore.shared.setExpandedSize(id: feature.id, width: resolvedWidth, height: resolvedHeight)
            LeftFeatureStore.shared.setExpandedPinned(id: feature.id, pinned: expandedPinned)
        case .builtin(let feature):
            var updated = feature
            // name 与默认名相同则置 nil（回退默认名），避免持久化冗余
            let defaultName: String
            switch feature.kind {
            case .music: defaultName = "音乐"
            case .shelf: defaultName = "中转站"
            case .newsnow: defaultName = "热点新闻"
            case .mineradio: defaultName = "Mineradio"
            default: defaultName = ""
            }
            updated.customDisplayName = (trimmedName == defaultName || trimmedName.isEmpty) ? nil : trimmedName
            updated.customIconName = iconName
            onSaveBuiltin(updated)
            LeftFeatureStore.shared.setExpandedSize(id: feature.id, width: resolvedWidth, height: resolvedHeight)
            LeftFeatureStore.shared.setExpandedPinned(id: feature.id, pinned: expandedPinned)
        }
        dismiss()
    }
}
