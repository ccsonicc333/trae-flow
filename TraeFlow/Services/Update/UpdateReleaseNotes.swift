import Foundation

struct UpdateReleaseNotes: Equatable, Sendable {
    let currentVersion: String
    let targetVersion: String
    let markdown: String
    let sourceURL: URL?
    let publishedAt: Date?

    var sections: [UpdateReleaseNotesSection] {
        UpdateReleaseNotesParser.sections(from: markdown)
    }

    func sections(locale: Locale) -> [UpdateReleaseNotesSection] {
        UpdateReleaseNotesParser.sections(from: markdown, locale: locale)
    }

    func localizedMarkdown(locale: Locale) -> String {
        UpdateReleaseNotesParser.localizedMarkdown(from: markdown, locale: locale)
    }
}

struct UpdateReleaseNotesSection: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let markdown: String

    var blocks: [UpdateReleaseNotesBlock] {
        UpdateReleaseNotesMarkdownParser.blocks(from: markdown)
    }

    var iconSymbolName: String {
        let normalizedTitle = title.lowercased()

        if normalizedTitle.contains("亮点") || normalizedTitle.contains("highlight") {
            return "sparkles"
        }

        if normalizedTitle.contains("修复") || normalizedTitle.contains("fix") {
            return "wrench.and.screwdriver"
        }

        if normalizedTitle.contains("说明") || normalizedTitle.contains("note") {
            return "info.circle"
        }

        if normalizedTitle.contains("关联 pr") || normalizedTitle.contains("related pr") || normalizedTitle.contains("pr") {
            return "arrow.triangle.branch"
        }

        return "doc.text"
    }
}

enum UpdateReleaseNotesBlock: Equatable, Sendable {
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case codeBlock(language: String?, code: String)
    case heading(level: Int, text: String)
    case divider
}

