import Foundation
import IslandShared

actor ApprovalCoordinator {
    private var pending: [UUID: CheckedContinuation<InterventionDecision, Never>] = [:]
    private var resolved: [UUID: InterventionDecision] = [:]

    func waitForDecision(requestID: UUID) async -> InterventionDecision {
        if let decision = resolved.removeValue(forKey: requestID) {
            return decision
        }

        return await withCheckedContinuation { continuation in
            pending[requestID] = continuation
        }
    }

    func resolve(requestID: UUID, decision: InterventionDecision) {
        if let continuation = pending.removeValue(forKey: requestID) {
            continuation.resume(returning: decision)
        } else {
            resolved[requestID] = decision
        }
    }
}
