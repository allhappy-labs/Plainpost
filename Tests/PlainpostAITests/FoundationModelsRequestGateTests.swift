import XCTest
@testable import PlainpostAI

final class FoundationModelsRequestGateTests: XCTestCase {
    func testCancelledWaiterIsRemovedAndNextWaiterCanAcquire() async throws {
        let gate = FoundationModelsRequestGate()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        try await waitUntil("cancelled waiter enqueues") {
            await gate.waitingCount == 1
        }
        cancelled.cancel()
        do {
            try await awaitTask(cancelled, named: "cancelled waiter")
            XCTFail("Cancelled waiter acquired the gate")
        } catch is CancellationError {}
        let waitingAfterCancellation = await gate.waitingCount
        XCTAssertEqual(waitingAfterCancellation, 0)

        let next = Task { try await gate.acquire() }
        try await waitUntil("next waiter enqueues") {
            await gate.waitingCount == 1
        }
        await gate.release()
        try await awaitTask(next, named: "next waiter")
        await gate.release()
        try await assertGateIsReusable(gate, named: "queued cancellation gate")
    }

    func testWaitersAcquireInFIFOOrder() async throws {
        let gate = FoundationModelsRequestGate()
        let recorder = GateOrderRecorder()
        try await gate.acquire()
        let first = Task {
            try await gate.acquire()
            await recorder.append(1)
            await gate.release()
        }
        try await waitUntil("first FIFO waiter enqueues") {
            await gate.waitingCount == 1
        }
        let second = Task {
            try await gate.acquire()
            await recorder.append(2)
            await gate.release()
        }
        try await waitUntil("second FIFO waiter enqueues") {
            await gate.waitingCount == 2
        }
        await gate.release()
        try await awaitTask(first, named: "first FIFO waiter")
        try await awaitTask(second, named: "second FIFO waiter")
        let values = await recorder.values
        XCTAssertEqual(values, [1, 2])
    }

