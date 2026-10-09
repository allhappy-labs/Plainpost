import Foundation
import PlainpostAccountProtocol

public enum NodeSyncError: Error, Equatable, Sendable {
    case invalidValue
}

public enum NodeSyncProblem: String, Codable, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case conflict
    case staleCursor = "stale_cursor"
    case unavailable
}

public enum NodeSyncBodyState: String, Codable, Equatable, Sendable {
    case complete
    case absent
    case malformed
    case omittedOversized = "omitted_oversized"
}

public struct NodeSyncAddress: Codable, Equatable, Sendable {
    public let displayName: String
    public let mailbox: String

    public init(displayName: String, mailbox: String) {
        self.displayName = displayName
        self.mailbox = mailbox
    }
}

public struct NodeSyncBody: Codable, Equatable, Sendable {
    public let state: NodeSyncBodyState
    public let value: String?

    public init(state: NodeSyncBodyState, value: String?) {
        self.state = state
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case state, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(value, forKey: .value)
    }
}

public struct NodeSyncAttachment: Codable, Equatable, Sendable {
    public let contentDigest: String?
    public let contentID: String?
    public let disposition: String
    public let filename: String
    public let id: String
    public let mime: String
    public let size: String

    public init(contentDigest: String?, contentID: String?, disposition: String, filename: String, id: String, mime: String, size: String) {
        self.contentDigest = contentDigest
        self.contentID = contentID
        self.disposition = disposition
        self.filename = filename
        self.id = id
        self.mime = mime
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case contentDigest, contentID, disposition, filename, id, mime, size
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(contentID, forKey: .contentID)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(filename, forKey: .filename)
        try container.encode(id, forKey: .id)
        try container.encode(mime, forKey: .mime)
        try container.encode(size, forKey: .size)
    }
}

public struct NodeSyncMessage: Codable, Equatable, Sendable {
    public let attachments: [NodeSyncAttachment]
    public let bcc: [NodeSyncAddress]
    public let cc: [NodeSyncAddress]
    public let flags: [String]
    public let from: [NodeSyncAddress]
    public let htmlBody: NodeSyncBody
    public let id: String
    public let inReplyTo: [String]
    public let labels: [String]
    public let receivedAt: String
    public let references: [String]
    public let replyTo: [NodeSyncAddress]
    public let sentAt: String?
    public let subject: String
    public let textBody: NodeSyncBody
    public let threadID: String
    public let to: [NodeSyncAddress]

    public init(attachments: [NodeSyncAttachment], bcc: [NodeSyncAddress], cc: [NodeSyncAddress], flags: [String], from: [NodeSyncAddress], htmlBody: NodeSyncBody, id: String, inReplyTo: [String], labels: [String], receivedAt: String, references: [String], replyTo: [NodeSyncAddress], sentAt: String?, subject: String, textBody: NodeSyncBody, threadID: String, to: [NodeSyncAddress]) {
        self.attachments = attachments
        self.bcc = bcc
        self.cc = cc
        self.flags = flags
        self.from = from
        self.htmlBody = htmlBody
        self.id = id
        self.inReplyTo = inReplyTo
        self.labels = labels
        self.receivedAt = receivedAt
        self.references = references
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.subject = subject
        self.textBody = textBody
        self.threadID = threadID
        self.to = to
    }

    private enum CodingKeys: String, CodingKey {
        case attachments, bcc, cc, flags, from, htmlBody, id, inReplyTo, labels, receivedAt, references, replyTo, sentAt, subject, textBody, threadID, to
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(bcc, forKey: .bcc)
        try container.encode(cc, forKey: .cc)
        try container.encode(flags, forKey: .flags)
        try container.encode(from, forKey: .from)
        try container.encode(htmlBody, forKey: .htmlBody)
        try container.encode(id, forKey: .id)
        try container.encode(inReplyTo, forKey: .inReplyTo)
        try container.encode(labels, forKey: .labels)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encode(references, forKey: .references)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(subject, forKey: .subject)
        try container.encode(textBody, forKey: .textBody)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(to, forKey: .to)
    }
}

public struct NodeSyncSnapshotRequest: Equatable, Sendable {
    public let after: String
    public let limit: UInt16

    public init(after: String, limit: UInt16) throws {
        guard NodeSyncValidation.cursor(after), (1...NodeSyncLimits.maximumPageSize).contains(limit) else { throw NodeSyncError.invalidValue }
        self.after = after
        self.limit = limit
    }
}

public struct NodeSyncSnapshotPage: Equatable, Sendable {
    public let messages: [NodeSyncMessage]
    public let nextCursor: String
    public let revision: String

    public init(messages: [NodeSyncMessage], nextCursor: String, revision: String) throws {
        guard messages.count <= Int(NodeSyncLimits.maximumPageSize), NodeSyncValidation.cursor(nextCursor), NodeSyncValidation.decimal(revision, allowZero: false), messages.allSatisfy(NodeSyncValidation.message) else { throw NodeSyncError.invalidValue }
        self.messages = messages
        self.nextCursor = nextCursor
        self.revision = revision
    }
}

public struct NodeSyncDeltaRequest: Equatable, Sendable {
    public let after: String
    public let limit: UInt16

    public init(after: String, limit: UInt16) throws {
        guard NodeSyncValidation.cursor(after), (1...NodeSyncLimits.maximumPageSize).contains(limit) else { throw NodeSyncError.invalidValue }
        self.after = after
        self.limit = limit
    }
}

public struct NodeSyncChange: Equatable, Sendable {
    public let kind: String
    public let logicalMailboxID: LogicalMailboxID
    public let messageID: String?
    public let threadID: String?

    public init(kind: String, logicalMailboxID: LogicalMailboxID, messageID: String?, threadID: String?) throws {
        guard NodeSyncValidation.change(kind: kind, logicalMailboxID: logicalMailboxID, messageID: messageID, threadID: threadID) else { throw NodeSyncError.invalidValue }
        self.kind = kind
        self.logicalMailboxID = logicalMailboxID
        self.messageID = messageID
        self.threadID = threadID
    }
}

public struct NodeSyncDeltaPage: Equatable, Sendable {
    public let changes: [NodeSyncChange]
    public let nextCursor: String
    public let revision: String

    public init(changes: [NodeSyncChange], nextCursor: String, revision: String) throws {
        guard changes.count <= Int(NodeSyncLimits.maximumPageSize), NodeSyncValidation.cursor(nextCursor), NodeSyncValidation.decimal(revision, allowZero: false), changes.allSatisfy(NodeSyncValidation.change) else { throw NodeSyncError.invalidValue }
        self.changes = changes
        self.nextCursor = nextCursor
        self.revision = revision
    }
}

public struct NodeSyncSearchRequest: Equatable, Sendable {
    public let after: String
    public let limit: UInt16
    public let logicalMailboxIDs: [LogicalMailboxID]
    public let query: String

    public init(after: String, limit: UInt16, logicalMailboxIDs: [LogicalMailboxID], query: String) throws {
        guard NodeSyncValidation.cursor(after), (1...NodeSyncLimits.maximumPageSize).contains(limit), NodeSyncValidation.sortedLogicalMailboxIDs(logicalMailboxIDs), NodeSyncValidation.searchQuery(query) else { throw NodeSyncError.invalidValue }
        self.after = after
        self.limit = limit
        self.logicalMailboxIDs = logicalMailboxIDs
        self.query = query
    }
}

public struct NodeSyncSearchPage: Equatable, Sendable {
    public let messages: [NodeSyncMessage]
    public let nextCursor: String
    public let revision: String

    public init(messages: [NodeSyncMessage], nextCursor: String, revision: String) throws {
        guard messages.count <= Int(NodeSyncLimits.maximumPageSize), NodeSyncValidation.cursor(nextCursor), NodeSyncValidation.decimal(revision, allowZero: false), messages.allSatisfy(NodeSyncValidation.message) else { throw NodeSyncError.invalidValue }
        self.messages = messages
        self.nextCursor = nextCursor
        self.revision = revision
    }
}

public struct NodeSyncMessageRequest: Equatable, Sendable {
    public let messageID: String
    public init(messageID: String) throws { guard NodeSyncValidation.identifier(messageID) else { throw NodeSyncError.invalidValue }; self.messageID = messageID }
}

public struct NodeSyncMessageResult: Equatable, Sendable {
    public let message: NodeSyncMessage
    public init(message: NodeSyncMessage) throws { guard NodeSyncValidation.message(message) else { throw NodeSyncError.invalidValue }; self.message = message }
}

public struct NodeSyncAttachmentRequest: Equatable, Sendable {
    public let attachmentID: String
    public init(attachmentID: String) throws { guard NodeSyncValidation.identifier(attachmentID) else { throw NodeSyncError.invalidValue }; self.attachmentID = attachmentID }
}

public struct NodeSyncAttachmentResult: Equatable, Sendable {
    public let attachment: NodeSyncAttachment
    public init(attachment: NodeSyncAttachment) throws { guard NodeSyncValidation.attachment(attachment) else { throw NodeSyncError.invalidValue }; self.attachment = attachment }
}

public struct NodeSyncMutationRequest: Equatable, Sendable {
    public let canonicalOperation: Data

    public init(canonicalOperation: Data) throws {
        guard !canonicalOperation.isEmpty, canonicalOperation.count <= NodeSyncLimits.maximumCanonicalOperationBytes, (try? NodeSyncCodec.decodeOperation(canonicalOperation)) != nil else { throw NodeSyncError.invalidValue }
        self.canonicalOperation = canonicalOperation
    }
}

