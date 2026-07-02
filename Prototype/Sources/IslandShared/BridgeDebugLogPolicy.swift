import Foundation

public struct BridgeDebugLogPolicy: Sendable, Equatable {
    public static let defaultRetentionDays = 7
    public static let minimumRetentionDays = 1
    public static let maximumRetentionDays = 30
    public static let defaultMaxDirectoryMegabytes = 256
    public static let minimumMaxDirectoryMegabytes = 16
    public static let maximumMaxDirectoryMegabytes = 1024

    public var isEnabled: Bool
    public var retentionDays: Int
    public var maxDirectoryMegabytes: Int

    public init(
        isEnabled: Bool = true,
        retentionDays: Int = Self.defaultRetentionDays,
        maxDirectoryMegabytes: Int = Self.defaultMaxDirectoryMegabytes
    ) {
        self.isEnabled = isEnabled
        self.retentionDays = Self.clampedRetentionDays(retentionDays)
        self.maxDirectoryMegabytes = Self.clampedMaxDirectoryMegabytes(maxDirectoryMegabytes)
    }

    public init(jsonObject: [String: Any]) {
        self.init(
            isEnabled: (jsonObject["debugLoggingEnabled"] as? Bool) ?? true,
            retentionDays: Self.intValue(
                jsonObject["debugLogRetentionDays"],
                default: Self.defaultRetentionDays
            ),
            maxDirectoryMegabytes: Self.intValue(
                jsonObject["debugLogMaxDirectoryMegabytes"],
                default: Self.defaultMaxDirectoryMegabytes
            )
        )
    }

    public static let `default` = BridgeDebugLogPolicy()

    public var maxDirectoryBytes: Int64 {
        Int64(maxDirectoryMegabytes) * 1024 * 1024
    }

    public var jsonObject: [String: Any] {
        [
            "debugLoggingEnabled": isEnabled,
            "debugLogRetentionDays": retentionDays,
            "debugLogMaxDirectoryMegabytes": maxDirectoryMegabytes
        ]
    }

    public static func clampedRetentionDays(_ value: Int) -> Int {
        min(max(value, minimumRetentionDays), maximumRetentionDays)
    }

    public static func clampedMaxDirectoryMegabytes(_ value: Int) -> Int {
        min(max(value, minimumMaxDirectoryMegabytes), maximumMaxDirectoryMegabytes)
    }

    private static func intValue(_ value: Any?, default defaultValue: Int) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue.rounded())
        }
        if let stringValue = value as? String,
           let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return intValue
        }
        return defaultValue
    }
}

public enum BridgeDebugLogPruner {
    public static func prune(
        directory: URL,
        policy: BridgeDebugLogPolicy,
        now: Date = Date(),
        fileManager: FileManager = .default,
        excludingFileNames: Set<String> = []
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }

        var entries = try debugLogFiles(
            in: directory,
            fileManager: fileManager,
            excludingFileNames: excludingFileNames
        )

        guard policy.isEnabled else {
            for entry in entries {
                try? fileManager.removeItem(at: entry.url)
            }
            return
        }

        let cutoffDate = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400)
        for entry in entries where entry.modifiedAt < cutoffDate {
            try? fileManager.removeItem(at: entry.url)
        }

        entries.removeAll { entry in
            entry.modifiedAt < cutoffDate || !fileManager.fileExists(atPath: entry.url.path)
        }

        var totalBytes = entries.reduce(Int64(0)) { partial, entry in
            partial + entry.sizeBytes
        }

        guard totalBytes > policy.maxDirectoryBytes else { return }

        for entry in entries.sorted(by: { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.path < rhs.url.path
            }
            return lhs.modifiedAt < rhs.modifiedAt
        }) where totalBytes > policy.maxDirectoryBytes {
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                totalBytes -= entry.sizeBytes
            }
        }
    }

    private static func debugLogFiles(
        in directory: URL,
        fileManager: FileManager,
        excludingFileNames: Set<String>
    ) throws -> [DebugLogFileEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [DebugLogFileEntry] = []
        for case let url as URL in enumerator {
            guard !excludingFileNames.contains(url.lastPathComponent),
                  isDebugLogFile(url) else {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else { continue }

            entries.append(
                DebugLogFileEntry(
                    url: url,
                    sizeBytes: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            )
        }
        return entries
    }

    private static func isDebugLogFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "jsonl", "log":
            return true
        default:
            return false
        }
    }
}

private struct DebugLogFileEntry {
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date
}
