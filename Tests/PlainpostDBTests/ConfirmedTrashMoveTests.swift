import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class ConfirmedTrashMoveTests: XCTestCase {
    private var url: URL!
    private var store: SQLiteMailStore!
    private let accountID = AccountID("acc")
    private let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("trash-move-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: accountID, displayName: "acc", email: EmailAddress("acc@example.test"),
            imapHost: "imap.example.test", imapPort: 993, smtpHost: "smtp.example.test", smtpPort: 465
        )
        let inbox = Mailbox(id: MailboxID("acc-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox")
        let source = try AccountMailSource(
            accountID: accountID, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: account, inbox: inbox, source: source)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func add(_ id: String, mailbox: String = "INBOX", uidValidity: Int = 10, uid: Int) throws -> MessageID {
        let message = MessageSummary(
            id: MessageID(id), threadID: ThreadID("\(id)-thread"), from: EmailAddress("sender@example.test"),
            subject: id, preview: id, smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: mailbox, uidValidity: uidValidity, uid: uid,
            notificationEligible: false
        )
        return MessageID(id)
    }

    private func trash(_ id: MessageID, uidValidity: Int?, uid: Int?) throws -> MessageSummary {
        try store.applyConfirmedMailboxAction(
            .trash(to: "Trash", uidValidity: uidValidity, uid: uid),
            membership: try store.membership(for: id),
            sourceSnapshot: .direct(generation: 1),
            actor: actor
        )
    }

    func testTrashMoveTakesTheProviderKeyFromCOPYUID() throws {
        let id = try add("m1", uid: 7)

        let moved = try trash(id, uidValidity: 44, uid: 501)

        XCTAssertEqual(moved.mailboxPath, "Trash")
        XCTAssertFalse(moved.isDeleted, "a message in Trash is not erased")
        let membership = try store.membership(for: id)
        XCTAssertEqual(membership.mailboxPath, "Trash")
        XCTAssertEqual(membership.uidValidity, 44)
        XCTAssertEqual(membership.uid, 501)
        XCTAssertEqual(store.messages.first { $0.id == id }?.mailboxPath, "Trash")
    }

    func testTrashMoveWithoutCOPYUIDNeverKeepsTheInboxUID() throws {
        let id = try add("m1", uid: 7)

        _ = try trash(id, uidValidity: nil, uid: nil)

        let membership = try store.membership(for: id)
        XCTAssertEqual(membership.mailboxPath, "Trash")
        XCTAssertEqual(membership.uidValidity, 0, "a local key no server mailbox reports")
        XCTAssertLessThan(membership.uid, 0)
    }

    /// One message delivered twice (two Inbox UIDs, one Message-ID): a
    /// confirmed move of one UID leaves the other cached, so sync never
    /// downloads it as new and shows the "deleted" message again.
    func testTrashMoveOfOneOfTwoInboxCopiesKeepsTheOtherCached() throws {
        let id = try add("m1", uid: 7)
        try addCopy(id, mailbox: "INBOX", uid: 8)
        XCTAssertEqual(try store.duplicateCopyUIDs(of: store.actionMembership(for: id, shownIn: "INBOX")), [8])

        _ = try store.applyConfirmedMailboxAction(
            .trash(to: "Trash", uidValidity: 44, uid: 501),
            membership: try store.actionMembership(for: id, shownIn: "INBOX"),
            sourceSnapshot: .direct(generation: 1), actor: actor
        )

        XCTAssertEqual(try store.cachedUIDs(accountID: accountID, mailboxPath: "INBOX", uidValidity: 10), [8])
        XCTAssertEqual(store.messages.first { $0.id == id }?.mailboxPath, "INBOX")
        XCTAssertEqual(try store.cachedUIDs(accountID: accountID, mailboxPath: "Trash", uidValidity: 44), [501])
    }

    func testTrashMoveOfBothInboxCopiesLeavesTheInbox() throws {
        let id = try add("m1", uid: 7)
        try addCopy(id, mailbox: "INBOX", uid: 8)

        _ = try store.applyConfirmedMailboxAction(
            .trash(to: "Trash", uidValidity: 44, uid: 501),
            membership: try store.actionMembership(for: id, shownIn: "INBOX"), duplicateUIDs: [8],
            sourceSnapshot: .direct(generation: 1), actor: actor
        )

        XCTAssertEqual(try store.cachedUIDs(accountID: accountID, mailboxPath: "INBOX", uidValidity: 10), [])
        XCTAssertEqual(store.messages.first { $0.id == id }?.mailboxPath, "Trash")
    }

    private func addCopy(_ id: MessageID, mailbox: String, uid: Int) throws {
        let existing = try XCTUnwrap(store.messages.first { $0.id == id })
        _ = try store.commitIncomingMessage(
            existing,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: mailbox, uidValidity: 10, uid: uid, notificationEligible: false
        )
    }

    func testDisplayedMembershipIsTheCopyInTheMessagesOwnMailbox() throws {
        let id = try add("m1", uid: 7)
        try addCopy(id, mailbox: "Sent", uid: 3)
        XCTAssertEqual(try store.displayedMembership(for: id).mailboxPath, "INBOX")

        _ = try trash(id, uidValidity: 44, uid: 501)

        XCTAssertEqual(try store.membership(for: id).mailboxPath, "Sent", "Sent sorts before Trash")
        let shown = try store.displayedMembership(for: id)
        XCTAssertEqual(shown.mailboxPath, "Trash")
        XCTAssertEqual(shown.uid, 501)
        // A confirmed action on the shown copy applies even though it isn't the first-sorted one.
        let erased = try store.applyConfirmedMailboxAction(
            .delete, membership: shown, sourceSnapshot: .direct(generation: 1), actor: actor
        )
        XCTAssertFalse(erased.isDeleted, "the Sent copy remains")
        XCTAssertEqual(erased.mailboxPath, "Sent")
        XCTAssertThrowsError(try store.actionMembership(for: id, shownIn: "Trash"), "the Trash copy is gone")
    }

    /// A self-addressed message as sync commits it: Inbox first, then Sent,
    /// so the message row's mailbox is Sent.
    private func selfAddressed() throws -> MessageID {
        let id = try add("m1", uid: 7)
        let existing = try XCTUnwrap(store.messages.first { $0.id == id })
        _ = try store.commitIncomingMessage(
            existing.withMailboxPath("Sent"),
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "Sent", uidValidity: 10, uid: 3, notificationEligible: false
        )
        XCTAssertEqual(store.messages.first { $0.id == id }?.mailboxPath, "Sent")
        return id
    }

    func testActionMembershipIsTheCopyInTheShownMailbox() throws {
        let id = try selfAddressed()
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "INBOX").uid, 7)
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "inbox").uid, 7, "INBOX ignores case")
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "Sent").uid, 3)
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "Sent", uid: 3).uid, 3)
        XCTAssertEqual(try store.actionMembership(for: id).mailboxPath, "INBOX", "no shown mailbox: the Inbox copy, not the last synced")
        XCTAssertThrowsError(try store.actionMembership(for: id, shownIn: "Archive"))
        XCTAssertThrowsError(try store.actionMembership(for: id, shownIn: "Sent", uid: 7), "that UID isn't the Sent copy")
    }

    func testMovingTheInboxCopyLeavesTheSentCopyAndItsRow() throws {
        let id = try selfAddressed()
        let inbox = try store.actionMembership(for: id, shownIn: "INBOX")

        let moved = try store.applyConfirmedMailboxAction(
            .trash(to: "Trash", uidValidity: 44, uid: 501), membership: inbox,
            sourceSnapshot: .direct(generation: 1), actor: actor
        )

        XCTAssertEqual(moved.mailboxPath, "Trash", "the result describes the copy acted on")
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "Sent").uid, 3)
        XCTAssertEqual(try store.actionMembership(for: id, shownIn: "Trash").uid, 501)
        XCTAssertEqual(store.messages.first { $0.id == id }?.mailboxPath, "Sent")
    }

    func testErasingOneCopyKeepsTheMessageWhileAnotherCopyRemains() throws {
        let id = try selfAddressed()
        _ = try store.applyConfirmedMailboxAction(
            .trash(to: "Trash", uidValidity: 44, uid: 501),
            membership: try store.actionMembership(for: id, shownIn: "INBOX"),
            sourceSnapshot: .direct(generation: 1), actor: actor
        )

        let erased = try store.applyConfirmedMailboxAction(
            .delete, membership: try store.actionMembership(for: id, shownIn: "Trash"),
            sourceSnapshot: .direct(generation: 1), actor: actor
        )

        XCTAssertFalse(erased.isDeleted, "the result is the message, which still has its Sent copy")
        XCTAssertEqual(erased.mailboxPath, "Sent")
        let message = try XCTUnwrap(store.messages.first { $0.id == id })
        XCTAssertFalse(message.isDeleted, "the Sent copy is still there")
        XCTAssertEqual(message.mailboxPath, "Sent")
        XCTAssertThrowsError(try store.actionMembership(for: id, shownIn: "Trash"))
    }

    func testTrashMoveIntoAMailboxThatAlreadyHoldsTheMessageKeepsOneCopy() throws {
        let id = try add("m1", uid: 7)
        try addCopy(id, mailbox: "Trash", uid: 12)

        _ = try trash(id, uidValidity: 44, uid: 501)

        let shown = try store.displayedMembership(for: id)
        XCTAssertEqual(shown.mailboxPath, "Trash")
        XCTAssertEqual(shown.uid, 12, "the existing Trash copy stays; no second row")
        XCTAssertThrowsError(try store.membership(for: id, accountID: accountID, mailboxPath: "INBOX", uidValidity: 10, uid: 7))
    }

    func testTheLocalKeyHealsWhenSyncBringsTheTrashCopy() throws {
        let id = try add("m1", uid: 7)
        _ = try trash(id, uidValidity: nil, uid: nil)
        let local = try store.displayedMembership(for: id)
        XCTAssertEqual(local.uidValidity, 0)

        // A sync of Trash finds the server's copy of the same message.
        let synced = try XCTUnwrap(store.messages.first { $0.id == id })
        _ = try store.commitIncomingMessage(
            synced,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "Trash", uidValidity: 44, uid: 900, notificationEligible: false
        )

        let healed = try store.displayedMembership(for: id)
        XCTAssertEqual(healed.uidValidity, 44)
        XCTAssertEqual(healed.uid, 900)
        XCTAssertThrowsError(
            try store.membership(for: id, accountID: accountID, mailboxPath: "Trash", uidValidity: 0, uid: local.uid),
            "the local key row is gone"
        )
    }

    func testTrashMoveFallsBackToALocalKeyWhenTheProviderKeyIsTaken() throws {
        _ = try add("stale", mailbox: "Trash", uidValidity: 44, uid: 501)
        let id = try add("m1", uid: 7)

        _ = try trash(id, uidValidity: 44, uid: 501)

        let membership = try store.membership(for: id)
        XCTAssertEqual(membership.uidValidity, 0)
        XCTAssertLessThan(membership.uid, 0)
        XCTAssertEqual(try store.membership(for: MessageID("stale")).uid, 501)
    }

    func testSearchTrashRoleUsesTheSharedResolver() {
        func isTrash(_ path: String, _ specialUse: String? = nil) -> Bool {
            SQLiteMailSearchProjectionWriter.mailboxRoleTokens(specialUse: specialUse, name: path, path: path).contains("trash")
        }
        XCTAssertTrue(isTrash("Trash"))
        XCTAssertTrue(isTrash("[Gmail]/Papierkorb"))
        XCTAssertTrue(isTrash("Rubbish", "\\Trash"))
        XCTAssertFalse(isTrash("Projects/Deleted"), "a nested user folder is not Trash")
    }
}
