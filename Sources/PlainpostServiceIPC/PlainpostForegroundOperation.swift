import Foundation
import PlainpostCore
import PlainpostOperations

public enum PlainpostForegroundOperationError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unexpectedResult
}

public struct PlainpostEmptySemanticPayload: Codable, Equatable, Sendable { public init() {} }

public struct PlainpostAccountSetupPayload: Codable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let displayName: String
    public let email: String
    public let imapHost: String
    public let imapPort: UInt16
    public let smtpHost: String
    public let smtpPort: Int
    public let username: String
    public let sentMailbox: String
    public let imapPassword: String
    public let smtpPassword: String

    public init(
        displayName: String, email: String, imapHost: String, imapPort: UInt16, smtpHost: String,
        smtpPort: Int, username: String, sentMailbox: String, imapPassword: String,
        smtpPassword: String
    ) {
        self.displayName = displayName
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = username
        self.sentMailbox = sentMailbox
        self.imapPassword = imapPassword
        self.smtpPassword = smtpPassword
    }

    public var description: String { "PlainpostAccountSetupPayload(<redacted credentials>)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "displayName": displayName,
                "email": email,
                "imapHost": imapHost,
                "imapPort": imapPort,
                "smtpHost": smtpHost,
                "smtpPort": smtpPort,
                "username": username,
                "sentMailbox": sentMailbox,
                "credentials": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

public struct PlainpostAccountCredentialReplacementPayload: Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let accountID: String
    public let imapPassword: String
    public let smtpPassword: String

    public init(accountID: String, imapPassword: String, smtpPassword: String) {
        self.accountID = accountID
        self.imapPassword = imapPassword
        self.smtpPassword = smtpPassword
    }

    public var description: String {
        "PlainpostAccountCredentialReplacementPayload(accountID: \(accountID), credentials: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "accountID": accountID,
                "credentials": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

/// Gmail setup after Google sign-in. The app exchanged the authorization code
/// and checked the identity; only the resulting grant crosses XPC, and the
/// service verifies the identity again with the access token.
public struct PlainpostGoogleAccountSetupPayload: Codable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let displayName: String
    public let email: String
    /// The Google identity the app verified after the exchange.
    public let identity: String
    public let accessToken: String
    public let refreshToken: String
    /// Seconds since 1970.
    public let accessTokenExpiresAt: Double

    public init(
        displayName: String, email: String, identity: String, accessToken: String,
        refreshToken: String, accessTokenExpiresAt: Double
    ) {
        self.displayName = displayName
        self.email = email
        self.identity = identity
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    public var description: String {
        "PlainpostGoogleAccountSetupPayload(email: \(email), tokens: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "displayName": displayName,
                "email": email,
                "identity": identity,
                "tokens": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

/// "Reauthorize Gmail": a new Google grant for an existing Gmail account,
/// including conversion of an App Password account to Google sign-in.
public struct PlainpostGoogleCredentialReplacementPayload: Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let accountID: String
    public let identity: String
    public let accessToken: String
    public let refreshToken: String
    /// Seconds since 1970.
    public let accessTokenExpiresAt: Double

    public init(
        accountID: String, identity: String, accessToken: String, refreshToken: String,
        accessTokenExpiresAt: Double
    ) {
        self.accountID = accountID
        self.identity = identity
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    public var description: String {
        "PlainpostGoogleCredentialReplacementPayload(accountID: \(accountID), tokens: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "accountID": accountID,
                "identity": identity,
                "tokens": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

public struct PlainpostAccountDeletionPayload: Codable, Equatable, Sendable,
    CustomStringConvertible
{
    public let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }

    public var description: String {
        "PlainpostAccountDeletionPayload(accountID: \(accountID))"
    }
}

public struct PlainpostAccountSetupSemanticResult: Codable, Equatable, Sendable {
    public let accountID: String
    public let email: String
    public let isIMAPVerified: Bool
    public let isSMTPVerified: Bool
    public let syncedMessageCount: Int

    public init(
        accountID: String, email: String, isIMAPVerified: Bool, isSMTPVerified: Bool,
        syncedMessageCount: Int
    ) {
        self.accountID = accountID
        self.email = email
        self.isIMAPVerified = isIMAPVerified
        self.isSMTPVerified = isSMTPVerified
        self.syncedMessageCount = syncedMessageCount
    }
}

public struct PlainpostAccountTestSemanticResult: Codable, Equatable, Sendable {
    public let isIMAPVerified: Bool
    public let isSMTPVerified: Bool

    public init(isIMAPVerified: Bool, isSMTPVerified: Bool) {
        self.isIMAPVerified = isIMAPVerified
        self.isSMTPVerified = isSMTPVerified
    }
}

public struct PlainpostDirectDraftDeliveryPayload: Codable, Equatable, Sendable {
    public let draftID: String
    public let expectedHash: String
    public let actorID: String
    public init(draftID: String, expectedHash: String, actorID: String) {
        self.draftID = draftID
        self.expectedHash = expectedHash
        self.actorID = actorID
    }
}

public struct PlainpostDirectDraftDeliverySemanticResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case messageID, remoteSentCopyAppended, waitingForNode
    }

    public let messageID: String
    public let remoteSentCopyAppended: Bool
    /// True when a Node-backed account's send is queued for, or admitted by,
    /// the Sync Node and not sent yet. Additive; older payloads decode false.
    public let waitingForNode: Bool

    public init(messageID: String, remoteSentCopyAppended: Bool, waitingForNode: Bool = false) {
        self.messageID = messageID
        self.remoteSentCopyAppended = remoteSentCopyAppended
        self.waitingForNode = waitingForNode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(String.self, forKey: .messageID)
        remoteSentCopyAppended = try container.decode(Bool.self, forKey: .remoteSentCopyAppended)
        waitingForNode = try container.decodeIfPresent(Bool.self, forKey: .waitingForNode) ?? false
    }
}

public struct PlainpostBrowserReplyDeliveryPayload: Codable, Equatable, Sendable {
    public let draftID: String
    public let expectedHash: String
    public let idempotencyKey: String

    public init(draftID: String, expectedHash: String, idempotencyKey: String) {
        self.draftID = draftID
        self.expectedHash = expectedHash
        self.idempotencyKey = idempotencyKey
    }
}

public struct PlainpostBrowserReplyDeliverySemanticResult: Codable, Equatable, Sendable {
    public let requestID: String
    public let jobID: String
    public let state: String

    public init(requestID: String, jobID: String, state: String) {
        self.requestID = requestID
        self.jobID = jobID
        self.state = state
    }
}

public struct PlainpostMailActionPayload: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case messageID, archiveMailbox, permanent, sourceMailbox, sourceUID
    }

    public let messageID: String
    public let archiveMailbox: String?
    /// For a delete: erase a message that is in Trash ("Delete Permanently").
    /// Without it a delete only moves to Trash and never erases. Additive; an
    /// older peer's payload decodes as false, and false is not encoded.
    public let permanent: Bool
    /// For an archive or delete: the mailbox (and UID, when known) of the copy
    /// the user acted on. A message can have a copy in several mailboxes; only
    /// that one is touched, and the action refuses if it isn't there. Nil
    /// means the INBOX copy, else the last-synced one. Additive.
    public let sourceMailbox: String?
    public let sourceUID: Int?

    public init(
        messageID: String,
        archiveMailbox: String? = nil,
        permanent: Bool = false,
        sourceMailbox: String? = nil,
        sourceUID: Int? = nil
    ) {
        self.messageID = messageID
        self.archiveMailbox = archiveMailbox
        self.permanent = permanent
        self.sourceMailbox = sourceMailbox
        self.sourceUID = sourceUID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(String.self, forKey: .messageID)
        archiveMailbox = try container.decodeIfPresent(String.self, forKey: .archiveMailbox)
        permanent = try container.decodeIfPresent(Bool.self, forKey: .permanent) ?? false
        sourceMailbox = try container.decodeIfPresent(String.self, forKey: .sourceMailbox)
        sourceUID = try container.decodeIfPresent(Int.self, forKey: .sourceUID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID, forKey: .messageID)
        try container.encodeIfPresent(archiveMailbox, forKey: .archiveMailbox)
        if permanent { try container.encode(true, forKey: .permanent) }
        try container.encodeIfPresent(sourceMailbox, forKey: .sourceMailbox)
        try container.encodeIfPresent(sourceUID, forKey: .sourceUID)
    }
}

public struct PlainpostMailActionSemanticResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case messageID, seen, mailboxPath, isDeleted, waitingForNode, deleteOutcome
    }

    public let messageID: String
    public let seen: Bool?
    public let mailboxPath: String?
    public let isDeleted: Bool
    /// True while a Node-backed account's change waits for the Sync Node:
    /// not yet dispatched, admitted but unfinished, or unconfirmed. Additive;
    /// an older peer's payload decodes as false.
    public let waitingForNode: Bool
    /// For a Direct delete: moved to Trash, already in Trash, or erased.
    /// Additive; nil from an older peer or for other actions.
    public let deleteOutcome: DeleteOutcome?

    public init(
        messageID: String, seen: Bool? = nil, mailboxPath: String? = nil, isDeleted: Bool,
        waitingForNode: Bool = false, deleteOutcome: DeleteOutcome? = nil
    ) {
        self.messageID = messageID
        self.seen = seen
        self.mailboxPath = mailboxPath
        self.isDeleted = isDeleted
        self.waitingForNode = waitingForNode
        self.deleteOutcome = deleteOutcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(String.self, forKey: .messageID)
        seen = try container.decodeIfPresent(Bool.self, forKey: .seen)
        mailboxPath = try container.decodeIfPresent(String.self, forKey: .mailboxPath)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        waitingForNode = try container.decodeIfPresent(Bool.self, forKey: .waitingForNode) ?? false
        deleteOutcome = try container.decodeIfPresent(DeleteOutcome.self, forKey: .deleteOutcome)
    }
}

