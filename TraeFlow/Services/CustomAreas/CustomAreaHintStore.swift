import Combine
import Foundation

/// 自定义 HTML 区域通过 JS Bridge 推送到紧凑态 Flow 岛的"提示"数据模型
struct CustomAreaHint: Equatable, Identifiable {
    let id: UUID
    let areaID: String
    let text: String
    /// 过期时间；到期后提示自动消失
    let expirationDate: Date

    init(areaID: String, text: String, duration: TimeInterval, now: Date = Date()) {
        self.id = UUID()
        self.areaID = areaID
        self.text = text
        self.expirationDate = now.addingTimeInterval(duration)
    }
}

/// Spec: 自定义 HTML 提示状态注册中心
/// 接收来自 `CustomAreaWebView` JS Bridge 的 `traeFlowHint` 消息，
/// 持有当前活跃提示并在超时后自动清除。
/// 紧凑态视图通过 `currentHint(for:)` 查询当前 areaID 是否有未过期提示。
@MainActor
final class CustomAreaHintStore: ObservableObject {
    static let shared = CustomAreaHintStore()

    /// 默认显示时长（毫秒），JS 未指定 duration 时使用
    static let defaultDurationMs: Int = 5000

    /// 当前活跃提示列表（按推送顺序）
    @Published private(set) var activeHints: [CustomAreaHint] = []

    /// 当 areaID 对应的提示过期或被清除时触发，供订阅者刷新
    let hintDidChange = PassthroughSubject<String, Never>()

    private var dismissWorkItems: [UUID: DispatchWorkItem] = [:]
    private let queue = DispatchQueue.main

    private init() {}

    /// 发布提示
    /// - Parameters:
    ///   - areaID: 来源自定义区域 ID
    ///   - text: 提示文本
    ///   - durationMs: 显示时长（毫秒），<=0 时使用默认值 5000ms
    func postHint(areaID: String, text: String, durationMs: Int) {
        let duration = max(TimeInterval(durationMs <= 0 ? Self.defaultDurationMs : durationMs) / 1000.0, 0.5)
        let hint = CustomAreaHint(areaID: areaID, text: text, duration: duration)

        NSLog("[traeFlowHint] postHint 存储提示 areaID=\(areaID) text=\(text) duration=\(duration)s")

        // 清除该 areaID 之前的提示（同一区域只保留最新一条）
        clearHint(for: areaID)

        activeHints.append(hint)
        hintDidChange.send(areaID)

        NSLog("[traeFlowHint] postHint 完成，当前活跃提示数=\(activeHints.count)")

        // 排期自动清除
        let workItem = DispatchWorkItem { [weak self] in
            self?.removeHint(hintID: hint.id)
        }
        dismissWorkItems[hint.id] = workItem
        queue.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    /// 查询某 areaID 当前是否有未过期提示
    func currentHint(for areaID: String) -> CustomAreaHint? {
        activeHints.first { $0.areaID == areaID }
    }

    /// 当前所有活跃提示中最新的一条（跨区域）。
    /// 紧凑态左半区优先渲染该提示，到期后自动回退到原选中的功能。
    var mostRecentHint: CustomAreaHint? {
        activeHints.last
    }

    /// 手动清除某 areaID 的提示
    func clearHint(for areaID: String) {
        let toRemove = activeHints.filter { $0.areaID == areaID }
        for hint in toRemove {
            removeHint(hintID: hint.id)
        }
    }

    /// 清除所有提示
    func clearAll() {
        for workItem in dismissWorkItems.values {
            workItem.cancel()
        }
        dismissWorkItems.removeAll()
        let removedAreaIDs = Set(activeHints.map(\.areaID))
        activeHints.removeAll()
        for areaID in removedAreaIDs {
            hintDidChange.send(areaID)
        }
    }

    private func removeHint(hintID: UUID) {
        guard let index = activeHints.firstIndex(where: { $0.id == hintID }) else { return }
        let hint = activeHints.remove(at: index)
        dismissWorkItems[hintID]?.cancel()
        dismissWorkItems.removeValue(forKey: hintID)
        hintDidChange.send(hint.areaID)
    }
}
