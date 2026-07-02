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

            // 图标 + 实时预览（图片优先，否则文字；均空回退默认 globe）
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

            // 名称
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // 按模式渲染差异字段
            switch mode {
            case .customArea:
                Toggle("允许请求外部接口", isOn: $allowsNetwork)
                    .font(.caption)

            case .webURL:
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://example.com", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    if !url.isEmpty, !isURLValid {
                        Text("请输入合法的 http 或 https 链接")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

            case .builtin:
                // 内置功能无额外字段，仅图标/名称/展开尺寸/固定开关
                EmptyView()
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
                        Slider(value: $expandedWidth, in: 470...800, step: 10)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("展开高度：\(Int(expandedHeight)) pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $expandedHeight, in: 200...900, step: 10)
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
