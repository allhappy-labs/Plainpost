import Foundation
import SQLite3
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI
import PlainpostRuntimeTestSupport

final class InboxProjectionRepositoryTests: XCTestCase {
    func testSelectedAccountProjectionExcludesOtherInboxAndReader() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-inbox-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["first", "second"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        try store.cacheMailboxes(accounts.map { account in
            Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                    name: "Inbox", path: "INBOX", specialUse: nil)
        })
        try store.cacheThread(MailThread(
            id: ThreadID("same-thread"), accountID: accounts[0].id,
            subjectNormalized: "shared", participantEmails: [accounts[0].email]
        ))
        for (index, account) in accounts.enumerated() {
            let message = MessageSummary(
                id: MessageID("message-\(account.id.rawValue)"),
                threadID: ThreadID("same-thread"), from: account.email,
                subject: "Shared", preview: "Private \(account.id.rawValue)",
                smartCategory: .personal, labels: [], isSeen: false,
                mailboxPath: "INBOX", isDeleted: false, body: "Private body",
                sentAt: Date(timeIntervalSince1970: Double(index + 1))
            )
            _ = try store.commitIncomingMessage(
                message, metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ), accountID: account.id, mailboxPath: "INBOX", uidValidity: 10,
                uid: index + 1, notificationEligible: false
            )
        }
        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(
            store: store, accountID: accounts[1].id
        ))

        let page = try await repository.mailboxPage(limit: 1, query: "", forceReload: false)
        let mailboxes = try await repository.mailSearchMailboxes(forceReload: false)
        let ownDetail = try await repository.threadDetail(messageID: "message-second")
        let foreignDetail = try await repository.threadDetail(messageID: "message-first")

        XCTAssertEqual(page.rows.count, 1)
        XCTAssertEqual(page.rows.first?.id, "message-second")
        XCTAssertEqual(page.totalRowCount, 1)
        XCTAssertEqual(page.accounts.map(\.id), [accounts[1].id])
        XCTAssertEqual(mailboxes.map(\.id), [MailboxID("second-inbox")])
        XCTAssertEqual(ownDetail.messages.map(\.id), ["message-second"])
        XCTAssertFalse(ownDetail.participants.contains(accounts[0].email.rawValue))
        XCTAssertTrue(foreignDetail.messages.isEmpty)
    }

    func testThreadDetailProjectionPreservesDirectAttachmentMetadata() async throws {
        let attachment = MailAttachment(
            id: "part-2", filename: "receipt.pdf", mimeType: "application/pdf",
            disposition: "attachment", byteCount: 12, contentDigest: "digest"
        )
        let sourceMessage = MessageSummary(
            id: MessageID("with-attachment"), threadID: ThreadID("attachment-thread"),
            from: EmailAddress("sender@example.com"), subject: "Receipt", preview: "Attached",
            smartCategory: .personal, labels: [], isSeen: true,
            mailboxPath: "INBOX", isDeleted: false, body: "Receipt attached", attachments: [attachment]
        )
        let source = RecordingInboxProjectionSource(
            messages: [listMessage(id: "with-attachment", threadID: "attachment-thread", sentAt: 1)],
            details: [sourceMessage]
        )
        let repository = InboxProjectionRepository(source: source)

        _ = try await repository.mailboxPage(limit: 20, query: "", forceReload: false)
        let detail = try await repository.threadDetail(messageID: "with-attachment")

        XCTAssertEqual(detail.messages.first?.attachments, [attachment])
    }

    func testSQLiteReaderProjectsPersistedDirectAttachmentWithScopedIdentity() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-reader-attachment-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: AccountID("attachment-account"), displayName: "Attachment",
            email: EmailAddress("attachment@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        _ = try store.replaceMailSource(
            AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: 1
            ),
            expectedGeneration: 0
        )
        let message = MessageSummary(
            id: MessageID("attachment-message"), threadID: nil,
            from: EmailAddress("sender@example.com"), subject: "Receipt",
            preview: "Attached", smartCategory: .personal
        )
        let payload = IncomingMessageAttachmentPayload(
            partPath: "2.1", filename: "receipt.pdf",
            mimeType: "application/pdf", data: Data("receipt bytes".utf8)
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [],
                attachments: [.init(filename: payload.filename, mimeType: payload.mimeType)],
                messageIdentifiers: []
            ),
            attachments: [payload], accountID: account.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1,
            notificationEligible: false
        )
        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(
            store: store, accountID: account.id
        ))

        let detail = try await repository.threadDetail(messageID: message.id.rawValue)

        let attachment = try XCTUnwrap(detail.messages.first?.attachments.first)
        XCTAssertEqual(attachment.filename, "receipt.pdf")
        XCTAssertEqual(attachment.byteCount, 13)
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(
            DirectIncomingAttachmentID.decode(attachment.id),
            DirectIncomingAttachmentID(
                accountID: account.id, messageID: message.id,
                partPath: "2.1", sourceGeneration: 1
            )
        )
    }

    func testSentReaderDoesNotMixAccountsWithTheSameThreadID() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sent-reader-owner-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["first", "second"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        try store.cacheThread(MailThread(
            id: ThreadID("same-thread-id"), accountID: accounts[0].id,
            subjectNormalized: "shared subject", participantEmails: [accounts[0].email]
        ))
        let actor = Actor(id: "user", kind: .user, displayName: "User", permissions: .guiUser)
        var sentIDs: [MessageID] = []
        for account in accounts {
            let draft = Draft(
                id: DraftID("draft-\(account.id.rawValue)"), accountID: account.id,
                from: account.email, to: [EmailAddress("recipient@example.com")],
                cc: [], bcc: [], subject: "Shared subject",
                bodyPlain: "Private body for \(account.id.rawValue)", createdBy: actor.id,
                aiGenerated: false, sourceThreadID: ThreadID("same-thread-id")
            )
            sentIDs.append(try store.recordDirectSentMessage(draft: draft, actor: actor).id)
        }
        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store))
        _ = try await repository.mailboxPage(limit: 20, query: "", forceReload: false)

        let detail = try await repository.threadDetail(messageID: sentIDs[1].rawValue)

        XCTAssertEqual(detail.messages.map(\.id), [sentIDs[1].rawValue])
        XCTAssertFalse(detail.participants.contains("first@example.com"))
    }

    func testLegacySentReplyReaderIncludesSelectedSentCopyWithoutInbox() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-sent-reader-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["first", "second"].map { id in
            Account(id: AccountID(id), displayName: id,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        let actor = Actor(id: "user", kind: .user, displayName: "User", permissions: .guiUser)
        var sentIDs: [MessageID] = []
        for account in accounts {
            let draft = Draft(
                id: DraftID("legacy-\(account.id.rawValue)"), accountID: account.id,
                from: account.email, to: [EmailAddress("recipient@example.com")],
                cc: [], bcc: [], subject: "Re: Shared subject",
                bodyPlain: "Private body for \(account.id.rawValue)", createdBy: actor.id,
                aiGenerated: false, sourceThreadID: ThreadID("thr_uid_legacy")
            )
            sentIDs.append(try store.recordDirectSentMessage(draft: draft, actor: actor).id)
        }
        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store))
        _ = try await repository.mailboxPage(limit: 20, query: "", forceReload: false)

        let detail = try await repository.threadDetail(messageID: sentIDs[1].rawValue)

        XCTAssertEqual(detail.messages.map(\.id), [sentIDs[1].rawValue])
        XCTAssertFalse(detail.participants.contains("first@example.com"))
    }

    func testSidebarUnreadBadgeDoesNotDependOnLoadedPage() async throws {
        var messages: [MailboxListMessage] = []
        for index in 0..<400 {
            let isSeen = (index >= 176 && index < 200) || index >= 314
            messages.append(listMessage(
                id: "msg_\(index)",
                threadID: "thread_\(index)",
                sentAt: Double(400 - index),
                isSeen: isSeen
            ))
        }
        let source = RecordingInboxProjectionSource(messages: messages)
        let repository = InboxProjectionRepository(source: source)

        let first = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        let second = try await repository.mailboxPage(limit: 400, query: "", forceReload: false)

        XCTAssertEqual(first.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 290)
        XCTAssertEqual(second.sidebarItems.first { $0.title == "Smart Inbox" }?.badge, 290)
        XCTAssertEqual(source.unreadCountReadCount, 1)
    }

    func testInitialMailboxPageIsBoundedAndReusesIndexWithoutReadingBodies() async throws {
        let source = RecordingInboxProjectionSource(messages: makeMessages(count: 10_000))
        let repository = InboxProjectionRepository(source: source)

        let first = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        let second = try await repository.mailboxPage(limit: 400, query: "", forceReload: false)

        XCTAssertEqual(first.rows.count, 200)
        XCTAssertEqual(first.totalRowCount, 10_000)
        XCTAssertTrue(first.hasMoreRows)
        XCTAssertEqual(second.rows.count, 400)
        let indexBuildCount = await repository.indexBuildCount
        XCTAssertEqual(indexBuildCount, 1)
        let loadedListMessageCount = await repository.loadedListMessageCount
        XCTAssertEqual(loadedListMessageCount, 400)
        XCTAssertEqual(source.completeMessageReadCount, 0)
    }

    func testSentProjectionRemainsVisibleWhenInboxIsEmptyAndPaginatesIndependently() async throws {
        let source = RecordingInboxProjectionSource(
            messages: [], sentMessages: makeMessages(count: 250)
        )
        let repository = InboxProjectionRepository(source: source)

        let first = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        let second = try await repository.mailboxPage(limit: 400, query: "", forceReload: false)

        XCTAssertTrue(first.rows.isEmpty)
        XCTAssertEqual(first.sentRows.count, 200)
        XCTAssertTrue(first.hasMoreSentRows)
        XCTAssertEqual(second.sentRows.count, 250)
        XCTAssertFalse(second.hasMoreSentRows)
        XCTAssertNotEqual(first.revision, second.revision,
                          "loading the next Sent page must publish new list content")
    }

    func testSelectedThreadReadsOnlyConversationMessageIDs() async throws {
        let messages = [
            listMessage(id: "new", threadID: "shared", sentAt: 20),
            listMessage(id: "old", threadID: "shared", sentAt: 10),
            listMessage(id: "other", threadID: "other", sentAt: 30),
        ]
        let source = RecordingInboxProjectionSource(messages: messages)
        let repository = InboxProjectionRepository(source: source)

        _ = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        _ = try await repository.threadDetail(messageID: "new")

        XCTAssertEqual(Set(source.completeReadIDs.last ?? []), Set([MessageID("new"), MessageID("old")]))
    }

    func testMailSearchMailboxMetadataIsBoundedCachedAndReloadable() async throws {
        let initial = (0...MailSearchMailbox.maximumMetadataCount).map { index in
            Mailbox(
                id: MailboxID("mailbox-\(index)"),
                accountID: AccountID("account"),
                name: index == 0 ? "" : "Mailbox \(index)",
                path: "Path \(index)",
                specialUse: nil
            )
        }
        let source = RecordingInboxProjectionSource(messages: [], mailboxes: initial)
        let repository = InboxProjectionRepository(source: source)

        let first = try await repository.mailSearchMailboxes(forceReload: false)
        let cached = try await repository.mailSearchMailboxes(forceReload: false)
        source.replaceMailboxes([
            Mailbox(
                id: MailboxID("new"),
                accountID: AccountID("account"),
                name: "New mailbox",
                path: "New",
                specialUse: nil
            )
        ])
        let reloaded = try await repository.mailSearchMailboxes(forceReload: true)

        XCTAssertEqual(first.count, MailSearchMailbox.maximumMetadataCount)
        XCTAssertEqual(first.first?.displayName, "Path 0")
        XCTAssertEqual(cached, first)
        XCTAssertEqual(reloaded.map(\.id), [MailboxID("new")])
        XCTAssertEqual(source.mailboxReadLimits, [MailSearchMailbox.maximumMetadataCount, MailSearchMailbox.maximumMetadataCount])
    }

    func testMailboxDirectoryListsTheSelectedAccountsFoldersWithUnreadCounts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailbox-directory-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["first", "second"].map { id in
            Account(id: AccountID(id), displayName: id.capitalized,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        try store.cacheMailboxes(accounts.flatMap { account in
            [
                Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                        name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                Mailbox(id: MailboxID("\(account.id.rawValue)-trash"), accountID: account.id,
                        name: "Trash", path: "Trash", specialUse: "\\Trash"),
            ]
        })
        let messages: [(String, Account, String, Bool)] = [
            ("f1", accounts[0], "INBOX", false),
            ("f2", accounts[0], "INBOX", true),
            ("s1", accounts[1], "INBOX", false),
            ("s2", accounts[1], "INBOX", false),
            ("s3", accounts[1], "Receipts", false),
        ]
        for (index, entry) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID(entry.0), threadID: ThreadID("t-\(entry.0)"), from: entry.1.email,
                    subject: "Subject", preview: "Preview", smartCategory: .personal, labels: [],
                    isSeen: entry.3, mailboxPath: entry.2, isDeleted: false,
                    sentAt: Date(timeIntervalSince1970: Double(index + 1))
                ),
                metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: entry.1.id, mailboxPath: entry.2, uidValidity: 1, uid: index + 1,
                notificationEligible: false
            )
        }

        let all = try await InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store))
            .mailboxDirectory()
        let selected = try await InboxProjectionRepository(source: SQLiteInboxProjectionSource(
            store: store, accountID: accounts[1].id
        )).mailboxDirectory()

        XCTAssertEqual(all.map(\.title), ["First", "Second"])
        XCTAssertEqual(all.first?.folders.map(\.path), ["INBOX", "Trash"])
        XCTAssertEqual(all.first?.folders.map(\.unread), [1, 0])
        XCTAssertEqual(selected.map(\.id), [accounts[1].id])
        XCTAssertEqual(selected.first?.folders.map(\.name), ["Inbox", "Trash", "Receipts"])
        XCTAssertEqual(selected.first?.folders.map(\.role), [.inbox, .trash, .other])
        XCTAssertEqual(selected.first?.folders.map(\.unread), [2, 0, 1])
        XCTAssertEqual(
            try SQLiteInboxProjectionSource(store: store, accountID: accounts[1].id)
                .folderUnreadCounts(accountID: accounts[0].id),
            [:],
            "an account-scoped source never reads another account's counts"
        )
    }

    func testRecentCorrespondentsMergeTheSourcesAccountsAndSkipEveryOwnAddress() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-correspondents-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["first", "second"].map { id in
            Account(id: AccountID(id), displayName: id.capitalized,
                    email: EmailAddress("\(id)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        }
        try store.cacheAccounts(accounts)
        let messages: [(String, Account, String, [String], Double)] = [
            ("f1", accounts[0], "ada@example.com", ["first@example.com"], 10),
            ("f2", accounts[0], "first@example.com", ["second@example.com", "bea@example.com"], 30),
            ("s1", accounts[1], "cal@example.com", ["second@example.com"], 20),
            ("s2", accounts[1], "first@example.com", ["second@example.com"], 40),
        ]
        for (index, entry) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID(entry.0), threadID: ThreadID("t-\(entry.0)"), from: EmailAddress(entry.2),
                    subject: "Subject", preview: "Preview", smartCategory: .personal, labels: [],
                    isSeen: true, mailboxPath: "INBOX", isDeleted: false, body: "Preview",
                    sentAt: Date(timeIntervalSince1970: entry.4), to: entry.3.map { EmailAddress($0) }
                ),
                metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: entry.1.id, mailboxPath: "INBOX", uidValidity: 1, uid: index + 1,
                notificationEligible: false
            )
        }
        let own: Set<String> = ["first@example.com", "second@example.com"]

        let all = try await InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store))
            .recentCorrespondents(ownAddresses: own)
        let selected = try await InboxProjectionRepository(source: SQLiteInboxProjectionSource(
            store: store, accountID: accounts[1].id
        )).recentCorrespondents(ownAddresses: own)

        XCTAssertEqual(all.map(\.address), ["bea@example.com", "cal@example.com", "ada@example.com"])
        XCTAssertEqual(selected.map(\.address), ["cal@example.com"])
        XCTAssertEqual(
            try SQLiteInboxProjectionSource(store: store, accountID: accounts[1].id)
                .recentCorrespondents(accountID: accounts[0].id, ownAddresses: own),
            [],
            "an account-scoped source never reads another account's correspondents"
        )
    }

    private func makeMessages(count: Int) -> [MailboxListMessage] {
        (0..<count).map { index in
            listMessage(id: "msg_\(index)", threadID: "thread_\(index)", sentAt: Double(count - index))
        }
    }

    private func listMessage(
        id: String,
        threadID: String,
        sentAt: Double,
        isSeen: Bool = false
    ) -> MailboxListMessage {
        MailboxListMessage(
            id: MessageID(id),
            threadID: ThreadID(threadID),
            from: EmailAddress("sender@example.com"),
            subject: "Subject \(id)",
            preview: "Preview \(id)",
            smartCategory: .personal,
            isSeen: isSeen,
            sentAt: Date(timeIntervalSince1970: sentAt)
        )
    }

    func testFolderRowsListOneAccountsFolderNewestFirst() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folder-rows-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("a"), displayName: "A", email: EmailAddress("a@example.com"),
                              imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(id: MailboxID("a-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: nil),
            Mailbox(id: MailboxID("a-sent"), accountID: account.id, name: "Sent", path: "Sent", specialUse: "\\Sent"),
        ])
        for (index, (id, path)) in [("s-old", "Sent"), ("i-1", "INBOX"), ("s-new", "Sent")].enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(id: MessageID(id), threadID: nil, from: account.email, subject: id, preview: "",
                               smartCategory: .personal, labels: [], isSeen: true, mailboxPath: path, isDeleted: false,
                               body: "", sentAt: Date(timeIntervalSince1970: Double(index + 1))),
                metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: account.id, mailboxPath: path, uidValidity: 1, uid: index + 1, notificationEligible: false
            )
        }
        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store, accountID: account.id))

        let sent = try await repository.folderRows(accountID: account.id, path: "Sent")
        let foreign = try await repository.folderRows(accountID: AccountID("other"), path: "Sent")

        XCTAssertEqual(sent.map(\.id), ["s-new", "s-old"])
        XCTAssertEqual(foreign, [])
    }

    func testDeviceSourceListsEveryDirectAndMirroredSyncNodeAccount() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let source = SQLiteInboxProjectionSource(store: try fixture.store(), scope: .deviceDirect)
        let rows = try source.mailboxListMessages(limit: 10, query: "")
        XCTAssertEqual(rows.map(\.id), ["msg_node_1", "msg_first_2", "msg_second_1", "msg_first_1"].map { MessageID($0) })
        XCTAssertEqual(Set(try source.accounts().map(\.id)), [fixture.first.id, fixture.second.id, fixture.node!.id])
        XCTAssertEqual(try source.mailboxUnreadConversationCounts(query: "").total, 4)
        XCTAssertEqual(try source.mailboxListMessageCount(query: ""), 4)
        XCTAssertEqual(try source.folderListMessages(accountID: fixture.node!.id, path: "INBOX", limit: 10).map(\.id), [MessageID("msg_node_1")])
        XCTAssertEqual(try source.accountID(containing: MessageID("msg_node_1")), fixture.node!.id)
    }

    /// An account in Sync Node fallback is synced by this device while its Node is away: it
    /// stays served, its mail where it was.
    func testDeviceSourceServesAnAccountInSyncNodeFallback() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self, withNodeAccount: true)
        let store = try fixture.store()
        let node = try store.mailSource(accountID: fixture.node!.id)
        _ = try store.replaceMailSource(node.withMode(.fallback), expectedGeneration: node.generation)
        let source = SQLiteInboxProjectionSource(store: store, scope: .deviceDirect)
        XCTAssertEqual(Set(try source.accounts().map(\.id)), [fixture.first.id, fixture.second.id, fixture.node!.id])
        XCTAssertEqual(try source.accountID(containing: MessageID("msg_node_1")), fixture.node!.id)
        let authority = try source.readAuthority().deviceDirect
        XCTAssertEqual(authority?.fallbackAccountIDs, [fixture.node!.id])
        XCTAssertEqual(authority?.directSyncAccountIDs, [fixture.first.id, fixture.second.id, fixture.node!.id])
    }

    func testDeviceDirectAuthorityChangesWhenAnAccountIsResourced() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let source = SQLiteInboxProjectionSource(store: try fixture.store(), scope: .deviceDirect)
        let before = try source.readAuthority()
        XCTAssertEqual(before.deviceDirect?.generations, [fixture.first.id: 1, fixture.second.id: 1])
        try fixture.switchToNode(fixture.second)
        let after = try source.readAuthority()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.deviceDirect?.generations, [fixture.first.id: 1, fixture.second.id: 2])
        XCTAssertEqual(after.deviceDirect?.nodeAccountIDs, [fixture.second.id])
    }

    /// The device-wide source's mailbox limit counts only served accounts' mailboxes: an
    /// account the device doesn't serve (here, one with no explicit source) never crowds them out.
    func testDeviceMailboxLimitCountsOnlyServedAccounts() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let store = try fixture.store()
        let unserved = Account(
            id: AccountID("acc_aaa_unserved"), displayName: "Unserved", email: EmailAddress("unserved@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts(store.accounts + [unserved])
        try store.cacheMailboxes((1...3).map {
            Mailbox(id: MailboxID("mb_aaa_node_\($0)"), accountID: unserved.id,
                    name: "Node \($0)", path: "Node\($0)", specialUse: nil)
        })
        let source = SQLiteInboxProjectionSource(store: store, scope: .deviceDirect)
        let mailboxes = try source.mailboxes(limit: 3)
        XCTAssertEqual(mailboxes.count, 3)
        XCTAssertTrue(mailboxes.allSatisfy { [fixture.first.id, fixture.second.id].contains($0.accountID) })
    }

    func testRowModelCarriesItsAccount() throws {
        let fixture = try TwoDirectAccountsFixture(testCase: self)
        let source = SQLiteInboxProjectionSource(store: try fixture.store(), scope: .deviceDirect)
        let row = MessageRowModel(message: try source.mailboxListMessages(limit: 10, query: "").first!)
        XCTAssertEqual(row.accountID, fixture.first.id)
    }
}

