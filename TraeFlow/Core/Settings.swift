//
//  Settings.swift
//  TRAEFLOW
//
//  App settings manager using UserDefaults
//

import AppKit
import Combine
import Foundation

enum AppSettingsDefaultKeys {
    nonisolated static let surfaceMode = "surfaceMode"
    nonisolated static let notchModuleWidth = "notchModuleWidth"
    nonisolated static let floatingPetAnchor = "floatingPetAnchor"
    nonisolated static let floatingPetSizeMode = "floatingPetSizeMode"
    nonisolated static let floatingPetCustomScale = "floatingPetCustomScale"
    nonisolated static let mascotAnimationSpeed = "mascotAnimationSpeed"
    nonisolated static let presentationModeOnboardingPending = "presentationModeOnboardingPending"
    nonisolated static let notchDetachmentHintPending = "notchDetachmentHintPending"
    nonisolated static let floatingPetSettingsHintPending = "floatingPetSettingsHintPending"
    nonisolated static let hookInstallOnboardingPending = "hookInstallOnboardingPending"
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    func resolvedLanguageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system:
            let preferredLanguage = preferredLanguages.first?.lowercased() ?? ""
            if preferredLanguage.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    func resolvedLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedLanguageCode(preferredLanguages: preferredLanguages))
    }
}

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

final class SoundPlaybackCoordinator {
    private var activeSound: NSSound?

    @discardableResult
    func play(_ sound: NSSound, volume: Float) -> Bool {
        stopActiveSound(except: sound)

        if isActiveSound(sound), sound.isPlaying {
            sound.stop()
        }

        sound.volume = volume
        let didPlay = sound.play()
        activeSound = didPlay ? sound : nil
        return didPlay
    }

    func clearIfActive(_ sound: NSSound) {
        guard isActiveSound(sound) else { return }
        activeSound = nil
    }

    private func stopActiveSound(except sound: NSSound) {
        guard let activeSound, !isSameSound(activeSound, sound) else { return }
        if activeSound.isPlaying {
            activeSound.stop()
        }
        self.activeSound = nil
    }

    private func isActiveSound(_ sound: NSSound) -> Bool {
        guard let activeSound else { return false }
        return isSameSound(activeSound, sound)
    }

    private func isSameSound(_ lhs: NSSound, _ rhs: NSSound) -> Bool { lhs === rhs }
}

enum AppSoundPlayback {
    static let shared = SoundPlaybackCoordinator()
}

enum UsageValueMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .used:
            return "已用量"
        case .remaining:
            return "剩余量"
        }
    }
}

enum AutoRoutePromptsIdleDelay: Int, CaseIterable, Identifiable {
    case tenMinutes = 600
    case twentyMinutes = 1200
    case thirtyMinutes = 1800
    case sixtyMinutes = 3600

    nonisolated var id: Int { rawValue }

    nonisolated var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    nonisolated var title: String {
        switch self {
        case .tenMinutes:
            return "10 分钟"
        case .twentyMinutes:
            return "20 分钟"
        case .thirtyMinutes:
            return "30 分钟"
        case .sixtyMinutes:
            return "1 小时"
        }
    }
}

enum NotchDisplayMode: String, CaseIterable, Identifiable {
    case compact
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "简约"
        case .detailed:
            return "详细"
        }
    }

    var subtitle: String {
        switch self {
        case .compact:
            return "只显示图标和会话数量"
        case .detailed:
            return "额外显示激活会话的最新消息"
        }
    }
}

enum ClosedNotchTrailingContentMode: String, CaseIterable, Identifiable {
    case sessionCount
    case traeTaskIcon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionCount:
            return "会话数量"
        case .traeTaskIcon:
            return "Trae 任务图标"
        }
    }
}

enum IslandToolApprovalMode: String, CaseIterable, Identifiable {
    case prompt
    case autoApprove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompt:
            return "每次询问"
        case .autoApprove:
            return "自动允许"
        }
    }

    var subtitle: String {
        switch self {
        case .prompt:
            return "写文件、Edit、Bash 等修改类工具需要手动批准"
        case .autoApprove:
            return "TRAE 的工具调用自动放行，不再弹窗"
        }
    }
}

enum IslandSurfaceMode: String, CaseIterable, Identifiable {
    case notch
    case floatingPet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch:
            return "刘海屏方式"
        case .floatingPet:
            return "独立悬浮宠物"
        }
    }

    var subtitle: String {
        switch self {
        case .notch:
            return "固定在屏幕顶部中央，沿用 Island 刘海/胶囊体验"
        case .floatingPet:
            return "默认贴近当前激活窗口右下角，可拖动并记住位置"
        }
    }
}

struct FloatingPetAnchor: Codable, Equatable {
    let xRatio: Double
    let yRatio: Double
}

enum FloatingPetSizeMode: String, CaseIterable, Identifiable {
    case automatic
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .standard:
            return "标准"
        case .large:
            return "较大"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "按显示器分辨率调整，高分屏会更醒目"
        case .standard:
            return "固定为旧版悬浮宠物尺寸"
        case .large:
            return "在所有显示器上放大宠物形象"
        }
    }
}

