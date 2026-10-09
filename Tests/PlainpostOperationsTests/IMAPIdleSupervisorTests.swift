import Foundation
import XCTest
import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets

final class IMAPIdleSupervisorTests: XCTestCase {
    func testMailboxChangeSignalsExactlyOnce() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let script = IdleScript(outcomes: [.mailboxChanged])
        let signals = AccountSignalRecorder()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { accountID in await signals.record(accountID) },
            clientFactory: { _, _ in IMAPClientProbe(script: script) },
            sleep: { duration in try await Task.sleep(for: duration) }
        )

        await supervisor.reconcileAccounts()
        try await waitUntil { await signals.count == 1 }
        await supervisor.stop()

        let recordedSignals = await signals.values
        XCTAssertEqual(recordedSignals, [fixture.account.id])
    }

    func testRenewalReconnectsWithoutSignaling() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let script = IdleScript(outcomes: [.renewalDue])
        let signals = AccountSignalRecorder()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { accountID in await signals.record(accountID) },
            clientFactory: { _, _ in IMAPClientProbe(script: script) },
            sleep: { duration in try await Task.sleep(for: duration) }
        )

        await supervisor.reconcileAccounts()
        try await waitUntil { await script.callCount >= 2 }
        await supervisor.stop()

        let signalCount = await signals.count
        XCTAssertEqual(signalCount, 0)
    }

    func testUnsupportedIdleSignalsThenWaitsSixtySeconds() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let script = IdleScript(outcomes: [.unsupported])
        let signals = AccountSignalRecorder()
        let sleeps = DurationRecorder()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { accountID in await signals.record(accountID) },
            clientFactory: { _, _ in IMAPClientProbe(script: script) },
            sleep: { duration in try await sleeps.sleep(duration) }
        )

        await supervisor.reconcileAccounts()
        try await waitUntil { await sleeps.values == [.seconds(60)] }
        await supervisor.stop()

        let recordedSignals = await signals.values
        XCTAssertEqual(recordedSignals, [fixture.account.id])
    }

    func testGoogleAccountAwaitingReauthorizationWaitsWithoutConnecting() async throws {
        let fixture = try await makeFixture(googleAccount: true)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try fixture.store.setAccountAuthentication(
            accountID: fixture.account.id, method: .googleOAuth, state: .reauthorizationRequired)
        let connections = Counter()
        let sleeps = DurationRecorder()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { _ in },
            clientFactory: { _, _ in
                Task { await connections.increment() }
                return IMAPClientProbe(script: IdleScript())
            },
            sleep: { duration in try await sleeps.sleep(duration) }
        )

        await supervisor.reconcileAccounts()
        try await waitUntil { await sleeps.values.count >= 1 }
        await supervisor.stop()

        let recordedSleeps = await sleeps.values
        XCTAssertEqual(recordedSleeps, [.seconds(30)])
        let connectionCount = await connections.value
        XCTAssertEqual(connectionCount, 0)
    }

    func testReconcileCancelsAndJoinsDisabledAccountWatcher() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let script = IdleScript()
        let disconnects = Counter()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { _ in },
            clientFactory: { _, _ in
                IMAPClientProbe(script: script) { await disconnects.increment() }
            },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        await supervisor.reconcileAccounts()
        try await waitUntil { await script.callCount == 1 }
        try fixture.store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: fixture.account.id,
                realTimeMonitoringEnabled: false
            )
        )

        await supervisor.reconcileAccounts()

        let disconnectCount = await disconnects.value
        XCTAssertEqual(disconnectCount, 1)
        await supervisor.stop()
    }

    func testReconcileCancelsAndJoinsDeletedAccountWatcher() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let script = IdleScript()
        let disconnects = Counter()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { _ in },
            clientFactory: { _, _ in
                IMAPClientProbe(script: script) { await disconnects.increment() }
            },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        await supervisor.reconcileAccounts()
        try await waitUntil { await script.callCount == 1 }
        try await fixture.store.deleteAccountData(
            accountID: fixture.account.id,
            credentials: fixture.credentials
        )

        await supervisor.reconcileAccounts()

        let disconnectCount = await disconnects.value
        XCTAssertEqual(disconnectCount, 1)
        await supervisor.stop()
    }

    func testStopJoinsWatcherAndNoSignalCanEscapeAfterReturn() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let controlledIdle = ControlledIdle()
        let signals = AccountSignalRecorder()
        let stopped = Counter()
        let supervisor = IMAPIdleSupervisor(
            store: fixture.store,
            credentials: fixture.credentials,
            signal: { accountID in await signals.record(accountID) },
            clientFactory: { _, _ in IMAPClientProbe(controlledIdle: controlledIdle) },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        await supervisor.reconcileAccounts()
        try await waitUntil { controlledIdle.hasStarted }

        let stopTask = Task {
            await supervisor.stop()
            await stopped.increment()
        }
        try await waitUntil { controlledIdle.wasCancelled }
        let countBeforeRelease = await stopped.value
        XCTAssertEqual(countBeforeRelease, 0)

        controlledIdle.release()
        await stopTask.value
        try await Task.sleep(for: .milliseconds(20))

        let countAfterRelease = await stopped.value
        let signalCount = await signals.count
        XCTAssertEqual(countAfterRelease, 1)
        XCTAssertEqual(signalCount, 0)
    }

    private func makeFixture(googleAccount: Bool = false) async throws -> (
        store: SQLiteMailStore,
        credentials: InMemoryCredentialVault,
        account: Account,
        url: URL
    ) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-idle-supervisor-\(UUID().uuidString).sqlite"
        )
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = googleAccount
            ? MailProviderProfile.gmail.makeGoogleAccount(
                displayName: "Idle Gmail", email: EmailAddress("idle@gmail.com")
            )
            : Account(
                id: AccountID("acc-idle"), displayName: "Idle Account",
                email: EmailAddress("idle@example.com"), username: "idle@example.com",
                imapHost: "imap.example.com", smtpHost: "smtp.example.com"
            )
        try store.cacheAccounts([account])
        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: account.id,
                realTimeMonitoringEnabled: true
            )
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("secret".utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):imap-password"
            )
        )
        return (store, credentials, account, url)
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

