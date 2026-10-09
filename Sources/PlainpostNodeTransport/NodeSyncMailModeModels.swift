import Foundation
import PlainpostAccountProtocol

// node-sync-v1 mail-mode values. They are an additive sibling of the legacy
// single-account families: legacy routes keep projecting the primary account,
// while these families list, import, remove and mirror every provider account
// of the authenticated Plainpost account. The Plainpost account itself always
// comes from the verified session, never from these values.

/// `node-sync.mail-capabilities.v1`. The wire form always carries version "1";
/// decoders reject any other version.
public struct NodeSyncMailCapabilities: Equatable, Sendable {
    public let googleImport: Bool
    public let imapImport: Bool
    public let mirrorCoordinates: Bool
    public let multiAccount: Bool

    public init(googleImport: Bool, imapImport: Bool, mirrorCoordinates: Bool, multiAccount: Bool) {
        self.googleImport = googleImport
        self.imapImport = imapImport
        self.mirrorCoordinates = mirrorCoordinates
        self.multiAccount = multiAccount
    }
}

public enum NodeSyncMailAccountState: String, Equatable, Sendable, CaseIterable {
    case ready
    case degraded
    case authenticationRequired = "authentication_required"
}

/// One provider account, which is exactly one logical mailbox. Non-null
/// assignment logical mailbox IDs always name the account itself.
public struct NodeSyncMailAccount: Equatable, Sendable {
    public let assignments: [NodeSyncDiscoveredMailbox]
    public let logicalMailboxID: LogicalMailboxID
    /// The account the legacy single-account routes project.
    public let primary: Bool
    public let providerIdentity: String
    /// `gmail` or `generic`.
    public let providerKind: String
    public let state: NodeSyncMailAccountState

    public init(assignments: [NodeSyncDiscoveredMailbox], logicalMailboxID: LogicalMailboxID, primary: Bool, providerIdentity: String, providerKind: String, state: NodeSyncMailAccountState) throws {
        guard NodeSyncMailModeValidation.ownedAssignments(assignments, owner: logicalMailboxID),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID),
              NodeSyncMailModeValidation.providerIdentity(providerIdentity),
              ["gmail", "generic"].contains(providerKind) else { throw NodeSyncError.invalidValue }
        self.assignments = assignments
        self.logicalMailboxID = logicalMailboxID
        self.primary = primary
        self.providerIdentity = providerIdentity
        self.providerKind = providerKind
        self.state = state
    }
}

/// Whether the primary account (the one legacy routes project) is listed.
public enum NodeSyncMailPrimaryState: String, Equatable, Sendable, CaseIterable {
    /// Exactly one listed account is primary.
    case available
    /// A primary account exists but cannot be represented; it is omitted and
    /// no listed account is primary.
    case unavailable
    /// The Plainpost account has no provider accounts; the list is empty.
    case none
}

/// `node-sync.mail-accounts-result.v1`: at most 200 accounts with unique
/// logical mailboxes and identities. `primaryState` is `available` exactly when
/// one listed account is primary, and `none` requires an empty list.
public struct NodeSyncMailAccountsResult: Equatable, Sendable {
    public let accounts: [NodeSyncMailAccount]
    public let primaryState: NodeSyncMailPrimaryState

    public init(accounts: [NodeSyncMailAccount], primaryState: NodeSyncMailPrimaryState) throws {
        let primaries = accounts.filter(\.primary).count
        guard accounts.count <= Int(NodeSyncLimits.maximumPageSize),
              Set(accounts.map(\.logicalMailboxID)).count == accounts.count,
              Set(accounts.map { Data($0.providerIdentity.utf8) }).count == accounts.count,
              (primaryState == .available) == (primaries == 1), primaries <= 1,
              primaryState != .none || accounts.isEmpty else { throw NodeSyncError.invalidValue }
        self.accounts = accounts
        self.primaryState = primaryState
    }

    /// The listed primary account, or nil when it is unavailable or absent.
    public var primaryAccount: NodeSyncMailAccount? { accounts.first(where: \.primary) }
}

/// `node-sync.mail-delta-page.v1`: changes of every account. Configured
/// accounts whose first import is incomplete are listed in `waitingAccounts`
/// (sorted by logical mailbox bytes) and contribute no change. When one
/// completes, the cursor becomes stale for every account, and ready accounts'
/// changes since that cursor are not delivered through it. Lossless recovery:
/// 1. bootstrap a fresh cursor (`mailDeltas(after: "")`);
/// 2. snapshot every account from `mailAccounts()` that the fresh page does not
///    list as waiting, not only the account that completed;
/// 3. continue from the fresh cursor; replayed upserts are idempotent.
public struct NodeSyncMailDeltaPage: Equatable, Sendable {
    public let changes: [NodeSyncChange]
    public let nextCursor: String
    public let revision: String
    public let waitingAccounts: [LogicalMailboxID]

