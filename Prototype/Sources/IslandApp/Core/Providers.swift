import Foundation
import IslandShared

protocol AgentProviderAdapter: Sendable {
    func installHooks() async throws
    func repairHooksIfNeeded() async
    func startMonitoring() async
    func submitInterventionResponse(_ response: InterventionDecision, request: InterventionRequest) async throws
}

struct TraeProviderAdapter: AgentProviderAdapter {
    let installer: HookInstaller

    func installHooks() async throws {
        try installer.installTRAEHookAssets()
    }

    func repairHooksIfNeeded() async {
        try? installer.installTRAEHookAssets()
    }

    func startMonitoring() async {}

    func submitInterventionResponse(_ response: InterventionDecision, request: InterventionRequest) async throws {}
}