public struct PlainpostLabelMutationPayload: Codable, Equatable, Sendable {
    public let labelID: String
    public let messageID: String
    public let selected: Bool

    public init(labelID: String, messageID: String, selected: Bool) {
        self.labelID = labelID
        self.messageID = messageID
        self.selected = selected
    }
}

public enum PlainpostForegroundOperation: Sendable {
    public static let schemaVersion = 1
    public static let maximumPayloadBytes = 262_144

    case inboxSync(PlainpostInboxSyncInput)
    case historicalSync(PlainpostInboxSyncInput)
    case ai(PlainpostAIOperationInput)
    case translateMessage(PlainpostAIOperationInput)
    case approveSend(PlainpostApprovalDecisionInput)
    case denySend(PlainpostApprovalDecisionInput)
    case accountAdd(PlainpostAccountSetupPayload)
    case accountTest(PlainpostAccountSetupPayload)
    case replaceAccountCredentials(PlainpostAccountCredentialReplacementPayload)
    case googleAccountAdd(PlainpostGoogleAccountSetupPayload)
    case replaceGoogleAccountCredential(PlainpostGoogleCredentialReplacementPayload)
    case deleteAccount(PlainpostAccountDeletionPayload)
    case deliverDirectDraft(PlainpostDirectDraftDeliveryPayload)
    case deliverBrowserReply(PlainpostBrowserReplyDeliveryPayload)
    case archive(PlainpostMailActionPayload)
    case delete(PlainpostMailActionPayload)
    case markRead(PlainpostMailActionPayload)
    case markUnread(PlainpostMailActionPayload)
    case flag(PlainpostMailActionPayload)
    case unflag(PlainpostMailActionPayload)
    /// `archiveMailbox` names the destination folder (its path).
    case move(PlainpostMailActionPayload)
    case addLabel(PlainpostLabelMutationPayload)
    case removeLabel(PlainpostLabelMutationPayload)
    case labelCommand(PlainpostLabelMutationPayload)

