import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// One provider mail account served by a Sync Node. A provider account is
/// exactly one logical mailbox; every mailbox listed here belongs to it.
public struct NodeMailAccount: Equatable, Sendable, Identifiable {
    public let logicalMailboxID: LogicalMailboxID
    public var id: LogicalMailboxID { logicalMailboxID }
    public let providerIdentity: String
    /// `gmail` or `generic`.
    public let providerKind: String
    /// The account the Node's legacy single-account routes project.
    public let isPrimary: Bool
    public let state: NodeSyncMailAccountState
    public let mailboxes: [SyncNodeProviderMailbox]

    public init(
        logicalMailboxID: LogicalMailboxID,
        providerIdentity: String,
        providerKind: String,
        isPrimary: Bool,
        state: NodeSyncMailAccountState,
        mailboxes: [SyncNodeProviderMailbox]
    ) {
        self.logicalMailboxID = logicalMailboxID
        self.providerIdentity = providerIdentity
        self.providerKind = providerKind
        self.isPrimary = isPrimary
        self.state = state
        self.mailboxes = mailboxes
    }

    init(_ account: NodeSyncMailAccount) {
        self.init(
            logicalMailboxID: account.logicalMailboxID,
            providerIdentity: account.providerIdentity,
            providerKind: account.providerKind,
            isPrimary: account.primary,
            state: account.state,
            mailboxes: account.assignments.map(NodeMailAccountCatalog.mailbox)
        )
    }
}

public enum NodeMailAccountCatalog {
    /// Multi-account Node → every account from /v1/mail/accounts. Older Node (404) → one account synthesized from
    /// /v1/status + legacy assignments with isPrimary = true, so older Nodes keep working.
    public static func load(_ client: NodeSyncClient) async throws -> (accounts: [NodeMailAccount], multiAccount: Bool) {
        let listed: NodeSyncMailAccountsResult
        do {
            listed = try await client.mailAccounts()
        } catch NodeSyncClientError.notFound {
            let status = try await client.status()
            let assignments = try await client.mailboxAssignments().assignments
            return (legacyAccounts(status: status, assignments: assignments), false)
        }
        return (listed.accounts.map(NodeMailAccount.init), true)
    }

    /// Reads the current catalog entry of one account through the route family
    /// the account was discovered with. Nil means the Node no longer lists it.
    static func account(
        _ logicalMailboxID: LogicalMailboxID,
        client: NodeSyncClient,
        multiAccount: Bool,
        legacyStatus: NodeSyncStatusResult
    ) async throws -> NodeMailAccount? {
        let accounts: [NodeMailAccount]
        if multiAccount {
            accounts = try await client.mailAccounts().accounts.map(NodeMailAccount.init)
        } else {
            let assignments = try await client.mailboxAssignments().assignments
            accounts = legacyAccounts(status: legacyStatus, assignments: assignments)
        }
        return accounts.first { $0.logicalMailboxID == logicalMailboxID }
    }

    /// An older Node projects a single provider account: `/v1/status` names
    /// its identity and the assignments read model its logical mailbox. The
    /// legacy provisioning route is Google-only, so the kind is `gmail`. When
    /// a legacy projection names several logical mailboxes, the lowest by raw
    /// bytes is the account, matching the legacy mutation factory's order.
    static func legacyAccounts(status: NodeSyncStatusResult, assignments: [NodeSyncDiscoveredMailbox]) -> [NodeMailAccount] {
        guard let identity = status.providerIdentity, !identity.isEmpty,
              let logicalMailboxID = assignments.compactMap(\.logicalMailboxID)
                .min(by: { $0.rawValue.lexicographicallyPrecedes($1.rawValue) }) else { return [] }
        let state: NodeSyncMailAccountState = status.state == "ready" ? .ready : .degraded
        return [NodeMailAccount(
            logicalMailboxID: logicalMailboxID,
            providerIdentity: identity,
            providerKind: "gmail",
            isPrimary: true,
            state: state,
            mailboxes: assignments.filter { $0.logicalMailboxID == logicalMailboxID }.map(mailbox)
        )]
    }

    static func mailbox(_ assignment: NodeSyncDiscoveredMailbox) -> SyncNodeProviderMailbox {
        SyncNodeProviderMailbox(
            displayName: assignment.displayName, mailboxHandle: assignment.mailboxHandle,
            role: assignment.role, logicalMailboxID: assignment.logicalMailboxID
        )
    }
}
