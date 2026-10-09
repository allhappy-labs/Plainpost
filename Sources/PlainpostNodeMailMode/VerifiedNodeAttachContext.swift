import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime

/// Public enrollment evidence only. No provider credential, endpoint, or
/// private signing material escapes the sealed session store.
public struct VerifiedNodeAttachContext: Sendable {
    public let accountID: PlainpostAccountID
    public let nodeID: AccountDeviceID
    public let trustEpoch: AccountTrustEpoch
    public let lease: AccountNodeOfflineLeaseV2
    public let action: AccountNodeEnrollmentAction
}

public enum VerifiedNodeAttachContextLoader {
    /// Requires a current verified trust head and a current root-signed V2
    /// enrollment lease that binds the exact account, Node, and trust epoch.
    /// Callers must still check provider-account identity and switch source
    /// with the durable operation fence and generation CAS.
    public static func load(
        credentials: AccountCredentialStore,
        endpointStore: SyncNodeEndpointStore,
        manifest: SessionKeyManifestVerifier,
        now: Date = Date()
    ) async throws -> VerifiedNodeAttachContext {
        let session: AccountSessionCredentials
        do {
            guard try credentials.loadCompletedDeletionReceipt() == nil,
                  try credentials.loadLocalDeletion() == nil,
                  let record = try credentials.loadSession(),
                  record.state == .active,
                  let active = record.credentials else { throw NodeSessionBrokerError.noActiveSession }
            session = active
        } catch let error as NodeSessionBrokerError {
            throw error
        } catch {
            throw NodeSessionBrokerError.noActiveSession
        }
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
        let stored = try endpointStore.loadReference(
            accountID: session.accountID,
            nodeID: node.deviceID,
            trustEpoch: commit.state.epoch
        ).session
        let lease = try AccountWireCodec.decodeNodeOfflineLeaseV2(stored.leaseWire)
        let base = lease.binding.base
        guard base.accountID == session.accountID,
              base.nodeDeviceID == node.deviceID,
              base.trustEpoch == commit.state.epoch,
              manifest.verifiesNodeEnrollmentLeaseV2(lease, at: now)
        else { throw NodeSessionBrokerError.notAdmitted }
        return VerifiedNodeAttachContext(
            accountID: session.accountID,
            nodeID: node.deviceID,
            trustEpoch: commit.state.epoch,
            lease: lease,
            action: base.action
        )
    }
}
