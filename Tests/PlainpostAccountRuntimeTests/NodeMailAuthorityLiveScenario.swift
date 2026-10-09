import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

/// The Client API acceptance runs in the already-enrolled private-transport
/// test process. It intentionally accepts the live Node sender rather than a
/// serialized session document, so the scenario cannot accidentally exercise
/// a second fake/session owner.
@MainActor
enum NodeMailAuthorityLiveScenario {
    enum ControlSignalObservation: Equatable, Sendable {
        case applied
        case failed
    }

    /// The live SMTP matrix is intentionally a closed, hand-derived contract.
    /// Counts describe the fixture's durable observations; operationClass and
    /// restartResult describe the provider result visible at the Node edge.
    enum SMTPMatrixOperationClass: String, Equatable, Sendable {
        case accepted
        case rejected
        case temporary
        case cancelled
        case deliveryUncertain = "delivery-uncertain"
    }

    enum SMTPMatrixResultClass: String, Equatable, Sendable {
        case accepted
        case rejected
        case temporary
        case disconnect
        case none
    }

    enum SMTPMatrixRestartResult: String, Equatable, Sendable {
        case accepted
        case uncertain
        case none
    }

    struct IMAPMatrixCase: Equatable, Sendable {
        let selector: String
        let fault: String
        let phase: String
        let protocolName: String
    }

    enum IMAPMatrixExpectedFaultClass: String, Equatable, Sendable {
        case authentication
        case transport
        case disconnect
    }

    enum IMAPMatrixAttachmentFaultClass: String, Equatable, Sendable {
        case disconnect
        case truncated
    }

    struct AuthorityReplacementContext: Sendable {
        let client: NodeSyncClient
        let authority: PlainpostNodeMailAuthority
    }

    typealias AuthorityReplacement = @MainActor () async throws -> AuthorityReplacementContext

    struct SMTPMatrixCase: Equatable, Sendable {
        let selector: String
        let fault: String
        let phase: String?
        let resultClass: SMTPMatrixResultClass
        let operationClass: SMTPMatrixOperationClass
        let draftCount: Int
        let deliveryCount: Int
        let sentCount: Int
        let authenticationCommandCount: Int
        let initialCancellationObserved: Bool
        let retryEligible: Bool
        let restartResult: SMTPMatrixRestartResult
    }

    static let smtpMatrixCases: [SMTPMatrixCase] = [
        SMTPMatrixCase(selector: "smtp-authentication", fault: "smtp-authentication", phase: "authentication", resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-recipient-451", fault: "smtp-recipient-451", phase: "recipient", resultClass: .temporary, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-recipient-550", fault: "smtp-recipient-550", phase: "recipient", resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-after-354", fault: "smtp-after-354", phase: "after-354", resultClass: .disconnect, operationClass: .deliveryUncertain, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .uncertain),
        SMTPMatrixCase(selector: "smtp-mid-data", fault: "smtp-mid-data", phase: "data", resultClass: .disconnect, operationClass: .deliveryUncertain, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .uncertain),
        SMTPMatrixCase(selector: "smtp-final-reply", fault: "smtp-final-reply", phase: "final-reply", resultClass: .disconnect, operationClass: .deliveryUncertain, draftCount: 1, deliveryCount: 1, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .uncertain),
        SMTPMatrixCase(selector: "smtp-quit-loss", fault: "smtp-quit-loss", phase: "quit", resultClass: .disconnect, operationClass: .accepted, draftCount: 0, deliveryCount: 1, sentCount: 1, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .accepted),
        SMTPMatrixCase(selector: "smtp-cancel-before-data", fault: "none", phase: "before-data", resultClass: .none, operationClass: .accepted, draftCount: 0, deliveryCount: 1, sentCount: 1, authenticationCommandCount: 1, initialCancellationObserved: true, retryEligible: true, restartResult: .accepted),
        SMTPMatrixCase(selector: "smtp-cancel-after-data", fault: "smtp-final-reply", phase: "acceptance-before-append", resultClass: .disconnect, operationClass: .deliveryUncertain, draftCount: 1, deliveryCount: 1, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: true, retryEligible: false, restartResult: .uncertain),
        SMTPMatrixCase(selector: "smtp-sent-append-failure", fault: "imap-sent-append", phase: "sent-append", resultClass: .temporary, operationClass: .accepted, draftCount: 0, deliveryCount: 1, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .accepted),
        SMTPMatrixCase(selector: "smtp-provider-restart-after-acceptance", fault: "none", phase: "sent-append", resultClass: .none, operationClass: .accepted, draftCount: 0, deliveryCount: 1, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .accepted),
        SMTPMatrixCase(selector: "smtp-untrusted-certificate", fault: "none", phase: nil, resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 0, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-same-ca-wrong-host", fault: "none", phase: nil, resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 0, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-tls1.1", fault: "none", phase: nil, resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 0, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-auth-before-starttls", fault: "none", phase: nil, resultClass: .rejected, operationClass: .rejected, draftCount: 1, deliveryCount: 0, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .none),
        SMTPMatrixCase(selector: "smtp-concurrent-sends", fault: "none", phase: nil, resultClass: .accepted, operationClass: .accepted, draftCount: 0, deliveryCount: 2, sentCount: 2, authenticationCommandCount: 2, initialCancellationObserved: false, retryEligible: false, restartResult: .accepted),
        SMTPMatrixCase(selector: "smtp-ambiguous-replay", fault: "smtp-final-reply", phase: "final-reply", resultClass: .disconnect, operationClass: .deliveryUncertain, draftCount: 1, deliveryCount: 1, sentCount: 0, authenticationCommandCount: 1, initialCancellationObserved: false, retryEligible: false, restartResult: .uncertain),
    ]

    static let imapMatrixCases: [IMAPMatrixCase] = [
        IMAPMatrixCase(selector: "imap-authentication", fault: "imap-authentication", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-untrusted-certificate", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-same-ca-wrong-host", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-tls1.1", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-catalog", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-header-fetch", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-body-fetch", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-attachment-fetch", fault: "imap-attachment-fetch", phase: "attachment-fetch", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-delayed-literal", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-truncated-literal", fault: "imap-truncated-literal", phase: "attachment-fetch", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-uid-gaps", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-expunge", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-uidvalidity-reset", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-idle-wakeup", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-poll-fallback", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-provider-restart-mid-page", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-provider-restart-after-commit", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-node-restart-before-ack", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-node-restart-after-ack", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-concurrent-mutations", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-stale-authority", fault: "none", phase: "none", protocolName: "imap"),
        IMAPMatrixCase(selector: "imap-mime-boundaries", fault: "none", phase: "none", protocolName: "imap"),
    ]

    nonisolated static func imapMatrixRecoveryErrorIsTransientForTesting(_ error: Error) -> Bool {
        if let error = error as? NodeSyncClientError {
            switch error {
            case .transport, .problem(.unavailable):
                return true
            case .cancelled, .conflict, .invalidResponse, .notFound, .problem, .transportAfterDispatch, .cancelledAfterDispatch:
                return false
            }
        }
        return (error as? PlainpostError) == .validationFailed("The Node is unavailable.")
    }

    /// A response dropped after the Node commits leaves the exact canonical
    /// mutation retained on the client. Replaying it after restart must return
    /// that durable applied result, never a second provider operation.
    nonisolated static func imapMatrixRestartReplayStateIsAppliedForTesting(_ state: String) -> Bool {
        state == "applied"
    }

    static func performAuthorityReplacement(_ replacement: AuthorityReplacement?) async throws -> AuthorityReplacementContext {
        guard let replacement else {
            XCTFail("IMAP stale-authority acceptance requires the real authority replacement callback")
            throw NodeSyncClientError.invalidResponse
        }
        return try await replacement()
    }

    private static func cancelAndConsume<T>(_ task: Task<T, Never>) async {
        task.cancel()
        _ = await task.value
    }

    static func imapMessageIsSeenForTesting(flags: [String]) -> Bool {
        flags.contains("seen")
    }

    static func imapMessageWithReadStateForTesting(_ message: NodeSyncMessage, seen: Bool) -> NodeSyncMessage {
        let flags = message.flags.filter { $0 != "seen" } + (seen ? ["seen"] : [])
        return NodeSyncMessage(
            attachments: message.attachments, bcc: message.bcc, cc: message.cc,
            flags: flags.sorted(), from: message.from, htmlBody: message.htmlBody, id: message.id,
            inReplyTo: message.inReplyTo, labels: message.labels, receivedAt: message.receivedAt,
            references: message.references, replyTo: message.replyTo, sentAt: message.sentAt,
            subject: message.subject, textBody: message.textBody, threadID: message.threadID, to: message.to
        )
    }

    struct IMAPNormalizedSnapshot: Equatable, Sendable {
        let messages: [NodeSyncMessage]
        let nextCursor: String
        let revision: String

        var hasMore: Bool { !nextCursor.isEmpty }
    }

    private struct IMAPAttachmentFetchEvidence: Sendable {
        let metadata: NodeSyncAttachment?
        let bytes: Data
    }

    static func imapNormalizedSnapshotForTesting(_ page: NodeSyncSnapshotPage) -> IMAPNormalizedSnapshot {
        IMAPNormalizedSnapshot(messages: page.messages, nextCursor: page.nextCursor, revision: page.revision)
    }

    static func imapSnapshotMatchesExpectedForTesting(
        _ page: NodeSyncSnapshotPage,
        expectedMessages: [NodeSyncMessage]?,
        expectedRevision: String?,
        requireAcceptanceFixtureShape: Bool,
        expectedAttachmentDigest: String? = nil
    ) -> Bool {
        let normalized = imapNormalizedSnapshotForTesting(page)
        guard !normalized.revision.isEmpty, normalized.revision != "0",
              normalized.nextCursor.isEmpty, !normalized.hasMore else { return false }
        if let expectedRevision, normalized.revision != expectedRevision { return false }
        if let expectedMessages, normalized.messages != expectedMessages { return false }
        return !requireAcceptanceFixtureShape || imapAcceptanceFixtureShapeMatches(
            normalized.messages,
            expectedAttachmentDigest: expectedAttachmentDigest
        )
    }

    static func imapReplacementSnapshotMessagesMatchForTesting(
        actual: [NodeSyncMessage],
        expected: [NodeSyncMessage]
    ) -> Bool {
        guard actual.count == expected.count,
              zip(actual, expected).allSatisfy({ actualMessage, expectedMessage in
                  actualMessage.attachments.count == expectedMessage.attachments.count &&
                      actualMessage.attachments.allSatisfy { !$0.id.isEmpty } &&
                      expectedMessage.attachments.allSatisfy { !$0.id.isEmpty }
              }) else { return false }
        return actual.map(imapMessageWithCanonicalAttachmentIDsForReplacement) ==
            expected.map(imapMessageWithCanonicalAttachmentIDsForReplacement)
    }

    private static func imapMessageWithCanonicalAttachmentIDsForReplacement(_ message: NodeSyncMessage) -> NodeSyncMessage {
        NodeSyncMessage(
            attachments: message.attachments.map { attachment in
                NodeSyncAttachment(
                    contentDigest: attachment.contentDigest,
                    contentID: attachment.contentID,
                    disposition: attachment.disposition,
                    filename: attachment.filename,
                    id: "replacement-opaque-capability",
                    mime: attachment.mime,
                    size: attachment.size
                )
            },
            bcc: message.bcc,
            cc: message.cc,
            flags: message.flags,
            from: message.from,
            htmlBody: message.htmlBody,
            id: message.id,
            inReplyTo: message.inReplyTo,
            labels: message.labels,
            receivedAt: message.receivedAt,
            references: message.references,
            replyTo: message.replyTo,
            sentAt: message.sentAt,
            subject: message.subject,
            textBody: message.textBody,
            threadID: message.threadID,
            to: message.to
        )
    }

    /// UIDVALIDITY replacement rotates provider identities, but must preserve
    /// every visible message field. Only the provider/message/thread and
    /// opaque attachment capability identities are intentionally ignored.
    static func imapUIDValidityReplacementMatchesForTesting(
        actual: NodeSyncSnapshotPage,
        previous: NodeSyncSnapshotPage,
        currentRevision: String,
        expectedMessageIDs: Set<String>? = nil
    ) -> Bool {
        imapUIDValidityReplacementMismatchClassForTesting(
            actual: actual,
            previous: previous,
            currentRevision: currentRevision,
            expectedMessageIDs: expectedMessageIDs
        ) == "matched"
    }

    /// Returns only a fixed diagnostic class so a failed live wait can be
    /// distinguished without exposing provider or projected identifiers.
    static func imapUIDValidityReplacementMismatchClassForTesting(
        actual: NodeSyncSnapshotPage,
        previous: NodeSyncSnapshotPage,
        currentRevision: String,
        expectedMessageIDs: Set<String>? = nil
    ) -> String {
        let previousIDs = Set(previous.messages.map(\.id))
        let actualIDs = Set(actual.messages.map(\.id))
        guard !currentRevision.isEmpty,
              actual.revision != currentRevision,
              actual.nextCursor.isEmpty,
              actual.messages.count == previous.messages.count,
              previousIDs.count == previous.messages.count,
              actualIDs.count == actual.messages.count,
              actual.messages.allSatisfy({ !$0.id.isEmpty && !$0.threadID.isEmpty }),
              previous.messages.allSatisfy({ !$0.id.isEmpty && !$0.threadID.isEmpty }),
              previousIDs.isDisjoint(with: actualIDs) else {
            return "envelope-or-unrotated-identity"
        }
        if let expectedMessageIDs, expectedMessageIDs != actualIDs {
            return "identity-vector"
        }
        let canonicalize: (NodeSyncMessage) -> NodeSyncMessage = { message in
            NodeSyncMessage(
                attachments: message.attachments.map { attachment in
                    NodeSyncAttachment(
                        contentDigest: attachment.contentDigest,
                        contentID: attachment.contentID,
                        disposition: attachment.disposition,
                        filename: attachment.filename,
                        id: "replacement-opaque-capability",
                        mime: attachment.mime,
                        size: attachment.size
                    )
                },
                bcc: message.bcc, cc: message.cc, flags: message.flags, from: message.from,
                htmlBody: message.htmlBody, id: "replacement-message-id", inReplyTo: message.inReplyTo,
                labels: message.labels, receivedAt: message.receivedAt, references: message.references,
                replyTo: message.replyTo, sentAt: message.sentAt, subject: message.subject,
                textBody: message.textBody, threadID: "replacement-thread-id", to: message.to
            )
        }
        let canonicalActual = actual.messages.map(canonicalize).sorted { $0.subject < $1.subject }
        let canonicalPrevious = previous.messages.map(canonicalize).sorted { $0.subject < $1.subject }
        return canonicalActual == canonicalPrevious ? "matched" : "stable-content"
    }

    /// Classifies a stable-content mismatch without returning any message
    /// values. The order is deterministic and only used for bounded failure
    /// diagnostics; matching remains the strict canonical comparison above.
    static func imapUIDValidityStableContentMismatchClassForTesting(
        actual: NodeSyncSnapshotPage,
        previous: NodeSyncSnapshotPage
    ) -> String {
        let current = actual.messages.sorted { $0.subject < $1.subject }
        let prior = previous.messages.sorted { $0.subject < $1.subject }
        guard current.count == prior.count else { return "envelope" }
        func attachmentsMatch(_ left: [NodeSyncAttachment], _ right: [NodeSyncAttachment]) -> Bool {
            left.count == right.count && zip(left, right).allSatisfy { currentAttachment, priorAttachment in
                currentAttachment.contentDigest == priorAttachment.contentDigest &&
                    currentAttachment.contentID == priorAttachment.contentID &&
                    currentAttachment.disposition == priorAttachment.disposition &&
                    currentAttachment.filename == priorAttachment.filename &&
                    currentAttachment.mime == priorAttachment.mime &&
                    currentAttachment.size == priorAttachment.size
            }
        }
        for (currentMessage, priorMessage) in zip(current, prior) {
            guard currentMessage.subject == priorMessage.subject else { return "headers" }
            if !attachmentsMatch(currentMessage.attachments, priorMessage.attachments) {
                return "attachments"
            }
            if currentMessage.flags != priorMessage.flags || currentMessage.labels != priorMessage.labels {
                return "flags-labels"
            }
            if currentMessage.from != priorMessage.from || currentMessage.to != priorMessage.to ||
                currentMessage.cc != priorMessage.cc || currentMessage.bcc != priorMessage.bcc ||
                currentMessage.replyTo != priorMessage.replyTo {
                return "addresses"
            }
            if currentMessage.receivedAt != priorMessage.receivedAt || currentMessage.sentAt != priorMessage.sentAt {
                return "timestamps"
            }
            if currentMessage.textBody != priorMessage.textBody || currentMessage.htmlBody != priorMessage.htmlBody {
                return "bodies"
            }
            if currentMessage.inReplyTo != priorMessage.inReplyTo || currentMessage.references != priorMessage.references {
                return "headers"
            }
        }
        return "unknown"
    }

    static func imapUIDValidityMismatchClassShouldEmitForTesting(
        previous: String?,
        current: String
    ) -> Bool {
        current != "matched" && previous != current
    }

    /// Classifies the concurrent IMAP postcondition in a fixed order. The
    /// matcher intentionally inspects real message content but returns only a
    /// closed category, so a timeout can explain the failed invariant without
    /// exposing message or provider values.
    static func imapConcurrentMutationMismatchClassForTesting(
        actual: NodeSyncSnapshotPage,
        previous: NodeSyncSnapshotPage,
        currentRevision: String,
        readMessageID: String,
        archiveMessageID: String,
        deleteMessageID: String,
        archiveSubject: String,
        archiveTextBody: NodeSyncBody,
        deleteSubject: String,
        deleteTextBody: NodeSyncBody
    ) -> String {
        guard !currentRevision.isEmpty, actual.revision != currentRevision else { return "revision" }
        guard actual.messages.count == previous.messages.count else { return "count" }
        let actualIDs = actual.messages.map(\.id)
        guard Set(actualIDs).count == actualIDs.count else { return "duplicate-ids" }
        guard Set([readMessageID, archiveMessageID, deleteMessageID]).count == 3 else {
            return "target-collision"
        }
        guard let projectedRead = actual.messages.first(where: { $0.id == readMessageID }) else {
            return "read-missing"
        }
        func isArchiveReplacement(_ message: NodeSyncMessage) -> Bool {
            message.id != archiveMessageID && message.subject == archiveSubject &&
                message.textBody == archiveTextBody &&
                (message.labels.contains("ARCHIVE") || message.labels.contains("ALL")) &&
                !message.labels.contains("INBOX")
        }
        func isDeleteReplacement(_ message: NodeSyncMessage) -> Bool {
            message.id != deleteMessageID && message.subject == deleteSubject &&
                message.textBody == deleteTextBody && message.labels.contains("TRASH") &&
                !message.labels.contains("INBOX")
        }
        guard let projectedArchive = actual.messages.first(where: isArchiveReplacement) else {
            return "archive-missing"
        }
        guard let projectedDelete = actual.messages.first(where: isDeleteReplacement) else {
            return "delete-missing"
        }
        if actual.messages.contains(where: { $0.id == archiveMessageID }) { return "old-archive-present" }
        if actual.messages.contains(where: { $0.id == deleteMessageID }) { return "old-delete-present" }
        guard Set([projectedRead.id, projectedArchive.id, projectedDelete.id]).count == 3 else {
            return "target-collision"
        }
        guard imapMessageIsSeenForTesting(flags: projectedRead.flags) else { return "seen-missing" }
        guard projectedRead.labels.contains("FLAGGED") else { return "flagged-missing" }
        return "matched"
    }

    /// Selects two mutation targets without relying on snapshot positions.
    /// The read target is excluded and every input identity must be unique so
    /// a reordered provider page cannot make two operations address one mail.
    static func imapConcurrentMutationTargetsForTesting(
        messages: [NodeSyncMessage],
        readMessageID: String
    ) -> (read: NodeSyncMessage, archive: NodeSyncMessage, delete: NodeSyncMessage)? {
        guard !readMessageID.isEmpty,
              messages.allSatisfy({ !$0.id.isEmpty }),
              Set(messages.map(\.id)).count == messages.count,
              let read = messages.first(where: { $0.id == readMessageID }) else {
            return nil
        }
        let candidates = messages.filter { $0.id != readMessageID }
        guard candidates.count >= 2 else { return nil }
        return (read: read, archive: candidates[0], delete: candidates[1])
    }

    static func imapConcurrentMutationMismatchClassShouldEmitForTesting(
        previous: String?,
        current: String
    ) -> Bool {
        current != "matched" && previous != current
    }

    static func imapMIMEProjectionMatchesForTesting(
        _ messages: [NodeSyncMessage],
        fixtureDigest: String
    ) -> Bool {
        guard messages.count == 2,
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ !$0.id.isEmpty && !$0.threadID.isEmpty && $0.labels == ["INBOX"] }),
              let acceptance = messages.first(where: { $0.subject == "Plainpost acceptance é" }),
              let continuation = messages.first(where: { $0.subject == "Plainpost continuation" }),
              acceptance.textBody == NodeSyncBody(state: .complete, value: "Unicode acceptance body"),
              acceptance.htmlBody == NodeSyncBody(state: .complete, value: "<p>Related HTML</p>"),
              continuation.textBody == NodeSyncBody(state: .complete, value: "Continuation body"),
              continuation.htmlBody == NodeSyncBody(state: .absent, value: nil),
              acceptance.replyTo.isEmpty,
              continuation.attachments.isEmpty,
              acceptance.attachments.count == 5 else {
            return false
        }
        func matches(_ attachment: NodeSyncAttachment, filename: String, mime: String, disposition: String, size: String, digest: String, contentID: String? = nil) -> Bool {
            attachment.filename == filename && attachment.mime == mime && attachment.disposition == disposition &&
                attachment.size == size && attachment.contentDigest == digest && attachment.contentID == contentID && !attachment.id.isEmpty
        }
        let byName = Dictionary(uniqueKeysWithValues: acceptance.attachments.map { ($0.filename, $0) })
        guard byName.count == 5,
              let logo = byName["logo.png"], let cafe = byName["café.txt"],
              let empty = byName["empty.bin"], let malicious = byName[".._.._secret.txt"],
              let fixture = byName["fixture.bin"],
              matches(logo, filename: "logo.png", mime: "image/png", disposition: "inline", size: "4", digest: "D0Y2x49l02OezloGS1rnU-NAhhShT7GKtNdUDSwkhUM", contentID: "logo@example.test"),
              matches(cafe, filename: "café.txt", mime: "text/plain", disposition: "attachment", size: "4", digest: "2v1mwLmJZeaIvh_BKULAnwNQ5r4GhQF8PyNOl9CtyS4"),
              matches(empty, filename: "empty.bin", mime: "application/octet-stream", disposition: "attachment", size: "0", digest: "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"),
              matches(malicious, filename: ".._.._secret.txt", mime: "application/octet-stream", disposition: "attachment", size: "4", digest: "tcH7Lvxta0Z0wv3MSM4BtDo7fAN2PAwzVd4Ame4PjHM"),
              matches(fixture, filename: "fixture.bin", mime: "application/octet-stream", disposition: "attachment", size: "262144", digest: fixtureDigest) else {
            return false
        }
        return true
    }