public struct NodeSyncMutationResult: Equatable, Sendable {
    public let idempotencyKey: String
    public let state: String
    public init(idempotencyKey: String, state: String) throws { guard NodeSyncValidation.identifier(idempotencyKey), ["pending", "applied", "rejected", "conflicted", "delivery_uncertain"].contains(state) else { throw NodeSyncError.invalidValue }; self.idempotencyKey = idempotencyKey; self.state = state }
}

/// Authenticated draft-local state used to resume CAS operations after an
/// authority is recreated. It intentionally contains no message content.
public struct NodeSyncDraftState: Equatable, Sendable {
    public let draftID: String
    public let revision: String
    public let state: String

    public init(draftID: String, revision: String, state: String) throws {
        guard NodeSyncValidation.identifier(draftID),
              NodeSyncValidation.decimal(revision, allowZero: true),
              ["local", "append_pending", "appended", "delete_pending", "deleted", "reconciling", "send_pending", "send_uncertain"].contains(state)
        else { throw NodeSyncError.invalidValue }
        self.draftID = draftID
        self.revision = revision
        self.state = state
    }
}

public struct NodeSyncGoogleProvisionRequest: Equatable, Sendable {
    public let authorizationCode: String
    public let clientID: String
    public let codeVerifier: String
    public let redirectURI: String
    public init(authorizationCode: String, clientID: String, codeVerifier: String, redirectURI: String) throws { guard NodeSyncValidation.identifier(authorizationCode, maximum: 4_096), NodeSyncValidation.identifier(clientID), NodeSyncValidation.pkceCodeVerifier(codeVerifier), NodeSyncValidation.httpsRedirectURI(redirectURI) else { throw NodeSyncError.invalidValue }; self.authorizationCode = authorizationCode; self.clientID = clientID; self.codeVerifier = codeVerifier; self.redirectURI = redirectURI }
}

public struct NodeSyncMailboxAssignment: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID
    public let mailboxHandle: String
    public init(logicalMailboxID: LogicalMailboxID, mailboxHandle: String) throws { guard NodeSyncValidation.logicalMailboxID(logicalMailboxID), NodeSyncValidation.identifier(mailboxHandle) else { throw NodeSyncError.invalidValue }; self.logicalMailboxID = logicalMailboxID; self.mailboxHandle = mailboxHandle }
}

public struct NodeSyncDiscoveredMailbox: Equatable, Sendable {
    public let displayName: String
    public let logicalMailboxID: LogicalMailboxID?
    public let mailboxHandle: String
    public let role: String
    /// The authenticated authority epoch for this logical mailbox. It is
    /// absent on discovery-only responses and present on active assignments.
    public let authorityEpoch: String?
    public init(displayName: String, logicalMailboxID: LogicalMailboxID?, mailboxHandle: String, role: String, authorityEpoch: String? = nil) throws {
        guard NodeSyncValidation.text(displayName, maximum: 4_096),
              logicalMailboxID.map(NodeSyncValidation.logicalMailboxID) ?? true,
              NodeSyncValidation.identifier(mailboxHandle),
              ["inbox", "sent", "drafts", "trash", "junk", "archive", "all", "other"].contains(role),
              authorityEpoch.map({ NodeSyncValidation.decimal($0, allowZero: false) }) ?? true
        else { throw NodeSyncError.invalidValue }
        self.displayName = displayName; self.logicalMailboxID = logicalMailboxID; self.mailboxHandle = mailboxHandle; self.role = role; self.authorityEpoch = authorityEpoch
    }
}

public struct NodeSyncGoogleProvisionResult: Equatable, Sendable {
    public let discoveredMailboxes: [NodeSyncDiscoveredMailbox]
    public let providerIdentity: String
    public init(discoveredMailboxes: [NodeSyncDiscoveredMailbox], providerIdentity: String) throws { guard discoveredMailboxes.count <= Int(NodeSyncLimits.maximumPageSize), NodeSyncValidation.identifier(providerIdentity) else { throw NodeSyncError.invalidValue }; self.discoveredMailboxes = discoveredMailboxes; self.providerIdentity = providerIdentity }
}

public struct NodeSyncMailboxAssignmentsRequest: Equatable, Sendable {
    public let assignments: [NodeSyncMailboxAssignment]
    public init(assignments: [NodeSyncMailboxAssignment]) throws { guard assignments.count <= Int(NodeSyncLimits.maximumPageSize) else { throw NodeSyncError.invalidValue }; self.assignments = assignments }
}

public struct NodeSyncMailboxAssignmentsResult: Equatable, Sendable {
    public let assignments: [NodeSyncDiscoveredMailbox]
    public init(assignments: [NodeSyncDiscoveredMailbox]) throws { guard assignments.count <= Int(NodeSyncLimits.maximumPageSize) else { throw NodeSyncError.invalidValue }; self.assignments = assignments }
}

public struct NodeSyncStatusRequest: Equatable, Sendable {
    public init() {}
}

public struct NodeSyncProviderSyncRequest: Equatable, Sendable {
    public init() {}
}

public struct NodeSyncNotificationRecipientRequest: Equatable, Sendable {
    public let accountID: String
    public let deviceID: String
    public let trustEpoch: String
    public let trustRevision: String
    public let trustHead: Data
    public let routingHandle: Data
    public let agreementPublicKey: Data
    public let deviceSignature: Data
    public let trustCommit: Data

    public init(accountID: String, deviceID: String, trustEpoch: String, trustRevision: String, trustHead: Data, routingHandle: Data, agreementPublicKey: Data, deviceSignature: Data, trustCommit: Data) throws {
        guard PlainpostAccountID(rawValue: accountID) != nil, AccountDeviceID(rawValue: deviceID) != nil,
              NodeSyncValidation.decimal(trustEpoch, allowZero: false), NodeSyncValidation.decimal(trustRevision, allowZero: false),
              trustHead.count == 32, trustHead.contains(where: { $0 != 0 }), routingHandle.count == 32, routingHandle.contains(where: { $0 != 0 }),
              agreementPublicKey.count == 65, agreementPublicKey.first == 4, deviceSignature.count == 64,
              !trustCommit.isEmpty, trustCommit.count <= 256 * 1024 else { throw NodeSyncError.invalidValue }
        self.accountID = accountID; self.deviceID = deviceID; self.trustEpoch = trustEpoch; self.trustRevision = trustRevision
        self.trustHead = trustHead; self.routingHandle = routingHandle; self.agreementPublicKey = agreementPublicKey; self.deviceSignature = deviceSignature; self.trustCommit = trustCommit
    }
}

public struct NodeSyncNotificationRecipientResult: Equatable, Sendable {
    public let state: String
    public init(state: String) throws { guard state == "applied" else { throw NodeSyncError.invalidValue }; self.state = state }
}

public struct NodeSyncNotificationRecipientRemovalRequest: Equatable, Sendable {
    public init() {}
}

public enum NodeSyncNotificationPolicyMode: String, Codable, Equatable, Sendable {
    case richPreview = "rich_preview"
    case senderSubject = "sender_subject"
    case generic
    case off
}

public struct NodeSyncNotificationPolicyReadRequest: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID?
    public init(logicalMailboxID: LogicalMailboxID?) throws {
        guard logicalMailboxID.map(NodeSyncValidation.logicalMailboxID) ?? true else { throw NodeSyncError.invalidValue }
        self.logicalMailboxID = logicalMailboxID
    }
}

public struct NodeSyncNotificationPolicyUpdateRequest: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID?
    public let mode: NodeSyncNotificationPolicyMode
    public let clear: Bool
    public let expectedVersion: String
    public let idempotencyKey: String
    public init(logicalMailboxID: LogicalMailboxID?, mode: NodeSyncNotificationPolicyMode? = nil, clear: Bool = false, expectedVersion: String, idempotencyKey: String) throws {
        guard logicalMailboxID.map(NodeSyncValidation.logicalMailboxID) ?? true,
              NodeSyncValidation.decimal(expectedVersion, allowZero: false),
              UInt64(expectedVersion).map({ (1...65_535).contains($0) }) ?? false,
              NodeSyncValidation.identifier(idempotencyKey, maximum: 256),
              (!clear && mode != nil && (logicalMailboxID != nil || mode != nil)) || (clear && logicalMailboxID != nil && mode == nil)
        else { throw NodeSyncError.invalidValue }
        self.logicalMailboxID = logicalMailboxID; self.mode = mode ?? .richPreview; self.clear = clear; self.expectedVersion = expectedVersion; self.idempotencyKey = idempotencyKey
    }

}

public struct NodeSyncNotificationPolicy: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID?
    public let mode: NodeSyncNotificationPolicyMode
    public let version: String
    public let scopeVersion: String
    public let override: Bool
    public init(logicalMailboxID: LogicalMailboxID?, mode: NodeSyncNotificationPolicyMode, version: String, scopeVersion: String, override: Bool) throws {
        guard logicalMailboxID.map(NodeSyncValidation.logicalMailboxID) ?? true,
              NodeSyncValidation.decimal(version, allowZero: false), NodeSyncValidation.decimal(scopeVersion, allowZero: true),
              UInt64(version).map({ (1...65_535).contains($0) }) ?? false,
              UInt64(scopeVersion).map({ (1...65_535).contains($0) }) ?? false else { throw NodeSyncError.invalidValue }
        self.logicalMailboxID = logicalMailboxID; self.mode = mode; self.version = version; self.scopeVersion = scopeVersion; self.override = override
    }

}

