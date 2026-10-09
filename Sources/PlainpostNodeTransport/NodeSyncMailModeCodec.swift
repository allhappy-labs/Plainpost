import Foundation
import PlainpostAccountProtocol

/// Strict canonical codec for the node-sync-v1 mail-mode families. Decoding
/// parses, rejects unknown, duplicate, missing and non-canonical members by
/// re-encoding and comparing bytes, then applies the value validation.
public enum NodeSyncMailModeCodec {
    public static func decodeMailCapabilities(_ data: Data) throws -> NodeSyncMailCapabilities {
        let wire: MailCapabilitiesWire = try decodeFamily(data, "node-sync.mail-capabilities.v1")
        guard wire.version == "1" else { throw NodeSyncError.invalidValue }
        return NodeSyncMailCapabilities(googleImport: wire.googleImport, imapImport: wire.imapImport, mirrorCoordinates: wire.mirrorCoordinates, multiAccount: wire.multiAccount)
    }

    public static func encodeMailCapabilities(_ value: NodeSyncMailCapabilities) throws -> Data {
        try canonical(MailCapabilitiesWire(googleImport: value.googleImport, imapImport: value.imapImport, kind: "node-sync.mail-capabilities.v1", mirrorCoordinates: value.mirrorCoordinates, multiAccount: value.multiAccount, version: "1"))
    }

    public static func decodeMailAccountsResult(_ data: Data) throws -> NodeSyncMailAccountsResult {
        let wire: MailAccountsResultWire = try decodeFamily(data, "node-sync.mail-accounts-result.v1")
        guard let primaryState = NodeSyncMailPrimaryState(rawValue: wire.primaryState) else { throw NodeSyncError.invalidValue }
        return try NodeSyncMailAccountsResult(accounts: try wire.accounts.map { account in
            guard let state = NodeSyncMailAccountState(rawValue: account.state) else { throw NodeSyncError.invalidValue }
            return try NodeSyncMailAccount(assignments: try account.assignments.map(discoveredMailbox), logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(account.logicalMailboxID), primary: account.primary, providerIdentity: account.providerIdentity, providerKind: account.providerKind, state: state)
        }, primaryState: primaryState)
    }

    public static func encodeMailAccountsResult(_ value: NodeSyncMailAccountsResult) throws -> Data {
        try canonical(MailAccountsResultWire(accounts: try value.accounts.map { account in
            MailAccountWire(assignments: try account.assignments.map(discoveredMailboxWire), logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(account.logicalMailboxID), primary: account.primary, providerIdentity: account.providerIdentity, providerKind: account.providerKind, state: account.state.rawValue)
        }, kind: "node-sync.mail-accounts-result.v1", primaryState: value.primaryState.rawValue))
    }

    public static func decodeMailDeltaPage(_ data: Data) throws -> NodeSyncMailDeltaPage {
        let wire: MailDeltaPageWire = try decodeFamily(data, "node-sync.mail-delta-page.v1")
        return try NodeSyncMailDeltaPage(
            changes: try wire.changes.map { try NodeSyncChange(kind: $0.kind, logicalMailboxID: NodeSyncCodec.decodeLogicalMailboxID($0.logicalMailboxID), messageID: $0.messageID, threadID: $0.threadID) },
            nextCursor: wire.nextCursor, revision: wire.revision,
            waitingAccounts: try wire.waitingAccounts.map(NodeSyncCodec.decodeLogicalMailboxID))
    }

    public static func encodeMailDeltaPage(_ value: NodeSyncMailDeltaPage) throws -> Data {
        try canonical(MailDeltaPageWire(
            changes: try value.changes.map { MailModeChangeWire(kind: $0.kind, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID($0.logicalMailboxID), messageID: $0.messageID, threadID: $0.threadID) },
            kind: "node-sync.mail-delta-page.v1", nextCursor: value.nextCursor, revision: value.revision,
            waitingAccounts: try value.waitingAccounts.map(NodeSyncCodec.encodeLogicalMailboxID)))
    }

