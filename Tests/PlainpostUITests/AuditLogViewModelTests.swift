import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostTestSupport
import PlainpostRuntimeTestSupport
import PlainpostSecrets
@testable import PlainpostUI

final class AuditLogViewModelTests: XCTestCase {
    /// On a route where `runtimeDependencies` is set (the shape iOS always uses, since its
    /// one on-device database and rotating audit log hold every Direct and Sync Node account),
    /// the raw `auditLogURL` stays nil, but the view model can still export the selected
    /// account's own entries so iOS has something safe to share. See the fuller isolation
    /// coverage in `PlainpostAppRuntimeTests.testSelectedDirectAuditViewDoesNotShowOtherAccountOrRawCombinedFile`.
    @MainActor
    func testDirectRouteExportsOwnEntriesWithoutExposingTheRawCombinedFile() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-direct-route-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let account = PlainpostFixtures.personalAccount
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccounts([account])
        _ = try seed.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ), expectedGeneration: 0
        )
        _ = try seed.createDraft(
            Draft(
                id: DraftID("audit-export-draft"), accountID: account.id, from: account.email,
                to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                subject: "Export", bodyPlain: "Body",
                createdBy: PlainpostFixtures.codexActor.id,
                aiGenerated: false, sourceThreadID: nil
            ), actor: PlainpostFixtures.codexActor
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: account.id,
                runtimeDependencies: InMemoryAppRuntimeDependencies(
                    credentials: InMemoryCredentialVault()
                )
            ), notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await runtime.shutdown() } }

        let audit = runtime.makeAuditLogViewModel()
        XCTAssertNil(audit.auditLogURL)

        let exportedURL = try XCTUnwrap(audit.exportAuditLog?())
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let contents = try String(contentsOf: exportedURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("audit-export-draft"))
    }

    /// The Node route has no export, so Share Audit Log must not be offered there.
    @MainActor
    func testShareAuditLogIsOfferedOnlyWithAnExport() {
        let withoutExport = AuditLogViewModel(log: ThreadRecordingAuditLog(rows: []))
        XCTAssertFalse(withoutExport.canShareAuditLog)
        let withExport = AuditLogViewModel(
            log: ThreadRecordingAuditLog(rows: []),
            exportAuditLog: { URL(fileURLWithPath: "/tmp/audit.txt") }
        )
        XCTAssertTrue(withExport.canShareAuditLog)
    }

    /// Exports must never pile up: a user can tap "Share Audit Log" more than once (or
    /// return to the page and tap it again) across the lifetime of the export folder, and
    /// each write should replace the previous export rather than add to it.
    func testConsecutiveExportsLeaveExactlyOneFileInTheExportFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-export-pileup-\(UUID().uuidString)", isDirectory: true)
        let directory = AuditLogExport.directory(in: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = AuditEntry(
            id: "aud_pileup", actorID: "codex", action: "draft.create",
            targetType: "draft", targetID: "drf_pileup", result: "ok"
        )

        let first = try AuditLogExport.write([TimestampedAuditEntry(entry: entry, occurredAt: nil)], to: directory)
        let second = try AuditLogExport.write([TimestampedAuditEntry(entry: entry, occurredAt: nil)], to: directory)

        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent, "each export should get its own file name")
        let filesAfter = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(filesAfter.map(\.lastPathComponent), [second.lastPathComponent])
    }

    func testExportStartsEachLineWithItsISO8601Timestamp() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-export-times-\(UUID().uuidString)", isDirectory: true)
        let directory = AuditLogExport.directory(in: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let newer = TimestampedAuditEntry(
            entry: AuditEntry(
                id: "aud_newer", actorID: "codex", action: "draft.create",
                targetType: "draft", targetID: "drf_1", result: "ok"
            ),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
        let older = TimestampedAuditEntry(
            entry: AuditEntry(
                id: "aud_older", actorID: "codex", action: "message.read",
                targetType: "message", targetID: "msg_1", result: "denied"
            ),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let untimed = TimestampedAuditEntry(
            entry: AuditEntry(
                id: "aud_untimed", actorID: "codex", action: "legacy.event",
                targetType: "runtime", targetID: "r", result: "ok"
            ),
            occurredAt: nil
        )

        let url = try AuditLogExport.write([newer, older, untimed], to: directory)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("Plainpost audit log · exported "))
        XCTAssertEqual(Array(lines.dropFirst()), [
            "2027-01-15T08:01:00Z · draft.create · ok · draft drf_1",
            "2027-01-15T08:00:00Z · message.read · denied · message msg_1",
            "unknown time · legacy.event · ok · runtime r",
        ])
    }

    func testSelectedAuditServiceUsesScopedEntriesBeforeItsDisplayLimit() throws {
        let foreign = AuditEntry(
            id: "foreign", actorID: "other", action: "message.read",
            targetType: "message", targetID: "foreign-message", result: "ok"
        )
        let selected = AuditEntry(
            id: "selected", actorID: "owner", action: "message.read",
            targetType: "message", targetID: "selected-message", result: "ok"
        )
        let service = AuditLogService(
            repository: AuditEntrySnapshotRepository(auditEntries: [selected, foreign]),
            displayLimit: 1,
            selectedEntries: { limit in
                XCTAssertEqual(limit, 1)
                return [selected]
            }
        )

        XCTAssertEqual(try service.rows().map(\.id), ["selected"])
    }

    func testAuditLogServiceUsesASendableRepositoryContract() throws {
        let repository = AuditEntrySnapshotRepository(
            auditEntries: [
                AuditEntry(
                    id: "aud_sendable",
                    actorID: "local-user",
                    action: "message.read",
                    targetType: "message",
                    targetID: "msg_1",
                    result: "ok"
                ),
            ]
        )
        let service = AuditLogService(repository: repository)

        requireSendable(service)
        XCTAssertEqual(try service.rows().map(\.id), ["aud_sendable"])
    }

    @MainActor
    func testDisabledSmartInboxDiagnosticsPresentsRetainedQueuedJobAsPaused() async throws {
        try await assertDisabledSmartInboxDiagnostics(running: false)
    }

    @MainActor
    func testDisabledSmartInboxDiagnosticsPresentsRunningJobAsPausedAndRetainsProgress() async throws {
        try await assertDisabledSmartInboxDiagnostics(running: true)
    }

    @MainActor
    private func assertDisabledSmartInboxDiagnostics(running: Bool) async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-disabled-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox, recordID: "", providerID: "foundation"
        )
        let organizerPayload = String(decoding: try JSONEncoder().encode(organizerInput), as: UTF8.self)
        let completed = try store.enqueueJob(.init(
            kind: .aiOperation, payloadJSON: organizerPayload, idempotencyKey: "completed-organizer"
        ))
        let completedLease = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(
            id: completed.id, leaseToken: try XCTUnwrap(completedLease.leaseToken), resultArtifactID: nil
        )
        let organizer = try store.enqueueJob(.init(
            kind: .aiOperation, payloadJSON: organizerPayload, idempotencyKey: "active-organizer"
        ))
        if running {
            let lease = try XCTUnwrap(store.claimNextJob())
            try store.updateJobProgress(
                id: organizer.id, leaseToken: try XCTUnwrap(lease.leaseToken),
                progress: .init(current: 3, total: 10, phase: "classifying", label: "Smart Inbox")
            )
        }
        let otherAIInput = PlainpostAIOperationInput(
            operation: .answerMailboxQuestion, recordID: "", providerID: "foundation"
        )
        let otherAI = try store.enqueueJob(.init(
            kind: .aiOperation,
            payloadJSON: String(decoding: try JSONEncoder().encode(otherAIInput), as: UTF8.self),
            idempotencyKey: "ordinary-ai"
        ))
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let sync = try store.enqueueJob(.init(
            kind: .inboxSync,
            payloadJSON: String(decoding: try JSONEncoder().encode(PlainpostInboxSyncInput(
                accountID: PlainpostFixtures.personalAccount.id, trigger: .manual, scope: .recent
            )), as: UTF8.self), idempotencyKey: "ordinary-sync"
        ))
        let settings = AIProviderSettingsViewModel(
            statuses: [], selectedProviderID: "foundation",
            persistSmartInboxPolicy: { try store.setSmartInboxMode($0) }
        )
        let activity = SmartInboxActivityCoordinator(
            jobProvider: { try? store.job(id: organizer.id) }, pause: { _ in }, resume: { _ in }
        )
        let maintenance = MailMaintenanceViewModel(
            accountSetup: .preview(), smartInboxActivity: activity, activeRerunJob: { nil },
            selectedProviderID: { "foundation" }, smartInboxSettings: settings,
            rerun: { _, _, _ in "fixture" }
        )
        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperations()
        let originalRows = viewModel.operationRows
        func activeOperations() -> [OperationActivityRowModel] {
            TroubleshootingSettingsPage.reconciledActiveOperations(
                viewModel.operationRows,
                smartInboxActivity: activity.presentation,
                smartInboxEnabled: maintenance.smartInboxEnabled
            )
        }
        func queuedOperationCount() -> Int {
            activeOperations().filter { $0.state == .queued }.count
        }
        let originalOrganizer = try XCTUnwrap(originalRows.first { $0.id == organizer.id })
        XCTAssertEqual(queuedOperationCount(), running ? 2 : 3)

        settings.setSmartInboxMode(.off)
        XCTAssertFalse(maintenance.smartInboxEnabled)
        let presented = try XCTUnwrap(activeOperations().first { $0.id == organizer.id })
        XCTAssertEqual(presented.state, .paused)
        XCTAssertEqual(presented.statusLabel, "Paused")
        XCTAssertEqual(presented.phase, "Paused")
        XCTAssertEqual(presented.resultDetail, "Smart Inbox is disabled. Turn it on to resume organizing.")
        XCTAssertEqual(presented.current, originalOrganizer.current)
        XCTAssertEqual(presented.total, originalOrganizer.total)
        XCTAssertFalse(OperationActivityRow(operation: presented).showsIndeterminateProgress)
        XCTAssertEqual(queuedOperationCount(), 2)
        XCTAssertEqual(viewModel.operationRows, originalRows, "Presentation must not mutate durable diagnostics rows")
        XCTAssertEqual(try store.job(id: organizer.id).state, running ? .running : .queued)
        for id in [otherAI.id, sync.id] {
            XCTAssertEqual(
                activeOperations().first { $0.id == id }, originalRows.first { $0.id == id }
            )
        }
        XCTAssertFalse(activeOperations().contains { $0.id == completed.id })
        XCTAssertEqual(viewModel.operationRows.first { $0.id == completed.id }?.state, .completed)

        settings.setSmartInboxMode(.allMail)
        XCTAssertTrue(maintenance.smartInboxEnabled)
        XCTAssertEqual(activeOperations().first { $0.id == organizer.id }, originalOrganizer)
        XCTAssertEqual(queuedOperationCount(), running ? 2 : 3)
    }

    @MainActor
    func testDiagnosticsShowsPausedOrganizerReasonAndRetainedProgress() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-paused-progress-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation"
        )
        let payload = try JSONEncoder().encode(input)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                priority: input.operation.priority,
                idempotencyKey: "paused-diagnostics"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.pauseJob(
            id: job.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            reason: "ai-draft",
            progress: .init(current: 673, total: 1_452, phase: "paused", label: "Smart Inbox")
        )

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperations()

        let activity = try XCTUnwrap(viewModel.operationRows.first)
        XCTAssertEqual(activity.id, job.id)
        XCTAssertEqual(activity.state, .paused)
        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(activity.current, 673)
        XCTAssertEqual(activity.total, 1_452)
        XCTAssertEqual(activity.resultDetail, "Paused for an AI draft")
    }

    @MainActor
    func testDiagnosticsShowsSpecificMessageTranslationPauseReason() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-paused-translation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let message = MessageSummary(
            id: MessageID("msg-translate"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Translate",
            preview: "Translate",
            smartCategory: .personal
        )
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let input = PlainpostAIOperationInput(
            operation: .translateMessage,
            recordID: message.id.rawValue,
            accountID: PlainpostFixtures.personalAccount.id,
            providerID: "foundation",
            targetLanguageIdentifier: "en",
            targetLanguageName: "English"
        )
        let payload = try JSONEncoder().encode(input)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                priority: input.operation.priority,
                idempotencyKey: "paused-translation-diagnostics"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        try store.pauseJob(
            id: job.id,
            leaseToken: try XCTUnwrap(running.leaseToken),
            reason: "message-translation",
            progress: .init(current: 0, total: 1, phase: "paused", label: "Smart Inbox")
        )

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperations()

        let activity = try XCTUnwrap(viewModel.operationRows.first)
        XCTAssertEqual(activity.title, "Translating message")
        XCTAssertEqual(activity.resultDetail, "Paused for message translation")
    }

    @MainActor
    func testDiagnosticsMapsMailSyncPauseReasons() async throws {
        for (reason, expected) in [
            ("mail-sync", "Waiting for mail sync"),
            ("mail-sync-failed", "Waiting for successful mail sync"),
            ("credentials-unavailable", "Waiting for Mail Keychain"),
        ] {
            let databaseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audit-\(reason)-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let store = try SQLiteMailStore(path: databaseURL.path)
            try store.migrate()
            let input = PlainpostAIOperationInput(
                operation: .recategorizeInbox,
                recordID: "",
                providerID: "foundation"
            )
            let payload = try JSONEncoder().encode(input)
            let job = try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .aiOperation,
                    payloadJSON: String(decoding: payload, as: UTF8.self),
                    priority: input.operation.priority,
                    idempotencyKey: "diagnostics-\(reason)"
                )
            )
            let running = try XCTUnwrap(store.claimNextJob())
            try store.pauseJob(
                id: job.id,
                leaseToken: try XCTUnwrap(running.leaseToken),
                reason: reason,
                progress: .init(current: 1, total: 2, phase: "paused", label: "Smart Inbox")
            )

            let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
            try await viewModel.refreshOperations()

            XCTAssertEqual(viewModel.operationRows.first?.resultDetail, expected)
        }
    }

    @MainActor
    func testDiagnosticsKeepsTerminalFailedSyncRecentWhileOrganizerIsReleased() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-blocking-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("acc_blocked"),
            displayName: "Blocked",
            email: EmailAddress("blocked@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        let initialSync = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .manual, scope: .recent)
        )
        let runningInitialSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.completeJob(
            id: initialSync.id,
            leaseToken: try XCTUnwrap(runningInitialSync.leaseToken),
            resultArtifactID: nil
        )
        let organizerInput = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation"
        )
        let organizerPayload = try JSONEncoder().encode(organizerInput)
        let organizer = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: organizerPayload, as: UTF8.self),
                priority: organizerInput.operation.priority,
                idempotencyKey: "blocking-sync-organizer"
            )
        )
        let runningOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        try store.pauseJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(runningOrganizer.leaseToken),
            reason: "mail-sync-failed",
            progress: .init(current: 1, total: 2, phase: "paused", label: "Smart Inbox")
        )
        let failedSync = try store.enqueueCoalescedInboxSyncJob(
            .init(accountID: account.id, trigger: .manual, scope: .recent)
        )
        let runningFailedSync = try XCTUnwrap(store.claimNextJob(allowedKinds: [.inboxSync]))
        try store.failJob(
            id: failedSync.id,
            leaseToken: try XCTUnwrap(runningFailedSync.leaseToken),
            code: "TEST",
            message: "failed",
            retryAt: nil
        )

        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: store),
            jobs: store,
            accountEmails: { [account] in [account.id: account.email.rawValue] }
        )
        try await viewModel.refreshOperations()

        let queuedOrganizer = try XCTUnwrap(
            viewModel.operationRows.first(where: { $0.id == organizer.id })
        )
        XCTAssertEqual(queuedOrganizer.state, .queued)
        XCTAssertEqual(queuedOrganizer.resultDetail, "Waiting for the background worker")

        let queuedFailedSyncEvent = try XCTUnwrap(
            viewModel.operationRows.first(where: { $0.id == failedSync.id })
        )
        XCTAssertEqual(queuedFailedSyncEvent.state, .failed)
        XCTAssertEqual(queuedFailedSyncEvent.accountEmail, "blocked@example.com")

        let resumedOrganizer = try XCTUnwrap(store.claimNextJob(allowedKinds: [.aiOperation]))
        XCTAssertEqual(resumedOrganizer.id, organizer.id)
        try await viewModel.refreshOperations()

        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == organizer.id })?.state,
            .running
        )
        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == failedSync.id })?.state,
            .failed
        )

        try store.completeJob(
            id: organizer.id,
            leaseToken: try XCTUnwrap(resumedOrganizer.leaseToken),
            resultArtifactID: nil
        )
        try await viewModel.refreshOperations()

        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == organizer.id })?.state,
            .completed
        )
        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == failedSync.id })?.state,
            .failed
        )
    }

    @MainActor
    func testDiagnosticsNamesBlockingAccountForBothMailSyncPauseReasons() async throws {
        let now = Date(timeIntervalSince1970: 1_752_102_500)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation"
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let waiting = PlainpostDurableJob(
            id: "waiting-mail-sync",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: .paused,
            priority: input.operation.priority,
            idempotencyKey: "waiting-mail-sync",
            pauseReason: "mail-sync",
            progress: .init(current: 1, total: 2, phase: "paused", label: "Smart Inbox"),
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now
        )
        let failed = PlainpostDurableJob(
            id: "failed-mail-sync",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: .paused,
            priority: input.operation.priority,
            idempotencyKey: "failed-mail-sync",
            pauseReason: "mail-sync-failed",
            progress: .init(current: 1, total: 2, phase: "paused", label: "Smart Inbox"),
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [waiting, failed],
                terminalJobs: [],
                anchor: nil,
                totalTerminalCount: 0,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: [
                .init(
                    accountID: AccountID("acc_blocked"),
                    accountEmail: "blocked@example.com",
                    state: .waitingForSuccessfulSync
                ),
            ]
        )
        let viewModel = AuditLogViewModel(log: AuditLogService(repository: AuditEntrySnapshotRepository()), jobs: repository)

        try await viewModel.refreshOperations(now: now)

        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == waiting.id })?.resultDetail,
            "Waiting for mail sync (blocked@example.com)"
        )
        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == failed.id })?.resultDetail,
            "Waiting for successful mail sync (blocked@example.com)"
        )
    }

    @MainActor
    func testDiagnosticsExplainsManualPauseAndHidesInternalSmartInboxFollowUp() async throws {
        let now = Date(timeIntervalSince1970: 1_752_102_550)
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation"
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let manual = PlainpostDurableJob(
            id: "manual-smart-inbox-pause",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: .paused,
            idempotencyKey: "manual-smart-inbox-pause",
            pauseReason: "user-requested",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now
        )
        let lowPower = PlainpostDurableJob(
            id: "low-power-smart-inbox-pause",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: .paused,
            idempotencyKey: "low-power-smart-inbox-pause",
            pauseReason: "low-power",
            createdAt: now.addingTimeInterval(-25),
            updatedAt: now
        )
        let followUp = PlainpostDurableJob(
            id: "follow-up-smart-inbox-pause",
            kind: .aiOperation,
            payloadJSON: payloadJSON,
            state: .paused,
            idempotencyKey: "follow-up-smart-inbox-pause",
            pauseReason: "smart-inbox-follow-up",
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [manual, lowPower, followUp],
                terminalJobs: [],
                anchor: nil,
                totalTerminalCount: 0,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository
        )

        try await viewModel.refreshOperations(now: now)

        XCTAssertEqual(Set(viewModel.operationRows.map(\.id)), [manual.id, lowPower.id])
        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == manual.id })?.resultDetail,
            "Paused by you"
        )
        XCTAssertEqual(
            viewModel.operationRows.first(where: { $0.id == lowPower.id })?.resultDetail,
            "Paused in Low Power Mode"
        )
    }

    @MainActor
    func testDiagnosticsRetainsSafeRetryDetailAndTerminalOperationalContext() async throws {
        let now = Date(timeIntervalSince1970: 1_752_102_600)
        let retry = PlainpostDurableJob(
            id: "retry-connection-limit",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .queued,
            attempt: 2,
            maxAttempts: 5,
            idempotencyKey: "retry-connection-limit",
            errorCode: "IMAP_CONNECTION_LIMIT",
            errorMessage: "server-only detail that must not reach diagnostics",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now.addingTimeInterval(-5)
        )
        let failed = PlainpostDurableJob(
            id: "failed-throttled",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .failed,
            attempt: 5,
            maxAttempts: 5,
            idempotencyKey: "failed-throttled",
            errorCode: "IMAP_THROTTLED",
            errorMessage: "The mail server temporarily limited synchronization. Plainpost will retry.",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [retry],
                terminalJobs: [failed],
                anchor: .init(updatedAt: now, id: failed.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(log: AuditLogService(repository: AuditEntrySnapshotRepository()), jobs: repository)

        try await viewModel.refreshOperationsInBackground(now: now)

        let retryRow = try XCTUnwrap(viewModel.operationRows.first(where: { $0.id == retry.id }))
        XCTAssertEqual(
            retryRow.resultDetail,
            "The mail server has too many simultaneous connections. Plainpost will retry."
        )
        XCTAssertFalse(retryRow.resultDetail?.contains("server-only detail") ?? true)
        XCTAssertEqual(retryRow.attempt, 2)
        XCTAssertEqual(retryRow.maxAttempts, 5)
        let failedRow = try XCTUnwrap(viewModel.operationRows.first(where: { $0.id == failed.id }))
        XCTAssertEqual(failedRow.attempt, 5)
        XCTAssertEqual(failedRow.maxAttempts, 5)
        XCTAssertEqual(failedRow.terminalOccurrenceAt, now)
    }

    @MainActor
    func testDiagnosticsExplainsCompletedSmartInboxWithPartialFailures() async throws {
        let now = Date(timeIntervalSince1970: 1_752_102_600)
        let partial = PlainpostDurableJob(
            id: "partial-smart-inbox",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .completed,
            idempotencyKey: "partial-smart-inbox",
            errorCode: "SMART_INBOX_PARTIAL_FAILURE",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [],
                terminalJobs: [partial],
                anchor: .init(updatedAt: now, id: partial.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository
        )

        try await viewModel.refreshOperations(now: now)

        let row = try XCTUnwrap(viewModel.operationRows.first)
        XCTAssertEqual(row.statusLabel, "Partial")
        XCTAssertTrue(row.isPartialFailure)
        XCTAssertEqual(
            row.resultDetail,
            "Some messages could not be classified. Plainpost will try them again after the messages or AI setup change."
        )
    }

    @MainActor
    func testDiagnosticsBuildsRowsAndResolvesAccountsOffMainActor() async throws {
        let now = Date(timeIntervalSince1970: 1_754_202_400)
        let accountID = AccountID("account-off-main")
        let inboxPayload = String(
            decoding: try JSONEncoder().encode(
                PlainpostInboxSyncInput(
                    accountID: accountID,
                    trigger: .schedule,
                    scope: .incremental
                )
            ),
            as: UTF8.self
        )
        let inboxSync = PlainpostDurableJob(
            id: "off-main-inbox-sync",
            kind: .inboxSync,
            payloadJSON: inboxPayload,
            state: .completed,
            idempotencyKey: "off-main-inbox-sync",
            createdAt: now.addingTimeInterval(-5),
            updatedAt: now
        )
        let lookup = ThreadRecordingAccountLookup(email: "off-main@example.com")
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [],
                terminalJobs: [inboxSync],
                anchor: .init(updatedAt: now, id: inboxSync.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository,
            accountEmails: { [accountID] in [accountID: lookup.resolve()] }
        )

        try await viewModel.refreshOperationsInBackground(now: now)

        XCTAssertEqual(lookup.callCount, 1)
        XCTAssertFalse(lookup.wasResolvedOnMainThread)
        XCTAssertEqual(viewModel.operationRows.first?.accountEmail, "off-main@example.com")
    }

    @MainActor
    func testOlderNavigationWinsWhenAnEarlierRefreshCompletesLater() async throws {
        let now = Date(timeIntervalSince1970: 1_752_102_700)
        func terminal(_ id: String, updatedAt: Date) -> PlainpostDurableJob {
            PlainpostDurableJob(
                id: id,
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                state: .completed,
                idempotencyKey: id,
                createdAt: updatedAt.addingTimeInterval(-1),
                updatedAt: updatedAt
            )
        }
        let firstPageJobs = (0..<20).map { index in
            terminal("page-one-\(index)", updatedAt: now.addingTimeInterval(-Double(index)))
        }
        let secondPageJobs = (0..<20).map { index in
            terminal("page-two-\(index)", updatedAt: now.addingTimeInterval(-Double(index + 20)))
        }
        let anchor = PlainpostDiagnosticsPageAnchor(updatedAt: now, id: firstPageJobs[0].id)
        let repository = DiagnosticsRowsRepository(
            pages: [
                0: .init(
                    activeJobs: [],
                    terminalJobs: firstPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 0,
                    limit: AuditLogViewModel.operationPageSize
                ),
                20: .init(
                    activeJobs: [],
                    terminalJobs: secondPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 20,
                    limit: AuditLogViewModel.operationPageSize
                ),
            ],
            blockers: []
        )
        let viewModel = AuditLogViewModel(log: AuditLogService(repository: AuditEntrySnapshotRepository()), jobs: repository)
        try await viewModel.refreshOperationsInBackground(now: now)
        repository.holdNextPageLoad()

        let staleRefresh = Task {
            try await viewModel.refreshOperationsInBackground(now: now)
        }
        await repository.waitForHeldPageLoad()
        XCTAssertTrue(viewModel.isLoadingOperations)

        try await viewModel.loadOlderOperations(now: now)
        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertEqual(viewModel.operationRows.first?.id, secondPageJobs[0].id)
        XCTAssertFalse(viewModel.isLoadingOperations)

        repository.releaseHeldPageLoad()
        try await staleRefresh.value

        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertEqual(viewModel.operationRows.first?.id, secondPageJobs[0].id)
    }

    @MainActor
    func testAutomaticPollStaysIdleWhileOlderNavigationIsInFlight() async throws {
        let now = Date(timeIntervalSince1970: 1_754_205_100)
        func terminal(_ id: String, updatedAt: Date) -> PlainpostDurableJob {
            PlainpostDurableJob(
                id: id,
                kind: .aiOperation,
                payloadJSON: plainpostTestAIOperationPayloadJSON,
                state: .completed,
                idempotencyKey: id,
                createdAt: updatedAt.addingTimeInterval(-1),
                updatedAt: updatedAt
            )
        }
        let firstPageJobs = (0..<20).map { index in
            terminal("idle-poll-page-one-\(index)", updatedAt: now.addingTimeInterval(-Double(index)))
        }
        let secondPageJobs = (0..<20).map { index in
            terminal("idle-poll-page-two-\(index)", updatedAt: now.addingTimeInterval(-Double(index + 20)))
        }
        let anchor = PlainpostDiagnosticsPageAnchor(updatedAt: now, id: firstPageJobs[0].id)
        let repository = DiagnosticsRowsRepository(
            pages: [
                0: .init(
                    activeJobs: [],
                    terminalJobs: firstPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 0,
                    limit: AuditLogViewModel.operationPageSize
                ),
                20: .init(
                    activeJobs: [],
                    terminalJobs: secondPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 20,
                    limit: AuditLogViewModel.operationPageSize
                ),
            ],
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository
        )
        try await viewModel.refreshOperationsInBackground(now: now)
        repository.holdNextPageLoad()

        let navigation = Task {
            try await viewModel.loadOlderOperations(now: now)
        }
        await repository.waitForHeldPageLoad()
        XCTAssertTrue(viewModel.isLoadingOperations)

        try await viewModel.pollOperationsIfIdle(now: now)

        XCTAssertTrue(viewModel.isLoadingOperations)
        XCTAssertEqual(viewModel.operationPageOffset, 0)

        repository.releaseHeldPageLoad()
        try await navigation.value

        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertEqual(viewModel.operationRows.first?.id, secondPageJobs[0].id)
        XCTAssertFalse(viewModel.isLoadingOperations)
    }

    @MainActor
    func testCancelledAutomaticPollDoesNotSilentlySkipBusyExplicitRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_754_205_200)
        let job = PlainpostDurableJob(
            id: "cancelled-idle-poll",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .completed,
            idempotencyKey: "cancelled-idle-poll",
            createdAt: now.addingTimeInterval(-1),
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [],
                terminalJobs: [job],
                anchor: .init(updatedAt: now, id: job.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository
        )
        repository.holdNextPageLoad()
        let explicitRefresh = Task {
            try await viewModel.refreshOperations(now: now)
        }
        await repository.waitForHeldPageLoad()
        XCTAssertTrue(viewModel.isLoadingOperations)

        let cancelledPoll = Task {
            try await viewModel.pollOperationsIfIdle(now: now)
        }
        cancelledPoll.cancel()
        do {
            try await cancelledPoll.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: idle-only skipping must not consume caller cancellation.
        }

        XCTAssertTrue(viewModel.isLoadingOperations)
        repository.releaseHeldPageLoad()
        try await explicitRefresh.value
        XCTAssertFalse(viewModel.isLoadingOperations)
    }

    @MainActor
    func testOlderNavigationWinsWhenEarlierOffMainRowConstructionCompletesLater() async throws {
        let now = Date(timeIntervalSince1970: 1_754_202_500)
        let accountID = AccountID("account-stale-off-main")
        let payloadJSON = String(
            decoding: try JSONEncoder().encode(
                PlainpostInboxSyncInput(
                    accountID: accountID,
                    trigger: .realTimeSignal,
                    scope: .incremental
                )
            ),
            as: UTF8.self
        )
        func terminal(_ id: String, updatedAt: Date) -> PlainpostDurableJob {
            PlainpostDurableJob(
                id: id,
                kind: .inboxSync,
                payloadJSON: payloadJSON,
                state: .completed,
                idempotencyKey: id,
                createdAt: updatedAt.addingTimeInterval(-1),
                updatedAt: updatedAt
            )
        }
        let firstPageJobs = (0..<20).map { index in
            terminal("stale-off-main-page-one-\(index)", updatedAt: now.addingTimeInterval(-Double(index)))
        }
        let secondPageJobs = (0..<20).map { index in
            terminal("stale-off-main-page-two-\(index)", updatedAt: now.addingTimeInterval(-Double(index + 20)))
        }
        let anchor = PlainpostDiagnosticsPageAnchor(updatedAt: now, id: firstPageJobs[0].id)
        let repository = DiagnosticsRowsRepository(
            pages: [
                0: .init(
                    activeJobs: [],
                    terminalJobs: firstPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 0,
                    limit: AuditLogViewModel.operationPageSize
                ),
                20: .init(
                    activeJobs: [],
                    terminalJobs: secondPageJobs,
                    anchor: anchor,
                    totalTerminalCount: 40,
                    offset: 20,
                    limit: AuditLogViewModel.operationPageSize
                ),
            ],
            blockers: []
        )
        let accountSnapshot = OneShotAccountSnapshotGate(
            values: [accountID: "stale-off-main@example.com"]
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository()),
            jobs: repository,
            accountEmails: { accountSnapshot.snapshot() }
        )
        try await viewModel.refreshOperationsInBackground(now: now)
        accountSnapshot.holdNextSnapshot()

        let staleRefresh = Task {
            try await viewModel.refreshOperationsInBackground(now: now)
        }
        await accountSnapshot.waitForHeldSnapshot()
        XCTAssertTrue(viewModel.isLoadingOperations)

        try await viewModel.loadOlderOperations(now: now)
        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertEqual(viewModel.operationRows.first?.id, secondPageJobs[0].id)
        XCTAssertEqual(viewModel.operationRows.first?.accountEmail, "stale-off-main@example.com")
        XCTAssertFalse(viewModel.isLoadingOperations)

        accountSnapshot.releaseHeldSnapshot()
        try await staleRefresh.value

        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertEqual(viewModel.operationRows.first?.id, secondPageJobs[0].id)
        XCTAssertFalse(viewModel.isLoadingOperations)
    }

    @MainActor
    func testRefreshBoundsLargeAuditHistoryToNewestEntries() async throws {
        let entries = (1...250).map { index in
            AuditEntry(
                id: "aud_\(index)",
                actorID: "local-user",
                action: "category.change",
                targetType: "message",
                targetID: "msg_\(index)",
                result: "ok"
            )
        }
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository(auditEntries: entries))
        )

        try await viewModel.refresh()

        XCTAssertEqual(viewModel.rows.count, 200)
        XCTAssertEqual(viewModel.rows.first?.id, "aud_250")
        XCTAssertEqual(viewModel.rows.last?.id, "aud_51")
        XCTAssertEqual(viewModel.statusMessage, "Showing latest 200 audit events")
    }

    @MainActor
    func testRefreshLoadsAuditRowsOffMainActor() async throws {
        let log = ThreadRecordingAuditLog(
            rows: [
                AuditLogRowModel(
                    id: "aud_off_main",
                    actorID: "local-user",
                    action: "message.read",
                    targetSummary: "message msg_1",
                    result: "ok"
                )
            ]
        )
        let viewModel = AuditLogViewModel(log: log)

        try await viewModel.refresh()

        XCTAssertEqual(log.callCount, 1)
        XCTAssertFalse(log.wasReadOnMainThread)
        XCTAssertEqual(viewModel.rows.map(\.id), ["aud_off_main"])
    }

    @MainActor
    func testNewerFullRefreshOwnsAuditOperationsAndLoadingWhileOlderAuditFinishes() async throws {
        let now = Date(timeIntervalSince1970: 1_754_205_000)
        let initialAudit = AuditLogRowModel(
            id: "audit-initial",
            actorID: "initial",
            action: "initial",
            targetSummary: "initial",
            result: "ok"
        )
        let olderAudit = AuditLogRowModel(
            id: "audit-older",
            actorID: "older",
            action: "older",
            targetSummary: "older",
            result: "ok"
        )
        let newerAudit = AuditLogRowModel(
            id: "audit-newer",
            actorID: "newer",
            action: "newer",
            targetSummary: "newer",
            result: "ok"
        )
        let initialOperation = OperationActivityRowModel(
            id: "operation-initial",
            title: "Initial",
            state: .completed,
            phase: "Completed",
            detail: nil,
            providerID: nil,
            modelID: nil,
            accountEmail: nil,
            resultDetail: nil,
            current: 0,
            total: nil,
            createdAt: now,
            updatedAt: now
        )
        let newerJob = PlainpostDurableJob(
            id: "operation-newer",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .completed,
            idempotencyKey: "operation-newer",
            createdAt: now,
            updatedAt: now
        )
        let olderJob = PlainpostDurableJob(
            id: "operation-older",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .completed,
            idempotencyKey: "operation-older",
            createdAt: now.addingTimeInterval(-1),
            updatedAt: now.addingTimeInterval(-1)
        )
        let log = SequencedAuditLog(rowsInCallOrder: [[olderAudit], [newerAudit]], holdFirst: true)
        let repository = DiagnosticsRowsRepository(
            pagesInCallOrder: [
                .init(
                    activeJobs: [],
                    terminalJobs: [newerJob],
                    anchor: .init(updatedAt: now, id: newerJob.id),
                    totalTerminalCount: 1,
                    offset: 0,
                    limit: AuditLogViewModel.operationPageSize
                ),
                .init(
                    activeJobs: [],
                    terminalJobs: [olderJob],
                    anchor: .init(updatedAt: now.addingTimeInterval(-1), id: olderJob.id),
                    totalTerminalCount: 1,
                    offset: 0,
                    limit: AuditLogViewModel.operationPageSize
                ),
            ],
            blockers: []
        )
        repository.holdNextPageLoad()
        let viewModel = AuditLogViewModel(
            log: log,
            jobs: repository,
            rows: [initialAudit],
            operationRows: [initialOperation]
        )

        let olderRefresh = Task { try await viewModel.refresh() }
        await log.waitForHeldFirstRead()
        let newerRefresh = Task { try await viewModel.refresh() }
        await repository.waitForHeldPageLoad()
        log.releaseHeldFirstRead()
        try await olderRefresh.value

        XCTAssertTrue(viewModel.isLoadingOperations)
        XCTAssertEqual(viewModel.rows.map(\.id), ["audit-initial"])
        XCTAssertEqual(viewModel.operationRows.map(\.id), ["operation-initial"])

        repository.releaseHeldPageLoad()
        try await newerRefresh.value

        XCTAssertFalse(viewModel.isLoadingOperations)
        XCTAssertEqual(viewModel.rows.map(\.id), ["audit-newer"])
        XCTAssertEqual(viewModel.operationRows.map(\.id), ["operation-newer"])
    }

    @MainActor
    func testCancellingFullRefreshDuringAuditLoadLeavesStateAndLoadingOwned() async throws {
        let now = Date(timeIntervalSince1970: 1_754_205_100)
        let initialAudit = AuditLogRowModel(
            id: "audit-cancel-audit-initial",
            actorID: "initial",
            action: "initial",
            targetSummary: "initial",
            result: "ok"
        )
        let replacementAudit = AuditLogRowModel(
            id: "audit-cancel-audit-replacement",
            actorID: "replacement",
            action: "replacement",
            targetSummary: "replacement",
            result: "ok"
        )
        let initialOperation = OperationActivityRowModel(
            id: "operation-cancel-audit-initial",
            title: "Initial",
            state: .completed,
            phase: "Completed",
            detail: nil,
            providerID: nil,
            modelID: nil,
            accountEmail: nil,
            resultDetail: nil,
            current: 0,
            total: nil,
            createdAt: now,
            updatedAt: now
        )
        let replacementJob = PlainpostDurableJob(
            id: "operation-cancel-audit-replacement",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .completed,
            idempotencyKey: "operation-cancel-audit-replacement",
            createdAt: now,
            updatedAt: now
        )
        let log = SequencedAuditLog(rowsInCallOrder: [[replacementAudit]], holdFirst: true)
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [],
                terminalJobs: [replacementJob],
                anchor: .init(updatedAt: now, id: replacementJob.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        let viewModel = AuditLogViewModel(
            log: log,
            jobs: repository,
            rows: [initialAudit],
            operationRows: [initialOperation]
        )

        let refresh = Task { try await viewModel.refresh() }
        await log.waitForHeldFirstRead()
        XCTAssertTrue(viewModel.isLoadingOperations)
        refresh.cancel()
        log.releaseHeldFirstRead()

        do {
            try await refresh.value
            XCTFail("Expected full refresh cancellation during audit loading.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(viewModel.isLoadingOperations)
        XCTAssertEqual(viewModel.rows.map(\.id), ["audit-cancel-audit-initial"])
        XCTAssertEqual(viewModel.operationRows.map(\.id), ["operation-cancel-audit-initial"])
    }

    @MainActor
    func testCancellingFullRefreshDuringOperationLoadAppliesNoPartialSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_754_205_200)
        let initialAudit = AuditLogRowModel(
            id: "audit-cancel-operation-initial",
            actorID: "initial",
            action: "initial",
            targetSummary: "initial",
            result: "ok"
        )
        let replacementAudit = AuditLogRowModel(
            id: "audit-cancel-operation-replacement",
            actorID: "replacement",
            action: "replacement",
            targetSummary: "replacement",
            result: "ok"
        )
        let initialOperation = OperationActivityRowModel(
            id: "operation-cancel-operation-initial",
            title: "Initial",
            state: .completed,
            phase: "Completed",
            detail: nil,
            providerID: nil,
            modelID: nil,
            accountEmail: nil,
            resultDetail: nil,
            current: 0,
            total: nil,
            createdAt: now,
            updatedAt: now
        )
        let replacementJob = PlainpostDurableJob(
            id: "operation-cancel-operation-replacement",
            kind: .inboxSync,
            payloadJSON: plainpostTestInboxSyncPayloadJSON,
            state: .completed,
            idempotencyKey: "operation-cancel-operation-replacement",
            createdAt: now,
            updatedAt: now
        )
        let repository = DiagnosticsRowsRepository(
            page: .init(
                activeJobs: [],
                terminalJobs: [replacementJob],
                anchor: .init(updatedAt: now, id: replacementJob.id),
                totalTerminalCount: 1,
                offset: 0,
                limit: AuditLogViewModel.operationPageSize
            ),
            blockers: []
        )
        repository.holdNextPageLoad()
        let viewModel = AuditLogViewModel(
            log: ThreadRecordingAuditLog(rows: [replacementAudit]),
            jobs: repository,
            rows: [initialAudit],
            operationRows: [initialOperation]
        )

        let refresh = Task { try await viewModel.refresh() }
        await repository.waitForHeldPageLoad()
        XCTAssertTrue(viewModel.isLoadingOperations)
        refresh.cancel()
        repository.releaseHeldPageLoad()

        do {
            try await refresh.value
            XCTFail("Expected full refresh cancellation during operation loading.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(viewModel.isLoadingOperations)
        XCTAssertEqual(viewModel.rows.map(\.id), ["audit-cancel-operation-initial"])
        XCTAssertEqual(viewModel.operationRows.map(\.id), ["operation-cancel-operation-initial"])
    }

    @MainActor
    func testDiagnosticsMapsDurableAIProgress() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-progress-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let input = PlainpostAIOperationInput(
            operation: .recategorizeInbox,
            recordID: "",
            providerID: "foundation"
        )
        let payload = try JSONEncoder().encode(input)
        let queued = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                idempotencyKey: "diagnostics-progress"
            )
        )
        let running = try XCTUnwrap(store.claimNextJob())
        let leaseToken = try XCTUnwrap(running.leaseToken)
        try store.updateJobProgress(
            id: queued.id,
            leaseToken: leaseToken,
            progress: .init(current: 42, total: 100, phase: "classifying", label: "Smart Inbox")
        )

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperations()

        let activity = try XCTUnwrap(viewModel.operationRows.first)
        XCTAssertEqual(activity.title, "Organizing Smart Inbox")
        XCTAssertEqual(activity.phase, "Classifying")
        XCTAssertEqual(activity.providerID, "foundation")
        XCTAssertEqual(activity.modelID, "apple-foundation-system")
        XCTAssertEqual(activity.progressFraction, 0.42)
        XCTAssertTrue(activity.isActive)
    }

    @MainActor
    func testDiagnosticsRetainsTerminalWorkForExactlyTheRecentHour() {
        let now = Date()
        let recent = PlainpostDurableJob(
            id: "recent",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .completed,
            idempotencyKey: "recent",
            updatedAt: now.addingTimeInterval(-3_599)
        )
        let expired = PlainpostDurableJob(
            id: "expired",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .failed,
            idempotencyKey: "expired",
            updatedAt: now.addingTimeInterval(-3_601)
        )
        let queued = PlainpostDurableJob(
            id: "queued",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .queued,
            idempotencyKey: "queued",
            updatedAt: now.addingTimeInterval(-7_200)
        )

        XCTAssertEqual(
            AuditLogViewModel.retainedJobs([recent, expired, queued], now: now).map(\.id),
            ["recent", "queued"]
        )
    }

    @MainActor
    func testDiagnosticsKeepsOlderActiveWorkAlongsideTwentyRecentJobs() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-active-jobs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let diagnosticThread = MailThread(
            id: ThreadID("diagnostics-terminal"),
            accountID: PlainpostFixtures.personalAccount.id,
            subjectNormalized: "diagnostics",
            participantEmails: [PlainpostFixtures.personalAccount.email]
        )
        try store.cacheThread(diagnosticThread)

        let activePayloadJSON = String(
            decoding: try JSONEncoder().encode(
                PlainpostInboxSyncInput(accountID: PlainpostFixtures.personalAccount.id, trigger: .manual)
            ),
            as: UTF8.self
        )
        _ = try store.enqueueJob(
            PlainpostJobRequest(kind: .inboxSync, payloadJSON: activePayloadJSON, idempotencyKey: "older-active")
        )
        let active = try XCTUnwrap(store.claimNextJob())
        XCTAssertEqual(active.state, .running)

        let payloadJSON = String(
            decoding: try JSONEncoder().encode(
                PlainpostAIOperationInput(
                    operation: .summarizeThread,
                    recordID: diagnosticThread.id.rawValue,
                    accountID: PlainpostFixtures.personalAccount.id,
                    providerID: "deterministic"
                )
            ),
            as: UTF8.self
        )
        for index in 0..<60 {
            _ = try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .aiOperation,
                    payloadJSON: payloadJSON,
                    idempotencyKey: "newer-terminal-\(index)"
                )
            )
            let claimed = try XCTUnwrap(store.claimNextJob())
            let leaseToken = try XCTUnwrap(claimed.leaseToken)
            try store.completeJob(id: claimed.id, leaseToken: leaseToken, resultArtifactID: nil)
        }

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperationsInBackground()

        XCTAssertEqual(viewModel.operationRows.filter(\.isActive).map(\.id), [active.id])
        XCTAssertEqual(viewModel.operationRows.filter { !$0.isActive }.count, 20)
    }

    @MainActor
    func testDiagnosticsNavigatesTwentyEventPages() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-pagination-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()

        for index in 0..<45 {
            _ = try store.enqueueJob(
                PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "paginated-terminal-\(index)")
            )
            let claimed = try XCTUnwrap(store.claimNextJob())
            try store.completeJob(id: claimed.id, leaseToken: try XCTUnwrap(claimed.leaseToken), resultArtifactID: nil)
        }

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperationsInBackground()
        let firstPageIDs = viewModel.operationRows.filter { !$0.isActive }.map(\.id)
        XCTAssertEqual(firstPageIDs.count, 20)
        XCTAssertEqual(viewModel.operationPageOffset, 0)
        XCTAssertEqual(viewModel.operationTotalCount, 45)
        XCTAssertEqual(viewModel.operationRangeLabel, "1–20 of 45")
        XCTAssertTrue(viewModel.canLoadOlderOperations)
        XCTAssertFalse(viewModel.canLoadNewerOperations)

        try await viewModel.loadOlderOperations()
        XCTAssertEqual(viewModel.operationRows.filter { !$0.isActive }.count, 20)
        XCTAssertEqual(viewModel.operationPageOffset, 20)
        XCTAssertNotEqual(viewModel.operationRows.filter { !$0.isActive }.map(\.id), firstPageIDs)
        XCTAssertTrue(viewModel.canLoadNewerOperations)

        _ = try store.enqueueJob(
            PlainpostJobRequest(kind: .aiOperation, payloadJSON: plainpostTestAIOperationPayloadJSON, idempotencyKey: "paginated-newer")
        )
        let newer = try XCTUnwrap(store.claimNextJob())
        try store.completeJob(id: newer.id, leaseToken: try XCTUnwrap(newer.leaseToken), resultArtifactID: nil)
        try await viewModel.loadNewerOperations()
        XCTAssertEqual(viewModel.operationPageOffset, 0)
        XCTAssertEqual(viewModel.operationRows.filter { !$0.isActive }.map(\.id), firstPageIDs)

        try await viewModel.loadOlderOperations()
        try await viewModel.loadOlderOperations()
        XCTAssertEqual(viewModel.operationPageOffset, 40)
        XCTAssertEqual(viewModel.operationRows.filter { !$0.isActive }.count, 5)
        XCTAssertEqual(viewModel.operationRangeLabel, "41–45 of 45")
        XCTAssertFalse(viewModel.canLoadOlderOperations)

        try store.pruneTerminalJobs(before: Date().addingTimeInterval(1))
        try await viewModel.refreshOperations()
        XCTAssertEqual(viewModel.operationPageOffset, 0)
        XCTAssertEqual(viewModel.operationTotalCount, 0)
        XCTAssertEqual(viewModel.operationRangeLabel, "0 of 0")
        XCTAssertFalse(viewModel.canLoadNewerOperations)
    }

    @MainActor
    func testDiagnosticsPaginationLabelsAndNavigation() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-pagination-labels-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let now = Date(timeIntervalSince1970: 1_754_022_400)

        for index in 0..<42 {
            _ = try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .aiOperation,
                    payloadJSON: plainpostTestAIOperationPayloadJSON,
                    idempotencyKey: "pagination-labels-\(index)"
                )
            )
            let claimed = try XCTUnwrap(store.claimNextJob())
            try store.completeJob(
                id: claimed.id,
                leaseToken: try XCTUnwrap(claimed.leaseToken),
                resultArtifactID: nil
            )
        }

        let viewModel = AuditLogViewModel(log: AuditLogService(repository: store), jobs: store)
        try await viewModel.refreshOperationsInBackground(now: now)
        XCTAssertEqual(viewModel.operationRangeLabel, "1–20 of 42")
        XCTAssertFalse(viewModel.canLoadNewerOperations)
        XCTAssertTrue(viewModel.canLoadOlderOperations)

        try await viewModel.loadOlderOperations(now: now)
        XCTAssertEqual(viewModel.operationRangeLabel, "21–40 of 42")
        XCTAssertTrue(viewModel.canLoadNewerOperations)
        XCTAssertTrue(viewModel.canLoadOlderOperations)

        try await viewModel.loadOlderOperations(now: now)
        XCTAssertEqual(viewModel.operationRangeLabel, "41–42 of 42")
        XCTAssertFalse(viewModel.canLoadOlderOperations)

        try await viewModel.loadNewerOperations(now: now)
        XCTAssertEqual(viewModel.operationRangeLabel, "21–40 of 42")
        XCTAssertTrue(viewModel.canLoadNewerOperations)
        XCTAssertTrue(viewModel.canLoadOlderOperations)
    }

    @MainActor
    func testRefreshMapsAuditEntriesNewestFirstWithoutSecrets() async throws {
        let store = InMemoryMailStore(
            auditEntries: [
                AuditEntry(
                    id: "aud_1",
                    actorID: "codex",
                    action: "draft.create",
                    targetType: "draft",
                    targetID: "drf_1",
                    result: "ok"
                ),
                AuditEntry(
                    id: "aud_2",
                    actorID: "local-user",
                    action: "send.sent",
                    targetType: "send_request",
                    targetID: "srq_1",
                    result: "ok"
                )
            ]
        )
        let viewModel = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository(auditEntries: store.auditEntries))
        )

        try await viewModel.refresh()

        XCTAssertEqual(viewModel.rows.map(\.id), ["aud_2", "aud_1"])
        XCTAssertEqual(viewModel.rows[0].actorID, "local-user")
        XCTAssertEqual(viewModel.rows[0].action, "send.sent")
        XCTAssertEqual(viewModel.rows[0].targetSummary, "send_request srq_1")
        XCTAssertFalse(viewModel.rows.description.contains("secret"))
    }

    @MainActor
    func testAuditLogShowsAgentRequestAndApprovalEventsAfterLocalSMTPDelivery() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "Audit E2E"
        )

        let approval = ApprovalQueueViewModel(
            queue: ApprovalQueueService(
                store: store,
                smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
            )
        )
        try await approval.approve(
            requestID: request.id.rawValue,
            username: "me@example.com",
            password: "secret"
        )

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)

        let audit = AuditLogViewModel(
            log: AuditLogService(repository: AuditEntrySnapshotRepository(auditEntries: store.auditEntries))
        )
        try await audit.refresh()

        XCTAssertEqual(
            audit.rows.map(\.action),
            ["send.sent", "message.sent_copy", "send.sending", "send.approved", "send.request", "draft.create"]
        )
        XCTAssertEqual(audit.rows.first?.actorID, "local-user")
        XCTAssertEqual(audit.rows.last?.actorID, "codex")
        XCTAssertTrue(audit.rows.allSatisfy { !$0.targetSummary.contains("secret") })
    }
}