public struct NodeSyncStatusResult: Equatable, Sendable {
    public let revision: String
    public let state: String
    public let version: String
    public let reachability: String
    public let syncLag: String
    public let storage: String
    public let providerIdentity: String?
    public let assignments: [NodeSyncDiscoveredMailbox]
    public let backup: String
    public let endpoint: String
    public let updateStatus: String
    public init(revision: String, state: String, version: String = "unknown", reachability: String = "unknown", syncLag: String? = nil, storage: String = "unknown", providerIdentity: String? = nil, assignments: [NodeSyncDiscoveredMailbox] = [], backup: String = "unknown", endpoint: String = "unknown", updateStatus: String = "unknown") throws {
        let resolvedSyncLag = syncLag ?? "unknown"
        guard NodeSyncValidation.decimal(revision, allowZero: true), ["ready", "degraded", "unavailable"].contains(state), NodeSyncValidation.identifier(version), NodeSyncValidation.identifier(reachability), NodeSyncValidation.identifier(resolvedSyncLag), NodeSyncValidation.identifier(storage), NodeSyncValidation.identifier(backup), NodeSyncValidation.identifier(endpoint, maximum: 2_048), NodeSyncValidation.identifier(updateStatus), assignments.count <= Int(NodeSyncLimits.maximumPageSize), providerIdentity.map({ NodeSyncValidation.identifier($0) }) ?? true, assignments.allSatisfy({ NodeSyncValidation.text($0.displayName, maximum: 4_096) && NodeSyncValidation.identifier($0.mailboxHandle) && ["inbox", "sent", "drafts", "trash", "junk", "archive", "all", "other"].contains($0.role) }) else { throw NodeSyncError.invalidValue }
        self.revision = revision; self.state = state; self.version = version; self.reachability = reachability; self.syncLag = resolvedSyncLag; self.storage = storage; self.providerIdentity = providerIdentity; self.assignments = assignments; self.backup = backup; self.endpoint = endpoint; self.updateStatus = updateStatus
    }
}

public enum NodeSyncOperationState: String, Codable, Equatable, Sendable {
    case verified
    case uncertain
    case erased
    case recoveryRequired = "recovery_required"
    case operatorActionRequired = "operator_action_required"
}

public enum NodeSyncBackupState: String, Codable, Equatable, Sendable {
    case verified
    case uncertain
    case unchanged
}

public enum NodeSyncUpgradeStatus: String, Codable, Equatable, Sendable {
    case ready
    case blocked
}

public struct NodeSyncOperationResult: Equatable, Sendable {
	public let state: NodeSyncOperationState
	public let backup: NodeSyncBackupState
	public let completedAt: String?
	public let upgradeStatus: NodeSyncUpgradeStatus

	public init(state: NodeSyncOperationState, backup: NodeSyncBackupState, completedAt: String?, upgradeStatus: NodeSyncUpgradeStatus) throws {
		guard completedAt.map(NodeSyncValidation.timestamp) ?? true else { throw NodeSyncError.invalidValue }
		self.state = state; self.backup = backup; self.completedAt = completedAt; self.upgradeStatus = upgradeStatus
	}

	public init(state: String, backup: String, completedAt: String?, upgradeStatus: String) throws {
		guard let state = NodeSyncOperationState(rawValue: state),
              let backup = NodeSyncBackupState(rawValue: backup),
              let upgradeStatus = NodeSyncUpgradeStatus(rawValue: upgradeStatus),
              completedAt.map(NodeSyncValidation.timestamp) ?? true else { throw NodeSyncError.invalidValue }
		try self.init(state: state, backup: backup, completedAt: completedAt, upgradeStatus: upgradeStatus)
	}

	public var isSuccessfulBackup: Bool {
		state == .verified && backup == .verified && upgradeStatus == .ready
	}

	public var isSuccessfulErase: Bool {
		state == .erased && backup == .unchanged && upgradeStatus == .blocked
	}

	public var requiresOperatorAction: Bool {
		switch state {
		case .recoveryRequired, .operatorActionRequired, .uncertain: return true
		case .verified, .erased: return false
		}
	}
}

public struct NodeSyncProblemResult: Equatable, Sendable {
    public let category: NodeSyncProblem
    public init(category: NodeSyncProblem) { self.category = category }
}

// NodeSyncUnsignedOperation is the signature preimage. It has no fake
// signature field, so a signer can construct and freeze its exact bytes first.
public struct NodeSyncUnsignedOperation: Equatable, Sendable {
    public let accountID, authorityEpoch, clientID, idempotencyKey, issuedAt, nodeID, trustEpoch: String
    public let logicalMailboxID: LogicalMailboxID
    public let operation: NodeSyncOperationVariant

    public init(accountID: String, authorityEpoch: String, clientID: String, idempotencyKey: String, issuedAt: String, logicalMailboxID: LogicalMailboxID, nodeID: String, operation: NodeSyncOperationVariant, trustEpoch: String) throws {
        guard NodeSyncValidation.canonicalUUID(accountID), NodeSyncValidation.decimal(authorityEpoch, allowZero: false), NodeSyncValidation.canonicalUUID(clientID), NodeSyncValidation.identifier(idempotencyKey), NodeSyncValidation.timestamp(issuedAt), NodeSyncValidation.logicalMailboxID(logicalMailboxID), NodeSyncValidation.canonicalUUID(nodeID), NodeSyncValidation.decimal(trustEpoch, allowZero: false), NodeSyncValidation.operationVariant(operation) else { throw NodeSyncError.invalidValue }
        self.accountID = accountID; self.authorityEpoch = authorityEpoch; self.clientID = clientID; self.idempotencyKey = idempotencyKey; self.issuedAt = issuedAt; self.logicalMailboxID = logicalMailboxID; self.nodeID = nodeID; self.operation = operation; self.trustEpoch = trustEpoch
    }
}

// NodeSyncOperation is the exact signed envelope passed through the mutation
// wrapper. It deliberately performs no key lookup or crypto verification.
public struct NodeSyncOperation: Equatable, Sendable {
    public let unsigned: NodeSyncUnsignedOperation
    public let signature: Data

    public init(unsigned: NodeSyncUnsignedOperation, signature: Data) throws {
        guard signature.count == 64 else { throw NodeSyncError.invalidValue }
        self.unsigned = unsigned; self.signature = signature
        guard (try? NodeSyncCodec.encodeOperation(self)) != nil else { throw NodeSyncError.invalidValue }
    }
}

public enum NodeSyncOperationVariant: Equatable, Sendable {
    case saveDraft(draftID: String, expectedRevision: String, rfc5322: Data, bcc: [String] = [])
    case deleteDraft(draftID: String, expectedRevision: String)
    case send(draftID: String, expectedRevision: String)
    case setLabels(messageIDs: [String], addLabelIDs: [String], removeLabelIDs: [String])
    case setRead(messageIDs: [String], read: Bool)
    case archive(messageIDs: [String])
    case delete(messageIDs: [String])
    case setFlagged(messageIDs: [String], flagged: Bool)
    /// `destinationMailboxPath` is a folder path the Node published in mirror coordinates.
    case move(messageIDs: [String], destinationMailboxPath: String)
}

public enum NodeSyncLimits {
    public static let maximumPageSize: UInt16 = 200
    public static let maximumRequestBodyBytes = 1_048_576
    public static let maximumCursorBytes = 4_096
    public static let maximumIdentifierBytes = 512
    public static let maximumSearchQueryBytes = 4_096
    public static let maximumMessageReferenceBytes = 998
    public static let maximumCanonicalFamilyBytes = 1_048_576
    public static let maximumCanonicalOperationBytes = 256 << 10
    public static let maximumRFC5322Bytes = 180 << 10
}

public enum NodeSyncCodec {
    public static func decodeSnapshotRequest(_ data: Data) throws -> NodeSyncSnapshotRequest {
        let wire: SnapshotRequestWire = try decodeCanonical(data)
        guard wire.kind == "node-sync.snapshot-request.v1" else { throw NodeSyncError.invalidValue }
        return try NodeSyncSnapshotRequest(after: wire.after, limit: wire.limit)
    }

    public static func encodeSnapshotRequest(_ value: NodeSyncSnapshotRequest) throws -> Data {
        try canonical(SnapshotRequestWire(after: value.after, kind: "node-sync.snapshot-request.v1", limit: value.limit))
    }

    public static func decodeSnapshotPage(_ data: Data) throws -> NodeSyncSnapshotPage {
        let wire: SnapshotPageWire = try decodeCanonical(data)
        guard wire.kind == "node-sync.snapshot-page.v1" else { throw NodeSyncError.invalidValue }
        return try NodeSyncSnapshotPage(messages: wire.messages, nextCursor: wire.nextCursor, revision: wire.revision)
    }

    public static func encodeSnapshotPage(_ value: NodeSyncSnapshotPage) throws -> Data {
        try canonical(SnapshotPageWire(kind: "node-sync.snapshot-page.v1", messages: value.messages, nextCursor: value.nextCursor, revision: value.revision))
    }

    public static func decodeMutationRequest(_ data: Data) throws -> NodeSyncMutationRequest {
        let wire: MutationRequestWire = try decodeCanonical(data)
        guard wire.kind == "node-sync.mutation-request.v1",
              let operation = decodeBase64URL(wire.canonicalOperation),
              operation.count == wire.canonicalOperationBytes else {
            throw NodeSyncError.invalidValue
        }
        return try NodeSyncMutationRequest(canonicalOperation: operation)
    }

    public static func encodeMutationRequest(_ value: NodeSyncMutationRequest) throws -> Data {
        try canonical(MutationRequestWire(canonicalOperation: encodeBase64URL(value.canonicalOperation), canonicalOperationBytes: value.canonicalOperation.count, kind: "node-sync.mutation-request.v1"))
    }

    public static func decodeOperation(_ data: Data) throws -> NodeSyncOperation {
        let wire: OperationWire = try decodeFamily(data, "node-sync.operation.v1")
        guard let signature = decodeBase64URL(wire.signature), signature.count == 64 else { throw NodeSyncError.invalidValue }
        let unsigned = try NodeSyncUnsignedOperation(accountID: wire.accountID, authorityEpoch: wire.authorityEpoch, clientID: wire.clientID, idempotencyKey: wire.idempotencyKey, issuedAt: wire.issuedAt, logicalMailboxID: decodeLogicalMailboxID(wire.logicalMailboxID), nodeID: wire.nodeID, operation: try operationVariant(wire.operation), trustEpoch: wire.trustEpoch)
        return try NodeSyncOperation(unsigned: unsigned, signature: signature)
    }