enum UpdateReleaseNotesParser {
    static func sections(from markdown: String, locale: Locale? = nil) -> [UpdateReleaseNotesSection] {
        let normalized = localizedMarkdown(from: markdown, locale: locale)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        var sections: [UpdateReleaseNotesSection] = []
        var currentTitle = "更新内容"
        var currentLines: [String] = []
        var sectionIndex = 0

        for line in normalized.components(separatedBy: "\n") {
            if let heading = headingTitle(in: line) {
                if !currentLines.isEmpty {
                    sections.append(
                        UpdateReleaseNotesSection(
                            id: "\(sectionIndex)-\(currentTitle)",
                            title: currentTitle,
                            markdown: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    sectionIndex += 1
                    currentLines.removeAll(keepingCapacity: true)
                }

                currentTitle = heading
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            sections.append(
                UpdateReleaseNotesSection(
                    id: "\(sectionIndex)-\(currentTitle)",
                    title: currentTitle,
                    markdown: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return sections.filter { !$0.markdown.isEmpty }
    }

    static func localizedMarkdown(from markdown: String, locale: Locale?) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return ""
        }

        let blocks = localizedBlocks(from: normalized)
        guard !blocks.isEmpty else {
            return normalized
        }

        let preferredLanguage = preferredLanguageCode(for: locale)
        if let preferredBlock = blocks[preferredLanguage] {
            return preferredBlock
        }

        if preferredLanguage != "en", let englishBlock = blocks["en"] {
            return englishBlock
        }

        return blocks.values.first ?? normalized
    }

    private static func headingTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else {
            return nil
        }

        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredLanguageCode(for locale: Locale?) -> String {
        let languageCode = locale?.identifier.lowercased() ?? "en"
        return languageCode.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    private static func localizedBlocks(from markdown: String) -> [String: String] {
        let lines = markdown.components(separatedBy: "\n")
        var commonLines: [String] = []
        var currentLanguage: String?
        var blocks: [String: [String]] = [:]

        for line in lines {
            if let languageMarker = languageMarker(in: line) {
                currentLanguage = languageMarker
                if blocks[languageMarker] == nil {
                    blocks[languageMarker] = []
                }
                continue
            }

            if let currentLanguage {
                blocks[currentLanguage, default: []].append(line)
            } else {
                commonLines.append(line)
            }
        }

        return blocks.reduce(into: [:]) { partialResult, entry in
            let mergedLines = (commonLines + entry.value)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !mergedLines.isEmpty {
                partialResult[entry.key] = mergedLines
            }
        }
    }

    private static func languageMarker(in line: String) -> String? {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "<!-- zh-Hans -->":
            return "zh-Hans"
        case "<!-- en -->":
            return "en"
        default:
            return nil
        }
    }
}

enum UpdateReleaseNotesMarkdownParser {
    static func blocks(from markdown: String) -> [UpdateReleaseNotesBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [UpdateReleaseNotesBlock] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listStyle: ListStyle?
        var codeFenceLanguage: String?
        var codeLines: [String] = []
        var quoteLines: [String] = []
        var isInCodeFence = false

        func flushParagraph() {
            let text = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                paragraphLines.removeAll(keepingCapacity: true)
                return
            }
            blocks.append(.paragraph(text))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            let items = listItems
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty, let currentListStyle = listStyle else {
                listItems.removeAll(keepingCapacity: true)
                listStyle = nil
                return
            }

            switch currentListStyle {
            case .unordered:
                blocks.append(.unorderedList(items))
            case .ordered:
                blocks.append(.orderedList(items))
            }

            listItems.removeAll(keepingCapacity: true)
            listStyle = nil
        }

        func flushQuote() {
            let quote = quoteLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else {
                quoteLines.removeAll(keepingCapacity: true)
                return
            }
            blocks.append(.quote(quote))
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushCodeBlock() {
            let code = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            guard !code.isEmpty else {
                codeFenceLanguage = nil
                codeLines.removeAll(keepingCapacity: true)
                return
            }
            blocks.append(.codeBlock(language: codeFenceLanguage, code: code))
            codeFenceLanguage = nil
            codeLines.removeAll(keepingCapacity: true)
        }

        func flushAllInlineBlocks() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInCodeFence {
                if trimmed.hasPrefix("```") {
                    flushCodeBlock()
                    isInCodeFence = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushAllInlineBlocks()
                codeFenceLanguage = fenceLanguage(fromFence: trimmed)
                isInCodeFence = true
                continue
            }

            if trimmed.isEmpty {
                flushAllInlineBlocks()
                continue
            }

            if isDivider(trimmed) {
                flushAllInlineBlocks()
                blocks.append(.divider)
                continue
            }

            if let heading = heading(from: trimmed) {
                flushAllInlineBlocks()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let listItem = listItem(from: line) {
                flushParagraph()
                flushQuote()

                if listStyle != nil, listStyle != listItem.style {
                    flushList()
                }

                listStyle = listItem.style
                listItems.append(listItem.text)
                continue
            }

            if let listStyle, isListContinuation(line) {
                switch listStyle {
                case .unordered, .ordered:
                    guard !listItems.isEmpty else { continue }
                    let continuation = trimmed
                    if !continuation.isEmpty {
                        listItems[listItems.count - 1] += "\n" + continuation
                    }
                }
                continue
            }

            if let quoteLine = quoteLine(from: trimmed) {
                flushParagraph()
                flushList()
                quoteLines.append(quoteLine)
                continue
            }

            paragraphLines.append(line)
        }

        if isInCodeFence {
            flushCodeBlock()
        }

        flushAllInlineBlocks()
        return blocks
    }

    private enum ListStyle {
        case unordered
        case ordered
    }

    private static func fenceLanguage(fromFence line: String) -> String? {
        let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped == "---" || stripped == "***"
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }

        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else {
            return nil
        }

        let text = line.dropFirst(level + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func quoteLine(from line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return line.drop { $0 == ">" || $0 == " " }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListContinuation(_ line: String) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    private static func listItem(from line: String) -> (style: ListStyle, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (.unordered, text)
        }

        let scanner = Scanner(string: trimmed)
        guard let number = scanner.scanInt(),
              number >= 0 else {
            return nil
        }

        guard scanner.scanString(".") != nil || scanner.scanString(")") != nil else {
            return nil
        }

        _ = scanner.scanString(" ")
        let text = String(trimmed[scanner.currentIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (.ordered, text)
    }
}
