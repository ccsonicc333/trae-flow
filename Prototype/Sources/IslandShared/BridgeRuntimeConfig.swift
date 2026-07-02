import Foundation

public struct BridgeRuntimeConfig: Sendable, Equatable {
    public var routePromptsToTerminal: Bool
    public var debugLogPolicy: BridgeDebugLogPolicy

    public init(
        routePromptsToTerminal: Bool = false,
        debugLogPolicy: BridgeDebugLogPolicy = .default
    ) {
        self.routePromptsToTerminal = routePromptsToTerminal
        self.debugLogPolicy = debugLogPolicy
    }

    public static let `default` = BridgeRuntimeConfig()

    public static let relativeConfigPath = ".trae-flow/bridge-config.json"
    /// Spec: Launcher 导出 TRAE_FLOW_BRIDGE_CONFIG；保留 TRAE_FLOW_BRIDGE_CONFIG 作为向后兼容回退
    public static let configPathEnvironmentKey = "TRAE_FLOW_BRIDGE_CONFIG"
    public static let legacyConfigPathEnvironmentKey = "TRAE_FLOW_BRIDGE_CONFIG"

    public static func defaultConfigURL(home: URL? = nil) -> URL {
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(relativeConfigPath)
    }

    public static func configuredURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // Spec: 优先读取 TRAE_FLOW_BRIDGE_CONFIG，回退到 TRAE_FLOW_BRIDGE_CONFIG
        if let path = environment[configPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let path = environment[legacyConfigPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return defaultConfigURL()
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeRuntimeConfig {
        load(from: configuredURL(environment: environment))
    }

    public static func load(from url: URL) -> BridgeRuntimeConfig {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        let route = (json["routePromptsToTerminal"] as? Bool) ?? false
        return BridgeRuntimeConfig(
            routePromptsToTerminal: route,
            debugLogPolicy: BridgeDebugLogPolicy(jsonObject: json)
        )
    }

    public var jsonObject: [String: Any] {
        var object = debugLogPolicy.jsonObject
        object["routePromptsToTerminal"] = routePromptsToTerminal
        return object
    }
}
