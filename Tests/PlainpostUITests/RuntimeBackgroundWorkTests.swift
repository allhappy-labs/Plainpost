import XCTest
import Dispatch
@testable import PlainpostUI

final class RuntimeBackgroundWorkTests: XCTestCase {
    @MainActor
    func testShutdownJoinsAdmittedWork() async {
        let owner = RuntimeBackgroundWork()
        let gate = BackgroundWorkGate()
        addTeardownBlock { await gate.release() }

        owner.start { await gate.run() }
        guard await gate.waitUntilStarted() else {
            await gate.release()
            XCTFail("background work did not start")
            return
        }

        let shutdownCompletion = BackgroundWorkCompletion()
        Task { @MainActor in
            await owner.shutdown()
            await shutdownCompletion.markFinished()
        }
        guard await gate.waitUntilCancellationObserved() else {
            await gate.release()
            XCTFail("shutdown did not cancel admitted work")
            return
        }
        let completedBeforeRelease = await shutdownCompletion.isFinished()
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertEqual(owner.ownedTaskCount, 1)

        await gate.release()
        guard await shutdownCompletion.waitUntilFinished() else {
            await gate.release()
            XCTFail("shutdown did not finish after admitted work was released")
            return
        }
        guard await gate.waitUntilFinished() else {
            await gate.release()
            XCTFail("admitted work did not finish after release")
            return
        }
        XCTAssertEqual(owner.ownedTaskCount, 0)
    }

    @MainActor
    func testStartAfterShutdownDoesNotRun() async {
        let owner = RuntimeBackgroundWork()
        let gate = BackgroundWorkGate()
        addTeardownBlock { await gate.release() }

        await owner.shutdown()
        owner.start { await gate.run() }

        let startedCount = await gate.startedCount()
        XCTAssertEqual(startedCount, 0)
        XCTAssertEqual(owner.ownedTaskCount, 0)
    }

    @MainActor
    func testConcurrentShutdownWaitsForSameDrain() async {
        let owner = RuntimeBackgroundWork()
        let gate = BackgroundWorkGate()
        addTeardownBlock { await gate.release() }
        owner.start { await gate.run() }
        guard await gate.waitUntilStarted() else {
            await gate.release()
            XCTFail("background work did not start")
            return
        }

        let firstDrain = owner.beginShutdown()
        let secondDrain = owner.beginShutdown()
        let firstCompletion = BackgroundWorkCompletion()
        let secondCompletion = BackgroundWorkCompletion()
        Task {
            await firstDrain.value
            await firstCompletion.markFinished()
        }
        Task {
            await secondDrain.value
            await secondCompletion.markFinished()
        }
        guard await gate.waitUntilCancellationObserved() else {
            await gate.release()
            XCTFail("shutdown did not cancel admitted work")
            return
        }

        let firstFinishedBeforeRelease = await firstCompletion.isFinished()
        let secondFinishedBeforeRelease = await secondCompletion.isFinished()
        XCTAssertFalse(firstFinishedBeforeRelease)
        XCTAssertFalse(secondFinishedBeforeRelease)
        XCTAssertEqual(owner.ownedTaskCount, 1)

        await gate.release()
        guard await firstCompletion.waitUntilFinished() else {
            await gate.release()
            XCTFail("first shutdown did not finish after admitted work was released")
            return
        }
        guard await secondCompletion.waitUntilFinished() else {
            await gate.release()
            XCTFail("second shutdown did not finish after admitted work was released")
            return
        }
        guard await gate.waitUntilFinished() else {
            await gate.release()
            XCTFail("admitted work did not finish after release")
            return
        }
        XCTAssertEqual(owner.ownedTaskCount, 0)
    }

    func testReleaseBeforeRunAndRepeatedReleaseAreIdempotent() async {
        let gate = BackgroundWorkGate()

        await gate.release()
        await gate.release()
        let runTask = Task { await gate.run() }
        addTeardownBlock {
            await gate.release()
            await runTask.value
        }

        let started = await gate.waitUntilStarted(timeout: .seconds(1))
        XCTAssertTrue(started)
        let finished = await gate.waitUntilFinished(timeout: .seconds(1))
        await gate.release()
        await runTask.value
        XCTAssertTrue(finished)
        await gate.release()
    }
}

private actor BackgroundWorkGate {
    private var startedCallCount = 0
    private var cancellationObserved = false
    private var finished = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var nextWaiterID = 0
    private var startedWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var cancellationWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var finishedWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    func run() async {
        startedCallCount += 1
        startedWaiters.values.forEach { $0.resume(returning: true) }
        startedWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        finished = true
        finishedWaiters.values.forEach { $0.resume(returning: true) }
        finishedWaiters.removeAll()
    }

    func waitUntilStarted(timeout: DispatchTimeInterval = .seconds(1)) async -> Bool {
        guard startedCallCount == 0 else { return true }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            startedWaiters[waiterID] = continuation
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                Task { await self.expireStartedWaiter(waiterID) }
            }
        }
    }

    func startedCount() -> Int { startedCallCount }

    func waitUntilCancellationObserved(timeout: DispatchTimeInterval = .seconds(1)) async -> Bool {
        guard !cancellationObserved else { return true }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            cancellationWaiters[waiterID] = continuation
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                Task { await self.expireCancellationWaiter(waiterID) }
            }
        }
    }

    func waitUntilFinished(timeout: DispatchTimeInterval = .seconds(1)) async -> Bool {
        guard !finished else { return true }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            finishedWaiters[waiterID] = continuation
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                Task { await self.expireFinishedWaiter(waiterID) }
            }
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func recordCancellation() {
        cancellationObserved = true
        cancellationWaiters.values.forEach { $0.resume(returning: true) }
        cancellationWaiters.removeAll()
    }

    private func expireStartedWaiter(_ waiterID: Int) {
        startedWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    private func expireCancellationWaiter(_ waiterID: Int) {
        cancellationWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    private func expireFinishedWaiter(_ waiterID: Int) {
        finishedWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}

private actor BackgroundWorkCompletion {
    private var finished = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    func markFinished() {
        finished = true
        waiters.values.forEach { $0.resume(returning: true) }
        waiters.removeAll()
    }

    func isFinished() -> Bool { finished }

    func waitUntilFinished(timeout: DispatchTimeInterval = .seconds(1)) async -> Bool {
        guard !finished else { return true }
        let waiterID = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                Task { await self.expireWaiter(waiterID) }
            }
        }
    }

    private func expireWaiter(_ waiterID: Int) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}
