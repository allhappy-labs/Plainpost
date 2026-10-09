@preconcurrency import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostDB
import PlainpostOperationRuntime
import PlainpostOperations
@testable import PlainpostService

final class ServiceMailMonitorTests: XCTestCase {
    func testStartIsIdempotentAndSchedulesImmediateSignalForEnabledAccounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let supervisor = IdleSupervisorRecorder()
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )

        await monitor.start()
        await monitor.start()

        XCTAssertEqual(ServiceMailMonitor.fallbackInterval, .seconds(5 * 60))
        try await waitUntil { await signals.count == 1 }
        let reconcileCount = await supervisor.reconcileCount
        let recordedSignals = await signals.values
        XCTAssertEqual(reconcileCount, 1)
        XCTAssertEqual(recordedSignals, [fixture.enabledAccount.id])
        try await waitUntil { sleeps.durations == [.seconds(5 * 60)] }
        await monitor.stop()
    }

    func testStartReturnsWhileImmediateSignalIsStillRunning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let signal = BlockingSignal()
        let completion = Counter()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: IdleSupervisorRecorder(),
            signal: { accountID in await signal.run(accountID) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )
        let start = Task {
            await monitor.start()
            await completion.increment()
        }
        defer {
            Task {
                await signal.release()
                await monitor.stop()
            }
        }

        try await waitUntil { await signal.hasStarted }

        let completedWhileSignalWasBlocked = await completion.value
        XCTAssertEqual(completedWhileSignalWasBlocked, 1)
        await signal.release()
        await start.value
        await monitor.stop()
    }

    func testFallbackSignalsAgainAfterFiveMinuteInterval() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: IdleSupervisorRecorder(),
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }

        sleeps.resumeNext()
        try await waitUntil { await signals.count == 2 }

        let recordedSignals = await signals.values
        XCTAssertEqual(
            recordedSignals,
            [fixture.enabledAccount.id, fixture.enabledAccount.id]
        )
        XCTAssertEqual(sleeps.durations.first, .seconds(5 * 60))
        await monitor.stop()
    }

    func testAccountsChangeReconcilesWatchersAndFallbackMembership() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let center = NotificationCenter()
        let supervisor = IdleSupervisorRecorder()
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: center,
            observeDistributedNotifications: false
        )
        await monitor.start()
        // The fallback loop has signalled once and is parked in its sleep, so
        // the preference change below cannot race its first signal.
        try await waitUntil { sleeps.durations.count == 1 }
        try fixture.store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: fixture.disabledAccount.id,
                realTimeMonitoringEnabled: true
            )
        )

        center.post(
            name: MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: [
                MailStoreChangeSignal.scopeUserInfoKey:
                    MailStoreChangeScope.accounts.rawValue
            ]
        )
        try await waitUntil { await supervisor.reconcileCount == 2 }
        try await waitUntil { await signals.count == 3 }

        // The first fallback signal, then every enabled account in account-ID
        // order ("acc-disabled" sorts before "acc-enabled").
        let recordedSignals = await signals.values
        XCTAssertEqual(recordedSignals, [
            fixture.enabledAccount.id,
            fixture.disabledAccount.id,
            fixture.enabledAccount.id,
        ])
        await monitor.stop()
    }

    func testDistributedAccountsChangeAlsoReconcilesWatchers() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let supervisor = IdleSupervisorRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { _ in },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: true
        )
        await monitor.start()

        DistributedNotificationCenter.default().postNotificationName(
            MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: [
                MailStoreChangeSignal.scopeUserInfoKey:
                    MailStoreChangeScope.accounts.rawValue
            ],
            deliverImmediately: true
        )
        try await waitUntil { await supervisor.reconcileCount >= 2 }

        await monitor.stop()
    }

    func testStopRemovesObserversCancelsFallbackAndJoinsSupervisor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let center = NotificationCenter()
        let supervisor = IdleSupervisorRecorder(blockStop: true)
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let stopFinished = Counter()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: center,
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }

        let stopTask = Task {
            await monitor.stop()
            await stopFinished.increment()
        }
        try await waitUntil { await supervisor.stopCount == 1 }
        let countWhileSupervisorBlocked = await stopFinished.value
        XCTAssertEqual(countWhileSupervisorBlocked, 0)

        center.post(
            name: MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: [
                MailStoreChangeSignal.scopeUserInfoKey:
                    MailStoreChangeScope.accounts.rawValue
            ]
        )
        await supervisor.releaseStop()
        await stopTask.value
        try await Task.sleep(for: .milliseconds(20))

        let reconcileCount = await supervisor.reconcileCount
        let signalCount = await signals.count
        XCTAssertEqual(reconcileCount, 1)
        XCTAssertEqual(signalCount, 1)
        XCTAssertTrue(sleeps.wasCancelled)
    }

    func testFallbackIntervalReconcilesWatchersBeforeSignaling() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let supervisor = IdleSupervisorRecorder()
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }
        let reconcilesBeforeInterval = await supervisor.reconcileCount
        XCTAssertEqual(reconcilesBeforeInterval, 1)

        sleeps.resumeNext()
        try await waitUntil { await signals.count == 2 }
        // Rebuilds watchers a failed reconcile dropped, with no `.accounts` change.
        let reconcilesAfterInterval = await supervisor.reconcileCount
        XCTAssertEqual(reconcilesAfterInterval, 2)
        await monitor.stop()
    }

    func testFallbackSignalsSkipNodeModeAccounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let nodeAccount = account(id: "acc-node", email: "node@example.com")
        try fixture.store.cacheAccounts([nodeAccount])
        try fixture.store.saveSyncPreferences(
            MailSyncPreferences(accountID: nodeAccount.id, realTimeMonitoringEnabled: true)
        )
        try fixture.store.replaceMailSource(
            AccountMailSource.direct(nodeAccount.id).nodeBacked(
                nodeID: "30000000-0000-4000-8000-000000000801",
                logicalMailboxID: String(repeating: "Q", count: 43),
                providerIdentity: "node@example.com"
            ),
            expectedGeneration: 0
        )
        let signals = SignalRecorder()
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: IdleSupervisorRecorder(),
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )

        await monitor.start()
        try await waitUntil { sleeps.durations == [.seconds(5 * 60)] }
        let recordedSignals = await signals.values
        XCTAssertEqual(recordedSignals, [fixture.enabledAccount.id])
        await monitor.stop()
    }

    func testStopJoinsObserverTriggeredSignal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let center = NotificationCenter()
        let supervisor = IdleSupervisorRecorder()
        let sleeps = SleepController()
        let signal = ObserverSignalGate()
        let stopReturned = expectation(description: "stop must join the admitted observer signal")
        stopReturned.isInverted = true
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signal.run(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: center,
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }
        postAccountsChanged(center)
        try await waitUntil { await signal.values.count == 2 }

        let stop = Task {
            await monitor.stop()
            stopReturned.fulfill()
        }
        // Cancellation proves shutdown has closed admission. The observer's
        // signal is still held; the fallback has never left its first sleep.
        try await waitUntil { sleeps.wasCancelled }
        await fulfillment(of: [stopReturned], timeout: 0.1)
        let earlySupervisorStops = await supervisor.stopCount
        XCTAssertEqual(earlySupervisorStops, 0, "supervisor shutdown must follow admitted work")
        postAccountsChanged(center)
        await signal.release()
        await stop.value
        postAccountsChanged(center)
        await monitor.start() // A stopped instance is intentionally one-shot.
        await monitor.stop()
        let reconciles = await supervisor.reconcileCount
        let values = await signal.values
        let stops = await supervisor.stopCount
        XCTAssertEqual(reconciles, 2)
        XCTAssertEqual(values, [fixture.enabledAccount.id, fixture.enabledAccount.id])
        XCTAssertEqual(stops, 1)
    }

    func testAccountChangesCoalesceAndSignalLatestMembership() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let center = NotificationCenter()
        let supervisor = IdleSupervisorRecorder()
        let sleeps = SleepController()
        let overlappingSignal = expectation(description: "observer signals must not overlap")
        overlappingSignal.isInverted = true
        let signal = ObserverSignalGate(onOverlap: { overlappingSignal.fulfill() })
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signal.run(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: center,
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }
        postAccountsChanged(center)
        try await waitUntil { await signal.values.count == 2 }
        // The first pass captured the old enabled set before entering signal.
        // Signals during this suspension must retain a follow-up account read.
        try fixture.store.saveSyncPreferences(MailSyncPreferences(
            accountID: fixture.enabledAccount.id, realTimeMonitoringEnabled: false
        ))
        try fixture.store.saveSyncPreferences(MailSyncPreferences(
            accountID: fixture.disabledAccount.id, realTimeMonitoringEnabled: true
        ))
        for _ in 0..<20 { postAccountsChanged(center) }
        await fulfillment(of: [overlappingSignal], timeout: 0.1)
        let heldReconciles = await supervisor.reconcileCount
        XCTAssertEqual(heldReconciles, 2)
        await signal.release()
        try await waitUntil { await signal.values.contains(fixture.disabledAccount.id) }
        await monitor.stop()
        let values = await signal.values
        let reconciles = await supervisor.reconcileCount
        XCTAssertEqual(values, [fixture.enabledAccount.id, fixture.enabledAccount.id, fixture.disabledAccount.id])
        XCTAssertEqual(reconciles, 3)
    }

    func testOverlappingStopsBothJoinSupervisor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let supervisor = IdleSupervisorRecorder(blockStop: true)
        let sleeps = SleepController()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { _ in },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )
        await monitor.start()
        try await waitUntil { sleeps.durations.count == 1 }
        let first = Task { await monitor.stop() }
        try await waitUntil { await supervisor.stopCount == 1 }
        let secondReturned = expectation(description: "every stop caller joins shutdown")
        secondReturned.isInverted = true
        let second = Task {
            await monitor.stop()
            secondReturned.fulfill()
        }
        await fulfillment(of: [secondReturned], timeout: 0.1)
        await supervisor.releaseStop()
        await first.value
        await second.value
        let stops = await supervisor.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testStopJoinsStartupReconciliationBeforeStoppingSupervisor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let supervisor = IdleSupervisorRecorder(blockReconcile: true)
        let sleeps = SleepController()
        let signals = SignalRecorder()
        let monitor = ServiceMailMonitor(
            store: fixture.store,
            idleSupervisor: supervisor,
            signal: { accountID in await signals.record(accountID) },
            sleep: { duration in try await sleeps.sleep(duration) },
            notificationCenter: NotificationCenter(),
            observeDistributedNotifications: false
        )
        let start = Task { await monitor.start() }
        try await waitUntil { await supervisor.reconcileCount == 1 }
        let stopReturned = expectation(description: "shutdown must join startup reconciliation")
        stopReturned.isInverted = true
        let stop = Task {
            await monitor.stop()
            stopReturned.fulfill()
        }
        await fulfillment(of: [stopReturned], timeout: 0.1)
        let earlyStops = await supervisor.stopCount
        XCTAssertEqual(earlyStops, 0)
        await supervisor.releaseReconcile()
        await start.value
        await stop.value
        let lateWatchers = await supervisor.activeWatchers
        let stops = await supervisor.stopCount
        let values = await signals.values
        XCTAssertEqual(lateWatchers, 0, "late startup reconciliation must not recreate stopped watchers")
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(values, [])
        XCTAssertEqual(sleeps.durations, [])
        await monitor.start()
        let reconciles = await supervisor.reconcileCount
        XCTAssertEqual(reconciles, 1)
    }

    private func postAccountsChanged(_ center: NotificationCenter) {
        center.post(
            name: MailStoreChangeSignal.notificationName,
            object: nil,
            userInfo: [MailStoreChangeSignal.scopeUserInfoKey: MailStoreChangeScope.accounts.rawValue]
        )
    }

    private func makeFixture() throws -> (
        store: SQLiteMailStore,
        enabledAccount: Account,
        disabledAccount: Account,
        url: URL
    ) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-service-monitor-\(UUID().uuidString).sqlite"
        )
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let enabledAccount = account(id: "acc-enabled", email: "enabled@example.com")
        let disabledAccount = account(id: "acc-disabled", email: "disabled@example.com")
        try store.cacheAccounts([enabledAccount, disabledAccount])
        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: enabledAccount.id,
                realTimeMonitoringEnabled: true
            )
        )
        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: disabledAccount.id,
                realTimeMonitoringEnabled: false
            )
        )
        return (store, enabledAccount, disabledAccount, url)
    }

    private func account(id: String, email: String) -> Account {
        Account(
            id: AccountID(id),
            displayName: id,
            email: EmailAddress(email),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor IdleSupervisorRecorder: IMAPIdleSupervising {
    private(set) var reconcileCount = 0
    private(set) var stopCount = 0
    private let blockStop: Bool
    private let blockReconcile: Bool
    private(set) var activeWatchers = 0
    private var reconcileContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(blockStop: Bool = false, blockReconcile: Bool = false) {
        self.blockStop = blockStop
        self.blockReconcile = blockReconcile
    }

    func reconcileAccounts() async {
        reconcileCount += 1
        if blockReconcile {
            await withCheckedContinuation { reconcileContinuation = $0 }
        }
        // Like the real supervisor, reconciliation may install watchers after
        // awaiting the departure of old watchers.
        activeWatchers = 1
    }

    func releaseReconcile() {
        reconcileContinuation?.resume()
        reconcileContinuation = nil
    }

    func stop() async {
        stopCount += 1
        activeWatchers = 0
        guard blockStop else { return }
        await withCheckedContinuation { stopContinuation = $0 }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor SignalRecorder {
    private(set) var values: [AccountID] = []
    var count: Int { values.count }

    func record(_ accountID: AccountID) {
        values.append(accountID)
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor BlockingSignal {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_: AccountID) async {
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SleepController: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var recordedDurations: [Duration] = []
    private var waiters: [Waiter] = []
    private var cancelled = false

    var durations: [Duration] { lock.withLock { recordedDurations } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    recordedDurations.append(duration)
                    if cancelled { return true }
                    waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            self.cancel(id: id)
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        let waiter = lock.withLock {
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        waiter?.continuation.resume()
    }

    private func cancel(id: UUID) {
        let waiter: Waiter? = lock.withLock {
            cancelled = true
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume()
    }
}

private actor ObserverSignalGate {
    private(set) var values: [AccountID] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let onOverlap: @Sendable () -> Void

    init(onOverlap: @escaping @Sendable () -> Void = {}) {
        self.onOverlap = onOverlap
    }

    func run(_ accountID: AccountID) async {
        values.append(accountID)
        guard values.count > 1, !released else { return }
        if continuations.count == 1 { onOverlap() }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