    public init(changes: [NodeSyncChange], nextCursor: String, revision: String, waitingAccounts: [LogicalMailboxID]) throws {
        let page = try NodeSyncDeltaPage(changes: changes, nextCursor: nextCursor, revision: revision)
        guard waitingAccounts.count <= Int(NodeSyncLimits.maximumPageSize),
              waitingAccounts.allSatisfy(NodeSyncMailModeValidation.logicalMailboxID),
              NodeSyncMailModeValidation.sortedUniqueBytes(waitingAccounts.map { Array($0.rawValue) }),
              changes.allSatisfy({ !waitingAccounts.contains($0.logicalMailboxID) }) else { throw NodeSyncError.invalidValue }
        self.changes = page.changes
        self.nextCursor = page.nextCursor
        self.revision = page.revision
        self.waitingAccounts = waitingAccounts
    }
}

/// Carries a Google refresh token to the Node. Descriptions and reflection
/// are redacted so the token cannot reach logs.
public struct NodeSyncGoogleTokenImportRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let expectedProviderIdentity: String
    public let logicalMailboxID: LogicalMailboxID
    public let refreshToken: String

    public init(expectedProviderIdentity: String, logicalMailboxID: LogicalMailboxID, refreshToken: String) throws {
        guard NodeSyncMailModeValidation.providerIdentity(expectedProviderIdentity),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID),
              NodeSyncMailModeValidation.credential(refreshToken, maximum: NodeSyncMailModeLimits.maximumCredentialBytes) else { throw NodeSyncError.invalidValue }
        self.expectedProviderIdentity = expectedProviderIdentity
        self.logicalMailboxID = logicalMailboxID
        self.refreshToken = refreshToken
    }

    public var description: String { "NodeSyncGoogleTokenImportRequest(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public struct NodeSyncMailEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// `implicit_tls` or `starttls`.
    public let security: String

    public init(host: String, port: UInt16, security: String) throws {
        guard NodeSyncMailModeValidation.host(host), port != 0, ["implicit_tls", "starttls"].contains(security) else { throw NodeSyncError.invalidValue }
        self.host = host
        self.port = port
        self.security = security
    }
}

/// Distinct provider mailbox paths for each role; `archive` is optional and
/// omitted from the wire when nil.
public struct NodeSyncMailboxRolePaths: Equatable, Sendable {
    public let archive: String?
    public let drafts: String
    public let inbox: String
    public let sent: String
    public let trash: String

    public init(archive: String?, drafts: String, inbox: String, sent: String, trash: String) throws {
        let paths = [drafts, inbox, sent, trash] + (archive.map { [$0] } ?? [])
        guard paths.allSatisfy(NodeSyncMailModeValidation.mailboxPath),
              Set(paths.map { Data($0.utf8) }).count == paths.count else { throw NodeSyncError.invalidValue }
        self.archive = archive
        self.drafts = drafts
        self.inbox = inbox
        self.sent = sent
        self.trash = trash
    }
}

/// Carries a generic IMAP/SMTP login to the Node. Descriptions and reflection
/// are redacted so the password cannot reach logs.
public struct NodeSyncIMAPProviderImportRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let expectedProviderIdentity: String
    public let imap: NodeSyncMailEndpoint
    public let logicalMailboxID: LogicalMailboxID
    public let password: String
    public let roles: NodeSyncMailboxRolePaths
    public let smtp: NodeSyncMailEndpoint
    public let username: String

    public init(expectedProviderIdentity: String, imap: NodeSyncMailEndpoint, logicalMailboxID: LogicalMailboxID, password: String, roles: NodeSyncMailboxRolePaths, smtp: NodeSyncMailEndpoint, username: String) throws {
        guard NodeSyncMailModeValidation.providerIdentity(expectedProviderIdentity),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID),
              NodeSyncMailModeValidation.credential(password, maximum: NodeSyncMailModeLimits.maximumCredentialBytes),
              NodeSyncMailModeValidation.credential(username, maximum: NodeSyncMailModeLimits.maximumUsernameBytes) else { throw NodeSyncError.invalidValue }
        self.expectedProviderIdentity = expectedProviderIdentity
        self.imap = imap
        self.logicalMailboxID = logicalMailboxID
        self.password = password
        self.roles = roles
        self.smtp = smtp
        self.username = username
    }

    public var description: String { "NodeSyncIMAPProviderImportRequest(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public enum NodeSyncProviderImportState: String, Equatable, Sendable, CaseIterable {
    case created
    case unchanged
    case replaced
}

