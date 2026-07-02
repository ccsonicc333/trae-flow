import Foundation
import AppKit

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var name: String
    var fileURL: URL
    var size: Int64
    /// 沙箱外文件通过 SecurityScopedBookmarkStore 持久化的 bookmark data
    var bookmarkData: Data?

    init(id: UUID = UUID(),
         name: String,
         fileURL: URL,
         size: Int64,
         bookmarkData: Data? = nil) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.size = size
        self.bookmarkData = bookmarkData
    }

    /// 文件图标（从系统获取）
    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: fileURL.path)
    }

    /// 格式化的文件大小
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
