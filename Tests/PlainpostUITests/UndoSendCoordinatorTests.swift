import Foundation
import XCTest
@testable import PlainpostCore
import PlainpostDB
@testable import PlainpostUI

final class UndoSendCoordinatorTests: XCTestCase {
    @MainActor func testUncertainDeliveryShowsReviewStatusWithoutResendAction() async throws {
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: UncertainSender(), sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()
        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .uncertain }
        XCTAssertNil(coordinator.restoreFailedSend())
        XCTAssertFalse(coordinator.isSendPending)
    }

    /// The From account is checked again when the Undo window ends: one removed or moved to
    /// Sync Node meanwhile never sends, and the draft comes back to the user.
    @MainActor func testValidationFailureAtTheEndOfUndoKeepsTheDraft() async throws {
        let sleeper = ControllableSleeper()
        let sender = RecordingSender()
        let coordinator = UndoSendCoordinator(
            sender: sender,
            sleep: { duration in try await sleeper.sleep(duration) },
            validateBeforeSend: { _, _ in throw PlainpostError.permissionDenied("account changed") }
        )
        let snapshot = ComposerRestoreSnapshot.fixture()
        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.hasFailedSend }
        XCTAssertTrue(sender.drafts.isEmpty)
        XCTAssertEqual(coordinator.restoreFailedSend()?.subject, snapshot.subject)
    }

    @MainActor func testSuccessfulSendReportsItsDraft() async throws {
        let sleeper = ControllableSleeper()
        var sentFrom: [AccountID] = []
        let coordinator = UndoSendCoordinator(
            sender: RecordingSender(),
            sleep: { duration in try await sleeper.sleep(duration) },
            didSend: { sentFrom.append($0.accountID) }
        )
        let snapshot = ComposerRestoreSnapshot.fixture()
        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(sentFrom, [AccountID("acc_test")])
    }

    /// The end-of-Undo check compares the draft's account with its source as of Send, so a
    /// source that changed and came back within the window is still caught.
    @MainActor func testTheEndOfUndoCheckSeesTheSourceAsOfSend() async throws {
        let sleeper = ControllableSleeper()
        let sender = RecordingSender()
        var generation: Int64 = 1
        let coordinator = UndoSendCoordinator(
            sender: sender,
            sleep: { duration in try await sleeper.sleep(duration) },
            sourceAtSchedule: { _ in generation },
            validateBeforeSend: { _, scheduled in
                guard scheduled == 3 else { throw PlainpostError.permissionDenied("source changed") }
            }
        )
        let snapshot = ComposerRestoreSnapshot.fixture()
        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        generation = 3
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.hasFailedSend }
        XCTAssertTrue(sender.drafts.isEmpty, "scheduled at 1, so the check refuses")
    }

    @MainActor func testRestoredUncertainDraftCannotBeScheduledAgain() throws {
        let snapshot = ComposerRestoreSnapshot.fixture()
        let draft = snapshot.fixtureDraft
        let intent = DirectSendIntent(
            draftID: draft.id, contentHash: draft.contentHash,
            accountID: draft.accountID, sourceGeneration: 1, state: .uncertain
        )
        let coordinator = UndoSendCoordinator(sender: RecordingSender(), uncertainIntents: [intent])
        XCTAssertEqual(coordinator.snackbarState, .uncertain)
        XCTAssertFalse(coordinator.schedule(draft: draft, restoring: snapshot))
        XCTAssertEqual(coordinator.snackbarState, .uncertain)
    }
    func testLegacyRestoreSnapshotWithoutAttachmentsDecodesAsEmpty() throws {
        let encoded = try JSONEncoder().encode(ComposerRestoreSnapshot.fixture())
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "attachments")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(ComposerRestoreSnapshot.self, from: legacyData)

        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    @MainActor
    func testUndoPreservesAttachmentMetadataAndBytes() async throws {
        let attachment = DraftAttachment(
            id: "att-undo",
            filename: "undo.txt",
            mimeType: "text/plain",
            data: Data("restore me".utf8)
        )
        let snapshot = ComposerRestoreSnapshot.fixture(attachments: [attachment])
        let coordinator = UndoSendCoordinator(sender: RecordingSender())

        XCTAssertTrue(coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot))

        XCTAssertEqual(coordinator.undoLatestSend()?.attachments, [attachment])
    }

    @MainActor
    func testUndoCancelsPendingDeliveryAndReturnsOriginalSnapshot() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture(subject: "Correct recipient")

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        let restored = coordinator.undoLatestSend()

        XCTAssertEqual(restored, snapshot)
        await sleeper.resumeAll()
        XCTAssertTrue(sender.drafts.isEmpty)
        XCTAssertNil(coordinator.snackbarState)
    }

    @MainActor
    func testDelayDeliversOnceAtTenSecondsAndReportsSent() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        guard case let .pending(actualSnapshot, _) = coordinator.snackbarState else {
            return XCTFail("Expected a pending undo-send snackbar.")
        }
        XCTAssertEqual(actualSnapshot, snapshot)
        XCTAssertTrue(sender.drafts.isEmpty)

        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(sender.drafts, [snapshot.fixtureDraft])
        XCTAssertEqual(coordinator.snackbarState, .sent)
    }

    @MainActor
    func testASendQueuedForTheSyncNodeIsNeverReportedAsSent() async throws {
        let sender = RecordingSender(queued: true)
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .queuedForSyncNode }

        XCTAssertEqual(coordinator.snackbarState, .queuedForSyncNode)
        XCTAssertFalse(coordinator.isSendPending)
        XCTAssertEqual(UndoSendSnackbar.queuedMessage, "Queued for Sync Node")
    }

    @MainActor
    func testSecondScheduleDuringPendingCountdownPreservesOriginalDelivery() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let firstSnapshot = ComposerRestoreSnapshot.fixture(subject: "First message")
        let secondSnapshot = ComposerRestoreSnapshot.fixture(subject: "Second message")

        XCTAssertTrue(coordinator.schedule(draft: firstSnapshot.fixtureDraft, restoring: firstSnapshot))
        await waitUntilSleepIsPending(in: sleeper)
        XCTAssertFalse(coordinator.schedule(draft: secondSnapshot.fixtureDraft, restoring: secondSnapshot))

        guard case let .pending(snapshot, _) = coordinator.snackbarState else {
            return XCTFail("Expected the original pending undo-send snackbar.")
        }
        XCTAssertEqual(snapshot, firstSnapshot)

        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(sender.drafts, [firstSnapshot.fixtureDraft])
    }

    @MainActor
    func testUndoAtDeadlineDoesNotCancelPendingDelivery() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        let clock = ControllableClock(now: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let coordinator = UndoSendCoordinator(
            sender: sender,
            now: { clock.now },
            sleep: { duration in
                try await sleeper.sleep(duration)
            }
        )
        let snapshot = ComposerRestoreSnapshot.fixture()

        XCTAssertTrue(coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot))
        await waitUntilSleepIsPending(in: sleeper)
        clock.advance(by: 10)

        XCTAssertNil(coordinator.undoLatestSend())
        guard case .pending = coordinator.snackbarState else {
            return XCTFail("Expiry must leave the delivery task pending until it can begin delivery.")
        }

        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(sender.drafts, [snapshot.fixtureDraft])
    }

    @MainActor
    func testDeliveryInFlightIsNotUndoableAndKeepsTheSendGuardUntilItCompletes() async throws {
        let sender = BlockingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let firstSnapshot = ComposerRestoreSnapshot.fixture(subject: "First message")
        let secondSnapshot = ComposerRestoreSnapshot.fixture(subject: "Second message")

        XCTAssertTrue(coordinator.schedule(draft: firstSnapshot.fixtureDraft, restoring: firstSnapshot))
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await sender.waitUntilSendHasStarted()

        XCTAssertEqual(coordinator.snackbarState, .sending)
        XCTAssertFalse(coordinator.schedule(draft: secondSnapshot.fixtureDraft, restoring: secondSnapshot))
        XCTAssertNil(coordinator.undoLatestSend())
        let deliveredDrafts = await sender.drafts
        XCTAssertEqual(deliveredDrafts, [firstSnapshot.fixtureDraft])

        await sender.release()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(coordinator.snackbarState, .sent)

        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.snackbarState == nil }
        XCTAssertNil(coordinator.snackbarState)
    }

    @MainActor
    func testSentConfirmationDismissesAfterTenSeconds() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll() // delivery delay
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(coordinator.snackbarState, .sent)

        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll() // sent-confirmation delay
        await waitUntil { coordinator.snackbarState == nil }
        XCTAssertNil(coordinator.snackbarState)
    }

    @MainActor
    func testFailedDeliveryCanRestoreOriginalSnapshot() async throws {
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: FailingSender(), sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil {
            coordinator.snackbarState == .failed(snapshot: snapshot)
        }

        XCTAssertEqual(coordinator.snackbarState, .failed(snapshot: snapshot))
        XCTAssertEqual(coordinator.restoreFailedSend(), snapshot)
        XCTAssertNil(coordinator.snackbarState)
    }

    @MainActor
    func testFailedDeliveryIsReportedUntilRestoredOrDismissed() async throws {
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: FailingSender(), sleep: { duration in
            try await sleeper.sleep(duration)
        })
        let snapshot = ComposerRestoreSnapshot.fixture()
        XCTAssertFalse(coordinator.hasFailedSend)
        // Dismissing without a failure changes nothing.
        coordinator.dismissFailedSend()
        XCTAssertNil(coordinator.snackbarState)

        coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot)
        XCTAssertFalse(coordinator.hasFailedSend)
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await waitUntil { coordinator.hasFailedSend }
        XCTAssertFalse(coordinator.isSendPending)

        coordinator.dismissFailedSend()
        XCTAssertFalse(coordinator.hasFailedSend)
        XCTAssertNil(coordinator.snackbarState)
        XCTAssertNil(coordinator.restoreFailedSend())
    }

    @MainActor
    func testSendPendingPublisherCoversUndoWindowAndDeliveryUntilItSettles() async throws {
        let sender = BlockingSender()
        let sleeper = ControllableSleeper()
        let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
            try await sleeper.sleep(duration)
        })
        var published: [Bool] = []
        let observation = coordinator.sendPendingPublisher.sink { published.append($0) }
        defer { observation.cancel() }
        XCTAssertEqual(published, [false])

        let snapshot = ComposerRestoreSnapshot.fixture()
        XCTAssertTrue(coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot))
        XCTAssertEqual(published, [false, true])
        await waitUntilSleepIsPending(in: sleeper)
        await sleeper.resumeAll()
        await sender.waitUntilSendHasStarted()
        // `.sending` is still pending: the delivery must outlive its owner's teardown.
        XCTAssertEqual(published, [false, true])
        XCTAssertTrue(coordinator.isSendPending)

        await sender.release()
        await waitUntil { coordinator.snackbarState == .sent }
        XCTAssertEqual(published, [false, true, false])
        XCTAssertFalse(coordinator.isSendPending)

        XCTAssertTrue(coordinator.schedule(draft: snapshot.fixtureDraft, restoring: snapshot))
        XCTAssertNotNil(coordinator.undoLatestSend())
        XCTAssertEqual(published, [false, true, false, true, false])
    }

    @MainActor
    func testCoordinatorDeallocationCancelsPendingDelivery() async throws {
        let sender = RecordingSender()
        let sleeper = ControllableSleeper()
        weak var releasedCoordinator: UndoSendCoordinator?

        do {
            let coordinator = UndoSendCoordinator(sender: sender, sleep: { duration in
                try await sleeper.sleep(duration)
            })
            coordinator.schedule(
                draft: ComposerRestoreSnapshot.fixture().fixtureDraft,
                restoring: .fixture()
            )
            releasedCoordinator = coordinator
        }

        XCTAssertNil(releasedCoordinator)
        await sleeper.resumeAll()
        await Task.yield()
        XCTAssertTrue(sender.drafts.isEmpty)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not met.", file: file, line: line)
    }

    @MainActor
    private func waitUntilSleepIsPending(
        in sleeper: ControllableSleeper,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await sleeper.hasPendingSleep {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected a pending sleep.", file: file, line: line)
    }
}

