import Foundation
import XCTest
import PlainpostCore
import PlainpostDB
import PlainpostAccounts
import PlainpostLocalServer
import PlainpostOperations
import PlainpostOperationRuntime
import PlainpostSecrets
@testable import PlainpostIOSRuntime
import PlainpostRuntimeTestSupport
import PlainpostTestSupport
@testable import PlainpostUI

final class IOSLocalMailRuntimeDependenciesTests: XCTestCase {
    func testCredentialRepairRestoresBothPreviousSecretsWhenSMTPWriteFails() async throws {
        let accountID = AccountID("repair")
        let imapKey = MailCredentialKeys.imapPassword(accountID)
        let smtpKey = MailCredentialKeys.smtpPassword(accountID)
        let credentials = RepairFaultingCredentialVault(initial: [
            imapKey: Data("old-imap".utf8),
            smtpKey: Data("old-smtp".utf8),
        ])
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: credentials)

        do {
            try await dependencies.saveAccountCredentials(
                accountID: accountID, imapPassword: "new-imap", smtpPassword: "new-smtp"
            )
            XCTFail("The injected SMTP write should fail")
        } catch RepairVaultError.smtpWrite {
            // The original write error remains visible to the caller.
        }

        let restoredIMAP = try await credentials.load(imapKey)
        let restoredSMTP = try await credentials.load(smtpKey)
        XCTAssertEqual(restoredIMAP, Data("old-imap".utf8))
        XCTAssertEqual(restoredSMTP, Data("old-smtp".utf8))
    }

    @MainActor func testReopenedRuntimeSurfacesPersistedUncertainDirectSend() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-uncertain-reopen-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let owner = account("uncertain")
        let direct = try AccountMailSource(
            accountID: owner.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: owner, inbox: inbox(for: owner), source: direct)
        let proposed = Draft(
            id: DraftID("drf_uncertain_reopen"), accountID: owner.id, from: owner.email,
            to: [EmailAddress("friend@example.com")], cc: [], bcc: [], subject: "Review",
            bodyPlain: "Body", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil
        )
        let draft = try store.createDraft(proposed, actor: Actor(
            id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser
        ))
        _ = try store.reserveDirectSend(draftID: draft.id, contentHash: draft.contentHash, accountID: owner.id)
        try store.markDirectSendSubmitting(draftID: draft.id, contentHash: draft.contentHash)
        try store.markDirectSendUncertain(draftID: draft.id, contentHash: draft.contentHash)
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: owner.id,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
        ))
        XCTAssertTrue(runtime.hasUncertainSend)
        await runtime.shutdown()
    }
    @MainActor func testProductionIOSSetupPublishesDirectSourceBeforeRuntimeReopen() async throws {
        let imap = LocalIMAPServer(username: "me@example.com", password: "imap-secret", message: PlainpostFixtures.aliceMessage)
        let smtp = LocalSMTPServer(username: "me@example.com", password: "smtp-secret")
        try await imap.start()
        try await smtp.start()
        defer { imap.stop(); smtp.stop() }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-setup-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        let credentials = InMemoryCredentialVault()
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: credentials)
        let handler = dependencies.makeAccountSetupHandler(store: store, inboxSyncOrchestrator: SuccessfulAccountInboxSyncer())
        let result = try await handler.addAccount(
            AccountSetupRequest(
                displayName: "Personal", email: EmailAddress("me@example.com"),
                imapHost: "127.0.0.1", imapPort: imap.port,
                smtpHost: "127.0.0.1", smtpPort: smtp.port,
                imapPassword: "imap-secret", smtpPassword: "smtp-secret"
            ), progress: { _ in }
        )

        try store.requireDirectMailSource(accountID: result.account.id)
        let reopened = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: result.account.id, runtimeDependencies: dependencies
        ))
        let composer = reopened.makeComposerViewModel()
        composer.to = "friend@example.com"
        composer.subject = "Ready"
        composer.bodyMarkdown = "Hello"
        try await composer.saveDraft()
        let draftID = try XCTUnwrap(composer.lastDraftID)
        composer.bodyMarkdown = "Hello again"
        try await composer.saveDraft()
        XCTAssertEqual(composer.lastDraftID, draftID, "editing must replace the same draft")
        XCTAssertEqual(try reopened.store.draft(id: DraftID(draftID)).bodyMarkdown, "Hello again")
        try await composer.discardDraft()
        XCTAssertThrowsError(try reopened.store.draft(id: DraftID(draftID)))
        await reopened.shutdown()
    }
    @MainActor func testProductionConfigurationAssemblesLocalRuntimeWithoutServiceMonitor() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-local-runtime-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let credentials = InMemoryCredentialVault()
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: credentials)
        let service = RuntimeServiceClientFake()
        let seededStore = try SQLiteMailStore(path: url.path)
        try seededStore.migrate()
        let existing = account("existing")
        let direct = try AccountMailSource(
            accountID: existing.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try seededStore.cacheAccountSetup(account: existing, inbox: inbox(for: existing), source: direct)
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: url, serviceClient: service, selectedAccountID: existing.id, runtimeDependencies: dependencies
        )
        let runtime = try PlainpostAppRuntime(configuration: configuration)
        let store = runtime.store
        let hasMonitor = runtime.hasServiceFailureMonitor
        let setup = dependencies.makeAccountSetupHandler(
            store: store, inboxSyncOrchestrator: NoopAccountInboxSyncer()
        )
        let sender = try dependencies.makeDirectComposerSender(store: store)
        let actions = dependencies.makeInboxMailActionHandler(
            store: store, mailboxFlagScheduler: NoopMailboxFlagScheduler()
        )

        XCTAssertFalse(hasMonitor)
        XCTAssertTrue(setup is IOSDirectGoogleAccountSetupHandler)
        XCTAssertTrue(sender is IOSDirectComposerSender)
        XCTAssertTrue(actions is IOSDirectInboxActionHandler)
        let accountSetup = runtime.makeAccountSetupViewModel()
        XCTAssertEqual(accountSetup.account?.id, existing.id)
        await accountSetup.deleteSelectedAccount()
        XCTAssertTrue(store.accounts.isEmpty)
        let calls = await service.snapshot()
        XCTAssertEqual(calls.statusCallCount, 0)
        XCTAssertEqual(calls.lockCallCount, 0)
        XCTAssertTrue(calls.unlockReasons.isEmpty)
        XCTAssertTrue(calls.foregroundOperationKinds.isEmpty)
    }

    func testLegacyIOSWorkerFactoryDoesNotClaimWithoutSelectedAccount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-source-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
        let runtime = dependencies.makeOperationRuntime(store: store, allowedJobKinds: [.inboxSync])

        let legacy = account("legacy")
        try store.cacheAccountSetup(account: legacy, inbox: inbox(for: legacy))
        let legacyJob = try enqueueSync(for: legacy.id, in: store)
        let firstClaim = try await runtime.processNextJob()
        XCTAssertNil(firstClaim)
        XCTAssertEqual(try store.job(id: legacyJob.id).state, .queued)

        let nodeAccount = account("node")
        let direct = try AccountMailSource(
            accountID: nodeAccount.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: nodeAccount, inbox: inbox(for: nodeAccount), source: direct)
        let node = direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "node@example.com"
        )
        try store.replaceMailSource(node, expectedGeneration: 1)
        let nodeJob = try enqueueSync(for: nodeAccount.id, in: store)
        let secondClaim = try await runtime.processNextJob()
        XCTAssertNil(secondClaim)
        XCTAssertEqual(try store.job(id: legacyJob.id).state, .queued)
        XCTAssertEqual(try store.job(id: nodeJob.id).state, .queued)
    }

    func testLocalRuntimeNeverClaimsApprovedDeliveryBeforeDurableIntentExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-approval-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let draft = try store.createDraft(
            PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor
        )
        let request = try store.requestSend(
            draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Durable approval"
        )
        let input = PlainpostApprovalDecisionInput(
            requestID: request.id, actorID: PlainpostFixtures.guiUser.id
        )
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            maxAttempts: 1, idempotencyKey: "ios-approval-fence"
        ))
        let runtime = IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
            .makeOperationRuntime(store: store, allowedJobKinds: [.approvedDelivery])

        let processed = try await runtime.processNextJob()
        XCTAssertNil(processed)
        XCTAssertEqual(try store.job(id: job.id).state, .queued)
    }

    func testSelectedWorkerWithoutAccountDoesNotFallBackToGlobalClaim() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-worker-unselected-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let input = PlainpostInboxSyncInput(accountID: account.id, trigger: .manual)
        let job = try store.enqueueJob(.init(
            kind: .inboxSync,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: UUID().uuidString
        ))
        let runtime = IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
            .makeOperationRuntime(
                store: store, allowedJobKinds: [.inboxSync],
                selectedDirectAccountID: nil,
                expectedDirectSourceGeneration: nil
            )
        let processed = try await runtime.processNextJob()
        XCTAssertNil(processed)
        XCTAssertEqual(try store.job(id: job.id).state, .queued)
    }

    /// The device-wide iOS worker claims a current-generation job for any Direct account.
    func testUnselectedWorkerClaimsCurrentJobsForEveryDirectAccount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-worker-every-direct-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let direct = account("every-direct")
        try store.cacheAccountSetup(
            account: direct, inbox: inbox(for: direct),
            source: try AccountMailSource(
                accountID: direct.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let generation = try store.mailSource(accountID: direct.id).generation
        let input = PlainpostInboxSyncInput(
            accountID: direct.id, trigger: .manual, expectedDirectSourceGeneration: generation
        )
        let job = try store.enqueueJob(.init(
            kind: .inboxSync,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: UUID().uuidString
        ))
        let runtime = IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
            .makeOperationRuntime(store: store, allowedJobKinds: [.inboxSync])
        _ = try? await runtime.processNextJob()
        XCTAssertNotEqual(try store.job(id: job.id).state, .queued, "the job was claimed")
    }

    func testStrictDirectRuntimeRejectsApprovedDeliveryEvenIfKindIsExplicitlyAllowed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-approval-execution-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let draft = try store.createDraft(
            PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor
        )
        let request = try store.requestSend(
            draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Durable approval"
        )
        let input = PlainpostApprovalDecisionInput(
            requestID: request.id, actorID: PlainpostFixtures.guiUser.id
        )
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            maxAttempts: 1, idempotencyKey: "ios-execution-fence"
        ))
        let runtime = LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.approvedDelivery], requireExplicitDirectSource: true
        )

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Strict direct runtime must reject the delivery job")
        } catch {
            XCTAssertEqual(
                error as? PlainpostError,
                .permissionDenied("Direct delivery requires durable send intent.")
            )
        }
        XCTAssertEqual(try store.job(id: job.id).state, .failed)
    }

    func testDirectInboxActionFailsClosedUntilAccountOwnershipIsAvailable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-action-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let handler = IOSDirectInboxActionHandler(
            store: store, mailboxFlagScheduler: NoopMailboxFlagScheduler(),
            credentials: InMemoryCredentialVault()
        )
        do {
            _ = try await handler.perform(.markRead, messageID: MessageID("unowned"))
            XCTFail("Unowned action must fail closed")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
    }

    func testDirectComposerFailsClosedUntilDurableSendIntentIsAvailable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-send-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let sender = IOSDirectComposerSender(store: store, credentials: InMemoryCredentialVault())
        let draft = Draft(
            id: DraftID("unowned"), accountID: AccountID("unowned"),
            from: EmailAddress("from@example.com"), to: [EmailAddress("to@example.com")],
            cc: [], bcc: [], subject: "Test", bodyPlain: "Message",
            createdBy: "local-user", aiGenerated: false, sourceThreadID: nil
        )
        do {
            _ = try await sender.send(draft: draft)
            XCTFail("Direct send must fail before durable intent exists")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }
    }

    func testLocalAccountDeletionRemovesOnlySelectedAccountAndCredentials() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-delete-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = account("first")
        let second = account("second")
        for account in [first, second] {
            try store.cacheAccountSetup(account: account, inbox: inbox(for: account), source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ))
        }
        let credentials = InMemoryCredentialVault()
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: credentials)
        try await dependencies.saveAccountCredentials(
            accountID: first.id, imapPassword: "first-imap", smtpPassword: "first-smtp"
        )
        try await dependencies.saveAccountCredentials(
            accountID: second.id, imapPassword: "second-imap", smtpPassword: "second-smtp"
        )

        try await dependencies.deleteLocalAccount(accountID: first.id, store: store)

        let firstIMAP = try await credentials.load(MailCredentialKeys.imapPassword(first.id))
        let firstSMTP = try await credentials.load(MailCredentialKeys.smtpPassword(first.id))
        let secondIMAP = try await credentials.load(MailCredentialKeys.imapPassword(second.id))
        XCTAssertEqual(store.accounts.map(\.id), [second.id])
        XCTAssertNil(firstIMAP)
        XCTAssertNil(firstSMTP)
        XCTAssertEqual(secondIMAP, Data("second-imap".utf8))
    }

    @MainActor func testSelectedDirectSettingsHideTheNodeAccountWhichDeletesFromThisDeviceOnly() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-settings-source-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let directAccount = account("direct")
        let nodeAccount = account("node")
        let directSource = try AccountMailSource(
            accountID: directAccount.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: directAccount, inbox: inbox(for: directAccount), source: directSource)
        let credentials = InMemoryCredentialVault()
        let dependencies = IOSLocalMailRuntimeDependencies(credentials: credentials)
        let runtime = try PlainpostAppRuntime(configuration: PlainpostAppRuntimeConfiguration(
            databaseURL: url, selectedAccountID: directAccount.id, runtimeDependencies: dependencies
        ))
        defer { Task { await runtime.shutdown() } }

        // The runtime guard remains in force at construction. Add the Node
        // projection afterward to exercise account-settings boundaries.
        try store.cacheAccountSetup(
            account: nodeAccount, inbox: inbox(for: nodeAccount),
            source: try AccountMailSource(
                accountID: nodeAccount.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let nodeSource = try store.mailSource(accountID: nodeAccount.id).nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: nodeAccount.email.rawValue
        )
        try store.replaceMailSource(nodeSource, expectedGeneration: 1)
        try await dependencies.saveAccountCredentials(
            accountID: nodeAccount.id, imapPassword: "node-imap", smtpPassword: "node-smtp"
        )

        let settings = runtime.makeAccountSetupViewModel()
        XCTAssertEqual(settings.accounts.map(\.id), [directAccount.id])
        settings.selectAccount(id: nodeAccount.id)
        XCTAssertEqual(settings.account?.id, directAccount.id)
        settings.reloadAccounts(selecting: nodeAccount.id)
        XCTAssertEqual(settings.accounts.map(\.id), [directAccount.id])
        XCTAssertEqual(settings.account?.id, directAccount.id)

        let additional = settings.makeAdditionalAccountViewModel()
        additional.displayName = "Conflicting Node"
        additional.email = nodeAccount.email.rawValue
        additional.username = nodeAccount.email.rawValue
        additional.imapHost = "imap.example.com"
        additional.smtpHost = "smtp.example.com"
        additional.imapPassword = "unused-imap"
        additional.smtpPassword = "unused-smtp"
        do {
            try await additional.submit()
            XCTFail("Adding an existing Node identity must fail before provider I/O")
        } catch {
            XCTAssertTrue(error is PlainpostError)
        }

        // Removing it takes it, and the sign-in it kept, off this device; the Node keeps it.
        try await dependencies.deleteLocalAccount(accountID: nodeAccount.id, store: store)
        XCTAssertEqual(store.accounts.map(\.id), [directAccount.id])
        let removedNodeIMAP = try await credentials.load(MailCredentialKeys.imapPassword(nodeAccount.id))
        XCTAssertNil(removedNodeIMAP)
    }

    /// The device-wide runtime serves the Direct account only; the Node-backed one's leftover
    /// Direct-era state never reaches it, and building it contacts no service.
    @MainActor func testMixedSourceDeviceWideRuntimeServesTheDirectAndTheMirroredSyncNodeAccount() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-mixed-source-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let nodeAccount = account("a-node")
        let directAccount = account("z-direct")
        let nodeDirect = try AccountMailSource(
            accountID: nodeAccount.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: nodeAccount, inbox: inbox(for: nodeAccount), source: nodeDirect)
        try store.cacheAccountSetup(
            account: directAccount, inbox: inbox(for: directAccount),
            source: try AccountMailSource(
                accountID: directAccount.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        try store.replaceMailSource(nodeDirect.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "a-node@example.com"
        ), expectedGeneration: 1)
        XCTAssertEqual(store.accounts.first?.id, nodeAccount.id)
        let service = RuntimeServiceClientFake()
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: url, serviceClient: service,
            runtimeDependencies: IOSLocalMailRuntimeDependencies(credentials: InMemoryCredentialVault())
        )

        let runtime = try PlainpostAppRuntime(configuration: configuration)
        defer { Task { await runtime.shutdown() } }
        XCTAssertEqual(runtime.makeAccountSetupViewModel().accounts.map(\.id), [nodeAccount.id, directAccount.id])
        let sections = await runtime.mailboxDirectorySections()
        XCTAssertEqual(sections.map(\.id), [nodeAccount.id, directAccount.id])
        let calls = await service.snapshot()
        XCTAssertEqual(calls.statusCallCount, 0)
        XCTAssertTrue(calls.foregroundOperationKinds.isEmpty)
    }

    private func account(_ id: String) -> Account {
        Account(id: AccountID(id), displayName: id,
                email: EmailAddress("\(id)@example.com"),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    private func enqueueSync(for accountID: AccountID, in store: SQLiteMailStore) throws -> PlainpostDurableJob {
        let input = PlainpostInboxSyncInput(accountID: accountID, trigger: .manual)
        return try store.enqueueJob(PlainpostJobRequest(
            kind: .inboxSync,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            maxAttempts: 1,
            idempotencyKey: "ios-source-\(accountID.rawValue)"
        ))
    }

    private func inbox(for account: Account) -> Mailbox {
        Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
    }
}

private enum RepairVaultError: Error {
    case smtpWrite
}

private actor RepairFaultingCredentialVault: CredentialVault {
    private var values: [CredentialRecordKey: Data]
    private var storeCount = 0

    init(initial: [CredentialRecordKey: Data]) {
        values = initial
    }

    func store(_ secret: Data, for key: CredentialRecordKey) throws {
        storeCount += 1
        if storeCount == 2 { throw RepairVaultError.smtpWrite }
        values[key] = secret
    }

    func load(_ key: CredentialRecordKey) throws -> Data? { values[key] }

    func remove(_ key: CredentialRecordKey) throws { values.removeValue(forKey: key) }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        let current = keys.map { values[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        for (key, value) in zip(keys, created) { values[key] = value }
        return created.map(Optional.some)
    }
}

private struct NoopAccountInboxSyncer: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        throw PlainpostError.validationFailed("Unexpected test sync")
    }
}

private struct SuccessfulAccountInboxSyncer: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }
}

private struct NoopMailboxFlagScheduler: MailboxFlagScheduling {
    func schedule(_ input: PlainpostMailboxFlagInput) throws {}
    func signalWork() async throws {}
}
