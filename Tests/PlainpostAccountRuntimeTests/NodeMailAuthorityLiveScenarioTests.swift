import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

@MainActor
final class NodeMailAuthorityLiveScenarioTests: XCTestCase {
    func testIMAPCanonicalSeenFlagUsesNodeProjectionValue() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMessageIsSeenForTesting(flags: ["seen"]))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMessageIsSeenForTesting(flags: ["\\Seen"]))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMessageIsSeenForTesting(flags: []))
    }

    func testIMAPConcurrentMutationMismatchClassifierUsesClosedOrderedCategories() throws {
        func message(
            id: String,
            subject: String,
            body: String,
            flags: [String] = [],
            labels: [String] = ["INBOX"]
        ) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [], bcc: [], cc: [], flags: flags,
                from: [], htmlBody: NodeSyncBody(state: .absent, value: nil), id: id,
                inReplyTo: [], labels: labels, receivedAt: "2026-09-02T00:00:00Z", references: [],
                replyTo: [], sentAt: nil, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: body), threadID: "thread-\(id)", to: []
            )
        }
        let oldRead = message(id: "read-old", subject: "Read", body: "read")
        let oldArchive = message(id: "archive-old", subject: "Archive", body: "archive")
        let oldDelete = message(id: "delete-old", subject: "Delete", body: "delete")
        let untouched = message(id: "untouched", subject: "Untouched", body: "untouched")
        let previous = try NodeSyncSnapshotPage(
            messages: [oldRead, oldArchive, oldDelete, untouched], nextCursor: "", revision: "7"
        )
        func actual(
            archiveLabel: String = "ARCHIVE",
            readFlags: [String] = ["seen"],
            readLabels: [String] = ["FLAGGED", "INBOX"],
            archiveID: String = "archive-new",
            deleteID: String = "delete-new",
            extra: NodeSyncMessage? = nil,
            revision: String = "8"
        ) throws -> NodeSyncSnapshotPage {
            try NodeSyncSnapshotPage(
                messages: [
                    message(id: "read-old", subject: "Read", body: "read", flags: readFlags, labels: readLabels),
                    message(id: archiveID, subject: "Archive", body: "archive", labels: [archiveLabel]),
                    message(id: deleteID, subject: "Delete", body: "delete", labels: ["TRASH"]),
                    extra ?? untouched
                ], nextCursor: "", revision: revision
            )
        }
        func page(_ messages: [NodeSyncMessage], revision: String = "8") throws -> NodeSyncSnapshotPage {
            try NodeSyncSnapshotPage(messages: messages, nextCursor: "", revision: revision)
        }
        func classify(_ page: NodeSyncSnapshotPage, archiveID: String = "archive-old", deleteID: String = "delete-old") -> String {
            NodeMailAuthorityLiveScenario.imapConcurrentMutationMismatchClassForTesting(
                actual: page, previous: previous, currentRevision: previous.revision,
                readMessageID: "read-old", archiveMessageID: archiveID, deleteMessageID: deleteID,
                archiveSubject: "Archive", archiveTextBody: oldArchive.textBody,
                deleteSubject: "Delete", deleteTextBody: oldDelete.textBody
            )
        }
        XCTAssertEqual(classify(try actual(revision: "7")), "revision")
        let base = try actual()
        XCTAssertEqual(classify(try page(Array(base.messages.dropLast()))), "count")
        XCTAssertEqual(classify(try actual(extra: message(id: "read-old", subject: "Extra", body: "extra"))), "duplicate-ids")
        XCTAssertEqual(
            classify(try page(base.messages.map { $0.id == "read-old" ? message(id: "read-other", subject: "Read", body: "read") : $0 })),
            "read-missing"
        )
        XCTAssertEqual(
            classify(try page(base.messages.map { $0.id == "archive-new" ? message(id: "archive-new", subject: "Wrong", body: "archive", labels: ["ARCHIVE"]) : $0 })),
            "archive-missing"
        )
        XCTAssertEqual(
            classify(try page(base.messages.map { $0.id == "delete-new" ? message(id: "delete-new", subject: "Wrong", body: "delete", labels: ["TRASH"]) : $0 })),
            "delete-missing"
        )
        XCTAssertEqual(classify(try actual(extra: message(id: "archive-old", subject: "Old", body: "old"))), "old-archive-present")
        XCTAssertEqual(classify(try actual(extra: message(id: "delete-old", subject: "Old", body: "old"))), "old-delete-present")
        XCTAssertEqual(classify(try actual(), archiveID: "same-target", deleteID: "same-target"), "target-collision")
        XCTAssertEqual(classify(try actual(readFlags: [])), "seen-missing")
        XCTAssertEqual(classify(try actual(readLabels: ["INBOX"])), "flagged-missing")
        XCTAssertEqual(classify(try actual(archiveLabel: "ARCHIVE")), "matched")
        XCTAssertEqual(classify(try actual(archiveLabel: "ALL")), "matched")
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapConcurrentMutationMismatchClassShouldEmitForTesting(previous: nil, current: "count"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapConcurrentMutationMismatchClassShouldEmitForTesting(previous: "count", current: "count"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapConcurrentMutationMismatchClassShouldEmitForTesting(previous: "count", current: "matched"))
    }

    func testIMAPConcurrentMutationTargetsIgnoreSnapshotOrderAndFailClosed() {
        func message(id: String) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [], bcc: [], cc: [], flags: [], from: [],
                htmlBody: NodeSyncBody(state: .absent, value: nil), id: id, inReplyTo: [], labels: ["INBOX"],
                receivedAt: "2026-09-02T00:00:00Z", references: [], replyTo: [], sentAt: nil,
                subject: id, textBody: NodeSyncBody(state: .complete, value: id), threadID: "thread-(id)", to: []
            )
        }
        let read = message(id: "read")
        let archive = message(id: "archive")
        let delete = message(id: "delete")
        let untouched = message(id: "untouched")
        for permutation in [
            [read, archive, delete, untouched],
            [archive, delete, read, untouched],
            [delete, untouched, archive, read]
        ] {
            let targets = NodeMailAuthorityLiveScenario.imapConcurrentMutationTargetsForTesting(
                messages: permutation, readMessageID: "read"
            )
            XCTAssertEqual(targets?.read.id, "read")
            XCTAssertNotEqual(targets?.archive.id, "read")
            XCTAssertNotEqual(targets?.delete.id, "read")
            XCTAssertNotEqual(targets?.archive.id, targets?.delete.id)
        }
        XCTAssertNil(NodeMailAuthorityLiveScenario.imapConcurrentMutationTargetsForTesting(messages: [read, archive], readMessageID: "read"))
        XCTAssertNil(NodeMailAuthorityLiveScenario.imapConcurrentMutationTargetsForTesting(messages: [archive, delete], readMessageID: "read"))
        XCTAssertNil(NodeMailAuthorityLiveScenario.imapConcurrentMutationTargetsForTesting(messages: [read, archive, archive], readMessageID: "read"))
    }

    func testIMAPConcurrentMutationBaselineWaitSkipsPartialAndMalformedSnapshots() async throws {
        func fixtureMessage(
            id: String,
            subject: String,
            body: String,
            htmlBody: NodeSyncBody,
            attachment: NodeSyncAttachment? = nil,
            receivedAt: String
        ) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: attachment.map { [$0] } ?? [], bcc: [], cc: [], flags: [],
                from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
                htmlBody: htmlBody, id: id, inReplyTo: [], labels: ["INBOX"],
                receivedAt: receivedAt, references: [], replyTo: [], sentAt: nil,
                subject: subject, textBody: NodeSyncBody(state: .complete, value: body),
                threadID: "thread-\(id)",
                to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
            )
        }
        let acceptance = fixtureMessage(
            id: "acceptance", subject: "Plainpost acceptance é", body: "Unicode acceptance body",
            htmlBody: NodeSyncBody(state: .complete, value: "<p>Unicode <strong>acceptance</strong> body</p>"),
            attachment: NodeSyncAttachment(
                contentDigest: nil, contentID: nil, disposition: "attachment", filename: "fixture.bin",
                id: "capability", mime: "application/octet-stream", size: "262144"
            ), receivedAt: "2026-09-02T00:00:00Z"
        )
        let continuation = fixtureMessage(
            id: "continuation", subject: "Plainpost continuation", body: "Continuation body",
            htmlBody: NodeSyncBody(state: .absent, value: nil), receivedAt: "2026-09-02T00:00:01Z"
        )
        let partial = try NodeSyncSnapshotPage(messages: [acceptance], nextCursor: "", revision: "7")
        let complete = try NodeSyncSnapshotPage(messages: [acceptance, continuation], nextCursor: "", revision: "8")
        let snapshots = RevisionSnapshotSequence(pages: [partial, complete])

        let baseline = try await NodeMailAuthorityLiveScenario.waitForAcceptanceFixtureSnapshotForTesting(
            pollAttempts: 2,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )
        XCTAssertEqual(baseline.messages, [acceptance, continuation])
        XCTAssertEqual(baseline.revision, "8")
        let baselineCallCount = await snapshots.callCount()
        XCTAssertEqual(baselineCallCount, 2)

        let duplicate = try NodeSyncSnapshotPage(messages: [acceptance, acceptance], nextCursor: "", revision: "8")
        let duplicateSnapshots = RevisionSnapshotSequence(pages: [duplicate])
        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForAcceptanceFixtureSnapshotForTesting(
                pollAttempts: 1,
                pollDelayMilliseconds: 0,
                snapshot: { await duplicateSnapshots.next() },
                isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTFail("duplicate acceptance fixture identities must fail closed")
        } catch {
            // Expected: malformed baseline never becomes a targetable snapshot.
        }

        let insufficientSnapshots = RevisionSnapshotSequence(pages: [partial])
        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForAcceptanceFixtureSnapshotForTesting(
                pollAttempts: 1,
                pollDelayMilliseconds: 0,
                snapshot: { await insufficientSnapshots.next() },
                isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTFail("partial acceptance fixture must fail closed")
        } catch {
            // Expected: partial baseline never becomes a targetable snapshot.
        }
    }

    func testIMAPStaleAuthorityAllowsInitialSnapshotBeforeDedicatedReplacement() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixSnapshotMaySucceedForTesting(selector: "imap-stale-authority"))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixSnapshotMaySucceedForTesting(selector: "imap-authentication"))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixSnapshotMaySucceedForTesting(selector: "imap-delayed-literal"))
    }

    func testIMAPMatrixUsesNodeTwoLifecycleWithoutSMTPAuthorityOutage() {
        for selector in NodeMailAuthorityLiveScenario.imapMatrixCases.map(\.selector) {
            XCTAssertTrue(
                NodeMailAuthorityLiveScenario.imapMatrixUsesNodeTwoLifecycleForTesting(selector: selector),
                selector
            )
        }
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixUsesNodeTwoLifecycleForTesting(selector: "smtp-mid-data")
        )
    }

    func testIMAPMatrixControlActionsUseTheClosedSwiftAllowlist() {
        for action in [
            "provider-transition", "attachment-release-probe", "release-backup-restore", "restart-node", "restart-imap-fixture",
            "restart-smtp-fixture", "mail-postcondition", "smtp-matrix-resume", "imap-matrix-resume",
            "imap-matrix-reset-uidvalidity", "imap-matrix-assert-authentication", "imap-matrix-arm-authentication",
            "imap-matrix-arm-tls-failure", "imap-matrix-append-message", "imap-matrix-assert-no-idle",
            "imap-matrix-catalog-probe", "imap-matrix-fetch-probe", "imap-matrix-delayed-literal-probe",
            "imap-matrix-arm-provider-restart",
            "arm-sent-append-failure", "smtp-matrix-assert-no-auth", "smtp-matrix-assert-authentication-command",
            "restore-smtp-fixture-normal", "restore-imap-fixture-normal"
        ] {
            XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixControlActionAllowedForTesting(action: action), action)
        }
    }

    func testIMAPDisconnectRecoveriesUseDedicatedCompleteProjectionBranch() {
        for selector in ["imap-header-fetch", "imap-body-fetch"] {
            XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRequiresCompleteProjectionRecoveryForTesting(selector: selector))
        }
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixUsesDedicatedCatalogProbeForTesting(selector: "imap-catalog"))
        for selector in ["imap-header-fetch", "imap-body-fetch"] {
            XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixUsesDedicatedFetchProbeForTesting(selector: selector))
        }
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixUsesDedicatedDelayedLiteralProbeForTesting(
                selector: "imap-delayed-literal"
            )
        )
        for selector in ["imap-attachment-fetch", "imap-truncated-literal", "imap-mime-boundaries"] {
            XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRequiresCompleteProjectionRecoveryForTesting(selector: selector))
        }
    }

    func testIMAPAttachmentScenariosOwnTheAttachmentBarrierAfterSnapshot() {
        for selector in ["imap-attachment-fetch", "imap-truncated-literal", "imap-mime-boundaries"] {
            XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: selector), selector)
            XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixOwnsAttachmentBarrierForTesting(selector: selector), selector)
        }
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixExpectedAttachmentFaultClassForTesting(selector: "imap-attachment-fetch"),
            .disconnect
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixExpectedAttachmentFaultClassForTesting(selector: "imap-truncated-literal"),
            .truncated
        )
        XCTAssertNil(NodeMailAuthorityLiveScenario.imapMatrixExpectedAttachmentFaultClassForTesting(selector: "imap-mime-boundaries"))
    }

    func testIMAPAttachmentFaultAssertionUsesNodeTypedTransportErrors() {
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultErrorIsExpectedForTesting(
                NodeSyncClientError.transport
            )
        )
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultErrorIsExpectedForTesting(
                NodeSyncClientError.problem(.unavailable)
            )
        )
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultErrorIsExpectedForTesting(
                NodeSyncClientError.transportAfterDispatch
            )
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultErrorClassForTesting(
                NodeSyncClientError.transportAfterDispatch
            ),
            "transport-after-dispatch"
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultErrorIsExpectedForTesting(
                PlainpostError.validationFailed("The Node is unavailable.")
            )
        )
    }

    func testIMAPTruncatedLiteralAcceptsOnlyMalformedLiteralOutcomes() {
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorIsExpectedForTesting(
                NodeSyncClientError.problem(.unavailable)
            )
        )
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorIsExpectedForTesting(
                NodeSyncClientError.invalidResponse
            )
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorClassForTesting(
                NodeSyncClientError.problem(.unavailable)
            ),
            "unavailable"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorClassForTesting(
                NodeSyncClientError.invalidResponse
            ),
            "invalid-response"
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorIsExpectedForTesting(
                NodeSyncClientError.transport
            )
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixTruncatedLiteralErrorIsExpectedForTesting(
                PlainpostError.validationFailed("Attachment size did not match Node metadata.")
            )
        )
    }

    func testIMAPAttachmentDisconnectUsesOneAttemptFaultThenRecovery() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultRequiresRecoveryForTesting(selector: "imap-attachment-fetch"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixAttachmentFaultRequiresRecoveryForTesting(selector: "imap-truncated-literal"))
    }

    func testIMAPAttachmentDisconnectUsesDedicatedOneAttemptProbe() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRequiresDedicatedAttachmentFaultProbeForTesting(selector: "imap-attachment-fetch"))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRequiresDedicatedAttachmentFaultProbeForTesting(selector: "imap-truncated-literal"))
    }

    func testIMAPAttachmentRetryRequiresHydratedDigest() {
        let bytes = Data(repeating: 0, count: 262144)
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixExpectedAttachmentDigestForTesting(bytes),
            "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA"
        )
    }

    func testIMAPAcceptanceShapeAllowsOnlyExpectedHydratedDigest() {
        let attachment = NodeSyncAttachment(
            contentDigest: nil, contentID: nil, disposition: "attachment", filename: "fixture.bin",
            id: "capability", mime: "application/octet-stream", size: "262144"
        )
        let acceptance = NodeSyncMessage(
            attachments: [attachment], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .complete, value: "<p>Unicode <strong>acceptance</strong> body</p>"),
            id: "acceptance", inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z",
            references: [], replyTo: [], sentAt: nil, subject: "Plainpost acceptance é",
            textBody: NodeSyncBody(state: .complete, value: "Unicode acceptance body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        let continuation = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "continuation", inReplyTo: [], labels: ["INBOX"],
            receivedAt: "2026-08-31T10:00:01Z", references: [], replyTo: [], sentAt: nil,
            subject: "Plainpost continuation", textBody: NodeSyncBody(state: .complete, value: "Continuation body"),
            threadID: "thread-2", to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapAcceptanceFixtureShapeMatchesForTesting([acceptance, continuation]))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapAcceptanceFixtureShapeMatchesForTesting(
            [acceptance], expectedAttachmentDigest: nil
        ) == false)
        var hydrated = acceptance
        hydrated = NodeSyncMessage(
            attachments: [NodeSyncAttachment(
                contentDigest: "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA", contentID: nil,
                disposition: "attachment", filename: "fixture.bin", id: "capability",
                mime: "application/octet-stream", size: "262144"
            )], bcc: hydrated.bcc, cc: hydrated.cc, flags: hydrated.flags, from: hydrated.from,
            htmlBody: hydrated.htmlBody, id: hydrated.id, inReplyTo: hydrated.inReplyTo, labels: hydrated.labels,
            receivedAt: hydrated.receivedAt, references: hydrated.references, replyTo: hydrated.replyTo,
            sentAt: hydrated.sentAt, subject: hydrated.subject, textBody: hydrated.textBody,
            threadID: hydrated.threadID, to: hydrated.to
        )
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapAcceptanceFixtureShapeMatchesForTesting(
            [hydrated, continuation], expectedAttachmentDigest: "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA"
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapAcceptanceFixtureShapeMatchesForTesting(
            [hydrated, continuation], expectedAttachmentDigest: "wrong"
        ))
    }

    func testIMAPInitialSnapshotFaultsAreClosedAndSelectorSpecific() {
        for selector in ["imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1"] {
            XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: selector))
        }
        for selector in ["imap-header-fetch", "imap-body-fetch"] {
            XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: selector))
        }
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: "imap-catalog"))
        for selector in [
            "imap-delayed-literal", "imap-truncated-literal", "imap-uid-gaps", "imap-expunge",
            "imap-uidvalidity-reset", "imap-idle-wakeup", "imap-poll-fallback", "imap-provider-restart-mid-page",
            "imap-provider-restart-after-commit", "imap-node-restart-before-ack", "imap-node-restart-after-ack",
            "imap-concurrent-mutations", "imap-stale-authority", "imap-mime-boundaries"
        ] {
            XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: selector))
        }
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixInitialPhaseBarrierForTesting(
                selector: "imap-delayed-literal"
            )
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixInitialPhaseBarrierForTesting(
                selector: "imap-node-restart-before-ack"
            )
        )
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: "imap-attachment-fetch"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: "imap-authentication"))
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapMatrixExpectedInitialFaultClassForTesting(selector: "imap-authentication"),
            .authentication
        )
        for selector in ["imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1"] {
            XCTAssertNil(NodeMailAuthorityLiveScenario.imapMatrixExpectedInitialFaultClassForTesting(selector: selector), selector)
        }
        for selector in ["imap-header-fetch", "imap-body-fetch"] {
            XCTAssertNil(NodeMailAuthorityLiveScenario.imapMatrixExpectedInitialFaultClassForTesting(selector: selector), selector)
        }
    }

    func testIMAPUIDGapFixtureUsesExactStableVisibleIdentitiesAndBodies() {
        func message(id: String, subject: String, body: String) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [], bcc: [], cc: [], flags: [], from: [],
                htmlBody: NodeSyncBody(state: .absent, value: nil), id: id, inReplyTo: [], labels: ["INBOX"],
                receivedAt: "2026-08-31T10:00:00Z", references: [], replyTo: [], sentAt: nil, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: body), threadID: "thread-\(id)", to: []
            )
        }
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapUIDGapFixtureShapeMatchesForTesting([
                message(id: "visible-nine", subject: "UID gap nine", body: "nine"),
                message(id: "visible-one", subject: "UID gap one", body: "one"),
                message(id: "visible-four", subject: "UID gap four", body: "four"),
            ])
        )
    }

    func testIMAPGenericMessageIdentityUsesCanonicalKnownVector() throws {
        let logicalMailboxID = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0, count: 32)))
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapGenericMessageIdentityForTesting(
                logicalMailboxID: logicalMailboxID,
                uid: "1"
            ),
            "980e67bd19a8bc8533ff8132469e134477da18b09ae155af6f5db303093c45ff"
        )
    }

    func testIMAPRecoveryPostconditionIncludesCompleteProjectionAndPageState() throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z", references: [],
            replyTo: [], sentAt: nil, subject: "Plainpost acceptance é",
            textBody: NodeSyncBody(state: .complete, value: "Unicode acceptance body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
        )
        let page = try NodeSyncSnapshotPage(messages: [message], nextCursor: "", revision: "8")
        let normalized = NodeMailAuthorityLiveScenario.imapNormalizedSnapshotForTesting(page)
        XCTAssertEqual(normalized.messages, [message])
        XCTAssertEqual(normalized.nextCursor, "")
        XCTAssertEqual(normalized.revision, "8")
        XCTAssertFalse(normalized.hasMore)

        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedForTesting(
                page,
                expectedMessages: [message],
                expectedRevision: "8",
                requireAcceptanceFixtureShape: false
            )
        )
        let partial = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedForTesting(
                partial,
                expectedMessages: [message],
                expectedRevision: "8",
                requireAcceptanceFixtureShape: false
            )
        )
        let paged = try NodeSyncSnapshotPage(messages: [message], nextCursor: "continuation", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedForTesting(
                paged,
                expectedMessages: [message],
                expectedRevision: "8",
                requireAcceptanceFixtureShape: false
            )
        )
    }

    func testIMAPUIDValidityResetWaitsForChangedRevisionBeforeExactBaseline() async throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z", references: [],
            replyTo: [], sentAt: nil, subject: "Plainpost acceptance é",
            textBody: NodeSyncBody(state: .complete, value: "Unicode acceptance body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
        )
        let stale = try NodeSyncSnapshotPage(messages: [message], nextCursor: "", revision: "7")
        let changed = try NodeSyncSnapshotPage(messages: [message], nextCursor: "", revision: "8")
        let snapshots = RevisionSnapshotSequence(pages: [stale, changed])

        let recovered = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
            currentRevision: stale.revision,
            pollAttempts: 2,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )

        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedForTesting(
                recovered,
                expectedMessages: [message],
                expectedRevision: "8",
                requireAcceptanceFixtureShape: false
            )
        )
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPUIDValidityReplacementRequiresRotatedIDsAndExactStableContent() throws {
        func message(
            id: String,
            threadID: String = "thread-1",
            subject: String = "Subject",
            body: String = "Body",
            attachments: [NodeSyncAttachment] = []
        ) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: attachments, bcc: [], cc: [], flags: [],
                from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
                htmlBody: NodeSyncBody(state: .absent, value: nil), id: id,
                inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z", references: [],
                replyTo: [], sentAt: nil, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: body), threadID: threadID,
                to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
            )
        }
        let old = try NodeSyncSnapshotPage(messages: [message(id: "old")], nextCursor: "", revision: "7")
        let rotated = try NodeSyncSnapshotPage(messages: [message(id: "new", threadID: "thread-new")], nextCursor: "", revision: "8")
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMatchesForTesting(
            actual: rotated, previous: old, currentRevision: old.revision
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMatchesForTesting(
            actual: try NodeSyncSnapshotPage(messages: [message(id: "old")], nextCursor: "", revision: "8"),
            previous: old, currentRevision: old.revision
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMatchesForTesting(
            actual: try NodeSyncSnapshotPage(messages: [message(id: "new", subject: "Changed")], nextCursor: "", revision: "8"),
            previous: old, currentRevision: old.revision
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMatchesForTesting(
            actual: try NodeSyncSnapshotPage(messages: [message(id: "new")], nextCursor: "continuation", revision: "8"),
            previous: old, currentRevision: old.revision
        ))
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMismatchClassForTesting(
                actual: rotated, previous: old, currentRevision: old.revision,
                expectedMessageIDs: ["unexpected"]
            ),
            "identity-vector"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapUIDValidityReplacementMismatchClassForTesting(
                actual: try NodeSyncSnapshotPage(messages: [message(id: "new", subject: "Changed")], nextCursor: "", revision: "8"),
                previous: old, currentRevision: old.revision
            ),
            "stable-content"
        )
        let oldAttachment = NodeSyncAttachment(
            contentDigest: "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU", contentID: nil, disposition: "attachment", filename: "file.bin",
            id: "capability-old", mime: "application/octet-stream", size: "4"
        )
        let changedAttachment = NodeSyncAttachment(
            contentDigest: "2v1mwLmJZeaIvh_BKULAnwNQ5r4GhQF8PyNOl9CtyS4", contentID: nil, disposition: "attachment", filename: "file.bin",
            id: "capability-new", mime: "application/octet-stream", size: "4"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapUIDValidityStableContentMismatchClassForTesting(
                actual: try NodeSyncSnapshotPage(messages: [message(id: "new", attachments: [changedAttachment])], nextCursor: "", revision: "8"),
                previous: try NodeSyncSnapshotPage(messages: [message(id: "old", attachments: [oldAttachment])], nextCursor: "", revision: "7")
            ),
            "attachments"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapUIDValidityStableContentMismatchClassForTesting(
                actual: try NodeSyncSnapshotPage(messages: [message(id: "new", body: "Changed body")], nextCursor: "", revision: "8"),
                previous: old
            ),
            "bodies"
        )
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapUIDValidityMismatchClassShouldEmitForTesting(previous: nil, current: "identity-vector"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapUIDValidityMismatchClassShouldEmitForTesting(previous: "identity-vector", current: "identity-vector"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapUIDValidityMismatchClassShouldEmitForTesting(previous: "identity-vector", current: "matched"))
    }

    func testIMAPUIDValidityReplacementWaitSkipsIntermediateProjectionBeforeExactReplacement() async throws {
        func message(id: String, subject: String) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [], bcc: [], cc: [], flags: [],
                from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
                htmlBody: NodeSyncBody(state: .absent, value: nil), id: id, inReplyTo: [], labels: ["INBOX"],
                receivedAt: "2026-08-31T10:00:00Z", references: [], replyTo: [], sentAt: nil,
                subject: subject, textBody: NodeSyncBody(state: .complete, value: "Body (subject)"),
                threadID: "thread-(id)", to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
            )
        }
        let old = try NodeSyncSnapshotPage(
            messages: [message(id: "old-one", subject: "One"), message(id: "old-two", subject: "Two")],
            nextCursor: "", revision: "7"
        )
        let intermediate = try NodeSyncSnapshotPage(
            messages: [
                message(id: "new-one", subject: "One"), message(id: "new-two", subject: "Two"),
                message(id: "old-one", subject: "One"), message(id: "old-two", subject: "Two"),
            ], nextCursor: "", revision: "8"
        )
        let replacement = try NodeSyncSnapshotPage(
            messages: [message(id: "new-one", subject: "One"), message(id: "new-two", subject: "Two")],
            nextCursor: "", revision: "9"
        )
        let snapshots = RevisionSnapshotSequence(pages: [intermediate, replacement])

        let result = try await NodeMailAuthorityLiveScenario.waitForUIDValidityReplacementForTesting(
            previous: old,
            expectedMessageIDs: Set(["new-one", "new-two"]),
            pollAttempts: 2,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )

        XCTAssertEqual(result, replacement)
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPMIMEProjectionRequiresAllFiveExactAttachmentDescriptorsAndDigests() throws {
        func attachment(_ filename: String, _ mime: String, _ disposition: String, _ size: String, _ digest: String, _ contentID: String? = nil) -> NodeSyncAttachment {
            NodeSyncAttachment(contentDigest: digest, contentID: contentID, disposition: disposition, filename: filename, id: "capability-\(filename)", mime: mime, size: size)
        }
        let acceptance = NodeSyncMessage(
            attachments: [
                attachment("logo.png", "image/png", "inline", "4", "D0Y2x49l02OezloGS1rnU-NAhhShT7GKtNdUDSwkhUM", "logo@example.test"),
                attachment("café.txt", "text/plain", "attachment", "4", "2v1mwLmJZeaIvh_BKULAnwNQ5r4GhQF8PyNOl9CtyS4"),
                attachment("empty.bin", "application/octet-stream", "attachment", "0", "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"),
                attachment(".._.._secret.txt", "application/octet-stream", "attachment", "4", "tcH7Lvxta0Z0wv3MSM4BtDo7fAN2PAwzVd4Ame4PjHM"),
                attachment("fixture.bin", "application/octet-stream", "attachment", "262144", "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA"),
            ], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .complete, value: "<p>Related HTML</p>"), id: "acceptance",
            inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z", references: [], replyTo: [], sentAt: nil,
            subject: "Plainpost acceptance é", textBody: NodeSyncBody(state: .complete, value: "Unicode acceptance body"),
            threadID: "thread-acceptance", to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        let continuation = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [], from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "continuation", inReplyTo: [], labels: ["INBOX"],
            receivedAt: "2026-08-31T10:00:01Z", references: [], replyTo: [], sentAt: nil, subject: "Plainpost continuation",
            textBody: NodeSyncBody(state: .complete, value: "Continuation body"), threadID: "thread-continuation",
            to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMIMEProjectionMatchesForTesting(
            [acceptance, continuation], fixtureDigest: "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA"
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMIMEProjectionMatchesForTesting(
            [acceptance, continuation], fixtureDigest: "wrong"
        ))
    }

    func testIMAPAttachmentRecoveryProjectionUsesSingleAttachmentContract() throws {
        let digest = "ijnSq9OZmrc8NNskdoSc3fMDzjibNYJoUPmnAFibSpA"
        let acceptance = NodeSyncMessage(
            attachments: [NodeSyncAttachment(
                contentDigest: digest, contentID: nil, disposition: "attachment", filename: "fixture.bin",
                id: "capability-fixture", mime: "application/octet-stream", size: "262144"
            )], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .complete, value: "<p>Unicode <strong>acceptance</strong> body</p>"),
            id: "acceptance", inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z",
            references: [], replyTo: [], sentAt: nil, subject: "Plainpost acceptance é",
            textBody: NodeSyncBody(state: .complete, value: "Unicode acceptance body"), threadID: "thread-acceptance",
            to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        let continuation = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "", mailbox: "acceptance@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "continuation", inReplyTo: [], labels: ["INBOX"],
            receivedAt: "2026-08-31T10:00:01Z", references: [], replyTo: [], sentAt: nil,
            subject: "Plainpost continuation", textBody: NodeSyncBody(state: .complete, value: "Continuation body"),
            threadID: "thread-continuation", to: [NodeSyncAddress(displayName: "", mailbox: "recipient@example.test")]
        )
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapAttachmentRecoveryProjectionMatchesForTesting(
            [acceptance, continuation], fixtureDigest: digest
        ))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMIMEProjectionMatchesForTesting(
            [acceptance, continuation], fixtureDigest: digest
        ))
    }

    func testIMAPDeltaWaitRetriesOnlyAllowlistedTransientErrorsWithoutClassifier() async throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let change = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "message", threadID: "thread")
        let page = try NodeSyncDeltaPage(changes: [change], nextCursor: "next", revision: "8")
        let sequence = DeltaPageSequence(results: [
            .failure(NodeSyncClientError.problem(.unavailable)), .success(page)
        ])
        let recovered = try await NodeMailAuthorityLiveScenario.waitForNonEmptyDeltaForTesting(
            pollAttempts: 2, pollDelayMilliseconds: 0, fetch: { try await sequence.next() }
        )
        XCTAssertEqual(recovered, page)
        let sequenceCallCount = await sequence.callCount()
        XCTAssertEqual(sequenceCallCount, 2)
        let terminal = DeltaPageSequence(results: [.failure(NodeSyncClientError.problem(.unauthorized)), .success(page)])
        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForNonEmptyDeltaForTesting(
                pollAttempts: 2, pollDelayMilliseconds: 0, fetch: { try await terminal.next() }
            )
            XCTFail("terminal delta errors must not be retried")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .problem(.unauthorized))
        }
        let terminalCallCount = await terminal.callCount()
        XCTAssertEqual(terminalCallCount, 1)
    }

    func testIMAPAppendDeltaAcceptsOnlyOneTargetUpsertAndSafeMetadata() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 8, count: 32)))
        let otherLogical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 9, count: 32)))
        let target = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "target-message", threadID: "target-thread")
        let other = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "other-message", threadID: "other-thread")
        let wrongLogical = try NodeSyncChange(kind: "upsert", logicalMailboxID: otherLogical, messageID: "target-message", threadID: "target-thread")
        let removed = try NodeSyncChange(kind: "membership_removed", logicalMailboxID: logical, messageID: nil, threadID: nil)
        let tombstoned = try NodeSyncChange(kind: "tombstoned", logicalMailboxID: logical, messageID: "other-message", threadID: nil)
        let epochReset = try NodeSyncChange(kind: "epoch_reset", logicalMailboxID: logical, messageID: nil, threadID: nil)
        let baselineComplete = try NodeSyncChange(kind: "baseline_complete", logicalMailboxID: logical, messageID: nil, threadID: nil)
        let otherMailboxEpochReset = try NodeSyncChange(kind: "epoch_reset", logicalMailboxID: otherLogical, messageID: nil, threadID: nil)
        let cases: [(String, [NodeSyncChange], String)] = [
            ("target upsert", [target], "matched"),
            ("target plus epoch metadata", [target, epochReset], "matched"),
            ("target plus baseline metadata", [target, baselineComplete], "matched"),
            ("target plus other-mailbox metadata", [target, otherMailboxEpochReset], "matched"),
            ("target upsert absent", [epochReset], "target-upsert-zero"),
            ("wrong message upsert", [other], "unrelated-upsert"),
            ("wrong logical mailbox", [wrongLogical], "unrelated-upsert"),
            ("duplicate target upsert", [target, target], "target-upsert-duplicate"),
            ("membership removal", [target, removed], "membership-removed"),
            ("tombstone", [target, tombstoned], "tombstoned"),
        ]
        for (name, changes, expectedClass) in cases {
            let page = try NodeSyncDeltaPage(changes: changes, nextCursor: "next", revision: "8")
            XCTAssertEqual(
                NodeMailAuthorityLiveScenario.imapAppendDeltaShapeClassForTesting(
                    page,
                    logicalMailboxID: logical,
                    messageID: "target-message",
                    threadID: "target-thread"
                ),
                expectedClass,
                name
            )
            XCTAssertEqual(
                NodeMailAuthorityLiveScenario.imapAppendDeltaMatchesForTesting(
                    page,
                    logicalMailboxID: logical,
                    messageID: "target-message",
                    threadID: "target-thread"
                ),
                expectedClass == "matched",
                name
            )
        }
        let invalidEnvelope = try NodeSyncDeltaPage(changes: [target], nextCursor: "", revision: "8")
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapAppendDeltaShapeClassForTesting(
                invalidEnvelope,
                logicalMailboxID: logical,
                messageID: "target-message",
                threadID: "target-thread"
            ),
            "metadata-invalid"
        )
    }

    func testIMAPAppendDeltaSequenceAllowsExactBaselineReplayBeforeTargetContinuation() throws {
        let logical = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 10, count: 32)))
        let baseline = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "baseline-message", threadID: "baseline-thread")
        let target = try NodeSyncChange(kind: "upsert", logicalMailboxID: logical, messageID: "target-message", threadID: "target-thread")
        let firstPage = try NodeSyncDeltaPage(changes: [baseline], nextCursor: "cursor-1", revision: "8")
        let secondPage = try NodeSyncDeltaPage(changes: [target], nextCursor: "cursor-2", revision: "9")
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapAppendDeltaSequenceShapeClassForTesting(
                [firstPage, secondPage],
                logicalMailboxID: logical,
                baselineMessageIDs: ["baseline-message": "baseline-thread"],
                messageID: "target-message",
                threadID: "target-thread"
            ),
            "matched"
        )

        let duplicateBaseline = try NodeSyncDeltaPage(changes: [baseline], nextCursor: "cursor-2", revision: "9")
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.imapAppendDeltaSequenceShapeClassForTesting(
                [firstPage, duplicateBaseline, secondPage],
                logicalMailboxID: logical,
                baselineMessageIDs: ["baseline-message": "baseline-thread"],
                messageID: "target-message",
                threadID: "target-thread"
            ),
            "baseline-upsert-duplicate"
        )
    }

    func testIMAPRecoverySetComparisonDoesNotAssumeAppendOrder() throws {
        let first = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [], from: [],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-a", inReplyTo: [], labels: ["INBOX"],
            receivedAt: "2026-08-31T10:00:00Z", references: [], replyTo: [], sentAt: nil, subject: "First",
            textBody: NodeSyncBody(state: .complete, value: "first"), threadID: "thread-a", to: []
        )
        let second = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [], from: [],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-b", inReplyTo: [], labels: ["INBOX"],
            receivedAt: "2026-08-31T10:00:01Z", references: [], replyTo: [], sentAt: nil, subject: "Second",
            textBody: NodeSyncBody(state: .complete, value: "second"), threadID: "thread-b", to: []
        )
        let page = try NodeSyncSnapshotPage(messages: [second, first], nextCursor: "", revision: "8")

        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedSetForTesting(
                page,
                expectedMessages: [first, second],
                expectedRevision: "8"
            )
        )
    }

    func testIMAPReplacementSnapshotIgnoresOnlyOpaqueAttachmentCapabilityIDs() throws {
        func message(
            id: String = "message-1",
            threadID: String = "thread-1",
            subject: String = "Replacement",
            body: String = "Body",
            htmlBody: NodeSyncBody = NodeSyncBody(state: .absent, value: nil),
            flags: [String] = [],
            labels: [String] = ["INBOX"],
            receivedAt: String = "2026-08-31T10:00:00Z",
            sentAt: String? = nil,
            from: [NodeSyncAddress] = [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            to: [NodeSyncAddress] = [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")],
            attachmentID: String = "capability-node-one",
            attachmentContentDigest: String? = nil,
            attachmentContentID: String? = nil,
            attachmentDisposition: String = "attachment",
            attachmentFilename: String = "fixture.bin",
            attachmentMime: String = "application/octet-stream",
            attachmentSize: String = "4"
        ) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [NodeSyncAttachment(
                    contentDigest: attachmentContentDigest, contentID: attachmentContentID,
                    disposition: attachmentDisposition, filename: attachmentFilename, id: attachmentID,
                    mime: attachmentMime,
                    size: attachmentSize
                )],
                bcc: [], cc: [], flags: flags, from: from,
                htmlBody: htmlBody, id: id,
                inReplyTo: [], labels: labels, receivedAt: receivedAt, references: [], replyTo: [],
                sentAt: sentAt, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: body), threadID: threadID,
                to: to
            )
        }

        let nodeOne = message(attachmentID: "capability-node-one")
        let nodeTwo = message(attachmentID: "capability-node-two")
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapReplacementSnapshotMessagesMatchForTesting(
                actual: [nodeTwo], expected: [nodeOne]
            )
        )

        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapReplacementSnapshotMessagesMatchForTesting(
                actual: [message(attachmentID: "")], expected: [nodeOne]
            )
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapReplacementSnapshotMessagesMatchForTesting(
                actual: [nodeOne], expected: [message(attachmentID: "")]
            )
        )

        let changed: [(String, NodeSyncMessage)] = [
            ("message identity", message(id: "message-2")),
            ("thread", message(threadID: "thread-2")),
            ("header", message(subject: "Changed")),
            ("body", message(body: "Changed")),
            ("HTML body", message(htmlBody: NodeSyncBody(state: .complete, value: "<p>Changed</p>"))),
            ("flags", message(flags: ["seen"])),
            ("labels", message(labels: ["ARCHIVE"])),
            ("address", message(from: [NodeSyncAddress(displayName: "Other", mailbox: "other@example.test")])),
            ("recipient", message(to: [NodeSyncAddress(displayName: "Other", mailbox: "other@example.test")])),
            ("timestamp", message(receivedAt: "2026-08-31T10:00:01Z")),
            ("sent timestamp", message(sentAt: "2026-08-31T10:00:01Z")),
            ("attachment digest", message(attachmentContentDigest: "digest")),
            ("attachment content ID", message(attachmentContentID: "cid-other")),
            ("attachment disposition", message(attachmentDisposition: "inline")),
            ("attachment filename", message(attachmentFilename: "other.bin")),
            ("attachment MIME", message(attachmentMime: "text/plain")),
            ("attachment size", message(attachmentSize: "5")),
        ]
        for (field, candidate) in changed {
            XCTAssertFalse(
                NodeMailAuthorityLiveScenario.imapReplacementSnapshotMessagesMatchForTesting(
                    actual: [candidate], expected: [nodeOne]
                ),
                "replacement comparison must reject changed \(field)"
            )
        }
    }

    func testIMAPRevisionWaitObservesBoundedProviderTransition() async throws {
        let unchanged = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "7")
        let changed = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "8")
        let snapshots = RevisionSnapshotSequence(pages: [unchanged, changed])

        let result = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
            currentRevision: "7",
            pollAttempts: 3,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )

        XCTAssertEqual(result.revision, "8")
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPRevisionWaitFailsAfterBoundedUnchangedObservations() async throws {
        let unchanged = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "7")
        let snapshots = RevisionSnapshotSequence(pages: [unchanged])

        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
                currentRevision: "7",
                pollAttempts: 2,
                pollDelayMilliseconds: 0,
                snapshot: { await snapshots.next() },
                isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTFail("unchanged provider revision must fail after the bounded observation window")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .transport)
        }

        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPRevisionWaitAcceptsProductionDerivedObservationBudget() async throws {
        let changed = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "8")
        let snapshots = RevisionSnapshotSequence(pages: [changed])

        let result = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
            currentRevision: "7",
            pollAttempts: 1_500,
            pollDelayMilliseconds: 250,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )

        XCTAssertEqual(result.revision, "8")
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testIMAPRevisionWaitRetriesAllowlistedTransientSnapshotErrors() async throws {
        let changed = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "8")
        let snapshots = RevisionSnapshotErrorSequence(mode: .transientThenChanged, transientCount: 2, page: changed)

        let result = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
            currentRevision: "7",
            pollAttempts: 3,
            pollDelayMilliseconds: 0,
            snapshot: { try await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
        )

        XCTAssertEqual(result.revision, "8")
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testIMAPRevisionWaitBoundsRepeatedTransientSnapshotErrors() async throws {
        let unchanged = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "7")
        let snapshots = RevisionSnapshotErrorSequence(mode: .transientForever, transientCount: 0, page: unchanged)

        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
                currentRevision: "7",
                pollAttempts: 3,
                pollDelayMilliseconds: 0,
                snapshot: { try await snapshots.next() },
                isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTFail("repeated transient snapshot errors must terminate at the bounded attempt count")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .transport)
        }

        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testIMAPRevisionWaitPropagatesTerminalSnapshotErrorsImmediately() async throws {
        let unchanged = try NodeSyncSnapshotPage(messages: [], nextCursor: "", revision: "7")
        let snapshots = RevisionSnapshotErrorSequence(mode: .terminal, transientCount: 0, page: unchanged)

        do {
            _ = try await NodeMailAuthorityLiveScenario.waitForRevisionChangeForTesting(
                currentRevision: "7",
                pollAttempts: 3,
                pollDelayMilliseconds: 0,
                snapshot: { try await snapshots.next() },
                isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) }
            )
            XCTFail("terminal snapshot errors must not be retried")
        } catch let error as NodeSyncClientError {
            XCTAssertEqual(error, .problem(.unauthorized))
        }

        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testIMAPSnapshotWaitRequiresExactExpungeRemovalAfterRevisionChange() async throws {
        func message(id: String, subject: String) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: [], bcc: [], cc: [], flags: [],
                from: [], htmlBody: NodeSyncBody(state: .absent, value: nil), id: id,
                inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z",
                references: [], replyTo: [], sentAt: nil, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: subject), threadID: id, to: []
            )
        }
        let deleted = message(id: "deleted", subject: "Deleted")
        let retained = message(id: "retained", subject: "Retained")
        let pending = try NodeSyncSnapshotPage(messages: [deleted, retained], nextCursor: "", revision: "8")
        let committed = try NodeSyncSnapshotPage(messages: [retained], nextCursor: "", revision: "9")
        let snapshots = RevisionSnapshotSequence(pages: [pending, committed])

        let result = try await NodeMailAuthorityLiveScenario.waitForSnapshotMatchingForTesting(
            currentRevision: "7",
            pollAttempts: 2,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) },
            matches: { page in
                page.revision != "7" && page.messages == [retained] && !page.messages.contains(where: { $0.id == deleted.id })
            }
        )

        XCTAssertEqual(result.revision, "9")
        XCTAssertEqual(result.messages, [retained])
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPNodeRestartSnapshotWaitSkipsPendingReadUntilCommitted() async throws {
        let message = NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: "message-1",
            inReplyTo: [], labels: ["INBOX"], receivedAt: "2026-08-31T10:00:00Z", references: [],
            replyTo: [], sentAt: nil, subject: "Read transition",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-1",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.test")]
        )
        let pending = try NodeSyncSnapshotPage(messages: [message], nextCursor: "", revision: "7")
        let committed = try NodeSyncSnapshotPage(
            messages: [NodeMailAuthorityLiveScenario.imapMessageWithReadStateForTesting(message, seen: true)],
            nextCursor: "", revision: "8"
        )
        let snapshots = RevisionSnapshotSequence(pages: [pending, committed])

        let result = try await NodeMailAuthorityLiveScenario.waitForSnapshotMatchingForTesting(
            currentRevision: "7",
            pollAttempts: 2,
            pollDelayMilliseconds: 0,
            snapshot: { await snapshots.next() },
            isTransient: { NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting($0) },
            matches: { page in
                NodeMailAuthorityLiveScenario.imapSnapshotMatchesExpectedSetForTesting(
                    page,
                    expectedMessages: [NodeMailAuthorityLiveScenario.imapMessageWithReadStateForTesting(message, seen: true)],
                    expectedRevision: nil
                )
            }
        )

        XCTAssertEqual(result.revision, "8")
        XCTAssertTrue(result.messages[0].flags.contains("seen"))
        let callCount = await snapshots.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIMAPExpungePostconditionRetainsExactTrashCopyAndInboxMembership() throws {
        func message(id: String, labels: [String], subject: String = "Deleted subject", body: String = "Deleted body", attachment: Bool = true) -> NodeSyncMessage {
            NodeSyncMessage(
                attachments: attachment ? [NodeSyncAttachment(
                    contentDigest: nil, contentID: nil, disposition: "attachment", filename: "fixture.bin",
                    id: "capability-\(id)", mime: "application/octet-stream", size: "4"
                )] : [],
                bcc: [], cc: [], flags: [],
                from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.test")],
                htmlBody: NodeSyncBody(state: .absent, value: nil), id: id,
                inReplyTo: [], labels: labels, receivedAt: "2026-08-31T10:00:00Z",
                references: [], replyTo: [], sentAt: nil, subject: subject,
                textBody: NodeSyncBody(state: .complete, value: body), threadID: "thread-\(id)", to: []
            )
        }
        let deleted = message(id: "inbox-source", labels: ["INBOX"])
        let retained = message(id: "inbox-retained", labels: ["INBOX"], subject: "Retained subject", body: "Retained body", attachment: false)
        let trashCopy = message(id: "trash-copy", labels: ["TRASH"])
        let page = try NodeSyncSnapshotPage(messages: [trashCopy, retained], nextCursor: "", revision: "8")
        let globalDelete = try NodeSyncSnapshotPage(messages: [retained], nextCursor: "", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapExpungeProjectionMatchesForTesting(
                globalDelete,
                baselineMessages: [deleted, retained],
                deletedMessage: deleted,
                currentRevision: "7"
            )
        )
        let mixedMembership = try NodeSyncSnapshotPage(messages: [message(id: "trash-copy", labels: ["INBOX", "TRASH"]), retained], nextCursor: "", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapExpungeProjectionMatchesForTesting(
                mixedMembership,
                baselineMessages: [deleted, retained],
                deletedMessage: deleted,
                currentRevision: "7"
            )
        )
        let reusedSource = try NodeSyncSnapshotPage(messages: [message(id: "inbox-source", labels: ["TRASH"]), retained], nextCursor: "", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapExpungeProjectionMatchesForTesting(
                reusedSource,
                baselineMessages: [deleted, retained],
                deletedMessage: deleted,
                currentRevision: "7"
            )
        )
        let modifiedRetained = message(id: "inbox-retained", labels: ["INBOX"], subject: "Changed retained", body: "Retained body", attachment: false)
        let changedBaseline = try NodeSyncSnapshotPage(messages: [trashCopy, modifiedRetained], nextCursor: "", revision: "8")
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapExpungeProjectionMatchesForTesting(
                changedBaseline,
                baselineMessages: [deleted, retained],
                deletedMessage: deleted,
                currentRevision: "7"
            )
        )

        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapExpungeProjectionMatchesForTesting(
                page,
                baselineMessages: [deleted, retained],
                deletedMessage: deleted,
                currentRevision: "7"
            )
        )
    }

    func testIMAPStaleAuthorityInvokesTheInjectedReplacementCallback() async throws {
        var invocations = 0
        let client = NodeSyncClient(sender: ReplacementCallbackSender())
        let authority = PlainpostNodeMailAuthority(
            client: client,
            accountID: AccountID("replacement-callback-test")
        )
        let context = try await NodeMailAuthorityLiveScenario.performAuthorityReplacement {
            invocations += 1
            return .init(client: client, authority: authority)
        }
        XCTAssertEqual(invocations, 1)
        XCTAssertTrue(context.client === client)
        XCTAssertTrue(context.authority === authority)
    }

    func testIMAPRecoveryRetriesOnlyUnavailableTransportErrors() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NodeSyncClientError.transport))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NodeSyncClientError.problem(.unavailable)))
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(PlainpostError.validationFailed("The Node is unavailable.")))

        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NodeSyncClientError.invalidResponse))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NodeSyncClientError.problem(.unauthorized)))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NodeSyncClientError.transportAfterDispatch))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(PlainpostError.validationFailed("Attachment size did not match Node metadata.")))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixRecoveryErrorIsTransientForTesting(NSError(domain: "fixture", code: 1)))
    }

    func testIMAPRestartReplayRequiresDurableAppliedOutcome() {
        XCTAssertTrue(
            NodeMailAuthorityLiveScenario.imapMatrixRestartReplayStateIsAppliedForTesting("applied")
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixRestartReplayStateIsAppliedForTesting("conflicted")
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixRestartReplayStateIsAppliedForTesting("rejected")
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixRestartReplayStateIsAppliedForTesting("pending")
        )
        XCTAssertFalse(
            NodeMailAuthorityLiveScenario.imapMatrixRestartReplayStateIsAppliedForTesting("delivery_uncertain")
        )
    }

    func testIMAPMatrixCasesAreClosedAndUseTheTruncatedLiteralBarrier() {
        let cases = NodeMailAuthorityLiveScenario.imapMatrixCases
        XCTAssertEqual(cases.map(\.selector), [
            "imap-authentication", "imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1",
            "imap-catalog", "imap-header-fetch", "imap-body-fetch", "imap-attachment-fetch",
            "imap-delayed-literal", "imap-truncated-literal", "imap-uid-gaps", "imap-expunge",
            "imap-uidvalidity-reset", "imap-idle-wakeup", "imap-poll-fallback",
            "imap-provider-restart-mid-page", "imap-provider-restart-after-commit",
            "imap-node-restart-before-ack", "imap-node-restart-after-ack", "imap-concurrent-mutations",
            "imap-stale-authority", "imap-mime-boundaries",
        ])
        XCTAssertEqual(Set(cases.map(\.selector)).count, cases.count)
        let truncated = cases.first { $0.selector == "imap-truncated-literal" }!
        XCTAssertEqual(truncated.fault, "imap-truncated-literal")
        XCTAssertEqual(truncated.phase, "attachment-fetch")
        XCTAssertEqual(truncated.protocolName, "imap")
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixInitialSnapshotMustFailForTesting(selector: truncated.selector))

        let expectedFaults: [String: String] = [
            "imap-authentication": "imap-authentication",
            "imap-attachment-fetch": "imap-attachment-fetch",
            "imap-truncated-literal": "imap-truncated-literal",
        ]
        for matrixCase in cases {
            XCTAssertEqual(matrixCase.fault, expectedFaults[matrixCase.selector] ?? "none", matrixCase.selector)
        }
        for selector in [
            "imap-untrusted-certificate", "imap-same-ca-wrong-host", "imap-tls1.1", "imap-catalog",
            "imap-delayed-literal", "imap-uid-gaps", "imap-expunge", "imap-uidvalidity-reset",
            "imap-idle-wakeup", "imap-poll-fallback", "imap-provider-restart-mid-page",
            "imap-provider-restart-after-commit", "imap-node-restart-before-ack",
            "imap-node-restart-after-ack", "imap-concurrent-mutations", "imap-stale-authority",
            "imap-mime-boundaries",
        ] {
            guard let matrixCase = cases.first(where: { $0.selector == selector }) else {
                XCTFail("missing IMAP matrix selector: \(selector)")
                continue
            }
            XCTAssertEqual(matrixCase.fault, "none", selector)
            XCTAssertEqual(matrixCase.phase, "none", selector)
            XCTAssertEqual(matrixCase.protocolName, "imap", selector)
        }
    }

    func testSMTPMatrixCasesAreClosedAndDeriveProviderPostconditions() {
        let cases = NodeMailAuthorityLiveScenario.smtpMatrixCases
        XCTAssertEqual(cases.map(\.selector), [
            "smtp-authentication",
            "smtp-recipient-451",
            "smtp-recipient-550",
            "smtp-after-354",
            "smtp-mid-data",
            "smtp-final-reply",
            "smtp-quit-loss",
            "smtp-cancel-before-data",
            "smtp-cancel-after-data",
            "smtp-sent-append-failure",
            "smtp-provider-restart-after-acceptance",
            "smtp-untrusted-certificate",
            "smtp-same-ca-wrong-host",
            "smtp-tls1.1",
            "smtp-auth-before-starttls",
            "smtp-concurrent-sends",
            "smtp-ambiguous-replay",
        ])
        XCTAssertEqual(Set(cases.map(\.selector)).count, cases.count)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-recipient-451" })?.resultClass, .temporary)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-recipient-550" })?.resultClass, .rejected)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-recipient-451" })?.operationClass, .rejected)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-after-354" })?.operationClass, .deliveryUncertain)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-mid-data" })?.deliveryCount, 0)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-final-reply" })?.deliveryCount, 1)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-quit-loss" })?.restartResult, .accepted)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-ambiguous-replay" })?.deliveryCount, 1)
        XCTAssertEqual(cases.first(where: { $0.selector == "smtp-concurrent-sends" })?.deliveryCount, 2)

        let expected: [(String, NodeMailAuthorityLiveScenario.SMTPMatrixResultClass, NodeMailAuthorityLiveScenario.SMTPMatrixOperationClass, Int, Int, Int, Int, Bool, Bool, NodeMailAuthorityLiveScenario.SMTPMatrixRestartResult)] = [
            ("smtp-authentication", .rejected, .rejected, 1, 0, 0, 1, false, false, .none),
            ("smtp-recipient-451", .temporary, .rejected, 1, 0, 0, 1, false, false, .none),
            ("smtp-recipient-550", .rejected, .rejected, 1, 0, 0, 1, false, false, .none),
            ("smtp-after-354", .disconnect, .deliveryUncertain, 1, 0, 0, 1, false, false, .uncertain),
            ("smtp-mid-data", .disconnect, .deliveryUncertain, 1, 0, 0, 1, false, false, .uncertain),
            ("smtp-final-reply", .disconnect, .deliveryUncertain, 1, 1, 0, 1, false, false, .uncertain),
            ("smtp-quit-loss", .disconnect, .accepted, 0, 1, 1, 1, false, false, .accepted),
            ("smtp-cancel-before-data", .none, .accepted, 0, 1, 1, 1, true, true, .accepted),
            ("smtp-cancel-after-data", .disconnect, .deliveryUncertain, 1, 1, 0, 1, true, false, .uncertain),
            ("smtp-sent-append-failure", .temporary, .accepted, 0, 1, 0, 1, false, false, .accepted),
            ("smtp-provider-restart-after-acceptance", .none, .accepted, 0, 1, 0, 1, false, false, .accepted),
            ("smtp-untrusted-certificate", .rejected, .rejected, 1, 0, 0, 0, false, false, .none),
            ("smtp-same-ca-wrong-host", .rejected, .rejected, 1, 0, 0, 0, false, false, .none),
            ("smtp-tls1.1", .rejected, .rejected, 1, 0, 0, 0, false, false, .none),
            ("smtp-auth-before-starttls", .rejected, .rejected, 1, 0, 0, 1, false, false, .none),
            ("smtp-concurrent-sends", .accepted, .accepted, 0, 2, 2, 2, false, false, .accepted),
            ("smtp-ambiguous-replay", .disconnect, .deliveryUncertain, 1, 1, 0, 1, false, false, .uncertain),
        ]
        for (selector, resultClass, operationClass, draftCount, deliveryCount, sentCount, authenticationCommandCount, initialCancellationObserved, retryEligible, restartResult) in expected {
            guard let matrixCase = cases.first(where: { $0.selector == selector }) else {
                XCTFail("missing SMTP matrix case: \(selector)")
                continue
            }
            XCTAssertEqual(matrixCase.resultClass, resultClass, selector)
            XCTAssertEqual(matrixCase.operationClass, operationClass, selector)
            XCTAssertEqual(matrixCase.draftCount, draftCount, selector)
            XCTAssertEqual(matrixCase.deliveryCount, deliveryCount, selector)
            XCTAssertEqual(matrixCase.sentCount, sentCount, selector)
            XCTAssertEqual(matrixCase.authenticationCommandCount, authenticationCommandCount, selector)
            XCTAssertEqual(matrixCase.initialCancellationObserved, initialCancellationObserved, selector)
            XCTAssertEqual(matrixCase.retryEligible, retryEligible, selector)
            XCTAssertEqual(matrixCase.restartResult, restartResult, selector)
        }
    }

    func testSMTPMatrixMapsOnlyTerminalNodeStatesToTypedOutcomes() throws {
        XCTAssertEqual(NodeMailAuthorityLiveScenario.smtpMatrixOperationClass(for: "applied"), .accepted)
        XCTAssertEqual(NodeMailAuthorityLiveScenario.smtpMatrixOperationClass(for: "rejected"), .rejected)
        XCTAssertEqual(NodeMailAuthorityLiveScenario.smtpMatrixOperationClass(for: "conflicted"), .rejected)
        XCTAssertEqual(NodeMailAuthorityLiveScenario.smtpMatrixOperationClass(for: "delivery_uncertain"), .deliveryUncertain)
        XCTAssertNil(NodeMailAuthorityLiveScenario.smtpMatrixOperationClass(for: "pending"))
    }

    func testSMTPMatrixPhaseObservationUsesAuthoritativeProjectionAndBoundedResume() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smtp-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = root.appendingPathComponent("mail-observations.jsonl")
        let waiter = Task {
            try await NodeMailAuthorityLiveScenario.waitForMailPhaseForTesting(
                "acceptance-before-append", observationFile: observations, pollAttempts: 20, pollDelayMilliseconds: 5
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        try Data("{\"kind\":\"phase-reached\",\"protocol\":\"smtp\",\"phase\":\"acceptance-before-append\",\"occurrence\":1}\n".utf8)
            .write(to: observations, options: .atomic)
        try await waiter.value
        try NodeMailAuthorityLiveScenario.requestSMTPMatrixResumeForTesting(root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("smtp-matrix-resume.request").path))
    }

    func testSMTPMatrixPhaseObservationRejectsLegacyProjectionPath() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smtp-matrix-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("observations.jsonl")
        try Data("{\"protocol\":\"smtp\",\"phase\":\"authentication\"}\n".utf8).write(to: legacy)
        do {
            try await NodeMailAuthorityLiveScenario.waitForMailPhaseForTesting(
                "authentication", observationFile: legacy, pollAttempts: 1, pollDelayMilliseconds: 0
            )
            XCTFail("legacy observations.jsonl must not satisfy the authoritative phase wait")
        } catch {
            // Expected: the old projection is deliberately not a valid seam.
        }
    }

    func testSMTPMatrixSentAppendPhaseUsesIMAPObservationProtocol() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smtp-matrix-imap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = root.appendingPathComponent("mail-observations.jsonl")
        try Data("{\"kind\":\"phase-reached\",\"protocol\":\"imap\",\"phase\":\"sent-append\",\"occurrence\":1}\n".utf8)
            .write(to: observations, options: .atomic)
        try await NodeMailAuthorityLiveScenario.waitForMailPhaseForTesting(
            "sent-append", protocolName: "imap", observationFile: observations, pollAttempts: 1, pollDelayMilliseconds: 0
        )
    }

    func testIMAPPhaseObservationUsesTheRequestedOccurrence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imap-phase-occurrence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = root.appendingPathComponent("mail-observations.jsonl")
        try Data([
            "{\"kind\":\"phase-reached\",\"protocol\":\"imap\",\"phase\":\"header-fetch\",\"occurrence\":1}",
            "{\"kind\":\"phase-reached\",\"protocol\":\"imap\",\"phase\":\"header-fetch\",\"occurrence\":2}",
        ].joined(separator: "\n").appending("\n").utf8).write(to: observations, options: .atomic)
        try await NodeMailAuthorityLiveScenario.waitForMailPhaseForTesting(
            "header-fetch",
            protocolName: "imap",
            occurrence: 2,
            observationFile: observations,
            pollAttempts: 1,
            pollDelayMilliseconds: 0
        )
    }

    func testIMAPProviderRestartOccurrenceResultRequiresBoundedMode0600Integer() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imap-provider-restart-occurrence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("imap-matrix-arm-provider-restart.result")
        try Data("7\n".utf8).write(to: result, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
        XCTAssertEqual(try NodeMailAuthorityLiveScenario.readIMAPProviderRestartOccurrenceForTesting(root), 7)

        try Data("0\n".utf8).write(to: result, options: .atomic)
        XCTAssertThrowsError(try NodeMailAuthorityLiveScenario.readIMAPProviderRestartOccurrenceForTesting(root))
        try Data("7\n8\n".utf8).write(to: result, options: .atomic)
        XCTAssertThrowsError(try NodeMailAuthorityLiveScenario.readIMAPProviderRestartOccurrenceForTesting(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: result.path)
        try Data("7\n".utf8).write(to: result, options: .atomic)
        XCTAssertThrowsError(try NodeMailAuthorityLiveScenario.readIMAPProviderRestartOccurrenceForTesting(root))
    }

    func testIMAPProviderRestartMidPageUsesIdleBarrierBeforeArming() {
        XCTAssertTrue(NodeMailAuthorityLiveScenario.imapMatrixUsesIdleBarrierForTesting(selector: "imap-provider-restart-mid-page"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixUsesIdleBarrierForTesting(selector: "imap-provider-restart-after-commit"))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.imapMatrixUsesIdleBarrierForTesting(selector: "imap-poll-fallback"))
    }

    func testIMAPIdleWaitRequiresAnActiveFixtureLease() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imap-idle-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let control = root.appendingPathComponent("mail-control.json")
        try Data("{\"imap_idle_active_count\":1,\"imap_idle_active_inbox_count\":0}\n".utf8).write(to: control, options: .atomic)
        let waiter = Task {
            try await NodeMailAuthorityLiveScenario.waitForActiveIMAPIdleForTesting(
                root,
                pollAttempts: 20,
                pollDelayMilliseconds: 5
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        try Data("{\"imap_idle_active_inbox_count\":1}\n".utf8).write(to: control, options: .atomic)
        try await waiter.value
    }

    func testAssignmentMatchingUsesTypedFieldsInsteadOfDelimiterConcatenation() throws {
        let logical = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let first = SyncNodeMailboxSelection(
            displayName: "left\u{1F}middle", mailboxHandle: "right", role: "inbox", logicalMailboxID: logical
        )
        let second = SyncNodeMailboxSelection(
            displayName: "left", mailboxHandle: "middle\u{1F}right", role: "inbox", logicalMailboxID: logical
        )
        let status = SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0", storage: "managed",
            providerIdentity: "provider@example.com",
            assignments: [
                SyncNodeProviderMailbox(displayName: first.displayName, mailboxHandle: first.mailboxHandle, role: first.role, logicalMailboxID: logical),
                SyncNodeProviderMailbox(displayName: second.displayName, mailboxHandle: second.mailboxHandle, role: second.role, logicalMailboxID: logical)
            ],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )

        XCTAssertTrue(NodeMailAuthorityLiveScenario.status(status, matches: [first, second], providerIdentity: "provider@example.com"))
    }

    func testAssignmentMatchingRejectsUnknownReachabilityDiagnostic() throws {
        let logical = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let selection = SyncNodeMailboxSelection(
            displayName: "Inbox", mailboxHandle: "inbox-handle", role: "inbox", logicalMailboxID: logical
        )
        let status = SyncNodeStatus(
            state: "ready", version: "node-sync-v1", reachability: "unknown", syncLag: "0", storage: "managed",
            providerIdentity: "provider@example.com",
            assignments: [
                SyncNodeProviderMailbox(displayName: selection.displayName, mailboxHandle: selection.mailboxHandle, role: selection.role, logicalMailboxID: logical)
            ],
            backup: "not_reported", endpoint: "session-scoped", updateStatus: "current"
        )

        XCTAssertFalse(NodeMailAuthorityLiveScenario.status(status, matches: [selection], providerIdentity: "provider@example.com"))
    }

    func testBackupRestoreStatusComparisonIgnoresVolatileRuntimeFields() {
        let before = SyncNodeStatus(
            revision: "10", state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
            storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "not_reported",
            endpoint: "session-scoped", updateStatus: "current"
        )
        let after = SyncNodeStatus(
            revision: "11", state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "2",
            storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
            endpoint: "session-scoped", updateStatus: "recovery"
        )

        XCTAssertTrue(NodeMailAuthorityLiveScenario.backupRestoreStatusMatches(before: before, after: after))
        XCTAssertNil(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(before: before, after: after))
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
                before: before,
                after: SyncNodeStatus(
                    revision: "11", state: "recovering", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
                    storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
                    endpoint: "session-scoped", updateStatus: "recovery"
                )
            ),
            "status-state"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
                before: before,
                after: SyncNodeStatus(
                    revision: "11", state: "ready", version: "node-sync-v1", reachability: "unknown", syncLag: "0",
                    storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
                    endpoint: "session-scoped", updateStatus: "recovery"
                )
            ),
            "status-reachability"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
                before: before,
                after: SyncNodeStatus(
                    revision: "11", state: "ready", version: "other-node", reachability: "reachable", syncLag: "0",
                    storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
                    endpoint: "session-scoped", updateStatus: "current"
                )
            ),
            "status-version"
        )
        func validAfter(
            storage: String = "managed",
            providerIdentity: String? = "provider@example.com",
            assignments: [SyncNodeProviderMailbox] = [],
            backup: String = "verified",
            endpoint: String = "session-scoped"
        ) -> SyncNodeStatus {
            SyncNodeStatus(
                revision: "11", state: "ready", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
                storage: storage, providerIdentity: providerIdentity, assignments: assignments, backup: backup,
                endpoint: endpoint, updateStatus: "recovery"
            )
        }
        XCTAssertEqual(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
            before: before, after: validAfter(storage: "object")
        ), "status-storage")
        XCTAssertEqual(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
            before: before, after: validAfter(providerIdentity: "other@example.com")
        ), "status-provider-identity")
        XCTAssertEqual(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
            before: before,
            after: validAfter(assignments: [SyncNodeProviderMailbox(displayName: "Inbox", mailboxHandle: "inbox", role: "inbox")])
        ), "status-assignments")
        XCTAssertEqual(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
            before: before, after: validAfter(backup: "pending")
        ), "status-backup")
        XCTAssertEqual(NodeMailAuthorityLiveScenario.backupRestoreStatusMismatchClassForTesting(
            before: before, after: validAfter(endpoint: "other-endpoint")
        ), "status-endpoint")
        XCTAssertFalse(NodeMailAuthorityLiveScenario.backupRestoreStatusMatches(before: after, after: before))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.backupRestoreStatusMatches(before: before, after: SyncNodeStatus(
            revision: "11", state: "recovering", version: "node-sync-v1", reachability: "reachable", syncLag: "0",
            storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
            endpoint: "session-scoped", updateStatus: "recovery"
        )))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.backupRestoreStatusMatches(before: before, after: SyncNodeStatus(
            revision: "11", state: "ready", version: "node-sync-v1", reachability: "unknown", syncLag: "0",
            storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
            endpoint: "session-scoped", updateStatus: "recovery"
        )))
        XCTAssertFalse(NodeMailAuthorityLiveScenario.backupRestoreStatusMatches(before: before, after: SyncNodeStatus(
            revision: "11", state: "ready", version: "other-node", reachability: "reachable", syncLag: "0",
            storage: "managed", providerIdentity: "provider@example.com", assignments: [], backup: "verified",
            endpoint: "session-scoped", updateStatus: "current"
        )))
    }

    func testBackupRestoreVerificationMismatchClassUsesClosedOrderedCategories() {
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
                statusMatches: false, snapshotMatches: false, messageMatches: false,
                attachmentMetadataMatches: false, attachmentBytesMatch: false
            ),
            "status"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
                statusMatches: true, snapshotMatches: false, messageMatches: false,
                attachmentMetadataMatches: false, attachmentBytesMatch: false
            ),
            "snapshot"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
                statusMatches: true, snapshotMatches: true, messageMatches: false,
                attachmentMetadataMatches: false, attachmentBytesMatch: false
            ),
            "message"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
                statusMatches: true, snapshotMatches: true, messageMatches: true,
                attachmentMetadataMatches: false, attachmentBytesMatch: false
            ),
            "attachment-metadata"
        )
        XCTAssertEqual(
            NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
                statusMatches: true, snapshotMatches: true, messageMatches: true,
                attachmentMetadataMatches: true, attachmentBytesMatch: false
            ),
            "attachment-bytes"
        )
        XCTAssertNil(NodeMailAuthorityLiveScenario.backupRestoreVerificationMismatchClassForTesting(
            statusMatches: true, snapshotMatches: true, messageMatches: true,
            attachmentMetadataMatches: true, attachmentBytesMatch: true
        ))
    }

    func testBackupRestoreSnapshotComparisonIgnoresVolatileEnvelope() throws {
        let message = MessageSummary(
            id: MessageID("message-1"), threadID: ThreadID("thread-1"), from: EmailAddress("sender@example.com"),
            subject: "Subject", preview: "Body", body: "Body", smartCategory: .unknown, labels: ["INBOX"], isSeen: true
        )
        let before = MailSnapshotPage(messages: [message], nextCursor: MailSearchCursor(rawValue: "cursor-before"), revision: "11")
        let after = MailSnapshotPage(messages: [message], nextCursor: MailSearchCursor(rawValue: "cursor-after"), revision: "12")
        XCTAssertTrue(NodeMailAuthorityLiveScenario.backupRestoreSnapshotMatchesForTesting(before: before, after: after))

        let changed = MessageSummary(
            id: MessageID("message-1"), threadID: ThreadID("thread-1"), from: EmailAddress("sender@example.com"),
            subject: "Changed", preview: "Body", body: "Body", smartCategory: .unknown, labels: ["INBOX"], isSeen: true
        )
        let changedAfter = MailSnapshotPage(messages: [changed], nextCursor: MailSearchCursor(rawValue: "cursor-after"), revision: "12")
        XCTAssertFalse(NodeMailAuthorityLiveScenario.backupRestoreSnapshotMatchesForTesting(before: before, after: changedAfter))
    }

    func testTerminalMutationWaitReplaysPendingCanonicalOperationUntilApplied() async throws {
        let endpoint = URL(string: "https://node.example.ts.net:443")!
        let pending = try NodeSyncCodec.encodeMutationResult(
            try NodeSyncMutationResult(idempotencyKey: "mutation-1", state: "pending")
        )
        let applied = try NodeSyncCodec.encodeMutationResult(
            try NodeSyncMutationResult(idempotencyKey: "mutation-1", state: "applied")
        )
        let sender = PendingMutationSender(responses: [
            NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: pending),
            NodeHTTPResponse(statusCode: 200, url: endpoint, headers: [:], body: applied),
        ])
        let client = NodeSyncClient(sender: sender)

        let result = try await NodeMailAuthorityLiveScenario.waitForTerminalMutation(
            client: client,
            canonicalOperation: try validCanonicalOperation(),
            stagePrefix: "test-send"
        )

        XCTAssertEqual(result.state, "applied")
        let callCount = await sender.callCount()
        XCTAssertEqual(callCount, 2)
        let requests = await sender.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].body, requests[1].body)
    }

    private func validCanonicalOperation() throws -> Data {
        let mailbox = try NodeSyncCodec.decodeLogicalMailboxID("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let unsigned = try NodeSyncUnsignedOperation(
            accountID: "11111111-1111-4111-8111-111111111111",
            authorityEpoch: "2",
            clientID: "22222222-2222-4222-8222-222222222222",
            idempotencyKey: "mutation-1",
            issuedAt: "2026-08-20T12:34:56Z",
            logicalMailboxID: mailbox,
            nodeID: "33333333-3333-4333-8333-333333333333",
            operation: .setRead(messageIDs: ["message-1"], read: true),
            trustEpoch: "1"
        )
        return try NodeSyncCodec.encodeOperation(
            try NodeSyncOperation(unsigned: unsigned, signature: Data(repeating: 0x42, count: 64))
        )
    }
}

