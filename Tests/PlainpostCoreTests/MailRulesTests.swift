import XCTest
@testable import PlainpostCore

final class MailRulesTests: XCTestCase {
    func testDomainMatchesExactDomainAndSubdomainWithoutSuffixCollision() throws {
        let rule = try MailRule.validated(
            id: "rule-domain",
            name: "Build mail",
            scope: .allAccounts,
            conditions: [.init(field: .from, operator: .domainIs, value: "@example.com")],
            actions: [.suppressNotification]
        )

        XCTAssertEqual(actions(rule, from: "bot@example.com"), [.suppressNotification])
        XCTAssertEqual(actions(rule, from: "bot@ci.example.com"), [.suppressNotification])
        XCTAssertTrue(actions(rule, from: "bot@notexample.com").isEmpty)
    }

    func testConditionsUseANDAndMatchingRulesMergeActions() throws {
        let accountID = AccountID("acc-work")
        let first = try MailRule.validated(
            id: "rule-one",
            name: "Receipts",
            scope: .account(accountID),
            conditions: [
                .init(field: .from, operator: .domainIs, value: "billing.example"),
                .init(field: .subject, operator: .contains, value: "Receipt")
            ],
            actions: [.skipInbox, .markAsRead]
        )
        let second = try MailRule.validated(
            id: "rule-two",
            name: "Quiet billing",
            scope: .allAccounts,
            conditions: [.init(field: .recipients, operator: .emailIs, value: "me@work.example")],
            actions: [.markAsRead, .suppressNotification]
        )
        let message = fixture(
            from: "notices@billing.example",
            subject: "Your Receipt",
            to: ["me@work.example"]
        )

        XCTAssertEqual(
            MailRuleEvaluator.actions(for: message, accountID: accountID, rules: [first, second]),
            [.skipInbox, .markAsRead, .suppressNotification]
        )
    }

    func testValidationRejectsMissingFieldsAndInvalidOperatorPairing() {
        XCTAssertThrowsError(try MailRule.validated(
            id: "invalid",
            name: " ",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: " ")],
            actions: []
        ))
        XCTAssertThrowsError(try MailRule.validated(
            id: "invalid-pair",
            name: "Invalid pair",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .domainIs, value: "example.com")],
            actions: [.skipInbox]
        ))
    }

    func testDisabledAndOtherAccountRulesDoNotMatch() throws {
        let selectedAccount = AccountID("acc-work")
        let disabled = try MailRule.validated(
            id: "disabled",
            name: "Disabled",
            isEnabled: false,
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "Build")],
            actions: [.skipInbox]
        )
        let otherAccount = try MailRule.validated(
            id: "other-account",
            name: "Other account",
            scope: .account(AccountID("acc-personal")),
            conditions: [.init(field: .subject, operator: .contains, value: "Build")],
            actions: [.markAsRead]
        )

        XCTAssertTrue(MailRuleEvaluator.actions(
            for: fixture(from: "bot@example.com", subject: "Build", to: []),
            accountID: selectedAccount,
            rules: [disabled, otherAccount]
        ).isEmpty)
    }

    func testValidationNormalizesEmailAndDomainValues() throws {
        let rule = try MailRule.validated(
            id: "normalized",
            name: "Normalized",
            scope: .allAccounts,
            conditions: [
                .init(field: .from, operator: .emailIs, value: " Sender@Example.COM "),
                .init(field: .recipients, operator: .domainIs, value: " @WORK.Example ")
            ],
            actions: [.markAsRead]
        )

        XCTAssertEqual(rule.conditions.map(\.value), ["sender@example.com", "work.example"])
    }

    func testLabelOnlyEnabledRuleIsValid() throws {
        let rule = try MailRule.validated(
            name: "Travel",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: ["label-travel"]
        )

        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.labelIDs, ["label-travel"])
    }

    func testEnabledRuleWithoutAnyActionIsInvalidButDisabledRepairStateIsValid() throws {
        XCTAssertThrowsError(try MailRule.validated(
            name: "Needs repair",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: []
        ))
        let disabled = try MailRule.validated(
            name: "Needs repair",
            isEnabled: false,
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: []
        )
        XCTAssertFalse(disabled.isEnabled)
    }

    func testRuleLabelIDsAreUniqueSortedAndDefaultToEmpty() throws {
        let labeled = try MailRule.validated(
            name: "Sorted labels",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [],
            labelIDs: ["label-z", "label-a", "label-z"]
        )
        let existingCaller = try MailRule.validated(
            name: "Existing caller",
            scope: .allAccounts,
            conditions: [.init(field: .subject, operator: .contains, value: "flight")],
            actions: [.markAsRead]
        )

        XCTAssertEqual(labeled.labelIDs, ["label-a", "label-z"])
        XCTAssertEqual(existingCaller.labelIDs, [])
    }

    private func actions(_ rule: MailRule, from: String) -> Set<MailRuleAction> {
        MailRuleEvaluator.actions(
            for: fixture(from: from, subject: "Build", to: []),
            accountID: AccountID("acc-work"),
            rules: [rule]
        )
    }

    private func fixture(from: String, subject: String, to: [String]) -> MessageSummary {
        MessageSummary(
            id: MessageID("msg-fixture"),
            threadID: nil,
            from: EmailAddress(from),
            subject: subject,
            preview: "Preview",
            smartCategory: .notification,
            labels: [],
            isSeen: false,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Body",
            to: to.map { EmailAddress($0) },
            cc: []
        )
    }
}
