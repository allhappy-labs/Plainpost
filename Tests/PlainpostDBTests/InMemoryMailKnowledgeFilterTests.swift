import XCTest
@testable import PlainpostCore
@testable import PlainpostDB

final class InMemoryMailKnowledgeFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ id: String, seen: Bool = false, category: SmartCategory = .notification,
                         mailbox: String = "INBOX", from: String = "noreply@github.com",
                         daysAgo: Double = 1, subject: String = "Hello") -> MessageSummary {
        MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress(from), subject: subject,
                       preview: subject, smartCategory: category, labels: [], isSeen: seen,
                       mailboxPath: mailbox, isDeleted: false,
                       sentAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testFiltersUnreadMailboxSenderDateAndCategory() throws {
        let store = InMemoryMailStore(messages: [
            message("unread-inbox"),
            message("read-inbox", seen: true),
            message("unread-sent", mailbox: "Sent"),
            message("old", daysAgo: 30),
            message("news", category: .newsletter),
            message("lena", from: "lena@example.com"),
        ])
        let filter = MailKnowledgeFilter(unreadOnly: true, mailbox: .inbox, senderContains: "github",
                                         sentAfter: now.addingTimeInterval(-7 * 86_400), sentBefore: nil,
                                         categories: [.notification])
        let result = try store.filteredMailMessages(filter, accountID: nil, limit: 10)
        XCTAssertEqual(result.messages.map(\.id), [MessageID("unread-inbox")])
        XCTAssertEqual(result.totalCount, 1)
    }

    func testTotalCountIgnoresLimitAndOrderIsNewestFirst() throws {
        let store = InMemoryMailStore(messages: (0..<5).map { message("m\($0)", daysAgo: Double($0)) })
        let result = try store.filteredMailMessages(MailKnowledgeFilter(unreadOnly: true), accountID: nil, limit: 2)
        XCTAssertEqual(result.totalCount, 5)
        XCTAssertEqual(result.messages.map(\.id), [MessageID("m0"), MessageID("m1")])
    }

    func testRankedSearchAppliesFilter() throws {
        let store = InMemoryMailStore(messages: [
            message("unread", subject: "Quarterly invoice"),
            message("read", seen: true, subject: "Quarterly invoice"),
        ])
        let results = try store.rankedMailSearch(MailKnowledgeQuery(
            text: "invoice", filter: MailKnowledgeFilter(unreadOnly: true)))
        XCTAssertEqual(results.map(\.message.id), [MessageID("unread")])
    }

    func testAnyMailboxListExcludesTrashAndJunk() throws {
        let store = InMemoryMailStore(messages: [
            message("inbox"), message("trash", mailbox: "Trash"), message("deleted", mailbox: "Deleted Items"),
            message("junk", mailbox: "Junk"), message("spam", mailbox: "[Gmail]/Spam"),
            message("archived", mailbox: "Archive"),
        ])
        let result = try store.filteredMailMessages(MailKnowledgeFilter(unreadOnly: true), accountID: nil, limit: 10)
        XCTAssertEqual(Set(result.messages.map(\.id)), Set([MessageID("inbox"), MessageID("archived")]))
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(try store.filteredMailCategoryCounts(MailKnowledgeFilter(unreadOnly: true), accountID: nil),
                       [.notification: 2])
    }

    func testCategoryCountsGroupEveryMatchRegardlessOfLimit() throws {
        let store = InMemoryMailStore(messages: (0..<7).map { message("n\($0)") }
            + (0..<3).map { message("l\($0)", category: .newsletter) }
            + [message("read", seen: true)])
        let counts = try store.filteredMailCategoryCounts(MailKnowledgeFilter(unreadOnly: true), accountID: nil)
        XCTAssertEqual(counts, [.notification: 7, .newsletter: 3])
    }

    func testConversationMessagesByKeyAreAccountScoped() throws {
        let threaded = { (id: String, thread: String) in
            MessageSummary(id: MessageID(id), threadID: ThreadID(thread), from: EmailAddress("a@example.com"),
                           subject: "S", preview: "S", smartCategory: .personal, sentAt: self.now)
        }
        let mine = threaded("mine", "thr_1"), theirs = threaded("theirs", "thr_1"), other = threaded("other", "thr_2")
        let store = InMemoryMailStore(
            messages: [mine, theirs, other, message("single")],
            memberships: [
                MailboxMessageMembership(accountID: AccountID("a"), mailboxPath: "INBOX", uidValidity: 1, uid: 1, messageID: mine.id),
                MailboxMessageMembership(accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 1, uid: 2, messageID: theirs.id),
            ])
        XCTAssertEqual(Set(try store.conversationMessages(conversationKey: "thr_1", accountID: nil).map(\.id)),
                       Set([mine.id, theirs.id]))
        XCTAssertEqual(try store.conversationMessages(conversationKey: "thr_1", accountID: AccountID("a")).map(\.id), [mine.id])
        XCTAssertEqual(try store.conversationMessages(conversationKey: "message_single", accountID: nil).map(\.id),
                       [MessageID("single")])
    }
}
