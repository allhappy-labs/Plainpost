import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// Reconstructs a private sender only by intersecting authenticated account
/// metadata with ThisDeviceOnly state. Neither source alone is sufficient.
public enum SyncNodeSessionLocator {
    public static func discover(
        remote: any SyncNodeEndpointMetadataRemote,
        trust: AccountTrustCoordinator,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        store: SyncNodeEndpointStore,
        client: NodeTLSClient = NodeTLSClient(),
        now: Date = Date()
    ) async throws -> NodeSessionTransport? {
        guard let published = try await SyncNodeEndpointMetadata.discover(remote: remote, trust: trust, accountID: credentials.accountID, credentials: credentials, device: device, now: now) else { return nil }
        let sender = try restore(published: published, credentials: credentials, device: device, store: store, client: client)
        let persisted = try store.loadReference(
            accountID: published.accountID,
            nodeID: published.nodeID,
            trustEpoch: published.trustEpoch
        )
        // An online discovery is also the upgrade path for clients created
        // before the endpoint cache existed. The endpoint was authenticated
        // by Central and opened by the trust coordinator above; only now seal
        // that validated value for a future cached read-only launch.
        try store.saveEndpoint(published.endpoint, for: persisted.reference, identity: device)
        return sender
    }

    public static func restore(
        published: SyncNodePublishedEndpointV1,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        store: SyncNodeEndpointStore,
        client: NodeTLSClient = NodeTLSClient()
    ) throws -> NodeSessionTransport {
        guard published.accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        let persisted = try store.loadReference(accountID: published.accountID, nodeID: published.nodeID, trustEpoch: published.trustEpoch)
        guard persisted.reference.accountID == published.accountID,
              persisted.reference.nodeID == published.nodeID,
              persisted.reference.trustEpoch == published.trustEpoch
        else { throw AccountRuntimeError.corruptSecret }
        return try NodeSessionTransport(reference: persisted.reference, clientID: credentials.deviceID, endpoint: try NodeEndpointURL(published.endpoint.absoluteString), store: store, identity: device, client: client)
    }

    /// Restores an already-enrolled Node session from ThisDeviceOnly state.
    /// No Central metadata request is made; callers must have independently
    /// admitted the account's still-valid offline lease before selecting this
    /// cached read-only path.
    public static func restoreCached(
        credentials: AccountSessionCredentials,
        nodeID: AccountDeviceID,
        trustEpoch: AccountTrustEpoch,
        device: AccountDeviceIdentity,
        store: SyncNodeEndpointStore,
        client: NodeTLSClient = NodeTLSClient()
    ) throws -> NodeSessionTransport {
        try restoreCachedConnection(
            credentials: credentials,
            nodeID: nodeID,
            trustEpoch: trustEpoch,
            device: device,
            store: store,
            client: client
        ).transport
    }

    public static func restoreCachedConnection(
        credentials: AccountSessionCredentials,
        nodeID: AccountDeviceID,
        trustEpoch: AccountTrustEpoch,
        device: AccountDeviceIdentity,
        store: SyncNodeEndpointStore,
        client: NodeTLSClient = NodeTLSClient()
    ) throws -> SyncNodeCachedConnection {
        let persisted = try store.loadReference(accountID: credentials.accountID, nodeID: nodeID, trustEpoch: trustEpoch)
        let endpoint = try store.loadEndpoint(for: persisted.reference, identity: device)
        let published = try SyncNodePublishedEndpointV1(accountID: persisted.reference.accountID, nodeID: persisted.reference.nodeID, trustEpoch: persisted.reference.trustEpoch, endpoint: endpoint)
        guard published.accountID == credentials.accountID else { throw AccountRuntimeError.untrustedResponse }
        let canonicalEndpoint = try NodeEndpointURL(published.endpoint.absoluteString)
        let sender = try NodeSessionTransport(reference: persisted.reference, clientID: credentials.deviceID, endpoint: canonicalEndpoint, store: store, identity: device, client: client)
        return SyncNodeCachedConnection(endpoint: canonicalEndpoint, transport: sender)
    }
}
