import CryptoKit
import SQLite3
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB

private enum LabelTestActors {
    static let user = Actor(
        id: "label-test-user",
        kind: .user,
        displayName: "Label Test User",
        permissions: .agentRequested(
            readBody: true,
            createDrafts: true,
            requestSend: true
        )
    )
    static let system = Actor(
        id: "label-test-system",
        kind: .system,
        displayName: "Label Test System",
        permissions: .agentRequested(
            readBody: true,
            createDrafts: true,
            requestSend: true
        )
    )
}

final class SQLiteMailLabelStoreTests: XCTestCase {
    func testAccountCacheUpdatePreservesScopedLabelsOwnershipRulesAndSearchProjection() throws {
        let fixture = try SQLiteMailLabelFixture()
        let messageID = MessageID("account-edit-message")
        let labels = [
            ("user-label", "User Label"),
            ("rule-label", "Rule Label"),
            ("smart-label", "Smart Label"),
            ("excluded-label", "Excluded Label"),
        ]
        for (id, title) in labels {
            try fixture.store.saveMailLabel(try label(
                id: id,
                title: title,
                description: "Account-scoped \(title)",
                isSmartInboxEnabled: true,
                scope: .account(fixture.work.id)
            ))
        }
        try fixture.store.saveMailRule(try MailRule.validated(
            id: "account-rule",
            name: "Account label rule",
            scope: .account(fixture.work.id),
            conditions: [
                .init(field: .subject, operator: .contains, value: "Account edit"),
            ],
            actions: [],
            labelIDs: ["rule-label"]
        ))
        _ = try fixture.store.commitIncomingMessage(
            MessageSummary(
                id: messageID,
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                subject: "Account edit",
                preview: "Preserve every dependent row.",
                smartCategory: .personal
            ),
            metadata: .init(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: fixture.work.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 42,
            notificationEligible: false
        )
        try fixture.store.addUserLabel(
            labelID: "user-label",
            to: messageID,
            actor: LabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "account-rule",
            labelIDs: ["rule-label"],
            on: messageID,
            actor: LabelTestActors.system
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["smart-label", "excluded-label"],
            on: messageID,
            actor: LabelTestActors.system
        )
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "excluded-label",
            from: messageID,
            actor: LabelTestActors.user
        )

        let edited = Account(
            id: fixture.work.id,
            displayName: "Renamed Work",
            email: EmailAddress("renamed@work.example"),
            username: "renamed@work.example",
            sentMailbox: fixture.work.sentMailbox,
            imapHost: "imap.renamed.example",
            imapPort: fixture.work.imapPort,
            smtpHost: "smtp.renamed.example",
            smtpPort: fixture.work.smtpPort
        )
        try fixture.store.cacheAccounts([edited])

        XCTAssertEqual(
            fixture.store.accounts.first { $0.id == fixture.work.id },
            edited
        )
        XCTAssertEqual(
            Set(try fixture.store.mailLabels(effectiveFor: fixture.work.id).map(\.id)),
            Set(labels.map(\.0))
        )
        XCTAssertEqual(
            Set(try fixture.store.labelAssignments(for: messageID).map {
                "\($0.labelID):\($0.source)"
            }),
            [
                "user-label:user",
                "rule-label:rule(ruleID: \"account-rule\")",
                "smart-label:smartInbox",
            ]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: messageID).map(\.labelID),
            ["excluded-label"]
        )
        XCTAssertEqual(
            try fixture.store.mailRule(id: "account-rule")?.labelIDs,
            ["rule-label"]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == messageID }).labels,
            ["Rule Label", "Smart Label", "User Label"]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                "SELECT labels FROM mail_search_documents WHERE message_id = 'account-edit-message'"
            ),
            ["Rule Label Smart Label User Label"]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                """
                SELECT labels FROM mail_search_fts
                WHERE rowid = (
                    SELECT rowid FROM mail_search_documents
                    WHERE message_id = 'account-edit-message'
                )
                """
            ),
            ["Rule Label Smart Label User Label"]
        )
        XCTAssertEqual(try fixture.store.searchMessages("Smart Label"), [messageID])
    }

    func testDefinitionAuditUsesCanonicalSafeDetailsForCreateRenameAndEligibility() throws {
        let fixture = try SQLiteMailLabelFixture()
        let secretDescription = "SECRET-DESCRIPTION-MUST-NOT-BE-AUDITED"
        try fixture.store.saveMailLabel(try label(
            id: "projects",
            title: "Project",
            description: secretDescription,
            scope: .allAccounts
        ))
        let created = try XCTUnwrap(fixture.store.auditEntries.last {
            $0.action == "mail_label.create"
        })
        XCTAssertEqual(
            created.result,
            """
            {"isSmartInboxEnabled":false,"labelID":"projects","scope":"allAccounts","title":"Project"}
            """
        )

        try fixture.store.saveMailLabel(try label(
            id: "projects",
            title: "Projects",
            description: secretDescription,
            isSmartInboxEnabled: true,
            scope: .allAccounts,
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        let audits = fixture.store.auditEntries.filter { $0.targetID == "projects" }
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.rename" }).result,
            """
            {"labelID":"projects","newTitle":"Projects","oldTitle":"Project","scope":"allAccounts"}
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.eligibility_change" }).result,
            """
            {"isSmartInboxEnabled":true,"labelID":"projects","scope":"allAccounts"}
            """
        )
        XCTAssertTrue(audits.allSatisfy { !$0.result.contains(secretDescription) })
    }

    func testOwnershipAuditRecordsSourceDiffsAndExclusionLifecycleWithoutMailContent() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "rule-1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        let audits = fixture.store.auditEntries
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.smart_inbox_replace" }).result,
            """
            {"addedLabelIDs":["travel"],"removedLabelIDs":[],"source":"smartInbox"}
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.exclusion_create" }).result,
            """
            {"labelID":"travel","source":"user"}
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.exclusion_clear" }).result,
            """
            {"labelID":"travel","source":"user"}
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(audits.last { $0.action == "mail_label.rule_replace" }).result,
            """
            {"addedLabelIDs":["travel"],"removedLabelIDs":[],"ruleID":"rule-1","source":"rule"}
            """
        )

        let forbidden = [
            "Travel plans",
            "sender@example.com",
            "Preview",
            "Classify every input email",
        ]
        XCTAssertTrue(audits.allSatisfy { audit in
            forbidden.allSatisfy { !audit.result.contains($0) }
        })
    }

    func testDefinitionMutationRollsBackWhenStructuredAuditFails() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.execute(
            """
            CREATE TRIGGER reject_label_rename_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'mail_label.rename'
            BEGIN
                SELECT RAISE(ABORT, 'forced audit failure');
            END;
            """
        )
        let original = try XCTUnwrap(fixture.store.mailLabel(id: "travel"))

        XCTAssertThrowsError(try fixture.store.saveMailLabel(try label(
            id: original.id,
            title: "Journeys",
            description: original.description,
            isSmartInboxEnabled: original.isSmartInboxEnabled,
            scope: original.scope,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt.addingTimeInterval(1)
        )))

        XCTAssertEqual(try fixture.store.mailLabel(id: "travel"), original)
    }

    func testDefinitionDeleteRollsBackCleanupWhenStructuredAuditFails() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.execute(
            """
            CREATE TRIGGER reject_label_delete_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'mail_label.delete'
            BEGIN
                SELECT RAISE(ABORT, 'forced audit failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.store.deleteMailLabel(id: "travel"))

        XCTAssertNotNil(try fixture.store.mailLabel(id: "travel"))
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source),
            [.user]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
    }

    func testStringCompatibilityReturnsMessageSummaryBackedByUserOwnership() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()

        let added = try fixture.store.addLabel(
            "Travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        XCTAssertEqual(added.labels, ["Travel"])
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source),
            [.user]
        )

        let removed = try fixture.store.removeLabel(
            "Travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )
        XCTAssertEqual(removed.labels, [])
    }

    func testIndependentSourcesKeepLabelEffectiveUntilLastOwnerLeaves() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )

        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
        XCTAssertEqual(
            Set(try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source)),
            [.rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: MessageID("m1")).map(\.labelID),
            ["travel"]
        )
    }

    func testManualReaddClearsExclusion() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )

        XCTAssertEqual(try fixture.store.labelExclusions(for: MessageID("m1")), [])
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source),
            [.user]
        )
    }

    func testLegacyStringMutationCreatesDefinitionAndUserOwnership() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()

        _ = try fixture.store.addLabel(
            "VIP",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )

        let definition = try XCTUnwrap(fixture.store.mailLabels(effectiveFor: nil).first {
            $0.normalizedTitle == "vip"
        })
        XCTAssertFalse(definition.isSmartInboxEnabled)
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1"))
                .first(where: { $0.labelID == definition.id })?.source,
            .user
        )
    }

    func testSmartInboxReplacementHonorsExclusionsAndPreservesOtherSources() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )

        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source),
            [.rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: MessageID("m1")).map(\.labelID),
            ["travel"]
        )
    }

    func testRuleReplacementTouchesOnlyNamedRuleOwnership() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.saveMailLabel(try label(
            id: "flights",
            title: "Flights",
            scope: .allAccounts
        ))
        try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r2",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["flights"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        let assignments = try fixture.store.labelAssignments(for: MessageID("m1"))
        XCTAssertEqual(
            Set(assignments.filter { $0.labelID == "travel" }.map(\.source)),
            [.user, .smartInbox, .rule(ruleID: "r2")]
        )
        XCTAssertEqual(
            assignments.filter { $0.labelID == "flights" }.map(\.source),
            [.rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Flights", "Travel"]
        )
    }

    func testLegacyAddFallsBackToTargetAccountWhenAnotherAccountBlocksGlobalTitle() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.saveMailLabel(try label(
            id: "personal-vip",
            title: "VIP",
            scope: .account(fixture.personal.id)
        ))

        _ = try fixture.store.addLabel(
            "vip",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )

        let workDefinition = try XCTUnwrap(
            fixture.store.mailLabels(effectiveFor: fixture.work.id).first {
                $0.normalizedTitle == "vip"
            }
        )
        XCTAssertEqual(workDefinition.scope, .account(fixture.work.id))
        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1"))
                .first(where: { $0.labelID == workDefinition.id })?.source,
            .user
        )
        XCTAssertEqual(
            try fixture.store.mailLabels(effectiveFor: fixture.personal.id)
                .filter { $0.normalizedTitle == "vip" }.map(\.id),
            ["personal-vip"]
        )
    }

    func testLegacyRemovePreservesRuleOwnershipAndCreatesSmartInboxExclusion() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        _ = try fixture.store.addLabel(
            "Trávél",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )

        _ = try fixture.store.removeLabel(
            "travel",
            from: MessageID("m1"),
            actor: LabelTestActors.user
        )

        XCTAssertEqual(
            try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source),
            [.rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: MessageID("m1")).map(\.labelID),
            ["travel"]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
    }

    func testSourceAwareMutationsEnforceLabelPermission() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        let restricted = Actor(
            id: "restricted",
            kind: .mcpAgent,
            displayName: "Restricted",
            permissions: .agentRequested(
                readBody: true,
                createDrafts: false,
                requestSend: false,
                addLabels: false
            )
        )

        XCTAssertThrowsError(try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: restricted
        ))
        XCTAssertThrowsError(try fixture.store.removeUserOrSmartInboxLabel(
            labelID: "travel",
            from: MessageID("m1"),
            actor: restricted
        ))
        XCTAssertThrowsError(try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: restricted
        ))
        XCTAssertThrowsError(try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: restricted
        ))
        XCTAssertEqual(try fixture.store.labelAssignments(for: MessageID("m1")), [])
    }

    func testAssignmentMutationRollsBackProjectionAndOwnershipWhenAuditFails() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.execute(
            """
            CREATE TRIGGER reject_label_assignment_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'mail_label.user_add'
            BEGIN
                SELECT RAISE(ABORT, 'forced audit failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.store.addUserLabel(
            labelID: "travel",
            to: MessageID("m1"),
            actor: LabelTestActors.user
        ))

        XCTAssertEqual(try fixture.store.labelAssignments(for: MessageID("m1")), [])
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            []
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                "SELECT labels FROM mail_search_documents WHERE message_id = 'm1'"
            ),
            [""]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                """
                SELECT labels FROM mail_search_fts
                WHERE rowid = (
                    SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'
                )
                """
            ),
            [""]
        )
    }

    func testEstablishUserLabelAtomicallyReplacesSmartInboxAndPreservesRuleOwnership() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.execute(
            """
            INSERT INTO message_label_exclusions (message_id, label_id, created_at)
            VALUES ('m1', 'travel', 100);
            """
        )

        try fixture.store.establishUserLabel(
            labelID: "travel",
            on: MessageID("m1"),
            actor: LabelTestActors.user
        )

        XCTAssertEqual(
            Set(try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source)),
            [.user, .rule(ruleID: "r1")]
        )
        XCTAssertEqual(try fixture.store.labelExclusions(for: MessageID("m1")), [])
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
    }

    func testEstablishUserLabelRollsBackAllOwnershipWhenAuditFails() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.replaceSmartInboxLabels(
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.store.replaceRuleLabels(
            ruleID: "r1",
            labelIDs: ["travel"],
            on: MessageID("m1"),
            actor: LabelTestActors.system
        )
        try fixture.execute(
            """
            INSERT INTO message_label_exclusions (message_id, label_id, created_at)
            VALUES ('m1', 'travel', 100);
            CREATE TRIGGER reject_establish_user_label_audit
            BEFORE INSERT ON audit_entries
            WHEN NEW.action = 'mail_label.user_establish'
            BEGIN
                SELECT RAISE(ABORT, 'forced audit failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.store.establishUserLabel(
            labelID: "travel",
            on: MessageID("m1"),
            actor: LabelTestActors.user
        ))

        XCTAssertEqual(
            Set(try fixture.store.labelAssignments(for: MessageID("m1")).map(\.source)),
            [.smartInbox, .rule(ruleID: "r1")]
        )
        XCTAssertEqual(
            try fixture.store.labelExclusions(for: MessageID("m1")).map(\.labelID),
            ["travel"]
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                "SELECT labels FROM mail_search_documents WHERE message_id = 'm1'"
            ),
            ["Travel"]
        )
    }

    func testAssignmentDecoderRejectsRuleOwnershipWithoutRuleID() throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.execute(
            """
            INSERT INTO message_label_assignments (
                message_id, label_id, source_kind, source_id, created_at
            ) VALUES ('m1', 'travel', 'rule', '', 100);
            """
        )

        XCTAssertThrowsError(
            try fixture.store.labelAssignments(for: MessageID("m1"))
        )
    }

    func testExistingStringLabelsBackfillAsGlobalUserOwnedDefinitions() throws {
        let fixture = try SQLiteMailLabelFixture(openAtMigrationBeforeV27: true)
        try fixture.insertCurrentMessage(
            id: "m1",
            labels: ["Travel", "travel", "VIP", "Trávél"]
        )

        try fixture.migrateToLatest()

        let labels = try fixture.store.mailLabels(effectiveFor: nil)
        XCTAssertEqual(Set(labels.map(\.normalizedTitle)), ["travel", "vip"])
        XCTAssertTrue(labels.allSatisfy {
            !$0.isSmartInboxEnabled && $0.description.isEmpty && $0.scope == .allAccounts
        })
        XCTAssertEqual(
            labels.first(where: { $0.normalizedTitle == "travel" })?.title,
            "Travel"
        )
        XCTAssertEqual(
            labels.first(where: { $0.normalizedTitle == "travel" })?.id,
            legacyLabelID(normalizedTitle: "travel")
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel", "VIP"]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                """
                SELECT source_kind || ':' || source_id
                FROM message_label_assignments
                WHERE message_id = 'm1'
                ORDER BY label_id
                """
            ),
            ["user:", "user:"]
        )
        XCTAssertEqual(
            try fixture.queryStrings(
                "SELECT labels FROM mail_search_documents WHERE message_id = 'm1'"
            ),
            ["Travel VIP"]
        )
        XCTAssertEqual(try fixture.store.searchMessages("Travel"), [MessageID("m1")])
        XCTAssertTrue(fixture.store.auditEntries.contains {
            $0.action == "mail_label.legacy_backfill"
                && $0.targetID == legacyLabelID(normalizedTitle: "travel")
                && $0.result.contains("Trávél")
                && $0.result.contains("travel")
        })

        let idsBeforeReopen = labels.map(\.id).sorted()
        let reopened = try fixture.reopenAndMigrate()
        XCTAssertEqual(try reopened.mailLabels(effectiveFor: nil).map(\.id).sorted(), idsBeforeReopen)
        XCTAssertEqual(
            try fixture.queryInteger("SELECT COUNT(*) FROM message_label_assignments"),
            2
        )
    }

    func testDefinitionScopeAndEffectiveTitleUniqueness() throws {
        let fixture = try SQLiteMailLabelFixture()
        let repository: any MailLabelDefinitionRepository = fixture.store
        try repository.saveMailLabel(try label(
            id: "global-travel",
            title: "Travel",
            scope: .allAccounts
        ))
        XCTAssertThrowsError(try repository.saveMailLabel(try label(
            id: "account-travel",
            title: "trávél",
            scope: .account(fixture.work.id)
        ))) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .duplicateEffectiveTitle)
        }

        try repository.saveMailLabel(try label(
            id: "account-vip-a",
            title: "VIP",
            scope: .account(fixture.work.id)
        ))
        try repository.saveMailLabel(try label(
            id: "account-vip-b",
            title: "vip",
            scope: .account(fixture.personal.id)
        ))

        XCTAssertEqual(
            try repository.mailLabels(effectiveFor: fixture.work.id).map(\.id),
            ["global-travel", "account-vip-a"]
        )
        XCTAssertEqual(
            try repository.mailLabels(effectiveFor: fixture.personal.id).map(\.id),
            ["global-travel", "account-vip-b"]
        )
        XCTAssertThrowsError(try repository.saveMailLabel(try label(
            id: "global-vip",
            title: "VIP",
            scope: .allAccounts
        ))) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .duplicateEffectiveTitle)
        }
    }

    func testDefinitionScopeIsImmutable() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "fixed-scope",
            title: "Travel",
            scope: .allAccounts
        ))

        XCTAssertThrowsError(try fixture.store.saveMailLabel(try label(
            id: "fixed-scope",
            title: "Travel",
            scope: .account(fixture.work.id)
        ))) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .immutableScope)
        }
        XCTAssertEqual(try fixture.store.mailLabel(id: "fixed-scope")?.scope, .allAccounts)
    }

    func testTwentyFifthEffectiveSmartLabelIsRejected() throws {
        let fixture = try SQLiteMailLabelFixture()
        for index in 0..<24 {
            try fixture.store.saveMailLabel(try label(
                id: "global-\(index)",
                title: "Global \(index)",
                description: "Description \(index)",
                isSmartInboxEnabled: true,
                scope: .allAccounts
            ))
        }

        XCTAssertThrowsError(try fixture.store.saveMailLabel(try label(
            id: "account-extra",
            title: "Extra",
            description: "Extra description",
            isSmartInboxEnabled: true,
            scope: .account(fixture.work.id)
        ))) { error in
            XCTAssertEqual(
                error as? MailLabelValidationError,
                .effectiveSmartInboxLimitExceeded(scope: .account(fixture.work.id))
            )
        }
        XCTAssertNil(try fixture.store.mailLabel(id: "account-extra"))
    }

    func testTwentyFifthGlobalSmartLabelNamesAllAccountsScope() throws {
        let fixture = try SQLiteMailLabelFixture()
        for index in 0..<24 {
            try fixture.store.saveMailLabel(try label(
                id: "global-\(index)",
                title: "Global \(index)",
                description: "Description \(index)",
                isSmartInboxEnabled: true,
                scope: .allAccounts
            ))
        }

        XCTAssertThrowsError(try fixture.store.saveMailLabel(try label(
            id: "global-extra",
            title: "Extra",
            description: "Extra description",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        ))) { error in
            XCTAssertEqual(
                error as? MailLabelValidationError,
                .effectiveSmartInboxLimitExceeded(scope: .allAccounts)
            )
        }
    }

    func testGlobalSmartLabelNamesAccountWhoseEffectiveLimitWouldBeExceeded() throws {
        let fixture = try SQLiteMailLabelFixture()
        for index in 0..<23 {
            try fixture.store.saveMailLabel(try label(
                id: "global-\(index)",
                title: "Global \(index)",
                description: "Description \(index)",
                isSmartInboxEnabled: true,
                scope: .allAccounts
            ))
        }
        try fixture.store.saveMailLabel(try label(
            id: "work-existing",
            title: "Work Existing",
            description: "Work description",
            isSmartInboxEnabled: true,
            scope: .account(fixture.work.id)
        ))

        XCTAssertThrowsError(try fixture.store.saveMailLabel(try label(
            id: "global-extra",
            title: "Extra",
            description: "Extra description",
            isSmartInboxEnabled: true,
            scope: .allAccounts
        ))) { error in
            XCTAssertEqual(
                error as? MailLabelValidationError,
                .effectiveSmartInboxLimitExceeded(scope: .account(fixture.work.id))
            )
        }
    }

    func testRenameRebuildsAssignedMessageAndSearchProjections() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "travel",
            title: "Travel",
            scope: .allAccounts
        ))
        try fixture.insertCurrentMessage(id: "m1", labels: ["Travel"])
        try fixture.execute(
            """
            INSERT INTO message_label_assignments (
                message_id, label_id, source_kind, source_id, created_at
            ) VALUES ('m1', 'travel', 'user', '', 100)
            """
        )
        let original = try XCTUnwrap(fixture.store.mailLabel(id: "travel"))

        try fixture.store.saveMailLabel(try label(
            id: original.id,
            title: "Journeys",
            scope: original.scope,
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Journeys"]
        )
        XCTAssertEqual(try fixture.store.searchMessages("Journeys"), [MessageID("m1")])
        XCTAssertTrue(try fixture.store.searchMessages("Travel").isEmpty)
        XCTAssertEqual(try fixture.store.mailLabel(id: "travel")?.createdAt, original.createdAt)
        XCTAssertTrue(fixture.store.auditEntries.contains {
            $0.action == "mail_label.update" && $0.targetID == "travel"
        })
    }

    func testSmartInboxEnablementUsesDefinitionValidationAndLimitChecks() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "empty-description",
            title: "Travel",
            scope: .allAccounts
        ))

        XCTAssertThrowsError(
            try fixture.store.setMailLabelSmartInboxEnabled(id: "empty-description", isEnabled: true)
        ) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .smartInboxDescriptionRequired)
        }
        XCTAssertThrowsError(
            try fixture.store.setMailLabelSmartInboxEnabled(id: "missing", isEnabled: true)
        ) { error in
            XCTAssertEqual(error as? MailLabelValidationError, .unknownLabel)
        }
    }

    func testSmartInboxEnablementDoesNotOverwriteRenameAtWriteBoundary() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "travel",
            title: "Travel",
            description: "Original description",
            scope: .allAccounts
        ))
        try fixture.execute(
            """
            CREATE TRIGGER concurrent_label_rename
            BEFORE UPDATE OF smart_inbox_enabled ON mail_labels
            WHEN OLD.id = 'travel' AND NEW.smart_inbox_enabled = 1
            BEGIN
                UPDATE mail_labels
                SET title = 'Journeys',
                    normalized_title = 'journeys',
                    description = 'Renamed at write boundary',
                    updated_at = 150
                WHERE id = OLD.id;
            END;
            """
        )

        try fixture.store.setMailLabelSmartInboxEnabled(id: "travel", isEnabled: true)

        let stored = try XCTUnwrap(fixture.store.mailLabel(id: "travel"))
        XCTAssertEqual(stored.title, "Journeys")
        XCTAssertEqual(stored.normalizedTitle, "journeys")
        XCTAssertEqual(stored.description, "Renamed at write boundary")
        XCTAssertTrue(stored.isSmartInboxEnabled)
        XCTAssertGreaterThan(stored.updatedAt, Date(timeIntervalSince1970: 150))
    }

    func testDeletionPreviewAndDeleteCleanAssignmentsRulesAndProjections() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "travel",
            title: "Travel",
            scope: .allAccounts
        ))
        try fixture.insertCurrentMessage(id: "m1", labels: ["Travel"])
        try fixture.execute(
            """
            INSERT INTO message_label_assignments (
                message_id, label_id, source_kind, source_id, created_at
            ) VALUES ('m1', 'travel', 'user', '', 100);
            INSERT INTO mail_rules (
                id, name, is_enabled, scope_account_id, created_at, updated_at
            ) VALUES
                ('label-only', 'Label only', 1, NULL, 100, 100),
                ('mixed', 'Mixed', 1, NULL, 100, 100);
            INSERT INTO mail_rule_actions (rule_id, action)
            VALUES ('mixed', 'markAsRead');
            INSERT INTO mail_rule_label_actions (rule_id, label_id, ordinal)
            VALUES
                ('label-only', 'travel', 0),
                ('mixed', 'travel', 0);
            """
        )

        XCTAssertEqual(
            try fixture.store.previewMailLabelDeletion(id: "travel"),
            MailLabelDeletionPreview(
                labelID: "travel",
                scope: .allAccounts,
                affectedMessageCount: 1,
                affectedRuleCount: 2
            )
        )

        try fixture.store.deleteMailLabel(id: "travel")

        XCTAssertNil(try fixture.store.mailLabel(id: "travel"))
        XCTAssertEqual(try fixture.queryInteger("SELECT COUNT(*) FROM message_label_assignments"), 0)
        XCTAssertEqual(try fixture.queryInteger("SELECT COUNT(*) FROM mail_rule_label_actions"), 0)
        XCTAssertEqual(
            try fixture.queryInteger("SELECT is_enabled FROM mail_rules WHERE id = 'label-only'"),
            0
        )
        XCTAssertEqual(
            try fixture.queryInteger("SELECT is_enabled FROM mail_rules WHERE id = 'mixed'"),
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            []
        )
        XCTAssertTrue(try fixture.store.searchMessages("Travel").isEmpty)
        XCTAssertTrue(fixture.store.auditEntries.contains {
            $0.action == "mail_label.delete" && $0.targetID == "travel"
        })
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.auditEntries.last {
                $0.action == "mail_label.delete" && $0.targetID == "travel"
            }).result,
            """
            {"affectedMessageCount":1,"affectedRuleCount":2,"exclusionCount":0,"labelID":"travel","ruleAssignmentCount":0,"scope":"allAccounts","smartInboxAssignmentCount":0,"title":"Travel","userAssignmentCount":1}
            """
        )
    }

    func testDeletionRollsBackAllCleanupWhenDefinitionDeleteFails() throws {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try label(
            id: "travel",
            title: "Travel",
            scope: .allAccounts
        ))
        try fixture.insertCurrentMessage(id: "m1", labels: ["Travel"])
        try fixture.execute(
            """
            INSERT INTO message_label_assignments (
                message_id, label_id, source_kind, source_id, created_at
            ) VALUES ('m1', 'travel', 'user', '', 100);
            INSERT INTO mail_rules (
                id, name, is_enabled, scope_account_id, created_at, updated_at
            ) VALUES ('label-only', 'Label only', 1, NULL, 100, 100);
            INSERT INTO mail_rule_label_actions (rule_id, label_id, ordinal)
            VALUES ('label-only', 'travel', 0);
            CREATE TRIGGER reject_travel_delete
            BEFORE DELETE ON mail_labels
            WHEN OLD.id = 'travel'
            BEGIN
                SELECT RAISE(ABORT, 'forced delete failure');
            END;
            """
        )

        XCTAssertThrowsError(try fixture.store.deleteMailLabel(id: "travel"))

        XCTAssertNotNil(try fixture.store.mailLabel(id: "travel"))
        XCTAssertEqual(try fixture.queryInteger("SELECT COUNT(*) FROM message_label_assignments"), 1)
        XCTAssertEqual(try fixture.queryInteger("SELECT COUNT(*) FROM mail_rule_label_actions"), 1)
        XCTAssertEqual(
            try fixture.queryInteger("SELECT is_enabled FROM mail_rules WHERE id = 'label-only'"),
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture.store.messages.first { $0.id == MessageID("m1") }).labels,
            ["Travel"]
        )
    }

    func testActionSnapshotUsesMessageAccountWhenMailboxMembershipIsMissing() async throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        try fixture.store.saveMailLabel(try label(
            id: "work-only",
            title: "Work only",
            scope: .account(fixture.work.id)
        ))
        try fixture.store.saveMailLabel(try label(
            id: "personal-only",
            title: "Personal only",
            scope: .account(fixture.personal.id)
        ))
        try fixture.execute(
            "DELETE FROM mailbox_messages WHERE message_id = 'm1';"
        )

        let snapshot = try await fixture.store.messageLabelActionSnapshot(
            for: MessageID("m1")
        )

        XCTAssertEqual(snapshot.accountID, fixture.work.id)
        XCTAssertEqual(
            Set(snapshot.labels.map(\.id)),
            ["travel", "work-only"]
        )
    }

    func testActionSnapshotUsesThreadAccountWhenMembershipAndMessageAccountAreMissing() async throws {
        let fixture = try SQLiteMailLabelFixture.seeded()
        let legacyThread = MailThread(
            id: ThreadID("legacy-thread"),
            accountID: fixture.work.id,
            subjectNormalized: "legacy thread",
            participantEmails: [fixture.work.email]
        )
        try fixture.store.cacheThread(legacyThread)
        try fixture.store.saveMailLabel(try label(
            id: "work-only",
            title: "Work only",
            scope: .account(fixture.work.id)
        ))
        try fixture.store.saveMailLabel(try label(
            id: "personal-only",
            title: "Personal only",
            scope: .account(fixture.personal.id)
        ))
        try fixture.execute(
            """
            DELETE FROM mailbox_messages WHERE message_id = 'm1';
            UPDATE messages
            SET account_id = NULL,
                thread_id = 'legacy-thread'
            WHERE id = 'm1';
            """
        )

        let snapshot = try await fixture.store.messageLabelActionSnapshot(
            for: MessageID("m1")
        )

        XCTAssertEqual(snapshot.accountID, fixture.work.id)
        XCTAssertEqual(
            Set(snapshot.labels.map(\.id)),
            ["travel", "work-only"]
        )
    }

    private func label(
        id: String,
        title: String,
        description: String = "",
        isSmartInboxEnabled: Bool = false,
        scope: MailLabelScope,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) throws -> MailLabelDefinition {
        try MailLabelDefinition.validated(
            id: id,
            title: title,
            description: description,
            isSmartInboxEnabled: isSmartInboxEnabled,
            scope: scope,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func legacyLabelID(normalizedTitle: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedTitle.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "legacy-label-\(digest)"
    }
}

private final class SQLiteMailLabelFixture {
    let url: URL
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

    init(openAtMigrationBeforeV27: Bool = false) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-labels-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([work, personal])
        if openAtMigrationBeforeV27 {
            try execute(
                """
                DROP TABLE IF EXISTS smart_inbox_label_catalog_snapshots;
                DROP TABLE IF EXISTS mail_rule_label_actions;
                DROP TABLE IF EXISTS message_label_exclusions;
                DROP TABLE IF EXISTS message_label_assignments;
                DROP TABLE IF EXISTS mail_labels;
                ALTER TABLE smart_inbox_work_items DROP COLUMN catalog_fingerprint;
                ALTER TABLE smart_inbox_work_items DROP COLUMN label_matches_json;
                ALTER TABLE smart_inbox_classification_cache DROP COLUMN catalog_fingerprint;
                ALTER TABLE smart_inbox_classification_cache DROP COLUMN label_matches_json;
                DELETE FROM grdb_migrations WHERE identifier = 'v27-smart-inbox-labels';
                """
            )
        }
    }

    static func seeded() throws -> SQLiteMailLabelFixture {
        let fixture = try SQLiteMailLabelFixture()
        try fixture.store.saveMailLabel(try MailLabelDefinition.validated(
            id: "travel",
            title: "Travel",
            description: "Trips and travel",
            isSmartInboxEnabled: true,
            scope: .allAccounts,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        _ = try fixture.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("m1"),
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                subject: "Travel plans",
                preview: "Preview",
                smartCategory: .personal
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: fixture.work.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        return fixture
    }

    deinit {
        let auditLogURL = store.auditLogURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: auditLogURL)
        for index in 1...4 {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: "\(auditLogURL.path).\(index)")
            )
        }
        let lockURL = auditLogURL.deletingLastPathComponent()
            .appendingPathComponent(
                auditLogURL.lastPathComponent.replacingOccurrences(of: ".log", with: ".lock")
            )
        try? FileManager.default.removeItem(at: lockURL)
    }

    func migrateToLatest() throws {
        try store.migrate()
    }

    func reopenAndMigrate() throws -> SQLiteMailStore {
        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        return reopened
    }

    func insertCurrentMessage(id: String, labels: [String]) throws {
        let escapedID = id.replacingOccurrences(of: "'", with: "''")
        let escapedAccountID = work.id.rawValue.replacingOccurrences(of: "'", with: "''")
        let labelsJSON = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        let projectedLabels = labels.joined(separator: " ")
            .replacingOccurrences(of: "'", with: "''")
        try execute(
            """
            INSERT INTO messages (
                id, account_id, from_email, subject, preview, smart_category, labels_json
            ) VALUES (
                '\(escapedID)', '\(escapedAccountID)', 'sender@example.com',
                '\(escapedID)', 'Preview', 'personal', '\(labelsJSON)'
            );
            INSERT INTO mail_search_documents (
                message_id, account_id, sort_date, sender, sender_email, subject,
                labels, is_seen, is_flagged, is_delegated, is_deleted, is_trash,
                is_inbox, is_sent, has_attachments, has_documents
            ) VALUES (
                '\(escapedID)', '\(escapedAccountID)', 0, 'sender@example.com',
                'sender@example.com', '\(escapedID)', '\(projectedLabels)',
                0, 0, 0, 0, 0, 1, 0, 0, 0
            );
            """
        )
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not execute SQLite statement.")
        }
    }

    func queryInteger(_ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PlainpostError.validationFailed("SQLite query returned no row.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func queryStrings(_ sql: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else {
                throw PlainpostError.validationFailed("SQLite query returned a non-text value.")
            }
            values.append(String(cString: value))
        }
        return values
    }
}
