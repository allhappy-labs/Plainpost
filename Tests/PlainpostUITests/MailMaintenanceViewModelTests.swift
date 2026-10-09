import Combine
import XCTest
@testable import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostOperations
@testable import PlainpostUI

final class MailMaintenanceViewModelTests: XCTestCase {
    @MainActor
    func testSuccessPolicyPerformsEachProductionEffectExactlyOnce() {
        var mailboxAdvanceCount = 0
        var activityRefreshCount = 0

        MailMaintenanceSuccessPolicy.perform(
            advanceMailbox: { mailboxAdvanceCount += 1 },
            refreshActivity: { activityRefreshCount += 1 }
        )

        XCTAssertEqual(mailboxAdvanceCount, 1)
        XCTAssertEqual(activityRefreshCount, 1)
    }

    @MainActor
    func testSyncCallsAccountSetupOnceAndPresentsProgressAndSuccess() async {
        let service = SuspendedMaintenanceAccountSetupService()
        let accountSetup = connectedAccountSetup(service: service)
        let maintenance = makeMaintenance(accountSetup: accountSetup)

        let sync = Task { await maintenance.syncNow() }
        await service.waitUntilSyncStarts()

        let syncCallCount = await service.syncCallCount
        XCTAssertEqual(syncCallCount, 1)
        XCTAssertEqual(maintenance.syncState, .inProgress(message: "Syncing…"))
        XCTAssertEqual(maintenance.syncButtonTitle, "Syncing…")
        XCTAssertTrue(maintenance.isSyncing)

        await service.finishSync()
        await sync.value

        XCTAssertEqual(maintenance.syncState, .success(message: "Inbox sync finished."))
        XCTAssertEqual(maintenance.syncButtonTitle, "Sync now")
        XCTAssertFalse(maintenance.isSyncing)
    }

    @MainActor
    func testLastSyncRefreshesOnSyncCompletionAndActivityRefresh() async {
        let service = SuspendedMaintenanceAccountSetupService()
        var stored: Date?
        let maintenance = makeMaintenance(
            accountSetup: connectedAccountSetup(service: service),
            lastSuccessfulSync: { stored }
        )
        XCTAssertNil(maintenance.lastSuccessfulSyncAt)

        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = Task { await maintenance.syncNow() }
        await service.waitUntilSyncStarts()
        stored = synced
        await service.finishSync()
        await sync.value
        XCTAssertEqual(maintenance.lastSuccessfulSyncAt, synced)

        let later = synced.addingTimeInterval(60)
        stored = later
        maintenance.refreshActivity()
        XCTAssertEqual(maintenance.lastSuccessfulSyncAt, later)
    }

