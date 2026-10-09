import Foundation

/// Where an account's mail comes from. `direct` accounts talk to the provider
/// from this Mac; `nodeBacked` accounts are mirrored from a Sync Node.
public enum AccountMailSourceKind: String, Codable, Sendable {
    case direct
    case nodeBacked = "node_backed"
}

/// A Node-backed account either follows the Node (`node`) or temporarily
/// talks to the provider directly while the Node is unreachable (`fallback`).
public enum NodeBackedMode: String, Codable, Sendable {
    case node
    case fallback
}

public enum AccountMailSourceError: Error, Equatable, Sendable {
    case invalidSource
}

/// The persisted mail source of one account. `generation` is a
/// compare-and-swap counter: every transition returns a copy one generation
/// ahead, and the store accepts it only over the generation it was derived
/// from. An account without a stored row is Direct at generation 0.
public struct AccountMailSource: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let kind: AccountMailSourceKind
    /// `nil` exactly when `kind == .direct`.
    public let mode: NodeBackedMode?
    /// The Sync Node's device UUID, always lowercase.
    public let nodeID: String?
    /// The Node's logical mailbox ID: raw base64url of 32 bytes (43 characters).
    public let logicalMailboxID: String?
    public let providerIdentity: String?
    public let generation: Int64

    /// Validating initializer for values read from storage or the wire.
    public init(
        accountID: AccountID,
        kind: AccountMailSourceKind,
        mode: NodeBackedMode?,
        nodeID: String?,
        logicalMailboxID: String?,
        providerIdentity: String?,
        generation: Int64
    ) throws {
        self.init(
            unchecked: accountID, kind: kind, mode: mode, nodeID: nodeID?.lowercased(),
            logicalMailboxID: logicalMailboxID, providerIdentity: providerIdentity,
            generation: generation
        )
        try validate()
    }

    private init(
        unchecked accountID: AccountID,
        kind: AccountMailSourceKind,
        mode: NodeBackedMode?,
        nodeID: String?,
        logicalMailboxID: String?,
        providerIdentity: String?,
        generation: Int64
    ) {
        self.accountID = accountID
        self.kind = kind
        self.mode = mode
        self.nodeID = nodeID
        self.logicalMailboxID = logicalMailboxID
        self.providerIdentity = providerIdentity
        self.generation = generation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountID: try container.decode(AccountID.self, forKey: .accountID),
            kind: try container.decode(AccountMailSourceKind.self, forKey: .kind),
            mode: try container.decodeIfPresent(NodeBackedMode.self, forKey: .mode),
            nodeID: try container.decodeIfPresent(String.self, forKey: .nodeID),
            logicalMailboxID: try container.decodeIfPresent(String.self, forKey: .logicalMailboxID),
            providerIdentity: try container.decodeIfPresent(String.self, forKey: .providerIdentity),
            generation: try container.decode(Int64.self, forKey: .generation)
        )
    }

    /// The implicit source of an account with no stored row.
    public static func direct(_ accountID: AccountID) -> AccountMailSource {
        AccountMailSource(
            unchecked: accountID, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 0
        )
    }

    /// Direct sync (IMAP IDLE, scheduled and realtime inbox sync, direct
    /// flag/archive/draft writes) runs only for Direct accounts and for
    /// Node-backed accounts in fallback.
    public var runsDirectSync: Bool { kind == .direct || mode == .fallback }

    /// Hands the account to a Node in `.node` mode, one generation ahead.
    /// The result is unchecked; the store validates it before writing.
    public func nodeBacked(
        nodeID: String,
        logicalMailboxID: String,
        providerIdentity: String
    ) -> AccountMailSource {
        AccountMailSource(
            unchecked: accountID, kind: .nodeBacked, mode: .node, nodeID: nodeID.lowercased(),
            logicalMailboxID: logicalMailboxID, providerIdentity: providerIdentity,
            generation: generation + 1
        )
    }

    public func withMode(_ mode: NodeBackedMode) -> AccountMailSource {
        precondition(kind == .nodeBacked, "Only a Node-backed source has a mode.")
        return AccountMailSource(
            unchecked: accountID, kind: kind, mode: mode, nodeID: nodeID,
            logicalMailboxID: logicalMailboxID, providerIdentity: providerIdentity,
            generation: generation + 1
        )
    }

    public func revertedToDirect() -> AccountMailSource {
        AccountMailSource(
            unchecked: accountID, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: generation + 1
        )
    }

    public func validate() throws {
        guard generation >= 0, !accountID.rawValue.isEmpty else {
            throw AccountMailSourceError.invalidSource
        }
        switch kind {
        case .direct:
            guard mode == nil, nodeID == nil, logicalMailboxID == nil, providerIdentity == nil else {
                throw AccountMailSourceError.invalidSource
            }
        case .nodeBacked:
            guard mode != nil,
                  let nodeID, UUID(uuidString: nodeID) != nil, nodeID == nodeID.lowercased(),
                  let logicalMailboxID, Self.isLogicalMailboxID(logicalMailboxID),
                  let providerIdentity, !providerIdentity.isEmpty
            else {
                throw AccountMailSourceError.invalidSource
            }
        }
    }

    private static let base64URLAlphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Canonical unpadded base64url of exactly 32 bytes: 43 characters whose
    /// last one carries 4 data bits and 2 zero bits, so each ID has one spelling.
    private static func isLogicalMailboxID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 43,
              bytes.allSatisfy(base64URLAlphabet.contains),
              let last = bytes.last,
              let lastValue = base64URLAlphabet.firstIndex(of: last)
        else { return false }
        return lastValue & 0b11 == 0
    }
}

/// A message's provider identity on one account: the IMAP membership
/// `(mailbox, UIDVALIDITY, UID)`. It never changes for a stored message.
public struct StableMessageKey: Hashable, Sendable {
    public let accountID: AccountID
    public let mailboxPath: String
    public let uidValidity: Int
    public let uid: Int

    public init(accountID: AccountID, mailboxPath: String, uidValidity: Int, uid: Int) {
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uidValidity = uidValidity
        self.uid = uid
    }
}
