import XCTest
import SQLite3
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport

final class QueuedOperationClientTests: XCTestCase {
    func testIncrementalSyncReusesActiveDurableJobAcrossStoreRestart() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let input = PlainpostInboxSyncInput(
            accountID: AccountID("account-a"),
            trigger: .manual,
            scope: .incremental
        )
        let firstStore = try SQLiteMailStore(path: databaseURL.path)
        try firstStore.migrate()
        try firstStore.cacheAccounts([syncTestAccount(id: input.accountID)])
        let first = try enqueueInboxSyncJob(input, store: firstStore)

        let reopenedStore = try SQLiteMailStore(path: databaseURL.path)
        try reopenedStore.migrate()
        let reopened = try enqueueInboxSyncJob(input, store: reopenedStore)

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(try reopenedStore.jobs(limit: 100).count, 1)
        XCTAssertEqual(try firstStore.claimNextJob()?.id, first.id)
        XCTAssertNil(try reopenedStore.claimNextJob())
    }

    func testQueuedScheduleThenRealtimeCoalescesBackgroundWorkAndRetainsReconciliation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-schedule-realtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-schedule-realtime")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )
        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )

        XCTAssertEqual(realtime.id, scheduled.id)
        XCTAssertEqual(realtime.priority, PlainpostInboxSyncInput(
            accountID: accountID,
            trigger: .realTimeSignal,
            scope: .incremental
        ).schedulingPriority)
        let activeSyncs = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(activeSyncs.map(\.id), [scheduled.id])
        let input = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data((try store.job(id: scheduled.id)).payloadJSON.utf8)
        )
        XCTAssertEqual(input.trigger, .schedule)
    }

    func testQueuedRealtimeThenScheduleCoalescesBackgroundWorkAndRetainsReconciliation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-realtime-schedule-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-realtime-schedule")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )
        let repeatedRealtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )

        XCTAssertEqual(scheduled.id, realtime.id)
        XCTAssertEqual(repeatedRealtime.id, realtime.id)
        XCTAssertEqual(scheduled.priority, PlainpostInboxSyncInput(
            accountID: accountID,
            trigger: .realTimeSignal,
            scope: .incremental
        ).schedulingPriority)
        let activeSyncs = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(activeSyncs.map(\.id), [realtime.id])
        let input = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data((try store.job(id: realtime.id)).payloadJSON.utf8)
        )
        XCTAssertEqual(input.trigger, .schedule)
    }

    func testRunningScheduledSyncCoversRealtimeSignalWithoutSecondBackgroundJob() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-operation-schedule-realtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-running-schedule")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )
        _ = try XCTUnwrap(store.claimNextJob())
        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )

        XCTAssertEqual(realtime.id, scheduled.id)
        let activeSyncs = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(activeSyncs.map(\.id), [scheduled.id])
    }

    func testRunningRealtimeSyncRetainsScheduleReconciliationWithoutSecondBackgroundJob() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-operation-realtime-schedule-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-running-realtime")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        _ = try XCTUnwrap(store.claimNextJob())
        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )

        XCTAssertEqual(scheduled.id, realtime.id)
        let activeSyncs = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(activeSyncs.map(\.id), [realtime.id])
    }

    func testCancellationRequestedRunningRealtimeCreatesOneCanonicalBackgroundSuccessor() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-operation-cancelled-successor-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let firstStore = try SQLiteMailStore(path: databaseURL.path)
        try firstStore.migrate()
        let accountID = AccountID("account-cancelled-successor")
        try firstStore.cacheAccounts([syncTestAccount(id: accountID)])
        let secondStore = try SQLiteMailStore(path: databaseURL.path)
        try secondStore.migrate()

        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: firstStore
        )
        let running = try XCTUnwrap(firstStore.claimNextJob())
        try firstStore.requestJobCancellation(id: running.id)

        async let scheduled = enqueueInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: accountID,
                trigger: .schedule,
                scope: .incremental
            ),
            store: firstStore
        )
        async let repeatedRealtime = enqueueInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: accountID,
                trigger: .realTimeSignal,
                scope: .incremental
            ),
            store: secondStore
        )
        let concurrentSignals = try await [scheduled, repeatedRealtime]
        let repeatedSchedule = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: secondStore
        )

        let successorIDs = Set(concurrentSignals.map(\.id) + [repeatedSchedule.id])
        XCTAssertEqual(successorIDs.count, 1)
        let successorID = try XCTUnwrap(successorIDs.first)
        XCTAssertNotEqual(successorID, realtime.id)
        let successor = try firstStore.job(id: successorID)
        XCTAssertEqual(successor.state, .queued)
        XCTAssertFalse(successor.cancellationRequested)
        XCTAssertEqual(
            successor.priority,
            PlainpostInboxSyncInput(
                accountID: accountID,
                trigger: .realTimeSignal,
                scope: .incremental
            ).schedulingPriority
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data(successor.payloadJSON.utf8)
            ).trigger,
            .schedule
        )
        XCTAssertEqual(try firstStore.job(id: realtime.id).state, .running)
        XCTAssertTrue(try firstStore.job(id: realtime.id).cancellationRequested)

        let recovery = try firstStore.recoverBackgroundAgentJobs(
            allowedKinds: [.inboxSync, .historicalSync]
        )
        XCTAssertEqual(recovery.cancelledDuplicateCount, 0)
        XCTAssertEqual(try firstStore.job(id: successorID).state, .queued)

        try firstStore.acknowledgeJobCancellation(
            id: realtime.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )
        XCTAssertEqual(try firstStore.job(id: realtime.id).state, .cancelled)
        let claimedSuccessor = try XCTUnwrap(firstStore.claimNextJob())
        XCTAssertEqual(claimedSuccessor.id, successorID)
        XCTAssertGreaterThan(
            try firstStore.inboxSyncReconciliationGeneration(
                id: successorID,
                leaseToken: try XCTUnwrap(claimedSuccessor.leaseToken)
            ),
            0
        )
    }

    func testScheduleBeforeInboxSyncCompletionKeepsTheRunningJobForOneReconciliationPass() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-operation-before-completion-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-before-completion")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let observedGeneration = try store.inboxSyncReconciliationGeneration(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )
        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )

        XCTAssertEqual(scheduled.id, realtime.id)
        XCTAssertTrue(
            try store.completeInboxSyncPass(
                id: running.id,
                leaseToken: try XCTUnwrap(running.leaseToken),
                observedReconciliationGeneration: observedGeneration,
                resultArtifactID: nil
            )
        )
        XCTAssertEqual(try store.job(id: running.id).state, .running)

        let reconciliationGeneration = try store.inboxSyncReconciliationGeneration(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )
        XCTAssertFalse(
            try store.completeInboxSyncPass(
                id: running.id,
                leaseToken: try XCTUnwrap(running.leaseToken),
                observedReconciliationGeneration: reconciliationGeneration,
                resultArtifactID: nil
            )
        )
        XCTAssertEqual(try store.job(id: running.id).state, .completed)
    }

    func testScheduleAfterInboxSyncCompletionCreatesTheNextBackgroundJob() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-operation-after-completion-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-after-completion")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let observedGeneration = try store.inboxSyncReconciliationGeneration(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )
        XCTAssertFalse(
            try store.completeInboxSyncPass(
                id: running.id,
                leaseToken: try XCTUnwrap(running.leaseToken),
                observedReconciliationGeneration: observedGeneration,
                resultArtifactID: nil
            )
        )

        let scheduled = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .schedule, scope: .incremental),
            store: store
        )
        XCTAssertNotEqual(scheduled.id, realtime.id)
        XCTAssertEqual(scheduled.state, .queued)
        let activeSyncs = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(activeSyncs.map(\.id), [scheduled.id])
    }

    func testManualRecentUpgradesQueuedBackgroundWithoutCoalescingCompleteHistory() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-account-singleton-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-a")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let realtime = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        let manual = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: .recent),
            store: store
        )
        let historical = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: .completeHistory),
            store: store
        )

        XCTAssertEqual(realtime.id, manual.id)
        XCTAssertNotEqual(historical.id, manual.id)
        let upgradedJob = try store.job(id: manual.id)
        let upgradedInput = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data(upgradedJob.payloadJSON.utf8)
        )
        XCTAssertEqual(upgradedJob.kind, .inboxSync)
        XCTAssertEqual(upgradedInput.trigger, .manual)
        XCTAssertEqual(upgradedInput.scope, .recent)
        XCTAssertEqual(
            try store.jobs(limit: 100).filter { [.queued, .running, .paused].contains($0.state) }.count,
            2
        )
    }

    func testDifferentQueuedSyncRequestsRemainDistinctWithoutDowngradingWork() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-distinct-work-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-distinct-work")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let manual = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .manual, scope: .recent),
            store: store
        )
        let realtime = try enqueueInboxSyncJob(
            .init(accountID: accountID, trigger: .realTimeSignal, scope: .recent),
            store: store
        )

        XCTAssertNotEqual(manual.id, realtime.id)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data((try store.job(id: manual.id)).payloadJSON.utf8)
            ),
            .init(accountID: accountID, trigger: .manual, scope: .recent)
        )
        XCTAssertGreaterThan(manual.priority, realtime.priority)
    }

    func testManualRecentQueuesOneFollowUpBehindRunningBackgroundIncremental() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-running-upgrade-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-running-upgrade")
        try store.cacheAccounts([syncTestAccount(id: accountID)])

        let background = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .realTimeSignal, scope: .incremental),
            store: store
        )
        let runningBackground = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(runningBackground.id, background.id)

        let manual = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: .recent),
            store: store
        )
        let repeatedManual = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: .recent),
            store: store
        )

        XCTAssertNotEqual(manual.id, background.id)
        XCTAssertEqual(repeatedManual.id, manual.id)
        let manualInput = try JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data(manual.payloadJSON.utf8)
        )
        XCTAssertEqual(manualInput.trigger, .manual)
        XCTAssertEqual(manualInput.scope, .recent)
        XCTAssertEqual(
            try store.jobs(limit: 100).filter { [.queued, .running, .paused].contains($0.state) }.count,
            2
        )
        let recovery = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.inboxSync, .historicalSync]
        )
        XCTAssertEqual(recovery.cancelledDuplicateCount, 0)
        XCTAssertEqual(try store.job(id: background.id).state, .running)
        XCTAssertEqual(try store.job(id: manual.id).state, .queued)

        try store.completeJob(
            id: background.id,
            leaseToken: try XCTUnwrap(runningBackground.leaseToken),
            resultArtifactID: nil
        )
        XCTAssertEqual(try store.claimNextJob()?.id, manual.id)
    }

    func testInboxSyncSchedulingPriorityFavorsManualOverRealtimeAndScheduleByDefault() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-priority-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let backgroundAccount = AccountID("account-background-priority")
        let manualAccount = AccountID("account-manual-priority")
        let scheduledAccount = AccountID("account-scheduled-priority")
        try store.cacheAccounts([
            syncTestAccount(id: backgroundAccount),
            syncTestAccount(id: manualAccount),
            syncTestAccount(id: scheduledAccount),
        ])

        let background = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: backgroundAccount,
                trigger: .realTimeSignal,
                scope: .incremental
            ),
            store: store
        )
        let manual = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: manualAccount,
                trigger: .manual,
                scope: .recent
            ),
            store: store
        )
        let scheduled = try enqueueInboxSyncJob(
            PlainpostInboxSyncInput(
                accountID: scheduledAccount,
                trigger: .schedule,
                scope: .incremental
            ),
            store: store
        )

        XCTAssertGreaterThan(manual.priority, background.priority)
        XCTAssertGreaterThan(background.priority, scheduled.priority)
        XCTAssertEqual(try store.claimNextJob()?.id, manual.id)
        XCTAssertEqual(try store.claimNextJob()?.id, background.id)
        XCTAssertEqual(try store.claimNextJob()?.id, scheduled.id)
    }

    func testBackgroundRecoveryCancelsOnlyEquivalentLegacyInboxSyncJobs() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-legacy-dedup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-a")
        try store.cacheAccounts([syncTestAccount(id: accountID)])
        let input = PlainpostInboxSyncInput(accountID: accountID, trigger: .manual, scope: .recent)

        for index in 0..<3 {
            let payload = try JSONEncoder().encode(input)
            _ = try store.enqueueJob(PlainpostJobRequest(
                kind: input.scope == .completeHistory ? .historicalSync : .inboxSync,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                idempotencyKey: "legacy-sync-\(index)"
            ))
        }

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.inboxSync, .historicalSync]
        )
        let active = try store.jobs(limit: 100).filter {
            ($0.kind == .inboxSync || $0.kind == .historicalSync)
                && [.queued, .running, .paused].contains($0.state)
        }

        XCTAssertEqual(summary.cancelledDuplicateCount, 2)
        XCTAssertEqual(active.count, 1)
    }

    func testBackgroundRecoveryMergesLegacyScheduleBehindRunningRealtimeWithoutDroppingReconciliation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-legacy-schedule-realtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let accountID = AccountID("account-legacy-schedule-realtime")
        try store.cacheAccounts([syncTestAccount(id: accountID)])
        let realtimeInput = PlainpostInboxSyncInput(
            accountID: accountID,
            trigger: .realTimeSignal,
            scope: .incremental
        )
        let scheduleInput = PlainpostInboxSyncInput(
            accountID: accountID,
            trigger: .schedule,
            scope: .incremental
        )
        let realtime = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(realtimeInput), as: UTF8.self),
                priority: realtimeInput.schedulingPriority,
                idempotencyKey: "legacy-realtime"
            )
        )
        let runningRealtime = try XCTUnwrap(store.claimNextJob())
        let scheduled = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(scheduleInput), as: UTF8.self),
                priority: scheduleInput.schedulingPriority,
                idempotencyKey: "legacy-schedule"
            )
        )

        let recovery = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.inboxSync, .historicalSync]
        )

        XCTAssertEqual(recovery.cancelledDuplicateCount, 1)
        XCTAssertEqual(try store.job(id: scheduled.id).state, .cancelled)
        XCTAssertEqual(try store.job(id: realtime.id).state, .running)
        let observedGeneration = try store.inboxSyncReconciliationGeneration(
            id: realtime.id,
            leaseToken: try XCTUnwrap(runningRealtime.leaseToken)
        )
        XCTAssertGreaterThan(observedGeneration, 0)
    }

    func testBackgroundRecoveryRetainsManualPauseAndCancelsOnlyCompatibleIncrementalDuplicate() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-manual-pause-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let baseline = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic",
            modelID: "deterministic-local"
        ).resolvingSmartInboxClassifierIdentity()
        let incompatible = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "ollama",
            modelID: "qwen3:8b"
        ).resolvingSmartInboxClassifierIdentity()
        func enqueue(_ input: PlainpostAIOperationInput, key: String) throws -> PlainpostDurableJob {
            try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .aiOperation,
                    payloadJSON: String(
                        decoding: try JSONEncoder().encode(input),
                        as: UTF8.self
                    ),
                    idempotencyKey: key
                )
            )
        }
        let duplicate = try enqueue(baseline, key: "legacy-compatible-duplicate")
        let manualPause = try enqueue(baseline, key: "legacy-compatible-manual-pause")
        try store.requestJobPause(id: manualPause.id)
        let separate = try enqueue(incompatible, key: "legacy-incompatible-incremental")

        let summary = try store.recoverBackgroundAgentJobs(allowedKinds: [.aiOperation])
        let activeIncremental = try store.jobs(limit: 100).filter { job in
            guard [.queued, .running, .paused].contains(job.state),
                  let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(job.payloadJSON.utf8)
                  ) else {
                return false
            }
            return input.operation == .recategorizeInbox
                && input.smartInboxRunMode == .incremental
        }

        XCTAssertEqual(summary.cancelledDuplicateCount, 1)
        XCTAssertEqual(Set(activeIncremental.map(\.id)), Set([manualPause.id, separate.id]))
        XCTAssertEqual(try store.job(id: duplicate.id).state, .cancelled)
        XCTAssertEqual(try store.job(id: manualPause.id).state, .paused)
        XCTAssertEqual(try store.job(id: manualPause.id).pauseReason, "user-requested")
        XCTAssertEqual(try store.job(id: separate.id).state, .queued)
    }

    func testBackgroundRecoveryNeverCancelsManualPauseWhenCompatibleJobIsRunning() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-running-with-manual-pause-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let message = MessageSummary(
            id: MessageID("msg_running_with_manual_pause"),
            threadID: ThreadID("thr_running_with_manual_pause"),
            from: EmailAddress("alice@example.com"),
            subject: "Preserve manual pause",
            preview: "Keep prepared and staged Smart Inbox work.",
            smartCategory: .unknown
        )
        try store.cacheOwnedTestMessage(message)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let manualPause = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        let manualRunning = try XCTUnwrap(
            store.claimNextJob(now: start, leaseDuration: 60)
        )
        XCTAssertEqual(manualRunning.id, manualPause.id)
        let manualLease = try XCTUnwrap(manualRunning.leaseToken)
        let catalog = try XCTUnwrap(
            store.smartInboxLabelCatalogSnapshot(jobID: manualPause.id)
        )
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        let classifierDiscriminator = input.resolvedSmartInboxClassifierIdentity.discriminator
        try store.prepareSmartInboxWork(
            jobID: manualPause.id,
            leaseToken: manualLease,
            seeds: [
                .init(
                    ordinal: 0,
                    messageID: message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: classifierDiscriminator
                    )
                ),
            ],
            catalogSnapshot: catalog
        )
        _ = try store.recordSmartInboxClassification(
            jobID: manualPause.id,
            leaseToken: manualLease,
            ordinal: 0,
            classification: .init(
                messageID: message.id,
                category: .personal,
                priority: .normal,
                requiresAction: false,
                confidence: 0.95
            ),
            providerID: input.resolvedSmartInboxClassifierIdentity.providerID,
            modelID: input.resolvedSmartInboxClassifierIdentity.modelID,
            classifierDiscriminator: classifierDiscriminator,
            actor: Actor(
                id: "manual-pause-preservation-test",
                kind: .user,
                displayName: "Manual Pause Preservation Test",
                permissions: .guiUser
            )
        )
        try store.requestJobPause(id: manualPause.id)
        let pausedProgress = PlainpostOperationProgress(
            current: 1,
            total: 1,
            phase: "paused",
            label: "Smart Inbox"
        )
        try store.acknowledgeJobPause(
            id: manualPause.id,
            leaseToken: manualLease,
            progress: pausedProgress
        )
        let workBefore = try store.smartInboxWorkSummary(jobID: manualPause.id)
        let snapshotBefore = try store.smartInboxLabelCatalogSnapshot(jobID: manualPause.id)

        let compatible = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: manualPause.payloadJSON,
                idempotencyKey: "legacy-compatible-running-\(UUID().uuidString)"
            )
        )
        let compatibleRunning = try XCTUnwrap(
            store.claimNextJob(
                now: start.addingTimeInterval(1),
                leaseDuration: 60
            )
        )
        XCTAssertEqual(compatibleRunning.id, compatible.id)
        try store.prepareSmartInboxWork(
            jobID: compatible.id,
            leaseToken: try XCTUnwrap(compatibleRunning.leaseToken),
            seeds: [],
            catalogSnapshot: catalog
        )
        XCTAssertEqual(try store.job(id: compatible.id).state, .running)
        XCTAssertGreaterThan(
            try XCTUnwrap(store.job(id: compatible.id).leaseExpiresAt),
            start.addingTimeInterval(2)
        )

        let summary = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: start.addingTimeInterval(2)
        )
        let preserved = try store.job(id: manualPause.id)

        XCTAssertEqual(summary.cancelledDuplicateCount, 0)
        XCTAssertEqual(preserved.id, manualPause.id)
        XCTAssertEqual(preserved.state, .paused)
        XCTAssertEqual(preserved.pauseReason, "user-requested")
        XCTAssertEqual(preserved.progress, pausedProgress)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: manualPause.id), workBefore)
        XCTAssertEqual(
            try store.smartInboxLabelCatalogSnapshot(jobID: manualPause.id),
            snapshotBefore
        )
        XCTAssertEqual(try store.job(id: compatible.id).state, .running)
    }

    func testBackgroundRecoveryPreservesLaterManualPauseBesideCompatibleRunningWork() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-running-before-manual-pause-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let payloadJSON = String(
            decoding: try JSONEncoder().encode(input),
            as: UTF8.self
        )
        let runningJob = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: payloadJSON,
                idempotencyKey: "legacy-running-before-manual-pause"
            )
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let running = try XCTUnwrap(
            store.claimNextJob(now: start, leaseDuration: 60)
        )
        XCTAssertEqual(running.id, runningJob.id)
        let manualPause = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: payloadJSON,
                idempotencyKey: "legacy-manual-pause-after-running"
            )
        )
        try store.requestJobPause(id: manualPause.id)

        _ = try store.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: start.addingTimeInterval(1)
        )

        XCTAssertEqual(try store.job(id: runningJob.id).state, .running)
        XCTAssertEqual(try store.job(id: manualPause.id).state, .paused)
        XCTAssertEqual(try store.job(id: manualPause.id).pauseReason, "user-requested")
    }

    func testTerminalIncrementalSyncAllowsExactlyOneFreshJobForConcurrentCallers() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-sync-terminal-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let input = PlainpostInboxSyncInput(
            accountID: AccountID("account-a"),
            trigger: .manual,
            scope: .incremental
        )
        try store.cacheAccounts([syncTestAccount(id: input.accountID)])
        let original = try enqueueInboxSyncJob(input, store: store)
        let running = try XCTUnwrap(store.claimNextJob())
        let artifact = DurableOperationArtifact(
            id: "sync-result",
            kind: "inbox-sync",
            recordID: input.accountID.rawValue,
            payloadJSON: String(decoding: try JSONEncoder().encode(
                PlainpostInboxSyncResult(
                    accountID: input.accountID,
                    syncedMessageCount: 0,
                    jobID: running.id
                )
            ), as: UTF8.self)
        )
        try store.saveDurableOperationArtifact(
            artifact,
            forJobID: running.id
        )
        try store.completeJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: artifact.id
        )

        async let first = enqueueInboxSyncJob(input, store: store)
        async let second = enqueueInboxSyncJob(input, store: store)
        let replacements = try await [first, second]

        XCTAssertEqual(Set(replacements.map(\.id)).count, 1)
        XCTAssertNotEqual(replacements[0].id, original.id)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.state == .queued }.count, 1)

        let replacementRunning = try XCTUnwrap(store.claimNextJob())
        try store.failJob(
            id: replacementRunning.id,
            leaseToken: try XCTUnwrap(replacementRunning.leaseToken),
            code: "OFFLINE",
            message: "Offline",
            retryAt: nil
        )

        async let afterFailureFirst = enqueueInboxSyncJob(input, store: store)
        async let afterFailureSecond = enqueueInboxSyncJob(input, store: store)
        let afterFailure = try await [afterFailureFirst, afterFailureSecond]

        XCTAssertEqual(Set(afterFailure.map(\.id)).count, 1)
        XCTAssertNotEqual(afterFailure[0].id, replacementRunning.id)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.state == .queued }.count, 1)
    }

    func testIncrementalRequestIdentityChangesAcrossClassifierSelection() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-model-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_model_switch"),
                threadID: ThreadID("thr_model_switch"),
                from: EmailAddress("alice@example.com"),
                subject: "Model switch",
                preview: "Organize once",
                smartCategory: .unknown
            )
        )
        let first = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation",
            modelID: "model-a"
        )
        let second = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "ollama",
            modelID: "model-b"
        )

        let firstIdentity = try smartInboxJobIdentity(input: first, store: store)
        let secondIdentity = try smartInboxJobIdentity(input: second, store: store)

        XCTAssertNotEqual(firstIdentity, secondIdentity)
    }

    func testIncrementalRequestIdentityChangesAcrossSchemaAndPromptVersions() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-contract-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_contract_switch"),
                threadID: nil,
                from: EmailAddress("alice@example.com"),
                subject: "Contract switch",
                preview: "Reclassify for contract changes",
                smartCategory: .unknown
            )
        )
        func input(schemaVersion: String, promptVersion: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                modelID: "deterministic-local",
                smartInboxClassifierIdentity: SmartInboxClassifierIdentity(
                    providerID: "deterministic",
                    modelID: "deterministic-local",
                    schemaVersion: schemaVersion,
                    promptVersion: promptVersion
                )
            )
        }

        let baseline = try smartInboxJobIdentity(
            input: input(schemaVersion: "schema-v1", promptVersion: "prompt-v1"),
            store: store
        )
        let schemaChanged = try smartInboxJobIdentity(
            input: input(schemaVersion: "schema-v2", promptVersion: "prompt-v1"),
            store: store
        )
        let promptChanged = try smartInboxJobIdentity(
            input: input(schemaVersion: "schema-v1", promptVersion: "prompt-v2"),
            store: store
        )

        XCTAssertNotEqual(baseline, schemaChanged)
        XCTAssertNotEqual(baseline, promptChanged)
    }

    private func syncTestAccount(id: AccountID) -> Account {
        Account(
            id: id,
            displayName: "Sync Test",
            email: EmailAddress("sync@example.com"),
            imapHost: "127.0.0.1",
            smtpHost: "127.0.0.1"
        )
    }

    func testFullRerunIdentityCoalescesDifferentActiveRequestIDs() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-rerun-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_rerun_identity"),
                threadID: ThreadID("thr_rerun_identity"),
                from: EmailAddress("alice@example.com"),
                subject: "Rerun",
                preview: "Reprocess deliberately",
                smartCategory: .unknown
            )
        )
        let first = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "request-one"
        )
        let second = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation",
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "request-two"
        )

        XCTAssertEqual(
            try smartInboxJobIdentity(input: first, store: store),
            try smartInboxJobIdentity(input: second, store: store)
        )
    }

    func testCompletedRerunJobCanBeReplaced() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-completed-rerun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let request = PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            idempotencyKey: "completed-rerun",
            replaceTerminalDuplicate: true
        )
        let original = try store.enqueueJob(request)
        let running = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )

        let replacement = try store.enqueueJob(request)

        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.state, .queued)
        XCTAssertEqual(try store.job(id: original.id).state, .completed)
    }

    func testDeliveryUncertainRerunJobCanBeReplaced() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-uncertain-rerun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let request = PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            idempotencyKey: "uncertain-rerun",
            replaceTerminalDuplicate: true
        )
        let original = try store.enqueueJob(request)
        let running = try XCTUnwrap(store.claimNextJob())
        try store.markDeliveryUncertain(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            message: "Delivery outcome is unknown."
        )

        let replacement = try store.enqueueJob(request)

        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.state, .queued)
        XCTAssertEqual(try store.job(id: original.id).state, .deliveryUncertain)
    }

    func testDifferentRerunRequestIDsAttachToQueuedRunningAndPausedJob() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-active-rerun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_active_rerun"),
                threadID: ThreadID("thr_active_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Active rerun",
                preview: "Attach every active state",
                smartCategory: .unknown
            )
        )
        func input(_ requestID: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: requestID
            )
        }

        let queued = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input("queued")).job)
        let queuedDuplicate = try XCTUnwrap(
            try store.enqueueSmartInboxJob(input: input("queued-duplicate")).job
        )
        XCTAssertEqual(queuedDuplicate.id, queued.id)

        let running = try XCTUnwrap(store.claimNextJob())
        let runningDuplicate = try XCTUnwrap(
            try store.enqueueSmartInboxJob(input: input("running-duplicate")).job
        )
        XCTAssertEqual(runningDuplicate.id, running.id)

        try store.pauseJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            reason: "test-pause",
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        let pausedDuplicate = try XCTUnwrap(
            try store.enqueueSmartInboxJob(input: input("paused-duplicate")).job
        )
        XCTAssertEqual(pausedDuplicate.id, running.id)
        XCTAssertEqual(pausedDuplicate.state, .paused)
    }

    func testDifferentFullRerunClassifierIdentitiesDoNotAttachAcrossActiveStates() throws {
        let baseline = SmartInboxClassifierIdentity(
            providerID: "deterministic",
            modelID: "deterministic-local",
            schemaVersion: "schema-v1",
            promptVersion: "prompt-v1"
        )
        let scenarios: [(state: PlainpostOperationState, identity: SmartInboxClassifierIdentity)] = [
            (
                .queued,
                SmartInboxClassifierIdentity(
                    providerID: baseline.providerID,
                    modelID: "deterministic-local-v2",
                    schemaVersion: baseline.schemaVersion,
                    promptVersion: baseline.promptVersion
                )
            ),
            (
                .running,
                SmartInboxClassifierIdentity(
                    providerID: baseline.providerID,
                    modelID: baseline.modelID,
                    schemaVersion: "schema-v2",
                    promptVersion: baseline.promptVersion
                )
            ),
            (
                .paused,
                SmartInboxClassifierIdentity(
                    providerID: baseline.providerID,
                    modelID: baseline.modelID,
                    schemaVersion: baseline.schemaVersion,
                    promptVersion: "prompt-v2"
                )
            ),
        ]

        for scenario in scenarios {
            let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "queued-operation-rerun-identity-\(scenario.state.rawValue)-\(UUID().uuidString).sqlite"
            )
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let store = try SQLiteMailStore(path: databaseURL.path)
            try store.migrate()
            try store.cacheOwnedTestMessage(
                MessageSummary(
                    id: MessageID("msg_rerun_identity_\(scenario.state.rawValue)"),
                    threadID: nil,
                    from: EmailAddress("alice@example.com"),
                    subject: "Full rerun identity",
                    preview: "Do not attach incompatible classifier work",
                    smartCategory: .unknown
                )
            )
            func input(
                requestID: String,
                identity: SmartInboxClassifierIdentity
            ) -> PlainpostAIOperationInput {
                PlainpostAIOperationInput(
                    operation: .recategorizeInbox,
                    recordID: "",
                    providerID: identity.providerID,
                    modelID: identity.modelID,
                    smartInboxRunMode: .rerunAll,
                    smartInboxRequestID: requestID,
                    smartInboxClassifierIdentity: identity
                )
            }

            let original = try XCTUnwrap(
                try store.enqueueSmartInboxJob(
                    input: input(requestID: "original", identity: baseline)
                ).job
            )
            switch scenario.state {
            case .queued:
                break
            case .running:
                let running = try XCTUnwrap(store.claimNextJob())
                XCTAssertEqual(running.id, original.id)
            case .paused:
                let running = try XCTUnwrap(store.claimNextJob())
                XCTAssertEqual(running.id, original.id)
                try store.pauseJob(
                    id: running.id,
                    leaseToken: try XCTUnwrap(running.leaseToken),
                    reason: "test-pause",
                    progress: .init(
                        current: 0,
                        total: 1,
                        phase: "paused",
                        label: "Smart Inbox"
                    )
                )
            default:
                XCTFail("Unsupported active test state: \(scenario.state.rawValue)")
            }

            let changed = try XCTUnwrap(
                try store.enqueueSmartInboxJob(
                    input: input(requestID: "changed", identity: scenario.identity)
                ).job
            )
            let changedInput = try JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data(changed.payloadJSON.utf8)
            )

            XCTAssertNotEqual(changed.id, original.id, "state: \(scenario.state.rawValue)")
            XCTAssertEqual(changedInput.smartInboxClassifierIdentity, scenario.identity)
            XCTAssertTrue(changed.idempotencyKey.hasPrefix("ai:recategorizeInbox:v3:"))
            XCTAssertEqual(
                try store.jobs(limit: 100).filter {
                    [.queued, .running, .paused].contains($0.state)
                }.count,
                2,
                "state: \(scenario.state.rawValue)"
            )
        }
    }

    func testActiveFullRerunCoalescesAfterWorkSetChanges() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-changing-rerun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_initial_rerun"),
                threadID: ThreadID("thr_initial_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Initial rerun work",
                preview: "Present before enqueue",
                smartCategory: .unknown
            )
        )
        func input(_ requestID: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: requestID
            )
        }
        let active = try XCTUnwrap(
            try store.enqueueSmartInboxJob(input: input("initial-request")).job
        )
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_arrived_during_rerun"),
                threadID: ThreadID("thr_arrived_during_rerun"),
                from: EmailAddress("bob@example.com"),
                subject: "Changed rerun work set",
                preview: "Arrived after enqueue",
                smartCategory: .unknown
            )
        )

        let duplicate = try XCTUnwrap(
            try store.enqueueSmartInboxJob(input: input("later-request")).job
        )

        XCTAssertEqual(duplicate.id, active.id)
        XCTAssertEqual(
            try store.jobs(limit: 100).filter { [.queued, .running, .paused].contains($0.state) }.count,
            1
        )
    }

    func testConcurrentTerminalRerunReplacementCreatesOneNewActiveJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-terminal-rerun-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_terminal_rerun"),
                threadID: ThreadID("thr_terminal_rerun"),
                from: EmailAddress("alice@example.com"),
                subject: "Terminal rerun",
                preview: "Replace once",
                smartCategory: .unknown
            )
        )
        func input(_ requestID: String) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic",
                smartInboxRunMode: .rerunAll,
                smartInboxRequestID: requestID
            )
        }
        let original = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input("original")).job)
        let running = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        )

        async let first = store.enqueueSmartInboxJob(input: input("replacement-one"))
        async let second = store.enqueueSmartInboxJob(input: input("replacement-two"))
        let replacements = try await [first, second].compactMap(\.job)

        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(Set(replacements.map(\.id)).count, 1)
        XCTAssertNotEqual(replacements.first?.id, original.id)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.state == .queued }.count, 1)
    }

    func testEquivalentSmartInboxRequestsCoalesceToOneDurableJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-coalescing-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_coalesce"),
                threadID: ThreadID("thr_coalesce"),
                from: EmailAddress("alice@example.com"),
                subject: "Coalesce",
                preview: "Organize once",
                smartCategory: .newsletter
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild]
        )
        let signal = RecordingWorkerSignal(runtime: runtime)
        let client = QueuedOperationClient(store: store, workerSignal: signal)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        )

        async let first = client.executeAI(input)
        async let second = client.executeAI(input)
        let results = try await [first, second]

        XCTAssertEqual(results[0].jobID, results[1].jobID)
        let organizerJobs = try store.jobs(limit: 100).filter { job in
            guard let decoded = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data(job.payloadJSON.utf8)
            ) else { return false }
            return decoded.operation == .recategorizeInbox
        }
        XCTAssertEqual(organizerJobs.count, 1)
        XCTAssertEqual(organizerJobs.first?.state, .completed)
    }

    func testAutomaticIncrementalRequestAttachesToManualPauseWithoutWorkerSignal() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-manual-pause-coalescing-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_manual_pause_coalesce"),
                threadID: ThreadID("thr_manual_pause_coalesce"),
                from: EmailAddress("alice@example.com"),
                subject: "Remain paused",
                preview: "Automatic organization must attach without waking a worker.",
                smartCategory: .unknown
            )
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        )
        let paused = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        try store.requestJobPause(id: paused.id)

        let coalesced = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        XCTAssertEqual(coalesced.id, paused.id)
        XCTAssertEqual(coalesced.state, .paused)
        XCTAssertEqual(coalesced.pauseReason, "user-requested")

        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild]
        )
        let signal = RecordingWorkerSignal(runtime: runtime)
        let client = QueuedOperationClient(
            store: store,
            workerSignal: signal,
            pollInterval: .milliseconds(10)
        )
        let request = Task {
            try await client.executeAI(input)
        }
        try await Task.sleep(for: .milliseconds(100))

        let active = try store.jobs(limit: 100).filter {
            [.queued, .running, .paused].contains($0.state)
        }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, paused.id)
        XCTAssertEqual(active.first?.state, .paused)
        XCTAssertEqual(active.first?.pauseReason, "user-requested")
        let signalCount = await signal.signalCount
        XCTAssertEqual(signalCount, 0)

        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected the waiting request to observe cancellation.")
        } catch is CancellationError {
            // Expected: runtime pause acknowledgement is intentionally a later task.
        }
    }

    func testCompletionAtomicallyPromotesOnePreparedFollowUpAcrossStoreReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-follow-up-demand-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = MessageSummary(
            id: MessageID("msg_follow_up_first"), threadID: ThreadID("thr_follow_up_first"),
            from: EmailAddress("alice@example.com"), subject: "First", preview: "Prepared", smartCategory: .unknown
        )
        let later = MessageSummary(
            id: MessageID("msg_follow_up_later"), threadID: ThreadID("thr_follow_up_later"),
            from: EmailAddress("bob@example.com"), subject: "Later", preview: "Follow up", smartCategory: .unknown
        )
        try store.cacheOwnedTestMessage(first)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox, recordID: "", providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let original = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)
        let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: original.id))
        let firstInput = try XCTUnwrap(store.smartInboxClassificationInputs(scope: .allAccounts).first)
        try store.prepareSmartInboxWork(
            jobID: original.id,
            leaseToken: lease,
            seeds: [.init(
                ordinal: 0,
                messageID: first.id.rawValue,
                sourceFingerprint: SmartInboxClassificationFingerprint.message(
                    firstInput,
                    classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator
                )
            )],
            catalogSnapshot: catalog
        )
        try store.requestJobPause(id: original.id)
        try store.acknowledgeJobPause(
            id: original.id,
            leaseToken: lease,
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        try store.cacheOwnedTestMessage(later)
        let client = QueuedOperationClient(store: store, workerSignal: NoopOperationWorkerSignal())
        try await client.enqueueIncrementalSmartInbox(input)
        try await client.enqueueIncrementalSmartInbox(input)

        let reopenedStore = try SQLiteMailStore(path: url.path)
        try reopenedStore.migrate()
        try reopenedStore.resumeUserPausedJob(id: original.id, now: Date())
        let resumed = try XCTUnwrap(reopenedStore.claimNextJob())
        XCTAssertEqual(resumed.id, original.id)
        try reopenedStore.completeJob(id: resumed.id, leaseToken: try XCTUnwrap(resumed.leaseToken), resultArtifactID: nil)

        // This is the crash/relaunch boundary: completion and promotion have committed,
        // then a fresh store must observe the sole runnable successor with no demand left behind.
        let relaunchedStore = try SQLiteMailStore(path: url.path)
        try relaunchedStore.migrate()
        let organizers = try relaunchedStore.jobs(limit: 100).filter { $0.kind == .aiOperation }
        XCTAssertEqual(organizers.count, 2)
        let followUp = try XCTUnwrap(organizers.first { $0.state == .queued })
        XCTAssertEqual(
            try relaunchedStore.terminalSmartInboxSuccessor(after: original.id),
            followUp.id
        )
        XCTAssertFalse(try hasPendingFollowUpDemand(at: url, predecessorID: original.id))
        XCTAssertFalse(try hasPendingFollowUpDemand(at: url, predecessorID: followUp.id))
    }

    func testCompletionCancelsPreparedFollowUpWhenOnlyUnchangedFailuresRemain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-empty-failure-follow-up-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let message = MessageSummary(
            id: MessageID("msg_failed_follow_up"),
            threadID: ThreadID("thr_failed_follow_up"),
            from: EmailAddress("alice@example.com"),
            subject: "Cannot classify",
            preview: "Do not loop",
            smartCategory: .unknown
        )
        try store.cacheOwnedTestMessage(message)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let predecessor = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)
        let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: predecessor.id))
        let classificationInput = try XCTUnwrap(
            store.smartInboxClassificationInputs(scope: .allAccounts).first
        )
        try store.prepareSmartInboxWork(
            jobID: predecessor.id,
            leaseToken: lease,
            seeds: [.init(
                ordinal: 0,
                messageID: message.id.rawValue,
                sourceFingerprint: SmartInboxClassificationFingerprint.message(
                    classificationInput,
                    classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator
                )
            )],
            catalogSnapshot: catalog
        )

        _ = try store.enqueueSmartInboxJob(input: input)
        let successor = try XCTUnwrap(
            try store.jobs(limit: 10).first {
                $0.id != predecessor.id && $0.pauseReason == "smart-inbox-follow-up"
            }
        )
        _ = try store.recordSmartInboxWorkItem(
            jobID: predecessor.id,
            leaseToken: lease,
            ordinal: 0,
            state: .failed,
            classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator,
            errorMessage: "Safe failure"
        )
        try store.completeJob(id: predecessor.id, leaseToken: lease, resultArtifactID: nil)

        XCTAssertEqual(try store.job(id: successor.id).state, .cancelled)
        XCTAssertNil(try store.terminalSmartInboxSuccessor(after: predecessor.id))
        XCTAssertFalse(try hasPendingFollowUpDemand(at: url, predecessorID: predecessor.id))
    }

    func testLocalClientContinuesPromotedPreparedFollowUpAfterUserResume() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-local-follow-up-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = MessageSummary(
            id: MessageID("msg_local_follow_up_first"), threadID: ThreadID("thr_local_follow_up_first"),
            from: EmailAddress("alice@example.com"), subject: "First", preview: "Prepared", smartCategory: .unknown
        )
        let later = MessageSummary(
            id: MessageID("msg_local_follow_up_later"), threadID: ThreadID("thr_local_follow_up_later"),
            from: EmailAddress("bob@example.com"), subject: "Later", preview: "Follow up", smartCategory: .unknown
        )
        try store.cacheOwnedTestMessage(first)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox, recordID: "", providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()
        let original = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
        let running = try XCTUnwrap(store.claimNextJob())
        let lease = try XCTUnwrap(running.leaseToken)
        let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: original.id))
        let firstInput = try XCTUnwrap(store.smartInboxClassificationInputs(scope: .allAccounts).first)
        try store.prepareSmartInboxWork(
            jobID: original.id,
            leaseToken: lease,
            seeds: [.init(
                ordinal: 0,
                messageID: first.id.rawValue,
                sourceFingerprint: SmartInboxClassificationFingerprint.message(
                    firstInput,
                    classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator
                )
            )],
            catalogSnapshot: catalog
        )
        try store.requestJobPause(id: original.id)
        try store.acknowledgeJobPause(
            id: original.id,
            leaseToken: lease,
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )
        try store.cacheOwnedTestMessage(later)
        let localClient = LocalOperationClient(runtime: LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild]
        ))

        try await localClient.enqueueIncrementalSmartInbox(input)
        try await localClient.enqueueIncrementalSmartInbox(input)
        try store.resumeUserPausedJob(id: original.id, now: Date())
        await localClient.waitForIncrementalSmartInboxIdle()

        let organizers = try store.jobs(limit: 100).filter { $0.kind == .aiOperation }
        XCTAssertEqual(organizers.count, 2)
        XCTAssertTrue(organizers.allSatisfy { $0.state == .completed })
        XCTAssertNotNil(try store.smartInboxClassificationCache()[later.id])
    }

    func testProductionRecoveryPreservesPreparedSuccessorUntilLocalClientDrainsIt() async throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "production-recovery")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild]
        ))
        try await client.enqueueIncrementalSmartInbox(fixture.input)

        let recovery = try fixture.store.recoverBackgroundAgentJobs(allowedKinds: [.aiOperation])

        XCTAssertEqual(recovery.cancelledDuplicateCount, 0)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .paused)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).pauseReason, "smart-inbox-follow-up")
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        await client.waitForIncrementalSmartInboxIdle()
        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .completed)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .completed)
        XCTAssertNotNil(try fixture.store.smartInboxClassificationCache()[fixture.laterMessageID])
    }

    func testSmartInboxActivityPrefersUserPausedPredecessorOverBlockedFollowUp() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "activity-selection")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let activity = try XCTUnwrap(fixture.store.smartInboxActivityJob())

        XCTAssertEqual(activity.id, fixture.predecessor.id)
        XCTAssertEqual(activity.pauseReason, "user-requested")
    }

    func testTerminalFailurePromotesPreparedSuccessor() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "terminal-failure")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        let running = try XCTUnwrap(fixture.store.claimNextJob())

        try fixture.store.failJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            code: "PROVIDER_FAILED",
            message: "Provider failed",
            retryAt: nil
        )

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .failed)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .queued)
        XCTAssertEqual(
            try fixture.store.terminalSmartInboxSuccessor(after: fixture.predecessor.id),
            fixture.successor.id
        )
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testRetryableFailurePreservesPreparedSuccessorPair() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "retryable-failure")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        let running = try XCTUnwrap(fixture.store.claimNextJob())

        try fixture.store.failJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            code: "OFFLINE",
            message: "Retry later",
            retryAt: Date().addingTimeInterval(60)
        )

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .queued)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .paused)
        XCTAssertTrue(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
        XCTAssertNil(try fixture.store.terminalSmartInboxSuccessor(after: fixture.predecessor.id))
    }

    func testImmediateCancellationCancelsPreparedSuccessorPair() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "immediate-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try fixture.store.requestJobCancellation(id: fixture.predecessor.id)

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .cancelled)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
        XCTAssertNil(try fixture.store.terminalSmartInboxSuccessor(after: fixture.predecessor.id))
    }

    func testAcknowledgedCancellationCancelsPreparedSuccessorPair() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "acknowledged-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        let running = try XCTUnwrap(fixture.store.claimNextJob())
        try fixture.store.requestJobCancellation(id: running.id)

        try fixture.store.acknowledgeJobCancellation(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken)
        )

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .cancelled)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testExpiredCancellationRecoveryCancelsPreparedSuccessorPairAfterRestart() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "recovered-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let startedAt = Date(timeIntervalSince1970: 2_200_000_000)
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: startedAt)
        let running = try XCTUnwrap(
            fixture.store.claimNextJob(now: startedAt, leaseDuration: 10, allowedKinds: [.aiOperation])
        )
        try fixture.store.requestJobCancellation(id: running.id)
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()

        _ = try reopened.recoverBackgroundAgentJobs(
            allowedKinds: [.aiOperation],
            now: startedAt.addingTimeInterval(11)
        )

        XCTAssertEqual(try reopened.job(id: fixture.predecessor.id).state, .cancelled)
        XCTAssertEqual(try reopened.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testExpiredCancellationClaimCancelsPreparedSuccessorPair() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "claimed-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let startedAt = Date(timeIntervalSince1970: 2_300_000_000)
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: startedAt)
        let running = try XCTUnwrap(
            fixture.store.claimNextJob(now: startedAt, leaseDuration: 10, allowedKinds: [.aiOperation])
        )
        try fixture.store.requestJobCancellation(id: running.id)

        XCTAssertNil(
            try fixture.store.claimNextJob(
                now: startedAt.addingTimeInterval(11),
                leaseDuration: 10,
                allowedKinds: [.aiOperation]
            )
        )
        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .cancelled)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testPruningTerminalPairRemovesPromotedSuccessorMapping() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "pruning")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        let predecessor = try XCTUnwrap(fixture.store.claimNextJob())
        try fixture.store.completeJob(
            id: predecessor.id,
            leaseToken: try XCTUnwrap(predecessor.leaseToken),
            resultArtifactID: nil
        )
        let successor = try XCTUnwrap(fixture.store.claimNextJob())
        try fixture.store.completeJob(
            id: successor.id,
            leaseToken: try XCTUnwrap(successor.leaseToken),
            resultArtifactID: nil
        )

        try fixture.store.pruneTerminalJobs(before: Date().addingTimeInterval(1))

        XCTAssertNil(try fixture.store.terminalSmartInboxSuccessor(after: fixture.predecessor.id))
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testRuntimeSafeBoundaryCancellationCancelsReservedSuccessorPair() async throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "runtime-boundary-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let provider = BoundaryCancellingProvider(
            store: fixture.store,
            predecessorID: fixture.predecessor.id
        )
        let runtime = LocalOperationRuntime(
            store: fixture.store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())

        _ = try await runtime.processNextJob()

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .cancelled)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testDirectSuccessorCancellationDetachesPairAndPredecessorCanComplete() throws {
        let fixture = try makePreparedFollowUpFixture(suffix: "successor-cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try fixture.store.requestJobCancellation(id: fixture.successor.id)
        try fixture.store.resumeUserPausedJob(id: fixture.predecessor.id, now: Date())
        let running = try XCTUnwrap(fixture.store.claimNextJob())
        XCTAssertNoThrow(try fixture.store.completeJob(
            id: running.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            resultArtifactID: nil
        ))

        XCTAssertEqual(try fixture.store.job(id: fixture.predecessor.id).state, .completed)
        XCTAssertEqual(try fixture.store.job(id: fixture.successor.id).state, .cancelled)
        XCTAssertFalse(try hasPendingFollowUpDemand(at: fixture.url, predecessorID: fixture.predecessor.id))
    }

    func testExpiredSyncCancellationRecoveryFailsReadinessAndResumesSystemPausedOrganizer() throws {
        let fixture = try makeExpiredSyncCancellationFixture(suffix: "recovery")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        let notifications = QueuedOperationsNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notifications.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }

        let summary = try reopened.recoverBackgroundAgentJobs(
            allowedKinds: [.inboxSync, .historicalSync, .aiOperation],
            now: fixture.startedAt.addingTimeInterval(11)
        )

        XCTAssertEqual(summary.cancelledExpiredCount, 1)
        XCTAssertEqual(try reopened.job(id: fixture.syncID).state, .cancelled)
        XCTAssertEqual(try reopened.job(id: fixture.organizerID).state, .queued)
        XCTAssertEqual(try sqliteText(at: fixture.url, sql: "SELECT state FROM account_sync_readiness LIMIT 1"), "failed")
        XCTAssertEqual(notifications.scopes, [.operations])
    }

    func testExpiredSyncCancellationClaimFailsReadinessAndResumesSystemPausedOrganizer() throws {
        let fixture = try makeExpiredSyncCancellationFixture(suffix: "claim")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        let notifications = QueuedOperationsNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { notifications.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertNil(try reopened.claimNextJob(
            now: fixture.startedAt.addingTimeInterval(11),
            leaseDuration: 10,
            allowedKinds: [.inboxSync, .historicalSync]
        ))

        XCTAssertEqual(try reopened.job(id: fixture.syncID).state, .cancelled)
        XCTAssertEqual(try reopened.job(id: fixture.organizerID).state, .queued)
        XCTAssertEqual(try sqliteText(at: fixture.url, sql: "SELECT state FROM account_sync_readiness LIMIT 1"), "failed")
        XCTAssertEqual(notifications.scopes, [.operations])
    }

    func testUpToDateSmartInboxArtifactRetainsConcreteModelIdentity() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-up-to-date-model-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_up_to_date_model"),
                threadID: nil,
                from: EmailAddress("alice@example.com"),
                subject: "Concrete model",
                preview: "Persist it in every artifact",
                smartCategory: .unknown
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild]
        )
        let client = LocalOperationClient(runtime: runtime)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        ).resolvingSmartInboxClassifierIdentity()

        let first = try await client.executeAI(input)
        let second = try await client.executeAI(input)

        for result in [first, second] {
            let artifact = try store.durableOperationArtifact(id: result.artifactID)
            let payload = try JSONDecoder().decode(
                PlainpostLocalAIArtifactPayload.self,
                from: Data(artifact.payloadJSON.utf8)
            )
            XCTAssertEqual(payload.modelID, "deterministic-local")
        }
        XCTAssertEqual(second.jobID, "smart-inbox-up-to-date")
    }

    func testQueuedClientSignalsWorkerAndReadsCompletedAIArtifact() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-operation-client-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(
            MessageSummary(
                id: MessageID("msg_worker_test"),
                threadID: ThreadID("thr_worker_test"),
                from: EmailAddress("alice@example.com"),
                subject: "Worker isolation",
                preview: "Please summarize this in the worker.",
                smartCategory: .personal
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault()
        )
        let signal = RecordingWorkerSignal(runtime: runtime)
        let client = QueuedOperationClient(store: store, workerSignal: signal)

        let result = try await client.executeAI(
            PlainpostAIOperationInput(
                operation: .summarizeMessage,
                recordID: "msg_worker_test",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: "deterministic"
            )
        )

        let signalCount = await signal.signalCount
        XCTAssertEqual(signalCount, 1)
        XCTAssertEqual(try store.job(id: result.jobID).state, .completed)
        let artifact = try store.durableOperationArtifact(id: result.artifactID)
        let payload = try JSONDecoder().decode(
            PlainpostLocalAIArtifactPayload.self,
            from: Data(artifact.payloadJSON.utf8)
        )
        XCTAssertFalse(payload.text?.isEmpty ?? true)
    }
}

