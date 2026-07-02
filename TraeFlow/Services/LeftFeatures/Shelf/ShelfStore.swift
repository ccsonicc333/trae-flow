import Combine
import Foundation
import AppKit

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []

    private init() {}

    // MARK: - Add

    /// 拖入文件。沙箱外文件通过 SecurityScopedBookmarkStore 持久化 bookmark。
    func add(url: URL) {
        // 避免重复添加同一文件
        if items.contains(where: { $0.fileURL == url }) { return }

        let name = url.lastPathComponent
        let size = fileSize(at: url)
        let bookmarkData = saveBookmarkIfNeeded(for: url)

        let item = ShelfItem(
            name: name,
            fileURL: url,
            size: size,
            bookmarkData: bookmarkData
        )
        items.append(item)
    }

    // MARK: - Remove

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
    }

    /// 清空所有条目（应用退出时调用）
    func clear() {
        items.removeAll()
    }

    // MARK: - AirDrop

    func airDropAll() {
        airDrop(items: items)
    }

    func airDrop(ids: [UUID]) {
        let selected = items.filter { ids.contains($0.id) }
        airDrop(items: selected)
    }

    private func airDrop(items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let urls = items.map { $0.fileURL }
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 沙箱外文件通过 SecurityScopedBookmarkStore 持久化 bookmark。
    /// 非沙箱环境下 bookmark 仍可保存，便于后续恢复访问。
    private func saveBookmarkIfNeeded(for url: URL) -> Data? {
        _ = SecurityScopedBookmarkStore.saveBookmark(for: url)
        return try? url.bookmarkData(options: [],
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
    }
}
