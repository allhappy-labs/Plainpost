import Foundation
import GRDB
import XCTest
import PlainpostAccountProtocol
import PlainpostAccountRuntime
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport

final class MailIntentRouterTests: XCTestCase {
    // MARK: - Plan tests

    /// Each message change names its own Node change; nothing becomes a delete by default.
    func testEveryMessageKindMapsToItsOwnNodeChange() throws {
        let ids = [MessageID("node-1")]
        let expected: [MailIntentKind: MailMutationIntent] = [
            .markRead: .setRead(messageIDs: ids, read: true),
            .markUnread: .setRead(messageIDs: ids, read: false),
            .archive: .archive(messageIDs: ids),
            .delete: .delete(messageIDs: ids),
            .flag: .setFlagged(messageIDs: ids, flagged: true),
            .unflag: .setFlagged(messageIDs: ids, flagged: false),
            .move: .move(messageIDs: ids, destinationMailboxPath: "Receipts"),
        ]
        for kind in MailIntentKind.allCases {
            let folder = kind == .move ? "Receipts" : nil
            if kind.targetsMessage {
                XCTAssertEqual(try MailIntentRouter.mutationIntent(kind, nodeMessageID: "node-1", folder: folder), expected[kind], "\(kind)")
            } else {
                XCTAssertThrowsError(try MailIntentRouter.mutationIntent(kind, nodeMessageID: "node-1"), "\(kind)")
            }
        }
        XCTAssertThrowsError(try MailIntentRouter.mutationIntent(.move, nodeMessageID: "node-1"), "a move names its folder")
    }

