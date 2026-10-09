import Foundation
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
@testable import PlainpostService

final class DirectSyncGatingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Honoured when the runner enables test timeouts.
        executionTimeAllowance = 60
    }

    func testNodeModeAccountGetsNoIdleWatcherNoScheduledJobAndNoDirectRemoteAction() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-direct", "acc-node"])
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        await harness.idleSupervisor.reconcileAccounts()
        let watchedAccountIDs = await harness.watchedAccountIDs()
        XCTAssertEqual(watchedAccountIDs, ["acc-direct"])
        try harness.runtime.enqueueScheduledSyncJobs()
        XCTAssertEqual(try harness.queuedInboxSyncAccountIDs(), ["acc-direct"])

        // Direct seams only; Task 16 routes the service's perform(.archive) for Node-backed accounts through the router.
        await XCTAssertThrowsErrorAsync(try await harness.operations.performRemoteMailAction(
            .archive, messageID: harness.messageID(account: "acc-node"), archiveMailbox: "Archive")) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .invalidRequest)
        }
        try harness.enqueueMailboxArchiveJob(account: "acc-node")
        await XCTAssertThrowsErrorAsync(try await harness.runtime.processNextJob()) {   // executes reconcileMailboxArchive
            XCTAssertEqual($0 as? PlainpostError, .validationFailed("This account's mail is handled by the Sync Node."))
        }
        try await harness.waitUntil { harness.imapLoginCount(account: "acc-direct") > 0 }
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
        await harness.stopIdleSupervisor()
    }

    func testFallbackModeKeepsEveryDirectPath() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"])
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .fallback)
        await harness.idleSupervisor.reconcileAccounts()
        let watchedAccountIDs = await harness.watchedAccountIDs()
        XCTAssertEqual(watchedAccountIDs, ["acc-node"])
        try harness.runtime.enqueueScheduledSyncJobs()
        XCTAssertEqual(try harness.queuedInboxSyncAccountIDs(), ["acc-node"])
        try harness.enqueueMailboxArchiveJob(account: "acc-node")
        _ = try await harness.runtime.processNextJob()
        XCTAssertEqual(harness.archiveCount(account: "acc-node"), 1)
        await harness.stopIdleSupervisor()
    }

    func testMailboxFlagRefusesNodeModeBeforeLogin() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"])
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        try harness.enqueueMailboxFlagJob(account: "acc-node")
        await XCTAssertThrowsErrorAsync(try await harness.runtime.processNextJob()) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed("This account's mail is handled by the Sync Node."))
        }
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testInboxSyncForNodeModeAccountCompletesAsSkippedWithoutCredentials() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"], storeCredentials: false)
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        let syncRuntime = LocalOperationRuntime(
            store: harness.store, credentials: harness.credentials, allowedJobKinds: [.inboxSync])
        try syncRuntime.enqueueRealtimeSyncIfNeeded(accountID: AccountID("acc-node"))
        let job = try await syncRuntime.processNextJob()
        XCTAssertEqual(job?.state, .completed)
        XCTAssertEqual(job?.progress?.phase, "skipped-node-mode")
        XCTAssertNil(job?.pauseReason)
    }

    func testSkippedHistoricalSyncReportsItsRealSource() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"], storeCredentials: false)
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        let syncRuntime = LocalOperationRuntime(
            store: harness.store, credentials: harness.credentials, allowedJobKinds: [.inboxSync, .historicalSync])
        _ = try harness.store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: AccountID("acc-node"), trigger: .manual, scope: .completeHistory))
        let processed = try await syncRuntime.processNextJob()
        let job = try XCTUnwrap(processed)
        XCTAssertEqual(job.progress?.phase, "skipped-node-mode")
        let artifact = try harness.store.durableOperationArtifact(id: XCTUnwrap(job.resultArtifactID))
        let result = try JSONDecoder().decode(PlainpostInboxSyncResult.self, from: Data(artifact.payloadJSON.utf8))
        XCTAssertEqual(result.source, .historicalBackfill)
        XCTAssertEqual(result.syncedMessageCount, 0)
    }

    func testUnreadableSourceFailsTheSyncInsteadOfSkippingIt() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"], storeCredentials: false)
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        let syncRuntime = LocalOperationRuntime(
            store: harness.store, credentials: harness.credentials, allowedJobKinds: [.inboxSync])
        try syncRuntime.enqueueRealtimeSyncIfNeeded(accountID: AccountID("acc-node"))
        try await harness.store.databasePool.write { database in try database.execute(sql: "DROP TABLE account_mail_sources") }

        await XCTAssertThrowsErrorAsync(try await syncRuntime.processNextJob()) { _ in }
        let job = try XCTUnwrap(try harness.store.jobs(limit: 10).first { $0.kind == .inboxSync })
        XCTAssertNotEqual(job.state, .completed)
        XCTAssertNotEqual(job.progress?.phase, "skipped-node-mode")
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
    }

    func testSourceReadErrorRetriesDirectFlagAndArchiveJobsInsteadOfRefusing() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-direct"])
        defer { harness.cleanup() }
        try harness.enqueueMailboxFlagJob(account: "acc-direct")
        try harness.enqueueMailboxArchiveJob(account: "acc-direct")
        try await harness.hideMailSources()

        for kind in [PlainpostOperationKind.mailboxFlag, .mailboxArchive] {
            await XCTAssertThrowsErrorAsync(try await harness.runtime.processNextJob()) {
                XCTAssertNil($0 as? PlainpostError, "\(kind): a read error must not become a permanent refusal")
            }
            let job = try XCTUnwrap(try harness.store.jobs(limit: 10).first { $0.kind == kind })
            XCTAssertEqual(job.state, .queued, "\(kind) must be scheduled for retry")
            XCTAssertFalse(job.errorMessage?.contains("Sync Node") ?? false)
        }
        // The service's direct archive surfaces the read error, not invalidRequest.
        await XCTAssertThrowsErrorAsync(try await harness.operations.performRemoteMailAction(
            .archive, messageID: harness.messageID(account: "acc-direct"), archiveMailbox: "Archive")) {
            XCTAssertNotEqual($0 as? PlainpostServiceClientError, .invalidRequest)
        }
        XCTAssertEqual(harness.imapLoginCount(account: "acc-direct"), 0)
    }

    func testIdleWatcherSurvivesASourceReadErrorAndResumes() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-direct"], idleRenewal: .milliseconds(20))
        defer { harness.cleanup() }
        await harness.idleSupervisor.reconcileAccounts()
        try await harness.waitUntil { harness.imapLoginCount(account: "acc-direct") > 0 }

        try await harness.hideMailSources()
        try await Task.sleep(for: .milliseconds(200))
        let watchedDuringOutage = await harness.watchedAccountIDs()
        XCTAssertEqual(watchedDuringOutage, ["acc-direct"])
        let loginsDuringOutage = harness.imapLoginCount(account: "acc-direct")

        try await harness.restoreMailSources()
        try await harness.waitUntil(timeout: .seconds(10)) {
            harness.imapLoginCount(account: "acc-direct") > loginsDuringOutage + 1
        }
        let watchedAfter = await harness.watchedAccountIDs()
        XCTAssertEqual(watchedAfter, ["acc-direct"])
        await harness.stopIdleSupervisor()
    }

    func testIdleWatcherEndsWhenAccountFlipsToNodeWithinOneRenewal() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"], idleRenewal: .milliseconds(20))
        defer { harness.cleanup() }
        await harness.idleSupervisor.reconcileAccounts()
        try await harness.waitUntil { harness.imapLoginCount(account: "acc-node") > 0 }

        // No reconcile: the watch loop itself must notice the flip.
        try harness.markNodeBacked("acc-node", mode: .node)
        try await harness.waitUntilAsync { await harness.watchedAccountIDs().isEmpty }
        let settled = harness.imapLoginCount(account: "acc-node")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), settled)
        await harness.stopIdleSupervisor()
    }

    func testReconcileCancelsAWatcherBlockedInIdleWhenAccountFlipsToNode() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"])
        defer { harness.cleanup() }
        await harness.idleSupervisor.reconcileAccounts()
        try await harness.waitUntil { harness.imapLoginCount(account: "acc-node") > 0 }
        try harness.markNodeBacked("acc-node", mode: .node)
        await harness.idleSupervisor.reconcileAccounts()
        let watchedAccountIDs = await harness.watchedAccountIDs()
        XCTAssertEqual(watchedAccountIDs, [])
    }

    func testServiceDirectPathsRefuseNodeModeAccounts() async throws {
        let harness = try await DirectSyncGatingHarness(accounts: ["acc-node"])
        defer { harness.cleanup() }
        try harness.markNodeBacked("acc-node", mode: .node)
        let draft = try harness.createDraft(account: "acc-node")
        await harness.operations.reopenRuntimeConstruction()

        // Task 16: a Node-backed account's draft save and send go to the
        // mail-intent router; without one they cannot be routed and never
        // fall back to the direct path.
        await XCTAssertThrowsErrorAsync(try await harness.operations.syncDraftToServer(
            draftID: draft.id.rawValue, mailbox: "Drafts")) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .nodeSession(.unavailable))
        }
        await XCTAssertThrowsErrorAsync(try await harness.operations.perform(.deliverDirectDraft(
            PlainpostDirectDraftDeliveryPayload(draftID: draft.id.rawValue, expectedHash: draft.contentHash, actorID: "local-user")))) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .nodeSession(.unavailable))
        }
        await XCTAssertThrowsErrorAsync(try await harness.operations.performSmartInboxBatch(
            PlainpostSmartInboxBatchRequest(accountID: "acc-node", category: "seen", action: "archive_read", archiveMailbox: "Archive"))) {
            XCTAssertEqual($0 as? PlainpostServiceClientError, .invalidRequest)
        }

        // A realtime signal for a Node-mode account enqueues no direct sync.
        try await harness.operations.handleRealtimeMailSignal(accountID: AccountID("acc-node"))
        XCTAssertEqual(try harness.inboxSyncJobAccountIDs(), [])
        XCTAssertEqual(harness.imapLoginCount(account: "acc-node"), 0)
        await harness.operations.beginVaultLockdown()
    }
}