    public static func encodeOperation(_ value: NodeSyncOperation) throws -> Data {
        let result = try canonical(try operationWire(value))
        guard result.count <= NodeSyncLimits.maximumCanonicalOperationBytes else { throw NodeSyncError.invalidValue }
        return result
    }

    public static func canonicalUnsignedOperation(_ value: NodeSyncUnsignedOperation) throws -> Data {
        try canonical(try unsignedOperationWire(value))
    }

    // u32be length-prefixes domain, u16be version, and canonical unsigned
    // operation in that order. The signature field never enters this transcript.
    public static func operationTranscript(_ value: NodeSyncUnsignedOperation) throws -> Data {
        try lengthPrefixed([Data("Plainpost.NodeSyncOperation.v1".utf8), Data([0, 1]), canonicalUnsignedOperation(value)])
    }

    public static func decodeDeltaRequest(_ data: Data) throws -> NodeSyncDeltaRequest { let wire: DeltaRequestWire = try decodeFamily(data, "node-sync.delta-request.v1"); return try NodeSyncDeltaRequest(after: wire.after, limit: wire.limit) }
    public static func encodeDeltaRequest(_ value: NodeSyncDeltaRequest) throws -> Data { try canonical(DeltaRequestWire(after: value.after, kind: "node-sync.delta-request.v1", limit: value.limit)) }
    public static func decodeSearchRequest(_ data: Data) throws -> NodeSyncSearchRequest { let wire: SearchRequestWire = try decodeFamily(data, "node-sync.search-request.v1"); return try NodeSyncSearchRequest(after: wire.after, limit: wire.limit, logicalMailboxIDs: try wire.logicalMailboxIDs.map(decodeLogicalMailboxID), query: wire.query) }
    public static func encodeSearchRequest(_ value: NodeSyncSearchRequest) throws -> Data { try canonical(SearchRequestWire(after: value.after, kind: "node-sync.search-request.v1", limit: value.limit, logicalMailboxIDs: try value.logicalMailboxIDs.map(encodeLogicalMailboxID), query: value.query)) }
    public static func decodeMessageRequest(_ data: Data) throws -> NodeSyncMessageRequest { let wire: MessageRequestWire = try decodeFamily(data, "node-sync.message-request.v1"); return try NodeSyncMessageRequest(messageID: wire.messageID) }
    public static func encodeMessageRequest(_ value: NodeSyncMessageRequest) throws -> Data { try canonical(MessageRequestWire(kind: "node-sync.message-request.v1", messageID: value.messageID)) }
    public static func decodeAttachmentRequest(_ data: Data) throws -> NodeSyncAttachmentRequest { let wire: AttachmentRequestWire = try decodeFamily(data, "node-sync.attachment-request.v1"); return try NodeSyncAttachmentRequest(attachmentID: wire.attachmentID) }
    public static func encodeAttachmentRequest(_ value: NodeSyncAttachmentRequest) throws -> Data { try canonical(AttachmentRequestWire(attachmentID: value.attachmentID, kind: "node-sync.attachment-request.v1")) }
    public static func decodeGoogleProvisionRequest(_ data: Data) throws -> NodeSyncGoogleProvisionRequest { let wire: GoogleProvisionRequestWire = try decodeFamily(data, "node-sync.google-provision-request.v1"); return try NodeSyncGoogleProvisionRequest(authorizationCode: wire.authorizationCode, clientID: wire.clientID, codeVerifier: wire.codeVerifier, redirectURI: wire.redirectURI) }
    public static func encodeGoogleProvisionRequest(_ value: NodeSyncGoogleProvisionRequest) throws -> Data { try canonical(GoogleProvisionRequestWire(authorizationCode: value.authorizationCode, clientID: value.clientID, codeVerifier: value.codeVerifier, kind: "node-sync.google-provision-request.v1", redirectURI: value.redirectURI)) }
    public static func decodeMailboxAssignmentsRequest(_ data: Data) throws -> NodeSyncMailboxAssignmentsRequest { let wire: MailboxAssignmentsRequestWire = try decodeFamily(data, "node-sync.mailbox-assignments-request.v1"); return try NodeSyncMailboxAssignmentsRequest(assignments: try wire.assignments.map { try NodeSyncMailboxAssignment(logicalMailboxID: decodeLogicalMailboxID($0.logicalMailboxID), mailboxHandle: $0.mailboxHandle) }) }
    public static func encodeMailboxAssignmentsRequest(_ value: NodeSyncMailboxAssignmentsRequest) throws -> Data { try canonical(MailboxAssignmentsRequestWire(assignments: try value.assignments.map { MailboxAssignmentWire(logicalMailboxID: try encodeLogicalMailboxID($0.logicalMailboxID), mailboxHandle: $0.mailboxHandle) }, kind: "node-sync.mailbox-assignments-request.v1")) }
    public static func decodeStatusRequest(_ data: Data) throws -> NodeSyncStatusRequest { _ = try decodeFamily(data, "node-sync.status-request.v1") as StatusRequestWire; return NodeSyncStatusRequest() }
    public static func encodeStatusRequest(_ value: NodeSyncStatusRequest) throws -> Data { try canonical(StatusRequestWire(kind: "node-sync.status-request.v1")) }
    public static func decodeProviderSyncRequest(_ data: Data) throws -> NodeSyncProviderSyncRequest { _ = try decodeFamily(data, "node-sync.provider-sync-request.v1") as ProviderSyncRequestWire; return NodeSyncProviderSyncRequest() }
    public static func encodeProviderSyncRequest(_ value: NodeSyncProviderSyncRequest) throws -> Data { try canonical(ProviderSyncRequestWire(kind: "node-sync.provider-sync-request.v1")) }
    public static func decodeNotificationRecipientRequest(_ data: Data) throws -> NodeSyncNotificationRecipientRequest {
        let wire: NotificationRecipientRequestWire = try decodeFamily(data, "node-sync.notification-recipient-request.v1")
        guard let head = decodeBase64URL(wire.trustHead), let route = decodeBase64URL(wire.routingHandle), let agreement = decodeBase64URL(wire.agreementPublicKey), let signature = decodeBase64URL(wire.deviceSignature), let commit = decodeBase64URL(wire.trustCommit) else { throw NodeSyncError.invalidValue }
        return try NodeSyncNotificationRecipientRequest(accountID: wire.accountID, deviceID: wire.deviceID, trustEpoch: wire.trustEpoch, trustRevision: wire.revision, trustHead: head, routingHandle: route, agreementPublicKey: agreement, deviceSignature: signature, trustCommit: commit)
    }
    public static func encodeNotificationRecipientRequest(_ value: NodeSyncNotificationRecipientRequest) throws -> Data {
        try canonical(NotificationRecipientRequestWire(accountID: value.accountID, agreementPublicKey: encodeBase64URL(value.agreementPublicKey), deviceID: value.deviceID, deviceSignature: encodeBase64URL(value.deviceSignature), kind: "node-sync.notification-recipient-request.v1", revision: value.trustRevision, routingHandle: encodeBase64URL(value.routingHandle), trustCommit: encodeBase64URL(value.trustCommit), trustEpoch: value.trustEpoch, trustHead: encodeBase64URL(value.trustHead)))
    }
    public static func decodeNotificationRecipientResult(_ data: Data) throws -> NodeSyncNotificationRecipientResult {
        let wire: NotificationRecipientResultWire = try decodeFamily(data, "node-sync.notification-recipient-result.v1")
        return try NodeSyncNotificationRecipientResult(state: wire.state)
    }
    public static func encodeNotificationRecipientResult(_ value: NodeSyncNotificationRecipientResult) throws -> Data {
        try canonical(NotificationRecipientResultWire(kind: "node-sync.notification-recipient-result.v1", state: value.state))
    }
    public static func encodeNotificationRecipientRemovalRequest(_ value: NodeSyncNotificationRecipientRemovalRequest) throws -> Data {
        try canonical(NotificationRecipientRemovalRequestWire(kind: "node-sync.notification-recipient-remove.v1"))
    }
    public static func decodeNotificationRecipientRemovalRequest(_ data: Data) throws -> NodeSyncNotificationRecipientRemovalRequest {
        _ = try decodeFamily(data, "node-sync.notification-recipient-remove.v1") as NotificationRecipientRemovalRequestWire
        return NodeSyncNotificationRecipientRemovalRequest()
    }
    public static func decodeNotificationPolicyReadRequest(_ data: Data) throws -> NodeSyncNotificationPolicyReadRequest {
        let wire: NotificationPolicyReadRequestWire = try decodeFamily(data, "node-sync.notification-policy-read-request.v1")
        return try NodeSyncNotificationPolicyReadRequest(logicalMailboxID: try wire.logicalMailboxID.map(decodeLogicalMailboxID))
    }
    public static func encodeNotificationPolicyReadRequest(_ value: NodeSyncNotificationPolicyReadRequest) throws -> Data {
        try canonical(NotificationPolicyReadRequestWire(kind: "node-sync.notification-policy-read-request.v1", logicalMailboxID: try value.logicalMailboxID.map(encodeLogicalMailboxID)))
    }
    public static func decodeNotificationPolicyUpdateRequest(_ data: Data) throws -> NodeSyncNotificationPolicyUpdateRequest {
        let wire: NotificationPolicyUpdateRequestWire = try decodeFamily(data, "node-sync.notification-policy-update-request.v1")
        let mailbox = try wire.logicalMailboxID.map(decodeLogicalMailboxID)
        if wire.clear {
            guard wire.mode.isEmpty else { throw NodeSyncError.invalidValue }
            return try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, clear: true, expectedVersion: wire.expectedVersion, idempotencyKey: wire.idempotencyKey)
        }
        guard let mode = NodeSyncNotificationPolicyMode(rawValue: wire.mode) else { throw NodeSyncError.invalidValue }
        return try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: mailbox, mode: mode, expectedVersion: wire.expectedVersion, idempotencyKey: wire.idempotencyKey)
    }
    public static func encodeNotificationPolicyUpdateRequest(_ value: NodeSyncNotificationPolicyUpdateRequest) throws -> Data {
        // Central Direct's absent-default bootstrap must never cross the Node
        // wire, whose CAS predecessor is strictly positive.
        guard NodeSyncValidation.decimal(value.expectedVersion, allowZero: false),
              UInt64(value.expectedVersion).map({ (1...65_535).contains($0) }) ?? false else {
            throw NodeSyncError.invalidValue
        }
        return try canonical(NotificationPolicyUpdateRequestWire(clear: value.clear, expectedVersion: value.expectedVersion, idempotencyKey: value.idempotencyKey, kind: "node-sync.notification-policy-update-request.v1", logicalMailboxID: try value.logicalMailboxID.map(encodeLogicalMailboxID), mode: value.clear ? "" : value.mode.rawValue))
    }
    public static func decodeNotificationPolicy(_ data: Data) throws -> NodeSyncNotificationPolicy {
        let wire: NotificationPolicyResultWire = try decodeFamily(data, "node-sync.notification-policy-result.v1")
        guard let mode = NodeSyncNotificationPolicyMode(rawValue: wire.mode) else { throw NodeSyncError.invalidValue }
        return try NodeSyncNotificationPolicy(logicalMailboxID: try wire.logicalMailboxID.map(decodeLogicalMailboxID), mode: mode, version: wire.version, scopeVersion: wire.scopeVersion, override: wire.override)
    }
    public static func encodeNotificationPolicy(_ value: NodeSyncNotificationPolicy) throws -> Data {
        try canonical(NotificationPolicyResultWire(kind: "node-sync.notification-policy-result.v1", logicalMailboxID: try value.logicalMailboxID.map(encodeLogicalMailboxID), mode: value.mode.rawValue, override: value.override, scopeVersion: value.scopeVersion, version: value.version))
    }
    public static func decodeDeltaPage(_ data: Data) throws -> NodeSyncDeltaPage { let wire: DeltaPageWire = try decodeFamily(data, "node-sync.delta-page.v1"); return try NodeSyncDeltaPage(changes: try wire.changes.map { try NodeSyncChange(kind: $0.kind, logicalMailboxID: decodeLogicalMailboxID($0.logicalMailboxID), messageID: $0.messageID, threadID: $0.threadID) }, nextCursor: wire.nextCursor, revision: wire.revision) }
    public static func encodeDeltaPage(_ value: NodeSyncDeltaPage) throws -> Data { try canonical(DeltaPageWire(changes: try value.changes.map { ChangeWire(kind: $0.kind, logicalMailboxID: try encodeLogicalMailboxID($0.logicalMailboxID), messageID: $0.messageID, threadID: $0.threadID) }, kind: "node-sync.delta-page.v1", nextCursor: value.nextCursor, revision: value.revision)) }
    public static func decodeSearchPage(_ data: Data) throws -> NodeSyncSearchPage { let wire: SearchPageWire = try decodeFamily(data, "node-sync.search-page.v1"); return try NodeSyncSearchPage(messages: wire.messages, nextCursor: wire.nextCursor, revision: wire.revision) }
    public static func encodeSearchPage(_ value: NodeSyncSearchPage) throws -> Data { try canonical(SearchPageWire(kind: "node-sync.search-page.v1", messages: value.messages, nextCursor: value.nextCursor, revision: value.revision)) }
    public static func decodeMessageResult(_ data: Data) throws -> NodeSyncMessageResult { let wire: MessageResultWire = try decodeFamily(data, "node-sync.message-result.v1"); return try NodeSyncMessageResult(message: wire.message) }
    public static func encodeMessageResult(_ value: NodeSyncMessageResult) throws -> Data { try canonical(MessageResultWire(kind: "node-sync.message-result.v1", message: value.message)) }
    public static func decodeAttachmentResult(_ data: Data) throws -> NodeSyncAttachmentResult { let wire: AttachmentResultWire = try decodeFamily(data, "node-sync.attachment-result.v1"); return try NodeSyncAttachmentResult(attachment: wire.attachment) }
    public static func encodeAttachmentResult(_ value: NodeSyncAttachmentResult) throws -> Data { try canonical(AttachmentResultWire(attachment: value.attachment, kind: "node-sync.attachment-result.v1")) }
    public static func decodeMutationResult(_ data: Data) throws -> NodeSyncMutationResult { let wire: MutationResultWire = try decodeFamily(data, "node-sync.mutation-result.v1"); return try NodeSyncMutationResult(idempotencyKey: wire.idempotencyKey, state: wire.state) }
    public static func encodeMutationResult(_ value: NodeSyncMutationResult) throws -> Data { try canonical(MutationResultWire(idempotencyKey: value.idempotencyKey, kind: "node-sync.mutation-result.v1", state: value.state)) }
    public static func decodeDraftState(_ data: Data) throws -> NodeSyncDraftState { let wire: DraftStateWire = try decodeFamily(data, "node-sync.draft-state.v1"); return try NodeSyncDraftState(draftID: wire.draftID, revision: wire.revision, state: wire.state) }
    public static func encodeDraftState(_ value: NodeSyncDraftState) throws -> Data { try canonical(DraftStateWire(draftID: value.draftID, kind: "node-sync.draft-state.v1", revision: value.revision, state: value.state)) }
    public static func decodeGoogleProvisionResult(_ data: Data) throws -> NodeSyncGoogleProvisionResult { let wire: GoogleProvisionResultWire = try decodeFamily(data, "node-sync.google-provision-result.v1"); return try NodeSyncGoogleProvisionResult(discoveredMailboxes: try wire.discoveredMailboxes.map(discoveredMailbox), providerIdentity: wire.providerIdentity) }
    public static func encodeGoogleProvisionResult(_ value: NodeSyncGoogleProvisionResult) throws -> Data { try canonical(GoogleProvisionResultWire(discoveredMailboxes: try value.discoveredMailboxes.map(discoveredMailboxWire), kind: "node-sync.google-provision-result.v1", providerIdentity: value.providerIdentity)) }
    public static func decodeMailboxAssignmentsResult(_ data: Data) throws -> NodeSyncMailboxAssignmentsResult { let wire: MailboxAssignmentsResultWire = try decodeFamily(data, "node-sync.mailbox-assignments-result.v1"); return try NodeSyncMailboxAssignmentsResult(assignments: try wire.assignments.map(discoveredMailbox)) }
    public static func encodeMailboxAssignmentsResult(_ value: NodeSyncMailboxAssignmentsResult) throws -> Data { try canonical(MailboxAssignmentsResultWire(assignments: try value.assignments.map(discoveredMailboxWire), kind: "node-sync.mailbox-assignments-result.v1")) }
    public static func decodeStatusResult(_ data: Data) throws -> NodeSyncStatusResult {
        let wire: StatusResultWire = try decodeFamily(data, "node-sync.status-result.v1")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let richKeys = ["assignments", "backup", "endpoint", "reachability", "storage", "syncLag", "updateStatus", "version"]
        let hasRich = object?["assignments"] != nil || object?["version"] != nil || object?["reachability"] != nil || object?["syncLag"] != nil || object?["storage"] != nil || object?["backup"] != nil || object?["endpoint"] != nil || object?["updateStatus"] != nil
        if !hasRich && Set(object.map { Array($0.keys) } ?? []) != Set(["kind", "revision", "state"]) {
            throw NodeSyncError.invalidValue
        }
        if hasRich && richKeys.contains(where: { object?[$0] == nil }) {
            throw NodeSyncError.invalidValue
        }
        return try NodeSyncStatusResult(
            revision: wire.revision,
            state: wire.state,
            version: wire.version ?? "unknown",
            reachability: wire.reachability ?? "unknown",
            syncLag: wire.syncLag ?? "unknown",
            storage: wire.storage ?? "unknown",
            providerIdentity: wire.providerIdentity,
            assignments: try (wire.assignments ?? []).map(discoveredMailbox),
            backup: wire.backup ?? "unknown",
            endpoint: wire.endpoint ?? "unknown",
            updateStatus: wire.updateStatus ?? "unknown"
        )
    }

    public static func decodeOperationResult(_ data: Data) throws -> NodeSyncOperationResult {
        try decodeOperationResult(data, expectedKind: nil)
    }

    public static func decodeOperationResult(_ data: Data, expectedKind: String?) throws -> NodeSyncOperationResult {
        let wire: OperationResultWire = try decodeCanonical(data)
        guard wire.kind == "node-sync.backup-result.v1" || wire.kind == "node-sync.erase-result.v1" else { throw NodeSyncError.invalidValue }
        if let expectedKind, wire.kind != expectedKind { throw NodeSyncError.invalidValue }
		let result = try NodeSyncOperationResult(state: wire.state, backup: wire.backup, completedAt: wire.completedAt, upgradeStatus: wire.upgradeStatus)
		if wire.kind == "node-sync.backup-result.v1" {
			guard (result.state == .verified && result.backup == .verified && result.upgradeStatus == .ready) ||
				(result.state == .uncertain && result.backup == .uncertain && result.upgradeStatus == .blocked) else { throw NodeSyncError.invalidValue }
		} else {
			guard [.erased, .recoveryRequired, .operatorActionRequired].contains(result.state), result.backup == .unchanged, result.upgradeStatus == .blocked else { throw NodeSyncError.invalidValue }
		}
		return result
	}

    public static func encodeBackupRequest() throws -> Data {
        try canonical(BackupRequestWire(kind: "node-sync.backup-request.v1"))
    }

    public static func encodeEraseRequest(confirmation: String) throws -> Data {
        try canonical(EraseRequestWire(confirmation: confirmation, kind: "node-sync.erase-request.v1"))
    }
    public static func encodeStatusResult(_ value: NodeSyncStatusResult) throws -> Data { try canonical(StatusResultWire(kind: "node-sync.status-result.v1", revision: value.revision, state: value.state, version: value.version, reachability: value.reachability, syncLag: value.syncLag, storage: value.storage, providerIdentity: value.providerIdentity, assignments: try value.assignments.map(discoveredMailboxWire), backup: value.backup, endpoint: value.endpoint, updateStatus: value.updateStatus)) }
    public static func decodeProblem(_ data: Data) throws -> NodeSyncProblemResult { let wire: ProblemWire = try decodeFamily(data, "node-sync.problem.v1"); return NodeSyncProblemResult(category: wire.category) }
    public static func encodeProblem(_ value: NodeSyncProblemResult) throws -> Data { try canonical(ProblemWire(category: value.category, kind: "node-sync.problem.v1")) }

    private static func decodeCanonical<Value: Codable>(_ data: Data) throws -> Value {
        guard data.count <= NodeSyncLimits.maximumCanonicalFamilyBytes,
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              validJSON(object),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              try canonical(value) == data else {
            throw NodeSyncError.invalidValue
        }
        return value
    }

    private static func decodeFamily<Value: Codable & NodeSyncKindWire>(_ data: Data, _ kind: String) throws -> Value {
        let wire: Value = try decodeCanonical(data)
        guard wire.kind == kind else { throw NodeSyncError.invalidValue }
        return wire
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

    public static func decodeLogicalMailboxID(_ value: String) throws -> LogicalMailboxID {
        guard let raw = decodeBase64URL(value), raw.count == 32, !raw.allSatisfy({ $0 == 0 }), let logicalMailboxID = LogicalMailboxID(rawValue: raw) else { throw NodeSyncError.invalidValue }
        return logicalMailboxID
    }

    public static func encodeLogicalMailboxID(_ value: LogicalMailboxID) throws -> String {
        guard NodeSyncValidation.logicalMailboxID(value) else { throw NodeSyncError.invalidValue }
        return encodeBase64URL(value.rawValue)
    }

    private static func operationWire(_ value: NodeSyncOperation) throws -> OperationWire {
        try OperationWire(accountID: value.unsigned.accountID, authorityEpoch: value.unsigned.authorityEpoch, clientID: value.unsigned.clientID, idempotencyKey: value.unsigned.idempotencyKey, issuedAt: value.unsigned.issuedAt, kind: "node-sync.operation.v1", logicalMailboxID: encodeLogicalMailboxID(value.unsigned.logicalMailboxID), nodeID: value.unsigned.nodeID, operation: variantWire(value.unsigned.operation), signature: encodeBase64URL(value.signature), trustEpoch: value.unsigned.trustEpoch)
    }

    private static func unsignedOperationWire(_ value: NodeSyncUnsignedOperation) throws -> UnsignedOperationWire {
        try UnsignedOperationWire(accountID: value.accountID, authorityEpoch: value.authorityEpoch, clientID: value.clientID, idempotencyKey: value.idempotencyKey, issuedAt: value.issuedAt, kind: "node-sync.operation.v1", logicalMailboxID: encodeLogicalMailboxID(value.logicalMailboxID), nodeID: value.nodeID, operation: variantWire(value.operation), trustEpoch: value.trustEpoch)
    }

    private static func discoveredMailbox(_ value: DiscoveredMailboxWire) throws -> NodeSyncDiscoveredMailbox {
        try NodeSyncDiscoveredMailbox(displayName: value.displayName, logicalMailboxID: try value.logicalMailboxID.map(decodeLogicalMailboxID), mailboxHandle: value.mailboxHandle, role: value.role, authorityEpoch: value.authorityEpoch)
    }

    private static func discoveredMailboxWire(_ value: NodeSyncDiscoveredMailbox) throws -> DiscoveredMailboxWire {
        DiscoveredMailboxWire(displayName: value.displayName, logicalMailboxID: try value.logicalMailboxID.map(encodeLogicalMailboxID), mailboxHandle: value.mailboxHandle, role: value.role, authorityEpoch: value.authorityEpoch)
    }

    private static func operationVariant(_ value: OperationVariantWire) throws -> NodeSyncOperationVariant {
        switch value {
        case let .saveDraft(draftID, expectedRevision, rfc5322, bcc, bytes):
            guard let data = decodeBase64URL(rfc5322), data.count == bytes else { throw NodeSyncError.invalidValue }
            return .saveDraft(draftID: draftID, expectedRevision: expectedRevision, rfc5322: data, bcc: bcc)
        case let .deleteDraft(draftID, expectedRevision): return .deleteDraft(draftID: draftID, expectedRevision: expectedRevision)
        case let .send(draftID, expectedRevision): return .send(draftID: draftID, expectedRevision: expectedRevision)
        case let .setLabels(messageIDs, addLabelIDs, removeLabelIDs): return .setLabels(messageIDs: messageIDs, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
        case let .setRead(messageIDs, read): return .setRead(messageIDs: messageIDs, read: read)
        case let .archive(messageIDs): return .archive(messageIDs: messageIDs)
        case let .delete(messageIDs): return .delete(messageIDs: messageIDs)
        case let .setFlagged(messageIDs, flagged): return .setFlagged(messageIDs: messageIDs, flagged: flagged)
        case let .move(messageIDs, path): return .move(messageIDs: messageIDs, destinationMailboxPath: path)
        }
    }

    private static func variantWire(_ value: NodeSyncOperationVariant) -> OperationVariantWire {
        switch value {
        case let .saveDraft(draftID, expectedRevision, rfc5322, bcc): return .saveDraft(draftID: draftID, expectedRevision: expectedRevision, rfc5322: encodeBase64URL(rfc5322), bcc: bcc, bytes: rfc5322.count)
        case let .deleteDraft(draftID, expectedRevision): return .deleteDraft(draftID: draftID, expectedRevision: expectedRevision)
        case let .send(draftID, expectedRevision): return .send(draftID: draftID, expectedRevision: expectedRevision)
        case let .setLabels(messageIDs, addLabelIDs, removeLabelIDs): return .setLabels(messageIDs: messageIDs, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs)
        case let .setRead(messageIDs, read): return .setRead(messageIDs: messageIDs, read: read)
        case let .archive(messageIDs): return .archive(messageIDs: messageIDs)
        case let .delete(messageIDs): return .delete(messageIDs: messageIDs)
        case let .setFlagged(messageIDs, flagged): return .setFlagged(messageIDs: messageIDs, flagged: flagged)
        case let .move(messageIDs, path): return .move(messageIDs: messageIDs, destinationMailboxPath: path)
        }
    }

    private static func lengthPrefixed(_ parts: [Data]) -> Data {
        var result = Data()
        for part in parts {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(part)
        }
        return result
    }

    private static func validJSON(_ value: Any) -> Bool {
        if let text = value as? String {
            return NodeSyncValidation.text(text, maximum: NodeSyncLimits.maximumRequestBodyBytes)
        }
        if let values = value as? [Any] {
            return values.allSatisfy(validJSON)
        }
        if let values = value as? [String: Any] {
            return values.allSatisfy { NodeSyncValidation.text($0.key, maximum: NodeSyncLimits.maximumRequestBodyBytes) && validJSON($0.value) }
        }
        return value is NSNumber || value is NSNull
    }
}

private protocol NodeSyncKindWire { var kind: String { get } }

private struct SnapshotRequestWire: Codable, NodeSyncKindWire {
    let after: String
    let kind: String
    let limit: UInt16
}

private struct SnapshotPageWire: Codable, NodeSyncKindWire {
    let kind: String
    let messages: [NodeSyncMessage]
    let nextCursor: String
    let revision: String
}

private struct MutationRequestWire: Codable, NodeSyncKindWire {
    let canonicalOperation: String
    let canonicalOperationBytes: Int
    let kind: String
}

private struct DeltaRequestWire: Codable, NodeSyncKindWire { let after: String; let kind: String; let limit: UInt16 }
private struct SearchRequestWire: Codable, NodeSyncKindWire { let after: String; let kind: String; let limit: UInt16; let logicalMailboxIDs: [String]; let query: String }
private struct MessageRequestWire: Codable, NodeSyncKindWire { let kind: String; let messageID: String }
private struct AttachmentRequestWire: Codable, NodeSyncKindWire { let attachmentID: String; let kind: String }
private struct GoogleProvisionRequestWire: Codable, NodeSyncKindWire { let authorizationCode: String; let clientID: String; let codeVerifier: String; let kind: String; let redirectURI: String }
private struct MailboxAssignmentsRequestWire: Codable, NodeSyncKindWire { let assignments: [MailboxAssignmentWire]; let kind: String }
private struct StatusRequestWire: Codable, NodeSyncKindWire { let kind: String }
private struct ProviderSyncRequestWire: Codable, NodeSyncKindWire { let kind: String }
private struct NotificationRecipientRequestWire: Codable, NodeSyncKindWire { let accountID: String; let agreementPublicKey: String; let deviceID: String; let deviceSignature: String; let kind: String; let revision: String; let routingHandle: String; let trustCommit: String; let trustEpoch: String; let trustHead: String }
private struct NotificationRecipientResultWire: Codable, NodeSyncKindWire { let kind: String; let state: String }
private struct NotificationRecipientRemovalRequestWire: Codable, NodeSyncKindWire { let kind: String }
private struct NotificationPolicyReadRequestWire: Codable, NodeSyncKindWire { let kind: String; let logicalMailboxID: String? }
private struct NotificationPolicyUpdateRequestWire: Codable, NodeSyncKindWire { let clear: Bool; let expectedVersion: String; let idempotencyKey: String; let kind: String; let logicalMailboxID: String?; let mode: String }
private struct NotificationPolicyResultWire: Codable, NodeSyncKindWire { let kind: String; let logicalMailboxID: String?; let mode: String; let override: Bool; let scopeVersion: String; let version: String }
private struct DeltaPageWire: Codable, NodeSyncKindWire { let changes: [ChangeWire]; let kind: String; let nextCursor: String; let revision: String }
private struct SearchPageWire: Codable, NodeSyncKindWire { let kind: String; let messages: [NodeSyncMessage]; let nextCursor: String; let revision: String }
private struct MessageResultWire: Codable, NodeSyncKindWire { let kind: String; let message: NodeSyncMessage }
private struct AttachmentResultWire: Codable, NodeSyncKindWire { let attachment: NodeSyncAttachment; let kind: String }
private struct MutationResultWire: Codable, NodeSyncKindWire { let idempotencyKey: String; let kind: String; let state: String }
private struct GoogleProvisionResultWire: Codable, NodeSyncKindWire { let discoveredMailboxes: [DiscoveredMailboxWire]; let kind: String; let providerIdentity: String }
private struct MailboxAssignmentsResultWire: Codable, NodeSyncKindWire { let assignments: [DiscoveredMailboxWire]; let kind: String }
private struct StatusResultWire: Codable, NodeSyncKindWire { let kind: String; let revision: String; let state: String; let version: String?; let reachability: String?; let syncLag: String?; let storage: String?; let providerIdentity: String?; let assignments: [DiscoveredMailboxWire]?; let backup: String?; let endpoint: String?; let updateStatus: String? }
private struct BackupRequestWire: Codable, NodeSyncKindWire { let kind: String }
private struct EraseRequestWire: Codable, NodeSyncKindWire { let confirmation: String; let kind: String }
private struct OperationResultWire: Codable, NodeSyncKindWire { let backup: String; let completedAt: String?; let kind: String; let state: String; let upgradeStatus: String }
private struct DraftStateWire: Codable, NodeSyncKindWire { let draftID: String; let kind: String; let revision: String; let state: String }
private struct ProblemWire: Codable, NodeSyncKindWire { let category: NodeSyncProblem; let kind: String }
private struct ChangeWire: Codable {
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
private struct MailboxAssignmentWire: Codable { let logicalMailboxID: String; let mailboxHandle: String }
private struct DiscoveredMailboxWire: Codable {
    let displayName: String
    let logicalMailboxID: String?
    let mailboxHandle: String
    let role: String
    let authorityEpoch: String?

    private enum CodingKeys: String, CodingKey { case displayName, logicalMailboxID, mailboxHandle, role, authorityEpoch }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(logicalMailboxID, forKey: .logicalMailboxID)
        try container.encode(mailboxHandle, forKey: .mailboxHandle)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(authorityEpoch, forKey: .authorityEpoch)
    }
}
private struct OperationWire: Codable, NodeSyncKindWire { let accountID: String; let authorityEpoch: String; let clientID: String; let idempotencyKey: String; let issuedAt: String; let kind: String; let logicalMailboxID: String; let nodeID: String; let operation: OperationVariantWire; let signature: String; let trustEpoch: String }
private struct UnsignedOperationWire: Codable { let accountID: String; let authorityEpoch: String; let clientID: String; let idempotencyKey: String; let issuedAt: String; let kind: String; let logicalMailboxID: String; let nodeID: String; let operation: OperationVariantWire; let trustEpoch: String }

private enum OperationVariantWire: Codable {
    case saveDraft(draftID: String, expectedRevision: String, rfc5322: String, bcc: [String], bytes: Int)
    case deleteDraft(draftID: String, expectedRevision: String)
    case send(draftID: String, expectedRevision: String)
    case setLabels(messageIDs: [String], addLabelIDs: [String], removeLabelIDs: [String])
    case setRead(messageIDs: [String], read: Bool)
    case archive(messageIDs: [String])
    case delete(messageIDs: [String])
    case setFlagged(messageIDs: [String], flagged: Bool)
    case move(messageIDs: [String], destinationMailboxPath: String)

    private enum Key: String, CodingKey { case addLabelIDs, bcc, destinationMailboxPath, draftID, expectedRevision, flagged, kind, messageIDs, read, removeLabelIDs, rfc5322, rfc5322Bytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "save_draft":
            let explicitBcc = try c.decodeIfPresent([String].self, forKey: .bcc)
            guard explicitBcc?.isEmpty != true else { throw NodeSyncError.invalidValue }
            self = .saveDraft(draftID: try c.decode(String.self, forKey: .draftID), expectedRevision: try c.decode(String.self, forKey: .expectedRevision), rfc5322: try c.decode(String.self, forKey: .rfc5322), bcc: explicitBcc ?? [], bytes: try c.decode(Int.self, forKey: .rfc5322Bytes))
        case "delete_draft": self = .deleteDraft(draftID: try c.decode(String.self, forKey: .draftID), expectedRevision: try c.decode(String.self, forKey: .expectedRevision))
        case "send": self = .send(draftID: try c.decode(String.self, forKey: .draftID), expectedRevision: try c.decode(String.self, forKey: .expectedRevision))
        case "set_labels": self = .setLabels(messageIDs: try c.decode([String].self, forKey: .messageIDs), addLabelIDs: try c.decode([String].self, forKey: .addLabelIDs), removeLabelIDs: try c.decode([String].self, forKey: .removeLabelIDs))
        case "set_read": self = .setRead(messageIDs: try c.decode([String].self, forKey: .messageIDs), read: try c.decode(Bool.self, forKey: .read))
        case "archive": self = .archive(messageIDs: try c.decode([String].self, forKey: .messageIDs))
        case "delete": self = .delete(messageIDs: try c.decode([String].self, forKey: .messageIDs))
        case "set_flagged": self = .setFlagged(messageIDs: try c.decode([String].self, forKey: .messageIDs), flagged: try c.decode(Bool.self, forKey: .flagged))
        case "move": self = .move(messageIDs: try c.decode([String].self, forKey: .messageIDs), destinationMailboxPath: try c.decode(String.self, forKey: .destinationMailboxPath))
        default: throw NodeSyncError.invalidValue
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .saveDraft(draftID, expectedRevision, rfc5322, bcc, bytes): try c.encodeIfPresent(bcc.isEmpty ? nil : bcc, forKey: .bcc); try c.encode(draftID, forKey: .draftID); try c.encode(expectedRevision, forKey: .expectedRevision); try c.encode("save_draft", forKey: .kind); try c.encode(rfc5322, forKey: .rfc5322); try c.encode(bytes, forKey: .rfc5322Bytes)
        case let .deleteDraft(draftID, expectedRevision): try c.encode(draftID, forKey: .draftID); try c.encode(expectedRevision, forKey: .expectedRevision); try c.encode("delete_draft", forKey: .kind)
        case let .send(draftID, expectedRevision): try c.encode(draftID, forKey: .draftID); try c.encode(expectedRevision, forKey: .expectedRevision); try c.encode("send", forKey: .kind)
        case let .setLabels(messageIDs, addLabelIDs, removeLabelIDs): try c.encode(addLabelIDs, forKey: .addLabelIDs); try c.encode("set_labels", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs); try c.encode(removeLabelIDs, forKey: .removeLabelIDs)
        case let .setRead(messageIDs, read): try c.encode("set_read", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs); try c.encode(read, forKey: .read)
        case let .archive(messageIDs): try c.encode("archive", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs)
        case let .delete(messageIDs): try c.encode("delete", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs)
        case let .setFlagged(messageIDs, flagged): try c.encode(flagged, forKey: .flagged); try c.encode("set_flagged", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs)
        case let .move(messageIDs, path): try c.encode(path, forKey: .destinationMailboxPath); try c.encode("move", forKey: .kind); try c.encode(messageIDs, forKey: .messageIDs)
        }
    }
}

