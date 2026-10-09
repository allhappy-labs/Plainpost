import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
@testable import PlainpostUI

@MainActor
final class MailRulesViewModelTests: XCTestCase {
    func testDirectAccountScopeHidesGlobalAndNodeRulesAndRejectsForeignMutations() throws {
        let fixture = try MailRulesViewModelFixture()
        let direct = fixture.work.id
        let node = fixture.personal.id
        try fixture.store.saveMailRule(try rule(id: "global-rule", scope: .allAccounts))
        try fixture.store.saveMailRule(try rule(id: "direct-rule", scope: .account(direct)))
        try fixture.store.saveMailRule(try rule(id: "node-rule", scope: .account(node)))
        let nodeSource = try fixture.store.mailSource(accountID: node).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "node@example.com"
        )
        try fixture.store.replaceMailSource(nodeSource, expectedGeneration: 1)
        let model = MailRulesViewModel(
            store: fixture.store, processor: MailRuleProcessor(store: fixture.store),
            accounts: [fixture.work, fixture.personal], selectedDirectAccountID: direct
        )

        XCTAssertEqual(model.visibleRules.map(\.id), ["direct-rule"])
        XCTAssertEqual(model.accounts.map(\.id), [direct])
        model.selectAccount(.allAccounts)
        XCTAssertEqual(model.selection, .account(direct))
        model.setEnabled(id: "node-rule", isEnabled: false)
        XCTAssertEqual(try fixture.store.mailRule(id: "node-rule")?.isEnabled, true)
        model.beginAddingRule()
        XCTAssertEqual(model.draft?.scope, .account(direct))
        model.draft = MailRuleDraft(
            name: "Cross-account", scope: .account(node),
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")]
        )
        model.saveDraft()
        XCTAssertFalse(try fixture.store.mailRules(effectiveFor: node).contains { $0.name == "Cross-account" })
        model.beginAddingRule()
        model.draft?.name = "Direct-only"
        model.draft?.conditions = [.init(field: .from, operator: .domainIs, value: "example.com")]
        model.saveDraft()
        XCTAssertTrue(try fixture.store.mailRules(effectiveFor: direct).contains { $0.name == "Direct-only" })