    static func imapAttachmentRecoveryProjectionMatchesForTesting(
        _ messages: [NodeSyncMessage],
        fixtureDigest: String
    ) -> Bool {
        imapAcceptanceFixtureShapeMatches(messages, expectedAttachmentDigest: fixtureDigest)
    }

    static func imapSnapshotMatchesExpectedSetForTesting(
        _ page: NodeSyncSnapshotPage,
        expectedMessages: [NodeSyncMessage],
        expectedRevision: String?
    ) -> Bool {
        guard imapSnapshotMatchesExpectedForTesting(
            page,
            expectedMessages: nil,
            expectedRevision: expectedRevision,
            requireAcceptanceFixtureShape: false
        ) else { return false }
        let actual = page.messages.sorted { $0.id < $1.id }
        let expected = expectedMessages.sorted { $0.id < $1.id }
        return actual.count == expected.count &&
            Set(actual.map(\.id)).count == actual.count &&
            Set(expected.map(\.id)).count == expected.count &&
            actual == expected
    }

    static func imapExpungeProjectionMatchesForTesting(
        _ page: NodeSyncSnapshotPage,
        baselineMessages: [NodeSyncMessage],
        deletedMessage: NodeSyncMessage,
        currentRevision: String
    ) -> Bool {
        let expectedInbox = baselineMessages.filter { $0.id != deletedMessage.id }
        let inbox = page.messages.filter { $0.labels.contains("INBOX") && !$0.labels.contains("TRASH") }
        let trash = page.messages.filter { $0.labels.contains("TRASH") && !$0.labels.contains("INBOX") }
        let baselineIDs = Set(baselineMessages.map(\.id))
        guard !currentRevision.isEmpty,
              page.revision != currentRevision,
              page.nextCursor.isEmpty,
              baselineIDs.count == baselineMessages.count,
              baselineMessages.contains(where: { $0.id == deletedMessage.id }),
              page.messages.count == expectedInbox.count + 1,
              Set(page.messages.map(\.id)).count == page.messages.count,
              inbox.count == expectedInbox.count,
              Set(inbox.map(\.id)) == Set(expectedInbox.map(\.id)),
              inbox.sorted(by: { $0.id < $1.id }) == expectedInbox.sorted(by: { $0.id < $1.id }),
              trash.count == 1,
              trash[0].id != deletedMessage.id,
              !baselineIDs.contains(trash[0].id),
              !page.messages.contains(where: { $0.id == deletedMessage.id }),
              imapExpungeMessageContentMatchesForTesting(trash[0], deletedMessage) else {
            return false
        }
        return true
    }

    private static func imapExpungeMessageContentMatchesForTesting(
        _ copy: NodeSyncMessage,
        _ source: NodeSyncMessage
    ) -> Bool {
        guard copy.subject == source.subject,
              copy.textBody == source.textBody,
              copy.htmlBody == source.htmlBody,
              copy.from == source.from,
              copy.to == source.to,
              copy.cc == source.cc,
              copy.bcc == source.bcc,
              copy.replyTo == source.replyTo,
              copy.inReplyTo == source.inReplyTo,
              copy.references == source.references,
              copy.receivedAt == source.receivedAt,
              copy.sentAt == source.sentAt,
              copy.flags == source.flags,
              copy.attachments.count == source.attachments.count else {
            return false
        }
        return zip(copy.attachments, source.attachments).allSatisfy { copyAttachment, sourceAttachment in
            copyAttachment.contentDigest == sourceAttachment.contentDigest &&
                copyAttachment.contentID == sourceAttachment.contentID &&
                copyAttachment.disposition == sourceAttachment.disposition &&
                copyAttachment.filename == sourceAttachment.filename &&
                copyAttachment.mime == sourceAttachment.mime &&
                copyAttachment.size == sourceAttachment.size
        }
    }

    static func imapMatrixTransitionMessageMatchesForTesting(_ message: NodeSyncMessage) -> Bool {
        !message.id.isEmpty && !message.threadID.isEmpty &&
            message.subject == "IMAP matrix transition" &&
            message.textBody == NodeSyncBody(state: .complete, value: "IMAP matrix transition body") &&
            message.htmlBody == NodeSyncBody(state: .absent, value: nil) &&
            message.flags.isEmpty && message.labels == ["INBOX"] &&
            message.from.map(\.mailbox) == ["acceptance@example.test"] &&
            message.to.map(\.mailbox) == ["recipient@example.test"] &&
            message.cc.isEmpty && message.bcc.isEmpty && message.replyTo.isEmpty &&
            message.inReplyTo.isEmpty && message.references.isEmpty && message.attachments.isEmpty
    }

    /// A provider append may share a delta revision with explicitly metadata-only
    /// changes, but it must publish exactly one upsert for the appended message.
    /// Membership removals, tombstones, unrelated upserts, and duplicate target
    /// upserts are message-bearing effects and are not part of this transition.
    static func imapAppendDeltaShapeClassForTesting(
        _ page: NodeSyncDeltaPage,
        logicalMailboxID: LogicalMailboxID,
        messageID: String,
        threadID: String
    ) -> String {
        guard !page.nextCursor.isEmpty, !messageID.isEmpty, !threadID.isEmpty else {
            return "metadata-invalid"
        }
        var targetUpserts = 0
        for change in page.changes {
            switch change.kind {
            case "upsert":
                guard change.logicalMailboxID == logicalMailboxID,
                      change.messageID == messageID,
                      change.threadID == threadID else {
                    return "unrelated-upsert"
                }
                targetUpserts += 1
            case "membership_removed":
                return "membership-removed"
            case "tombstoned":
                return "tombstoned"
            case "epoch_reset", "baseline_complete":
                guard change.messageID == nil, change.threadID == nil else {
                    return "metadata-invalid"
                }
            default:
                return "metadata-invalid"
            }
        }
        switch targetUpserts {
        case 0: return "target-upsert-zero"
        case 1: return "matched"
        default: return "target-upsert-duplicate"
        }
    }

    static func imapAppendDeltaSequenceShapeClassForTesting(
        _ pages: [NodeSyncDeltaPage],
        logicalMailboxID: LogicalMailboxID,
        baselineMessageIDs: [String: String],
        messageID: String,
        threadID: String
    ) -> String {
        guard !pages.isEmpty, !messageID.isEmpty, !threadID.isEmpty else {
            return "metadata-invalid"
        }
        var targetUpserts = 0
        var baselineUpserts: [String: Int] = [:]
        for page in pages {
            guard !page.nextCursor.isEmpty else { return "metadata-invalid" }
            for change in page.changes {
                switch change.kind {
                case "upsert":
                    guard change.logicalMailboxID == logicalMailboxID,
                          let changeMessageID = change.messageID,
                          let changeThreadID = change.threadID else {
                        return "unrelated-upsert"
                    }
                    if changeMessageID == messageID {
                        guard changeThreadID == threadID else { return "unrelated-upsert" }
                        targetUpserts += 1
                    } else if baselineMessageIDs[changeMessageID] == changeThreadID {
                        baselineUpserts[changeMessageID, default: 0] += 1
                        if baselineUpserts[changeMessageID, default: 0] > 1 {
                            return "baseline-upsert-duplicate"
                        }
                    } else {
                        return "unrelated-upsert"
                    }
                case "membership_removed":
                    return "membership-removed"
                case "tombstoned":
                    return "tombstoned"
                case "epoch_reset", "baseline_complete":
                    guard change.messageID == nil, change.threadID == nil else {
                        return "metadata-invalid"
                    }
                default:
                    return "metadata-invalid"
                }
            }
        }
        switch targetUpserts {
        case 0: return "target-upsert-zero"
        case 1: return "matched"
        default: return "target-upsert-duplicate"
        }
    }

    static func imapAppendDeltaMatchesForTesting(
        _ page: NodeSyncDeltaPage,
        logicalMailboxID: LogicalMailboxID,
        messageID: String,
        threadID: String
    ) -> Bool {
        imapAppendDeltaShapeClassForTesting(
            page,
            logicalMailboxID: logicalMailboxID,
            messageID: messageID,
            threadID: threadID
        ) == "matched"
    }