    public var kind: PlainpostForegroundOperationKind {
        switch self {
        case .inboxSync: .inboxSync
        case .historicalSync: .historicalSync
        case .ai: .AI
        case .translateMessage: .translateMessage
        case .approveSend: .approveSend
        case .denySend: .denySend
        case .accountAdd: .accountAdd
        case .accountTest: .accountTest
        case .replaceAccountCredentials: .replaceAccountCredentials
        case .googleAccountAdd: .googleAccountAdd
        case .replaceGoogleAccountCredential: .replaceGoogleAccountCredential
        case .deleteAccount: .deleteAccount
        case .deliverDirectDraft: .deliverDirectDraft
        case .deliverBrowserReply: .deliverBrowserReply
        case .archive: .archive
        case .delete: .delete
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .flag: .flag
        case .unflag: .unflag
        case .move: .move
        case .addLabel: .addLabel
        case .removeLabel: .removeLabel
        case .labelCommand: .labelCommand
        }
    }

    public func requestDTO() throws -> PlainpostForegroundOperationRequestDTO {
        let payload: Data
        switch self {
        case .inboxSync(let value), .historicalSync(let value): payload = try Self.encode(value)
        case .ai(let value), .translateMessage(let value): payload = try Self.encode(value)
        case .approveSend(let value), .denySend(let value): payload = try Self.encode(value)
        case .accountAdd(let value), .accountTest(let value): payload = try Self.encode(value)
        case .replaceAccountCredentials(let value): payload = try Self.encode(value)
        case .googleAccountAdd(let value): payload = try Self.encode(value)
        case .replaceGoogleAccountCredential(let value): payload = try Self.encode(value)
        case .deleteAccount(let value): payload = try Self.encode(value)
        case .deliverDirectDraft(let value): payload = try Self.encode(value)
        case .deliverBrowserReply(let value): payload = try Self.encode(value)
        case .archive(let value), .delete(let value), .markRead(let value), .markUnread(let value),
            .flag(let value), .unflag(let value), .move(let value):
            payload = try Self.encode(value)
        case .addLabel(let value), .removeLabel(let value), .labelCommand(let value):
            payload = try Self.encode(value)
        }
        guard
            let request = PlainpostForegroundOperationRequestDTO(
                schemaVersion: Self.schemaVersion, kind: kind, archivedPayload: payload)
        else { throw PlainpostForegroundOperationError.invalidEnvelope }
        return request
    }