enum SubagentVisibilityMode: String, CaseIterable, Identifiable {
    case hidden
    case visible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden:
            return "不显示"
        case .visible:
            return "显示"
        }
    }

    var subtitle: String {
        switch self {
        case .hidden:
            return "主列表里隐藏挂靠在主 Agent 下的子 Agent 项"
        case .visible:
            return "主列表里将明确的子 Agent 挂靠在主 Agent 下展示"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case Self.hidden.rawValue:
            self = .hidden
        case Self.visible.rawValue, "firstLevelOnly", "all":
            self = .visible
        default:
            return nil
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()
    nonisolated static let defaultNotchModuleWidth: Double = 320
    nonisolated static let minimumNotchModuleWidth: Double = 70
    nonisolated static let maximumNotchModuleWidth: Double = 1000

    private let defaults: UserDefaults
    private let bridgeRuntimeConfigWriter: (BridgeRuntimeConfigSnapshot) -> Void
    private var isBootstrapping = true
    private var subagentVisibilityModeStorage: SubagentVisibilityMode

    // MARK: - Keys

    private enum Keys {
        static let appLanguage = "appLanguage"
        static let notificationSound = "notificationSound"
        static let soundEnabled = "soundEnabled"
        static let soundVolume = "soundVolume"
        static let temporarilyMuteNotificationsUntil = "temporarilyMuteNotificationsUntil"
        static let processingStartSound = "processingStartSound"
        static let attentionRequiredSound = "attentionRequiredSound"
        static let taskCompletedSound = "taskCompletedSound"
        static let taskErrorSound = "taskErrorSound"
        static let resourceLimitSound = "resourceLimitSound"
        static let processingStartSoundEnabled = "processingStartSoundEnabled"
        static let attentionRequiredSoundEnabled = "attentionRequiredSoundEnabled"
        static let taskCompletedSoundEnabled = "taskCompletedSoundEnabled"
        static let taskErrorSoundEnabled = "taskErrorSoundEnabled"
        static let resourceLimitSoundEnabled = "resourceLimitSoundEnabled"
        static let soundThemeMode = "soundThemeMode"
        static let selectedSoundPackPath = "selectedSoundPackPath"
        static let hideInFullscreen = "hideInFullscreen"
        static let autoHideWhenIdle = "autoHideWhenIdle"
        static let autoCollapseOnLeave = "autoCollapseOnLeave"
        static let alwaysExpandFlowIsland = "alwaysExpandFlowIsland"
        static let openOnHover = "openOnHover"
        static let isPanelPinned = "isPanelPinned"
        static let keepIslandOpen = "keepIslandOpen"
        static let hoverOpenDelayMs = "hoverOpenDelayMs"
        static let smartSuppression = "smartSuppression"
        static let autoOpenCompactedNotificationPanel = "autoOpenCompactedNotificationPanel"
        // Spec: 紧凑态/展开态功能选择由 LeftFeatureStore 统一管理（持久化键 leftFeatureCompactID / leftFeatureExpandedActiveID）
        // Spec: 紧凑态左半区高度（默认 24，范围 24–80，步长 1），调高后可承载歌词等富内容
        static let compactLeftHeight = "compactLeftHeight"
        // Spec: 紧凑态自定义 HTML 提示开关 —— 开启后在 Flow 岛显示 JS Bridge 推送的提示
        static let showCompactHintEnabled = "showCompactHintEnabled"
        // Spec: 远程 URL 功能收起后保活开关 —— 开启后 Flow 岛收起时 WKWebView 继续运行（音频/JS/网络）
        static let keepWebURLAliveWhenCollapsed = "keepWebURLAliveWhenCollapsed"
        static let showAgentDetail = "showAgentDetail"
        static let subagentVisibilityMode = "subagentVisibilityMode"
        static let legacyCodexSubagentVisibilityMode = "codexSubagentVisibilityMode"
        static let showUsage = "showUsage"
        static let usageValueMode = "usageValueMode"
        static let contentFontSize = "contentFontSize"
        static let maxPanelHeight = "maxPanelHeight"
        static let expandedPanelWidth = "expandedPanelWidth"
        static let notchModuleWidth = AppSettingsDefaultKeys.notchModuleWidth
        static let notchDisplayMode = "notchDisplayMode"
        static let closedNotchTrailingContentMode = "closedNotchTrailingContentMode"
        static let previewMascotKind = "previewMascotKind"
        static let surfaceMode = AppSettingsDefaultKeys.surfaceMode
        static let floatingPetAnchor = AppSettingsDefaultKeys.floatingPetAnchor
        static let floatingPetSizeMode = AppSettingsDefaultKeys.floatingPetSizeMode
        static let floatingPetCustomScale = AppSettingsDefaultKeys.floatingPetCustomScale
        static let mascotAnimationSpeed = AppSettingsDefaultKeys.mascotAnimationSpeed
        static let presentationModeOnboardingPending = AppSettingsDefaultKeys.presentationModeOnboardingPending
        static let notchDetachmentHintPending = AppSettingsDefaultKeys.notchDetachmentHintPending
        static let floatingPetSettingsHintPending = AppSettingsDefaultKeys.floatingPetSettingsHintPending
        static let hookInstallOnboardingPending = AppSettingsDefaultKeys.hookInstallOnboardingPending
        static let automaticUpdateChecksEnabled = "automaticUpdateChecksEnabled"
        static let mascotOverrides = "mascotOverrides"
        // 宠物主题包系统新键（Task 5）
        static let selectedMascotThemeID = "selectedMascotThemeID"
        static let mascotThemeOverrides = "mascotThemeOverrides"
        static let mascotPerClientOverrideEnabled = "mascotPerClientOverrideEnabled"
        static let deletedBuiltinMascotThemeIDs = "deletedBuiltinMascotThemeIDs"
        static let openActiveSessionShortcut = "openActiveSessionShortcut"
        static let openActiveSessionShortcutDisabled = "openActiveSessionShortcutDisabled"
        static let openSessionListShortcut = "openSessionListShortcut"
        static let openSessionListShortcutDisabled = "openSessionListShortcutDisabled"
        static let leftFeatureQuickExpandShortcut = "leftFeatureQuickExpandShortcut"
        static let leftFeatureQuickExpandShortcutDisabled = "leftFeatureQuickExpandShortcutDisabled"
        static let routePromptsToTerminal = "routePromptsToTerminal"
        static let autoRoutePromptsToTerminalWhenIdleEnabled = "autoRoutePromptsToTerminalWhenIdleEnabled"
        static let autoRoutePromptsIdleDelay = "autoRoutePromptsIdleDelay"
        static let hookDebugLoggingEnabled = "hookDebugLoggingEnabled"
        static let hookDebugLogRetentionDays = "hookDebugLogRetentionDays"
        static let hookDebugLogMaxDirectoryMegabytes = "hookDebugLogMaxDirectoryMegabytes"
        static let traeToolApprovalMode = "traeToolApprovalMode"
    }

    // MARK: - Published Settings

    @Published var appLanguage: AppLanguage {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
        }
    }

    @Published var notificationSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notificationSound.rawValue, forKey: Keys.notificationSound)
            taskCompletedSound = notificationSound
        }
    }

    @Published var soundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(soundEnabled, forKey: Keys.soundEnabled)
        }
    }

    @Published var soundVolume: Double {
        didSet {
            let clamped = min(max(soundVolume, 0), 1)
            if soundVolume != clamped {
                soundVolume = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(soundVolume, forKey: Keys.soundVolume)
        }
    }

    @Published var temporarilyMuteNotificationsUntil: Date? {
        didSet {
            guard !isBootstrapping else { return }

            if let temporarilyMuteNotificationsUntil {
                defaults.set(
                    temporarilyMuteNotificationsUntil.timeIntervalSince1970,
                    forKey: Keys.temporarilyMuteNotificationsUntil
                )
            } else {
                defaults.removeObject(forKey: Keys.temporarilyMuteNotificationsUntil)
            }
        }
    }

    @Published var processingStartSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(processingStartSound.rawValue, forKey: Keys.processingStartSound)
        }
    }

    @Published var attentionRequiredSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(attentionRequiredSound.rawValue, forKey: Keys.attentionRequiredSound)
        }
    }

    @Published var taskCompletedSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskCompletedSound.rawValue, forKey: Keys.taskCompletedSound)
            if notificationSound != taskCompletedSound {
                notificationSound = taskCompletedSound
            }
        }
    }

    @Published var taskErrorSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskErrorSound.rawValue, forKey: Keys.taskErrorSound)
        }
    }

    @Published var resourceLimitSound: NotificationSound {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(resourceLimitSound.rawValue, forKey: Keys.resourceLimitSound)
        }
    }

    @Published var processingStartSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(processingStartSoundEnabled, forKey: Keys.processingStartSoundEnabled)
        }
    }

    @Published var attentionRequiredSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(attentionRequiredSoundEnabled, forKey: Keys.attentionRequiredSoundEnabled)
        }
    }

    @Published var taskCompletedSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskCompletedSoundEnabled, forKey: Keys.taskCompletedSoundEnabled)
        }
    }

    @Published var taskErrorSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(taskErrorSoundEnabled, forKey: Keys.taskErrorSoundEnabled)
        }
    }

    @Published var resourceLimitSoundEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(resourceLimitSoundEnabled, forKey: Keys.resourceLimitSoundEnabled)
        }
    }

    @Published var soundThemeMode: SoundThemeMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(soundThemeMode.rawValue, forKey: Keys.soundThemeMode)
        }
    }

    @Published var selectedSoundPackPath: String {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(selectedSoundPackPath, forKey: Keys.selectedSoundPackPath)
        }
    }

    @Published var hideInFullscreen: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(hideInFullscreen, forKey: Keys.hideInFullscreen)
        }
    }

    @Published var autoHideWhenIdle: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoHideWhenIdle, forKey: Keys.autoHideWhenIdle)
        }
    }

    @Published var autoCollapseOnLeave: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoCollapseOnLeave, forKey: Keys.autoCollapseOnLeave)
        }
    }

    /// Flow 岛始终以展开态显示（默认开启）。开启后启动直接进入展开态、
    /// hover 离开不再自动收起、低功耗/空闲策略也不再把窗口推出屏幕；
    /// 仍可通过点击面板外手动收起（notchClose）。
    @Published var alwaysExpandFlowIsland: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(alwaysExpandFlowIsland, forKey: Keys.alwaysExpandFlowIsland)
        }
    }

    /// 鼠标悬停是否自动展开 Flow 岛（默认开启，保持向后兼容）。
    /// 关闭后鼠标移入触发区不会启动 hover 展开计时器，仅保留点击展开入口。
    @Published var openOnHover: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(openOnHover, forKey: Keys.openOnHover)
        }
    }

    /// 展开态面板固定状态（默认关闭）。开启后 hover 离开不再自动收起、
    /// 低功耗/空闲隐藏策略也不再把窗口推出屏幕；
    /// 仍可通过点击面板外手动收起（notchClose）。
    @Published var isPanelPinned: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(isPanelPinned, forKey: Keys.isPanelPinned)
        }
    }

    @Published var keepIslandOpen: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(keepIslandOpen, forKey: Keys.keepIslandOpen)
        }
    }

    /// 鼠标移入 Flow 岛后延迟多少毫秒再展开（仅当 openOnHover 开启时生效）。
    @Published var hoverOpenDelayMs: Int {
        didSet {
            let clamped = min(max(hoverOpenDelayMs, 0), 2000)
            if hoverOpenDelayMs != clamped {
                hoverOpenDelayMs = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(hoverOpenDelayMs, forKey: Keys.hoverOpenDelayMs)
        }
    }

    @Published var smartSuppression: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(smartSuppression, forKey: Keys.smartSuppression)
        }
    }

    @Published var autoOpenCompactedNotificationPanel: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoOpenCompactedNotificationPanel, forKey: Keys.autoOpenCompactedNotificationPanel)
        }
    }

    // Spec: 紧凑态/展开态功能选择由 LeftFeatureStore 统一管理（compactFeatureID / expandedActiveFeatureID），
    // Settings 不再重复持有这两个字段，避免双套持久化键冲突。

    /// Spec: 紧凑态左半区高度（默认 24，范围 30–80，步长 1），调高后可承载歌词等富内容。
    /// Flow 岛 `closedNotchSize.height` 跟随该值动态扩展以避免内容被截断。
    @Published var compactLeftHeight: CGFloat = 24 {
        didSet {
            let clamped = min(max(compactLeftHeight, 30), 80)
            if compactLeftHeight != clamped {
                compactLeftHeight = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(Double(compactLeftHeight), forKey: Keys.compactLeftHeight)
        }
    }

    /// Spec: 紧凑态自定义 HTML 提示开关（默认 true）。
    /// 开启后，自定义 HTML 通过 JS Bridge 推送的提示会叠加显示在 Flow 岛紧凑态左半区。
    @Published var showCompactHintEnabled: Bool = true {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showCompactHintEnabled, forKey: Keys.showCompactHintEnabled)
        }
    }

    /// Spec: 远程 URL 功能收起后保活开关（默认 true）。
    /// 开启后，Flow 岛收起时远程 URL（`.webURL` / `.newsnow`）/ Mineradio 功能的 WKWebView 不会被销毁，
    /// 音频播放、JS 执行、网络请求继续运行；下次展开时复用同一实例。
    @Published var keepWebURLAliveWhenCollapsed: Bool = true {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(keepWebURLAliveWhenCollapsed, forKey: Keys.keepWebURLAliveWhenCollapsed)
            // 关闭保活时清空缓存，释放已保活的 WKWebView
            if !keepWebURLAliveWhenCollapsed {
                CustomAreaWebViewCache.shared.clearAll()
            }
        }
    }

    @Published var showAgentDetail: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showAgentDetail, forKey: Keys.showAgentDetail)
        }
    }

    var subagentVisibilityMode: SubagentVisibilityMode {
        get { subagentVisibilityModeStorage }
        set {
            let shouldUpdatePublishedState = subagentVisibilityModeStorage != newValue
            if shouldUpdatePublishedState {
                objectWillChange.send()
                subagentVisibilityModeStorage = newValue
            }

            guard !isBootstrapping else { return }

            let persistedValue = newValue.rawValue
            let primaryStoredValue = defaults.string(forKey: Keys.subagentVisibilityMode)
            let legacyStoredValue = defaults.string(forKey: Keys.legacyCodexSubagentVisibilityMode)
            guard shouldUpdatePublishedState
                    || primaryStoredValue != persistedValue
                    || legacyStoredValue != persistedValue else { return }

            defaults.set(persistedValue, forKey: Keys.subagentVisibilityMode)
            defaults.set(persistedValue, forKey: Keys.legacyCodexSubagentVisibilityMode)
        }
    }

    @Published var showUsage: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(showUsage, forKey: Keys.showUsage)
        }
    }

    @Published var usageValueMode: UsageValueMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(usageValueMode.rawValue, forKey: Keys.usageValueMode)
        }
    }

    @Published var contentFontSize: Double {
        didSet {
            let clamped = min(max(contentFontSize, 11), 17)
            if contentFontSize != clamped {
                contentFontSize = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(contentFontSize, forKey: Keys.contentFontSize)
        }
    }

    @Published var maxPanelHeight: Double {
        didSet {
            let clamped = min(max(maxPanelHeight, 200), 900)
            if maxPanelHeight != clamped {
                maxPanelHeight = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(maxPanelHeight, forKey: Keys.maxPanelHeight)
        }
    }

    @Published var expandedPanelWidth: Double {
        didSet {
            let clamped = min(max(expandedPanelWidth, 470), 800)
            if expandedPanelWidth != clamped {
                expandedPanelWidth = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(expandedPanelWidth, forKey: Keys.expandedPanelWidth)
        }
    }

    @Published var notchModuleWidth: Double {
        didSet {
            let clamped = Self.normalizedNotchModuleWidth(notchModuleWidth)
            if notchModuleWidth != clamped {
                notchModuleWidth = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(notchModuleWidth, forKey: Keys.notchModuleWidth)
        }
    }

    @Published var notchDisplayMode: NotchDisplayMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notchDisplayMode.rawValue, forKey: Keys.notchDisplayMode)
        }
    }

    @Published var closedNotchTrailingContentMode: ClosedNotchTrailingContentMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(closedNotchTrailingContentMode.rawValue, forKey: Keys.closedNotchTrailingContentMode)
        }
    }

    /// 兼容入口：旧 `previewMascotKind` 键已迁移到 `selectedMascotThemeID`。
    /// 写入转发到新键；读取返回 init 时与新键同步的快照值。
    @Published var previewMascotKind: MascotKind {
        didSet {
            guard !isBootstrapping else { return }
            // 兼容：转发到新键（claude 视为内置回退，存为 nil）
            selectedMascotThemeID = previewMascotKind == .claude ? nil : previewMascotKind.themeID
        }
    }

    /// 用户全局选中的主题包 ID（nil 表示用内置 claude 回退）
    @Published var selectedMascotThemeID: String? {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(selectedMascotThemeID, forKey: Keys.selectedMascotThemeID)
        }
    }

    /// 被用户删除的内置主题包 ID 集合（nil 时使用空集合）
    @Published var deletedBuiltinMascotThemeIDs: Set<String> {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistValue(deletedBuiltinMascotThemeIDs, defaults: defaults, key: Keys.deletedBuiltinMascotThemeIDs)
        }
    }

    @Published var surfaceMode: IslandSurfaceMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(surfaceMode.rawValue, forKey: Keys.surfaceMode)
        }
    }

    @Published var floatingPetAnchor: FloatingPetAnchor? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistValue(floatingPetAnchor, defaults: defaults, key: Keys.floatingPetAnchor)
        }
    }

    @Published var floatingPetSizeMode: FloatingPetSizeMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(floatingPetSizeMode.rawValue, forKey: Keys.floatingPetSizeMode)
        }
    }

    /// 用户通过滚轮缩放设置的宠物大小覆盖（0 = 禁用，跟随 floatingPetSizeMode）。
    /// 最小 0.5，无上限。
    @Published var floatingPetCustomScale: CGFloat {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(Double(floatingPetCustomScale), forKey: Keys.floatingPetCustomScale)
        }
    }

    /// 宠物动画速率倍率。
    /// - 0 = 完全不动（渲染静态首帧）
    /// - 1 = 默认正常速度
    /// - 2 = 2 倍速
    /// 范围 0...2，默认 1。`MascotView` 据此调整 TimelineView 的 interval（或切换为静态帧）。
    @Published var mascotAnimationSpeed: Double {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(mascotAnimationSpeed, forKey: Keys.mascotAnimationSpeed)
        }
    }

    @Published var presentationModeOnboardingPending: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(presentationModeOnboardingPending, forKey: Keys.presentationModeOnboardingPending)
        }
    }

    @Published var notchDetachmentHintPending: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(notchDetachmentHintPending, forKey: Keys.notchDetachmentHintPending)
        }
    }

    @Published var floatingPetSettingsHintPending: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(floatingPetSettingsHintPending, forKey: Keys.floatingPetSettingsHintPending)
        }
    }

    @Published var hookInstallOnboardingPending: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(hookInstallOnboardingPending, forKey: Keys.hookInstallOnboardingPending)
        }
    }

    @Published var automaticUpdateChecksEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(automaticUpdateChecksEnabled, forKey: Keys.automaticUpdateChecksEnabled)
        }
    }

    /// 兼容入口：旧 `mascotOverrides` 键已迁移到 `mascotThemeOverrides`。
    /// 写入转发到新键；读取返回 init 时与新键同步的快照值。
    @Published var mascotOverrides: [String: String] {
        didSet {
            guard !isBootstrapping else { return }
            // 兼容：转发到新键（sanitizer 在新键 didSet 内执行）
            mascotThemeOverrides = mascotOverrides
        }
    }

    /// 按客户端覆盖的主题包 ID 映射（仅当 mascotPerClientOverrideEnabled=true 时生效）
    @Published var mascotThemeOverrides: [String: String] {
        didSet {
            let sanitized = Self.sanitizedMascotThemeOverrides(mascotThemeOverrides)
            if mascotThemeOverrides != sanitized {
                mascotThemeOverrides = sanitized
                return
            }
            guard !isBootstrapping else { return }
            Self.persistValue(mascotThemeOverrides, defaults: defaults, key: Keys.mascotThemeOverrides)
        }
    }

    /// 是否启用按客户端覆盖宠物主题包
    @Published var mascotPerClientOverrideEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(mascotPerClientOverrideEnabled, forKey: Keys.mascotPerClientOverrideEnabled)
        }
    }

    @Published var openActiveSessionShortcut: GlobalShortcut? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistShortcut(
                openActiveSessionShortcut,
                defaults: defaults,
                key: Keys.openActiveSessionShortcut,
                disabledKey: Keys.openActiveSessionShortcutDisabled
            )
        }
    }

    @Published var openSessionListShortcut: GlobalShortcut? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistShortcut(
                openSessionListShortcut,
                defaults: defaults,
                key: Keys.openSessionListShortcut,
                disabledKey: Keys.openSessionListShortcutDisabled
            )
        }
    }

    /// 左侧功能"位置式快捷展开"快捷键模板（默认 Option + 1）。
    /// 运行时仅取其修饰键，与数字键 1-9 组合展开对应序号的已启用功能。
    @Published var leftFeatureQuickExpandShortcut: GlobalShortcut? {
        didSet {
            guard !isBootstrapping else { return }
            Self.persistShortcut(
                leftFeatureQuickExpandShortcut,
                defaults: defaults,
                key: Keys.leftFeatureQuickExpandShortcut,
                disabledKey: Keys.leftFeatureQuickExpandShortcutDisabled
            )
        }
    }

    @Published var routePromptsToTerminal: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(routePromptsToTerminal, forKey: Keys.routePromptsToTerminal)
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var autoRoutePromptsToTerminalWhenIdleEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(
                autoRoutePromptsToTerminalWhenIdleEnabled,
                forKey: Keys.autoRoutePromptsToTerminalWhenIdleEnabled
            )
            if !autoRoutePromptsToTerminalWhenIdleEnabled {
                setIdleAutoRoutePromptsToTerminalActive(false)
                return
            }
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var autoRoutePromptsIdleDelay: AutoRoutePromptsIdleDelay {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(autoRoutePromptsIdleDelay.rawValue, forKey: Keys.autoRoutePromptsIdleDelay)
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var hookDebugLoggingEnabled: Bool {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(hookDebugLoggingEnabled, forKey: Keys.hookDebugLoggingEnabled)
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var hookDebugLogRetentionDays: Int {
        didSet {
            let clamped = BridgeRuntimeConfigSnapshot.clampedDebugLogRetentionDays(hookDebugLogRetentionDays)
            if hookDebugLogRetentionDays != clamped {
                hookDebugLogRetentionDays = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(hookDebugLogRetentionDays, forKey: Keys.hookDebugLogRetentionDays)
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var hookDebugLogMaxDirectoryMegabytes: Int {
        didSet {
            let clamped = BridgeRuntimeConfigSnapshot.clampedDebugLogMaxDirectoryMegabytes(
                hookDebugLogMaxDirectoryMegabytes
            )
            if hookDebugLogMaxDirectoryMegabytes != clamped {
                hookDebugLogMaxDirectoryMegabytes = clamped
                return
            }
            guard !isBootstrapping else { return }
            defaults.set(
                hookDebugLogMaxDirectoryMegabytes,
                forKey: Keys.hookDebugLogMaxDirectoryMegabytes
            )
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    @Published var traeToolApprovalMode: IslandToolApprovalMode {
        didSet {
            guard !isBootstrapping else { return }
            defaults.set(traeToolApprovalMode.rawValue, forKey: Keys.traeToolApprovalMode)
        }
    }

    @Published private(set) var idleAutoRoutePromptsToTerminalActive: Bool = false {
        didSet {
            guard !isBootstrapping else { return }
            writeEffectiveBridgeRuntimeConfig()
        }
    }

    var effectiveRoutePromptsToTerminal: Bool {
        routePromptsToTerminal
            || (autoRoutePromptsToTerminalWhenIdleEnabled && idleAutoRoutePromptsToTerminalActive)
    }

    var bridgeRuntimeConfigSnapshot: BridgeRuntimeConfigSnapshot {
        BridgeRuntimeConfigSnapshot(
            routePromptsToTerminal: effectiveRoutePromptsToTerminal,
            debugLoggingEnabled: hookDebugLoggingEnabled,
            debugLogRetentionDays: hookDebugLogRetentionDays,
            debugLogMaxDirectoryMegabytes: hookDebugLogMaxDirectoryMegabytes
        )
    }

    func setIdleAutoRoutePromptsToTerminalActive(_ active: Bool) {
        let next = autoRoutePromptsToTerminalWhenIdleEnabled && active
        guard idleAutoRoutePromptsToTerminalActive != next else { return }
        idleAutoRoutePromptsToTerminalActive = next
    }

    /// 按客户端查询主题包覆盖（仅当 per-client override 开启时生效）
    func mascotOverride(for client: MascotClient) -> MascotKind? {
        guard mascotPerClientOverrideEnabled else { return nil }
        guard let rawValue = mascotThemeOverrides[client.rawValue] else { return nil }
        return MascotKind(rawValue: rawValue)
    }

    /// 解析客户端最终使用的主题包：per-client 覆盖 > 全局选择 > 内置 claude
    func mascotKind(for client: MascotClient) -> MascotKind {
        if let override = mascotOverride(for: client) {
            return override
        }
        return globalMascotKind
    }

    /// client 为 nil 时用全局选择（旧逻辑用 previewMascotKind，现统一到 selectedMascotThemeID）
    func mascotKind(for client: MascotClient?) -> MascotKind {
        guard let client else { return globalMascotKind }
        return mascotKind(for: client)
    }

    /// 全局选中的主题包（selectedMascotThemeID 解析，nil/无效回退 .claude）
    var globalMascotKind: MascotKind {
        guard let id = selectedMascotThemeID, !id.isEmpty else {
            return .claude
        }
        return MascotKind(themeID: id)
    }

    func hasCustomMascot(for client: MascotClient) -> Bool {
        mascotPerClientOverrideEnabled && mascotThemeOverrides[client.rawValue] != nil
    }

    func setMascotOverride(_ mascot: MascotKind?, for client: MascotClient) {
        var updated = mascotThemeOverrides
        if let mascot, mascot != .claude {
            updated[client.rawValue] = mascot.rawValue
        } else {
            updated.removeValue(forKey: client.rawValue)
        }
        mascotThemeOverrides = updated
    }

    /// 设置全局主题包（nil 或 claude 清除，回退到内置 claude）
    func setGlobalMascotThemeID(_ id: String?) {
        selectedMascotThemeID = (id == nil || id == MascotKind.claude.themeID) ? nil : id
    }

    func resetMascotOverrides() {
        mascotThemeOverrides = [:]
        mascotPerClientOverrideEnabled = false
        selectedMascotThemeID = nil
    }

    func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        switch action {
        case .openActiveSession:
            return openActiveSessionShortcut
        case .openSessionList:
            return openSessionListShortcut
        }
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: GlobalShortcutAction) {
        let normalized = Self.sanitizedShortcut(shortcut)

        switch action {
        case .openActiveSession:
            openActiveSessionShortcut = normalized
            if normalized != nil, normalized == openSessionListShortcut {
                openSessionListShortcut = nil
            }
        case .openSessionList:
            openSessionListShortcut = normalized
            if normalized != nil, normalized == openActiveSessionShortcut {
                openActiveSessionShortcut = nil
            }
        }
    }

    func resetShortcut(_ action: GlobalShortcutAction) {
        setShortcut(action.defaultShortcut, for: action)
    }

    /// 重置左侧功能"位置式快捷展开"快捷键为默认 Option + 1
    func resetLeftFeatureQuickExpandShortcut() {
        leftFeatureQuickExpandShortcut = GlobalShortcut.defaultLeftFeatureQuickExpandShortcut
    }

    var customizedMascotClientCount: Int {
        mascotPerClientOverrideEnabled ? mascotThemeOverrides.count : 0
    }

    var locale: Locale {
        appLanguage.resolvedLocale()
    }

    var areNotificationsMutedTemporarily: Bool {
        Self.isNotificationMuteActive(until: temporarilyMuteNotificationsUntil)
    }

    func muteNotifications(for duration: TimeInterval, now: Date = Date()) {
        temporarilyMuteNotificationsUntil = now.addingTimeInterval(duration)
    }

    nonisolated static func isNotificationMuteActive(until date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date > now
    }

    private static func decodeValue<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private static func persistValue<T: Encodable>(
        _ value: T?,
        defaults: UserDefaults,
        key: String
    ) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        guard let data = try? JSONEncoder().encode(value) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private static func boolValue(
        from defaults: UserDefaults,
        key: String,
        exists: Bool,
        default defaultValue: Bool
    ) -> Bool {
        exists ? defaults.bool(forKey: key) : defaultValue
    }

    private static func doubleValue(
        from defaults: UserDefaults,
        key: String,
        exists: Bool,
        default defaultValue: Double
    ) -> Double {
        exists ? defaults.double(forKey: key) : defaultValue
    }

    private static func intValue(
        from defaults: UserDefaults,
        key: String,
        exists: Bool,
        default defaultValue: Int
    ) -> Int {
        exists ? defaults.integer(forKey: key) : defaultValue
    }

    private func containsPersistedValue(forKey key: String) -> Bool {
        defaults.dictionaryRepresentation()[key] != nil
    }

    /// 主题包覆盖 sanitizer：丢弃未知 client、无效主题包 ID、以及等于内置 claude 的条目
    private static func sanitizedMascotThemeOverrides(_ rawOverrides: [String: String]) -> [String: String] {
        rawOverrides.reduce(into: [:]) { result, entry in
            guard let client = MascotClient(rawValue: entry.key),
                  let mascot = MascotKind(rawValue: entry.value),
                  mascot != .claude else {
                return
            }
            result[client.rawValue] = mascot.rawValue
        }
    }

    private static func sanitizedShortcut(_ shortcut: GlobalShortcut?) -> GlobalShortcut? {
        guard let shortcut else { return nil }
        return GlobalShortcut(keyCode: shortcut.keyCode, modifierFlags: shortcut.modifierFlags)
    }

    private static func shortcut(from defaults: UserDefaults, key: String) -> GlobalShortcut? {
        if let shortcut = decodeValue(GlobalShortcut.self, from: defaults, key: key) {
            return sanitizedShortcut(shortcut)
        }

        guard let rawValue = defaults.dictionary(forKey: key) as? [String: Int] else {
            return nil
        }

        guard let keyCode = rawValue["keyCode"],
              let modifiers = rawValue["modifierFlags"] else {
            return nil
        }

        let shortcut = GlobalShortcut(
            keyCode: UInt16(keyCode),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )

        persistValue(shortcut, defaults: defaults, key: key)
        return shortcut
    }

    private static func resolvedShortcut(
        from defaults: UserDefaults,
        key: String,
        disabledKey: String,
        action: GlobalShortcutAction
    ) -> GlobalShortcut? {
        if defaults.bool(forKey: disabledKey) {
            return nil
        }

        let persistedShortcut = shortcut(from: defaults, key: key)

        if let persistedShortcut,
           action.legacyDefaultShortcuts.contains(persistedShortcut) {
            return action.defaultShortcut
        }

        return persistedShortcut ?? action.defaultShortcut
    }

    /// 左侧功能"位置式快捷展开"快捷键的解析：
    /// - `disabledKey` 为 true → nil（用户主动清空）
    /// - 否则取持久化值，缺失时回退默认 `Option + 1`
    private static func resolvedLeftFeatureQuickExpandShortcut(
        from defaults: UserDefaults,
        key: String,
        disabledKey: String
    ) -> GlobalShortcut? {
        if defaults.bool(forKey: disabledKey) {
            return nil
        }
        let persisted = shortcut(from: defaults, key: key)
        return persisted ?? GlobalShortcut.defaultLeftFeatureQuickExpandShortcut
    }

    private static func persistShortcut(
        _ shortcut: GlobalShortcut?,
        defaults: UserDefaults,
        key: String,
        disabledKey: String
    ) {
        defaults.set(shortcut == nil, forKey: disabledKey)
        persistValue(shortcut, defaults: defaults, key: key)
    }

    private static func mascotOverrides(from defaults: UserDefaults, key: String) -> [String: String] {
        if let overrides = decodeValue([String: String].self, from: defaults, key: key) {
            return overrides
        }

        let legacyOverrides = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if !legacyOverrides.isEmpty {
            persistValue(legacyOverrides, defaults: defaults, key: key)
        }

        return legacyOverrides
    }

    nonisolated static func normalizedNotchModuleWidth(_ width: Double) -> Double {
        min(max(width, minimumNotchModuleWidth), maximumNotchModuleWidth)
    }

    init(
        defaults: UserDefaults = .standard,
        bridgeRuntimeConfigWriter: @escaping (BridgeRuntimeConfigSnapshot) -> Void = {
            BridgeRuntimeConfigWriter.write($0)
        }
    ) {
        self.defaults = defaults
        self.bridgeRuntimeConfigWriter = bridgeRuntimeConfigWriter
        self.subagentVisibilityModeStorage = .visible
        let persistedKeys = Set(defaults.dictionaryRepresentation().keys)
        let appLanguageRaw = defaults.string(forKey: Keys.appLanguage)
        let legacyNotificationSound = NotificationSound(
            rawValue: defaults.string(forKey: Keys.notificationSound) ?? ""
        ) ?? .blow
        let usageValueModeRaw = defaults.string(forKey: Keys.usageValueMode)
        let soundThemeModeRaw = defaults.string(forKey: Keys.soundThemeMode)
        let resolvedSoundThemeMode = SoundThemeMode(
            rawValue: soundThemeModeRaw ?? ""
        ) ?? .builtIn
        let subagentVisibilityModeRaw = defaults.string(forKey: Keys.subagentVisibilityMode)
            ?? defaults.string(forKey: Keys.legacyCodexSubagentVisibilityMode)
        let temporarilyMuteNotificationsUntilTimestamp = persistedKeys.contains(Keys.temporarilyMuteNotificationsUntil)
            ? defaults.double(forKey: Keys.temporarilyMuteNotificationsUntil)
            : nil
        // 清理旧版 notchPetStyle 设置（已移除）
        defaults.removeObject(forKey: "notchPetStyle")
        let notchDisplayModeRaw = defaults.string(forKey: Keys.notchDisplayMode)
        let closedNotchTrailingContentModeRaw = defaults.string(forKey: Keys.closedNotchTrailingContentMode)
        let previewMascotKindRaw = defaults.string(forKey: Keys.previewMascotKind)
        let surfaceModeRaw = defaults.string(forKey: Keys.surfaceMode)
        let floatingPetAnchor = Self.decodeValue(FloatingPetAnchor.self, from: defaults, key: Keys.floatingPetAnchor)
        let floatingPetSizeModeRaw = defaults.string(forKey: Keys.floatingPetSizeMode)
        let floatingPetCustomScaleRaw = defaults.object(forKey: Keys.floatingPetCustomScale) as? Double
        let mascotAnimationSpeedRaw = defaults.object(forKey: Keys.mascotAnimationSpeed) as? Double
        let mascotOverrideRaw = Self.mascotOverrides(from: defaults, key: Keys.mascotOverrides)
        // 宠物主题包系统迁移（Task 5）：旧 mascotOverrides / previewMascotKind → 新键
        let hasNewSelectedThemeID = persistedKeys.contains(Keys.selectedMascotThemeID)
        let hasNewThemeOverrides = persistedKeys.contains(Keys.mascotThemeOverrides)
        let hasNewPerClientEnabled = persistedKeys.contains(Keys.mascotPerClientOverrideEnabled)

        // 迁移：旧 mascotOverrides → 新 mascotThemeOverrides（若新键不存在）
        let migratedThemeOverridesRaw: [String: String] = hasNewThemeOverrides
            ? Self.mascotOverrides(from: defaults, key: Keys.mascotThemeOverrides)
            : mascotOverrideRaw
        let migratedThemeOverrides = Self.sanitizedMascotThemeOverrides(migratedThemeOverridesRaw)

        // 迁移：旧 previewMascotKind → 新 selectedMascotThemeID（若新键不存在）
        let migratedSelectedThemeID: String?
        if hasNewSelectedThemeID {
            migratedSelectedThemeID = defaults.string(forKey: Keys.selectedMascotThemeID)
        } else if let legacyRaw = previewMascotKindRaw,
                  let legacyKind = MascotKind(rawValue: legacyRaw),
                  legacyKind != .claude {
            migratedSelectedThemeID = legacyRaw
        } else {
            migratedSelectedThemeID = nil
        }

        // per-client 开关：新键存在则读；否则旧覆盖非空时自动开启
        let migratedPerClientEnabled: Bool = hasNewPerClientEnabled
            ? Self.boolValue(from: defaults, key: Keys.mascotPerClientOverrideEnabled, exists: true, default: false)
            : !migratedThemeOverrides.isEmpty

        // 迁移落地：若新键原本不存在，则把迁移结果写入新键并清除旧键（保证幂等与跨重启存活）
        // Published 初始值不会触发 didSet，故需在此显式持久化新键
        if !hasNewThemeOverrides {
            Self.persistValue(migratedThemeOverrides, defaults: defaults, key: Keys.mascotThemeOverrides)
            if !mascotOverrideRaw.isEmpty {
                defaults.removeObject(forKey: Keys.mascotOverrides)
            }
        }
        if !hasNewSelectedThemeID {
            if let migratedSelectedThemeID {
                defaults.set(migratedSelectedThemeID, forKey: Keys.selectedMascotThemeID)
            }
            if previewMascotKindRaw != nil {
                defaults.removeObject(forKey: Keys.previewMascotKind)
            }
        }
        if !hasNewPerClientEnabled {
            defaults.set(migratedPerClientEnabled, forKey: Keys.mascotPerClientOverrideEnabled)
        }
        let deletedBuiltinMascotThemeIDs = Self.decodeValue(
            Set<String>.self,
            from: defaults,
            key: Keys.deletedBuiltinMascotThemeIDs
        ) ?? Set<String>()
        let openActiveSessionShortcut = Self.resolvedShortcut(
            from: defaults,
            key: Keys.openActiveSessionShortcut,
            disabledKey: Keys.openActiveSessionShortcutDisabled,
            action: .openActiveSession
        )
        let openSessionListShortcut = Self.resolvedShortcut(
            from: defaults,
            key: Keys.openSessionListShortcut,
            disabledKey: Keys.openSessionListShortcutDisabled,
            action: .openSessionList
        )
        let leftFeatureQuickExpandShortcut = Self.resolvedLeftFeatureQuickExpandShortcut(
            from: defaults,
            key: Keys.leftFeatureQuickExpandShortcut,
            disabledKey: Keys.leftFeatureQuickExpandShortcutDisabled
        )
        let temporarilyMuteNotificationsUntil = temporarilyMuteNotificationsUntilTimestamp.map {
            Date(timeIntervalSince1970: $0)
        }
        let activeTemporaryMute =
            Self.isNotificationMuteActive(until: temporarilyMuteNotificationsUntil)
            ? temporarilyMuteNotificationsUntil
            : nil

        _appLanguage = Published(initialValue: AppLanguage(rawValue: appLanguageRaw ?? "") ?? .system)
        _notificationSound = Published(initialValue: legacyNotificationSound)
        _soundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.soundEnabled,
            exists: persistedKeys.contains(Keys.soundEnabled),
            default: true
        ))
        _soundVolume = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.soundVolume,
            exists: persistedKeys.contains(Keys.soundVolume),
            default: 0.9
        ))
        _temporarilyMuteNotificationsUntil = Published(initialValue: activeTemporaryMute)
        _processingStartSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.processingStartSound) ?? ""
        ) ?? .tink)
        _attentionRequiredSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.attentionRequiredSound) ?? ""
        ) ?? .glass)
        _taskCompletedSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.taskCompletedSound) ?? ""
        ) ?? legacyNotificationSound)
        _taskErrorSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.taskErrorSound) ?? ""
        ) ?? .basso)
        _resourceLimitSound = Published(initialValue: NotificationSound(
            rawValue: defaults.string(forKey: Keys.resourceLimitSound) ?? ""
        ) ?? .morse)
        _processingStartSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.processingStartSoundEnabled,
            exists: persistedKeys.contains(Keys.processingStartSoundEnabled),
            default: true
        ))
        _attentionRequiredSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.attentionRequiredSoundEnabled,
            exists: persistedKeys.contains(Keys.attentionRequiredSoundEnabled),
            default: true
        ))
        _taskCompletedSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.taskCompletedSoundEnabled,
            exists: persistedKeys.contains(Keys.taskCompletedSoundEnabled),
            default: true
        ))
        _taskErrorSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.taskErrorSoundEnabled,
            exists: persistedKeys.contains(Keys.taskErrorSoundEnabled),
            default: true
        ))
        _resourceLimitSoundEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.resourceLimitSoundEnabled,
            exists: persistedKeys.contains(Keys.resourceLimitSoundEnabled),
            default: true
        ))
        _soundThemeMode = Published(initialValue: resolvedSoundThemeMode)
        _selectedSoundPackPath = Published(initialValue: defaults.string(forKey: Keys.selectedSoundPackPath) ?? "")
        _hideInFullscreen = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.hideInFullscreen,
            exists: persistedKeys.contains(Keys.hideInFullscreen),
            default: true
        ))
        _autoHideWhenIdle = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoHideWhenIdle,
            exists: persistedKeys.contains(Keys.autoHideWhenIdle),
            default: false
        ))
        _autoCollapseOnLeave = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoCollapseOnLeave,
            exists: persistedKeys.contains(Keys.autoCollapseOnLeave),
            default: true
        ))
        _alwaysExpandFlowIsland = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.alwaysExpandFlowIsland,
            exists: persistedKeys.contains(Keys.alwaysExpandFlowIsland),
            default: false
        ))
        _openOnHover = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.openOnHover,
            exists: persistedKeys.contains(Keys.openOnHover),
            default: true
        ))
        _isPanelPinned = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.isPanelPinned,
            exists: persistedKeys.contains(Keys.isPanelPinned),
            default: false
        ))
        _keepIslandOpen = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.keepIslandOpen,
            exists: persistedKeys.contains(Keys.keepIslandOpen),
            default: false
        ))
        _hoverOpenDelayMs = Published(initialValue: Self.intValue(
            from: defaults,
            key: Keys.hoverOpenDelayMs,
            exists: persistedKeys.contains(Keys.hoverOpenDelayMs),
            default: 240
        ))
        _smartSuppression = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.smartSuppression,
            exists: persistedKeys.contains(Keys.smartSuppression),
            default: true
        ))
        _autoOpenCompactedNotificationPanel = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoOpenCompactedNotificationPanel,
            exists: persistedKeys.contains(Keys.autoOpenCompactedNotificationPanel),
            default: true
        ))
        _compactLeftHeight = Published(initialValue: CGFloat(min(80, max(30, Self.doubleValue(
            from: defaults,
            key: Keys.compactLeftHeight,
            exists: persistedKeys.contains(Keys.compactLeftHeight),
            default: 30
        )))))
        _showCompactHintEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.showCompactHintEnabled,
            exists: persistedKeys.contains(Keys.showCompactHintEnabled),
            default: true
        ))
        _keepWebURLAliveWhenCollapsed = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.keepWebURLAliveWhenCollapsed,
            exists: persistedKeys.contains(Keys.keepWebURLAliveWhenCollapsed),
            default: true
        ))
        _showAgentDetail = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.showAgentDetail,
            exists: persistedKeys.contains(Keys.showAgentDetail),
            default: true
        ))
        subagentVisibilityModeStorage = SubagentVisibilityMode(
            persistedValue: subagentVisibilityModeRaw ?? ""
        ) ?? .visible
        if defaults.string(forKey: Keys.subagentVisibilityMode) == nil {
            defaults.set(subagentVisibilityModeStorage.rawValue, forKey: Keys.subagentVisibilityMode)
        }
        _showUsage = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.showUsage,
            exists: persistedKeys.contains(Keys.showUsage),
            default: true
        ))
        _usageValueMode = Published(initialValue: UsageValueMode(rawValue: usageValueModeRaw ?? "") ?? .remaining)
        _contentFontSize = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.contentFontSize,
            exists: persistedKeys.contains(Keys.contentFontSize),
            default: 13
        ))
        _maxPanelHeight = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.maxPanelHeight,
            exists: persistedKeys.contains(Keys.maxPanelHeight),
            default: 580
        ))
        _expandedPanelWidth = Published(initialValue: Self.doubleValue(
            from: defaults,
            key: Keys.expandedPanelWidth,
            exists: persistedKeys.contains(Keys.expandedPanelWidth),
            default: 500
        ))
        _notchModuleWidth = Published(initialValue: Self.normalizedNotchModuleWidth(Self.doubleValue(
            from: defaults,
            key: Keys.notchModuleWidth,
            exists: persistedKeys.contains(Keys.notchModuleWidth),
            default: Self.defaultNotchModuleWidth
        )))
        _notchDisplayMode = Published(initialValue: NotchDisplayMode(rawValue: notchDisplayModeRaw ?? "") ?? .compact)
        _closedNotchTrailingContentMode = Published(initialValue: ClosedNotchTrailingContentMode(
            rawValue: closedNotchTrailingContentModeRaw ?? ""
        ) ?? .sessionCount)
        _previewMascotKind = Published(initialValue: MascotKind(themeID: migratedSelectedThemeID ?? MascotKind.claude.themeID))
        _selectedMascotThemeID = Published(initialValue: migratedSelectedThemeID)
        _surfaceMode = Published(initialValue: IslandSurfaceMode(rawValue: surfaceModeRaw ?? "") ?? .notch)
        _floatingPetAnchor = Published(initialValue: floatingPetAnchor)
        _floatingPetSizeMode = Published(
            initialValue: FloatingPetSizeMode(rawValue: floatingPetSizeModeRaw ?? "") ?? .automatic
        )
        _floatingPetCustomScale = Published(
            initialValue: CGFloat(floatingPetCustomScaleRaw ?? 0)
        )
        // Spec: 默认 1.0（正常速度）；旧版本无此键时回退到 1.0。clamp 到 0...2 防止脏值。
        let resolvedMascotAnimationSpeed = mascotAnimationSpeedRaw ?? 1.0
        _mascotAnimationSpeed = Published(
            initialValue: min(2.0, max(0.0, resolvedMascotAnimationSpeed))
        )
        _presentationModeOnboardingPending = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.presentationModeOnboardingPending,
            exists: persistedKeys.contains(Keys.presentationModeOnboardingPending),
            default: false
        ))
        _notchDetachmentHintPending = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.notchDetachmentHintPending,
            exists: persistedKeys.contains(Keys.notchDetachmentHintPending),
            default: false
        ))
        _floatingPetSettingsHintPending = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.floatingPetSettingsHintPending,
            exists: persistedKeys.contains(Keys.floatingPetSettingsHintPending),
            default: false
        ))
        _hookInstallOnboardingPending = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.hookInstallOnboardingPending,
            exists: persistedKeys.contains(Keys.hookInstallOnboardingPending),
            default: false
        ))
        _automaticUpdateChecksEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.automaticUpdateChecksEnabled,
            exists: persistedKeys.contains(Keys.automaticUpdateChecksEnabled),
            default: true
        ))
        _mascotOverrides = Published(initialValue: migratedThemeOverrides)
        _mascotThemeOverrides = Published(initialValue: migratedThemeOverrides)
        _mascotPerClientOverrideEnabled = Published(initialValue: migratedPerClientEnabled)
        _deletedBuiltinMascotThemeIDs = Published(initialValue: deletedBuiltinMascotThemeIDs)
        _openActiveSessionShortcut = Published(initialValue: openActiveSessionShortcut)
        _openSessionListShortcut = Published(initialValue: openSessionListShortcut)
        _leftFeatureQuickExpandShortcut = Published(initialValue: leftFeatureQuickExpandShortcut)
        let routePromptsToTerminal = Self.boolValue(
            from: defaults,
            key: Keys.routePromptsToTerminal,
            exists: persistedKeys.contains(Keys.routePromptsToTerminal),
            default: false
        )
        _routePromptsToTerminal = Published(initialValue: routePromptsToTerminal)
        _autoRoutePromptsToTerminalWhenIdleEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.autoRoutePromptsToTerminalWhenIdleEnabled,
            exists: persistedKeys.contains(Keys.autoRoutePromptsToTerminalWhenIdleEnabled),
            default: true
        ))
        _autoRoutePromptsIdleDelay = Published(initialValue: AutoRoutePromptsIdleDelay(
            rawValue: defaults.integer(forKey: Keys.autoRoutePromptsIdleDelay)
        ) ?? .thirtyMinutes)
        _hookDebugLoggingEnabled = Published(initialValue: Self.boolValue(
            from: defaults,
            key: Keys.hookDebugLoggingEnabled,
            exists: persistedKeys.contains(Keys.hookDebugLoggingEnabled),
            default: BridgeRuntimeConfigSnapshot.defaultDebugLoggingEnabled
        ))
        _hookDebugLogRetentionDays = Published(initialValue: BridgeRuntimeConfigSnapshot.clampedDebugLogRetentionDays(
            Self.intValue(
                from: defaults,
                key: Keys.hookDebugLogRetentionDays,
                exists: persistedKeys.contains(Keys.hookDebugLogRetentionDays),
                default: BridgeRuntimeConfigSnapshot.defaultDebugLogRetentionDays
            )
        ))
        _hookDebugLogMaxDirectoryMegabytes = Published(initialValue: BridgeRuntimeConfigSnapshot.clampedDebugLogMaxDirectoryMegabytes(
            Self.intValue(
                from: defaults,
                key: Keys.hookDebugLogMaxDirectoryMegabytes,
                exists: persistedKeys.contains(Keys.hookDebugLogMaxDirectoryMegabytes),
                default: BridgeRuntimeConfigSnapshot.defaultDebugLogMaxDirectoryMegabytes
            )
        ))
        _traeToolApprovalMode = Published(initialValue: IslandToolApprovalMode(
            rawValue: defaults.string(forKey: Keys.traeToolApprovalMode) ?? ""
        ) ?? .prompt)

        if defaults.string(forKey: Keys.soundThemeMode) == nil {
            defaults.set(resolvedSoundThemeMode.rawValue, forKey: Keys.soundThemeMode)
        }
        if activeTemporaryMute == nil {
            defaults.removeObject(forKey: Keys.temporarilyMuteNotificationsUntil)
        }
        if !persistedKeys.contains(Keys.processingStartSoundEnabled) {
            defaults.set(true, forKey: Keys.processingStartSoundEnabled)
        }

        isBootstrapping = false

        writeEffectiveBridgeRuntimeConfig()
    }

    private func writeEffectiveBridgeRuntimeConfig() {
        let config = bridgeRuntimeConfigSnapshot
        bridgeRuntimeConfigWriter(config)
        NotificationCenter.default.post(
            name: .bridgeRuntimeConfigDidChange,
            object: self,
            userInfo: ["config": config]
        )
    }
}

