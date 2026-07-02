//
//  HookInstaller.swift
//  TraeFlow
//
//  Installs and manages hook integrations for supported clients.
//

import AppKit
import Foundation

private enum HookConfigParser {
    static func parseJSONObject(from data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let sanitized = removeTrailingCommas(from: stripJSONComments(from: string))
        guard let sanitizedData = sanitized.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any]
    }

    private static func stripJSONComments(from string: String) -> String {
        var output = ""
        var index = string.startIndex
        var isInsideString = false
        var isEscaping = false
        var isLineComment = false
        var isBlockComment = false

        while index < string.endIndex {
            let character = string[index]
            let nextIndex = string.index(after: index)
            let nextCharacter = nextIndex < string.endIndex ? string[nextIndex] : nil

            if isLineComment {
                if character == "\n" {
                    isLineComment = false
                    output.append(character)
                }
                index = nextIndex
                continue
            }

            if isBlockComment {
                if character == "\n" {
                    output.append(character)
                } else if character == "*", nextCharacter == "/" {
                    isBlockComment = false
                    index = string.index(after: nextIndex)
                    continue
                }
                index = nextIndex
                continue
            }

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                isLineComment = true
                index = string.index(after: nextIndex)
                continue
            }

            if character == "/", nextCharacter == "*" {
                isBlockComment = true
                index = string.index(after: nextIndex)
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func removeTrailingCommas(from string: String) -> String {
        let characters = Array(string)
        var output = ""
        var index = 0
        var isInsideString = false
        var isEscaping = false

        while index < characters.count {
            let character = characters[index]

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                isInsideString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }

                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output
    }
}

struct TOMLHookConfigParser {
    struct TOMLHookEntry: Equatable {
        let event: String
        let command: String
        let matcher: String?
        let timeout: Int?
    }

    enum TOMLSegment: Equatable {
        case text(String)
        case hook(TOMLHookEntry)
    }

    static func parse(_ content: String) -> [TOMLSegment] {
        var segments: [TOMLSegment] = []
        let lines = content.components(separatedBy: .newlines)
        var textBuffer: [String] = []
        var currentHookFields: [String: String] = [:]
        var isInHooksBlock = false

        func flushText() {
            if !textBuffer.isEmpty {
                segments.append(.text(textBuffer.joined(separator: "\n")))
                textBuffer = []
            }
        }

        func flushHook() {
            if let entry = makeEntry(from: currentHookFields) {
                segments.append(.hook(entry))
            }
            currentHookFields = [:]
            isInHooksBlock = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[[hooks]]") {
                if isInHooksBlock {
                    flushHook()
                }
                flushText()
                isInHooksBlock = true
                currentHookFields = [:]
                continue
            }

            if isInHooksBlock,
               (trimmed.hasPrefix("[[") && !trimmed.hasPrefix("[[hooks]]"))
                || (trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[")) {
                flushHook()
                textBuffer.append(line)
                continue
            }

            if isInHooksBlock {
                if let (key, value) = parseKeyValue(line) {
                    currentHookFields[key] = value
                }
                // Blank lines inside hooks are ignored; they don't terminate the block
            } else {
                textBuffer.append(line)
            }
        }

        if isInHooksBlock {
            flushHook()
        }
        flushText()

        return segments
    }

    static func rebuild(segments: [TOMLSegment], newHooks: [TOMLHookEntry]) -> String {
        var output = ""
        var hasTrailingNewline = false

        for segment in segments {
            switch segment {
            case .text(let text):
                if !output.isEmpty, !hasTrailingNewline {
                    output += "\n"
                }
                output += text
                hasTrailingNewline = text.hasSuffix("\n") || text.isEmpty
            case .hook(let entry):
                if !islandManaged(entry) {
                    if !output.isEmpty, !hasTrailingNewline {
                        output += "\n"
                    }
                    output += renderHook(entry)
                    hasTrailingNewline = true
                }
            }
        }

        for entry in newHooks {
            if !output.isEmpty, !hasTrailingNewline {
                output += "\n"
            }
            output += renderHook(entry)
            hasTrailingNewline = true
        }

        return output
    }

    static func containsManagedHooks(_ content: String) -> Bool {
        parse(content).contains { segment in
            if case .hook(let entry) = segment {
                return islandManaged(entry)
            }
            return false
        }
    }

    static func islandManaged(_ entry: TOMLHookEntry) -> Bool {
        entry.command.contains("trae-flow-bridge")
    }

    static func makeEntry(from fields: [String: String]) -> TOMLHookEntry? {
        guard let event = fields["event"] else { return nil }
        let command = fields["command"] ?? ""
        let matcher = fields["matcher"]
        let timeout = fields["timeout"].flatMap(Int.init)
        return TOMLHookEntry(event: event, command: command, matcher: matcher, timeout: timeout)
    }

    static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eqIndex = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var rawValue = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
        // Strip inline TOML comments (simple heuristic: unquoted #)
        rawValue = stripInlineComment(rawValue)
        let value = stripTOMLQuotes(rawValue)
        return (key, value)
    }

    static func stripInlineComment(_ value: String) -> String {
        var inString = false
        var stringChar: Character? = nil
        for (index, char) in value.enumerated() {
            if inString {
                if char == stringChar {
                    inString = false
                    stringChar = nil
                }
                continue
            }
            if char == "\"" || char == "'" {
                inString = true
                stringChar = char
                continue
            }
            if char == "#" {
                return value[..<value.index(value.startIndex, offsetBy: index)].trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    static func stripTOMLQuotes(_ value: String) -> String {
        var result = value
        if result.hasPrefix("\""), result.hasSuffix("\"") {
            result = String(result.dropFirst().dropLast())
        } else if result.hasPrefix("'"), result.hasSuffix("'") {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    static func renderHook(_ entry: TOMLHookEntry) -> String {
        var lines = ["[[hooks]]"]
        lines.append("event = \"\(entry.event)\"")
        lines.append("command = \"\(entry.command.replacingOccurrences(of: "\"", with: "\\\""))\"")
        if let matcher = entry.matcher {
            lines.append("matcher = \"\(matcher.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        if let timeout = entry.timeout {
            lines.append("timeout = \(timeout)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct HookInstaller {
    struct BridgeHealthStatus: Equatable {
        let isHealthy: Bool
        let message: String
    }

    private static let preferredTargetsDefaultsKey = "HookInstaller.preferredTargets.v1"
    private static let eventSelectionsDefaultsKey = "HookInstaller.eventSelections.v1"
    private static let installedVersionDefaultsKey = "HookInstaller.installedVersion.v1"
    private static let firstLaunchDefaultsKey = "HookInstaller.isFirstLaunch.v1"
    private static let versionMetadataDefaultsKey = "HookInstaller.versionMetadata.v1"
    private static let supportDirectoryName = ".trae-flow"
    private static let bridgeLauncherName = "trae-flow-bridge"
    private static let bridgeBinaryName = "TraeFlowBridge"
    private static let legacyBridgeBinaryName = "IslandBridge"
    private static let statusLineScriptName = "island-statusline"

    private struct VersionMetadata: Codable {
        let version: String
        let build: String
        let installedAt: String
        let previousVersion: String

        var dictionaryValue: [String: Any] {
            [
                "version": version,
                "build": build,
                "installedAt": installedAt,
                "previousVersion": previousVersion
            ]
        }
    }

    private static func decodeValue<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private static func persistValue<T: Encodable>(_ value: T?, defaults: UserDefaults, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }

        guard let data = try? JSONEncoder().encode(value) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private static var defaultPreferredTargets: Set<String> {
        Set(
            ClientProfileRegistry.managedHookProfiles
                .filter { $0.defaultEnabled && canManage($0) }
                .map(\.id)
        )
    }

    /// Install managed hooks for preferred clients on app launch.
    static func installIfNeeded(
        markPresentationOnboardingPending: (() -> Void)? = nil,
        markHookInstallOnboardingPending: (() -> Void)? = nil
    ) {
        // Check if this is first launch and perform auto-integration
        let isFirstLaunch = checkAndMarkFirstLaunch(
            markPresentationOnboardingPending: markPresentationOnboardingPending
        )

        let preferredTargets = preferredTargets()

        installBridgeLauncherIfNeeded()
        removeLegacyTraeHooks()

        if isFirstLaunch {
            // Defer auto-install of default-enabled profiles to the first-run welcome
            // sheet so the user can choose between defaults and a customized selection.
            if let markHookInstallOnboardingPending {
                markHookInstallOnboardingPending()
            } else {
                UserDefaults.standard.set(true, forKey: AppSettingsDefaultKeys.hookInstallOnboardingPending)
            }
            updateVersionMetadata()
            return
        }

        for profile in ClientProfileRegistry.managedHookProfiles {
            if preferredTargets.contains(profile.id) && canManage(profile) {
                install(profile, persistPreference: false, bypassAvailabilityCheck: false)
            } else {
                uninstall(profile, persistPreference: false)
            }
        }

        // Update version metadata after installation
        updateVersionMetadata()
    }

    /// Run the default first-run install for every defaultEnabled profile.
    static func performFirstRunDefaultInstall() {
        installBridgeLauncherIfNeeded()
        for profile in ClientProfileRegistry.managedHookProfiles where profile.defaultEnabled {
            guard canManage(profile) else { continue }
            install(profile, persistPreference: true, bypassAvailabilityCheck: false)
        }
    }


    static func defaultEnabledManageableProfiles() -> [ManagedHookClientProfile] {
        ClientProfileRegistry.managedHookProfiles.filter { profile in
            profile.defaultEnabled && canManage(profile)
        }
    }

    @MainActor
    static func bridgeHealthStatus() -> BridgeHealthStatus {
        installBridgeLauncherIfNeeded()

        let launcherURL = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(bridgeLauncherName)
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            return BridgeHealthStatus(
                isHealthy: false,
                message: AppLocalization.string("Bridge launcher 未安装或不可执行")
            )
        }

        guard preferredBridgeBinaryURL() != nil else {
            return BridgeHealthStatus(
                isHealthy: false,
                message: AppLocalization.string("TraeFlowBridge 二进制缺失")
            )
        }

        guard launcherContainsCurrentRuntimeEnvironment(launcherURL) else {
            return BridgeHealthStatus(
                isHealthy: false,
                message: AppLocalization.string("Bridge launcher 需要重新安装以更新运行时环境")
            )
        }

        let socketPath = BridgeRuntimePaths.socketPath
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return BridgeHealthStatus(
                isHealthy: false,
                message: AppLocalization.string("Bridge 监听尚未启动，请保持 TRAE FLOW 正在运行后重试")
            )
        }

        guard runBridgeLauncherHealthCheck(launcherURL) else {
            return BridgeHealthStatus(
                isHealthy: false,
                message: AppLocalization.string("Bridge launcher 自检失败，请重启 TRAE FLOW 后重新安装 Hooks")
            )
        }

        return BridgeHealthStatus(
            isHealthy: true,
            message: AppLocalization.string("Bridge 链路正常，Hooks 事件可转发到当前 App")
        )
    }

    /// Check if this is the first launch and mark as installed
    static func checkAndMarkFirstLaunch(
        defaults: UserDefaults = .standard,
        markPresentationOnboardingPending: (() -> Void)? = nil
    ) -> Bool {

        // Check if we've already recorded a version
        if defaults.string(forKey: installedVersionDefaultsKey) != nil {
            return false
        }

        // First launch - mark it
        defaults.set(true, forKey: firstLaunchDefaultsKey)
        if let markPresentationOnboardingPending {
            markPresentationOnboardingPending()
        } else {
            defaults.set(true, forKey: AppSettingsDefaultKeys.presentationModeOnboardingPending)
        }
        return true
    }

    /// Update version metadata for tracking updates
    private static func updateVersionMetadata() {
        let defaults = UserDefaults.standard
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let versionMetadata = VersionMetadata(
            version: currentVersion,
            build: currentBuild,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            previousVersion: defaults.string(forKey: installedVersionDefaultsKey) ?? ""
        )

        defaults.set(currentVersion, forKey: installedVersionDefaultsKey)
        persistValue(versionMetadata, defaults: defaults, key: versionMetadataDefaultsKey)
    }

    /// Get the installed version metadata
    static func getVersionMetadata() -> [String: Any]? {
        let defaults = UserDefaults.standard

        if let metadata = decodeValue(VersionMetadata.self, from: defaults, key: versionMetadataDefaultsKey) {
            return metadata.dictionaryValue
        }

        guard let legacyMetadata = defaults.dictionary(forKey: versionMetadataDefaultsKey) else {
            return nil
        }

        guard let version = legacyMetadata["version"] as? String,
              let build = legacyMetadata["build"] as? String,
              let installedAt = legacyMetadata["installedAt"] as? String,
              let previousVersion = legacyMetadata["previousVersion"] as? String else {
            return legacyMetadata
        }

        let metadata = VersionMetadata(
            version: version,
            build: build,
            installedAt: installedAt,
            previousVersion: previousVersion
        )
        persistValue(metadata, defaults: defaults, key: versionMetadataDefaultsKey)
        return metadata.dictionaryValue
    }

    /// Check if this is a fresh install (never installed before)
    static func isFreshInstall() -> Bool {
        return UserDefaults.standard.string(forKey: installedVersionDefaultsKey) == nil
    }

    /// Get the current installed version
    static func getInstalledVersion() -> String? {
        return UserDefaults.standard.string(forKey: installedVersionDefaultsKey)
    }

    static func install(_ profile: ManagedHookClientProfile) {
        install(profile, persistPreference: true)
    }

    static func install(_ profile: ManagedHookClientProfile, selection: HookInstallSelection) {
        if profile.supportsEventSelection {
            saveSelection(selection, for: profile)
        }
        install(profile, persistPreference: true)
    }

    static func loadSelection(for profile: ManagedHookClientProfile) -> HookInstallSelection {
        guard profile.supportsEventSelection else {
            return HookInstallSelection.defaultSelection(for: profile)
        }
        guard let stored = UserDefaults.standard.dictionary(forKey: eventSelectionsDefaultsKey) as? [String: [String]],
              let names = stored[profile.id] else {
            return HookInstallSelection.defaultSelection(for: profile)
        }
        let validNames = Set(profile.events.map(\.name))
        let filtered = Set(names).intersection(validNames)
        guard !filtered.isEmpty else {
            return HookInstallSelection.defaultSelection(for: profile)
        }
        return HookInstallSelection(enabledEventNames: filtered)
    }

    static func saveSelection(_ selection: HookInstallSelection, for profile: ManagedHookClientProfile) {
        var stored = (UserDefaults.standard.dictionary(forKey: eventSelectionsDefaultsKey) as? [String: [String]]) ?? [:]
        stored[profile.id] = Array(selection.enabledEventNames).sorted()
        UserDefaults.standard.set(stored, forKey: eventSelectionsDefaultsKey)
    }

    private static func effectiveEvents(for profile: ManagedHookClientProfile) -> [HookInstallEventDescriptor] {
        guard profile.supportsEventSelection else { return profile.events }
        return loadSelection(for: profile).filteredEvents(for: profile)
    }

    static func createTemporarySettingsFile(for profileID: String) -> URL? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: profileID) else {
            return nil
        }

        installBridgeLauncherIfNeeded()

        let directory = islandSupportDirectory()
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("native-runtime-hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(profile.id)-\(UUID().uuidString).json")
        let command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)
        var hooks: [String: Any] = [:]
        for event in effectiveEvents(for: profile) {
            hooks[event.name] = makeHookEntries(command: command, event: event)
        }
        writeJSONObject(["hooks": hooks], to: fileURL)
        return fileURL
    }

    static func removeTemporarySettingsFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func reinstall(_ profile: ManagedHookClientProfile) {
        uninstall(profile, persistPreference: false)
        install(profile, persistPreference: true)
    }

    static func uninstall(_ profile: ManagedHookClientProfile) {
        uninstall(profile, persistPreference: true)
    }

    /// Check if any managed hooks are currently installed.
    static func isInstalled() -> Bool {
        ClientProfileRegistry.managedHookProfiles.contains { isInstalled($0) }
    }

    static func isInstalled(_ profile: ManagedHookClientProfile) -> Bool {
        switch profile.installationKind {
        case .jsonHooks:
            return profile.configurationURLs.contains { containsManagedHooks(at: $0, profile: profile) }
        case .pluginFile:
            return profile.configurationURLs.contains { containsManagedPlugin(at: $0, profile: profile) }
                && isManagedPluginEnabled(profile)
        case .pluginDirectory:
            return profile.configurationURLs.contains { containsManagedPluginDirectory(at: $0, profile: profile) }
        case .hookDirectory:
            return profile.configurationURLs.contains { containsManagedHookDirectory(at: $0, profile: profile) }
                && isInternalHookEnabled(profile)
        case .tomlHooks:
            return profile.configurationURLs.contains { containsManagedTOMLHooks(at: $0) }
        }
    }

    /// Uninstall hooks for all managed targets.
    static func uninstall() {
        for profile in ClientProfileRegistry.managedHookProfiles {
            uninstall(profile, persistPreference: false)
        }
        persistPreferredTargets(Set<String>())
    }

    private static func install(
        _ profile: ManagedHookClientProfile,
        persistPreference: Bool,
        bypassAvailabilityCheck: Bool = false
    ) {
        if persistPreference {
            var targets = preferredTargets()
            targets.insert(profile.id)
            persistPreferredTargets(targets)
        }

        guard bypassAvailabilityCheck || canManage(profile) else {
            return
        }

        installBridgeLauncherIfNeeded()
        switch profile.installationKind {
        case .jsonHooks:
            for url in installationTargets(for: profile) {
                updateHooks(at: url, profile: profile)
            }
        case .pluginFile:
            for url in installationTargets(for: profile) {
                writeManagedPlugin(at: url, profile: profile)
            }
            setManagedPluginEnabled(true, for: profile)
        case .pluginDirectory:
            for url in installationTargets(for: profile) {
                writeManagedPluginDirectory(at: url, profile: profile)
            }
        case .hookDirectory:
            for url in installationTargets(for: profile) {
                writeManagedHookDirectory(at: url, profile: profile)
            }
            setInternalHookEnabled(true, for: profile)
        case .tomlHooks:
            for url in installationTargets(for: profile) {
                updateTOMLHooks(at: url, profile: profile)
            }
        }
    }

    private static func uninstall(_ profile: ManagedHookClientProfile, persistPreference: Bool) {
        if persistPreference {
            var targets = preferredTargets()
            targets.remove(profile.id)
            persistPreferredTargets(targets)
        }

        switch profile.installationKind {
        case .jsonHooks:
            for url in profile.configurationURLs {
                removeManagedHooks(at: url, profile: profile)
            }
        case .pluginFile:
            for url in profile.configurationURLs {
                removeManagedPlugin(at: url, profile: profile)
            }
            setManagedPluginEnabled(false, for: profile)
        case .pluginDirectory:
            for url in profile.configurationURLs {
                removeManagedPluginDirectory(at: url, profile: profile)
            }
        case .hookDirectory:
            for url in profile.configurationURLs {
                removeManagedHookDirectory(at: url, profile: profile)
            }
            setInternalHookEnabled(false, for: profile)
        case .tomlHooks:
            for url in profile.configurationURLs {
                removeManagedTOMLHooks(at: url)
            }
        }
    }

    private static func canManage(_ profile: ManagedHookClientProfile) -> Bool {
        profile.alwaysVisibleInSettings
            || ClientAppLocator.isInstalled(bundleIdentifiers: profile.localAppBundleIdentifiers)
    }

    private static func preferredTargets() -> Set<String> {
        guard let values = UserDefaults.standard.stringArray(forKey: preferredTargetsDefaultsKey) else {
            return defaultPreferredTargets
        }

        let targets = Set(values.compactMap { value in
            ClientProfileRegistry.managedHookProfile(id: value)?.id
        })

        // 迁移兜底：若持久化的 profile id 全部失效（例如从旧的按变体拆分 profile
        // `trae` / `trae-cn` 迁移到合并后的 `trae-hooks` / `trae-cn-hooks`），
        // 回退到默认启用集合，避免因 id 不匹配而把所有 hooks 卸载。
        if targets.isEmpty {
            return defaultPreferredTargets
        }

        return targets
    }

    private static func persistPreferredTargets(_ targets: Set<String>) {
        let values = targets.sorted()
        UserDefaults.standard.set(values, forKey: preferredTargetsDefaultsKey)
    }

    private static func installationTargets(for profile: ManagedHookClientProfile) -> [URL] {
        let existingTargets = profile.configurationURLs.filter { url in
            let fileManager = FileManager.default
            return fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: url.deletingLastPathComponent().path)
        }

        return existingTargets.isEmpty ? [profile.primaryConfigurationURL] : existingTargets
    }

    private static func isInternalHookEnabled(_ profile: ManagedHookClientProfile) -> Bool {
        guard let url = profile.activationConfigurationURL,
              let entryName = profile.activationEntryName,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        return isInternalHookEnabled(existingData: data, entryName: entryName)
    }

    private static func isManagedPluginEnabled(_ profile: ManagedHookClientProfile) -> Bool {
        managedPluginActivationConfigurationURLs(for: profile).contains { url in
            guard let data = try? Data(contentsOf: url) else {
                return false
            }
            return isManagedPluginEnabled(
                existingData: data,
                pluginURL: profile.primaryConfigurationURL
            )
        }
    }

    private static func setInternalHookEnabled(_ enabled: Bool, for profile: ManagedHookClientProfile, customConfigURL: URL? = nil) {
        guard let entryName = profile.activationEntryName else {
            return
        }

        let url = customConfigURL ?? profile.activationConfigurationURL
        guard let url else {
            return
        }

        let existingData = try? Data(contentsOf: url)
        let data = updatedInternalHookConfigurationData(
            existingData: existingData,
            entryName: entryName,
            installing: enabled
        )
        writeData(data, to: url)
    }

    private static func setManagedPluginEnabled(
        _ enabled: Bool,
        for profile: ManagedHookClientProfile,
        customConfigURL: URL? = nil,
        pluginURL: URL? = nil
    ) {
        let pluginURL = pluginURL ?? profile.primaryConfigurationURL
        let urls = managedPluginActivationConfigurationURLs(
            for: profile,
            customConfigURL: customConfigURL
        )
        guard !urls.isEmpty else {
            return
        }

        let targetURLs = enabled ? [urls[0]] : urls
        for url in targetURLs {
            let existingData = try? Data(contentsOf: url)
            let data = updatedConfigurationData(
                existingData: existingData,
                profile: profile,
                customCommand: "",
                installing: enabled,
                pluginURL: pluginURL
            )
            writeData(data, to: url)
        }
    }

    private static func managedPluginActivationConfigurationURLs(
        for profile: ManagedHookClientProfile,
        customConfigURL: URL? = nil
    ) -> [URL] {
        guard let primaryURL = customConfigURL ?? profile.activationConfigurationURL else {
            return []
        }

        return [primaryURL]
    }

    private static func removeLegacyTraeHooks() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyPaths = [
            "Library/Application Support/Trae/User/settings.json",
            "Library/Application Support/Trae CN/User/settings.json",
            "Library/Application Support/TRAE SOLO/User/settings.json",
            "Library/Application Support/TRAE SOLO CN/User/settings.json",
            "Library/Application Support/TRAE Work/User/settings.json",
            "Library/Application Support/TRAE Work CN/User/settings.json",
            ".trae/settings.json"
        ]

        for path in legacyPaths {
            let url = path
                .split(separator: "/")
                .reduce(home) { partialURL, component in
                    partialURL.appendingPathComponent(String(component))
                }
            removeManagedHooks(at: url)
        }
    }

    private static func removeManagedHooks(at url: URL, profile: ManagedHookClientProfile? = nil) {
        guard let data = try? Data(contentsOf: url),
              var json = HookConfigParser.parseJSONObject(from: data),
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    isIslandManagedHookEntry(entry, for: profile)
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if isManagedStatusLine(json["statusLine"] as? [String: Any]) {
            json.removeValue(forKey: "statusLine")
        }
        writeJSONObject(json, to: url)
    }

    private static func containsManagedTOMLHooks(at url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return TOMLHookConfigParser.containsManagedHooks(content)
    }

    private static func updateTOMLHooks(at url: URL, profile: ManagedHookClientProfile) {
        let command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)
        let existingContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let segments = TOMLHookConfigParser.parse(existingContent)
        let newHooks = effectiveEvents(for: profile).map { event -> TOMLHookConfigParser.TOMLHookEntry in
            let matcher = event.templates.first.map { template -> String in
                switch template {
                case .plain: return ""
                case .matcher(let value): return value
                }
            } ?? ""
            let timeout = event.timeout
            return TOMLHookConfigParser.TOMLHookEntry(
                event: event.name,
                command: command,
                matcher: matcher,
                timeout: timeout
            )
        }
        let updatedContent = TOMLHookConfigParser.rebuild(segments: segments, newHooks: newHooks)
        try? updatedContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func removeManagedTOMLHooks(at url: URL) {
        guard let existingContent = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let segments = TOMLHookConfigParser.parse(existingContent)
        let updatedContent = TOMLHookConfigParser.rebuild(segments: segments, newHooks: [])
        try? updatedContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func installBridgeLauncherIfNeeded() {
        let binDirectory = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
        let launcherURL = binDirectory.appendingPathComponent(bridgeLauncherName)

        BridgeRuntimePaths.prepareRuntimeDirectory()
        try? FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )

        installBridgeBinaryIfNeeded(in: binDirectory)
        installStatusLineScript(in: binDirectory)

        let bundleBridge = (Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(bridgeBinaryName)
            .path) ?? ""
        let legacyBundleBridge = (Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(legacyBridgeBinaryName)
            .path) ?? ""

        let environmentExports = BridgeRuntimePaths.launcherEnvironment
            .sorted { $0.key < $1.key }
            .map { key, value in
                "export \(key)=\(shellQuoted(value))"
            }
            .joined(separator: "\n")

        let script = """
        #!/bin/zsh
        \(environmentExports)

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        candidates=(
          "$SCRIPT_DIR/\(bridgeBinaryName)"
          "$SCRIPT_DIR/\(legacyBridgeBinaryName)"
          "\(bundleBridge)"
          "\(legacyBundleBridge)"
        )

        for candidate in "${candidates[@]}"; do
          if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            exec "$candidate" "$@"
          fi
        done

        echo "\(bridgeBinaryName) binary not found" >&2
        exit 127
        """

        if let existingData = try? Data(contentsOf: launcherURL),
           existingData == Data(script.utf8) {
            return
        }

        try? Data(script.utf8).write(to: launcherURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path
        )
    }

    private static func launcherContainsCurrentRuntimeEnvironment(_ launcherURL: URL) -> Bool {
        guard let content = try? String(contentsOf: launcherURL, encoding: .utf8) else {
            return false
        }

        return BridgeRuntimePaths.launcherEnvironment.allSatisfy { key, value in
            content.contains("export \(key)=") && content.contains(shellQuoted(value))
        }
    }

    private static func runBridgeLauncherHealthCheck(_ launcherURL: URL) -> Bool {
        let process = Process()
        process.executableURL = launcherURL
        process.arguments = ["--mode", "health-check"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return false
        }

        guard finished.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return false
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && output == "ok"
    }

    private static func installStatusLineScript(in binDirectory: URL) {
        let scriptURL = binDirectory.appendingPathComponent(statusLineScriptName)
        let script = """
        #!/bin/bash
        input=$(cat)
        _rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\\n' "$_rl" > /tmp/island-rate-limits.json
        echo "$input" | jq -r 'if .model.display_name then "[\\(.model.display_name)] \\(.context_window.used_percentage // 0)% context" else empty end' 2>/dev/null
        """

        try? Data(script.utf8).write(to: scriptURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func installBridgeBinaryIfNeeded(in binDirectory: URL) {
        guard let bundledBridgeURL = preferredBridgeBinaryURL() else {
            return
        }

        let destinationURL = binDirectory.appendingPathComponent(bridgeBinaryName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let matchesExistingBinary =
                (try? Data(contentsOf: bundledBridgeURL)) == (try? Data(contentsOf: destinationURL))
            if matchesExistingBinary == true {
                return
            }

            try? FileManager.default.removeItem(at: destinationURL)
        }

        try? FileManager.default.copyItem(at: bundledBridgeURL, to: destinationURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func preferredBridgeBinaryURL() -> URL? {
        let candidates = [
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(bridgeBinaryName),
            URL(fileURLWithPath: "/Users/trae-flow/Island/Prototype/.build/debug/\(bridgeBinaryName)")
        ]
        .compactMap { $0 }
        .filter { FileManager.default.isReadableFile(atPath: $0.path) }

        guard !candidates.isEmpty else {
            return nil
        }

        return candidates.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private static func normalizedHookEntries(
        _ existingEntries: [[String: Any]]?,
        preferred: [[String: Any]],
        preferredFirst: Bool = false,
        profile: ManagedHookClientProfile? = nil
    ) -> [[String: Any]] {
        let preservedEntries = (existingEntries ?? []).filter { !isIslandManagedHookEntry($0, for: profile) }
        return preferredFirst ? preferred + preservedEntries : preservedEntries + preferred
    }

    private static func removingIslandManagedHooks(
        from hooks: [String: Any],
        profile: ManagedHookClientProfile? = nil
    ) -> [String: Any] {
        var updated = hooks
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { isIslandManagedHookEntry($0, for: profile) }
            if entries.isEmpty {
                updated.removeValue(forKey: event)
            } else {
                updated[event] = entries
            }
        }
        return updated
    }

    private static func updateHooks(at url: URL, profile: ManagedHookClientProfile) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = HookConfigParser.parseJSONObject(from: data) {
            json = existing
        }

        let activeEvents = effectiveEvents(for: profile)

        let command = bridgeCommand(source: profile.bridgeSource, extraArguments: profile.bridgeExtraArguments)

        var hooks = removingIslandManagedHooks(from: json["hooks"] as? [String: Any] ?? [:], profile: profile)
        for event in activeEvents {
            let existingEvent = hooks[event.name] as? [[String: Any]]
            hooks[event.name] = normalizedHookEntries(
                existingEvent,
                preferred: makeHookEntries(command: command, event: event),
                profile: profile
            )
        }

        json["hooks"] = hooks
        if profile.id == "claude-hooks" {
            json["statusLine"] = installedClaudeStatusLineConfiguration(
                preserving: json["statusLine"] as? [String: Any]
            )
        }
        writeJSONObject(json, to: url)
    }

    nonisolated static func installedClaudeStatusLineConfiguration(
        preserving existingStatusLine: [String: Any]?
    ) -> [String: Any] {
        if let existingStatusLine, !isManagedStatusLine(existingStatusLine) {
            return existingStatusLine
        }

        return managedStatusLineConfiguration()
    }

    private static func managedStatusLineConfiguration() -> [String: Any] {
        [
            "type": "command",
            "command": statusLineCommand()
        ]
    }

    private static func statusLineCommand() -> String {
        islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(statusLineScriptName)
            .path
    }

    private static func isManagedStatusLine(_ statusLine: [String: Any]?) -> Bool {
        guard let command = statusLine?["command"] as? String else {
            return false
        }

        return command == statusLineCommand()
            || command.contains("/.trae-flow/bin/\(statusLineScriptName)")
    }

    private static func writeManagedPlugin(at url: URL, profile: ManagedHookClientProfile) {
        let content = managedPluginSource(for: profile)
        guard !content.isEmpty else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    private static func removeManagedPlugin(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedPlugin(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedPlugin(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        return content.contains(managedMarker(for: profile))
    }

    private static func writeManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) {
        let files = managedPluginDirectoryFiles(for: profile)
        guard !files.isEmpty else { return }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = url.appendingPathComponent(name)
            try? Data(content.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func removeManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedPluginDirectory(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedPluginDirectory(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let marker = managedMarker(for: profile)
        let candidates = [
            url.appendingPathComponent("plugin.yaml"),
            url.appendingPathComponent("__init__.py"),
            url.appendingPathComponent("index.ts")
        ]

        return candidates.contains { fileURL in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return content.contains(marker)
        }
    }

    private static func writeManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) {
        let files = managedHookDirectoryFiles(for: profile)
        guard !files.isEmpty else { return }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = url.appendingPathComponent(name)
            try? Data(content.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func removeManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) {
        guard containsManagedHookDirectory(at: url, profile: profile) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private static func containsManagedHookDirectory(at url: URL, profile: ManagedHookClientProfile) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        let marker = managedMarker(for: profile)
        let candidates = [
            url.appendingPathComponent("HOOK.md"),
            url.appendingPathComponent("handler.ts")
        ]

        return candidates.contains { fileURL in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return content.contains(marker)
        }
    }

    private static func makeHookEntries(command: String, event: HookInstallEventDescriptor) -> [[String: Any]] {
        var hookCommand: [String: Any] = [
            "type": "command",
            "command": command
        ]
        if let timeout = event.timeout {
            hookCommand["timeout"] = timeout
        }

        return event.templates.map { template in
            switch template {
            case .plain:
                return ["hooks": [hookCommand]]
            case .matcher(let matcher):
                return [
                    "matcher": matcher,
                    "hooks": [hookCommand]
                ]
            }
        }
    }

    private static func islandSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    private static func bridgeCommandArguments(for profile: ManagedHookClientProfile) -> [String] {
        [
            islandSupportDirectory()
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(bridgeLauncherName)
                .path,
            "--source",
            profile.bridgeSource
        ] + profile.bridgeExtraArguments
    }

    private static func bridgeCommand(source: String, extraArguments: [String] = []) -> String {
        let launcherPath = islandSupportDirectory()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(bridgeLauncherName)
            .path
        return ([launcherPath, "--source", source] + extraArguments)
            .map(shellQuotedIfNeeded)
            .joined(separator: " ")
    }

    private static func containsManagedHooks(at url: URL, profile: ManagedHookClientProfile? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = HookConfigParser.parseJSONObject(from: data),
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if isIslandManagedHookEntry(entry, for: profile) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func isIslandManagedHookEntry(
        _ entry: [String: Any],
        for profile: ManagedHookClientProfile? = nil
    ) -> Bool {
        if let command = hookCommandString(from: entry) {
            return isIslandManagedHookCommand(command, for: profile)
        }

        if let nestedHooks = entry["hooks"] as? [[String: Any]] {
            return nestedHooks.contains { hook in
                guard let command = hookCommandString(from: hook) else { return false }
                return isIslandManagedHookCommand(command, for: profile)
            }
        }

        return false
    }

    private static func hookCommandString(from entry: [String: Any]) -> String? {
        let candidates = [
            entry["command"] as? String,
            entry["bash"] as? String,
            entry["powershell"] as? String
        ]
        return candidates.compactMap { command in
            let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }.first
    }

    private static func isIslandManagedHookCommand(
        _ command: String,
        for profile: ManagedHookClientProfile? = nil
    ) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("/.trae-flow/bin/trae-flow-bridge")
            || normalized.contains("/.trae-flow/bin/island-bridge")
            // 旧版 trae-flow 使用 shell 脚本（~/.config/trae-flow/hooks/trae*.sh）
            // 注入 variant 字段并发送到同一 socket。这些旧条目与新 bridge 二进制冲突，
            // 需要在写入新条目时一并清理。
            || normalized.contains("/.config/trae-flow/hooks/")
    }

    private static func managedMarker(for profile: ManagedHookClientProfile) -> String {
        "TRAE FLOW managed integration: \(profile.id)"
    }

    static func managedPluginSource(for profile: ManagedHookClientProfile) -> String {
        return ""
    }

    static func managedPluginDirectoryFiles(for profile: ManagedHookClientProfile) -> [String: String] {
        return [:]
    }

    static func managedHookDirectoryFiles(
        for profile: ManagedHookClientProfile,
        bridgeArguments: [String]? = nil,
        bridgeEnvironment: [String: String] = [:]
    ) -> [String: String] {
        return [:]
    }

    // MARK: - Custom Hook Installations

    private static let customInstallationsDefaultsKey = "HookInstaller.customInstallations.v1"

    struct CustomHookInstallation: Codable, Identifiable, Equatable {
        let id: String
        let profileID: String
        let customPath: String
        let installedAt: Date

        var customURL: URL {
            URL(fileURLWithPath: customPath)
        }

        var profileTitle: String {
            ClientProfileRegistry.managedHookProfile(id: profileID)?.title ?? profileID
        }
    }

    static func customInstallations() -> [CustomHookInstallation] {
        guard let data = UserDefaults.standard.data(forKey: customInstallationsDefaultsKey),
              let installations = try? JSONDecoder().decode([CustomHookInstallation].self, from: data) else {
            return []
        }
        return installations
    }

    static func installCustom(profileID: String, directoryPath: String) {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: profileID) else {
            return
        }

        let directoryURL = URL(fileURLWithPath: directoryPath)
        let url = customInstallationURL(for: profile, baseDirectory: directoryURL)
        let activationConfigURL = customActivationConfigurationURL(for: profile, baseDirectory: directoryURL)

        installBridgeLauncherIfNeeded()
        switch profile.installationKind {
        case .jsonHooks:
            updateHooks(at: url, profile: profile)
        case .pluginFile:
            writeManagedPlugin(at: url, profile: profile)
            setManagedPluginEnabled(true, for: profile, customConfigURL: activationConfigURL, pluginURL: url)
        case .pluginDirectory:
            writeManagedPluginDirectory(at: url, profile: profile)
        case .hookDirectory:
            writeManagedHookDirectory(at: url, profile: profile)
            setInternalHookEnabled(true, for: profile, customConfigURL: activationConfigURL)
        case .tomlHooks:
            updateTOMLHooks(at: url, profile: profile)
        }

        let installation = CustomHookInstallation(
            id: UUID().uuidString,
            profileID: profileID,
            customPath: url.path,
            installedAt: Date()
        )
        var existing = customInstallations()
        existing.append(installation)
        persistCustomInstallations(existing)
    }

    static func uninstallCustom(id: String) {
        var installations = customInstallations()
        guard let index = installations.firstIndex(where: { $0.id == id }) else {
            return
        }

        let installation = installations[index]
        let url = installation.customURL

        if let profile = ClientProfileRegistry.managedHookProfile(id: installation.profileID) {
            let activationConfigURL = customActivationConfigurationURL(for: profile, installedURL: url)
            switch profile.installationKind {
            case .jsonHooks:
                removeManagedHooks(at: url)
            case .pluginFile:
                removeManagedPlugin(at: url, profile: profile)
                setManagedPluginEnabled(false, for: profile, customConfigURL: activationConfigURL, pluginURL: url)
            case .pluginDirectory:
                removeManagedPluginDirectory(at: url, profile: profile)
            case .hookDirectory:
                removeManagedHookDirectory(at: url, profile: profile)
                setInternalHookEnabled(false, for: profile, customConfigURL: activationConfigURL)
            case .tomlHooks:
                removeManagedTOMLHooks(at: url)
            }
        }

        installations.remove(at: index)
        persistCustomInstallations(installations)
    }

    static func isCustomInstalled(_ installation: CustomHookInstallation) -> Bool {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: installation.profileID) else {
            return false
        }
        let url = installation.customURL
        switch profile.installationKind {
        case .jsonHooks:
            return containsManagedHooks(at: url)
        case .pluginFile:
            return containsManagedPlugin(at: url, profile: profile)
        case .pluginDirectory:
            return containsManagedPluginDirectory(at: url, profile: profile)
        case .hookDirectory:
            let activationConfigURL = customActivationConfigurationURL(for: profile, installedURL: url)
            return containsManagedHookDirectory(at: url, profile: profile)
                && isInternalHookEnabled(at: activationConfigURL, for: profile)
        case .tomlHooks:
            return containsManagedTOMLHooks(at: url)
        }
    }

    private static func persistCustomInstallations(_ installations: [CustomHookInstallation]) {
        guard let data = try? JSONEncoder().encode(installations) else {
            return
        }
        UserDefaults.standard.set(data, forKey: customInstallationsDefaultsKey)
    }

    // MARK: - JSON Utilities

    nonisolated static func remoteBridgeBinaryURL() -> URL? {
        preferredBridgeBinaryURL()
    }

    nonisolated static func managedBridgeCommand(
        source: String,
        extraArguments: [String],
        launcherPath: String,
        socketPath: String?
    ) -> String {
        var components: [String] = []
        if let socketPath, !socketPath.isEmpty {
            components.append("ISLAND_SOCKET_PATH=\(shellQuoted(socketPath))")
        }
        components.append(shellQuoted(launcherPath))
        components.append("--source")
        components.append(source)
        components.append(contentsOf: extraArguments.map(shellQuoted))
        return components.joined(separator: " ")
    }

    nonisolated static func updatedInternalHookConfigurationData(
        existingData: Data?,
        entryName: String,
        installing: Bool
    ) -> Data {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = HookConfigParser.parseJSONObject(from: existingData) {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var internalHooks = hooks["internal"] as? [String: Any] ?? [:]
        var entries = internalHooks["entries"] as? [String: Any] ?? [:]
        var entry = entries[entryName] as? [String: Any] ?? [:]

        entry["enabled"] = installing
        entries[entryName] = entry

        if installing {
            internalHooks["enabled"] = true
        }

        internalHooks["entries"] = entries
        hooks["internal"] = internalHooks
        json["hooks"] = hooks

        return (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
    }

    nonisolated static func isInternalHookEnabled(
        existingData: Data?,
        entryName: String
    ) -> Bool {
        guard let existingData,
              let json = HookConfigParser.parseJSONObject(from: existingData),
              let hooks = json["hooks"] as? [String: Any],
              let internalHooks = hooks["internal"] as? [String: Any],
              let entries = internalHooks["entries"] as? [String: Any],
              let entry = entries[entryName] as? [String: Any],
              let enabled = entry["enabled"] as? Bool else {
            return false
        }

        return enabled
    }

    nonisolated static func updatedConfigurationData(
        existingData: Data?,
        profile: ManagedHookClientProfile,
        customCommand: String,
        installing: Bool,
        removingCommandPrefixes: [String] = [],
        pluginURL: URL? = nil
    ) -> Data {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = HookConfigParser.parseJSONObject(from: existingData) {
            json = existing
        }

        switch profile.installationKind {
        case .jsonHooks:
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            if installing {
                hooks = removingIslandManagedHooks(from: hooks, profile: profile)
                for event in profile.events {
                    let existingEvent = sanitizedHookEntries(
                        hooks[event.name] as? [[String: Any]],
                        removingCommandPrefixes: removingCommandPrefixes
                    )
                    hooks[event.name] = normalizedHookEntries(
                        existingEvent,
                        preferred: makeHookEntries(command: customCommand, event: event),
                        profile: profile
                    )
                }
            } else {
                for (event, value) in hooks {
                    guard var entries = value as? [[String: Any]] else { continue }
                    entries.removeAll { entry in
                        isIslandManagedHookEntry(entry, for: profile)
                    }
                    if entries.isEmpty {
                        hooks.removeValue(forKey: event)
                    } else {
                        hooks[event] = entries
                    }
                }
            }

            if hooks.isEmpty {
                json.removeValue(forKey: "hooks")
            } else {
                json["hooks"] = hooks
            }

        case .pluginFile:
            let targetPluginURL = pluginURL ?? profile.primaryConfigurationURL
            let pluginSpecifier = targetPluginURL.absoluteURL.absoluteString
            let pluginPath = targetPluginURL.path
            let existingPlugins = json["plugin"] as? [Any] ?? []
            let filteredPlugins = existingPlugins.filter { entry in
                !pluginEntry(entry, matches: pluginSpecifier, pluginPath: pluginPath)
            }

            if installing {
                json["plugin"] = filteredPlugins + [pluginSpecifier]
            } else if filteredPlugins.isEmpty {
                json.removeValue(forKey: "plugin")
            } else {
                json["plugin"] = filteredPlugins
            }
        case .pluginDirectory, .hookDirectory:
            break
        case .tomlHooks:
            break
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        return data
    }

    private static func sanitizedHookEntries(
        _ entries: [[String: Any]]?,
        removingCommandPrefixes: [String]
    ) -> [[String: Any]]? {
        guard !removingCommandPrefixes.isEmpty else { return entries }
        return entries?.filter { entry in
            !entryContainsCommand(entry, withPrefixes: removingCommandPrefixes)
        }
    }

    private static func entryContainsCommand(
        _ entry: [String: Any],
        withPrefixes prefixes: [String]
    ) -> Bool {
        if let command = hookCommandString(from: entry) {
            return prefixes.contains { command.hasPrefix($0) }
        }

        if let nestedHooks = entry["hooks"] as? [[String: Any]] {
            return nestedHooks.contains { hook in
                guard let command = hookCommandString(from: hook) else { return false }
                return prefixes.contains { command.hasPrefix($0) }
            }
        }

        return false
    }

    private static func writeJSONObject(_ json: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url)
        }
    }

    private static func writeData(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func customInstallationURL(for profile: ManagedHookClientProfile, baseDirectory: URL) -> URL {
        switch profile.installationKind {
        case .jsonHooks, .pluginFile, .tomlHooks:
            return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent)
        case .pluginDirectory, .hookDirectory:
            return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent, isDirectory: true)
        }
    }

    private static func customActivationConfigurationURL(for profile: ManagedHookClientProfile, baseDirectory: URL) -> URL? {
        switch profile.installationKind {
        case .jsonHooks, .pluginFile, .pluginDirectory, .tomlHooks, .hookDirectory:
            return nil
        }
    }

    private static func customActivationConfigurationURL(for profile: ManagedHookClientProfile, installedURL: URL) -> URL? {
        switch profile.installationKind {
        case .jsonHooks, .pluginFile, .pluginDirectory, .tomlHooks, .hookDirectory:
            return nil
        }
    }

    private static func isInternalHookEnabled(at url: URL?, for profile: ManagedHookClientProfile) -> Bool {
        guard let url,
              let entryName = profile.activationEntryName,
              let data = try? Data(contentsOf: url) else {
            return false
        }
        return isInternalHookEnabled(existingData: data, entryName: entryName)
    }

    private nonisolated static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private nonisolated static func shellQuotedIfNeeded(_ string: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@%")
        if string.rangeOfCharacter(from: safeCharacters.inverted) == nil {
            return string
        }
        return shellQuoted(string)
    }

    nonisolated static func isManagedPluginEnabled(existingData: Data?, pluginURL: URL) -> Bool {
        guard let existingData,
              let json = HookConfigParser.parseJSONObject(from: existingData),
              let plugins = json["plugin"] as? [Any] else {
            return false
        }

        let pluginSpecifier = pluginURL.absoluteURL.absoluteString
        let pluginPath = pluginURL.path
        return plugins.contains { pluginEntry($0, matches: pluginSpecifier, pluginPath: pluginPath) }
    }

    private static func pluginEntry(_ entry: Any, matches pluginSpecifier: String, pluginPath: String) -> Bool {
        if let string = entry as? String {
            return normalizedPluginLocation(string) == normalizedPluginLocation(pluginSpecifier)
                || normalizedPluginLocation(string) == normalizedPluginLocation(pluginPath)
        }

        if let pair = entry as? [Any],
           let string = pair.first as? String {
            return normalizedPluginLocation(string) == normalizedPluginLocation(pluginSpecifier)
                || normalizedPluginLocation(string) == normalizedPluginLocation(pluginPath)
        }

        return false
    }

    private static func normalizedPluginLocation(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
