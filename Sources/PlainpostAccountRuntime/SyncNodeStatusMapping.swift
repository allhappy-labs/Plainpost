import PlainpostNodeTransport

/// One transport-to-runtime projection used by every Node-backed surface.
/// Keeping this beside the runtime vocabulary prevents security-sensitive
/// status fields from drifting between mail, provider, and operations views.
public extension NodeSyncStatusResult {
    func syncNodeStatus() -> SyncNodeStatus {
        SyncNodeStatus(
            revision: revision, state: state, version: version,
            reachability: reachability, syncLag: syncLag, storage: storage,
            providerIdentity: providerIdentity,
            assignments: assignments.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }, backup: backup, endpoint: endpoint, updateStatus: updateStatus
        )
    }
}
