import CryptoKit
import Foundation
import PlainpostAccountProtocol

public enum IMAPInternalDateParser {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    public static func date(from response: String) -> Date? {
        guard let match = response.range(
            of: #"INTERNALDATE\s+\"([^\"]+)\""#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let value = response[match]
            .replacingOccurrences(of: "^.*INTERNALDATE\\s+\\\"", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\"$", with: "", options: .regularExpression)
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: value)
    }
}

/// The only notification decision an IMAP ingress is allowed to make while
/// committing a message.  A candidate without provider arrival evidence is
/// deliberately representable, but is never eligible for publication.
public enum IncomingNotificationDisposition: Equatable, Sendable {
    case ineligible
    case establishWatermark
    case candidate(providerArrivalAt: Date?)

    public var isEligible: Bool {
        guard case .candidate(let arrival) = self else { return false }
        return arrival != nil
    }

    public var providerArrivalAt: Date? {
        guard case .candidate(let arrival) = self else { return nil }
        return arrival
    }

    public static func forSync(
        mailboxPath: String,
        source: IMAPSyncSource,
        generation: MailboxGenerationStatus,
        providerArrivalAt: Date?
    ) -> IncomingNotificationDisposition {
        guard mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame else {
            return .ineligible
        }
        guard source == .incremental, generation == .unchanged else {
            return .establishWatermark
        }
        return .candidate(providerArrivalAt: providerArrivalAt)
    }
}

public struct NotificationRecipientSnapshot: Equatable, Codable, Sendable {
    public let recipientID: String
    public let routingHandle: Data
    public let agreementPublicKey: Data
    public let replayID: String?
    public let collapseDigest: Data?
    public let producerDeviceID: String?
    public let producerGeneration: Int64?
    public let policyVersion: Int64?

    public init(recipientID: String, routingHandle: Data, agreementPublicKey: Data,
                replayID: String? = nil, collapseDigest: Data? = nil,
                producerDeviceID: String? = nil, producerGeneration: Int64? = nil,
                policyVersion: Int64? = nil) {
        self.recipientID = recipientID
        self.routingHandle = routingHandle
        self.agreementPublicKey = agreementPublicKey
        self.replayID = replayID
        self.collapseDigest = collapseDigest
        self.producerDeviceID = producerDeviceID
        self.producerGeneration = producerGeneration
        self.policyVersion = policyVersion
    }
}

public enum NotificationDeliveryOutcome: String, Codable, Sendable {
    case accepted
    case idempotent
    case retryable
    case expired
    case revoked
    case malformed
    case rejected
}

public struct NotificationProducerConfiguration: Equatable, Sendable {
    public let logicalMailboxID: String
    public let logicalMailboxIDValue: LogicalMailboxID?
    public let plainpostAccountID: PlainpostAccountID?
    public let producerDeviceID: String?
    public let producerDeviceIDValue: AccountDeviceID?
    public let producerKind: String
    public let policyMode: String
    public let policyVersion: Int64
    public let configRevision: Int64
    public let logicalMailboxIDBytes: Data
    public let producerGeneration: Int64
    public let configVersion: String
    /// Stable assignment/trust identity, independent of policy coordinates.
    /// Nil is retained for pre-Task-4 compatibility rows.
    public let producerIdentityDigest: String?
    /// Direct policy scope semantics; nil is retained for legacy callers.
    public let policyOverride: Bool?
    /// Direct policy scope high-water, independent of the legacy config
    /// revision used by assignment/trust/configuration consumers.
    public let directPolicyScopeVersion: Int64

    public init(logicalMailboxID: String, producerDeviceID: String? = nil,
                producerKind: String = "mac", policyMode: String = "off",
                policyVersion: Int64 = 0, configRevision: Int64 = 0,
                producerGeneration: Int64 = 0, configVersion: String = "default") {
        self.logicalMailboxID = logicalMailboxID
        self.logicalMailboxIDValue = nil
        self.plainpostAccountID = nil
        self.producerDeviceID = producerDeviceID
        self.producerDeviceIDValue = nil
        self.producerKind = producerKind
        self.policyMode = policyMode
        self.policyVersion = policyVersion
        self.configRevision = configRevision
        // String-only construction is a compatibility/unconfigured path. It
        // must never manufacture authority from a mailbox path or label.
        self.logicalMailboxIDBytes = Data(repeating: 0, count: 32)
        self.producerGeneration = producerGeneration
        self.configVersion = configVersion
        self.producerIdentityDigest = nil
        self.policyOverride = nil
        self.directPolicyScopeVersion = 0
    }