private final class DirectSyncGatingHarness: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMailStore
    let credentials = InMemoryCredentialVault()
    let idleSupervisor: IMAPIdleSupervisor
    let runtime: LocalOperationRuntime
    let operations: PlainpostServiceOperations
    private let recorder = GatingIMAPRecorder()
    private var messageIDs: [String: MessageID] = [:]

    init(
        accounts: [String],
        storeCredentials: Bool = true,
        idleRenewal: Duration? = nil
    ) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-sync-gating-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        let cached = accounts.map { id in
            Account(
                id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.test"),
                username: "\(id)@example.test", imapHost: Self.host(for: id), smtpHost: "smtp.\(id).example.test")
        }
        try store.cacheAccounts(cached)
        for account in cached {
            try store.saveSyncPreferences(MailSyncPreferences(accountID: account.id, realTimeMonitoringEnabled: true))
            if storeCredentials {
                try await credentials.store(
                    Data("test-only-password".utf8),
                    for: CredentialRecordKey(rawValue: "account:\(account.id.rawValue):imap-password"))
            }
            let rfcMessageID = "<m-\(account.id.rawValue)@example.test>"
            let message = MessageSummary(
                id: MessageID(IMAPSyncService.canonicalMessageID(accountID: account.id, rfcMessageID: rfcMessageID)),
                threadID: nil, from: EmailAddress("a@example.test"), subject: "Hi", preview: "Hi", smartCategory: .personal,
                labels: [], isSeen: true, mailboxPath: "INBOX", isDeleted: false, body: "Hi", rfcMessageID: rfcMessageID)
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 42, notificationDisposition: .ineligible)
            messageIDs[account.id.rawValue] = message.id
        }
        let recorder = recorder
        idleSupervisor = IMAPIdleSupervisor(
            store: store,
            credentials: credentials,
            signal: { _ in },
            clientFactory: { host, _ in GatingIMAPClient(host: host, recorder: recorder, idleRenewal: idleRenewal) },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.mailboxArchive, .mailboxFlag],
            mailboxFlagClientFactory: { account in
                GatingIMAPClient(host: account.imapHost, recorder: recorder, idleRenewal: idleRenewal)
            }
        )
        let assembly = SQLiteCredentialVaultAssembly(store: store, provider: GatingVaultKeyProvider())
        try await assembly.unlockForeground(prompt: "Test-only in-memory vault unlock")
        operations = PlainpostServiceOperations(
            applicationSupportURL: directory,
            store: store,
            assembly: assembly,
            backgroundJobWakeScheduler: NoopBackgroundJobWakeScheduler(),
            mailMonitorFactory: { _ in GatingNoopMailMonitor() }
        )
    }

    static func host(for accountID: String) -> String { "imap.\(accountID).example.test" }

    /// Stops the IDLE supervisor, failing the test instead of hanging when a
    /// watcher does not end within 5 s.
    func stopIdleSupervisor(file: StaticString = #filePath, line: UInt = #line) async {
        let done = GatingStopFlag()
        let supervisor = idleSupervisor
        Task {
            await supervisor.stop()
            done.set()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !done.isSet {
            guard ContinuousClock.now < deadline else {
                XCTFail("IMAPIdleSupervisor.stop() did not finish within 5 s", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func markNodeBacked(_ accountID: String, mode: NodeBackedMode) throws {
        let current = try store.mailSource(accountID: AccountID(accountID))
        var next = current.kind == .nodeBacked ? current : try store.replaceMailSource(
            current.nodeBacked(
                nodeID: "30000000-0000-4000-8000-000000000801",
                logicalMailboxID: Self.logicalMailboxID(for: accountID),
                providerIdentity: "\(accountID)@example.test"),
            expectedGeneration: current.generation)
        if next.mode != mode {
            next = try store.replaceMailSource(next.withMode(mode), expectedGeneration: next.generation)
        }
    }

    private static func logicalMailboxID(for accountID: String) -> String {
        let seed = accountID.unicodeScalars.map { String(format: "%02x", $0.value & 0x3f) }.joined()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let characters = seed.unicodeScalars.map { alphabet[Int($0.value) % alphabet.count] }
        return String((characters + Array(repeating: "A", count: 43)).prefix(43))
    }

    func hideMailSources() async throws {
        try await store.databasePool.write { database in
            try database.execute(sql: "ALTER TABLE account_mail_sources RENAME TO account_mail_sources_hidden")
        }
    }

    func restoreMailSources() async throws {
        try await store.databasePool.write { database in
            try database.execute(sql: "ALTER TABLE account_mail_sources_hidden RENAME TO account_mail_sources")
        }
    }

    func watchedAccountIDs() async -> [String] {
        await idleSupervisor.watchedAccountIDs.map(\.rawValue).sorted()
    }

    func messageID(account: String) -> MessageID {
        messageIDs[account]!
    }

    func imapLoginCount(account: String) -> Int {
        recorder.logins(host: Self.host(for: account))
    }

    func archiveCount(account: String) -> Int {
        recorder.archives(host: Self.host(for: account))
    }

    func queuedInboxSyncAccountIDs() throws -> [String] {
        try store.jobs(limit: 100)
            .filter { $0.kind == .inboxSync && $0.state == .queued }
            .map { try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data($0.payloadJSON.utf8)).accountID.rawValue }
            .sorted()
    }

    func inboxSyncJobAccountIDs() throws -> [String] {
        try store.jobs(limit: 100)
            .filter { $0.kind == .inboxSync }
            .map { try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data($0.payloadJSON.utf8)).accountID.rawValue }
            .sorted()
    }

    func enqueueMailboxArchiveJob(account: String) throws {
        let input = PlainpostMailboxArchiveInput(
            messageID: messageID(account: account), accountID: AccountID(account),
            sourceMailboxPath: "INBOX", destinationMailboxPath: "Archive", uidValidity: 7, uid: 42)
        _ = try store.enqueueJob(PlainpostJobRequest(
            kind: .mailboxArchive,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: "gating-archive-\(account)"))
    }

    func enqueueMailboxFlagJob(account: String) throws {
        let input = PlainpostMailboxFlagInput(
            messageID: messageID(account: account), accountID: AccountID(account),
            mailboxPath: "INBOX", uidValidity: 7, uid: 42, desiredSeen: false)
        _ = try store.enqueueJob(PlainpostJobRequest(
            kind: .mailboxFlag,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: "gating-flag-\(account)"))
    }

    func createDraft(account: String) throws -> Draft {
        try store.createDraft(
            Draft(
                id: DraftID("drf_gating_\(account)"), accountID: AccountID(account),
                from: EmailAddress("\(account)@example.test"), to: [EmailAddress("to@example.test")],
                cc: [], bcc: [], subject: "Gating", bodyPlain: "Body", createdBy: "local-user",
                aiGenerated: false, sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
    }

    func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        try await waitUntilAsync(timeout: timeout) { predicate() }
    }

    func waitUntilAsync(
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

private final class GatingStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class GatingIMAPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loginCounts: [String: Int] = [:]
    private var archiveCounts: [String: Int] = [:]

    func recordLogin(host: String) { lock.withLock { loginCounts[host, default: 0] += 1 } }
    func recordArchive(host: String) { lock.withLock { archiveCounts[host, default: 0] += 1 } }
    func logins(host: String) -> Int { lock.withLock { loginCounts[host] ?? 0 } }
    func archives(host: String) -> Int { lock.withLock { archiveCounts[host] ?? 0 } }
}

private struct GatingIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    let host: String
    let recorder: GatingIMAPRecorder
    let idleRenewal: Duration?

    func login(username: String, password: String) async throws { recorder.recordLogin(host: host) }
    /// The server's folders: the account has an Archive to move to.
    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(id: MailboxID("\(host)-archive"), accountID: AccountID(host), name: "Archive", path: "Archive", specialUse: "\\Archive")]
    }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 7] UIDs valid" }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws { recorder.recordArchive(host: host) }
    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        recorder.recordArchive(host: host)
        return IMAPMoveResult(mailbox: mailbox, uidValidity: nil, uid: nil)
    }
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }

    func idle(maxDuration: TimeInterval) async throws -> IMAPIdleOutcome {
        // A short default renewal keeps a watcher from parking a test for an
        // hour when a cancellation is missed.
        try await Task.sleep(for: idleRenewal ?? .seconds(min(maxDuration, 2)))
        return .renewalDue
    }
}

private actor GatingVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x53, count: 32)
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { key }
    func countMatchingItems() async throws -> Int { 1 }
}

private actor GatingNoopMailMonitor: ServiceMailMonitoring {
    func start() {}
    func stop() {}
}

private actor NoopBackgroundJobWakeScheduler: BackgroundJobWakeScheduling {
    func replaceWake(at date: Date?, action: @escaping @Sendable () async -> Void) {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