private final class RecordingInboxProjectionSource: InboxProjectionSource, @unchecked Sendable {
    private let lock = NSLock()
    private let messages: [MailboxListMessage]
    private let sentMessages: [MailboxListMessage]
    private let details: [MessageSummary]
    private var reads: [[MessageID]] = []
    private var mailboxValues: [Mailbox]
    private var recordedMailboxReadLimits: [Int] = []
    private var recordedUnreadCountReads = 0

    init(messages: [MailboxListMessage], sentMessages: [MailboxListMessage] = [], mailboxes: [Mailbox] = [], details: [MessageSummary] = []) {
        self.messages = messages
        self.sentMessages = sentMessages
        mailboxValues = mailboxes
        self.details = details
    }

    var completeReadIDs: [[MessageID]] {
        lock.withLock { reads }
    }

    var completeMessageReadCount: Int {
        lock.withLock { reads.count }
    }

    var mailboxReadLimits: [Int] {
        lock.withLock { recordedMailboxReadLimits }
    }

    var unreadCountReadCount: Int {
        lock.withLock { recordedUnreadCountReads }
    }

    func replaceMailboxes(_ mailboxes: [Mailbox]) {
        lock.withLock { mailboxValues = mailboxes }
    }

    func mailboxes(limit: Int) throws -> [Mailbox] {
        lock.withLock {
            recordedMailboxReadLimits.append(limit)
            return Array(mailboxValues.prefix(limit))
        }
    }