private extension PlainpostSmartInboxJobEnqueueResult {
    var job: PlainpostDurableJob? {
        guard case .job(let job) = self else { return nil }
        return job
    }
}

private struct PreparedFollowUpFixture {
    let url: URL
    let store: SQLiteMailStore
    let input: PlainpostAIOperationInput
    let predecessor: PlainpostDurableJob
    let successor: PlainpostDurableJob
    let laterMessageID: MessageID
}

private struct ExpiredSyncCancellationFixture {
    let url: URL
    let syncID: String
    let organizerID: String
    let startedAt: Date
}

private func makePreparedFollowUpFixture(suffix: String) throws -> PreparedFollowUpFixture {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-pair-\(suffix)-\(UUID().uuidString).sqlite")
    let store = try SQLiteMailStore(path: url.path)
    try store.migrate()
    let first = MessageSummary(
        id: MessageID("msg_pair_first_\(suffix)"),
        threadID: ThreadID("thr_pair_first_\(suffix)"),
        from: EmailAddress("first@example.com"),
        subject: "First",
        preview: "Prepared",
        smartCategory: .unknown
    )
    let later = MessageSummary(
        id: MessageID("msg_pair_later_\(suffix)"),
        threadID: ThreadID("thr_pair_later_\(suffix)"),
        from: EmailAddress("later@example.com"),
        subject: "Later",
        preview: "Follow up",
        smartCategory: .unknown
    )
    try store.cacheOwnedTestMessage(first)
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "deterministic"
    ).resolvingSmartInboxClassifierIdentity()
    let predecessor = try XCTUnwrap(try store.enqueueSmartInboxJob(input: input).job)
    let running = try XCTUnwrap(store.claimNextJob())
    let lease = try XCTUnwrap(running.leaseToken)
    let catalog = try XCTUnwrap(store.smartInboxLabelCatalogSnapshot(jobID: predecessor.id))
    let firstInput = try XCTUnwrap(store.smartInboxClassificationInputs(scope: .allAccounts).first)
    try store.prepareSmartInboxWork(
        jobID: predecessor.id,
        leaseToken: lease,
        seeds: [.init(
            ordinal: 0,
            messageID: first.id.rawValue,
            sourceFingerprint: SmartInboxClassificationFingerprint.message(
                firstInput,
                classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator
            )
        )],
        catalogSnapshot: catalog
    )
    try store.requestJobPause(id: predecessor.id)
    try store.acknowledgeJobPause(
        id: predecessor.id,
        leaseToken: lease,
        progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
    )
    try store.cacheOwnedTestMessage(later)
    _ = try store.enqueueSmartInboxJob(input: input)
    let successor = try XCTUnwrap(try store.jobs(limit: 100).first {
        $0.id != predecessor.id && $0.pauseReason == "smart-inbox-follow-up"
    })
    return PreparedFollowUpFixture(
        url: url,
        store: store,
        input: input,
        predecessor: predecessor,
        successor: successor,
        laterMessageID: later.id
    )
}

