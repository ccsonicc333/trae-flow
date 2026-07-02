import Foundation
import IslandShared
import Testing

@Test
func bridgeRuntimeConfigLoadsDebugLogPolicy() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "routePromptsToTerminal": true,
          "debugLoggingEnabled": false,
          "debugLogRetentionDays": 14,
          "debugLogMaxDirectoryMegabytes": 128
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = BridgeRuntimeConfig.load(
            environment: [BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path()]
        )

        #expect(config.routePromptsToTerminal)
        #expect(config.debugLogPolicy.isEnabled == false)
        #expect(config.debugLogPolicy.retentionDays == 14)
        #expect(config.debugLogPolicy.maxDirectoryMegabytes == 128)
    }
}

@Test
func bridgeRuntimeConfigClampsDebugLogPolicy() async throws {
    try await withTemporaryDirectory { directory in
        let configURL = directory.appending(path: "bridge-config.json")
        try """
        {
          "debugLogRetentionDays": 500,
          "debugLogMaxDirectoryMegabytes": 2
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = BridgeRuntimeConfig.load(
            environment: [BridgeRuntimeConfig.configPathEnvironmentKey: configURL.path()]
        )

        #expect(config.debugLogPolicy.retentionDays == BridgeDebugLogPolicy.maximumRetentionDays)
        #expect(config.debugLogPolicy.maxDirectoryMegabytes == BridgeDebugLogPolicy.minimumMaxDirectoryMegabytes)
    }
}

@Test
func debugLogPrunerRemovesFilesOutsideRetentionWindow() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".trae-flow-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let oldLog = logsDirectory.appending(path: "20260501.jsonl")
        let freshLog = logsDirectory.appending(path: "20260611.jsonl")
        let ignoredFile = logsDirectory.appending(path: "notes.txt")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(oldLog, size: 8, modifiedAt: now.addingTimeInterval(-9 * 86_400))
        try writeDebugLog(freshLog, size: 8, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        try "keep".write(to: ignoredFile, atomically: true, encoding: .utf8)

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(retentionDays: 7, maxDirectoryMegabytes: 16),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: oldLog.path))
        #expect(FileManager.default.fileExists(atPath: freshLog.path))
        #expect(FileManager.default.fileExists(atPath: ignoredFile.path))
    }
}

@Test
func debugLogPrunerRemovesOldestFilesUntilUnderSizeLimit() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".trae-flow-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let oldestLog = logsDirectory.appending(path: "20260609.jsonl")
        let middleLog = logsDirectory.appending(path: "20260610.jsonl")
        let newestLog = logsDirectory.appending(path: "20260611.jsonl")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(oldestLog, size: 9 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-3 * 86_400))
        try writeDebugLog(middleLog, size: 8 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        try writeDebugLog(newestLog, size: 8 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-86_400))

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(retentionDays: 7, maxDirectoryMegabytes: 16),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: oldestLog.path))
        #expect(FileManager.default.fileExists(atPath: middleLog.path))
        #expect(FileManager.default.fileExists(atPath: newestLog.path))
    }
}

@Test
func debugLogPrunerDeletesLogsWhenPolicyDisabled() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".trae-flow-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let log = logsDirectory.appending(path: "receiver.log")
        let ignoredFile = logsDirectory.appending(path: "notes.txt")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(log, size: 8, modifiedAt: now)
        try "keep".write(to: ignoredFile, atomically: true, encoding: .utf8)

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(isEnabled: false),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: ignoredFile.path))
    }
}

private func writeDebugLog(_ url: URL, size: Int, modifiedAt: Date) throws {
    try Data(repeating: 0x61, count: size).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
    )
}
