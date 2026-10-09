import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime

final class AccountSessionControllerTests: XCTestCase {
    func testFreshInstallRequiresSignIn() async throws {
        let store = SessionStore(session: nil)
        let controller = AccountSessionController(credentials: store, refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let state = await controller.prepare(now: date(0))
        XCTAssertEqual(state, .signInRequired)
    }

    func testBundledControllerRefreshUsesSelectedCentralOrigin() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentialsStore = AccountCredentialStore(secretStore: secrets, service: "test.controller.selected-origin")
        try credentialsStore.saveSession(try session(accessExpiry: date(-1), lease: "lease"))
        let transport = HostRecordingFailureTransport()
        let controller = try AccountSessionRuntimeAssembly.bundledController(
            credentials: credentialsStore,
            bootstrapManifest: try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore()),
            transport: transport,
            baseURL: URL(string: "https://selected-central.example:8443")!
        )

        _ = await controller.prepare(now: date(0))
        let hosts = await transport.hosts()

        XCTAssertEqual(hosts, ["selected-central.example"])
    }

    func testPendingLocalDeletionBlocksSessionAndRefreshBeforeAnyAccountTraffic() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let deviceID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let store = SessionStore(session: AccountSession(credentials: try credentials(accessExpiry: date(900), lease: "lease")))
        store.localDeletion = try AccountLocalDeletionCheckpoint(accountID: accountID, deviceID: deviceID, kind: .macos, targetHandle: Data(repeating: 1, count: 32), deletionGeneration: PositiveUInt64(1), phase: .prepared, resultDigest: nil)
        let refresher = CountingRefresher()
        let controller = AccountSessionController(credentials: store, refresher: refresher, leaseVerifier: { _, _ in nil })

        let state = await controller.prepare(now: date(0))

        XCTAssertEqual(state, .cleanupRequired)
        let callCount = await refresher.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testCompletedDeletionReceiptIsPermanentTerminalStateBeforeSessionOrNetworkAccess() async throws {
        let store = SessionStore(session: AccountSession(credentials: try credentials(accessExpiry: date(900), lease: "lease")))
        store.completedDeletionReceipt = try AccountCompletedDeletionReceipt(
            targetHandle: Data(repeating: 0x41, count: 32),
            targetKind: .macos,
            deletionGeneration: PositiveUInt64(2),
            resultDigest: Data(repeating: 0x42, count: 32)
        )
        let refresher = CountingRefresher()
        let controller = AccountSessionController(credentials: store, refresher: refresher, leaseVerifier: { _, _ in nil })

        let state = await controller.prepare(now: date(0))
        let callCount = await refresher.callCount

        XCTAssertEqual(state, .deleted)
        XCTAssertEqual(callCount, 0)
    }

    func testProvisionalActivationSurfacesPendingApprovalWithoutRefreshing() async throws {
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            mode: .pending
        )
        let store = SessionStore(session: AccountSession(state: .provisional(activation)))
        let refresher = CountingRefresher()
        let controller = AccountSessionController(
            credentials: store,
            refresher: refresher,
            leaseVerifier: { _, _ in nil }
        )

        let state = await controller.prepare(now: date(0))
        let callCount = await refresher.callCount
        XCTAssertEqual(state, .provisional(activation))
        XCTAssertEqual(callCount, 0)
    }

    func testPendingRefreshCannotPromoteWithoutVerifiedTrustCompletion() async throws {
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            mode: .pending
        )
        let provisional = try credentials(accessExpiry: date(-1), lease: "pending")
        let refreshed = try credentials(accessExpiry: date(900), lease: "admitted")
        let store = SessionStore(session: try AccountSession(provisional: activation, credentials: provisional))
        let controller = AccountSessionController(
            credentials: store,
            refresher: TestRefresher(result: .success(refreshed)),
            leaseVerifier: { _, _ in nil },
            pendingAdmissionCompleter: nil
        )

        let state = await controller.prepare(now: date(0))

        XCTAssertEqual(state, .provisional(activation))
        XCTAssertEqual(store.session?.state, .provisional(activation))
        XCTAssertEqual(store.session?.credentials, provisional)
    }

    func testPendingPromotionOccursOnlyAfterVerifiedTrustCompleterCommitsActivation() async throws {
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            mode: .pending
        )
        let provisional = try credentials(accessExpiry: date(-1), lease: "pending")
        let refreshed = try credentials(accessExpiry: date(900), lease: "admitted")
        let store = SessionStore(session: try AccountSession(provisional: activation, credentials: provisional))
        let controller = AccountSessionController(
            credentials: store,
            refresher: TestRefresher(result: .success(refreshed)),
            leaseVerifier: { _, _ in nil },
            pendingAdmissionCompleter: { receivedActivation, receivedCredentials, _ in
                XCTAssertEqual(receivedActivation, activation)
                XCTAssertEqual(receivedCredentials, refreshed)
                try store.saveSession(AccountSession(credentials: receivedCredentials))
            }
        )

        let state = await controller.prepare(now: date(0))

        XCTAssertEqual(state, .active)
        XCTAssertEqual(store.session?.credentials, refreshed)
    }

    @MainActor func testPendingAdmissionCancellationDuringAmbiguousResponsePutCancelsExactAttempt() async throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let pendingID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let ownerID = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let pendingIdentity = try AccountDeviceIdentity.generate()
        let ownerIdentity = try AccountDeviceIdentity.generate()
        let now = date(0)
        let offer = try TrustHandshakeOfferV1(
            accountID: accountID,
            existingDeviceID: ownerID,
            pendingDeviceID: pendingID,
            existingPublicBundle: ownerIdentity.publicBundle,
            pendingPublicBundle: pendingIdentity.publicBundle,
            existingNonce: Data(repeating: 7, count: 32),
            createdAtUnixMilliseconds: PositiveUInt64(UInt64(now.timeIntervalSince1970 * 1_000)),
            expiresAtUnixMilliseconds: PositiveUInt64(UInt64(now.addingTimeInterval(300).timeIntervalSince1970 * 1_000))
        )
        let offerEnvelope = try AccountWireCodec.decodeAdmissionOfferEnvelope(AccountWireCodec.encodeAdmissionOfferEnvelope(offer))
        let rendezvous = BlockingResponseRendezvous(offer: offerEnvelope)
        let activation = AccountActivation(accountID: accountID, deviceID: pendingID, mode: .pending)
        let controller = try AccountAdmissionController(
            rendezvous: rendezvous,
            pending: activation,
            publicBundle: pendingIdentity.publicBundle,
            poll: { .provisional(activation) },
            random: { count in Data(repeating: 8, count: count) }
        )

        controller.start(now: now)
        await rendezvous.waitUntilResponseStarted()
        controller.cancel()
        await rendezvous.waitUntilCanceled()

        let canceledDigest = await rendezvous.canceledDigest()
        XCTAssertEqual(canceledDigest, offerEnvelope.offerDigest)
    }

    /// Right after sign-in no trusted device has sent its offer yet. The new device keeps
    /// waiting for it instead of failing straight into account recovery.
    @MainActor func testPendingAdmissionWaitsForAnOfferThatArrivesLater() async throws {
        let fixture = try AdmissionFixture()
        let rendezvous = LateOfferRendezvous(offer: fixture.offerEnvelope, emptyFetches: 2)
        let controller = try AccountAdmissionController(
            rendezvous: rendezvous, pending: fixture.activation, publicBundle: fixture.pendingIdentity.publicBundle,
            poll: { [activation = fixture.activation] in .provisional(activation) },
            random: { count in Data(repeating: 8, count: count) },
            clock: { fixture.now }, sleep: { _ in await Task.yield() }
        )

        controller.start(now: fixture.now)
        for _ in 0..<500 where { if case .matchingCode = controller.state { return false }; return controller.state != .failed }() {
            await Task.yield()
        }

        if case .matchingCode = controller.state {} else { XCTFail("Expected a matching code, got \(controller.state)") }
        let fetches = await rendezvous.fetchCount
        XCTAssertEqual(fetches, 3)
        controller.cancel()
    }

    @MainActor func testPendingAdmissionWithNoOfferEndsExpiredAtItsDeadline() async throws {
        let fixture = try AdmissionFixture()
        let rendezvous = LateOfferRendezvous(offer: fixture.offerEnvelope, emptyFetches: .max)
        let clock = AdmissionTestClock(fixture.now)
        let controller = try AccountAdmissionController(
            rendezvous: rendezvous, pending: fixture.activation, publicBundle: fixture.pendingIdentity.publicBundle,
            poll: { [activation = fixture.activation] in .provisional(activation) },
            random: { count in Data(repeating: 8, count: count) },
            clock: { clock.now }, sleep: { duration in clock.advance(by: duration) }
        )

        controller.start(now: fixture.now)
        for _ in 0..<5_000 where controller.state == .waiting { await Task.yield() }

        XCTAssertEqual(controller.state, .expired)
    }

    /// Another device's recovery (or suspension) leaves this device suspended for good.
    /// Starting over clears the stored session so the device signs in again like a new one;
    /// it never clears a session Central still accepts.
    func testASuspendedSessionCanStartOverAndAnActiveOneCannot() async throws {
        let suspendedStore = SessionStore(session: try session(accessExpiry: date(-1), lease: "lease"))
        let suspended = AccountSessionController(
            credentials: suspendedStore, refresher: TestRefresher(result: .failure(.suspended)),
            leaseVerifier: { _, _ in nil }, jitter: { _ in 0 }
        )
        let before = await suspended.prepare(now: date(0))
        XCTAssertEqual(before, .suspended)

        let after = await suspended.discardSuspendedSession(now: date(0))

        XCTAssertEqual(after, .signInRequired)
        XCTAssertNil(suspendedStore.session)

        let activeStore = SessionStore(session: try session(accessExpiry: date(-1), lease: "lease"))
        let active = AccountSessionController(
            credentials: activeStore,
            refresher: TestRefresher(result: .success(try credentials(accessExpiry: date(3_600), lease: "lease"))),
            leaseVerifier: { _, _ in nil }, jitter: { _ in 0 }
        )
        let kept = await active.discardSuspendedSession(now: date(0))
        XCTAssertEqual(kept, .active)
        XCTAssertNotNil(activeStore.session)
    }

    func testCredentialLoadFailureAndIncompleteGenesisFailClosed() async throws {
        let unavailable = AccountSessionController(
            credentials: ThrowingSessionStore(),
            refresher: CountingRefresher(),
            leaseVerifier: { _, _ in nil }
        )
        let unavailableState = await unavailable.prepare(now: date(0))
        XCTAssertEqual(unavailableState, .expired)

        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("11111111-2222-3333-4444-555555555555"),
            mode: .genesis
        )
        let incomplete = AccountSessionController(
            credentials: SessionStore(session: AccountSession(state: .provisional(activation))),
            refresher: CountingRefresher(),
            leaseVerifier: { _, _ in nil }
        )
        let incompleteState = await incomplete.prepare(now: date(0))
        XCTAssertEqual(incompleteState, .expired)
    }

    func testNetworkFailureUsesOnlyAnAlreadyValidSignedLease() async throws {
        let session = try session(accessExpiry: date(-1), lease: "signed-lease")
        let store = SessionStore(session: session)
        let expiry = date(30)
        let controller = AccountSessionController(credentials: store, refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { lease, now in lease == "signed-lease" && now < expiry ? expiry : nil }, jitter: { _ in 0 })
        let fallback = await controller.prepare(now: date(0))
        XCTAssertEqual(fallback, .offlineLease(expiresAt: expiry))
        let invalid = AccountSessionController(credentials: store, refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let invalidState = await invalid.prepare(now: date(0))
        XCTAssertEqual(invalidState, .expired)
    }

    func testRefreshProducesActiveStateAndSchedulesJitteredEarlyRefresh() async throws {
        let session = try session(accessExpiry: date(-1), lease: "lease")
        let replacement = try credentials(accessExpiry: date(900), lease: "new-lease")
        let store = SessionStore(session: session)
        let now = date(0)
        let controller = AccountSessionController(credentials: store, refresher: TestRefresher(result: .success(replacement)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0.5 }, clock: { now })
        let state = await controller.prepare(now: now)
        XCTAssertEqual(state, .active)
        XCTAssertEqual(try XCTUnwrap(store.session?.credentials), replacement)
        let scheduled = await controller.nextRefreshAt
        let deadline = try XCTUnwrap(scheduled)
        XCTAssertGreaterThan(deadline, date(0))
        XCTAssertLessThan(deadline, replacement.accessExpiresAt)
    }

    func testTransientFailureNamesOnlyCausesThatClearByThemselves() async throws {
        let locked = AccountSessionController(credentials: ThrowingSessionStore(), refresher: CountingRefresher(), leaseVerifier: { _, _ in nil })
        _ = await locked.prepare(now: date(0))
        let lockedFailure = await locked.lastTransientFailure
        XCTAssertEqual(lockedFailure, .credentialsUnavailable)

        let session = try session(accessExpiry: date(-1), lease: "lease")
        let leaseExpiry = date(30)
        let offline = AccountSessionController(credentials: SessionStore(session: session), refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { _, _ in leaseExpiry }, jitter: { _ in 0 })
        _ = await offline.prepare(now: date(0))
        let offlineFailure = await offline.lastTransientFailure
        XCTAssertEqual(offlineFailure, .network)
        let expiredOffline = AccountSessionController(credentials: SessionStore(session: session), refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let expiredState = await expiredOffline.prepare(now: date(0))
        XCTAssertEqual(expiredState, .expired)
        let expiredFailure = await expiredOffline.lastTransientFailure
        XCTAssertEqual(expiredFailure, .network)

        let suspended = AccountSessionController(credentials: SessionStore(session: session), refresher: TestRefresher(result: .failure(.suspended)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        _ = await suspended.prepare(now: date(0))
        let suspendedFailure = await suspended.lastTransientFailure
        XCTAssertNil(suspendedFailure)

        // A later success clears the earlier failure.
        let store = SessionStore(session: session)
        let recovering = AccountSessionController(credentials: store, refresher: TestRefresher(result: .failure(.network)), leaseVerifier: { _, _ in leaseExpiry }, jitter: { _ in 0 })
        _ = await recovering.prepare(now: date(0))
        store.session = nil
        _ = await recovering.prepare(now: date(0))
        let cleared = await recovering.lastTransientFailure
        XCTAssertNil(cleared)
    }

    func testScheduledRefreshResultReachesTheObserver() async throws {
        // Active until the refresh deadline, then the background refresh
        // finds Central unreachable: the observer must learn the session is
        // now offline instead of the result being dropped.
        let store = SessionStore(session: try session(accessExpiry: date(120), lease: "signed-lease"))
        let later = date(200)
        let offlineExpiry = date(500)
        let controller = AccountSessionController(
            credentials: store,
            refresher: TestRefresher(result: .failure(.network)),
            leaseVerifier: { _, _ in offlineExpiry },
            jitter: { _ in 0 },
            clock: { later }
        )
        let (stream, continuation) = AsyncStream<(AccountSessionState, AccountSessionTransientFailure?)>.makeStream()
        await controller.setStateObserver { state, failure in continuation.yield((state, failure)) }

        let initial = await controller.prepare(now: date(0))
        XCTAssertEqual(initial, .active)

        let delivered = await firstValue(of: stream)
        XCTAssertEqual(delivered?.0, .offlineLease(expiresAt: date(500)))
        XCTAssertEqual(delivered?.1, .network)
    }

    func testSuccessfulScheduledRefreshStillReportsAfterSchedulingTheNextOne() async throws {
        let replacement = try credentials(accessExpiry: date(10_000), lease: "new-lease")
        let store = SessionStore(session: try session(accessExpiry: date(120), lease: "lease"))
        let later = date(200)
        let controller = AccountSessionController(
            credentials: store,
            refresher: TestRefresher(result: .success(replacement)),
            leaseVerifier: { _, _ in nil },
            jitter: { _ in 0 },
            clock: { later }
        )
        let (stream, continuation) = AsyncStream<AccountSessionState>.makeStream()
        await controller.setStateObserver { state, _ in continuation.yield(state) }
        _ = await controller.prepare(now: date(0))

        let delivered = await firstValue(of: stream)
        XCTAssertEqual(delivered, .active)
        XCTAssertEqual(store.session?.credentials, replacement)
    }

    func testSuspensionAndRejectionHaveDistinctStates() async throws {
        let session = try session(accessExpiry: date(-1), lease: "lease")
        let suspended = AccountSessionController(credentials: SessionStore(session: session), refresher: TestRefresher(result: .failure(.suspended)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let suspendedState = await suspended.prepare(now: date(0))
        XCTAssertEqual(suspendedState, .suspended)
        let store = SessionStore(session: session)
        let rejected = AccountSessionController(credentials: store, refresher: TestRefresher(result: .failure(.rejected)), leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let rejectedState = await rejected.prepare(now: date(0))
        XCTAssertEqual(rejectedState, .signInRequired)
        XCTAssertNil(store.session)
    }

    func testConcurrentPrepareCoalescesExactlyOneRefreshAndReplacement() async throws {
        let session = try session(accessExpiry: date(-1), lease: "lease")
        let replacement = try credentials(accessExpiry: date(900), lease: "new-lease")
        let store = SessionStore(session: session)
        let refresher = CoalescingRefresher(replacement: replacement)
        let controller = AccountSessionController(credentials: store, refresher: refresher, leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let now = date(0)
        async let first = controller.prepare(now: now)
        async let second = controller.prepare(now: now)
        await refresher.waitUntilStarted()
        await refresher.release()
        let states = await [first, second]
        XCTAssertEqual(states, [.active, .active])
        let callCount = await refresher.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testWaiterCancellationAfterDispatchDoesNotCancelSharedCompareAndSave() async throws {
        let original = try session(accessExpiry: date(-1), lease: "lease"), replacement = try credentials(accessExpiry: date(900), lease: "new-lease")
        let store = SessionStore(session: original), refresher = CoalescingRefresher(replacement: replacement)
        let controller = AccountSessionController(credentials: store, refresher: refresher, leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let now = date(0), waiter = Task { await controller.prepare(now: now) }
        await refresher.waitUntilStarted(); waiter.cancel(); await refresher.release()
        let cancelledState = await waiter.value; XCTAssertEqual(cancelledState, .expired)
        XCTAssertEqual(store.session?.credentials, replacement); XCTAssertEqual(store.saveCount, 1)
    }

    func testTwoControllerInstancesCannotOverwriteEachOthersRotatedCredential() async throws {
        let backing = InMemoryAccountSecretStore(), service = "com.marynavdovenko.Plainpost.AccountTests.ControllerRace"
        let firstStore = AccountCredentialStore(secretStore: backing, service: service), secondStore = AccountCredentialStore(secretStore: backing, service: service)
        _ = try firstStore.loadOrCreateDeviceIdentity()
        let (activation, material) = try genesisActivationFixture()
        let original = try credentials(accessExpiry: date(-1), lease: "original"), firstReplacement = try credentials(accessExpiry: date(900), lease: "winner-a"), secondReplacement = try credentials(accessExpiry: date(900), lease: "winner-b")
        try firstStore.commitActivation(activation, credentials: original, genesisMaterial: material)
        let firstRefresher = CoalescingRefresher(replacement: firstReplacement), secondRefresher = CoalescingRefresher(replacement: secondReplacement)
        let first = AccountSessionController(credentials: firstStore, refresher: firstRefresher, leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let second = AccountSessionController(credentials: secondStore, refresher: secondRefresher, leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let now = date(0)
        async let firstState = first.prepare(now: now); async let secondState = second.prepare(now: now)
        await firstRefresher.waitUntilStarted(); await secondRefresher.waitUntilStarted(); await firstRefresher.release(); await secondRefresher.release()
        let firstResult = await firstState, secondResult = await secondState
        XCTAssertEqual([firstResult, secondResult], [.active, .active])
        let stored = try XCTUnwrap(firstStore.loadSession()?.credentials)
        XCTAssertTrue(stored == firstReplacement || stored == secondReplacement)
    }
    func testStaleRejectedRefreshCannotClearNewLoginFromAnotherController() async throws {
        let backing = InMemoryAccountSecretStore(), service = "com.marynavdovenko.Plainpost.AccountTests.ClearRace"
        let staleStore = AccountCredentialStore(secretStore: backing, service: service), loginStore = AccountCredentialStore(secretStore: backing, service: service)
        _ = try staleStore.loadOrCreateDeviceIdentity()
        let (activation, material) = try genesisActivationFixture()
        let original = try credentials(accessExpiry: date(-1), lease: "original"), replacement = try credentials(accessExpiry: date(900), lease: "new-login")
        try staleStore.commitActivation(activation, credentials: original, genesisMaterial: material)
        let refresher = ControlledRejectingRefresher(), controller = AccountSessionController(credentials: staleStore, refresher: refresher, leaseVerifier: { _, _ in nil }, jitter: { _ in 0 })
        let now = date(0), task = Task { await controller.prepare(now: now) }
        await refresher.waitUntilStarted()
        XCTAssertTrue(try loginStore.replaceSession(ifCurrent: original, with: replacement))
        await refresher.release()
        let state = await task.value
        XCTAssertEqual(state, .active)
        XCTAssertEqual(try loginStore.loadSession()?.credentials, replacement)
    }

    private func session(accessExpiry: Date, lease: String) throws -> AccountSession { AccountSession(credentials: try credentials(accessExpiry: accessExpiry, lease: lease)) }
    private func credentials(accessExpiry: Date, lease: String) throws -> AccountSessionCredentials { try AccountSessionCredentials(accountID: PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"), deviceID: AccountDeviceID("11111111-2222-3333-4444-555555555555"), accessToken: "access", accessExpiresAt: accessExpiry, refreshCredential: Data(repeating: 1, count: 32), offlineLease: lease) }
    /// The first element, or nil when none arrives within five seconds.
    private func firstValue<Element: Sendable>(of stream: AsyncStream<Element>) async -> Element? {
        await withTaskGroup(of: Element?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_785_902_400 + seconds) }
}

private actor HostRecordingFailureTransport: AccountHTTPTransport {
    private var recordedHosts: [String] = []
    func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        if let host = request.url?.host { recordedHosts.append(host) }
        return AccountHTTPResponse(statusCode: 500, headers: ["content-type": "application/json"], body: Data("{}".utf8))
    }
    func hosts() -> [String] { recordedHosts }
}

private actor BlockingResponseRendezvous: AccountAdmissionRendezvous {
    let offer: AccountTrustAdmissionOfferEnvelopeV1
    private var responseStarted = false
    private var canceled: Data?

    init(offer: AccountTrustAdmissionOfferEnvelopeV1) { self.offer = offer }
    func listPending() async throws -> [AccountPendingDevice] { [] }
    func submitOffer(_ offer: TrustHandshakeOfferV1, for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 { self.offer }
    func fetchOffer(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 { offer }
    func submitResponse(_ response: AccountTrustAdmissionResponseEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {
        responseStarted = true
        try await Task.sleep(for: .seconds(60))
    }
    func fetchResponse(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionResponseEnvelopeV1 { throw AccountRuntimeError.untrustedResponse }
    func cancel(_ attempt: AccountTrustAdmissionCancelEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws { canceled = attempt.offerDigest }
    func waitUntilResponseStarted() async { while !responseStarted { await Task.yield() } }
    func waitUntilCanceled() async { while canceled == nil { await Task.yield() } }
    func canceledDigest() -> Data? { canceled }
}

private final class SessionStore: AccountCredentialStoring, @unchecked Sendable {
    var session: AccountSession?
    var saveCount = 0
    var localDeletion: AccountLocalDeletionCheckpoint?
    var completedDeletionReceipt: AccountCompletedDeletionReceipt?
    init(session: AccountSession?) { self.session = session }
    func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity { try AccountDeviceIdentity.generate() }
    func loadSession() throws -> AccountSession? { session }
    func saveSession(_ session: AccountSession) throws { saveCount += 1; self.session = session }
    func clearSession() throws { session = nil }
    func commitProvisionalActivation(_ activation: AccountActivation, genesisMaterial: Data?) throws {}
    func loadLocalDeletion() throws -> AccountLocalDeletionCheckpoint? { localDeletion }
    func loadCompletedDeletionReceipt() throws -> AccountCompletedDeletionReceipt? { completedDeletionReceipt }
}

private struct ThrowingSessionStore: AccountCredentialStoring {
    func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity { throw AccountRuntimeError.secretUnavailable }
    func loadLocalDeletion() throws -> AccountLocalDeletionCheckpoint? { nil }
    func loadSession() throws -> AccountSession? { throw AccountRuntimeError.secretUnavailable }
    func saveSession(_ session: AccountSession) throws { throw AccountRuntimeError.secretUnavailable }
    func clearSession() throws { throw AccountRuntimeError.secretUnavailable }
    func commitProvisionalActivation(_ activation: AccountActivation, genesisMaterial: Data?) throws { throw AccountRuntimeError.secretUnavailable }
}

private actor CoalescingRefresher: AccountSessionRefreshing {
    let replacement: AccountSessionCredentials
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    init(replacement: AccountSessionCredentials) { self.replacement = replacement }
    func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials { callCount += 1; if !released { await withCheckedContinuation { continuations.append($0) } }; return replacement }
    func waitUntilStarted() async { while callCount == 0 { await Task.yield() } }
    func release() { released = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
}

private struct TestRefresher: AccountSessionRefreshing {
    let result: Result<AccountSessionCredentials, AccountSessionRefreshFailure>
    func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials { try result.get() }
}

private actor CountingRefresher: AccountSessionRefreshing {
    private(set) var callCount = 0
    func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials {
        callCount += 1
        throw AccountSessionRefreshFailure.network
    }
}

private actor ControlledRejectingRefresher: AccountSessionRefreshing {
    private var started = false, released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials { started = true; if !released { await withCheckedContinuation { continuations.append($0) } }; throw AccountSessionRefreshFailure.rejected }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { released = true; continuations.forEach { $0.resume() }; continuations.removeAll() }
}

@MainActor
private struct AdmissionFixture {
    let now: Date
    let activation: AccountActivation
    let pendingIdentity: AccountDeviceIdentity
    let offerEnvelope: AccountTrustAdmissionOfferEnvelopeV1

    init() throws {
        let accountID = try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff")
        let pendingID = try AccountDeviceID("11111111-2222-3333-4444-555555555555")
        let ownerID = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        pendingIdentity = try AccountDeviceIdentity.generate()
        let ownerIdentity = try AccountDeviceIdentity.generate()
        now = Date(timeIntervalSince1970: 1_800_000_000)
        let offer = try TrustHandshakeOfferV1(
            accountID: accountID, existingDeviceID: ownerID, pendingDeviceID: pendingID,
            existingPublicBundle: ownerIdentity.publicBundle, pendingPublicBundle: pendingIdentity.publicBundle,
            existingNonce: Data(repeating: 7, count: 32),
            createdAtUnixMilliseconds: PositiveUInt64(UInt64(now.timeIntervalSince1970 * 1_000)),
            expiresAtUnixMilliseconds: PositiveUInt64(UInt64(now.addingTimeInterval(300).timeIntervalSince1970 * 1_000))
        )
        offerEnvelope = try AccountWireCodec.decodeAdmissionOfferEnvelope(AccountWireCodec.encodeAdmissionOfferEnvelope(offer))
        activation = AccountActivation(accountID: accountID, deviceID: pendingID, mode: .pending)
    }
}

private final class AdmissionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(by duration: Duration) {
        lock.withLock { value = value.addingTimeInterval(Double(duration.components.seconds)) }
    }
}

/// No offer for the first `emptyFetches` checks (Central answers 409), then the offer.
private actor LateOfferRendezvous: AccountAdmissionRendezvous {
    let offer: AccountTrustAdmissionOfferEnvelopeV1
    private let emptyFetches: Int
    private(set) var fetchCount = 0

    init(offer: AccountTrustAdmissionOfferEnvelopeV1, emptyFetches: Int) {
        self.offer = offer
        self.emptyFetches = emptyFetches
    }
    func listPending() async throws -> [AccountPendingDevice] { [] }
    func submitOffer(_ offer: TrustHandshakeOfferV1, for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 { self.offer }
    func fetchOffer(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionOfferEnvelopeV1 {
        fetchCount += 1
        guard fetchCount > emptyFetches else { throw AccountRuntimeError.untrustedResponse }
        return offer
    }
    func submitResponse(_ response: AccountTrustAdmissionResponseEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {}
    func fetchResponse(for pendingDeviceID: AccountDeviceID) async throws -> AccountTrustAdmissionResponseEnvelopeV1 { throw AccountRuntimeError.untrustedResponse }
    func cancel(_ attempt: AccountTrustAdmissionCancelEnvelopeV1, for pendingDeviceID: AccountDeviceID) async throws {}
}
