import Foundation
import CryptoKit
import PlainpostAccountProtocol

public struct MailSnapshotPage: Equatable, Sendable {
    public let messages: [MessageSummary]
    public let nextCursor: MailSearchCursor?
    public let revision: String

    public init(messages: [MessageSummary], nextCursor: MailSearchCursor?, revision: String) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.revision = revision
    }
}

public struct MailAttachment: Equatable, Codable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let disposition: String
    public let byteCount: Int
    public let contentDigest: String?

    public init(id: String, filename: String, mimeType: String, disposition: String, byteCount: Int, contentDigest: String?) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.disposition = disposition
        self.byteCount = byteCount
        self.contentDigest = contentDigest
    }
}

public struct MailAttachmentStream: Sendable {
    public let metadata: MailAttachment
    public let bytes: PlainpostByteStream

    public init(metadata: MailAttachment, bytes: PlainpostByteStream) {
        self.metadata = metadata
        self.bytes = bytes
    }

    /// Consumes the one-shot stream while enforcing the declared attachment
    /// size. Callers that need streaming should iterate `bytes` directly;
    /// this bounded helper is for UI previews and save panels.
    public func readAll(maxBytes: Int = 50 * 1_048_576) async throws -> Data {
        guard maxBytes >= 0 else { throw PlainpostError.validationFailed("Invalid attachment limit.") }
        var result = Data()
        for try await chunk in bytes {
            guard chunk.count <= maxBytes - result.count else {
                throw PlainpostError.validationFailed("Attachment exceeds the allowed size.")
            }
            result.append(chunk)
        }
        guard result.count == metadata.byteCount else {
            throw PlainpostError.validationFailed("Attachment size did not match Node metadata.")
        }
        if let contentDigest = metadata.contentDigest {
            let normalized = contentDigest.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
            guard let expectedDigest = Data(base64Encoded: padded),
                  expectedDigest == Data(SHA256.hash(data: result)) else {
                throw PlainpostError.validationFailed("Attachment digest did not match Node metadata.")
            }
        }
        return result
    }
}

public struct MailMutationResult: Equatable, Sendable {
    public let idempotencyKey: String
    public let state: String

    public init(idempotencyKey: String, state: String) {
        self.idempotencyKey = idempotencyKey
        self.state = state
    }
}

/// Source-neutral intents understood by a Node-backed mutation capability.
/// UI code describes the requested effect; the authority owns canonical
/// encoding, signing, idempotency, and transport.
public enum MailMutationIntent: Equatable, Sendable {
    case saveDraft(Draft)
    case deleteDraft(DraftID)
    case send(Draft)
    case setRead(messageIDs: [MessageID], read: Bool)
    case archive(messageIDs: [MessageID])
    case delete(messageIDs: [MessageID])
    case setLabels(messageIDs: [MessageID], addLabelIDs: [String], removeLabelIDs: [String])
    case setFlagged(messageIDs: [MessageID], flagged: Bool)
    /// `destinationMailboxPath` is the folder's provider path, as mirror coordinates name it.
    case move(messageIDs: [MessageID], destinationMailboxPath: String)
}

public protocol MailSnapshotServing: Sendable {
    func snapshot(after cursor: MailSearchCursor?, limit: Int) async throws -> MailSnapshotPage
}

public protocol MailMessageServing: Sendable {
    func message(id: MessageID) async throws -> MessageSummary
}

public protocol MailMutationServing: Sendable {
    func apply(canonicalOperation: Data) async throws -> MailMutationResult
    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult
    /// Signs and applies `intent` under the caller's idempotency key (for a
    /// journaled intent, its operation ID), so a retry of the same change can
    /// never become a second Node operation.
    func perform(_ intent: MailMutationIntent, idempotencyKey: String) async throws -> MailMutationResult
}

public extension MailMutationServing {
    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        _ = intent
        throw PlainpostError.permissionDenied("This mail authority does not expose mutations.")
    }

    func perform(_ intent: MailMutationIntent, idempotencyKey: String) async throws -> MailMutationResult {
        _ = (intent, idempotencyKey)
        throw PlainpostError.permissionDenied("This mail authority does not expose mutations.")
    }
}

public protocol MailAttachmentServing: Sendable {
    func attachment(id: String) async throws -> MailAttachmentStream
}

public protocol PlainpostMailAuthority: Sendable {
    /// The account identity selected by this authority. Local fixture
    /// authorities may leave it unspecified, but a production Node authority
    /// must expose its bound account so UI projections cannot borrow another
    /// account's local identity.
    var accountID: AccountID? { get }
    /// Provider identity selected by the Node for composing. A Node-backed
    /// authority must supply this; local fixtures may leave it unset.
    var senderAddress: EmailAddress? { get }
    var snapshots: any MailSnapshotServing { get }
    var search: any MailSearchService { get }
    var messages: any MailMessageServing { get }
    var mutations: any MailMutationServing { get }
    var attachments: any MailAttachmentServing { get }
}

public extension PlainpostMailAuthority {
    var accountID: AccountID? { nil }
    var senderAddress: EmailAddress? { nil }
}
