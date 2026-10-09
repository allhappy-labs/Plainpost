import Foundation
import SQLite3
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport

final class InteractiveAIPreemptionTests: XCTestCase {
    func testMessageTranslationCancelsInFlightClassificationThenOrganizerRetriesIt() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("immediate-translation-preemption-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "Erste"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Zweite"))

        let provider = CancellableClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        let organizer = try store.enqueueJob(
            Self.jobRequest(input: organizerInput, idempotencyKey: "immediate-organizer")
        )
        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        let translationInput = PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: "msg_1",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: provider.id,
            targetLanguageIdentifier: "en",
            targetLanguageName: "English"
        )
        let translation = try store.enqueueJob(
            Self.jobRequest(input: translationInput, idempotencyKey: "immediate-translation")
        )

        let paused = try await Self.value(of: firstPass, within: .seconds(2))
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "message-translation")
        XCTAssertEqual(paused?.progress?.current, 0)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)

        let completedTranslation = try await runtime.processNextJob()
        let completedOrganizer = try await runtime.processNextJob()
        let events = await provider.events()
        XCTAssertEqual(completedTranslation?.id, translation.id)
        XCTAssertEqual(completedOrganizer?.id, organizer.id)
        XCTAssertEqual(events, [
            "classify:msg_1",
            "cancel:msg_1",
            "translate",
            "classify:msg_1",
            "classify:msg_2",
        ])
    }

    func testCancellingActiveRerunRecordsCanonicalCompletionAudit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rerun-cancellation-audit-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheThread(MailThread(
            id: ThreadID("thr_shared"),
            accountID: PlainpostFixtures.personalAccount.id,
            subjectNormalized: "shared thread",
            participantEmails: [PlainpostFixtures.personalAccount.email, EmailAddress("alice@example.com")]
        ))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellableClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id,
            smartInboxRunMode: .rerunAll,
            smartInboxRequestID: "rerun-cancellation-audit"
        )
        let organizer = try store.enqueueJob(
            Self.jobRequest(input: input, idempotencyKey: "rerun-cancellation-audit")
        )

        let running = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        try store.requestJobCancellation(id: organizer.id)

        let cancelled = try await Self.value(of: running, within: .seconds(2))
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).categorized, 0)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)
        let audit = try XCTUnwrap(
            store.recentAuditEntries(limit: 20).first {
                $0.action == "smart_inbox.reclassification.complete" && $0.targetID == organizer.id
            }
        )
        XCTAssertEqual(
            audit.result,
            """
            {"errorClass":"cancelled","failed":0,"jobID":"\(organizer.id)","modelID":"\(provider.id)","providerID":"\(provider.id)","scope":"allAccounts","status":"cancelled","unchanged":0,"updated":0}
            """
        )
    }

    func testInteractiveEnqueueDiscardsConcurrentProviderFailureThenRunsFirst() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-failure-preemption-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = ConcurrentFailureClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: provider.id),
            idempotencyKey: "provider-failure-organizer"
        ))

        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilClassificationStarts()
        let translation = try store.enqueueJob(Self.jobRequest(
            input: .init(
                operation: .translateMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id,
                targetLanguageIdentifier: "en",
                targetLanguageName: "English"
            ),
            idempotencyKey: "provider-failure-translation"
        ))
        await provider.releaseFailure()

        let paused = try await Self.value(of: firstPass, within: .seconds(2))
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "message-translation")
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
        let completedTranslation = try await runtime.processNextJob()
        let completedOrganizer = try await runtime.processNextJob()
        XCTAssertEqual(completedTranslation?.id, translation.id)
        XCTAssertEqual(completedOrganizer?.id, organizer.id)
    }

    func testExternalCancellationDuringClassificationPropagatesWithoutFailingJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-cancellation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellationHoldingClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: provider.id),
            idempotencyKey: "external-cancellation-organizer"
        ))

        let running = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        running.cancel()
        await provider.waitUntilCancellationStarts()
        await provider.releaseCancellation()

        do {
            _ = try await Self.value(of: running, within: .seconds(2))
            XCTFail("Expected external cancellation to propagate")
        } catch is CancellationError {
        }
        let job = try store.job(id: organizer.id)
        XCTAssertNotEqual(job.state, .failed)
        XCTAssertEqual(job.attempt, 1)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
    }

    func testAutomaticPreemptionPublishesPausingUntilProviderCancellationDrains() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("automatic-pausing-progress-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellationHoldingClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: provider.id),
            idempotencyKey: "automatic-pausing-organizer"
        ))

        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        _ = try store.enqueueJob(Self.jobRequest(
            input: .init(
                operation: .translateMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id,
                targetLanguageIdentifier: "en",
                targetLanguageName: "English"
            ),
            idempotencyKey: "automatic-pausing-translation"
        ))
        await provider.waitUntilCancellationStarts()

        let draining = try store.job(id: organizer.id)
        XCTAssertEqual(draining.state, .running)
        XCTAssertFalse(draining.pauseRequested)
        XCTAssertEqual(draining.progress?.phase, "pausing")
        await provider.releaseCancellation()

        let paused = try await Self.value(of: firstPass, within: .seconds(2))
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertFalse(paused?.pauseRequested ?? true)
        XCTAssertEqual(paused?.pauseReason, "message-translation")
        XCTAssertEqual(paused?.progress?.phase, "paused")
    }

    func testExternalCancellationDuringAutomaticPreemptionDrainPropagatesWithoutSchedulerPauseOrFailure() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-cancellation-preemption-drain-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellationHoldingClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: provider.id),
            idempotencyKey: "external-cancellation-preemption-drain-organizer"
        ))

        let running = Task { try await runtime.processNextJob() }
        try await Self.waitUntil(within: .seconds(2)) {
            await provider.hasFirstClassificationStarted()
        }
        let beforeCancellation = try store.job(id: organizer.id)
        let retainedLease = try XCTUnwrap(beforeCancellation.leaseToken)
        _ = try store.enqueueJob(Self.jobRequest(
            input: .init(
                operation: .translateMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id,
                targetLanguageIdentifier: "en",
                targetLanguageName: "English"
            ),
            idempotencyKey: "external-cancellation-preemption-drain-translation"
        ))
        try await Self.waitUntil(within: .seconds(2)) {
            await provider.hasCancellationStarted()
        }
        running.cancel()
        await provider.releaseCancellation()

        do {
            _ = try await Self.value(of: running, within: .seconds(2))
            XCTFail("Expected external cancellation to propagate instead of a scheduler pause")
        } catch is CancellationError {
        }
        let job = try store.job(id: organizer.id)
        XCTAssertEqual(job.state, .running)
        XCTAssertEqual(job.leaseToken, retainedLease)
        XCTAssertEqual(job.attempt, beforeCancellation.attempt)
        XCTAssertEqual(job.availableAt, beforeCancellation.availableAt)
        XCTAssertNil(job.errorCode)
        XCTAssertNil(job.errorMessage)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
    }

    func testExternalCancellationWinsConcurrentProviderFailureWithoutFailingJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-cancellation-provider-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = ConcurrentFailureClassificationProvider()
        let failureSelected = HeldProviderFailureSelectionHook()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider },
            afterSmartInboxProviderFailureSelected: {
                await failureSelected.enterAndWait()
            }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: provider.id),
            idempotencyKey: "external-cancellation-provider-failure-organizer"
        ))

        let running = Task { try await runtime.processNextJob() }
        try await Self.waitUntil(within: .seconds(2)) {
            await provider.hasClassificationStarted()
        }
        let beforeCancellation = try store.job(id: organizer.id)
        let retainedLease = try XCTUnwrap(beforeCancellation.leaseToken)
        await provider.releaseFailure()
        try await Self.waitUntil(within: .seconds(2)) {
            await failureSelected.hasEntered()
        }
        let failureSelectionCount = await failureSelected.entryCount
        XCTAssertEqual(failureSelectionCount, 1)
        running.cancel()
        await failureSelected.release()

        do {
            _ = try await Self.value(of: running, within: .seconds(2))
            XCTFail("Expected external cancellation to win the concurrent provider failure")
        } catch is CancellationError {
        }
        let job = try store.job(id: organizer.id)
        XCTAssertEqual(job.state, .running)
        XCTAssertEqual(job.leaseToken, retainedLease)
        XCTAssertEqual(job.attempt, beforeCancellation.attempt)
        XCTAssertEqual(job.availableAt, beforeCancellation.availableAt)
        XCTAssertNil(job.errorCode)
        XCTAssertNil(job.errorMessage)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
    }

    func testEveryUserTriggeredAIOperationOutranksSmartInbox() {
        let operations: [PlainpostAIOperationKind] = [
            .summarizeThread,
            .summarizeMessage,
            .translateMessage,
            .answerThreadQuestion,
            .answerMailboxQuestion,
            .draftReply,
            .rewriteDraft,
            .classifyMessage,
        ]
        for operation in operations {
            XCTAssertGreaterThan(operation.priority, PlainpostAIOperationKind.recategorizeInbox.priority)
            XCTAssertFalse(operation.schedulerPauseReason.isEmpty)
        }
    }

    func testOrganizerResumesAfterAllQueuedInteractiveWorkDrains() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-queue-drain-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Second"))
        let provider = CancellableClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: provider.id
            ),
            idempotencyKey: "drain-organizer"
        ))
        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        let summary = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .summarizeMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id
            ),
            idempotencyKey: "drain-summary"
        ))
        let translation = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .translateMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id,
                targetLanguageIdentifier: "en",
                targetLanguageName: "English"
            ),
            idempotencyKey: "drain-translation"
        ))

        _ = try await Self.value(of: firstPass, within: .seconds(2))
        let firstInteractiveJob = try await runtime.processNextJob()
        let secondInteractiveJob = try await runtime.processNextJob()
        let resumedOrganizerJob = try await runtime.processNextJob()
        let firstInteractive = try XCTUnwrap(firstInteractiveJob)
        let secondInteractive = try XCTUnwrap(secondInteractiveJob)
        let resumedOrganizer = try XCTUnwrap(resumedOrganizerJob)
        XCTAssertEqual(Set([firstInteractive.id, secondInteractive.id]), Set([summary.id, translation.id]))
        XCTAssertEqual(resumedOrganizer.id, organizer.id)
    }

    func testWatcherIgnoresFutureTerminalAndEqualPriorityJobs() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preemption-filter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let terminal = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            priority: 100,
            idempotencyKey: "terminal-interactive"
        ))
        let claimedTerminal = try XCTUnwrap(
            store.claimNextJob(now: now, leaseDuration: 30, allowedKinds: [.aiOperation, .searchRebuild])
        )
        try store.completeJob(
            id: terminal.id,
            leaseToken: try XCTUnwrap(claimedTerminal.leaseToken),
            resultArtifactID: nil
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "deterministic"
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: organizerInput,
            idempotencyKey: "predicate-organizer"
        ))
        _ = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            priority: 100,
            idempotencyKey: "future-interactive",
            availableAt: now.addingTimeInterval(60)
        ))
        _ = try store.enqueueJob(PlainpostJobRequest(
            kind: .searchRebuild,
            payloadJSON: plainpostTestSearchRebuildPayloadJSON,
            priority: PlainpostAIServiceClass.bulk.priority,
            idempotencyKey: "equal-priority-rebuild"
        ))
        let claimedOrganizer = try XCTUnwrap(
            store.claimNextJob(now: now, allowedKinds: [.aiOperation, .searchRebuild])
        )
        let watcher = SmartInboxPreemptionWatcher(
            store: store,
            jobID: organizer.id,
            leaseToken: try XCTUnwrap(claimedOrganizer.leaseToken),
            priority: organizer.priority,
            allowedKinds: [.aiOperation, .searchRebuild],
            pollInterval: .milliseconds(25)
        )

        XCTAssertNil(try watcher.directive(now: now))
    }

    func testInFlightWatcherDoesNotPreemptForMailReadiness() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preemption-readiness-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try Self.completeSuccessfulSync(in: store, key: "preemption-ready-sync")
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic"
            ),
            idempotencyKey: "readiness-organizer"
        ))
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])
        )
        _ = try store.enqueueJob(try Self.syncRequest(key: "readiness-active-sync"))
        let watcher = SmartInboxPreemptionWatcher(
            store: store,
            jobID: organizer.id,
            leaseToken: try XCTUnwrap(claimed.leaseToken),
            priority: organizer.priority,
            allowedKinds: [.aiOperation, .searchRebuild],
            pollInterval: .milliseconds(25)
        )

        XCTAssertNil(try watcher.directive())
    }

    func testInFlightWatcherReportsLeaseLoss() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preemption-lease-loss-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "deterministic"
            ),
            idempotencyKey: "lease-loss-organizer"
        ))
        let claimed = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])
        )
        let leaseToken = try XCTUnwrap(claimed.leaseToken)
        try store.pauseJob(
            id: organizer.id,
            leaseToken: leaseToken,
            reason: "test-lease-loss",
            progress: .init(current: 0, total: 0, phase: "paused", label: "Smart Inbox")
        )
        let watcher = SmartInboxPreemptionWatcher(
            store: store,
            jobID: organizer.id,
            leaseToken: leaseToken,
            priority: organizer.priority,
            allowedKinds: [.aiOperation, .searchRebuild],
            pollInterval: .milliseconds(25)
        )

        XCTAssertEqual(try watcher.directive(), .leaseLost)
    }

    func testDisappearedInteractiveTriggerRetriesTheInterruptedClassification() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preemption-disappeared-trigger-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellationHoldingClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: provider.id
            ),
            idempotencyKey: "disappeared-trigger-organizer"
        ))
        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        let interactive = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .translateMessage,
                recordID: "msg_1",
                accountID: PlainpostFixtures.personalAccount.id,
                providerID: provider.id,
                targetLanguageIdentifier: "en",
                targetLanguageName: "English"
            ),
            idempotencyKey: "disappeared-trigger-interactive"
        ))
        await provider.waitUntilCancellationStarts()
        try store.requestJobCancellation(id: interactive.id)
        await provider.releaseCancellation()

        let completed = try await Self.value(of: firstPass, within: .seconds(2))
        let events = await provider.events()
        XCTAssertEqual(completed?.id, organizer.id)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(events, [
            "classify:msg_1",
            "cancel:msg_1",
            "classify:msg_1",
        ])
    }

    func testManualPauseCancelsInFlightClassificationImmediately() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preemption-manual-pause-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        let provider = CancellableClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: provider.id
            ),
            idempotencyKey: "manual-pause-organizer"
        ))
        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        try store.requestJobPause(id: organizer.id)

        let paused = try await Self.value(of: firstPass, within: .seconds(2))
        let events = await provider.events()
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "user-requested")
        XCTAssertEqual(paused?.progress?.current, 0)
        XCTAssertEqual(events, ["classify:msg_1", "cancel:msg_1"])
    }

    func testSummaryPreemptionDiscardsResponseWhenBoundaryWins() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-ai-preemption-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheThread(MailThread(
            id: ThreadID("thr_shared"),
            accountID: PlainpostFixtures.personalAccount.id,
            subjectNormalized: "shared thread",
            participantEmails: [PlainpostFixtures.personalAccount.email, EmailAddress("alice@example.com")]
        ))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Second"))

        let provider = ControlledAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        let organizer = try store.enqueueJob(
            Self.jobRequest(input: organizerInput, idempotencyKey: "organizer")
        )

        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        let summaryInput = PlainpostAIOperationInput(
            operation: .summarizeThread,
            recordID: "thr_shared",
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: provider.id
        )
        let summary = try store.enqueueJob(Self.jobRequest(input: summaryInput, idempotencyKey: "summary"))
        await provider.releaseFirstClassification()

        let paused = try await firstPass.value
        XCTAssertEqual(paused?.id, organizer.id)
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.progress?.current, 0)
        XCTAssertEqual(paused?.pauseReason, "thread-summary")
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
        XCTAssertEqual(try store.messageSummary(id: MessageID("msg_1"))?.smartCategory, .unknown)
        let auditContents = try String(contentsOf: store.auditLogURL, encoding: .utf8)
        XCTAssertFalse(auditContents.contains("\"action\":\"smart_inbox.reconcile\""))

        let completedSummary = try await runtime.processNextJob()
        XCTAssertEqual(completedSummary?.id, summary.id)
        XCTAssertEqual(completedSummary?.state, .completed)

        let completedOrganizer = try await runtime.processNextJob()
        XCTAssertEqual(completedOrganizer?.id, organizer.id)
        XCTAssertEqual(completedOrganizer?.state, .completed)
        XCTAssertEqual(completedOrganizer?.progress?.current, 2)
        let events = await provider.events()
        XCTAssertEqual(events, ["classify:msg_1", "generate", "classify:msg_1", "classify:msg_2"])
        XCTAssertEqual(try store.messageSummary(id: MessageID("msg_1"))?.smartCategory, .newsletter)
        XCTAssertEqual(try store.messageSummary(id: MessageID("msg_2"))?.smartCategory, .newsletter)
        let completedAuditContents = try String(contentsOf: store.auditLogURL, encoding: .utf8)
        XCTAssertTrue(completedAuditContents.contains("\"action\":\"smart_inbox.reconcile\""))
        XCTAssertTrue(completedAuditContents.contains("\"targetID\":\"msg_1\""))
    }

    func testDraftReplyPreemptionDiscardsResponseWhenBoundaryWins() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-draft-preemption-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("acc_shared"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1",
            smtpHost: "127.0.0.1"
        )
        try store.cacheAccounts([account])
        try Self.completeSuccessfulSync(in: store, key: "draft-initial-sync", accountID: account.id)
        try store.cacheThread(
            MailThread(
                id: ThreadID("thr_shared"),
                accountID: account.id,
                subjectNormalized: "shared thread",
                participantEmails: [account.email, EmailAddress("alice@example.com")]
            )
        )
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"), account: account)
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Second"), account: account)

        let provider = ControlledAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        let organizer = try store.enqueueJob(Self.jobRequest(input: organizerInput, idempotencyKey: "draft-organizer"))

        let firstPass = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        let draftInput = PlainpostAIOperationInput(
            operation: .draftReply,
            recordID: "thr_shared",
            conversationReferenceKind: .thread,
            accountID: account.id,
            providerID: provider.id
        )
        let draft = try store.enqueueJob(Self.jobRequest(input: draftInput, idempotencyKey: "draft"))
        await provider.releaseFirstClassification()

        let paused = try await firstPass.value
        XCTAssertEqual(paused?.id, organizer.id)
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "ai-draft")

        let completedDraft = try await runtime.processNextJob()
        XCTAssertEqual(completedDraft?.id, draft.id)
        XCTAssertEqual(completedDraft?.state, .completed)
        let completedOrganizer = try await runtime.processNextJob()
        XCTAssertEqual(completedOrganizer?.id, organizer.id)
        XCTAssertEqual(completedOrganizer?.state, .completed)
        let events = await provider.events()
        XCTAssertEqual(events, ["classify:msg_1", "generate", "classify:msg_1", "classify:msg_2"])
    }

    func testChangedSnapshotItemsCompleteAsSkippedInsteadOfProviderFailure() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-skip-stale-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "Original first"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Original second"))
        let provider = ControlledAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        let organizer = try store.enqueueJob(Self.jobRequest(input: input, idempotencyKey: "skip-stale"))

        let work = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "Changed first"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Changed second"))
        await provider.releaseFirstClassification()

        let completed = try await work.value
        XCTAssertEqual(completed?.id, organizer.id)
        XCTAssertEqual(completed?.state, .completed)
        let events = await provider.events()
        XCTAssertEqual(events, ["classify:msg_1", "classify:msg_2"])
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).categorized, 0)
        XCTAssertEqual(try store.smartInboxWorkSummary(jobID: organizer.id).failed, 0)
    }

    func testOrganizerClaimsWhenNoSyncIsActiveDespiteIncompleteReadiness() async throws {
        let context = try SmartInboxRuntimeContext(messages: [
            Self.message(id: "msg_1", preview: "First")
        ])
        try context.store.cacheAccounts([PlainpostFixtures.personalAccount])
        let organizer = try context.enqueue(mode: .incremental, providerID: "provider-a")

        let completed = try await context.runtime.processNextJob()

        let events = await context.provider.events()
        XCTAssertEqual(completed?.id, organizer.id)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(events, ["classify:msg_1"])
    }

    func testOrganizerDiscardsResponseWhenMailReadinessChangesMidRun() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-sync-pause-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Second"))
        try Self.completeSuccessfulSync(in: store, key: "initial-sync")
        let provider = ControlledAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        let organizer = try store.enqueueJob(Self.jobRequest(input: input, idempotencyKey: "sync-pause"))

        let work = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        _ = try store.enqueueJob(try Self.syncRequest(key: "mid-run-sync"))
        await provider.releaseFirstClassification()

        let paused = try await work.value
        XCTAssertEqual(paused?.id, organizer.id)
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "mail-sync")
        XCTAssertEqual(paused?.progress?.current, 0)
        XCTAssertEqual(
            try Self.smartInboxWorkState(databaseURL: databaseURL, jobID: organizer.id, ordinal: 0),
            "pending"
        )
    }

    func testActiveSyncPrecedesTerminalFailedReadinessAtBoundary() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-failed-sync-precedence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let secondAccount = Account(
            id: AccountID("acc_second"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([PlainpostFixtures.personalAccount, secondAccount])
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "First"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Second"))
        try Self.completeSuccessfulSync(in: store, key: "personal-initial-sync")
        try Self.completeSuccessfulSync(
            in: store,
            key: "second-initial-sync",
            accountID: secondAccount.id
        )
        let provider = ControlledAIProvider()
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: provider.id
        )
        _ = try store.enqueueJob(Self.jobRequest(input: input, idempotencyKey: "failed-sync-pause"))

        let work = Task { try await runtime.processNextJob() }
        await provider.waitUntilFirstClassificationStarts()
        _ = try store.enqueueJob(try Self.syncRequest(key: "personal-failed-sync"))
        let failedSync = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        try store.failJob(
            id: failedSync.id,
            leaseToken: try XCTUnwrap(failedSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )
        _ = try store.enqueueJob(
            try Self.syncRequest(key: "second-active-sync", accountID: secondAccount.id)
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
        await provider.releaseFirstClassification()

        let paused = try await work.value
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.pauseReason, "mail-sync")
    }

    func testTerminalFailedSyncRequeuesCheckpointedOrganizerWhenNoSyncRemains() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-terminal-failure-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try Self.completeSuccessfulSync(in: store, key: "terminal-failure-initial-sync")
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "terminal-failure-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync",
            progress: .init(current: 149, total: 191, phase: "paused", label: "Smart Inbox")
        )
        let pausedBeforeFailure = try store.job(id: organizer.id)
        let sync = try store.enqueueJob(try Self.syncRequest(key: "terminal-failure-sync"))
        let runningSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.failJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(runningSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)
        let resumed = try store.job(id: organizer.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        XCTAssertEqual(resumed.progress?.current, 149)
        XCTAssertEqual(resumed.progress?.total, 191)
        XCTAssertEqual(resumed.attempt, max(0, pausedBeforeFailure.attempt - 1))
        XCTAssertEqual(try store.claimNextJob(allowedKinds: [.aiOperation])?.id, organizer.id)
    }

    func testTerminalFailureContinuesRemainingPreparedSmartInboxWork() async throws {
        let messages = (0..<191).map { index in
            Self.message(id: "msg_\(index)", preview: "Message \(index)")
        }
        let context = try SmartInboxRuntimeContext(messages: messages)
        try context.store.cacheAccounts([PlainpostFixtures.personalAccount])
        try context.completeSuccessfulSync(key: "checkpoint-initial-sync")
        let organizer = try context.enqueue(mode: .incremental, providerID: context.provider.id)
        let runningOrganizer = try XCTUnwrap(
            context.store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])
        )
        let organizerLease = try XCTUnwrap(runningOrganizer.leaseToken)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: context.provider.id
        ).resolvingSmartInboxClassifierIdentity()
        let classifierDiscriminator = input.resolvedSmartInboxClassifierIdentity.discriminator
        let classificationInputs = try context.store.smartInboxClassificationInputs(scope: .allAccounts)
            .sorted { $0.message.id.rawValue < $1.message.id.rawValue }
        try context.store.prepareSmartInboxWork(
            jobID: organizer.id,
            leaseToken: organizerLease,
            seeds: classificationInputs.enumerated().map { ordinal, classificationInput in
                .init(
                    ordinal: ordinal,
                    messageID: classificationInput.message.id.rawValue,
                    sourceFingerprint: SmartInboxClassificationFingerprint.message(
                        classificationInput,
                        classifierDiscriminator: classifierDiscriminator
                    )
                )
            }
        )
        for ordinal in 0..<149 {
            let classificationInput = classificationInputs[ordinal]
            _ = try context.store.recordSmartInboxClassification(
                jobID: organizer.id,
                leaseToken: organizerLease,
                ordinal: ordinal,
                classification: .init(
                    messageID: classificationInput.message.id,
                    category: .newsletter,
                    priority: .high,
                    requiresAction: true,
                    confidence: 0.9
                ),
                providerID: context.provider.id,
                modelID: input.resolvedSmartInboxClassifierIdentity.modelID,
                classifierDiscriminator: classifierDiscriminator,
                actor: PlainpostFixtures.guiUser
            )
        }
        _ = try context.store.applySmartInboxWork(
            jobID: organizer.id,
            leaseToken: organizerLease,
            actor: PlainpostFixtures.guiUser
        )
        let completedCache = try context.store.smartInboxClassificationCache()
        XCTAssertEqual(completedCache.count, 149)

        let before = try context.store.job(id: organizer.id)
        XCTAssertEqual(before.progress?.current, 149)
        XCTAssertEqual(before.progress?.total, 191)
        try context.store.pauseJob(
            id: organizer.id,
            leaseToken: organizerLease,
            reason: "mail-sync",
            progress: try XCTUnwrap(before.progress)
        )
        let sync = try context.store.enqueueJob(try Self.syncRequest(key: "checkpoint-terminal-failure"))
        let runningSync = try XCTUnwrap(
            context.store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        try context.store.failJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(runningSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        _ = try await context.runtime.processNextJob()

        let classificationCallCount = await context.provider.classificationCallCount()
        XCTAssertEqual(classificationCallCount, 42)
        let completed = try context.store.job(id: organizer.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.progress?.current, 191)
        XCTAssertEqual(completed.progress?.total, 191)
        let finalCache = try context.store.smartInboxClassificationCache()
        XCTAssertEqual(finalCache.count, 191)
        for ordinal in 0..<149 {
            let messageID = classificationInputs[ordinal].message.id
            XCTAssertEqual(finalCache[messageID], completedCache[messageID])
        }
    }

    func testTerminalFailedSyncDoesNotReleaseOrganizerWhileAnotherSyncIsActive() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-active-sync-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let firstAccount = PlainpostFixtures.personalAccount
        let secondAccount = Account(
            id: AccountID("acc_active_sync"),
            displayName: "Active Sync",
            email: EmailAddress("active-sync@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([firstAccount, secondAccount])
        try Self.completeSuccessfulSync(in: store, key: "active-sync-first-initial", accountID: firstAccount.id)
        try Self.completeSuccessfulSync(in: store, key: "active-sync-second-initial", accountID: secondAccount.id)
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "active-sync-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync",
            progress: .init(current: 149, total: 191, phase: "paused", label: "Smart Inbox")
        )
        let failedSync = try store.enqueueJob(
            try Self.syncRequest(key: "active-sync-terminal-failure", accountID: firstAccount.id)
        )
        let runningFailedSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        let activeSync = try store.enqueueJob(
            try Self.syncRequest(key: "active-sync-running", accountID: secondAccount.id)
        )
        let runningActiveSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.failJob(
            id: failedSync.id,
            leaseToken: try XCTUnwrap(runningFailedSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        let paused = try store.job(id: organizer.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.pauseReason, "mail-sync")
        XCTAssertEqual(try store.smartInboxReadiness(), .waitingForSuccessfulSync)

        try store.completeJob(
            id: activeSync.id,
            leaseToken: try XCTUnwrap(runningActiveSync.leaseToken),
            resultArtifactID: nil
        )

        XCTAssertEqual(try store.job(id: organizer.id).state, .queued)
    }

    func testCancellationRequestedRunningSyncBlocksOrganizerUntilAcknowledged() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-cancelling-sync-barrier-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let firstAccount = PlainpostFixtures.personalAccount
        let secondAccount = Account(
            id: AccountID("acc_cancelling_sync"),
            displayName: "Cancelling Sync",
            email: EmailAddress("cancelling-sync@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([firstAccount, secondAccount])
        try Self.completeSuccessfulSync(in: store, key: "cancelling-first-initial", accountID: firstAccount.id)
        try Self.completeSuccessfulSync(in: store, key: "cancelling-second-initial", accountID: secondAccount.id)
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "cancelling-sync-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync",
            progress: .init(current: 149, total: 191, phase: "paused", label: "Smart Inbox")
        )
        let terminalSync = try store.enqueueJob(
            try Self.syncRequest(key: "cancelling-terminal-failure", accountID: firstAccount.id)
        )
        let runningTerminalSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        let cancellingSync = try store.enqueueJob(
            try Self.syncRequest(key: "cancelling-running", accountID: secondAccount.id)
        )
        let runningCancellingSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.requestJobCancellation(id: cancellingSync.id)
        try store.failJob(
            id: terminalSync.id,
            leaseToken: try XCTUnwrap(runningTerminalSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        XCTAssertEqual(try store.job(id: organizer.id).state, .paused)
        try store.acknowledgeJobCancellation(
            id: cancellingSync.id,
            leaseToken: try XCTUnwrap(runningCancellingSync.leaseToken)
        )
        XCTAssertEqual(try store.job(id: organizer.id).state, .queued)
    }

    func testRetryableSyncFailureKeepsPausedOrganizerUnclaimable() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-retryable-sync-barrier-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try Self.completeSuccessfulSync(in: store, key: "retryable-sync-initial")
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "retryable-sync-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync",
            progress: .init(current: 149, total: 191, phase: "paused", label: "Smart Inbox")
        )
        let paused = try store.job(id: organizer.id)
        let sync = try store.enqueueJob(try Self.syncRequest(key: "retryable-sync"))
        let runningSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.failJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(runningSync.leaseToken),
            code: "TEMPORARY",
            message: "retry later",
            retryAt: Date().addingTimeInterval(60)
        )

        XCTAssertEqual(try store.job(id: sync.id).state, .queued)
        let stillPaused = try store.job(id: organizer.id)
        XCTAssertEqual(stillPaused.state, .paused)
        XCTAssertEqual(stillPaused.pauseReason, "mail-sync")
        XCTAssertEqual(stillPaused.progress, paused.progress)
        XCTAssertEqual(stillPaused.attempt, paused.attempt)
        XCTAssertNil(try store.claimNextJob(allowedKinds: [.aiOperation]))
    }

    func testSuccessfulSyncAutomaticallyResumesMailSyncFailedOrganizer() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-sync-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        try store.cacheOwnedTestMessage(Self.message(id: "msg_unrelated", preview: "Unrelated"))
        try Self.completeSuccessfulSync(in: store, key: "sync-recovery-initial", accountID: account.id)
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "sync-recovery-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync-failed",
            progress: .init(current: 3, total: 7, phase: "paused", label: "Smart Inbox")
        )
        let pausedBeforeRecovery = try store.job(id: organizer.id)
        XCTAssertEqual(pausedBeforeRecovery.pauseReason, "mail-sync-failed")
        let attemptBeforeRecovery = pausedBeforeRecovery.attempt
        let unrelatedInput = PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: "msg_unrelated",
            accountID: account.id,
            providerID: "deterministic",
            targetLanguageIdentifier: "en",
            targetLanguageName: "English"
        )
        let unrelatedAvailableAt = Date().addingTimeInterval(60)
        let unrelated = try store.enqueueJob(PlainpostJobRequest(
            kind: .aiOperation,
            payloadJSON: String(
                decoding: try JSONEncoder().encode(unrelatedInput),
                as: UTF8.self
            ),
            priority: unrelatedInput.operation.priority,
            idempotencyKey: "sync-recovery-unrelated",
            availableAt: unrelatedAvailableAt
        ))
        let runningUnrelated = try XCTUnwrap(
            store.claimNextJob(now: unrelatedAvailableAt, allowedKinds: [.aiOperation])
        )
        try store.pauseJob(
            id: unrelated.id,
            leaseToken: try XCTUnwrap(runningUnrelated.leaseToken),
            reason: "mail-sync-failed",
            progress: .init(current: 0, total: 1, phase: "paused", label: "Translation")
        )

        let recovery = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .manual, scope: .recent)
        )
        let runningRecovery = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.completeJob(
            id: recovery.id,
            leaseToken: try XCTUnwrap(runningRecovery.leaseToken),
            resultArtifactID: nil
        )

        let resumed = try store.job(id: organizer.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        XCTAssertEqual(resumed.attempt, max(0, attemptBeforeRecovery - 1))
        XCTAssertEqual(resumed.progress?.current, pausedBeforeRecovery.progress?.current)
        XCTAssertEqual(try store.job(id: unrelated.id).state, .paused)
        XCTAssertEqual(try store.claimNextJob(allowedKinds: [.aiOperation])?.id, organizer.id)
    }

    func testTerminalFailedAccountReadinessDoesNotBlockOrganizer() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-multi-account-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let firstAccount = PlainpostFixtures.personalAccount
        let secondAccount = Account(
            id: AccountID("acc_blocked"),
            displayName: "Blocked",
            email: EmailAddress("blocked@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([firstAccount, secondAccount])
        try Self.completeSuccessfulSync(in: store, key: "multi-first-initial", accountID: firstAccount.id)
        try Self.completeSuccessfulSync(in: store, key: "multi-second-initial", accountID: secondAccount.id)
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: .init(operation: .recategorizeInbox, recordID: "", providerID: "deterministic"),
            idempotencyKey: "multi-account-organizer"
        ))
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync-failed",
            progress: .init(current: 4, total: 9, phase: "paused", label: "Smart Inbox")
        )
        let failedSync = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: secondAccount.id, trigger: .manual, scope: .recent)
        )
        let runningFailedSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.failJob(
            id: failedSync.id,
            leaseToken: try XCTUnwrap(runningFailedSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        let recovery = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: firstAccount.id, trigger: .manual, scope: .recent)
        )
        let runningRecovery = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.completeJob(
            id: recovery.id,
            leaseToken: try XCTUnwrap(runningRecovery.leaseToken),
            resultArtifactID: nil
        )

        let resumed = try store.job(id: organizer.id)
        XCTAssertEqual(resumed.state, .queued)
        XCTAssertNil(resumed.pauseReason)
        XCTAssertEqual(
            try store.smartInboxSyncBlockers(),
            [.init(
                accountID: secondAccount.id,
                accountEmail: secondAccount.email.rawValue,
                state: .waitingForSuccessfulSync
            )]
        )
    }

    func testIncrementalOrganizerInvalidatesCachedMessagesAcrossProviders() async throws {
        let context = try SmartInboxRuntimeContext(messages: [
            Self.message(id: "msg_1", preview: "First"),
            Self.message(id: "msg_2", preview: "Second"),
        ])
        _ = try await context.run(mode: .incremental, providerID: "provider-a")
        let cache = try context.store.smartInboxClassificationCache()
        XCTAssertEqual(Set(cache.keys.map(\.rawValue)), Set(["msg_1", "msg_2"]))
        XCTAssertEqual(Set(cache.values.map(\.providerID)), Set(["provider-a"]))
        try context.store.cacheOwnedTestMessage(Self.message(id: "msg_3", preview: "Third"))

        _ = try await context.run(mode: .incremental, providerID: "provider-b")

        let events = await context.provider.events()
        XCTAssertEqual(events, [
            "classify:msg_1", "classify:msg_2", "classify:msg_1", "classify:msg_2", "classify:msg_3",
        ])
    }

    func testChangedFingerprintInvalidatesOnlyThatMessage() async throws {
        let context = try SmartInboxRuntimeContext(messages: [
            Self.message(id: "msg_1", preview: "First"),
            Self.message(id: "msg_2", preview: "Second"),
        ])
        _ = try await context.run(mode: .incremental, providerID: "provider-a")
        try context.store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Changed second"))

        _ = try await context.run(mode: .incremental, providerID: "provider-a")

        let events = await context.provider.events()
        XCTAssertEqual(events, [
            "classify:msg_1", "classify:msg_2", "classify:msg_2",
        ])
    }

    func testRerunAllBypassesEveryValidCacheEntry() async throws {
        let context = try SmartInboxRuntimeContext(messages: [
            Self.message(id: "msg_1", preview: "First"),
            Self.message(id: "msg_2", preview: "Second"),
        ])
        _ = try await context.run(mode: .incremental, providerID: "provider-a")

        _ = try await context.run(mode: .rerunAll, providerID: "provider-b")

        let events = await context.provider.events()
        XCTAssertEqual(events, [
            "classify:msg_1", "classify:msg_2", "classify:msg_1", "classify:msg_2",
        ])
    }

    func testEmptyIncrementalOrganizerResumeKeepsOriginalSnapshot() async throws {
        let context = try SmartInboxRuntimeContext(messages: [])
        let organizer = try context.enqueue(mode: .incremental, providerID: "provider-a")
        let claimed = try XCTUnwrap(
            context.store.claimNextJob(allowedKinds: [.aiOperation, .searchRebuild])
        )
        let firstLease = try XCTUnwrap(claimed.leaseToken)
        try context.store.prepareSmartInboxWork(jobID: organizer.id, leaseToken: firstLease, seeds: [])
        try context.store.pauseJob(
            id: organizer.id,
            leaseToken: firstLease,
            reason: "test-preemption",
            progress: .init(current: 0, total: 0, phase: "paused", label: "Smart Inbox")
        )
        let laterMessage = Self.message(id: "msg_later", preview: "Arrived later")
        try context.store.cacheOwnedTestMessage(laterMessage)

        let completed = try await context.runtime.processNextJob()
        let events = await context.provider.events()

        XCTAssertEqual(completed?.id, organizer.id)
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(events, [])
        XCTAssertEqual(try context.store.smartInboxWorkSummary(jobID: organizer.id).total, 0)
        XCTAssertEqual(
            try context.store.messageSummary(id: laterMessage.id)?.smartCategory,
            .unknown
        )
    }

    private static func jobRequest(
        input: PlainpostAIOperationInput,
        idempotencyKey: String
    ) throws -> PlainpostJobRequest {
        let data = try JSONEncoder().encode(input)
        return PlainpostJobRequest(
            kind: input.operation == .rebuildIndex ? .searchRebuild : .aiOperation,
            payloadJSON: String(decoding: data, as: UTF8.self),
            priority: input.operation.priority,
            idempotencyKey: idempotencyKey
        )
    }

    private static func syncRequest(
        key: String,
        accountID: AccountID = PlainpostFixtures.personalAccount.id
    ) throws -> PlainpostJobRequest {
        let input = PlainpostInboxSyncInput(
            accountID: accountID,
            trigger: .manual
        )
        let data = try JSONEncoder().encode(input)
        return PlainpostJobRequest(
            kind: .inboxSync,
            payloadJSON: String(decoding: data, as: UTF8.self),
            priority: 100,
            idempotencyKey: key
        )
    }

    private static func completeSuccessfulSync(
        in store: SQLiteMailStore,
        key: String,
        accountID: AccountID = PlainpostFixtures.personalAccount.id
    ) throws {
        _ = try store.enqueueJob(try syncRequest(key: key, accountID: accountID))
        let sync = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        try store.completeJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(sync.leaseToken),
            resultArtifactID: nil
        )
    }

    private static func message(id: String, preview: String) -> MessageSummary {
        MessageSummary(
            id: MessageID(id),
            threadID: ThreadID("thr_shared"),
            from: EmailAddress("alice@example.com"),
            subject: "Shared thread",
            preview: preview,
            smartCategory: .unknown
        )
    }

    private static func smartInboxWorkState(
        databaseURL: URL,
        jobID: String,
        ordinal: Int
    ) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT state FROM smart_inbox_work_items WHERE job_id = ? AND ordinal = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, jobID, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(ordinal))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw PlainpostError.validationFailed("SQLite query returned no row.")
        }
        return String(cString: value)
    }

    private enum AsyncTestTimeout: Error {
        case exceeded
    }

    private static func waitUntil(
        within duration: Duration,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while !(await condition()) {
            guard clock.now < deadline else {
                throw AsyncTestTimeout.exceeded
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func value<T: Sendable>(
        of task: Task<T, any Error>,
        within duration: Duration
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: AsyncTestOutcome<T>.self) { group in
            group.addTask { .value(try await task.value) }
            group.addTask {
                try await Task.sleep(for: duration)
                return .timeout
            }
            guard let outcome = try await group.next() else {
                throw AsyncTestTimeout.exceeded
            }
            switch outcome {
            case .value(let value):
                group.cancelAll()
                return value
            case .timeout:
                task.cancel()
                _ = try? await task.value
                group.cancelAll()
                throw AsyncTestTimeout.exceeded
            }
        }
    }
}

private enum AsyncTestOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timeout
}