    func testAMoveJournalsItsFolderAndReachesTheNodeAsAMove() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let messageID = try await harness.seedMirroredMessage(nodeID: "n1", account: 0)
        // A move without a folder is refused, and a flag names no folder.
        await XCTAssertThrowsErrorAsync(try await harness.router.performIntent(.move, messageID: messageID))
        await XCTAssertThrowsErrorAsync(try await harness.router.performIntent(.flag, messageID: messageID,
                                                                               archiveMailbox: "Receipts"))
        let dispatch = try await harness.router.performIntent(.move, messageID: messageID, archiveMailbox: "Receipts")
        let record = try XCTUnwrap(try harness.store.mailIntent(operationID: dispatch.operationID))
        XCTAssertEqual(record.kind, .move)
        XCTAssertEqual(record.archiveMailbox, "Receipts")
        let key = try XCTUnwrap(record.idempotencyKey)
        let accepted = try XCTUnwrap(harness.node.acceptedOperation(key))
        guard case let .move(_, path) = try NodeSyncCodec.decodeOperation(accepted).unsigned.operation else {
            return XCTFail("the Node got no move")
        }
        XCTAssertEqual(path, "Receipts")
    }


    func testAdmittedNodeSendIsNeverRepeatedDirectlyAfterFallback() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.scriptMutationStates(["applied", "pending"])   // saveDraft applied, send admitted
        let draft = try harness.makeDraft()

        let sendOutcome = try await harness.router.send(draft)
        XCTAssertEqual(sendOutcome, .waitingForNode)
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)

        XCTAssertEqual(harness.direct.sentDraftIDs, [])
        let record = try XCTUnwrap(harness.store.mailIntents(accountID: harness.accountID, states: [.admitted]).first)
        XCTAssertEqual(record.route, .node)
        XCTAssertTrue(MailIntentGuard.waitsForNode(record))
        XCTAssertEqual(harness.node.mutationCount, 2)
    }

    func testFallbackSendIsMacOwnedAndNeverReachesNode() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let sendOutcome = try await harness.router.send(try harness.makeDraft())
        XCTAssertEqual(sendOutcome, .confirmed)
        XCTAssertEqual(harness.direct.sentDraftIDs.count, 1)
        try harness.switchToNode()
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.node.mutationCount, 0)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testMutationIsSignedForTheOwningAccountAndRejectedDoesNotFallBack() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, accounts: 2)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "gm2.0123456789abcdef0123456789abcdef01234567", account: 1)
        let archiveOutcome = try await harness.router.perform(.archive, messageID: message)
        XCTAssertEqual(archiveOutcome, .confirmed)
        XCTAssertEqual(harness.node.lastMutationLogicalMailboxID, harness.logicalMailboxID(account: 1))
        harness.node.scriptMutationStates(["rejected"])
        guard case .failed = try await harness.router.perform(.delete, messageID: message) else { return XCTFail("rejected must fail") }
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testDispatchPendingSkipsLifecycleOwnedCredentialPushes() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        _ = try harness.store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000031", accountID: harness.accountID,
                                                kind: .credentialPush, messageID: nil, draftID: nil, now: Date())
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(try harness.store.mailIntents(accountID: harness.accountID, states: [.pending]).map(\.kind), [.credentialPush])
    }

    // MARK: - Journal first, one intent, idempotency key pass-through

    func testTheJournalRowExistsBeforeAnyNetworkCall() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-journal-first", account: 0)
        harness.node.clearRequests()
        let gate = harness.node.hold("/v1/mail/accounts")
        let router = harness.router
        let dispatch = Task { try await router.perform(.markRead, messageID: message) }
        try await harness.waitUntil { gate.hasArrived }
        let journaled = try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases))
        XCTAssertEqual(journaled.map(\.kind), [.markRead])
        XCTAssertEqual(journaled.first?.state, .pending)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
        gate.release()
        let outcome = try await dispatch.value
        XCTAssertEqual(outcome, .confirmed)
    }

    func testOneIntentPerActionAndTheOperationIDIsTheNodeIdempotencyKey() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-key", account: 0)

        let dispatch = try await harness.router.performIntent(.archive, messageID: message)

        XCTAssertEqual(dispatch.outcome, .confirmed)
        let rows = try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operationID, dispatch.operationID)
        XCTAssertTrue(MailIntentRecord.isValidOperationID(dispatch.operationID))
        XCTAssertEqual(harness.node.acceptedIdempotencyKeys, [dispatch.operationID])
        let signed = try NodeSyncCodec.decodeOperation(try XCTUnwrap(harness.node.acceptedOperation(dispatch.operationID)))
        XCTAssertEqual(signed.unsigned.idempotencyKey, dispatch.operationID)
        XCTAssertEqual(signed.unsigned.operation, .archive(messageIDs: ["n-key"]))
    }

    func testALostAcknowledgementIsUncertainAndSettlesByReplayingTheExactRequestOnce() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-lost", account: 0)
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()   // the immediate reconcile cannot reach the Node either

        let dispatch = try await harness.router.performIntent(.markRead, messageID: message)

        XCTAssertEqual(dispatch.outcome, .uncertain)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .uncertain)
        XCTAssertEqual(try harness.store.mailIntentsWaitingForNode(messageIDs: [message]), [message])
        // A later settle replays the retained exact bytes; the Node dedupes by key.
        await harness.router.settleAdmittedIntents(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
        XCTAssertEqual(harness.node.signedMutationCount, 1, "an uncertain intent is never re-encoded")
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testAnImmediateReconcileSettlesALostAcknowledgement() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-reconcile", account: 0)
        harness.node.failNextMutationAfterDispatch()

        let outcome = try await harness.router.perform(.archive, messageID: message)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
        XCTAssertEqual(harness.node.mutationPostCount, 1)
    }

    func testDeliveryUncertainIsNeverRecordedAsFailed() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.scriptMutationStates(["applied", "delivery_uncertain"])
        let draft = try harness.makeDraft()

        let dispatch = try await harness.router.sendIntent(draft)

        XCTAssertEqual(dispatch.outcome, .uncertain)
        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .uncertain)
        XCTAssertFalse(MailIntentGuard.mayResend(record))
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.direct.sentDraftIDs, [])
    }

    func testAnAdmittedIntentSettlesThroughItsRetainedRequest() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-admitted", account: 0)
        harness.node.scriptMutationStates(["pending"])
        let dispatch = try await harness.router.performIntent(.delete, messageID: message)
        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .admitted)

        harness.node.settlePendingMutations(to: "applied")
        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
        XCTAssertEqual(harness.node.signedMutationCount, 1)
    }

    func testConcurrentDispatchersSendTheIntentOnce() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-race", account: 0)
        let gate = harness.node.hold("/v1/mail/accounts")
        let router = harness.router
        let first = Task { try await router.performIntent(.archive, messageID: message) }
        try await harness.waitUntil { gate.hasArrived }
        // The journaled intent is still pending; a second dispatcher takes it.
        await router.dispatchPending(accountID: harness.accountID)
        gate.release()
        let dispatch = try await first.value

        XCTAssertEqual(dispatch.outcome, .confirmed)
        XCTAssertEqual(harness.node.mutationPostCount, 1, "only the begin-dispatch winner sends")
        XCTAssertEqual(harness.node.mutationCount, 1)
    }

    func testAnIntentIsAdmittedOnlyAfterTheNodeAnswers() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-in-flight", account: 0)
        harness.node.scriptMutationStates(["pending"])
        let gate = harness.node.hold("/v1/mutations")
        let router = harness.router
        let dispatch = Task { try await router.performIntent(.archive, messageID: message) }
        try await harness.waitUntil { gate.hasArrived }

        let inFlight = try XCTUnwrap(harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases)).first)
        XCTAssertEqual(inFlight.state, .dispatching)
        XCTAssertEqual(inFlight.route, .node)
        XCTAssertEqual(try harness.store.mailIntentsWaitingForNode(messageIDs: [message]), [])
        gate.release()
        let result = try await dispatch.value
        XCTAssertEqual(result.state, .admitted)
    }

    // MARK: - Retained receipts belong to their own intent

    func testASettledRetainedReceiptUpdatesItsOwnIntentAndNeverFailsTheNewAction() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let first = try await harness.seedMirroredMessage(nodeID: "n-first", account: 0)
        let second = try await harness.seedMirroredMessage(nodeID: "n-second", account: 0)
        harness.node.scriptMutationStates(["pending"])
        let earlier = try await harness.router.performIntent(.archive, messageID: first)
        XCTAssertEqual(try harness.intent(earlier.operationID).state, .admitted)
        // The Node settles the earlier operation as conflicted; the session
        // replays its retained request on the next request.
        try harness.node.retainAnswer(for: earlier.operationID, state: "conflicted")

        let later = try await harness.router.performIntent(.markRead, messageID: second)

        XCTAssertEqual(later.outcome, .confirmed)
        XCTAssertEqual(try harness.intent(earlier.operationID).state, .failed)
        XCTAssertEqual(try harness.intent(later.operationID).state, .confirmed)
    }

    // MARK: - Stale epoch and 409 (I5)

    func testAStaleEpochConflictIsResignedOnceUnderANewKey() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-epoch", account: 0)
        harness.node.answerNextMutationAsStaleEpoch()

        let dispatch = try await harness.router.performIntent(.archive, messageID: message)

        XCTAssertEqual(dispatch.outcome, .confirmed)
        let newKey = MailIntentRouter.rekey(dispatch.operationID)
        XCTAssertEqual(harness.node.acceptedIdempotencyKeys, [dispatch.operationID, newKey],
                       "the old key stays bound to its conflicted receipt; the re-signed operation uses a new key")
        XCTAssertEqual(harness.node.signedMutationCount, 2)
        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.idempotencyKey, newKey)
        let stored = try XCTUnwrap(harness.store.mailIntentCanonicalOperation(operationID: dispatch.operationID))
        XCTAssertEqual(try NodeSyncCodec.decodeOperation(stored).unsigned.idempotencyKey, newKey)
        XCTAssertEqual(try NodeSyncCodec.decodeOperation(stored).unsigned.authorityEpoch, "2")
    }

    func testAConflictedReceiptWithoutAnEpochMoveFailsAndIsNotResigned() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-conflicted", account: 0)
        harness.node.scriptMutationStates(["conflicted"])

        guard case .failed = try await harness.router.perform(.archive, messageID: message) else { return XCTFail("expected failed") }
        XCTAssertEqual(harness.node.signedMutationCount, 1)
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testA409IsReplayedWithTheExactBytesAndThenIsUncertainNeverFailed() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-bound", account: 0)
        let operationID = "00000000-0000-4000-8000-000000000051"
        harness.node.bindKey(operationID)

        let dispatch = try await harness.router.performIntent(.archive, messageID: message, operationID: operationID)

        XCTAssertEqual(dispatch.outcome, .uncertain)
        let record = try harness.intent(operationID)
        XCTAssertEqual(record.state, .uncertain)
        XCTAssertFalse(MailIntentGuard.mayResend(record))
        XCTAssertEqual(harness.node.mutationPostCount, 2, "the exact bytes are replayed once")
        XCTAssertEqual(harness.node.signedMutationCount, 1, "a 409 is never re-signed")
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.direct.performedActions, [])
        // Its exact replay answers 409 again: it ends unconfirmed, never failed.
        try harness.switchToNode()
        await harness.router.settleAdmittedIntents(accountID: harness.accountID)
        let settled = try harness.intent(operationID)
        XCTAssertEqual(settled.state, .unconfirmed)
        XCTAssertFalse(MailIntentGuard.mayResend(settled))
    }

    // MARK: - Durable replay (R1) and the uncertain amendment (R2)

    func testAnAdmittedIntentSettlesAfterARestartFromItsStoredBytes() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-restart", account: 0)
        harness.node.scriptMutationStates(["pending"])
        let dispatch = try await harness.router.performIntent(.archive, messageID: message)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .admitted)

        // A new service process: nothing of the first router survives.
        let reopened = try SQLiteMailStore(path: harness.url.path)
        let restarted = MailIntentRouter(store: reopened, direct: harness.direct, processStartedAt: Date())
        await restarted.attach(sessions: harness.sessions)
        harness.node.settlePendingMutations(to: "applied")
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
        XCTAssertEqual(harness.node.signedMutationCount, 1, "settled by replaying the stored bytes, never re-encoded")
    }

    func testACrashedNodeDispatchSettlesFromItsStoredBytes() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-crash-bytes", account: 0)
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(dispatch.outcome, .uncertain)
        // The session's retained answer is lost with the process.
        _ = try await harness.node.reconcilePendingRequest()

        let reopened = try SQLiteMailStore(path: harness.url.path)
        let restarted = MailIntentRouter(store: reopened, direct: harness.direct, processStartedAt: Date())
        await restarted.attach(sessions: harness.sessions)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
    }

    func testAnUncertainIntentFailsOnlyWhenItsExactReplayIsRejected() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-replay-rejected", account: 0)
        harness.node.scriptMutationStates(["rejected"])
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.performIntent(.delete, messageID: message)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .uncertain)
        _ = try await harness.node.reconcilePendingRequest()

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(try harness.store.mailIntentsWaitingForNode(messageIDs: [message]), [])
    }

    func testAnUncertainIntentWhoseReplayIsConflictedBecomesUnconfirmed() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-replay-conflicted", account: 0)
        harness.node.scriptMutationStates(["conflicted"])
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.performIntent(.archive, messageID: message)
        _ = try await harness.node.reconcilePendingRequest()

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .unconfirmed)
        XCTAssertFalse(MailIntentGuard.mayResend(record), "it may have taken effect")
        XCTAssertEqual(try harness.store.mailIntentsWaitingForNode(messageIDs: [message]), [], "the badge clears")
    }

    // MARK: - Save stage (fix round 2)

    /// A send whose draft save lost its answer: the save is journaled under
    /// its key and the send's target revision, with no stored bytes.
    private func sendWithLostSave(_ harness: MailIntentRouterHarness, drainRetained: Bool) async throws -> (Draft, String) {
        let draft = try harness.makeDraft()
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.sendIntent(draft)
        XCTAssertEqual(dispatch.outcome, .uncertain)
        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.idempotencyKey, MailIntentRouter.saveKey(for: dispatch.operationID), "the save key is journaled")
        XCTAssertEqual(record.sendRevision, "2")
        XCTAssertNil(try harness.store.mailIntentCanonicalOperation(operationID: dispatch.operationID))
        if drainRetained { _ = try await harness.node.reconcilePendingRequest() }
        return (draft, dispatch.operationID)
    }

    private func restartedRouter(_ harness: MailIntentRouterHarness) async throws -> MailIntentRouter {
        let reopened = try SQLiteMailStore(path: harness.url.path)
        let router = MailIntentRouter(store: reopened, direct: harness.direct, processStartedAt: Date(), sleep: { _ in })
        await router.attach(sessions: harness.sessions)
        return router
    }

    func testASendWhoseSaveWasLostIsRedoneAfterARestartAndSentOnce() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let (_, operationID) = try await sendWithLostSave(harness, drainRetained: true)

        let restarted = try await restartedRouter(harness)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds, ["save_draft", "save_draft", "send"], "the save is redone, the send leaves once")
        XCTAssertEqual(harness.node.acceptedIdempotencyKeys.last, operationID)
        XCTAssertEqual(harness.node.acceptedStates.last, "applied")
        let sent = try NodeSyncCodec.decodeOperation(try XCTUnwrap(harness.node.acceptedOperation(operationID)))
        guard case let .send(_, revision) = sent.unsigned.operation else { return XCTFail("expected a send") }
        XCTAssertEqual(revision, "4", "the redone save moved the draft to 4; the send is signed there")
        XCTAssertEqual(try harness.intent(operationID).sendRevision, "4")
    }

    func testARedoWhileTheOriginalSaveIsStillPendingSendsOnce() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.scriptMutationStates(["pending"])
        let dispatch = try await harness.router.sendIntent(try harness.makeDraft())
        XCTAssertEqual(dispatch.outcome, .uncertain, "the save stays pending on the Node")
        XCTAssertNil(try harness.store.mailIntentCanonicalOperation(operationID: dispatch.operationID))

        let restarted = try await restartedRouter(harness)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds, ["save_draft", "save_draft", "send"])
        XCTAssertEqual(harness.node.acceptedStates, ["pending", "applied", "applied"], "the original save is left as it is")
    }

    /// Two settle passes race for one send whose save was lost: A is held
    /// while its redone save is on the wire.
    private func racingSettles(_ harness: MailIntentRouterHarness) async throws -> (String, Task<Void, Never>, FakeNodeMailServer.Gate) {
        let (_, operationID) = try await sendWithLostSave(harness, drainRetained: true)
        await harness.router.forgetProcessMemory()
        let gate = harness.node.hold("/v1/mutations")
        let router = harness.router
        let accountID = harness.accountID
        let first = Task { await router.settleAdmittedIntents(accountID: accountID) }
        try await harness.waitUntil { gate.hasArrived }
        return (operationID, first, gate)
    }

    func testConcurrentSettlePassesNeverWorkOnOneRowAtOnce() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let (operationID, first, gate) = try await racingSettles(harness)
        let postsWhileHeld = harness.node.mutationPostCount

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)
        XCTAssertEqual(harness.node.mutationPostCount, postsWhileHeld, "the second pass leaves the row to the first")

        gate.release()
        await first.value
        XCTAssertEqual(try harness.intent(operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds.filter { $0 == "send" }.count, 1)
    }

    func testASaveStageIsNeverFailedOnceItsSendBytesAreStored() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        await harness.router.disableSingleFlightForTesting()
        let (operationID, first, gate) = try await racingSettles(harness)
        let heldKey = MailIntentRouter.rekey(MailIntentRouter.saveKey(for: operationID))
        harness.node.scriptMutationStates(["applied", "pending"])   // B: save applied, send admitted

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)
        XCTAssertNotNil(try harness.store.mailIntentCanonicalOperation(operationID: operationID), "B stored and posted the send")
        // A's held save now meets its key bound to other bytes: a 409, twice.
        harness.node.bindKey(heldKey)
        gate.release()
        await first.value

        let record = try harness.intent(operationID)
        XCTAssertEqual(record.state, .uncertain, "A's failed save must not fail a send that may have left")
        XCTAssertTrue(try harness.store.mailIntentSendInFlight(draftID: try XCTUnwrap(record.draftID)), "the draft stays locked")
        XCTAssertEqual(harness.node.acceptedKinds.filter { $0 == "send" }.count, 1)
    }

    func testARetainedSaveReceiptAttachesToItsSendAfterARestart() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let (_, operationID) = try await sendWithLostSave(harness, drainRetained: false)

        let restarted = try await restartedRouter(harness)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds, ["save_draft", "send"], "the retained applied save is used, not redone")
    }

    func testAnUncertainSendWhoseSaveIsRejectedFailsAndUnlocksItsDraft() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.scriptMutationStates(["rejected"])
        let (draft, operationID) = try await sendWithLostSave(harness, drainRetained: true)

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(operationID).state, .failed)
        XCTAssertFalse(try harness.store.mailIntentSendInFlight(draftID: draft.id), "the draft lock is released")
        XCTAssertEqual(harness.node.acceptedKinds, ["save_draft"])
    }

    func testAnUncertainSendWhoseDraftWasEditedFailsAndNeverSends() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let (draft, operationID) = try await sendWithLostSave(harness, drainRetained: true)
        _ = try harness.store.updateDraft(id: draft.id, patch: DraftPatch(bodyPlain: "edited while waiting"),
                                          actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))

        let restarted = try await restartedRouter(harness)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(operationID).state, .failed)
        XCTAssertFalse(try harness.store.mailIntentSendInFlight(draftID: draft.id))
        XCTAssertFalse(harness.node.acceptedKinds.contains("send"))
    }

    func testASendIsBoundToTheApprovedSaveRevision() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.editDraftOnAnotherDeviceAfterNextSave()

        let dispatch = try await harness.router.sendIntent(try harness.makeDraft())

        guard case .failed = dispatch.outcome else { return XCTFail("a send of content the user never approved must not go out") }
        XCTAssertEqual(harness.node.acceptedKinds, ["save_draft", "send"])
        XCTAssertEqual(harness.node.acceptedStates, ["applied", "conflicted"], "the Node's revision check refused the send")
        let signed = try NodeSyncCodec.decodeOperation(try XCTUnwrap(harness.node.acceptedOperation(dispatch.operationID)))
        XCTAssertEqual(signed.unsigned.operation, .send(draftID: try XCTUnwrap(harness.intent(dispatch.operationID).draftID).rawValue,
                                                       expectedRevision: "2"))
    }

    func testAStandaloneDraftSaveWithALostAnswerIsRedoneAfterARestart() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.saveDraftIntent(try harness.makeDraft())
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .uncertain)
        XCTAssertEqual(try harness.intent(dispatch.operationID).idempotencyKey, dispatch.operationID, "the save key is journaled")
        _ = try await harness.node.reconcilePendingRequest()

        let restarted = try await restartedRouter(harness)
        await restarted.settleAdmittedIntents(accountID: harness.accountID)

        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .confirmed)
        XCTAssertEqual(record.idempotencyKey, MailIntentRouter.rekey(dispatch.operationID))
    }

    func testAQueueDrainUnderALeaseOnlySessionLeavesIntentsPending() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, readOnly: true)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-drain-read-only", account: 0)
        harness.sessions.setReachable(false)
        let dispatch = try await harness.router.performIntent(.archive, messageID: message)
        harness.sessions.setReachable(true)

        await harness.router.dispatchPending(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .pending, "read-only is a passing session state")
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testSettleNeverReplaysBytesSignedForAnotherNode() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-other-node", account: 0)
        harness.node.setSigningNodeID("40000000-0000-4000-8000-000000000999")
        harness.node.scriptMutationStates(["pending"])
        let dispatch = try await harness.router.performIntent(.archive, messageID: message)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .admitted)
        let posts = harness.node.mutationPostCount

        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(harness.node.mutationPostCount, posts)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .admitted)
    }

    func testConcurrentRowsKeepTheirOwnPendingReason() async throws {
        // An unavailable head must stop its drain and reset its stall count,
        // even while an independent row reports a different pending reason.
        for targetBlocked in [true, false] {
            let clock = RouterClock()
            let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, accounts: 2,
                                                                 now: { clock.now })
            defer { harness.cleanUp() }
            let first = try await harness.seedMirroredMessage(nodeID: "n-isolated-head", account: 0)
            let second = try await harness.seedMirroredMessage(nodeID: "n-isolated-tail", account: 0)
            let other = try await harness.seedMirroredMessage(nodeID: "n-independent", account: 1)
            harness.sessions.setReachable(false)
            let head = try await harness.router.performIntent(.archive, messageID: first)
            clock.advance(1)
            let tail = try await harness.router.performIntent(.markRead, messageID: second)
            let older = try await harness.router.performIntent(.markRead, messageID: other)
            clock.advance(1)
            let newer = try await harness.router.performIntent(.markUnread, messageID: other)
            harness.sessions.setReachable(true)
            try harness.flip(account: 1, mode: .fallback)
            let sessions = PausedRouterSessions(base: harness.sessions)
            await harness.router.attach(sessions: sessions)
            let transientAttempts = SignalCounter()
            if !targetBlocked {
                await harness.router.setBeginFailpoint { id in
                    if id == older.operationID {
                        transientAttempts.increment()
                        throw TestBusyDatabase()
                    }
                }
            }

            for pass in 1...MailIntentRouter.headStallPassLimit {
                let arrived = expectation(description: "head paused at client lookup, pass \(pass)")
                await sessions.pauseNextLookup(arrived: { arrived.fulfill() })
                let draining = Task { await harness.router.dispatchPending(accountID: harness.accountID) }
                await fulfillment(of: [arrived], timeout: 5)
                let independent = try await harness.router.performIntent(
                    targetBlocked ? .markUnread : .markRead, messageID: other,
                    operationID: targetBlocked ? newer.operationID : older.operationID)
                XCTAssertEqual(independent.state, .pending)
                if targetBlocked {
                    XCTAssertEqual(independent.detail, MailIntentRouter.waitingForEarlierChangeMessage)
                } else {
                    XCTAssertEqual(transientAttempts.value, pass, "independent row reached the transient store failure")
                }
                await sessions.releaseLookup()
                await draining.value
                XCTAssertEqual(try harness.intent(head.operationID).state, .pending)
                XCTAssertEqual(try harness.intent(tail.operationID).state, .pending,
                               "unavailable head stops; targetBlocked=\(targetBlocked), pass=\(pass) must not skip or spend stall budget")
            }

            // Only this row's actual transient failures count toward its bound.
            await harness.router.setBeginFailpoint { id in
                if id == head.operationID { throw TestBusyDatabase() }
            }
            for _ in 1..<MailIntentRouter.headStallPassLimit {
                await harness.router.dispatchPending(accountID: harness.accountID)
                XCTAssertEqual(try harness.intent(tail.operationID).state, .pending)
            }
            await harness.router.dispatchPending(accountID: harness.accountID)
            XCTAssertEqual(try harness.intent(tail.operationID).state, .confirmed)
            XCTAssertEqual(try harness.intent(head.operationID).state, .pending)
            XCTAssertEqual(try harness.intent(older.operationID).state, .pending)
            XCTAssertEqual(try harness.intent(newer.operationID).state, .pending)
        }
    }

    func testAPersistentlyStuckHeadRowStopsBlockingTheQueueWithoutFailing() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let first = try await harness.seedMirroredMessage(nodeID: "n-stuck-head", account: 0)
        let second = try await harness.seedMirroredMessage(nodeID: "n-behind-head", account: 0)
        let head = "00000000-0000-4000-8000-000000000061"
        await harness.router.setBeginFailpoint { operationID in
            if operationID == head { throw TestBusyDatabase() }
        }
        harness.sessions.setReachable(false)
        _ = try await harness.router.performIntent(.archive, messageID: first, operationID: head)
        let behind = try await harness.router.performIntent(.markRead, messageID: second)
        harness.sessions.setReachable(true)

        for _ in 1..<MailIntentRouter.headStallPassLimit {
            await harness.router.dispatchPending(accountID: harness.accountID)
            XCTAssertEqual(try harness.intent(behind.operationID).state, .pending, "order holds while the head may recover")
        }
        await harness.router.dispatchPending(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(behind.operationID).state, .confirmed)
        XCTAssertEqual(try harness.intent(head).state, .pending, "the stuck row is never failed for it")
    }

    func testAnUnrenderableDraftIsRefusedAndDoesNotBlockTheQueue() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-after-unrenderable", account: 0)
        let empty = try harness.store.createDraft(
            Draft(id: DraftID("drf_router_no_recipients"), accountID: harness.accountID, from: EmailAddress("user0@example.test"),
                  to: [], cc: [], bcc: [], subject: "No one", bodyPlain: "body", createdBy: "local-user", aiGenerated: false,
                  sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
        harness.sessions.setReachable(false)
        let save = try await harness.router.saveDraftIntent(empty)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        harness.sessions.setReachable(true)

        await harness.router.dispatchPending(accountID: harness.accountID)

        let refused = try harness.intent(save.operationID)
        XCTAssertEqual(refused.state, .failed)
        XCTAssertNil(refused.route)
        XCTAssertEqual(try harness.intent(read.operationID).state, .confirmed)
    }

    func testAStuckHeadNeverLetsALaterChangeToTheSameMessageOvertakeIt() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let stuckMessage = try await harness.seedMirroredMessage(nodeID: "n-stuck-target", account: 0)
        let other = try await harness.seedMirroredMessage(nodeID: "n-free-target", account: 0)
        let head = "00000000-0000-4000-8000-000000000071"
        await harness.router.setBeginFailpoint { operationID in
            if operationID == head { throw TestBusyDatabase() }
        }
        harness.sessions.setReachable(false)
        _ = try await harness.router.performIntent(.markRead, messageID: stuckMessage, operationID: head)
        let sameTarget = try await harness.router.performIntent(.markUnread, messageID: stuckMessage)
        let otherTarget = try await harness.router.performIntent(.archive, messageID: other)
        harness.sessions.setReachable(true)

        for _ in 0..<MailIntentRouter.headStallPassLimit {
            await harness.router.dispatchPending(accountID: harness.accountID)
        }

        XCTAssertEqual(try harness.intent(head).state, .pending)
        XCTAssertEqual(try harness.intent(sameTarget.operationID).state, .pending, "per-message order holds")
        XCTAssertEqual(try harness.intent(otherTarget.operationID).state, .confirmed)
    }

    // MARK: - Errors after journaling (I1, I2) and approved content (I3)

    func testABusyStoreDuringBeginLeavesTheIntentPendingInsteadOfReportingFailure() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-busy", account: 0)
        await harness.router.setBeginFailpoint { _ in throw TestBusyDatabase() }

        let dispatch = try await harness.router.performIntent(.archive, messageID: message)

        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .pending)
        await harness.router.setBeginFailpoint(nil)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
    }

    func testAPendingSendOfADiscardedDraftIsRefusedWithoutBlockingLaterIntents() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-after-discard", account: 0)
        let draft = try harness.makeDraft()
        harness.sessions.setReachable(false)
        let save = try await harness.router.saveDraftIntent(draft)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(try harness.intent(save.operationID).state, .pending)
        try await harness.store.databasePool.write { database in
            try database.execute(sql: "DELETE FROM drafts WHERE id = ?", arguments: [draft.id.rawValue])
        }

        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: harness.accountID)

        let refused = try harness.intent(save.operationID)
        XCTAssertEqual(refused.state, .failed)
        XCTAssertNil(refused.route)
        XCTAssertEqual(try harness.intent(read.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds, ["set_read"])
    }

    func testAQueuedSendOfAnEditedDraftIsRefusedAndNeverSent() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()
        harness.sessions.setReachable(false)
        let dispatch = try await harness.router.sendIntent(draft)
        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        XCTAssertEqual(try harness.intent(dispatch.operationID).contentHash, draft.contentHash)
        _ = try harness.store.updateDraft(id: draft.id, patch: DraftPatch(bodyPlain: "edited after send"),
                                          actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))

        harness.sessions.setReachable(true)
        await harness.router.dispatchPending(accountID: harness.accountID)
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)

        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .failed)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
        XCTAssertEqual(harness.direct.sentDraftIDs, [])
    }

    func testADraftWithASendInFlightIsLockedAgainstASecondSend() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()
        harness.sessions.setReachable(false)
        _ = try await harness.router.sendIntent(draft)

        await XCTAssertThrowsErrorAsync(try await harness.router.sendIntent(draft)) {
            XCTAssertEqual($0 as? MailIntentRouterError, .sendInProgress)
        }
        XCTAssertEqual(try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases)).count, 1)
    }

    func testAFallbackSendDeliversOnlyTheApprovedContent() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()
        _ = try await harness.router.send(draft)
        XCTAssertEqual(harness.direct.sentApprovedHashes, [draft.contentHash])
    }

    func testAnArchiveCarriesItsDestinationToTheDirectRoute() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()
        _ = try await harness.router.performIntent(.archive, messageID: message, archiveMailbox: "Processed/Rules")
        XCTAssertEqual(harness.direct.archiveMailboxes, ["Processed/Rules"])
    }

    // MARK: - Unreachable, detached, unsynced

    func testBeforeAttachANodeIntentStaysPendingAndReturnsWaiting() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, attach: false)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-detached", account: 0)

        let dispatch = try await harness.router.performIntent(.archive, messageID: message)

        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .pending)
        XCTAssertNil(record.route)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
        XCTAssertEqual(harness.direct.performedActions, [])
        // Spec semantics: a pending, unrouted intent shows no badge.
        XCTAssertEqual(try harness.store.mailIntentsWaitingForNode(messageIDs: [message]), [])

        await harness.router.attach(sessions: harness.sessions)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
    }

    func testAnUnreachableNodeLeavesTheIntentPendingForDispatchPending() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-unreachable", account: 0)
        harness.sessions.setReachable(false)

        let dispatch = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .pending)

        // Fallback then dispatches it directly: it never reached the Node.
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(try harness.intent(dispatch.operationID).route, .direct)
        XCTAssertEqual(harness.direct.performedActions, [RecordingDirectMailDispatcher.Action(kind: .markRead, messageID: message)])
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testAMessageWithoutANodeLinkFailsWithoutDirectFallback() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()

        let outcome = try await harness.router.perform(.archive, messageID: message)

        XCTAssertEqual(outcome, .failed("Message isn't synced with the Sync Node yet."))
        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testAnUncertainNodeIntentIsNeverReroutedDirect() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-reroute", account: 0)
        harness.node.failNextMutationAfterDispatch()
        harness.node.failNextReconcile()
        let dispatch = try await harness.router.performIntent(.archive, messageID: message)
        XCTAssertEqual(dispatch.outcome, .uncertain)

        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)
        _ = try harness.store.rerouteUnstartedDirectIntents(accountID: harness.accountID, now: Date())

        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(try harness.intent(dispatch.operationID).route, .node)
    }

    // MARK: - Direct (fallback) outcomes

    func testAnAmbiguousDirectOutcomeStaysDispatchingAndIsNeverFailed() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        harness.direct.failNext(with: DirectDispatchTestError.connectionLostAfterCommand)

        let dispatch = try await harness.router.sendIntent(try harness.makeDraft())

        XCTAssertEqual(dispatch.outcome, .uncertain)
        let record = try harness.intent(dispatch.operationID)
        XCTAssertEqual(record.state, .dispatching)
        XCTAssertEqual(record.route, .direct)
        XCTAssertFalse(MailIntentGuard.mayResend(record))
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.direct.sentDraftIDs.count, 1, "an ambiguous send is never sent again")
    }

    func testAnAuthoritativeDirectRefusalFails() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        harness.direct.failNext(with: DirectMailDispatchRefusal(message: "Sign in again."))

        let outcome = try await harness.router.send(try harness.makeDraft())

        XCTAssertEqual(outcome, .failed("Sign in again."))
    }

    func testDraftSaveInFallbackUsesTheDirectDraftPath() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()

        let outcome = try await harness.router.saveDraft(draft)

        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(harness.direct.savedDraftIDs, [draft.id])
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    // MARK: - Source first, schema, read-only

    func testADirectAccountIsRefusedAndNeverJournaled() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .direct)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()

        await XCTAssertThrowsErrorAsync(try await harness.router.perform(.archive, messageID: message)) {
            XCTAssertEqual($0 as? MailIntentRouterError, .notNodeBacked)
        }
        XCTAssertEqual(try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases)), [])
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testAnAbsentJournalCannotRouteAndNeverFallsBackDirect() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()
        let reopened = try harness.reopenWithoutJournal()
        let router = MailIntentRouter(store: reopened, direct: harness.direct)
        await router.attach(sessions: harness.sessions)

        await XCTAssertThrowsErrorAsync(try await router.perform(.archive, messageID: message)) {
            XCTAssertEqual($0 as? MailIntentRouterError, .journalUnavailable)
        }
        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testLeaseOnlyAdmissionRefusesTheMutationWithATypedError() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, readOnly: true)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-read-only", account: 0)

        var operationID: String?
        do {
            _ = try await harness.router.perform(.archive, messageID: message)
            XCTFail("a lease-only session must refuse mutations")
        } catch {
            XCTAssertEqual(error as? MailIntentRouterError, .readOnly)
        }
        operationID = try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases)).first?.operationID
        let record = try harness.intent(try XCTUnwrap(operationID))
        XCTAssertEqual(record.state, .failed, "a refused mutation is never queued to run later")
        XCTAssertEqual(harness.node.mutationPostCount, 0)
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    // MARK: - Recovery, journal content

    func testInterruptedNodeDispatchIsRecoveredBeforeTheRouterDispatches() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-crash", account: 0)
        let crashed = "00000000-0000-4000-8000-000000000041"
        let then = Date(timeIntervalSinceNow: -60)
        _ = try harness.store.journalMailIntent(operationID: crashed, accountID: harness.accountID, kind: .archive,
                                                messageID: message, draftID: nil, now: then)
        _ = try harness.store.beginMailIntentDispatch(operationID: crashed, route: .node, now: then)
        let router = MailIntentRouter(store: harness.store, direct: harness.direct, processStartedAt: Date(timeIntervalSinceNow: -1))
        await router.attach(sessions: harness.sessions)

        _ = try await router.perform(.markRead, messageID: message)

        XCTAssertEqual(try harness.intent(crashed).state, .uncertain)
        XCTAssertEqual(harness.node.acceptedKinds, ["set_read"])
    }

    func testJournalRowsCarryNoBodyRecipientOrCredential() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        harness.node.scriptMutationStates(["applied", "applied"])
        let draft = try harness.makeDraft(body: "secret-body-text", recipient: "hidden-recipient@example.test")
        _ = try await harness.router.send(draft)

        let (count, rendered, columns) = try await harness.store.databasePool.read { database -> (Int, String, Set<String>) in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM mail_intent_journal")
            return (rows.count, rows.map(\.description).joined(), Set(rows.first.map { Array($0.columnNames) } ?? []))
        }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(rendered.contains("secret-body-text"))
        XCTAssertFalse(rendered.contains("hidden-recipient"))
        XCTAssertEqual(columns, ["operation_id", "account_id", "kind", "route", "state", "message_id", "draft_id",
                                 "created_at", "updated_at", "idempotency_key", "canonical_operation", "content_hash",
                                 "archive_mailbox", "send_revision", "reported", "deferral_count", "deferral_reason",
                                 "first_deferred_at", "deferral_due_at", "next_attempt_at"])
    }

    func testJournalMovesPostAMailboxChangeSignal() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-signal", account: 0)
        let counter = SignalCounter()
        let observer = NotificationCenter.default.addObserver(forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil) { note in
            if MailStoreChangeSignal.scope(from: note) == .mailbox { counter.increment() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        harness.node.scriptMutationStates(["pending"])

        _ = try await harness.router.perform(.archive, messageID: message)

        XCTAssertGreaterThanOrEqual(counter.value, 2, "journal and admitted moves each post a change")
    }
}

