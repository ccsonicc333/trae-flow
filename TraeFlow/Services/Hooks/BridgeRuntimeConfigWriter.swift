import Foundation

extension Notification.Name {
    static let bridgeRuntimeConfigDidChange = Notification.Name("BridgeRuntimeConfigDidChange")
}

/// Writes the small runtime config consumed by `TraeFlowBridge` at hook time.
/// Schema must stay in sync with `BridgeRuntimeConfig` in `IslandShared`.
enum BridgeRuntimeConfigWriter {
    nonisolated static func write(_ config: BridgeRuntimeConfigSnapshot) {
        let url = BridgeRuntimePaths.runtimeConfigURL

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = payloadData(config) else { return }

        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func payloadData(_ config: BridgeRuntimeConfigSnapshot) -> Data? {
        let payload: [String: Any] = [
            "routePromptsToTerminal": config.routePromptsToTerminal,
            "debugLoggingEnabled": config.debugLoggingEnabled,
            "debugLogRetentionDays": config.debugLogRetentionDays,
            "debugLogMaxDirectoryMegabytes": config.debugLogMaxDirectoryMegabytes
        ]

        return try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

struct BridgeRuntimeConfigSnapshot: Equatable, Sendable {
    static let defaultDebugLoggingEnabled = true
    static let defaultDebugLogRetentionDays = 7
    static let minimumDebugLogRetentionDays = 1
    static let maximumDebugLogRetentionDays = 30
    static let defaultDebugLogMaxDirectoryMegabytes = 256
    static let minimumDebugLogMaxDirectoryMegabytes = 16
    static let maximumDebugLogMaxDirectoryMegabytes = 1024

    let routePromptsToTerminal: Bool
    let debugLoggingEnabled: Bool
    let debugLogRetentionDays: Int
    let debugLogMaxDirectoryMegabytes: Int

    init(
        routePromptsToTerminal: Bool,
        debugLoggingEnabled: Bool = Self.defaultDebugLoggingEnabled,
        debugLogRetentionDays: Int = Self.defaultDebugLogRetentionDays,
        debugLogMaxDirectoryMegabytes: Int = Self.defaultDebugLogMaxDirectoryMegabytes
    ) {
        self.routePromptsToTerminal = routePromptsToTerminal
        self.debugLoggingEnabled = debugLoggingEnabled
        self.debugLogRetentionDays = Self.clampedDebugLogRetentionDays(debugLogRetentionDays)
        self.debugLogMaxDirectoryMegabytes = Self.clampedDebugLogMaxDirectoryMegabytes(debugLogMaxDirectoryMegabytes)
    }

    static func clampedDebugLogRetentionDays(_ value: Int) -> Int {
        min(max(value, minimumDebugLogRetentionDays), maximumDebugLogRetentionDays)
    }

    static func clampedDebugLogMaxDirectoryMegabytes(_ value: Int) -> Int {
        min(max(value, minimumDebugLogMaxDirectoryMegabytes), maximumDebugLogMaxDirectoryMegabytes)
    }
}
