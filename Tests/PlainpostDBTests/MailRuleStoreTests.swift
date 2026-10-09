import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations

final class MailRuleStoreTests: XCTestCase {
    func testEffectiveAccountRulesIncludeGlobalAndSelectedAccountOnly() throws {
        let fixture = try StoreFixture()
        try fixture.store.saveMailRule(try rule(id: "global", name: "A Global", scope: .allAccounts))
        try fixture.store.saveMailRule(try rule(id: "work", name: "B Work", scope: .account(fixture.work.id)))
        try fixture.store.saveMailRule(try rule(
            id: "personal",
            name: "C Personal",
            scope: .account(fixture.personal.id)
        ))

        XCTAssertEqual(
            try fixture.store.mailRules(effectiveFor: fixture.work.id).map(\.id),
            ["global", "work"]
        )
        XCTAssertEqual(
            Set(try fixture.store.mailRules(effectiveFor: nil).map(\.id)),
            ["global", "work", "personal"]
        )
    }

    func testSavingRuleReplacesConditionsAndActionsTransactionally() throws {
        let fixture = try StoreFixture()
        var value = try rule(id: "editable", name: "Editable", scope: .allAccounts)
        try fixture.store.saveMailRule(value)
        value.conditions = [.init(field: .subject, operator: .contains, value: "Invoice")]
        value.actions = [.skipInbox, .markAsRead]
        value.updatedAt = Date(timeIntervalSince1970: 200)

        try fixture.store.saveMailRule(value)

        let loaded = try XCTUnwrap(fixture.store.mailRule(id: "editable"))
        XCTAssertEqual(loaded.conditions, value.conditions)
        XCTAssertEqual(loaded.actions, [.skipInbox, .markAsRead])
        XCTAssertEqual(loaded.updatedAt, value.updatedAt)
    }

    func testEnablementAndDeletionUpdateStoredRules() throws {
        let fixture = try StoreFixture()
        try fixture.store.saveMailRule(try rule(id: "mutable", name: "Mutable", scope: .allAccounts))

        try fixture.store.setMailRuleEnabled(id: "mutable", isEnabled: false)
        XCTAssertEqual(try fixture.store.mailRule(id: "mutable")?.isEnabled, false)

        try fixture.store.deleteMailRule(id: "mutable")
        XCTAssertNil(try fixture.store.mailRule(id: "mutable"))
    }

    func testMailboxListMessageIDsCanBeScopedToOneAccount() throws {
        let fixture = try StoreFixture()
        try fixture.insertInboxMessage(id: "msg-work", account: fixture.work, uid: 1)
        try fixture.insertInboxMessage(id: "msg-personal", account: fixture.personal, uid: 2)

        XCTAssertEqual(
            try fixture.store.mailboxListMessageIDs(
                accountID: fixture.work.id,
                inMailboxPath: "INBOX"
            ),
            [MessageID("msg-work")]
        )
        XCTAssertEqual(
            try fixture.store.mailboxListMessageIDs(
                accountID: fixture.personal.id,
                inMailboxPath: "INBOX"
            ),
            [MessageID("msg-personal")]
        )
    }