private struct AuditEntrySnapshotRepository: AuditRepository, Sendable {
    let auditEntries: [AuditEntry]

    init(auditEntries: [AuditEntry] = []) {
        self.auditEntries = auditEntries
    }
}

private func requireSendable<Value: Sendable>(_: Value) {}

private final class ThreadRecordingAccountLookup: @unchecked Sendable {
    private let email: String
    private let lock = NSLock()
    private var calls = 0
    private var resolvedOnMainThread = false

    init(email: String) {
        self.email = email
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var wasResolvedOnMainThread: Bool {
        lock.withLock { resolvedOnMainThread }
    }

    func resolve() -> String {
        lock.withLock {
            calls += 1
            resolvedOnMainThread = resolvedOnMainThread || Thread.isMainThread
        }
        return email
    }
}

private final class ThreadRecordingAuditLog: AuditLogHandling, @unchecked Sendable {
    private let values: [AuditLogRowModel]
    private let lock = NSLock()
    private var calls = 0
    private var readOnMainThread = false

    init(rows: [AuditLogRowModel]) {
        values = rows
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var wasReadOnMainThread: Bool {
        lock.withLock { readOnMainThread }
    }

    func rows() throws -> [AuditLogRowModel] {
        lock.withLock {
            calls += 1
            readOnMainThread = readOnMainThread || Thread.isMainThread
        }
        return values
    }
}

private final class SequencedAuditLog: AuditLogHandling, @unchecked Sendable {
    private let rowsInCallOrder: [[AuditLogRowModel]]
    private let holdFirst: Bool
    private let lock = NSLock()
    private let firstReadRelease = DispatchSemaphore(value: 0)
    private var callIndex = 0
    private var firstReadHeld = false
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(rowsInCallOrder: [[AuditLogRowModel]], holdFirst: Bool) {
        self.rowsInCallOrder = rowsInCallOrder
        self.holdFirst = holdFirst
    }

