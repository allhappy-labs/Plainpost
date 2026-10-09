import XCTest
@testable import PlainpostUI

@MainActor
final class PlainpostRuntimePreparationFenceTests: XCTestCase {
    func testDelayedNonCooperativePreparationCannotPublishAfterNewerGeneration() async {
        let fence = PlainpostRuntimePreparationFence()
        let gate = PreparationGate()
        var published: [UInt64] = []

        let older = Task { @MainActor in
            let generation = fence.begin()
            await gate.wait()
            guard !Task.isCancelled, fence.isCurrent(generation) else { return }
            published.append(generation)
        }

        while await gate.waiterCount == 0 { await Task.yield() }
        let newerGeneration = fence.begin()
        await gate.release()
        await older.value

        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(fence.isCurrent(newerGeneration))
    }
}

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiterCount = 0

    func wait() async {
        waiterCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