private enum NodeSyncValidation {
    static func message(_ value: NodeSyncMessage) -> Bool {
        guard value.attachments.count <= Int(NodeSyncLimits.maximumPageSize),
              value.bcc.count <= Int(NodeSyncLimits.maximumPageSize),
              value.cc.count <= Int(NodeSyncLimits.maximumPageSize),
              value.flags.count <= Int(NodeSyncLimits.maximumPageSize),
              value.from.count <= Int(NodeSyncLimits.maximumPageSize),
              value.inReplyTo.count <= Int(NodeSyncLimits.maximumPageSize),
              value.labels.count <= Int(NodeSyncLimits.maximumPageSize),
              value.references.count <= Int(NodeSyncLimits.maximumPageSize),
              value.replyTo.count <= Int(NodeSyncLimits.maximumPageSize),
              value.to.count <= Int(NodeSyncLimits.maximumPageSize),
              identifier(value.id),
              identifier(value.threadID),
              text(value.subject, maximum: NodeSyncLimits.maximumRequestBodyBytes),
              timestamp(value.receivedAt),
              value.sentAt.map(timestamp) ?? true,
              body(value.textBody),
              body(value.htmlBody),
              value.attachments.allSatisfy(attachment),
              value.bcc.allSatisfy(address),
              value.cc.allSatisfy(address),
              value.from.allSatisfy(address),
              value.replyTo.allSatisfy(address),
              value.to.allSatisfy(address),
              value.inReplyTo.allSatisfy(messageReference),
              value.references.allSatisfy(messageReference),
              sortedFlags(value.flags),
              sortedIdentifiers(value.labels) else {
            return false
        }
        return true
    }

