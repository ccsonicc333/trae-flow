import Combine
import Foundation

/// codex 宠物目录的沙盒访问状态
///
/// - 非沙盒构建始终为 `.notRequired`
/// - 沙盒构建根据书签是否存在与是否过期返回对应状态
enum CodexPetsAccessStatus: Equatable, Sendable {
    /// 非沙盒构建，无需授权
    case notRequired
    /// 沙盒构建，尚未授权（无书签）
    case notAuthorized
    /// 沙盒构建，已授权（URL 是从书签恢复的目录）
    case authorized(URL)
    /// 沙盒构建，书签失效但已自动重建
    case stale(URL)
}

/// 主题包扫描器：合并内置 / codex / user 三源主题包，按 ID 去重（后者覆盖前者）
///
/// 扫描顺序与优先级（同 ID 后加载者覆盖先加载者）：
/// 1. 内置主题包（`BuiltInMascotThemes.allThemes`）
/// 2. `$HOME/.codex/pets/`（codex CLI 已安装宠物）
/// 3. `$HOME/.traeflow/pets/`（用户自装，优先级最高）
///
/// 沙盒构建（APP_STORE）下 codex 目录访问通过 `SecurityScopedBookmarkStore`
/// 的安全书签授权；非沙盒构建直接读取。`codexPetsAccessStatus` 暴露当前授权状态供 UI 消费。
@MainActor
final class MascotThemeScanner: ObservableObject {
    static let shared = MascotThemeScanner()

    /// 已扫描到的主题包（按 内置 → codex → user 顺序合并去重后）
    @Published private(set) var themes: [MascotTheme] = []
    /// 扫描过程中跳过的无效主题包数量（pet.json 缺失/解析失败/spritesheet 不存在）
    @Published private(set) var skippedCount: Int = 0
    /// 上次扫描时间
    @Published private(set) var lastScanDate: Date?
    /// codex 宠物目录的当前沙盒访问状态（供设置页 UI 决定是否提示授权）
    @Published private(set) var codexPetsAccessStatus: CodexPetsAccessStatus = .notRequired

    private let watcher: MascotThemeWatcher
    private var cancellables: Set<AnyCancellable> = []

    init(watcher: MascotThemeWatcher = .shared) {
        self.watcher = watcher
        self.codexPetsAccessStatus = Self.currentCodexPetsAccess().status
        Task { @MainActor in
            self.bindWatcher()
            await self.rescan()
        }
    }

    /// 立即重新扫描（绕过节流）
    func rescanNow() async {
        await rescan()
    }

    /// 按 ID 查找主题包
    func theme(forID id: String) -> MascotTheme? {
        themes.first { $0.id == id }
    }