@MainActor
enum AppSettings {
    static var shared: AppSettingsStore { AppSettingsStore.shared }
    nonisolated static let defaultSettingsWindowSize = CGSize(width: 880, height: 550)
    nonisolated static let minimumSettingsWindowSize = CGSize(width: 820, height: 540)
    nonisolated static let maximumSettingsWindowSize = CGSize(width: 1440, height: 1100)
    nonisolated static let notchModuleWidthRange =
        AppSettingsStore.minimumNotchModuleWidth...AppSettingsStore.maximumNotchModuleWidth

    static var notificationSound: NotificationSound {
        get { shared.notificationSound }
        set { shared.notificationSound = newValue }
    }

    static var soundEnabled: Bool {
        get { shared.soundEnabled }
        set { shared.soundEnabled = newValue }
    }

    static var soundVolume: Double {
        get { shared.soundVolume }
        set { shared.soundVolume = newValue }
    }

    static var temporarilyMuteNotificationsUntil: Date? {
        get { shared.temporarilyMuteNotificationsUntil }
        set { shared.temporarilyMuteNotificationsUntil = newValue }
    }

    static var areReminderNotificationsSuppressed: Bool {
        shared.areNotificationsMutedTemporarily
    }

    static var soundThemeMode: SoundThemeMode {
        get { shared.soundThemeMode }
        set { shared.soundThemeMode = newValue }
    }

