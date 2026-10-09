import XCTest
@testable import PlainpostOperations
@testable import PlainpostUI

final class SmartInboxPowerGateTests: XCTestCase {
    func testLowPowerModeBlocksWorkAndReportsChanges() {
        let center = NotificationCenter()
        let lowPower = LockedFlag(true)
        let gate = SmartInboxPowerGate(
            isLowPowerModeEnabled: { lowPower.value }, notificationCenter: center, appliesLowPowerMode: true
        )
        XCTAssertFalse(gate.allowsWork)
        let changed = expectation(description: "change")
        gate.observe { allows in
            XCTAssertTrue(allows)
            changed.fulfill()
        }
        lowPower.value = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(gate.allowsWork)
    }

    func testLowPowerModeIsIgnoredWhereItDoesNotApply() {
        XCTAssertTrue(SmartInboxPowerGate(isLowPowerModeEnabled: { true }, appliesLowPowerMode: false).allowsWork)
    }

    // Turning Low Power Mode on pauses a running Re-sort All with the Low Power
    // reason, and turning it off lifts every Low Power pause.
    @MainActor
    func testLowPowerModePausesRunningReSortAndLiftsThePauseAfterwards() async {
        let center = NotificationCenter()
        let lowPower = LockedFlag(false)
        let gate = SmartInboxPowerGate(
            isLowPowerModeEnabled: { lowPower.value }, notificationCenter: center, appliesLowPowerMode: true
        )
        let jobs = RerunJobs(job(state: .running))
        let policy = jobs.policy()
        gate.observe { allowsWork in
            Task { @MainActor in policy.schedule(allowsWork: allowsWork) }
        }

        lowPower.value = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await waitUntil { jobs.paused == ["rerun-1"] }
        await policy.settle()
        XCTAssertEqual(jobs.paused, ["rerun-1"])
        XCTAssertEqual(jobs.liftCount, 0)

        jobs.current = job(state: .running, pauseRequested: true, pauseReason: "low-power")
        lowPower.value = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await waitUntil { jobs.liftCount == 1 }
        await policy.settle()
        XCTAssertEqual(jobs.liftCount, 1)
        XCTAssertEqual(jobs.paused, ["rerun-1"])
    }

    // A Re-sort the user already paused is not paused again for Low Power Mode.
    @MainActor
    func testLowPowerModeLeavesAUserPausedReSortAlone() async {
        let jobs = RerunJobs(job(state: .paused, pauseReason: "user-requested"))
        let policy = jobs.policy()

        policy.schedule(allowsWork: false)
        await policy.settle()

        XCTAssertTrue(jobs.paused.isEmpty)
    }

    // A Re-sort already paused by the system (mail sync or interactive AI) is moved to
    // the Low Power pause too, so the system can't resume it during Low Power Mode.
    @MainActor
    func testLowPowerModeAlsoPausesASystemPausedReSort() async {
        for reason in ["mail-sync", "mail-sync-failed", "interactive-ai"] {
            let jobs = RerunJobs(job(state: .paused, pauseReason: reason))
            let policy = jobs.policy()
            policy.schedule(allowsWork: false)
            await policy.settle()
            XCTAssertEqual(jobs.paused, ["rerun-1"], reason)
        }
    }

    // A failed lift is retried once after a short delay.
    @MainActor
    func testFailedLiftIsRetriedOnce() async {
        let jobs = RerunJobs(job(state: .paused, pauseReason: "low-power"))
        jobs.liftFailures = 1
        let policy = jobs.policy()
        policy.schedule(allowsWork: true)
        await policy.settle()
        XCTAssertEqual(jobs.liftCount, 2)

        let failing = RerunJobs(job(state: .paused, pauseReason: "low-power"))
        failing.liftFailures = 5
        let failingPolicy = failing.policy()
        failingPolicy.schedule(allowsWork: true)
        await failingPolicy.settle()
        XCTAssertEqual(failing.liftCount, 2, "only one retry")
    }

    // A launch outside Low Power Mode lifts a Low Power pause left by an earlier run.
    @MainActor
    func testLaunchOutsideLowPowerModeLiftsLeftoverPauses() async {
        let jobs = RerunJobs(job(state: .paused, pauseReason: "low-power"))
        let policy = jobs.policy()

        policy.schedule(allowsWork: true)
        await policy.settle()

        XCTAssertEqual(jobs.liftCount, 1)
        XCTAssertTrue(jobs.paused.isEmpty)
    }

    @MainActor
    func testLowPowerModeWithoutReSortPausesNothing() async {
        let jobs = RerunJobs(nil)
        let policy = jobs.policy()
        policy.schedule(allowsWork: false)
        await policy.settle()
        XCTAssertTrue(jobs.paused.isEmpty)
    }

    private func job(
        state: PlainpostOperationState, pauseRequested: Bool = false, pauseReason: String? = nil
    ) -> PlainpostDurableJob {
        PlainpostDurableJob(
            id: "rerun-1", kind: .aiOperation, payloadJSON: "{}", state: state,
            pauseRequested: pauseRequested, idempotencyKey: "rerun-1", pauseReason: pauseReason
        )
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class RerunJobs {
    var current: PlainpostDurableJob?
    var paused: [String] = []
    var liftCount = 0
    var liftFailures = 0

    init(_ job: PlainpostDurableJob?) { current = job }

    func policy() -> SmartInboxLowPowerRerunPolicy {
        SmartInboxLowPowerRerunPolicy(
            activeRerunJob: { [unowned self] in current },
            pause: { [unowned self] id in paused.append(id) },
            liftLowPowerPauses: { [unowned self] in
                liftCount += 1
                if liftFailures > 0 {
                    liftFailures -= 1
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            liftRetryDelay: .zero
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