    func folderUnreadCounts(accountID: AccountID) throws -> [String: Int] {
        [:]
    }

    func recentCorrespondents(accountID: AccountID, ownAddresses: Set<String>) throws -> [Correspondent] {
        []
    }

    func mailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = normalizedQuery.isEmpty ? messages : messages.filter { message in
            [message.from.rawValue, message.subject, message.preview].contains { value in
                value.localizedCaseInsensitiveContains(normalizedQuery)
            }
        }
        return Array(matches.prefix(limit))
    }

    func mailboxListMessageCount(query: String) throws -> Int {
        try mailboxListMessages(limit: Int.max, query: query).count
    }

    func sentMailboxListMessages(limit: Int, query: String) throws -> [MailboxListMessage] {
        Array(sentMessages.filter { message in
            query.isEmpty || message.subject.localizedCaseInsensitiveContains(query)
        }.prefix(limit))
    }

    func sentMailboxListMessageCount(query: String) throws -> Int {
        try sentMailboxListMessages(limit: Int.max, query: query).count
    }

    func mailboxUnreadConversationCounts(query: String) throws -> MailboxUnreadConversationCounts {
        lock.withLock { recordedUnreadCountReads += 1 }
        let rows = MessageRowModel.threadedRows(
            from: try mailboxListMessages(limit: Int.max, query: query)
        )
        let counts = SidebarUnreadCounts(rows: rows)
        return MailboxUnreadConversationCounts(
            total: counts.total,
            personal: counts.personal,
            notifications: counts.notifications,
            newsletters: counts.newsletters
        )
    }

    func completeConversation(containing messageID: MessageID) throws -> [MessageSummary] {
        guard let selected = messages.first(where: { $0.id == messageID }) else { return [] }
        let matchingMessages = messages.filter { message in
            if let threadID = selected.threadID, !threadID.rawValue.hasPrefix("thr_uid_") {
                return message.threadID == threadID
            }
            return message.id == messageID
        }
        lock.withLock { reads.append(matchingMessages.map(\.id)) }
        return matchingMessages.map { message in
            if let detail = details.first(where: { $0.id == message.id }) { return detail }
            return MessageSummary(
                id: message.id,
                threadID: message.threadID,
                from: message.from,
                subject: message.subject,
                preview: message.preview,
                body: "Body \(message.id.rawValue)",
                smartCategory: message.smartCategory,
                sentAt: message.sentAt
            )
        }
    }

    func accountID(containing messageID: MessageID) throws -> AccountID? { nil }

    func thread(id: ThreadID) throws -> MailThread? { nil }
    func accounts() throws -> [Account] { [] }
    func pendingApprovalCount() throws -> Int { 0 }
}