    static var selectedSoundPackPath: String {
        get { shared.selectedSoundPackPath }
        set { shared.selectedSoundPackPath = newValue }
    }

    static var hideInFullscreen: Bool {
        get { shared.hideInFullscreen }
        set { shared.hideInFullscreen = newValue }
    }

    static var autoHideWhenIdle: Bool {
        get { shared.autoHideWhenIdle }
        set { shared.autoHideWhenIdle = newValue }
    }

    static var autoCollapseOnLeave: Bool {
        get { shared.autoCollapseOnLeave }
        set { shared.autoCollapseOnLeave = newValue }
    }

    static var alwaysExpandFlowIsland: Bool {
        get { shared.alwaysExpandFlowIsland }
        set { shared.alwaysExpandFlowIsland = newValue }
    }

    static var openOnHover: Bool {
        get { shared.openOnHover }
        set { shared.openOnHover = newValue }
    }

    static var isPanelPinned: Bool {
        get { shared.isPanelPinned }
        set { shared.isPanelPinned = newValue }
    }

    static var keepIslandOpen: Bool {
        get { shared.keepIslandOpen }
        set { shared.keepIslandOpen = newValue }
    }

    static var hoverOpenDelayMs: Int {
        get { shared.hoverOpenDelayMs }
        set { shared.hoverOpenDelayMs = newValue }
    }