// MARK: - Fix round 1 (Task 17): vault gate, deferral, reported, cancellation

final class RouterGateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Closes the vault gate right after its first direct write, as a lock
/// landing in the middle of a fallback drain does.
final class LockingDirectMailDispatcher: DirectMailDispatching, @unchecked Sendable {
    let gate: RouterGateFlag
    private let lock = NSLock()
    private var performed: [MailIntentKind] = []
    var performedKinds: [MailIntentKind] { lock.withLock { performed } }
    init(gate: RouterGateFlag) { self.gate = gate }
    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        lock.withLock { performed.append(action) }
        gate.value = false
    }
    func saveDraft(_ draft: Draft) async throws {}
    func send(_ draft: Draft, approvedContentHash: String) async throws {}
}

final class MailIntentRouterFixRoundTests: XCTestCase {
    func testALockMidDrainLeavesTheRemainingRowsPending() async throws {
        let gate = RouterGateFlag(true)
        let direct = LockingDirectMailDispatcher(gate: gate)
        let harness = try await MailIntentRouterHarness.make(
            testName: #function, source: .fallback, direct: direct, directDispatchAllowed: { gate.value })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()
        let ids = (1...3).map { "00000000-0000-4000-8000-00000000017\($0)" }
        for (index, id) in ids.enumerated() {
            _ = try harness.store.journalMailIntent(operationID: id, accountID: harness.accountID,
                                                    kind: index == 1 ? .markUnread : .markRead, messageID: message,
                                                    draftID: nil, now: Date(timeIntervalSinceNow: Double(index)))
        }

        await harness.router.dispatchPending(accountID: harness.accountID)

        XCTAssertEqual(direct.performedKinds, [.markRead])
        XCTAssertEqual(try harness.intent(ids[0]).state, .confirmed)
        for id in ids.dropFirst() {
            let row = try harness.intent(id)
            XCTAssertEqual(row.state, .pending, "never failed by the lock")
            XCTAssertNil(row.route)
        }
        gate.value = true
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(direct.performedKinds.count, 2, "the next open pass resumes (and the gate closes again)")
        gate.value = true
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try ids.map { try harness.intent($0).state }, [.confirmed, .confirmed, .confirmed])
    }

