import Foundation
import PlainpostAccountProtocol
import PlainpostCore

public enum NotificationRuntimeError: Error, Equatable, Sendable {
    case unavailable
    case invalidAssignment
    case staleAssignment
    case invalidEnvelope
}

/// A coordination response is the only authority source allowed to select
/// recipients. The signed bytes are retained so verification is explicit at
/// the producer boundary rather than inferred from database rows.
public struct NotificationRecipientAssignment: Sendable {
    public let recipients: [NotificationRecipientSnapshot]
    public let signedBytes: Data
    public let signature: Data
    public let signerDeviceID: String
    public let configVersion: String
    public let producerGeneration: Int64
    public let policyVersion: Int64

    public init(
        recipients: [NotificationRecipientSnapshot],
        signedBytes: Data,
        signature: Data,
        signerDeviceID: String,
        configVersion: String,
        producerGeneration: Int64,
        policyVersion: Int64
    ) {
        self.recipients = recipients
        self.signedBytes = signedBytes
        self.signature = signature
        self.signerDeviceID = signerDeviceID
        self.configVersion = configVersion
        self.producerGeneration = producerGeneration
        self.policyVersion = policyVersion
    }
}

public protocol CoordinationClient: Sendable {
    /// The claim is part of the authority coordinate. Implementations must
    /// not infer the selected producer from mailbox text or local defaults.
    func recipientAssignment(
        for source: NotificationPublicationSource,
        claim: NotificationPublicationClaim
    ) async throws -> NotificationRecipientAssignment
}

public protocol RecipientAssignmentVerifying: Sendable {
    func verify(
        assignment: NotificationRecipientAssignment,
        source: NotificationPublicationSource
    ) throws
}

public protocol NotificationPreviewBuilder: Sendable {
    func envelope(
        for source: NotificationPublicationSource,
        claim: NotificationPublicationClaim,
        recipient: NotificationRecipientSnapshot
    ) throws -> Data
}

public protocol RelayClient: Sendable {
    func deliver(
        _ delivery: NotificationDeliveryClaim
    ) async throws -> NotificationRelayResult
}

public struct NotificationRelayResult: Sendable, Equatable {
    public let outcome: NotificationDeliveryOutcome
    public let nextAttemptAt: Date?

    public init(outcome: NotificationDeliveryOutcome, nextAttemptAt: Date? = nil) {
        self.outcome = outcome
        self.nextAttemptAt = nextAttemptAt
    }
}

public struct NotificationPreparedPublication: Sendable {
    public let recipients: [NotificationRecipientSnapshot]
    public let envelopeBytes: [Data]
    public let configVersion: String
    public let producerGeneration: Int64

    init(
        recipients: [NotificationRecipientSnapshot],
        envelopeBytes: [Data],
        configVersion: String,
        producerGeneration: Int64
    ) {
        self.recipients = recipients
        self.envelopeBytes = envelopeBytes
        self.configVersion = configVersion
        self.producerGeneration = producerGeneration
    }
}

/// Coordinates assignment verification and one-time envelope construction.
/// After freeze, the drain always relays bytes read from SQLite and never
/// calls this builder again.
public struct NotificationProducer: Sendable {
    private let coordination: any CoordinationClient
    private let verifier: any RecipientAssignmentVerifying
    private let previewBuilder: any NotificationPreviewBuilder

    public init(
        coordination: any CoordinationClient,
        verifier: any RecipientAssignmentVerifying,
        previewBuilder: any NotificationPreviewBuilder
    ) {
        self.coordination = coordination
        self.verifier = verifier
        self.previewBuilder = previewBuilder
    }

    /// Production composition uses this until authenticated coordination and
    /// preview adapters are assembled. It deliberately fails closed before a
    /// publication can be frozen.
    public static func unavailable() -> NotificationProducer {
        NotificationProducer(
            coordination: UnavailableCoordinationClient(),
            verifier: RejectingAssignmentVerifier(),
            previewBuilder: UnavailablePreviewBuilder()
        )
    }

    public func prepare(
        claim: NotificationPublicationClaim,
        source: NotificationPublicationSource
    ) async throws -> NotificationPreparedPublication {
        guard claim.publicationID == source.publicationID,
              claim.messageID == source.messageID,
              claim.configVersion == source.configVersion,
              claim.producerGeneration == source.producerGeneration,
              claim.logicalMailboxIDBytes.count == 32,
              claim.logicalMailboxIDBytes.contains(where: { $0 != 0 }),
              claim.producerKind == "mac",
              claim.policyVersion > 0,
              claim.producerGeneration > 0 else {
            throw NotificationRuntimeError.staleAssignment
        }

        let assignment = try await coordination.recipientAssignment(for: source, claim: claim)
        try verifier.verify(assignment: assignment, source: source)
        guard assignment.configVersion == claim.configVersion,
              assignment.producerGeneration == claim.producerGeneration,
              assignment.policyVersion == claim.policyVersion,
              assignment.signerDeviceID == claim.producerDeviceID,
              assignment.recipients.map(\.recipientID).count == Set(assignment.recipients.map(\.recipientID)).count,
              assignment.recipients.allSatisfy({
                  $0.routingHandle.count == 32 && $0.agreementPublicKey.count == 65
              }) else {
            throw NotificationRuntimeError.staleAssignment
        }

        let envelopes = try assignment.recipients.map {
            let bytes = try previewBuilder.envelope(for: source, claim: claim, recipient: $0)
            guard !bytes.isEmpty, bytes.count <= 4096 else {
                throw NotificationRuntimeError.invalidEnvelope
            }
            return bytes
        }
        return NotificationPreparedPublication(
            recipients: assignment.recipients,
            envelopeBytes: envelopes,
            configVersion: assignment.configVersion,
            producerGeneration: assignment.producerGeneration
        )
    }
}