private actor ReplacementCallbackSender: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 404, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }
}

private actor PendingMutationSender: NodeSessionRequestSending {
    private let responses: [NodeHTTPResponse]
    private var index = 0
    private var captured: [NodeHTTPRequest] = []

    init(responses: [NodeHTTPResponse]) { self.responses = responses }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        captured.append(NodeHTTPRequest(
            endpoint: try NodeEndpointURL("https://node.example.ts.net:443"),
            method: method,
            path: path,
            body: body
        ))
        defer { index += 1 }
        return responses[min(index, responses.count - 1)]
    }

    func callCount() -> Int { index }
    func requests() -> [NodeHTTPRequest] { captured }
}

private actor RevisionSnapshotSequence {
    private let pages: [NodeSyncSnapshotPage]
    private var index = 0

    init(pages: [NodeSyncSnapshotPage]) { self.pages = pages }

    func next() -> NodeSyncSnapshotPage {
        defer { index += 1 }
        return pages[min(index, pages.count - 1)]
    }

    func callCount() -> Int { index }
}

private enum RevisionSnapshotSequenceMode {
    case transientThenChanged
    case transientForever
    case terminal
}

private actor RevisionSnapshotErrorSequence {
    private let mode: RevisionSnapshotSequenceMode
    private var remainingTransient: Int
    private let page: NodeSyncSnapshotPage
    private var index = 0

    init(mode: RevisionSnapshotSequenceMode, transientCount: Int, page: NodeSyncSnapshotPage) {
        self.mode = mode
        remainingTransient = transientCount
        self.page = page
    }

    func next() throws -> NodeSyncSnapshotPage {
        defer { index += 1 }
        switch mode {
        case .transientThenChanged where remainingTransient > 0:
            remainingTransient -= 1
            throw NodeSyncClientError.problem(.unavailable)
        case .transientThenChanged:
            return page
        case .transientForever:
            throw NodeSyncClientError.problem(.unavailable)
        case .terminal:
            throw NodeSyncClientError.problem(.unauthorized)
        }
    }

    func callCount() -> Int { index }
}

private actor DeltaPageSequence {
    private var results: [Result<NodeSyncDeltaPage, Error>]
    private var index = 0

    init(results: [Result<NodeSyncDeltaPage, Error>]) {
        self.results = results
    }

    func next() throws -> NodeSyncDeltaPage {
        defer { index += 1 }
        return try results[min(index, results.count - 1)].get()
    }

    func callCount() -> Int { index }
}
