import Foundation
import SQLite3
import XCTest
@testable import PlainpostAI
import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
@testable import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostTestSupport

final class LocalOperationsTests: XCTestCase {
    func testRecentInboxJobWithCompleteHistoryPreferenceFetchesNewestFirstWithoutLosingOldUIDs() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        try store.saveSyncPreferences(.init(
            accountID: account.id, downloadCompleteHistory: true, recentMessageLimit: 2
        ))
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("synthetic-fixture".utf8), for: accountIMAPPasswordKey(account.id))
        let client = RuntimeHistoryFreshnessClient()
        let job = try store.enqueueCoalescedInboxSyncJob(.init(
            accountID: account.id, trigger: .manual, scope: .recent, expectedDirectSourceGeneration: 1
        ))
        let scope = try XCTUnwrap(store.syncExecutionScope(jobID: job.id))
        XCTAssertTrue(scope.downloadCompleteHistory)
        XCTAssertFalse(scope.incrementalOnly)
        let runtime = LocalOperationRuntime(
            store: store, credentials: vault, allowedJobKinds: [.inboxSync, .historicalSync],
            requireExplicitDirectSource: true, selectedDirectAccountID: account.id,
            expectedDirectSourceGeneration: 1, requireSelectedDirectClaimScope: true,
            inboxSyncClientFactory: { _, _ in client }
        )
        let next = try await runtime.processNextJob()
        let processed = try XCTUnwrap(next)
        let fetched = await client.fetchedUIDs
        XCTAssertEqual(fetched.first, 5)
        XCTAssertEqual(Set(fetched), Set(1...5))
        XCTAssertEqual(processed.id, job.id)
        XCTAssertEqual(processed.state, .completed)
        XCTAssertEqual(try store.cachedUIDs(
            accountID: account.id, mailboxPath: "INBOX", uidValidity: 7
        ), Set(1...5))
        XCTAssertEqual(try store.mailSource(accountID: account.id).generation, 1)
    }

    /// iOS has no helper process: the device-wide worker in the app runs read-state
    /// write-back, or it stays "Waiting for the background worker" forever.
    func testInProcessWorkerDrainsADeviceWideMailboxFlagJob() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: AccountID("in-process-flag-account"), displayName: "Flag",
            email: EmailAddress("flag@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("in-process-flag-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let message = MessageSummary(
            id: MessageID("in-process-flag-message"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Flag", preview: "Flag",
            smartCategory: .personal, isSeen: false
        )
        try store.cacheMessageReliably(message)
        try store.recordCachedUID(accountID: account.id, mailboxPath: "INBOX",
                                  uidValidity: 1, uid: 4, messageID: message.id)
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("secret".utf8), for: accountIMAPPasswordKey(account.id))
        let remoteSeen = ControlledRemoteSeenState(seen: false)
        let worker = InProcessOperationWorkerSignal(runtime: LocalOperationRuntime(
            store: store, credentials: vault,
            allowedJobKinds: [.mailboxFlag, .mailboxArchive], requireExplicitDirectSource: true,
            requireSelectedDirectClaimScope: true,
            mailboxFlagClientFactory: { _ in ControlledMailboxFlagClient(state: remoteSeen) }
        ))
        let job = try enqueueMailboxFlag(PlainpostMailboxFlagInput(
            messageID: message.id, accountID: account.id, mailboxPath: "INBOX",
            uidValidity: 1, uid: 4, desiredSeen: true,
            expectedDirectSourceGeneration: 1
        ), in: store)

        try await worker.signalWork()
        await worker.waitUntilIdle()

        XCTAssertEqual(try store.job(id: job.id).state, .completed)
        let didMarkRead = await remoteSeen.isSeen()
        XCTAssertTrue(didMarkRead)
    }

    func testSelectedDirectMailboxFlagBlocksABASourceSwitchWhileRunning() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: AccountID("aba-mailbox-account"), displayName: "ABA",
            email: EmailAddress("aba@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let direct = try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("aba-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: direct
        )
        let message = MessageSummary(
            id: MessageID("aba-message"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "ABA", preview: "ABA",
            smartCategory: .personal, isSeen: false
        )
        try store.cacheMessageReliably(message)
        try store.recordCachedUID(accountID: account.id, mailboxPath: "INBOX",
                                  uidValidity: 1, uid: 4, messageID: message.id)
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("secret".utf8), for: accountIMAPPasswordKey(account.id))
        let probe = IMAPFactoryConstructionProbe()
        let remoteSeen = ControlledRemoteSeenState(seen: false)
        let runtime = LocalOperationRuntime(
            store: store, credentials: vault,
            allowedJobKinds: [.mailboxFlag], requireExplicitDirectSource: true,
            selectedDirectAccountID: account.id, expectedDirectSourceGeneration: 1,
            requireSelectedDirectClaimScope: true,
            mailboxFlagClientFactory: { _ in
                probe.record()
                return ControlledMailboxFlagClient(state: remoteSeen)
            }
        )
        _ = try enqueueMailboxFlag(PlainpostMailboxFlagInput(
            messageID: message.id, accountID: account.id, mailboxPath: "INBOX",
            uidValidity: 1, uid: 4, desiredSeen: true,
            expectedDirectSourceGeneration: 1
        ), in: store)
        runtime.beforeLeaseFence = { _ in
            XCTAssertThrowsError(try store.replaceMailSource(direct.nodeBacked(
                nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
                logicalMailboxID: String(repeating: "A", count: 43),
                providerIdentity: account.email.rawValue
            ), expectedGeneration: 1)) { error in
                XCTAssertEqual(error as? NodeMailModeStoreError, .operationUnresolved)
            }
        }
        _ = try await runtime.processNextJob()
        XCTAssertEqual(probe.constructionCount, 1)
        let didMarkRead = await remoteSeen.isSeen()
        XCTAssertTrue(didMarkRead)
        XCTAssertEqual(try store.mailSource(accountID: account.id), direct)
    }

    func testSelectedDirectSchedulerOnlyEnqueuesSelectedGeneration() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let selected = PlainpostFixtures.personalAccount
        let foreign = Account(
            id: AccountID("scheduled-foreign"), displayName: "Foreign",
            email: EmailAddress("foreign@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([selected, foreign])
        _ = try store.replaceMailSource(AccountMailSource(
            accountID: selected.id, kind: .direct, mode: nil,
            nodeID: nil, logicalMailboxID: nil,
            providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        for account in [selected, foreign] {
            try store.saveSyncPreferences(MailSyncPreferences(
                accountID: account.id, downloadCompleteHistory: false,
                recentMessageLimit: 100, realTimeMonitoringEnabled: true
            ))
        }
        let runtime = LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.inboxSync], requireExplicitDirectSource: true,
            selectedDirectAccountID: selected.id, expectedDirectSourceGeneration: 1,
            requireSelectedDirectClaimScope: true
        )

        try runtime.enqueueScheduledSyncJobs()

        let jobs = try store.jobs().filter { $0.kind == .inboxSync }
        XCTAssertEqual(jobs.count, 1)
        let input = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self, from: Data(try XCTUnwrap(jobs.first).payloadJSON.utf8)
        )
        XCTAssertEqual(input.accountID, selected.id)
        XCTAssertEqual(input.expectedDirectSourceGeneration, 1)
    }

    /// The device-wide iOS worker (claim scope on, no selected account) schedules every
    /// Direct account at that account's own generation, and never a Sync Node one.
    func testEveryDirectAccountSchedulerEnqueuesEachDirectAccountWithItsGeneration() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let accounts = ["a", "b", "n"].map {
            Account(id: AccountID("scheduled-\($0)"), displayName: $0, email: EmailAddress("\($0)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        for account in accounts {
            _ = try store.replaceMailSource(AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0)
            try store.saveSyncPreferences(MailSyncPreferences(
                accountID: account.id, downloadCompleteHistory: false,
                recentMessageLimit: 100, realTimeMonitoringEnabled: true
            ))
        }
        let nodeDirect = try store.mailSource(accountID: accounts[2].id)
        _ = try store.replaceMailSource(nodeDirect.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: "n@example.com"
        ), expectedGeneration: nodeDirect.generation)
        let runtime = LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.inboxSync], requireExplicitDirectSource: true,
            selectedDirectAccountID: nil, expectedDirectSourceGeneration: nil,
            requireSelectedDirectClaimScope: true
        )

        try runtime.enqueueScheduledSyncJobs()

        let inputs = try store.jobs().filter { $0.kind == .inboxSync }.map {
            try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data($0.payloadJSON.utf8))
        }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: inputs.map { ($0.accountID, $0.expectedDirectSourceGeneration) }),
            [accounts[0].id: try store.mailSource(accountID: accounts[0].id).generation,
             accounts[1].id: try store.mailSource(accountID: accounts[1].id).generation]
        )
    }

    func testExplicitDirectSourceSwitchDuringCredentialLoadWaitsForFlagJob() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: AccountID("source-switch"), displayName: "Source Switch",
            email: EmailAddress("source@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let direct = try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("source-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: direct
        )
        let message = MessageSummary(
            id: MessageID("source-message"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Source", preview: "Source",
            smartCategory: .personal, isSeen: false
        )
        try store.cacheMessageReliably(message)
        try store.recordCachedUID(accountID: account.id, mailboxPath: "INBOX",
                                  uidValidity: 1, uid: 1, messageID: message.id)
        let vault = SuspendedIMAPCredentialVault(
            key: accountIMAPPasswordKey(account.id), secret: Data("secret".utf8)
        )
        let probe = IMAPFactoryConstructionProbe()
        let remoteSeen = ControlledRemoteSeenState(seen: false)
        let runtime = LocalOperationRuntime(
            store: store, credentials: vault,
            allowedJobKinds: [.mailboxFlag], requireExplicitDirectSource: true,
            mailboxFlagClientFactory: { _ in
                probe.record()
                return ControlledMailboxFlagClient(state: remoteSeen)
            }
        )
        _ = try enqueueMailboxFlag(PlainpostMailboxFlagInput(
            messageID: message.id, accountID: account.id, mailboxPath: "INBOX",
            uidValidity: 1, uid: 1, desiredSeen: true
        ), in: store)

        let processing = Task { try await runtime.processNextJob() }
        await vault.waitUntilLoadIsHeld()
        XCTAssertThrowsError(try store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "source@example.com"
        ), expectedGeneration: 1)) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .operationUnresolved)
        }
        await vault.releaseLoad()
        _ = try await processing.value
        XCTAssertEqual(probe.constructionCount, 1)
        let didMarkRead = await remoteSeen.isSeen()
        XCTAssertTrue(didMarkRead)
        XCTAssertEqual(try store.mailSource(accountID: account.id), direct)
    }

    func testInteractiveAIRejectsInjectedNonLocalProviderBeforeGeneration() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheOwnedTestMessage(PlainpostFixtures.aliceMessage)
        let provider = NonLocalAIProviderProbe()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .summarizeMessage,
            recordID: PlainpostFixtures.aliceMessage.id.rawValue,
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: provider.id
        )
        _ = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                maxAttempts: 1,
                idempotencyKey: "reject-non-local-provider"
            )
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected a non-local provider to be rejected.")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .remoteEndpointDisallowed)
            XCTAssertEqual(provider.generationCount, 0)
        }
    }

    // The message names the Settings button the user actually sees.
    func testReauthorizationFailurePointsAtSignInAgain() {
        let job = PlainpostDurableJob(
            id: "job-reauthorize", kind: .inboxSync, payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running, leaseToken: "lease", idempotencyKey: "reauthorize"
        )
        let disposition = LocalOperationFailurePolicy.disposition(
            error: MailCredentialError.reauthorizationRequired, job: job, now: Date()
        )
        XCTAssertEqual(disposition.code, "MAIL_REAUTHORIZATION_REQUIRED")
        XCTAssertEqual(disposition.message, "Google sign-in for this account has expired. Choose Sign in again in Settings.")
    }

    func testSQLiteContentionFailurePolicyUsesDeterministicBoundedRetry() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let job = PlainpostDurableJob(
            id: "job-contention-a",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running,
            attempt: 3,
            maxAttempts: 5,
            leaseToken: "lease",
            idempotencyKey: "contention-a"
        )

        let first = LocalOperationFailurePolicy.disposition(
            error: SQLiteMailStoreError.transientContention,
            job: job,
            now: now
        )
        let repeated = LocalOperationFailurePolicy.disposition(
            error: SQLiteMailStoreError.transientContention,
            job: job,
            now: now
        )
        let otherJob = PlainpostDurableJob(
            id: "job-contention-b",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running,
            attempt: job.attempt,
            maxAttempts: job.maxAttempts,
            leaseToken: "lease",
            idempotencyKey: "contention-b"
        )
        let other = LocalOperationFailurePolicy.disposition(
            error: SQLiteMailStoreError.transientContention,
            job: otherJob,
            now: now
        )
        let base = pow(2, Double(job.attempt)) * 2
        let delay = try XCTUnwrap(first.retryAt).timeIntervalSince(now)

        XCTAssertEqual(first.code, "DATABASE_BUSY")
        XCTAssertEqual(first.message, "The local mail database is busy. Plainpost will retry automatically.")
        XCTAssertFalse(first.message.localizedCaseInsensitiveContains("secret"))
        XCTAssertEqual(first.retryAt, repeated.retryAt)
        XCTAssertNotEqual(first.retryAt, other.retryAt)
        XCTAssertGreaterThanOrEqual(delay, base * 0.8)
        XCTAssertLessThanOrEqual(delay, base * 1.2)
        XCTAssertLessThanOrEqual(LocalOperationFailurePolicy.retryDelay(attempt: 20, jobID: job.id), 300)

        let exhausted = PlainpostDurableJob(
            id: job.id,
            kind: job.kind,
            payloadJSON: job.payloadJSON,
            state: .running,
            attempt: job.maxAttempts,
            maxAttempts: job.maxAttempts,
            leaseToken: "lease",
            idempotencyKey: job.idempotencyKey
        )
        XCTAssertNil(LocalOperationFailurePolicy.disposition(
            error: SQLiteMailStoreError.transientContention,
            job: exhausted,
            now: now
        ).retryAt)
    }

    func testValidationFailurePolicyRemainsPermanent() {
        let job = PlainpostDurableJob(
            id: "job-validation",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running,
            attempt: 1,
            maxAttempts: 5,
            leaseToken: "lease",
            idempotencyKey: "validation"
        )

        let disposition = LocalOperationFailurePolicy.disposition(
            error: PlainpostError.validationFailed("Mailbox selection is invalid."),
            job: job,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(disposition.code, "VALIDATION_FAILED")
        XCTAssertEqual(disposition.message, "Mailbox selection is invalid.")
        XCTAssertNil(disposition.retryAt)
    }

    func testUnconfiguredGoogleOAuthFailsWithoutRetrying() {
        let job = PlainpostDurableJob(
            id: "job-google-client-missing",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running,
            attempt: 1,
            maxAttempts: 5,
            leaseToken: "lease",
            idempotencyKey: "google-client-missing"
        )

        let disposition = LocalOperationFailurePolicy.disposition(
            error: MailCredentialError.oauthNotConfigured,
            job: job
        )

        XCTAssertEqual(disposition.code, "GOOGLE_OAUTH_NOT_CONFIGURED")
        XCTAssertNil(disposition.retryAt)
    }

    func testIMAPFailurePolicyUsesSanitizedSpecificReasons() {
        let job = PlainpostDurableJob(
            id: "job-imap-failure-policy",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .running,
            attempt: 1,
            maxAttempts: 5,
            leaseToken: "lease",
            idempotencyKey: "imap-failure-policy"
        )
        let cases: [(IMAPClientError, String, String)] = [
            (.authenticationFailed, "IMAP_AUTHENTICATION_REJECTED", "The mail server rejected the saved account credentials."),
            (.connectionLimit, "IMAP_CONNECTION_LIMIT", "The mail server has too many simultaneous connections. Plainpost will retry."),
            (.throttled, "IMAP_THROTTLED", "The mail server temporarily limited synchronization. Plainpost will retry."),
            (.tlsFailed, "IMAP_TLS_FAILED", "Plainpost could not establish a trusted secure connection to the mail server."),
            (.timedOut, "IMAP_NETWORK_UNAVAILABLE", "The mail server did not respond in time. Plainpost will retry."),
            (.connectionFailed, "IMAP_NETWORK_UNAVAILABLE", "Plainpost could not reach the mail server. Plainpost will retry."),
            (.resourceLimit, "IMAP_RESOURCE_LIMIT", "The mail server response exceeded Plainpost's safety limit."),
        ]

        for (error, code, message) in cases {
            let disposition = LocalOperationFailurePolicy.disposition(
                error: error,
                job: job,
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )
            XCTAssertEqual(disposition.code, code)
            XCTAssertEqual(disposition.message, message)
        }

        let protocolDisposition = LocalOperationFailurePolicy.disposition(
            error: IMAPClientError.protocolError("server-only detail"),
            job: job,
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(protocolDisposition.code, "IMAP_PROTOCOL_ERROR")
        XCTAssertEqual(protocolDisposition.message, "The mail server returned an unsupported response.")
        XCTAssertFalse(protocolDisposition.message.contains("server-only detail"))
    }

    func testRuntimeAnchorsRetryAtToFailureTimeInsteadOfClaimTime() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let claimTime = Date(timeIntervalSince1970: 2_000_000_000)
        let failureTime = claimTime.addingTimeInterval(600)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "failure-time"
        )
        let job = try store.enqueueJob(try Self.aiRequest(
            input: input,
            priority: 100,
            key: "failure-time-anchor"
        ))
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in throw FailureTimeTestError.transient },
            failureDateProvider: { failureTime }
        )

        do {
            _ = try await runtime.processNextJob(now: claimTime)
            XCTFail("Expected the injected transient failure.")
        } catch FailureTimeTestError.transient {
            let queued = try store.job(id: job.id)
            let expectedRetryAt = failureTime.addingTimeInterval(
                LocalOperationFailurePolicy.retryDelay(attempt: queued.attempt, jobID: queued.id)
            )
            XCTAssertEqual(queued.state, .queued)
            XCTAssertGreaterThan(queued.availableAt, failureTime)
            XCTAssertEqual(
                queued.availableAt.timeIntervalSince1970,
                expectedRetryAt.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    func testRuntimeRetriesContendedInboxJobOnceWithoutCreatingDuplicateSync() async throws {
        let password = "contention-sync-secret"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-operations-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let writerHolder = RuntimeSQLiteWriteLockHolder()
        let writerHeld = DispatchSemaphore(value: 0)
        let writerReleased = DispatchSemaphore(value: 0)
        let store = try SQLiteMailStore(
            path: url.path,
            busyTimeout: 0.05,
            onTransientContention: {
                try writerHolder.rollbackIfHeld()
                writerReleased.signal()
            }
        )
        try store.migrate()
        try writerHolder.install(RuntimeSQLiteWriteLock(databaseURL: url))
        let imap = LocalIMAPServer(
            username: "contention@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let account = Account(
            id: AccountID("acc_contention_runtime"),
            displayName: "Contention Runtime",
            email: EmailAddress("contention@example.com"),
            username: "contention@example.com",
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data(password.utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let job = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync],
            beforeJobExecution: { claimed in
                if claimed.id == job.id, claimed.attempt == 1 {
                    try writerHolder.beginImmediate()
                    writerHeld.signal()
                    try store.cacheAccounts([account])
                }
            }
        )

        do {
            _ = try await runtime.processNextJob(now: Date(timeIntervalSince1970: 2_000_000_000))
            XCTFail("Expected SQLite contention to escape the first sync attempt.")
        } catch {
            XCTAssertEqual(error as? SQLiteMailStoreError, .transientContention)
        }
        XCTAssertEqual(writerHeld.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(writerReleased.wait(timeout: .now() + 1), .success)
        let queued = try store.job(id: job.id)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.attempt, 1)
        XCTAssertEqual(queued.errorCode, "DATABASE_BUSY")
        XCTAssertEqual(queued.errorMessage, "The local mail database is busy. Plainpost will retry automatically.")
        XCTAssertEqual(
            try store.jobs(limit: 100).filter { $0.kind == .inboxSync || $0.kind == .historicalSync }.map(\.id),
            [job.id]
        )
        XCTAssertEqual(
            try store.enqueueCoalescedInboxSyncJob(
                PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
            ).id,
            job.id
        )

        let completed = try await runtime.processNextJob(now: queued.availableAt)

        XCTAssertEqual(completed?.id, job.id)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.attempt, 2)
        XCTAssertEqual(
            try store.jobs(limit: 100).filter { $0.kind == .inboxSync || $0.kind == .historicalSync }.count,
            1
        )
    }

    func testBackgroundAgentOwnsMailAndAIJobKinds() {
        XCTAssertEqual(
            PlainpostBackgroundAgentJobPolicy.allowedKinds,
            [
                .inboxSync, .historicalSync, .approvedDelivery, .denySend,
                .aiOperation, .searchRebuild, .mailboxFlag, .mailboxArchive,
            ]
        )
    }

    func testBackgroundAgentPendingWorkIgnoresAcknowledgedManualPause() {
        let manualPause = PlainpostDurableJob(
            id: "manual-pause",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .paused,
            idempotencyKey: "manual-pause",
            pauseReason: "user-requested"
        )

        XCTAssertFalse(PlainpostBackgroundAgentJobPolicy.hasPendingWork([manualPause]))
    }

    func testBackgroundAgentPendingWorkIgnoresAcknowledgedLowPowerPause() {
        let lowPowerPause = PlainpostDurableJob(
            id: "low-power-pause",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .paused,
            idempotencyKey: "low-power-pause",
            pauseReason: "low-power"
        )

        XCTAssertFalse(PlainpostBackgroundAgentJobPolicy.hasPendingWork([lowPowerPause]))
    }

    func testBackgroundAgentPendingWorkRetainsUnacknowledgedPauseRequest() {
        let awaitingAcknowledgement = PlainpostDurableJob(
            id: "pause-requested",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .running,
            leaseToken: "lease",
            cancellationRequested: false,
            pauseRequested: true,
            idempotencyKey: "pause-requested"
        )

        XCTAssertTrue(PlainpostBackgroundAgentJobPolicy.hasPendingWork([awaitingAcknowledgement]))
    }

    func testInboxSyncPausesWhenMailCredentialsAreUnavailable() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        let job = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
        )
        let credentials = InMemoryCredentialVault()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync]
        )

        let processed = try await runtime.processNextJob()

        XCTAssertEqual(processed?.id, job.id)
        XCTAssertEqual(processed?.state, .paused)
        XCTAssertEqual(processed?.pauseReason, "credentials-unavailable")
        XCTAssertEqual(processed?.attempt, 0)
        XCTAssertNil(processed?.errorCode)
        XCTAssertNil(processed?.errorMessage)

        let retry = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
        )
        XCTAssertEqual(retry.id, job.id)
        XCTAssertEqual(retry.state, .queued)
        XCTAssertNil(retry.pauseReason)
    }

    func testInboxSyncPausesWhenVaultIsLocked() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        let job = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: account.id,
                trigger: .manual,
                scope: .incremental
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: ThrowingCredentialVault(error: .locked),
            allowedJobKinds: [.inboxSync]
        )

        let processed = try await runtime.processNextJob()

        XCTAssertEqual(processed?.id, job.id)
        XCTAssertEqual(processed?.state, .paused)
        XCTAssertEqual(processed?.pauseReason, "credentials-unavailable")
        XCTAssertEqual(processed?.attempt, 0)
    }

    func testInboxSyncPausesWhenGoogleAccountNeedsReauthorization() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let email = EmailAddress("me@gmail.com")
        let account = Account(
            id: AccountID.stableAccountID(email: email),
            displayName: "Gmail",
            email: email,
            username: email.rawValue,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587
        )
        try store.cacheAccounts([account])
        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        let job = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .incremental)
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data("stale-app-password".utf8), for: accountIMAPPasswordKey(account.id))
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync]
        )

        let processed = try await runtime.processNextJob()

        XCTAssertEqual(processed?.id, job.id)
        XCTAssertEqual(processed?.state, .paused)
        XCTAssertEqual(processed?.pauseReason, "credentials-unavailable")
        XCTAssertEqual(processed?.attempt, 0)
    }

    func testInboxSyncTreatsCorruptCredentialAsTerminalInsteadOfMissing() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        let job = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: account.id,
                trigger: .manual,
                scope: .incremental
            )
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data([0xFF]),
            for: accountIMAPPasswordKey(account.id)
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync]
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected corrupt credential data to fail closed.")
        } catch CredentialVaultError.ciphertextInvalid {
            // Expected.
        }

        let failed = try store.job(id: job.id)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotEqual(failed.pauseReason, "credentials-unavailable")
    }

    func testRunUntilTerminalStateContinuesAfterCompetingJobFails() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Runtime target"
        )
        let missing = PlainpostApprovalDecisionInput(
            requestID: SendRequestID("missing-request"),
            actorID: PlainpostFixtures.guiUser.id
        )
        let target = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let competing = try store.enqueueJob(try approvalJob(
            kind: .denySend,
            input: target,
            priority: 200,
            key: "competing-failure"
        ))
        let missingPayload = String(
            decoding: try JSONEncoder().encode(missing),
            as: UTF8.self
        )
        try await store.databasePool.write { database in
            try database.execute(
                sql: "UPDATE durable_jobs SET payload_json = ? WHERE id = ?",
                arguments: [missingPayload, competing.id]
            )
        }
        let targetJob = try store.enqueueJob(try approvalJob(
            kind: .denySend,
            input: target,
            priority: 100,
            key: "terminal-target"
        ))
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.denySend]
        )

        let terminal = try await runtime.runUntilTerminalState(
            jobID: targetJob.id,
            pollInterval: .milliseconds(5)
        )

        XCTAssertEqual(try store.job(id: competing.id).state, .failed)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .denied)
    }

    func testAcceptedApprovedDeliveryWithLocalSentPersistenceFailureIsTerminalUncertain() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: PlainpostFixtures.personalAccount.id,
            displayName: "Personal",
            email: PlainpostFixtures.personalAccount.email,
            imapHost: "127.0.0.1",
            smtpHost: "127.0.0.1",
            smtpPort: Int(smtp.port)
        )
        try store.cacheAccounts([account])
        let draft = try store.createDraft(
            PlainpostFixtures.replyDraft,
            actor: PlainpostFixtures.codexActor
        )
        let request = try store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Durable approval"
        )
        let input = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: PlainpostFixtures.guiUser.id
        )
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .approvedDelivery,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                priority: 100,
                maxAttempts: 5,
                idempotencyKey: "post-smtp-approved-persistence"
            )
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("secret".utf8),
            for: accountSMTPPasswordKey(account.id)
        )
        try await store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_search_fts")
        }
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.approvedDelivery]
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected local Sent persistence failure after SMTP acceptance.")
        } catch {
            XCTAssertEqual(error as? PostSMTPPersistenceError, .localPersistenceFailed)
            XCTAssertFalse(error.localizedDescription.contains("mail_search_fts"))
        }

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .deliveryUncertain)
        let persisted = try store.job(id: job.id)
        XCTAssertEqual(persisted.state, .deliveryUncertain)
        XCTAssertEqual(persisted.attempt, 1)
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.approvedDelivery]))
    }

    /// Controller ruling R3 (Task 16 review, routed in Task 17 fix round 1):
    /// an approved send (agent approval or browser reply) of a Node-backed
    /// account, in either mode, goes to the service's mail-intent router and
    /// never over this runtime's direct SMTP. A runtime without that route
    /// sends nothing: the job ends as a transient failure would, never
    /// completed and never uncertain.
    func testApprovedDeliveryOfANodeBackedAccountIsHandedToTheRouterAndNeverSentOverSMTP() async throws {
        for mode in [NodeBackedMode.node, .fallback] {
            for routed in [false, true] {
                let fixture = try await ApprovedNodeDeliveryFixture.make(mode: mode, key: "\(mode.rawValue)-\(routed)")
                defer { fixture.cleanUp() }
                let handedOff = ApprovedSendRecorder()
                let handoff: NodeModeApprovedSendHandoff = { @Sendable work in handedOff.record(work) }
                let runtime = LocalOperationRuntime(
                    store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery],
                    nodeModeApprovedSendHandoff: routed ? handoff : nil
                )

                _ = try? await runtime.processNextJob()

                let accepted = await fixture.smtp.acceptedMessages()
                XCTAssertEqual(accepted.count, 0, "no direct SMTP for a Node-backed account (\(mode), routed: \(routed))")
                let job = try fixture.store.job(id: fixture.jobID)
                if routed {
                    XCTAssertEqual(handedOff.sends.map(\.requestID), [fixture.requestID])
                    XCTAssertEqual(handedOff.sends.map(\.jobID), [fixture.jobID])
                    XCTAssertEqual(job.state, .completed)
                } else {
                    XCTAssertNotEqual(job.state, .completed, "no route here: nothing sent")
                    XCTAssertNotEqual(job.state, .deliveryUncertain)
                }
            }
        }
    }

    /// Once an approved send's intent is journaled, no job for that request
    /// ever takes the direct SMTP path, even after its account reverted to
    /// Direct (or on a lease-recovered retry).
    func testAJournaledApprovedSendNeverTakesTheDirectPath() async throws {
        let fixture = try await ApprovedNodeDeliveryFixture.make(mode: .node, key: "journaled")
        defer { fixture.cleanUp() }
        let draft = try fixture.store.draft(id: try fixture.store.sendRequest(id: fixture.requestID).draftID)
        let operationID = UUID().uuidString.lowercased()
        _ = try fixture.store.claimSendRequestForDelivery(
            id: fixture.requestID, currentDraftHash: draft.contentHash, actor: PlainpostFixtures.guiUser, deliveryOperationID: operationID)
        _ = try fixture.store.journalMailIntent(
            operationID: operationID, accountID: draft.accountID,
            kind: .send, messageID: nil, draftID: draft.id, contentHash: draft.contentHash, now: Date())
        let source = try fixture.store.mailSource(accountID: draft.accountID)
        // Normal source changes cannot pass an unresolved approved-delivery
        // job. Recreate a legacy/recovered Direct row to exercise the runtime's
        // independent journal fence if such state is ever encountered.
        XCTAssertThrowsError(try fixture.store.replaceMailSource(
            source.revertedToDirect(), expectedGeneration: source.generation
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .operationUnresolved)
        }
        try await fixture.store.databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE account_mail_sources
                    SET kind = 'direct', mode = NULL, node_id = NULL,
                        logical_mailbox_id = NULL, provider_identity = NULL,
                        generation = ?
                    WHERE account_id = ?
                    """,
                arguments: [source.generation + 1, draft.accountID.rawValue]
            )
        }
        XCTAssertEqual(try fixture.store.mailSource(accountID: draft.accountID).kind, .direct)
        let runtime = LocalOperationRuntime(store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery])

        _ = try? await runtime.processNextJob()

        let accepted = await fixture.smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 0)
        XCTAssertNotEqual(try fixture.store.job(id: fixture.jobID).state, .completed)
    }

    func testRunUntilTerminalStateCancelsWhileTargetIsPersistedRunning() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            idempotencyKey: "persisted-running-cancellation"
        ))
        _ = try XCTUnwrap(store.claimNextJob(now: Date(), leaseDuration: 60))
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation]
        )
        let waiter = Task {
            try await runtime.runUntilTerminalState(
                jobID: job.id,
                pollInterval: .milliseconds(5)
            )
        }

        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try store.job(id: job.id).state, .running)
    }

    func testMailboxFlagJobMarksRemoteMessageReadWithoutRewritingLocalState() async throws {
        let password = "mailbox-flag-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let seedClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await seedClient.login(username: "me@example.com", password: password)
        _ = try await seedClient.selectMailbox("INBOX")
        try await seedClient.markUnread(uid: 1)
        await seedClient.disconnect()

        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: imap.port)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(false),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let runtime = LocalOperationRuntime(store: store, credentials: credentials)
        let input = PlainpostMailboxFlagInput(
            messageID: PlainpostFixtures.aliceMessage.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            desiredSeen: true
        )
        let job = try enqueueMailboxFlag(input, in: store)

        _ = try await runtime.runUntilTerminal(jobID: job.id)

        let verificationClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await verificationClient.login(username: "me@example.com", password: password)
        _ = try await verificationClient.selectMailbox("INBOX")
        let remoteHeader = try await verificationClient.fetchHeader(uid: 1)
        XCTAssertTrue(remoteHeader.contains("\\Seen"))
        await verificationClient.disconnect()
        XCTAssertFalse(try XCTUnwrap(store.messages.first { $0.id == input.messageID }).isSeen)
    }

    func testMailboxArchiveJobForACopyAlreadyInTheArchiveSendsNothingAndKeepsIt() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("mbx-gmail-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("mbx-gmail-all"), accountID: account.id, name: "All Mail", path: "[Gmail]/All Mail", specialUse: "\\All"),
        ])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withMailboxPath("[Gmail]/All Mail"),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "[Gmail]/All Mail",
            uidValidity: 42,
            uid: 7,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data("archive-secret".utf8), for: accountIMAPPasswordKey(account.id))
        let archiveState = ArchiveRecordingState()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            mailboxFlagClientFactory: { _ in ArchiveRecordingClient(state: archiveState) }
        )
        let job = try store.enqueueMailboxArchive(PlainpostMailboxArchiveInput(
            messageID: PlainpostFixtures.aliceMessage.id, accountID: account.id,
            sourceMailboxPath: "[Gmail]/All Mail", destinationMailboxPath: "Archive",
            uidValidity: 42, uid: 7
        ))

        _ = try await runtime.runUntilTerminal(jobID: job.id)

        let archiveCalls = await archiveState.calls()
        XCTAssertEqual(archiveCalls, [], "no move into the mailbox the copy is already in")
        XCTAssertTrue(try store.mailboxListMessageIDs(
            accountID: account.id, inMailboxPath: "[Gmail]/All Mail"
        ).contains(PlainpostFixtures.aliceMessage.id), "the All Mail copy stays")
    }

    func testMailboxArchiveJobUsesCapturedInboxMembership() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx-archive-runtime-inbox"),
                accountID: account.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
            Mailbox(
                id: MailboxID("mbx-archive-runtime-archive"),
                accountID: account.id,
                name: "Archive",
                path: "Archive",
                specialUse: "\\Archive"
            ),
        ])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage,
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 42,
            uid: 7,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("archive-secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let archiveState = ArchiveRecordingState()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            mailboxFlagClientFactory: { _ in ArchiveRecordingClient(state: archiveState) }
        )
        let input = PlainpostMailboxArchiveInput(
            messageID: PlainpostFixtures.aliceMessage.id,
            accountID: account.id,
            sourceMailboxPath: "INBOX",
            destinationMailboxPath: "Archive",
            uidValidity: 42,
            uid: 7
        )
        let job = try store.enqueueMailboxArchive(input)

        _ = try await runtime.runUntilTerminal(jobID: job.id)

        let archiveCalls = await archiveState.calls()
        XCTAssertEqual(
            archiveCalls,
            [.init(uid: 7, mailbox: "Archive")]
        )
        XCTAssertFalse(try store.mailboxListMessageIDs(
            accountID: account.id,
            inMailboxPath: "INBOX"
        ).contains(PlainpostFixtures.aliceMessage.id))
    }

    func testMailboxFlagSurvivesRestartAndProductionBackgroundWorkerDrainsIt() async throws {
        let password = "mailbox-restart-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let seedClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await seedClient.login(username: "me@example.com", password: password)
        _ = try await seedClient.selectMailbox("INBOX")
        try await seedClient.markUnread(uid: 1)
        await seedClient.disconnect()

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mailbox-restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let account = localAccount(port: imap.port)
        let jobID: String
        do {
            let writer = try SQLiteMailStore(path: databaseURL.path)
            try writer.migrate()
            try writer.cacheAccounts([account])
            _ = try writer.commitIncomingMessage(
                PlainpostFixtures.aliceMessage.withSeen(false),
                metadata: emptySearchMetadata(),
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                notificationEligible: false
            )
            _ = try writer.openMessageForHuman(
                PlainpostFixtures.aliceMessage.id,
                actor: PlainpostFixtures.guiUser
            )
            jobID = try XCTUnwrap(writer.jobs(limit: 10).first { $0.kind == .mailboxFlag }).id
        }

        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let reopened = try SQLiteMailStore(path: databaseURL.path)
        try reopened.migrate()
        let runtime = LocalOperationRuntime(
            store: reopened,
            credentials: credentials,
            allowedJobKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds
        )

        let processed = try await runtime.processNextJob()

        XCTAssertEqual(processed?.id, jobID)
        XCTAssertEqual(try reopened.job(id: jobID).state, .completed)
        let verificationClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await verificationClient.login(username: "me@example.com", password: password)
        _ = try await verificationClient.selectMailbox("INBOX")
        let remoteHeader = try await verificationClient.fetchHeader(uid: 1)
        XCTAssertTrue(remoteHeader.contains("\\Seen"))
        await verificationClient.disconnect()
    }

    func testMailboxFlagWorkerSkipsJobSupersededByLatestHumanDesiredState() async throws {
        let password = "mailbox-superseded-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let seedClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await seedClient.login(username: "me@example.com", password: password)
        _ = try await seedClient.selectMailbox("INBOX")
        try await seedClient.markUnread(uid: 1)
        await seedClient.disconnect()

        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: imap.port)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(false),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        _ = try store.openMessageForHuman(
            PlainpostFixtures.aliceMessage.id,
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.markSeen(
            PlainpostFixtures.aliceMessage.id,
            seen: false,
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.markSeen(
            PlainpostFixtures.aliceMessage.id,
            seen: true,
            actor: PlainpostFixtures.guiUser
        )
        XCTAssertEqual(try store.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id), true)

        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds
        )

        while try await runtime.processNextJob() != nil {}

        let verificationClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await verificationClient.login(username: "me@example.com", password: password)
        _ = try await verificationClient.selectMailbox("INBOX")
        let remoteHeader = try await verificationClient.fetchHeader(uid: 1)
        XCTAssertTrue(remoteHeader.contains("\\Seen"))
        await verificationClient.disconnect()
    }

    func testOlderMailboxMutationLandingLastRequeuesLatestDesiredState() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(false),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let remoteMailbox = ControlledRemoteSeenState(seen: false)
        let oldMutationGate = MailboxFlagMutationGate()
        let recoverySignal = RecordingOperationWorkerSignal()
        let olderClient = ControlledMailboxFlagClient(
            state: remoteMailbox,
            markReadGate: oldMutationGate
        )
        let newerClient = ControlledMailboxFlagClient(state: remoteMailbox)
        let olderRuntime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds,
            mailboxFlagClientFactory: { _ in olderClient },
            workerSignal: recoverySignal
        )
        // A legacy/unscoped worker models the cross-process interleaving under
        // review by allowing the contrary job to run while the older mutation
        // is already beyond its initial desired-state check.
        let newerRuntime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            mailboxFlagClientFactory: { _ in newerClient }
        )
        _ = try store.openMessageForHuman(
            PlainpostFixtures.aliceMessage.id,
            actor: PlainpostFixtures.guiUser
        )

        let olderTask = Task { try await olderRuntime.processNextJob() }
        await oldMutationGate.waitUntilPaused()
        _ = try store.markSeen(
            PlainpostFixtures.aliceMessage.id,
            seen: false,
            actor: PlainpostFixtures.guiUser
        )
        let processedNewerJob = try await newerRuntime.processNextJob()
        let newerJob = try XCTUnwrap(processedNewerJob)
        let newerInput = try JSONDecoder().decode(
            PlainpostMailboxFlagInput.self,
            from: Data(newerJob.payloadJSON.utf8)
        )
        XCTAssertFalse(newerInput.desiredSeen)
        let seenAfterNewerMutation = await remoteMailbox.isSeen()
        XCTAssertFalse(seenAfterNewerMutation)
        try store.reconcileMailboxState(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            states: [IMAPRemoteMessageState(uid: 1, flags: [])]
        )
        XCTAssertNil(
            try store.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id),
            "The newer server observation should acknowledge its durable intent."
        )

        await oldMutationGate.release()
        _ = try await olderTask.value
        let recoverySignalCount = await recoverySignal.signalCount()
        XCTAssertEqual(recoverySignalCount, 1)
        let seenAfterOlderMutation = await remoteMailbox.isSeen()
        XCTAssertTrue(seenAfterOlderMutation, "The older mutation must land last in this regression.")
        let reopenedStore = try SQLiteMailStore(path: url.path)
        try reopenedStore.migrate()
        XCTAssertEqual(
            try reopenedStore.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id),
            false
        )
        let recoveryJob = try XCTUnwrap(
            reopenedStore.jobs(limit: 20).first(where: { job in
                guard job.kind == .mailboxFlag, job.state == .queued else { return false }
                return (try? JSONDecoder().decode(
                    PlainpostMailboxFlagInput.self,
                    from: Data(job.payloadJSON.utf8)
                ).desiredSeen) == false
            })
        )
        XCTAssertNotEqual(recoveryJob.id, newerJob.id)
        try reopenedStore.reconcileMailboxState(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            states: [IMAPRemoteMessageState(uid: 1, flags: ["\\Seen"])]
        )
        XCTAssertFalse(try XCTUnwrap(reopenedStore.messageSummary(id: PlainpostFixtures.aliceMessage.id)).isSeen)
        XCTAssertEqual(
            try reopenedStore.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id),
            false
        )

        let recoveryRuntime = LocalOperationRuntime(
            store: reopenedStore,
            credentials: credentials,
            allowedJobKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds,
            mailboxFlagClientFactory: { _ in newerClient }
        )
        _ = try await recoveryRuntime.processNextJob()
        let seenAfterRecovery = await remoteMailbox.isSeen()
        XCTAssertFalse(seenAfterRecovery)
        try reopenedStore.reconcileMailboxState(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            states: [IMAPRemoteMessageState(uid: 1, flags: [])]
        )
        XCTAssertNil(try reopenedStore.desiredSeenState(messageID: PlainpostFixtures.aliceMessage.id))
        XCTAssertFalse(
            try reopenedStore.jobs(limit: 20).contains { $0.kind == .mailboxFlag && $0.state == .queued }
        )
    }

    func testMailboxFlagJobMarksRemoteMessageUnreadWithoutRewritingLocalState() async throws {
        let password = "mailbox-unflag-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }

        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: imap.port)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(true),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let runtime = LocalOperationRuntime(store: store, credentials: credentials)
        let input = PlainpostMailboxFlagInput(
            messageID: PlainpostFixtures.aliceMessage.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            desiredSeen: false
        )
        let job = try enqueueMailboxFlag(input, in: store)

        _ = try await runtime.runUntilTerminal(jobID: job.id)

        let verificationClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await verificationClient.login(username: "me@example.com", password: password)
        _ = try await verificationClient.selectMailbox("INBOX")
        let remoteHeader = try await verificationClient.fetchHeader(uid: 1)
        XCTAssertFalse(remoteHeader.contains("\\Seen"))
        await verificationClient.disconnect()
        XCTAssertTrue(try XCTUnwrap(store.messages.first { $0.id == input.messageID }).isSeen)
    }

    func testMailboxFlagUIDValidityMismatchFailsClosedBeforeRemoteMutation() async throws {
        let password = "mailbox-stale-uid-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }

        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: imap.port)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(true),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 2,
            uid: 1,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let runtime = LocalOperationRuntime(store: store, credentials: credentials)
        let input = PlainpostMailboxFlagInput(
            messageID: PlainpostFixtures.aliceMessage.id,
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 2,
            uid: 1,
            desiredSeen: false
        )
        let job = try enqueueMailboxFlag(input, in: store)

        var operationError: Error?
        do {
            _ = try await runtime.processNextJob()
        } catch {
            operationError = error
        }

        XCTAssertEqual(
            operationError as? PlainpostError,
            .validationFailed("Mailbox state changed. Sync is required before updating message status.")
        )
        XCTAssertEqual(try store.job(id: job.id).state, .failed)
        let verificationClient = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await verificationClient.login(username: "me@example.com", password: password)
        _ = try await verificationClient.selectMailbox("INBOX")
        let remoteHeader = try await verificationClient.fetchHeader(uid: 1)
        XCTAssertTrue(remoteHeader.contains("\\Seen"))
        await verificationClient.disconnect()
    }

    func testMailboxFlagTransportFailureRemainsQueuedForRetry() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "mailbox-flag-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        let unavailablePort = imap.port
        imap.stop()

        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: unavailablePort)
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            PlainpostFixtures.aliceMessage.withSeen(true),
            metadata: emptySearchMetadata(),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("mailbox-flag-secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let runtime = LocalOperationRuntime(store: store, credentials: credentials)
        let job = try enqueueMailboxFlag(
            PlainpostMailboxFlagInput(
                messageID: PlainpostFixtures.aliceMessage.id,
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                desiredSeen: false
            ),
            in: store
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected the unavailable IMAP server to fail.")
        } catch is IMAPClientError {
            let retried = try store.job(id: job.id)
            XCTAssertEqual(retried.state, .queued)
            XCTAssertEqual(retried.attempt, 1)
            XCTAssertEqual(retried.errorCode, "IMAP_NETWORK_UNAVAILABLE")
        }
    }

    func testMailboxFlagMissingMembershipFailsTerminally() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let runtime = LocalOperationRuntime(store: store, credentials: InMemoryCredentialVault())
        let missingMessage = MessageSummary(
            id: MessageID("msg-missing"), threadID: nil,
            from: EmailAddress("missing@example.com"), subject: "Missing",
            preview: "Missing membership", smartCategory: .unknown
        )
        try store.cacheOwnedTestMessage(missingMessage)
        let missingMembership = try store.membership(for: missingMessage.id)
        let job = try enqueueMailboxFlag(
            PlainpostMailboxFlagInput(
                messageID: MessageID("msg-missing"),
                accountID: PlainpostFixtures.personalAccount.id,
                mailboxPath: missingMembership.mailboxPath,
                uidValidity: missingMembership.uidValidity,
                uid: missingMembership.uid,
                desiredSeen: true
            ),
            in: store
        )
        try await store.databasePool.write { database in
            try database.execute(
                sql: "DELETE FROM mailbox_messages WHERE message_id = ?",
                arguments: [missingMessage.id.rawValue]
            )
        }

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected missing membership to fail.")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("The mailbox flag membership is unavailable or changed.")
            )
            let failed = try store.job(id: job.id)
            XCTAssertEqual(failed.state, .failed)
            XCTAssertEqual(failed.attempt, 1)
            XCTAssertEqual(failed.errorCode, "VALIDATION_FAILED")
        }
    }

    func testCanonicalMailboxMembershipPrefersInbox() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = PlainpostFixtures.aliceMessage
        let metadata = IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "Archive",
            uidValidity: 7,
            uid: 42,
            notificationEligible: false
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 8,
            uid: 5,
            notificationEligible: false
        )

        XCTAssertEqual(
            try store.membership(for: message.id),
            MailboxMessageMembership(
                accountID: PlainpostFixtures.personalAccount.id,
                mailboxPath: "INBOX",
                uidValidity: 8,
                uid: 5,
                messageID: message.id
            )
        )
    }

    func testMissingMailboxMembershipThrowsCanonicalNotFoundError() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try store.membership(for: MessageID("msg-missing"))) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .notFound("Message mailbox membership was not found.")
            )
        }
    }

    func testSmartInboxRunModeDefaultsToIncrementalForOlderPayloads() throws {
        let data = Data(#"{"operation":"recategorizeInbox","recordID":"","providerID":"foundation"}"#.utf8)

        let input = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: data)

        XCTAssertEqual(input.smartInboxRunMode, .incremental)
        XCTAssertNil(input.smartInboxRequestID)
        XCTAssertNil(input.targetLanguageIdentifier)
        XCTAssertNil(input.targetLanguageName)
    }

    func testAIOperationPrioritiesMatchUserIntent() {
        XCTAssertEqual(PlainpostAIOperationKind.summarizeThread.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.summarizeMessage.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.translateMessage.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.translateMessage.priority, 100)
        XCTAssertEqual(PlainpostAIOperationKind.answerThreadQuestion.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.answerMailboxQuestion.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.draftReply.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.rewriteDraft.serviceClass, .interactive)
        XCTAssertEqual(PlainpostAIOperationKind.classifyMessage.serviceClass, .direct)
        XCTAssertEqual(PlainpostAIOperationKind.recategorizeInbox.serviceClass, .bulk)
        XCTAssertEqual(PlainpostAIOperationKind.rebuildIndex.serviceClass, .bulk)
        XCTAssertGreaterThan(PlainpostAIServiceClass.interactive.priority, PlainpostAIServiceClass.bulk.priority)
    }

    func testTranslationOperationPersistsCompleteArtifactAndMessageCache() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = MessageSummary(
            id: MessageID("msg-translate-runtime"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translate",
            preview: "Hallo Welt",
            body: "Hallo Welt",
            smartCategory: .personal
        )
        try store.cacheOwnedTestMessage(message)
        let provider = DeterministicAIProvider()
        let input = PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: message.id.rawValue,
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: provider.id,
            targetLanguageIdentifier: "en",
            targetLanguageName: "English"
        )
        let job = try store.enqueueJob(
            try Self.aiRequest(
                input: input,
                priority: input.operation.priority,
                key: "translate-message-runtime"
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )

        let processed = try await runtime.processNextJob()
        let completed = try XCTUnwrap(processed)
        let artifactID = try XCTUnwrap(completed.resultArtifactID)
        let artifact = try store.durableOperationArtifact(id: artifactID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        let cached = try XCTUnwrap(
            store.cachedTranslation(messageID: message.id, targetLanguageID: "en")
        )

        XCTAssertEqual(completed.id, job.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(payload.translatedBodyKind, EmailBodyKind.plainText.rawValue)
        XCTAssertEqual(payload.translatedBody, "Hallo Welt")
        XCTAssertEqual(payload.sourceFingerprint, MailTranslationFingerprint.message(message))
        XCTAssertEqual(payload.modelID, provider.chatModelID)
        XCTAssertEqual(cached.translatedBody, payload.translatedBody)
        XCTAssertEqual(cached.sourceFingerprint, payload.sourceFingerprint)
    }

    func testMessageReferencedConversationOperationsExecuteForUnthreadedAndLegacyMessages() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        let messages = [
            MessageSummary(
                id: MessageID("msg-runtime-unthreaded"), threadID: nil,
                from: EmailAddress("sender@example.com"), subject: "Unthreaded runtime",
                preview: "Unthreaded body", body: "Unthreaded body", smartCategory: .personal
            ),
            MessageSummary(
                id: MessageID("msg-runtime-legacy"), threadID: ThreadID("thr_uid_INBOX_1_502"),
                from: EmailAddress("legacy@example.com"), subject: "Legacy runtime",
                preview: "Legacy body", body: "Legacy body", smartCategory: .personal
            ),
        ]
        try store.cacheAccounts([account])
        for (index, message) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                message,
                metadata: emptySearchMetadata(),
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 501 + index,
                notificationEligible: false
            )
        }
        let provider = DeterministicAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in provider }
        )

        func execute(
            _ operation: PlainpostAIOperationKind,
            for message: MessageSummary,
            suffix: String
        ) async throws -> PlainpostLocalAIArtifactPayload {
            let input = PlainpostAIOperationInput(
                operation: operation,
                recordID: message.id.rawValue,
                conversationReferenceKind: .message,
                accountID: account.id,
                providerID: provider.id,
                question: operation == .answerThreadQuestion ? "What happened?" : nil
            )
            let job = try store.enqueueJob(try Self.aiRequest(
                input: input,
                priority: input.operation.priority,
                key: "message-conversation-\(suffix)-\(operation.rawValue)"
            ))
            let completed = try await runtime.runUntilTerminal(jobID: job.id)
            let artifact = try store.durableOperationArtifact(
                id: try XCTUnwrap(completed.resultArtifactID)
            )
            return try JSONDecoder().decode(
                PlainpostLocalAIArtifactPayload.self,
                from: Data(artifact.payloadJSON.utf8)
            )
        }

        for (index, message) in messages.enumerated() {
            let suffix = index == 0 ? "unthreaded" : "legacy"
            let summary = try await execute(.summarizeThread, for: message, suffix: suffix)
            XCTAssertEqual(summary.resultRecordID, message.id.rawValue)
            XCTAssertFalse(summary.text?.isEmpty ?? true)

            let answer = try await execute(.answerThreadQuestion, for: message, suffix: suffix)
            XCTAssertEqual(answer.resultRecordID, message.id.rawValue)
            XCTAssertFalse(answer.text?.isEmpty ?? true)

            let reply = try await execute(.draftReply, for: message, suffix: suffix)
            let draft = try store.draft(id: DraftID(try XCTUnwrap(reply.resultRecordID)))
            XCTAssertEqual(draft.accountID, account.id)
            XCTAssertEqual(draft.sourceThreadID, message.threadID)
            XCTAssertTrue(draft.aiGenerated)
        }
    }

    func testTranslationOperationRequiresBothTargetLanguageFields() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let message = MessageSummary(
            id: MessageID("msg-translate-missing-target"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translate",
            preview: "Hallo",
            body: "Hallo",
            smartCategory: .personal
        )
        try store.cacheOwnedTestMessage(message)
        let input = PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: message.id.rawValue,
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "deterministic",
            targetLanguageIdentifier: "en"
        )
        let job = try store.enqueueJob(
            try Self.aiRequest(
                input: input,
                priority: input.operation.priority,
                key: "translate-message-missing-target"
            )
        )
        let resolutionCounter = TranslationProviderResolutionCounter()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation],
            aiProviderResolver: { _ in
                resolutionCounter.increment()
                return DeterministicAIProvider()
            }
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected target-language validation failure")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("Translation target language is required.")
            )
        }

        XCTAssertEqual(try store.job(id: job.id).state, .failed)
        XCTAssertEqual(resolutionCounter.value, 0)
        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "en"))
    }

    func testPausedBulkJobRetainsProgressAndRetryBudgetThenResumesAfterInteractiveWork() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bulk = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: PlainpostAIServiceClass.bulk.priority,
                maxAttempts: 1,
                idempotencyKey: "bulk"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)
        let interactive = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: PlainpostAIServiceClass.interactive.priority,
                idempotencyKey: "interactive"
            )
        )
        XCTAssertEqual(
            try store.nextPendingJob(
                higherPriorityThan: running.priority,
                now: Date(),
                allowedKinds: [.aiOperation]
            )?.id,
            interactive.id
        )

        try store.pauseJob(
            id: bulk.id,
            leaseToken: lease,
            reason: "thread-summary",
            progress: .init(current: 42, total: 100, phase: "paused", label: "Smart Inbox")
        )
        let paused = try store.job(id: bulk.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.pauseReason, "thread-summary")
        XCTAssertEqual(paused.progress?.current, 42)
        XCTAssertEqual(paused.attempt, 1)

        let claimedInteractive = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(claimedInteractive.id, interactive.id)
        try store.completeJob(
            id: claimedInteractive.id,
            leaseToken: try XCTUnwrap(claimedInteractive.leaseToken),
            resultArtifactID: nil
        )
        let resumed = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(resumed.id, bulk.id)
        XCTAssertEqual(resumed.attempt, 1)
        XCTAssertEqual(resumed.progress?.current, 42)
    }

    func testCancellingPausedJobIsTerminal() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bulk = try store.enqueueJob(
            PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, priority: 10, idempotencyKey: "bulk-cancel")
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.pauseJob(
            id: bulk.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            reason: "ai-draft",
            progress: .init(current: 1, total: 2, phase: "paused", label: "Smart Inbox")
        )

        try store.requestJobCancellation(id: bulk.id)

        XCTAssertEqual(try store.job(id: bulk.id).state, .cancelled)
        XCTAssertNil(try store.claimNextJob())
    }

    func testRunningCancellationIsAcknowledgedAtSafeBoundary() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let job = try store.enqueueJob(
            PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "running-cancel")
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)

        try store.requestJobCancellation(id: job.id)
        XCTAssertTrue(try store.job(id: job.id).cancellationRequested)
        try store.acknowledgeJobCancellation(id: job.id, leaseToken: lease)

        let cancelled = try store.job(id: job.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.leaseToken)
    }

    func testHigherPriorityLookupRespectsWorkerAllowedKinds() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try store.enqueueJob(try Self.syncRequest(key: "delivery", priority: 100))

        XCTAssertNil(
            try store.nextPendingJob(
                higherPriorityThan: 10,
                now: Date(),
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
    }

    func testSeparateAIRunnersCannotClaimConcurrently() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bulk = try store.enqueueJob(
            PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, priority: 10, idempotencyKey: "runner-bulk")
        )
        let interactive = try store.enqueueJob(
            PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, priority: 100, idempotencyKey: "runner-interactive")
        )
        let first = try XCTUnwrap(
            store.claimNextJob(now: Date(), leaseDuration: 30, allowedKinds: [.aiOperation, .searchRebuild])
        )
        XCTAssertEqual(first.id, interactive.id)

        XCTAssertNil(
            try store.claimNextJob(now: Date(), leaseDuration: 30, allowedKinds: [.aiOperation, .searchRebuild])
        )
        try store.completeJob(
            id: first.id,
            leaseToken: try XCTUnwrap(first.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(
            try store.claimNextJob(
                now: Date(),
                leaseDuration: 30,
                allowedKinds: [.aiOperation, .searchRebuild]
            )?.id,
            bulk.id
        )
    }

    func testFailedAndCancelledCoalescedJobsCanBeReplaced() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let failedRequest = PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            idempotencyKey: "replace-failed",
            replaceTerminalDuplicate: true
        )
        let failed = try store.enqueueJob(failedRequest)
        let failedRunning = try XCTUnwrap(store.claimNextJob())
        try store.failJob(
            id: failed.id,
            leaseToken: try XCTUnwrap(failedRunning.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )
        let failedReplacement = try store.enqueueJob(failedRequest)
        XCTAssertNotEqual(failedReplacement.id, failed.id)
        XCTAssertEqual(failedReplacement.state, .queued)
        XCTAssertEqual(try store.job(id: failed.id).state, .failed)

        try store.requestJobCancellation(id: failedReplacement.id)
        let cancelledReplacement = try store.enqueueJob(failedRequest)
        XCTAssertNotEqual(cancelledReplacement.id, failedReplacement.id)
        XCTAssertEqual(cancelledReplacement.state, .queued)
        XCTAssertEqual(try store.job(id: failedReplacement.id).state, .cancelled)
    }

    func testUserInitiatedSyncsReconcileServerReadState() {
        XCTAssertTrue(LocalOperationRuntime.shouldReconcileRemoteState(for: .accountSetup))
        XCTAssertTrue(LocalOperationRuntime.shouldReconcileRemoteState(for: .manual))
        XCTAssertTrue(LocalOperationRuntime.shouldReconcileRemoteState(for: .schedule))
        XCTAssertFalse(LocalOperationRuntime.shouldReconcileRemoteState(for: .realTimeSignal))
    }

    func testManualSyncUpgradesQueuedRealtimeSyncWithoutCreatingADuplicateJob() async throws {
        let messageID = MessageID(
            IMAPSyncService.localMessageID(
                accountID: AccountID("acc_realtime_manual"),
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1
            )
        )
        let remoteMessage = MessageSummary(
            id: messageID,
            threadID: nil,
            from: EmailAddress("alice@example.com"),
            subject: "Realtime then manual",
            preview: "Reconcile the seen flag",
            body: "Reconcile the seen flag",
            smartCategory: .personal,
            isSeen: true
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "sync-secret",
            message: remoteMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: AccountID("acc_realtime_manual"),
            displayName: "Realtime Manual",
            email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([account])
        try store.cacheMessageReliably(remoteMessage.withSeen(false))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: messageID
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("sync-secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let realtime = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: account.id,
                trigger: .realTimeSignal,
                scope: .incremental
            )
        )
        let manual = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: account.id,
                trigger: .manual,
                scope: .incremental
            )
        )

        XCTAssertEqual(manual.id, realtime.id)
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync]
        )
        let processed = try await runtime.processNextJob()
        XCTAssertEqual(processed?.id, realtime.id)
        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: messageID)).isSeen)
        XCTAssertEqual(try store.job(id: realtime.id).attempt, 1)
        let followUp = try await runtime.processNextJob()
        XCTAssertNil(followUp)
    }

    func testScheduleSignalDuringRunningRealtimeSyncReconcilesWithinOneDurableJob() async throws {
        let accountID = AccountID("acc_running_realtime_schedule")
        let messageID = MessageID(
            IMAPSyncService.localMessageID(
                accountID: accountID,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1
            )
        )
        let remoteMessage = MessageSummary(
            id: messageID,
            threadID: nil,
            from: EmailAddress("alice@example.com"),
            subject: "Running realtime then schedule",
            preview: "Reconcile after the realtime pass begins",
            body: "Reconcile after the realtime pass begins",
            smartCategory: .personal,
            isSeen: true
        )
        let sessionGate = OneShotIMAPSessionGate()
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "sync-secret",
            message: remoteMessage,
            onSessionStart: { sessionGate.sessionStarted() }
        )
        try await imap.start()
        defer { imap.stop() }
        defer { sessionGate.releaseFirstSession() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: accountID,
            displayName: "Running Realtime Schedule",
            email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([account])
        try store.cacheMessageReliably(remoteMessage.withSeen(false))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: messageID
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("sync-secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let realtime = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .realTimeSignal, scope: .incremental)
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync]
        )

        let processing = Task { try await runtime.processNextJob() }
        XCTAssertTrue(sessionGate.waitForFirstSession())
        let scheduled = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .schedule, scope: .incremental)
        )
        XCTAssertEqual(scheduled.id, realtime.id)
        XCTAssertEqual(
            try store.jobs(limit: 100).filter {
                ($0.kind == .inboxSync || $0.kind == .historicalSync)
                    && [.queued, .running, .paused].contains($0.state)
            }.map(\.id),
            [realtime.id]
        )

        sessionGate.releaseFirstSession()
        let completed = try await processing.value

        XCTAssertEqual(completed?.id, realtime.id)
        XCTAssertEqual(try store.job(id: realtime.id).state, .completed)
        XCTAssertEqual(imap.messageStateFetchCount, 1)
        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: messageID)).isSeen)
        let followUp = try await runtime.processNextJob()
        XCTAssertNil(followUp)
    }

    func testCancellationRequestedRealtimeTerminalsBeforeScheduledSuccessorExecutes() async throws {
        let accountID = AccountID("acc_cancelled_realtime_successor")
        let messageID = MessageID(
            IMAPSyncService.localMessageID(
                accountID: accountID,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1
            )
        )
        let remoteMessage = MessageSummary(
            id: messageID,
            threadID: nil,
            from: EmailAddress("alice@example.com"),
            subject: "Cancelled realtime successor",
            preview: "The scheduled successor must reconcile this flag",
            body: "The scheduled successor must reconcile this flag",
            smartCategory: .personal,
            isSeen: true
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "sync-secret",
            message: remoteMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: accountID,
            displayName: "Cancelled Realtime Successor",
            email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([account])
        try store.cacheMessageReliably(remoteMessage.withSeen(false))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: messageID
        )
        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data("sync-secret".utf8),
            for: accountIMAPPasswordKey(account.id)
        )
        let realtime = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .realTimeSignal, scope: .incremental)
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.requestJobCancellation(id: realtime.id)
        let scheduled = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .schedule, scope: .incremental)
        )
        try store.acknowledgeJobCancellation(
            id: realtime.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )

        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync]
        )
        let processed = try await runtime.processNextJob()

        XCTAssertNotEqual(scheduled.id, realtime.id)
        XCTAssertEqual(try store.job(id: realtime.id).state, .cancelled)
        XCTAssertEqual(processed?.id, scheduled.id)
        XCTAssertEqual(try store.job(id: scheduled.id).state, .completed)
        XCTAssertEqual(imap.messageStateFetchCount, 1)
        XCTAssertTrue(try XCTUnwrap(store.messageSummary(id: messageID)).isSeen)
    }

    func testRuntimeSyncsSeparateAccountsConcurrentlyThroughLocalIMAP() async throws {
        let overlap = IMAPSessionOverlapProbe(expectedSessions: 2)
        let firstServer = LocalIMAPServer(
            username: "first@example.com",
            password: "first-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionStart: { overlap.sessionStarted() },
            onSessionEnd: { overlap.sessionEnded() }
        )
        let secondServer = LocalIMAPServer(
            username: "second@example.com",
            password: "second-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionStart: { overlap.sessionStarted() },
            onSessionEnd: { overlap.sessionEnded() }
        )
        try await firstServer.start()
        try await secondServer.start()
        defer {
            firstServer.stop()
            secondServer.stop()
        }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let firstAccount = Account(
            id: AccountID("acc_parallel_first"),
            displayName: "First",
            email: EmailAddress("first@example.com"),
            imapHost: "127.0.0.1",
            imapPort: firstServer.port,
            smtpHost: "127.0.0.1"
        )
        let secondAccount = Account(
            id: AccountID("acc_parallel_second"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "127.0.0.1",
            imapPort: secondServer.port,
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([firstAccount, secondAccount])
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data("first-secret".utf8), for: accountIMAPPasswordKey(firstAccount.id))
        try await credentials.store(Data("second-secret".utf8), for: accountIMAPPasswordKey(secondAccount.id))
        let firstJob = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: firstAccount.id, trigger: .manual, scope: .incremental)
        )
        let secondJob = try store.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(accountID: secondAccount.id, trigger: .manual, scope: .incremental)
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync]
        )

        async let firstProcessed = runtime.processNextJob()
        async let secondProcessed = runtime.processNextJob()
        let processed = try await [firstProcessed, secondProcessed].compactMap { $0 }

        XCTAssertEqual(Set(processed.map(\.id)), Set([firstJob.id, secondJob.id]))
        XCTAssertEqual(overlap.maximumConcurrentSessions, 2)
        XCTAssertEqual(try store.job(id: firstJob.id).attempt, 1)
        XCTAssertEqual(try store.job(id: secondJob.id).attempt, 1)
        XCTAssertEqual(firstServer.loginAttempts.count, 1)
        XCTAssertEqual(secondServer.loginAttempts.count, 1)
    }

    func testSyncAppliesRulesAndReturnsExactSuppressedIDs() async throws {
        let password = "rule-sync-secret"
        let imap = LocalIMAPServer(
            username: "rules@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Account(
            id: AccountID("acc_rule_sync"),
            displayName: "Rule Sync",
            email: EmailAddress("rules@example.com"),
            username: "rules@example.com",
            imapHost: "127.0.0.1",
            imapPort: imap.port,
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([account])
        try store.saveMailRule(try MailRule.validated(
            id: "silent-alice",
            name: "Silent Alice",
            scope: .account(account.id),
            conditions: [
                .init(
                    field: .from,
                    operator: .emailIs,
                    value: PlainpostFixtures.aliceMessage.from.rawValue
                ),
            ],
            actions: [.skipInbox, .suppressNotification]
        ))
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data(password.utf8), for: accountIMAPPasswordKey(account.id))
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.inboxSync, .historicalSync]
        ))
        let expectedID = MessageID(IMAPSyncService.localMessageID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1
        ))

        let result = try await client.executeInboxSync(.init(
            accountID: account.id,
            trigger: .manual,
            scope: .incremental
        ))

        XCTAssertEqual(result.newMessageIDs, [expectedID])
        XCTAssertEqual(result.suppressedNotificationMessageIDs, [expectedID])
        XCTAssertTrue(try store.hasMailRuleAction(.skipInbox, messageID: expectedID))
    }

    func testConfirmedExistingRuleRunUsesPreviewSnapshot() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = localAccount(port: 1)
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx-existing-inbox"),
                accountID: account.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
            Mailbox(
                id: MailboxID("mbx-existing-archive"),
                accountID: account.id,
                name: "Archive",
                path: "Archive",
                specialUse: "\\Archive"
            ),
        ])
        func insert(_ id: String, uid: Int) throws {
            try store.cacheMessageReliably(MessageSummary(
                id: MessageID(id),
                threadID: nil,
                from: EmailAddress("noise@example.com"),
                subject: id,
                preview: "Preview",
                smartCategory: .notification,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false
            ))
            try store.recordCachedUID(
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: uid,
                messageID: MessageID(id)
            )
        }
        try insert("msg-existing-1", uid: 1)
        try insert("msg-existing-2", uid: 2)
        let rule = try MailRule.validated(
            id: "existing-noise",
            name: "Existing noise",
            scope: .account(account.id),
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.skipInbox, .markAsRead, .suppressNotification]
        )
        let processor = MailRuleProcessor(store: store)

        let preview = try processor.previewExisting(rule: rule)
        try insert("msg-existing-later", uid: 3)
        let run = try processor.applyExisting(rule: rule, preview: preview)

        XCTAssertEqual(preview.archiveCount, 2)
        XCTAssertEqual(preview.markReadCount, 2)
        XCTAssertEqual(preview.countsByAccount[account.id], .init(archiveCount: 2, markReadCount: 2))
        XCTAssertEqual(Set(run.messageIDs), [MessageID("msg-existing-1"), MessageID("msg-existing-2")])
        XCTAssertFalse(run.messageIDs.contains(MessageID("msg-existing-later")))
    }

    func testNewerSyncGenerationCannotBeOverwrittenByOlderCompletion() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let first = try store.enqueueJob(try Self.syncRequest(key: "sync-first"))
        let claimedFirst = try XCTUnwrap(store.claimNextJob())
        let second = try store.enqueueJob(try Self.syncRequest(key: "sync-second"))

        try store.completeJob(
            id: claimedFirst.id,
            leaseToken: try XCTUnwrap(claimedFirst.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSync)
        XCTAssertEqual(try store.job(id: second.id).state, .queued)
        XCTAssertEqual(first.id, claimedFirst.id)
    }

    func testEnablingAdditionalMailboxInvalidatesReadinessUntilExpandedSyncCompletes() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)

        try store.saveMailboxSyncPreference(
            MailboxSyncPreference(
                accountID: PlainpostFixtures.personalAccount.id,
                mailboxPath: "Projects",
                mode: .recent
            )
        )

        try assertExpandedScopeBlocksOrganizerUntilRecentSyncCompletes(
            store: store,
            key: "expanded-mailbox"
        )
    }

    func testIncreasingRecentLimitInvalidatesReadinessUntilExpandedSyncCompletes() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)

        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: PlainpostFixtures.personalAccount.id,
                recentMessageLimit: 250
            )
        )

        try assertExpandedScopeBlocksOrganizerUntilRecentSyncCompletes(
            store: store,
            key: "expanded-recent-limit"
        )
    }

    func testEnablingCompleteHistoryInvalidatesReadinessUntilHistoricalSyncCompletes() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)

        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: PlainpostFixtures.personalAccount.id,
                downloadCompleteHistory: true
            )
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
        let organizer = try enqueueOrganizer(store: store, key: "blocked-complete-history")
        let incremental = try store.enqueueJob(
            try Self.syncRequest(
                key: "expanded-complete-history-incremental",
                scope: .incremental
            )
        )
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild]))
        let claimedIncremental = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedIncremental.id, incremental.id)
        try store.completeJob(
            id: claimedIncremental.id,
            leaseToken: try XCTUnwrap(claimedIncremental.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)

        let historical = try store.enqueueJob(
            try Self.syncRequest(
                key: "expanded-complete-history-full",
                scope: .completeHistory
            )
        )
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild]))
        let claimedHistorical = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedHistorical.id, historical.id)
        try store.completeJob(
            id: claimedHistorical.id,
            leaseToken: try XCTUnwrap(claimedHistorical.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
        XCTAssertEqual(
            try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])?.id,
            organizer.id
        )
    }

    func testOlderActiveSyncBlocksOrganizerAfterNewerSyncCompletes() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let older = try store.enqueueJob(try Self.syncRequest(key: "older-active", priority: 10))
        let newer = try store.enqueueJob(try Self.syncRequest(key: "newer-first", priority: 100))
        let claimedNewer = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedNewer.id, newer.id)
        try store.completeJob(
            id: claimedNewer.id,
            leaseToken: try XCTUnwrap(claimedNewer.leaseToken),
            resultArtifactID: nil
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "test"
        )
        let organizer = try store.enqueueJob(
            try Self.aiRequest(input: organizerInput, priority: 50, key: "blocked-by-older-sync")
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSync)
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild]))
        XCTAssertEqual(try store.job(id: organizer.id).state, .queued)

        let claimedOlder = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedOlder.id, older.id)
        try store.completeJob(
            id: claimedOlder.id,
            leaseToken: try XCTUnwrap(claimedOlder.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
        XCTAssertEqual(
            try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])?.id,
            organizer.id
        )
    }

    func testTerminalSyncFailureRequiresSuccessfulRetry() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.enqueueJob(try Self.syncRequest(key: "sync-fails"))
        let claimed = try XCTUnwrap(store.claimNextJob())

        try store.failJob(
            id: claimed.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
    }

    func testExpiredCancelledSyncRequiresSuccessfulRetry() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.enqueueJob(try Self.syncRequest(key: "sync-cancelled-after-expiry"))
        let start = Date()
        let running = try XCTUnwrap(store.claimNextJob(now: start, leaseDuration: 10))

        try store.requestJobCancellation(id: running.id)
        XCTAssertNil(try store.claimNextJob(now: start.addingTimeInterval(11), leaseDuration: 10))

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
    }

    func testRetryableSyncFailureRemainsPendingUntilCompletion() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let sync = try store.enqueueJob(try Self.syncRequest(key: "sync-retry"))
        let running = try XCTUnwrap(store.claimNextJob())

        try store.failJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            code: "TEMPORARY",
            message: "retry",
            retryAt: Date()
        )
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSync)

        let retried = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: retried.id,
            leaseToken: try XCTUnwrap(retried.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
    }

    func testSuccessfulSyncGenerationRecoversTerminalFailure() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.enqueueJob(try Self.syncRequest(key: "failed-generation"))
        let failed = try XCTUnwrap(store.claimNextJob())
        try store.failJob(
            id: failed.id,
            leaseToken: try XCTUnwrap(failed.leaseToken),
            code: "TERMINAL",
            message: "failed",
            retryAt: nil
        )

        _ = try store.enqueueJob(try Self.syncRequest(key: "successful-generation"))
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSync)
        let successful = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: successful.id,
            leaseToken: try XCTUnwrap(successful.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
    }

    func testCancellingQueuedSyncRequiresSuccessfulSync() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let sync = try store.enqueueJob(try Self.syncRequest(key: "queued-cancel"))

        try store.requestJobCancellation(id: sync.id)

        XCTAssertEqual(try store.job(id: sync.id).state, .cancelled)
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
    }

    func testEveryAccountMustHaveSuccessfulSyncReadiness() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let secondAccount = Account(
            id: AccountID("acc_second"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([PlainpostFixtures.personalAccount, secondAccount])

        _ = try store.enqueueJob(try Self.syncRequest(key: "only-first-account"))
        let firstSync = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: firstSync.id,
            leaseToken: try XCTUnwrap(firstSync.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
    }

    func testBlockedOrganizerDoesNotStarveInteractiveAIWork() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheOwnedTestMessage(MessageSummary(
            id: MessageID("msg_1"),
            threadID: ThreadID("thr_1"),
            from: EmailAddress("sender@example.com"),
            subject: "Interactive fixture",
            preview: "Interactive fixture",
            smartCategory: .unknown
        ))
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "test"
        )
        let organizer = try store.enqueueJob(
            try Self.aiRequest(input: organizerInput, priority: 200, key: "blocked-organizer")
        )
        let interactiveInput = PlainpostAIOperationInput(
            operation: .summarizeMessage,
            recordID: "msg_1",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "test"
        )
        let interactive = try store.enqueueJob(
            try Self.aiRequest(input: interactiveInput, priority: 100, key: "interactive-ai")
        )
        _ = try store.enqueueJob(try Self.syncRequest(key: "active-sync-blocks-organizer"))

        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])
        )

        XCTAssertEqual(claimed.id, interactive.id)
        XCTAssertEqual(try store.job(id: organizer.id).state, .queued)
    }

    func testActiveAIRunnerDoesNotStarveUnrelatedEligibleWork() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let activeAI = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 300,
                idempotencyKey: "active-ai"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(running.id, activeAI.id)
        _ = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                priority: 200,
                idempotencyKey: "queued-ai"
            )
        )
        let unrelated = try store.enqueueJob(
            try Self.syncRequest(key: "unrelated-delivery", priority: 100)
        )

        let claimed = try store.claimNextJob()

        XCTAssertEqual(claimed?.id, unrelated.id)
    }

    func testExplicitAllowedKindsSerializeMailWorkerGroupAcrossStores() throws {
        let (firstStore, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let secondStore = try SQLiteMailStore(path: url.path)
        try secondStore.migrate()
        let mailKinds: Set<PlainpostOperationKind> = [
            .inboxSync, .historicalSync, .approvedDelivery, .denySend,
        ]
        _ = try firstStore.enqueueJob(
            try Self.syncRequest(key: "mail-runner-active", priority: 200)
        )
        XCTAssertNotNil(try firstStore.claimNextJob(allowedKinds: mailKinds))
        _ = try firstStore.enqueueJob(
            try Self.syncRequest(key: "mail-runner-second", priority: 100)
        )

        XCTAssertNil(try secondStore.claimNextJob(allowedKinds: mailKinds))
    }

    func testUnscopedWorkersKeepOneSyncPerAccountAndAllowSeparateAccounts() throws {
        let (firstStore, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let secondStore = try SQLiteMailStore(path: url.path)
        try secondStore.migrate()
        let firstAccount = AccountID("acc_unscoped_first")
        let secondAccount = AccountID("acc_unscoped_second")
        try firstStore.cacheAccounts([
            Account(
                id: firstAccount,
                displayName: "Unscoped First",
                email: EmailAddress("first@example.com"),
                imapHost: "127.0.0.1",
                smtpHost: "127.0.0.1"
            ),
            Account(
                id: secondAccount,
                displayName: "Unscoped Second",
                email: EmailAddress("second@example.com"),
                imapHost: "127.0.0.1",
                smtpHost: "127.0.0.1"
            ),
        ])
        let realtime = try firstStore.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: firstAccount,
                trigger: .realTimeSignal,
                scope: .incremental
            ),
            priority: 300
        )
        let reconciling = try firstStore.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: firstAccount,
                trigger: .manual,
                scope: .incremental
            ),
            priority: 200
        )
        let independent = try firstStore.enqueueCoalescedInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: secondAccount,
                trigger: .manual,
                scope: .incremental
            ),
            priority: 100
        )

        XCTAssertEqual(reconciling.id, realtime.id)

        let firstClaim = try XCTUnwrap(firstStore.claimNextJob())
        XCTAssertEqual(firstClaim.id, realtime.id)
        let concurrentClaim = try XCTUnwrap(secondStore.claimNextJob())
        XCTAssertEqual(
            concurrentClaim.id,
            independent.id,
            "An unscoped production worker must skip a same-account sync while allowing another account."
        )
        XCTAssertNil(try secondStore.claimNextJob())

        try firstStore.completeJob(
            id: firstClaim.id,
            leaseToken: try XCTUnwrap(firstClaim.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertNil(try secondStore.claimNextJob())
    }

    func testForegroundAndProductionMailboxWorkersCannotClaimOppositeFlagsConcurrently() throws {
        let (firstStore, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let secondStore = try SQLiteMailStore(path: url.path)
        try secondStore.migrate()
        try firstStore.cacheOwnedTestMessage(PlainpostFixtures.aliceMessage.withSeen(false))
        _ = try firstStore.openMessageForHuman(
            PlainpostFixtures.aliceMessage.id,
            actor: PlainpostFixtures.guiUser
        )
        _ = try firstStore.markSeen(
            PlainpostFixtures.aliceMessage.id,
            seen: false,
            actor: PlainpostFixtures.guiUser
        )

        let first = try XCTUnwrap(
            firstStore.claimNextJob(
                allowedKinds: PlainpostBackgroundAgentJobPolicy.allowedKinds
            )
        )
        let firstInput = try JSONDecoder().decode(
            PlainpostMailboxFlagInput.self,
            from: Data(first.payloadJSON.utf8)
        )
        XCTAssertTrue(firstInput.desiredSeen)
        XCTAssertNil(
            try secondStore.claimNextJob(allowedKinds: [.mailboxFlag]),
            "A foreground worker must not overlap the packaged mailbox worker."
        )

        try firstStore.completeJob(
            id: first.id,
            leaseToken: try XCTUnwrap(first.leaseToken),
            resultArtifactID: nil
        )
        let contrary = try XCTUnwrap(
            secondStore.claimNextJob(allowedKinds: [.mailboxFlag])
        )
        let contraryInput = try JSONDecoder().decode(
            PlainpostMailboxFlagInput.self,
            from: Data(contrary.payloadJSON.utf8)
        )
        XCTAssertFalse(contraryInput.desiredSeen)
    }

    func testOccupiedMailGroupDoesNotStarveLowerEligibleAIGroup() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let mailKinds: Set<PlainpostOperationKind> = [
            .inboxSync, .historicalSync, .approvedDelivery, .denySend,
        ]
        _ = try store.enqueueJob(
            try Self.syncRequest(key: "occupied-mail-group", priority: 300)
        )
        XCTAssertNotNil(try store.claimNextJob(allowedKinds: mailKinds))
        _ = try store.enqueueJob(
            try Self.syncRequest(key: "blocked-mail-candidate", priority: 200)
        )
        let lowerAI = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                priority: 100,
                idempotencyKey: "lower-ai-candidate"
            )
        )

        let claimed = try store.claimNextJob(allowedKinds: mailKinds.union([.aiOperation, .searchRebuild]))

        XCTAssertEqual(claimed?.id, lowerAI.id)
    }

    func testEnqueueIsIdempotentAndClaimUsesFiniteLease() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try Self.syncRequest(key: "sync:acc_one", priority: 10)

        let first = try store.enqueueJob(request)
        let duplicate = try store.enqueueJob(request)
        XCTAssertEqual(first.id, duplicate.id)

        let claimed = try XCTUnwrap(store.claimNextJob(now: Date(), leaseDuration: 30))
        XCTAssertEqual(claimed.id, first.id)
        XCTAssertEqual(claimed.state, .running)
        XCTAssertEqual(claimed.attempt, 1)
        XCTAssertNotNil(claimed.leaseToken)
        XCTAssertNotNil(claimed.leaseExpiresAt)
        XCTAssertNil(try store.claimNextJob(now: Date(), leaseDuration: 30))
    }

    func testExpiredJobIsReclaimedAndCompletedWithOriginalId() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let request = PlainpostJobRequest(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            idempotencyKey: "search:all"
        )
        let queued = try store.enqueueJob(request)
        let start = Date()
        _ = try store.claimNextJob(now: start, leaseDuration: 10)

        let reclaimed = try XCTUnwrap(store.claimNextJob(now: start.addingTimeInterval(11), leaseDuration: 10))
        XCTAssertEqual(reclaimed.id, queued.id)
        XCTAssertEqual(reclaimed.attempt, 2)
        let token = try XCTUnwrap(reclaimed.leaseToken)
        let artifact = DurableOperationArtifact(
            id: "artifact",
            kind: PlainpostAIOperationKind.rebuildIndex.rawValue,
            recordID: "",
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostLocalAIArtifactPayload(indexedMessageCount: 0)
            ), as: UTF8.self)
        )
        try store.saveDurableOperationArtifact(artifact, forJobID: reclaimed.id)
        try store.completeJob(id: reclaimed.id, leaseToken: token, resultArtifactID: artifact.id)
        XCTAssertEqual(try store.job(id: queued.id).state, .completed)
        XCTAssertEqual(try store.job(id: queued.id).resultArtifactID, "artifact")
    }

    func testClaimSkipsAcknowledgedManualPause() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let paused = try enqueueOrganizer(store: store, key: "manual-pause-claim")
        try store.requestJobPause(id: paused.id)

        XCTAssertNil(
            try store.claimNextJob(
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(try store.job(id: paused.id).state, .paused)
        XCTAssertEqual(try store.job(id: paused.id).pauseReason, "user-requested")
    }

    func testManualPauseCannotPreemptRunningWork() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let paused = try enqueueOrganizer(store: store, key: "manual-pause-preemption")
        try store.requestJobPause(id: paused.id)

        XCTAssertNil(
            try store.nextPendingJob(
                higherPriorityThan: 0,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
    }

    func testExpiredPauseRequestBecomesManualPauseBeforeNextClaim() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pausing = try enqueueOrganizer(store: store, key: "expired-pause-request")
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(running.id, pausing.id)
        try store.requestJobPause(id: pausing.id)
        let next = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                priority: 0,
                idempotencyKey: "search-after-manual-pause"
            )
        )

        let claimed = try XCTUnwrap(
            store.claimNextJob(
                now: start.addingTimeInterval(11),
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        let recovered = try store.job(id: pausing.id)

        XCTAssertEqual(claimed.id, next.id)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(recovered.pauseReason, "user-requested")
        XCTAssertFalse(recovered.pauseRequested)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertNil(recovered.leaseExpiresAt)
    }

    func testExpiredCancellationWinsOverPauseRequestBeforeNextClaim() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let cancelling = try enqueueOrganizer(store: store, key: "expired-cancel-and-pause")
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(running.id, cancelling.id)
        try store.requestJobPause(id: cancelling.id)
        try store.requestJobCancellation(id: cancelling.id)
        let next = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                priority: 0,
                idempotencyKey: "search-after-cancelled-pause"
            )
        )

        let claimed = try XCTUnwrap(
            store.claimNextJob(
                now: start.addingTimeInterval(11),
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )

        XCTAssertEqual(claimed.id, next.id)
        XCTAssertEqual(try store.job(id: cancelling.id).state, .cancelled)
    }

    func testBackgroundRecoveryAcknowledgesExpiredManualPauseRequest() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pausing = try enqueueOrganizer(store: store, key: "background-expired-pause")
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(running.id, pausing.id)
        try store.requestJobPause(id: pausing.id)

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation, .searchRebuild],
            now: start.addingTimeInterval(11)
        )
        let recovered = try store.job(id: pausing.id)

        XCTAssertEqual(summary.requeuedExpiredCount, 0)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(recovered.pauseReason, "user-requested")
        XCTAssertFalse(recovered.pauseRequested)
        XCTAssertNil(recovered.leaseToken)
        XCTAssertNil(recovered.leaseExpiresAt)
    }

    func testBackgroundRecoveryPostsOperationsChangeForPauseOnlyRecovery() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pausing = try enqueueOrganizer(store: store, key: "background-pause-notification")
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(running.id, pausing.id)
        try store.requestJobPause(id: pausing.id)
        let notifications = OperationsNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            notifications.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation, .searchRebuild],
            now: start.addingTimeInterval(11)
        )

        XCTAssertEqual(summary.requeuedExpiredCount, 0)
        XCTAssertEqual(summary.cancelledDuplicateCount, 0)
        XCTAssertEqual(notifications.scopes, [.operations])
    }

    func testClaimPostsOperationsChangeWhenOnlyRecoveryAcknowledgesPause() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try establishReadySyncScope(store: store)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pausing = try enqueueOrganizer(store: store, key: "claim-pause-notification")
        let running = try XCTUnwrap(
            store.claimNextJob(
                now: start,
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )
        XCTAssertEqual(running.id, pausing.id)
        try store.requestJobPause(id: pausing.id)
        let notifications = OperationsNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            notifications.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertNil(
            try store.claimNextJob(
                now: start.addingTimeInterval(11),
                leaseDuration: 10,
                allowedKinds: [.aiOperation, .searchRebuild]
            )
        )

        XCTAssertEqual(try store.job(id: pausing.id).state, .paused)
        XCTAssertEqual(notifications.scopes, [.operations])
    }

    func testAutomaticSchedulerPauseRemainsClaimable() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                idempotencyKey: "automatic-scheduler-pause"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.pauseJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            reason: "scheduler-preempted",
            progress: .init(
                current: 0,
                total: 1,
                phase: "paused",
                label: "Search"
            )
        )

        let resumed = try XCTUnwrap(store.claimNextJob())

        XCTAssertEqual(resumed.id, job.id)
        XCTAssertEqual(resumed.state, .running)
        XCTAssertNil(resumed.pauseReason)
    }

    func testRestrictedClaimCannotTakeAIWorkIntoTheMailProcess() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let aiJob = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                priority: 100,
                idempotencyKey: "ai:isolated"
            )
        )
        let syncJob = try store.enqueueJob(
            try Self.syncRequest(key: "sync:local", priority: 10)
        )

        let claimed = try XCTUnwrap(
            store.claimNextJob(
                now: Date(),
                leaseDuration: 30,
                allowedKinds: [.inboxSync, .historicalSync, .approvedDelivery, .denySend]
            )
        )

        XCTAssertEqual(claimed.id, syncJob.id)
        XCTAssertEqual(try store.job(id: aiJob.id).state, .queued)
    }

    func testPreferencesDefaultToRecentOneHundredAndPersistCompleteHistory() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let accountID = AccountID("acc_one")
        XCTAssertEqual(try store.syncPreferences(accountID: accountID).recentMessageLimit, 100)
        XCTAssertFalse(try store.syncPreferences(accountID: accountID).downloadCompleteHistory)

        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: accountID,
                downloadCompleteHistory: true,
                recentMessageLimit: 250,
                realTimeMonitoringEnabled: true
            )
        )
        let saved = try store.syncPreferences(accountID: accountID)
        XCTAssertTrue(saved.downloadCompleteHistory)
        XCTAssertEqual(saved.recentMessageLimit, 250)
    }

    func testMailboxSelectionIncludesImplicitlyEnabledInboxAlongsidePersistedMailboxes() {
        let accountID = AccountID("acc_one")
        let selected = MailboxSyncSelection.selectedMailboxPaths(
            availableMailboxPaths: ["INBOX", "Archive", "Sent"],
            preferences: [
                MailboxSyncPreference(accountID: accountID, mailboxPath: "Archive", mode: .complete),
                MailboxSyncPreference(accountID: accountID, mailboxPath: "Sent", mode: .complete)
            ]
        )

        XCTAssertEqual(selected, ["Archive", "INBOX", "Sent"])
    }

    func testMailboxSelectionDefaultsToRecentForSpecialUseSentAndArchive() {
        let accountID = AccountID("acc_one")
        let selected = MailboxSyncSelection.selectedMailboxPaths(
            availableMailboxes: [
                Mailbox(id: MailboxID("mbx_inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                Mailbox(id: MailboxID("mbx_archive"), accountID: accountID, name: "Archive", path: "Archive", specialUse: "\\Archive"),
                Mailbox(id: MailboxID("mbx_sent"), accountID: accountID, name: "Sent", path: "Sent", specialUse: "\\Sent"),
                Mailbox(id: MailboxID("mbx_projects"), accountID: accountID, name: "Projects", path: "Projects", specialUse: nil)
            ],
            preferences: []
        )

        XCTAssertEqual(selected, ["Archive", "INBOX", "Sent"])
    }

    /// The phone's Drafts folder shows drafts written in other mail apps.
    func testMailboxSelectionDefaultsToRecentForSpecialUseDrafts() {
        let accountID = AccountID("acc_one")
        let selected = MailboxSyncSelection.selectedMailboxPaths(
            availableMailboxes: [
                Mailbox(id: MailboxID("mbx_inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                Mailbox(id: MailboxID("mbx_drafts"), accountID: accountID, name: "Drafts", path: "[Gmail]/Drafts", specialUse: "\\Drafts"),
                Mailbox(id: MailboxID("mbx_plain"), accountID: accountID, name: "Drafts", path: "Drafts", specialUse: nil)
            ],
            preferences: []
        )

        XCTAssertEqual(selected, ["[Gmail]/Drafts", "INBOX"])
    }

    func testMailboxSelectionRespectsExplicitlyDisabledInbox() {
        let accountID = AccountID("acc_one")
        let selected = MailboxSyncSelection.selectedMailboxPaths(
            availableMailboxPaths: ["INBOX", "Archive"],
            preferences: [
                MailboxSyncPreference(accountID: accountID, mailboxPath: "inbox", mode: .off),
                MailboxSyncPreference(accountID: accountID, mailboxPath: "Archive", mode: .recent)
            ]
        )

        XCTAssertEqual(selected, ["Archive"])
    }

    func testMailboxSelectionKeepsCaseDistinctNonInboxPaths() {
        let accountID = AccountID("acc_one")
        let selected = MailboxSyncSelection.selectedMailboxPaths(
            availableMailboxPaths: ["INBOX", "Projects/Foo", "Projects/foo"],
            preferences: [
                MailboxSyncPreference(accountID: accountID, mailboxPath: "Projects/Foo", mode: .recent),
                MailboxSyncPreference(accountID: accountID, mailboxPath: "Projects/foo", mode: .complete)
            ]
        )

        XCTAssertEqual(Set(selected), Set(["INBOX", "Projects/Foo", "Projects/foo"]))
    }

    func testFTSSearchesBodyAndDoesNotInventAttachmentContent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let messageID = MessageID("msg_search")
        let account = Account(
            id: AccountID("search-account"),
            displayName: "Search",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: messageID,
                threadID: nil,
                from: EmailAddress("alice@example.com"),
                subject: "Quarterly plans",
                preview: "Roadmap",
                body: "The comet project ships on Friday.",
                smartCategory: .personal
            ),
            metadata: .init(
                to: [EmailAddress("bob@example.com")],
                cc: [],
                bcc: [],
                attachments: [.init(
                    filename: "budget-2026.xlsx",
                    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                )],
                messageIdentifiers: ["<message@example.com>"]
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let service = SQLiteMailSearchService(store: store)
        let messageIDs = { (response: MailSearchResponse) in
            response.hits.compactMap { hit -> MessageID? in
                guard case .message(let message) = hit else { return nil }
                return message.messageID
            }
        }
        let bodyResponse = try await service.search(.init(query: "comet", mode: .messages))
        let filenameResponse = try await service.search(
            .init(query: "filename:budget", mode: .messages)
        )
        let recipientResponse = try await service.search(
            .init(query: "to:bob@example.com", mode: .messages)
        )
        let attachmentContentResponse = try await service.search(
            .init(query: "spreadsheet-cell-secret", mode: .messages)
        )
        XCTAssertEqual(messageIDs(bodyResponse), [messageID])
        XCTAssertEqual(messageIDs(filenameResponse), [messageID])
        XCTAssertEqual(messageIDs(recipientResponse), [messageID])
        XCTAssertTrue(messageIDs(attachmentContentResponse).isEmpty)
    }

    private func makeStore() throws -> (SQLiteMailStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-operations-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        return (store, url)
    }

    private func localAccount(port: UInt16) -> Account {
        Account(
            id: AccountID("acc_mailbox_flag"),
            displayName: "Mailbox Flag",
            email: EmailAddress("me@example.com"),
            username: "me@example.com",
            imapHost: "127.0.0.1",
            imapPort: port,
            smtpHost: "smtp.example.com"
        )
    }

    private func emptySearchMetadata() -> IncomingMessageSearchMetadata {
        IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        )
    }

    private func enqueueMailboxFlag(
        _ input: PlainpostMailboxFlagInput,
        in store: SQLiteMailStore
    ) throws -> PlainpostDurableJob {
        let data = try JSONEncoder().encode(input)
        return try store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(decoding: data, as: UTF8.self),
                idempotencyKey: "test-mailbox-flag:\(input.messageID.rawValue):\(input.desiredSeen)"
            )
        )
    }

    private func establishReadySyncScope(store: SQLiteMailStore) throws {
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx_inbox"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
            Mailbox(
                id: MailboxID("mbx_archive"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: "Archive",
                path: "Archive",
                specialUse: "\\Archive"
            ),
            Mailbox(
                id: MailboxID("mbx_projects"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: "Projects",
                path: "Projects",
                specialUse: nil
            ),
        ])
        let initial = try store.enqueueJob(try Self.syncRequest(key: "initial-ready-scope"))
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimed.id, initial.id)
        try store.completeJob(
            id: claimed.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
    }

    private func assertExpandedScopeBlocksOrganizerUntilRecentSyncCompletes(
        store: SQLiteMailStore,
        key: String
    ) throws {
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
        let organizer = try enqueueOrganizer(store: store, key: "blocked-\(key)")
        let incremental = try store.enqueueJob(
            try Self.syncRequest(key: "\(key)-incremental", scope: .incremental)
        )
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild]))
        let claimedIncremental = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedIncremental.id, incremental.id)
        try store.completeJob(
            id: claimedIncremental.id,
            leaseToken: try XCTUnwrap(claimedIncremental.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)

        let expanded = try store.enqueueJob(try Self.syncRequest(key: "\(key)-recent"))
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild]))
        let claimedExpanded = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        XCTAssertEqual(claimedExpanded.id, expanded.id)
        try store.completeJob(
            id: claimedExpanded.id,
            leaseToken: try XCTUnwrap(claimedExpanded.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .ready)
        XCTAssertEqual(
            try store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])?.id,
            organizer.id
        )
    }

    private func enqueueOrganizer(store: SQLiteMailStore, key: String) throws -> PlainpostDurableJob {
        try store.enqueueJob(
            try Self.aiRequest(
                input: PlainpostAIOperationInput(
                    operation: .recategorizeInbox,
                    recordID: "",
                    providerID: "test"
                ),
                priority: 50,
                key: key
            )
        )
    }

    private static func syncRequest(
        key: String,
        priority: Int = 100,
        scope: PlainpostSyncScope = .recent
    ) throws -> PlainpostJobRequest {
        let input = PlainpostInboxSyncInput(
            accountID: PlainpostFixtures.personalAccount.id,
            trigger: .manual,
            scope: scope
        )
        let data = try JSONEncoder().encode(input)
        return PlainpostJobRequest(
            kind: .inboxSync,
            payloadJSON: String(decoding: data, as: UTF8.self),
            priority: priority,
            idempotencyKey: key
        )
    }

    private func approvalJob(
        kind: PlainpostOperationKind,
        input: PlainpostApprovalDecisionInput,
        priority: Int,
        key: String
    ) throws -> PlainpostJobRequest {
        PlainpostJobRequest(
            kind: kind,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: priority,
            maxAttempts: 1,
            idempotencyKey: key
        )
    }

    private static func aiRequest(
        input: PlainpostAIOperationInput,
        priority: Int,
        key: String
    ) throws -> PlainpostJobRequest {
        let data = try JSONEncoder().encode(input)
        return PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: String(decoding: data, as: UTF8.self),
            priority: priority,
            idempotencyKey: key
        )
    }

    private func overwriteLegacyJob(
        id: String,
        kind: PlainpostOperationKind,
        payloadJSON: String,
        databaseURL: URL
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw PlainpostError.validationFailed("Unable to open legacy job database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE durable_jobs SET kind = ?, payload_json = ?, max_attempts = 1 WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw PlainpostError.validationFailed("Unable to prepare legacy job update.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, payloadJSON, -1, transient)
        sqlite3_bind_text(statement, 3, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PlainpostError.validationFailed("Unable to write legacy job update.")
        }
    }

}
private actor RecordingSMTPClient: SMTPClientProtocol {
    private var calls = 0

    func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        calls += 1
    }

    func sendCount() -> Int {
        calls
    }
}

private enum FailureTimeTestError: Error {
    case transient
}

private struct AmbiguousSMTPClient: SMTPClientProtocol, Sendable {
    func send(
        username: String,
        password: String,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        throw SMTPClientError.connectionFailed
    }
}

private final class RuntimeSQLiteWriteLock: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private var didBegin = false
    private var isHeld = false

    init(databaseURL: URL) throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite writer connection.")
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func beginImmediate() throws {
        try lock.withLock {
            guard !didBegin else {
                throw PlainpostError.validationFailed("SQLite writer was acquired more than once.")
            }
            try executeLocked("BEGIN IMMEDIATE")
            didBegin = true
            isHeld = true
        }
    }

    func rollbackIfHeld() throws {
        try lock.withLock {
            guard isHeld else { return }
            try executeLocked("ROLLBACK")
            isHeld = false
        }
    }

    private func executeLocked(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not execute SQLite writer statement.")
        }
    }
}

private final class TranslationProviderResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class RuntimeSQLiteWriteLockHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: RuntimeSQLiteWriteLock?

    func install(_ writer: RuntimeSQLiteWriteLock) throws {
        try lock.withLock {
            guard self.writer == nil else {
                throw PlainpostError.validationFailed("SQLite writer was installed more than once.")
            }
            self.writer = writer
        }
    }

    func beginImmediate() throws {
        try requiredWriter().beginImmediate()
    }

    func rollbackIfHeld() throws {
        try requiredWriter().rollbackIfHeld()
    }

    private func requiredWriter() throws -> RuntimeSQLiteWriteLock {
        try lock.withLock {
            guard let writer else {
                throw PlainpostError.validationFailed("SQLite writer was not installed.")
            }
            return writer
        }
    }
}

private actor ControlledRemoteSeenState {
    private var seen: Bool

    init(seen: Bool) {
        self.seen = seen
    }

    func setSeen(_ seen: Bool) {
        self.seen = seen
    }

    func isSeen() -> Bool {
        seen
    }
}

private final class IMAPSessionOverlapProbe: @unchecked Sendable {
    private let expectedSessions: Int
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var activeSessions = 0
    private var observedMaximumConcurrentSessions = 0
    private var startedSessions = 0

    init(expectedSessions: Int) {
        self.expectedSessions = expectedSessions
    }

    var maximumConcurrentSessions: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedMaximumConcurrentSessions
    }

    func sessionStarted() {
        lock.lock()
        activeSessions += 1
        startedSessions += 1
        observedMaximumConcurrentSessions = max(observedMaximumConcurrentSessions, activeSessions)
        let shouldRelease = startedSessions == expectedSessions
        lock.unlock()
        if shouldRelease {
            for _ in 0..<expectedSessions {
                release.signal()
            }
        }
        _ = release.wait(timeout: .now() + 0.5)
    }

    func sessionEnded() {
        lock.lock()
        activeSessions -= 1
        lock.unlock()
    }
}

private final class OneShotIMAPSessionGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasHeldFirstSession = false

    func sessionStarted() {
        let shouldHold = lock.withLock { () -> Bool in
            guard !hasHeldFirstSession else { return false }
            hasHeldFirstSession = true
            return true
        }
        guard shouldHold else { return }
        started.signal()
        _ = release.wait(timeout: .now() + 3)
    }

    func waitForFirstSession() -> Bool {
        started.wait(timeout: .now() + 3) == .success
    }

    func releaseFirstSession() {
        release.signal()
    }
}

private final class NonLocalAIProviderProbe: AIProvider, @unchecked Sendable {
    let id = "remote-test-provider"
    let displayName = "Remote Test Provider"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: false
    )
    private let lock = NSLock()
    private var storedGenerationCount = 0

    var generationCount: Int {
        lock.withLock { storedGenerationCount }
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        lock.withLock { storedGenerationCount += 1 }
        return AIGenerationResponse(text: "remote", modelID: id, localOnly: false)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }
}

private actor RecordingOperationWorkerSignal: OperationWorkerSignaling {
    private var count = 0

    func signalWork() async throws {
        count += 1
    }

    func signalCount() -> Int {
        count
    }
}

private final class OperationsNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedScopes: [MailStoreChangeScope] = []

    var scopes: [MailStoreChangeScope] {
        lock.withLock { recordedScopes }
    }

    func record(_ notification: Notification) {
        lock.withLock {
            recordedScopes.append(MailStoreChangeSignal.scope(from: notification))
        }
    }
}

private actor MailboxFlagMutationGate {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func accountIMAPPasswordKey(_ accountID: AccountID) -> CredentialRecordKey {
    CredentialRecordKey(rawValue: "account:\(accountID.rawValue):imap-password")
}

private func accountSMTPPasswordKey(_ accountID: AccountID) -> CredentialRecordKey {
    CredentialRecordKey(rawValue: "account:\(accountID.rawValue):smtp-password")
}

private actor ThrowingCredentialVault: CredentialVault {
    private let error: CredentialVaultError

    init(error: CredentialVaultError) {
        self.error = error
    }

    func store(_ secret: Data, for key: CredentialRecordKey) throws {
        throw error
    }

    func load(_ key: CredentialRecordKey) throws -> Data? {
        throw error
    }

    func remove(_ key: CredentialRecordKey) throws {
        throw error
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        throw error
    }
}

private actor ArchiveRecordingState {
    struct Call: Equatable {
        let uid: Int
        let mailbox: String
    }

    private var recorded: [Call] = []

    func append(uid: Int, mailbox: String) {
        recorded.append(.init(uid: uid, mailbox: mailbox))
    }

    func calls() -> [Call] {
        recorded
    }
}

private final class ArchiveRecordingClient: IMAPClientProtocol, @unchecked Sendable {
    private let state: ArchiveRecordingState

    init(state: ArchiveRecordingState) {
        self.state = state
    }

    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { [] }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 42] selected" }
    func allMessageUIDs() async throws -> [Int] { [7] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {
        XCTFail("archive is a quoted move that reports where the copy landed")
    }
    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        await state.append(uid: uid, mailbox: mailbox)
        return IMAPMoveResult(mailbox: mailbox, uidValidity: nil, uid: nil)
    }
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: 1)
    }
}

private final class ControlledMailboxFlagClient: IMAPClientProtocol, @unchecked Sendable {
    private let state: ControlledRemoteSeenState
    private let markReadGate: MailboxFlagMutationGate?

    init(
        state: ControlledRemoteSeenState,
        markReadGate: MailboxFlagMutationGate? = nil
    ) {
        self.state = state
        self.markReadGate = markReadGate
    }

    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { [] }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 1] selected" }
    func allMessageUIDs() async throws -> [Int] { [1] }
    func fetchHeader(uid: Int) async throws -> String {
        await state.isSeen() ? "\\Seen" : ""
    }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {
        if let markReadGate {
            await markReadGate.pause()
        }
        await state.setSeen(true)
    }
    func markUnread(uid: Int) async throws {
        await state.setSeen(false)
    }
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: 1)
    }
}

private final class ApprovedSendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NodeModeApprovedSend] = []
    var sends: [NodeModeApprovedSend] { lock.withLock { stored } }
    func record(_ send: NodeModeApprovedSend) { lock.withLock { stored.append(send) } }
}

private struct ApprovedNodeDeliveryFixture {
    let smtp: LocalSMTPServer
    let store: SQLiteMailStore
    let url: URL
    let credentials: InMemoryCredentialVault
    let requestID: SendRequestID
    let jobID: String

    static func make(mode: NodeBackedMode, key: String) async throws -> ApprovedNodeDeliveryFixture {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-approved-node-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: PlainpostFixtures.personalAccount.id, displayName: "Personal", email: PlainpostFixtures.personalAccount.email,
            imapHost: "127.0.0.1", smtpHost: "127.0.0.1", smtpPort: Int(smtp.port)
        )
        try store.cacheAccounts([account])
        let source = try store.replaceMailSource(
            AccountMailSource.direct(account.id).nodeBacked(
                nodeID: "40000000-0000-4000-8000-000000000919",
                logicalMailboxID: "ERERERERERERERERERERERERERERERERERERERERERE",
                providerIdentity: account.email.rawValue
            ),
            expectedGeneration: 0
        )
        if mode == .fallback {
            _ = try store.replaceMailSource(source.withMode(.fallback), expectedGeneration: source.generation)
        }
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Node-mode approval")
        let input = PlainpostApprovalDecisionInput(requestID: request.id, actorID: PlainpostFixtures.guiUser.id)
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: 100, maxAttempts: 5, idempotencyKey: "node-mode-approved-\(key)"
        ))
        let credentials = InMemoryCredentialVault()
        try await credentials.store(Data("secret".utf8), for: accountSMTPPasswordKey(account.id))
        return ApprovedNodeDeliveryFixture(smtp: smtp, store: store, url: url, credentials: credentials,
                                           requestID: request.id, jobID: job.id)
    }

    func cleanUp() {
        smtp.stop()
        try? FileManager.default.removeItem(at: url)
    }
}

private actor SuspendedIMAPCredentialVault: CredentialVault {
    private let key: CredentialRecordKey
    private let secret: Data
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    init(key: CredentialRecordKey, secret: Data) {
        self.key = key
        self.secret = secret
    }

    func store(_ secret: Data, for key: CredentialRecordKey) throws {}
    func remove(_ key: CredentialRecordKey) throws {}

    func load(_ key: CredentialRecordKey) async throws -> Data? {
        guard key == self.key else { return nil }
        await withCheckedContinuation { continuation in
            heldLoad = continuation
            observer?.resume()
            observer = nil
        }
        return secret
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        keys.map { $0 == key ? secret : nil }
    }

    func waitUntilLoadIsHeld() async {
        if heldLoad != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func releaseLoad() {
        heldLoad?.resume()
        heldLoad = nil
    }
}

private final class IMAPFactoryConstructionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var constructionCount: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private actor RuntimeHistoryFreshnessClient: IMAPClientProtocol {
    private(set) var fetchedUIDs: [Int] = []
    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { [Mailbox(
        id: MailboxID("runtime-history-inbox"), accountID: PlainpostFixtures.personalAccount.id,
        name: "INBOX", path: "INBOX", specialUse: "\\Inbox"
    )] }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 7]" }
    func allMessageUIDs() async throws -> [Int] { Array(1...5) }
    func fetchHeader(uid: Int) async throws -> String {
        fetchedUIDs.append(uid)
        return "From: sender@example.test\r\nSubject: Synthetic \(uid)\r\n"
    }
    func fetchBody(uid: Int) async throws -> String { "Synthetic body" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        .init(mailbox: mailbox, uid: nil)
    }
}