    func testAPreEffectDeferralReturnsTheRowToPendingAndALaterPassSendsIt() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()
        harness.direct.failNext(with: DirectMailDispatchDeferral(reason: "Plainpost is locked."))

        let dispatch = try await harness.router.performIntent(.archive, messageID: message)

        XCTAssertEqual(dispatch.state, .pending)
        XCTAssertEqual(dispatch.outcome, .waitingForNode)
        XCTAssertNil(try harness.intent(dispatch.operationID).route)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.direct.performedActions.count, 2)
    }

    func testOnlyOutcomesTheCallerWasNotToldAreLeftForANotice() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        // Interactive: the caller gets the failure.
        harness.direct.failNext(with: DirectMailDispatchRefusal(message: "refused"))
        let interactive = try await harness.router.sendIntent(try harness.makeDraft())
        guard case .failed = interactive.outcome else { return XCTFail("expected a refusal") }
        // Queued in Node mode, then failed by a fallback drain.
        try harness.switchToNode()
        harness.sessions.setReachable(false)
        let queued = try await harness.router.sendIntent(try harness.makeDraft())
        XCTAssertEqual(queued.outcome, .waitingForNode)
        try harness.switchToFallback()
        harness.direct.failNext(with: DirectMailDispatchRefusal(message: "refused"))
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(queued.operationID).state, .failed)

        let unreported = try harness.store.unreportedSendOutcomes(after: .distantPast, limit: 20)
        XCTAssertEqual(unreported.map(\.operationID), [queued.operationID])
    }

    func testACancelledDrainStartsNoDispatch() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage()
        _ = try harness.store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000181", accountID: harness.accountID,
                                                kind: .markRead, messageID: message, draftID: nil, now: Date())
        let router = harness.router
        let accountID = harness.accountID
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await router.dispatchPending(accountID: accountID)
        }.value
        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(try harness.intent("00000000-0000-4000-8000-000000000181").state, .pending)
    }
}