    static func address(_ value: NodeSyncAddress) -> Bool {
        text(value.displayName, maximum: 4_096) && identifier(value.mailbox, maximum: 4_096)
    }

    static func body(_ value: NodeSyncBody) -> Bool {
        switch value.state {
        case .complete:
            return value.value.map { text($0, maximum: NodeSyncLimits.maximumRequestBodyBytes) } ?? false
        case .absent, .malformed, .omittedOversized:
            return value.value == nil
        }
    }

    static func attachment(_ value: NodeSyncAttachment) -> Bool {
        guard identifier(value.id),
              identifier(value.filename),
              identifier(value.mime, maximum: 255),
              decimal(value.size, allowZero: true),
              value.contentID.map({ text($0, maximum: 998) }) ?? true,
              value.contentDigest.map(validDigest) ?? true,
              ["none", "inline", "attachment"].contains(value.disposition) else {
            return false
        }
        return true
    }

    static func sortedFlags(_ values: [String]) -> Bool {
        let allowed = Set(["answered", "deleted", "draft", "flagged", "seen"])
        return values.allSatisfy(allowed.contains) && sortedUniqueUTF8(values)
    }

    static func sortedIdentifiers(_ values: [String]) -> Bool {
        values.count <= Int(NodeSyncLimits.maximumPageSize) && values.allSatisfy({ identifier($0) }) && sortedUniqueUTF8(values)
    }