public struct NodeSyncProviderImportResult: Equatable, Sendable {
    public let assignments: [NodeSyncDiscoveredMailbox]
    public let logicalMailboxID: LogicalMailboxID
    public let providerIdentity: String
    public let state: NodeSyncProviderImportState

    public init(assignments: [NodeSyncDiscoveredMailbox], logicalMailboxID: LogicalMailboxID, providerIdentity: String, state: NodeSyncProviderImportState) throws {
        guard NodeSyncMailModeValidation.ownedAssignments(assignments, owner: logicalMailboxID),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID),
              NodeSyncMailModeValidation.providerIdentity(providerIdentity) else { throw NodeSyncError.invalidValue }
        self.assignments = assignments
        self.logicalMailboxID = logicalMailboxID
        self.providerIdentity = providerIdentity
        self.state = state
    }
}

public struct NodeSyncProviderRemoveRequest: Equatable, Sendable {
    public let expectedProviderIdentity: String
    public let logicalMailboxID: LogicalMailboxID

    public init(expectedProviderIdentity: String, logicalMailboxID: LogicalMailboxID) throws {
        guard NodeSyncMailModeValidation.providerIdentity(expectedProviderIdentity),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID) else { throw NodeSyncError.invalidValue }
        self.expectedProviderIdentity = expectedProviderIdentity
        self.logicalMailboxID = logicalMailboxID
    }
}

public struct NodeSyncProviderRemoveResult: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID
    /// `removed` or `absent`.
    public let state: String

    public init(logicalMailboxID: LogicalMailboxID, state: String) throws {
        guard NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID), ["removed", "absent"].contains(state) else { throw NodeSyncError.invalidValue }
        self.logicalMailboxID = logicalMailboxID
        self.state = state
    }
}

/// `node-sync.account-snapshot-request.v1`; the result is the existing
/// `node-sync.snapshot-page.v1` family for that one account.
public struct NodeSyncAccountSnapshotRequest: Equatable, Sendable {
    public let after: String
    public let limit: UInt16
    public let logicalMailboxID: LogicalMailboxID

    public init(after: String, limit: UInt16, logicalMailboxID: LogicalMailboxID) throws {
        let page = try NodeSyncSnapshotRequest(after: after, limit: limit)
        guard NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID) else { throw NodeSyncError.invalidValue }
        self.after = page.after
        self.limit = page.limit
        self.logicalMailboxID = logicalMailboxID
    }
}

/// 1...200 message IDs sorted by UTF-8 bytes without duplicates.
public struct NodeSyncMirrorCoordinatesRequest: Equatable, Sendable {
    public let messageIDs: [String]

    public init(messageIDs: [String]) throws {
        guard (1...Int(NodeSyncLimits.maximumPageSize)).contains(messageIDs.count),
              messageIDs.allSatisfy({ NodeSyncMailModeValidation.identifier($0) }),
              NodeSyncMailModeValidation.sortedUniqueUTF8(messageIDs) else { throw NodeSyncError.invalidValue }
        self.messageIDs = messageIDs
    }
}

/// A provider coordinate sent only to authenticated, trusted devices of the
/// same account.
public struct NodeSyncMirrorMembership: Equatable, Sendable {
    public let flags: [String]
    public let logicalMailboxID: LogicalMailboxID
    public let mailboxPath: String
    public let uid: UInt32
    public let uidValidity: UInt32

    public init(flags: [String], logicalMailboxID: LogicalMailboxID, mailboxPath: String, uid: UInt32, uidValidity: UInt32) throws {
        guard NodeSyncMailModeValidation.sortedFlags(flags),
              NodeSyncMailModeValidation.logicalMailboxID(logicalMailboxID),
              NodeSyncMailModeValidation.mailboxPath(mailboxPath),
              uid != 0, uidValidity != 0 else { throw NodeSyncError.invalidValue }
        self.flags = flags
        self.logicalMailboxID = logicalMailboxID
        self.mailboxPath = mailboxPath
        self.uid = uid
        self.uidValidity = uidValidity
    }
}

/// One known message. Memberships sort by logical mailbox bytes, then
/// mailbox path bytes.
public struct NodeSyncMirrorCoordinate: Equatable, Sendable {
    public let memberships: [NodeSyncMirrorMembership]
    public let messageID: String
    public let rfcMessageID: String?

    public init(memberships: [NodeSyncMirrorMembership], messageID: String, rfcMessageID: String?) throws {
        guard memberships.count <= Int(NodeSyncLimits.maximumPageSize),
              NodeSyncMailModeValidation.sortedMemberships(memberships),
              NodeSyncMailModeValidation.identifier(messageID),
              rfcMessageID.map({ NodeSyncMailModeValidation.identifier($0, maximum: NodeSyncLimits.maximumMessageReferenceBytes) }) ?? true else { throw NodeSyncError.invalidValue }
        self.memberships = memberships
        self.messageID = messageID
        self.rfcMessageID = rfcMessageID
    }
}