// Legacy lookup contracts use real SQLite; no message contents are logged.
extension InboxProjectionRepositoryTests {
    func testLegacyLookupPreservesNormalizationOwnershipAndSentSelection() throws {
        let (url, store) = try task9LegacyFixture(unrelatedCount: 0, richSemantics: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SQLiteInboxProjectionSource(store: store, accountID: AccountID("a"))
        let messages = try source.completeConversation(containing: MessageID("selected"))
        XCTAssertEqual(Set(messages.map { $0.id.rawValue }), ["selected", "own-native", "own-nil", "own-legacy"])
        XCTAssertTrue(try SQLiteInboxProjectionSource(store: store, accountID: AccountID("b")).completeConversation(containing: MessageID("selected")).isEmpty)
        XCTAssertEqual(try source.completeConversation(containing: MessageID("upper-thread")).map { $0.id.rawValue }, ["upper-thread"])
        XCTAssertEqual(Set(try source.completeConversation(containing: MessageID("street-selected")).map { $0.id.rawValue }), ["street-selected", "street-exact"])
        XCTAssertEqual(MailThreading.normalizedSubject(" \tRe [12]: Fw:\n CAFÉ \n"), "café")
        XCTAssertEqual(MailThreading.normalizedSubject("cafe\u{301}"), "café", "Swift equality preserves canonical Unicode equivalence")
        XCTAssertNotEqual(MailThreading.normalizedSubject("STRASSE"), MailThreading.normalizedSubject("Straße"))
    }

    func testLegacyLookupDoesNotMaterializeUnrelatedInboxMetadataOrBodies() throws {
        let (url, store) = try task9LegacyFixture(unrelatedCount: 100_000, richSemantics: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let trace = LegacyLookupWorkTrace()
        try trace.install(store)
        defer { try? trace.uninstall(store) }
        let source = SQLiteInboxProjectionSource(store: store, accountID: AccountID("a"))
        let result = try source.completeConversation(containing: MessageID("legacy-new"))
        XCTAssertEqual(Set(result.map { $0.id.rawValue }), ["legacy-new", "legacy-old"])
        XCTAssertEqual(trace.bodyIDs, ["legacy-new", "legacy-old"])
        XCTAssertLessThanOrEqual(trace.listRows, 2)
        print("TASK9_LEGACY_WORK " + String(data: try JSONSerialization.data(withJSONObject: trace.metrics, options: [.sortedKeys]), encoding: .utf8)!)
        let sql = try XCTUnwrap(trace.lookupSQL, "the reader must select matching identities, not the full list")
        let plan = try store.databasePool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: ["a", "target topic"])
                .map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("messages_account_sent_at") && $0.contains("account_id=?") })
        print("TASK9_LEGACY_QUERY_PLAN " + String(data: try JSONSerialization.data(withJSONObject: plan), encoding: .utf8)!)
    }

    func testLegacyLookupPreservesMembershipFreeOwnershipAndFallbackBoundary() throws {
        let (url, store) = try task9LegacyFixture(unrelatedCount: 0, richSemantics: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM mailbox_messages")
            try db.execute(sql: """
                INSERT INTO threads(id, account_id, subject_normalized, participant_emails)
                SELECT DISTINCT thread_id, account_id, '', '[]' FROM messages WHERE thread_id IS NOT NULL
                """)
        }
        let source = SQLiteInboxProjectionSource(store: store, accountID: AccountID("a"))
        let trace = LegacyLookupWorkTrace()
        try trace.install(store)
        defer { try? trace.uninstall(store) }
        let messages = try source.completeConversation(containing: MessageID("selected"))
        // The legacy owner helper uses membership, then thread ownership. A
        // canonical account column alone never grants ownership to own-nil.
        XCTAssertEqual(Set(messages.map { $0.id.rawValue }), ["selected", "own-native", "own-legacy"])
        XCTAssertTrue(try SQLiteInboxProjectionSource(store: store, accountID: AccountID("b")).completeConversation(containing: MessageID("selected")).isEmpty)
        print("TASK9_MEMBERSHIP_FREE_WORK " + String(data: try JSONSerialization.data(withJSONObject: trace.metrics, options: [.sortedKeys]), encoding: .utf8)!)
        try store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO mailbox_messages(account_id,mailbox_path,uid_validity,uid,message_id) VALUES ('b','INBOX',1,1,'foreign')")
        }
        XCTAssertEqual(try source.completeConversation(containing: MessageID("selected")).map { $0.id.rawValue }, ["selected"], "any real membership suppresses the legacy mailbox_path fallback")
    }

}