    func waitForHeldFirstRead() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstReadHeld {
                lock.unlock()
                continuation.resume()
            } else {
                firstReadWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseHeldFirstRead() {
        firstReadRelease.signal()
    }

    func rows() throws -> [AuditLogRowModel] {
        lock.lock()
        let index = callIndex
        callIndex += 1
        let shouldHold = holdFirst && index == 0
        let waiters: [CheckedContinuation<Void, Never>]
        if shouldHold {
            firstReadHeld = true
            waiters = firstReadWaiters
            firstReadWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
        if shouldHold {
            guard firstReadRelease.wait(timeout: .now() + 3) == .success else {
                throw DiagnosticsRowsRepositoryError.unsupported
            }
        }
        guard !rowsInCallOrder.isEmpty else { return [] }
        return rowsInCallOrder[min(index, rowsInCallOrder.count - 1)]
    }
}

private final class OneShotAccountSnapshotGate: @unchecked Sendable {
    private let values: [AccountID: String]
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var shouldHoldNextSnapshot = false
    private var hasHeldSnapshot = false
    private var heldSnapshotWaiters: [CheckedContinuation<Void, Never>] = []

    init(values: [AccountID: String]) {
        self.values = values
    }

    func holdNextSnapshot() {
        lock.withLock { shouldHoldNextSnapshot = true }
    }

    func waitForHeldSnapshot() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasHeldSnapshot {
                lock.unlock()
                continuation.resume()
            } else {
                heldSnapshotWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseHeldSnapshot() {
        release.signal()
    }

    func snapshot() -> [AccountID: String] {
        let shouldHold = lock.withLock { () -> Bool in
            guard shouldHoldNextSnapshot else { return false }
            shouldHoldNextSnapshot = false
            return true
        }
        if shouldHold {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                hasHeldSnapshot = true
                let captured = heldSnapshotWaiters
                heldSnapshotWaiters.removeAll()
                return captured
            }
            waiters.forEach { $0.resume() }
            _ = release.wait(timeout: .now() + 3)
        }
        return values
    }
}

private enum DiagnosticsRowsRepositoryError: Error {
    case unsupported
}

private final class DiagnosticsRowsRepository: DurableJobRepository, @unchecked Sendable {
    private let pages: [Int: PlainpostDiagnosticsJobPage]
    private let pagesInCallOrder: [PlainpostDiagnosticsJobPage]
    private let blockers: [PlainpostSyncBlocker]
    private let pageLoadLock = NSLock()
    private let heldPageLoadRelease = DispatchSemaphore(value: 0)
    private var shouldHoldNextPageLoad = false
    private var hasHeldPageLoadStarted = false
    private var heldPageLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var pageCallIndex = 0

    init(page: PlainpostDiagnosticsJobPage, blockers: [PlainpostSyncBlocker]) {
        pages = [page.offset: page]
        pagesInCallOrder = []
        self.blockers = blockers
    }

    init(pages: [Int: PlainpostDiagnosticsJobPage], blockers: [PlainpostSyncBlocker]) {
        self.pages = pages
        pagesInCallOrder = []
        self.blockers = blockers
    }

    init(pagesInCallOrder: [PlainpostDiagnosticsJobPage], blockers: [PlainpostSyncBlocker]) {
        pages = [:]
        self.pagesInCallOrder = pagesInCallOrder
        self.blockers = blockers
    }

    func holdNextPageLoad() {
        pageLoadLock.lock()
        shouldHoldNextPageLoad = true
        pageLoadLock.unlock()
    }

    func waitForHeldPageLoad() async {
        await withCheckedContinuation { continuation in
            pageLoadLock.lock()
            if hasHeldPageLoadStarted {
                pageLoadLock.unlock()
                continuation.resume()
            } else {
                heldPageLoadWaiters.append(continuation)
                pageLoadLock.unlock()
            }
        }
    }

    func releaseHeldPageLoad() {
        heldPageLoadRelease.signal()
    }

    func enqueueJob(_ request: PlainpostJobRequest) throws -> PlainpostDurableJob {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func job(id: String) throws -> PlainpostDurableJob {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func job(idempotencyKey: String) throws -> PlainpostDurableJob? {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func jobs(limit: Int) throws -> [PlainpostDurableJob] {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func diagnosticsJobs(now: Date, recentTerminalLimit: Int) throws -> [PlainpostDurableJob] {
        let page = try page(for: 0)
        return page.activeJobs + page.terminalJobs
    }

    func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int
    ) throws -> PlainpostDiagnosticsJobPage {
        pageLoadLock.lock()
        let shouldHold = shouldHoldNextPageLoad
        shouldHoldNextPageLoad = false
        let waiters = shouldHold ? heldPageLoadWaiters : []
        let page: PlainpostDiagnosticsJobPage?
        if pagesInCallOrder.isEmpty {
            page = pages[offset] ?? pages[0]
        } else {
            page = pagesInCallOrder[min(pageCallIndex, pagesInCallOrder.count - 1)]
            pageCallIndex += 1
        }
        if shouldHold {
            hasHeldPageLoadStarted = true
            heldPageLoadWaiters.removeAll()
        }
        pageLoadLock.unlock()
        if shouldHold {
            waiters.forEach { $0.resume() }
            guard heldPageLoadRelease.wait(timeout: .now() + 1) == .success else {
                throw DiagnosticsRowsRepositoryError.unsupported
            }
        }
        guard let page else {
            throw DiagnosticsRowsRepositoryError.unsupported
        }
        return page
    }

    func smartInboxSyncBlockers() throws -> [PlainpostSyncBlocker] {
        blockers
    }

    func claimNextJob(now: Date, leaseDuration: TimeInterval) throws -> PlainpostDurableJob? {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func nextPendingJob(
        higherPriorityThan priority: Int,
        now: Date,
        allowedKinds: Set<PlainpostOperationKind>?
    ) throws -> PlainpostDurableJob? {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func pauseJob(
        id: String,
        leaseToken: String,
        reason: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func requestJobPause(id: String) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func acknowledgeJobPause(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func resumeUserPausedJob(id: String, now: Date) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func acknowledgeJobCancellation(id: String, leaseToken: String) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func updateJobProgress(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func renewJobLease(
        id: String,
        leaseToken: String,
        now: Date,
        leaseDuration: TimeInterval
    ) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func completeJob(id: String, leaseToken: String, resultArtifactID: String?) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func failJob(
        id: String,
        leaseToken: String,
        code: String,
        message: String,
        retryAt: Date?
    ) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func markDeliveryUncertain(id: String, leaseToken: String, message: String) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func requestJobCancellation(id: String) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    func pruneTerminalJobs(before: Date) throws {
        throw DiagnosticsRowsRepositoryError.unsupported
    }

    private func page(for offset: Int) throws -> PlainpostDiagnosticsJobPage {
        guard let page = pages[offset] ?? pages[0] else {
            throw DiagnosticsRowsRepositoryError.unsupported
        }
        return page
    }
}
