import Foundation
import AppKit

/// Spec: 自动获取网站 favicon 并缓存到本地 `~/Library/Application Support/trae-flow/icons/`。
///
/// 抓取策略（按顺序尝试，首个成功即返回）：
/// 1. 站点根目录 `/favicon.ico`（最通用，国内可达）
/// 2. 解析站点首页 HTML 中的 `<link rel="icon" ...>` / `<link rel="shortcut icon" ...>`，按尺寸降序选最大
/// 3. `https://icons.duckduckgo.com/ip3/<host>.ico`（国外聚合服务，国内可能不可达）
/// 4. `https://www.google.com/s2/favicons?domain=<host>&sz=64`（国外聚合服务，国内可能不可达）
///
/// 严格校验：
/// - 响应 Content-Type 以 `image/` 开头，**或** 数据 magic bytes 匹配 PNG/JPEG/GIF/ICO/BMP
/// - `NSImage(data:)` 解码成功且 `size.width >= 8 && size.height >= 8`
/// - 拒绝把 HTML 错误页（content-type: text/html）当成图标
///
/// 缓存：
/// - 命中磁盘缓存（`favicon-<sanitized-host>.png`）时直接返回 NSImage
/// - 网络抓取成功后重编码为 PNG 写入磁盘
/// - 失败时不缓存，下次仍会重试
///
/// 调用方典型用法：`FaviconFetcher.fetch(for: url) { iconID in ... }`，
/// `iconID` 形如 `img:favicon-example.com.png`，可直接写入 `LeftFeature.customIconName`。
enum FaviconFetcher {
    /// 单个候选请求超时（秒）—— 缩短到 6s 避免国内不可达的聚合服务拖慢整体
    private static let timeout: TimeInterval = 6

