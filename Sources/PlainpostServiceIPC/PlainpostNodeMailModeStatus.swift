import Foundation
import PlainpostXPCObjC

/// The service's Sync Node mail-mode state as the app renders it. It carries
/// no credential, identity, address or path: only a state and two counts.
public struct PlainpostNodeMailModeStatus: Equatable, Sendable, Codable, CustomStringConvertible {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// No account on this Mac is Node-backed.
        case noNode = "no_node"
        case connected
        /// "Sync Node unavailable — connected directly": Node-backed accounts
        /// sync with their providers until the Node is reachable again.
        case connectedDirectly = "connected_directly"
        /// The Node does not serve the mail-mode routes: "Update your Sync Node".
        case updateRequired = "update_required"
        /// The Node answered `unauthorized`; the app shows "Reconnect Sync Node".
        case reconnectRequired = "reconnect_required"
    }

    /// Upper bound for either count on the wire.
    public static let maximumCount = 1_000_000

    public let state: State
    public let nodeBackedAccountCount: Int
    /// Node-backed mail changes not yet confirmed by the Node or the
    /// provider (queued, in flight, admitted or uncertain).
    public let waitingIntentCount: Int

    public init(state: State, nodeBackedAccountCount: Int, waitingIntentCount: Int) {
        self.state = state
        self.nodeBackedAccountCount = min(max(0, nodeBackedAccountCount), Self.maximumCount)
        self.waitingIntentCount = min(max(0, waitingIntentCount), Self.maximumCount)
    }

    public static let noNode = PlainpostNodeMailModeStatus(state: .noNode, nodeBackedAccountCount: 0, waitingIntentCount: 0)

    public var description: String {
        "PlainpostNodeMailModeStatus(state: \(state.rawValue), nodeBackedAccountCount: \(nodeBackedAccountCount), waitingIntentCount: \(waitingIntentCount))"
    }

    public func dto() throws -> PlainpostNodeMailModeStatusDTO {
        guard let dto = PlainpostNodeMailModeStatusDTO(
            schemaVersion: 1,
            state: state.rawValue,
            nodeBackedAccountCount: nodeBackedAccountCount,
            waitingIntentCount: waitingIntentCount
        ) else { throw PlainpostServiceClientError.operationFailed }
        return dto
    }

    /// Decodes the XPC reply; an unknown state is a service failure.
    public init(dto: PlainpostNodeMailModeStatusDTO) throws {
        guard dto.schemaVersion == 1,
              let state = State(rawValue: dto.state),
              (0...Self.maximumCount).contains(dto.nodeBackedAccountCount),
              (0...Self.maximumCount).contains(dto.waitingIntentCount)
        else { throw PlainpostServiceClientError.operationFailed }
        self.init(state: state, nodeBackedAccountCount: dto.nodeBackedAccountCount, waitingIntentCount: dto.waitingIntentCount)
    }
}

extension PlainpostNodeMailModeStatusDTO: @retroactive @unchecked Sendable {}
