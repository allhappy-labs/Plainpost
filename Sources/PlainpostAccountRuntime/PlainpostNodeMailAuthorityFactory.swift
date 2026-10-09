import Foundation
import PlainpostCore
import PlainpostNodeTransport

/// The single production assembly point for an authenticated Node mail
/// authority. Callers resolve the sender through their account/session
/// boundary, then use this factory to bind every mail capability to the same
/// client and access policy.
public enum PlainpostNodeMailAuthorityFactory {
    public enum Access: Sendable {
        case authorized
        case cachedReadOnly
    }

    public static func make(
        client: NodeSyncClient,
        accountID: AccountID,
        senderAddress: String? = nil,
        access: Access,
        nodeSendJournal: (any NodeSendJournal)? = nil
    ) throws -> any PlainpostMailAuthority {
        let authority = PlainpostNodeMailAuthority(
            client: client,
            accountID: accountID,
            senderAddress: senderAddress.map { EmailAddress($0) },
            nodeSendJournal: nodeSendJournal
        )
        return try resolve(authority, access: access)
    }

    /// Scoped counterpart of the existing `make(client:accountID:senderAddress:access:)`; same SyncNodeController access rules.
    /// `multiAccount` comes from `NodeMailAccountCatalog.load`, so older Nodes keep the legacy snapshot route.
    public static func make(
        client: NodeSyncClient,
        accountID: AccountID,
        mailAccount: NodeMailAccount,
        multiAccount: Bool,
        access: Access,
        nodeSendJournal: (any NodeSendJournal)? = nil,
        requiresSendJournal: Bool = true
    ) throws -> any PlainpostMailAuthority {
        let authority = PlainpostNodeMailAuthority(
            client: client, accountID: accountID, mailAccount: mailAccount, multiAccount: multiAccount,
            nodeSendJournal: nodeSendJournal, requiresSendJournal: requiresSendJournal
        )
        return try resolve(authority, access: access)
    }

    private static func resolve(_ authority: PlainpostNodeMailAuthority, access: Access) throws -> any PlainpostMailAuthority {
        let controller = SyncNodeController(
            access: access == .cachedReadOnly ? .cachedReadOnly : .authorized,
            cachedReadOnlyPermitted: access == .cachedReadOnly,
            makeAuthority: { _ in authority }
        )
        return try controller.resolve()
    }
}
