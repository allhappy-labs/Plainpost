import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
@testable import PlainpostUI

@MainActor
final class MailLabelsViewModelTests: XCTestCase {
    func testDirectAccountScopeHidesGlobalAndNodeLabelsAndRejectsForeignSave() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-labels-direct-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let direct = Account(id: AccountID("a"), displayName: "Direct",
                             email: EmailAddress("a@example.com"), imapHost: "imap.example.com",
                             smtpHost: "smtp.example.com")
        let node = Account(id: AccountID("b"), displayName: "Node",
                           email: EmailAddress("b@example.com"), imapHost: "imap.example.com",
                           smtpHost: "smtp.example.com")
        for account in [direct, node] {
            let source = try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
            let inbox = Mailbox(
                id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
            )
            try store.cacheAccountSetup(account: account, inbox: inbox, source: source)
        }
        try store.saveMailLabel(.global)
        try store.saveMailLabel(.accountA)
        try store.saveMailLabel(.accountB)
        let nodeSource = try store.mailSource(accountID: node.id).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "node@example.com"
        )
        try store.replaceMailSource(nodeSource, expectedGeneration: 1)
        let model = MailLabelsViewModel(
            definitions: store, accounts: [direct, node], selectedDirectAccountID: direct.id,
            runReclassification: { _ in MailLabelRunProgress(updated: 0, unchanged: 0, failed: 0) }
        )

        await model.load()
        XCTAssertEqual(model.labels.map(\.id), ["account-a"])
        XCTAssertEqual(model.accounts.map(\.id), [direct.id])
        model.selectAccount(.allAccounts)
        XCTAssertEqual(model.selection, .account(direct.id))
        model.draft = MailLabelDraft(title: "Cross-account", scope: .account(node.id))
        await model.save()
        XCTAssertNil(try store.mailLabels(effectiveFor: node.id).first { $0.title == "Cross-account" })
        model.selection = .account(node.id)
        model.addLabel()
        XCTAssertEqual(model.draft?.scope, .account(direct.id))
        model.draft?.title = "Direct-only"
        await model.save()
        XCTAssertNotNil(try store.mailLabels(effectiveFor: direct.id).first { $0.title == "Direct-only" })

        let directSource = try store.mailSource(accountID: direct.id).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1eb",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "direct@example.com"
        )
        try store.replaceMailSource(directSource, expectedGeneration: 1)
        await model.load()
        XCTAssertTrue(model.labels.isEmpty)
    }

    func testLabelsDestinationUsesManagementWorkAreaAndFirstSelection() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.global, .accountA])

        await model.load()

        XCTAssertEqual(model.selectedLabelID, "global")
        XCTAssertEqual(PlainpostDestination.labels.workAreaKind, .settings)
        XCTAssertEqual(PlainpostDestination.labels.settingsSection, .rulesLabels)
    }

    func testDescriptionClearConfirmationDisablesSmartInbox() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.globalSmart])
        await model.load()
        model.draft?.description = ""

        XCTAssertTrue(model.requiresDisableConfirmation)
        await model.confirmDescriptionClearAndSave()

        XCTAssertFalse(model.labels[0].isSmartInboxEnabled)
    }

    func testSmartInboxToggleRequiresDescription() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.globalManualOnly])
        await model.load()

        model.setSmartInboxEnabled(true)

        XCTAssertFalse(model.draft?.isSmartInboxEnabled == true)
        XCTAssertEqual(
            model.validationMessage,
            "Add a description before using this label in Smart Inbox."
        )
    }

    func testSaveDoesNotStartReclassification() async throws {
        let probe = SmartInboxRunProbe()
        let model = MailLabelsViewModel.fixture(labels: [.globalSmart], runProbe: probe)
        await model.load()
        model.draft?.description = "Changed definition"

        await model.save()

        XCTAssertEqual(probe.requests, [])
    }

    func testAccountSelectionFiltersLabelsAndNewDraftScopeIsImmutable() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.global, .accountA, .accountB])
        await model.load()

        model.selectAccount(.account(AccountID("a")))
        XCTAssertEqual(model.labels.map(\.id), ["global", "account-a"])
        model.addLabel()
        XCTAssertEqual(model.draft?.scope, .account(AccountID("a")))
    }

    func testAccountScopeDisplayUsesActualAccountNameAndEmail() {
        let account = Account(
            id: AccountID("a"),
            displayName: "Work",
            email: EmailAddress("me@work.example"),
            imapHost: "imap.work.example",
            smtpHost: "smtp.work.example"
        )
        let model = MailLabelsViewModel(
            accounts: [account],
            labels: [.accountA],
            runReclassification: { _ in
                MailLabelRunProgress(updated: 0, unchanged: 0, failed: 0)
            }
        )

        XCTAssertEqual(
            model.scopeDisplayName(.account(account.id)),
            "Work — me@work.example"
        )
        XCTAssertEqual(model.scopeDisplayName(.allAccounts), "All Accounts")
    }

    func testRepositoryBackedAllAccountsShowsOnlyGlobalLabels() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-labels-vm-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([
            Account(
                id: AccountID("a"),
                displayName: "Work",
                email: EmailAddress("me@work.example"),
                imapHost: "imap.work.example",
                smtpHost: "smtp.work.example"
            ),
        ])
        try store.saveMailLabel(.global)
        try store.saveMailLabel(.accountA)
        let model = MailLabelsViewModel(
            definitions: store,
            accounts: [],
            runReclassification: { _ in
                MailLabelRunProgress(updated: 0, unchanged: 0, failed: 0)
            }
        )

        await model.load()

        XCTAssertEqual(model.labels.map(\.id), ["global"])
    }

    func testPreviewAndConfirmReclassificationUseExplicitScopedRequest() async throws {
        let probe = SmartInboxRunProbe(
            result: MailLabelRunProgress(updated: 3, unchanged: 2, failed: 1)
        )
        let model = MailLabelsViewModel.fixture(labels: [.accountASmart], runProbe: probe)
        await model.load()
        model.selectAccount(.account(AccountID("a")))

        await model.previewReclassification()
        guard case .reclassify(let preview) = model.confirmation else {
            return XCTFail("Expected reclassification confirmation")
        }
        XCTAssertEqual(preview.scope, .account(AccountID("a")))
        await model.confirmReclassification()

        XCTAssertEqual(
            probe.requests,
            [
                PlainpostSmartInboxRunRequest(
                    mode: .rerunAll,
                    scope: .account(AccountID("a")),
                    requestedLabelID: "account-a-smart"
                ),
            ]
        )
        XCTAssertEqual(model.progress?.summary, "3 updated, 2 unchanged, 1 failed")
    }

    func testReclassificationCannotStartWithoutExplicitPreviewConfirmation() async throws {
        let probe = SmartInboxRunProbe(
            result: MailLabelRunProgress(updated: 1, unchanged: 0, failed: 0)
        )
        let model = MailLabelsViewModel.fixture(labels: [.globalSmart], runProbe: probe)
        await model.load()

        await model.confirmReclassification()

        XCTAssertEqual(probe.requests, [])
        XCTAssertNil(model.progress)
    }

    func testSuccessfulReclassificationSummaryOmitsFailedCount() {
        XCTAssertEqual(
            MailLabelRunProgress(updated: 4, unchanged: 2, failed: 0).summary,
            "4 updated, 2 unchanged"
        )
    }

    func testTerminalReclassificationErrorAcknowledgesPossiblePartialUpdates() async throws {
        let model = MailLabelsViewModel(
            accounts: [],
            labels: [.globalSmart],
            runReclassification: { _ in
                throw PlainpostError.validationFailed("Terminal failure after one applied message.")
            }
        )
        await model.load()
        await model.previewReclassification()

        await model.confirmReclassification()

        XCTAssertEqual(
            model.validationMessage,
            "Processing did not complete. Some messages may already be updated."
        )
        XCTAssertFalse(
            model.validationMessage?.localizedCaseInsensitiveContains("could not be started")
                == true
        )
    }

    func testDeletePreviewIncludesMessagesAndRulesThenDeletesDefinition() async throws {
        let model = MailLabelsViewModel.fixture(
            labels: [.globalSmart],
            deletionPreview: MailLabelDeletionPreview(
                labelID: "global-smart",
                scope: .allAccounts,
                affectedMessageCount: 8,
                affectedRuleCount: 2
            )
        )
        await model.load()

        await model.previewDeletion()
        guard case .delete(let preview) = model.confirmation else {
            return XCTFail("Expected delete confirmation")
        }
        XCTAssertEqual(preview.affectedMessageCount, 8)
        XCTAssertEqual(preview.affectedRuleCount, 2)

        await model.confirmDeletion()
        XCTAssertTrue(model.labels.isEmpty)
    }

    // Deleting a label closes its editor (iOS pops back to the list) instead of
    // opening the next label in its place.
    func testDeletingALabelClosesItsEditorWithoutSelectingAnother() async throws {
        let model = MailLabelsViewModel.fixture(
            labels: [.global, .globalSmart],
            deletionPreview: MailLabelDeletionPreview(
                labelID: "global-smart",
                scope: .allAccounts,
                affectedMessageCount: 0,
                affectedRuleCount: 0
            )
        )
        await model.load()
        model.selectLabel(id: "global-smart")
        XCTAssertNotNil(model.draft)

        await model.previewDeletion()
        await model.confirmDeletion()

        XCTAssertEqual(model.labels.map(\.id), ["global"])
        XCTAssertNil(model.selectedLabelID)
        XCTAssertNil(model.draft, "the editor must close, not move on to the next label")

        // Opening the page again still selects the first label.
        model.selectAccount(model.selection)
        XCTAssertEqual(model.selectedLabelID, "global")
    }

    // iOS pushes the editor whenever a label is selected, so loading must not
    // select one: the editor opens only from a row tap or Add.
    func testListOnlyLoadingLeavesTheEditorClosedUntilALabelIsChosen() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.global, .globalSmart])
        model.selectsFirstLabelOnLoad = false

        await model.load()
        XCTAssertEqual(model.labels.map(\.id), ["global", "global-smart"])
        XCTAssertNil(model.selectedLabelID)
        XCTAssertNil(model.draft, "opening the page must show the list, not an editor")

        model.selectLabel(id: "global-smart")
        XCTAssertEqual(model.draft?.existingLabelID, "global-smart")

        // Back from the editor, then the page reloads: it stays on the list.
        model.selectedLabelID = nil
        model.draft = nil
        await model.load()
        model.selectAccount(model.selection)
        XCTAssertNil(model.draft)

        // Saving keeps the saved label's editor open.
        model.selectLabel(id: "global")
        await model.save()
        XCTAssertEqual(model.selectedLabelID, "global")
        XCTAssertNotNil(model.draft)
    }

    // The iOS row toggle changes only the label's Smart Inbox flag: no selection, no
    // draft, so the editor is not pushed.
    func testRowSmartInboxToggleSavesTheFlagWithoutSelectingOrOpeningTheEditor() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.globalSmart, .globalManualOnly])
        model.selectsFirstLabelOnLoad = false
        await model.load()

        await model.setSmartInboxEnabled(false, forLabelID: "global-smart")
        XCTAssertEqual(model.labels.first { $0.id == "global-smart" }?.isSmartInboxEnabled, false)
        XCTAssertNil(model.selectedLabelID)
        XCTAssertNil(model.draft, "the row toggle must not open the editor")

        await model.setSmartInboxEnabled(true, forLabelID: "global-smart")
        XCTAssertEqual(model.labels.first { $0.id == "global-smart" }?.isSmartInboxEnabled, true)
        XCTAssertNil(model.draft)

        // A label without a description can't join Smart Inbox. The row has nowhere to
        // show why, so its editor opens with the message and the flag still off.
        await model.setSmartInboxEnabled(true, forLabelID: "global-manual")
        XCTAssertEqual(model.labels.first { $0.id == "global-manual" }?.isSmartInboxEnabled, false)
        XCTAssertEqual(model.selectedLabelID, "global-manual")
        XCTAssertEqual(model.draft?.existingLabelID, "global-manual", "the editor opens for that label")
        XCTAssertEqual(model.draft?.isSmartInboxEnabled, false)
        XCTAssertEqual(model.validationMessage, "Add a description before using this label in Smart Inbox.")

        // Back on the list, a successful toggle clears the stale message.
        model.selectedLabelID = nil
        model.draft = nil
        await model.setSmartInboxEnabled(false, forLabelID: "global-smart")
        XCTAssertNil(model.validationMessage)
        XCTAssertNil(model.draft)
    }

    func testRowSmartInboxToggleKeepsAnOpenEditorOnItsOwnLabel() async throws {
        let model = MailLabelsViewModel.fixture(labels: [.globalSmart, .global])
        await model.load()
        model.selectLabel(id: "global")
        model.draft?.title = "Receipts (unsaved)"

        await model.setSmartInboxEnabled(false, forLabelID: "global-smart")

        XCTAssertEqual(model.labels.first { $0.id == "global-smart" }?.isSmartInboxEnabled, false)
        XCTAssertEqual(model.selectedLabelID, "global")
        XCTAssertEqual(model.draft?.title, "Receipts (unsaved)")
    }

    func testOnlyTheSideBySideMacLayoutSelectsTheFirstLabelOnLoad() {
        #if os(iOS)
        XCTAssertFalse(MailLabelsViewModel.platformSelectsFirstLabelOnLoad)
        #else
        XCTAssertTrue(MailLabelsViewModel.platformSelectsFirstLabelOnLoad)
        #endif
    }

    func testReclassificationPreviewUsesAsyncCountOnlyRepositoryPath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-label-preview-count-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let bodyReads = LockedCounter()
        let countReads = LockedCounter()
        let enteredCountRead = expectation(description: "Count-only query entered")
        let releaseCountRead = DispatchSemaphore(value: 0)
        let store = try SQLiteMailStore(
            path: url.path,
            busyTimeout: 5,
            onTransientContention: nil,
            onSmartInboxClassificationInputRead: {
                bodyReads.increment()
            },
            onSmartInboxReclassificationPreviewCountRead: {
                countReads.increment()
                enteredCountRead.fulfill()
                _ = releaseCountRead.wait(timeout: .now() + 2)
            }
        )
        defer { try? FileManager.default.removeItem(at: store.auditLogURL) }
        try store.migrate()
        try store.saveMailLabel(.globalSmart)
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("preview-count-message"),
                threadID: nil,
                from: EmailAddress("private@example.com"),
                subject: "Private",
                preview: "Preview",
                body: "BODY-MUST-NOT-BE-READ",
                smartCategory: .unknown
            )
        )
        let model = MailLabelsViewModel(
            definitions: store,
            accounts: [],
            runReclassification: { _ in
                MailLabelRunProgress(updated: 0, unchanged: 0, failed: 0)
            }
        )
        await model.load()

        let previewTask = Task { await model.previewReclassification() }
        await fulfillment(of: [enteredCountRead], timeout: 1)

        XCTAssertTrue(model.isWorking, "The main actor must remain responsive while SQLite counts.")
        XCTAssertEqual(bodyReads.value, 0)
        XCTAssertEqual(countReads.value, 1)
        releaseCountRead.signal()
        await previewTask.value

        guard case .reclassify(let preview) = model.confirmation else {
            return XCTFail("Expected reclassification confirmation")
        }
        XCTAssertEqual(preview.affectedMessageCount, 1)
        XCTAssertEqual(bodyReads.value, 0)
    }

    func testAllAccountsLimitMessageNamesAllAccounts() async throws {
        let fixture = try LimitMessageFixture(globalCount: 24, accountCount: 0)
        let model = fixture.makeModel()
        await model.load()
        model.addLabel()
        model.draft?.title = "Extra"
        model.draft?.description = "Extra description"
        model.setSmartInboxEnabled(true)

        await model.save()

        XCTAssertEqual(
            model.validationMessage,
            "All Accounts already has 24 labels enabled for Smart Inbox."
        )
    }

    func testGlobalLimitMessageNamesAffectedAccount() async throws {
        let fixture = try LimitMessageFixture(globalCount: 23, accountCount: 1)
        let model = fixture.makeModel()
        await model.load()
        model.addLabel()
        model.draft?.title = "Extra"
        model.draft?.description = "Extra description"
        model.setSmartInboxEnabled(true)

        await model.save()

        XCTAssertEqual(
            model.validationMessage,
            "Work already has 24 labels enabled for Smart Inbox."
        )
    }

    func testAccountLimitMessageNamesSelectedAccount() async throws {
        let fixture = try LimitMessageFixture(globalCount: 0, accountCount: 24)
        let model = fixture.makeModel()
        await model.load()
        model.selectAccount(.account(fixture.work.id))
        model.addLabel()
        model.draft?.title = "Extra"
        model.draft?.description = "Extra description"
        model.setSmartInboxEnabled(true)

        await model.save()

        XCTAssertEqual(
            model.validationMessage,
            "Work already has 24 labels enabled for Smart Inbox."
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LimitMessageFixture {
    let store: SQLiteMailStore
    let work = Account(
        id: AccountID("limit-work"),
        displayName: "Work",
        email: EmailAddress("me@work.example"),
        imapHost: "imap.work.example",
        smtpHost: "smtp.work.example"
    )
    private let url: URL

    init(globalCount: Int, accountCount: Int) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-label-limit-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([work])
        for index in 0..<globalCount {
            try store.saveMailLabel(try MailLabelDefinition.validated(
                id: "global-limit-\(index)",
                title: "Global Limit \(index)",
                description: "Description \(index)",
                isSmartInboxEnabled: true,
                scope: .allAccounts
            ))
        }
        for index in 0..<accountCount {
            try store.saveMailLabel(try MailLabelDefinition.validated(
                id: "account-limit-\(index)",
                title: "Account Limit \(index)",
                description: "Description \(index)",
                isSmartInboxEnabled: true,
                scope: .account(work.id)
            ))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: store.auditLogURL)
    }

    @MainActor
    func makeModel() -> MailLabelsViewModel {
        MailLabelsViewModel(
            definitions: store,
            accounts: [work],
            runReclassification: { _ in
                MailLabelRunProgress(updated: 0, unchanged: 0, failed: 0)
            }
        )
    }
}
