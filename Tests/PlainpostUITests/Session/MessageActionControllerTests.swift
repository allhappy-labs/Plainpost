import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class MessageActionControllerTests: XCTestCase {
    private final class Recorder {
        var performed: [(InboxMailAction, String)] = []
        var outcome: InboxMailActionOutcome = .succeeded(.init(messageID: MessageID("x"), action: .archive))
        var failures: [String] = []
    }

    private func make(delay: Duration, recorder: Recorder, sleeper: ControlledSleeper? = nil)
        -> (MessageActionController, MailboxController, MailboxRefreshBus) {
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue,
            selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        let bus = MailboxRefreshBus()
        let controller = MessageActionController(
            mailbox: mailbox, refreshBus: bus, commitDelay: delay,
            perform: { action, id in recorder.performed.append((action, id)); return recorder.outcome },
            reproject: {},
            reportFailure: { recorder.failures.append($0) },
            sleep: sleeper?.sleep ?? { @Sendable _ in }
        )
        sleeper?.controller = controller
        return (controller, mailbox, bus)
    }

    func testTheShownMailboxReachesTheBackend() async {
        var shown: [String?] = []
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        let controller = MessageActionController(
            mailbox: mailbox, refreshBus: MailboxRefreshBus(), commitDelay: .zero,
            performInMailbox: { action, id, mailboxPath in
                shown.append(mailboxPath)
                return .succeeded(.init(messageID: MessageID(id), action: action))
            },
            reproject: {}, reportFailure: { _ in }
        )

        _ = await controller.performReturningOutcome(.delete, messageID: "m1", shownIn: "Sent", origin: .mailbox)
        _ = await controller.performReturningOutcome(.archive, messageID: "m2", origin: .mailbox)

        XCTAssertEqual(shown, ["Sent", nil])
    }

    /// A list action in an open account folder acts on that folder's copy of the message.
    func testAnOpenFolderIsTheShownMailboxForListActions() async {
        var shown: [String?] = []
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        mailbox.openFolder(MailFolderRef(accountID: AccountID("work"), path: "Sent", name: "Sent", role: .sent))
        let controller = MessageActionController(
            mailbox: mailbox, refreshBus: MailboxRefreshBus(), commitDelay: .zero,
            performInMailbox: { action, id, mailboxPath in
                shown.append(mailboxPath)
                return .succeeded(.init(messageID: MessageID(id), action: action))
            },
            reproject: {}, reportFailure: { _ in }
        )
        _ = await controller.performReturningOutcome(.delete, messageID: "m1", origin: .mailbox)
        _ = await controller.performReturningOutcome(.archive, messageID: "m2", origin: .askMailBatch)
        XCTAssertEqual(shown, ["Sent", nil])
    }

    func testZeroDelayCommitsImmediatelyLikeToday() async {
        let recorder = Recorder()
        let (controller, _, bus) = make(delay: .zero, recorder: recorder)
        let ok = await controller.performReturningOutcome(.archive, messageID: "m1", origin: .mailbox)
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.performed.map(\.1), ["m1"])
        XCTAssertNil(controller.pendingUndo)
        XCTAssertEqual(bus.revision, 1)
    }

    func testGraceArchiveHidesRowAndPublishesUndoBeforeCommitting() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        XCTAssertEqual(controller.overlayState.overlays["m1"]?.action, .archive)
        XCTAssertEqual(controller.pendingUndo?.messageID, "m1")
        XCTAssertTrue(recorder.performed.isEmpty, "nothing reaches the backend during the grace period")
        await sleeper.release()
        XCTAssertEqual(recorder.performed.map(\.1), ["m1"])
        XCTAssertNil(controller.pendingUndo)
    }

    func testUndoDuringGraceRestoresRowAndNavigationWithoutBackendCall() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, mailbox, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        mailbox.openMessage("m1", from: .mailbox(destination: .allInboxes, mode: .focusedList))
        controller.perform(.archive, messageID: "m1")
        XCTAssertEqual(mailbox.mailboxNavigation.route, .list(.mailbox(destination: .allInboxes, mode: .focusedList)))
        controller.undo()
        XCTAssertNil(controller.overlayState.overlays["m1"])
        XCTAssertEqual(mailbox.selectedMessageID, "m1")
        await sleeper.release()
        XCTAssertTrue(recorder.performed.isEmpty)
    }

    func testUndoAfterCommitIsIgnored() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        await sleeper.release()
        controller.undo()
        XCTAssertEqual(recorder.performed.count, 1)
        XCTAssertEqual(controller.overlayState.overlays["m1"], nil, "committed row stays gone after refresh")
    }

    func testCommitPendingNowSkipsTheRestOfTheWait() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.delete, messageID: "m1")
        controller.commitPendingNow()
        await sleeper.release()
        XCTAssertEqual(recorder.performed.map(\.0), [.delete])
    }

    func testCommitPendingNowWakesAnInFlightSleep() async throws {
        let recorder = Recorder()
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue,
            selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        let controller = MessageActionController(
            mailbox: mailbox, refreshBus: MailboxRefreshBus(), commitDelay: .seconds(600),
            perform: { action, id in recorder.performed.append((action, id)); return recorder.outcome },
            reproject: {},
            reportFailure: { _ in }
        )
        controller.perform(.archive, messageID: "m1")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(recorder.performed.isEmpty, "the real sleep is still waiting")
        controller.commitPendingNow()
        let deadline = ContinuousClock.now + .seconds(5)
        while recorder.performed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recorder.performed.map(\.1), ["m1"])
        XCTAssertNil(controller.pendingUndo)
    }

    func testNewerActionOnSameRowSupersedesPendingGraceAction() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        _ = await controller.performReturningOutcome(.markRead, messageID: "m1", origin: .askMailBatch)
        await sleeper.release()
        XCTAssertEqual(recorder.performed.map(\.0), [.markRead], "the superseded archive never commits")
    }

    /// Through `perform`, as the rows and the conversation call it: a mark-read on a row whose
    /// archive is waiting ends that wait at once, so nothing stays pending for the rest of the
    /// window (a background commit or an account switch would wait on it).
    func testMarkReadOnARowWithAWaitingArchiveEndsItsWaitAtOnce() async throws {
        let recorder = Recorder()
        let (controller, _) = realSleepController(recorder)
        controller.perform(.archive, messageID: "m1")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(controller.hasPendingGraceActions)

        controller.perform(.markRead, messageID: "m1")
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.hasPendingGraceActions || recorder.performed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(controller.hasPendingGraceActions, "the superseded archive leaves no 600 s wait behind")
        XCTAssertEqual(recorder.performed.map(\.0), [.markRead], "the superseded archive never reaches the backend")
        XCTAssertNil(controller.pendingUndo)
    }

    func testAskMailBatchNeverWaits() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        let ok = await controller.performReturningOutcome(.archive, messageID: "m1", origin: .askMailBatch)
        await sleeper.release()
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.performed.count, 1)
    }

    func testFailureRollsBackAndReports() async {
        let recorder = Recorder()
        recorder.outcome = .failed(message: "IMAP refused")
        let (controller, _, _) = make(delay: .zero, recorder: recorder)
        let ok = await controller.performReturningOutcome(.archive, messageID: "m1", origin: .mailbox)
        XCTAssertFalse(ok)
        XCTAssertNil(controller.overlayState.overlays["m1"])
        XCTAssertEqual(recorder.failures, ["IMAP refused"])
    }

    func testDidCommitReportsOnlySuccessfulCommits() async {
        let recorder = Recorder()
        let (controller, _, _) = make(delay: .zero, recorder: recorder)
        var committed: [String] = []
        controller.didCommit = { id, action in committed.append("\(action):\(id)") }

        _ = await controller.performReturningOutcome(.archive, messageID: "m1", origin: .mailbox)
        _ = await controller.performReturningOutcome(.markRead, messageID: "m2", origin: .mailbox)
        recorder.outcome = .failed(message: "IMAP refused")
        _ = await controller.performReturningOutcome(.delete, messageID: "m3", origin: .mailbox)

        XCTAssertEqual(committed, ["archive:m1", "markRead:m2"], "a rollback never reports a commit")
        XCTAssertNil(controller.overlayState.overlays["m3"], "the rolled-back row comes back")
    }

    func testDidCommitIsNotCalledForAnUndoneGraceAction() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        var committed: [String] = []
        controller.didCommit = { id, _ in committed.append(id) }
        controller.perform(.archive, messageID: "m1")
        controller.undo()
        await sleeper.release()
        XCTAssertEqual(committed, [])
    }

    private func realSleepController(_ recorder: Recorder) -> (MessageActionController, MailboxController) {
        let mailbox = MailboxController(
            destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
            navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
        )
        let controller = MessageActionController(
            mailbox: mailbox, refreshBus: MailboxRefreshBus(), commitDelay: .seconds(600),
            perform: { action, id in recorder.performed.append((action, id)); return recorder.outcome },
            reproject: {}, reportFailure: { _ in }
        )
        return (controller, mailbox)
    }

    func testReArchiveAfterUndoCommitsOnce() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        controller.undo()
        controller.perform(.archive, messageID: "m1")
        XCTAssertEqual(controller.pendingUndo?.messageID, "m1")
        await sleeper.release()
        XCTAssertEqual(recorder.performed.map(\.1), ["m1"], "the undone archive never commits; the second commits once")
        XCTAssertNil(controller.pendingUndo)
    }

    func testNewerGraceActionOnTheSameRowReplacesTheUndo() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        controller.perform(.delete, messageID: "m1")
        XCTAssertEqual(controller.pendingUndo?.action, .delete)
        await sleeper.release()
        XCTAssertEqual(recorder.performed.map(\.0), [.delete])
    }

    func testAnotherActionOnTheRowClearsItsUndoAtOnce() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        controller.perform(.archive, messageID: "m1")
        controller.perform(.markRead, messageID: "m1")
        await sleeper.release()
        XCTAssertNil(controller.pendingUndo, "a superseded archive must not keep its Undo toast")
    }

    func testUndoDuringAnInFlightWaitEndsItWithoutABackendCall() async {
        let recorder = Recorder()
        let (controller, _) = realSleepController(recorder)
        controller.perform(.archive, messageID: "m1")
        for _ in 0..<5 { await Task.yield() }
        controller.undo()
        let started = ContinuousClock.now
        await controller.commitPendingAndWait()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "undo ends the 600 s wait at once")
        XCTAssertTrue(recorder.performed.isEmpty)
        XCTAssertNil(controller.overlayState.overlays["m1"])
    }

    func testUndoAfterTheUserNavigatedKeepsTheirPlace() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, mailbox, _) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        let list = MailboxListContext.mailbox(destination: .allInboxes, mode: .focusedList)
        mailbox.openMessage("m1", from: list)
        controller.perform(.archive, messageID: "m1")
        mailbox.openMessage("m2", from: list)
        controller.undo()
        XCTAssertNil(controller.overlayState.overlays["m1"], "the row comes back")
        XCTAssertEqual(mailbox.selectedMessageID, "m2", "Undo doesn't pull the user back to m1")
        await sleeper.release()
        XCTAssertTrue(recorder.performed.isEmpty)
    }

    func testCommitPendingAndWaitReturnsAfterTheBackendAnswers() async {
        let recorder = Recorder()
        let (controller, _) = realSleepController(recorder)
        controller.perform(.archive, messageID: "m1")
        XCTAssertTrue(controller.hasPendingGraceActions)
        await controller.commitPendingAndWait()
        XCTAssertEqual(recorder.performed.map(\.1), ["m1"])
        XCTAssertFalse(controller.hasPendingGraceActions)
        XCTAssertNil(controller.pendingUndo)
    }

    func testMarkAllReadIsOneBatchWithOneRefresh() async {
        let recorder = Recorder()
        let sleeper = ControlledSleeper()
        let (controller, _, bus) = make(delay: .seconds(4), recorder: recorder, sleeper: sleeper)
        let marked = await controller.markAllRead(["a", "b", "c"])
        await sleeper.release()
        XCTAssertEqual(marked, 3)
        XCTAssertEqual(recorder.performed.map(\.0), [.markRead, .markRead, .markRead])
        XCTAssertEqual(bus.revision, 1, "one refresh for the whole batch")
        XCTAssertNil(controller.pendingUndo, "mark read never waits for Undo")
    }
}

/// Holds every sleep until `release()`; lets tests act inside the grace window. Deterministic:
/// a sleep that starts after `release()` returns at once, and `release()` returns only once
/// every action the controller started has settled.
@MainActor
final class ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var isReleased = false
    /// The controller whose started actions `release()` waits for; `make` connects it.
    weak var controller: MessageActionController?
    /// Main-actor bound, so a sleep registers in the same queue the controller's tasks run on.
    var sleep: @Sendable (Duration) async throws -> Void {
        { @MainActor [self] _ in
            guard !isReleased else { return }
            try await withCheckedThrowingContinuation { self.continuations.append($0) }
        }
    }
    func release() async {
        isReleased = true
        let pending = continuations; continuations = []
        pending.forEach { $0.resume() }
        await controller?.waitForStartedActions()
    }
}
