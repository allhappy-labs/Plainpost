import XCTest

/// Test-only explicit admission, cancellation and release barriers; no sleep-based ordering.
@MainActor
final class MailRefreshTestBarrier {
    let arrived = MailRefreshTestCounter()
    let departed = MailRefreshTestCounter()
    nonisolated let cancelled = XCTestExpectation(description: "admitted dependency cancelled")
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived.record()
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { waiters.append($0) } }
        } onCancel: {
            self.cancelled.fulfill()
        }
        departed.record()
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class MailRefreshTestCounter {
    private(set) var count = 0
    private var waiters: [(Int, XCTestExpectation)] = []

    func record() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.fulfill() }
    }

    func wait(for count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        guard self.count < count else { return }
        let ready = XCTestExpectation(description: "counter reaches \(count)")
        waiters.append((count, ready))
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }
}
