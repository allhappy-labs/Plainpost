import Combine
import Foundation
import XCTest
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostServiceIPC
@testable import PlainpostUI

@MainActor
final class PlainpostSessionRetryDriverTests: XCTestCase {
    private let offline = AccountSessionViewModel.Presentation.offlineLease(expiresAt: Date(timeIntervalSinceNow: 3_600))

    func testRetriesOnlyForTransientFailuresInOfflineOrRecoveryStates() {
        typealias Driver = PlainpostSessionRetryDriver
        XCTAssertTrue(Driver.isEligible(presentation: offline, transientFailure: .network))
        XCTAssertTrue(Driver.isEligible(presentation: .recoveryRequired, transientFailure: .credentialsUnavailable))
        XCTAssertTrue(Driver.isEligible(presentation: .recoveryRequired, transientFailure: .network))
        XCTAssertFalse(Driver.isEligible(presentation: .recoveryRequired, transientFailure: nil), "a real recovery needs the user")
        XCTAssertFalse(Driver.isEligible(presentation: .active, transientFailure: .network))
        XCTAssertFalse(Driver.isEligible(presentation: .signInRequired, transientFailure: .network))
        XCTAssertFalse(Driver.isEligible(presentation: .suspended, transientFailure: .network))
        XCTAssertFalse(Driver.isEligible(presentation: nil, transientFailure: .network))
    }

    func testBacksOffFrom15SecondsToFiveMinutesAndStopsWhenRecovered() async throws {
        let gate = SleepGate()
        var prepares = 0
        let driver = PlainpostSessionRetryDriver(
            prepare: { prepares += 1 },
            isHidden: { true },
            sleep: { try await gate.sleep($0) }
        )
        driver.update(presentation: offline, transientFailure: .network)
        for expectedPrepares in 1...6 {
            try await gate.waitForRequests(expectedPrepares)
            await gate.releaseNext()
            try await waitUntil { prepares == expectedPrepares }
        }
        try await gate.waitForRequests(7)
        let requested = await gate.requested
        XCTAssertEqual(requested, [15, 30, 60, 120, 300, 300, 300].map { Duration.seconds($0) })

        driver.update(presentation: .active, transientFailure: nil)
        XCTAssertFalse(driver.isRetrying)
        await gate.releaseNext()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(prepares, 6, "a recovered session is not prepared again")
    }

    func testNetworkWakeOrUnlockTriesAtOnceAndRestartsTheBackoff() async throws {
        let gate = SleepGate()
        var prepares = 0
        let driver = PlainpostSessionRetryDriver(
            prepare: { prepares += 1 },
            isHidden: { true },
            sleep: { try await gate.sleep($0) }
        )
        driver.conditionsMayHaveChanged()
        XCTAssertEqual(prepares, 0, "nothing to retry while the session is fine")

        driver.update(presentation: .recoveryRequired, transientFailure: .credentialsUnavailable)
        try await gate.waitForRequests(1)
        await gate.releaseNext()
        try await waitUntil { prepares == 1 }
        try await gate.waitForRequests(2)

        driver.conditionsMayHaveChanged()
        XCTAssertEqual(prepares, 2)
        try await gate.waitForRequests(3)
        let requested = await gate.requested
        XCTAssertEqual(requested.last, .seconds(15))
    }

