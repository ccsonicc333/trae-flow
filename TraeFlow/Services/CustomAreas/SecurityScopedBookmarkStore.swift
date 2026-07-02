import AppKit
import Foundation

/// Spec: 沙箱外自定义目录已通过 Security-Scoped Bookmark 或合适权限保持持久访问
///
/// 管理 Security-Scoped Bookmark：当用户选择沙箱外的目录时，
/// 创建 bookmark 并持久化，后续访问时 resolving 为可访问的 URL。
enum SecurityScopedBookmarkStore {
    private static let defaultsKey = "traeFlowCustomAreaBookmarks"

    // MARK: - Save

    /// 为指定目录创建 Security-Scoped Bookmark 并持久化
    static func saveBookmark(for url: URL) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = loadAllBookmarkData()
            bookmarks[url.path] = bookmarkData
            saveAllBookmarkData(bookmarks)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Resolve

    /// 解析指定路径的 bookmark，返回可访问的 URL（需调用 startAccessing）
    static func resolveURL(for path: String) -> URL? {
        let bookmarks = loadAllBookmarkData()
        guard let data = bookmarks[path] else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Bookmark 过期，尝试重新创建
                _ = saveBookmark(for: url)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Spec: 删除自定义区域目录时仅移除引用，不删除用户原始文件夹
    /// 但应清理对应的 bookmark
    static func removeBookmark(for path: String) {
        var bookmarks = loadAllBookmarkData()
        bookmarks.removeValue(forKey: path)
        saveAllBookmarkData(bookmarks)
    }

    // MARK: - Access Helpers

    /// 在闭包内安全访问沙箱外目录
    static func withAccess<T>(to path: String, _ block: (URL) -> T?) -> T? {
        guard let url = resolveURL(for: path) else {
            // 非 bookmark 目录（内置目录），直接访问
            let directURL = URL(fileURLWithPath: path, isDirectory: true)
            return block(directURL)
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return block(url)
    }

    // MARK: - Persistence

    private static func loadAllBookmarkData() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return [:]
        }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: data) as? [String: Data]) ?? [:]
    }

    private static func saveAllBookmarkData(_ bookmarks: [String: Data]) {
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: bookmarks as NSDictionary,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Codex 宠物目录书签

extension SecurityScopedBookmarkStore {
    /// codex 宠物目录的安全书签 key（独立于自定义区域 bookmark 字典，避免互相污染）
    private static let codexPetsBookmarkKey = "traeFlowCodexPetsBookmark"

    /// 保存 codex 宠物目录书签
    static func saveCodexPetsBookmark(for url: URL) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: codexPetsBookmarkKey)
            return true
        } catch {
            return false
        }
    }

    /// 解析 codex 宠物目录书签，返回可访问的 URL（需调用 startAccessing）
    /// - Returns: `(url, isStale)`；无书签返回 nil
    static func resolveCodexPetsBookmark() -> (url: URL, isStale: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: codexPetsBookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            return nil
        }
    }

    /// 清除 codex 宠物目录书签
    static func removeCodexPetsBookmark() {
        UserDefaults.standard.removeObject(forKey: codexPetsBookmarkKey)
    }

    /// 在闭包内安全访问 codex 宠物目录
    /// 沙盒构建下从书签恢复 URL 并 startAccessing；非沙盒直接用原 URL
    static func withCodexPetsAccess<T>(_ block: (URL) -> T?) -> T? {
        return block(UserHomeDirectoryResolver.codexPetsDirectory)
    }
}