    static var smartSuppression: Bool {
        get { shared.smartSuppression }
        set { shared.smartSuppression = newValue }
    }

    static var autoOpenCompactedNotificationPanel: Bool {
        get { shared.autoOpenCompactedNotificationPanel }
        set { shared.autoOpenCompactedNotificationPanel = newValue }
    }

    // Spec: compactFeatureID / expandedActiveFeatureID 由 LeftFeatureStore 统一管理，Settings 不再提供静态访问器。

    static var compactLeftHeight: CGFloat {
        get { shared.compactLeftHeight }
        set { shared.compactLeftHeight = newValue }
    }

    static var showCompactHintEnabled: Bool {
        get { shared.showCompactHintEnabled }
        set { shared.showCompactHintEnabled = newValue }
    }

    static var keepWebURLAliveWhenCollapsed: Bool {
        get { shared.keepWebURLAliveWhenCollapsed }
        set { shared.keepWebURLAliveWhenCollapsed = newValue }
    }

    static func muteReminderNotifications(for duration: TimeInterval, now: Date = Date()) {
        shared.muteNotifications(for: duration, now: now)
    }

    static func clearReminderNotificationMute() {
        shared.temporarilyMuteNotificationsUntil = nil
    }

    nonisolated static func isNotificationMuteActive(until date: Date?, now: Date = Date()) -> Bool {
        AppSettingsStore.isNotificationMuteActive(until: date, now: now)
    }