private actor HeldProviderFailureSelectionHook {
    private(set) var entryCount = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hasEntered() -> Bool {
        entryCount > 0
    }

    func enterAndWait() async {
        entryCount += 1
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ConcurrentFailureClassificationProvider: AIProvider, @unchecked Sendable {
    let id = "concurrent-failure"
    let displayName = "Concurrent Failure"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let controller = ConcurrentFailureClassificationController()

    func waitUntilClassificationStarts() async {
        await controller.waitUntilClassificationStarts()
    }

    func hasClassificationStarted() async -> Bool {
        await controller.hasClassificationStarted()
    }

    func releaseFailure() async {
        await controller.releaseFailure()
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        try await controller.classify()
        return AIClassificationResponse(category: .newsletter, confidence: 0.9, reason: "Controlled")
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        AITranslationResponse(
            segments: request.segments.map {
                AITranslatedSegment(id: $0.id, translation: "Translated \($0.text)")
            },
            modelID: id,
            localOnly: true
        )
    }
}

private actor ConcurrentFailureClassificationController {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureRelease: CheckedContinuation<Void, Never>?

    func waitUntilClassificationStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func hasClassificationStarted() -> Bool {
        started
    }

    func releaseFailure() {
        failureRelease?.resume()
        failureRelease = nil
    }

    func classify() async throws {
        if !started {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { failureRelease = $0 }
            throw AIProviderError.unavailable
        }
    }
}

private final class CancellableClassificationProvider: AIProvider, @unchecked Sendable {
    let id = "cancellable"
    let displayName = "Cancellable"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let controller = CancellableClassificationController()

    func waitUntilFirstClassificationStarts() async {
        await controller.waitUntilFirstClassificationStarts()
    }

    func events() async -> [String] { await controller.events }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        await controller.append("generate")
        return AIGenerationResponse(text: "Generated reply or summary", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        try await controller.classify(messageID: request.message.id.rawValue)
        return AIClassificationResponse(category: .newsletter, confidence: 0.9, reason: "Controlled")
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        await controller.append("translate")
        return AITranslationResponse(
            segments: request.segments.map {
                AITranslatedSegment(id: $0.id, translation: "Translated \($0.text)")
            },
            modelID: id,
            localOnly: true
        )
    }
}

private actor CancellableClassificationController {
    private(set) var events: [String] = []
    private var invocationCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFirstClassificationStarts() async {
        if invocationCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func append(_ event: String) { events.append(event) }

    func classify(messageID: String) async throws {
        invocationCount += 1
        events.append("classify:\(messageID)")
        if invocationCount == 1 {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                events.append("cancel:\(messageID)")
                throw CancellationError()
            }
        }
    }
}

private final class CancellationHoldingClassificationProvider: AIProvider, @unchecked Sendable {
    let id = "cancellation-holding"
    let displayName = "Cancellation Holding"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let controller = CancellationHoldingClassificationController()

    func waitUntilFirstClassificationStarts() async {
        await controller.waitUntilFirstClassificationStarts()
    }

    func hasFirstClassificationStarted() async -> Bool {
        await controller.hasFirstClassificationStarted()
    }

    func waitUntilCancellationStarts() async {
        await controller.waitUntilCancellationStarts()
    }

    func hasCancellationStarted() async -> Bool {
        await controller.hasCancellationStarted()
    }

    func releaseCancellation() async {
        await controller.releaseCancellation()
    }

    func events() async -> [String] { await controller.events }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        try await controller.classify(messageID: request.message.id.rawValue)
        return AIClassificationResponse(category: .newsletter, confidence: 0.9, reason: "Controlled")
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        throw AIProviderError.unavailable
    }
}

private actor CancellationHoldingClassificationController {
    private(set) var events: [String] = []
    private var invocationCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRelease: CheckedContinuation<Void, Never>?

    func waitUntilFirstClassificationStarts() async {
        if invocationCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func hasFirstClassificationStarted() -> Bool {
        invocationCount > 0
    }

    func waitUntilCancellationStarts() async {
        if events.contains(where: { $0.hasPrefix("cancel:") }) { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func hasCancellationStarted() -> Bool {
        events.contains { $0.hasPrefix("cancel:") }
    }

    func releaseCancellation() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }

    func classify(messageID: String) async throws {
        invocationCount += 1
        events.append("classify:\(messageID)")
        guard invocationCount == 1 else { return }
        let starters = startWaiters
        startWaiters.removeAll()
        starters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            events.append("cancel:\(messageID)")
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { cancellationRelease = $0 }
            throw CancellationError()
        }
    }
}

private final class ControlledAIProvider: AIProvider, @unchecked Sendable {
    let id = "controlled"
    let displayName = "Controlled"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4096,
        runsLocally: true
    )
    private let controller = ControlledAIController()

    func waitUntilFirstClassificationStarts() async {
        await controller.waitUntilFirstClassificationStarts()
    }

    func releaseFirstClassification() async {
        await controller.releaseFirstClassification()
    }

    func events() async -> [String] {
        await controller.recordedEvents()
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        await controller.recordGeneration()
        return AIGenerationResponse(text: "The thread contains two messages.", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        await controller.classify(messageID: request.message.id.rawValue)
        return AIClassificationResponse(category: .newsletter, confidence: 0.9, reason: "Controlled classification")
    }

    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        await controller.recordTranslation()
        return AITranslationResponse(
            segments: request.segments.map {
                AITranslatedSegment(id: $0.id, translation: "Translated \($0.text)")
            },
            modelID: chatModelID,
            localOnly: true
        )
    }
}

private actor ControlledAIController {
    private var eventLog: [String] = []
    private var firstClassificationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilFirstClassificationStarts() async {
        guard !firstClassificationStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstClassification() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func classify(messageID: String) async {
        eventLog.append("classify:\(messageID)")
        guard !firstClassificationStarted else { return }
        firstClassificationStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func recordGeneration() {
        eventLog.append("generate")
    }

    func recordTranslation() {
        eventLog.append("translate")
    }

    func recordedEvents() -> [String] {
        eventLog
    }
}

private final class SmartInboxRuntimeContext {
    let store: SQLiteMailStore
    let runtime: LocalOperationRuntime
    let provider = RecordingClassificationProvider()
    private let databaseURL: URL

    init(messages: [MessageSummary]) throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-cache-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        for message in messages {
            try store.cacheOwnedTestMessage(message)
        }
        let provider = self.provider
        runtime = LocalOperationRuntime(
            store: store,
            credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func enqueue(mode: PlainpostSmartInboxRunMode, providerID: String) throws -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: providerID,
            smartInboxRunMode: mode,
            smartInboxRequestID: mode == .rerunAll ? UUID().uuidString.lowercased() : nil
        )
        let data = try JSONEncoder().encode(input)
        return try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: input.operation.priority,
                idempotencyKey: "test-organizer:\(UUID().uuidString.lowercased())"
            )
        )
    }

    func run(mode: PlainpostSmartInboxRunMode, providerID: String) async throws -> PlainpostDurableJob? {
        _ = try enqueue(mode: mode, providerID: providerID)
        return try await runtime.processNextJob()
    }

    func completeSuccessfulSync(key: String) throws {
        let input = PlainpostInboxSyncInput(
            accountID: PlainpostFixtures.personalAccount.id,
            trigger: .manual
        )
        let data = try JSONEncoder().encode(input)
        _ = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: 100,
                idempotencyKey: key
            )
        )
        let sync = try XCTUnwrap(
            store.claimNextJob(allowedKinds: [.inboxSync, .historicalSync])
        )
        try store.completeJob(
            id: sync.id,
            leaseToken: try XCTUnwrap(sync.leaseToken),
            resultArtifactID: nil
        )
    }
}

