import Foundation
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostNodeTransport

/// Validates an account-bound Node source proposal. This does not persist a
/// source or establish a trusted session: the caller must obtain the Node ID
/// and trust epoch from a verified broker, then recheck the source with CAS.
public enum NodeAttachAdmission {
    public static func propose(
        account: Account,
        source: AccountMailSource,
        expectedGeneration: Int64,
        plainpostAccountID: PlainpostAccountID,
        nodeID: AccountDeviceID,
        trustEpoch: AccountTrustEpoch,
        lease: AccountNodeOfflineLeaseV2,
        expectedAction: AccountNodeEnrollmentAction,
        manifest: SessionKeyManifestVerifier,
        nodeAccount: NodeMailAccount,
        now: Date = Date()
    ) throws -> AccountMailSource {
        guard source.accountID == account.id,
              source.kind == .direct,
              source.generation == expectedGeneration,
              expectedGeneration >= 0,
              expectedGeneration < Int64.max,
              lease.binding.base.accountID == plainpostAccountID,
              lease.binding.base.nodeDeviceID == nodeID,
              lease.binding.base.trustEpoch == trustEpoch,
              lease.binding.base.action == expectedAction,
              manifest.verifiesNodeEnrollmentLeaseV2(lease, at: now),
              nodeAccount.state == .ready,
              ["gmail", "generic"].contains(nodeAccount.providerKind),
              !nodeAccount.providerIdentity.isEmpty,
              nodeAccount.providerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == account.email.rawValue.lowercased(),
              validMailboxes(nodeAccount.mailboxes, owner: nodeAccount.logicalMailboxID)
        else { throw AccountRuntimeError.untrustedResponse }

        let proposal = source.nodeBacked(
            nodeID: nodeID.rawValue,
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(nodeAccount.logicalMailboxID),
            providerIdentity: nodeAccount.providerIdentity
        )
        try proposal.validate()
        return proposal
    }

    private static func validMailboxes(
        _ mailboxes: [SyncNodeProviderMailbox], owner: LogicalMailboxID
    ) -> Bool {
        let allowedRoles: Set<String> = ["inbox", "sent", "drafts", "trash", "junk", "archive", "all", "other"]
        guard !mailboxes.isEmpty, mailboxes.count <= Int(NodeSyncLimits.maximumPageSize),
              mailboxes.allSatisfy({ mailbox in
                  mailbox.logicalMailboxID == owner &&
                  allowedRoles.contains(mailbox.role) &&
                  !mailbox.mailboxHandle.isEmpty &&
                  mailbox.mailboxHandle == mailbox.mailboxHandle.trimmingCharacters(in: .whitespacesAndNewlines) &&
                  mailbox.mailboxHandle.utf8.count <= NodeSyncLimits.maximumIdentifierBytes &&
                  !mailbox.mailboxHandle.unicodeScalars.contains(where: { $0.value == 0 })
              }) else { return false }
        let handles = mailboxes.map(\.mailboxHandle)
        let specialRoles = mailboxes.map(\.role).filter { $0 != "other" }
        return Set(handles).count == handles.count &&
            specialRoles.filter({ $0 == "inbox" }).count == 1 &&
            Set(specialRoles).count == specialRoles.count
    }
}