    func testLastSyncDescriptionIsNeverOrLocaleAwareRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            MailLastSyncPolicy.description(of: nil, now: now, locale: Locale(identifier: "en_US")),
            "Never"
        )
        XCTAssertEqual(
            MailLastSyncPolicy.description(
                of: now.addingTimeInterval(-300), now: now, locale: Locale(identifier: "en_US")
            ),
            "5 minutes ago"
        )
        XCTAssertEqual(
            MailLastSyncPolicy.description(
                of: now.addingTimeInterval(-300), now: now, locale: Locale(identifier: "de_DE")
            ),
            "vor 5 Minuten"
        )
    }

    @MainActor
    func testSecondSyncWhileFirstIsActiveJoinsSharedRequest() async {
        let service = SuspendedMaintenanceAccountSetupService()
        let maintenance = makeMaintenance(
            accountSetup: connectedAccountSetup(service: service)
        )

        let firstSync = Task { await maintenance.syncNow() }
        await service.waitUntilSyncStarts()

        let joinedSync = Task { await maintenance.syncNow() }
        await Task.yield()
        let syncCallCount = await service.syncCallCount
        XCTAssertEqual(syncCallCount, 1)

        await service.finishSync()
        await firstSync.value
        await joinedSync.value
    }

    @MainActor
    func testTwoModelsShareSyncStateRequestAndCompletionPath() async {
        let firstService = SuspendedMaintenanceAccountSetupService()
        let secondService = SuspendedMaintenanceAccountSetupService()
        let syncCoordinator = MailSyncCoordinator()
        let completions = MaintenanceCompletionRecorder()
        let firstMaintenance = makeMaintenance(
            accountSetup: connectedAccountSetup(service: firstService),
            syncCoordinator: syncCoordinator,
            didCompleteSuccessfully: {
                await completions.record()
            }
        )
        let secondMaintenance = makeMaintenance(
            accountSetup: connectedAccountSetup(service: secondService),
            syncCoordinator: syncCoordinator,
            didCompleteSuccessfully: {
                await completions.record()
            }
        )
        var secondModelChangeCount = 0
        let secondModelObservation = secondMaintenance.objectWillChange.sink {
            secondModelChangeCount += 1
        }

        let firstSync = Task { await firstMaintenance.syncNow() }
        await firstService.waitUntilSyncStarts()

        XCTAssertGreaterThan(secondModelChangeCount, 0)
        XCTAssertTrue(firstMaintenance.isSyncing)
        XCTAssertTrue(secondMaintenance.isSyncing)
        XCTAssertEqual(
            secondMaintenance.syncState,
            .inProgress(message: "Syncing…")
        )

        let joinedSync = Task { await secondMaintenance.syncNow() }
        await Task.yield()
        let firstSyncCallCount = await firstService.syncCallCount
        let secondSyncCallCount = await secondService.syncCallCount
        XCTAssertEqual(firstSyncCallCount, 1)
        XCTAssertEqual(secondSyncCallCount, 0)

        await firstService.finishSync()
        await firstSync.value
        await joinedSync.value

        let completionCount = await completions.count
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(
            firstMaintenance.syncState,
            .success(message: "Inbox sync finished.")
        )
        XCTAssertEqual(secondMaintenance.syncState, firstMaintenance.syncState)
        XCTAssertFalse(firstMaintenance.isSyncing)
        XCTAssertFalse(secondMaintenance.isSyncing)
        withExtendedLifetime(secondModelObservation) {}
    }

    @MainActor
    func testConfirmedRerunUsesCurrentProviderRerunAllAndFreshLowercaseRequestID() async throws {
        let recorder = MaintenanceRerunRecorder()
        var selectedProviderID = "foundation"
        let maintenance = makeMaintenance(
            selectedProviderID: { selectedProviderID },
            rerun: { providerID, mode, requestID in
                try await recorder.run(
                    providerID: providerID,
                    mode: mode,
                    requestID: requestID
                )
            }
        )

        let initialCallCount = await recorder.callCount
        XCTAssertEqual(initialCallCount, 0, "Opening Diagnostics must not start a rerun.")
        selectedProviderID = "ollama"

        await maintenance.rerunSmartInbox()

        let calls = await recorder.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.providerID, "ollama")
        XCTAssertEqual(call.mode, .rerunAll)
        let requestID = try XCTUnwrap(call.requestID)
        XCTAssertFalse(requestID.isEmpty)
        XCTAssertEqual(requestID, requestID.lowercased())
        XCTAssertNotNil(UUID(uuidString: requestID))
        XCTAssertEqual(
            maintenance.rerunState,
            .success(message: "Smart Inbox rerun finished.")
        )
    }

    @MainActor
    func testUnavailableAIGenerationPreventsDiagnosticsRerun() async {
        let recorder = MaintenanceRerunRecorder()
        let maintenance = makeMaintenance(
            aiGenerationAvailable: { false },
            rerun: { providerID, mode, requestID in
                try await recorder.run(
                    providerID: providerID, mode: mode, requestID: requestID
                )
            }
        )

        XCTAssertFalse(maintenance.canRerunSmartInbox)
        await maintenance.rerunSmartInbox()

        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(maintenance.rerunState, .idle)
    }

    @MainActor
    func testSecondRerunWhileFirstIsInProgressIsIgnored() async {
        let recorder = MaintenanceRerunRecorder(suspends: true)
        let maintenance = makeMaintenance(
            rerun: { providerID, mode, requestID in
                try await recorder.run(
                    providerID: providerID,
                    mode: mode,
                    requestID: requestID
                )
            }
        )

        let firstRerun = Task { await maintenance.rerunSmartInbox() }
        await recorder.waitUntilRunStarts()

        XCTAssertEqual(maintenance.rerunState, .inProgress(message: "Rerunning Smart Inbox…"))
        XCTAssertEqual(maintenance.rerunButtonTitle, "Rerunning Smart Inbox…")
        XCTAssertTrue(maintenance.isRerunActive)

        await maintenance.rerunSmartInbox()
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)

        await recorder.finishRun()
        await firstRerun.value
    }

    @MainActor
    func testRerunIsIgnoredWhileCoordinatorReportsActiveRerun() async {
        let job = smartInboxRerunJob()
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { job },
            pause: { _ in },
            resume: { _ in }
        )
        let recorder = MaintenanceRerunRecorder()
        let maintenance = makeMaintenance(
            smartInboxActivity: coordinator,
            rerun: { providerID, mode, requestID in
                try await recorder.run(
                    providerID: providerID,
                    mode: mode,
                    requestID: requestID
                )
            }
        )

        XCTAssertTrue(maintenance.isRerunActive)
        await maintenance.rerunSmartInbox()

        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(maintenance.rerunState, .idle)
    }

    @MainActor
    func testRefreshActivityTracksExternalRerunStartAndCompletion() {
        var durableJob: PlainpostDurableJob?
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { durableJob },
            pause: { _ in },
            resume: { _ in }
        )
        let maintenance = makeMaintenance(
            smartInboxActivity: coordinator
        )

        XCTAssertFalse(maintenance.isRerunActive)

        durableJob = smartInboxRerunJob()
        maintenance.refreshActivity()
        XCTAssertTrue(maintenance.isRerunActive)

        durableJob = nil
        maintenance.refreshActivity()
        XCTAssertFalse(maintenance.isRerunActive)
    }

    @MainActor
    func testAuthoritativeRerunDisablesActionWhenPresentationShowsIncremental() {
        var activeRerun: PlainpostDurableJob? = smartInboxRerunJob()
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { self.smartInboxIncrementalJob() },
            pause: { _ in },
            resume: { _ in }
        )
        let maintenance = makeMaintenance(
            smartInboxActivity: coordinator,
            activeRerunJob: { activeRerun }
        )

        XCTAssertFalse(coordinator.isRerunActive)
        XCTAssertTrue(maintenance.isRerunActive)

        activeRerun = nil
        maintenance.refreshActivity()
        XCTAssertFalse(maintenance.isRerunActive)
    }

    @MainActor
    func testSuccessfulRerunInvokesCompletionCallbackOnce() async {
        let completions = MaintenanceCompletionRecorder()
        let maintenance = makeMaintenance(
            rerun: { _, _, _ in "Up to date" },
            didCompleteSuccessfully: {
                await completions.record()
            }
        )

        await maintenance.rerunSmartInbox()

        let completionCount = await completions.count
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testFailuresUseSafeHumanReadableMessages() async {
        let secretBody = "Quarterly acquisition body"
        let secretCredential = "imap-password-123"
        let syncService = SuspendedMaintenanceAccountSetupService(
            failure: MaintenanceTestError.failure("\(secretBody) \(secretCredential)")
        )
        let syncMaintenance = makeMaintenance(
            accountSetup: connectedAccountSetup(service: syncService)
        )

        let sync = Task { await syncMaintenance.syncNow() }
        await syncService.waitUntilSyncStarts()
        await syncService.finishSync()
        await sync.value

        XCTAssertEqual(
            syncMaintenance.syncState,
            .failure(message: "Inbox sync failed. Check your account settings and try again.")
        )
        XCTAssertFalse(syncMaintenance.syncState.message.contains(secretBody))
        XCTAssertFalse(syncMaintenance.syncState.message.contains(secretCredential))

        let rerunMaintenance = makeMaintenance(
            rerun: { _, _, _ in
                throw MaintenanceTestError.failure("\(secretBody) \(secretCredential)")
            }
        )
        await rerunMaintenance.rerunSmartInbox()

        XCTAssertEqual(
            rerunMaintenance.rerunState,
            .failure(message: "Smart Inbox rerun failed. Try again.")
        )
        XCTAssertFalse(rerunMaintenance.rerunState.message.contains(secretBody))
        XCTAssertFalse(rerunMaintenance.rerunState.message.contains(secretCredential))
    }

    @MainActor
    func testIsSmartInboxPausedForLowPowerReflectsLowPowerModeActiveClosure() {
        let pausedMaintenance = makeMaintenance(lowPowerModeActive: { true })
        XCTAssertTrue(pausedMaintenance.isSmartInboxPausedForLowPower)

        let activeMaintenance = makeMaintenance(lowPowerModeActive: { false })
        XCTAssertFalse(activeMaintenance.isSmartInboxPausedForLowPower)
    }

    @MainActor
    func testLowPowerModeChangesPublishLiveAndDisableReSort() async {
        let changes = PassthroughSubject<Bool, Never>()
        let maintenance = makeMaintenance(
            lowPowerModeActive: { false },
            lowPowerModeChanges: changes.eraseToAnyPublisher()
        )
        XCTAssertFalse(maintenance.isSmartInboxPausedForLowPower)
        XCTAssertTrue(maintenance.canRerunSmartInbox)

        let published = expectation(description: "low power published")
        let observation = maintenance.$isSmartInboxPausedForLowPower.dropFirst().sink { active in
            if active { published.fulfill() }
        }
        changes.send(true)
        await fulfillment(of: [published], timeout: 1)
        observation.cancel()
        XCTAssertTrue(maintenance.isSmartInboxPausedForLowPower)
        XCTAssertFalse(maintenance.canRerunSmartInbox, "Re-sort All is disabled, not left to fail, in Low Power Mode")

        let cleared = expectation(description: "low power cleared")
        let clearObservation = maintenance.$isSmartInboxPausedForLowPower.dropFirst().sink { active in
            if !active { cleared.fulfill() }
        }
        changes.send(false)
        await fulfillment(of: [cleared], timeout: 1)
        clearObservation.cancel()
        XCTAssertTrue(maintenance.canRerunSmartInbox)
    }

    @MainActor
    func testSmartInboxProgressReflectsActivityPresentation() {
        let job = smartInboxRerunJob()
        let coordinator = SmartInboxActivityCoordinator(
            jobProvider: { job },
            pause: { _ in },
            resume: { _ in }
        )
        let maintenance = makeMaintenance(smartInboxActivity: coordinator)

        let progress = maintenance.smartInboxProgress
        XCTAssertEqual(progress?.processed, 1)
        XCTAssertEqual(progress?.total, 10)
    }

    @MainActor
    private func makeMaintenance(
        accountSetup: AccountSetupViewModel? = nil,
        syncCoordinator: MailSyncCoordinator = MailSyncCoordinator(),
        smartInboxActivity: SmartInboxActivityCoordinator? = nil,
        activeRerunJob: (() -> PlainpostDurableJob?)? = nil,
        selectedProviderID: @escaping () -> String = { "foundation" },
        aiGenerationAvailable: @escaping () -> Bool = { true },
        rerun: @escaping (String, PlainpostSmartInboxRunMode, String?) async throws -> String = {
            _, _, _ in "Up to date"
        },
        didCompleteSuccessfully: @escaping () async -> Void = {},
        lowPowerModeActive: @escaping () -> Bool = { false },
        lowPowerModeChanges: AnyPublisher<Bool, Never>? = nil,
        lastSuccessfulSync: @escaping () -> Date? = { nil }
    ) -> MailMaintenanceViewModel {
        let activity = smartInboxActivity ?? SmartInboxActivityCoordinator(
            jobProvider: { nil },
            pause: { _ in },
            resume: { _ in }
        )
        return MailMaintenanceViewModel(
            accountSetup: accountSetup ?? connectedAccountSetup(
                service: SuspendedMaintenanceAccountSetupService()
            ),
            syncCoordinator: syncCoordinator,
            smartInboxActivity: activity,
            activeRerunJob: activeRerunJob ?? {
                activity.isRerunActive ? activity.job : nil
            },
            selectedProviderID: selectedProviderID,
            aiGenerationAvailable: aiGenerationAvailable,
            rerun: rerun,
            didCompleteSuccessfully: didCompleteSuccessfully,
            lowPowerModeActive: lowPowerModeActive,
            lowPowerModeChanges: lowPowerModeChanges,
            lastSuccessfulSync: lastSuccessfulSync
        )
    }

    @MainActor
    private func connectedAccountSetup(
        service: any AccountSetupHandling
    ) -> AccountSetupViewModel {
        let account = Account(
            id: AccountID("acc_maintenance"),
            displayName: "Maintenance",
            email: EmailAddress("maintenance@example.com"),
            imapHost: "imap.example.com",
            imapPort: 993,
            smtpHost: "smtp.example.com",
            smtpPort: 587
        )
        return AccountSetupViewModel(
            setup: service,
            displayName: account.displayName,
            email: account.email.rawValue,
            imapHost: account.imapHost,
            smtpHost: account.smtpHost,
            username: account.username,
            status: .connected(accountID: account.id.rawValue),
            account: account
        )
    }

    private func smartInboxRerunJob() -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation",
            smartInboxRunMode: .rerunAll
        )
        return PlainpostDurableJob(
            id: "job_maintenance_rerun",
            kind: .aiOperation,
            payloadJSON: String(
                decoding: try! JSONEncoder().encode(input),
                as: UTF8.self
            ),
            state: .running,
            idempotencyKey: "maintenance-rerun",
            progress: PlainpostOperationProgress(
                current: 1,
                total: 10,
                phase: "running",
                label: "Smart Inbox"
            )
        )
    }

    private func smartInboxIncrementalJob() -> PlainpostDurableJob {
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation",
            smartInboxRunMode: .incremental
        )
        return PlainpostDurableJob(
            id: "job_maintenance_incremental",
            kind: .aiOperation,
            payloadJSON: String(
                decoding: try! JSONEncoder().encode(input),
                as: UTF8.self
            ),
            state: .running,
            idempotencyKey: "maintenance-incremental",
            progress: PlainpostOperationProgress(
                current: 2,
                total: 10,
                phase: "running",
                label: "Smart Inbox"
            )
        )
    }
}