    public static func decodeGoogleTokenImportRequest(_ data: Data) throws -> NodeSyncGoogleTokenImportRequest {
        let wire: GoogleTokenImportRequestWire = try decodeFamily(data, "node-sync.google-token-import-request.v1")
        return try NodeSyncGoogleTokenImportRequest(expectedProviderIdentity: wire.expectedProviderIdentity, logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID), refreshToken: wire.refreshToken)
    }

    public static func encodeGoogleTokenImportRequest(_ value: NodeSyncGoogleTokenImportRequest) throws -> Data {
        try canonical(GoogleTokenImportRequestWire(expectedProviderIdentity: value.expectedProviderIdentity, kind: "node-sync.google-token-import-request.v1", logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID), refreshToken: value.refreshToken))
    }

    public static func decodeIMAPProviderImportRequest(_ data: Data) throws -> NodeSyncIMAPProviderImportRequest {
        let wire: IMAPProviderImportRequestWire = try decodeFamily(data, "node-sync.imap-provider-import-request.v1")
        let roles = try NodeSyncMailboxRolePaths(archive: wire.roles.archive, drafts: wire.roles.drafts, inbox: wire.roles.inbox, sent: wire.roles.sent, trash: wire.roles.trash)
        return try NodeSyncIMAPProviderImportRequest(expectedProviderIdentity: wire.expectedProviderIdentity, imap: try endpoint(wire.imap), logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID), password: wire.password, roles: roles, smtp: try endpoint(wire.smtp), username: wire.username)
    }

    public static func encodeIMAPProviderImportRequest(_ value: NodeSyncIMAPProviderImportRequest) throws -> Data {
        let roles = MailboxRolePathsWire(archive: value.roles.archive, drafts: value.roles.drafts, inbox: value.roles.inbox, sent: value.roles.sent, trash: value.roles.trash)
        return try canonical(IMAPProviderImportRequestWire(expectedProviderIdentity: value.expectedProviderIdentity, imap: endpointWire(value.imap), kind: "node-sync.imap-provider-import-request.v1", logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID), password: value.password, roles: roles, smtp: endpointWire(value.smtp), username: value.username))
    }

    public static func decodeProviderImportResult(_ data: Data) throws -> NodeSyncProviderImportResult {
        let wire: ProviderImportResultWire = try decodeFamily(data, "node-sync.provider-import-result.v1")
        guard let state = NodeSyncProviderImportState(rawValue: wire.state) else { throw NodeSyncError.invalidValue }
        return try NodeSyncProviderImportResult(assignments: try wire.assignments.map(discoveredMailbox), logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID), providerIdentity: wire.providerIdentity, state: state)
    }

    public static func encodeProviderImportResult(_ value: NodeSyncProviderImportResult) throws -> Data {
        try canonical(ProviderImportResultWire(assignments: try value.assignments.map(discoveredMailboxWire), kind: "node-sync.provider-import-result.v1", logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID), providerIdentity: value.providerIdentity, state: value.state.rawValue))
    }

    public static func decodeProviderRemoveRequest(_ data: Data) throws -> NodeSyncProviderRemoveRequest {
        let wire: ProviderRemoveRequestWire = try decodeFamily(data, "node-sync.provider-remove-request.v1")
        return try NodeSyncProviderRemoveRequest(expectedProviderIdentity: wire.expectedProviderIdentity, logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID))
    }

    public static func encodeProviderRemoveRequest(_ value: NodeSyncProviderRemoveRequest) throws -> Data {
        try canonical(ProviderRemoveRequestWire(expectedProviderIdentity: value.expectedProviderIdentity, kind: "node-sync.provider-remove-request.v1", logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID)))
    }

    public static func decodeProviderRemoveResult(_ data: Data) throws -> NodeSyncProviderRemoveResult {
        let wire: ProviderRemoveResultWire = try decodeFamily(data, "node-sync.provider-remove-result.v1")
        return try NodeSyncProviderRemoveResult(logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID), state: wire.state)
    }

    public static func encodeProviderRemoveResult(_ value: NodeSyncProviderRemoveResult) throws -> Data {
        try canonical(ProviderRemoveResultWire(kind: "node-sync.provider-remove-result.v1", logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID), state: value.state))
    }

    public static func decodeAccountSnapshotRequest(_ data: Data) throws -> NodeSyncAccountSnapshotRequest {
        let wire: AccountSnapshotRequestWire = try decodeFamily(data, "node-sync.account-snapshot-request.v1")
        return try NodeSyncAccountSnapshotRequest(after: wire.after, limit: wire.limit, logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(wire.logicalMailboxID))
    }

    public static func encodeAccountSnapshotRequest(_ value: NodeSyncAccountSnapshotRequest) throws -> Data {
        try canonical(AccountSnapshotRequestWire(after: value.after, kind: "node-sync.account-snapshot-request.v1", limit: value.limit, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(value.logicalMailboxID)))
    }

    public static func decodeMirrorCoordinatesRequest(_ data: Data) throws -> NodeSyncMirrorCoordinatesRequest {
        let wire: MirrorCoordinatesRequestWire = try decodeFamily(data, "node-sync.mirror-coordinates-request.v1")
        return try NodeSyncMirrorCoordinatesRequest(messageIDs: wire.messageIDs)
    }

    public static func encodeMirrorCoordinatesRequest(_ value: NodeSyncMirrorCoordinatesRequest) throws -> Data {
        try canonical(MirrorCoordinatesRequestWire(kind: "node-sync.mirror-coordinates-request.v1", messageIDs: value.messageIDs))
    }

    public static func decodeMirrorCoordinatesResult(_ data: Data) throws -> NodeSyncMirrorCoordinatesResult {
        let wire: MirrorCoordinatesResultWire = try decodeFamily(data, "node-sync.mirror-coordinates-result.v1")
        return try NodeSyncMirrorCoordinatesResult(records: try wire.records.map { record in
            try NodeSyncMirrorCoordinate(memberships: try record.memberships.map { membership in
                guard let uid = NodeSyncMailModeValidation.decimal(membership.uid).flatMap(UInt32.init(exactly:)),
                      let uidValidity = NodeSyncMailModeValidation.decimal(membership.uidValidity).flatMap(UInt32.init(exactly:)) else { throw NodeSyncError.invalidValue }
                return try NodeSyncMirrorMembership(flags: membership.flags, logicalMailboxID: try NodeSyncCodec.decodeLogicalMailboxID(membership.logicalMailboxID), mailboxPath: membership.mailboxPath, uid: uid, uidValidity: uidValidity)
            }, messageID: record.messageID, rfcMessageID: record.rfcMessageID)
        })
    }

    public static func encodeMirrorCoordinatesResult(_ value: NodeSyncMirrorCoordinatesResult) throws -> Data {
        try canonical(MirrorCoordinatesResultWire(kind: "node-sync.mirror-coordinates-result.v1", records: try value.records.map { record in
            MirrorCoordinateWire(memberships: try record.memberships.map { membership in
                MirrorMembershipWire(flags: membership.flags, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(membership.logicalMailboxID), mailboxPath: membership.mailboxPath, uid: String(membership.uid), uidValidity: String(membership.uidValidity))
            }, messageID: record.messageID, rfcMessageID: record.rfcMessageID)
        }))
    }

    private static func endpoint(_ wire: MailEndpointWire) throws -> NodeSyncMailEndpoint {
        guard let port = NodeSyncMailModeValidation.decimal(wire.port).flatMap(UInt16.init(exactly:)) else { throw NodeSyncError.invalidValue }
        return try NodeSyncMailEndpoint(host: wire.host, port: port, security: wire.security)
    }

    private static func endpointWire(_ value: NodeSyncMailEndpoint) -> MailEndpointWire {
        MailEndpointWire(host: value.host, port: String(value.port), security: value.security)
    }

    private static func discoveredMailbox(_ value: MailModeDiscoveredMailboxWire) throws -> NodeSyncDiscoveredMailbox {
        try NodeSyncDiscoveredMailbox(displayName: value.displayName, logicalMailboxID: try value.logicalMailboxID.map(NodeSyncCodec.decodeLogicalMailboxID), mailboxHandle: value.mailboxHandle, role: value.role, authorityEpoch: value.authorityEpoch)
    }

    private static func discoveredMailboxWire(_ value: NodeSyncDiscoveredMailbox) throws -> MailModeDiscoveredMailboxWire {
        MailModeDiscoveredMailboxWire(authorityEpoch: value.authorityEpoch, displayName: value.displayName, logicalMailboxID: try value.logicalMailboxID.map(NodeSyncCodec.encodeLogicalMailboxID), mailboxHandle: value.mailboxHandle, role: value.role)
    }

    // The helpers below mirror NodeSyncCodec's private canonical helpers.
    private static func decodeFamily<Value: Codable & MailModeKindWire>(_ data: Data, _ kind: String) throws -> Value {
        guard data.count <= NodeSyncLimits.maximumCanonicalFamilyBytes,
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              validJSON(object),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              try canonical(value) == data,
              value.kind == kind else {
            throw NodeSyncError.invalidValue
        }
        return value
    }

    private static func canonical<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let result = Data(text.utf8)
        guard result.count <= NodeSyncLimits.maximumCanonicalFamilyBytes else { throw NodeSyncError.invalidValue }
        return result
    }

    private static func validJSON(_ value: Any) -> Bool {
        if let text = value as? String {
            return NodeSyncMailModeValidation.text(text, maximum: NodeSyncLimits.maximumRequestBodyBytes)
        }
        if let values = value as? [Any] {
            return values.allSatisfy(validJSON)
        }
        if let values = value as? [String: Any] {
            return values.allSatisfy { NodeSyncMailModeValidation.text($0.key, maximum: NodeSyncLimits.maximumRequestBodyBytes) && validJSON($0.value) }
        }
        return value is NSNumber || value is NSNull
    }
}

