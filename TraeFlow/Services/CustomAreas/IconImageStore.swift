import AppKit
import Foundation

/// 功能图标图片存储 —— 把用户选择的图片复制到 `~/Library/Application Support/trae-flow/icons/`
/// 文件名格式 `<featureID>.<ext>`，customIconName 字段存 `img:<filename>`。
/// 通过 `IconImageStore` 统一管理图片的写入、解析与加载。
@MainActor
enum IconImageStore {
    /// 支持的图片扩展名（NSImage 可读）
    static let supportedExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]

    /// 保存图片数据，返回图标标识符 `img:<filename>`
    /// - Parameter data: 图片二进制数据
    /// - Parameter featureID: 关联的功能 ID（用于命名文件，避免冲突）
    /// - Parameter ext: 扩展名（不带点，如 "png"）
    @discardableResult
    static func saveImage(data: Data, for featureID: String, ext: String) -> String? {
        let safeExt = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeExt.isEmpty else { return nil }
        let safeID = sanitizeFilename(featureID)
        let filename = "\(safeID).\(safeExt)"
        let url = BridgeRuntimePaths.iconsDirectoryURL.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return "img:\(filename)"
        } catch {
            NSLog("[IconImageStore] 保存图片失败: \(error)")
            return nil
        }
    }

    /// 解析图标标识符为图片文件 URL
    /// - Parameter iconID: `img:<filename>` 或裸 filename
    /// - Returns: 图片文件完整 URL；非图片标识符返回 nil
    static func imageURL(for iconID: String) -> URL? {
        let filename: String
        if iconID.hasPrefix("img:") {
            filename = String(iconID.dropFirst(4))
        } else {
            return nil
        }
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return BridgeRuntimePaths.iconsDirectoryURL.appendingPathComponent(trimmed)
    }

    /// 加载图片为 NSImage
    static func nsImage(for iconID: String) -> NSImage? {
        guard let url = imageURL(for: iconID) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 将 featureID sanitize 为安全文件名（仅保留字母数字与连字符）
    private static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "icon" }
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|.")
        return trimmed.components(separatedBy: illegal).joined(separator: "-")
    }
}