    /// 删除指定主题包
    ///
    /// 非内置主题包会同时清理 `~/.traeflow/pets/` 和 `~/.codex/pets/` 下同名的目录，
    /// 避免扫描合并后 codex 副本继续显示在列表中。
    /// 内置主题包无法真正从 App Bundle 删除，改为记录到 `deletedBuiltinMascotThemeIDs`
    /// 并在扫描时过滤掉，从而实现“删除”效果；用户可通过恢复默认入口还原。
    /// 若当前选中的正是被删除主题，会恢复为默认主题。
    func deleteTheme(_ theme: MascotTheme) async {
        let themeID = theme.id
        if theme.source == .builtin {
            AppSettings.shared.deletedBuiltinMascotThemeIDs.insert(themeID)
        } else {
            let candidates = [
                UserHomeDirectoryResolver.traeFlowPetsDirectory.appendingPathComponent(themeID),
                UserHomeDirectoryResolver.codexPetsDirectory.appendingPathComponent(themeID)
            ]
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if AppSettings.shared.selectedMascotThemeID == themeID {
            AppSettings.shared.setGlobalMascotThemeID(nil)
        }
        await rescan()
    }

    /// 恢复所有被删除的内置主题包
    func restoreDeletedBuiltinThemes() async {
        AppSettings.shared.deletedBuiltinMascotThemeIDs.removeAll()
        await rescan()
    }

    /// 用户通过 NSOpenPanel 授权 codex 宠物目录后调用
    /// 保存安全书签并立即重扫，使新授权的目录下的主题包立即可用
    func requestCodexPetsAccess(url: URL) async {
        _ = SecurityScopedBookmarkStore.saveCodexPetsBookmark(for: url)
        await rescan()
    }

    /// 从 codex 同步主题包到 `~/.traeflow/pets/`
    ///
    /// 遍历 `~/.codex/pets/` 下所有子目录（不校验 pet.json，复制全部子目录），
    /// 复制到 `~/.traeflow/pets/`，目标已存在时跳过以保留用户自定义。
    /// 复制完成后立即触发 rescan。
    /// 沙盒构建下通过 `SecurityScopedBookmarkStore.withCodexPetsAccess` 访问 codex 目录；
    /// 未授权时 codexURL 为 nil，直接返回空结果。
    ///
    /// - Returns: `(synced: 新复制数量, skipped: 已存在跳过数量, failed: 失败的目录名列表)`
    @discardableResult
    func syncFromCodex() async -> (synced: Int, skipped: Int, failed: [String]) {
        let codexURL: URL? = SecurityScopedBookmarkStore.withCodexPetsAccess { url in url }
        let result = await Self.performSyncFromCodex(
            codexURL: codexURL,
            destinationURL: UserHomeDirectoryResolver.traeFlowPetsDirectory
        )
        await rescan()
        return result
    }

    // MARK: - Private

    private func bindWatcher() {
        watcher.didChange
            .debounce(for: .seconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.rescan() }
            }
            .store(in: &cancellables)
    }

    /// 计算当前 codex 宠物目录的访问状态与可访问 URL
    ///
    /// - 非沙盒构建：始终 `.notRequired`，URL 为 `codexPetsDirectory`
    /// - 沙盒构建：根据书签是否存在与是否过期返回对应状态；未授权时 URL 为 nil
    nonisolated static func currentCodexPetsAccess() -> (status: CodexPetsAccessStatus, url: URL?) {
        return (.notRequired, UserHomeDirectoryResolver.codexPetsDirectory)
    }

    /// 同步纯函数：从 codex 目录复制所有子目录到 trae-flow 目录
    ///
    /// - 目标已存在时跳过
    /// - 目标根目录不存在时先创建
    /// - codexURL 为 nil 时返回空结果（沙盒未授权场景）
    /// - 失败的目录收集到 failed 列表，不阻塞其他目录复制
    nonisolated static func performSyncFromCodex(
        codexURL: URL?,
        destinationURL: URL
    ) async -> (synced: Int, skipped: Int, failed: [String]) {
        guard let codexURL else { return (0, 0, []) }
        let fileManager = FileManager.default

        // 确保 destination 存在
        try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: codexURL.path) else {
            return (0, 0, [])
        }

        var synced = 0
        var skipped = 0
        var failed: [String] = []

