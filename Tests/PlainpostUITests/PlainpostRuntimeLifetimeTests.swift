import Combine
import XCTest
@testable import PlainpostUI

/// The runtime (and with it new-mail notification delivery) follows the
/// account session, not the mailbox window: it keeps running with no
/// windows and starts on a hidden login launch.
@MainActor
final class PlainpostRuntimeLifetimeTests: XCTestCase {
    func testDemandFollowsThePresentation() {
        XCTAssertEqual(PlainpostRuntimeLifetime.demand(for: .active), .running(readOnly: false))
        XCTAssertEqual(
            PlainpostRuntimeLifetime.demand(for: .offlineLease(expiresAt: Date(timeIntervalSince1970: 1))),
            .running(readOnly: true)
        )
        for presentation: AccountSessionViewModel.Presentation? in [
            nil, .signInRequired, .pendingApproval(matchingCode: nil), .suspended,
            .cleanupRequired, .deleted, .recoveryRequired,
        ] {
            XCTAssertEqual(PlainpostRuntimeLifetime.demand(for: presentation), .stopped, "\(String(describing: presentation))")
        }
    }

    func testActiveSessionStartsOnceWithoutAnyWindow() async {
        let harness = LifetimeHarness()
        harness.lifetime.apply(.signInRequired)
        harness.lifetime.apply(.active)
        harness.lifetime.apply(.active)
        await harness.lifetime.waitUntilIdle()

        XCTAssertEqual(harness.events, ["start:readWrite"])
    }

    func testInitialNonMailboxPresentationNeverShutsDown() async {
        // Shutting down locks the vault; nothing ran yet, so nothing stops.
        let harness = LifetimeHarness()
        harness.lifetime.apply(.signInRequired)
        harness.lifetime.apply(nil)
        await harness.lifetime.waitUntilIdle()

        XCTAssertEqual(harness.events, [])
    }

    func testLeavingTheMailboxStopsAndOfflineLeaseRunsReadOnly() async {
        let harness = LifetimeHarness()
        harness.lifetime.apply(.active)
        await harness.lifetime.waitUntilIdle()
        harness.lifetime.apply(.offlineLease(expiresAt: Date(timeIntervalSince1970: 1)))
        await harness.lifetime.waitUntilIdle()
        harness.lifetime.apply(.suspended)
        await harness.lifetime.waitUntilIdle()
        harness.lifetime.apply(nil)
        await harness.lifetime.waitUntilIdle()

        XCTAssertEqual(harness.events, ["start:readWrite", "start:readOnly", "stop"])
    }

    func testStartWaitsForAnInFlightStop() async {
        // PlainpostApplicationModel drops a start issued while its shutdown
        // is still running, so the lifetime must order them.
        let harness = LifetimeHarness(holdsStop: true)
        harness.lifetime.apply(.active)
        await harness.lifetime.waitUntilIdle()
        harness.lifetime.apply(.suspended)
        await harness.stopEntered()
        harness.lifetime.apply(.active)
        await Task.yield()
        XCTAssertEqual(harness.events, ["start:readWrite", "stop"])

        harness.releaseStop()
        await harness.lifetime.waitUntilIdle()
        XCTAssertEqual(harness.events, ["start:readWrite", "stop", "stop-finished", "start:readWrite"])
    }

    func testObservesPublishedPresentations() async {
        let harness = LifetimeHarness()
        let subject = PassthroughSubject<AccountSessionViewModel.Presentation?, Never>()
        harness.lifetime.observe(subject.eraseToAnyPublisher())

        subject.send(.active)
        await harness.lifetime.waitUntilIdle()
        subject.send(nil)
        await harness.lifetime.waitUntilIdle()

        XCTAssertEqual(harness.events, ["start:readWrite", "stop"])
    }
}

@MainActor
private final class LifetimeHarness {
    var events: [String] = []
    private let holdsStop: Bool
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopEnteredContinuation: CheckedContinuation<Void, Never>?
    private var didEnterStop = false
    lazy var lifetime = PlainpostRuntimeLifetime(
        start: { [unowned self] readOnly in
            events.append(readOnly ? "start:readOnly" : "start:readWrite")
        },
        stop: { [unowned self] in
            events.append("stop")
            guard holdsStop else { return }
            didEnterStop = true
            stopEnteredContinuation?.resume()
            stopEnteredContinuation = nil
            await withCheckedContinuation { stopContinuation = $0 }
            events.append("stop-finished")
        }
    )

    init(holdsStop: Bool = false) { self.holdsStop = holdsStop }

    func stopEntered() async {
        guard !didEnterStop else { return }
        await withCheckedContinuation { stopEnteredContinuation = $0 }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}