    func testQueuedContenderCancellationRaceHandsOffWithoutOverlappingOwners() async throws {
        let gate = FoundationModelsRequestGate()
        let contenderHold = CancellableGateTestSuspension()
        let successorHold = CancellableGateTestSuspension()
        let probeAdmission = CancellableGateTestSuspension()
        let probeAcquired = GateTestSignal()
        let ownership = GateOwnershipRecorder()
        try await gate.acquire()

        let contender = Task {
            try await gate.acquire()
            await ownership.enter("contender")
            do {
                try await contenderHold.wait()
                await ownership.leave("contender")
                await gate.release()
            } catch {
                await ownership.leave("contender")
                await gate.release()
                throw error
            }
        }
        try await waitUntil("contender enqueues") {
            await gate.waitingCount == 1
        }
        let successor = Task {
            try await gate.acquire()
            await ownership.enter("successor")
            do {
                try await successorHold.wait()
                await ownership.leave("successor")
                await gate.release()
            } catch {
                await ownership.leave("successor")
                await gate.release()
                throw error
            }
        }
        try await waitUntil("successor enqueues behind contender") {
            await gate.waitingCount == 2
        }
        let probe = Task {
            try await gate.acquire()
            await probeAcquired.signal()
            try await probeAdmission.wait()
            await ownership.enter("probe")
            await ownership.leave("probe")
            await gate.release()
        }
        try await waitUntil("probe enqueues behind successor") {
            await gate.waitingCount == 3
        }
        defer {
            contender.cancel()
            successor.cancel()
            probe.cancel()
            Task {
                await contenderHold.cancel()
                await successorHold.cancel()
                await probeAdmission.cancel()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { contender.cancel() }
            group.addTask { await gate.release() }
        }

        do {
            try await awaitTask(contender, named: "racing contender")
            XCTFail("Cancelled contender completed normally")
        } catch is CancellationError {}
        try await waitUntil("successor owns gate after contender race") {
            await ownership.hasOnlyActiveOwner("successor")
        }
        try await waitUntil("racing successor hold is armed") {
            await successorHold.isWaiting
        }
        let queuedProbeCount = await gate.waitingCount
        XCTAssertEqual(queuedProbeCount, 1)

        let probeWasPrematurelyGranted = await probeAcquired.isSignalled
        XCTAssertFalse(probeWasPrematurelyGranted)
        await probeAdmission.resume()
        if probeWasPrematurelyGranted {
            try await waitUntil("premature probe overlaps successor") {
                await ownership.hasConcurrentOwners
            }
        }
        await successorHold.resume()
        try await awaitTask(successor, named: "racing successor")
        try await awaitTask(probe, named: "racing probe")

        let state = await ownership.state
        XCTAssertEqual(state.maxConcurrentOwners, 1)
        XCTAssertEqual(state.activeOwners, [])
        XCTAssertTrue(
            [Set(["successor", "probe"]), Set(["contender", "successor", "probe"])]
                .contains(state.completedOwners)
        )
        try await assertGateIsReusable(gate, named: "contender cancellation race gate")
    }

    func testSuspensionConsumesEarlyResumeAndCancel() async throws {
        let resumed = CancellableGateTestSuspension()
        await resumed.resume()
        let resumedWaiter = Task { try await resumed.wait() }
        try await awaitTask(resumedWaiter, named: "early resumed suspension")

        let cancelled = CancellableGateTestSuspension()
        await cancelled.cancel()
        let cancelledWaiter = Task { try await cancelled.wait() }
        do {
            try await awaitTask(cancelledWaiter, named: "early cancelled suspension")
            XCTFail("Early cancellation was not delivered to the later waiter")
        } catch is CancellationError {}
    }

    func testCancelledSharedWrapperHandoffKeepsSuccessorAndProbeExclusive() async throws {
        let operationStarted = GateTestSignal()
        let operationSuspension = CancellableGateTestSuspension()
        let successorHold = CancellableGateTestSuspension()
        let ownership = GateOwnershipRecorder()
        let request = Task {
            try await withFoundationModelsRequest {
                await operationStarted.signal()
                try await operationSuspension.wait()
            }
        }
        defer {
            request.cancel()
            Task {
                await operationSuspension.cancel()
                await successorHold.cancel()
            }
        }

        try await waitUntil("shared wrapper operation starts") {
            await operationStarted.isSignalled
        }
        let successor = Task {
            try await FoundationModelsRequestGate.shared.acquire()
            await ownership.enter("successor")
            try await successorHold.wait()
            await ownership.leave("successor")
            await FoundationModelsRequestGate.shared.release()
        }
        try await waitUntil("successor enqueues") {
            await FoundationModelsRequestGate.shared.waitingCount == 1
        }
        let probe = Task {
            try await FoundationModelsRequestGate.shared.acquire()
            await ownership.enter("probe")
            await ownership.leave("probe")
            await FoundationModelsRequestGate.shared.release()
        }
        try await waitUntil("probe enqueues behind successor") {
            await FoundationModelsRequestGate.shared.waitingCount == 2
        }

        request.cancel()
        do {
            try await awaitTask(request, named: "cancelled shared wrapper")
            XCTFail("Cancelled wrapper completed its suspended operation")
        } catch is CancellationError {}
        try await waitUntil("successor owns shared gate") {
            await ownership.hasOnlyActiveOwner("successor")
        }
        try await waitUntil("shared-gate successor hold is armed") {
            await successorHold.isWaiting
        }
        let queuedProbeCount = await FoundationModelsRequestGate.shared.waitingCount
        let handoffState = await ownership.state
        XCTAssertEqual(queuedProbeCount, 1, "handoff ownership state: \(handoffState)")

        await successorHold.resume()
        try await awaitTask(successor, named: "shared-gate successor")
        try await awaitTask(probe, named: "shared-gate probe")

        let state = await ownership.state
        XCTAssertEqual(state.maxConcurrentOwners, 1)
        XCTAssertEqual(state.activeOwners, [])
        XCTAssertEqual(state.completedOwners, ["probe", "successor"])
        try await assertGateIsReusable(FoundationModelsRequestGate.shared, named: "shared wrapper gate")
    }
}

private actor GateOrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private struct GateTestTimeout: Error, CustomStringConvertible {
    let description: String
}

private actor GateTaskResult<Value: Sendable> {
    private var result: Result<Value, any Error>?

    func record(_ result: Result<Value, any Error>) {
        self.result = result
    }

    var isFinished: Bool { result != nil }

    func value() throws -> Value? {
        try result?.get()
    }
}

private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else {
            throw GateTestTimeout(description: "Timed out waiting for \(description)")
        }
        await Task.yield()
    }
}