    static func imapUIDGapFixtureShapeMatchesForTesting(_ messages: [NodeSyncMessage]) -> Bool {
        let stableVisibleFields = messages.map { ($0.subject, $0.textBody) }.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }
        guard stableVisibleFields.map(\.0) == ["UID gap four", "UID gap nine", "UID gap one"],
              stableVisibleFields.map(\.1) == [
                  NodeSyncBody(state: .complete, value: "four"),
                  NodeSyncBody(state: .complete, value: "nine"),
                  NodeSyncBody(state: .complete, value: "one"),
              ],
              messages.count == 3,
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({
                  !$0.id.isEmpty && !$0.threadID.isEmpty && !$0.receivedAt.isEmpty &&
                      $0.flags.isEmpty && $0.labels == ["INBOX"] &&
                      $0.from.isEmpty && $0.to.isEmpty && $0.cc.isEmpty && $0.bcc.isEmpty &&
                      $0.replyTo.isEmpty && $0.inReplyTo.isEmpty && $0.references.isEmpty &&
                      $0.htmlBody == NodeSyncBody(state: .absent, value: nil) && $0.attachments.isEmpty
              }) else { return false }
        return true
    }

    static func imapGenericMessageIdentityForTesting(
        logicalMailboxID: LogicalMailboxID,
        uid: String,
        providerMailboxID: String = "INBOX",
        providerEpoch: UInt64 = 1
    ) -> String {
        var canonical = Data("plainpost.generic.imap.message.v1\0".utf8)
        canonical.append(contentsOf: logicalMailboxID.rawValue.map { String(format: "%02x", $0) }.joined().utf8)
        canonical.append(0)
        canonical.append(contentsOf: providerMailboxID.utf8)
        canonical.append(0)
        canonical.append(contentsOf: String(providerEpoch).utf8)
        canonical.append(0)
        canonical.append(contentsOf: uid.utf8)
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    static func imapAcceptanceFixtureShapeMatchesForTesting(
        _ messages: [NodeSyncMessage],
        expectedAttachmentDigest: String? = nil
    ) -> Bool {
        imapAcceptanceFixtureShapeMatches(messages, expectedAttachmentDigest: expectedAttachmentDigest)
    }

    private static func imapAcceptanceFixtureShapeMatches(
        _ messages: [NodeSyncMessage],
        expectedAttachmentDigest: String? = nil
    ) -> Bool {
        guard messages.count == 2,
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ !$0.id.isEmpty && !$0.threadID.isEmpty && !$0.receivedAt.isEmpty }),
              messages.allSatisfy({
                  $0.flags.isEmpty && $0.labels == ["INBOX"] &&
                      $0.from.map(\.mailbox) == ["acceptance@example.test"] &&
                      $0.to.map(\.mailbox) == ["recipient@example.test"] &&
                      $0.cc.isEmpty && $0.bcc.isEmpty && $0.replyTo.isEmpty &&
                      $0.inReplyTo.isEmpty && $0.references.isEmpty
              }) else { return false }
        let bySubject = Dictionary(uniqueKeysWithValues: messages.map { ($0.subject, $0) })
        guard let acceptance = bySubject["Plainpost acceptance é"],
              let continuation = bySubject["Plainpost continuation"],
              bySubject.count == messages.count,
              acceptance.textBody == NodeSyncBody(state: .complete, value: "Unicode acceptance body"),
              continuation.textBody == NodeSyncBody(state: .complete, value: "Continuation body"),
              acceptance.htmlBody == NodeSyncBody(state: .complete, value: "<p>Unicode <strong>acceptance</strong> body</p>"),
              continuation.htmlBody == NodeSyncBody(state: .absent, value: nil),
              acceptance.attachments.count == 1,
              acceptance.attachments[0].filename == "fixture.bin",
              acceptance.attachments[0].mime == "application/octet-stream",
              acceptance.attachments[0].disposition == "attachment",
              acceptance.attachments[0].size == "262144",
              acceptance.attachments[0].contentDigest == expectedAttachmentDigest,
              continuation.attachments.isEmpty else { return false }
        return true
    }

    static func imapMatrixSnapshotMaySucceedForTesting(selector: String) -> Bool {
        guard imapMatrixCases.contains(where: { $0.selector == selector }) else { return false }
        return !imapMatrixInitialSnapshotMustFailForTesting(selector: selector)
    }

    static func imapMatrixInitialSnapshotMustFailForTesting(selector: String) -> Bool {
        if selector == "imap-authentication" {
            return false
        }
        return imapMatrixExpectedInitialFaultClassForTesting(selector: selector) != nil
    }

    static func imapMatrixExpectedInitialFaultClassForTesting(selector: String) -> IMAPMatrixExpectedFaultClass? {
        switch selector {
        case "imap-authentication": return .authentication
        default: return nil
        }
    }

    static func imapMatrixExpectedAttachmentFaultClassForTesting(selector: String) -> IMAPMatrixAttachmentFaultClass? {
        switch selector {
        case "imap-attachment-fetch": return .disconnect
        case "imap-truncated-literal": return .truncated
        default: return nil
        }
    }

    /// The fault assertion must inspect the Node transport result before the
    /// mail-authority adapter intentionally maps it to PlainpostError.
    static func imapMatrixAttachmentFaultErrorIsExpectedForTesting(_ error: Error) -> Bool {
        ["transport", "unavailable", "transport-after-dispatch"].contains(
            imapMatrixAttachmentFaultErrorClassForTesting(error)
        )
    }

    static func imapMatrixAttachmentFaultErrorClassForTesting(_ error: Error) -> String {
        guard let transportError = error as? NodeSyncClientError else { return "other" }
        switch transportError {
        case .transport: return "transport"
        case .problem(.unavailable): return "unavailable"
        case .transportAfterDispatch: return "transport-after-dispatch"
        default: return "other"
        }
    }

    /// The dedicated one-attempt probe exposes the two closed boundaries for a
    /// malformed literal: the provider may reject it as unavailable, or the
    /// streaming client may reject the declared Content-Length at EOF.
    /// Unrelated transport errors remain terminal failures.
    static func imapMatrixTruncatedLiteralErrorIsExpectedForTesting(_ error: Error) -> Bool {
        guard let transportError = error as? NodeSyncClientError else { return false }
        switch transportError {
        case .problem(.unavailable), .invalidResponse:
            return true
        default:
            return false
        }
    }

    static func imapMatrixTruncatedLiteralErrorClassForTesting(_ error: Error) -> String {
        guard let transportError = error as? NodeSyncClientError else { return "other" }
        switch transportError {
        case .problem(.unavailable):
            return "unavailable"
        case .invalidResponse:
            return "invalid-response"
        default:
            return "other"
        }
    }

    static func imapMatrixAttachmentFaultRequiresRecoveryForTesting(selector: String) -> Bool {
        selector == "imap-attachment-fetch"
    }

    static func imapMatrixRequiresDedicatedAttachmentFaultProbeForTesting(selector: String) -> Bool {
        ["imap-attachment-fetch", "imap-truncated-literal"].contains(selector)
    }

    static func imapMatrixExpectedAttachmentDigestForTesting(_ bytes: Data) -> String {
        NodeSessionWire.encodeBase64URL(Data(SHA256.hash(data: bytes)))
    }

    static func imapMatrixOwnsAttachmentBarrierForTesting(selector: String) -> Bool {
        imapMatrixExpectedAttachmentFaultClassForTesting(selector: selector) != nil || selector == "imap-mime-boundaries"
    }

    static func imapMatrixRequiresCompleteProjectionRecoveryForTesting(selector: String) -> Bool {
        ["imap-header-fetch", "imap-body-fetch"].contains(selector)
    }

    static func imapMatrixUsesDedicatedCatalogProbeForTesting(selector: String) -> Bool {
        selector == "imap-catalog"
    }

    static func imapMatrixUsesDedicatedFetchProbeForTesting(selector: String) -> Bool {
        ["imap-header-fetch", "imap-body-fetch"].contains(selector)
    }

    static func imapMatrixUsesDedicatedDelayedLiteralProbeForTesting(selector: String) -> Bool {
        selector == "imap-delayed-literal"
    }

    static func imapMatrixUsesIdleBarrierForTesting(selector: String) -> Bool {
        selector == "imap-provider-restart-mid-page"
    }

    static func imapMatrixUsesNodeTwoLifecycleForTesting(selector: String) -> Bool {
        imapMatrixCases.contains { $0.selector == selector }
    }

    static func imapMatrixControlActionAllowedForTesting(action: String) -> Bool {
        controlFileName(action: action, phase: "request") != nil
    }

    static func readIMAPProviderRestartOccurrenceForTesting(_ root: URL) throws -> Int {
        try readIMAPProviderRestartOccurrence(root)
    }

    static func imapMatrixInitialPhaseBarrierForTesting(selector: String) -> Bool {
        guard let matrixCase = imapMatrixCases.first(where: { $0.selector == selector }),
              matrixCase.phase != "none" else { return false }
        // These cases own their phase barrier after the initial snapshot: the
        // generic snapshot task must not wait for a phase emitted by work that
        // has not been started yet.
        return !imapMatrixOwnsAttachmentBarrierForTesting(selector: selector)
            && selector != "imap-node-restart-before-ack"
    }

    private static let imapMatrixRecoveryAttempts = 60

    // Keep this aligned with the production sync runtime's zero-option
    // defaultPollDeadline (one minute). The fixture shares one session across
    // all six seeded mailboxes, so acceptance waits are derived from a full
    // six-mailbox cycle rather than the runtime's minimum bound. The
    // readiness bound adds the shell harness's scheduling margin and one
    // final production poll deadline: 6 * 60 + 15 + 60 = 435 seconds. This
    // is an acceptance observation budget, not a production timeout change.
    private static let genericProviderPollIntervalSeconds = 60
    private static let acceptanceFixtureMailboxCount = 6
    private static let acceptanceSnapshotPageLimit = acceptanceFixtureMailboxCount * 4
    private static let providerTransitionSchedulingMarginSeconds = 15
    private static let acceptanceProviderReadinessTimeoutSeconds =
        genericProviderPollIntervalSeconds * acceptanceFixtureMailboxCount + providerTransitionSchedulingMarginSeconds + genericProviderPollIntervalSeconds
    private static let acceptanceProviderTransitionPollDelayMilliseconds = 250
    private static let acceptanceProviderTransitionPollAttempts =
        ((genericProviderPollIntervalSeconds * acceptanceFixtureMailboxCount + providerTransitionSchedulingMarginSeconds) * 1000 / acceptanceProviderTransitionPollDelayMilliseconds)
    private static let acceptanceControlSignalPollAttempts = acceptanceProviderTransitionPollAttempts

    static func run(authority: PlainpostNodeMailAuthority, secondaryAuthority: PlainpostNodeMailAuthority? = nil, client: NodeSyncClient, secondaryClient: NodeSyncClient? = nil, attachmentFaultProbeClient: NodeSyncClient? = nil, controlRoot: URL, responseClassifier: AcceptanceResponseClassifier? = nil, authorityReplacement: AuthorityReplacement? = nil) async throws {
        let configuredDrops = Set((ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_DROP_RESPONSES"] ?? "").split(separator: ",").compactMap { token in
            token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1).first.map(String.init)
        })
        guard configuredDrops.contains("status") else {
            XCTFail("acceptance must exercise the real Node status response-drop recovery")
            throw NodeSyncClientError.invalidResponse
        }
        stage("status-initial-begin")
        stage("response-drop-status-begin")
        let nativeStatusResult = try await statusWithPostDispatchRecovery(label: "status", client: client) {
            try await authority.status()
        }
        XCTAssertTrue(nativeStatusResult.recovered, "the acceptance status GET must cross the response-drop injector")
        stage("response-drop-status-replay-end")
        let nativeStatus = nativeStatusResult.value
        guard let initialProviderIdentity = nativeStatus.providerIdentity,
              !initialProviderIdentity.isEmpty else {
            throw NodeSyncClientError.invalidResponse
        }
        let status = try await client.status()
        stage("status-initial-end")
        XCTAssertFalse(nativeStatus.version.isEmpty)
        XCTAssertEqual(nativeStatus.version, status.version, "the native authority and protocol client must observe the same Node")

        // IMAP matrix cases own their provider operation from the first
        // snapshot onward. Running the ordinary bootstrap first would
        // consume catalog/header/body faults before the selector's barrier
        // could observe them.
        if let matrixCase = try imapMatrixCaseFromEnvironment() {
            try await runIMAPMatrixCase(
                matrixCase,
                initialMessages: [],
                authority: authority,
                secondaryAuthority: secondaryAuthority,
                client: client,
                secondaryClient: secondaryClient,
                attachmentFaultProbeClient: attachmentFaultProbeClient,
                controlRoot: controlRoot,
                authorityReplacement: authorityReplacement
            )
            return
        }

        stage("snapshot-initial-begin")
        let first = try await waitForInitialSnapshot(client: client, responseClassifier: responseClassifier)
        stage("snapshot-initial-end")
        XCTAssertFalse(first.messages.isEmpty, "the real provider owner must publish an initial snapshot")
        stage("native-authority-snapshot-begin")
        let nativeSnapshot = try await authority.snapshots.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
        stage("native-authority-snapshot-end")
        XCTAssertEqual(nativeSnapshot.messages.first?.id.rawValue, first.messages.first?.id, "the production authority must map the same authenticated Node snapshot")
        var initialMessages = first.messages
        var snapshotCursor = first.nextCursor
        var snapshotPageCount = 0
        if !first.nextCursor.isEmpty {
            while !snapshotCursor.isEmpty && snapshotPageCount < acceptanceSnapshotPageLimit {
                stage("snapshot-page-begin")
                let page = try await client.snapshot(after: snapshotCursor, limit: 2)
                stage("snapshot-page-end")
                XCTAssertTrue(Set(initialMessages.map(\.id).filter { !$0.isEmpty }).isDisjoint(with: page.messages.map(\.id)))
                initialMessages.append(contentsOf: page.messages)
                snapshotCursor = page.nextCursor
                snapshotPageCount += 1
            }
            XCTAssertTrue(snapshotCursor.isEmpty, "initial snapshot continuation exceeded its bounded page budget")
        }

        var secondaryBootstrap: NodeSyncDeltaPage?
        if let secondaryClient {
            guard let secondaryAuthority else { throw NodeSyncClientError.invalidResponse }
            let secondaryNativeStatus = try await secondaryAuthority.status()
            XCTAssertFalse(secondaryNativeStatus.version.isEmpty)
            stage("secondary-snapshot-begin")
            let secondaryFirst = try await waitForInitialSnapshot(client: secondaryClient, responseClassifier: responseClassifier)
            stage("secondary-snapshot-end")
            XCTAssertFalse(secondaryFirst.messages.isEmpty, "the independently admitted client must see the initial snapshot")
            XCTAssertEqual(secondaryFirst.messages.first?.id, first.messages.first?.id)
            if !secondaryFirst.nextCursor.isEmpty {
                stage("secondary-snapshot-page-begin")
                let secondaryPage = try await secondaryClient.snapshot(after: secondaryFirst.nextCursor, limit: 2)
                stage("secondary-snapshot-page-end")
                XCTAssertTrue(Set(secondaryFirst.messages.map(\.id)).isDisjoint(with: secondaryPage.messages.map(\.id)))
            }
            stage("secondary-delta-bootstrap-begin")
            let page = try await secondaryClient.delta(limit: 2)
            stage("secondary-delta-bootstrap-end")
            XCTAssertTrue(page.changes.isEmpty, "the secondary cursor must bootstrap independently")
            secondaryBootstrap = page
        }

        stage("assignments-begin")
        let assignments = try await client.mailboxAssignments().assignments
        stage("assignments-end")
        guard let logical = assignments.compactMap(\.logicalMailboxID).first else {
            throw NodeSyncClientError.invalidResponse
        }
        let selections = assignments.compactMap { assignment -> SyncNodeMailboxSelection? in
            guard let logicalMailboxID = assignment.logicalMailboxID else { return nil }
            return SyncNodeMailboxSelection(displayName: assignment.displayName, mailboxHandle: assignment.mailboxHandle, role: assignment.role, logicalMailboxID: logicalMailboxID)
        }
        XCTAssertEqual(selections.count, assignments.count, "every accepted assignment must carry its authenticated logical mailbox")
        stage("assignment-provider-readiness-begin")
        _ = try await authority.providerController.waitForTrustedProviderStatus(
            timeout: .seconds(Self.acceptanceProviderReadinessTimeoutSeconds),
            expectedProviderIdentity: initialProviderIdentity,
            matching: { status in
                Self.status(status, matches: selections, providerIdentity: initialProviderIdentity)
            }
        )
        stage("assignment-provider-readiness-end")
        stage("delta-bootstrap-begin")
        let bootstrap = try await client.delta(limit: 2)
        stage("delta-bootstrap-end")
        XCTAssertTrue(bootstrap.changes.isEmpty, "delta bootstrap must not synthesize provider state")
        if let matrixCase = try smtpMatrixCaseFromEnvironment() {
            try await runSMTPMatrixCase(
                matrixCase,
                authority: authority,
                secondaryAuthority: secondaryAuthority,
                client: client,
                secondaryClient: secondaryClient,
                logicalMailboxID: logical,
                controlRoot: controlRoot
            )
            return
        }
        stage("provider-transition-request-begin")
        try request(controlRoot, action: "provider-transition")
        stage("provider-transition-request-end")
        stage("provider-transition-wait-begin")
        try await wait(controlRoot, action: "provider-transition")
        stage("provider-transition-wait-end")
        stage("delta-transition-begin")
        let delta = try await waitForNonEmptyDelta(client: client, cursor: bootstrap.nextCursor, responseClassifier: responseClassifier)
        stage("delta-transition-end")
        XCTAssertFalse(delta.changes.isEmpty, "provider transition must create a real projection delta")
        if let secondaryClient, let secondaryBootstrap {
            stage("secondary-delta-transition-begin")
            let secondaryDelta = try await waitForNonEmptyDelta(client: secondaryClient, cursor: secondaryBootstrap.nextCursor, responseClassifier: responseClassifier)
            stage("secondary-delta-transition-end")
            XCTAssertFalse(secondaryDelta.changes.isEmpty)
            XCTAssertNotEqual(secondaryDelta.nextCursor, secondaryBootstrap.nextCursor, "secondary cursor must advance independently")
        }

        stage("unicode-search-begin")
        let logicalMailboxToken = try NodeSyncCodec.encodeLogicalMailboxID(logical)
        let unicodeRequest = MailSearchRequest(
            query: "é",
            scope: MailSearchSelectionScope(mailboxIDs: [MailboxID(logicalMailboxToken)]),
            mode: .messages,
            limit: 2
        )
        let unicode = try await authority.search.search(unicodeRequest)
        stage("unicode-search-end")
        XCTAssertFalse(unicode.hits.isEmpty, "Unicode search must reach the Node index")

        let attachmentCandidates = initialMessages
            .filter { $0.subject == "Plainpost acceptance é" && !$0.attachments.isEmpty }
            .sorted { $0.id < $1.id }
        stage("attachment-candidate-count=\(attachmentCandidates.count)-snapshot-pages=\(snapshotPageCount)")
        guard let message = attachmentCandidates.first else {
            XCTFail("the acceptance fixture must publish a multipart attachment in the complete initial snapshot")
            throw NodeSyncClientError.invalidResponse
        }
        stage("message-begin")
        let body = try await authority.messages.message(id: MessageID(message.id))
        stage("message-end")
        XCTAssertEqual(body.subject, message.subject)
        XCTAssertEqual(body.body, "Unicode acceptance body")
        XCTAssertEqual(body.bodyHTML, "<p>Unicode <strong>acceptance</strong> body</p>")
        XCTAssertFalse(body.bodyHTML?.contains("<script") == true, "fixture HTML must be sanitized and script-free")

        guard let attachment = message.attachments.first else {
            XCTFail("the acceptance fixture must publish a multipart attachment")
            throw NodeSyncClientError.invalidResponse
        }
        XCTAssertNil(attachment.contentDigest, "snapshot attachment metadata must remain unhydrated until authenticated fetch")
        stage("attachment-snapshot-digest=absent")
        stage("attachment-early-begin")
        let early = try await authority.attachments.attachment(id: attachment.id)
        stage("attachment-early-end")
        let earlyIterator = early.bytes.makeAsyncIterator()
        _ = try await earlyIterator.next()
        let activeStream = try FileManager.default.contentsOfDirectory(at: controlRoot, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension == "stream-active" }
        XCTAssertTrue(activeStream, "the early attachment stream must still own its transport before cancellation")
        stage("attachment-active-before-cancel=\(activeStream ? 1 : 0)")
        earlyIterator.cancel()
        stage("attachment-release-request-begin")
        try request(controlRoot, action: "attachment-release-probe")
        stage("attachment-release-request-end")
        stage("attachment-release-wait-begin")
        try await wait(controlRoot, action: "attachment-release-probe")
        stage("attachment-release-wait-end")
        stage("attachment-complete-begin")
        let complete = try await authority.attachments.attachment(id: attachment.id)
        stage("attachment-complete-open-end")
        stage("attachment-complete-drain-begin")
        var bytes = Data()
        var didObserveFirstByte = false
        for try await chunk in complete.bytes {
            if !didObserveFirstByte {
                didObserveFirstByte = true
                stage("attachment-complete-first-byte")
            }
            bytes.append(chunk)
        }
        stage("attachment-complete-drain-end")
        stage("attachment-complete-end")
        let hydratedAttachment = complete.metadata
        XCTAssertEqual(hydratedAttachment.id, attachment.id)
        XCTAssertEqual(hydratedAttachment.filename, attachment.filename)
        XCTAssertEqual(hydratedAttachment.mimeType, attachment.mime)
        guard let expectedAttachmentBytes = Int(attachment.size) else {
            XCTFail("the fixture attachment must publish a decimal size")
            throw NodeSyncClientError.invalidResponse
        }
        XCTAssertEqual(hydratedAttachment.byteCount, expectedAttachmentBytes)
        XCTAssertEqual(hydratedAttachment.disposition, attachment.disposition)
        XCTAssertEqual(bytes.count, hydratedAttachment.byteCount)
        guard let digest = hydratedAttachment.contentDigest else {
            XCTFail("the authenticated attachment response must publish a SHA-256 content digest")
            throw NodeSyncClientError.invalidResponse
        }
        XCTAssertEqual(NodeSessionWire.encodeBase64URL(Data(SHA256.hash(data: bytes))), digest)

        if ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_PRIVATE_TRANSPORT_RELEASE"] == "1" {
            try await verifyReleaseBackupRestore(
                authority: authority,
                attachmentID: attachment.id,
                controlRoot: controlRoot
            )
        }

        stage("read-apply-begin")
        let read = try await authority.mutations.perform(.setRead(messageIDs: [MessageID(message.id)], read: true))
        stage("read-apply-end")
        XCTAssertEqual(read.state, "applied")
        stage("read-verify-begin")
        let readMessage = try await waitForMessage(messages: authority.messages, id: MessageID(message.id)) { $0.isSeen }
        stage("read-verify-end")
        XCTAssertTrue(readMessage.isSeen)

        stage("label-apply-begin")
        let labelResult = try await authority.mutations.perform(
            .setLabels(messageIDs: [MessageID(message.id)], addLabelIDs: ["FLAGGED"], removeLabelIDs: [])
        )
        stage("label-apply-end")
        XCTAssertEqual(labelResult.state, "applied", "generic IMAP FLAGGED is the supported durable label operation")
        stage("label-verify-begin")
        let labeled = try await waitForMessage(messages: authority.messages, id: MessageID(message.id)) { $0.labels.contains("FLAGGED") }
        stage("label-verify-end")
        XCTAssertTrue(labeled.labels.contains("FLAGGED"))
        stage("label-replay-sign-begin")
        let labelOperation = try client.signMutation(
            variant: .setLabels(messageIDs: [message.id], addLabelIDs: ["FLAGGED"], removeLabelIDs: []),
            logicalMailboxID: logical,
            idempotencyKey: runUnique("live-label-replay")
        )
        stage("label-replay-sign-end")
        stage("label-replay-first-begin")
        let labelReplayFirst = try await authority.mutations.apply(canonicalOperation: labelOperation)
        stage("label-replay-first-end")
        stage("label-replay-second-begin")
        let labelReplaySecond = try await authority.mutations.apply(canonicalOperation: labelOperation)
        stage("label-replay-second-end")
        XCTAssertEqual(labelReplayFirst.state, "applied")
        XCTAssertEqual(labelReplayFirst, labelReplaySecond, "canonical label replay must retain the original applied result")

        stage("archive-apply-begin")
        let archiveResult = try await authority.mutations.perform(.archive(messageIDs: [MessageID(message.id)]))
        stage("archive-apply-end")
        XCTAssertEqual(archiveResult.state, "applied")
        stage("archive-verify-begin")
        let archived = try await waitForMailboxReplacement(snapshots: authority.snapshots, messages: authority.messages, original: body, requiredLabel: "ARCHIVE", alternateLabel: "ALL")
        stage("archive-verify-end")
        XCTAssertNotEqual(archived.id.rawValue, message.id)
        XCTAssertTrue(archived.labels.contains("ARCHIVE") || archived.labels.contains("ALL"))

        stage("delete-apply-begin")
        let deleteResult = try await authority.mutations.perform(.delete(messageIDs: [archived.id]))
        stage("delete-apply-end")
        XCTAssertEqual(deleteResult.state, "applied")
        stage("delete-verify-begin")
        let deleted = try await waitForMailboxReplacement(snapshots: authority.snapshots, messages: authority.messages, original: archived, requiredLabel: "TRASH")
        stage("delete-verify-end")
        XCTAssertNotEqual(deleted.id, archived.id)
        XCTAssertTrue(deleted.labels.contains("TRASH"))

        // Archive and delete are provider moves, so each durable replacement
        // receives a new message ID. Replay the canonical operation against
        // the currently active Trash replacement; the pre-archive ID is
        // intentionally no longer authorized by the Node.
        let replayMessageID = deleted.id
        stage("replay-sign-begin")
        let readOperation = try client.signMutation(
            variant: .setRead(messageIDs: [replayMessageID.rawValue], read: true),
            logicalMailboxID: logical,
            idempotencyKey: runUnique("live-read-replay")
        )
        stage("replay-sign-end")
        stage("replay-first-begin")
        let applied = try await authority.mutations.apply(canonicalOperation: readOperation)
        stage("replay-first-end")
        stage("replay-second-begin")
        let replayed = try await authority.mutations.apply(canonicalOperation: readOperation)
        stage("replay-second-end")
        XCTAssertEqual(applied.state, "applied", "replay must retain the original applied result")
        XCTAssertEqual(applied, replayed, "canonical mutation replay must return the original result")

        let draftID = runUnique("acceptance-draft-crud")
        guard let accountID = authority.accountID else {
            throw NodeSyncClientError.invalidResponse
        }
        let draft = Draft(
            id: DraftID(draftID), accountID: accountID,
            from: EmailAddress("acceptance@example.test"),
            to: [EmailAddress("recipient@example.test")], cc: [], bcc: [EmailAddress("blind@example.test")],
            subject: "acceptance", bodyPlain: "body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )
        let draftOperation = try signDraftOperation(
            draft, expectedRevision: "0", logicalMailboxID: logical, client: client,
            idempotencyKey: runUnique("live-create-draft")
        )
        stage("draft-create-apply-begin")
        let draftResult = try await authority.mutations.apply(canonicalOperation: draftOperation)
        stage("draft-create-apply-end")
        XCTAssertEqual(draftResult.state, "applied")
        stage("draft-create-replay-begin")
        let draftReplay = try await authority.mutations.apply(canonicalOperation: draftOperation)
        stage("draft-create-replay-end")
        XCTAssertEqual(draftReplay, draftResult, "canonical create replay must retain the original applied result")
        stage("draft-create-replay-postcondition")
        try await assertDraftPostcondition(draft, checkpoint: "draft-created", draftCount: 1, controlRoot: controlRoot)
        let reread = try await client.draftState(id: draftID)
        let updatedDraft = Draft(
            id: draft.id, accountID: draft.accountID, from: draft.from, to: draft.to,
            cc: draft.cc, bcc: draft.bcc, subject: draft.subject, bodyPlain: "updated-body",
            createdBy: draft.createdBy, aiGenerated: draft.aiGenerated, sourceThreadID: draft.sourceThreadID
        )
        let updateOperation = try signDraftOperation(
            updatedDraft, expectedRevision: reread.revision, logicalMailboxID: logical, client: client,
            idempotencyKey: runUnique("live-update-draft")
        )
        stage("draft-update-apply-begin")
        let updateResult = try await authority.mutations.apply(canonicalOperation: updateOperation)
        stage("draft-update-apply-end")
        XCTAssertEqual(updateResult.state, "applied")
        stage("draft-update-replay-begin")
        let updateReplay = try await authority.mutations.apply(canonicalOperation: updateOperation)
        stage("draft-update-replay-end")
        XCTAssertEqual(updateReplay, updateResult, "canonical update replay must retain the original applied result")
        stage("draft-update-replay-postcondition")
        try await assertDraftPostcondition(updatedDraft, checkpoint: "draft-updated", draftCount: 1, controlRoot: controlRoot)
        let updated = try await client.draftState(id: draftID)
        let deleteOperation = try client.signMutation(
            variant: .deleteDraft(draftID: draftID, expectedRevision: updated.revision),
            logicalMailboxID: logical,
            idempotencyKey: runUnique("live-delete-draft")
        )
        stage("draft-delete-apply-begin")
        let deleteDraftResult = try await authority.mutations.apply(canonicalOperation: deleteOperation)
        stage("draft-delete-apply-end")
        stage("draft-delete-replay-begin")
        let deleteReplay = try await authority.mutations.apply(canonicalOperation: deleteOperation)
        stage("draft-delete-replay-end")
        XCTAssertEqual(deleteDraftResult.state, "applied")
        XCTAssertEqual(deleteDraftResult, deleteReplay, "canonical delete replay must retain the original applied result")
        stage("draft-delete-replay-postcondition")
        try await assertDraftPostcondition(updatedDraft, checkpoint: "draft-deleted", draftCount: 0, controlRoot: controlRoot)

        // Drafts are provider-owned state. Re-open the provider session after
        // the destructive replay and assert that the deleted draft remains
        // absent before moving on to SMTP delivery coverage.
        stage("restart-imap-fixture-request-begin")
        try request(controlRoot, action: "restart-imap-fixture")
        try await wait(controlRoot, action: "restart-imap-fixture")
        stage("restart-imap-fixture-postcondition")
        try await assertDraftPostcondition(updatedDraft, checkpoint: "draft-deleted", draftCount: 0, controlRoot: controlRoot)

        // The fixture restart helper proves only that IMAP accepts a protocol
        // probe. A cached Node status can remain ready while its provider
        // owner is replaying a disconnected change stream, so force a fresh
        // provider command and wait for its projection delta before starting
        // the next mutation. This is the recovery proof; status alone is not.
        stage("restart-imap-fixture-provider-recovery-cursor-begin")
        let recoveryBootstrap = try await client.delta(limit: 2)
        XCTAssertTrue(recoveryBootstrap.changes.isEmpty, "recovery delta must bootstrap without synthesizing changes")
        let restartRecoveryCursor = recoveryBootstrap.nextCursor
        stage("restart-imap-fixture-provider-recovery-cursor-end")
        stage("restart-imap-fixture-provider-recovery-request-begin")
        try request(controlRoot, action: "provider-transition")
        stage("restart-imap-fixture-provider-recovery-request-end")
        stage("restart-imap-fixture-provider-recovery-wait-begin")
        try await wait(controlRoot, action: "provider-transition")
        stage("restart-imap-fixture-provider-recovery-wait-end")
        stage("restart-imap-fixture-provider-recovery-delta-begin")
        let restartRecoveryDelta = try await waitForNonEmptyDelta(
            client: client, cursor: restartRecoveryCursor, responseClassifier: responseClassifier
        )
        XCTAssertFalse(restartRecoveryDelta.changes.isEmpty)
        stage("restart-imap-fixture-provider-recovery-delta-end")

        let sendDraftID = runUnique("acceptance-draft-send")
        let sendDraft = Draft(
            id: DraftID(sendDraftID), accountID: accountID,
            from: EmailAddress("acceptance@example.test"),
            to: [EmailAddress("recipient@example.test")], cc: [], bcc: [EmailAddress("blind@example.test")],
            subject: "acceptance-send", bodyPlain: "send-body", createdBy: "acceptance",
            aiGenerated: false, sourceThreadID: nil
        )
        let sendSave = try await authority.mutations.perform(.saveDraft(sendDraft))
        XCTAssertEqual(sendSave.state, "applied")
        let sendState = try await client.draftState(id: sendDraftID)
        let sendOperation = try client.signMutation(
            variant: .send(draftID: sendDraftID, expectedRevision: sendState.revision),
            logicalMailboxID: logical,
            idempotencyKey: runUnique("live-send")
        )
        stage("send-perform-begin")
        let sendResult = try await authority.mutations.apply(canonicalOperation: sendOperation)
        stage("send-perform-end")
        let sendReplay = try await authority.mutations.apply(canonicalOperation: sendOperation)
        XCTAssertEqual(sendResult.state, "applied")
        XCTAssertEqual(sendResult, sendReplay, "exact signed send replay must not duplicate delivery")
        let rendered = try DraftRenderer().render(sendDraft)
        let source = Data("\(rendered.headers)\r\n\r\n\(rendered.body)".utf8)
        let expectation = MailPostconditionExpectation(
            checkpoint: "send-delivery", draftCount: 0, deliveryCount: 1, sentCount: 1, envelopeSender: "acceptance@example.test",
            envelopeRecipients: ["recipient@example.test", "blind@example.test"],
            messageID: "<\(sendDraftID)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(source),
            bccHeaderAbsent: true, correlated: true
        )
        try writeMailPostconditionExpectation(expectation, root: controlRoot)
        try request(controlRoot, action: "mail-postcondition")
        try await wait(controlRoot, action: "mail-postcondition")
        for (action, stageName) in [("restart-imap-fixture", "imap-fixture-restart"), ("restart-smtp-fixture", "smtp-fixture-restart")] {
            stage("\(stageName)-request-begin")
            try request(controlRoot, action: action)
            try await wait(controlRoot, action: action)
            try request(controlRoot, action: "mail-postcondition")
            try await wait(controlRoot, action: "mail-postcondition")
        }

        stage("restart-request-begin")
        try request(controlRoot, action: "restart-node")
        stage("restart-request-end")
        stage("restart-wait-begin")
        try await wait(controlRoot, action: "restart-node")
        stage("restart-wait-end")
        stage("restart-status-begin")
        let restartStatusResult = try await statusWithPostDispatchRecovery(label: "restart-status", client: client) {
            try await client.status()
        }
        XCTAssertTrue(restartStatusResult.recovered, "the acceptance restart status GET must cross its independent response-drop injector")
        stage("restart-status-end")
        let postRestartReplay = try await authority.mutations.apply(canonicalOperation: sendOperation)
        XCTAssertEqual(postRestartReplay, sendResult, "the same signed send must remain idempotent after Node restart")
        stage("restart-node-postcondition")
        // The send draft is now provider-deleted and its authenticated
        // delivery is durable. Check both facts after the Node process has
        // restarted, before repeating the strict send-delivery assertion.
        try writeMailPostconditionExpectation(MailPostconditionExpectation(
            checkpoint: "send-delivery", draftCount: 0, deliveryCount: 1, sentCount: 1,
            envelopeSender: "acceptance@example.test",
            envelopeRecipients: ["recipient@example.test", "blind@example.test"],
            messageID: "<\(sendDraftID)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(source),
            bccHeaderAbsent: true, correlated: true
        ), root: controlRoot)
        try request(controlRoot, action: "mail-postcondition")
        try await wait(controlRoot, action: "mail-postcondition")
    }

    private struct MailPostconditionExpectation: Codable {
        let checkpoint: String
        let draftCount: Int
        let deliveryCount: Int
        let sentCount: Int
        let envelopeSender: String
        let envelopeRecipients: [String]
        let messageID: String
        let canonicalDigest: String
        let bccHeaderAbsent: Bool
        let correlated: Bool

        enum CodingKeys: String, CodingKey {
            case checkpoint, draftCount = "draft_count", deliveryCount = "delivery_count", sentCount = "sent_count", envelopeSender = "envelope_sender", envelopeRecipients = "envelope_recipients", messageID = "message_id", canonicalDigest = "canonical_digest", bccHeaderAbsent = "bcc_header_absent", correlated
        }
    }

    private static func writeMailPostconditionExpectation(_ expectation: MailPostconditionExpectation, root: URL) throws {
        let path = root.appendingPathComponent("mail-postcondition.expectation")
        let data = try JSONEncoder().encode(expectation)
        guard FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw NodeSyncClientError.transport
        }
    }

    private static func assertDraftPostcondition(_ draft: Draft, checkpoint: String, draftCount: Int, controlRoot: URL) async throws {
        let rendered = try DraftRenderer().render(draft)
        let source = Data("\(rendered.headers)\r\n\r\n\(rendered.body)".utf8)
        try writeMailPostconditionExpectation(MailPostconditionExpectation(
            checkpoint: checkpoint, draftCount: draftCount, deliveryCount: 0, sentCount: 0,
            envelopeSender: "", envelopeRecipients: [],
            messageID: "<\(draft.id.rawValue)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(source),
            bccHeaderAbsent: true, correlated: false
        ), root: controlRoot)
        try request(controlRoot, action: "mail-postcondition")
        try await wait(controlRoot, action: "mail-postcondition")
    }

    private static func signDraftOperation(
        _ draft: Draft,
        expectedRevision: String,
        logicalMailboxID: LogicalMailboxID,
        client: NodeSyncClient,
        idempotencyKey: String
    ) throws -> Data {
        let rendered = try DraftRenderer().render(draft)
        let source = Data("\(rendered.headers)\r\n\r\n\(rendered.body)".utf8)
        return try client.signMutation(
            variant: .saveDraft(
                draftID: draft.id.rawValue,
                expectedRevision: expectedRevision,
                rfc5322: source,
                bcc: draft.bcc.map(\.rawValue)
            ),
            logicalMailboxID: logicalMailboxID,
            idempotencyKey: idempotencyKey
        )
    }

    private static func verifyReleaseBackupRestore(
        authority: PlainpostNodeMailAuthority,
        attachmentID: String,
        controlRoot: URL
    ) async throws {
        stage("backup-restore-begin")
        stage("backup-restore-baseline-begin")
        let statusBefore = try await authority.status()
        let snapshotBefore = try await authority.snapshots.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
        guard let messageID = snapshotBefore.messages.first(where: { $0.attachments.contains(where: { $0.id == attachmentID }) })?.id else {
            throw NodeSyncClientError.invalidResponse
        }
        let messageBefore = try await authority.messages.message(id: messageID)
        let attachmentBefore = try await authority.attachments.attachment(id: attachmentID)
        let bytesBefore = try await attachmentBefore.readAll()
        stage("backup-restore-baseline-end")
        stage("backup-restore-request-begin")
        try request(controlRoot, action: "release-backup-restore")
        stage("backup-restore-request-end")
        stage("backup-restore-wait-begin")
        try await wait(controlRoot, action: "release-backup-restore")
        stage("backup-restore-wait-end")
        stage("backup-restore-verify-begin")
        let statusAfter = try await authority.status()
        let snapshotAfter = try await authority.snapshots.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
        let messageAfter = try await authority.messages.message(id: messageBefore.id)
        let attachmentAfter = try await authority.attachments.attachment(id: attachmentID)
        let bytesAfter = try await attachmentAfter.readAll()
        let statusMismatchClass = backupRestoreStatusMismatchClassForTesting(before: statusBefore, after: statusAfter)
        let statusMatches = statusMismatchClass == nil
        let snapshotMatches = backupRestoreSnapshotMatchesForTesting(before: snapshotBefore, after: snapshotAfter)
        let messageMatches = messageAfter == messageBefore
        let attachmentMetadataMatches = attachmentAfter.metadata == attachmentBefore.metadata
        let attachmentBytesMatch = bytesAfter == bytesBefore
        if let mismatchClass = statusMismatchClass ?? backupRestoreVerificationMismatchClassForTesting(
            statusMatches: statusMatches,
            snapshotMatches: snapshotMatches,
            messageMatches: messageMatches,
            attachmentMetadataMatches: attachmentMetadataMatches,
            attachmentBytesMatch: attachmentBytesMatch
        ) {
            stage("backup-restore-verify-failed-\(mismatchClass)")
            throw NodeSyncClientError.invalidResponse
        }
        stage("backup-restore-verify-end")
        stage("backup-restore-success")
        stage("backup-restore-end")
    }

    nonisolated static func backupRestoreStatusMatches(before: SyncNodeStatus, after: SyncNodeStatus) -> Bool {
        backupRestoreStatusMismatchClassForTesting(before: before, after: after) == nil
    }

    /// Snapshot revision and continuation cursors are response-envelope state,
    /// not restored mail content. Compare the complete message projection while
    /// leaving those volatile fields to the status/recovery checks.
    nonisolated static func backupRestoreSnapshotMatchesForTesting(
        before: MailSnapshotPage,
        after: MailSnapshotPage
    ) -> Bool {
        before.messages == after.messages
    }

    nonisolated static func backupRestoreStatusMismatchClassForTesting(
        before: SyncNodeStatus,
        after: SyncNodeStatus
    ) -> String? {
        if after.state != "ready" { return "status-state" }
        if after.reachability != "reachable" { return "status-reachability" }
        if before.version != after.version { return "status-version" }
        if before.storage != after.storage { return "status-storage" }
        if before.providerIdentity != after.providerIdentity { return "status-provider-identity" }
        if before.assignments != after.assignments { return "status-assignments" }
        if !(before.backup == after.backup || (before.backup == "not_reported" && after.backup == "verified")) {
            return "status-backup"
        }
        if before.endpoint != after.endpoint { return "status-endpoint" }
        return nil
    }

    nonisolated static func backupRestoreVerificationMismatchClassForTesting(
        statusMatches: Bool,
        snapshotMatches: Bool,
        messageMatches: Bool,
        attachmentMetadataMatches: Bool,
        attachmentBytesMatch: Bool
    ) -> String? {
        if !statusMatches { return "status" }
        if !snapshotMatches { return "snapshot" }
        if !messageMatches { return "message" }
        if !attachmentMetadataMatches { return "attachment-metadata" }
        if !attachmentBytesMatch { return "attachment-bytes" }
        return nil
    }

    private static func smtpMatrixCaseFromEnvironment() throws -> SMTPMatrixCase? {
        guard let selector = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO"], !selector.isEmpty else {
            return nil
        }
        guard let matrixCase = smtpMatrixCases.first(where: { $0.selector == selector }) else {
            XCTFail("SMTP matrix selector is outside the closed Swift allowlist")
            throw NodeSyncClientError.invalidResponse
        }
        return matrixCase
    }

    private static func imapMatrixCaseFromEnvironment() throws -> IMAPMatrixCase? {
        guard let selector = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_SCENARIO"], !selector.isEmpty else {
            return nil
        }
        guard let matrixCase = imapMatrixCases.first(where: { $0.selector == selector }) else {
            if selector.hasPrefix("imap-") {
                XCTFail("IMAP matrix selector is outside the closed Swift allowlist")
                throw NodeSyncClientError.invalidResponse
            }
            return nil
        }
        return matrixCase
    }

    private static func runIMAPMatrixCase(
        _ matrixCase: IMAPMatrixCase,
        initialMessages: [NodeSyncMessage],
        authority: PlainpostNodeMailAuthority,
        secondaryAuthority: PlainpostNodeMailAuthority?,
        client: NodeSyncClient,
        secondaryClient: NodeSyncClient?,
        attachmentFaultProbeClient: NodeSyncClient?,
        controlRoot: URL,
        authorityReplacement: AuthorityReplacement?
    ) async throws {
        stage("imap-matrix-\(matrixCase.selector)-begin")
        if matrixCase.selector == "imap-provider-restart-mid-page" {
            let baseline = try await waitForInitialSnapshot(client: client, responseClassifier: nil)
            guard imapSnapshotMatchesExpectedForTesting(
                baseline,
                expectedMessages: nil,
                expectedRevision: nil,
                requireAcceptanceFixtureShape: true
            ) else { throw NodeSyncClientError.invalidResponse }
            stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
            let bootstrap = try await client.delta(limit: 2)
            guard bootstrap.changes.isEmpty, !bootstrap.nextCursor.isEmpty,
                  let logicalMailboxID = try await client.mailboxAssignments().assignments.first(where: { $0.role == "inbox" })?.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            if imapMatrixUsesIdleBarrierForTesting(selector: matrixCase.selector) {
                try await waitForMailPhase("idle", protocolName: "imap", root: controlRoot)
                try await waitForActiveIMAPIdle(root: controlRoot)
                stage("imap-matrix-\(matrixCase.selector)-idle-observed")
            }
            try request(controlRoot, action: "imap-matrix-arm-provider-restart")
            try await wait(controlRoot, action: "imap-matrix-arm-provider-restart")
            let headerFetchOccurrence = try readIMAPProviderRestartOccurrence(controlRoot)
            stage("imap-matrix-\(matrixCase.selector)-barrier-armed")
            try request(controlRoot, action: "imap-matrix-append-message")
            try await wait(controlRoot, action: "imap-matrix-append-message")
            try await waitForMailPhase(
                "header-fetch",
                protocolName: "imap",
                occurrence: headerFetchOccurrence,
                root: controlRoot
            )
            stage("imap-matrix-\(matrixCase.selector)-phase-reached")
            let paused = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            guard imapSnapshotMatchesExpectedForTesting(
                paused,
                expectedMessages: baseline.messages,
                expectedRevision: baseline.revision,
                requireAcceptanceFixtureShape: true
            ) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-projection-unchanged")
            try request(controlRoot, action: "restart-imap-fixture")
            try await wait(controlRoot, action: "restart-imap-fixture")
            try request(controlRoot, action: "imap-matrix-resume")
            try await wait(controlRoot, action: "imap-matrix-resume")
            stage("imap-matrix-\(matrixCase.selector)-barrier-released")
            let deltaPages = try await waitForAppendDeltaSequence(client: client, cursor: bootstrap.nextCursor, responseClassifier: nil)
            let recovered = try await waitForSnapshotMatchingForTesting(
                currentRevision: baseline.revision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    guard page.revision != baseline.revision,
                          page.messages.count == baseline.messages.count + 1,
                          let transition = page.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                          imapMatrixTransitionMessageMatchesForTesting(transition) else { return false }
                    return imapSnapshotMatchesExpectedSetForTesting(
                        page,
                        expectedMessages: baseline.messages + [transition],
                        expectedRevision: nil
                    )
                }
            )
            guard let transition = recovered.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                  imapMatrixTransitionMessageMatchesForTesting(transition),
                  imapAppendDeltaSequenceShapeClassForTesting(
                      deltaPages,
                      logicalMailboxID: logicalMailboxID,
                      baselineMessageIDs: Dictionary(uniqueKeysWithValues: baseline.messages.map { ($0.id, $0.threadID) }),
                      messageID: transition.id,
                      threadID: transition.threadID
                  ) == "matched" else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        }
        var messages = initialMessages
        var snapshotPage: NodeSyncSnapshotPage?
        if messages.isEmpty {
            let snapshotTask = Task { () -> Result<NodeSyncSnapshotPage, Error> in
                do {
                    return .success(try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit))
                } catch {
                    return .failure(error)
                }
            }
            if imapMatrixInitialPhaseBarrierForTesting(selector: matrixCase.selector) {
                do {
                    try await waitForMailPhase(matrixCase.phase, protocolName: matrixCase.protocolName, root: controlRoot)
                    stage("imap-matrix-\(matrixCase.selector)-phase-reached")
                    try request(controlRoot, action: "imap-matrix-resume")
                    try await wait(controlRoot, action: "imap-matrix-resume")
                    if matrixCase.selector == "imap-delayed-literal" {
                        stage("imap-matrix-\(matrixCase.selector)-literal-released")
                    }
                } catch {
                    await cancelAndConsume(snapshotTask)
                    throw error
                }
            }
            switch await snapshotTask.value {
            case let .failure(error):
                guard let expectedFaultClass = imapMatrixExpectedInitialFaultClassForTesting(selector: matrixCase.selector) else { throw error }
                XCTAssertTrue(messages.isEmpty, "IMAP protocol failure must not publish a partial snapshot")
                switch expectedFaultClass {
                case .authentication:
                    guard (error as? NodeSyncClientError) == .problem(.unauthorized) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                case .transport, .disconnect:
                    guard let transportError = error as? NodeSyncClientError,
                          transportError == .transport || transportError == .problem(.unavailable) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                }
                stage("imap-matrix-\(matrixCase.selector)-fault-class-\(expectedFaultClass.rawValue)")
                stage("imap-matrix-\(matrixCase.selector)-rejected")
                switch matrixCase.selector {
                case "imap-authentication", "imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1":
                    // Startup TLS failures must precede LOGIN. Restore the
                    // normal fixture listener and prove a new authenticated
                    // session can still publish the complete baseline.
                    if matrixCase.selector != "imap-authentication" {
                        try request(controlRoot, action: "restore-imap-fixture-normal")
                        try await wait(controlRoot, action: "restore-imap-fixture-normal")
                    }
                    let recovered = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        recovered,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    try request(controlRoot, action: "imap-matrix-assert-authentication")
                    try await wait(controlRoot, action: "imap-matrix-assert-authentication")
                    stage("imap-matrix-\(matrixCase.selector)-fresh-authenticated-session")
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                case "imap-catalog", "imap-header-fetch", "imap-body-fetch":
                    let recovered = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        recovered,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                default:
                    throw NodeSyncClientError.invalidResponse
                }
            case let .success(snapshot):
                guard !imapMatrixInitialSnapshotMustFailForTesting(selector: matrixCase.selector) else {
                    XCTFail("IMAP \(matrixCase.selector) unexpectedly completed without its typed failure")
                    throw NodeSyncClientError.invalidResponse
                }
                messages = snapshot.messages
                snapshotPage = snapshot
                if matrixCase.selector == "imap-authentication" {
                    guard imapSnapshotMatchesExpectedForTesting(
                        snapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
                    try request(controlRoot, action: "imap-matrix-arm-authentication")
                    try await wait(controlRoot, action: "imap-matrix-arm-authentication")
                    stage("imap-matrix-\(matrixCase.selector)-fault-armed")
                    try request(controlRoot, action: "restart-node")
                    try await wait(controlRoot, action: "restart-node")
                    stage("imap-matrix-\(matrixCase.selector)-startup-fault-observed")
                    try request(controlRoot, action: "imap-matrix-assert-authentication")
                    try await wait(controlRoot, action: "imap-matrix-assert-authentication")
                    stage("imap-matrix-\(matrixCase.selector)-durable-block-observed")
                    let replacementContext = try await performAuthorityReplacement(authorityReplacement)
                    stage("imap-matrix-\(matrixCase.selector)-authority-replacement")
                    let replacementSnapshot = try await replacementContext.client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        replacementSnapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ), imapReplacementSnapshotMessagesMatchForTesting(
                        actual: replacementSnapshot.messages,
                        expected: snapshot.messages
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-fresh-authenticated-session")
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                }
                if ["imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1"].contains(matrixCase.selector) {
                    stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
                    try request(controlRoot, action: "imap-matrix-arm-tls-failure")
                    try await wait(controlRoot, action: "imap-matrix-arm-tls-failure")
                    stage("imap-matrix-\(matrixCase.selector)-fault-armed")
                    try request(controlRoot, action: "restart-node")
                    try await wait(controlRoot, action: "restart-node")
                    stage("imap-matrix-\(matrixCase.selector)-startup-fault-observed")
                    try request(controlRoot, action: "restore-imap-fixture-normal")
                    try await wait(controlRoot, action: "restore-imap-fixture-normal")
                    stage("imap-matrix-\(matrixCase.selector)-fixture-restored")
                    let replacementContext = try await performAuthorityReplacement(authorityReplacement)
                    stage("imap-matrix-\(matrixCase.selector)-authority-replacement")
                    let replacementSnapshot = try await replacementContext.client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        replacementSnapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ), imapReplacementSnapshotMessagesMatchForTesting(
                        actual: replacementSnapshot.messages,
                        expected: snapshot.messages
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-fresh-authenticated-session")
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                }
                if matrixCase.selector == "imap-catalog" {
                    guard imapSnapshotMatchesExpectedForTesting(
                        snapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
                    try request(controlRoot, action: "imap-matrix-catalog-probe")
                    try await wait(controlRoot, action: "imap-matrix-catalog-probe")
                    stage("imap-matrix-\(matrixCase.selector)-fault-class-disconnect")
                    stage("imap-matrix-\(matrixCase.selector)-rejected")
                    let recovered = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        recovered,
                        expectedMessages: snapshot.messages,
                        expectedRevision: snapshot.revision,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-catalog-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                }
                if imapMatrixUsesDedicatedFetchProbeForTesting(selector: matrixCase.selector) {
                    guard imapSnapshotMatchesExpectedForTesting(
                        snapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
                    try request(controlRoot, action: "imap-matrix-fetch-probe")
                    try await wait(controlRoot, action: "imap-matrix-fetch-probe")
                    stage("imap-matrix-\(matrixCase.selector)-fault-class-disconnect")
                    stage("imap-matrix-\(matrixCase.selector)-rejected")
                    let recovered = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        recovered,
                        expectedMessages: snapshot.messages,
                        expectedRevision: snapshot.revision,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-fetch-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                }
                if imapMatrixUsesDedicatedDelayedLiteralProbeForTesting(selector: matrixCase.selector) {
                    guard imapSnapshotMatchesExpectedForTesting(
                        snapshot,
                        expectedMessages: nil,
                        expectedRevision: nil,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-healthy-baseline")
                    try request(controlRoot, action: "imap-matrix-delayed-literal-probe")
                    try await wait(controlRoot, action: "imap-matrix-delayed-literal-probe")
                    stage("imap-matrix-\(matrixCase.selector)-phase-reached")
                    stage("imap-matrix-\(matrixCase.selector)-literal-released")
                    let recovered = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
                    guard imapSnapshotMatchesExpectedForTesting(
                        recovered,
                        expectedMessages: snapshot.messages,
                        expectedRevision: snapshot.revision,
                        requireAcceptanceFixtureShape: true
                    ) else {
                        throw NodeSyncClientError.invalidResponse
                    }
                    stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
                    stage("imap-matrix-\(matrixCase.selector)-end")
                    return
                }
            }
        }
        if imapMatrixRequiresCompleteProjectionRecoveryForTesting(selector: matrixCase.selector) {
            guard let recovered = snapshotPage,
                  imapSnapshotMatchesExpectedForTesting(
                      recovered,
                      expectedMessages: nil,
                      expectedRevision: nil,
                      requireAcceptanceFixtureShape: true
                  ) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        }
        switch matrixCase.selector {
        case "imap-delayed-literal":
            guard let message = messages.first,
                  message.subject == "Plainpost acceptance é",
                  message.textBody.value == "Unicode acceptance body" else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-projection-committed")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-provider-restart-mid-page":
            try request(controlRoot, action: "restart-imap-fixture")
            try await wait(controlRoot, action: "restart-imap-fixture")
            let recovered = try await waitForInitialSnapshot(client: client, responseClassifier: nil)
            XCTAssertTrue(
                imapSnapshotMatchesExpectedForTesting(
                    recovered,
                    expectedMessages: nil,
                    expectedRevision: nil,
                    requireAcceptanceFixtureShape: true
                ),
                "provider restart must recover the complete normalized snapshot without partial state"
            )
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-provider-restart-after-commit":
            guard let baseline = snapshotPage,
                  imapSnapshotMatchesExpectedForTesting(
                      baseline,
                      expectedMessages: messages,
                      expectedRevision: nil,
                      requireAcceptanceFixtureShape: true
                  ) else {
                throw NodeSyncClientError.invalidResponse
            }
            guard let logicalMailboxID = try await client.mailboxAssignments().assignments.first(where: { $0.role == "inbox" })?.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            let bootstrap = try await client.delta(limit: 2)
            guard bootstrap.changes.isEmpty, !bootstrap.nextCursor.isEmpty else { throw NodeSyncClientError.invalidResponse }
            try request(controlRoot, action: "restart-imap-fixture")
            try await wait(controlRoot, action: "restart-imap-fixture")
            try request(controlRoot, action: "imap-matrix-append-message")
            try await wait(controlRoot, action: "imap-matrix-append-message")
            stage("imap-matrix-\(matrixCase.selector)-post-restart-imap-work-begin")
            let deltaPages = try await waitForAppendDeltaSequence(client: client, cursor: bootstrap.nextCursor, responseClassifier: nil)
            guard let delta = deltaPages.first else { throw NodeSyncClientError.invalidResponse }
            XCTAssertFalse(delta.nextCursor.isEmpty, "provider restart after commit must return a continuation cursor")
            XCTAssertNotEqual(delta.revision, bootstrap.revision, "provider restart after commit delta must advance the revision")
            let recovered = try await waitForSnapshotMatchingForTesting(
                currentRevision: bootstrap.revision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    guard let transition = page.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                          imapMatrixTransitionMessageMatchesForTesting(transition) else { return false }
                    return page.revision != bootstrap.revision && imapSnapshotMatchesExpectedSetForTesting(
                        page,
                        expectedMessages: messages + [transition],
                        expectedRevision: nil
                    )
                }
            )
            guard let transition = recovered.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                  imapMatrixTransitionMessageMatchesForTesting(transition) else { throw NodeSyncClientError.invalidResponse }
            let deltaSequenceShapeClass = imapAppendDeltaSequenceShapeClassForTesting(
                deltaPages,
                logicalMailboxID: logicalMailboxID,
                baselineMessageIDs: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.threadID) }),
                messageID: transition.id,
                threadID: transition.threadID
            )
            stage("imap-matrix-\(matrixCase.selector)-delta-shape-\(deltaSequenceShapeClass)")
            XCTAssertTrue(
                deltaSequenceShapeClass == "matched",
                "provider restart after commit must publish exactly one target upsert"
            )
            XCTAssertTrue(
                imapSnapshotMatchesExpectedSetForTesting(
                    recovered,
                    expectedMessages: messages + [transition],
                    expectedRevision: nil
                ),
                "provider restart after commit must preserve the exact normalized baseline and append one transition"
            )
            XCTAssertNotEqual(recovered.revision, bootstrap.revision, "provider restart after commit must advance the projection revision")
            stage("imap-matrix-\(matrixCase.selector)-post-restart-imap-work-end")
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-node-restart-before-ack":
            guard let message = messages.first else { throw NodeSyncClientError.invalidResponse }
            let mutationTask = Task { () -> Result<MailMutationResult, Error> in
                do {
                    return .success(try await authority.mutations.perform(.setRead(messageIDs: [MessageID(message.id)], read: true)))
                } catch {
                    return .failure(error)
                }
            }
            do {
                guard case let .failure(error) = await mutationTask.value,
                      (error as? PlainpostError) == .validationFailed("The Node is unavailable.") else {
                    throw NodeSyncClientError.invalidResponse
                }
            } catch {
                await cancelAndConsume(mutationTask)
                throw error
            }
            stage("imap-matrix-\(matrixCase.selector)-response-drop-observed")
            stage("imap-matrix-\(matrixCase.selector)-fault-class-transport")
            stage("imap-matrix-\(matrixCase.selector)-response-drop-transport")
            try request(controlRoot, action: "restart-node")
            try await wait(controlRoot, action: "restart-node")
            stage("imap-matrix-\(matrixCase.selector)-recovery-replay-begin")
            var replayResult: NodeSyncMutationResult?
            for attempt in 0..<2 {
                do {
                    // Reconcile the exact device-retained canonical request.
                    // Do not call mutations.perform here: it settles the
                    // retained request and, when that result is applied, would
                    // then sign and dispatch a fresh setRead operation.
                    // Before-ack restart must settle the already-committed
                    // operation as applied and never create a new provider
                    // mutation while the startup recovery barrier is open.
                    replayResult = try await client.reconcilePendingMutation()
                    break
                } catch let error as NodeSyncClientError where error == .transport && attempt == 0 {
                    // The first exact replay can report node-sequence-consumed
                    // after the server committed the original request. That
                    // response advances the local pending record into its
                    // retained canonical-mutation slot; one second bounded
                    // reconciliation dispatches those same canonical bytes
                    // under the next authenticated sequence.
                    stage("imap-matrix-\(matrixCase.selector)-recovery-replay-sequence-consumed")
                } catch {
                    throw NodeSyncClientError.invalidResponse
                }
            }
            stage("imap-matrix-\(matrixCase.selector)-recovery-replay-end")
            if let replayResult {
                stage("imap-matrix-\(matrixCase.selector)-recovery-replay-applied")
                guard imapMatrixRestartReplayStateIsAppliedForTesting(replayResult.state) else {
                    throw NodeSyncClientError.invalidResponse
                }
            } else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-recovery-replay-closed")
            guard let baselineRevision = snapshotPage?.revision else { throw NodeSyncClientError.invalidResponse }
            let expectedAfterAck = messages.map { imapMessageWithReadStateForTesting($0, seen: $0.id == message.id ? true : imapMessageIsSeenForTesting(flags: $0.flags)) }
            let recovered = try await waitForSnapshotMatchingForTesting(
                currentRevision: baselineRevision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    page.revision != baselineRevision && imapSnapshotMatchesExpectedSetForTesting(
                        page,
                        expectedMessages: expectedAfterAck,
                        expectedRevision: nil
                    ) && page.messages.first(where: { $0.id == message.id }).map {
                        imapMessageIsSeenForTesting(flags: $0.flags)
                    } == true
                }
            )
            XCTAssertTrue(recovered.messages.first(where: { $0.id == message.id })?.flags.contains("seen") == true, "Node restart before acknowledgement must retain the committed read mutation")
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-node-restart-after-ack":
            guard let message = messages.first else { throw NodeSyncClientError.invalidResponse }
            let result = try await authority.mutations.perform(.setRead(messageIDs: [MessageID(message.id)], read: true))
            XCTAssertEqual(result.state, "applied")
            stage("imap-matrix-\(matrixCase.selector)-acknowledged")
            try request(controlRoot, action: "restart-node")
            try await wait(controlRoot, action: "restart-node")
            let expectedAfterAck = messages.map { imapMessageWithReadStateForTesting($0, seen: $0.id == message.id ? true : imapMessageIsSeenForTesting(flags: $0.flags)) }
            let baselineRevision = snapshotPage?.revision ?? "baseline"
            let recovered = try await waitForSnapshotMatchingForTesting(
                currentRevision: baselineRevision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    page.revision != baselineRevision && imapSnapshotMatchesExpectedSetForTesting(
                        page,
                        expectedMessages: expectedAfterAck,
                        expectedRevision: nil
                    ) && page.messages.first(where: { $0.id == message.id }).map {
                        imapMessageIsSeenForTesting(flags: $0.flags)
                    } == true
                }
            )
            XCTAssertTrue(recovered.messages.first(where: { $0.id == message.id })?.flags.contains("seen") == true, "Node restart after acknowledgement must retain the committed read mutation")
            stage("imap-matrix-\(matrixCase.selector)-projection-recovered")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-idle-wakeup", "imap-poll-fallback":
            guard let baseline = snapshotPage,
                  imapSnapshotMatchesExpectedForTesting(
                      baseline,
                      expectedMessages: messages,
                      expectedRevision: nil,
                      requireAcceptanceFixtureShape: true
                  ) else {
                throw NodeSyncClientError.invalidResponse
            }
            let bootstrap = try await client.delta(limit: 2)
            guard bootstrap.changes.isEmpty, !bootstrap.nextCursor.isEmpty else { throw NodeSyncClientError.invalidResponse }
            if matrixCase.selector == "imap-idle-wakeup" {
                try await waitForMailPhase("idle", protocolName: "imap", root: controlRoot)
                stage("imap-matrix-\(matrixCase.selector)-command-observed")
            } else {
                try request(controlRoot, action: "imap-matrix-assert-no-idle")
                try await wait(controlRoot, action: "imap-matrix-assert-no-idle")
                stage("imap-matrix-\(matrixCase.selector)-idle-absent")
            }
            guard let logicalMailboxID = try await client.mailboxAssignments().assignments.first(where: { $0.role == "inbox" })?.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            try request(controlRoot, action: "imap-matrix-append-message")
            try await wait(controlRoot, action: "imap-matrix-append-message")
            let deltaPages = try await waitForAppendDeltaSequence(client: client, cursor: bootstrap.nextCursor, responseClassifier: nil)
            guard let delta = deltaPages.first else { throw NodeSyncClientError.invalidResponse }
            XCTAssertFalse(delta.nextCursor.isEmpty, "IMAP \(matrixCase.selector) must return a continuation cursor")
            XCTAssertNotEqual(delta.revision, bootstrap.revision, "IMAP \(matrixCase.selector) delta must advance the revision")
            let recovered = try await waitForSnapshotMatchingForTesting(
                currentRevision: bootstrap.revision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    guard let transition = page.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                          imapMatrixTransitionMessageMatchesForTesting(transition) else { return false }
                    return page.revision != bootstrap.revision && imapSnapshotMatchesExpectedSetForTesting(
                        page,
                        expectedMessages: messages + [transition],
                        expectedRevision: nil
                    )
                }
            )
            guard let transition = recovered.messages.first(where: { $0.subject == "IMAP matrix transition" }),
                  imapMatrixTransitionMessageMatchesForTesting(transition) else { throw NodeSyncClientError.invalidResponse }
            let deltaSequenceShapeClass = imapAppendDeltaSequenceShapeClassForTesting(
                deltaPages,
                logicalMailboxID: logicalMailboxID,
                baselineMessageIDs: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.threadID) }),
                messageID: transition.id,
                threadID: transition.threadID
            )
            stage("imap-matrix-\(matrixCase.selector)-delta-shape-\(deltaSequenceShapeClass)")
            XCTAssertTrue(
                deltaSequenceShapeClass == "matched",
                "IMAP \(matrixCase.selector) must publish exactly one target upsert"
            )
            XCTAssertTrue(
                imapSnapshotMatchesExpectedSetForTesting(
                    recovered,
                    expectedMessages: messages + [transition],
                    expectedRevision: nil
                ),
                "IMAP \(matrixCase.selector) must recover the exact normalized baseline and append one transition"
            )
            XCTAssertNotEqual(recovered.revision, bootstrap.revision, "IMAP \(matrixCase.selector) must advance the projection revision")
            stage("imap-matrix-\(matrixCase.selector)-delta-observed")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-uid-gaps":
            guard imapUIDGapFixtureShapeMatchesForTesting(messages) else {
                throw NodeSyncClientError.invalidResponse
            }
            let assignments = try await client.mailboxAssignments().assignments
            guard let logicalMailboxID = assignments.first(where: { $0.role == "inbox" })?.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            let expectedUIDs: [String: String] = [
                "UID gap one": "1",
                "UID gap four": "4",
                "UID gap nine": "9",
            ]
            guard messages.allSatisfy({ message in
                guard let uid = expectedUIDs[message.subject] else { return false }
                return message.id == imapGenericMessageIdentityForTesting(logicalMailboxID: logicalMailboxID, uid: uid) &&
                    message.threadID == message.id
            }) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-cursor-reconciled")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-expunge":
            guard let message = messages.first else { throw NodeSyncClientError.invalidResponse }
            let beforeExpunge = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            guard imapSnapshotMatchesExpectedSetForTesting(
                beforeExpunge,
                expectedMessages: messages,
                expectedRevision: nil
            ) else {
                throw NodeSyncClientError.invalidResponse
            }
            let result = try await authority.mutations.perform(.delete(messageIDs: [MessageID(message.id)]))
            XCTAssertEqual(result.state, "applied", "IMAP EXPUNGE must commit through the authority")
            let afterExpunge = try await waitForSnapshotMatchingForTesting(
                currentRevision: beforeExpunge.revision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) },
                matches: { page in
                    imapExpungeProjectionMatchesForTesting(
                        page,
                        baselineMessages: messages,
                        deletedMessage: message,
                        currentRevision: beforeExpunge.revision
                    )
                }
            )
            XCTAssertTrue(
                imapExpungeProjectionMatchesForTesting(
                    afterExpunge,
                    baselineMessages: messages,
                    deletedMessage: message,
                    currentRevision: beforeExpunge.revision
                ),
                "EXPUNGE must project one retained Inbox message and one exact Trash copy after commit"
            )
            stage("imap-matrix-\(matrixCase.selector)-projection-committed")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-uidvalidity-reset":
            let oldSnapshot = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            let assignments = try await client.mailboxAssignments().assignments
            guard let logicalMailboxID = assignments.first(where: { $0.role == "inbox" })?.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            try request(controlRoot, action: "imap-matrix-reset-uidvalidity")
            try await wait(controlRoot, action: "imap-matrix-reset-uidvalidity")
            stage("imap-matrix-\(matrixCase.selector)-provider-session-revision-wait-begin")
            let recovered = try await waitForUIDValidityReplacementForTesting(
                previous: oldSnapshot,
                expectedMessageIDs: Set(["1", "2"].map {
                    imapGenericMessageIdentityForTesting(
                        logicalMailboxID: logicalMailboxID,
                        uid: $0,
                        providerEpoch: 2
                    )
                }),
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            stage("imap-matrix-\(matrixCase.selector)-provider-session-revision-changed")
            XCTAssertTrue(
                imapUIDValidityReplacementMatchesForTesting(
                    actual: recovered,
                    previous: oldSnapshot,
                    currentRevision: oldSnapshot.revision,
                    expectedMessageIDs: Set(["1", "2"].map {
                        imapGenericMessageIdentityForTesting(
                            logicalMailboxID: logicalMailboxID,
                            uid: $0,
                            providerEpoch: 2
                        )
                    })
                ),
                "UIDVALIDITY reset must rotate identities while preserving exact normalized content"
            )
            XCTAssertNotEqual(oldSnapshot.revision, recovered.revision, "UIDVALIDITY reset must advance the provider revision")
            stage("imap-matrix-\(matrixCase.selector)-baseline-rebuilt")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-concurrent-mutations":
            stage("imap-matrix-\(matrixCase.selector)-baseline-begin")
            let baseline = try await waitForAcceptanceFixtureSnapshotForTesting(
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            messages = baseline.messages
            snapshotPage = baseline
            stage("imap-matrix-\(matrixCase.selector)-baseline-end")
            guard let message = messages.first else {
                throw NodeSyncClientError.invalidResponse
            }
            guard let secondaryAuthority, let secondaryClient else { throw NodeSyncClientError.invalidResponse }
            // Matrix execution enters before the generic secondary bootstrap
            // path, so this independently-created authority has not yet
            // published an authenticated status. Confirm it here before
            // launching concurrent mutations; otherwise its capability gate
            // rejects the secondary operations while the primary requests
            // have already committed.
            stage("imap-matrix-\(matrixCase.selector)-secondary-status-confirmation-begin")
            let secondaryStatus = try await secondaryAuthority.status()
            guard secondaryStatus.state == "ready",
                  secondaryStatus.reachability == "reachable",
                  secondaryStatus.providerIdentity?.isEmpty == false else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-secondary-status-confirmation-end")
            // Add two independent fixture messages first, then use two
            // admitted authorities/Node sessions for four concurrent IMAP
            // mutations. This exercises provider concurrency while keeping
            // each final mailbox projection unambiguous.
            let appendBootstrap = try await client.delta(limit: 2)
            guard appendBootstrap.changes.isEmpty, !appendBootstrap.nextCursor.isEmpty else {
                throw NodeSyncClientError.invalidResponse
            }
            for _ in 0..<2 {
                try request(controlRoot, action: "imap-matrix-append-message")
                try await wait(controlRoot, action: "imap-matrix-append-message")
            }
            let appendDelta = try await waitForNonEmptyDelta(
                client: client,
                cursor: appendBootstrap.nextCursor,
                responseClassifier: nil
            )
            XCTAssertEqual(appendDelta.changes.count, 2, "concurrent IMAP mutations must observe both appended messages before targeting them")
            XCTAssertFalse(appendDelta.nextCursor.isEmpty, "concurrent IMAP mutation setup must advance its delta cursor")
            let concurrentSnapshot = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            guard let concurrentTargets = imapConcurrentMutationTargetsForTesting(
                messages: concurrentSnapshot.messages,
                readMessageID: message.id
            ) else { throw NodeSyncClientError.invalidResponse }
            let archiveMessage = concurrentTargets.archive
            let deleteMessage = concurrentTargets.delete
            async let read = authority.mutations.perform(.setRead(messageIDs: [MessageID(message.id)], read: true))
            async let label = secondaryAuthority.mutations.perform(.setLabels(messageIDs: [MessageID(message.id)], addLabelIDs: ["FLAGGED"], removeLabelIDs: []))
            async let archive = authority.mutations.perform(.archive(messageIDs: [MessageID(archiveMessage.id)]))
            async let delete = secondaryAuthority.mutations.perform(.delete(messageIDs: [MessageID(deleteMessage.id)]))
            let readResult = try await read
            let labelResult = try await label
            let archiveResult = try await archive
            let deleteResult = try await delete
            XCTAssertEqual(readResult.state, "applied")
            XCTAssertEqual(labelResult.state, "applied")
            XCTAssertEqual(archiveResult.state, "applied")
            XCTAssertEqual(deleteResult.state, "applied")
            stage("imap-matrix-\(matrixCase.selector)-projection-wait-begin")
            let projected = try await waitForConcurrentMutationProjectionForTesting(
                previous: concurrentSnapshot,
                readMessageID: message.id,
                archiveMessageID: archiveMessage.id,
                deleteMessageID: deleteMessage.id,
                archiveSubject: archiveMessage.subject,
                archiveTextBody: archiveMessage.textBody,
                deleteSubject: deleteMessage.subject,
                deleteTextBody: deleteMessage.textBody,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            stage("imap-matrix-\(matrixCase.selector)-projection-wait-end")
            XCTAssertTrue(projected.revision != concurrentSnapshot.revision, "concurrent IMAP mutations must publish an advanced projection revision")
            let secondarySnapshot = try await secondaryClient.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            XCTAssertEqual(Set(secondarySnapshot.messages.map(\.id)).count, secondarySnapshot.messages.count, "concurrent mutations must not duplicate projected messages")
            stage("imap-matrix-\(matrixCase.selector)-projection-committed")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        case "imap-stale-authority":
            guard let message = messages.first else { throw NodeSyncClientError.invalidResponse }
            let staleBaseline = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            let assignments = try await client.mailboxAssignments().assignments
            guard let assignment = assignments.first(where: { $0.role == "inbox" && $0.logicalMailboxID != nil }),
                  let logicalMailboxID = assignment.logicalMailboxID else {
                throw NodeSyncClientError.invalidResponse
            }
            let staleRead = !imapMessageIsSeenForTesting(flags: message.flags)
            let staleOperation = try client.signMutation(
                variant: .setRead(messageIDs: [message.id], read: staleRead),
                logicalMailboxID: logicalMailboxID,
                idempotencyKey: "imap-stale-authority"
            )
            stage("imap-matrix-\(matrixCase.selector)-old-session-prepared")
            try request(controlRoot, action: "imap-matrix-reset-uidvalidity")
            try await wait(controlRoot, action: "imap-matrix-reset-uidvalidity")
            stage("imap-matrix-\(matrixCase.selector)-provider-session-revision-wait-begin")
            let providerAfterReset = try await waitForRevisionChangeForTesting(
                currentRevision: staleBaseline.revision,
                pollAttempts: acceptanceProviderTransitionPollAttempts,
                pollDelayMilliseconds: acceptanceProviderTransitionPollDelayMilliseconds,
                snapshot: { try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit) },
                isTransient: { imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTAssertNotEqual(staleBaseline.revision, providerAfterReset.revision, "a new IMAP UIDVALIDITY must advance the provider session revision")
            stage("imap-matrix-\(matrixCase.selector)-provider-session-revision-changed")
            stage("imap-matrix-\(matrixCase.selector)-provider-session-replaced")
            let replacementContext = try await performAuthorityReplacement(authorityReplacement)
            stage("imap-matrix-\(matrixCase.selector)-authority-replaced")
            let replacementBaseline = try await replacementContext.client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            guard imapSnapshotMatchesExpectedForTesting(
                replacementBaseline,
                expectedMessages: nil,
                expectedRevision: nil,
                requireAcceptanceFixtureShape: true
            ), imapReplacementSnapshotMessagesMatchForTesting(
                actual: replacementBaseline.messages,
                expected: staleBaseline.messages
            ) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-replacement-baseline-complete")
            do {
                _ = try await client.mutation(canonicalOperation: staleOperation)
                XCTFail("stale IMAP session unexpectedly mutated after authority replacement")
            } catch let error as NodeSyncClientError {
                XCTAssertEqual(error, .problem(.unauthorized), "the replaced Node must reject the old authenticated session")
            } catch let error as NodeSessionError where error == .authenticationRejected {
                XCTFail("NodeSyncClient must map NodeSessionError.authenticationRejected to unauthorized")
            } catch {
                XCTFail("stale IMAP session failed through an unexpected typed seam")
            }
            stage("imap-matrix-\(matrixCase.selector)-old-session-rejected")
            let replacementAfterRejectedMutation = try await replacementContext.client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            XCTAssertEqual(
                replacementAfterRejectedMutation.revision,
                replacementBaseline.revision,
                "a rejected stale mutation must not commit a replacement projection revision"
            )
            XCTAssertEqual(
                replacementAfterRejectedMutation.messages,
                replacementBaseline.messages,
                "a rejected stale mutation must not alter the replacement target projection"
            )
            stage("imap-matrix-\(matrixCase.selector)-old-session-no-side-effect")
            try request(controlRoot, action: "imap-matrix-append-message")
            try await wait(controlRoot, action: "imap-matrix-append-message")
            let freshSnapshot = try await replacementContext.client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
            guard let freshMessage = freshSnapshot.messages.first else { throw NodeSyncClientError.invalidResponse }
            _ = try await replacementContext.authority.status()
            let freshResult = try await replacementContext.authority.mutations.perform(
                .setRead(messageIDs: [MessageID(freshMessage.id)], read: staleRead)
            )
            XCTAssertEqual(freshResult.state, "applied", "the replacement authority must admit a fresh IMAP mutation")
            let committed = try await waitForMessage(
                messages: replacementContext.authority.messages,
                id: MessageID(freshMessage.id)
            ) { $0.isSeen == staleRead }
            XCTAssertEqual(committed.isSeen, staleRead)
            stage("imap-matrix-\(matrixCase.selector)-replacement-session-applied")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        default:
            break
        }
        guard ["imap-attachment-fetch", "imap-truncated-literal", "imap-mime-boundaries"].contains(matrixCase.selector) else {
            throw NodeSyncClientError.invalidResponse
        }
        guard let message = messages.first(where: { !$0.attachments.isEmpty }),
              let attachment = message.attachments.first(where: { $0.filename == "fixture.bin" }) else {
            throw NodeSyncClientError.invalidResponse
        }
        if matrixCase.selector == "imap-mime-boundaries" {
            stage("imap-matrix-\(matrixCase.selector)-snapshot-success")
            stage("imap-matrix-\(matrixCase.selector)-metadata-begin")
            XCTAssertEqual(message.textBody.value, "Unicode acceptance body")
            XCTAssertEqual(message.htmlBody.value, "<p>Related HTML</p>")
            XCTAssertTrue(message.replyTo.isEmpty, "malformed Reply-To must be ignored without partial message projection")
            let attachmentsByName = Dictionary(uniqueKeysWithValues: message.attachments.map { ($0.filename, $0) })
            XCTAssertEqual(Set(attachmentsByName.keys), ["logo.png", "café.txt", "empty.bin", ".._.._secret.txt", "fixture.bin"])
            XCTAssertEqual(attachmentsByName["logo.png"]?.mime, "image/png")
            XCTAssertEqual(attachmentsByName["logo.png"]?.disposition, "inline")
            XCTAssertEqual(attachmentsByName["logo.png"]?.size, "4")
            XCTAssertEqual(attachmentsByName["logo.png"]?.contentDigest, nil)
            XCTAssertEqual(attachmentsByName["logo.png"]?.id.isEmpty, false)
            XCTAssertEqual(attachmentsByName["café.txt"]?.mime, "text/plain")
            XCTAssertEqual(attachmentsByName["café.txt"]?.disposition, "attachment")
            XCTAssertEqual(attachmentsByName["café.txt"]?.size, "4")
            XCTAssertEqual(attachmentsByName["empty.bin"]?.size, "0")
            XCTAssertEqual(attachmentsByName[".._.._secret.txt"]?.size, "4")
            XCTAssertEqual(attachmentsByName["fixture.bin"]?.size, "262144")
            XCTAssertEqual(attachmentsByName["fixture.bin"]?.mime, "application/octet-stream")
            XCTAssertEqual(attachmentsByName["fixture.bin"]?.disposition, "attachment")
            guard let logo = attachmentsByName["logo.png"],
                  let cafe = attachmentsByName["café.txt"],
                  let empty = attachmentsByName["empty.bin"],
                  let malicious = attachmentsByName[".._.._secret.txt"] else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-metadata-end")
            let expectedBytes: [(NodeSyncAttachment, Data)] = [
                (logo, Data([0x89, 0x50, 0x4e, 0x47])),
                (cafe, Data([0x63, 0x61, 0x66, 0xe9])),
                (empty, Data()),
                (malicious, Data("evil".utf8)),
            ]
            for (descriptor, expected) in expectedBytes {
                let attachmentClass: String
                switch descriptor.filename {
                case "logo.png": attachmentClass = "inline"
                case "café.txt": attachmentClass = "cafe"
                case "empty.bin": attachmentClass = "empty"
                case ".._.._secret.txt": attachmentClass = "sanitized"
                default: throw NodeSyncClientError.invalidResponse
                }
                stage("imap-matrix-\(matrixCase.selector)-\(attachmentClass)-open")
                let stream = try await authority.attachments.attachment(id: descriptor.id)
                let bytes = try await stream.readAll(maxBytes: expected.count)
                stage("imap-matrix-\(matrixCase.selector)-\(attachmentClass)-drain")
                XCTAssertEqual(bytes, expected, "MIME attachment bytes for \(descriptor.filename)")
                XCTAssertEqual(stream.metadata.byteCount, expected.count)
                XCTAssertEqual(stream.metadata.contentDigest, NodeSessionWire.encodeBase64URL(Data(SHA256.hash(data: expected))))
            }
            stage("imap-matrix-\(matrixCase.selector)-over-limit-open")
            let overLimit = try await authority.attachments.attachment(id: attachmentsByName["fixture.bin"]!.id)
            do {
                _ = try await overLimit.readAll(maxBytes: 262143)
                XCTFail("MIME attachment over-limit read unexpectedly succeeded")
            } catch let error as PlainpostError {
                XCTAssertEqual(error, .validationFailed("Attachment exceeds the allowed size."))
            }
            stage("imap-matrix-\(matrixCase.selector)-over-limit-drain")
            stage("imap-matrix-\(matrixCase.selector)-accepted-limit-open")
            let accepted = try await authority.attachments.attachment(id: attachmentsByName["fixture.bin"]!.id)
            let acceptedBytes = try await accepted.readAll(maxBytes: 262144)
            stage("imap-matrix-\(matrixCase.selector)-accepted-limit-drain")
            XCTAssertEqual(acceptedBytes, Data(repeating: 0, count: 262144))
            XCTAssertEqual(accepted.metadata.byteCount, 262144)
            XCTAssertEqual(accepted.metadata.contentDigest, "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA")
            stage("imap-matrix-\(matrixCase.selector)-message-projection-read-begin")
            let projected = try await authority.messages.message(id: MessageID(message.id))
            stage("imap-matrix-\(matrixCase.selector)-message-projection-read-end")
            XCTAssertEqual(projected.attachments.count, 5, "successful MIME projection must retain every valid attachment")
            XCTAssertEqual(Set(projected.attachments.map(\.filename)), Set(attachmentsByName.keys))
            stage("imap-matrix-\(matrixCase.selector)-malformed-header")
            stage("imap-matrix-\(matrixCase.selector)-over-limit")
            stage("imap-matrix-\(matrixCase.selector)-success")
            stage("imap-matrix-\(matrixCase.selector)-end")
            return
        }
        guard attachment.filename == "fixture.bin", attachment.mime == "application/octet-stream", attachment.disposition == "attachment", attachment.size == "262144", attachment.contentDigest == nil else {
            throw NodeSyncClientError.invalidResponse
        }
        guard let expectedFaultClass = imapMatrixExpectedAttachmentFaultClassForTesting(selector: matrixCase.selector) else {
            throw NodeSyncClientError.invalidResponse
        }
        let attachmentClient: NodeSyncClient
        if imapMatrixRequiresDedicatedAttachmentFaultProbeForTesting(selector: matrixCase.selector) {
            guard let attachmentFaultProbeClient else { throw NodeSyncClientError.invalidResponse }
            attachmentClient = attachmentFaultProbeClient
        } else {
            attachmentClient = client
        }
        let fetchTask: Task<Result<IMAPAttachmentFetchEvidence, Error>, Never> = Task {
            do {
                switch expectedFaultClass {
                case .disconnect:
                    let download = try await attachmentClient.attachment(id: attachment.id, metadata: attachment)
                    var data = Data()
                    for try await chunk in download.bytes {
                        data.append(chunk)
                    }
                    return .success(IMAPAttachmentFetchEvidence(metadata: download.metadata, bytes: data))
                case .truncated:
                    let download = try await attachmentClient.attachment(id: attachment.id, metadata: attachment)
                    var data = Data()
                    for try await chunk in download.bytes {
                        data.append(chunk)
                    }
                    return .success(IMAPAttachmentFetchEvidence(metadata: download.metadata, bytes: data))
                }
            } catch {
                return .failure(error)
            }
        }
        if matrixCase.phase != "none" {
            do {
                try await waitForMailPhase(matrixCase.phase, protocolName: matrixCase.protocolName, root: controlRoot)
                stage("imap-matrix-\(matrixCase.selector)-phase-reached")
                try request(controlRoot, action: "imap-matrix-resume")
                try await wait(controlRoot, action: "imap-matrix-resume")
            } catch {
                await cancelAndConsume(fetchTask)
                throw error
            }
        }
        let fetchResult = await fetchTask.value
        switch expectedFaultClass {
        case .disconnect:
            guard case let .failure(error) = fetchResult,
                  imapMatrixAttachmentFaultErrorIsExpectedForTesting(error) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-fault-error-\(imapMatrixAttachmentFaultErrorClassForTesting(error))")
            stage("imap-matrix-\(matrixCase.selector)-fault-class-\(expectedFaultClass.rawValue)")
            stage("imap-matrix-\(matrixCase.selector)-rejected")
        case .truncated:
            guard case let .failure(error) = fetchResult,
                  imapMatrixTruncatedLiteralErrorIsExpectedForTesting(error) else {
                throw NodeSyncClientError.invalidResponse
            }
            stage("imap-matrix-\(matrixCase.selector)-fault-error-\(imapMatrixTruncatedLiteralErrorClassForTesting(error))")
            stage("imap-matrix-\(matrixCase.selector)-fault-class-\(expectedFaultClass.rawValue)")
            stage("imap-matrix-\(matrixCase.selector)-rejected")
        }
        stage("imap-matrix-\(matrixCase.selector)-recovery-begin")
        var recoveredStream: MailAttachmentStream?
        var recoveredBytes: Data?
        var recoveryError: Error?
        var recoveryAttempts = 0
        for attempt in 1...imapMatrixRecoveryAttempts {
            recoveryAttempts = attempt
            do {
                let candidate = try await authority.attachments.attachment(id: attachment.id)
                let candidateBytes = try await candidate.readAll(maxBytes: 262144)
                recoveredStream = candidate
                recoveredBytes = candidateBytes
                break
            } catch {
                recoveryError = error
                guard Self.imapMatrixRecoveryErrorIsTransientForTesting(error) else { break }
                if attempt < imapMatrixRecoveryAttempts {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        stage("imap-matrix-\(matrixCase.selector)-recovery-attempts=\(recoveryAttempts)")
        guard let recovered = recoveredStream, let recoveredBytes else {
            throw recoveryError ?? NodeSyncClientError.transport
        }
        XCTAssertEqual(recoveredBytes, Data(repeating: 0, count: 262144))
        XCTAssertEqual(recovered.metadata.byteCount, 262144)
        XCTAssertEqual(NodeSessionWire.encodeBase64URL(Data(SHA256.hash(data: recoveredBytes))), "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA")
        var recoveredMessage: MessageSummary?
        recoveryError = nil
        var messageRecoveryAttempts = 0
        for attempt in 1...imapMatrixRecoveryAttempts {
            messageRecoveryAttempts = attempt
            do {
                recoveredMessage = try await authority.messages.message(id: MessageID(message.id))
                break
            } catch {
                recoveryError = error
                guard Self.imapMatrixRecoveryErrorIsTransientForTesting(error) else { break }
                if attempt < imapMatrixRecoveryAttempts {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        stage("imap-matrix-\(matrixCase.selector)-message-recovery-attempts=\(messageRecoveryAttempts)")
        guard let recoveredMessage else {
            throw recoveryError ?? NodeSyncClientError.transport
        }
        XCTAssertEqual(recoveredMessage.subject, "Plainpost acceptance é")
        XCTAssertEqual(recoveredMessage.body, "Unicode acceptance body")
        XCTAssertEqual(recoveredMessage.attachments.count, 1)
        XCTAssertEqual(recoveredMessage.attachments[0].filename, "fixture.bin")
        XCTAssertEqual(recoveredMessage.attachments[0].byteCount, 262144)
        let recoveredProjection = try await client.snapshot(after: nil, limit: acceptanceSnapshotPageLimit)
        guard imapAttachmentRecoveryProjectionMatchesForTesting(
            recoveredProjection.messages,
            fixtureDigest: imapMatrixExpectedAttachmentDigestForTesting(Data(repeating: 0, count: 262144))
        ) else {
            throw NodeSyncClientError.invalidResponse
        }
        stage("imap-matrix-\(matrixCase.selector)-complete-projection-recovered")
        stage("imap-matrix-\(matrixCase.selector)-recovery-end")
        stage("imap-matrix-\(matrixCase.selector)-end")
    }

    private static func runSMTPMatrixCase(
        _ matrixCase: SMTPMatrixCase,
        authority: PlainpostNodeMailAuthority,
        secondaryAuthority: PlainpostNodeMailAuthority?,
        client: NodeSyncClient,
        secondaryClient: NodeSyncClient?,
        logicalMailboxID: LogicalMailboxID,
        controlRoot: URL
    ) async throws {
        guard let accountID = authority.accountID else { throw NodeSyncClientError.invalidResponse }
        stage("smtp-matrix-\(matrixCase.selector)-begin")
        let draftID = runUnique("smtp-\(matrixCase.selector)")
        let draft = Draft(
            id: DraftID(draftID), accountID: accountID,
            from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [EmailAddress("blind@example.test")], subject: "smtp-matrix",
            bodyPlain: "smtp-matrix-body", createdBy: "acceptance", aiGenerated: false, sourceThreadID: nil
        )
        let rendered = try DraftRenderer().render(draft)
        let source = Data("\(rendered.headers)\r\n\r\n\(rendered.body)".utf8)
        let saved = try await authority.mutations.perform(.saveDraft(draft))
        XCTAssertEqual(saved.state, "applied")

        let draftState = try await client.draftState(id: draftID)
        let canonicalSend = try client.signMutation(
            variant: .send(draftID: draftID, expectedRevision: draftState.revision),
            logicalMailboxID: logicalMailboxID,
            idempotencyKey: runUnique("smtp-matrix-send")
        )

        if matrixCase.selector == "smtp-concurrent-sends" {
            guard let secondaryAuthority, let secondaryClient else { throw NodeSyncClientError.invalidResponse }
            let secondDraft = Draft(
                id: DraftID(runUnique("smtp-concurrent-secondary")), accountID: accountID,
                from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
                cc: [], bcc: [EmailAddress("blind-secondary@example.test")], subject: "smtp-matrix-secondary",
                bodyPlain: "smtp-matrix-secondary-body", createdBy: "acceptance", aiGenerated: false, sourceThreadID: nil
            )
            let secondarySaved = try await secondaryAuthority.mutations.perform(.saveDraft(secondDraft))
            XCTAssertEqual(secondarySaved.state, "applied")
            async let firstSend = authority.mutations.perform(.send(draft))
            async let secondSend = secondaryAuthority.mutations.perform(.send(secondDraft))
            let firstResult = try await firstSend
            let secondResult = try await secondSend
            XCTAssertEqual(firstResult.state, "applied")
            XCTAssertEqual(secondResult.state, "applied")
            stage("smtp-matrix-\(matrixCase.selector)-operation-applied")
            // The owner performs the bounded two-delivery count assertion from
            // the fixture authority; no response body or message bytes enter
            // the Swift stage log.
            stage("smtp-matrix-\(matrixCase.selector)-end")
            _ = client
            _ = secondaryClient
            return
        }

        if matrixCase.selector == "smtp-sent-append-failure" {
            // Arm the target-specific Sent APPEND fault only after Drafts has
            // been durably saved and the canonical send bytes are prepared.
            // This prevents an earlier Drafts APPEND from consuming it.
            try request(controlRoot, action: "arm-sent-append-failure")
            try await wait(controlRoot, action: "arm-sent-append-failure")
        }

        let operationTask: Task<SMTPMatrixOperationClass, Never> = Task {
            do {
                _ = try await authority.mutations.apply(canonicalOperation: canonicalSend)
                return Task.isCancelled ? .cancelled : .accepted
            } catch {
                return Task.isCancelled ? .cancelled : .deliveryUncertain
            }
        }
        if let phase = matrixCase.phase, ["smtp-cancel-before-data", "smtp-cancel-after-data", "smtp-sent-append-failure", "smtp-provider-restart-after-acceptance"].contains(matrixCase.selector) {
            let phaseProtocol = ["smtp-sent-append-failure", "smtp-provider-restart-after-acceptance"].contains(matrixCase.selector) ? "imap" : "smtp"
            try await waitForMailPhase(phase, protocolName: phaseProtocol, root: controlRoot)
            if matrixCase.selector == "smtp-cancel-before-data" || matrixCase.selector == "smtp-cancel-after-data" {
                operationTask.cancel()
                try request(controlRoot, action: "smtp-matrix-resume")
                try await wait(controlRoot, action: "smtp-matrix-resume")
            } else if matrixCase.selector == "smtp-sent-append-failure" {
                try request(controlRoot, action: "smtp-matrix-resume")
                try await wait(controlRoot, action: "smtp-matrix-resume")
            } else {
                // The IMAP Sent phase is reached only after the SMTP client
                // has received final 250 and the fixture has durably recorded
                // the delivery. Assert that boundary before restarting the
                // provider service that owns the pending Sent APPEND.
                try writeMailPostconditionExpectation(MailPostconditionExpectation(
                    checkpoint: "send-delivery", draftCount: 1, deliveryCount: 1, sentCount: 0,
                    envelopeSender: "acceptance@example.test",
                    envelopeRecipients: ["recipient@example.test", "blind@example.test"],
                    messageID: "<\(draftID)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(source),
                    bccHeaderAbsent: true, correlated: false
                ), root: controlRoot)
                try request(controlRoot, action: "mail-postcondition")
                try await wait(controlRoot, action: "mail-postcondition")
                try request(controlRoot, action: "restart-imap-fixture")
                try await wait(controlRoot, action: "restart-imap-fixture")
                try request(controlRoot, action: "smtp-matrix-resume")
                try await wait(controlRoot, action: "smtp-matrix-resume")
            }
        }
        let taskOutcome = await operationTask.value
        let tlsStartupFailure = ["smtp-untrusted-certificate", "smtp-same-ca-wrong-host", "smtp-tls1.1", "smtp-auth-before-starttls"].contains(matrixCase.selector)
        if tlsStartupFailure {
            // The startup failure must be observed before the fixture is
            // restored; otherwise a later successful AUTH could mask a
            // credential-bearing command emitted during the failed attempt.
            try request(controlRoot, action: "smtp-matrix-assert-authentication-command")
            try await wait(controlRoot, action: "smtp-matrix-assert-authentication-command")
        }
        var retryAttempts = 0
        if matrixCase.retryEligible {
            XCTAssertEqual(taskOutcome, .cancelled, "retry-eligible SMTP case must retain its initial cancellation outcome")
            retryAttempts = 1
            let retryResult = try await authority.mutations.apply(canonicalOperation: canonicalSend)
            XCTAssertEqual(retryResult.state, "applied", "retry-eligible SMTP case must safely replay canonical bytes")
        }
        if matrixCase.selector == "smtp-provider-restart-after-acceptance", taskOutcome != .accepted {
            // Reconcile the exact signed bytes after the provider restart;
            // generating a fresh idempotency key here would risk a duplicate.
            _ = try? await authority.mutations.apply(canonicalOperation: canonicalSend)
        }
        XCTAssertEqual(retryAttempts, matrixCase.retryEligible ? 1 : 0, "non-retryable SMTP cases must not execute a retry path")
        stage("smtp-matrix-\(matrixCase.selector)-retry-attempts=\(retryAttempts)")
        let terminal = try await client.mutation(canonicalOperation: canonicalSend)
        guard let observedOperationClass = smtpMatrixOperationClass(for: terminal.state) else {
            XCTFail("SMTP matrix operation remained non-terminal: \(terminal.state)")
            throw NodeSyncClientError.invalidResponse
        }
        XCTAssertEqual(observedOperationClass, matrixCase.operationClass, "SMTP matrix operation class diverged from the hand-derived contract")
        XCTAssertEqual(taskOutcome == .cancelled, matrixCase.initialCancellationObserved, "SMTP matrix initial task cancellation diverged from the typed contract")
        let observedRestartResult: SMTPMatrixRestartResult = switch observedOperationClass {
        case .accepted: .accepted
        case .deliveryUncertain: .uncertain
        case .rejected, .temporary, .cancelled: .none
        }
        XCTAssertEqual(observedRestartResult, matrixCase.restartResult, "SMTP matrix restart result diverged from the typed contract")

        if tlsStartupFailure {
            try request(controlRoot, action: "restore-smtp-fixture-normal")
            try await wait(controlRoot, action: "restore-smtp-fixture-normal")
            let recoveryID = runUnique("smtp-\(matrixCase.selector)-recovery")
            let recoveryDraft = Draft(
                id: DraftID(recoveryID), accountID: accountID,
                from: EmailAddress("acceptance@example.test"), to: [EmailAddress("recipient@example.test")],
                cc: [], bcc: [EmailAddress("blind@example.test")], subject: "smtp-tls-recovery",
                bodyPlain: "smtp-tls-recovery-body", createdBy: "acceptance", aiGenerated: false, sourceThreadID: nil
            )
            let recoverySaved = try await authority.mutations.perform(.saveDraft(recoveryDraft))
            XCTAssertEqual(recoverySaved.state, "applied")
            let recoveryResult = try await authority.mutations.perform(.send(recoveryDraft))
            XCTAssertEqual(recoveryResult.state, "applied")
            let recoveryRendered = try DraftRenderer().render(recoveryDraft)
            let recoverySource = Data("\(recoveryRendered.headers)\r\n\r\n\(recoveryRendered.body)".utf8)
            try writeMailPostconditionExpectation(MailPostconditionExpectation(
                checkpoint: "send-delivery", draftCount: 0, deliveryCount: 1, sentCount: 1,
                envelopeSender: "acceptance@example.test",
                envelopeRecipients: ["recipient@example.test", "blind@example.test"],
                messageID: "<\(recoveryID)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(recoverySource),
                bccHeaderAbsent: true, correlated: true
            ), root: controlRoot)
            try request(controlRoot, action: "mail-postcondition")
            try await wait(controlRoot, action: "mail-postcondition")
            stage("smtp-matrix-\(matrixCase.selector)-recovery-applied")
            stage("smtp-matrix-\(matrixCase.selector)-end")
            return
        }

        if matrixCase.deliveryCount == 0 {
            try await assertDraftPostcondition(draft, checkpoint: "draft-created", draftCount: matrixCase.draftCount, controlRoot: controlRoot)
        } else {
            try writeMailPostconditionExpectation(MailPostconditionExpectation(
                checkpoint: "send-delivery", draftCount: matrixCase.draftCount, deliveryCount: matrixCase.deliveryCount,
                sentCount: matrixCase.sentCount, envelopeSender: "acceptance@example.test",
                envelopeRecipients: ["recipient@example.test", "blind@example.test"],
                messageID: "<\(draftID)@plainpost.local>", canonicalDigest: CanonicalMailSource.digestHex(source),
                bccHeaderAbsent: true, correlated: matrixCase.sentCount == 1
            ), root: controlRoot)
            try request(controlRoot, action: "mail-postcondition")
            try await wait(controlRoot, action: "mail-postcondition")
        }
        stage("smtp-matrix-\(matrixCase.selector)-end")
        _ = client
        _ = logicalMailboxID
    }

    private static func waitForMailPhase(
        _ phase: String,
        protocolName: String = "smtp",
        occurrence: Int = 1,
        root: URL
    ) async throws {
        guard let stateRoot = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_STATE_ROOT"], !stateRoot.isEmpty else {
            throw NodeSyncClientError.invalidResponse
        }
        try await waitForMailPhaseForTesting(
            phase,
            protocolName: protocolName,
            occurrence: occurrence,
            observationFile: URL(fileURLWithPath: stateRoot).appendingPathComponent("mail-observations.jsonl"),
            pollAttempts: 240,
            pollDelayMilliseconds: 250
        )
    }

    private static func waitForActiveIMAPIdle(root: URL) async throws {
        guard let stateRoot = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_ACCEPTANCE_MAIL_STATE_ROOT"], !stateRoot.isEmpty else {
            throw NodeSyncClientError.invalidResponse
        }
        try await waitForActiveIMAPIdleForTesting(URL(fileURLWithPath: stateRoot))
    }

    static func waitForActiveIMAPIdleForTesting(
        _ stateRoot: URL,
        pollAttempts: Int = 240,
        pollDelayMilliseconds: Int = 250
    ) async throws {
        guard stateRoot.lastPathComponent != "mail-control.json",
              (1...240).contains(pollAttempts),
              (0...30_000).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        let control = stateRoot.appendingPathComponent("mail-control.json")
        for _ in 0..<pollAttempts {
            if let data = try? Data(contentsOf: control),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let activeCount = value["imap_idle_active_inbox_count"] as? Int,
               activeCount > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
        }
        throw NodeSyncClientError.transport
    }

    static func waitForMailPhaseForTesting(
        _ phase: String,
        protocolName: String = "smtp",
        occurrence: Int = 1,
        observationFile: URL,
        pollAttempts: Int,
        pollDelayMilliseconds: Int
    ) async throws {
        guard observationFile.lastPathComponent == "mail-observations.jsonl",
              ["smtp", "imap"].contains(protocolName),
              (1...1000).contains(occurrence),
              (1...1000).contains(pollAttempts), (0...30_000).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        for _ in 0..<pollAttempts {
            if let data = try? Data(contentsOf: observationFile), let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          value["kind"] as? String == "phase-reached",
                          value["protocol"] as? String == protocolName,
                          value["phase"] as? String == phase,
                          value["occurrence"] as? Int == occurrence else { continue }
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
        }
        throw NodeSyncClientError.transport
    }

    static func waitForRevisionChangeForTesting(
        currentRevision: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        snapshot: @escaping @Sendable () async throws -> NodeSyncSnapshotPage,
        isTransient: @escaping @Sendable (Error) -> Bool
    ) async throws -> NodeSyncSnapshotPage {
        guard !currentRevision.isEmpty,
              (1...acceptanceProviderTransitionPollAttempts).contains(pollAttempts),
              (0...acceptanceProviderTransitionPollDelayMilliseconds).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        for attempt in 0..<pollAttempts {
            do {
                let page = try await snapshot()
                if page.revision != currentRevision { return page }
            } catch {
                guard isTransient(error) else { throw error }
            }
            if attempt + 1 < pollAttempts, pollDelayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        throw NodeSyncClientError.transport
    }

    static func waitForUIDValidityReplacementForTesting(
        previous: NodeSyncSnapshotPage,
        expectedMessageIDs: Set<String>? = nil,
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        snapshot: @escaping @Sendable () async throws -> NodeSyncSnapshotPage,
        isTransient: @escaping @Sendable (Error) -> Bool
    ) async throws -> NodeSyncSnapshotPage {
        guard !previous.revision.isEmpty,
              (1...acceptanceProviderTransitionPollAttempts).contains(pollAttempts),
              (0...acceptanceProviderTransitionPollDelayMilliseconds).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        var lastMismatchClass = "no-snapshot"
        var emittedMismatchClass: String?
        for attempt in 0..<pollAttempts {
            do {
                let page = try await snapshot()
                lastMismatchClass = imapUIDValidityReplacementMismatchClassForTesting(
                    actual: page,
                    previous: previous,
                    currentRevision: previous.revision,
                    expectedMessageIDs: expectedMessageIDs
                )
                if lastMismatchClass == "matched" { return page }
                if lastMismatchClass == "stable-content" {
                    lastMismatchClass += "-" + imapUIDValidityStableContentMismatchClassForTesting(
                        actual: page,
                        previous: previous
                    )
                }
                if imapUIDValidityMismatchClassShouldEmitForTesting(
                    previous: emittedMismatchClass,
                    current: lastMismatchClass
                ) {
                    stage("imap-uidvalidity-replacement-mismatch-\(lastMismatchClass)")
                    emittedMismatchClass = lastMismatchClass
                }
            } catch {
                guard isTransient(error) else { throw error }
                lastMismatchClass = "transient-error"
                if imapUIDValidityMismatchClassShouldEmitForTesting(
                    previous: emittedMismatchClass,
                    current: lastMismatchClass
                ) {
                    stage("imap-uidvalidity-replacement-mismatch-\(lastMismatchClass)")
                    emittedMismatchClass = lastMismatchClass
                }
            }
            if attempt + 1 < pollAttempts, pollDelayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        if imapUIDValidityMismatchClassShouldEmitForTesting(
            previous: emittedMismatchClass,
            current: lastMismatchClass
        ) {
            stage("imap-uidvalidity-replacement-mismatch-\(lastMismatchClass)")
        }
        throw NodeSyncClientError.transport
    }

    static func waitForSnapshotMatchingForTesting(
        currentRevision: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        snapshot: @escaping @Sendable () async throws -> NodeSyncSnapshotPage,
        isTransient: @escaping @Sendable (Error) -> Bool,
        matches: @escaping @MainActor @Sendable (NodeSyncSnapshotPage) -> Bool
    ) async throws -> NodeSyncSnapshotPage {
        guard !currentRevision.isEmpty,
              (1...acceptanceProviderTransitionPollAttempts).contains(pollAttempts),
              (0...acceptanceProviderTransitionPollDelayMilliseconds).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        for attempt in 0..<pollAttempts {
            do {
                let page = try await snapshot()
                if matches(page) { return page }
            } catch {
                guard isTransient(error) else { throw error }
            }
            if attempt + 1 < pollAttempts, pollDelayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        throw NodeSyncClientError.transport
    }

    static func waitForAcceptanceFixtureSnapshotForTesting(
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        snapshot: @escaping @Sendable () async throws -> NodeSyncSnapshotPage,
        isTransient: @escaping @Sendable (Error) -> Bool
    ) async throws -> NodeSyncSnapshotPage {
        guard (1...acceptanceProviderTransitionPollAttempts).contains(pollAttempts),
              (0...acceptanceProviderTransitionPollDelayMilliseconds).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        for attempt in 0..<pollAttempts {
            do {
                let page = try await snapshot()
                if imapSnapshotMatchesExpectedForTesting(
                    page,
                    expectedMessages: nil,
                    expectedRevision: nil,
                    requireAcceptanceFixtureShape: true
                ) {
                    return page
                }
            } catch {
                guard isTransient(error) else { throw error }
            }
            if attempt + 1 < pollAttempts, pollDelayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        throw NodeSyncClientError.transport
    }

    static func waitForConcurrentMutationProjectionForTesting(
        previous: NodeSyncSnapshotPage,
        readMessageID: String,
        archiveMessageID: String,
        deleteMessageID: String,
        archiveSubject: String,
        archiveTextBody: NodeSyncBody,
        deleteSubject: String,
        deleteTextBody: NodeSyncBody,
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        snapshot: @escaping @Sendable () async throws -> NodeSyncSnapshotPage,
        isTransient: @escaping @Sendable (Error) -> Bool
    ) async throws -> NodeSyncSnapshotPage {
        guard !previous.revision.isEmpty,
              (1...acceptanceProviderTransitionPollAttempts).contains(pollAttempts),
              (0...acceptanceProviderTransitionPollDelayMilliseconds).contains(pollDelayMilliseconds) else {
            throw NodeSyncClientError.invalidResponse
        }
        var lastMismatchClass = "no-snapshot"
        var emittedMismatchClass: String?
        for attempt in 0..<pollAttempts {
            do {
                let page = try await snapshot()
                lastMismatchClass = imapConcurrentMutationMismatchClassForTesting(
                    actual: page,
                    previous: previous,
                    currentRevision: previous.revision,
                    readMessageID: readMessageID,
                    archiveMessageID: archiveMessageID,
                    deleteMessageID: deleteMessageID,
                    archiveSubject: archiveSubject,
                    archiveTextBody: archiveTextBody,
                    deleteSubject: deleteSubject,
                    deleteTextBody: deleteTextBody
                )
                if lastMismatchClass == "matched" { return page }
            } catch {
                guard isTransient(error) else { throw error }
                lastMismatchClass = "transient-error"
            }
            if imapConcurrentMutationMismatchClassShouldEmitForTesting(
                previous: emittedMismatchClass,
                current: lastMismatchClass
            ) {
                stage("imap-concurrent-mutations-projection-mismatch-\(lastMismatchClass)")
                emittedMismatchClass = lastMismatchClass
            }
            if attempt + 1 < pollAttempts, pollDelayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        if imapConcurrentMutationMismatchClassShouldEmitForTesting(
            previous: emittedMismatchClass,
            current: lastMismatchClass
        ) {
            stage("imap-concurrent-mutations-projection-mismatch-\(lastMismatchClass)")
        }
        throw NodeSyncClientError.transport
    }

    static func smtpMatrixOperationClass(for state: String) -> SMTPMatrixOperationClass? {
        switch state {
        case "applied": return .accepted
        case "rejected", "conflicted": return .rejected
        case "delivery_uncertain": return .deliveryUncertain
        default: return nil
        }
    }

    static func requestSMTPMatrixResumeForTesting(_ root: URL) throws {
        try request(root, action: "smtp-matrix-resume")
    }

    static func requestIMAPMatrixResumeForTesting(_ root: URL) throws {
        try request(root, action: "imap-matrix-resume")
    }

    private static func stage(_ name: String) {
        let line = Data("ERROR swift-stage stage=\(name)\n".utf8)
        if let path = ProcessInfo.processInfo.environment["PLAINPOST_SYNC_NODE_STAGE_LOG"], !path.isEmpty {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: path) {
                _ = fileManager.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            }
        }
        FileHandle.standardError.write(line)
    }

    private static func statusWithPostDispatchRecovery<T>(label: String, client: NodeSyncClient, operation: () async throws -> T) async throws -> (value: T, recovered: Bool) {
        do {
            return (try await operation(), false)
        } catch let error as NodeSyncClientError where error == .transportAfterDispatch {
            stage("response-drop-\(label)-observed")
            stage("response-drop-\(label)-exact-replay-begin")
            do {
                guard try await client.reconcilePendingRequest() == nil else {
                    throw NodeSyncClientError.invalidResponse
                }
                throw NodeSyncClientError.invalidResponse
            } catch let error as NodeSyncClientError where error == .transport {
                // NodeSessionTransport reports the strict middleware's
                // sequence-consumed 409 as application uncertainty, which
                // NodeSyncClient maps to transport. Only this exact mapped
                // outcome permits the fresh status request below.
            }
            stage("response-drop-\(label)-exact-replay-end")
            let value = try await operation()
            stage("response-drop-\(label)-fresh-commit")
            return (value, true)
        }
    }

    private static func runUnique(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private static func request(_ root: URL, action: String) throws {
        guard let filename = controlFileName(action: action, phase: "request") else {
            throw NodeSyncClientError.invalidResponse
        }
        let path = root.appendingPathComponent(filename)
        for phase in ["applied", "failed"] {
            if let terminal = controlFileName(action: action, phase: phase) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(terminal))
            }
        }
        guard FileManager.default.createFile(atPath: path.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw NodeSyncClientError.transport
        }
    }

    nonisolated static func status(_ status: SyncNodeStatus, matches selections: [SyncNodeMailboxSelection], providerIdentity: String) -> Bool {
        guard status.state == "ready",
              status.reachability == "reachable",
              status.providerIdentity == providerIdentity,
              status.assignments.count == selections.count else { return false }
        let expected = Set(selections.map(ScenarioAssignmentFingerprint.init))
        let actual = Set(status.assignments.map(ScenarioAssignmentFingerprint.init))
        return expected.count == selections.count && actual.count == status.assignments.count && expected == actual
    }

    private struct ScenarioAssignmentFingerprint: Hashable, Sendable {
        let displayName: String
        let mailboxHandle: String
        let role: String
        let logicalMailboxID: String

        init(_ selection: SyncNodeMailboxSelection) {
            displayName = selection.displayName
            mailboxHandle = selection.mailboxHandle
            role = selection.role
            logicalMailboxID = selection.logicalMailboxID?.rawValue.base64EncodedString() ?? ""
        }

        init(_ mailbox: SyncNodeProviderMailbox) {
            displayName = mailbox.displayName
            mailboxHandle = mailbox.mailboxHandle
            role = mailbox.role
            logicalMailboxID = mailbox.logicalMailboxID?.rawValue.base64EncodedString() ?? ""
        }
    }

    private static func wait(_ root: URL, action: String) async throws {
        try await wait(
            root,
            action: action,
            pollAttempts: acceptanceControlSignalPollAttempts,
            pollDelayMilliseconds: 250
        )
    }

    static func waitForControlSignalForTesting(
        _ root: URL,
        action: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int
    ) async throws {
        try await wait(
            root,
            action: action,
            pollAttempts: pollAttempts,
            pollDelayMilliseconds: pollDelayMilliseconds
        )
    }

    private static func wait(
        _ root: URL,
        action: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int
    ) async throws {
        let observation = try await observeControlSignal(
            root,
            action: action,
            pollAttempts: pollAttempts,
            pollDelayMilliseconds: pollDelayMilliseconds
        )
        if observation == .failed {
            stage(action == "attachment-release-probe" ? "attachment-release-failed" : "\(action)-failed")
            throw NodeSyncClientError.transport
        }
    }

    static func observeControlSignalForTesting(
        _ root: URL,
        action: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int
    ) async throws -> ControlSignalObservation {
        try await observeControlSignal(
            root,
            action: action,
            pollAttempts: pollAttempts,
            pollDelayMilliseconds: pollDelayMilliseconds
        )
    }

    private static func observeControlSignal(
        _ root: URL,
        action: String,
        pollAttempts: Int,
        pollDelayMilliseconds: Int
    ) async throws -> ControlSignalObservation {
        guard let filename = controlFileName(action: action, phase: "applied") else {
            throw NodeSyncClientError.invalidResponse
        }
        let path = root.appendingPathComponent(filename)
        let failedPath = controlFileName(action: action, phase: "failed").map(root.appendingPathComponent)
        for _ in 0..<pollAttempts {
            if FileManager.default.fileExists(atPath: path.path) { return .applied }
            if let failedPath, FileManager.default.fileExists(atPath: failedPath.path) {
                return .failed
            }
            try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
        }
        throw NodeSyncClientError.transport
    }

    // The shell controller and this process intentionally share these exact
    // action.phase names. Keep the allowlist closed so a caller cannot turn a
    // client-controlled action into an arbitrary filesystem path.
    private static func controlFileName(action: String, phase: String) -> String? {
        guard ["provider-transition", "attachment-release-probe", "release-backup-restore", "restart-node", "restart-imap-fixture", "restart-smtp-fixture", "mail-postcondition", "smtp-matrix-resume", "imap-matrix-resume", "imap-matrix-reset-uidvalidity", "imap-matrix-assert-authentication", "imap-matrix-arm-authentication", "imap-matrix-arm-tls-failure", "imap-matrix-append-message", "imap-matrix-assert-no-idle", "imap-matrix-catalog-probe", "imap-matrix-fetch-probe", "imap-matrix-delayed-literal-probe", "imap-matrix-arm-provider-restart", "arm-sent-append-failure", "smtp-matrix-assert-no-auth", "smtp-matrix-assert-authentication-command", "restore-smtp-fixture-normal", "restore-imap-fixture-normal"].contains(action), ["request", "applied", "failed"].contains(phase) else {
            return nil
        }
        return "\(action).\(phase)"
    }

    private static func readIMAPProviderRestartOccurrence(_ root: URL) throws -> Int {
        let path = root.appendingPathComponent("imap-matrix-arm-provider-restart.result", isDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw NodeSyncClientError.invalidResponse
        }
        let data = try Data(contentsOf: path)
        guard data.count >= 2, data.last == 0x0A,
              data.dropLast().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw NodeSyncClientError.invalidResponse
        }
        let text = String(decoding: data.dropLast(), as: UTF8.self)
        guard let occurrence = Int(text), (1...1000).contains(occurrence) else {
            throw NodeSyncClientError.invalidResponse
        }
        return occurrence
    }

    static func waitForNonEmptyDeltaForTesting(
        pollAttempts: Int,
        pollDelayMilliseconds: Int,
        responseClassifier: AcceptanceResponseClassifier? = nil,
        fetch: @escaping @Sendable () async throws -> NodeSyncDeltaPage
    ) async throws -> NodeSyncDeltaPage {
        guard pollAttempts > 0, pollDelayMilliseconds >= 0 else { throw NodeSyncClientError.invalidResponse }
        for attempt in 0..<pollAttempts {
            do {
                let page = try await fetch()
                if !page.changes.isEmpty { return page }
            } catch {
                if let responseClassifier {
                    let responseSummary = await responseClassifier.summary()
                    stage("delta-transition-error-class=operation-\(responseSummary)")
                }
                guard imapMatrixRecoveryErrorIsTransientForTesting(error) else { throw error }
                if attempt == pollAttempts - 1 { throw error }
            }
            if attempt < pollAttempts - 1 {
                try await Task.sleep(for: .milliseconds(pollDelayMilliseconds))
            }
        }
        throw NodeSyncClientError.transport
    }

    private static func waitForNonEmptyDelta(client: NodeSyncClient, cursor: String, responseClassifier: AcceptanceResponseClassifier?) async throws -> NodeSyncDeltaPage {
        // The generic provider shares one session across the six seeded
        // mailboxes and uses the production one-minute default poll cadence.
        // Allow one complete cycle plus a bounded scheduling margin; this
        // remains a finite acceptance wait and does not change production poll
        // limits.
        return try await waitForNonEmptyDeltaForTesting(
            pollAttempts: acceptanceProviderTransitionPollAttempts,
            pollDelayMilliseconds: 250,
            responseClassifier: responseClassifier,
            fetch: { try await client.delta(after: cursor, limit: 2) },
        )
    }

    private static func waitForAppendDeltaSequence(
        client: NodeSyncClient,
        cursor: String,
        responseClassifier: AcceptanceResponseClassifier?
    ) async throws -> [NodeSyncDeltaPage] {
        var pages = [try await waitForNonEmptyDelta(client: client, cursor: cursor, responseClassifier: responseClassifier)]
        var nextCursor = pages[0].nextCursor
        for _ in 0..<imapMatrixRecoveryAttempts {
            let page = try await waitForDeltaPage(client: client, cursor: nextCursor, responseClassifier: responseClassifier)
            if page.changes.isEmpty {
                return pages
            }
            pages.append(page)
            nextCursor = page.nextCursor
        }
        throw NodeSyncClientError.transport
    }

    private static func waitForDeltaPage(client: NodeSyncClient, cursor: String, responseClassifier: AcceptanceResponseClassifier?) async throws -> NodeSyncDeltaPage {
        for attempt in 0..<imapMatrixRecoveryAttempts {
            do {
                return try await client.delta(after: cursor, limit: 2)
            } catch {
                if let responseClassifier {
                    let responseSummary = await responseClassifier.summary()
                    stage("delta-transition-error-class=operation-\(responseSummary)")
                }
                guard imapMatrixRecoveryErrorIsTransientForTesting(error) else { throw error }
                if attempt == imapMatrixRecoveryAttempts - 1 { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw NodeSyncClientError.transport
    }

    private static func waitForMessage(messages: any MailMessageServing, id: MessageID, matching: (MessageSummary) -> Bool) async throws -> MessageSummary {
        for _ in 0..<acceptanceProviderTransitionPollAttempts {
            do {
                let message = try await messages.message(id: id)
                if matching(message) { return message }
            } catch let error as PlainpostError {
                guard case .notFound = error else { throw error }
                // The provider projection may replace a record while its
                // mailbox transition is being committed; keep the bound.
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NodeSyncClientError.transport
    }

    static func waitForTerminalMutation(client: NodeSyncClient, canonicalOperation: Data, stagePrefix: String) async throws -> NodeSyncMutationResult {
        var pendingAttempts = 0
        for _ in 0..<acceptanceProviderTransitionPollAttempts {
            let result = try await client.mutation(canonicalOperation: canonicalOperation)
            if result.state != "pending" {
                stage("\(stagePrefix)-terminal-state=\(result.state)-pending-attempts=\(pendingAttempts)")
                return result
            }
            pendingAttempts += 1
            try await Task.sleep(for: .milliseconds(250))
        }
        stage("\(stagePrefix)-terminal-timeout-pending-attempts=\(pendingAttempts)")
        throw NodeSyncClientError.transport
    }

    private static func waitForMailboxReplacement(
        snapshots: any MailSnapshotServing,
        messages: any MailMessageServing,
        original: MessageSummary,
        requiredLabel: String,
        alternateLabel: String? = nil
    ) async throws -> MessageSummary {
        for _ in 0..<acceptanceProviderTransitionPollAttempts {
            var originalGone = false
            do { _ = try await messages.message(id: original.id) }
            catch let error as PlainpostError {
                guard case .notFound = error else { throw error }
                originalGone = true
            }
            if originalGone {
                let page = try await snapshots.snapshot(after: nil, limit: 50)
                if let replacement = page.messages.first(where: { candidate in
                    candidate.id != original.id &&
                    candidate.subject == original.subject &&
                    candidate.body == original.body &&
                    (candidate.labels.contains(requiredLabel) || (alternateLabel.map { alternate in candidate.labels.contains(alternate) } ?? false))
                }) {
                    return replacement
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NodeSyncClientError.transport
    }

    private static func waitForInitialSnapshot(client: NodeSyncClient, responseClassifier: AcceptanceResponseClassifier?) async throws -> NodeSyncSnapshotPage {
        var attempts = 0
        var unavailable = 0
        var transport = 0
        var empty = 0
        for _ in 0..<acceptanceProviderTransitionPollAttempts {
            attempts += 1
            do {
                let page = try await client.snapshot(limit: 2)
                if !page.messages.isEmpty {
                    return page
                }
                empty += 1
            } catch NodeSyncClientError.problem(.unavailable) {
                // ClientAPI admission intentionally opens before the first
                // provider baseline; retry until the real projection exists.
                unavailable += 1
            } catch NodeSyncClientError.transport {
                // A just-started TLS listener can still be between restarts.
                transport += 1
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let transportSummary: String
        if let responseClassifier {
            transportSummary = await responseClassifier.summary()
        } else {
            transportSummary = "status-untracked-transport=0"
        }
        stage("snapshot-initial-timeout-attempts=\(attempts)-unavailable=\(unavailable)-transport=\(transport)-empty=\(empty)-responses=\(transportSummary)")
        throw NodeSyncClientError.transport
    }
}