    public init(requestDTO: PlainpostForegroundOperationRequestDTO) throws {
        guard requestDTO.schemaVersion == Self.schemaVersion, !requestDTO.archivedPayload.isEmpty,
            requestDTO.archivedPayload.count <= Self.maximumPayloadBytes
        else { throw PlainpostForegroundOperationError.invalidEnvelope }
        let payload = requestDTO.archivedPayload
        switch requestDTO.kind {
        case .inboxSync: self = .inboxSync(try Self.decode(payload))
        case .historicalSync: self = .historicalSync(try Self.decode(payload))
        case .AI: self = .ai(try Self.decode(payload))
        case .translateMessage: self = .translateMessage(try Self.decode(payload))
        case .approveSend: self = .approveSend(try Self.decode(payload))
        case .denySend: self = .denySend(try Self.decode(payload))
        case .accountAdd: self = .accountAdd(try Self.decode(payload))
        case .accountTest: self = .accountTest(try Self.decode(payload))
        case .replaceAccountCredentials: self = .replaceAccountCredentials(try Self.decode(payload))
        case .googleAccountAdd: self = .googleAccountAdd(try Self.decode(payload))
        case .replaceGoogleAccountCredential:
            self = .replaceGoogleAccountCredential(try Self.decode(payload))
        case .deleteAccount: self = .deleteAccount(try Self.decode(payload))
        case .deliverDirectDraft: self = .deliverDirectDraft(try Self.decode(payload))
        case .deliverBrowserReply: self = .deliverBrowserReply(try Self.decode(payload))
        case .archive: self = .archive(try Self.decode(payload))
        case .delete: self = .delete(try Self.decode(payload))
        case .markRead: self = .markRead(try Self.decode(payload))
        case .markUnread: self = .markUnread(try Self.decode(payload))
        case .flag: self = .flag(try Self.decode(payload))
        case .unflag: self = .unflag(try Self.decode(payload))
        case .move: self = .move(try Self.decode(payload))
        case .addLabel: self = .addLabel(try Self.decode(payload))
        case .removeLabel: self = .removeLabel(try Self.decode(payload))
        case .labelCommand: self = .labelCommand(try Self.decode(payload))
        @unknown default: throw PlainpostForegroundOperationError.invalidEnvelope
        }
        try validate()
    }

    /// The shown copy: a stable mailbox path, and a UID only with a mailbox.
    private static func requireSourceCopy(_ input: PlainpostMailActionPayload) throws {
        if let sourceMailbox = input.sourceMailbox { try requireStableMailbox(sourceMailbox) }
        if let sourceUID = input.sourceUID { try require(input.sourceMailbox != nil && sourceUID > 0) }
    }

