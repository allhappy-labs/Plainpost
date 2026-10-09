import XCTest
@testable import PlainpostCore
@testable import PlainpostUI

@MainActor
final class AskMailActionCoordinatorTests: XCTestCase {
    private func markReadSection(_ ids: [String] = ["a"]) -> [(id: String, noun: String, messageIDs: [MessageID], total: Int)] {
        [(id: "n", noun: "notifications", messageIDs: ids.map { MessageID($0) }, total: ids.count)]
    }

    func testWithoutUndoTheGraceWindowEndsInPerform() async {
        let grace = ReleasableSleep()
        let recorder = Recorder()
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in try await grace.sleep() },
            perform: { _, id in await recorder.append(id); return true })
        coordinator.apply(.markRead, blockID: "b", sections: markReadSection())
        await grace.entered.wait()
        grace.release()
        await coordinator.waitForIdle()
        let performed = await recorder.ids
        XCTAssertEqual(performed, [MessageID("a")], "control: the same setup performs when nobody taps Undo")
        XCTAssertEqual(grace.outcome, .released)
    }

    func testUndoInsideGraceWindowPerformsNothing() async {
        let grace = ReleasableSleep()
        let recorder = Recorder()
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in try await grace.sleep() },
            perform: { _, id in await recorder.append(id); return true })
        coordinator.apply(.markRead, blockID: "b", sections: markReadSection())
        XCTAssertEqual(coordinator.receipts["b/n"]?.text, "Marked 1 notification read")
        XCTAssertEqual(coordinator.receipts["b/n"]?.canUndo, true)
        await grace.entered.wait()

        coordinator.undo(blockID: "b", sectionID: "n")
        await grace.exited.wait()
        grace.release()

        // Undo cancelled the grace sleep itself, so the commit task ended on its cancellation path.
        XCTAssertEqual(grace.outcome, .cancelled)
        let performed = await recorder.ids
        XCTAssertEqual(performed, [])
        XCTAssertNil(coordinator.receipts["b/n"])
    }

    func testBatchSettledFiresOncePerCommittedSectionAndNotForUndone() async {
        let sleeps = FirstSleepWaitsForCancellation()
        let recorder = Recorder()
        var settled = 0
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in try await sleeps.sleep() },
            perform: { _, id in await recorder.append(id); return id != MessageID("gone") },
            onBatchSettled: { settled += 1 })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "u", noun: "notifications",
            messageIDs: [MessageID("undone")], total: 1)])
        coordinator.undo(blockID: "b", sectionID: "u")
        coordinator.apply(.archive, blockID: "b", sections: [(id: "l", noun: "newsletters",
            messageIDs: [MessageID("a"), MessageID("gone"), MessageID("c")], total: 3)])
        await coordinator.waitForIdle()

        XCTAssertEqual(settled, 1)
        let ids = await recorder.ids
        XCTAssertEqual(ids, [MessageID("a"), MessageID("gone"), MessageID("c")])
        XCTAssertEqual(coordinator.receipts["b/l"]?.text, "Archived 2 of 3 newsletters · 1 failed")
    }

    func testCommitSkipsFailedMessagesAndReportsAppliedCount() async {
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in },
            perform: { _, id in id != MessageID("gone") })
        coordinator.apply(.archive, blockID: "b", sections: [(id: "l", noun: "newsletters",
            messageIDs: [MessageID("a"), MessageID("gone"), MessageID("c")], total: 3)])
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.receipts["b/l"]?.phase, .done(applied: 2))
        XCTAssertEqual(coordinator.receipts["b/l"]?.text, "Archived 2 of 3 newsletters · 1 failed")
        XCTAssertEqual(coordinator.receipts["b/l"]?.canUndo, false)
    }

    func testPendingActionSurvivesReset() async {
        let counter = Counter()
        let coordinator = AskMailActionCoordinator(sleep: { _ in }, perform: { _, _ in await counter.increment(); return true })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("a")], total: 1)])
        coordinator.reset()
        await coordinator.waitForIdle()
        let performed = await counter.value
        XCTAssertEqual(performed, 1)
    }

    func testResetDropsFinishedReceipts() async {
        let coordinator = AskMailActionCoordinator(sleep: { _ in }, perform: { _, _ in true })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("a")], total: 1)])
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .done(applied: 1))
        coordinator.reset()
        XCTAssertNil(coordinator.receipts["b/n"])
    }

    func testMarkUnreadText() {
        let coordinator = AskMailActionCoordinator(sleep: { _ in try await Task.sleep(for: .seconds(60)) }, perform: { _, _ in true })
        coordinator.apply(.markUnread, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("a")], total: 1)])
        XCTAssertEqual(coordinator.receipts["b/n"]?.text, "Marked 1 notification unread")
        coordinator.undo(blockID: "b", sectionID: "n")
    }

    func testSingularNounOnlyForExactlyOne() {
        XCTAssertEqual(AskMailActionCoordinator.noun("notifications", count: 1), "notification")
        XCTAssertEqual(AskMailActionCoordinator.noun("newsletters", count: 1), "newsletter")
        XCTAssertEqual(AskMailActionCoordinator.noun("receipts", count: 1), "receipt")
        XCTAssertEqual(AskMailActionCoordinator.noun("messages", count: 1), "message")
        XCTAssertEqual(AskMailActionCoordinator.noun("invitations", count: 1), "invitation")
        XCTAssertEqual(AskMailActionCoordinator.noun("from people", count: 1), "from people")
        XCTAssertEqual(AskMailActionCoordinator.noun("notifications", count: 2), "notifications")
        XCTAssertEqual(AskMailActionCoordinator.noun("notifications", count: 0), "notifications")
    }

    func testPartialSelectionText() {
        let coordinator = AskMailActionCoordinator(sleep: { _ in try await Task.sleep(for: .seconds(60)) }, perform: { _, _ in true })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications",
            messageIDs: (0..<20).map { MessageID("m\($0)") }, total: 21)])
        XCTAssertEqual(coordinator.receipts["b/n"]?.text, "Marked 20 of 21 notifications read")
        // Stop the still-pending 60s sleep from leaking past the test: cancel via undo.
        coordinator.undo(blockID: "b", sectionID: "n")
    }

    func testReapplyWhilePendingReplacesPriorAction() async {
        let recorder = Recorder()
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in },
            perform: { _, id in await recorder.append(id); return true })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("a")], total: 1)])
        let succeeded = coordinator.apply(.archive, blockID: "b", sections: [(id: "n", noun: "newsletters", messageIDs: [MessageID("z")], total: 1)])
        XCTAssertTrue(succeeded)
        await coordinator.waitForIdle()
        let ids = await recorder.ids
        XCTAssertEqual(ids, [MessageID("z")])
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .done(applied: 1))
        XCTAssertEqual(coordinator.receipts["b/n"]?.text, "Archived 1 newsletter")
    }

    func testReapplyWhileApplyingIsRefused() async {
        let gate = PerformGate()
        let recorder = Recorder()
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in },
            perform: { _, id in
                if id == MessageID("a") { await gate.pass() }
                await recorder.append(id)
                return true
            })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications",
            messageIDs: [MessageID("a"), MessageID("b")], total: 2)])
        await gate.entered.wait()
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .applying)

        let succeeded = coordinator.apply(.archive, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("z")], total: 1)])
        XCTAssertFalse(succeeded)

        gate.release()
        await coordinator.waitForIdle()
        let ids = await recorder.ids
        XCTAssertEqual(ids, [MessageID("a"), MessageID("b")])
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .done(applied: 2))
        XCTAssertEqual(coordinator.receipts["b/n"]?.text, "Marked 2 notifications read")
    }

    func testUndoIsNoOpOnceApplying() async {
        let gate = PerformGate()
        let recorder = Recorder()
        let coordinator = AskMailActionCoordinator(
            sleep: { _ in },
            perform: { _, id in
                await gate.pass()
                await recorder.append(id)
                return true
            })
        coordinator.apply(.markRead, blockID: "b", sections: [(id: "n", noun: "notifications", messageIDs: [MessageID("a")], total: 1)])
        await gate.entered.wait()
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .applying)
        XCTAssertEqual(coordinator.receipts["b/n"]?.canUndo, false)

        coordinator.undo(blockID: "b", sectionID: "n")
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .applying)

        gate.release()
        await coordinator.waitForIdle()
        let ids = await recorder.ids
        XCTAssertEqual(ids, [MessageID("a")])
        XCTAssertEqual(coordinator.receipts["b/n"]?.phase, .done(applied: 1))
    }
}

