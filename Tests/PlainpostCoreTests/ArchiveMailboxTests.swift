import XCTest
@testable import PlainpostCore

final class ArchiveMailboxTests: XCTestCase {
    private func mailbox(_ path: String, _ specialUse: String? = nil) -> Mailbox {
        Mailbox(id: MailboxID(path), accountID: AccountID("a"), name: path, path: path, specialUse: specialUse)
    }

    /// The device's Gmail account: no Archive folder, archive is All Mail.
    private var gmail: [Mailbox] {
        [
            mailbox("INBOX", "\\Inbox"), mailbox("[Gmail]/All Mail", "\\All"), mailbox("[Gmail]/Trash", "\\Trash"),
            mailbox("[Gmail]/Sent Mail", "\\Sent"), mailbox("[Gmail]/Spam", "\\Junk"),
        ]
    }

    func testGmailArchivesToAllMail() {
        XCTAssertEqual(ArchiveMailbox.path(in: gmail), "[Gmail]/All Mail")
        XCTAssertEqual(
            ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("[Google Mail]/Alle Nachrichten", "\\all")]),
            "[Google Mail]/Alle Nachrichten", "any locale, any case of the mark"
        )
    }

    func testGmailAllMailWithoutSpecialUseIsFoundByName() {
        XCTAssertEqual(ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("[Gmail]/All Mail")]), "[Gmail]/All Mail")
    }

    func testArchiveSpecialUseWinsUnderAnyName() {
        let mailboxes = [mailbox("INBOX", "\\Inbox"), mailbox("Archive"), mailbox("Saved", "\\Archive")]
        XCTAssertEqual(ArchiveMailbox.path(in: mailboxes), "Saved")
        XCTAssertEqual(ArchiveMailbox.path(in: gmail + [mailbox("Kept", "\\Archive")]), "Kept", "\\Archive beats All Mail")
    }

    func testAFolderNamedArchiveStillWorks() {
        XCTAssertEqual(ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("Archive")]), "Archive")
        XCTAssertEqual(ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("archive")]), "archive", "case-insensitive")
        XCTAssertEqual(ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("INBOX.Archive")]), "INBOX.Archive")
    }

    func testANonGmailAllMailboxComesAfterANamedArchive() {
        // A Dovecot virtual "All" is not where a message is archived when a real Archive exists.
        let dovecot = [mailbox("INBOX"), mailbox("Archive"), mailbox("Virtual/All", "\\All")]
        XCTAssertEqual(ArchiveMailbox.path(in: dovecot), "Archive")
        XCTAssertEqual(ArchiveMailbox.path(in: [mailbox("INBOX"), mailbox("Virtual/All", "\\All")]), "Virtual/All")
    }

    func testNoArchiveMailboxIsNil() {
        XCTAssertNil(ArchiveMailbox.path(in: []))
        XCTAssertNil(ArchiveMailbox.path(in: [mailbox("INBOX", "\\Inbox"), mailbox("Trash", "\\Trash"), mailbox("Projects/Archive")]))
        XCTAssertNil(ArchiveMailbox.path(in: [mailbox("Old Archive", "\\Junk")]), "a mailbox marked as something else")
    }

    func testRequestedDestination() {
        XCTAssertEqual(ArchiveMailbox.destination(requested: nil, in: gmail), "[Gmail]/All Mail")
        XCTAssertEqual(ArchiveMailbox.destination(requested: "Archive", in: gmail), "[Gmail]/All Mail",
                       "the old default names the account's archive")
        XCTAssertEqual(ArchiveMailbox.destination(requested: "[gmail]/spam", in: gmail), "[Gmail]/Spam",
                       "a named folder the account has, as the server spells it")
        XCTAssertEqual(ArchiveMailbox.destination(requested: "Receipts", in: gmail), "Receipts",
                       "an explicit folder the cached list doesn't know yet")
        XCTAssertNil(ArchiveMailbox.destination(requested: "Archive", in: [mailbox("INBOX")]))
    }

    func testIsArchiveFollowsTheResolvedMailbox() {
        XCTAssertTrue(ArchiveMailbox.isArchive(path: "[Gmail]/All Mail", specialUse: "\\All", accountMailboxes: gmail))
        XCTAssertFalse(ArchiveMailbox.isArchive(path: "INBOX", specialUse: "\\Inbox", accountMailboxes: gmail))
        let dovecot = [mailbox("INBOX"), mailbox("Archive"), mailbox("Virtual/All", "\\All")]
        XCTAssertTrue(ArchiveMailbox.isArchive(path: "Archive", specialUse: nil, accountMailboxes: dovecot))
        XCTAssertFalse(ArchiveMailbox.isArchive(path: "Virtual/All", specialUse: "\\All", accountMailboxes: dovecot))
        // Without the folder list, by the mailbox alone.
        XCTAssertTrue(ArchiveMailbox.isArchive(path: "Saved", specialUse: "\\Archive"))
        XCTAssertTrue(ArchiveMailbox.isArchive(path: "Archive", specialUse: nil))
        XCTAssertFalse(ArchiveMailbox.isArchive(path: "Projects", specialUse: nil))
    }

    func testResolveRefusesWithoutAnyUIDCommandWhenTheServerHasNoArchive() async throws {
        let client = ListingClient(listed: [mailbox("INBOX", "\\Inbox"), mailbox("Trash", "\\Trash")])
        do {
            _ = try await ArchiveMailbox.resolve(requested: nil, client: client, cachedMailboxes: [mailbox("INBOX")])
            XCTFail("no Archive folder must refuse")
        } catch PlainpostError.validationFailed(let text) {
            XCTAssertEqual(text, ArchiveMailbox.noArchiveMessage)
        }
        XCTAssertEqual(client.listCount, 1, "the server's folder list is checked before refusing")
    }

    func testResolveUsesTheCachedListWithoutAsking() async throws {
        let client = ListingClient(listed: [])
        let path = try await ArchiveMailbox.resolve(requested: nil, client: client, cachedMailboxes: gmail)
        XCTAssertEqual(path, "[Gmail]/All Mail")
        XCTAssertEqual(client.listCount, 0)
    }

    func testResolveFindsTheArchiveOnTheServerWhenTheCachedListLacksIt() async throws {
        let client = ListingClient(listed: gmail)
        let path = try await ArchiveMailbox.resolve(requested: "Archive", client: client, cachedMailboxes: [])
        XCTAssertEqual(path, "[Gmail]/All Mail")
        XCTAssertEqual(client.listCount, 1)
    }
}

private final class ListingClient: IMAPClientProtocol, @unchecked Sendable {
    let listed: [Mailbox]
    var listCount = 0
    init(listed: [Mailbox]) { self.listed = listed }
    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] { listCount += 1; return listed }
    func selectMailbox(_ path: String) async throws -> String { "" }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws { XCTFail("no UID command") }
    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult { XCTFail("no UID command"); return .init(mailbox: mailbox, uidValidity: nil, uid: nil) }
    func delete(uid: Int) async throws { XCTFail("no UID command") }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult { .init(mailbox: mailbox, uid: nil) }
}