    public func validate() throws {
        switch self {
        case .inboxSync(let input):
            try Self.require(input.scope != .completeHistory)
            try Self.requireStableID(input.accountID.rawValue)
        case .historicalSync(let input):
            try Self.require(input.scope == .completeHistory)
            try Self.requireStableID(input.accountID.rawValue)
        case .ai(let input):
            try Self.require(input.operation != .translateMessage)
            try Self.validate(input)
        case .translateMessage(let input):
            try Self.require(input.operation == .translateMessage)
            try Self.validate(input)
        case .approveSend(let input), .denySend(let input):
            try Self.requireStableID(input.requestID.rawValue)
            try Self.requireStableID(input.actorID)
        case .accountAdd(let input), .accountTest(let input):
            try Self.requireBounded(input.displayName, maximum: 512)
            try Self.requireBounded(input.email, maximum: 512)
            try Self.requireBounded(input.imapHost, maximum: 1_024)
            try Self.requireBounded(input.smtpHost, maximum: 1_024)
            try Self.requireBounded(input.username, maximum: 1_024)
            try Self.requireBounded(input.sentMailbox, maximum: 1_024)
            try Self.requireBounded(input.imapPassword, maximum: 16_384)
            try Self.requireBounded(input.smtpPassword, maximum: 16_384)
            try Self.require((1...65_535).contains(input.smtpPort))
        case .replaceAccountCredentials(let input):
            try Self.requireStableID(input.accountID)
            try Self.requireBounded(input.imapPassword, maximum: 16_384)
            try Self.requireBounded(input.smtpPassword, maximum: 16_384)
        case .googleAccountAdd(let input):
            try Self.requireBounded(input.displayName, maximum: 512)
            try Self.requireBounded(input.email, maximum: 512)
            try Self.requireIdentity(input.identity)
            try Self.requireToken(input.accessToken)
            try Self.requireToken(input.refreshToken)
            try Self.require(input.accessTokenExpiresAt.isFinite && input.accessTokenExpiresAt > 0)
        case .replaceGoogleAccountCredential(let input):
            try Self.requireStableID(input.accountID)
            try Self.requireIdentity(input.identity)
            try Self.requireToken(input.accessToken)
            try Self.requireToken(input.refreshToken)
            try Self.require(input.accessTokenExpiresAt.isFinite && input.accessTokenExpiresAt > 0)
        case .deleteAccount(let input):
            try Self.requireStableID(input.accountID)
        case .deliverDirectDraft(let input):
            try Self.requireStableID(input.draftID)
            try Self.requireBounded(input.expectedHash, maximum: 512)
            try Self.requireStableID(input.actorID)
        case .deliverBrowserReply(let input):
            try Self.requireStableID(input.draftID)
            try Self.requireBounded(input.expectedHash, maximum: 512)
            try Self.requireBounded(input.idempotencyKey, maximum: 128)
        case .archive(let input):
            try Self.requireStableID(input.messageID)
            try Self.requireStableMailbox(input.archiveMailbox ?? "Archive")
            try Self.requireSourceCopy(input)
            try Self.require(!input.permanent)
        case .delete(let input):
            try Self.requireStableID(input.messageID)
            try Self.require(input.archiveMailbox == nil)
            try Self.requireSourceCopy(input)
        case .markRead(let input), .markUnread(let input):
            try Self.requireStableID(input.messageID)
            try Self.require(input.archiveMailbox == nil)
            try Self.require(!input.permanent && input.sourceMailbox == nil && input.sourceUID == nil)
        case .flag(let input), .unflag(let input):
            try Self.requireStableID(input.messageID)
            try Self.require(input.archiveMailbox == nil && !input.permanent)
            try Self.requireSourceCopy(input)
        case .move(let input):
            try Self.requireStableID(input.messageID)
            guard let destination = input.archiveMailbox else { throw PlainpostForegroundOperationError.invalidEnvelope }
            try Self.requireStableMailbox(destination)
            try Self.require(!input.permanent)
            try Self.requireSourceCopy(input)
        case .addLabel(let input), .removeLabel(let input), .labelCommand(let input):
            try Self.requireStableID(input.labelID)
            try Self.requireStableID(input.messageID)
        }
    }