    static var showAgentDetail: Bool {
        get { shared.showAgentDetail }
        set { shared.showAgentDetail = newValue }
    }

    static var subagentVisibilityMode: SubagentVisibilityMode {
        get { shared.subagentVisibilityMode }
        set { shared.subagentVisibilityMode = newValue }
    }

    static var showUsage: Bool {
        get { shared.showUsage }
        set { shared.showUsage = newValue }
    }

    static var usageValueMode: UsageValueMode {
        get { shared.usageValueMode }
        set { shared.usageValueMode = newValue }
    }

    static var contentFontSize: Double {
        get { shared.contentFontSize }
        set { shared.contentFontSize = newValue }
    }

    static var maxPanelHeight: Double {
        get { shared.maxPanelHeight }
        set { shared.maxPanelHeight = newValue }
    }

    static var expandedPanelWidth: Double {
        get { shared.expandedPanelWidth }
        set { shared.expandedPanelWidth = newValue }
    }

    static var notchModuleWidth: Double {
        get { shared.notchModuleWidth }
        set { shared.notchModuleWidth = newValue }
    }

    static var notchDisplayMode: NotchDisplayMode {
        get { shared.notchDisplayMode }
        set { shared.notchDisplayMode = newValue }
    }

    static var closedNotchTrailingContentMode: ClosedNotchTrailingContentMode {
        get { shared.closedNotchTrailingContentMode }
        set { shared.closedNotchTrailingContentMode = newValue }
    }

