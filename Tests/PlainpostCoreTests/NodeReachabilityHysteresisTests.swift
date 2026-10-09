import XCTest
@testable import PlainpostCore

final class NodeReachabilityHysteresisTests: XCTestCase {
    func testFallbackRequiresSustainedFailureAndRecoveryRequiresSustainedHealth() {
        let start = ContinuousClock.now
        var hysteresis = NodeReachabilityHysteresis(policy: .production, mode: .node)
        XCTAssertNil(hysteresis.observe(healthy: false, at: start))
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(30)))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(35)))      // flap resets the window
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(40)))
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(84)))
        XCTAssertEqual(hysteresis.observe(healthy: false, at: start + .seconds(85)), .fallback)
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(90)))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(119)))
        XCTAssertEqual(hysteresis.observe(healthy: true, at: start + .seconds(120)), .node)
        XCTAssertEqual(NodeReachabilityPolicy.production.unhealthyWindow, .seconds(45))
    }

    func testProductionPolicyMatchesTheSpecRange() {
        let policy = NodeReachabilityPolicy.production
        XCTAssertEqual(policy.unhealthyWindow, .seconds(45))
        XCTAssertEqual(policy.healthyWindow, .seconds(30))
        XCTAssertEqual(policy.probeInterval, .seconds(10))
        XCTAssertEqual(policy.probeTimeout, .seconds(10))
        XCTAssertGreaterThanOrEqual(policy.unhealthyWindow, .seconds(30))
        XCTAssertLessThanOrEqual(policy.unhealthyWindow, .seconds(60))
    }

    func testAnUnhealthyObservationDuringRecoveryRestartsTheHealthyWindow() {
        let start = ContinuousClock.now
        var hysteresis = NodeReachabilityHysteresis(policy: .production, mode: .fallback)
        XCTAssertNil(hysteresis.observe(healthy: true, at: start))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(29)))
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(29.5)))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(30)))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(59)))
        XCTAssertEqual(hysteresis.observe(healthy: true, at: start + .seconds(60)), .node)
        XCTAssertEqual(hysteresis.mode, .node)
    }

    func testHealthBeforeFallbackNeverCountsTowardRecovery() {
        let start = ContinuousClock.now
        var hysteresis = NodeReachabilityHysteresis(policy: .production, mode: .node)
        XCTAssertNil(hysteresis.observe(healthy: true, at: start))
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(1)))
        XCTAssertEqual(hysteresis.observe(healthy: false, at: start + .seconds(46)), .fallback)
        // The first healthy probe after entry starts the window; nothing earlier counts.
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(47)))
        XCTAssertNil(hysteresis.observe(healthy: true, at: start + .seconds(76)))
        XCTAssertEqual(hysteresis.observe(healthy: true, at: start + .seconds(77)), .node)
    }

    func testAFlappingNodeIsHeldInFallbackLongerEachTime() {
        let start = ContinuousClock.now
        var hysteresis = NodeReachabilityHysteresis(policy: .production, mode: .node)
        var now = start
        // Flap 1: fallback, then back after the base 30 s window.
        XCTAssertNil(hysteresis.observe(healthy: false, at: now))
        now += .seconds(45)
        XCTAssertEqual(hysteresis.observe(healthy: false, at: now), .fallback)
        XCTAssertEqual(hysteresis.requiredHealthyWindow, .seconds(30))
        now += .seconds(1)
        XCTAssertNil(hysteresis.observe(healthy: true, at: now))
        now += .seconds(30)
        XCTAssertEqual(hysteresis.observe(healthy: true, at: now), .node)

        // Flap 2 soon after the reconnect: the dwell doubles.
        now += .seconds(1)
        XCTAssertNil(hysteresis.observe(healthy: false, at: now))
        now += .seconds(45)
        XCTAssertEqual(hysteresis.observe(healthy: false, at: now), .fallback)
        XCTAssertEqual(hysteresis.requiredHealthyWindow, .seconds(60))
        now += .seconds(1)
        XCTAssertNil(hysteresis.observe(healthy: true, at: now))
        now += .seconds(30)
        XCTAssertNil(hysteresis.observe(healthy: true, at: now), "a flapping Node is not trusted after 30 s")
        now += .seconds(30)
        XCTAssertEqual(hysteresis.observe(healthy: true, at: now), .node)

        // A fallback long after the last reconnect starts from the base window again.
        now += .seconds(3_600)
        XCTAssertNil(hysteresis.observe(healthy: false, at: now))
        now += .seconds(45)
        XCTAssertEqual(hysteresis.observe(healthy: false, at: now), .fallback)
        XCTAssertEqual(hysteresis.requiredHealthyWindow, .seconds(30))
    }

    func testTheFlapDwellIsCapped() {
        let policy = NodeReachabilityPolicy.production
        var hysteresis = NodeReachabilityHysteresis(policy: policy, mode: .node)
        var now = ContinuousClock.now
        for _ in 0..<12 {
            XCTAssertNil(hysteresis.observe(healthy: false, at: now))
            now += policy.unhealthyWindow
            XCTAssertEqual(hysteresis.observe(healthy: false, at: now), .fallback)
            XCTAssertLessThanOrEqual(hysteresis.requiredHealthyWindow, policy.maximumHealthyWindow)
            now += .seconds(1)
            XCTAssertNil(hysteresis.observe(healthy: true, at: now))
            now += hysteresis.requiredHealthyWindow
            XCTAssertEqual(hysteresis.observe(healthy: true, at: now), .node)
            now += .seconds(1)
        }
        XCTAssertEqual(hysteresis.requiredHealthyWindow, policy.maximumHealthyWindow)
    }

    func testRestartingInFallbackStaysInFallbackUntilSustainedHealth() {
        let start = ContinuousClock.now
        var hysteresis = NodeReachabilityHysteresis(policy: .production, mode: .fallback)
        XCTAssertEqual(hysteresis.mode, .fallback)
        XCTAssertNil(hysteresis.observe(healthy: false, at: start))
        XCTAssertNil(hysteresis.observe(healthy: false, at: start + .seconds(600)))
        XCTAssertEqual(hysteresis.mode, .fallback)
    }
}
