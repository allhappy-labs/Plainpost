import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime

extension NodeSessionBroker {
    /// Restores only an endpoint previously sealed after authenticated Node
    /// discovery. The active account, existing device key, trusted Node and
    /// trust epoch must still agree. This does not create a Plainpost account
    /// or change a Direct mail source.
    public static func production(
        credentials: AccountCredentialStore,
        endpointStore: SyncNodeEndpointStore,
        discoveryRemote: (@Sendable () throws -> any SyncNodeEndpointMetadataRemote)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        leaseVerifier: @escaping @Sendable (AccountSessionCredentials, Date) -> Date? = NodeSessionAdmissionPolicy.persistedLeaseVerifier()
    ) -> NodeSessionBroker {
        NodeSessionBroker(
            resolveSender: {
                let session = try loadSession(credentials)
                guard let identity = try credentials.loadExistingDeviceIdentity() else { throw NodeSessionBrokerError.noActiveSession }
                let trust = try credentials.makeTrustCoordinator(
                    accountID: session.accountID,
                    deviceID: session.deviceID,
                    platform: .ios,
                    identity: identity
                )
                guard let commit = try await trust.currentTrustCommit(),
                      commit.state.accountID == session.accountID,
                      let node = commit.state.members.first(where: { $0.platform == .syncNode })
                else { throw NodeSessionBrokerError.noEnrolledNode }
                let transport: NodeSessionTransport
                do {
                    transport = try SyncNodeSessionLocator.restoreCachedConnection(
                        credentials: session,
                        nodeID: node.deviceID,
                        trustEpoch: commit.state.epoch,
                        device: identity,
                        store: endpointStore
                    ).transport
                } catch {
                    // A fresh enrollment may not yet have a sealed endpoint.
                    // Only a live writable session may ask authenticated
                    // Central metadata to discover and seal that endpoint.
                    guard session.accessExpiresAt > clock(), let discoveryRemote else {
                        throw NodeSessionBrokerError.noEnrolledNode
                    }
                    let remote = try discoveryRemote()
                    guard let discovered = try await SyncNodeSessionLocator.discover(
                        remote: remote, trust: trust, credentials: session,
                        device: identity, store: endpointStore
                    ) else { throw NodeSessionBrokerError.noEnrolledNode }
                    transport = discovered
                }
                return (node.deviceID.rawValue, transport)
            },
            check: {
                let session = try loadSession(credentials)
                guard try credentials.loadExistingDeviceIdentity() != nil else { throw NodeSessionBrokerError.noActiveSession }
                let now = clock()
                let admission = try NodeSessionAdmissionPolicy.admission(
                    accessExpiresAt: session.accessExpiresAt,
                    verifiedLeaseExpiresAt: leaseVerifier(session, now),
                    now: now
                )
                // A changed local trust head invalidates clients already
                // handed out. The resolver validates that head cryptographically.
                let commit = try credentials.loadCurrentTrustCommit(for: session.accountID)
                let node = commit?.state.members.first(where: { $0.platform == .syncNode })
                guard let commit, let node else { throw NodeSessionBrokerError.noEnrolledNode }
                if case .readOnly = admission {
                    // Reconciliation may replay an ambiguous request before
                    // the caller's read. A lease must never replay a write.
                    let reference = try endpointStore.loadReference(
                        accountID: session.accountID,
                        nodeID: node.deviceID,
                        trustEpoch: commit.state.epoch
                    ).reference
                    guard try endpointStore.loadRetainedMutation(for: reference) == nil
                    else { throw NodeSessionBrokerError.readOnly }
                    if let pending = try endpointStore.loadPending(for: reference) {
                        guard let method = pending.method, let path = pending.path,
                              NodeSessionAdmissionPolicy.permitsReadOnly(method: method, path: path)
                        else { throw NodeSessionBrokerError.readOnly }
                    }
                }
                let binding = [
                    session.accountID.rawValue, session.deviceID.rawValue,
                    node.deviceID.rawValue, commit.state.epoch.wireValue,
                ].joined(separator: "/")
                return NodeSessionCheck(admission: admission, binding: binding)
            }
        )
    }
}

private func loadSession(_ credentials: AccountCredentialStore) throws -> AccountSessionCredentials {
    do {
        guard try credentials.loadCompletedDeletionReceipt() == nil,
              try credentials.loadLocalDeletion() == nil else { throw NodeSessionBrokerError.notAdmitted }
        guard let session = try credentials.loadSession(), session.state == .active,
              let values = session.credentials else { throw NodeSessionBrokerError.noActiveSession }
        return values
    } catch let error as NodeSessionBrokerError {
        throw error
    } catch {
        throw NodeSessionBrokerError.noActiveSession
    }
}