    static var previewMascotKind: MascotKind {
        get { shared.previewMascotKind }
        set { shared.previewMascotKind = newValue }
    }

    static var surfaceMode: IslandSurfaceMode {
        get { shared.surfaceMode }
        set { shared.surfaceMode = newValue }
    }

    static var floatingPetAnchor: FloatingPetAnchor? {
        get { shared.floatingPetAnchor }
        set { shared.floatingPetAnchor = newValue }
    }

    static var floatingPetSizeMode: FloatingPetSizeMode {
        get { shared.floatingPetSizeMode }
        set { shared.floatingPetSizeMode = newValue }
    }

    static var floatingPetCustomScale: CGFloat {
        get { shared.floatingPetCustomScale }
        set { shared.floatingPetCustomScale = newValue }
    }

    static var mascotAnimationSpeed: Double {
        get { shared.mascotAnimationSpeed }
        set { shared.mascotAnimationSpeed = newValue }
    }

    static var presentationModeOnboardingPending: Bool {
        get { shared.presentationModeOnboardingPending }
        set { shared.presentationModeOnboardingPending = newValue }
    }

    static var notchDetachmentHintPending: Bool {
        get { shared.notchDetachmentHintPending }
        set { shared.notchDetachmentHintPending = newValue }
    }

    static var floatingPetSettingsHintPending: Bool {
        get { shared.floatingPetSettingsHintPending }
        set { shared.floatingPetSettingsHintPending = newValue }
    }