private func task9LegacyFixture(unrelatedCount: Int, richSemantics: Bool) throws -> (URL, SQLiteMailStore) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-lookup-\(UUID().uuidString).sqlite")
    let store = try SQLiteMailStore(path: url.path)
    try store.migrate()
    try store.cacheAccounts(["a", "b"].map { Account(id: AccountID($0), displayName: $0, email: EmailAddress("\($0)@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test") })
    try store.databasePool.write { db in
        if unrelatedCount > 0 {
            try db.execute(sql: """
                WITH RECURSIVE fixture(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM fixture WHERE n < \(unrelatedCount))
                INSERT INTO messages(id, account_id, from_email, subject, preview, body_text, smart_category, mailbox_path, is_seen, sent_at)
                SELECT printf('unrelated-%06d',n), 'a', 'sender@example.test', 'Unrelated ' || n, 'Preview', 'Unrelated body', 'personal', 'INBOX', 1, n FROM fixture
                """)
        }
        let entries: [(String, String, String?, String, String, String)] = richSemantics ? [
            ("selected", "a", "thr_uid_selected", " \tRe [12]: Fw:\n CAFÉ \n", "Sent", "0"),
            ("own-native", "a", "native-thread", "café", "INBOX", "0"),
            ("own-nil", "a", nil, "cafe\u{301}", "INBOX", "0"),
            ("own-legacy", "a", "thr_uid_other", " Fw: CaFÉ ", "INBOX", "0"),
            ("foreign", "b", "thr_uid_foreign", "café", "INBOX", "0"),
            ("plain-ascii", "a", nil, "Cafe", "INBOX", "0"),
            ("word-prefix", "a", nil, "Revolution: café", "INBOX", "0"),
            ("archived", "a", nil, "café", "Archive", "0"),
            ("deleted", "a", nil, "café", "INBOX", "1"),
            ("skipped", "a", nil, "café", "INBOX", "0"),
            ("upper-thread", "a", "THR_UID_1", "café", "Sent", "0"),
            ("street-selected", "a", "thr_uid_street", "Re: Straße", "Sent", "0"),
            ("street-exact", "a", nil, "STRAßE", "INBOX", "0"),
            ("street-ascii", "a", nil, "STRASSE", "INBOX", "0")
        ] : [("legacy-new", "a", "thr_uid_new", "Re: Target topic", "INBOX", "0"),
             ("legacy-old", "a", "thr_uid_old", "Target topic", "INBOX", "0")]
        for (id, owner, thread, subject, mailbox, deleted) in entries {
            try db.execute(sql: """
                INSERT INTO messages(id, account_id, thread_id, from_email, subject, preview, body_text, smart_category, mailbox_path, is_deleted)
                VALUES (?, ?, ?, 'sender@example.test', ?, 'Preview', 'Matching body', 'personal', ?, ?)
                """, arguments: [id, owner, thread, subject, mailbox, deleted])
        }
        try db.execute(sql: """
            INSERT INTO mailbox_messages(account_id, mailbox_path, uid_validity, uid, message_id)
            SELECT account_id, mailbox_path, 1, rowid, id FROM messages
            """)
        if richSemantics {
            try db.execute(sql: "INSERT INTO mail_rule_message_actions(message_id, account_id, action, source_rule_ids_json, created_at) VALUES ('skipped','a','skipInbox','[]',0)")
        }
    }
    return (url, store)
}