private func makeExpiredSyncCancellationFixture(suffix: String) throws -> ExpiredSyncCancellationFixture {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("expired-sync-cancellation-\(suffix)-\(UUID().uuidString).sqlite")
    let store = try SQLiteMailStore(path: url.path)
    try store.migrate()
    let account = Account(
        id: AccountID("account-expired-\(suffix)"),
        displayName: "Expired Sync",
        email: EmailAddress("expired-\(suffix)@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
    try store.cacheAccounts([account])
    let organizerInput = PlainpostAIOperationInput(
        operation: .recategorizeInbox,
        recordID: "",
        providerID: "deterministic"
    )
    let organizerPayload = String(decoding: try JSONEncoder().encode(organizerInput), as: UTF8.self)
    let organizer = try store.enqueueJob(.init(
        kind: .aiOperation,
        payloadJSON: organizerPayload,
        idempotencyKey: "expired-sync-organizer-\(suffix)"
    ))
    let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
    try store.pauseJob(
        id: organizer.id,
        leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
        reason: "mail-sync",
        progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
    )
    let sync = try enqueueInboxSyncJob(
        .init(accountID: account.id, trigger: .manual, scope: .incremental),
        store: store
    )
    let startedAt = Date(timeIntervalSince1970: 2_400_000_000)
    let runningSync = try XCTUnwrap(
        store.claimNextJob(now: startedAt, leaseDuration: 10, allowedKinds: [.inboxSync])
    )
    try store.requestJobCancellation(id: runningSync.id)
    return .init(url: url, syncID: sync.id, organizerID: organizer.id, startedAt: startedAt)
}

private func hasPendingFollowUpDemand(at url: URL, predecessorID: String) throws -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw PlainpostError.validationFailed("Could not open follow-up test database.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT EXISTS(SELECT 1 FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?)",
        -1,
        &statement,
        nil
    ) == SQLITE_OK else {
        throw PlainpostError.validationFailed("Could not prepare follow-up test query.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, predecessorID, -1, transient)
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PlainpostError.validationFailed("Could not read follow-up test query.")
    }
    return sqlite3_column_int(statement, 0) == 1
}

private func sqliteText(at url: URL, sql: String) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw PlainpostError.validationFailed("Could not open SQLite test database.")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw PlainpostError.validationFailed("Could not prepare SQLite test query.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
}

private final class BoundaryCancellingProvider: AIProvider, @unchecked Sendable {
    let id = "boundary-cancelling"
    let displayName = "Boundary Cancelling"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let store: SQLiteMailStore
    private let predecessorID: String
    private let lock = NSLock()
    private var didRequestCancellation = false

    init(store: SQLiteMailStore, predecessorID: String) {
        self.store = store
        self.predecessorID = predecessorID
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        .init(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        let shouldCancel = lock.withLock {
            guard !didRequestCancellation else { return false }
            didRequestCancellation = true
            return true
        }
        if shouldCancel {
            try store.requestJobCancellation(id: predecessorID)
        }
        return .init(category: .newsletter, confidence: 0.9, reason: "Boundary cancellation")
    }
}

private final class QueuedOperationsNotificationRecorder: @unchecked Sendable {
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

private actor RecordingWorkerSignal: OperationWorkerSignaling {
    private let runtime: LocalOperationRuntime
    private(set) var signalCount = 0

    init(runtime: LocalOperationRuntime) {
        self.runtime = runtime
    }

    func signalWork() async throws {
        signalCount += 1
        let runtime = self.runtime
        Task.detached {
            _ = try? await runtime.processNextJob()
        }
    }
}