    func testAnOpenWindowPreparesTheSessionItself() async throws {
        let gate = SleepGate()
        var prepares = 0
        var hidden = false
        let driver = PlainpostSessionRetryDriver(
            prepare: { prepares += 1 },
            isHidden: { hidden },
            sleep: { try await gate.sleep($0) }
        )
        driver.update(presentation: offline, transientFailure: .network)
        driver.conditionsMayHaveChanged()
        try await gate.waitForRequests(1)
        await gate.releaseNext()
        try await gate.waitForRequests(2)
        XCTAssertEqual(prepares, 0)

        hidden = true
        await gate.releaseNext()
        try await waitUntil { prepares == 1 }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met before the deadline") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor SleepGate {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while requested.count < count {
            guard Date() < deadline else { return XCTFail("only \(requested.count) of \(count) sleeps requested") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

final class PlainpostMenuBarStatusTests: XCTestCase {
    func testLockedLoginLaunchOffersUnlockAndSaysWhy() {
        let status = PlainpostMenuBarStatus(vaultState: .locked, presentation: .active, transientFailure: nil, ownership: .own)
        XCTAssertEqual(status.messages, ["Unlock Plainpost to receive notifications"])
        XCTAssertTrue(status.offersUnlock)
        XCTAssertFalse(status.offersLock)
    }

    func testReadyVaultOffersLockVault() {
        let status = PlainpostMenuBarStatus(vaultState: .ready, presentation: .active, transientFailure: nil, ownership: .own)
        XCTAssertEqual(status.messages, [])
        XCTAssertTrue(status.offersLock)
        XCTAssertFalse(status.offersUnlock)
        let offline = PlainpostMenuBarStatus(
            vaultState: .ready,
            presentation: .offlineLease(expiresAt: Date(timeIntervalSinceNow: 60)),
            transientFailure: .network,
            ownership: .own
        )
        XCTAssertTrue(offline.offersLock)
        XCTAssertEqual(offline.messages, [PlainpostMenuBarStatus.offlineMessage])
    }

    func testSignedOutSessionOffersNeitherVaultAction() {
        for vault in [PlainpostVaultLaunchState.locked, .ready] {
            let status = PlainpostMenuBarStatus(vaultState: vault, presentation: .signInRequired, transientFailure: nil, ownership: .unknown)
            XCTAssertFalse(status.offersUnlock)
            XCTAssertFalse(status.offersLock)
            XCTAssertEqual(status.messages, [])
        }
    }

    func testFailedLockIsShownFirst() {
        let status = PlainpostMenuBarStatus(
            vaultState: .ready, presentation: .active, transientFailure: nil, ownership: .own,
            lockError: PlainpostApplicationModel.lockVaultFailureMessage
        )
        XCTAssertEqual(status.messages, ["Plainpost could not lock the vault. Try again."])
        XCTAssertTrue(status.offersLock)
    }

    func testKeychainAndForeignServiceStates() {
        let keychain = PlainpostMenuBarStatus(vaultState: .checking, presentation: .recoveryRequired, transientFailure: .credentialsUnavailable, ownership: .unknown)
        XCTAssertEqual(keychain.messages, ["Waiting for your login keychain to unlock."])

        let foreign = PlainpostMenuBarStatus(
            vaultState: .locked,
            presentation: .active,
            transientFailure: nil,
            ownership: .foreign(bundlePath: "/Users/me/Downloads/Plainpost.app/Contents/Library/Helpers/PlainpostService.app")
        )
        XCTAssertEqual(foreign.messages, [
            "Another Plainpost installation is running the background service.",
            "Unlock Plainpost to receive notifications",
        ])
    }
}

@MainActor
final class AccountSessionBackgroundRefreshTests: XCTestCase {
    func testScheduledRefreshResultMovesTheSessionOffline() async throws {
        let model = AccountSessionViewModel(prepareSession: { _ in .active })
        model.prepare()
        try await waitUntil { model.presentation == .active }

        let expiry = Date(timeIntervalSinceNow: 3_600)
        model.receiveBackgroundSessionState(.offlineLease(expiresAt: expiry), transientFailure: .network)

        XCTAssertEqual(model.presentation, .offlineLease(expiresAt: expiry))
        XCTAssertEqual(model.transientFailure, .network)
    }

    func testForegroundPrepareInFlightWinsOverABackgroundResult() async throws {
        let gate = PrepareGate()
        let model = AccountSessionViewModel(prepareSession: { _ in await gate.wait() })
        model.prepare()
        model.receiveBackgroundSessionState(.suspended, transientFailure: nil)
        XCTAssertEqual(model.presentation, .signInRequired, "the pending prepare decides")

        await gate.release(.active)
        try await waitUntil { model.presentation == .active }
    }

    func testPrepareRecordsTheTransientFailure() async throws {
        let model = AccountSessionViewModel(prepareSession: { _ in .expired })
        model.transientFailureReader = { .credentialsUnavailable }
        model.prepare()
        try await waitUntil { model.transientFailure == .credentialsUnavailable }
        XCTAssertEqual(model.presentation, .recoveryRequired)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met before the deadline") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor PrepareGate {
    private var continuation: CheckedContinuation<AccountSessionState, Never>?
    private var pending: AccountSessionState?

    func wait() async -> AccountSessionState {
        if let pending { return pending }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ state: AccountSessionState) {
        if let continuation {
            continuation.resume(returning: state)
            self.continuation = nil
        } else {
            pending = state
        }
    }
}

final class PlainpostBundledServiceRestoreTests: XCTestCase {
    private let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "build-2")

    func testRunningCurrentBuildIsLeftAlone() async throws {
        let client = IdentityClient(answers: [.success(expected)])
        let result = try await run(client: client, isRegistered: true)
        XCTAssertEqual(result.events, [])
        XCTAssertEqual(result.ownership, [.own])
    }

    func testUnloadedJobIsReRegisteredAndOwnershipCheckedAfterwards() async throws {
        let client = IdentityClient(answers: [.failure(.serviceUnavailable), .success(expected)])
        let result = try await run(client: client, isRegistered: true)
        XCTAssertEqual(result.events, ["unregister", "register"])
        XCTAssertEqual(result.ownership, [.own])
    }

    func testStaleBuildAfterReinstallIsBounced() async throws {
        let stale = PlainpostServiceBuildIdentity(bundlePath: expected.bundlePath, buildStamp: "build-1")
        let client = IdentityClient(answers: [.success(stale), .success(expected)])
        let result = try await run(client: client, isRegistered: true)
        XCTAssertEqual(result.events, ["unregister", "register"])
        XCTAssertEqual(result.ownership, [.own])
    }

    func testAnotherInstallationsServiceIsReportedAndNotBounced() async throws {
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Users/me/Plainpost.app/S.app", buildStamp: "build-2")
        let client = IdentityClient(answers: [.success(foreign)])
        let result = try await run(client: client, isRegistered: true)
        XCTAssertEqual(result.events, [])
        XCTAssertEqual(result.ownership, [.foreign(bundlePath: foreign.bundlePath)])
    }

    func testForeignServiceStillAnsweringAfterRegistrationIsReported() async throws {
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Users/me/Plainpost.app/S.app", buildStamp: "x")
        let client = IdentityClient(answers: [.failure(.serviceUnavailable), .success(foreign)])
        let result = try await run(client: client, isRegistered: false)
        XCTAssertEqual(result.events, ["register"])
        XCTAssertEqual(result.ownership, [.foreign(bundlePath: foreign.bundlePath)])
    }

    private func run(
        client: IdentityClient,
        isRegistered: Bool
    ) async throws -> (events: [String], ownership: [PlainpostServiceOwnership]) {
        let recorder = RestoreRecorder()
        try await PlainpostBundledServiceRestore.run(
            client: client,
            expected: expected,
            isRegistered: isRegistered,
            unregister: { await recorder.record("unregister") },
            register: { await recorder.record("register") },
            publish: { ownership in recorder.publishNow(ownership) },
            bundleIsGone: { _ in false }
        )
        return (await recorder.events, recorder.ownershipSnapshot)
    }
}

private final class RestoreRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var published: [PlainpostServiceOwnership] = []

    var events: [String] { get async { lock.withLock { recorded } } }
    var ownershipSnapshot: [PlainpostServiceOwnership] { lock.withLock { published } }

    func record(_ event: String) async { lock.withLock { recorded.append(event) } }
    func publishNow(_ ownership: PlainpostServiceOwnership) { lock.withLock { published.append(ownership) } }
}

private actor IdentityClient: PlainpostServiceClientProtocol {
    private var answers: [Result<PlainpostServiceBuildIdentity?, PlainpostServiceClientError>]

    init(answers: [Result<PlainpostServiceBuildIdentity?, PlainpostServiceClientError>]) {
        self.answers = answers
    }

    nonisolated func status() async throws -> PlainpostVaultStatus { PlainpostVaultStatus(availability: .unlocked, matchingKeyItemCount: 1) }
    nonisolated func unlock(reason: String) async throws {}
    nonisolated func lock() async throws {}

    func serviceIdentity() async throws -> PlainpostServiceBuildIdentity? {
        guard !answers.isEmpty else { throw PlainpostServiceClientError.serviceUnavailable }
        return try answers.removeFirst().get()
    }
}

@MainActor
final class PlainpostSessionRecoveryMonitorTests: XCTestCase {
    func testManualLaunchRecoversFromABackgroundOfflineTransitionWithoutAWindow() async throws {
        // A manual launch: the window prepared the session, then closed.
        let prepares = PrepareCounter(results: [.active, .active])
        let model = AccountSessionViewModel(prepareSession: { _ in await prepares.next() })
        model.prepare()
        try await waitUntil { model.presentation == .active }

        var hidden = true
        let models = CurrentValueSubject<AccountSessionViewModel?, Never>(model)
        let monitor = PlainpostSessionRecoveryMonitor(
            accountModels: models.eraseToAnyPublisher(),
            isHidden: { hidden },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        monitor.networkPathChanged(satisfied: true)

        // A refresh on wake fails: the controller reports offline.
        model.receiveBackgroundSessionState(
            .offlineLease(expiresAt: Date(timeIntervalSinceNow: 3_600)),
            transientFailure: .network
        )
        XCTAssertTrue(monitor.driver.isRetrying)

        // The network comes back.
        monitor.networkPathChanged(satisfied: false)
        monitor.networkPathChanged(satisfied: true)
        try await waitUntil { model.presentation == .active }
        let calls = await prepares.calls
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(monitor.driver.isRetrying)
        hidden = false
    }

    func testFollowsTheCurrentAccountModel() async throws {
        let first = AccountSessionViewModel(prepareSession: { _ in .active })
        let secondPrepares = PrepareCounter(results: [.active])
        let second = AccountSessionViewModel(prepareSession: { _ in await secondPrepares.next() })
        let models = CurrentValueSubject<AccountSessionViewModel?, Never>(first)
        let monitor = PlainpostSessionRecoveryMonitor(
            accountModels: models.eraseToAnyPublisher(),
            isHidden: { true },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        models.send(second)
        second.receiveBackgroundSessionState(.expired, transientFailure: .credentialsUnavailable)
        monitor.conditionsMayHaveChanged()
        try await waitUntil { second.presentation == .active }
        let calls = await secondPrepares.calls
        XCTAssertEqual(calls, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met before the deadline") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
final class AccountSessionBackgroundRetryTests: XCTestCase {
    func testBackgroundRetryWithAnUnchangedStateLeavesFlowsAlone() async throws {
        // Every apply(.active) registers the cleanup target again, which is
        // what a full prepare does to in-memory flows.
        let registrations = RegistrationCounter()
        let model = AccountSessionViewModel(
            prepareSession: { _ in .active },
            activeCleanupRegistration: { await registrations.increment() }
        )
        model.prepare()
        try await waitUntilAsync { await registrations.count == 1 }

        model.refreshInBackground()
        try await Task.sleep(for: .milliseconds(100))
        let afterRetry = await registrations.count
        XCTAssertEqual(afterRetry, 1, "a background retry with no state change resets nothing")
        XCTAssertEqual(model.presentation, .active)
    }

    func testBackgroundRetryAppliesAChangedState() async throws {
        let prepares = PrepareCounter(results: [.suspended])
        let model = AccountSessionViewModel(prepareSession: { _ in await prepares.next() })
        model.receiveBackgroundSessionState(
            .offlineLease(expiresAt: Date(timeIntervalSinceNow: 3_600)),
            transientFailure: .network
        )
        model.refreshInBackground()
        try await waitUntilAsync { await MainActor.run { model.presentation == .suspended } }
        XCTAssertNil(model.transientFailure)
    }

    func testBackgroundRetryNeverOverridesAForegroundPrepare() async throws {
        let gate = PrepareGate()
        let calls = PrepareCounter(results: [])
        let model = AccountSessionViewModel(prepareSession: { _ in
            _ = await calls.next()
            return await gate.wait()
        })
        model.prepare()
        model.refreshInBackground()
        try await Task.sleep(for: .milliseconds(50))
        let count = await calls.calls
        XCTAssertEqual(count, 1, "the background retry waits for the foreground prepare")
        await gate.release(.active)
    }

    private func waitUntilAsync(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("condition not met before the deadline") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor PrepareCounter {
    private var results: [AccountSessionState]
    private(set) var calls = 0

    init(results: [AccountSessionState]) { self.results = results }

    func next() -> AccountSessionState {
        calls += 1
        return results.isEmpty ? .active : results.removeFirst()
    }
}

private actor RegistrationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

final class PlainpostBundledServiceRestoreEdgeTests: XCTestCase {
    private let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "build-2")

    func testForeignServiceWhoseInstallationIsGoneIsTakenOver() async throws {
        let orphan = PlainpostServiceBuildIdentity(bundlePath: "/Users/me/Deleted/Plainpost.app/S.app", buildStamp: "x")
        let client = EdgeIdentityClient(answers: [.success(orphan), .success(expected)])
        let recorder = EdgeRecorder()
        try await PlainpostBundledServiceRestore.run(
            client: client, expected: expected, isRegistered: true,
            unregister: { recorder.record("unregister") }, register: { recorder.record("register") },
            publish: { recorder.publish($0) }, bundleIsGone: { _ in true }
        )
        XCTAssertEqual(recorder.events, ["unregister", "register"])
        XCTAssertEqual(recorder.ownership, [.own])
    }

    func testServiceBusyStartingIsAskedTwiceAndLeftRunning() async throws {
        let client = EdgeIdentityClient(answers: [.failure(.timedOut), .failure(.timedOut)])
        let recorder = EdgeRecorder()
        try await PlainpostBundledServiceRestore.run(
            client: client, expected: expected, isRegistered: true,
            unregister: { recorder.record("unregister") }, register: { recorder.record("register") },
            publish: { recorder.publish($0) }
        )
        XCTAssertEqual(recorder.events, [], "a service busy migrating is not bounced")
        XCTAssertEqual(recorder.ownership, [.unknown])
        let asked = await client.asked
        XCTAssertEqual(asked, 2)
    }

    func testOneTimeoutThenAnAnswerIsJudgedByTheAnswer() async throws {
        let client = EdgeIdentityClient(answers: [.failure(.timedOut), .success(expected)])
        let recorder = EdgeRecorder()
        try await PlainpostBundledServiceRestore.run(
            client: client, expected: expected, isRegistered: true,
            unregister: { recorder.record("unregister") }, register: { recorder.record("register") },
            publish: { recorder.publish($0) }
        )
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.ownership, [.own])
    }

    func testPolicyForOrphanedAndBusyServices() {
        typealias Policy = PlainpostBundledServiceRefreshPolicy
        let foreign = PlainpostServiceBuildIdentity(bundlePath: "/Other/Plainpost.app/S.app", buildStamp: "x")
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .identity(foreign), expected: expected, bundleIsGone: { _ in false }), .foreign(bundlePath: foreign.bundlePath))
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .identity(foreign), expected: expected, bundleIsGone: { _ in true }), .refresh)
        XCTAssertEqual(Policy.decide(isRegistered: true, reported: .busy, expected: expected), .keepRunning)
        XCTAssertEqual(Policy.decide(isRegistered: false, reported: .busy, expected: expected), .refresh)
    }
}

private final class EdgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var published: [PlainpostServiceOwnership] = []
    var events: [String] { lock.withLock { recorded } }
    var ownership: [PlainpostServiceOwnership] { lock.withLock { published } }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }
    func publish(_ value: PlainpostServiceOwnership) { lock.withLock { published.append(value) } }
}

private actor EdgeIdentityClient: PlainpostServiceClientProtocol {
    private var answers: [Result<PlainpostServiceBuildIdentity?, PlainpostServiceClientError>]
    private(set) var asked = 0

    init(answers: [Result<PlainpostServiceBuildIdentity?, PlainpostServiceClientError>]) { self.answers = answers }

    nonisolated func status() async throws -> PlainpostVaultStatus { PlainpostVaultStatus(availability: .unlocked, matchingKeyItemCount: 1) }
    nonisolated func unlock(reason: String) async throws {}
    nonisolated func lock() async throws {}

    func serviceIdentity() async throws -> PlainpostServiceBuildIdentity? {
        asked += 1
        guard !answers.isEmpty else { throw PlainpostServiceClientError.serviceUnavailable }
        return try answers.removeFirst().get()
    }
}

@MainActor
final class AccountSessionPrepareTokenTests: XCTestCase {
    func testAppleSignInDuringAPrepareDoesNotBlockLaterBackgroundRefreshes() async throws {
        let gate = PrepareGate()
        let calls = PrepareCounter(results: [])
        var gated = true
        let model = AccountSessionViewModel(prepareSession: { _ in
            _ = await calls.next()
            if await MainActor.run(body: { gated }) { return await gate.wait() }
            return .suspended
        })
        model.prepare()
        try await waitUntilAsync { await calls.calls == 1 }
        // Apple sign-in bumps the generation while the prepare is in flight.
        _ = try model.beginAppleSignIn()
        gated = false
        await gate.release(.signInRequired)
        try await Task.sleep(for: .milliseconds(50))

        model.refreshInBackground()
        try await waitUntilAsync { await calls.calls == 2 }
        try await waitUntilAsync { await MainActor.run { model.presentation == .suspended } }

        model.receiveBackgroundSessionState(.active, transientFailure: nil)
        XCTAssertEqual(model.presentation, .active, "background results still apply")
    }