private func awaitTask<Value: Sendable>(
    _ task: Task<Value, any Error>,
    named name: String,
    timeout: Duration = .seconds(2)
) async throws -> Value {
    let result = GateTaskResult<Value>()
    Task {
        await result.record(await task.result)
    }

    do {
        try await waitUntil("\(name) completes", timeout: timeout) {
            await result.isFinished
        }
    } catch {
        task.cancel()
        do {
            try await waitUntil("\(name) drains after cancellation", timeout: timeout) {
                await result.isFinished
            }
        } catch {
            throw GateTestTimeout(description: "Timed out waiting for \(name) to complete or drain after cancellation")
        }
        throw GateTestTimeout(description: "Timed out waiting for \(name) to complete")
    }

    guard let value = try await result.value() else {
        throw GateTestTimeout(description: "\(name) completed without a result")
    }
    return value
}

private func assertGateIsReusable(
    _ gate: FoundationModelsRequestGate,
    named name: String
) async throws {
    let probe = Task {
        try await gate.acquire()
        await gate.release()
    }
    try await awaitTask(probe, named: "\(name) reuse probe")
}

private actor GateTestSignal {
    private(set) var isSignalled = false

    func signal() {
        isSignalled = true
    }
}

private actor GateOwnershipRecorder {
    struct State: Equatable {
        let activeOwners: Set<String>
        let completedOwners: Set<String>
        let maxConcurrentOwners: Int
    }

    private var activeOwners: Set<String> = []
    private var completedOwners: Set<String> = []
    private var maxConcurrentOwners = 0

    func enter(_ owner: String) {
        activeOwners.insert(owner)
        maxConcurrentOwners = max(maxConcurrentOwners, activeOwners.count)
    }

    func leave(_ owner: String) {
        activeOwners.remove(owner)
        completedOwners.insert(owner)
    }

    func hasOnlyActiveOwner(_ owner: String) -> Bool {
        activeOwners == [owner]
    }

    var hasConcurrentOwners: Bool { maxConcurrentOwners > 1 }

    var state: State {
        State(
            activeOwners: activeOwners,
            completedOwners: completedOwners,
            maxConcurrentOwners: maxConcurrentOwners
        )
    }
}

private actor CancellableGateTestSuspension {
    private enum Outcome {
        case resume
        case cancel
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var pendingOutcome: Outcome?

    var isWaiting: Bool { continuation != nil }

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingOutcome {
                    self.pendingOutcome = nil
                    switch pendingOutcome {
                    case .resume:
                        continuation.resume()
                    case .cancel:
                        continuation.resume(throwing: CancellationError())
                    }
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        complete(.cancel)
    }

    func resume() {
        complete(.resume)
    }

    private func complete(_ outcome: Outcome) {
        guard let continuation else {
            if pendingOutcome == nil {
                pendingOutcome = outcome
            }
            return
        }

        self.continuation = nil
        switch outcome {
        case .resume:
            continuation.resume()
        case .cancel:
            continuation.resume(throwing: CancellationError())
        }
    }
}