    static func logicalMailboxID(_ value: LogicalMailboxID) -> Bool {
        value.rawValue.count == 32 && !value.rawValue.allSatisfy({ $0 == 0 })
    }

    static func sortedLogicalMailboxIDs(_ values: [LogicalMailboxID]) -> Bool {
        guard values.count <= Int(NodeSyncLimits.maximumPageSize), values.allSatisfy(logicalMailboxID) else { return false }
        for index in values.indices.dropFirst() {
            let previous = values[values.index(before: index)].rawValue
            let current = values[index].rawValue
            guard previous.lexicographicallyPrecedes(current), previous != current else { return false }
        }
        return true
    }

    static func cursor(_ value: String) -> Bool {
        text(value, maximum: NodeSyncLimits.maximumCursorBytes)
    }

    static func identifier(_ value: String, maximum: Int = NodeSyncLimits.maximumIdentifierBytes) -> Bool {
        !value.isEmpty && text(value, maximum: maximum)
    }

    static func text(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func searchQuery(_ value: String) -> Bool {
        !value.isEmpty && text(value, maximum: NodeSyncLimits.maximumSearchQueryBytes) && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    static func messageReference(_ value: String) -> Bool {
        identifier(value, maximum: NodeSyncLimits.maximumMessageReferenceBytes)
    }

    static func pkceCodeVerifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (43...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 126 }
    }

    static func httpsRedirectURI(_ value: String) -> Bool {
        guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.queryItems?.isEmpty != false,
              components.fragment == nil, url.absoluteString == value else { return false }
        return true
    }

    static func decimal(_ value: String, allowZero: Bool) -> Bool {
        guard let number = UInt64(value), (allowZero || number > 0) else { return false }
        return String(number) == value
    }

    static func timestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58, bytes[19] == 90 else { return false }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var result = 0
            for index in start..<(start + count) { guard bytes[index] >= 48 && bytes[index] <= 57 else { return nil }; result = result * 10 + Int(bytes[index] - 48) }
            return result
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2), let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2), (1...9_999).contains(year), (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return false }
        let monthLengths = [31, (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day >= 1 && day <= monthLengths[month - 1]
    }

    static func validDigest(_ value: String) -> Bool {
        decodeBase64URL(value)?.count == 32
    }

    static func change(_ value: NodeSyncChange) -> Bool { change(kind: value.kind, logicalMailboxID: value.logicalMailboxID, messageID: value.messageID, threadID: value.threadID) }

    static func change(kind: String, logicalMailboxID: LogicalMailboxID, messageID: String?, threadID: String?) -> Bool {
        guard NodeSyncValidation.logicalMailboxID(logicalMailboxID) else { return false }
        switch kind {
        case "upsert":
            return messageID.map({ identifier($0) }) ?? false && threadID.map({ identifier($0) }) ?? false
        case "membership_removed":
            return messageID == nil && threadID == nil
        case "tombstoned":
            return (messageID.map { identifier($0) } ?? false) && threadID == nil
        case "epoch_reset", "baseline_complete":
            return messageID == nil && threadID == nil
        default: return false
        }
    }

    static func sortedUniqueUTF8(_ values: [String]) -> Bool {
        for index in values.indices.dropFirst() {
            let previous = Array(values[values.index(before: index)].utf8)
            let current = Array(values[index].utf8)
            guard previous.lexicographicallyPrecedes(current) else { return false }
        }
        return true
    }

    static func canonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36, [56, 57, 97, 98].contains(bytes[19]) else { return false }
        var nonzero = false
        for index in bytes.indices {
            if [8, 13, 18, 23].contains(index) { guard bytes[index] == 45 else { return false }; continue }
            guard (48...57).contains(bytes[index]) || (97...102).contains(bytes[index]) else { return false }
            nonzero = nonzero || bytes[index] != 48
        }
        return nonzero
    }

    static func operationVariant(_ value: NodeSyncOperationVariant) -> Bool {
        switch value {
        case let .saveDraft(draftID, expectedRevision, rfc5322, bcc):
            guard identifier(draftID), decimal(expectedRevision, allowZero: true), !rfc5322.isEmpty,
                  rfc5322.count <= NodeSyncLimits.maximumRFC5322Bytes,
                  bcc.count <= 256, bcc.allSatisfy(envelopeAddress), uniqueEnvelopeAddresses(bcc) else { return false }
            // The visible To/Cc envelope is part of the signed source. Reject
            // malformed or opaque headers here so Swift cannot sign a draft
            // that the Go verifier would later reject.
            guard let visible = draftHeaderRecipients(rfc5322) else { return false }
            let recipients = visible + bcc
            return !recipients.isEmpty && recipients.count <= 256 && uniqueEnvelopeAddresses(recipients)
        case let .deleteDraft(draftID, expectedRevision), let .send(draftID, expectedRevision): return identifier(draftID) && decimal(expectedRevision, allowZero: false)
        case let .setLabels(messageIDs, addLabelIDs, removeLabelIDs):
            return !messageIDs.isEmpty && sortedIdentifiers(messageIDs) && sortedIdentifiers(addLabelIDs) && sortedIdentifiers(removeLabelIDs) && (!addLabelIDs.isEmpty || !removeLabelIDs.isEmpty) && utf8Disjoint(addLabelIDs, removeLabelIDs)
        case let .setRead(messageIDs, _), let .archive(messageIDs), let .delete(messageIDs), let .setFlagged(messageIDs, _):
            return !messageIDs.isEmpty && sortedIdentifiers(messageIDs)
        case let .move(messageIDs, path):
            return !messageIDs.isEmpty && sortedIdentifiers(messageIDs) && identifier(path)
        }
    }

    static func utf8Disjoint(_ first: [String], _ second: [String]) -> Bool {
        !first.contains { left in second.contains { Data(left.utf8) == Data($0.utf8) } }
    }

    static func envelopeAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && value.utf8.count <= 320 && !value.contains(where: { $0 == "\0" || $0 == " " || $0 == "\r" || $0 == "\n" })
    }

    private static func uniqueEnvelopeAddresses(_ values: [String]) -> Bool {
        var seen = Set<String>()
        for value in values {
            let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let canonical = "\(parts[0])@\(parts[1].lowercased())"
            guard seen.insert(canonical).inserted else { return false }
        }
        return true
    }

    private static func draftHeaderRecipients(_ source: Data) -> [String]? {
        guard let text = String(data: source, encoding: .utf8), let end = text.range(of: "\r\n\r\n") else { return nil }
        var fields: [String: String] = [:]
        var current: String?
        for normalized in String(text[..<end.lowerBound]).components(separatedBy: "\r\n") where !normalized.isEmpty {
            if normalized.first == " " || normalized.first == "\t" {
                guard let key = current else { return nil }
                fields[key, default: ""] += " " + normalized.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = normalized.firstIndex(of: ":") else { return nil }
            let key = normalized[..<colon].lowercased()
            guard !key.isEmpty, fields[key] == nil else { return nil }
            fields[key] = String(normalized[normalized.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            current = key
        }
        // Blind recipients are envelope-only and must never be carried in
        // the signed RFC5322 source. Keep this rule aligned with Go's
        // parseVerifiedDraftV1 headerCount check.
        guard fields["bcc"] == nil else { return nil }
        var recipients: [String] = []
        for key in ["to", "cc"] {
            guard let raw = fields[key], !raw.isEmpty else { continue }
            let values = raw.split(separator: ",", omittingEmptySubsequences: false).map { part in
                let value = part.trimmingCharacters(in: .whitespaces)
                if let start = value.firstIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end {
                    return String(value[value.index(after: start)..<end])
                }
                return value
            }
            guard values.allSatisfy(envelopeAddress) else { return nil }
            recipients.append(contentsOf: values)
        }
        return recipients
    }
}

private func encodeBase64URL(_ value: Data) -> String {
    value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func decodeBase64URL(_ value: String) -> Data? {
    guard !value.isEmpty, !value.contains("="),
          value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else {
        return nil
    }
    let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let decoded = Data(base64Encoded: padded), encodeBase64URL(decoded) == value else { return nil }
    return decoded
}