    private static func validate(_ input: PlainpostAIOperationInput) throws {
        switch input.operation {
        case .summarizeThread, .summarizeMessage, .translateMessage, .answerThreadQuestion,
            .answerMailboxQuestion, .draftReply, .rewriteDraft, .classifyMessage:
            try requireStableID(input.recordID)
        case .recategorizeInbox:
            try require(input.recordID.isEmpty)
        case .rebuildIndex:
            if !input.recordID.isEmpty {
                try requireStableID(input.recordID)
            }
        }
        try requireBounded(input.providerID, maximum: 512)
        if let modelID = input.modelID { try requireBounded(modelID, maximum: 512) }
        if let language = input.targetLanguageIdentifier {
            try requireBounded(language, maximum: 128)
        }
        if let name = input.targetLanguageName { try requireBounded(name, maximum: 256) }
        if let question = input.question { try requireBounded(question, maximum: 32_768) }
        if let conversationKey = input.activeConversationKey {
            try requireStableID(conversationKey)
        }
        if let requestID = input.smartInboxRequestID {
            try requireStableID(requestID)
        }
        if let labelID = input.smartInboxRunRequest.requestedLabelID {
            try requireStableID(labelID)
        }
        if case .account(let accountID) = input.smartInboxRunRequest.scope {
            try requireStableID(accountID.rawValue)
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            let data = try JSONEncoder().encode(value)
            try require(!data.isEmpty && data.count <= maximumPayloadBytes)
            return data
        } catch { throw PlainpostForegroundOperationError.invalidEnvelope }
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw PlainpostForegroundOperationError.invalidEnvelope
        }
    }

    private static func requireStableID(_ value: String) throws {
        try requireBounded(value, maximum: 1_024)
        try require(value == value.trimmingCharacters(in: .whitespacesAndNewlines))
        try require(
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        )
    }

    /// OAuth tokens: 1…16 KiB without whitespace or control characters.
    private static func requireToken(_ value: String) throws {
        try requireBounded(value, maximum: 16_384)
        try require(
            !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
        )
    }

    private static func requireIdentity(_ value: String) throws {
        try requireBounded(value, maximum: 320)
        try require(value.contains("@"))
        try require(
            !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
        )
    }

    private static func requireStableMailbox(_ value: String) throws {
        try requireBounded(value, maximum: 1_024)
        try require(
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try require(
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        )
    }

    private static func requireBounded(_ value: String, maximum: Int, allowsEmpty: Bool = false)
        throws
    { try require((allowsEmpty || !value.isEmpty) && value.utf8.count <= maximum) }

    private static func require(_ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw PlainpostForegroundOperationError.invalidEnvelope }
    }
}

public enum PlainpostForegroundOperationResult: Sendable {
    case inboxSync(PlainpostInboxSyncResult)
    case historicalSync(PlainpostInboxSyncResult)
    case ai(PlainpostAIOperationResult)
    case translateMessage(PlainpostAIOperationResult)
    case approveSend
    case denySend
    case accountAdd(PlainpostAccountSetupSemanticResult)
    case accountTest(PlainpostAccountTestSemanticResult)
    case replaceAccountCredentials
    case googleAccountAdd(PlainpostAccountSetupSemanticResult)
    case replaceGoogleAccountCredential
    case deleteAccount
    case deliverDirectDraft(PlainpostDirectDraftDeliverySemanticResult)
    case deliverBrowserReply(PlainpostBrowserReplyDeliverySemanticResult)
    case archive(PlainpostMailActionSemanticResult)
    case delete(PlainpostMailActionSemanticResult)
    case markRead(PlainpostMailActionSemanticResult)
    case markUnread(PlainpostMailActionSemanticResult)
    case flag(PlainpostMailActionSemanticResult)
    case unflag(PlainpostMailActionSemanticResult)
    case move(PlainpostMailActionSemanticResult)
    case addLabel
    case removeLabel
    case labelCommand

