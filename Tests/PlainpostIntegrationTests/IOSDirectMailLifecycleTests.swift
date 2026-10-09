import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import PlainpostIOSRuntime
import PlainpostLocalServer
import PlainpostTestSupport
@testable import PlainpostUI
import PlainpostOperations
@testable import PlainpostOperationRuntime

final class IOSDirectMailLifecycleTests: XCTestCase {
    @MainActor func testExplicitHistoryObserverDoesNotDuplicateForegroundFinishersMaintenance() async throws {
        let fixture = try await makeForegroundFixture(uidCount: 0, holdInitialSearch: true)
        let maintenance = ForegroundCompletionOperationClient()
        let suite = "ForegroundHistoryEffects.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsAIProviderPreferenceStore(defaults: defaults)
        preferences.saveSmartInboxMode(.allMail)
        XCTAssertTrue(PlainpostAIGenerationPolicy.current, "The actual organizer must be enabled in this test environment")
        let historyRuntime = try PlainpostAppRuntime(configuration: fixture.configuration,
            aiOperationClientFactory: { _ in maintenance }, aiProviderPreferences: preferences)
        let finishingProvider = ForegroundCheckpointIMAPClient(accountID: fixture.account.id, uidCount: 0)
        let finishingConfiguration = PlainpostAppRuntimeConfiguration(
            databaseURL: fixture.configuration.databaseURL, selectedAccountID: fixture.account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(credentials: fixture.vault,
                imapClientFactory: { _, _ in finishingProvider }))
        let foregroundRuntime = try PlainpostAppRuntime(configuration: finishingConfiguration,
            aiOperationClientFactory: { _ in maintenance }, aiProviderPreferences: preferences)
        let history = Task { try await historyRuntime.syncSelectedDirectMailHistoryNow() }
        addTeardownBlock { @MainActor in
            fixture.provider.releaseAll()
            history.cancel()
            _ = await history.result
            await historyRuntime.shutdown()
            await foregroundRuntime.shutdown()
        }
        let searched = try await waitForForegroundCheckpointCondition { fixture.provider.searchEntered }
        XCTAssertTrue(searched)
        guard searched else { return }
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .historicalSync })
        XCTAssertTrue(try fixture.store.releaseJobLeaseForRetry(id: job.id, leaseToken: XCTUnwrap(job.leaseToken)))
        _ = try await foregroundRuntime.syncDirectMailNow()
        let finished = try await waitForForegroundCheckpointCondition {
            try fixture.store.job(id: job.id).state == .completed && maintenance.count == 1
                && foregroundRuntime.backgroundWork.ownedTaskCount == 0
        }
        XCTAssertTrue(finished, "The actual foreground finisher must first acknowledge maintenance")
        fixture.provider.releaseSearch()
        try await history.value
        // Both real completion handlers await the actual organizer enqueue
        // boundary. Also drain background tasks without cancelling them; Direct
        // global-search maintenance intentionally performs no mutation.
        let drained = try await waitForForegroundCheckpointCondition {
            historyRuntime.backgroundWork.ownedTaskCount == 0 && foregroundRuntime.backgroundWork.ownedTaskCount == 0
        }
        XCTAssertTrue(drained)
        XCTAssertEqual(maintenance.count, 1, "The explicit History button's terminal observer must not repeat the awaited organizer enqueue")
        XCTAssertEqual(maintenance.lastInput?.accountID, fixture.account.id)
        XCTAssertEqual(maintenance.lastInput?.expectedDirectSourceGeneration, 1)
        XCTAssertEqual(maintenance.lastInput?.smartInboxRunMode, .incremental)
        XCTAssertEqual(try fixture.store.diagnosticsJobs().filter { $0.kind == .historicalSync }.map(\.id), [job.id])
    }

    @MainActor func testForegroundRetryResumesCredentialPauseWhilePriorFailureEffectsAreStillFinishing() async throws {
        let notifications = ForegroundCheckpointNotifications(holdFailure: true)
        let fixture = try await makeForegroundFixture(uidCount: 0, notificationScheduler: notifications)
        try await fixture.vault.remove(MailCredentialKeys.imapPassword(fixture.account.id))
        var firstResult: Result<IMAPSyncResult, Error>?
        let first = Task {
            do { firstResult = .success(try await fixture.runtime.syncDirectMailNow()) }
            catch { firstResult = .failure(error) }
        }
        addTeardownBlock { notifications.releaseFailure(); first.cancel(); await first.value }
        let paused = try await waitForForegroundCheckpointCondition { firstResult != nil && notifications.failureEntered }
        XCTAssertTrue(paused, "Actual credential pause must settle observer and enter terminal failure effects")
        guard paused else { return }
        if case .success? = firstResult { XCTFail("Missing credentials unexpectedly succeeded") }
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertEqual(job.state, .paused)
        XCTAssertEqual(job.pauseReason, "credentials-unavailable")
        XCTAssertEqual(fixture.provider.searchCount, 0)
        try await fixture.vault.store(Data("incoming".utf8), for: MailCredentialKeys.imapPassword(fixture.account.id))
        var retried: Result<IMAPSyncResult, Error>?
        let retry = Task {
            do { retried = .success(try await fixture.runtime.syncDirectMailNow()) }
            catch { retried = .failure(error) }
        }
        addTeardownBlock { notifications.releaseFailure(); retry.cancel(); await retry.value }
        let settled = try await waitForForegroundCheckpointCondition { retried != nil }
        XCTAssertTrue(settled, "A resumed job needs a fresh execution owner while old failure effects are held")
        if case .failure(let error)? = retried { XCTFail("Restored credentials could not refresh: \(error)") }
        XCTAssertGreaterThan(fixture.provider.searchCount, 0, "Retry must execute an actual post-admission SEARCH")
        XCTAssertNotEqual(try fixture.store.job(id: job.id).state, .paused)
        XCTAssertEqual(try fixture.store.diagnosticsJobs().filter { $0.kind == .inboxSync }.map(\.id), [job.id])
        XCTAssertFalse(notifications.failureReleased, "No artificial wait for prior failure notification completion")
        notifications.releaseFailure()
    }

    @MainActor func testBackgroundObserverDoesNotDuplicateForegroundFinishersTerminalEffects() async throws {
        let fixture = try await makeForegroundFixture(uidCount: 0)
        let notifications = ForegroundCheckpointNotifications()
        let effects = ForegroundCompletionCounter()
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("fixture-password".utf8), for: MailCredentialKeys.imapPassword(fixture.account.id))
        func makeRuntime() -> LocalOperationRuntime {
            LocalOperationRuntime(store: fixture.store, credentials: vault, allowedJobKinds: [.inboxSync],
                mailboxFlagClientFactory: { _ in fixture.provider }, inboxSyncClientFactory: { _, _ in fixture.provider })
        }
        let backgroundRuntime = makeRuntime()
        let foregroundRuntime = makeRuntime()
        let reachedFence = expectation(description: "Background owner claimed before lease fence")
        let releaseFence = DispatchSemaphore(value: 0)
        backgroundRuntime.beforeLeaseFence = { _ in
            reachedFence.fulfill()
            _ = releaseFence.wait(timeout: .now() + 10)
        }
        let background = LocalOperationAccountInboxSyncer(
            client: LocalOperationClient(runtime: backgroundRuntime), notificationScheduler: notifications,
            didCompleteSync: { effects.increment() }, directSourceProvider: { (fixture.account.id, 1) })
        let foregroundEffects = LocalOperationAccountInboxSyncer(
            client: LocalOperationClient(runtime: foregroundRuntime), notificationScheduler: notifications,
            didCompleteSync: { effects.increment() }, directSourceProvider: { (fixture.account.id, 1) })
        let owner = DirectMailForegroundRefreshCoordinator(client: LocalOperationClient(runtime: foregroundRuntime)) { account, result in
            await foregroundEffects.didFinishForegroundOwnedSync(account: account, result: result)
        }
        let observing = Task { try await background.syncInbox(for: fixture.account, reason: .background) }
        addTeardownBlock { @MainActor in
            releaseFence.signal()
            observing.cancel()
            _ = await observing.result
            await owner.shutdown()
        }
        await fulfillment(of: [reachedFence], timeout: 3)
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertTrue(try fixture.store.releaseJobLeaseForRetry(id: job.id, leaseToken: XCTUnwrap(job.leaseToken)))
        _ = try await owner.refresh(account: fixture.account, sourceGeneration: 1)
        let finished = try await waitForForegroundCheckpointCondition {
            try fixture.store.job(id: job.id).state == .completed && effects.count == 1
        }
        XCTAssertTrue(finished)
        releaseFence.signal()
        _ = try await observing.value
        await owner.shutdown()
        XCTAssertEqual(effects.count, 1, "A terminal observer must not repeat the actual foreground finisher's maintenance")
        XCTAssertEqual(notifications.completedCount, 1, "Mixed old/new owners must schedule one terminal notification")
    }

    @MainActor func testRequestDuringSearchRequiresLaterSearchBeforeForegroundCompletion() async throws {
        let fixture = try await makeForegroundFixture(holdInitialSearch: true)
        fixture.provider.holdBody(2)
        var firstResult: Result<IMAPSyncResult, Error>?
        var secondResult: Result<IMAPSyncResult, Error>?
        let first = Task { do { firstResult = .success(try await fixture.runtime.syncDirectMailNow()) } catch { firstResult = .failure(error) } }
        addTeardownBlock { fixture.provider.releaseAll(); first.cancel(); await first.value }
        let searched = try await waitForForegroundCheckpointCondition { fixture.provider.searchEntered }
        XCTAssertTrue(searched)
        guard searched else { return }
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        let lease = try XCTUnwrap(job.leaseToken)
        let initial = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        let second = Task { do { secondResult = .success(try await fixture.runtime.syncDirectMailNow()) } catch { secondResult = .failure(error) } }
        addTeardownBlock { fixture.provider.releaseAll(); second.cancel(); await second.value }
        let admitted = try await waitForForegroundCheckpointCondition {
            (try fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease)?.revision ?? 0) > initial.revision
        }
        XCTAssertTrue(admitted)
        guard admitted else { return }
        let later = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        let ticket = PlainpostForegroundInboxRefreshRequest(jobID: job.id, accountID: fixture.account.id,
            sourceGeneration: 1, revision: later.revision, recentMessageLimit: later.recentMessageLimit, createdJob: false)
        fixture.provider.releaseSearch()
        let held = try await waitForForegroundCheckpointCondition { fixture.provider.historyEntered && firstResult != nil }
        XCTAssertTrue(held)
        XCTAssertNil(try fixture.store.foregroundInboxRefreshReceipt(ticket), "The older in-flight SEARCH cannot acknowledge the later admission")
        fixture.provider.releaseHistory()
        let fulfilled = try await waitForForegroundCheckpointCondition { secondResult != nil && fixture.provider.bodyEntered(2) }
        XCTAssertTrue(fulfilled, "A later SEARCH must settle the second pull while old history is still held")
        _ = try XCTUnwrap(firstResult).get()
        _ = try XCTUnwrap(secondResult).get()
        XCTAssertGreaterThanOrEqual(fixture.provider.searchCount, 2)
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)
    }

    @MainActor func testForegroundRequestAtFinalTailBoundaryDoesNotWaitForRemainingTail() async throws {
        let fixture = try await makeForegroundFixture(finalTailArrivals: true)
        fixture.provider.releaseHistory()
        fixture.provider.holdBody(4)
        fixture.provider.holdBody(5)
        _ = try await fixture.runtime.syncDirectMailNow()
        let tail = try await waitForForegroundCheckpointCondition { fixture.provider.bodyEntered(4) }
        XCTAssertTrue(tail)
        guard tail else { return }
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        var result: Result<IMAPSyncResult, Error>?
        let refresh = Task { do { result = .success(try await fixture.runtime.syncDirectMailNow()) } catch { result = .failure(error) } }
        addTeardownBlock { fixture.provider.releaseAll(); refresh.cancel(); await refresh.value }
        let admitted = try await waitForForegroundCheckpointCondition {
            try fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: XCTUnwrap(job.leaseToken)) != nil
        }
        XCTAssertTrue(admitted)
        guard admitted else { return }
        fixture.provider.releaseBody(4)
        let fulfilled = try await waitForForegroundCheckpointCondition { result != nil && fixture.provider.bodyEntered(5) }
        XCTAssertTrue(fulfilled, "The completed final-tail message is a foreground checkpoint boundary")
        _ = try XCTUnwrap(result).get()
        let cached = try fixture.store.cachedUIDs(accountID: fixture.account.id, mailboxPath: "INBOX", uidValidity: 41)
        XCTAssertTrue(cached.contains(65))
        XCTAssertFalse(cached.contains(5))
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)
        fixture.provider.releaseBody(5)
        let finished = try await waitForForegroundCheckpointCondition { try fixture.store.job(id: job.id).state == .completed }
        XCTAssertTrue(finished)
        XCTAssertEqual(fixture.provider.searchCount, 3, "The closed history discovery must remain finite")
    }

    @MainActor func testShutdownCancelsAndJoinsForegroundWaiterAndProviderOwner() async throws {
        let fixture = try await makeForegroundFixture(holdInitialSearch: true)
        var result: Result<IMAPSyncResult, Error>?
        let refresh = Task { do { result = .success(try await fixture.runtime.syncDirectMailNow()) } catch { result = .failure(error) } }
        addTeardownBlock { fixture.provider.releaseAll(); refresh.cancel(); await refresh.value }
        let entered = try await waitForForegroundCheckpointCondition { fixture.provider.searchEntered }
        XCTAssertTrue(entered)
        guard entered else { return }
        var stopped = false
        let shutdown = Task { await fixture.runtime.shutdown(); stopped = true }
        addTeardownBlock { await shutdown.value }
        let settled = try await waitForForegroundCheckpointCondition { stopped && result != nil }
        XCTAssertTrue(settled)
        XCTAssertEqual(fixture.provider.activeCallCount, 0, "Shutdown must join the actual held provider call")
        XCTAssertFalse(fixture.provider.isSearchReleased, "Test cleanup did not release the provider")
        if case .failure(let error)? = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Shutdown must detach the unfinished foreground observer") }
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertEqual(job.state, .queued)
        XCTAssertNil(job.leaseToken)
        do { _ = try await fixture.runtime.syncDirectMailNow(); XCTFail("Closed owner admitted work") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.provider.searchCount, 1)
    }

    @MainActor func testNewRuntimeAdoptsQueuedHistoryAndRunsTerminalCompletionEffectsOnce() async throws {
        let notifications = ForegroundCheckpointNotifications()
        let fixture = try await makeForegroundFixture(notificationScheduler: notifications)
        let first = Task { try await fixture.runtime.syncDirectMailNow() }
        addTeardownBlock { first.cancel(); _ = await first.result }
        let entered = try await waitForForegroundCheckpointCondition { fixture.provider.historyEntered }
        XCTAssertTrue(entered)
        guard entered else { return }
        _ = try await first.value
        let original = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertEqual(notifications.completedCount, 0, "A foreground receipt is not terminal sync completion")
        await fixture.runtime.shutdown()
        XCTAssertEqual(try fixture.store.job(id: original.id).state, .queued)
        fixture.provider.releaseHistory()
        let replacement = try PlainpostAppRuntime(configuration: fixture.configuration, notificationScheduler: notifications)
        addTeardownBlock { @MainActor in await replacement.shutdown() }
        _ = try await replacement.syncDirectMailNow()
        let finished = try await waitForForegroundCheckpointCondition {
            try fixture.store.job(id: original.id).state == .completed && notifications.completedCount == 1
        }
        XCTAssertTrue(finished, "The replacement runtime must own terminal effects for the queued job it executes")
        await replacement.shutdown()
        XCTAssertEqual(notifications.completedCount, 1)
        XCTAssertEqual(try fixture.store.diagnosticsJobs().filter { $0.kind == .inboxSync }.map(\.id), [original.id])
    }

    @MainActor func testStaleForegroundRuntimeRejectsBeforeAdmittingReplacementSourceJob() async throws {
        let fixture = try await makeForegroundFixture()
        _ = try fixture.store.replaceMailSource(AccountMailSource(
            accountID: fixture.account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 2
        ), expectedGeneration: 1)
        do {
            _ = try await fixture.runtime.syncDirectMailNow()
            XCTFail("A runtime captured at generation 1 must reject generation 2")
        } catch { XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict) }
        XCTAssertTrue(try fixture.store.diagnosticsJobs().isEmpty, "Reject stale authority before durable admission")
        XCTAssertFalse(fixture.provider.searchEntered)
    }

    @MainActor func testFulfilledForegroundReceiptDoesNotPoisonFrozenHistoryAfterSelectionChanges() async throws {
        let fixture = try await makeForegroundFixture()
        let foreground = Task { try await fixture.runtime.syncDirectMailNow() }
        addTeardownBlock { foreground.cancel(); _ = await foreground.result }
        let entered = try await waitForForegroundCheckpointCondition { fixture.provider.historyEntered }
        XCTAssertTrue(entered)
        guard entered else { return }
        _ = try await foreground.value
        let job = try XCTUnwrap(fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync })
        let sent = Mailbox(id: MailboxID("foreground-new-sent"), accountID: fixture.account.id,
                           name: "Sent", path: "Sent", specialUse: "\\Sent")
        try fixture.store.cacheMailboxes([sent])
        try fixture.store.saveMailboxSyncPreference(.init(accountID: fixture.account.id, mailboxPath: "Sent", mode: .recent))
        fixture.provider.releaseHistory()
        let completed = try await waitForForegroundCheckpointCondition {
            try fixture.store.job(id: job.id).state == .completed
        }
        XCTAssertTrue(completed, "A fulfilled observer must not revalidate live selection and fail frozen history")
        XCTAssertEqual(try fixture.store.cachedUIDs(accountID: fixture.account.id, mailboxPath: "INBOX", uidValidity: 41), Set([1, 2, 3]))
    }

    @MainActor func testForegroundCheckpointCommitsConfiguredWindowLargerThanFiftyBeforeReturning() async throws {
        let fixture = try await makeForegroundFixture(recentLimit: 60, uidCount: 61)
        var result: Result<IMAPSyncResult, Error>?
        let foreground = Task {
            do { result = .success(try await fixture.runtime.syncDirectMailNow()) }
            catch { result = .failure(error) }
        }
        addTeardownBlock { foreground.cancel(); await foreground.value }
        let entered = try await waitForForegroundCheckpointCondition { fixture.provider.historyEntered }
        XCTAssertTrue(entered)
        let completed = try await waitForForegroundCheckpointCondition { result != nil }
        XCTAssertTrue(completed)
        if case .failure(let error)? = result { XCTFail("Foreground window failed: \(error)") }
        XCTAssertEqual(try fixture.store.cachedUIDs(accountID: fixture.account.id, mailboxPath: "INBOX", uidValidity: 41), Set(2...61))
        XCTAssertFalse(fixture.provider.historyReleased)
        XCTAssertEqual(try fixture.store.diagnosticsJobs().first { $0.kind == .inboxSync }?.state, .running)
    }

    @MainActor func testEmptyAndFullyCachedInboxStillPerformFreshProviderSearch() async throws {
        let empty = try await makeForegroundFixture(uidCount: 0)
        let emptyResult = try await empty.runtime.syncDirectMailNow()
        XCTAssertEqual(emptyResult.syncedMessageCount, 0)
        XCTAssertGreaterThan(empty.provider.searchCount, 0)

        let cached = try await makeForegroundFixture()
        cached.provider.releaseHistory()
        _ = try await cached.runtime.syncDirectMailNow()
        let drained = try await waitForForegroundCheckpointCondition {
            try cached.store.diagnosticsJobs().filter { $0.kind == .inboxSync }.allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(drained)
        let searches = cached.provider.searchCount
        let bodies = cached.provider.bodyCount
        let cachedResult = try await cached.runtime.syncDirectMailNow()
        XCTAssertEqual(cachedResult.syncedMessageCount, 1)
        XCTAssertEqual(cachedResult.newlyDiscoveredMessageCount, 0)
        XCTAssertGreaterThan(cached.provider.searchCount, searches, "A cache hit alone cannot acknowledge a new pull")
        XCTAssertEqual(cached.provider.bodyCount, bodies, "Already committed recent targets need no BODY download")
    }

    @MainActor private func makeForegroundFixture(
        recentLimit: Int = 1, uidCount: Int = 3, holdInitialSearch: Bool = false, finalTailArrivals: Bool = false,
        notificationScheduler: (any LocalNotificationScheduling)? = nil
    ) async throws -> (store: SQLiteMailStore, account: Account, provider: ForegroundCheckpointIMAPClient, runtime: PlainpostAppRuntime, configuration: PlainpostAppRuntimeConfiguration, vault: InMemoryCredentialVault) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-edge-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: 993)
        try store.saveSyncPreferences(.init(accountID: account.id, downloadCompleteHistory: true, recentMessageLimit: recentLimit))
        let provider = ForegroundCheckpointIMAPClient(accountID: account.id, holdInitialSearch: holdInitialSearch, uidCount: uidCount, finalTailArrivals: finalTailArrivals)
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(credentials: vault, imapClientFactory: { _, _ in provider })
        )
        let runtime = try PlainpostAppRuntime(configuration: configuration, notificationScheduler: notificationScheduler)
        addTeardownBlock { @MainActor in
            provider.releaseAll()
            (notificationScheduler as? ForegroundCheckpointNotifications)?.releaseFailure()
            await runtime.shutdown()
            try? FileManager.default.removeItem(at: url)
        }
        return (store, account, provider, runtime, configuration, vault)
    }

    @MainActor func testCancellingForegroundRefreshDetachesWaiterWhileOwnedHistoryContinues() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-foreground-detach-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: 993)
        try store.saveSyncPreferences(MailSyncPreferences(
            accountID: account.id, downloadCompleteHistory: true, recentMessageLimit: 1
        ))
        let provider = ForegroundCheckpointIMAPClient(accountID: account.id, holdInitialSearch: true)
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(
                credentials: vault, imapClientFactory: { _, _ in provider }
            )
        ))
        var result: Result<IMAPSyncResult, Error>?
        let foreground = Task {
            do { result = .success(try await runtime.syncDirectMailNow()) }
            catch { result = .failure(error) }
        }
        addTeardownBlock { @MainActor in
            provider.releaseSearch()
            provider.releaseHistory()
            foreground.cancel()
            await foreground.value
            await runtime.shutdown()
            try? FileManager.default.removeItem(at: url)
        }
        let entered = try await waitForForegroundCheckpointCondition { provider.searchEntered }
        XCTAssertTrue(entered)
        guard entered else { return }
        let admitted = try XCTUnwrap(store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertEqual(admitted.state, .running)
        XCTAssertNotNil(admitted.leaseToken)
        foreground.cancel()
        let detached = try await waitForForegroundCheckpointCondition { result != nil }
        XCTAssertTrue(detached, "Cancellation must settle the foreground observer promptly")
        if case .failure(let error)? = result {
            XCTAssertTrue(error is CancellationError)
        } else {
            XCTFail("The cancelled foreground observer must not report refresh success")
        }
        let continuing = try store.job(id: admitted.id)
        XCTAssertEqual(continuing.state, .running, "View cancellation must not relinquish owned history")
        XCTAssertEqual(continuing.leaseToken, admitted.leaseToken)
        XCTAssertFalse(continuing.cancellationRequested)
        provider.releaseSearch()
        provider.releaseHistory()
        let completed = try await waitForForegroundCheckpointCondition {
            try store.job(id: admitted.id).state == .completed
        }
        XCTAssertTrue(completed, "History must continue without a second foreground caller")
        XCTAssertEqual(
            try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 41), Set([1, 2, 3])
        )
    }

    @MainActor func testForegroundRefreshCompletesAfterFreshInboxWhileOwnedHistoryContinues() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-foreground-checkpoint-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: 993)
        try store.saveSyncPreferences(MailSyncPreferences(
            accountID: account.id, downloadCompleteHistory: true, recentMessageLimit: 1
        ))
        let provider = ForegroundCheckpointIMAPClient(accountID: account.id)
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(
                credentials: vault, imapClientFactory: { _, _ in provider }
            )
        ))
        var refreshResult: Result<IMAPSyncResult, Error>?
        // This is the runtime future awaited by the actual iOS host's
        // localSyncTask and, in turn, the mailbox's .refreshable closure.
        let foreground = Task {
            do { refreshResult = .success(try await runtime.syncDirectMailNow()) }
            catch { refreshResult = .failure(error) }
        }
        addTeardownBlock { @MainActor in
            // Release the owned provider callback before cancellation/join,
            // including assertion failures or a thrown store assertion.
            provider.releaseHistory()
            foreground.cancel()
            await foreground.value
            await runtime.shutdown()
            try? FileManager.default.removeItem(at: url)
        }

        let historyEntered = try await waitForForegroundCheckpointCondition {
            provider.historyEntered
        }
        XCTAssertTrue(historyEntered, "The real import never reached the held historical BODY fetch")
        guard historyEntered else { return }
        XCTAssertEqual(
            try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 41),
            Set([3]), "The newest UID must be atomically committed before history is held"
        )
        let job = try XCTUnwrap(store.diagnosticsJobs().first { $0.kind == .inboxSync })
        XCTAssertEqual(job.state, .running)
        XCTAssertNotNil(job.leaseToken)
        XCTAssertFalse(try XCTUnwrap(store.mailboxSyncStatuses(accountID: account.id).first).complete)

        // A bounded liveness check follows a concrete provider/commit barrier;
        // it is not a promised wall-clock SLA for a physical Gmail refresh.
        let refreshCompleted = try await waitForForegroundCheckpointCondition {
            refreshResult != nil
        }
        XCTAssertTrue(
            refreshCompleted,
            "Foreground refresh still waits for full history after fresh inbox data is committed"
        )
        if case .failure(let error)? = refreshResult {
            XCTFail("Foreground refresh failed instead of completing its fresh inbox checkpoint: \(error)")
        }
        XCTAssertFalse(provider.historyReleased, "The test has not released historical provider work")
        let ownedHistory = try store.job(id: job.id)
        XCTAssertEqual(ownedHistory.state, .running, "Completing refresh must not cancel or finish history")
        XCTAssertNotNil(ownedHistory.leaseToken, "Historical work must retain its execution owner")
        XCTAssertEqual(
            try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 41),
            Set([3]), "Old gaps must remain pending while their provider is held"
        )

        provider.releaseHistory()
        let historyCompleted = try await waitForForegroundCheckpointCondition {
            try store.job(id: job.id).state == .completed
        }
        XCTAssertTrue(historyCompleted, "Owned history did not drain after its provider was released")
        XCTAssertEqual(
            try store.cachedUIDs(accountID: account.id, mailboxPath: "INBOX", uidValidity: 41),
            Set([1, 2, 3]), "Returning from refresh must preserve every older UID gap"
        )
        XCTAssertTrue(try XCTUnwrap(store.mailboxSyncStatuses(accountID: account.id).first).complete)
        try store.requireDirectMailSource(accountID: account.id)
    }

    @MainActor private func waitForForegroundCheckpointCondition(
        _ condition: () throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    @MainActor func testSelectedDirectCompleteHistoryImportsOlderMailBeyondRecentLimit() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(
            username: email.rawValue, password: "incoming",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let tls = try imap.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-complete-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: tls.port)

        let writer = SecureIMAPClient(
            host: "127.0.0.1", port: tls.port,
            certificateValidation: .testAnchor(tls.certificate)
        )
        try await writer.login(username: email.rawValue, password: "incoming")
        _ = try await writer.appendMessage(
            to: "INBOX", flags: [],
            data: "From: Sender <sender@example.test>\r\nTo: reader@example.test\r\nSubject: Newer fixture\r\nMessage-ID: <newer@example.test>\r\n\r\nNewer body"
        )
        await writer.disconnect()

        try store.saveSyncPreferences(MailSyncPreferences(
            accountID: account.id, recentMessageLimit: 1
        ))
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(
                credentials: vault,
                imapClientFactory: { _, _ in SecureIMAPClient(
                    host: "127.0.0.1", port: tls.port,
                    certificateValidation: .testAnchor(tls.certificate)
                ) }
            )
        ))
        _ = try await runtime.syncDirectMailNow()
        XCTAssertEqual(store.messages.map(\.subject), ["Newer fixture"])

        try runtime.enableCompleteHistoryForSelectedDirectAccount()
        try await runtime.syncSelectedDirectMailHistoryNow()
        XCTAssertTrue(try store.diagnosticsJobs().contains { $0.kind == .historicalSync })
        XCTAssertEqual(Set(store.messages.map(\.subject)), Set(["Newer fixture", PlainpostFixtures.aliceMessage.subject]))
        XCTAssertTrue(try store.syncPreferences(accountID: account.id).downloadCompleteHistory)
        let progress = try XCTUnwrap(store.mailboxSyncStatuses(accountID: account.id).first)
        XCTAssertEqual(progress.phase, .backfill)
        XCTAssertEqual(progress.downloaded, 2)
        XCTAssertEqual(progress.estimatedTotal, 2)
        XCTAssertTrue(progress.complete)
        await runtime.shutdown()
    }

    @MainActor func testSecureGenericSetupPublishesDirectSourceAndCachesInbox() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(username: email.rawValue, password: "incoming", message: PlainpostFixtures.aliceMessage)
        let smtp = LocalSMTPServer(username: email.rawValue, password: "outgoing")
        try await imap.start()
        try await smtp.start()
        defer { imap.stop(); smtp.stop() }
        let imapTLS = try imap.startImplicitTLS()
        let smtpTLS = try smtp.startImplicitTLS()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-direct-lifecycle-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let dependencies = IOSLocalMailRuntimeDependencies(
            credentials: vault,
            imapClientFactory: { _, _ in SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(imapTLS.certificate)) },
            smtpClientFactory: { _, _ in SecureSMTPClient(host: "127.0.0.1", port: Int(smtpTLS.port), certificateValidation: .testAnchor(smtpTLS.certificate)) }
        )
        let setup = dependencies.makeAccountSetupHandler(
            store: store,
            inboxSyncOrchestrator: FixtureInboxSync(store: store, dependencies: dependencies)
        )
        let request = AccountSetupRequest(
            displayName: "Reader", email: email,
            imapHost: "127.0.0.1", imapPort: imapTLS.port,
            smtpHost: "127.0.0.1", smtpPort: Int(smtpTLS.port),
            imapPassword: "incoming", smtpPassword: "outgoing"
        )
        XCTAssertTrue(store.accounts.isEmpty)
        let result = try await setup.addAccount(request, progress: { _ in })
        try store.requireDirectMailSource(accountID: result.account.id)
        XCTAssertEqual(store.accounts.map(\.id), [result.account.id])
        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(store.messages.count, 1)
        let first = try XCTUnwrap(store.messages.first)
        XCTAssertFalse(first.body.isEmpty)
        XCTAssertEqual(try store.membership(for: first.id).accountID, result.account.id)
        XCTAssertTrue(try store.searchMessages(first.subject).contains(first.id))

        let writer = SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(imapTLS.certificate))
        try await writer.login(username: email.rawValue, password: "incoming")
        let appended = try await writer.appendMessage(
            to: "INBOX", flags: [],
            data: "From: Sender <sender@example.test>\r\nTo: reader@example.test\r\nSubject: Incremental fixture\r\nMessage-ID: <incremental@example.test>\r\n\r\nIncremental body"
        )
        await writer.disconnect()
        XCTAssertEqual(appended.uid, 1001)

        let local = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: result.account.id,
            runtimeDependencies: dependencies
        ))
        _ = try await local.syncDirectMailNow()
        XCTAssertEqual(store.messages.count, 2)
        let incremental = try XCTUnwrap(store.messages.first { $0.subject == "Incremental fixture" })
        XCTAssertEqual(try store.membership(for: incremental.id).uid, 1001)
        XCTAssertEqual(try store.membership(for: incremental.id).accountID, result.account.id)
        XCTAssertTrue(try store.searchMessages("Incremental").contains(incremental.id))
        _ = try await local.syncDirectMailNow()
        XCTAssertEqual(store.messages.count, 2)
        await local.shutdown()
    }

    func testCertificateMismatchLeavesNoAccountOrCredential() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(username: email.rawValue, password: "incoming", message: PlainpostFixtures.aliceMessage)
        let smtp = LocalSMTPServer(username: email.rawValue, password: "outgoing")
        try await imap.start()
        try await smtp.start()
        defer { imap.stop(); smtp.stop() }
        let imapTLS = try imap.startImplicitTLS()
        let unrelatedAnchor = try smtp.startImplicitTLS().certificate
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-cert-mismatch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let setup = AccountSetupService(
            store: store, credentials: vault,
            imapClientFactory: { _, _ in SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(unrelatedAnchor)) },
            publishDirectMailSource: true
        )
        do {
            _ = try await setup.addAccount(AccountSetupRequest(
                displayName: "Reader", email: email,
                imapHost: "127.0.0.1", imapPort: imapTLS.port,
                smtpHost: "127.0.0.1", smtpPort: 9,
                imapPassword: "incoming", smtpPassword: "outgoing"
            ))
            XCTFail("A different certificate was trusted")
        } catch IMAPClientError.tlsFailed {}
        XCTAssertTrue(store.accounts.isEmpty)
        let id = AccountID("acc_reader_example_test")
        let savedIMAP = try await vault.load(MailCredentialKeys.imapPassword(id))
        let savedSMTP = try await vault.load(MailCredentialKeys.smtpPassword(id))
        XCTAssertNil(savedIMAP)
        XCTAssertNil(savedSMTP)
    }

    func testTrustedCertificateStillRequiresMatchingHostname() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(username: email.rawValue, password: "incoming", message: PlainpostFixtures.aliceMessage)
        try await imap.start()
        defer { imap.stop() }
        let imapTLS = try imap.startImplicitTLS(certificateName: "different.invalid")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-name-mismatch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let setup = AccountSetupService(
            store: store, credentials: vault,
            imapClientFactory: { _, _ in SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(imapTLS.certificate)) },
            publishDirectMailSource: true
        )
        do {
            _ = try await setup.addAccount(AccountSetupRequest(
                displayName: "Reader", email: email,
                imapHost: "127.0.0.1", imapPort: imapTLS.port,
                smtpHost: "127.0.0.1", smtpPort: 9,
                imapPassword: "incoming", smtpPassword: "outgoing"
            ))
            XCTFail("A trusted certificate with the wrong hostname was accepted")
        } catch IMAPClientError.tlsFailed {}
        XCTAssertTrue(store.accounts.isEmpty)
        let id = AccountID("acc_reader_example_test")
        let savedIMAP = try await vault.load(MailCredentialKeys.imapPassword(id))
        XCTAssertNil(savedIMAP)
    }

    func testSMTPRejectionLeavesNoAccountOrCredential() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(username: email.rawValue, password: "incoming", message: PlainpostFixtures.aliceMessage)
        let smtp = LocalSMTPServer(username: email.rawValue, password: "outgoing", rejectedRecipients: [email])
        try await imap.start()
        try await smtp.start()
        defer { imap.stop(); smtp.stop() }
        let imapTLS = try imap.startImplicitTLS()
        let smtpTLS = try smtp.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-smtp-rejection-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let setup = AccountSetupService(
            store: store, credentials: vault,
            imapClientFactory: { _, _ in SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(imapTLS.certificate)) },
            smtpClientFactory: { _, _ in SecureSMTPClient(host: "127.0.0.1", port: Int(smtpTLS.port), certificateValidation: .testAnchor(smtpTLS.certificate)) },
            publishDirectMailSource: true
        )
        do {
            _ = try await setup.addAccount(AccountSetupRequest(
                displayName: "Reader", email: email,
                imapHost: "127.0.0.1", imapPort: imapTLS.port,
                smtpHost: "127.0.0.1", smtpPort: Int(smtpTLS.port),
                imapPassword: "incoming", smtpPassword: "outgoing"
            ))
            XCTFail("SMTP rejection published an account")
        } catch SMTPClientError.recipientRejected {}
        XCTAssertTrue(store.accounts.isEmpty)
        let id = AccountID("acc_reader_example_test")
        let savedIMAP = try await vault.load(MailCredentialKeys.imapPassword(id))
        let savedSMTP = try await vault.load(MailCredentialKeys.smtpPassword(id))
        XCTAssertNil(savedIMAP)
        XCTAssertNil(savedSMTP)
    }

    func testFailedInitialSyncRollsBackPublishedDirectAccount() async throws {
        let email = EmailAddress("reader@example.test")
        let imap = LocalIMAPServer(username: email.rawValue, password: "incoming", message: PlainpostFixtures.aliceMessage)
        let smtp = LocalSMTPServer(username: email.rawValue, password: "outgoing")
        try await imap.start()
        try await smtp.start()
        defer { imap.stop(); smtp.stop() }
        let imapTLS = try imap.startImplicitTLS()
        let smtpTLS = try smtp.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-sync-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let setup = AccountSetupService(
            store: store, credentials: vault,
            inboxSyncOrchestrator: FailedFirstSync(),
            imapClientFactory: { _, _ in SecureIMAPClient(host: "127.0.0.1", port: imapTLS.port, certificateValidation: .testAnchor(imapTLS.certificate)) },
            smtpClientFactory: { _, _ in SecureSMTPClient(host: "127.0.0.1", port: Int(smtpTLS.port), certificateValidation: .testAnchor(smtpTLS.certificate)) },
            publishDirectMailSource: true
        )
        do {
            _ = try await setup.addAccount(AccountSetupRequest(
                displayName: "Reader", email: email,
                imapHost: "127.0.0.1", imapPort: imapTLS.port,
                smtpHost: "127.0.0.1", smtpPort: Int(smtpTLS.port),
                imapPassword: "incoming", smtpPassword: "outgoing"
            ))
            XCTFail("Initial sync failure published an account")
        } catch IMAPClientError.connectionFailed {}
        XCTAssertTrue(store.accounts.isEmpty)
        let id = AccountID("acc_reader_example_test")
        let savedIMAP = try await vault.load(MailCredentialKeys.imapPassword(id))
        let savedSMTP = try await vault.load(MailCredentialKeys.smtpPassword(id))
        XCTAssertNil(savedIMAP)
        XCTAssertNil(savedSMTP)
    }

    @MainActor func testCancelledTerminalSyncReleasesLeaseForImmediateFixtureRetry() async throws {
        let imap = LocalIMAPServer(
            username: "reader@example.test", password: "incoming",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let tls = try imap.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-cancel-retry-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: tls.port)
        let firstClient = FirstSyncClientFactory(mode: .waitForCancellation, tls: tls)
        let dependencies = IOSLocalMailRuntimeDependencies(
            credentials: vault, imapClientFactory: { _, _ in firstClient.make() }
        )
        let client = LocalOperationClient(runtime: dependencies.makeOperationRuntime(
            store: store, allowedJobKinds: [.inboxSync], selectedDirectAccountID: account.id,
            expectedDirectSourceGeneration: 1
        ))
        let input = PlainpostInboxSyncInput(
            accountID: account.id, trigger: .manual, expectedDirectSourceGeneration: 1
        )
        let pending = try store.enqueueCoalescedInboxSyncJob(input)
        // The terminal API retains cancellation/lease-release semantics. The
        // separately tested UI foreground checkpoint only detaches its waiter.
        let foreground = Task { try await client.executeInboxSync(input) }
        for _ in 0..<200 where !firstClient.entered {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(firstClient.entered, "The first sync never reached the fixture client")
        foreground.cancel() // terminal execution owner cancellation
        do {
            _ = try await foreground.value
            XCTFail("Cancelled foreground sync completed")
        } catch is CancellationError {}
        let released = try store.job(id: pending.id)
        XCTAssertEqual(released.state, .queued)
        XCTAssertNil(released.leaseToken)
        guard released.state == .queued else { return }

        let retryStarted = Date()
        _ = try await client.executeInboxSync(input)
        XCTAssertLessThan(Date().timeIntervalSince(retryStarted), 5)
        XCTAssertEqual(store.messages.count, 1)
    }

    @MainActor func testPeriodicFailureSurfacesAndManualRetryUsesFixture() async throws {
        let imap = LocalIMAPServer(
            username: "reader@example.test", password: "incoming",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }
        let tls = try imap.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-monitor-retry-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let account = try await seedDirectSyncAccount(store: store, vault: vault, imapPort: tls.port)
        let firstClient = FirstSyncClientFactory(mode: .fail, tls: tls)
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: account.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(
                credentials: vault, imapClientFactory: { _, _ in firstClient.make() }
            )
        ))
        let monitor = Task { try await runtime.monitorMail(interval: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        monitor.cancel()
        switch await monitor.result {
        case .success:
            XCTFail("Periodic sync failure was swallowed")
        case .failure(let error):
            XCTAssertFalse(error is CancellationError, "Monitor reported only its test cancellation")
        }
        _ = try await runtime.syncDirectMailNow()
        XCTAssertEqual(store.messages.count, 1)
        await runtime.shutdown()
    }

    // MARK: - Device-wide runtime: every Direct account

    /// Two Direct accounts on two local IMAP servers, and a device-wide runtime over both.
    @MainActor private func makeTwoAccountRuntime(
        firstPassword: String = "incoming", secondPassword: String = "work-pass",
        secondFailsFast: Bool = false
    ) async throws -> (runtime: PlainpostAppRuntime, store: SQLiteMailStore, first: Account, second: Account,
                       stop: () -> Void) {
        let firstServer = LocalIMAPServer(
            username: "reader@example.test", password: "incoming", message: PlainpostFixtures.aliceMessage
        )
        let secondServer = LocalIMAPServer(
            username: "work@example.test", password: "work-pass", message: PlainpostFixtures.aliceMessage
        )
        try await firstServer.start()
        try await secondServer.start()
        let firstTLS = try firstServer.startImplicitTLS()
        let secondTLS = try secondServer.startImplicitTLS()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-every-direct-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let vault = InMemoryCredentialVault()
        let first = try await seedDirectSyncAccount(
            store: store, vault: vault, imapPort: firstTLS.port, password: firstPassword
        )
        let second = try await seedDirectSyncAccount(
            store: store, vault: vault, imapPort: secondTLS.port,
            id: "acc_work_example_test", email: "work@example.test", password: secondPassword
        )
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(
                credentials: vault,
                imapClientFactory: { _, port in
                    if secondFailsFast, port == secondTLS.port {
                        return InterruptedFixtureIMAPClient(mode: .fail) {}
                    }
                    return SecureIMAPClient(
                        host: "127.0.0.1", port: port,
                        certificateValidation: .testAnchor(port == firstTLS.port ? firstTLS.certificate : secondTLS.certificate)
                    )
                }
            )
        ))
        return (runtime, store, first, second, { firstServer.stop(); secondServer.stop() })
    }

    @MainActor func testSyncAllDirectMailSyncsEveryDirectAccount() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        let results = await fixture.runtime.syncAllDirectMailNow()
        XCTAssertEqual(Set(results.keys), [fixture.first.id, fixture.second.id])
        for (accountID, result) in results {
            XCTAssertNoThrow(try result.get(), accountID.rawValue)
        }
        for account in [fixture.first, fixture.second] {
            XCTAssertGreaterThan(
                try fixture.store.mailboxListMessageCount(inMailboxPath: "INBOX", accountID: account.id, query: ""), 0,
                account.id.rawValue
            )
        }
        await fixture.runtime.shutdown()
    }

    /// The phone has no helper process: read state queued on it reaches the server
    /// through the app's own worker, not "Waiting for the background worker" forever.
    @MainActor func testQueuedReadStateIsWrittenBackByTheNextSync() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        _ = await fixture.runtime.syncAllDirectMailNow()
        let message = try XCTUnwrap(try fixture.store.messages(accountID: fixture.first.id).first)
        let membership = try fixture.store.membership(for: message.id)
        // Queued without a worker signal, as an offline open or a Sync Node fallback action leaves it.
        try DurableMailboxFlagScheduler(store: fixture.store).schedule(PlainpostMailboxFlagInput(
            messageID: message.id, accountID: fixture.first.id, mailboxPath: membership.mailboxPath,
            uidValidity: membership.uidValidity, uid: membership.uid, desiredSeen: !message.isSeen,
            expectedDirectSourceGeneration: try fixture.store.mailSource(accountID: fixture.first.id).generation
        ))
        func flagJobs() throws -> [PlainpostDurableJob] {
            try fixture.store.jobs(limit: 500).filter { $0.kind == .mailboxFlag }
        }
        XCTAssertEqual(try flagJobs().map(\.state), [.queued])

        _ = await fixture.runtime.syncAllDirectMailNow()
        let deadline = Date().addingTimeInterval(20)
        while try flagJobs().contains(where: { $0.state != .completed }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try flagJobs().map(\.state), [.completed])
        await fixture.runtime.shutdown()
    }

    /// Becoming active sends queued read state at once, without waiting for a sync.
    @MainActor func testResumingWriteBackSendsQueuedReadStateWithoutASync() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        _ = await fixture.runtime.syncAllDirectMailNow()
        let message = try XCTUnwrap(try fixture.store.messages(accountID: fixture.first.id).first)
        let membership = try fixture.store.membership(for: message.id)
        try DurableMailboxFlagScheduler(store: fixture.store).schedule(PlainpostMailboxFlagInput(
            messageID: message.id, accountID: fixture.first.id, mailboxPath: membership.mailboxPath,
            uidValidity: membership.uidValidity, uid: membership.uid, desiredSeen: !message.isSeen,
            expectedDirectSourceGeneration: try fixture.store.mailSource(accountID: fixture.first.id).generation
        ))
        func flagJobs() throws -> [PlainpostDurableJob] {
            try fixture.store.jobs(limit: 500).filter { $0.kind == .mailboxFlag }
        }

        await fixture.runtime.resumeQueuedMailboxWriteBack()
        let deadline = Date().addingTimeInterval(20)
        while try flagJobs().contains(where: { $0.state != .completed }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try flagJobs().map(\.state), [.completed])
        await fixture.runtime.shutdown()
    }

    /// A Sync Node account whose Node is away (fallback) is synced by the phone like a
    /// Direct one; in Node mode its mail comes from the Node's mirror instead.
    @MainActor func testSyncAllDirectMailSyncsASyncNodeAccountOnlyInFallback() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        let direct = try fixture.store.mailSource(accountID: fixture.second.id)
        let node = try fixture.store.replaceMailSource(direct.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: fixture.second.email.rawValue
        ), expectedGeneration: direct.generation)
        let inNodeMode = await fixture.runtime.syncAllDirectMailNow()
        XCTAssertEqual(Set(inNodeMode.keys), [fixture.first.id])
        // The pass's follow-up work (Smart Inbox) holds a mode change until it ends, as the
        // supervisor's next tick finds.
        let deadline = Date().addingTimeInterval(20)
        while (try? fixture.store.replaceMailSource(node.withMode(.fallback), expectedGeneration: node.generation)) == nil {
            guard Date() < deadline else { return XCTFail("The account never left Node mode") }
            try await Task.sleep(for: .milliseconds(50))
        }
        let inFallback = await fixture.runtime.syncAllDirectMailNow()
        XCTAssertEqual(Set(inFallback.keys), [fixture.first.id, fixture.second.id])
        XCTAssertNoThrow(try inFallback[fixture.second.id]?.get())
        XCTAssertGreaterThan(
            try fixture.store.mailboxListMessageCount(inMailboxPath: "INBOX", accountID: fixture.second.id, query: ""), 0
        )
        await fixture.runtime.shutdown()
    }

    @MainActor func testOneFailingAccountDoesNotStopTheOthersSync() async throws {
        let fixture = try await makeTwoAccountRuntime(secondFailsFast: true)
        defer { fixture.stop() }
        let results = await fixture.runtime.syncAllDirectMailNow()
        XCTAssertNoThrow(try results[fixture.first.id]?.get())
        XCTAssertThrowsError(try results[fixture.second.id]?.get())
        // The monitor keeps running through a failing account, reporting it after each pass.
        var reported: [AccountID?] = []
        fixture.runtime.directSyncFailureHandler = { reported.append($0?.accountID) }
        let monitor = Task { try await fixture.runtime.monitorMail(interval: .milliseconds(10)) }
        for _ in 0..<300 where reported.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(reported.count, 3, "the monitor stopped")
        XCTAssertTrue(reported.allSatisfy { $0 == fixture.second.id })
        monitor.cancel()
        _ = await monitor.result
        XCTAssertGreaterThan(
            try fixture.store.mailboxListMessageCount(inMailboxPath: "INBOX", accountID: fixture.first.id, query: ""), 0
        )
        await fixture.runtime.shutdown()
    }

    /// The periodic pass is the fallback sync: an account with Instant updates off still gets it.
    @MainActor func testTheMonitorSyncsAnAccountWithInstantUpdatesOff() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        var preferences = try fixture.store.syncPreferences(accountID: fixture.first.id)
        preferences.realTimeMonitoringEnabled = false
        try fixture.store.saveSyncPreferences(preferences)
        let monitor = Task { try await fixture.runtime.monitorMail(interval: .milliseconds(10)) }
        var synced = false
        for _ in 0..<300 where !synced {
            try await Task.sleep(for: .milliseconds(20))
            synced = try fixture.store.mailboxListMessageCount(
                inMailboxPath: "INBOX", accountID: fixture.first.id, query: ""
            ) > 0
        }
        monitor.cancel()
        _ = await monitor.result
        XCTAssertTrue(synced)
        await fixture.runtime.shutdown()
    }

    /// A failing account that sorts first must not hold up the others while its sync retries.
    @MainActor func testAFailingAccountDoesNotDelayTheOthers() async throws {
        let fixture = try await makeTwoAccountRuntime(firstPassword: "wrong")
        defer { fixture.stop() }
        let sync = Task { await fixture.runtime.syncAllDirectMailNow() }
        var synced = false
        for _ in 0..<150 where !synced {
            try await Task.sleep(for: .milliseconds(100))
            synced = try fixture.store.mailboxListMessageCount(
                inMailboxPath: "INBOX", accountID: fixture.second.id, query: ""
            ) > 0
        }
        XCTAssertTrue(synced, "The healthy account waited for the failing one")
        sync.cancel()
        _ = await sync.value
        await fixture.runtime.shutdown()
    }

    @MainActor func testCompleteHistoryRunsForTheChosenAccountOnly() async throws {
        let fixture = try await makeTwoAccountRuntime()
        defer { fixture.stop() }
        try fixture.runtime.enableCompleteHistory(for: fixture.second.id)
        try await fixture.runtime.syncDirectMailHistoryNow(for: fixture.second.id)
        XCTAssertTrue(try fixture.store.syncPreferences(accountID: fixture.second.id).downloadCompleteHistory)
        XCTAssertFalse(try fixture.store.syncPreferences(accountID: fixture.first.id).downloadCompleteHistory)
        await fixture.runtime.shutdown()
    }

    @MainActor private func seedDirectSyncAccount(
        store: SQLiteMailStore, vault: InMemoryCredentialVault, imapPort: UInt16,
        id: String = "acc_reader_example_test", email: String = "reader@example.test",
        password: String = "incoming"
    ) async throws -> Account {
        try store.migrate()
        let account = Account(
            id: AccountID(id), displayName: "Reader",
            email: EmailAddress(email),
            imapHost: "127.0.0.1", imapPort: imapPort,
            smtpHost: "127.0.0.1", smtpPort: 465
        )
        let inbox = Mailbox(
            id: MailboxID("mbx_\(account.id.rawValue)_inbox"), accountID: account.id,
            name: "INBOX", path: "INBOX", specialUse: "\\Inbox"
        )
        let direct = try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: account, inbox: inbox, source: direct)
        try await vault.store(Data(password.utf8), for: MailCredentialKeys.imapPassword(account.id))
        return account
    }
}