private actor IdleScript {
    private var outcomes: [IMAPIdleOutcome]
    private(set) var callCount = 0

    init(outcomes: [IMAPIdleOutcome] = []) {
        self.outcomes = outcomes
    }

    func next() async throws -> IMAPIdleOutcome {
        callCount += 1
        if !outcomes.isEmpty {
            return outcomes.removeFirst()
        }
        try await Task.sleep(for: .seconds(300))
        throw CancellationError()
    }
}

private actor AccountSignalRecorder {
    private(set) var values: [AccountID] = []
    var count: Int { values.count }

    func record(_ accountID: AccountID) {
        values.append(accountID)
    }
}

private actor DurationRecorder {
    private(set) var values: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        values.append(duration)
        try await Task.sleep(for: .seconds(300))
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class ControlledIdle: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false
    private var released = false

    var hasStarted: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func wait() async throws -> IMAPIdleOutcome {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    started = true
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            try Task.checkCancellation()
            return .renewalDue
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class IMAPClientProbe: IMAPClientProtocol, @unchecked Sendable {
    private let script: IdleScript?
    private let controlledIdle: ControlledIdle?
    private let onDisconnect: @Sendable () async -> Void

    init(
        script: IdleScript,
        onDisconnect: @escaping @Sendable () async -> Void = {}
    ) {
        self.script = script
        controlledIdle = nil
        self.onDisconnect = onDisconnect
    }

    init(controlledIdle: ControlledIdle) {
        script = nil
        self.controlledIdle = controlledIdle
        onDisconnect = {}
    }

    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { [] }
    func selectMailbox(_ path: String) async throws -> String { path }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func setFlags(
        uid: Int,
        add: [String],
        remove: [String],
        expectedModSequence: Int?
    ) async throws {}
    func setLabels(uid: Int, add: [String], remove: [String]) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(
        to mailbox: String,
        flags: [String],
        data: String
    ) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }

    func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome {
        if let script { return try await script.next() }
        guard let controlledIdle else { return .unsupported }
        return try await controlledIdle.wait()
    }

    func disconnect() async {
        await onDisconnect()
    }
}
