import PlainpostCore
@testable import PlainpostDB
import XCTest

final class MailboxAccountSetFilterTests: XCTestCase {
    private func seededStore() throws -> (SQLiteMailStore, [AccountID]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-set-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let ids = ["a", "b", "c"].map { AccountID("acc_set_\($0)") }
        try store.cacheAccounts(ids.map {
            Account(id: $0, displayName: $0.rawValue, email: EmailAddress("\($0.rawValue)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        })
        for (index, id) in ids.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID("msg_\(id.rawValue)"), threadID: ThreadID("thr_\(id.rawValue)"),
                               from: EmailAddress("sender@example.com"), subject: "Hello \(id.rawValue)",
                               preview: "p", smartCategory: .personal,
                               sentAt: Date(timeIntervalSince1970: TimeInterval(index + 1))),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: id, mailboxPath: "INBOX", uidValidity: 1, uid: index + 1,
                notificationEligible: false
            )
        }
        return (store, ids)
    }

    func testInboxRowsCarryTheirOwningAccount() throws {
        let (store, ids) = try seededStore()
        let rows = try store.mailboxListMessages(inMailboxPath: "INBOX", accountID: nil, limit: 10, query: "")
        XCTAssertEqual(Set(rows.compactMap(\.accountID)), Set(ids))
        XCTAssertEqual(rows.first { $0.id == MessageID("msg_acc_set_b") }?.accountID, ids[1])
    }

    func testAccountSetFilterKeepsOnlyListedAccounts() throws {
        let (store, ids) = try seededStore()
        let filter = MailboxAccountFilter.accounts([ids[0], ids[2]])
        let rows = try store.mailboxListMessages(inMailboxPath: "INBOX", accountFilter: filter, limit: 10, query: "")
        XCTAssertEqual(rows.map(\.id), [MessageID("msg_acc_set_c"), MessageID("msg_acc_set_a")])
        XCTAssertEqual(try store.mailboxListMessageCount(inMailboxPath: "INBOX", accountFilter: filter, query: ""), 2)
        XCTAssertEqual(
            try store.mailboxUnreadConversationCounts(inMailboxPath: "INBOX", accountFilter: filter, query: "").total, 2
        )
        XCTAssertEqual(
            Set(try store.notificationMessageIDs(accountFilter: filter, after: nil, limit: 10)),
            [MessageID("msg_acc_set_a"), MessageID("msg_acc_set_c")]
        )
    }

    func testEmptyAccountSetReturnsNothing() throws {
        let (store, _) = try seededStore()
        XCTAssertTrue(
            try store.mailboxListMessages(inMailboxPath: "INBOX", accountFilter: .accounts([]), limit: 10, query: "").isEmpty
        )
        XCTAssertEqual(try store.mailboxListMessageCount(inMailboxPath: "INBOX", accountFilter: .accounts([]), query: ""), 0)
        XCTAssertEqual(try store.sentMailboxListMessageCount(accountFilter: .accounts([]), query: ""), 0)
    }
}