        guard let contents = try? fileManager.contentsOfDirectory(
            at: codexURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0, [])
        }

        for entry in contents {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            let destEntry = destinationURL.appendingPathComponent(entry.lastPathComponent)

            if fileManager.fileExists(atPath: destEntry.path) {
                skipped += 1
                continue
            }

            do {
                try fileManager.copyItem(at: entry, to: destEntry)
                synced += 1
            } catch {
                failed.append(entry.lastPathComponent)
            }
        }

        return (synced, skipped, failed)
    }

    private func rescan() async {
        var merged: [String: MascotTheme] = [:]
        var skipped = 0
        let deletedBuiltinIDs = AppSettings.shared.deletedBuiltinMascotThemeIDs

        // 1. 内置主题包（用户删除的内置主题不再显示；user/codex 同名主题可继续覆盖）
        for theme in BuiltInMascotThemes.allThemes where !deletedBuiltinIDs.contains(theme.id) {
            merged[theme.id] = theme
        }

        // 2. codex 已安装（沙盒未授权时跳过；授权后走安全书签作用域访问）
        let codexAccess = Self.currentCodexPetsAccess()
        codexPetsAccessStatus = codexAccess.status
        if let codexResult = SecurityScopedBookmarkStore.withCodexPetsAccess({ url in
            Self.scanDirectory(at: url, source: .codex)
        }) {
            for theme in codexResult.themes { merged[theme.id] = theme }
            skipped += codexResult.skipped
        }

        // 3. 用户自装
        let userResult = Self.scanDirectory(
            at: UserHomeDirectoryResolver.traeFlowPetsDirectory,
            source: .user
        )
        for theme in userResult.themes { merged[theme.id] = theme }
        skipped += userResult.skipped

        themes = merged.values.sorted { lhs, rhs in
            if lhs.manifest.id == BuiltInMascotThemes.defaultThemeID { return true }
            if rhs.manifest.id == BuiltInMascotThemes.defaultThemeID { return false }
            return lhs.manifest.id < rhs.manifest.id
        }
        self.skippedCount = skipped
        self.lastScanDate = Date()

        // 更新监听列表：沙盒未授权时不监听 codex 目录（目录不存在时 watcher 内部也会跳过）
        var watchDirectories: [URL] = [UserHomeDirectoryResolver.traeFlowPetsDirectory]
        if let codexURL = codexAccess.url {
            watchDirectories.insert(codexURL, at: 0)
        }
        watcher.observe(directories: watchDirectories)
    }

    /// 扫描单个根目录下的所有一级子目录，每个子目录视为一个主题包
    ///
    /// 纯函数（无单例依赖），供 Scanner 内部与单元测试调用。
    /// 跳过规则：
    /// - 非目录文件（如 `.DS_Store`）
    /// - `pet.json` 缺失
    /// - `pet.json` JSON 解析失败
    /// - spritesheet 文件不存在
    ///
    /// - Parameters:
    ///   - rootURL: 主题包根目录（如 `$HOME/.codex/pets/`）
    ///   - source: 来源标记（用于 `MascotTheme.source`）
    /// - Returns: `(themes: 有效主题包列表, skipped: 跳过数量)`
    nonisolated static func scanDirectory(
        at rootURL: URL,
        source: MascotThemeSource
    ) -> (themes: [MascotTheme], skipped: Int) {
        let fileManager = FileManager.default

        // 根目录不存在视为空结果（不计入 skipped，避免首次安装时误报）
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return (themes: [], skipped: 0)
        }

        var themeEntries: [MascotTheme] = []
        var skipped = 0

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (themes: [], skipped: 0)
        }

        // 遍历一级子目录（深度限制 1，避免递归进深层）
        // NSDirectoryEnumerator 的 nextObject 在 Swift 里桥接为 Any，需要 cast 为 URL
        var visited: Set<String> = []
        let rootPath = rootURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            // 只处理 rootURL 的直接子目录
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            guard parentPath == rootPath else { continue }

            let standardizedPath = url.standardizedFileURL.path
            guard !visited.contains(standardizedPath) else { continue }
            visited.insert(standardizedPath)

            // 跳过非目录文件（.DS_Store 等）
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else {
                skipped += 1
                continue
            }

            // 读 pet.json
            let manifestURL = url.appendingPathComponent("pet.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL) else {
                skipped += 1
                continue
            }

            // 解析 manifest
            let manifest: MascotThemeManifest
            do {
                manifest = try JSONDecoder().decode(MascotThemeManifest.self, from: data)
            } catch {
                skipped += 1
                continue
            }

            // 校验 spritesheet 文件存在
            let theme = MascotTheme(
                manifest: manifest,
                rootURL: url,
                source: source
            )
            // 内置 claude 主题包走占位 rootURL，跳过文件存在性校验；
            // 但此处扫描的是 codex/user 目录，不应出现 claude 占位，仍按文件存在性校验
            guard fileManager.fileExists(atPath: theme.spritesheetURL.path) else {
                skipped += 1
                continue
            }

            themeEntries.append(theme)
        }

        return (themes: themeEntries, skipped: skipped)
    }
}