private actor MaintenanceCompletionRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private enum MaintenanceTestError: Error {
    case failure(String)
}

private actor SuspendedMaintenanceAccountSetupService: AccountSetupHandling {
    private var syncCalls = 0
    private var syncStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var syncFinishWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFinish = false
    private let failure: MaintenanceTestError?

    init(failure: MaintenanceTestError? = nil) {
        self.failure = failure
    }

    var syncCallCount: Int { syncCalls }

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        throw MaintenanceTestError.failure("not used")
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        syncCalls += 1
        let started = syncStartedWaiters
        syncStartedWaiters.removeAll()
        started.forEach { $0.resume() }

        if !shouldFinish {
            await withCheckedContinuation { continuation in
                syncFinishWaiters.append(continuation)
            }
        }
        if let failure {
            throw failure
        }
        return IMAPSyncResult(syncedMessageCount: 3)
    }

    func waitUntilSyncStarts() async {
        guard syncCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            syncStartedWaiters.append(continuation)
        }
    }

    func finishSync() {
        shouldFinish = true
        let waiters = syncFinishWaiters
        syncFinishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MaintenanceRerunRecorder {
    struct Call: Sendable {
        let providerID: String
        let mode: PlainpostSmartInboxRunMode
        let requestID: String?
    }

    private(set) var calls: [Call] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFinish = false
    private let suspends: Bool

    init(suspends: Bool = false) {
        self.suspends = suspends
    }

    var callCount: Int { calls.count }

    func run(
        providerID: String,
        mode: PlainpostSmartInboxRunMode,
        requestID: String?
    ) async throws -> String {
        calls.append(Call(providerID: providerID, mode: mode, requestID: requestID))
        let started = startWaiters
        startWaiters.removeAll()
        started.forEach { $0.resume() }
        if suspends && !shouldFinish {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        return "provider result must not be exposed"
    }

    func waitUntilRunStarts() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishRun() {
        shouldFinish = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