    public var kind: PlainpostForegroundOperationKind {
        switch self {
        case .inboxSync: .inboxSync
        case .historicalSync: .historicalSync
        case .ai: .AI
        case .translateMessage: .translateMessage
        case .approveSend: .approveSend
        case .denySend: .denySend
        case .accountAdd: .accountAdd
        case .accountTest: .accountTest
        case .replaceAccountCredentials: .replaceAccountCredentials
        case .googleAccountAdd: .googleAccountAdd
        case .replaceGoogleAccountCredential: .replaceGoogleAccountCredential
        case .deleteAccount: .deleteAccount
        case .deliverDirectDraft: .deliverDirectDraft
        case .deliverBrowserReply: .deliverBrowserReply
        case .archive: .archive
        case .delete: .delete
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .flag: .flag
        case .unflag: .unflag
        case .move: .move
        case .addLabel: .addLabel
        case .removeLabel: .removeLabel
        case .labelCommand: .labelCommand
        }
    }

    public func isSemanticallyCorrelated(
        with operation: PlainpostForegroundOperation
    ) -> Bool {
        guard kind == operation.kind else { return false }
        switch (self, operation) {
        case let (.archive(result), .archive(input)):
            return result.messageID == input.messageID
                && ArchiveMailbox.answers(result.mailboxPath, requested: input.archiveMailbox)
                && !result.isDeleted
        case let (.delete(result), .delete(input)):
            guard result.messageID == input.messageID else { return false }
            if input.permanent {
                // Only an erase answers an explicit Delete Permanently. The message
                // may remain (another copy, say in Sent), so isDeleted isn't required.
                return result.deleteOutcome == .deletedPermanently
            }
            switch result.deleteOutcome {
            case .movedToTrash?, .alreadyInTrash?:
                // A plain delete succeeds by moving to Trash, or finding it there.
                return !result.isDeleted
            case .deletedPermanently?:
                return false // a plain delete never erases
            case nil:
                // A Sync Node delete (or an older peer) reports it as deleted.
                return result.isDeleted
            }
        case let (.markRead(result), .markRead(input)):
            return result.messageID == input.messageID
                && result.seen == true
        case let (.markUnread(result), .markUnread(input)):
            return result.messageID == input.messageID
                && result.seen == false
        default:
            return true
        }
    }

    public func responseDTO() throws -> PlainpostForegroundOperationResultDTO {
        let payload: Data
        switch self {
        case .inboxSync(let value), .historicalSync(let value): payload = try Self.encode(value)
        case .ai(let value), .translateMessage(let value): payload = try Self.encode(value)
        case .approveSend, .denySend, .replaceAccountCredentials, .replaceGoogleAccountCredential,
            .deleteAccount, .addLabel, .removeLabel,
            .labelCommand:
            payload = try Self.encode(PlainpostEmptySemanticPayload())
        case .accountAdd(let value), .googleAccountAdd(let value): payload = try Self.encode(value)
        case .accountTest(let value): payload = try Self.encode(value)
        case .deliverDirectDraft(let value): payload = try Self.encode(value)
        case .deliverBrowserReply(let value): payload = try Self.encode(value)
        case .archive(let value), .delete(let value), .markRead(let value), .markUnread(let value),
            .flag(let value), .unflag(let value), .move(let value):
            payload = try Self.encode(value)
        }
        guard
            let response = PlainpostForegroundOperationResultDTO(
                schemaVersion: PlainpostForegroundOperation.schemaVersion, kind: kind,
                archivedPayload: payload)
        else { throw PlainpostForegroundOperationError.invalidEnvelope }
        return response
    }

