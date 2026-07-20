import AppKit
import Carbon.HIToolbox
import Combine

extension Notification.Name {
    static let traeFlowOpenActiveSessionShortcut = Notification.Name("traeFlowOpenActiveSessionShortcut")
    static let traeFlowOpenSessionListShortcut = Notification.Name("traeFlowOpenSessionListShortcut")
    static let traeFlowPresentNotchDetachmentHint = Notification.Name("traeFlowPresentNotchDetachmentHint")
    /// 左侧功能快捷展开；userInfo["featureID"] 为目标 LeftFeature.id
    static let traeFlowExpandLeftFeature = Notification.Name("traeFlowExpandLeftFeature")
}

@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    /// 已注册热键的语义来源。用于在 Carbon 事件回调中反查触发的目标。
    private enum HotKeyEntry: Hashable {
        case action(GlobalShortcutAction)
        case leftFeature(id: String)
        /// 位置式快捷键（修饰键 + 数字 1-9）指向的已启用功能索引（0-based）
        case leftFeaturePositional(index: Int)
    }

    private var hotKeyRefs: [HotKeyEntry: EventHotKeyRef] = [:]
    private var registeredActionsByHotKeyID: [UInt32: HotKeyEntry] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private let signature = GlobalShortcutManager.fourCharCode(from: "PISL")
    private var nextHotKeyID: UInt32 = 100

    /// 数字键 1-9 的 Carbon virtual-key code（位置式快捷展开使用）
    private static let numberKeyCodes: [Int: UInt16] = [
        1: UInt16(kVK_ANSI_1),
        2: UInt16(kVK_ANSI_2),
        3: UInt16(kVK_ANSI_3),
        4: UInt16(kVK_ANSI_4),
        5: UInt16(kVK_ANSI_5),
        6: UInt16(kVK_ANSI_6),
        7: UInt16(kVK_ANSI_7),
        8: UInt16(kVK_ANSI_8),
        9: UInt16(kVK_ANSI_9)
    ]

    private init() {
        installEventHandlerIfNeeded()

        Publishers.CombineLatest(
            AppSettings.shared.$openActiveSessionShortcut,
            AppSettings.shared.$openSessionListShortcut
        )
        .sink { [weak self] _, _ in
            self?.refreshRegistrations()
        }
        .store(in: &cancellables)

        // 修饰键模板变化 → 刷新位置式快捷键注册
        AppSettings.shared.$leftFeatureQuickExpandShortcut
            .sink { [weak self] _ in
                self?.refreshRegistrations()
            }
            .store(in: &cancellables)

        // 功能列表变化（启用/排序/独立快捷键）→ 延后到下一 runloop 刷新，
        // 确保 @Published 变更已落地再读取；debounce 合并连续变更。
        LeftFeatureStore.shared.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshRegistrations()
            }
            .store(in: &cancellables)
    }

    func start() {
        refreshRegistrations()
    }

    private func refreshRegistrations() {
        unregisterAllHotKeys()

        var registeredShortcuts = Set<GlobalShortcut>()

        // 1. 既有全局动作（活跃会话 / 会话列表），优先注册以避免被功能快捷键抢占
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = AppSettings.shortcut(for: action),
                  registeredShortcuts.insert(shortcut).inserted else {
                continue
            }
            register(shortcut, for: .action(action))
        }

        // 2. 位置式快捷展开：修饰键模板 + 数字键 1-9 → 对应序号的已启用功能
        let enabledFeatures = LeftFeatureStore.shared.enabledFeatures
        if let template = AppSettings.shared.leftFeatureQuickExpandShortcut {
            let modifiers = template.modifierFlags
            let maxCount = min(Self.numberKeyCodes.count, enabledFeatures.count)
            for index in 0..<maxCount {
                guard let keyCode = Self.numberKeyCodes[index + 1] else { continue }
                guard let shortcut = GlobalShortcut(keyCode: keyCode, modifierFlags: modifiers),
                      registeredShortcuts.insert(shortcut).inserted else {
                    continue
                }
                register(shortcut, for: .leftFeaturePositional(index: index))
            }
        }

        // 3. 每个已启用功能的独立快捷键（覆盖式：与位置式并存，冲突时位置式优先）
        for feature in enabledFeatures {
            guard let shortcut = feature.customShortcut,
                  registeredShortcuts.insert(shortcut).inserted else {
                continue
            }
            register(shortcut, for: .leftFeature(id: feature.id))
        }
    }

    private func register(_ shortcut: GlobalShortcut, for entry: HotKeyEntry) {
        var hotKeyRef: EventHotKeyRef?
        let carbonID = nextRegistrationID()
        let hotKeyID = EventHotKeyID(signature: signature, id: carbonID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else { return }
        hotKeyRefs[entry] = hotKeyRef
        registeredActionsByHotKeyID[carbonID] = entry
    }

    private func unregisterAllHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        registeredActionsByHotKeyID.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotKeyEvent(event)
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard let entry = registeredActionsByHotKeyID[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }

        switch entry {
        case .action(let action):
            switch action {
            case .openActiveSession:
                NotificationCenter.default.post(name: .traeFlowOpenActiveSessionShortcut, object: nil)
            case .openSessionList:
                NotificationCenter.default.post(name: .traeFlowOpenSessionListShortcut, object: nil)
            }
        case .leftFeature(let id):
            NotificationCenter.default.post(
                name: .traeFlowExpandLeftFeature,
                object: nil,
                userInfo: ["featureID": id]
            )
        case .leftFeaturePositional(let index):
            // 触发时再从 store 解析当前对应功能，避免注册后列表变动导致索引错位
            let enabled = LeftFeatureStore.shared.enabledFeatures
            guard index < enabled.count else {
                return OSStatus(eventNotHandledErr)
            }
            NotificationCenter.default.post(
                name: .traeFlowExpandLeftFeature,
                object: nil,
                userInfo: ["featureID": enabled[index].id]
            )
        }

        return noErr
    }

    private func nextRegistrationID() -> UInt32 {
        defer {
            nextHotKeyID = nextHotKeyID == UInt32.max ? 100 : nextHotKeyID + 1
        }
        return nextHotKeyID
    }

    private static func fourCharCode(from string: String) -> OSType {
        string.utf8.prefix(4).reduce(0) { partial, character in
            (partial << 8) + OSType(character)
        }
    }
}
