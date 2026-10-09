import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class MailboxDirectoryTests: XCTestCase {
    func testRoleComesFromSpecialUseThenCommonNames() {
        XCTAssertEqual(MailboxDirectoryModel.role(path: "INBOX", specialUse: nil), .inbox)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/Sent Mail", specialUse: "\\Sent"), .sent)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Archive", specialUse: nil), .archive)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Receipts", specialUse: nil), .other)
    }

    func testRoleReadsEverySpecialUseFlagBeforeTheName() {
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Posteingang", specialUse: "\\Inbox"), .inbox)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Entwürfe", specialUse: "\\Drafts"), .drafts)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/All Mail", specialUse: "\\All"), .archive)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Old", specialUse: "\\archive"), .archive)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/Bin", specialUse: "\\Trash"), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/Spam", specialUse: "\\Junk"), .junk)
        XCTAssertEqual(
            MailboxDirectoryModel.role(path: "Archive", specialUse: "\\Trash"), .trash,
            "a special-use flag outranks the folder's name"
        )
        XCTAssertEqual(
            MailboxDirectoryModel.role(path: "[Gmail]/Starred", specialUse: "\\Flagged"), .other,
            "a flag with no role falls back to the name"
        )
    }

    func testRoleFallsBackOnTheLastPathComponentIgnoringCase() {
        XCTAssertEqual(MailboxDirectoryModel.role(path: "inbox", specialUse: nil), .inbox)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Work/Drafts", specialUse: nil), .drafts)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "SENT ITEMS", specialUse: nil), .sent)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Sent Messages", specialUse: nil), .sent)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/All Mail", specialUse: nil), .archive)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Deleted Items", specialUse: nil), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Bin", specialUse: nil), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "spam", specialUse: nil), .junk)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Projects/Inbox", specialUse: nil), .other,
                       "only the top-level INBOX path is the inbox")
    }

    func testALegacyTrashBesideTheMarkedTrashIsAnOrdinaryFolder() {
        let id = AccountID("a")
        let account = Account(id: id, displayName: "A", email: EmailAddress("a@icloud.com"), imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587)
        let sections = MailboxDirectoryModel.sections(
            accounts: [account],
            mailboxes: [
                Mailbox(id: MailboxID("1"), accountID: id, name: "Deleted Messages", path: "Deleted Messages", specialUse: "\\Trash"),
                Mailbox(id: MailboxID("2"), accountID: id, name: "Trash", path: "Trash", specialUse: nil),
            ],
            unreadCounts: [:]
        )
        let roles = Dictionary(uniqueKeysWithValues: sections[0].folders.map { ($0.path, $0.role) })
        XCTAssertEqual(roles["Deleted Messages"], .trash)
        XCTAssertEqual(roles["Trash"], .other, "only the marked Trash offers Delete Permanently")
    }

    func testArchiveRoleIsTheFolderArchiveMovesTo() {
        // The same resolver Archive uses: Gmail's All Mail, not a label named Archive;
        // a real Archive, not a Dovecot virtual \All beside it.
        let gmail = AccountID("g")
        let dovecot = AccountID("d")
        let sections = MailboxDirectoryModel.sections(
            accounts: [
                Account(id: gmail, displayName: "G", email: EmailAddress("g@gmail.com"), imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com"),
                Account(id: dovecot, displayName: "D", email: EmailAddress("d@x.example"), imapHost: "h", smtpHost: "h"),
            ],
            mailboxes: [
                Mailbox(id: MailboxID("g1"), accountID: gmail, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                Mailbox(id: MailboxID("g2"), accountID: gmail, name: "All Mail", path: "[Gmail]/All Mail", specialUse: "\\All"),
                Mailbox(id: MailboxID("g3"), accountID: gmail, name: "Archive", path: "Archive", specialUse: nil),
                Mailbox(id: MailboxID("d1"), accountID: dovecot, name: "Archive", path: "Archive", specialUse: nil),
                Mailbox(id: MailboxID("d2"), accountID: dovecot, name: "All", path: "Virtual/All", specialUse: "\\All"),
            ],
            unreadCounts: [:]
        )
        let gmailRoles = Dictionary(uniqueKeysWithValues: sections[0].folders.map { ($0.path, $0.role) })
        XCTAssertEqual(gmailRoles["[Gmail]/All Mail"], .archive)
        XCTAssertEqual(gmailRoles["Archive"], .other)
        let dovecotRoles = Dictionary(uniqueKeysWithValues: sections[1].folders.map { ($0.path, $0.role) })
        XCTAssertEqual(dovecotRoles["Archive"], .archive)
        XCTAssertEqual(dovecotRoles["Virtual/All"], .other)
    }

    func testTrashRoleComesFromTheSharedTrashResolver() {
        // The same rules Delete uses to find Trash, so "Delete Permanently" shows only there.
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Google Mail]/Bin", specialUse: nil), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "[Gmail]/Papierkorb", specialUse: nil), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Gel&APY-schte Elemente", specialUse: nil), .trash)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "Projects/Deleted", specialUse: nil), .other,
                       "a nested user folder is not Trash by name")
    }

    func testOrderingPutsSystemFoldersFirst() {
        let id = AccountID("a")
        func f(_ path: String, _ role: MailboxFolder.Role) -> MailboxFolder {
            MailboxFolder(id: path, accountID: id, name: path, path: path, role: role, unread: 0)
        }
        let ordered = MailboxDirectoryModel.ordered([f("Zeta", .other), f("Trash", .trash), f("INBOX", .inbox), f("Alpha", .other), f("Sent", .sent)])
        XCTAssertEqual(ordered.map(\.path), ["INBOX", "Sent", "Trash", "Alpha", "Zeta"])
    }

    func testOrderingRanksEveryRoleThenNamesIgnoringCase() {
        let id = AccountID("a")
        func f(_ name: String, _ role: MailboxFolder.Role) -> MailboxFolder {
            MailboxFolder(id: name, accountID: id, name: name, path: name, role: role, unread: 0)
        }
        let ordered = MailboxDirectoryModel.ordered([
            f("receipts", .other), f("Trash", .trash), f("Spam", .junk), f("Archive", .archive),
            f("Sent", .sent), f("Drafts", .drafts), f("INBOX", .inbox), f("Bills", .other),
        ])
        XCTAssertEqual(ordered.map(\.name), ["INBOX", "Drafts", "Sent", "Archive", "Spam", "Trash", "Bills", "receipts"])
    }

    func testSectionsJoinEachAccountsFoldersWithItsUnreadCounts() {
        let work = Account(id: AccountID("work"), displayName: "Work", email: EmailAddress("me@work.example"),
                           imapHost: "imap.work.example", smtpHost: "smtp.work.example")
        let home = Account(id: AccountID("home"), displayName: "", email: EmailAddress("me@home.example"),
                           imapHost: "imap.home.example", smtpHost: "smtp.home.example")
        let mailboxes = [
            Mailbox(id: MailboxID("w-inbox"), accountID: work.id, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("w-sent"), accountID: work.id, name: "[Gmail]/Sent Mail", path: "[Gmail]/Sent Mail", specialUse: "\\Sent"),
            Mailbox(id: MailboxID("w-receipts"), accountID: work.id, name: "Receipts", path: "Receipts", specialUse: nil),
            Mailbox(id: MailboxID("h-inbox"), accountID: home.id, name: "Inbox", path: "Inbox", specialUse: nil),
        ]

        let sections = MailboxDirectoryModel.sections(
            accounts: [work, home],
            mailboxes: mailboxes,
            unreadCounts: [
                work.id: ["INBOX": 3, "Receipts": 0, "Projects/Launch": 2],
                home.id: ["INBOX": 1],
            ]
        )

        XCTAssertEqual(sections.map(\.id), [work.id, home.id])
        XCTAssertEqual(sections.map(\.title), ["Work", "me@home.example"])
        XCTAssertEqual(sections[0].folders.map(\.name), ["Inbox", "Sent Mail", "Launch", "Receipts"])
        XCTAssertEqual(sections[0].folders.map(\.path), ["INBOX", "[Gmail]/Sent Mail", "Projects/Launch", "Receipts"])
        XCTAssertEqual(sections[0].folders.map(\.role), [.inbox, .sent, .other, .other])
        XCTAssertEqual(sections[0].folders.map(\.unread), [3, 0, 2, 0])
        XCTAssertEqual(Set(sections[0].folders.map(\.id)).count, 4)
        XCTAssertTrue(sections[0].folders.allSatisfy { $0.accountID == work.id })
        XCTAssertEqual(sections[1].folders.map(\.path), ["Inbox"], "paths match ignoring case")
        XCTAssertEqual(sections[1].folders.map(\.unread), [1])
    }

    func testSnapshotUnreadCountsGroupUnreadLiveMessagesByPath() {
        func message(_ id: String, _ path: String, seen: Bool = false, deleted: Bool = false) -> MessageSummary {
            MessageSummary(id: MessageID(id), threadID: nil, from: EmailAddress("x@example.com"),
                           subject: "s", preview: "p", smartCategory: .personal, labels: [], isSeen: seen,
                           mailboxPath: path, isDeleted: deleted)
        }
        XCTAssertEqual(
            MailboxDirectoryModel.unreadCounts(messages: [
                message("a", "INBOX"), message("b", "inbox"), message("c", "INBOX", seen: true),
                message("d", "Archive", seen: true), message("e", "Trash", deleted: true),
            ]),
            ["INBOX": 2, "Archive": 0, "Trash": 0]
        )
    }

    func testRefreshPublishesTheLoadedSections() async {
        let section = Self.section("a", unread: 4)
        let model = MailboxDirectoryModel(load: { [section] })
        XCTAssertEqual(model.sections, [])

        await model.refresh()

        XCTAssertEqual(model.sections, [section])
    }

    func testRefreshIfLoadedWaitsForAFirstRefresh() async {
        var loads = 0
        let model = MailboxDirectoryModel(load: {
            loads += 1
            return [Self.section("a", unread: loads)]
        })

        await model.refreshIfLoaded()
        XCTAssertEqual(loads, 0, "nothing has shown the directory yet")
        XCTAssertEqual(model.sections, [])

        await model.refresh()
        model.setVisible(true)
        await model.refreshIfLoaded()
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(model.sections, [Self.section("a", unread: 2)])
    }

    func testAnOlderRefreshFinishingLateKeepsTheNewerSections() async {
        let gate = LoadGate()
        let model = MailboxDirectoryModel(load: { await gate.next() })

        let first = Task { await model.refresh() }
        await gate.waitForRequests(1)
        let second = Task { await model.refresh() }
        await gate.waitForRequests(2)

        gate.resume(1, with: [Self.section("new", unread: 2)])
        await second.value
        gate.resume(0, with: [Self.section("old", unread: 1)])
        await first.value

        XCTAssertEqual(model.sections, [Self.section("new", unread: 2)])
    }

    func testDotDelimitedInboxChildrenGetTheirRoleAndName() {
        XCTAssertEqual(MailboxDirectoryModel.role(path: "INBOX.Sent", specialUse: nil), .sent)
        XCTAssertEqual(MailboxDirectoryModel.role(path: "INBOX.Trash", specialUse: nil), .trash)
        let account = Account(id: AccountID("a"), displayName: "A", email: EmailAddress("a@x.example"), imapHost: "h", smtpHost: "h")
        let sections = MailboxDirectoryModel.sections(
            accounts: [account],
            mailboxes: [Mailbox(id: MailboxID("s"), accountID: account.id, name: "INBOX.Sent", path: "INBOX.Sent", specialUse: nil)],
            unreadCounts: [:]
        )
        XCTAssertEqual(sections.first?.folders.first?.name, "Sent")
    }

    func testHiddenDirectoryIgnoresSnapshotRefreshes() async {
        var loads = 0
        let model = MailboxDirectoryModel(load: { loads += 1; return [] })
        await model.refresh()
        await model.refreshIfLoaded()
        XCTAssertEqual(loads, 1, "nothing shows the directory")
        model.setVisible(true)
        await model.refreshIfLoaded()
        XCTAssertEqual(loads, 2)
    }

    func testInboxUnreadCountSumsEveryAccountsInbox() async {
        let a = AccountID("a"), b = AccountID("b")
        let model = MailboxDirectoryModel(load: {
            [
                MailboxAccountSection(id: a, title: "A", folders: [
                    MailboxFolder(id: "a|INBOX", accountID: a, name: "Inbox", path: "INBOX", role: .inbox, unread: 3),
                    MailboxFolder(id: "a|Spam", accountID: a, name: "Spam", path: "Spam", role: .junk, unread: 9),
                ]),
                MailboxAccountSection(id: b, title: "B", folders: [
                    MailboxFolder(id: "b|INBOX", accountID: b, name: "Inbox", path: "INBOX", role: .inbox, unread: 2),
                ]),
            ]
        })
        await model.refresh()
        XCTAssertEqual(model.inboxUnreadCount, 5)
    }

    func testHiddenDirectoryDoesNotRefresh() async {
        let gate = MailRefreshTestBarrier()
        var reads = 0
        let model = MailboxDirectoryModel(load: {
            reads += 1
            if reads == 2 { await gate.wait() }
            return [Self.section("a", unread: reads)]
        })
        model.setVisible(true)
        await model.refresh()
        let admitted = Task { await model.refreshIfLoaded() }
        await gate.arrived.wait(for: 1)
        model.setVisible(false)
        await model.refreshIfLoaded()
        XCTAssertEqual(reads, 2, "hidden invalidations do not read")
        gate.release()
        await admitted.value
        XCTAssertEqual(model.sections, [Self.section("a", unread: 1)], "hiding fences an admitted result")
        model.setVisible(true)
        await model.refresh()
        XCTAssertEqual(model.sections, [Self.section("a", unread: 3)], "showing consumes the latest dirty state")
    }

    func testCancelledDirectoryRefreshKeepsCachedSections() async {
        let gate = MailRefreshTestBarrier()
        var reads = 0
        let model = MailboxDirectoryModel(load: {
            reads += 1
            if reads == 2 { await gate.wait() }
            return [Self.section("a", unread: reads)]
        })
        model.setVisible(true)
        await model.refresh()
        let admitted = Task { await model.refresh() }
        await gate.arrived.wait(for: 1)
        admitted.cancel()
        await fulfillment(of: [gate.cancelled], timeout: 5)
        gate.release()
        await admitted.value
        XCTAssertEqual(model.sections, [Self.section("a", unread: 1)])
    }

    // MARK: - Helpers

    private static func section(_ id: String, unread: Int) -> MailboxAccountSection {
        MailboxAccountSection(
            id: AccountID(id),
            title: id,
            folders: [MailboxFolder(id: "\(id)|INBOX", accountID: AccountID(id), name: "Inbox",
                                    path: "INBOX", role: .inbox, unread: unread)]
        )
    }
}

/// Hands each load a continuation the test resumes, in any order.
@MainActor
private final class LoadGate {
    private var continuations: [CheckedContinuation<[MailboxAccountSection], Never>] = []

    func next() async -> [MailboxAccountSection] {
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForRequests(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resume(_ index: Int, with sections: [MailboxAccountSection]) {
        continuations[index].resume(returning: sections)
    }
}
