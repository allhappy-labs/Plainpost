import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport
import PlainpostServiceIPC

final class NodeReachabilitySupervisorTests: XCTestCase {
    // MARK: - Plan test

    func testReconnectStopsDirectSyncBeforeMirrorAndSettlesThenDispatches() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.store.mailSource(accountID: harness.accountID).mode, .fallback)
        XCTAssertTrue(harness.store.runsDirectSync(accountID: harness.accountID))
        let fallbackStatus = await harness.supervisor.status
        XCTAssertEqual(fallbackStatus, .connectedDirectly)
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(harness.log.events, ["mode:fallback", "dispatchPending", "mode:node", "reroute", "settle", "dispatchPending", "mirrorPass"])
        XCTAssertFalse(harness.store.runsDirectSync(accountID: harness.accountID))
        let status = await harness.supervisor.status
        XCTAssertEqual(status, .connected)
    }

    // MARK: - Fallback entry and exit

    func testFallbackNeedsASustainedUnhealthyWindow() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(50))   // unhealthy since t=10: 40 s so far
        XCTAssertEqual(try harness.mode(), .node)
        XCTAssertEqual(harness.log.events, [])
        let reachable = await harness.supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.nodeID)
        XCTAssertNil(reachable, "an unhealthy Node hands out no client, so intents stay pending")
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(10))   // one healthy probe resets the window
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(50))   // unhealthy since t=70: 40 s
        XCTAssertEqual(try harness.mode(), .node)
        await harness.advance(by: .seconds(10))   // 50 s
        XCTAssertEqual(try harness.mode(), .fallback)
    }

    func testReconnectWaitsForTheDwellTimeAndAFlapRestartsIt() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        harness.log.clear()

        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(30))       // healthy at 70, 80, 90: 20 s
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(10))       // one unhealthy probe at 100
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(30))       // healthy at 110, 120, 130: 20 s
        XCTAssertEqual(try harness.mode(), .fallback, "a Node that flaps is not trusted before 30 s of unbroken health")
        XCTAssertEqual(harness.log.events, [])
        let reachable = await harness.supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.nodeID)
        XCTAssertNil(reachable, "no Node client while the accounts are in fallback")
        await harness.advance(by: .seconds(10))       // 140: 30 s
        XCTAssertEqual(try harness.mode(), .node)
        XCTAssertEqual(harness.log.events.last, "mirrorPass")
    }

    func testAFlappingNodeIsHeldInFallbackLongerOnItsNextFallback() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(), .node)
        // It fails again right away: the next return needs 60 s of health.
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(), .fallback)
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(try harness.mode(), .node)
    }

    func testASessionThatCannotBeOpenedCountsAsUnhealthy() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.sessionAvailable.value = false
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        harness.sessionAvailable.value = true
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(), .node)
    }

    func testANodeThatNeedsAnUpdateIsReportedAndFallsBack() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, start: false)
        defer { harness.cleanUp() }
        harness.node.setServesMailMode(false)
        await harness.start()
        let early = await harness.supervisor.status
        XCTAssertEqual(early, .updateRequired)
        await harness.advance(by: .seconds(50))
        XCTAssertEqual(try harness.mode(), .fallback)
        let status = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(status.state, .updateRequired)
        XCTAssertEqual(try status.dto().state, "update_required")
    }

    // MARK: - Unauthorized

    func testUnauthorizedInvalidatesTheSessionOnceAndReportsReconnectRequired() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.fail("/v1/status", with: .unauthorized, times: 6)
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(harness.invalidations.value, 1, "a persistent unauthorized answer invalidates the session once")
        let status = await harness.supervisor.status
        XCTAssertEqual(status, .reconnectRequired)
        let wire = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(wire.state, .reconnectRequired)
        XCTAssertEqual(try wire.dto().state, "reconnect_required")
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(try harness.mode(), .fallback, "unauthorized counts as unhealthy")
        let stillReconnect = await harness.supervisor.status
        XCTAssertEqual(stillReconnect, .reconnectRequired)
        XCTAssertEqual(harness.invalidations.value, 1)

        await harness.advance(by: .seconds(10))    // the failures are used up: healthy again
        let recovered = await harness.supervisor.status
        XCTAssertEqual(recovered, .connectedDirectly)
        harness.node.fail("/v1/status", with: .unauthorized, times: 1)
        await harness.advance(by: .seconds(10))
        XCTAssertEqual(harness.invalidations.value, 2, "a new unauthorized episode invalidates again")
    }

    // MARK: - Lifecycle

    func testStopCancelsProbesAndPendingMirrorWakes() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        harness.node.setHealthy(true)
        let settle = harness.routing.holdNextSettle()
        await harness.advance(by: .seconds(30))
        harness.clock.advance(by: .seconds(10))           // 100: the reconnect starts and holds in settle
        await harness.waitUntil { settle.hasArrived }
        let supervisor = harness.supervisor!
        let stopping = Task { await supervisor.stop() }
        try await Task.sleep(for: .milliseconds(20))
        settle.release()
        await stopping.value
        XCTAssertFalse(harness.log.events.contains("mirrorPass"), "a stopped supervisor never wakes the mirror")

        harness.node.clearRequests()
        harness.clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.node.count("GET /v1/status"), 0, "no probe after stop")
        let reachable = await supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.nodeID)
        XCTAssertNil(reachable)
    }

    func testStopCancelsAProbeInFlight() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let gate = harness.node.hold("/v1/status")
        harness.clock.advance(by: .seconds(10))
        await harness.waitUntil { gate.hasArrived }
        await harness.supervisor.stop()   // returns although the probe never answers
        gate.release()
    }

    func testARestartRestoresThePersistedMode() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, modes: [.fallback], start: false)
        defer { harness.cleanUp() }
        await harness.start()
        XCTAssertEqual(try harness.mode(), .fallback, "a healthy first probe does not end fallback at once")
        let status = await harness.supervisor.status
        XCTAssertEqual(status, .connectedDirectly)
        await harness.advance(by: .seconds(20))
        XCTAssertEqual(try harness.mode(), .fallback)
        await harness.restart()                        // the dwell starts again after a restart
        await harness.advance(by: .seconds(20))
        XCTAssertEqual(try harness.mode(), .fallback)
        await harness.advance(by: .seconds(10))
        XCTAssertEqual(try harness.mode(), .node)

        await harness.restart()
        harness.log.clear()
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(try harness.mode(), .node, "a persisted node mode resumes as node")
        XCTAssertEqual(harness.log.events, [])
    }

    // MARK: - Scope

    func testDirectAccountsAreNeverModified() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, modes: [.node, nil])
        defer { harness.cleanUp() }
        let directBefore = try harness.store.mailSource(accountID: harness.accountIDs[1])
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(0), .node)
        XCTAssertEqual(try harness.store.mailSource(accountID: harness.accountIDs[1]), directBefore)
        XCTAssertEqual(directBefore.kind, .direct)
        XCTAssertEqual(harness.log.events.filter { $0 == "dispatchPending" }.count, 2, "only the Node-backed account is drained")
    }

    func testNoNodeBackedAccountMeansNoNodeTraffic() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, modes: [nil])
        defer { harness.cleanUp() }
        await harness.advance(by: .seconds(120))
        XCTAssertEqual(harness.node.requests, [])
        let status = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(status, .noNode)
    }

    func testTheAccountsSignalIsPostedExactlyOncePerTransition() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(harness.accountSignals.value, 0, "healthy ticks post nothing")
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(harness.accountSignals.value, 1)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(harness.accountSignals.value, 1, "fallback ticks post nothing")
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(harness.accountSignals.value, 2)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(harness.accountSignals.value, 2)
    }

    func testProbesNeverOverlapAndAProbeThatNeverAnswersIsUnhealthy() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.clearRequests()
        let gate = harness.node.hold("/v1/status")
        harness.probeMayHang.value = true
        await harness.advance(by: .seconds(70))
        XCTAssertEqual(harness.node.count("GET /v1/status"), 1, "no probe starts while one is still running")
        XCTAssertEqual(try harness.mode(), .fallback, "timed-out probes count as unhealthy")
        gate.release()
        await harness.waitUntil { true }
        try await Task.sleep(for: .milliseconds(20))
        harness.probeMayHang.value = false
        await harness.advance(by: .seconds(20))
        XCTAssertGreaterThan(harness.node.count("GET /v1/status"), 1, "probing resumes once the stuck probe ends")
    }

    func testTheSupervisorNeverConstructsANodeMailMirror() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let made = ReachabilityCounter()
        let node = harness.node
        let store = harness.store
        let broker = NodeSessionBroker(resolveSender: { (NodeReachabilitySupervisorHarness.nodeID, node) })
        let loop = NodeMailMirrorLoop(store: store, broker: broker) { nodeID, client in
            made.increment()
            return NodeMailMirror(store: store, client: client, nodeID: nodeID)
        }
        // The production initializer: the real router and the real loop.
        let supervisor = NodeReachabilitySupervisor(
            store: store,
            sessionFactory: { (NodeReachabilitySupervisorHarness.nodeID, NodeSyncClient(sender: node)) },
            router: harness.router, mirrorLoop: loop,
            invalidateSession: {}, mayDispatch: { true }, clock: harness.clock
        )
        XCTAssertFalse(Mirror(reflecting: supervisor).children.contains { $0.value is NodeMailMirror })
        await harness.replaceSupervisor(with: supervisor)
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(), .node)
        await supervisor.stop()
        XCTAssertEqual(made.value, 0, "the loop owns the mirror; the supervisor only wakes it")
    }

    // MARK: - Dispatch

    func testFallbackDispatchesQueuedIntentsDirectlyOnlyWhileTheVaultIsOpen() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, vaultOpen: false)
        defer { harness.cleanUp() }
        let message = try harness.seedLocalMessage()
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(10))
        let queued = try await harness.router.performIntent(.markRead, messageID: message)
        XCTAssertEqual(queued.outcome, .waitingForNode)
        await harness.advance(by: .seconds(50))
        XCTAssertEqual(try harness.mode(), .fallback)
        XCTAssertFalse(harness.log.events.contains("dispatchPending"), "no dispatch while the vault is locked")
        XCTAssertEqual(harness.direct.performedActions, [])
        XCTAssertEqual(try harness.intent(queued.operationID).state, .pending)

        harness.vaultOpen.value = true
        await harness.advance(by: .seconds(10))
        XCTAssertEqual(harness.log.events.filter { $0 == "dispatchPending" }.count, 1)
        XCTAssertEqual(harness.direct.performedActions.map(\.kind), [.markRead])
        XCTAssertEqual(try harness.intent(queued.operationID).state, .confirmed)
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(harness.log.events.filter { $0 == "dispatchPending" }.count, 1, "nothing left to drain")
    }

    func testReconnectWithTheVaultLockedDefersDispatchToTheNextOpenTick() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, modes: [.fallback], vaultOpen: false)
        defer { harness.cleanUp() }
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(try harness.mode(), .node)
        XCTAssertEqual(harness.log.events, ["mode:node", "reroute", "mirrorPass"])
    }

    func testPendingRowsAreRedrainedOnTheNextTick() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let message = try await harness.seedMirroredMessage(nodeID: "n-redrain")
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(10))
        let queued = try await harness.router.performIntent(.archive, messageID: message)
        XCTAssertEqual(queued.outcome, .waitingForNode, "a briefly unhealthy Node keeps the change pending")
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(10))
        XCTAssertEqual(try harness.mode(), .node)
        XCTAssertEqual(harness.log.events, ["dispatchPending"])
        XCTAssertEqual(try harness.intent(queued.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.mutationCount, 1)
        XCTAssertEqual(harness.direct.performedActions, [])
    }

    func testFallbackWhileANodeSendIsDispatchingLeavesItUncertainUntilTheNodeSettlesIt() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let draft = try harness.makeDraft()
        let gate = harness.node.hold("/v1/mutations")
        let router = harness.router
        let sending = Task { try await router.sendIntent(draft) }
        await harness.waitUntil { gate.hasArrived }
        let inFlight = try XCTUnwrap(harness.store.mailIntents(accountID: harness.accountID, states: Set(MailIntentState.allCases)).first)
        XCTAssertEqual(inFlight.state, .dispatching)
        XCTAssertEqual(inFlight.route, .node)

        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
        XCTAssertEqual(harness.direct.sentDraftIDs, [], "an in-flight Node send is never sent directly")
        gate.release()
        let dispatch = try await sending.value
        XCTAssertEqual(dispatch.route, .node)
        let afterFallback = try harness.intent(dispatch.operationID)
        XCTAssertEqual(afterFallback.state, .uncertain)
        await harness.advance(by: .seconds(30))
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .uncertain)
        XCTAssertEqual(harness.direct.sentDraftIDs, [])

        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(), .node)
        XCTAssertEqual(try harness.intent(dispatch.operationID).state, .confirmed)
        XCTAssertEqual(harness.node.acceptedKinds.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(harness.direct.sentDraftIDs, [])
    }

    // MARK: - Status

    func testStatusUpdatesAndTheWireStatusFollowTransitions() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let updates = await harness.supervisor.statusUpdates()
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .connected)
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(10))   // the probe at 10 s sees it
        let message = try harness.seedLocalMessage()
        _ = try await harness.router.performIntent(.markRead, messageID: message)
        let waiting = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(waiting, PlainpostNodeMailModeStatus(state: .connected, nodeBackedAccountCount: 1, waitingIntentCount: 1))
        await harness.advance(by: .seconds(50))
        let second = await iterator.next()
        XCTAssertEqual(second, .connectedDirectly)
        let wire = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(wire.state, .connectedDirectly)
        XCTAssertEqual(wire.waitingIntentCount, 0, "the fallback drain sent it directly")
    }

    // MARK: - Fix round 1

    func testABrokerThatRefusesAdmissionReadsReconnectSyncNode() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.sessionError.value = NodeSessionBrokerError.notAdmitted
        await harness.advance(by: .seconds(30))
        let status = await harness.supervisor.status
        XCTAssertEqual(status, .reconnectRequired)
        XCTAssertEqual(harness.invalidations.value, 1)
        let wire = await harness.supervisor.mailModeStatus()
        XCTAssertEqual(wire.state, .reconnectRequired, "the app shows \"Reconnect Sync Node\"")
    }

    func testEachProbeIsScheduledFromThePreviousProbesStart() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.clearRequests()
        harness.probeMayHang.value = true
        harness.probeDelay.value = .seconds(8)
        await harness.advance(by: .seconds(60))
        // Probes start at 10, 20, …, 60 and answer 8 s later: 18 … 58.
        XCTAssertEqual(harness.node.count("GET /v1/status"), 5)
    }

    func testABusyLaneThatAnswersOtherRequestsKeepsTheNodeHealthy() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        harness.laneActivity.value = NodeLaneActivitySnapshot(sinceLastResponse: .seconds(2), laneHeldFor: nil)
        await harness.advance(by: .seconds(90))
        XCTAssertEqual(try harness.mode(), .node, "the lane answered within the interval: busy, not down")
        harness.laneActivity.value = nil
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback)
    }

    func testAProbeWaitingBehindALongLaneRequestIsInconclusive() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let gate = harness.node.hold("/v1/status")
        harness.probeMayHang.value = true
        harness.laneActivity.value = NodeLaneActivitySnapshot(sinceLastResponse: nil, laneHeldFor: .seconds(3))
        await harness.advance(by: .seconds(90))
        XCTAssertEqual(try harness.mode(), .node, "the probe never had its full timeout on the wire")
        harness.laneActivity.value = NodeLaneActivitySnapshot(sinceLastResponse: nil, laneHeldFor: .seconds(30))
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(), .fallback, "a lane held past the timeout is a hung Node")
        gate.release()
    }

    func testAccountsBoundToAnotherNodeFallBackAloneAndNeverMoveTheOthers() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(
            testName: #function, modes: [.node, .node], boundTo: [nil, NodeReachabilitySupervisorHarness.otherNodeID])
        defer { harness.cleanUp() }
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(1), .fallback, "its Node is not the session's: direct sync handles it")
        XCTAssertEqual(try harness.mode(0), .node)
        await harness.advance(by: .seconds(120))
        XCTAssertEqual(try harness.mode(0), .node, "the healthy account never flips because of the other")
        let reachable = await harness.supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.nodeID)
        XCTAssertNotNil(reachable)
        let other = await harness.supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.otherNodeID)
        XCTAssertNil(other)
        let status = await harness.supervisor.status
        XCTAssertEqual(status, .connectedDirectly)
        XCTAssertGreaterThanOrEqual(harness.ticks.value, 18, "every tick runs the approved-send reconcile hook")
    }

    /// Without its provider sign-in on this device an account can't sync directly: it stays
    /// with its Node, its changes waiting, while the others on the Node fall back.
    func testOnlyAnAccountThatMaySyncDirectlyFallsBack() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(
            testName: #function, modes: [.node, .node], mayFallBack: [1])
        defer { harness.cleanUp() }
        harness.node.setHealthy(false)
        await harness.advance(by: .seconds(60))
        XCTAssertEqual(try harness.mode(0), .node)
        XCTAssertEqual(try harness.mode(1), .fallback)
        let reachable = await harness.supervisor.reachableClient(nodeID: NodeReachabilitySupervisorHarness.nodeID)
        XCTAssertNil(reachable, "the account left with its Node gets no client while the Node is away")
        harness.node.setHealthy(true)
        await harness.advance(by: .seconds(40))
        XCTAssertEqual(try harness.mode(0), .node)
        XCTAssertEqual(try harness.mode(1), .node)
    }

    func testTheBrokerLaneRecordsWhenItIsHeldAndWhenTheNodeAnswered() async throws {
        let node = FakeNodeMailServer()
        let broker = NodeSessionBroker(resolveSender: { (NodeReachabilitySupervisorHarness.nodeID, node) })
        XCTAssertNil(broker.activity.snapshot().sinceLastResponse)
        let client = try await broker.client().client
        let gate = node.hold("/v1/status")
        let probe = Task { try await client.status() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.hasArrived, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(broker.activity.snapshot().laneHeldFor, "the lane is held while the request is on the wire")
        gate.release()
        _ = try await probe.value
        let after = broker.activity.snapshot()
        XCTAssertNil(after.laneHeldFor)
        XCTAssertNotNil(after.sinceLastResponse)
    }

    func testAFailedCapabilityCheckConfirmsNothing() async throws {
        let harness = try await NodeReachabilitySupervisorHarness.make(testName: #function, start: false)
        defer { harness.cleanUp() }
        harness.node.fail("/v1/mail/capabilities", with: .unavailable, times: 3)
        await harness.start()
        await harness.advance(by: .seconds(20))
        await harness.advance(by: .seconds(20))
        // The client retries an unavailable answer once: the check fails at
        // t = 0 (two requests) and confirms at t = 10 (a failure, then the
        // answer). Only that answer records compatibility, so no later probe
        // checks again.
        XCTAssertEqual(harness.node.count("GET /v1/mail/capabilities"), 4)
        await harness.advance(by: .seconds(20))
        XCTAssertEqual(harness.node.count("GET /v1/mail/capabilities"), 4)
    }

    func testOnlyASuccessfulAnswerCountsAsTheNodeAnswering() {
        let activity = NodeLaneActivity()
        activity.recordResponse(statusCode: 429)
        activity.recordResponse(statusCode: 404)
        activity.recordResponse(statusCode: 503)
        XCTAssertNil(activity.snapshot().sinceLastResponse, "a relay can answer 4xx and 5xx on its own")
        activity.recordResponse(statusCode: 200)
        XCTAssertNotNil(activity.snapshot().sinceLastResponse)
    }
}