        let directSource = try fixture.store.mailSource(accountID: direct).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1eb",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "direct@example.com"
        )
        try fixture.store.replaceMailSource(directSource, expectedGeneration: 1)
        model.reload()
        XCTAssertTrue(model.visibleRules.isEmpty)
        model.beginAddingRule()
        model.saveDraft()
        XCTAssertNil(model.draft)
    }

    func testAccountSelectionFiltersRulesAndNewDraftInheritsScope() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-rules-vm-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let work = Account(
            id: AccountID("acc-vm-work"), displayName: "Work",
            email: EmailAddress("me@work.example"), imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([work])
        try store.saveMailRule(try rule(id: "global", scope: .allAccounts))
        try store.saveMailRule(try rule(id: "work", scope: .account(work.id)))
        let viewModel = MailRulesViewModel(
            store: store,
            processor: MailRuleProcessor(store: store),
            accounts: [work]
        )

        viewModel.selectAccount(.account(work.id))
        XCTAssertEqual(viewModel.visibleRules.map(\.id), ["global", "work"])
        viewModel.beginAddingRule()
        XCTAssertEqual(viewModel.draft?.scope, .account(work.id))
        viewModel.selectAccount(.allAccounts)
        viewModel.beginAddingRule()
        XCTAssertEqual(viewModel.draft?.scope, .allAccounts)
    }

    func testAccountRuleOffersGlobalAndSameAccountLabelsOnly() throws {
        let fixture = try MailRulesViewModelFixture()
        let viewModel = fixture.makeViewModel()

        viewModel.selectAccount(.account(fixture.work.id))
        viewModel.beginAddingRule()

        XCTAssertEqual(
            viewModel.availableLabelActions.map(\.id),
            ["global", "account-a"]
        )
    }

    func testGlobalRuleOffersOnlyGlobalLabels() throws {
        let fixture = try MailRulesViewModelFixture()
        let viewModel = fixture.makeViewModel()

        viewModel.beginAddingRule()

        XCTAssertEqual(viewModel.availableLabelActions.map(\.id), ["global"])
    }

    func testSavingLabelOnlyDraftPersistsSelectedLabels() throws {
        let fixture = try MailRulesViewModelFixture()
        let viewModel = fixture.makeViewModel()
        viewModel.beginAddingRule()
        var draft = try XCTUnwrap(viewModel.draft)
        draft.name = "Global travel"
        draft.actions = []
        draft.selectedLabelIDs = ["global"]
        draft.conditions = [
            .init(field: .subject, operator: .contains, value: "flight"),
        ]
        viewModel.draft = draft

        viewModel.saveDraft()

        let saved = try XCTUnwrap(
            fixture.store.mailRules(effectiveFor: nil).first { $0.name == "Global travel" }
        )
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.actions, [])
        XCTAssertEqual(saved.labelIDs, ["global"])
        XCTAssertNil(viewModel.validationMessage)
    }

    func testRulePersistenceRejectsLabelsOutsideItsScope() throws {
        let fixture = try MailRulesViewModelFixture()
        let condition = MailRuleCondition(
            field: .subject,
            operator: .contains,
            value: "flight"
        )
        XCTAssertThrowsError(try fixture.store.saveMailRule(MailRule.validated(
            id: "invalid-global",
            name: "Invalid global",
            scope: .allAccounts,
            conditions: [condition],
            actions: [],
            labelIDs: ["account-a"]
        ))) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .outOfScopeLabel)
        }
        XCTAssertThrowsError(try fixture.store.saveMailRule(MailRule.validated(
            id: "invalid-account",
            name: "Invalid account",
            scope: .account(fixture.work.id),
            conditions: [condition],
            actions: [],
            labelIDs: ["account-b"]
        ))) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .outOfScopeLabel)
        }

        let valid = try MailRule.validated(
            id: "valid-account",
            name: "Valid account",
            scope: .account(fixture.work.id),
            conditions: [condition],
            actions: [],
            labelIDs: ["global", "account-a"]
        )
        try fixture.store.saveMailRule(valid)
        XCTAssertEqual(
            try fixture.store.mailRule(id: valid.id)?.labelIDs,
            ["account-a", "global"]
        )
    }

    func testLabelDeletionKeepsSelectedRuleAndShowsDisabledRepairState() throws {
        let fixture = try MailRulesViewModelFixture()
        let rule = try MailRule.validated(
            id: "label-only",
            name: "Label only",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: ["global"]
        )
        try fixture.store.saveMailRule(rule)
        let viewModel = fixture.makeViewModel()
        viewModel.selectRule(id: rule.id)

        try fixture.store.deleteMailLabel(id: "global")
        viewModel.reload()

        XCTAssertEqual(viewModel.selectedRuleID, rule.id)
        XCTAssertEqual(viewModel.draft?.selectedLabelIDs, Set<String>())
        XCTAssertEqual(viewModel.draft?.isEnabled, false)
        XCTAssertEqual(
            viewModel.validationMessage,
            "Choose at least one action before enabling this rule."
        )
    }

    func testSelectingAndReselectingDisabledActionlessRuleShowsRepairMessage() throws {
        let fixture = try MailRulesViewModelFixture()
        let repairRule = try MailRule.validated(
            id: "repair",
            name: "Repair",
            isEnabled: false,
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: []
        )
        let healthyRule = try MailRule.validated(
            id: "healthy",
            name: "Healthy",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [.markAsRead]
        )
        try fixture.store.saveMailRule(repairRule)
        try fixture.store.saveMailRule(healthyRule)
        let viewModel = fixture.makeViewModel()

        viewModel.selectRule(id: repairRule.id)
        XCTAssertEqual(
            viewModel.validationMessage,
            "Choose at least one action before enabling this rule."
        )

        viewModel.selectRule(id: healthyRule.id)
        XCTAssertNil(viewModel.validationMessage)
        viewModel.selectRule(id: repairRule.id)
        XCTAssertEqual(
            viewModel.validationMessage,
            "Choose at least one action before enabling this rule."
        )
    }

    func testDeletingSelectedRuleClearsEditorPresentationSignal() throws {
        let fixture = try MailRulesViewModelFixture()
        try fixture.store.saveMailRule(try rule(id: "solo", scope: .allAccounts))
        let viewModel = fixture.makeViewModel()
        viewModel.selectRule(id: "solo")
        XCTAssertNotNil(
            viewModel.draft,
            "selecting a rule must present its editor (draft != nil is the presentation signal)"
        )

        viewModel.deleteSelectedRule()

        XCTAssertNil(viewModel.selectedRuleID)
        XCTAssertNil(
            viewModel.draft,
            "deleting the selected rule must clear the presentation signal so a pushed iOS editor pops"
        )
    }

    private func rule(id: String, scope: MailRuleScope) throws -> MailRule {
        try MailRule.validated(
            id: id, name: id, scope: scope,
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.skipInbox]
        )
    }
}

private final class MailRulesViewModelFixture {
    let store: SQLiteMailStore
    let work = Account(
        id: AccountID("a"),
        displayName: "Work",
        email: EmailAddress("me@work.example"),
        imapHost: "imap.work.example",
        smtpHost: "smtp.work.example"
    )
    let personal = Account(
        id: AccountID("b"),
        displayName: "Personal",
        email: EmailAddress("me@personal.example"),
        imapHost: "imap.personal.example",
        smtpHost: "smtp.personal.example"
    )

    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-rules-vm-labels-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        for account in [work, personal] {
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
        try store.saveMailLabel(try label(id: "global", title: "Global", scope: .allAccounts))
        try store.saveMailLabel(try label(
            id: "account-a",
            title: "Account A",
            scope: .account(work.id)
        ))
        try store.saveMailLabel(try label(
            id: "account-b",
            title: "Account B",
            scope: .account(personal.id)
        ))
    }

    deinit {
        let auditLogURL = store.auditLogURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: auditLogURL)
    }

    @MainActor
    func makeViewModel() -> MailRulesViewModel {
        MailRulesViewModel(
            store: store,
            processor: MailRuleProcessor(store: store),
            accounts: [work, personal]
        )
    }

    private func label(
        id: String,
        title: String,
        scope: MailLabelScope
    ) throws -> MailLabelDefinition {
        try MailLabelDefinition.validated(
            id: id,
            title: title,
            description: "",
            isSmartInboxEnabled: false,
            scope: scope
        )
    }
}
