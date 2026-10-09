import XCTest
import SQLite3
import PlainpostCore
import PlainpostTestSupport
@testable import PlainpostDB

final class SQLiteMailStoreDirectoryTests: XCTestCase {
    func testFolderUnreadCountsCountUnreadNonDeletedPerPath() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        let entries: [(String, String, Bool)] = [("a", "INBOX", false), ("b", "INBOX", false), ("c", "INBOX", true), ("d", "Archive", false)]
        for (index, entry) in entries.enumerated() {
            try commit(store, id: entry.0, path: entry.1, seen: entry.2, account: account.id, uid: index + 1)
        }
        XCTAssertEqual(try store.folderUnreadCounts(accountID: account.id), ["INBOX": 2, "Archive": 1])
    }

    func testFolderUnreadCountsListReadFoldersSkipDeletedAndStayInTheirAccount() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount.id
        let other = AccountID("acc_other")
        try commit(store, id: "read", path: "Receipts", seen: true, account: account, uid: 1)
        try commit(store, id: "deleted", path: "INBOX", seen: false, deleted: true, account: account, uid: 2)
        try commit(store, id: "unread", path: "INBOX", seen: false, account: account, uid: 3)
        try commit(store, id: "elsewhere", path: "INBOX", seen: false, account: other, uid: 4)
        try commit(store, id: "elsewhere-only", path: "Projects", seen: false, account: other, uid: 5)

        XCTAssertEqual(
            try store.folderUnreadCounts(accountID: account),
            ["INBOX": 1, "Receipts": 0],
            "a folder with only read mail is still listed, with no unread"
        )
        XCTAssertEqual(try store.folderUnreadCounts(accountID: other), ["INBOX": 1, "Projects": 1])
    }

    func testFolderUnreadCountsLeaveOutMessagesARuleKeptOutOfTheInbox() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        try commit(store, id: "kept", path: "INBOX", seen: false, account: account.id, uid: 1)
        try commit(store, id: "skipped", path: "INBOX", seen: false, account: account.id, uid: 2)
        _ = try store.enqueueMailRuleActions(
            messageID: MessageID("skipped"), accountID: account.id,
            actions: [.skipInbox], sourceRuleIDs: ["rule"]
        )

        XCTAssertEqual(try store.mailboxListMessageCount(inMailboxPath: "INBOX", accountID: account.id, query: ""), 1)
        XCTAssertEqual(try store.folderUnreadCounts(accountID: account.id), ["INBOX": 1])
    }

    func testFolderUnreadCountsFallBackToMessagePathsWithoutMemberships() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        let rows: [(id: String, account: Account, path: String, seen: Bool, deleted: Bool)] = [
            ("a1", accounts[0], "INBOX", false, false),
            ("a2", accounts[0], "INBOX", false, false),
            ("a3", accounts[0], "Archive", true, false),
            ("a4", accounts[0], "Archive", false, true),
            ("b1", accounts[1], "INBOX", false, false),
        ]
        for row in rows {
            let threadID = ThreadID("legacy-\(row.id)")
            try store.cacheThread(MailThread(
                id: threadID, accountID: row.account.id, subjectNormalized: "legacy",
                participantEmails: [row.account.email]
            ))
            try store.cacheMessage(MessageSummary(
                id: MessageID(row.id), threadID: threadID, from: row.account.email,
                subject: "Legacy", preview: "Legacy row",
                smartCategory: .personal, labels: [], isSeen: row.seen,
                mailboxPath: row.path, isDeleted: row.deleted
            ))
        }

        XCTAssertEqual(try store.folderUnreadCounts(accountID: accounts[0].id), ["INBOX": 2, "Archive": 0])
        XCTAssertEqual(try store.folderUnreadCounts(accountID: accounts[1].id), ["INBOX": 1])
    }

    // MARK: - Folder list

    /// Every folder shape (sparse, full, empty, the Inbox with a rule's skipped message, a
    /// deleted message, another account's copy) lists exactly what the date scan lists.
    func testFolderListMessagesMatchTheDateScanForEveryFolderShape() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount.id
        let other = AccountID("acc_other")
        for uid in 1...30 {
            try commit(store, id: "inbox-\(uid)", path: "INBOX", seen: false, account: account, uid: uid)
        }
        try commit(store, id: "receipt-old", path: "Receipts", seen: true, account: account, uid: 31)
        try commit(store, id: "receipt-deleted", path: "Receipts", seen: true, deleted: true, account: account, uid: 32)
        try commit(store, id: "receipt-new", path: "receipts", seen: true, account: account, uid: 33)
        try commit(store, id: "receipt-elsewhere", path: "Receipts", seen: true, account: other, uid: 34)
        _ = try store.enqueueMailRuleActions(
            messageID: MessageID("inbox-30"), accountID: account,
            actions: [.skipInbox], sourceRuleIDs: ["rule"]
        )

        for path in ["Receipts", "RECEIPTS", "INBOX", "inbox", "Empty"] {
            for limit in [1, 2, 5, 100] {
                XCTAssertEqual(
                    try store.folderListMessages(accountID: account, mailboxPath: path, limit: limit).map(\.id),
                    try store.mailboxListMessages(inMailboxPath: path, accountID: account, limit: limit, query: "").map(\.id),
                    "\(path), limit \(limit)"
                )
            }
        }
        XCTAssertEqual(
            try store.folderListMessages(accountID: account, mailboxPath: "Receipts", limit: 100).map(\.id.rawValue),
            ["receipt-new", "receipt-old"]
        )
        XCTAssertEqual(try store.folderListMessages(accountID: account, mailboxPath: "INBOX", limit: 2).map(\.id.rawValue),
                       ["inbox-29", "inbox-28"], "the rule's skipped message stays out of the Inbox")
    }

    func testFolderListMessagesFallBackToMessagePathsWithoutMemberships() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        let threadID = ThreadID("legacy")
        try store.cacheThread(MailThread(id: threadID, accountID: account.id, subjectNormalized: "legacy",
                                         participantEmails: [account.email]))
        try store.cacheMessage(MessageSummary(
            id: MessageID("legacy-1"), threadID: threadID, from: account.email, subject: "Legacy", preview: "",
            smartCategory: .personal, labels: [], isSeen: true, mailboxPath: "Archive", isDeleted: false
        ))

        XCTAssertEqual(
            try store.folderListMessages(accountID: account.id, mailboxPath: "Archive", limit: 200).map(\.id),
            try store.mailboxListMessages(inMailboxPath: "Archive", accountID: account.id, limit: 200, query: "").map(\.id)
        )
    }

    /// A sparse folder is read from its memberships: no scan of every message by date.
    func testASparseFolderIsReadFromItsMemberships() throws {
        let (_, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for sql in [SQLiteMailStore.sparseFolderListSQL, SQLiteMailStore.sparseInboxListSQL] {
            let details = try queryPlanDetails("EXPLAIN QUERY PLAN \(sql)", at: url)
            XCTAssertFalse(details.contains { $0.hasPrefix("SCAN m") }, "no scan of messages: \(details)")
            XCTAssertTrue(
                details.contains { $0.hasPrefix("SEARCH mailbox_messages") && $0.hasSuffix("(account_id=?)") },
                "the folder's memberships come from the account's key: \(details)"
            )
            XCTAssertTrue(
                details.contains { $0.hasPrefix("SEARCH m USING INDEX sqlite_autoindex_messages_1 (id=?)") },
                "each member is looked up by id: \(details)"
            )
        }
        let count = try queryPlanDetails("EXPLAIN QUERY PLAN \(SQLiteMailStore.folderMembershipCountSQL)", at: url)
        XCTAssertTrue(count.contains { $0.hasPrefix("SEARCH mailbox_messages USING COVERING INDEX") }, "\(count)")
    }

    // MARK: - Recent correspondents

    func testRecentCorrespondentsExcludeOwnAddressAndMergeCase() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        try commitMail(store, "1", from: "Maria@Northwind.example", name: "Maria Chen", to: [account.email.rawValue], at: 10, account: account.id)
        try commitMail(store, "2", from: "maria@northwind.example", name: nil, to: [account.email.rawValue], at: 30, account: account.id)
        try commitMail(store, "3", from: account.email.rawValue, name: "Me", to: ["tom@okafor.example"], at: 20, account: account.id)

        let result = try store.recentCorrespondents(accountID: account.id, ownAddresses: [account.email.rawValue])

        XCTAssertEqual(result.map { $0.address.lowercased() }, ["maria@northwind.example", "tom@okafor.example"])
        XCTAssertEqual(result.first?.displayName, "Maria Chen", "keeps the best known name across case variants")
        XCTAssertEqual(result.map(\.lastSeen), [Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 20)])
    }

    func testRecentCorrespondentsTakeSentToAndCcButOnlyTheSenderOfReceivedMail() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount.id
        let own = "me@example.com"
        let alias = "ME.ALIAS@example.com"
        try commitMail(store, "sent", from: own, name: nil, to: ["ana@example.com", alias], cc: ["ben@example.com"], at: 40, account: account)
        try commitMail(store, "received", from: "cy@example.com", name: "Cy", to: [own, "dora@example.com"], cc: ["eli@example.com"], at: 30, account: account)
        try commitMail(store, "from-alias", from: "me.alias@example.com", name: nil, to: ["fay@example.com"], at: 20, account: account)

        let result = try store.recentCorrespondents(accountID: account, ownAddresses: [own, alias])

        XCTAssertEqual(
            result.map(\.address),
            ["ana@example.com", "ben@example.com", "cy@example.com", "fay@example.com"],
            "mail from any own address counts as sent, and no own address is suggested"
        )
    }

    func testRecentCorrespondentsSkipDeletedJunkAndOtherAccountsMail() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount.id
        let other = AccountID("acc_other")
        try commitMail(store, "kept", from: "kept@example.com", name: nil, to: [], at: 10, account: account)
        try commitMail(store, "deleted", from: "deleted@example.com", name: nil, to: [], at: 20, deleted: true, account: account)
        try commitMail(store, "junk", from: "spammer@example.com", name: nil, to: [], at: 30, path: "Junk", account: account)
        try commitMail(store, "gmail-spam", from: "bulk@example.com", name: nil, to: [], at: 35, path: "[Gmail]/Spam", account: account)
        try commitMail(store, "elsewhere", from: "elsewhere@example.com", name: nil, to: [], at: 40, account: other)

        XCTAssertEqual(try store.recentCorrespondents(accountID: account, ownAddresses: []).map(\.address), ["kept@example.com"])
        XCTAssertEqual(try store.recentCorrespondents(accountID: other, ownAddresses: []).map(\.address), ["elsewhere@example.com"])
    }

    func testRecentCorrespondentsHonorTheScanAndResultLimits() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount.id
        for index in 1...4 {
            try commitMail(store, "m\(index)", from: "p\(index)@example.com", name: nil, to: [], at: Double(index), account: account)
        }

        XCTAssertEqual(
            try store.recentCorrespondents(accountID: account, ownAddresses: [], scanLimit: 3).map(\.address),
            ["p4@example.com", "p3@example.com", "p2@example.com"]
        )
        XCTAssertEqual(
            try store.recentCorrespondents(accountID: account, ownAddresses: [], limit: 2).map(\.address),
            ["p4@example.com", "p3@example.com"]
        )
    }

    func testRecentCorrespondentsResolveLegacyRowsThroughTheirThread() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let accounts = ["a", "b"].map { id in
            Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        for (id, account, from) in [("a1", accounts[0], "gil@example.com"), ("b1", accounts[1], "hal@example.com")] {
            let threadID = ThreadID("legacy-\(id)")
            try store.cacheThread(MailThread(
                id: threadID, accountID: account.id, subjectNormalized: "legacy", participantEmails: [account.email]
            ))
            try store.cacheMessage(MessageSummary(
                id: MessageID(id), threadID: threadID, from: EmailAddress(from), fromDisplayName: "Legacy",
                subject: "Legacy", preview: "Legacy row", smartCategory: .personal, labels: [], isSeen: true,
                mailboxPath: "INBOX", isDeleted: false, sentAt: Date(timeIntervalSince1970: 5)
            ))
        }

        XCTAssertEqual(try store.recentCorrespondents(accountID: accounts[0].id, ownAddresses: []).map(\.address), ["gil@example.com"])
        XCTAssertEqual(try store.recentCorrespondents(accountID: accounts[1].id, ownAddresses: []).map(\.address), ["hal@example.com"])
    }

    /// Account-owned and legacy thread-owned rows merge into one newest-first scan, and the
    /// scan limit applies to the merged order, not to each kind of row separately.
    func testRecentCorrespondentsMergeAccountAndLegacyRowsByRecency() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        func legacy(_ id: String, from: String, at: Double) throws {
            let threadID = ThreadID("legacy-\(id)")
            try store.cacheThread(MailThread(
                id: threadID, accountID: account.id, subjectNormalized: "legacy", participantEmails: [account.email]
            ))
            try store.cacheMessage(MessageSummary(
                id: MessageID(id), threadID: threadID, from: EmailAddress(from), fromDisplayName: nil,
                subject: "Legacy", preview: "Legacy row", smartCategory: .personal, labels: [], isSeen: true,
                mailboxPath: "INBOX", isDeleted: false, sentAt: Date(timeIntervalSince1970: at)
            ))
        }
        try commitMail(store, "owned-50", from: "a50@example.com", name: nil, to: [], at: 50, account: account.id)
        try legacy("legacy-40", from: "l40@example.com", at: 40)
        try commitMail(store, "owned-30", from: "a30@example.com", name: nil, to: [], at: 30, account: account.id)
        try legacy("legacy-20", from: "l20@example.com", at: 20)
        try commitMail(store, "owned-10", from: "a10@example.com", name: nil, to: [], at: 10, account: account.id)

        XCTAssertEqual(
            try store.recentCorrespondents(accountID: account.id, ownAddresses: []).map(\.address),
            ["a50@example.com", "l40@example.com", "a30@example.com", "l20@example.com", "a10@example.com"]
        )
        XCTAssertEqual(
            try store.recentCorrespondents(accountID: account.id, ownAddresses: [], scanLimit: 3).map(\.address),
            ["a50@example.com", "l40@example.com", "a30@example.com"]
        )
    }

    /// The correspondents scan runs on the shared inbox projection actor, so it must stop after
    /// `scanLimit` of the account's rows instead of walking every message in the store.
    func testRecentCorrespondentsQueryReadsTheAccountThroughAnIndex() throws {
        let (_, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let details = try queryPlanDetails("EXPLAIN QUERY PLAN \(SQLiteMailStore.recentCorrespondentsSQL)", at: url)

        XCTAssertFalse(
            details.contains { $0.hasPrefix("SCAN m") },
            "no full scan of messages: \(details)"
        )
        XCTAssertTrue(
            details.contains { $0.hasPrefix("SEARCH m USING INDEX messages_account_sent_at (account_id=?)") },
            "the account's rows come newest first from the account index: \(details)"
        )
    }

    func testCorrespondentsFromMessagesMatchTheStoreRules() {
        let own = "me@example.com"
        func message(_ id: String, from: String, name: String?, to: [String], at: Double?) -> MessageSummary {
            MessageSummary(
                id: MessageID(id), threadID: nil, from: EmailAddress(from), fromDisplayName: name,
                subject: "s", preview: "p", smartCategory: .personal, labels: [], isSeen: true,
                mailboxPath: "INBOX", isDeleted: false, body: "p",
                sentAt: at.map(Date.init(timeIntervalSince1970:)), to: to.map { EmailAddress($0) }
            )
        }
        let messages = [
            message("old", from: "ivy@example.com", name: "Ivy", to: [own], at: 10),
            message("undated", from: "jo@example.com", name: nil, to: [own], at: nil),
            message("new", from: "IVY@example.com", name: nil, to: [own], at: 30),
            message("sent", from: own, name: nil, to: ["kim@example.com"], at: 20),
        ]

        let result = Correspondent.recent(in: messages, ownAddresses: ["ME@example.com"])

        XCTAssertEqual(result.map { $0.address.lowercased() }, ["ivy@example.com", "kim@example.com", "jo@example.com"])
        XCTAssertEqual(result.first?.displayName, "Ivy")
    }

    func testMergedCorrespondentsInterleaveAccountsByRecency() {
        func person(_ address: String, _ name: String?, _ at: Double?) -> Correspondent {
            Correspondent(address: address, displayName: name, lastSeen: at.map(Date.init(timeIntervalSince1970:)))
        }
        let work = [person("lee@example.com", nil, 50), person("max@example.com", "Max", 10)]
        let personal = [person("LEE@example.com", "Lee Park", 40), person("nia@example.com", nil, 30), person("oz@example.com", nil, nil)]

        let merged = Correspondent.merged([work, personal], limit: 3)

        XCTAssertEqual(merged.map(\.address), ["lee@example.com", "nia@example.com", "max@example.com"])
        XCTAssertEqual(merged.first?.displayName, "Lee Park", "a name from another account fills a missing one")
        XCTAssertEqual(merged.first?.lastSeen, Date(timeIntervalSince1970: 50))
    }

    // MARK: - Helpers

    private func makeStore() throws -> (SQLiteMailStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return (store, url)
    }

    private func queryPlanDetails(_ sql: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query plan.")
        }
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let detail = sqlite3_column_text(statement, 3) else {
                throw PlainpostError.validationFailed("SQLite query plan detail is missing.")
            }
            details.append(String(cString: detail))
        }
        return details
    }

    private func commit(
        _ store: SQLiteMailStore,
        id: String,
        path: String,
        seen: Bool,
        deleted: Bool = false,
        account: AccountID,
        uid: Int
    ) throws {
        _ = try store.commitIncomingMessage(
            MessageSummary(id: MessageID(id), threadID: ThreadID("t\(id)"), from: EmailAddress("x@example.com"),
                           subject: "s", preview: "p", smartCategory: .personal, labels: [], isSeen: seen,
                           mailboxPath: path, isDeleted: deleted, sentAt: Date(timeIntervalSince1970: Double(uid))),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account, mailboxPath: path, uidValidity: 1, uid: uid, notificationEligible: false
        )
    }

    private func commitMail(
        _ store: SQLiteMailStore,
        _ id: String,
        from: String,
        name: String?,
        to: [String],
        cc: [String] = [],
        at: Double,
        deleted: Bool = false,
        path: String = "INBOX",
        account: AccountID
    ) throws {
        _ = try store.commitIncomingMessage(
            MessageSummary(
                id: MessageID(id), threadID: ThreadID("t\(id)"), from: EmailAddress(from), fromDisplayName: name,
                subject: "s", preview: "p", smartCategory: .personal, labels: [], isSeen: true,
                mailboxPath: path, isDeleted: deleted, body: "p", sentAt: Date(timeIntervalSince1970: at),
                to: to.map { EmailAddress($0) }, cc: cc.map { EmailAddress($0) }
            ),
            metadata: IncomingMessageSearchMetadata(
                to: to.map { EmailAddress($0) }, cc: cc.map { EmailAddress($0) }, bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account, mailboxPath: path, uidValidity: 1, uid: Int(at * 10), notificationEligible: false
        )
    }
}