// MARK: - Fix round 7 (Task 17): bounded transient deferrals

final class RouterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Every direct write fails before any provider effect because the mail
/// server cannot be reached, except for the listed messages.
final class UnreachableDirectMailDispatcher: DirectMailDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var reachableStorage: Set<MessageID> = []
    private var attemptsByTarget: [String: Int] = [:]
    private var performedStorage: [MessageID] = []
    var reachable: Set<MessageID> {
        get { lock.withLock { reachableStorage } }
        set { lock.withLock { reachableStorage = newValue } }
    }
    var performed: [MessageID] { lock.withLock { performedStorage } }
    private var performedKindStorage: [MailIntentKind] = []
    var performedKinds: [MailIntentKind] { lock.withLock { performedKindStorage } }
    func attempts(_ key: String) -> Int { lock.withLock { attemptsByTarget[key] ?? 0 } }
    private func unreachable(_ key: String) -> DirectMailDispatchDeferral {
        lock.withLock { attemptsByTarget[key, default: 0] += 1 }
        return DirectMailDispatchDeferral(transient: .mailServerUnreachable)
    }
    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        guard self.reachable.contains(messageID) else { throw unreachable(messageID.rawValue) }
        lock.withLock {
            performedStorage.append(messageID)
            performedKindStorage.append(action)
        }
    }
    func saveDraft(_ draft: Draft) async throws { throw unreachable(draft.id.rawValue) }
    func send(_ draft: Draft, approvedContentHash: String) async throws { throw unreachable(draft.id.rawValue) }
}

final class MailIntentRouterDeferralTests: XCTestCase {
    static let unreachableReason = "Plainpost couldn't reach your mail server."

    func testAPermanentlyUnreachableServerGetsBoundedAttemptsThenFailsWithANotice() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()
        harness.sessions.setReachable(false)
        let queued = try await harness.router.sendIntent(draft)
        try harness.switchToFallback()