    public init(
        plainpostAccountID: PlainpostAccountID,
        logicalMailboxID: LogicalMailboxID,
        producerDeviceID: AccountDeviceID,
        producerKind: String = "mac",
        policyMode: String = "enabled",
        policyVersion: Int64,
        configRevision: Int64,
        producerGeneration: Int64,
        configVersion: String,
        producerIdentityDigest: String? = nil,
        policyOverride: Bool? = nil,
        directPolicyScopeVersion: Int64 = 0
    ) {
        self.logicalMailboxID = logicalMailboxID.rawValue.base64EncodedString()
        self.logicalMailboxIDValue = logicalMailboxID
        self.plainpostAccountID = plainpostAccountID
        self.producerDeviceID = producerDeviceID.rawValue
        self.producerDeviceIDValue = producerDeviceID
        self.producerKind = producerKind
        self.policyMode = policyMode
        self.policyVersion = policyVersion
        self.configRevision = configRevision
        self.logicalMailboxIDBytes = logicalMailboxID.rawValue
        self.producerGeneration = producerGeneration
        self.configVersion = configVersion
        self.producerIdentityDigest = producerIdentityDigest
        self.policyOverride = policyOverride
        self.directPolicyScopeVersion = directPolicyScopeVersion
    }
}

public struct NotificationPublicationClaim: Equatable, Sendable {
    public let publicationID: String
    public let accountID: AccountID
    public let messageID: MessageID
    public let leaseToken: String
    public let configVersion: String
    public let producerGeneration: Int64
    public let logicalMailboxID: String
    public let producerDeviceID: String?
    public let producerKind: String
    public let policyMode: String
    public let policyVersion: Int64
    public let configRevision: Int64
    public let logicalMailboxIDBytes: Data
    /// True when this claim resumes an already-frozen publication. Such a
    /// claim must never invoke coordination or rebuild envelopes.
    public let resumesFrozenPublication: Bool

    public init(
        publicationID: String,
        accountID: AccountID,
        messageID: MessageID,
        leaseToken: String,
        configVersion: String,
        producerGeneration: Int64,
        logicalMailboxID: String = "",
        producerDeviceID: String? = nil,
        producerKind: String = "mac",
        policyMode: String = "off",
        policyVersion: Int64 = 0,
        configRevision: Int64 = 0,
        logicalMailboxIDBytes: Data? = nil,
        resumesFrozenPublication: Bool = false
    ) {
        self.publicationID = publicationID
        self.accountID = accountID
        self.messageID = messageID
        self.leaseToken = leaseToken
        self.configVersion = configVersion
        self.producerGeneration = producerGeneration
        self.logicalMailboxID = logicalMailboxID
        // A path/label is not an authority coordinate. Unconfigured callers
        // remain explicitly invalid instead of silently inventing a mailbox
        // ID from local text.
        self.logicalMailboxIDBytes = logicalMailboxIDBytes ?? Data(repeating: 0, count: 32)
        self.producerDeviceID = producerDeviceID
        self.producerKind = producerKind
        self.policyMode = policyMode
        self.policyVersion = policyVersion
        self.configRevision = configRevision
        self.resumesFrozenPublication = resumesFrozenPublication
    }
}

public struct NotificationPublicationSource: Equatable, Sendable {
    public let publicationID: String
    public let accountID: AccountID
    public let plainpostAccountID: AccountID
    public let messageID: MessageID
    public let mailboxPath: String
    public let logicalMailboxID: String
    public let logicalMailboxIDBytes: Data
    public let threadID: ThreadID?
    public let uidValidity: Int
    public let uid: Int
    public let providerArrivalAt: Date?
    public let configVersion: String
    public let producerGeneration: Int64

    public init(publicationID: String, accountID: AccountID, messageID: MessageID,
                mailboxPath: String, uidValidity: Int, uid: Int, providerArrivalAt: Date?,
                plainpostAccountID: AccountID? = nil, logicalMailboxID: String? = nil,
                logicalMailboxIDBytes: Data? = nil,
                threadID: ThreadID? = nil, configVersion: String = "default",
                producerGeneration: Int64 = 0) {
        self.publicationID = publicationID
        self.accountID = accountID
        self.plainpostAccountID = plainpostAccountID ?? accountID
        self.messageID = messageID
        self.mailboxPath = mailboxPath
        self.logicalMailboxID = logicalMailboxID ?? mailboxPath
        // A mailbox path cannot stand in for Central's opaque 32-byte ID.
        // Callers must supply the durable coordinate explicitly.
        self.logicalMailboxIDBytes = logicalMailboxIDBytes ?? Data(repeating: 0, count: 32)
        self.threadID = threadID
        self.uidValidity = uidValidity
        self.uid = uid
        self.providerArrivalAt = providerArrivalAt
        self.configVersion = configVersion
        self.producerGeneration = producerGeneration
    }
}

