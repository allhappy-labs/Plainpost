import Foundation
import SQLite3
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime

final class MailRuleProcessorTests: XCTestCase {
    func testPureNotificationPolicyFindsSuppressionWithoutApplyingRuleActions() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(
            id: "quiet-travel",
            actions: [.markAsRead, .suppressNotification],
            labelIDs: ["travel"]
        )
        let jobsBefore = try fixture.store.jobs(limit: 100)
        let assignmentsBefore = try fixture.store.labelAssignments(for: fixture.message.id)

        let suppressed = try MailRuleNotificationPolicy.evaluate(
            messageIDs: [fixture.message.id],
            accountID: fixture.account.id,
            store: fixture.store
        )

        XCTAssertEqual(suppressed, [fixture.message.id])
        XCTAssertEqual(try fixture.store.jobs(limit: 100), jobsBefore)
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id),
            assignmentsBefore
        )
        XCTAssertFalse(try fixture.store.hasMailRuleAction(
            .markAsRead,
            messageID: fixture.message.id
        ))
        XCTAssertFalse(try fixture.store.hasMailRuleAction(
            .suppressNotification,
            messageID: fixture.message.id
        ))
    }

    func testEvaluatorExposesMatchingRuleWithoutRequiringEnumActions() throws {
        let fixture = try MailRuleProcessorFixture()
        let rule = try fixture.rule(id: "travel-rule", labelIDs: ["travel"])

        XCTAssertTrue(MailRuleEvaluator.matches(
            message: fixture.message,
            accountID: fixture.account.id,
            rule: rule
        ))
    }

    func testNewMailAppliesMultipleLabelsAndKeepsTwoRuleOwnersIndependent() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(id: "r1", labelIDs: ["travel", "vip"])
        try fixture.saveRule(id: "r2", labelIDs: ["travel"])

        _ = try fixture.processor.processNewMessages(
            [fixture.message.id],
            accountID: fixture.account.id
        )

        let assignments = try fixture.store.labelAssignments(for: fixture.message.id)
        XCTAssertEqual(
            Set(assignments.filter { $0.labelID == "travel" }.map(\.source)),
            [.rule(ruleID: "r1"), .rule(ruleID: "r2")]
        )
        XCTAssertEqual(
            Set(assignments.filter { $0.labelID == "vip" }.map(\.source)),
            [.rule(ruleID: "r1")]
        )

        try fixture.store.deleteMailRule(id: "r1")

        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.source),
            [.rule(ruleID: "r2")]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == fixture.message.id }).labels,
            ["Travel"]
        )
        XCTAssertEqual(
            Set(fixture.store.auditEntries.filter {
                $0.action == "mail_rule.label_assignment_removed"
            }.map(\.targetID)),
            [
                "processor-message:travel:rule:r1",
                "processor-message:vip:rule:r1",
            ]
        )
    }

    func testApplyExistingIncludesLabelOnlyRule() throws {
        let fixture = try MailRuleProcessorFixture()
        let rule = try fixture.rule(id: "existing-travel", labelIDs: ["travel"])
        try fixture.store.saveMailRule(rule)

        let preview = try fixture.processor.previewExisting(rule: rule)
        let run = try fixture.processor.applyExisting(rule: rule, preview: preview)

        XCTAssertEqual(preview.matches.map(\.messageID), [fixture.message.id])
        XCTAssertEqual(run.messageIDs, [fixture.message.id])
        XCTAssertEqual(run.totalItemCount, 1)
        XCTAssertEqual(run.enqueuedItemCount, 1)
        XCTAssertEqual(run.completedItemCount, 1)
        XCTAssertEqual(run.failedItemCount, 0)
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.source),
            [.rule(ruleID: rule.id)]
        )
    }

    func testApplyExistingEnumActionRemainsEnqueuedUntilDurableJobCompletes() throws {
        let fixture = try MailRuleProcessorFixture()
        let rule = try fixture.rule(
            id: "existing-mark-read",
            actions: [.markAsRead],
            labelIDs: []
        )
        try fixture.store.saveMailRule(rule)

        let preview = try fixture.processor.previewExisting(rule: rule)
        let run = try fixture.processor.applyExisting(rule: rule, preview: preview)

        XCTAssertEqual(run.totalItemCount, 1)
        XCTAssertEqual(run.enqueuedItemCount, 1)
        XCTAssertEqual(run.completedItemCount, 0)
        XCTAssertEqual(run.failedItemCount, 0)
        XCTAssertTrue(try fixture.store.hasMailRuleAction(
            .markAsRead,
            messageID: fixture.message.id
        ))
    }

    func testSelectedDirectApplyExistingWithoutGenerationDoesNotCreateRunOrJobs() throws {
        let fixture = try MailRuleProcessorFixture()
        let rule = try fixture.rule(
            id: "selected-no-generation", actions: [.markAsRead], labelIDs: []
        )
        try fixture.store.saveMailRule(rule)
        let preview = try fixture.processor.previewExisting(rule: rule)
        let processor = MailRuleProcessor(
            store: fixture.store, requireDirectSourceGeneration: true
        )
        let jobsBefore = try fixture.store.jobs(limit: 100)

        XCTAssertThrowsError(try processor.applyExisting(rule: rule, preview: preview))

        XCTAssertEqual(try fixture.store.jobs(limit: 100), jobsBefore)
        XCTAssertFalse(try fixture.store.hasMailRuleAction(
            .markAsRead, messageID: fixture.message.id
        ))
    }

    func testSelectedDirectApplyExistingDoesNotWriteLabelsAfterSourceSwitch() throws {
        let fixture = try MailRuleProcessorFixture()
        let account = fixture.account
        _ = try fixture.store.replaceMailSource(AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil,
            nodeID: nil, logicalMailboxID: nil,
            providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        let rule = try fixture.rule(
            id: "selected-stale-label", actions: [.markAsRead], labelIDs: ["travel"]
        )
        try fixture.store.saveMailRule(rule)
        let processor = MailRuleProcessor(
            store: fixture.store, expectedDirectSourceGeneration: 1,
            requireDirectSourceGeneration: true
        )
        let preview = try processor.previewExisting(rule: rule)
        let source = try fixture.store.mailSource(accountID: account.id)
        _ = try fixture.store.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: account.email.rawValue
        ), expectedGeneration: source.generation)

        XCTAssertThrowsError(try processor.applyExisting(rule: rule, preview: preview))
        XCTAssertEqual(try fixture.store.labelAssignments(for: fixture.message.id), [])
        XCTAssertFalse(try fixture.store.hasMailRuleAction(
            .markAsRead, messageID: fixture.message.id
        ))
    }

    /// The phone syncing a Sync Node account in fallback leaves its mail to the Node's rules:
    /// nothing is applied, and nothing is reported failed or silenced.
    func testAFallbackSyncNodeAccountsNewMailIsLeftToTheNode() throws {
        let fixture = try MailRuleProcessorFixture()
        let account = fixture.account
        let source = try fixture.store.mailSource(accountID: account.id)
        let backed = try fixture.store.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: account.email.rawValue
        ), expectedGeneration: source.generation)
        let fallback = try fixture.store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: backed.generation)
        try fixture.saveRule(id: "quiet", actions: [.markAsRead, .suppressNotification], labelIDs: ["travel"])
        let processor = MailRuleProcessor(
            store: fixture.store, expectedDirectSourceGeneration: fallback.generation,
            requireDirectSourceGeneration: true
        )
        let result = try processor.processNewMessages([fixture.message.id], accountID: account.id)
        XCTAssertEqual(result.newMessageIDs, [fixture.message.id])
        XCTAssertEqual(result.suppressedNotificationMessageIDs, [])
        XCTAssertEqual(try fixture.store.labelAssignments(for: fixture.message.id), [])
        XCTAssertFalse(try fixture.store.hasMailRuleAction(.markAsRead, messageID: fixture.message.id))
    }

    func testApplyExistingUsesPreviewedLabelsAfterSameIDRuleIsEdited() throws {
        let fixture = try MailRuleProcessorFixture()
        let previewedRule = try fixture.rule(
            id: "existing-snapshot",
            labelIDs: ["travel"]
        )
        try fixture.store.saveMailRule(previewedRule)
        let preview = try fixture.processor.previewExisting(rule: previewedRule)
        let editedRule = try fixture.rule(
            id: previewedRule.id,
            labelIDs: ["vip"]
        )
        try fixture.store.saveMailRule(editedRule)

        _ = try fixture.processor.applyExisting(rule: editedRule, preview: preview)

        XCTAssertEqual(preview.matches.first?.labelIDs, ["travel"])
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.labelID),
            ["travel"]
        )
    }

    func testEditingRuleRemovesOnlyThatRulesOwnershipForRemovedLabels() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(id: "r1", labelIDs: ["travel", "vip"])
        try fixture.saveRule(id: "r2", labelIDs: ["vip"])
        _ = try fixture.processor.processNewMessages(
            [fixture.message.id],
            accountID: fixture.account.id
        )

        try fixture.saveRule(id: "r1", labelIDs: ["travel"])

        let assignments = try fixture.store.labelAssignments(for: fixture.message.id)
        XCTAssertEqual(
            Set(assignments.filter { $0.labelID == "travel" }.map(\.source)),
            [.rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            Set(assignments.filter { $0.labelID == "vip" }.map(\.source)),
            [.rule(ruleID: "r2")]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == fixture.message.id }).labels,
            ["Travel", "VIP"]
        )
        XCTAssertEqual(
            fixture.store.auditEntries.filter {
                $0.action == "mail_rule.label_assignment_removed"
            }.map(\.targetID),
            ["processor-message:vip:rule:r1"]
        )
    }

    func testRuleLabelReplacementSkipsMissingReferenceAndAppliesOtherLabels() throws {
        let fixture = try MailRuleProcessorFixture()

        try fixture.store.replaceRuleLabels(
            ruleID: "stale-rule",
            labelIDs: ["deleted-label", "travel"],
            on: fixture.message.id,
            actor: fixture.actor
        )

        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.labelID),
            ["travel"]
        )
    }

    func testRuleEditCleanupRollsBackWhenRemovalAuditFails() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(id: "r1", labelIDs: ["travel"])
        _ = try fixture.processor.processNewMessages(
            [fixture.message.id],
            accountID: fixture.account.id
        )
        try fixture.failAudit(action: "mail_rule.label_assignment_removed")

        XCTAssertThrowsError(try fixture.saveRule(
            id: "r1",
            actions: [.markAsRead],
            labelIDs: []
        ))

        XCTAssertEqual(try fixture.store.mailRule(id: "r1")?.labelIDs, ["travel"])
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.source),
            [.rule(ruleID: "r1")]
        )
    }

    func testRuleDeletionCleanupRollsBackWhenRemovalAuditFails() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(id: "r1", labelIDs: ["travel"])
        _ = try fixture.processor.processNewMessages(
            [fixture.message.id],
            accountID: fixture.account.id
        )
        try fixture.failAudit(action: "mail_rule.label_assignment_removed")

        XCTAssertThrowsError(try fixture.store.deleteMailRule(id: "r1"))

        XCTAssertNotNil(try fixture.store.mailRule(id: "r1"))
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map(\.source),
            [.rule(ruleID: "r1")]
        )
    }

    func testOneRuleLabelFailureDoesNotBlockOtherRuleActionsLabelsOrNotification() throws {
        let fixture = try MailRuleProcessorFixture()
        try fixture.saveRule(id: "broken", labelIDs: ["travel"])
        try fixture.saveRule(
            id: "healthy",
            actions: [.markAsRead, .suppressNotification],
            labelIDs: ["vip"]
        )
        try fixture.failRuleAssignment(ruleID: "broken")

        let result = try fixture.processor.processNewMessages(
            [fixture.message.id],
            accountID: fixture.account.id
        )

        XCTAssertEqual(result.suppressedNotificationMessageIDs, [fixture.message.id])
        XCTAssertTrue(try fixture.store.hasMailRuleAction(
            .markAsRead,
            messageID: fixture.message.id
        ))
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: fixture.message.id).map {
                ($0.labelID, $0.source)
            }.map { "\($0.0):\($0.1)" },
            ["vip:rule(ruleID: \"healthy\")"]
        )
        XCTAssertTrue(fixture.store.auditEntries.contains {
            $0.action == "mail_rule.evaluate_failed"
                && $0.targetID == fixture.message.id.rawValue
        })
    }
}

