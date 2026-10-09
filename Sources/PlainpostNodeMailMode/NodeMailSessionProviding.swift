import Foundation
import PlainpostNodeTransport

/// Supplies the Node session the mutation router dispatches through. The
/// reachability supervisor (Task 17) is the production provider; until it is
/// attached every Node-mode lookup is treated as unreachable.
public protocol NodeMailSessionProviding: Sendable {
    /// Current signed client for the Node, or nil while the supervisor reports fallback or unreachable.
    func reachableClient(nodeID: String) async -> NodeSyncClient?
    /// The session's admission read locally (no Node request), or nil when
    /// it cannot be read. Read-only means a mutation would be refused.
    func sessionAdmission(nodeID: String) async -> NodeSessionAdmission?
}

extension NodeMailSessionProviding {
    public func sessionAdmission(nodeID: String) async -> NodeSessionAdmission? { nil }
}
