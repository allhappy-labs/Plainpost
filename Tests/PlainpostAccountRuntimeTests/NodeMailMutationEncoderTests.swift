import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostNodeTransport

final class NodeMailMutationEncoderTests: XCTestCase {
    func testEncoderUsesRequestedLogicalMailboxAndOperationIDAsIdempotencyKey() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))
        let second = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 2, count: 32)))
        let data = try await encoder.operation(for: .setRead(messageIDs: [MessageID("n1")], read: true), logicalMailboxID: second,
                                               idempotencyKey: "00000000-0000-4000-8000-000000000009")
        let operation = try NodeSyncCodec.decodeOperation(data)
        XCTAssertEqual(operation.unsigned.logicalMailboxID, second)
        XCTAssertEqual(operation.unsigned.idempotencyKey, "00000000-0000-4000-8000-000000000009")
    }

    func testFlagAndMoveAreSignedWithSortedMessagesAndTheirDestination() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))
        let second = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 2, count: 32)))
        let flag = try await encoder.operation(for: .setFlagged(messageIDs: [MessageID("n2"), MessageID("n1")], flagged: true),
                                               logicalMailboxID: second, idempotencyKey: "flag-key")
        XCTAssertEqual(try NodeSyncCodec.decodeOperation(flag).unsigned.operation, .setFlagged(messageIDs: ["n1", "n2"], flagged: true))
        let move = try await encoder.operation(for: .move(messageIDs: [MessageID("n1")], destinationMailboxPath: "Receipts"),
                                               logicalMailboxID: second, idempotencyKey: "move-key")
        XCTAssertEqual(try NodeSyncCodec.decodeOperation(move).unsigned.operation, .move(messageIDs: ["n1"], destinationMailboxPath: "Receipts"))
    }

    func testASendIsSignedAtTheApprovedSaveRevisionNotTheNodesCurrentOne() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))
        let grace = TwoAccountNodeSender.graceLogicalMailboxID
        let draft = Draft(
            id: DraftID("approved-draft"), accountID: AccountID("plainpost-account"),
            from: EmailAddress("grace@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Approved", bodyPlain: "body", createdBy: "test", aiGenerated: false, sourceThreadID: nil
        )
        let save = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: grace, idempotencyKey: "save-approved")
        let revision = try XCTUnwrap(NodeMailMutationEncoder.revisionAfterSave(canonicalOperation: save))
        XCTAssertEqual(revision, "2")

        let send = try await encoder.sendOperation(draftID: draft.id, expectedRevision: revision, logicalMailboxID: grace,
                                                   idempotencyKey: "send-approved")

        XCTAssertEqual(try NodeSyncCodec.decodeOperation(send).unsigned.operation,
                       .send(draftID: "approved-draft", expectedRevision: "2"))
        let draftReads = await sender.draftStateReads("approved-draft")
        XCTAssertEqual(draftReads, 1, "the send never reads the Node's current revision")
        XCTAssertNil(NodeMailMutationEncoder.revisionAfterSave(canonicalOperation: send))
    }

    func testEncoderSignsWithTheAuthorityEpochOfTheRequestedAccount() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))

        let ada = try NodeSyncCodec.decodeOperation(try await encoder.operation(
            for: .archive(messageIDs: [MessageID("m1")]), logicalMailboxID: TwoAccountNodeSender.adaLogicalMailboxID, idempotencyKey: "op-ada"
        ))
        let grace = try NodeSyncCodec.decodeOperation(try await encoder.operation(
            for: .archive(messageIDs: [MessageID("m2")]), logicalMailboxID: TwoAccountNodeSender.graceLogicalMailboxID, idempotencyKey: "op-grace"
        ))

        XCTAssertEqual(ada.unsigned.authorityEpoch, "7")
        XCTAssertEqual(grace.unsigned.authorityEpoch, "3")
    }

    func testEncoderRefusesALogicalMailboxThatIsNotAnAccountOfThisSession() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))
        let foreign = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 9, count: 32)))

        do {
            _ = try await encoder.operation(for: .delete(messageIDs: [MessageID("m1")]), logicalMailboxID: foreign, idempotencyKey: "op-foreign")
            XCTFail("an unlisted logical mailbox must not be signed")
        } catch let error as PlainpostError {
            guard case .notFound = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testEncoderFallsBackToLegacyAssignmentsOnAnOlderNode() async throws {
        let sender = LegacySingleAccountNodeSender(identity: "ada@example.test")
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))

        let data = try await encoder.operation(
            for: .setRead(messageIDs: [MessageID("1789")], read: false),
            logicalMailboxID: LegacySingleAccountNodeSender.logicalMailboxID, idempotencyKey: "op-legacy"
        )

        let operation = try NodeSyncCodec.decodeOperation(data)
        XCTAssertEqual(operation.unsigned.logicalMailboxID, LegacySingleAccountNodeSender.logicalMailboxID)
        XCTAssertEqual(operation.unsigned.authorityEpoch, "5")
        let paths = await sender.requests().map(\.path)
        XCTAssertEqual(paths, ["/v1/mail/accounts", "/v1/mailboxes/assignments"])
    }

    func testResetDraftRevisionsForcesADraftStateReread() async throws {
        let sender = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: sender)
        let encoder = NodeMailMutationEncoder(client: client)
        let grace = TwoAccountNodeSender.graceLogicalMailboxID
        let draft = Draft(
            id: DraftID("reset-draft"), accountID: AccountID("plainpost-account"),
            from: EmailAddress("grace@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Reset", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )

        let first = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: grace, idempotencyKey: "save-1")
        let firstResult = try await client.mutation(canonicalOperation: first)
        XCTAssertEqual(firstResult.state, "applied")
        await encoder.recordApplied(canonicalOperation: first)
        var reads = await sender.draftStateReads("reset-draft")
        XCTAssertEqual(reads, 1)

        let cached = try NodeSyncCodec.decodeOperation(try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: grace, idempotencyKey: "save-2"))
        reads = await sender.draftStateReads("reset-draft")
        XCTAssertEqual(reads, 1, "a recorded save is the draft CAS head")
        guard case let .saveDraft(_, cachedRevision, _, _) = cached.unsigned.operation else { return XCTFail("expected save_draft") }
        XCTAssertEqual(cachedRevision, "2")

        await encoder.resetDraftRevisions()
        _ = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: grace, idempotencyKey: "save-3")
        reads = await sender.draftStateReads("reset-draft")
        XCTAssertEqual(reads, 2, "reset must re-read the durable draft state")
    }

    func testDeleteDraftUsesFreshDurableRevisionAfterSave() async throws {
        let sender = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: sender)
        let encoder = NodeMailMutationEncoder(client: client)
        let mailbox = TwoAccountNodeSender.graceLogicalMailboxID
        let draft = Draft(
            id: DraftID("delete-draft"), accountID: AccountID("plainpost-account"),
            from: EmailAddress("grace@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Delete", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )

        let saved = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: mailbox, idempotencyKey: "save-draft")
        let saveResult = try await client.mutation(canonicalOperation: saved)
        XCTAssertEqual(saveResult.state, "applied")
        await encoder.recordApplied(canonicalOperation: saved)

        let deleted = try NodeSyncCodec.decodeOperation(try await encoder.operation(
            for: .deleteDraft(draft.id), logicalMailboxID: mailbox, idempotencyKey: "delete-draft"
        ))
        guard case let .deleteDraft(draftID, expectedRevision) = deleted.unsigned.operation else {
            return XCTFail("expected delete_draft")
        }
        XCTAssertEqual(draftID, draft.id.rawValue)
        XCTAssertEqual(expectedRevision, "2")
        let stateReads = await sender.draftStateReads(draft.id.rawValue)
        XCTAssertEqual(stateReads, 2,
                       "deleting must read the durable CAS revision, even when a save was cached")
    }

    func testDeleteDraftRefusesUnseenRemoteRevision() async throws {
        let sender = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: sender)
        let encoder = NodeMailMutationEncoder(client: client)
        let mailbox = TwoAccountNodeSender.graceLogicalMailboxID
        let draft = Draft(
            id: DraftID("changed-draft"), accountID: AccountID("plainpost-account"),
            from: EmailAddress("grace@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Changed", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )
        let saved = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: mailbox, idempotencyKey: "save-draft")
        _ = try await client.mutation(canonicalOperation: saved)
        await encoder.recordApplied(canonicalOperation: saved)
        await sender.advanceDraftRevision(draft.id.rawValue)

        do {
            _ = try await encoder.operation(for: .deleteDraft(draft.id), logicalMailboxID: mailbox, idempotencyKey: "delete-draft")
            XCTFail("a remote edit must prevent deletion")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("This draft changed on another device. Reopen it before deleting."))
        }
        let requests = await sender.requests()
        XCTAssertEqual(requests.filter { $0.path == "/v1/mutations" }.count, 1,
                       "only the earlier save may reach the Node")
    }

    func testDeleteDraftRefusesRestoredIdentityWithoutKnownRevision() async throws {
        let sender = TwoAccountNodeSender()
        let encoder = NodeMailMutationEncoder(client: NodeSyncClient(sender: sender))
        do {
            _ = try await encoder.operation(
                for: .deleteDraft(DraftID("unknown-draft")),
                logicalMailboxID: TwoAccountNodeSender.graceLogicalMailboxID,
                idempotencyKey: "delete-unknown"
            )
            XCTFail("an untracked draft must not be deleted")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("Save this draft before deleting it from the Sync Node."))
        }
    }

    func testRecordedDraftRevisionsAreScopedToTheirLogicalMailbox() async throws {
        let sender = TwoAccountNodeSender()
        let client = NodeSyncClient(sender: sender)
        let encoder = NodeMailMutationEncoder(client: client)
        let draft = Draft(
            id: DraftID("shared-draft-id"), accountID: AccountID("plainpost-account"),
            from: EmailAddress("ada@example.test"), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Scoped", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )

        let adaSave = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: TwoAccountNodeSender.adaLogicalMailboxID, idempotencyKey: "ada-save")
        _ = try await client.mutation(canonicalOperation: adaSave)
        await encoder.recordApplied(canonicalOperation: adaSave)
        _ = try await encoder.operation(for: .saveDraft(draft), logicalMailboxID: TwoAccountNodeSender.graceLogicalMailboxID, idempotencyKey: "grace-save")

        let reads = await sender.draftStateReads("shared-draft-id")
        XCTAssertEqual(reads, 2, "another account's recorded revision must not be reused")
    }
}