public struct NotificationDeliveryClaim: Equatable, Sendable {
    public let publicationID: String
    public let recipientID: String
    public let routingHandle: Data
    public let agreementPublicKey: Data
    public let envelopeBytes: Data
    public let producerDeviceID: String?
    public let producerGeneration: Int64
    public let policyVersion: Int64
    public let replayID: String?
    public let collapseDigest: Data?
    public let envelopeDigest: Data?
    public let leaseToken: String?
    public let leaseExpiresAt: Date?

    public init(publicationID: String, recipientID: String, routingHandle: Data,
                agreementPublicKey: Data, envelopeBytes: Data,
                producerDeviceID: String? = nil, producerGeneration: Int64 = 0,
                policyVersion: Int64 = 0, replayID: String? = nil,
                collapseDigest: Data? = nil, envelopeDigest: Data? = nil,
                leaseToken: String? = nil, leaseExpiresAt: Date? = nil) {
        self.publicationID = publicationID
        self.recipientID = recipientID
        self.routingHandle = routingHandle
        self.agreementPublicKey = agreementPublicKey
        self.envelopeBytes = envelopeBytes
        self.producerDeviceID = producerDeviceID
        self.producerGeneration = producerGeneration
        self.policyVersion = policyVersion
        self.replayID = replayID
        self.collapseDigest = collapseDigest
        self.envelopeDigest = envelopeDigest
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
    }
}

/// Narrow persistence seam for the post-commit producer. Implementations must
/// perform only durable state transitions here; envelope construction and all
/// network I/O happen outside the database transaction.
public protocol NotificationPublicationStore: AnyObject, Sendable {
    func source(for publicationID: String) throws -> NotificationPublicationSource?
    func claimDeliveries(
        publicationID: String,
        leaseToken: String,
        limit: Int,
        now: Date
    ) throws -> [NotificationDeliveryClaim]
    func nextWorkDate(now: Date) throws -> Date?
    func claimNotificationPublication(
        now: Date,
        leaseToken: String,
        leaseDuration: TimeInterval
    ) throws -> NotificationPublicationClaim?
    func claimNotificationPublications(
        now: Date,
        leaseToken: String,
        leaseDuration: TimeInterval,
        limit: Int
    ) throws -> [NotificationPublicationClaim]
    func freezeNotificationPublication(
        publicationID: String,
        leaseToken: String,
        configVersion: String,
        producerGeneration: Int64,
        recipients: [NotificationRecipientSnapshot],
        envelopeBytes: [Data]
    ) throws -> Bool
    func cancelNotificationPublication(
        publicationID: String,
        leaseToken: String,
        configVersion: String,
        producerGeneration: Int64
    ) throws -> Bool
    func recordNotificationDeliveryOutcome(
        publicationID: String,
        leaseToken: String,
        recipientID: String,
        outcome: NotificationDeliveryOutcome,
        nextAttemptAt: Date?
    ) throws -> Bool
    func cleanupNotificationPublications(olderThan cutoff: Date) throws -> Int
}

public extension NotificationPublicationStore {
    func claimNotificationPublications(
        now: Date = Date(),
        leaseToken: String = UUID().uuidString,
        leaseDuration: TimeInterval = 60,
        limit: Int = 1
    ) throws -> [NotificationPublicationClaim] {
        guard limit > 0 else { return [] }
        var claims: [NotificationPublicationClaim] = []
        claims.reserveCapacity(limit)
        while claims.count < limit,
              let claim = try claimNotificationPublication(
                now: now, leaseToken: leaseToken, leaseDuration: leaseDuration
              ) {
            claims.append(claim)
        }
        return claims
    }

    func claimNotificationPublication(
        now: Date = Date(),
        leaseToken: String = UUID().uuidString,
        leaseDuration: TimeInterval = 60
    ) throws -> NotificationPublicationClaim? {
        try claimNotificationPublication(now: now, leaseToken: leaseToken, leaseDuration: leaseDuration)
    }
}