/// Swift 6 strict concurrency: a `var` local captured by an `@Sendable` closure across
/// suspension points is not permitted, so tests use a small actor instead of a mutable local.
private actor Recorder {
    var ids: [MessageID] = []
    func append(_ id: MessageID) { ids.append(id) }
}

/// The first grace sleep lasts until its task is cancelled (the undone action); later ones end at once.
private final class FirstSleepWaitsForCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func sleep() async throws {
        let isFirst = lock.withLock { calls += 1; return calls == 1 }
        if isFirst { try await Task.sleep(for: .seconds(3600)) }
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

/// A one-shot signal: `wait()` suspends until `open()`; once open, waiting returns at once.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let openAlready = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if openAlready { continuation.resume() }
        }
    }
}

/// A grace-window sleep the test ends explicitly. It signals `entered` when the coordinator starts
/// waiting, honours task cancellation (Undo), and signals `exited` however it ends.
private final class ReleasableSleep: @unchecked Sendable {
    enum Outcome: Equatable { case pending, released, cancelled }
    let entered = Latch()
    let exited = Latch()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished: Outcome = .pending
    var outcome: Outcome { lock.withLock { finished } }

    func sleep() async throws {
        defer { exited.open() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early: Outcome = lock.withLock {
                    if finished == .pending { self.continuation = continuation }
                    return finished
                }
                switch early {
                case .pending: entered.open()
                case .released: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            finish(.cancelled)
        }
    }

    func release() { finish(.released) }

    private func finish(_ outcome: Outcome) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard finished == .pending else { return nil }
            finished = outcome
            defer { continuation = nil }
            return continuation
        }
        guard let waiting else { return }
        if outcome == .cancelled { waiting.resume(throwing: CancellationError()) } else { waiting.resume() }
    }
}

/// Holds `perform` for one message: `entered` opens once it is running (so the section is
/// `.applying`), and `release()` lets it finish.
private final class PerformGate: @unchecked Sendable {
    let entered = Latch()
    private let released = Latch()
    func pass() async {
        entered.open()
        await released.wait()
    }
    func release() { released.open() }
}