private final class RecordingSender: DirectComposerSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDrafts: [Draft] = []
    private let queued: Bool

    init(queued: Bool = false) { self.queued = queued }

    var drafts: [Draft] { lock.withLock { storedDrafts } }

    func send(draft: Draft) async throws -> DirectComposerSendResult {
        lock.withLock { storedDrafts.append(draft) }
        return DirectComposerSendResult(messageID: "msg_undo_send", remoteSentCopyAppended: !queued, isQueuedForSyncNode: queued)
    }
}

private final class ControllableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        current = now
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(interval)
        }
    }
}

private struct FailingSender: DirectComposerSending {
    func send(draft: Draft) async throws -> DirectComposerSendResult {
        throw TestFailure.delivery
    }

    private enum TestFailure: Error {
        case delivery
    }
}

private struct UncertainSender: DirectComposerSending {
    func send(draft: Draft) async throws -> DirectComposerSendResult {
        throw DirectSendIntentError.alreadySubmitted(.uncertain)
    }
}

private actor BlockingSender: DirectComposerSending {
    private var storedDrafts: [Draft] = []
    private var sendStarted = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    var drafts: [Draft] {
        storedDrafts
    }

    func send(draft: Draft) async throws -> DirectComposerSendResult {
        storedDrafts.append(draft)
        sendStarted = true
        let waiting = startContinuations
        startContinuations.removeAll()
        waiting.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return DirectComposerSendResult(messageID: "msg_blocking_undo_send", remoteSentCopyAppended: true)
    }

    func waitUntilSendHasStarted() async {
        guard !sendStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        let waiting = releaseContinuations
        releaseContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor ControllableSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    var hasPendingSleep: Bool {
        !continuations.isEmpty
    }
}

private extension ComposerRestoreSnapshot {
    static func fixture(
        subject: String = "Undo send",
        attachments: [DraftAttachment] = []
    ) -> Self {
        Self(to: "alice@example.com", cc: "", bcc: "", subject: subject,
             bodyMarkdown: "Body", attachments: attachments, presentationMode: .newMessage,
             replyContext: nil, includesQuotedHistory: true)
    }

    var fixtureDraft: Draft {
        Draft(id: DraftID("drf_undo_send"), accountID: AccountID("acc_test"),
              from: EmailAddress("me@example.com"), to: [EmailAddress("alice@example.com")],
              cc: [], bcc: [], subject: subject, bodyPlain: "Body", bodyMarkdown: "Body",
              createdBy: "test", aiGenerated: false, sourceThreadID: nil, attachments: attachments)
    }
}