private struct UnavailableCoordinationClient: CoordinationClient {
    func recipientAssignment(
        for source: NotificationPublicationSource,
        claim: NotificationPublicationClaim
    ) async throws -> NotificationRecipientAssignment {
        throw NotificationRuntimeError.unavailable
    }
}

private struct RejectingAssignmentVerifier: RecipientAssignmentVerifying {
    func verify(
        assignment: NotificationRecipientAssignment,
        source: NotificationPublicationSource
    ) throws {
        throw NotificationRuntimeError.unavailable
    }
}

private struct UnavailablePreviewBuilder: NotificationPreviewBuilder {
    func envelope(for source: NotificationPublicationSource, claim: NotificationPublicationClaim, recipient: NotificationRecipientSnapshot) throws -> Data {
        throw NotificationRuntimeError.unavailable
    }
}

public struct UnavailableRelayClient: RelayClient {
    public init() {}

    public func deliver(
        _ delivery: NotificationDeliveryClaim
    ) async throws -> NotificationRelayResult {
        throw NotificationRuntimeError.unavailable
    }
}

public struct NotificationDrainResult: Sendable, Equatable {
    public let claimedCount: Int
    public let frozenCount: Int
    public let deliveredCount: Int
    public let retryAt: Date?

    public init(claimedCount: Int, frozenCount: Int, deliveredCount: Int, retryAt: Date?) {
        self.claimedCount = claimedCount
        self.frozenCount = frozenCount
        self.deliveredCount = deliveredCount
        self.retryAt = retryAt
    }
}

/// Drains only the durable local publication store. It has no Central client
/// and cannot bypass assignment verification or exact-byte persistence.
public actor NotificationDrain {
    private let store: any NotificationPublicationStore
    private let producer: NotificationProducer
    private let relay: any RelayClient
    private let dateProvider: @Sendable () -> Date
    private let leaseDuration: TimeInterval
    private let batchLimit: Int

    public init(
        store: any NotificationPublicationStore,
        producer: NotificationProducer,
        relay: any RelayClient,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        leaseDuration: TimeInterval = 60,
        batchLimit: Int = 16
    ) {
        self.store = store
        self.producer = producer
        self.relay = relay
        self.dateProvider = dateProvider
        self.leaseDuration = leaseDuration
        self.batchLimit = max(1, batchLimit)
    }

    public func drain() async throws -> NotificationDrainResult {
        let now = dateProvider()
        let leaseToken = UUID().uuidString
        let claims = try store.claimNotificationPublications(
            now: now,
            leaseToken: leaseToken,
            leaseDuration: leaseDuration,
            limit: batchLimit
        )
        var frozenCount = 0
        var deliveredCount = 0
        for claim in claims {
            guard let source = try store.source(for: claim.publicationID) else {
                _ = try store.cancelNotificationPublication(
                    publicationID: claim.publicationID,
                    leaseToken: claim.leaseToken,
                    configVersion: claim.configVersion,
                    producerGeneration: claim.producerGeneration
                )
                continue
            }
            if claim.resumesFrozenPublication {
                // Retry paths retain the frozen recipient set and exact
                // ciphertext. Coordination and preview are never repeated.
                frozenCount += 1
            } else {
                do {
                    let prepared = try await producer.prepare(claim: claim, source: source)
                    guard try store.freezeNotificationPublication(
                        publicationID: claim.publicationID,
                        leaseToken: claim.leaseToken,
                        configVersion: prepared.configVersion,
                        producerGeneration: prepared.producerGeneration,
                        recipients: prepared.recipients,
                        envelopeBytes: prepared.envelopeBytes
                    ) else { continue }
                    frozenCount += 1
                } catch NotificationRuntimeError.staleAssignment {
                    _ = try store.cancelNotificationPublication(
                        publicationID: claim.publicationID,
                        leaseToken: claim.leaseToken,
                        configVersion: claim.configVersion,
                        producerGeneration: claim.producerGeneration
                    )
                } catch {
                    // Leave the claimed lease durable; expiry makes the work
                    // retryable without inventing a terminal outcome.
                    continue
                }
            }

            let deliveries = try store.claimDeliveries(
                publicationID: claim.publicationID,
                leaseToken: claim.leaseToken,
                limit: batchLimit,
                now: dateProvider()
            )
            for delivery in deliveries {
                do {
                    let result = try await relay.deliver(delivery)
                    if try store.recordNotificationDeliveryOutcome(
                        publicationID: delivery.publicationID,
                        leaseToken: claim.leaseToken,
                        recipientID: delivery.recipientID,
                        outcome: result.outcome,
                        nextAttemptAt: result.nextAttemptAt
                    ) {
                        deliveredCount += 1
                    }
                } catch {
                    _ = try? store.recordNotificationDeliveryOutcome(
                        publicationID: delivery.publicationID,
                        leaseToken: claim.leaseToken,
                        recipientID: delivery.recipientID,
                        outcome: .retryable,
                        nextAttemptAt: dateProvider().addingTimeInterval(30)
                    )
                }
            }
        }
        return NotificationDrainResult(
            claimedCount: claims.count,
            frozenCount: frozenCount,
            deliveredCount: deliveredCount,
            retryAt: try store.nextWorkDate(now: dateProvider())
        )
    }
}