private protocol MailModeKindWire { var kind: String { get } }

private struct MailCapabilitiesWire: Codable, MailModeKindWire { let googleImport: Bool; let imapImport: Bool; let kind: String; let mirrorCoordinates: Bool; let multiAccount: Bool; let version: String }
private struct MailAccountsResultWire: Codable, MailModeKindWire { let accounts: [MailAccountWire]; let kind: String; let primaryState: String }
private struct MailDeltaPageWire: Codable, MailModeKindWire { let changes: [MailModeChangeWire]; let kind: String; let nextCursor: String; let revision: String; let waitingAccounts: [String] }

/// `messageID` and `threadID` are always present and explicitly null when absent.
private struct MailModeChangeWire: Codable {
    let kind: String
    let logicalMailboxID: String
    let messageID: String?
    let threadID: String?

    private enum CodingKeys: String, CodingKey { case kind, logicalMailboxID, messageID, threadID }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(logicalMailboxID, forKey: .logicalMailboxID)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(threadID, forKey: .threadID)
    }
}
private struct MailAccountWire: Codable { let assignments: [MailModeDiscoveredMailboxWire]; let logicalMailboxID: String; let primary: Bool; let providerIdentity: String; let providerKind: String; let state: String }
private struct GoogleTokenImportRequestWire: Codable, MailModeKindWire { let expectedProviderIdentity: String; let kind: String; let logicalMailboxID: String; let refreshToken: String }
private struct MailEndpointWire: Codable { let host: String; let port: String; let security: String }
private struct IMAPProviderImportRequestWire: Codable, MailModeKindWire { let expectedProviderIdentity: String; let imap: MailEndpointWire; let kind: String; let logicalMailboxID: String; let password: String; let roles: MailboxRolePathsWire; let smtp: MailEndpointWire; let username: String }
private struct ProviderImportResultWire: Codable, MailModeKindWire { let assignments: [MailModeDiscoveredMailboxWire]; let kind: String; let logicalMailboxID: String; let providerIdentity: String; let state: String }
private struct ProviderRemoveRequestWire: Codable, MailModeKindWire { let expectedProviderIdentity: String; let kind: String; let logicalMailboxID: String }
private struct ProviderRemoveResultWire: Codable, MailModeKindWire { let kind: String; let logicalMailboxID: String; let state: String }
private struct AccountSnapshotRequestWire: Codable, MailModeKindWire { let after: String; let kind: String; let limit: UInt16; let logicalMailboxID: String }
private struct MirrorCoordinatesRequestWire: Codable, MailModeKindWire { let kind: String; let messageIDs: [String] }
private struct MirrorCoordinatesResultWire: Codable, MailModeKindWire { let kind: String; let records: [MirrorCoordinateWire] }
private struct MirrorMembershipWire: Codable { let flags: [String]; let logicalMailboxID: String; let mailboxPath: String; let uid: String; let uidValidity: String }