private final class RecordingClassificationProvider: AIProvider, @unchecked Sendable {
    let id = "recording"
    let displayName = "Recording"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let recorder = ClassificationEventRecorder()

    func events() async -> [String] { await recorder.events }
    func classificationCallCount() async -> Int { await recorder.classificationCallCount() }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: "Generated", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        await recorder.append("classify:\(request.message.id.rawValue)")
        return AIClassificationResponse(category: .newsletter, confidence: 0.9, reason: "Recorded")
    }
}

private actor ClassificationEventRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func classificationCallCount() -> Int { events.filter { $0.hasPrefix("classify:") }.count }
}

extension InteractiveAIPreemptionTests {
    private func translationInput(_ recordID: String, providerID: String) -> PlainpostAIOperationInput {
        PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: recordID,
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: providerID,
            targetLanguageIdentifier: "en",
            targetLanguageName: "English"
        )
    }

    /// A person waiting on a translation runs only that translation, not an older one another
    /// screen queued and then abandoned (it sat ahead and the new request waited on it).
    func testAWaitingTranslationRunsOnlyItsOwnJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-job-only-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "Erste"))
        try store.cacheOwnedTestMessage(Self.message(id: "msg_2", preview: "Zweite"))
        let provider = CancellableClassificationProvider()
        let runtime = LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.aiOperation, .searchRebuild],
            aiProviderResolver: { _ in provider }
        )
        let abandoned = try store.enqueueJob(Self.jobRequest(
            input: translationInput("msg_2", providerID: provider.id), idempotencyKey: "abandoned-translation"
        ))

        _ = try await LocalOperationClient(runtime: runtime)
            .executeAI(translationInput("msg_1", providerID: provider.id))

        let events = await provider.events()
        XCTAssertEqual(events, ["translate"])
        XCTAssertEqual(try store.job(id: abandoned.id).state, .queued)
    }

    /// After a relaunch no one waits for an old question or translation; a Smart Inbox run keeps going.
    func testAbandonedInteractiveJobsAreCancelledAndSmartInboxIsKept() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abandoned-interactive-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheOwnedTestMessage(Self.message(id: "msg_1", preview: "Erste"))
        let translation = try store.enqueueJob(Self.jobRequest(
            input: translationInput("msg_1", providerID: "fixture"), idempotencyKey: "old-translation"
        ))
        let organizer = try store.enqueueJob(Self.jobRequest(
            input: PlainpostAIOperationInput(operation: .recategorizeInbox, recordID: "", providerID: "fixture"),
            idempotencyKey: "old-organizer"
        ))

        XCTAssertEqual(try LocalOperationRuntime.cancelAbandonedInteractiveAIJobs(in: store), 0,
                       "Fresh work may still have a waiting screen")
        XCTAssertEqual(
            try LocalOperationRuntime.cancelAbandonedInteractiveAIJobs(in: store, now: Date().addingTimeInterval(3_600)),
            1
        )
        XCTAssertEqual(try store.job(id: translation.id).state, .cancelled)
        XCTAssertEqual(try store.job(id: organizer.id).state, .queued)
    }
}