private final class MailRuleProcessorFixture {
    let store: SQLiteMailStore
    let account = Account(
        id: AccountID("processor-account"),
        displayName: "Processor",
        email: EmailAddress("me@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
    let message = MessageSummary(
        id: MessageID("processor-message"),
        threadID: nil,
        from: EmailAddress("sender@example.com"),
        subject: "Travel plans",
        preview: "Flights and hotel",
        smartCategory: .travel
    )
    let actor = Actor(
        id: "mail-rule-test",
        kind: .system,
        displayName: "Mail Rule Test",
        permissions: .guiUser
    )
    var processor: MailRuleProcessor { MailRuleProcessor(store: store) }

    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-rule-processor-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([account])
        try store.saveMailLabel(try label(id: "travel", title: "Travel"))
        try store.saveMailLabel(try label(id: "vip", title: "VIP"))
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
    }

    deinit {
        let auditLogURL = store.auditLogURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: auditLogURL)
    }

    func saveRule(
        id: String,
        actions: Set<MailRuleAction> = [],
        labelIDs: [String]
    ) throws {
        try store.saveMailRule(try rule(id: id, actions: actions, labelIDs: labelIDs))
    }

    func rule(
        id: String,
        actions: Set<MailRuleAction> = [],
        labelIDs: [String]
    ) throws -> MailRule {
        try MailRule.validated(
            id: id,
            name: id,
            scope: .account(account.id),
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: actions,
            labelIDs: labelIDs
        )
    }

    func failRuleAssignment(ruleID: String) throws {
        let escapedRuleID = ruleID.replacingOccurrences(of: "'", with: "''")
        try executeSQL(
            """
            CREATE TRIGGER fail_selected_rule_assignment
            BEFORE INSERT ON message_label_assignments
            WHEN NEW.source_kind = 'rule' AND NEW.source_id = '\(escapedRuleID)'
            BEGIN
                SELECT RAISE(FAIL, 'forced rule assignment failure');
            END;
            """
        )
    }

    func failAudit(action: String) throws {
        let escapedAction = action.replacingOccurrences(of: "'", with: "''")
        try executeSQL(
            """
            CREATE TRIGGER fail_selected_rule_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = '\(escapedAction)'
            BEGIN
                SELECT RAISE(FAIL, 'forced rule audit failure');
            END;
            """
        )
    }

    private func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw PlainpostError.validationFailed("The test database could not be opened.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("The test failure trigger could not be installed.")
        }
    }

    private func label(id: String, title: String) throws -> MailLabelDefinition {
        try MailLabelDefinition.validated(
            id: id,
            title: title,
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        )
    }
}