        var passes = 0
        while try harness.intent(queued.operationID).state == .pending, passes < 200 {
            await harness.router.dispatchPending(accountID: harness.accountID)
            clock.advance(15)
            passes += 1
        }

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .failed, "nothing was sent: failed, and the user is told")
        XCTAssertEqual(direct.attempts(draft.id.rawValue), MailIntentRouter.directDeferralLimit, "a bounded number of attempts")
        XCTAssertGreaterThan(passes, MailIntentRouter.directDeferralLimit, "backed off between attempts")
        XCTAssertEqual(row.deferralReason, .mailServerUnreachable, "the notice can say why")
        XCTAssertNil(row.nextAttemptAt)
        XCTAssertEqual(try harness.store.unreportedSendOutcomes(after: .distantPast, limit: 20).map(\.operationID),
                       [queued.operationID], "the send-failed notice appears")
    }

    func testADeferredRowStopsThePassAndLaterPassesSkipItWhileItBacksOff() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let head = try harness.seedUnlinkedMessage(uid: 42)
        let second = try harness.seedUnlinkedMessage(uid: 43)
        let reachable = try harness.seedUnlinkedMessage(uid: 44)
        direct.reachable = [reachable]
        let first = try await harness.router.performIntent(.markRead, messageID: head)
        XCTAssertEqual(first.state, .pending)
        XCTAssertEqual(first.detail, Self.unreachableReason + " It will retry.")
        XCTAssertEqual(try harness.intent(first.operationID).deferralReason, .mailServerUnreachable)
        XCTAssertEqual(try harness.store.pendingDirectDeferrals().map(\.reason), [.mailServerUnreachable])
        _ = try harness.store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000191", accountID: harness.accountID,
                                                kind: .markRead, messageID: second, draftID: nil,
                                                now: clock.now.addingTimeInterval(1))
        _ = try harness.store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000192", accountID: harness.accountID,
                                                kind: .markRead, messageID: reachable, draftID: nil,
                                                now: clock.now.addingTimeInterval(2))
        // The head backs off; the next row fails the same way and ends the
        // pass: one failing provider attempt per pass while the server is down.
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(direct.attempts(head.rawValue), 1, "not retried before its next attempt time")
        XCTAssertEqual(direct.attempts(second.rawValue), 1)
        XCTAssertEqual(direct.performed, [], "a deferral ends the pass")
        // Both back off: the other target goes out.
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(direct.performed, [reachable])
        XCTAssertEqual(direct.attempts(head.rawValue), 1)
        clock.advance(31)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(direct.attempts(head.rawValue), 2, "retried once its back-off passed")
    }

    func testASleepGapStartsANewRunSoOneErrorDoesNotFailTheRow() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 0 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        for _ in 1..<(MailIntentRouter.directDeferralLimit - 1) {
            clock.advance(1)
            await harness.router.dispatchPending(accountID: harness.accountID)
        }
        XCTAssertEqual(try harness.intent(queued.operationID).deferralCount, MailIntentRouter.directDeferralLimit - 1)

        // The Mac slept for an hour: well past the window and the gap.
        clock.advance(3_600)
        await harness.router.dispatchPending(accountID: harness.accountID)

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .pending, "one error after a long gap is a new run, not the last straw")
        XCTAssertEqual(row.deferralCount, 1)
        XCTAssertEqual(row.firstDeferredAt, clock.now)
        XCTAssertEqual(direct.attempts(message.rawValue), MailIntentRouter.directDeferralLimit)
    }

    func testAReconnectSendsABackingOffRowThroughTheNodeAtOnce() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-backoff", account: 0)
        try harness.switchToFallback()
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        let deferred = try harness.intent(queued.operationID)
        XCTAssertGreaterThan(try XCTUnwrap(deferred.nextAttemptAt), clock.now)

        try harness.switchToNode()
        _ = try await harness.router.rerouteUnstartedDirectIntents(accountID: harness.accountID)
        await harness.router.dispatchPending(accountID: harness.accountID)

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.route, .node, "the direct back-off does not hold a Node dispatch")
        XCTAssertEqual(harness.node.mutationPostCount, 1)
        XCTAssertEqual(row.deferralCount, 0, "a Node dispatch ends the direct run")
        XCTAssertNil(row.firstDeferredAt)
        XCTAssertNil(row.nextAttemptAt)
        XCTAssertNil(row.deferralReason)
        XCTAssertEqual(try harness.store.pendingDirectDeferrals().count, 0)
    }

    func testANodeRefusalAfterAReconnectDoesNotCarryTheMailServerReason() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        harness.sessions.setReachable(false)
        let queued = try await harness.router.sendIntent(try harness.makeDraft())
        try harness.switchToFallback()
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(queued.operationID).deferralReason, .mailServerUnreachable)

        try harness.switchToNode()
        harness.sessions.setReachable(true)
        harness.node.scriptMutationStates(["rejected"])
        await harness.router.dispatchPending(accountID: harness.accountID)

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .failed, "the Node refused the draft save")
        XCTAssertNil(row.deferralReason, "the send-failed notice must not blame the mail server")
        XCTAssertEqual(row.deferralCount, 0)
    }

    func testAnInteractiveChangeWaitsBehindAnOlderBackingOffChangeToTheSameMessage() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(read.state, .pending, "the mail server is unreachable: mark-read backs off")
        direct.reachable = [message]
        clock.advance(1)

        let unread = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(unread.state, .pending, "mark-unread must not overtake the older mark-read")
        XCTAssertEqual(unread.detail, DirectDeferralReason.mailServerUnreachable.message + " It will retry.",
                       "it waits on the older change, and says why")
        XCTAssertEqual(direct.performedKinds, [])

        clock.advance(31)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(direct.performedKinds, [.markRead, .markUnread], "sent in order: the message ends unread")
        XCTAssertEqual(try harness.intent(read.operationID).state, .confirmed)
        XCTAssertEqual(try harness.intent(unread.operationID).state, .confirmed)
    }

    func testTheStoreRefusesADirectBeginAheadOfAnOlderChangeToTheSameTarget() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let other = try harness.seedUnlinkedMessage(uid: 43)
        let start = Date()
        let older = "00000000-0000-4000-8000-000000000301"
        let newer = "00000000-0000-4000-8000-000000000302"
        let elsewhere = "00000000-0000-4000-8000-000000000303"
        _ = try harness.store.journalMailIntent(operationID: older, accountID: harness.accountID, kind: .markRead,
                                                messageID: message, draftID: nil, now: start)
        _ = try harness.store.journalMailIntent(operationID: newer, accountID: harness.accountID, kind: .markUnread,
                                                messageID: message, draftID: nil, now: start.addingTimeInterval(1))
        _ = try harness.store.journalMailIntent(operationID: elsewhere, accountID: harness.accountID, kind: .markUnread,
                                                messageID: other, draftID: nil, now: start.addingTimeInterval(2))
        XCTAssertThrowsError(try harness.store.beginMailIntentDispatch(operationID: newer, route: .direct, now: start)) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertNoThrow(try harness.store.beginMailIntentDispatch(operationID: elsewhere, route: .direct, now: start))
        XCTAssertNoThrow(try harness.store.beginMailIntentDispatch(operationID: older, route: .direct, now: start))
        _ = try harness.store.recordMailIntentOutcome(operationID: older, state: .confirmed, now: start)
        XCTAssertNoThrow(try harness.store.beginMailIntentDispatch(operationID: newer, route: .direct, now: start),
                         "once the older change settled, the newer one goes")
    }

    func testARowOlderThanADayFailsAtItsNextTransientDeferral() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 0 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        // Many sleep cycles: each long gap would start a new run.
        clock.advance(MailIntentRouter.directDeferralMaxAge)
        await harness.router.dispatchPending(accountID: harness.accountID)

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .failed, "a day after it was queued, nothing was sent: failed")
        XCTAssertEqual(row.deferralReason, .mailServerUnreachable)
        let retried = try await harness.router.performIntent(.markRead, messageID: message, operationID: queued.operationID)
        XCTAssertEqual(retried.outcome, .failed(DirectDeferralReason.mailServerUnreachable.message + " Nothing was sent."),
                       "a failed direct row reports its own reason, not a Sync Node refusal")
    }

    func testTheRestartGapIsMeasuredFromWhenTheRowWasDue() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 500 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        // 700 s after the deferral, but only 200 s after it was due (a
        // queue delay, not a sleep): the same run.
        clock.advance(700)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(queued.operationID).deferralCount, 2)
    }

    func testAFailureWriteThatCannotLandPutsTheRowBackToPending() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 0 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        await harness.router.setFailAfterDeferralsFailpoint { if $0 == .fail { throw TestBusyDatabase() } }
        for _ in 1..<(MailIntentRouter.directDeferralLimit - 1) {
            clock.advance(1)
            await harness.router.dispatchPending(accountID: harness.accountID)
        }
        // The last straw arrives on the interactive path (a durable retry).
        clock.advance(1)
        let reverted = try await harness.router.performIntent(.markRead, messageID: message, operationID: queued.operationID)
        XCTAssertEqual(reverted.state, .pending)
        XCTAssertEqual(reverted.detail, Self.unreachableReason + " It will retry.", "the caller hears why it waits")
        var row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .pending, "never stranded in dispatching(direct), which is never resent")
        XCTAssertNil(row.route)
        XCTAssertEqual(row.deferralCount, MailIntentRouter.directDeferralLimit, "the run stays at its limit")
        XCTAssertNotNil(row.nextAttemptAt, "the next attempt is scheduled, not immediate")

        await harness.router.setFailAfterDeferralsFailpoint(nil)
        clock.advance(1)
        await harness.router.dispatchPending(accountID: harness.accountID)
        row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .failed, "the next attempt, still unreachable, fails it")
    }

    func testAFailureThatCanNeitherBeWrittenNorRevertedFailsTheRowAtTheNextDrain() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 0 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        await harness.router.setFailAfterDeferralsFailpoint { _ in throw TestBusyDatabase() }
        for _ in 1..<MailIntentRouter.directDeferralLimit {
            clock.advance(1)
            await harness.router.dispatchPending(accountID: harness.accountID)
        }
        var row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .dispatching, "neither write landed")
        let attempts = direct.attempts(message.rawValue)

        await harness.router.setFailAfterDeferralsFailpoint(nil)
        clock.advance(1)
        await harness.router.dispatchPending(accountID: harness.accountID)
        row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .failed, "never left in dispatching(direct), which is never resent")
        XCTAssertEqual(row.deferralReason, .mailServerUnreachable)
        XCTAssertEqual(direct.attempts(message.rawValue), attempts, "failing it sends nothing")
    }

    func testASuccessClearsTheDeferralState() async throws {
        let clock = RouterClock()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback,
                                                             now: { clock.now }, directDeferralBackoff: { _ in 0 })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        harness.direct.failNext(with: DirectMailDispatchDeferral(transient: .mailServerUnreachable))
        harness.direct.failNext(with: DirectMailDispatchDeferral(transient: .mailServerUnreachable))
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        clock.advance(1)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(queued.operationID).deferralCount, 2)
        clock.advance(1)
        await harness.router.dispatchPending(accountID: harness.accountID)

        let row = try harness.intent(queued.operationID)
        XCTAssertEqual(row.state, .confirmed)
        XCTAssertEqual(row.deferralCount, 0)
        XCTAssertNil(row.deferralReason)
        XCTAssertNil(row.firstDeferredAt)
        XCTAssertNil(row.deferralDueAt)
        XCTAssertNil(row.nextAttemptAt)
    }

    func testADurableRetryOfTheSameOperationRespectsTheBackOff() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let operationID = MailIntentRouter.operationID(derivedFrom: "mailbox-job\u{0}job-1")
        _ = try await harness.router.performIntent(.markRead, messageID: message, operationID: operationID)
        let retried = try await harness.router.performIntent(.markRead, messageID: message, operationID: operationID)
        XCTAssertEqual(direct.attempts(message.rawValue), 1, "a job retry does not spend an attempt early")
        XCTAssertEqual(retried.state, .pending)
        XCTAssertEqual(retried.detail, Self.unreachableReason + " It will retry.")
        clock.advance(31)
        _ = try await harness.router.performIntent(.markRead, messageID: message, operationID: operationID)
        XCTAssertEqual(direct.attempts(message.rawValue), 2)
    }
}