    private func waitUntilAsync(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("condition not met before the deadline") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

final class PlainpostHungServiceRestartTests: XCTestCase {
    func testHungServiceIsRestartedOnTheThirdBusyCheck() async throws {
        let expected = PlainpostServiceBuildIdentity(bundlePath: "/Applications/Plainpost.app/S.app", buildStamp: "1")
        let tracker = PlainpostServiceBusyTracker()
        let client = EdgeIdentityClient(answers: Array(repeating: .failure(.timedOut), count: 6) + [.success(expected)])
        let recorder = EdgeRecorder()
        let start = Date(timeIntervalSince1970: 1_000)
        for pass in 0..<3 {
            try await PlainpostBundledServiceRestore.run(
                client: client, expected: expected, isRegistered: true,
                unregister: { recorder.record("unregister") }, register: { recorder.record("register") },
                publish: { recorder.publish($0) }, busyTracker: tracker,
                now: start.addingTimeInterval(Double(pass) * 20)
            )
            if pass < 2 { XCTAssertEqual(recorder.events, [], "pass \(pass) waits for a slow start") }
        }
        XCTAssertEqual(recorder.events, ["unregister", "register"])
        XCTAssertEqual(recorder.ownership, [.unknown, .unknown, .own])
    }

    func testPresenceIgnoresMinimizedWindows() {
        let minimized = PlainpostWindowPresence(canBecomeMain: true, isVisible: false, isMiniaturized: true)
        let open = PlainpostWindowPresence(canBecomeMain: true, isVisible: true, isMiniaturized: false)
        let panel = PlainpostWindowPresence(canBecomeMain: false, isVisible: true, isMiniaturized: false)
        XCTAssertFalse(PlainpostApplicationPresence.hasOnScreenWindow(in: [minimized, panel]))
        XCTAssertTrue(PlainpostApplicationPresence.hasOnScreenWindow(in: [minimized, open]))
        // The Dock icon still counts a minimized window.
        XCTAssertTrue(PlainpostApplicationPresence.hasUserFacingWindow(in: [minimized]))
    }
}
