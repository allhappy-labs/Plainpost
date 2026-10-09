import Foundation
import PlainpostAccountProtocol
import PlainpostCore

public struct NotificationMessageSnapshot: Sendable, Equatable {
    public let mailboxToken: String
    public let threadToken: String
    public let messageToken: String
    public let sender: String
    public let subject: String
    public let preview: String
    public let badge: UInt16
    public let messageDigest: Data
    public let replayID: Data
    public let collapseDigest: Data

    public init(mailboxToken: String, threadToken: String, messageToken: String, sender: String, subject: String, preview: String, badge: UInt16, messageDigest: Data, replayID: Data, collapseDigest: Data) {
        self.mailboxToken = mailboxToken; self.threadToken = threadToken; self.messageToken = messageToken
        self.sender = sender; self.subject = subject; self.preview = preview; self.badge = badge
        self.messageDigest = messageDigest; self.replayID = replayID; self.collapseDigest = collapseDigest
    }
}

public struct NotificationTrustCoordinates: Sendable, Equatable {
    public let epoch: UInt64
    public let revision: UInt64
    public let head: Data

    public init(epoch: UInt64, revision: UInt64, head: Data) throws {
        guard epoch > 0, revision > 0, head.count == 32, head.contains(where: { $0 != 0 }) else { throw NotificationRuntimeError.invalidAssignment }
        self.epoch = epoch; self.revision = revision; self.head = head
    }
}

/// Concrete producer-side preview builder. Message and trust snapshots are
/// queried by source at prepare time; after NotificationDrain freezes the
/// resulting bytes this builder is never invoked again.
public struct PPN2NotificationPreviewBuilder: NotificationPreviewBuilder, @unchecked Sendable {
    private let producerDeviceID: AccountDeviceID
    private let producerSigningPublicKey: Data
    private let sign: @Sendable (Data) throws -> Data
    private let snapshot: @Sendable (NotificationPublicationSource, NotificationPublicationClaim) throws -> NotificationMessageSnapshot
    private let trust: @Sendable (NotificationPublicationSource, NotificationPublicationClaim) throws -> NotificationTrustCoordinates
    private let now: @Sendable () -> Date

    public init(producerDeviceID: AccountDeviceID, producerSigningPublicKey: Data, sign: @escaping @Sendable (Data) throws -> Data, snapshot: @escaping @Sendable (NotificationPublicationSource, NotificationPublicationClaim) throws -> NotificationMessageSnapshot, trust: @escaping @Sendable (NotificationPublicationSource, NotificationPublicationClaim) throws -> NotificationTrustCoordinates, now: @escaping @Sendable () -> Date = Date.init) {
        self.producerDeviceID = producerDeviceID; self.producerSigningPublicKey = producerSigningPublicKey; self.sign = sign; self.snapshot = snapshot; self.trust = trust; self.now = now
    }

    public func envelope(for source: NotificationPublicationSource, claim: NotificationPublicationClaim, recipient: NotificationRecipientSnapshot) throws -> Data {
        guard claim.policyMode != "off", claim.policyVersion > 0, claim.policyVersion <= Int64(UInt16.max),
              recipient.recipientID != producerDeviceID.rawValue,
              let recipientID = try? AccountDeviceID(recipient.recipientID),
              let snapshot = try? self.snapshot(source, claim),
              let trust = try? self.trust(source, claim) else { throw NotificationRuntimeError.staleAssignment }
        let content: (String, String, String)
        switch claim.policyMode {
        case "rich_preview": content = (snapshot.sender, snapshot.subject, snapshot.preview)
        case "sender_subject": content = (snapshot.sender, snapshot.subject, "")
        // Generic presentation deliberately hides sender/subject and renders
        // the fixed service text. Keep the encrypted tuple canonical too.
        case "generic": content = ("Plainpost", "New mail is available.", "")
        default: throw NotificationRuntimeError.staleAssignment
        }
        return try RichNotificationEnvelope.seal(
            recipientRoutingHandle: recipient.routingHandle,
            recipientAgreementPublicKey: recipient.agreementPublicKey,
            recipientDeviceID: recipientID,
            producerDeviceID: producerDeviceID,
            logicalMailboxID: source.logicalMailboxIDBytes,
            trustEpoch: trust.epoch,
            trustRevision: trust.revision,
            producerAssignmentGeneration: claim.producerGeneration > 0 ? UInt64(claim.producerGeneration) : 0,
            trustHead: trust.head,
            policyVersion: UInt16(claim.policyVersion),
            messageDigest: snapshot.messageDigest,
            replayID: snapshot.replayID,
            collapseDigest: snapshot.collapseDigest,
            mailboxToken: snapshot.mailboxToken,
            threadToken: snapshot.threadToken,
            messageToken: snapshot.messageToken,
            sender: content.0,
            subject: content.1,
            preview: content.2,
            badge: snapshot.badge,
            now: now(),
            producerSigningPublicKey: producerSigningPublicKey,
            sign: sign
        )
    }
}