    func testEnqueueMailRuleActionsDeduplicatesAcrossMatchingRules() throws {
        let fixture = try StoreFixture()
        try fixture.store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx-work-inbox"),
                accountID: fixture.work.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
            Mailbox(
                id: MailboxID("mbx-work-archive"),
                accountID: fixture.work.id,
                name: "Archive",
                path: "Archive",
                specialUse: "\\Archive"
            ),
        ])
        try fixture.insertInboxMessage(id: "msg-inbox", account: fixture.work, uid: 7)

        let inserted = try fixture.store.enqueueMailRuleActions(
            messageID: MessageID("msg-inbox"),
            accountID: fixture.work.id,
            actions: [.skipInbox, .markAsRead, .suppressNotification],
            sourceRuleIDs: ["global", "work"]
        )

        XCTAssertEqual(
            Set(inserted.map(\.action)),
            [.skipInbox, .markAsRead, .suppressNotification]
        )
        XCTAssertTrue(try fixture.store.enqueueMailRuleActions(
            messageID: MessageID("msg-inbox"),
            accountID: fixture.work.id,
            actions: [.skipInbox, .markAsRead, .suppressNotification],
            sourceRuleIDs: ["work"]
        ).isEmpty)
        XCTAssertTrue(try fixture.store.hasMailRuleAction(
            .suppressNotification,
            messageID: MessageID("msg-inbox")
        ))
        XCTAssertTrue(try XCTUnwrap(
            fixture.store.messages.first { $0.id == MessageID("msg-inbox") }
        ).isSeen)
        XCTAssertFalse(try fixture.store.mailboxListMessageIDs(
            accountID: fixture.work.id,
            inMailboxPath: "INBOX"
        ).contains(MessageID("msg-inbox")))
        XCTAssertFalse(try fixture.store.mailboxListMessageIDs(
            inMailboxPath: "INBOX"
        ).contains(MessageID("msg-inbox")))
        XCTAssertFalse(try fixture.store.mailboxListMessages(
            inMailboxPath: "INBOX"
        ).contains { $0.id == MessageID("msg-inbox") })
        XCTAssertEqual(
            try fixture.store.mailboxListMessageCount(inMailboxPath: "INBOX", query: ""),
            0
        )
        XCTAssertEqual(
            try fixture.store.jobs().filter { $0.state == .queued }
                .map(\.kind).sorted { $0.rawValue < $1.rawValue },
            [.mailboxArchive, .mailboxFlag]
        )
    }

    func testSelectedDirectRuleActionsKeepEnqueueGenerationForFlagAndArchive() throws {
        let fixture = try StoreFixture()
        let account = fixture.work
        _ = try fixture.store.replaceMailSource(AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil,
            nodeID: nil, logicalMailboxID: nil,
            providerIdentity: nil, generation: 1
        ), expectedGeneration: 0)
        try fixture.store.cacheMailboxes([
            Mailbox(id: MailboxID("rule-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("rule-archive"), accountID: account.id,
                    name: "Archive", path: "Archive", specialUse: "\\Archive")
        ])
        try fixture.insertInboxMessage(id: "rule-versioned", account: account, uid: 17)

        let records = try fixture.store.enqueueMailRuleActions(
            messageID: MessageID("rule-versioned"), accountID: account.id,
            actions: [.markAsRead, .skipInbox], sourceRuleIDs: ["rule"],
            expectedDirectSourceGeneration: 1
        )
        let jobs = try records.flatMap(\.durableJobIDs).map { try fixture.store.job(id: $0) }
        XCTAssertEqual(jobs.count, 2)
        for job in jobs {
            let payload = Data(job.payloadJSON.utf8)
            if job.kind == .mailboxFlag {
                XCTAssertEqual(try JSONDecoder().decode(
                    PlainpostMailboxFlagInput.self, from: payload
                ).expectedDirectSourceGeneration, 1)
            } else {
                XCTAssertEqual(try JSONDecoder().decode(
                    PlainpostMailboxArchiveInput.self, from: payload
                ).expectedDirectSourceGeneration, 1)
            }
        }
    }

    private func rule(id: String, name: String, scope: MailRuleScope) throws -> MailRule {
        try MailRule.validated(
            id: id,
            name: name,
            scope: scope,
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.suppressNotification],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private final class StoreFixture {
    let store: SQLiteMailStore
    let url: URL
    let work = Account(
        id: AccountID("acc-work"),
        displayName: "Work",
        email: EmailAddress("me@work.example"),
        imapHost: "imap.work.example",
        smtpHost: "smtp.work.example"
    )
    let personal = Account(
        id: AccountID("acc-personal"),
        displayName: "Personal",
        email: EmailAddress("me@personal.example"),
        imapHost: "imap.personal.example",
        smtpHost: "smtp.personal.example"
    )

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-rules-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([work, personal])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func insertInboxMessage(id: String, account: Account, uid: Int) throws {
        try store.cacheMessageReliably(MessageSummary(
            id: MessageID(id),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: id,
            preview: "Preview",
            smartCategory: .personal
        ))
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: uid,
            messageID: MessageID(id)
        )
    }
}