    static var hookInstallOnboardingPending: Bool {
        get { shared.hookInstallOnboardingPending }
        set { shared.hookInstallOnboardingPending = newValue }
    }

    static func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        shared.shortcut(for: action)
    }

    static func setShortcut(_ shortcut: GlobalShortcut?, for action: GlobalShortcutAction) {
        shared.setShortcut(shortcut, for: action)
    }

    static func resetShortcut(_ action: GlobalShortcutAction) {
        shared.resetShortcut(action)
    }

    static func mascotKind(for client: MascotClient) -> MascotKind {
        shared.mascotKind(for: client)
    }

    static func mascotKind(for client: MascotClient?) -> MascotKind {
        shared.mascotKind(for: client)
    }

    static func isSoundEnabled(for event: NotificationEvent) -> Bool {
        switch event {
        case .processingStarted:
            return shared.processingStartSoundEnabled
        case .attentionRequired:
            return shared.attentionRequiredSoundEnabled
        case .taskCompleted:
            return shared.taskCompletedSoundEnabled
        case .taskError:
            return shared.taskErrorSoundEnabled
        case .resourceLimit:
            return shared.resourceLimitSoundEnabled
        }
    }

    static func setSoundEnabled(_ enabled: Bool, for event: NotificationEvent) {
        switch event {
        case .processingStarted:
            shared.processingStartSoundEnabled = enabled
        case .attentionRequired:
            shared.attentionRequiredSoundEnabled = enabled
        case .taskCompleted:
            shared.taskCompletedSoundEnabled = enabled
        case .taskError:
            shared.taskErrorSoundEnabled = enabled
        case .resourceLimit:
            shared.resourceLimitSoundEnabled = enabled
        }
    }

    static func sound(for event: NotificationEvent) -> NotificationSound {
        switch event {
        case .processingStarted:
            return shared.processingStartSound
        case .attentionRequired:
            return shared.attentionRequiredSound
        case .taskCompleted:
            return shared.taskCompletedSound
        case .taskError:
            return shared.taskErrorSound
        case .resourceLimit:
            return shared.resourceLimitSound
        }
    }

    static func setSound(_ sound: NotificationSound, for event: NotificationEvent) {
        switch event {
        case .processingStarted:
            shared.processingStartSound = sound
        case .attentionRequired:
            shared.attentionRequiredSound = sound
        case .taskCompleted:
            shared.taskCompletedSound = sound
        case .taskError:
            shared.taskErrorSound = sound
        case .resourceLimit:
            shared.resourceLimitSound = sound
        }
    }

    static func playSound(named soundName: String?) {
        guard soundEnabled, let soundName else { return }
        guard let sound = NSSound(named: NSSound.Name(soundName)) else { return }
        AppSoundPlayback.shared.play(sound, volume: Float(soundVolume))
    }

    static func playClientStartupSound() {
        // 已移除应用启动音效。
    }

    static func playReleaseNotesSuccessSound() {
        // 已移除内置 8-bit 音效。
    }

    static func playDetachedCapsuleSound() {
        // 已移除内置 8-bit 音效。
    }

    static func playSound(for event: NotificationEvent) {
        guard soundEnabled, isSoundEnabled(for: event) else { return }
        guard !areReminderNotificationsSuppressed else { return }

        switch soundThemeMode {
        case .builtIn:
            playSound(named: sound(for: event).soundName)
        case .soundPack:
            if SoundPackCatalog.shared.play(
                event: event,
                packPath: selectedSoundPackPath,
                volume: Float(soundVolume)
            ) {
                return
            }

            playSound(named: sound(for: event).soundName)
        }
    }

    static func playNotificationSound(_ sound: NotificationSound? = nil) {
        playSound(named: (sound ?? notificationSound).soundName)
    }

}