private final class LegacyLookupWorkTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String: Int] = [:]
    private var rows: [String: Int] = [:]
    private var bodies: Set<String> = []
    private var recordedLookupSQL: String?
    var lookupSQL: String? { lock.withLock { recordedLookupSQL } }
    var bodyIDs: Set<String> { lock.withLock { bodies } }
    var listRows: Int { lock.withLock { rows["list_metadata", default: 0] } }
    var metrics: [String: [String: Int]] { lock.withLock { ["queries": queries, "rows": rows] } }
    func install(_ store: SQLiteMailStore) throws {
        _ = try store.databasePool.read { db in
            sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_ROW), { event, context, statement, _ in
                guard let context, let statement, let text = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                Unmanaged<LegacyLookupWorkTrace>.fromOpaque(context).takeUnretainedValue().record(String(cString: text), statement: OpaquePointer(statement), isRow: event == UInt32(SQLITE_TRACE_ROW))
                return 0
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }
    func uninstall(_ store: SQLiteMailStore) throws {
        _ = try store.databasePool.read { db in sqlite3_trace_v2(db.sqliteConnection, 0, nil, nil) }
    }
    private func record(_ sql: String, statement: OpaquePointer, isRow: Bool) {
        let query = sql.lowercased()
        guard query.contains("select") else { return }
        let category = query.contains("body_text") ? "body" : query.contains("m.preview") ? "list_metadata" : query.contains("plainpost_subject_matches") ? "matched_ids" : "other"
        lock.withLock {
            if category == "matched_ids" { recordedLookupSQL = sql }
            if isRow {
                rows[category, default: 0] += 1
                if category == "body", let id = sqlite3_column_text(statement, 0) { bodies.insert(String(cString: id)) }
            } else { queries[category, default: 0] += 1 }
        }
    }
}