    public init(responseDTO: PlainpostForegroundOperationResultDTO) throws {
        guard responseDTO.schemaVersion == PlainpostForegroundOperation.schemaVersion,
            !responseDTO.archivedPayload.isEmpty,
            responseDTO.archivedPayload.count <= PlainpostForegroundOperation.maximumPayloadBytes
        else { throw PlainpostForegroundOperationError.invalidEnvelope }
        let payload = responseDTO.archivedPayload
        switch responseDTO.kind {
        case .inboxSync: self = .inboxSync(try Self.decode(payload))
        case .historicalSync: self = .historicalSync(try Self.decode(payload))
        case .AI: self = .ai(try Self.decode(payload))
        case .translateMessage: self = .translateMessage(try Self.decode(payload))
        case .approveSend:
            try Self.decodeEmpty(payload)
            self = .approveSend
        case .denySend:
            try Self.decodeEmpty(payload)
            self = .denySend
        case .accountAdd: self = .accountAdd(try Self.decode(payload))
        case .accountTest: self = .accountTest(try Self.decode(payload))
        case .replaceAccountCredentials:
            try Self.decodeEmpty(payload)
            self = .replaceAccountCredentials
        case .googleAccountAdd: self = .googleAccountAdd(try Self.decode(payload))
        case .replaceGoogleAccountCredential:
            try Self.decodeEmpty(payload)
            self = .replaceGoogleAccountCredential
        case .deleteAccount:
            try Self.decodeEmpty(payload)
            self = .deleteAccount
        case .deliverDirectDraft: self = .deliverDirectDraft(try Self.decode(payload))
        case .deliverBrowserReply: self = .deliverBrowserReply(try Self.decode(payload))
        case .archive: self = .archive(try Self.decode(payload))
        case .delete: self = .delete(try Self.decode(payload))
        case .markRead: self = .markRead(try Self.decode(payload))
        case .markUnread: self = .markUnread(try Self.decode(payload))
        case .flag: self = .flag(try Self.decode(payload))
        case .unflag: self = .unflag(try Self.decode(payload))
        case .move: self = .move(try Self.decode(payload))
        case .addLabel:
            try Self.decodeEmpty(payload)
            self = .addLabel
        case .removeLabel:
            try Self.decodeEmpty(payload)
            self = .removeLabel
        case .labelCommand:
            try Self.decodeEmpty(payload)
            self = .labelCommand
        @unknown default: throw PlainpostForegroundOperationError.invalidEnvelope
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            let data = try JSONEncoder().encode(value)
            guard !data.isEmpty, data.count <= PlainpostForegroundOperation.maximumPayloadBytes
            else { throw PlainpostForegroundOperationError.invalidEnvelope }
            return data
        } catch { throw PlainpostForegroundOperationError.invalidEnvelope }
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw PlainpostForegroundOperationError.invalidEnvelope
        }
    }

    private static func decodeEmpty(_ data: Data) throws {
        let _: PlainpostEmptySemanticPayload = try decode(data)
    }
}

/// Preserves the existing operation-client surface while routing every
/// credential-dependent execution through the injected signed service client.
public final class PlainpostServiceOperationAdapter: PlainpostOperationClientProtocol,
    @unchecked Sendable
{
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws
        -> PlainpostInboxSyncResult
    {
        let operation: PlainpostForegroundOperation =
            input.scope == .completeHistory ? .historicalSync(input) : .inboxSync(input)
        let result = try await serviceClient.perform(operation)
        switch result {
        case .inboxSync(let value), .historicalSync(let value): return value
        default: throw PlainpostForegroundOperationError.unexpectedResult
        }
    }

    public func executeAI(_ input: PlainpostAIOperationInput) async throws
        -> PlainpostAIOperationResult
    {
        let operation: PlainpostForegroundOperation =
            input.operation == .translateMessage ? .translateMessage(input) : .ai(input)
        let result = try await serviceClient.perform(operation)
        switch result {
        case .ai(let value), .translateMessage(let value): return value
        default: throw PlainpostForegroundOperationError.unexpectedResult
        }
    }

    public func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        let enqueueInput = PlainpostAIOperationInput(
            operation: input.operation,
            recordID: input.recordID,
            conversationReferenceKind: input.conversationReferenceKind,
            accountID: input.accountID,
            providerID: input.providerID,
            modelID: input.modelID,
            smartInboxRunRequest: input.smartInboxRunRequest,
            smartInboxRequestID: input.smartInboxRequestID,
            smartInboxClassifierIdentity: input.smartInboxClassifierIdentity,
            enqueueOnly: true
        )
        guard case .ai = try await serviceClient.perform(.ai(enqueueInput))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }

    public func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        guard
            case .approveSend = try await serviceClient.perform(
                .approveSend(
                    PlainpostApprovalDecisionInput(requestID: requestID, actorID: approvedBy)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }

    public func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        guard
            case .denySend = try await serviceClient.perform(
                .denySend(PlainpostApprovalDecisionInput(requestID: requestID, actorID: deniedBy)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }
}