/// Same-target ordering: a newer change to a message or draft never starts
/// before an older one has a recorded outcome, and ordering never turns a
/// read-only refusal into a queued change.
final class MailIntentRouterOrderingTests: XCTestCase {
    static let waitingMessage = "Waiting for an earlier change to this message."

    func testAChangeUnderALeaseOnlySessionIsRefusedEvenBehindAnOlderPendingChange() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, readOnly: true)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-read-only", account: 0)
        harness.sessions.setReachable(false)
        let older = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(older.state, .pending)
        harness.sessions.setReachable(true)

        await XCTAssertThrowsErrorAsync(try await harness.router.perform(.markUnread, messageID: message)) {
            XCTAssertEqual($0 as? MailIntentRouterError, .readOnly, "a change made while read-only always fails")
        }
        let rows = try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases))
        let newer = try XCTUnwrap(rows.first { $0.operationID != older.operationID })
        XCTAssertEqual(newer.state, .failed, "never queued behind the older change")
        XCTAssertEqual(try harness.intent(older.operationID).state, .pending)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testAChangeMadeWhileReadOnlyIsRefusedEvenWhenTheNodeIsUnreachable() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node, readOnly: true)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-read-only-unreachable", account: 0)
        harness.sessions.setReachable(false)
        harness.sessions.setAdmission(.readOnly(expiresAt: Date(timeIntervalSinceNow: 3_600)))

        await XCTAssertThrowsErrorAsync(try await harness.router.perform(.archive, messageID: message)) {
            XCTAssertEqual($0 as? MailIntentRouterError, .readOnly, "known locally, without the Node")
        }
        let rows = try harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases))
        XCTAssertEqual(rows.map(\.state), [.failed], "never queued to be sent once the Node is back")

        harness.sessions.setReachable(true)
        harness.sessions.setAdmission(.readWrite)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.node.mutationPostCount, 0)
    }

    func testTheWaitingDetailNamesTheOlderReasonOnlyWhileItBacksOff() async throws {
        let clock = RouterClock()
        let direct = UnreachableDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct,
                                                             now: { clock.now })
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        let due = try XCTUnwrap(try harness.intent(read.operationID).nextAttemptAt)
        // The back-off is over, but no drain has retried the older row yet.
        clock.advance(due.timeIntervalSince(clock.now) + 1)

        let unread = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(unread.state, .pending)
        XCTAssertEqual(unread.detail, Self.waitingMessage, "the older row is not backing off: no stale reason")
        XCTAssertEqual(direct.attempts(message.rawValue), 1, "the newer change never reached the mail server")
    }

    func testAnOrderingReadErrorLeavesTheChangePendingInsteadOfOvertaking() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-read-error", account: 0)
        harness.sessions.setReachable(false)
        let older = try await harness.router.performIntent(.markRead, messageID: message)
        harness.sessions.setReachable(true)
        harness.node.scriptMutationStates(["applied", "applied"])
        await harness.router.setOrderingReadFailpoint { throw TestBusyDatabase() }

        let newer = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(newer.state, .pending, "an unreadable journal must not let the change overtake")
        XCTAssertEqual(harness.node.mutationPostCount, 0)

        await harness.router.setOrderingReadFailpoint(nil)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(older.operationID).state, .confirmed)
        XCTAssertEqual(try harness.intent(newer.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationPostCount, 2)
    }

    func testAnUncertainChangeThatNeverReachedTheNodeIsReplayedBeforeANewerOne() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-uncertain", account: 0)
        // The mark-read is signed and stored, but its request never leaves
        // this device and nothing is retained: `uncertain` with bytes the
        // Node never saw (the client retries a pre-dispatch failure once).
        harness.node.failNextMutationBeforeDispatch(times: 2)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(read.state, .uncertain)
        XCTAssertEqual(harness.node.mutationCount, 0)

        let unread = try await harness.router.performIntent(.markUnread, messageID: message)
        await harness.router.settleAdmittedIntents(accountID: harness.accountID)

        XCTAssertEqual(harness.node.acceptedKinds, ["set_read", "set_unread"], "the Node applies them in order: the message ends unread")
        XCTAssertEqual(unread.state, .confirmed)
        XCTAssertEqual(try harness.intent(read.operationID).state, .confirmed)
    }

    func testANewerChangeWaitsWhileAnOlderUncertainOneCannotBeReplayed() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-uncertain-down", account: 0)
        // Two posts (each retried once) never leave: the dispatch and the
        // replay the newer change asks for.
        harness.node.failNextMutationBeforeDispatch(times: 4)
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(read.state, .uncertain)

        // Its replay cannot get an answer either: the newer change waits.
        let unread = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(unread.state, .pending)
        XCTAssertEqual(unread.detail, Self.waitingMessage)
        XCTAssertEqual(harness.node.mutationCount, 0)

        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(harness.node.acceptedKinds, ["set_read", "set_unread"])
        XCTAssertEqual(try harness.intent(unread.operationID).state, .confirmed)
    }

    func testANewerDirectChangeWaitsBehindAnOlderNodeChangeTheNodeMayStillApply() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-admitted-fallback", account: 0)
        harness.node.scriptMutationStates(["pending"])
        let read = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(read.state, .admitted)
        try harness.switchToFallback()
        harness.sessions.setReachable(false)

        let unread = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(unread.state, .pending, "the Node may still apply the mark-read after a direct mark-unread")
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testANewerNodeChangeWaitsWhileAnOlderOneIsOnTheWire() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-in-flight", account: 0)
        harness.node.scriptMutationStates(["applied", "applied"])
        let gate = harness.node.hold("/v1/mutations")
        let router = harness.router
        let olderTask = Task { try await router.performIntent(.markRead, messageID: message) }
        try await harness.waitUntil(timeout: .seconds(30)) { gate.hasArrived }

        let newer = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(newer.state, .pending, "never started while the older change is in flight")
        XCTAssertEqual(newer.detail, Self.waitingMessage)
        XCTAssertEqual(harness.node.requests.filter { $0 == "POST /v1/mutations" }.count, 1)

        gate.release()
        let older = try await olderTask.value
        XCTAssertEqual(older.state, .confirmed)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(newer.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationPostCount, 2)
    }

    func testANewerDirectChangeWaitsWhileAnOlderOneIsOnTheWire() async throws {
        let direct = GatedDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let router = harness.router
        let olderTask = Task { try await router.performIntent(.markRead, messageID: message) }
        try await harness.waitUntil(timeout: .seconds(30)) { direct.arrivals == 1 }

        let newer = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(newer.state, .pending, "never started while the older change is in flight")
        XCTAssertEqual(newer.detail, Self.waitingMessage)
        XCTAssertEqual(direct.arrivals, 1)

        direct.release()
        let settled = try await olderTask.value
        XCTAssertEqual(settled.state, .confirmed)
        await harness.router.dispatchPending(accountID: harness.accountID)
        XCTAssertEqual(try harness.intent(newer.operationID).state, .confirmed)
        XCTAssertEqual(direct.performedKinds, [.markRead, .markUnread])
    }

    func testAChangeToAnotherMessageIsNotHeldBackByAnInFlightChange() async throws {
        let direct = GatedDirectMailDispatcher()
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback, direct: direct)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        let other = try harness.seedUnlinkedMessage(uid: 43)
        direct.gated = [message]
        let router = harness.router
        let olderTask = Task { try await router.performIntent(.markRead, messageID: message) }
        try await harness.waitUntil(timeout: .seconds(30)) { direct.arrivals == 1 }

        let elsewhere = try await harness.router.performIntent(.markRead, messageID: other)
        XCTAssertEqual(elsewhere.state, .confirmed)
        direct.release()
        _ = try await olderTask.value
    }

    func testAnAdmittedOlderChangeDoesNotHoldBackANewerOneOnTheNode() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .node)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-order-admitted", account: 0)
        harness.node.scriptMutationStates(["pending", "applied"])
        let older = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(older.state, .admitted)

        let newer = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(newer.state, .confirmed, "the Node orders changes it already holds by arrival")
    }

    func testAnAmbiguousDirectChangeDoesNotHoldBackANewerOne() async throws {
        let harness = try await MailIntentRouterHarness.make(testName: #function, source: .fallback)
        defer { harness.cleanUp() }
        let message = try harness.seedUnlinkedMessage(uid: 42)
        harness.direct.failNext(with: DirectDispatchTestError.connectionLostAfterCommand)
        let older = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(older.state, .dispatching, "ended ambiguously: never resent")

        let newer = try await harness.router.performIntent(.markUnread, messageID: message)
        XCTAssertEqual(newer.state, .confirmed, "an ambiguous row has nothing left on the wire to order behind")
    }
}

/// Holds the first gated `perform` until the test releases it; later ones
/// go through, so a change that wrongly overtakes shows up instead of hanging.
final class GatedDirectMailDispatcher: DirectMailDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var arrivalCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var kinds: [MailIntentKind] = []
    private var gatedStorage: Set<MessageID>?

    var arrivals: Int { lock.withLock { arrivalCount } }
    var performedKinds: [MailIntentKind] { lock.withLock { kinds } }
    /// Messages whose writes are held; nil holds every write.
    var gated: Set<MessageID>? {
        get { lock.withLock { gatedStorage } }
        set { lock.withLock { gatedStorage = newValue } }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        let holds = lock.withLock { () -> Bool in
            let holds = gatedStorage.map { $0.contains(messageID) } ?? true
            if holds { arrivalCount += 1 }
            return holds && arrivalCount == 1 && !released
        }
        if holds {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        lock.withLock { kinds.append(action) }
    }

    func saveDraft(_ draft: Draft) async throws {}
    func send(_ draft: Draft, approvedContentHash: String) async throws {}
}