/// Records sort by message ID bytes without duplicates.
public struct NodeSyncMirrorCoordinatesResult: Equatable, Sendable {
    public let records: [NodeSyncMirrorCoordinate]

    public init(records: [NodeSyncMirrorCoordinate]) throws {
        guard records.count <= Int(NodeSyncLimits.maximumPageSize),
              NodeSyncMailModeValidation.sortedUniqueUTF8(records.map(\.messageID)) else { throw NodeSyncError.invalidValue }
        self.records = records
    }
}

enum NodeSyncMailModeLimits {
    static let maximumCredentialBytes = 16 << 10
    static let maximumUsernameBytes = 512
    static let maximumProviderIdentityBytes = 320
    static let maximumHostBytes = 253
    static let maximumMailboxPathBytes = 512
}

/// Mirrors the private NodeSyncValidation helpers the mail-mode families need
/// without widening them.
enum NodeSyncMailModeValidation {
    static func text(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func identifier(_ value: String, maximum: Int = NodeSyncLimits.maximumIdentifierBytes) -> Bool {
        !value.isEmpty && text(value, maximum: maximum)
    }

    static func logicalMailboxID(_ value: LogicalMailboxID) -> Bool {
        value.rawValue.count == 32 && !value.rawValue.allSatisfy({ $0 == 0 })
    }

    static func mailboxPath(_ value: String) -> Bool {
        identifier(value, maximum: NodeSyncMailModeLimits.maximumMailboxPathBytes)
    }

    /// CR, LF and NUL would let a credential alter IMAP/SMTP command framing.
    static func credential(_ value: String, maximum: Int) -> Bool {
        identifier(value, maximum: maximum) && !value.utf8.contains(13) && !value.utf8.contains(10)
    }

    /// A lower-case ASCII dot-atom addr-spec of at most 320 bytes.
    static func providerIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...NodeSyncMailModeLimits.maximumProviderIdentityBytes).contains(bytes.count),
              let at = bytes.firstIndex(of: 64), at > 0, at < bytes.count - 1 else { return false }
        let localSpecials = Set("!#$%&'*+/=?^_`{|}~.-".utf8)
        let local = bytes[..<at].allSatisfy { lowerAlphanumeric($0) || localSpecials.contains($0) }
        let domain = bytes[(at + 1)...].allSatisfy { lowerAlphanumeric($0) || $0 == 46 || $0 == 45 }
        return local && domain
    }

    /// A lower-case DNS name or IPv4 address of at most 253 bytes.
    static func host(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...NodeSyncMailModeLimits.maximumHostBytes).contains(bytes.count) else { return false }
        for (index, byte) in bytes.enumerated() where !lowerAlphanumeric(byte) {
            guard index != 0, index != bytes.count - 1, byte == 46 || byte == 45 else { return false }
        }
        return true
    }

    static func sortedFlags(_ values: [String]) -> Bool {
        let allowed = Set(["answered", "deleted", "draft", "flagged", "seen"])
        return values.allSatisfy(allowed.contains) && sortedUniqueUTF8(values)
    }

    static func sortedUniqueUTF8(_ values: [String]) -> Bool {
        sortedUniqueBytes(values.map { Array($0.utf8) })
    }

    static func sortedUniqueBytes(_ values: [[UInt8]]) -> Bool {
        for index in values.indices.dropFirst() {
            guard values[index - 1].lexicographicallyPrecedes(values[index]) else { return false }
        }
        return true
    }

    static func sortedMemberships(_ values: [NodeSyncMirrorMembership]) -> Bool {
        for index in values.indices.dropFirst() {
            let previous = values[index - 1]
            let current = values[index]
            let previousKey = Array(previous.logicalMailboxID.rawValue) + [0] + Array(previous.mailboxPath.utf8)
            let currentKey = Array(current.logicalMailboxID.rawValue) + [0] + Array(current.mailboxPath.utf8)
            guard previousKey.lexicographicallyPrecedes(currentKey) else { return false }
        }
        return true
    }

    static func ownedAssignments(_ values: [NodeSyncDiscoveredMailbox], owner: LogicalMailboxID) -> Bool {
        values.count <= Int(NodeSyncLimits.maximumPageSize) && values.allSatisfy { ($0.logicalMailboxID ?? owner) == owner }
    }

    static func decimal(_ value: String) -> UInt64? {
        guard let number = UInt64(value), number > 0, String(number) == value else { return nil }
        return number
    }

    private static func lowerAlphanumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
}
