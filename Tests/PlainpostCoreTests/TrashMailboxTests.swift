import XCTest
@testable import PlainpostCore

final class TrashMailboxTests: XCTestCase {
    private func mailbox(_ path: String, _ specialUse: String? = nil) -> Mailbox {
        Mailbox(id: MailboxID(path), accountID: AccountID("a"), name: path, path: path, specialUse: specialUse)
    }

    func testSpecialUseWinsOverAFolderNamedTrash() {
        let mailboxes = [mailbox("INBOX", "\\Inbox"), mailbox("Trash"), mailbox("Deleted Items", "\\Trash")]
        XCTAssertEqual(TrashMailbox.path(in: mailboxes), "Deleted Items")
    }

    func testGmailTrashIsFoundBySpecialUseInAnyLocale() {
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("INBOX", "\\Inbox"), mailbox("[Gmail]/Trash", "\\Trash")]), "[Gmail]/Trash")
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("[Google Mail]/Bin", "\\trash")]), "[Google Mail]/Bin")
    }

    func testGmailTrashIsFoundByNameWithoutSpecialUse() {
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("INBOX", "\\Inbox"), mailbox("[Gmail]/Trash")]), "[Gmail]/Trash")
    }

    func testProviderNamesWithoutSpecialUse() {
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("INBOX"), mailbox("Deleted Messages")]), "Deleted Messages")
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("INBOX"), mailbox("INBOX.Trash")]), "INBOX.Trash")
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("Deleted"), mailbox("Trash")]), "Trash", "the likelier name wins")
    }

    func testNoTrashMailboxIsNil() {
        XCTAssertNil(TrashMailbox.path(in: []))
        XCTAssertNil(TrashMailbox.path(in: [mailbox("INBOX", "\\Inbox"), mailbox("Archive", "\\Archive"), mailbox("Trash Talk")]))
    }

    func testLocalizedAndGmailBinNamesAreTrash() {
        XCTAssertEqual(TrashMailbox.path(in: [mailbox("INBOX"), mailbox("[Google Mail]/Bin")]), "[Google Mail]/Bin")
        XCTAssertTrue(TrashMailbox.isTrashPath("[Gmail]/Papierkorb"))
        XCTAssertTrue(TrashMailbox.isTrashPath("[Gmail]/Corbeille"))
        XCTAssertTrue(TrashMailbox.isTrashPath("Papelera"))
        XCTAssertTrue(TrashMailbox.isTrashPath("INBOX.Cestino"))
        // Modified UTF-7, as LIST sends it: "Gelöschte Elemente".
        XCTAssertTrue(TrashMailbox.isTrashPath("Gel&APY-schte Elemente"))
        XCTAssertEqual(TrashMailbox.decodeModifiedUTF7("&BBoEPgRABDcEOAQ9BDA-"), "Корзина")
    }

    func testNestedUserFoldersAreNeverTrashByName() {
        XCTAssertFalse(TrashMailbox.isTrashPath("Projects/Deleted"))
        XCTAssertFalse(TrashMailbox.isTrashPath("Clients/Bin"))
        XCTAssertFalse(TrashMailbox.isTrashPath("INBOX/Old/Trash"))
        XCTAssertNil(TrashMailbox.path(in: [mailbox("INBOX"), mailbox("Projects/Deleted")]))
        XCTAssertTrue(TrashMailbox.isTrash(path: "Projects/Deleted", specialUse: "\\Trash"), "the server's mark wins")
    }

    func testAskMailExclusionUsesTheSharedResolver() {
        XCTAssertTrue(MailMailboxFilter.isTrashOrJunk("[Google Mail]/Bin"))
        XCTAssertTrue(MailMailboxFilter.isTrashOrJunk("[Gmail]/Papierkorb"))
        XCTAssertTrue(MailMailboxFilter.isTrashOrJunk("Rubbish", specialUse: "\\Trash"))
        let icloud = [mailbox("Deleted Messages", "\\Trash"), mailbox("Trash")]
        XCTAssertFalse(MailMailboxFilter.isTrashOrJunk("Trash", accountMailboxes: icloud),
                       "a legacy Trash beside the marked one is ordinary, as in the folder list")
        XCTAssertTrue(MailMailboxFilter.isTrashOrJunk("Deleted Messages", specialUse: "\\Trash", accountMailboxes: icloud))
        XCTAssertTrue(MailMailboxFilter.isTrashOrJunk("Unwanted", specialUse: "\\Junk"))
        XCTAssertFalse(MailMailboxFilter.isTrashOrJunk("Projects"))
    }

    func testAMarkedTrashMakesSameNamedFoldersOrdinary() {
        let account = [mailbox("INBOX", "\\Inbox"), mailbox("Deleted Messages", "\\Trash"), mailbox("Trash")]
        XCTAssertTrue(TrashMailbox.isTrash(path: "Deleted Messages", specialUse: "\\Trash", accountMailboxes: account))
        XCTAssertFalse(TrashMailbox.isTrash(path: "Trash", specialUse: nil, accountMailboxes: account),
                       "iCloud's legacy Trash beside the marked Deleted Messages")
        XCTAssertFalse(TrashDelete.isInTrash("Trash", cachedMailboxes: account))
        XCTAssertTrue(TrashDelete.isInTrash("Deleted Messages", cachedMailboxes: account))
        XCTAssertTrue(TrashMailbox.isTrash(path: "Trash", specialUse: nil, accountMailboxes: [mailbox("Trash")]),
                      "without a marked Trash, the name still counts")
    }

    func testAMailboxMarkedAsSomethingElseIsNeverTrash() {
        XCTAssertNil(TrashMailbox.path(in: [mailbox("Trash", "\\Junk")]))
    }

    func testCOPYUIDIsReadOnlyForTheMovedUID() {
        func parse(_ lines: [String]) -> IMAPMoveResult {
            IMAPMoveResult.parsingCopyUID(mailbox: "Trash", sourceUID: 7, lines: lines)
        }
        let unknown = IMAPMoveResult(mailbox: "Trash", uidValidity: nil, uid: nil)
        XCTAssertEqual(parse(["* OK [COPYUID 44 7 501] moved", "A1 OK done"]), IMAPMoveResult(mailbox: "Trash", uidValidity: 44, uid: 501))
        XCTAssertEqual(parse(["A1 OK [COPYUID 44 7 501] UID COPY completed"]), IMAPMoveResult(mailbox: "Trash", uidValidity: 44, uid: 501),
                       "COPYUID on the tagged OK only")
        XCTAssertEqual(parse(["A1 OK [copyuid 44 7 501] done"]).uid, 501, "the response code is case-insensitive")
        XCTAssertEqual(parse(["A1 OK [COPYUID 44 8 501] done"]), unknown, "another source UID")
        XCTAssertEqual(parse(["A1 OK [COPYUID 44 7:9 501:503] done"]), unknown, "a range")
        XCTAssertEqual(parse(["A1 OK [COPYUID 44 7,9 501,502] done"]), unknown, "a set")
        XCTAssertEqual(parse(["A1 OK [COPYUID 0 7 501] done"]), unknown, "UIDVALIDITY is never zero")
        XCTAssertEqual(parse(["A1 OK done"]), unknown)
    }
}