// MARK: - Harness

enum DirectDispatchTestError: Error { case connectionLostAfterCommand }
struct TestBusyDatabase: Error {}

final class RecordingDirectMailDispatcher: DirectMailDispatching, @unchecked Sendable {
    struct Action: Equatable { let kind: MailIntentKind; let messageID: MessageID }
    private let lock = NSLock()
    private var actions: [Action] = []
    private var archives: [String?] = []
    private var approvedHashes: [String] = []
    private var sent: [DraftID] = []
    private var saved: [DraftID] = []
    private var failures: [any Error] = []

    var performedActions: [Action] { lock.withLock { actions } }
    var archiveMailboxes: [String?] { lock.withLock { archives } }
    var sentApprovedHashes: [String] { lock.withLock { approvedHashes } }
    var sentDraftIDs: [DraftID] { lock.withLock { sent } }
    var savedDraftIDs: [DraftID] { lock.withLock { saved } }
    func failNext(with error: any Error) { lock.withLock { failures.append(error) } }

    private func nextFailure() -> (any Error)? {
        lock.withLock { failures.isEmpty ? nil : failures.removeFirst() }
    }

    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        lock.withLock {
            actions.append(Action(kind: action, messageID: messageID))
            archives.append(archiveMailbox)
        }
        if let failure = nextFailure() { throw failure }
    }

    func saveDraft(_ draft: Draft) async throws {
        lock.withLock { saved.append(draft.id) }
        if let failure = nextFailure() { throw failure }
    }

    func send(_ draft: Draft, approvedContentHash: String) async throws {
        lock.withLock {
            sent.append(draft.id)
            approvedHashes.append(approvedContentHash)
        }
        if let failure = nextFailure() { throw failure }
    }
}

final class StubNodeMailSessions: NodeMailSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var reachable = true
    private let client: NodeSyncClient
    private let nodeID: String

    init(client: NodeSyncClient, nodeID: String) {
        self.client = client
        self.nodeID = nodeID
    }

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    private var admission: NodeSessionAdmission?
    /// The locally read admission; nil (unknown) by default.
    func setAdmission(_ value: NodeSessionAdmission?) { lock.withLock { admission = value } }

    func sessionAdmission(nodeID: String) async -> NodeSessionAdmission? {
        lock.withLock { admission }
    }

    func reachableClient(nodeID: String) async -> NodeSyncClient? {
        lock.withLock { reachable && nodeID == self.nodeID ? client : nil }
    }
}

/// Pauses exactly one client lookup and answers unavailable after release.
/// Other lookups keep using the real harness client, so a wrongly skipped
/// head visibly dispatches the next row instead of hiding behind an outage.
private actor PausedRouterSessions: NodeMailSessionProviding {
    let base: StubNodeMailSessions
    private var arrived: (@Sendable () -> Void)?
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    init(base: StubNodeMailSessions) { self.base = base }

    func pauseNextLookup(arrived: @escaping @Sendable () -> Void) {
        self.arrived = arrived
        released = false
    }

    func releaseLookup() {
        released = true
        held?.resume()
        held = nil
    }

    func reachableClient(nodeID: String) async -> NodeSyncClient? {
        guard let arrived else { return await base.reachableClient(nodeID: nodeID) }
        self.arrived = nil
        arrived()
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { held = continuation }
        }
        return nil
    }

    func sessionAdmission(nodeID: String) async -> NodeSessionAdmission? {
        await base.sessionAdmission(nodeID: nodeID)
    }
}

final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

struct MailIntentRouterHarness {
    enum Source { case node, fallback, direct }
    static let nodeID = "40000000-0000-4000-8000-000000000916"

    let store: SQLiteMailStore
    let url: URL
    let accountIDs: [AccountID]
    var accountID: AccountID { accountIDs[0] }
    let node: FakeNodeMailServer
    let direct: RecordingDirectMailDispatcher
    let sessions: StubNodeMailSessions
    let router: MailIntentRouter

    static func make(
        testName: String, source: Source, accounts: Int = 1, attach: Bool = true, readOnly: Bool = false,
        direct customDirect: (any DirectMailDispatching)? = nil,
        directDispatchAllowed: @escaping @Sendable () async -> Bool = { true },
        now: @escaping @Sendable () -> Date = Date.init,
        directDeferralBackoff: @escaping @Sendable (Int) -> TimeInterval = MailIntentRouter.directDeferralBackoff(attempt:)
    ) async throws -> MailIntentRouterHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plainpost.sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let cached = (0..<accounts).map { index in
            Account(id: AccountID("acc-\(index)"), displayName: "Account \(index)", email: EmailAddress("user\(index)@example.test"),
                    imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        }
        try store.cacheAccounts(cached)
        let node = FakeNodeMailServer()
        node.setSigningNodeID(nodeID)
        let client: NodeSyncClient
        if readOnly {
            let broker = NodeSessionBroker(
                resolveSender: { [node] in (Self.nodeID, node) },
                check: { NodeSessionCheck(admission: .readOnly(expiresAt: Date(timeIntervalSinceNow: 3_600)), binding: nil) },
                identityReadiness: { .ready }
            )
            client = try await broker.client().client
        } else {
            client = NodeSyncClient(sender: node)
        }
        let sessions = StubNodeMailSessions(client: client, nodeID: nodeID)
        let direct = RecordingDirectMailDispatcher()
        let router = MailIntentRouter(store: store, direct: customDirect ?? direct, now: now, sleep: { _ in },
                                      directDispatchAllowed: directDispatchAllowed, directDeferralBackoff: directDeferralBackoff)
        if attach { await router.attach(sessions: sessions) }
        let harness = MailIntentRouterHarness(store: store, url: url, accountIDs: cached.map(\.id), node: node, direct: direct,
                                              sessions: sessions, router: router)
        for index in 0..<accounts {
            switch source {
            case .direct: break
            case .node: try harness.flip(account: index, mode: .node)
            case .fallback: try harness.flip(account: index, mode: .fallback)
            }
        }
        return harness
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func logicalMailboxID(account index: Int) -> LogicalMailboxID {
        index == 0 ? FakeNodeMailServer.accountA : FakeNodeMailServer.accountB
    }

    func flip(account index: Int, mode: NodeBackedMode) throws {
        let accountID = accountIDs[index]
        var current = try store.mailSource(accountID: accountID)
        if current.kind != .nodeBacked {
            current = try store.replaceMailSource(
                current.nodeBacked(nodeID: Self.nodeID, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(logicalMailboxID(account: index)),
                                   providerIdentity: "user\(index)@example.test"),
                expectedGeneration: current.generation)
        }
        if current.mode != mode {
            _ = try store.replaceMailSource(current.withMode(mode), expectedGeneration: current.generation)
        }
    }

    func switchToFallback() throws { for index in accountIDs.indices { try flip(account: index, mode: .fallback) } }
    func switchToNode() throws { for index in accountIDs.indices { try flip(account: index, mode: .node) } }

    func intent(_ operationID: String) throws -> MailIntentRecord {
        try XCTUnwrap(try store.mailIntent(operationID: operationID))
    }

    func makeDraft(body: String = "Hello from the router test", recipient: String = "to@example.test") throws -> Draft {
        try store.createDraft(
            Draft(id: DraftID("drf_router_\(UUID().uuidString.prefix(8).lowercased())"), accountID: accountID,
                  from: EmailAddress("user0@example.test"), to: [EmailAddress(recipient)], cc: [], bcc: [],
                  subject: "Router", bodyPlain: body, createdBy: "local-user", aiGenerated: false, sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
    }

    /// Mirrors one Node message into the local store through the real mirror
    /// and returns its local message ID.
    func seedMirroredMessage(nodeID: String, account index: Int) async throws -> MessageID {
        let logical = logicalMailboxID(account: index)
        node.addMessage(nodeID: nodeID, rfcMessageID: "<\(nodeID)@example.test>", memberships: [("INBOX", 1, UInt32(abs(nodeID.hashValue) % 90_000 + 1), [])],
                        logical: logical)
        let mirror = NodeMailMirror(store: store, client: NodeSyncClient(sender: node), nodeID: Self.nodeID)
        _ = try await mirror.runPass()
        return try XCTUnwrap(try store.messageID(forNodeMessageID: nodeID, accountID: accountIDs[index]))
    }

    /// A local message with no Node link (for example direct-synced before the flip).
    func seedUnlinkedMessage(uid: Int = 42) throws -> MessageID {
        let rfcMessageID = "<unlinked-\(UUID().uuidString)@example.test>"
        let id = MessageID(IMAPSyncService.canonicalMessageID(accountID: accountID, rfcMessageID: rfcMessageID))
        let message = MessageSummary(id: id, threadID: nil, from: EmailAddress("a@example.test"), subject: "Hi", preview: "Hi",
                                     smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                                     body: "Hi", rfcMessageID: rfcMessageID)
        _ = try store.commitIncomingMessage(
            message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 7, uid: uid, notificationDisposition: .ineligible)
        return id
    }

    /// Another process's view of the same file after the journal table
    /// disappeared (v2 absent): writes throw `schemaUnavailable`.
    func reopenWithoutJournal() throws -> SQLiteMailStore {
        try store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_intent_journal")
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'node-mode-v2-mail-intent-journal'")
        }
        return try SQLiteMailStore(path: url.path)
    }

    func waitUntil(timeout: Duration = .seconds(3), _ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for a condition") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
