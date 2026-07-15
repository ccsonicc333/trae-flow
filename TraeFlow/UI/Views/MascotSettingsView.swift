import SwiftUI
import AppKit

/// 宠物主题包选择页
struct MascotSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var scanner = MascotThemeScanner.shared
    @State private var previewStatus: MascotStatus = .running
    @State private var syncResult: String?
    @State private var isSyncing = false
    @State private var designPromptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sandboxAccessSection
            staleThemeSection
            themePackSection
            animationSpeedSection
            designPromptSection
            downloadHintSection
        }
    }


    private var themePackSection: some View {
        MascotSectionCard(title: "宠物主题包") {
            VStack(spacing: 0) {
                // 路径头
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(UserHomeDirectoryResolver.traeFlowPetsDirectory.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        guard !isSyncing else { return }
                        isSyncing = true
                        Task {
                            // 1. 从 codex 同步已有主题包到 ~/.traeflow/pets/
                            let result = await scanner.syncFromCodex()
                            // 2. 重新扫描 ~/.traeflow/pets/ 等目录，让手动放入的主题包也被识别
                            await scanner.rescanNow()
                            isSyncing = false
                            if result.synced == 0 && result.skipped == 0 && result.failed.isEmpty {
                                syncResult = "已刷新"
                            } else {
                                var msg = "已同步 \(result.synced) 个，跳过 \(result.skipped) 个已存在"
                                if !result.failed.isEmpty {
                                    msg += "，失败：\(result.failed.joined(separator: ", "))"
                                }
                                syncResult = msg
                            }
                        }
                    } label: {
                        Text("刷新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSyncing)

                    Button {
                        let url = UserHomeDirectoryResolver.traeFlowPetsDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("打开文件夹")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    if !settings.deletedBuiltinMascotThemeIDs.isEmpty {
                        Button {
                            Task { await scanner.restoreDeletedBuiltinThemes() }
                        } label: {
                            Text("恢复内置宠物")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let syncResult {
                    Text(appLocalized: syncResult)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if scanner.themes.isEmpty {
                    MascotCardDivider()
                    Text(appLocalized: "未找到任何主题包。请确认 $HOME/.codex/pets/ 下有已安装的宠物，或点击重新扫描。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(Array(scanner.themes.enumerated()), id: \.element.id) { index, theme in
                        if index > 0 {
                            MascotCardDivider()
                        }
                        MascotThemeRow(
                            theme: theme,
                            isSelected: settings.globalMascotKind.themeID == theme.id,
                            previewStatus: previewStatus
                        )
                    }
                }
            }
        }
    }

    /// 沙盒构建下显示 codex 宠物目录授权入口（已废弃：项目不再支持 Mac App Store）
    @ViewBuilder
    private var sandboxAccessSection: some View {
        EmptyView()
    }

    /// 选中主题包失效提示：用户选过的非 claude 主题包在下次启动时已不存在（被删除或移动），
    /// 渲染层会临时回退到内置 claude 像素画。这里提示用户并允许一键清除失效 ID。
    @ViewBuilder
    private var staleThemeSection: some View {
        let availableThemeIDs = Set(scanner.themes.map(\.id))
        if let selectedID = settings.selectedMascotThemeID,
           !availableThemeIDs.contains(selectedID) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(appLocalized: "之前选择的宠物已不可用，已切换为默认")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("恢复默认") {
                    settings.setGlobalMascotThemeID(nil)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        }
    }

    /// 宠物动画速率设置 —— 0 = 完全不动，1 = 正常速度，2 = 2 倍速
    private var animationSpeedSection: some View {
        MascotSectionCard(title: "动画速率") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(appLocalized: "速率")
                        .font(.system(size: 12))

                    Slider(value: Binding(
                        get: { settings.mascotAnimationSpeed },
                        set: { settings.mascotAnimationSpeed = (Double($0) * 100).rounded() / 100 }
                    ), in: 0...2, step: 0.1)
                    .tint(.accentColor)

                    Text(speedLabel(settings.mascotAnimationSpeed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)

                    Button {
                        settings.mascotAnimationSpeed = 1.0
                    } label: {
                        Text(appLocalized: "默认")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(abs(settings.mascotAnimationSpeed - 1.0) < 0.001)
                }

                Text(appLocalized: "拖动调整宠物动画播放速率。设为 0 时宠物完全静止，1 为正常速度，2 为 2 倍速。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        if speed <= 0 {
            return "静止"
        }
        return String(format: "%.1f×", speed)
    }

    /// TRAE Work Design 生成宠物入口：按钮打开 TRAE Work CN，提示词可复制到 Design 中使用
    private var designPromptSection: some View {
        MascotSectionCard(title: "用 TRAE Work Design 生成宠物") {
            VStack(alignment: .leading, spacing: 12) {
                // 说明文字：单行，紧凑
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(appLocalized: "打开 TRAE Work CN，将提示词粘贴到设计对话中，AI 将自动生成宠物素材到 ~/.traeflow/pets/")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        TraeSessionLauncher.activate(.traeWorkCN)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 11))
                            Text("去 TRAE Work Design 生成")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pointingHand.pop() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                MascotCardDivider()

                // 提示词标题行：标题在左，复制按钮在右
                HStack(spacing: 8) {
                    Text(appLocalized: "生成宠物提示词")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(designPromptTemplate, forType: .string)
                        designPromptCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            designPromptCopied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: designPromptCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(designPromptCopied ? "已复制" : "复制提示词")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(designPromptCopied ? Color.green : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(designPromptCopied
                                    ? Color.green.opacity(0.1)
                                    : Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pointingHand.pop() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                // 可滚动的提示词文本区域
                ScrollView {
                    Text(designPromptTemplate)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    /// 生成宠物的提示词模板
    private let designPromptTemplate = """
        我要创建一个自定义宠物。请按以下要求直接生成并保存文件。

        【宠物信息】
        宠物 ID（英文文件夹名）：[在此填写，如 my-cat]
        宠物中文名：[在此填写，如 我的小猫]
        宠物类型描述：[在此填写，如 一只橘色的像素猫咪，圆脸大眼，尾巴翘起]
        背景：透明

        【任务 1：生成精灵表图像并保存到文件】
        直接生成一张 WebP 格式的精灵表（sprite sheet），并写入到以下路径：
        ~/.traeflow/pets/[宠物ID]/spritesheet.webp
        如果目录不存在，先用 mkdir -p 创建。

        精灵表规格（严格遵循）：
        - 整图尺寸：1536 × 1872 像素，恰好 8 列 × 9 行
        - 每帧大小：192 × 208 像素
        - 每行 8 帧，是同一个动画状态的逐帧循环（帧与帧之间有细微差异以形成动画）
        - 像素风格，背景透明或纯色填充

        9 行状态映射（从上到下，第 0 行为最顶部）：
        第 0 行 idle     — 宠物原地站立，轻微呼吸起伏（8帧循环）
        第 1 行 runRight — 宠物向右跑动的侧面姿态（8帧循环）
        第 2 行 runLeft  — 宠物向左跑动的侧面姿态，镜像 runRight（8帧循环）
        第 3 行 waving   — 宠物面向前方打招呼（8帧循环）
        第 4 行 jumping  — 宠物原地跳跃（8帧循环）
        第 5 行 failed   — 宠物表现失败/沮丧（8帧循环）
        第 6 行 waiting  — 宠物表现等待/思考（8帧循环）
        第 7 行 running  — 宠物工作状态的动态姿态（8帧循环）
        第 8 行 review   — 宠物凑近屏幕/审视（8帧循环）

        【任务 2：创建 pet.json 并保存到文件】
        将以下 JSON 写入到文件 ~/.traeflow/pets/[宠物ID]/pet.json，将 [宠物ID]、[中文名]、[描述] 替换为实际值：

        {
          "id": "[宠物ID]",
          "displayName": "[中文名]",
          "description": "[描述]",
          "kind": "animal",
          "frameWidth": 192,
          "frameHeight": 208,
          "fps": 8,
          "animations": {
            "idle": { "row": 0, "frames": 8 },
            "runRight": { "row": 1, "frames": 8 },
            "runLeft": { "row": 2, "frames": 8 },
            "waving": { "row": 3, "frames": 8 },
            "jumping": { "row": 4, "frames": 8 },
            "failed": { "row": 5, "frames": 8 },
            "waiting": { "row": 6, "frames": 8 },
            "running": { "row": 7, "frames": 8 },
            "review": { "row": 8, "frames": 8 }
          }
        }

        完成后告诉我文件已生成，让我去 TraeFlow 刷新选择。
        """

    /// 下载更多宠物提示区：展示第三方主题包下载站点，用户下载解压到 ~/.traeflow/pets/ 即可安装
    private var downloadHintSection: some View {
        MascotSectionCard(title: "下载更多宠物") {
            VStack(alignment: .leading, spacing: 12) {
                // 安装说明：路径部分可点击打开文件夹
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(appLocalized: "下载后解压到")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(" ")
                        .font(.system(size: 12))
                    Button {
                        let url = UserHomeDirectoryResolver.traeFlowPetsDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("~/.traeflow/pets/")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .underline()
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    Text(appLocalized: " 文件夹即可完成安装。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // 第三方下载站点标题
                Text(appLocalized: "第三方下载站点")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(downloadLinks, id: \.url) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.square.fill")
                                    .font(.system(size: 12))
                                Text(link.url)
                                    .font(.system(size: 12, weight: .medium))
                                    .underline()
                            }
                            .foregroundStyle(Color(NSColor.linkColor))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    /// 沙盒授权：通过 NSOpenPanel 让用户选择 $HOME/.codex/pets/ 目录
    private func requestCodexPetsAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "授权"
        panel.message = "选择 $HOME/.codex/pets/ 目录"
        panel.directoryURL = UserHomeDirectoryResolver.codexPetsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Task { await scanner.requestCodexPetsAccess(url: url) }
        }
    }
}

/// 下载链接条目（仅展示 URL，点击在浏览器打开）
private struct DownloadLink {
    let url: String
}

/// 第三方宠物主题包下载站点列表
private let downloadLinks: [DownloadLink] = [
    DownloadLink(url: "https://codex-pets.net/"),
    DownloadLink(url: "https://awesome-codex-pet.pages.dev/"),
    DownloadLink(url: "https://petdex.dev/")   
]

/// 宠物设置页专用区域卡片，匹配 SettingsSectionCard 的标题样式
private struct MascotSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized: title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        SettingsGlassSurface(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .opacity(0.96)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.025),
                                        Color.black.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
        }
    }
}

/// 宠物设置卡片内的分割线
private struct MascotCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}

/// 主题包列表行：左缩略图 + 中名称描述 + 右选择按钮，可展开显示各状态预览
private struct MascotThemeRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var scanner = MascotThemeScanner.shared
    @State private var isExpanded = false
    @State private var showDeleteConfirmation = false

    let theme: MascotTheme
    let isSelected: Bool
    let previewStatus: MascotStatus

    private let previewSize: CGFloat = 48

    /// TRAE hooks 实际会产生的宠物状态（不含 runLeft/running/dragging）
    private static let traeStatuses: [MascotStatus] = [
        .idle, .runRight, .waiting, .review, .failed, .waving, .jumping
    ]

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 14) {
                    // 左侧展开指示箭头（静态图标）
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)

                    // 左侧缩略图
                    previewThumbnail

                    // 中间名称 + 描述
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        if !theme.description.isEmpty {
                            Text(theme.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    // 右侧：删除按钮
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pointingHand.pop()
                        }
                    }
                    .alert("确认删除", isPresented: $showDeleteConfirmation) {
                        Button("取消", role: .cancel) {}
                        Button("删除", role: .destructive) {
                            Task { await scanner.deleteTheme(theme) }
                        }
                    } message: {
                        if theme.source == .builtin {
                            Text("确定要隐藏内置宠物「\(theme.displayName)」吗？可在上方点击“恢复内置宠物”还原。")
                        } else {
                            Text("确定要删除宠物主题包「\(theme.displayName)」吗？此操作不可撤销。")
                        }
                    }

                    // 右侧选择按钮（仅此按钮用于选择，不触发展开）
                    Button {
                        settings.setGlobalMascotThemeID(theme.id)
                    } label: {
                        if isSelected {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("已选")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor)
                            )
                        } else {
                            Text("选择")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.1))
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedStatusGrid
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                    ))
            }
        }
        .clipped()
    }

    /// 展开后各状态预览网格
    private var expandedStatusGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            Text("状态预览")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 12
            ) {
                ForEach(Self.traeStatuses, id: \.self) { status in
                    statusPreviewCell(status)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// 单个状态预览格：宠物动画 + 状态名
    /// 注意：不要在 body 里调用 `MascotSpriteCache.shared.frames(for:status:).count`，
    /// 那会同步触发整行帧裁剪 + 像素采样，导致展开时明显卡顿。
    private func statusPreviewCell(_ status: MascotStatus) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                MascotView(
                    kind: MascotKind(themeID: theme.id),
                    status: status,
                    size: 36
                )
                .environment(\.mascotAnimationsEnabled, true)
                // 展开状态预览是用户主动查看动画的场景，忽略 EnergyGovernor 的静态帧节能策略
                .environment(\.mascotAnimationsIgnoreEnergyPolicy, true)
            }
            .frame(height: 44)

            VStack(spacing: 2) {
                Text(status.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 缩略图预览 — 使用 MascotView 静态帧渲染，兼容内置像素画和 codex sprite sheet
    private var previewThumbnail: some View {
        let borderColor: Color = isSelected
            ? Color.accentColor
            : Color.white.opacity(0.08)

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)

            MascotView(
                kind: MascotKind(themeID: theme.id),
                status: previewStatus,
                size: previewSize - 8,
                animationTime: 0
            )
            .environment(\.mascotAnimationsEnabled, false)
        }
        .frame(width: previewSize, height: previewSize)
        .clipped()
    }
}

#Preview {
    MascotSettingsView()
        .frame(width: 880, height: 760)
}