    /// 抓取 favicon，结果回调在主线程。
    /// - Parameter url: 网站完整 URL（仅取 host 部分用于构造请求）
    /// - Parameter completion: 主线程回调；成功返回 `img:<filename>` 标识符，失败返回 nil。
    static func fetch(for url: URL, completion: @escaping (String?) -> Void) {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // 1. 磁盘缓存命中
        if let cached = loadFromDisk(host: host) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        // Spec: 候选顺序 —— 站点 /favicon.ico（国内可达）→ HTML 解析（国内可达）→ 聚合服务（国内可能不可达）
        // 把聚合服务放最后，避免国内用户等 12s 超时才到 HTML 解析
        // 实现方式：先试站点 /favicon.ico，失败后先走 HTML 解析，再试聚合服务
        let origin = "\(scheme)://\(host)"
        var candidates: [Candidate] = []
        if let u = URL(string: "\(origin)/favicon.ico") {
            candidates.append(Candidate(url: u, referer: origin))
        }
        // 聚合服务放最后
        if let u = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") {
            candidates.append(Candidate(url: u, referer: nil))
        }
        if let u = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") {
            candidates.append(Candidate(url: u, referer: nil))
        }

        // Spec: 站点 /favicon.ico 失败后先走 HTML 解析（国内可达），再试聚合服务
        // 通过 splitCandidatesAtHTMLParsing 把候选列表分成「站点 /favicon.ico」和「聚合服务」两段，
        // 中间插入 HTML 解析
        tryCandidatesWithHTMLFallback(
            firstCandidates: [candidates[0]],
            htmlOrigin: origin,
            remainingCandidates: Array(candidates.dropFirst()),
            host: host,
            completion: completion
        )
    }

    /// Spec: 先试 firstCandidates，全失败后走 HTML 解析，再走 remainingCandidates。
    private static func tryCandidatesWithHTMLFallback(
        firstCandidates: [Candidate],
        htmlOrigin: String,
        remainingCandidates: [Candidate],
        host: String,
        completion: @escaping (String?) -> Void
    ) {
        tryCandidates(candidates: firstCandidates, host: host, origin: htmlOrigin) { result in
            if let result {
                DispatchQueue.main.async { completion(result) }
                return
            }
            // firstCandidates 全失败 → 尝试 HTML 解析
            tryHTMLParsing(host: host, origin: htmlOrigin) { htmlResult in
                if let htmlResult {
                    DispatchQueue.main.async { completion(htmlResult) }
                    return
                }
                // HTML 解析也失败 → 走剩余聚合服务候选
                tryCandidates(candidates: remainingCandidates, host: host, origin: htmlOrigin, completion: completion)
            }
        }
    }

    /// 候选请求：URL + Referer（站点自身请求需带 Referer 避免部分站点拒绝）
    private struct Candidate {
        let url: URL
        let referer: String?
    }

    /// 依次尝试候选 URL，首个成功即保存并回调；全部失败回调 nil。
    /// Spec: 不再自动 fallback 到 HTML 解析（由 `tryCandidatesWithHTMLFallback` 统一控制顺序）。
    private static func tryCandidates(candidates: [Candidate],
                                      host: String,
                                      origin: String,
                                      completion: @escaping (String?) -> Void) {
        guard !candidates.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let next = candidates[0]
        let rest = Array(candidates.dropFirst())
        var request = URLRequest(url: next.url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        // 模拟浏览器 UA，避免部分站点拒绝
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        if let referer = next.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        request.setValue("image/png,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  isValidImageData(data: data, response: http),
                  let image = NSImage(data: data),
                  image.isValid,
                  image.size.width >= 8, image.size.height >= 8 else {
                tryCandidates(candidates: rest, host: host, origin: origin, completion: completion)
                return
            }
            // 保存到磁盘缓存（统一重编码为 PNG）
            let iconID = saveToDisk(data: data, host: host)
            DispatchQueue.main.async { completion(iconID) }
        }
        task.resume()
    }

    /// 解析站点首页 HTML，提取 `<link rel="icon" ...>` / `<link rel="shortcut icon" ...>` 的 href。
    /// 按 sizes 降序选最大尺寸；无 sizes 取第一个。
    private static func tryHTMLParsing(host: String,
                                       origin: String,
                                       completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(origin)/") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // 提取所有 <link rel="icon" ...> 与 <link rel="shortcut icon" ...>
            let iconURLs = extractIconURLs(from: html, origin: origin)
            guard !iconURLs.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // 转为候选列表（带 Referer = origin）
            let candidates = iconURLs.map { Candidate(url: $0, referer: origin) }
            tryCandidates(candidates: candidates, host: host, origin: origin, completion: completion)
        }
        task.resume()
    }

    /// 从 HTML 中提取 `<link rel="icon">` / `<link rel="shortcut icon">` 的 href，
    /// 按 `sizes` 属性降序排序（优先大尺寸）。
    private static func extractIconURLs(from html: String, origin: String) -> [URL] {
        // 简易正则匹配 <link ... rel="...icon..." ... href="...">
        let pattern = #"<link[^>]*rel\s*=\s*["']\s*(?:shortcut\s+icon|icon|apple-touch-icon)[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        // 解析每个 link 标签的 href 与 sizes
        struct IconLink {
            let url: URL
            let size: Int
        }
        var links: [IconLink] = []
        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            // 提取 href
            guard let href = extractAttribute(tag: tag, attribute: "href"), !href.isEmpty else { continue }
            // 解析为绝对 URL
            let absolute: URL?
            if href.hasPrefix("http://") || href.hasPrefix("https://") {
                absolute = URL(string: href)
            } else if href.hasPrefix("//") {
                absolute = URL(string: "https:\(href)")
            } else if href.hasPrefix("/") {
                absolute = URL(string: "\(origin)\(href)")
            } else {
                absolute = URL(string: "\(origin)/\(href)")
            }
            guard let url = absolute else { continue }
            // 解析 sizes（如 "48x48" / "16x16 32x32 64x64"）
            let sizeStr = extractAttribute(tag: tag, attribute: "sizes") ?? ""
            let maxSize = sizeStr
                .split(separator: " ")
                .compactMap { token -> Int? in
                    let parts = token.split(separator: "x")
                    guard parts.count == 2, let w = Int(parts[0]) else { return nil }
                    return w
                }
                .max() ?? 0
            // apple-touch-icon 通常是 180x180 高清版，加权
            let rel = extractAttribute(tag: tag, attribute: "rel") ?? ""
            let sizeScore = rel.contains("apple-touch") ? maxSize + 1000 : maxSize
            links.append(IconLink(url: url, size: sizeScore))
        }
        // 按尺寸降序
        return links.sorted { $0.size > $1.size }.map(\.url)
    }

    /// 从单个标签字符串中提取指定属性的值。
    private static func extractAttribute(tag: String, attribute: String) -> String? {
        // 匹配 attribute="value" 或 attribute='value'
        // 注意：["'] 是字符类（非捕获组），整个正则只有 1 个捕获组 `([^"']*)`
        let pattern = #"\#(attribute)\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        if let match = regex.firstMatch(in: tag, options: [], range: range),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: tag) {
            return String(tag[valueRange])
        }
        return nil
    }

    /// 校验响应数据是否为真实图片：
    /// - Content-Type 以 `image/` 开头，**或**
    /// - 数据 magic bytes 匹配 PNG/JPEG/GIF/BMP/ICO
    /// 拒绝 content-type: text/html 的错误页伪装。
    private static func isValidImageData(data: Data, response: HTTPURLResponse) -> Bool {
        // magic bytes 优先（content-type 可能不准）
        if data.count >= 4 {
            // PNG: 89 50 4E 47
            if data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return true }
            // JPEG: FF D8 FF
            if data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return true }
            // GIF: 47 49 46 38
            if data[0] == 0x47, data[1] == 0x49, data[2] == 0x46, data[3] == 0x38 { return true }
            // BMP: 42 4D
            if data[0] == 0x42, data[1] == 0x4D { return true }
            // ICO: 00 00 01 00
            if data[0] == 0x00, data[1] == 0x00, data[2] == 0x01, data[3] == 0x00 { return true }
            // WEBP: RIFF .... WEBP
            if data.count >= 12,
               data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
               data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return true }
            // SVG: 以 "<" 开头且包含 "<svg"
            if data[0] == 0x3C, let str = String(data: data, encoding: .utf8),
               str.contains("<svg") { return true }
        }
        // 兜底：content-type 以 image/ 开头
        if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.hasPrefix("image/") {
            return true
        }
        return false
    }

    /// 同步加载磁盘缓存的 favicon 标识符（若有）。
    /// 文件名格式 `favicon-<sanitized-host>.png`。
    private static func loadFromDisk(host: String) -> String? {
        let sanitized = sanitizeHost(host)
        let dir = BridgeRuntimePaths.iconsDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let filename = "favicon-\(sanitized).png"
        if entries.contains(where: { $0.lastPathComponent == filename }) {
            return "img:\(filename)"
        }
        return nil
    }

    /// 保存到磁盘缓存，返回 `img:<filename>` 标识符。
    /// 通过 NSImage 重新编码为 PNG，统一格式避免老 ico 格式无法读取。
    private static func saveToDisk(data: Data, host: String) -> String? {
        let sanitized = sanitizeHost(host)
        let filename = "favicon-\(sanitized).png"
        let url = BridgeRuntimePaths.iconsDirectoryURL.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 重新编码为 PNG 统一格式
            if let image = NSImage(data: data),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: url, options: [.atomic])
            } else {
                // 重新编码失败则写原始数据
                try data.write(to: url, options: [.atomic])
            }
            return "img:\(filename)"
        } catch {
            NSLog("[FaviconFetcher] 保存 favicon 失败 host=\(host): \(error)")
            return nil
        }
    }

    /// 将 host sanitize 为安全文件名（仅保留字母数字、点、连字符）。
    private static func sanitizeHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "unknown" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return trimmed.components(separatedBy: allowed.inverted).joined(separator: "-")
    }

    // MARK: - Site Metadata (favicon + title)

    /// 网站元数据：favicon 图标标识符 + 站点标题。
    struct SiteMetadata {
        let iconID: String?
        let title: String?
    }

    /// 并行获取网站 favicon + 标题，两者独立失败，任一成功即填入。
    /// 结果回调在主线程。
    static func fetchMetadata(for url: URL, completion: @escaping (SiteMetadata) -> Void) {
        let group = DispatchGroup()
        var iconID: String?
        var title: String?

        group.enter()
        fetch(for: url) { result in
            iconID = result
            group.leave()
        }
        group.enter()
        fetchSiteTitle(for: url) { result in
            title = result
            group.leave()
        }
        group.notify(queue: .main) {
            completion(SiteMetadata(iconID: iconID, title: title))
        }
    }

    /// 获取站点首页 `<title>` 标签内容，清理常见后缀（如 " - GitHub" → "GitHub"）。
    /// 失败回调 nil（主线程）。
    /// Spec: 与 favicon 抓取独立，复用 HTML 解析的请求（但为简化逻辑单独发请求，超时 6s）。
    static func fetchSiteTitle(for url: URL, completion: @escaping (String?) -> Void) {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let origin = "\(scheme)://\(host)"
        guard let pageURL = URL(string: "\(origin)/") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: pageURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let title = extractTitle(from: html)?.cleanedSiteTitle
            DispatchQueue.main.async { completion(title) }
        }
        task.resume()
    }

    /// 从 HTML 提取 `<title>...</title>` 内容（大小写不敏感）。
    private static func extractTitle(from html: String) -> String? {
        let pattern = #"<title[^>]*>([^<]*)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let titleRange = Range(match.range(at: 1), in: html) {
            let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

/// 站点标题清理：去除常见后缀分隔符（" - xxx" / " | xxx" / " · xxx"），
/// 保留首段作为简洁名称。如 "GitHub - Let's build from here" → "GitHub"。
private extension String {
    /// 清理站点标题为简洁名称。
    /// 优先在常见分隔符 ` - ` / ` | ` / ` · ` / ` — ` 处取首段；
    /// 若清理后为空则返回原标题。
    var cleanedSiteTitle: String {
        let separators = [" - ", " | ", " · ", " — ", " – ", " :: "]
        for sep in separators {
            if let range = self.range(of: sep) {
                let first = String(self[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !first.isEmpty { return first }
            }
        }
        return self
    }
}