/// Only the external IMAP boundary is controlled. The runtime, durable job,
/// source checks, Core import, SQLite atomic commit, and lease are all real.
private final class ForegroundCheckpointIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let accountID: AccountID
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var didSearch = false
    private var searchReleased: Bool
    private let uidCount: Int
    private var searches = 0
    private var bodies = 0
    private var activeCalls = 0
    private var heldBodies = Set<Int>()
    private var enteredBodies = Set<Int>()
    private let finalTailArrivals: Bool

    init(accountID: AccountID, holdInitialSearch: Bool = false, uidCount: Int = 3, finalTailArrivals: Bool = false) {
        self.accountID = accountID
        self.searchReleased = !holdInitialSearch
        self.uidCount = uidCount
        self.finalTailArrivals = finalTailArrivals
    }

    var historyEntered: Bool { lock.withLock { entered } }
    var historyReleased: Bool { lock.withLock { released } }
    var searchEntered: Bool { lock.withLock { didSearch } }
    var searchCount: Int { lock.withLock { searches } }
    var bodyCount: Int { lock.withLock { bodies } }
    var activeCallCount: Int { lock.withLock { activeCalls } }
    var isSearchReleased: Bool { lock.withLock { searchReleased } }
    func holdBody(_ uid: Int) { _ = lock.withLock { heldBodies.insert(uid) } }
    func releaseBody(_ uid: Int) { _ = lock.withLock { heldBodies.remove(uid) } }
    func bodyEntered(_ uid: Int) -> Bool { lock.withLock { enteredBodies.contains(uid) } }
    func releaseAll() { lock.withLock { released = true; searchReleased = true; heldBodies.removeAll() } }
    func releaseHistory() { lock.withLock { released = true } }
    func releaseSearch() { lock.withLock { searchReleased = true } }

    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(
            id: MailboxID("mbx_\(accountID.rawValue)_inbox"), accountID: accountID,
            name: "INBOX", path: "INBOX", specialUse: "\\Inbox"
        )]
    }
    func selectMailbox(_ path: String) async throws -> String {
        guard path == "INBOX" else { throw IMAPClientError.connectionFailed }
        return "* OK [UIDVALIDITY 41] UIDs valid"
    }
    func allMessageUIDs() async throws -> [Int] {
        let searchNumber = lock.withLock { didSearch = true; searches += 1; activeCalls += 1; return searches }
        defer { lock.withLock { activeCalls -= 1 } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while !lock.withLock({ searchReleased }) {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw PlainpostError.validationFailed("Fixture SEARCH barrier was not released.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if finalTailArrivals { return Array(1...(searchNumber == 1 ? 3 : searchNumber == 2 ? 64 : 65)) }
        return uidCount == 0 ? [] : Array(1...uidCount)
    }
    func fetchHeader(uid: Int) async throws -> String {
        "From: Sender <sender@example.test>\r\nTo: reader@example.test\r\nSubject: Checkpoint fixture \(uid)\r\nMessage-ID: <checkpoint-\(uid)@example.test>\r\nDate: Tue, 01 Sep 2026 10:00:00 +0000\r\n"
    }
    func fetchInternalDate(uid: Int) async throws -> Date? { Date(timeIntervalSince1970: 1_788_256_800) }
    func fetchBody(uid: Int) async throws -> String {
        lock.withLock { bodies += 1; activeCalls += 1; _ = enteredBodies.insert(uid) }
        defer { lock.withLock { activeCalls -= 1 } }
        let bodyDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while lock.withLock({ heldBodies.contains(uid) }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < bodyDeadline else { throw IMAPClientError.connectionFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
        if uid == 1 {
            lock.withLock { entered = true }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while !historyReleased {
                try Task.checkCancellation()
                guard clock.now < deadline else {
                    throw PlainpostError.validationFailed("Fixture history barrier was not released.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return try await fetchHeader(uid: uid) + "\r\nCheckpoint body \(uid)"
    }
    func markRead(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func markUnread(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func archive(uid: Int, archiveMailbox: String) async throws { throw IMAPClientError.connectionFailed }
    func delete(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        throw IMAPClientError.connectionFailed
    }
}

private final class ForegroundCheckpointNotifications: LocalNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private let holdFailure: Bool
    private var enteredFailure = false
    private var releasedFailure = false
    private var failureContinuation: CheckedContinuation<Void, Never>?
    init(holdFailure: Bool = false) { self.holdFailure = holdFailure }
    var failureEntered: Bool { lock.withLock { enteredFailure } }
    var failureReleased: Bool { lock.withLock { releasedFailure } }
    func releaseFailure() {
        let continuation = lock.withLock {
            releasedFailure = true
            let value = failureContinuation
            failureContinuation = nil
            return value
        }
        continuation?.resume()
    }
    var completedCount: Int { lock.withLock { completed } }
    func schedule(_ notification: PlainpostNotification) async throws {
        if notification.categoryIdentifier == "sync_completed" {
            lock.withLock { completed += 1 }
        } else if notification.categoryIdentifier == "sync_failed", holdFailure {
            await withCheckedContinuation { continuation in
                let released = lock.withLock {
                    enteredFailure = true
                    if releasedFailure { return true }
                    failureContinuation = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
    }
}

private final class FirstSyncClientFactory: @unchecked Sendable {
    enum Mode { case waitForCancellation, fail }
    private let lock = NSLock()
    private var first = true
    private var didEnter = false
    private let mode: Mode
    private let tls: LocalImplicitTLSProxy

    init(mode: Mode, tls: LocalImplicitTLSProxy) {
        self.mode = mode
        self.tls = tls
    }

    var entered: Bool { lock.withLock { didEnter } }

    func make() -> IMAPClientProtocol {
        lock.withLock {
            if first {
                first = false
                return InterruptedFixtureIMAPClient(mode: mode) { [weak self] in
                    self?.lock.withLock { self?.didEnter = true }
                }
            }
            return SecureIMAPClient(
                host: "127.0.0.1", port: tls.port,
                certificateValidation: .testAnchor(tls.certificate)
            )
        }
    }
}

private struct InterruptedFixtureIMAPClient: IMAPClientProtocol {
    let mode: FirstSyncClientFactory.Mode
    let entered: () -> Void

    func login(username: String, password: String) async throws {
        entered()
        switch mode {
        case .waitForCancellation:
            while true { try await Task.sleep(for: .milliseconds(10)) }
        case .fail:
            throw PlainpostError.validationFailed("Fixture periodic sync failed.")
        }
    }

    func listMailboxes() async throws -> [Mailbox] { throw IMAPClientError.connectionFailed }
    func selectMailbox(_ path: String) async throws -> String { throw IMAPClientError.connectionFailed }
    func allMessageUIDs() async throws -> [Int] { throw IMAPClientError.connectionFailed }
    func fetchHeader(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func fetchBody(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func markRead(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func markUnread(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func archive(uid: Int, archiveMailbox: String) async throws { throw IMAPClientError.connectionFailed }
    func delete(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        throw IMAPClientError.connectionFailed
    }
}

private struct FailedFirstSync: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        throw IMAPClientError.connectionFailed
    }
}

private struct FixtureInboxSync: AccountInboxSyncOrchestrating {
    let store: SQLiteMailStore
    let dependencies: IOSLocalMailRuntimeDependencies

    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        let generation = try store.mailSource(accountID: account.id).generation
        let client = LocalOperationClient(runtime: dependencies.makeOperationRuntime(
            store: store, allowedJobKinds: [.inboxSync],
            selectedDirectAccountID: account.id,
            expectedDirectSourceGeneration: generation
        ))
        let result = try await client.executeInboxSync(.init(
            accountID: account.id,
            trigger: .accountSetup,
            expectedDirectSourceGeneration: generation
        ))
        return IMAPSyncResult(
            syncedMessageCount: result.syncedMessageCount,
            newlyDiscoveredMessageCount: result.newlyDiscoveredMessageCount,
            source: result.source
        )
    }
}

private final class ForegroundCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class ForegroundCompletionOperationClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0
    private var input: PlainpostAIOperationInput?
    var count: Int { lock.withLock { invocations } }
    var lastInput: PlainpostAIOperationInput? { lock.withLock { input } }
    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        lock.withLock { invocations += 1; self.input = input }
    }
    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult { throw PlainpostError.permissionDenied("Unused test boundary") }
    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult { throw PlainpostError.permissionDenied("Unused test boundary") }
    func approveSend(requestID: SendRequestID, approvedBy: String) async throws { throw PlainpostError.permissionDenied("Unused test boundary") }
    func denySend(requestID: SendRequestID, deniedBy: String) async throws { throw PlainpostError.permissionDenied("Unused test boundary") }
}