/// `archive` is omitted, never null, when absent.
private struct MailboxRolePathsWire: Codable {
    let archive: String?
    let drafts: String
    let inbox: String
    let sent: String
    let trash: String

    private enum CodingKeys: String, CodingKey { case archive, drafts, inbox, sent, trash }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(archive, forKey: .archive)
        try container.encode(drafts, forKey: .drafts)
        try container.encode(inbox, forKey: .inbox)
        try container.encode(sent, forKey: .sent)
        try container.encode(trash, forKey: .trash)
    }
}

/// `rfcMessageID` is always present and explicitly null when absent.
private struct MirrorCoordinateWire: Codable {
    let memberships: [MirrorMembershipWire]
    let messageID: String
    let rfcMessageID: String?

    private enum CodingKeys: String, CodingKey { case memberships, messageID, rfcMessageID }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memberships, forKey: .memberships)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(rfcMessageID, forKey: .rfcMessageID)
    }
}

/// Same shape as the legacy discovered-mailbox wire: `logicalMailboxID` is
/// always present (null when unassigned) and `authorityEpoch` is omitted when
/// absent.
private struct MailModeDiscoveredMailboxWire: Codable {
    let authorityEpoch: String?
    let displayName: String
    let logicalMailboxID: String?
    let mailboxHandle: String
    let role: String

    private enum CodingKeys: String, CodingKey { case authorityEpoch, displayName, logicalMailboxID, mailboxHandle, role }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(authorityEpoch, forKey: .authorityEpoch)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(logicalMailboxID, forKey: .logicalMailboxID)
        try container.encode(mailboxHandle, forKey: .mailboxHandle)
        try container.encode(role, forKey: .role)
    }
}
