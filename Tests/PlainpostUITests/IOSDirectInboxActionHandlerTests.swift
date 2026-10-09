import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostIOSRuntime
import PlainpostTestSupport
@testable import PlainpostUI

final class IOSDirectInboxActionHandlerTests: XCTestCase {
    func testSelectedAccountRejectsForeignDirectMessageBeforeAnyMutation() async throws {
        let fixture = try Fixture()
        let messageA = try fixture.add("a", uid: 7)
        let messageB = try fixture.add("b", uid: 7)
        try await fixture.addPassword("a")
        try await fixture.addPassword("b")
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler,
            credentials: fixture.vault, selectedAccountID: AccountID("b"),
            imapClientFactory: { host, _ in fixture.client(host) }
        )

        for action in [InboxMailAction.markRead, .archive] {
            do {
                _ = try await handler.perform(action, messageID: messageA)
                XCTFail("Expected selected-account rejection")
            } catch {}
        }
        XCTAssertEqual(fixture.message(messageA)?.isSeen, false)
        XCTAssertEqual(fixture.message(messageA)?.mailboxPath, "INBOX")
        XCTAssertTrue(fixture.client("a").archived.isEmpty)
        XCTAssertTrue(try fixture.store.jobs(limit: 10).isEmpty)

        let own = try await handler.perform(.markRead, messageID: messageB)
        XCTAssertEqual(own.seen, true)
    }

    func testArchiveUsesOwningAccountWithSameUID() async throws {
        let fixture = try Fixture()
        let messageA = try fixture.add("a", uid: 7)
        let messageB = try fixture.add("b", uid: 7)
        try await fixture.addPassword("a")
        try await fixture.addPassword("b")

        let result = try await fixture.handler.perform(.archive, messageID: messageB)

        XCTAssertEqual(result.mailboxPath, "Archive")
        XCTAssertEqual(fixture.client("a").archived, [])
        XCTAssertEqual(fixture.client("b").archived, [7])
        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["INBOX"])
        XCTAssertEqual(fixture.client("b").usernames, ["b@example.test"])
        XCTAssertEqual(fixture.message(messageA)?.mailboxPath, "INBOX")
        XCTAssertEqual(fixture.message(messageB)?.mailboxPath, "Archive")
    }

    // MARK: - Flag and Move

    private func sharedActions(_ fixture: Fixture) -> DirectMailboxActionService {
        DirectMailboxActionService(
            store: fixture.store,
            credentials: .withoutGoogleOAuth(store: fixture.store, credentials: fixture.vault),
            requireExplicitDirectSource: false,
            imapClientFactory: { host, _ in fixture.client(host) },
            signalFlagWork: { try await fixture.scheduler.signalWork() }
        )
    }

    func testFlagSetsAndClearsFlaggedOnTheServerAndInTheStore() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("a", uid: 7)
        try await fixture.addPassword("a")
        let actions = sharedActions(fixture)

        let flagged = try await actions.perform(.flag, messageID: message)
        XCTAssertTrue(flagged.message.isFlagged)
        XCTAssertEqual(fixture.client("a").flagChanges, ["7+\\Flagged"])
        XCTAssertEqual(try fixture.store.messageSummary(id: message)?.isFlagged, true)
        XCTAssertEqual(try fixture.store.mailboxListMessages(inMailboxPath: "INBOX", limit: 10, query: "").first?.isFlagged, true, "lists show it")

        let cleared = try await actions.perform(.unflag, messageID: message)
        XCTAssertFalse(cleared.message.isFlagged)
        XCTAssertEqual(fixture.client("a").flagChanges, ["7+\\Flagged", "7-\\Flagged"])
        XCTAssertEqual(try fixture.store.messageSummary(id: message)?.isFlagged, false)
    }

    func testAFlagTheServerRefusesChangesNothing() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("a", uid: 7)
        try await fixture.addPassword("a")
        fixture.client("a").failure = .protocolError("NO flags refused")
        do {
            _ = try await sharedActions(fixture).perform(.flag, messageID: message)
            XCTFail("expected the refusal")
        } catch {}
        XCTAssertEqual(try fixture.store.messageSummary(id: message)?.isFlagged, false)
    }

    func testMoveGoesToTheChosenFolderOfTheMessagesAccount() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("a", uid: 7, folders: [
            Mailbox(id: MailboxID("a-inbox"), accountID: AccountID("a"), name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("a-receipts"), accountID: AccountID("a"), name: "Receipts", path: "Receipts", specialUse: nil),
        ])
        try await fixture.addPassword("a")
        fixture.client("a").copyUID = (uidValidity: 20, uid: 3)

        let result = try await sharedActions(fixture).perform(.move(to: "Receipts"), messageID: message)

        XCTAssertEqual(fixture.client("a").moved, ["7->Receipts"])
        XCTAssertEqual(result.message.mailboxPath, "Receipts")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Receipts")
    }

    func testMoveToAFolderTheAccountDoesntHaveIsRefusedBeforeTheServer() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("a", uid: 7)
        try await fixture.addPassword("a")
        do {
            _ = try await sharedActions(fixture).perform(.move(to: "Elsewhere"), messageID: message)
            XCTFail("expected a refusal")
        } catch {}
        XCTAssertTrue(fixture.client("a").moved.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testSharedServiceMacCompositionUsesSameOwningAccount() async throws {
        let fixture = try Fixture()
        let messageA = try fixture.add("a", uid: 7)
        let messageB = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let actions = DirectMailboxActionService(
            store: fixture.store,
            credentials: .withoutGoogleOAuth(store: fixture.store, credentials: fixture.vault),
            requireExplicitDirectSource: false,
            imapClientFactory: { host, _ in fixture.client(host) },
            signalFlagWork: { try await fixture.scheduler.signalWork() }
        )

        let result = try await actions.perform(.delete, messageID: messageB)

        XCTAssertEqual(result.message.mailboxPath, "Trash")
        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(fixture.message(messageA)?.mailboxPath, "INBOX")
        XCTAssertTrue(fixture.client("a").moved.isEmpty)
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
    }

    func testReadAndUnreadScheduleExactMembership() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler,
            credentials: fixture.vault, selectedAccountID: AccountID("b"),
            imapClientFactory: { host, _ in fixture.client(host) }
        )

        let read = try await handler.perform(.markRead, messageID: message)
        let unread = try await handler.perform(.markUnread, messageID: message)
        XCTAssertEqual(read.seen, true)
        XCTAssertEqual(unread.seen, false)
        let jobs = try fixture.store.jobs(limit: 10).filter { $0.kind == .mailboxFlag }
        XCTAssertEqual(jobs.count, 2)
        let inputs = try jobs.map { try JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: Data($0.payloadJSON.utf8)) }
        XCTAssertEqual(inputs.map(\.accountID), [AccountID("b"), AccountID("b")])
        XCTAssertEqual(inputs.map(\.uid), [7, 7])
        XCTAssertEqual(Set(inputs.map(\.desiredSeen)), [true, false])
        XCTAssertEqual(inputs.map(\.expectedDirectSourceGeneration), [1, 1])
    }

    /// The device-wide handler has no selected account: a read still schedules the owning
    /// account's flag job at that account's own generation, so the every-account worker can
    /// claim it and fence it against a source switch.
    func testUnscopedReadSchedulesOwnersGeneration() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler,
            credentials: fixture.vault,
            imapClientFactory: { host, _ in fixture.client(host) }
        )

        _ = try await handler.perform(.markRead, messageID: message)
        let jobs = try fixture.store.jobs(limit: 10).filter { $0.kind == .mailboxFlag }
        let inputs = try jobs.map { try JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: Data($0.payloadJSON.utf8)) }
        XCTAssertEqual(inputs.map(\.accountID), [AccountID("b")])
        XCTAssertEqual(inputs.map(\.expectedDirectSourceGeneration), [1])
    }

    func testRetainedSelectedReadHandlerRejectsDirectNodeDirectGenerationChange() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler,
            credentials: fixture.vault, selectedAccountID: AccountID("b"),
            imapClientFactory: { host, _ in fixture.client(host) }
        )
        let direct = try fixture.store.mailSource(accountID: AccountID("b"))
        let node = try fixture.store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "b@example.test"
        ), expectedGeneration: direct.generation)
        try fixture.store.replaceMailSource(node.revertedToDirect(), expectedGeneration: node.generation)

        do {
            _ = try await handler.perform(.markRead, messageID: message)
            XCTFail("Retained handler must reject the new Direct generation")
        } catch NodeMailModeStoreError.generationConflict {}
        XCTAssertEqual(fixture.message(message)?.isSeen, false)
        XCTAssertTrue(try fixture.store.jobs(limit: 10).isEmpty)
    }

    func testDeleteConfirmsProviderBeforeCacheMutation() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        fixture.client("b").failure = .connectionFailed
        do {
            _ = try await fixture.handler.perform(.delete, messageID: message)
            XCTFail("Expected provider failure")
        } catch IMAPClientError.connectionFailed {}
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
        fixture.client("b").failure = nil
        let deleted = try await fixture.handler.perform(.delete, messageID: message)
        XCTAssertEqual(deleted.mailboxPath, "Trash")
        XCTAssertFalse(deleted.deleted)
    }

    func testMissingCredentialFailsBeforeProviderMutation() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        do {
            _ = try await fixture.handler.perform(.archive, messageID: message)
            XCTFail("Expected missing credential")
        } catch {}
        XCTAssertTrue(fixture.client("b").archived.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testNodeSourceFailsBeforeProviderMutation() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let source = try fixture.store.mailSource(accountID: AccountID("b"))
        try fixture.store.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "b@example.test"
        ), expectedGeneration: 1)
        do {
            _ = try await fixture.handler.perform(.delete, messageID: message)
            XCTFail("Expected Node source rejection")
        } catch {}
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testChangedUIDValidityFailsBeforeProviderMutation() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        fixture.client("b").uidValidity = 99
        do {
            _ = try await fixture.handler.perform(.delete, messageID: message)
            XCTFail("Expected stale membership rejection")
        } catch {}
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testSourceSwitchDuringCredentialLoadFailsClosed() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        let credentials = SwitchingCredentialVault(store: fixture.store, accountID: AccountID("b"))
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler,
            credentials: credentials, imapClientFactory: { host, _ in fixture.client(host) }
        )

        do {
            _ = try await handler.perform(.archive, messageID: message)
            XCTFail("Expected changed source rejection")
        } catch {}
        XCTAssertTrue(fixture.client("b").archived.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testSourceSwitchDuringConfirmedArchiveDoesNotMutateNewSourceCache() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let gate = SuspendedProviderCommand()
        fixture.client("b").commandGate = gate
        let handler = fixture.handler
        let pending = Task { try await handler.perform(.archive, messageID: message) }
        await gate.waitUntilEntered()
        let source = try fixture.store.mailSource(accountID: AccountID("b"))
        try fixture.store.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "b@example.test"
        ), expectedGeneration: source.generation)
        await gate.release()

        do {
            _ = try await pending.value
            XCTFail("Confirmed provider action must report a reconciliation conflict")
        } catch let error as ConfirmedMailboxActionConflict {
            XCTAssertEqual(error, .sourceChanged)
        } catch {
            XCTFail("Expected source reconciliation conflict, got \(error)")
        }
        XCTAssertEqual(fixture.client("b").archived, [7])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testMembershipReplacementDuringConfirmedDeleteDoesNotDeleteNewRow() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let gate = SuspendedProviderCommand()
        fixture.client("b").commandGate = gate
        let handler = fixture.handler
        let pending = Task { try await handler.perform(.delete, messageID: message) }
        await gate.waitUntilEntered()
        try fixture.store.reconcileMailboxState(
            accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10, states: []
        )
        let replacement = MessageSummary(
            id: message, threadID: ThreadID("b-thread"),
            from: EmailAddress("sender@example.test"), subject: "replacement",
            preview: "replacement", smartCategory: .personal
        )
        _ = try fixture.store.commitIncomingMessage(
            replacement,
            metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 11, uid: 8,
            notificationEligible: false
        )
        await gate.release()

        do {
            _ = try await pending.value
            XCTFail("Confirmed provider action must report a reconciliation conflict")
        } catch let error as ConfirmedMailboxActionConflict {
            XCTAssertEqual(error, .membershipChanged)
        } catch {
            XCTFail("Expected membership reconciliation conflict, got \(error)")
        }
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertEqual(try fixture.store.membership(for: message).uidValidity, 11)
        XCTAssertEqual(try fixture.store.membership(for: message).uid, 8)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testLegacyMacSourceAppearingDuringArchiveReportsConflict() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7, publishDirectSource: false)
        try await fixture.addPassword("b")
        let gate = SuspendedProviderCommand()
        fixture.client("b").commandGate = gate
        let actions = DirectMailboxActionService(
            store: fixture.store,
            credentials: .withoutGoogleOAuth(store: fixture.store, credentials: fixture.vault),
            requireExplicitDirectSource: false,
            imapClientFactory: { host, _ in fixture.client(host) },
            signalFlagWork: { try await fixture.scheduler.signalWork() }
        )
        let pending = Task { try await actions.perform(.archive, messageID: message) }
        await gate.waitUntilEntered()
        let source = AccountMailSource.direct(AccountID("b"))
        try fixture.store.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "b@example.test"
        ), expectedGeneration: 0)
        await gate.release()

        do {
            _ = try await pending.value
            XCTFail("Legacy source appearing during provider work must conflict")
        } catch let error as ConfirmedMailboxActionConflict {
            XCTAssertEqual(error, .sourceChanged)
        } catch {
            XCTFail("Expected source reconciliation conflict, got \(error)")
        }
        XCTAssertEqual(fixture.client("b").archived, [7])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    // MARK: Delete moves to Trash

    func testDeleteMovesToTrashUnderTheNewUIDAndNeverErases() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        fixture.client("b").copyUID = (uidValidity: 44, uid: 501)

        let result = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(result.mailboxPath, "Trash")
        XCTAssertFalse(result.deleted)
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertTrue(fixture.client("b").deleted.isEmpty, "Delete outside Trash never erases")
        XCTAssertEqual(fixture.client("b").listCount, 0, "the cached folder list named Trash")
        let membership = try fixture.store.membership(for: message)
        XCTAssertEqual(membership.mailboxPath, "Trash")
        XCTAssertEqual(membership.uidValidity, 44)
        XCTAssertEqual(membership.uid, 501)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    /// Some servers (Purelymail) deliver one message twice: two Inbox UIDs with
    /// one Message-ID, shown as one row. Deleting it moves both copies; moving
    /// only one let the other come back on the next sync.
    func testDeleteMovesEveryInboxCopyOfAMessageDeliveredTwice() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try fixture.addCopy(of: message, account: "b", mailbox: "INBOX", uid: 8)
        try await fixture.addPassword("b")

        let result = try await fixture.handler.perform(.delete, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash", "8->Trash"])
        XCTAssertEqual(try fixture.store.cachedUIDs(accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10), [])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Trash")
    }

    func testACopyTheServerDidNotMoveStaysInTheInbox() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try fixture.addCopy(of: message, account: "b", mailbox: "INBOX", uid: 8)
        try await fixture.addPassword("b")
        fixture.client("b").failingMoveUIDs = [8]

        let result = try await fixture.handler.perform(.delete, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash", "8->Trash"])
        XCTAssertEqual(
            try fixture.store.cachedUIDs(accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10), [8],
            "the copy still on the server stays cached, so no sync downloads it as new"
        )
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testArchiveMovesEveryInboxCopyOfAMessageDeliveredTwice() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try fixture.addCopy(of: message, account: "b", mailbox: "INBOX", uid: 8)
        try await fixture.addPassword("b")

        _ = try await fixture.handler.perform(.archive, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(fixture.client("b").archived, [7, 8])
        XCTAssertEqual(try fixture.store.cachedUIDs(accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10), [])
    }

    func testPlainDeleteInsideTrashChangesNothing() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 9, mailbox: "Trash")
        try await fixture.addPassword("b")

        let result = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(result.deleteOutcome, .alreadyInTrash)
        XCTAssertFalse(result.deleted)
        XCTAssertTrue(fixture.client("b").selectedMailboxes.isEmpty, "no server contact")
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testDeletePermanentlyInsideTrashErases() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 9, mailbox: "Trash")
        try await fixture.addPassword("b")

        let result = try await fixture.handler.perform(.deletePermanently, messageID: message)

        XCTAssertEqual(result.deleteOutcome, .deletedPermanently)
        XCTAssertTrue(result.deleted)
        XCTAssertNil(result.mailboxPath)
        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["Trash"])
        XCTAssertEqual(fixture.client("b").deleted, [9])
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, true)
    }

    func testDeletePermanentlyErasesEveryTrashCopyOfAMessageDeliveredTwice() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 9, mailbox: "Trash")
        try fixture.addCopy(of: message, account: "b", mailbox: "Trash", uid: 10)
        try await fixture.addPassword("b")

        let result = try await fixture.handler.perform(.deletePermanently, messageID: message)

        XCTAssertEqual(result.deleteOutcome, .deletedPermanently)
        XCTAssertEqual(fixture.client("b").deleted, [9, 10])
        XCTAssertEqual(fixture.message(message)?.isDeleted, true)
    }

    func testDeleteWithoutTrashFailsClosedAndNeverErases() async throws {
        let fixture = try Fixture()
        let accountID = AccountID("b")
        let message = try fixture.add("b", uid: 7, folders: [
            Mailbox(id: MailboxID("b-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("b-archive"), accountID: accountID, name: "Archive", path: "Archive", specialUse: "\\Archive"),
        ])
        try await fixture.addPassword("b")
        fixture.client("b").listed = [
            Mailbox(id: MailboxID("x"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
        ]

        do {
            _ = try await fixture.handler.perform(.delete, messageID: message)
            XCTFail("Delete without a Trash mailbox must refuse")
        } catch PlainpostError.validationFailed(let text) {
            XCTAssertEqual(text, TrashDelete.noTrashMessage)
        }

        XCTAssertEqual(fixture.client("b").listCount, 1, "the server's folder list is checked before refusing")
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testDeleteFindsTrashOnTheServerWhenTheCachedListLacksIt() async throws {
        let fixture = try Fixture()
        let accountID = AccountID("b")
        let message = try fixture.add("b", uid: 7, folders: [
            Mailbox(id: MailboxID("b-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
        ])
        try await fixture.addPassword("b")
        fixture.client("b").listed = [
            Mailbox(id: MailboxID("x"), accountID: accountID, name: "Deleted Messages", path: "Deleted Messages", specialUse: nil),
        ]

        let result = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(result.mailboxPath, "Deleted Messages")
        XCTAssertEqual(fixture.client("b").moved, ["7->Deleted Messages"])
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
    }

    func testGmailDeleteMovesToGmailTrash() async throws {
        let fixture = try Fixture()
        let accountID = AccountID("g")
        let message = try fixture.add("g", uid: 7, email: "g@gmail.com", folders: [
            Mailbox(id: MailboxID("g-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("g-all"), accountID: accountID, name: "All Mail", path: "[Gmail]/All Mail", specialUse: "\\All"),
            Mailbox(id: MailboxID("g-bin"), accountID: accountID, name: "Bin", path: "[Gmail]/Bin", specialUse: "\\Trash"),
        ])
        try await fixture.addPassword("g")

        let result = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(result.mailboxPath, "[Gmail]/Bin")
        XCTAssertEqual(fixture.client("g").moved, ["7->[Gmail]/Bin"])
        XCTAssertTrue(fixture.client("g").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "[Gmail]/Bin")
    }

    func testRetriedDeleteNeverErases() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        fixture.client("b").copyUID = (uidValidity: 44, uid: 501)

        let first = try await fixture.handler.perform(.delete, messageID: message)
        let retry = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(first.deleteOutcome, .movedToTrash)
        XCTAssertEqual(retry.deleteOutcome, .alreadyInTrash)
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertTrue(fixture.client("b").deleted.isEmpty, "a retry with a valid Trash key still never erases")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Trash")
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testDeletePermanentlyOutsideTrashRefusesBeforeAnyChange() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")

        do {
            _ = try await fixture.handler.perform(.deletePermanently, messageID: message)
            XCTFail("an Inbox message must not be erased")
        } catch PlainpostError.validationFailed(let text) {
            XCTAssertEqual(text, TrashDelete.permanentOutsideTrashMessage)
        }
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    func testAnUnrecognizedTrashNeverErases() async throws {
        let fixture = try Fixture()
        let accountID = AccountID("b")
        // A Trash the server doesn't mark and whose name isn't known: not Trash.
        let message = try fixture.add("b", uid: 7, mailbox: "Mülleimer", folders: [
            Mailbox(id: MailboxID("b-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("b-m"), accountID: accountID, name: "Mülleimer", path: "Mülleimer", specialUse: nil),
        ])
        try await fixture.addPassword("b")

        for action in [InboxMailAction.delete, .deletePermanently] {
            do {
                _ = try await fixture.handler.perform(action, messageID: message)
                XCTFail("\(action) must refuse without a recognized Trash")
            } catch PlainpostError.validationFailed {}
        }

        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testDeletePermanentlyInTrashAfterAMoveWithoutCOPYUIDNeedsASyncFirst() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        _ = try await fixture.handler.perform(.delete, messageID: message)
        XCTAssertEqual(try fixture.store.membership(for: message).uidValidity, 0)

        do {
            _ = try await fixture.handler.perform(.deletePermanently, messageID: message)
            XCTFail("the old Inbox UID must never be expunged from Trash")
        } catch PlainpostError.validationFailed {}

        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    func testDeleteActsOnTheCopyShownNotTheFirstSortedCopy() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        // The same message CC'd to yourself also has a copy in Sent, which sorts
        // before Trash once the Inbox copy has moved.
        try fixture.addCopy(of: message, account: "b", mailbox: "Sent", uid: 3)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
        try await fixture.addPassword("b")

        _ = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["INBOX"])
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Trash")
        XCTAssertEqual(try fixture.store.displayedMembership(for: message).mailboxPath, "Trash")
        XCTAssertEqual(try fixture.store.membership(for: message).mailboxPath, "Sent",
                       "the Sent copy stays, and sorts first")

        // Archive (the other action that targets a copy) now acts on the Trash copy, never on Sent.
        fixture.client("b").selectedMailboxes = []
        _ = try? await fixture.handler.perform(.archive, messageID: message)
        XCTAssertFalse(fixture.client("b").selectedMailboxes.contains("Sent"))
    }

    // MARK: Self-addressed message with Sent sync on

    /// A message you sent to yourself, synced the way sync does it: the Inbox
    /// copy first, then the Sent copy, which leaves `messages.mailbox_path` = Sent.
    private func selfAddressed(_ fixture: Fixture) async throws -> MessageID {
        let message = try fixture.add("b", uid: 7)
        try fixture.addSyncedCopy(of: message, account: "b", mailbox: "Sent", uid: 3)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Sent", "the last synced copy wins the message row")
        try await fixture.addPassword("b")
        return message
    }

    private func assertSentCopyUntouched(_ fixture: Fixture, _ message: MessageID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(
            try fixture.store.membership(for: message, accountID: AccountID("b"), mailboxPath: "Sent", uidValidity: 10, uid: 3),
            file: file, line: line
        )
        XCTAssertFalse(fixture.client("b").selectedMailboxes.contains("Sent"), file: file, line: line)
    }

    func testInboxDeleteOfASelfAddressedMessageMovesOnlyTheInboxCopy() async throws {
        let fixture = try Fixture()
        let message = try await selfAddressed(fixture)

        let result = try await fixture.handler.perform(.delete, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(result.deleteOutcome, .movedToTrash)
        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["INBOX"])
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        assertSentCopyUntouched(fixture, message)
    }

    func testInboxArchiveOfASelfAddressedMessageArchivesOnlyTheInboxCopy() async throws {
        let fixture = try Fixture()
        let message = try await selfAddressed(fixture)

        _ = try await fixture.handler.perform(.archive, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["INBOX"])
        XCTAssertEqual(fixture.client("b").archived, [7])
        assertSentCopyUntouched(fixture, message)
    }

    func testWithoutAShownMailboxTheInboxCopyIsChosenNotTheLastSynced() async throws {
        let fixture = try Fixture()
        let message = try await selfAddressed(fixture)

        _ = try await fixture.handler.perform(.delete, messageID: message)

        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        assertSentCopyUntouched(fixture, message)
    }

    func testDeleteShownInSentMovesTheSentCopy() async throws {
        let fixture = try Fixture()
        let message = try await selfAddressed(fixture)

        _ = try await fixture.handler.perform(.delete, messageID: message, shownIn: "Sent")

        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["Sent"])
        XCTAssertEqual(fixture.client("b").moved, ["3->Trash"])
        XCTAssertNoThrow(try fixture.store.membership(for: message, accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10, uid: 7))
    }

    func testAskMailOpenOfAnArchivedMessageDeletesAndArchivesTheRightCopy() async throws {
        // Ask Mail opens messages that live outside the list underneath (Smart
        // Inbox); the conversation passes no shown mailbox, so the message's own
        // copy is used rather than a refusal.
        let fixture = try Fixture()
        let archived = try fixture.add("b", uid: 7, mailbox: "Archive", folders: [
            Mailbox(id: MailboxID("b-inbox"), accountID: AccountID("b"), name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("b-archive"), accountID: AccountID("b"), name: "Archive", path: "Archive", specialUse: "\\Archive"),
            Mailbox(id: MailboxID("b-trash"), accountID: AccountID("b"), name: "Trash", path: "Trash", specialUse: "\\Trash"),
        ])
        try await fixture.addPassword("b")
        let shownIn = MobileMailbox.actionList(under: .smartInbox, messageID: archived.rawValue, listMessageIDs: [])?.shownMailboxPath
        XCTAssertNil(shownIn)

        let deleted = try await fixture.handler.perform(.delete, messageID: archived, shownIn: shownIn)

        XCTAssertEqual(deleted.deleteOutcome, .movedToTrash)
        XCTAssertEqual(fixture.client("b").selectedMailboxes, ["Archive"])
        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])

        let sentFixture = try Fixture()
        let sent = try sentFixture.add("b", uid: 3, mailbox: "Sent")
        try await sentFixture.addPassword("b")
        _ = try await sentFixture.handler.perform(.archive, messageID: sent, shownIn: shownIn)
        XCTAssertEqual(sentFixture.client("b").selectedMailboxes, ["Sent"])
        XCTAssertEqual(sentFixture.client("b").archived, [3])
        XCTAssertEqual(sentFixture.message(sent)?.mailboxPath, "Archive")
    }

    // MARK: Archive goes to the account's own Archive (Gmail: All Mail)

    /// A real IMAP session against a server with exactly these folders, which the
    /// cached folder list also names (as after a sync).
    private static func layoutServer(
        _ folders: [(path: String, specialUse: String?)], cached: [(path: String, specialUse: String?)]? = nil,
        messageIn mailbox: String = "INBOX"
    ) async throws -> (Fixture, LocalIMAPServer, IOSDirectInboxActionHandler, MessageID) {
        let fixture = try Fixture()
        let accountID = AccountID("b")
        let message = try fixture.add("b", uid: 7, mailbox: mailbox, folders: (cached ?? folders).map {
            Mailbox(id: MailboxID("b-\($0.path)"), accountID: accountID, name: $0.path, path: $0.path, specialUse: $0.specialUse)
        })
        try await fixture.addPassword("b")
        let server = LocalIMAPServer(
            username: "b@example.test", password: "secret", message: try XCTUnwrap(fixture.message(message)),
            peer: LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"],
                mailboxes: folders.map { .init(path: $0.path, specialUse: $0.specialUse) },
                uidValidity: 10, messageUID: 7,
                messageData: Data("Subject: archived\r\n\r\nbody".utf8)
            )
        )
        try await server.start()
        let port = server.port
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler, credentials: fixture.vault
        ) { _, _ in PlaintextIMAPClient(host: "127.0.0.1", port: port) }
        return (fixture, server, handler, message)
    }

    /// The device's Gmail account: no Archive folder.
    private static let gmailFolders: [(path: String, specialUse: String?)] = [
        ("INBOX", "\\Inbox"), ("[Gmail]/All Mail", "\\All"), ("[Gmail]/Trash", "\\Trash"),
    ]

    func testGmailArchiveMovesToAllMailKeyedByCOPYUID() async throws {
        let (fixture, server, handler, message) = try await Self.layoutServer(Self.gmailFolders)
        defer { server.stop() }

        let result = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "[Gmail]/All Mail""#])
        XCTAssertEqual(result.mailboxPath, "[Gmail]/All Mail")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "[Gmail]/All Mail")
        let archived = try fixture.store.actionMembership(for: message, shownIn: "[Gmail]/All Mail")
        XCTAssertEqual(archived.uid, 501, "keyed by COPYUID, not the Inbox UID 7")

        // The iPhone Archive folder is All Mail, and an action there names that copy.
        let sections = MailboxDirectoryModel.sections(
            accounts: fixture.store.accounts, mailboxes: fixture.store.mailboxes, unreadCounts: [:]
        )
        let archiveFolders = sections.flatMap(\.folders).filter { $0.role == .archive }
        XCTAssertEqual(archiveFolders.map(\.path), ["[Gmail]/All Mail"])
        _ = try await handler.perform(.delete, messageID: message, shownIn: archiveFolders.first?.path)
        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "[Gmail]/All Mail""#, #"MOVE 501 "[Gmail]/Trash""#])
    }

    @MainActor
    func testArchiveFromSearchOfAMessageOnlyInAllMailSendsNothingAndKeepsIt() async throws {
        // A Gmail conversation opened from search or Ask Mail: no list underneath,
        // so no shown mailbox; the message's only copy is in All Mail.
        let (fixture, server, handler, message) = try await Self.layoutServer(Self.gmailFolders, messageIn: "[Gmail]/All Mail")
        defer { server.stop() }
        let shownIn = MobileMailbox.actionList(under: .smartInbox, messageID: message.rawValue, listMessageIDs: [])?.shownMailboxPath
        XCTAssertNil(shownIn)
        let actions = InboxMailActionViewModel(handler: handler)

        let outcome = await actions.perform(.archive, messageID: message.rawValue, shownIn: shownIn)

        guard case .succeeded(let result) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertTrue(result.alreadyArchived)
        XCTAssertEqual(result.mailboxPath, "[Gmail]/All Mail")
        XCTAssertEqual(actions.statusMessage, "This message is already archived.")
        XCTAssertEqual(server.uidCommands, [])
        XCTAssertEqual(server.selectedMailboxes, [], "the cached folder list settles it: no server contact")
        let copy = try fixture.store.actionMembership(for: message, shownIn: "[Gmail]/All Mail")
        XCTAssertEqual(copy.uid, 7, "the All Mail copy stays")
    }

    func testArchiveOfACopyFoundInTheArchiveByTheServerListSendsNothing() async throws {
        // The cached folder list predates All Mail; the server's list names it.
        let (fixture, server, handler, message) = try await Self.layoutServer(
            Self.gmailFolders, cached: [("INBOX", "\\Inbox"), ("[Gmail]/Trash", "\\Trash")], messageIn: "[Gmail]/All Mail"
        )
        defer { server.stop() }

        let result = try await handler.perform(.archive, messageID: message, shownIn: "[Gmail]/All Mail")

        XCTAssertTrue(result.alreadyArchived)
        XCTAssertEqual(server.uidCommands, [])
        XCTAssertEqual(try fixture.store.actionMembership(for: message, shownIn: "[Gmail]/All Mail").uid, 7)
    }

    func testArchiveSpecialUseUnderAnotherNameIsTheDestination() async throws {
        let (fixture, server, handler, message) = try await Self.layoutServer([
            ("INBOX", "\\Inbox"), ("Archive", nil), ("Saved", "\\Archive"), ("Trash", "\\Trash"),
        ])
        defer { server.stop() }

        let result = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "Saved""#])
        XCTAssertEqual(result.mailboxPath, "Saved")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Saved")
    }

    func testAFolderNamedArchiveStillReceivesArchives() async throws {
        let (fixture, server, handler, message) = try await Self.layoutServer([
            ("INBOX", "\\Inbox"), ("Archive", nil), ("Trash", "\\Trash"),
        ])
        defer { server.stop() }

        _ = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")

        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "Archive""#])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Archive")
    }

    func testNoArchiveFolderRefusesWithAClearMessageAndNoUIDCommand() async throws {
        let (fixture, server, handler, message) = try await Self.layoutServer([("INBOX", "\\Inbox"), ("Trash", "\\Trash")])
        defer { server.stop() }

        do {
            _ = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")
            XCTFail("an account without an Archive folder must refuse")
        } catch PlainpostError.validationFailed(let text) {
            XCTAssertEqual(text, ArchiveMailbox.noArchiveMessage)
        }

        XCTAssertEqual(server.uidCommands, [])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    @MainActor
    func testAServerRefusalShowsAReadableReasonNotMailActionFailed() async throws {
        // The cached folder list still names an Archive the server has since removed.
        let (fixture, server, handler, message) = try await Self.layoutServer(
            [("INBOX", "\\Inbox"), ("Trash", "\\Trash")],
            cached: [("INBOX", "\\Inbox"), ("Archive", "\\Archive"), ("Trash", "\\Trash")]
        )
        defer { server.stop() }
        let actions = InboxMailActionViewModel(handler: handler)

        let outcome = await actions.perform(.archive, messageID: message.rawValue, shownIn: "INBOX")

        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "Archive""#])
        XCTAssertEqual(outcome, .failed(message: "The mail server refused to archive this message: no such mailbox."))
        XCTAssertEqual(actions.statusMessage, "The mail server refused to archive this message: no such mailbox.")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")
    }

    @MainActor
    func testARefusedDeleteShowsAReadableReason() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        fixture.client("b").failure = .protocolError("A0006 NO [OVERQUOTA] Quota exceeded")
        let actions = InboxMailActionViewModel(handler: fixture.handler)

        let outcome = await actions.perform(.delete, messageID: message.rawValue)

        XCTAssertEqual(outcome, .failed(message: "The mail server refused to delete this message: Quota exceeded."))
    }

    // MARK: Archive keys its copy by the server's new UID (final review I1)

    /// A real IMAP session against a server that gives every mailbox the same
    /// UIDVALIDITY (as Dovecot often does), so a stale UID would match.
    private func archiveServer(capabilities: [String]) async throws -> (Fixture, LocalIMAPServer, IOSDirectInboxActionHandler, MessageID) {
        let fixture = try Fixture()
        let accountID = AccountID("b")
        let message = try fixture.add("b", uid: 7, folders: [
            Mailbox(id: MailboxID("b-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
            Mailbox(id: MailboxID("b-archive"), accountID: accountID, name: "Archive", path: "Archive", specialUse: "\\Archive"),
            Mailbox(id: MailboxID("b-trash"), accountID: accountID, name: "Trash", path: "Trash", specialUse: "\\Trash"),
        ])
        try await fixture.addPassword("b")
        let server = LocalIMAPServer(
            username: "b@example.test", password: "secret", message: try XCTUnwrap(fixture.message(message)),
            peer: LocalIMAPPeerResponse(
                capabilities: capabilities,
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox"), .init(path: "Archive", specialUse: "\\Archive"),
                            .init(path: "Trash", specialUse: "\\Trash")],
                uidValidity: 10, messageUID: 7,
                messageData: Data("Subject: archived\r\n\r\nbody".utf8)
            )
        )
        try await server.start()
        let port = server.port
        let handler = IOSDirectInboxActionHandler(
            store: fixture.store, mailboxFlagScheduler: fixture.scheduler, credentials: fixture.vault
        ) { _, _ in PlaintextIMAPClient(host: "127.0.0.1", port: port) }
        return (fixture, server, handler, message)
    }

    func testDeleteInArchiveAfterArchivingUsesTheArchiveCopysOwnUID() async throws {
        let (fixture, server, handler, message) = try await archiveServer(capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"])
        defer { server.stop() }

        _ = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")
        let archived = try fixture.store.actionMembership(for: message, shownIn: "Archive")
        XCTAssertEqual(archived.uid, 501, "keyed by COPYUID, not the Inbox UID 7")

        _ = try await handler.perform(.delete, messageID: message, shownIn: "Archive")

        XCTAssertEqual(server.uidCommands, [#"MOVE 7 "Archive""#, #"MOVE 501 "Trash""#])
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Trash")
    }

    func testDeleteInArchiveWithoutCOPYUIDFailsClosedInsteadOfGuessingAUID() async throws {
        let (fixture, server, handler, message) = try await archiveServer(capabilities: ["IMAP4rev1", "UIDPLUS"])
        defer { server.stop() }

        _ = try await handler.perform(.archive, messageID: message, shownIn: "INBOX")
        XCTAssertEqual(try fixture.store.actionMembership(for: message, shownIn: "Archive").uidValidity, 0, "a local key")
        let afterArchive = server.uidCommands

        do {
            _ = try await handler.perform(.delete, messageID: message, shownIn: "Archive")
            XCTFail("an unknown Archive UID must not be guessed")
        } catch PlainpostError.validationFailed {}

        XCTAssertEqual(afterArchive, [#"COPY 7 "Archive""#, #"STORE 7 +FLAGS.SILENT (\Deleted)"#, "EXPUNGE 7"])
        XCTAssertEqual(server.uidCommands, afterArchive, "nothing reached the server for the Delete")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Archive")
    }

    func testAShownMailboxWithoutTheMessageFailsBeforeTheServer() async throws {
        let fixture = try Fixture()
        let message = try await selfAddressed(fixture)

        for action in [InboxMailAction.delete, .archive] {
            do {
                _ = try await fixture.handler.perform(action, messageID: message, shownIn: "Archive")
                XCTFail("\(action) must refuse when the shown mailbox has no copy")
            } catch PlainpostError.validationFailed {}
        }
        XCTAssertTrue(fixture.client("b").selectedMailboxes.isEmpty)
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").archived.isEmpty)
    }

    func testActionOnAMessageWithNoCopyInItsMailboxFailsBeforeTheServer() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try fixture.addCopy(of: message, account: "b", mailbox: "Sent", uid: 3)
        try await fixture.addPassword("b")
        // The Inbox copy vanished locally (for example, a sync removed it).
        try fixture.store.reconcileMailboxState(accountID: AccountID("b"), mailboxPath: "INBOX", uidValidity: 10, states: [])

        do {
            _ = try await fixture.handler.perform(.delete, messageID: message)
            XCTFail("a Delete with no copy where the message is shown must refuse")
        } catch PlainpostError.validationFailed {}

        XCTAssertTrue(fixture.client("b").selectedMailboxes.isEmpty, "no server contact at all")
        XCTAssertTrue(fixture.client("b").moved.isEmpty)
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
    }

    @MainActor
    func testDeleteOfAMessageAlreadyInTrashSettlesWithoutAnError() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 9, mailbox: "Trash")
        try await fixture.addPassword("b")
        let actions = InboxMailActionViewModel(handler: fixture.handler)
        var failures: [String] = []
        let controller = MessageActionController(
            mailbox: MailboxController(
                destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
                navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
            ),
            refreshBus: MailboxRefreshBus(), commitDelay: .zero,
            performInMailbox: { action, id, shownIn in await actions.perform(action, messageID: id, shownIn: shownIn) },
            reproject: {}, reportFailure: { failures.append($0) }
        )

        let succeeded = await controller.performReturningOutcome(.delete, messageID: message.rawValue, origin: .mailbox)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(failures, [], "no alert for a message already in Trash")
        XCTAssertEqual(actions.statusMessage, "This message is already in Trash.")
        XCTAssertTrue(fixture.client("b").selectedMailboxes.isEmpty)
        XCTAssertEqual(fixture.message(message)?.isDeleted, false)
    }

    @MainActor
    func testUndoDuringGraceKeepsTheMessageAndCommitMovesItToTrash() async throws {
        let fixture = try Fixture()
        let message = try fixture.add("b", uid: 7)
        try await fixture.addPassword("b")
        let actions = InboxMailActionViewModel(handler: fixture.handler)
        let controller = MessageActionController(
            mailbox: MailboxController(
                destination: .allInboxes, mode: InboxDisplayMode.focusedList.rawValue, selectedMessageID: nil,
                navigation: MailboxWorkspaceNavigationState(initialContext: .mailbox(destination: .allInboxes, mode: .focusedList))
            ),
            refreshBus: MailboxRefreshBus(), commitDelay: .seconds(4),
            perform: { action, id in await actions.perform(action, messageID: id) },
            reproject: {}, reportFailure: { XCTFail("unexpected failure: \($0)") },
            sleep: { try await Task.sleep(for: $0) }
        )

        controller.perform(.delete, messageID: message.rawValue)
        XCTAssertEqual(controller.pendingUndo?.action, .delete)
        controller.undo()
        await controller.waitForStartedActions()

        XCTAssertTrue(fixture.client("b").moved.isEmpty, "an undone Delete never reaches the server")
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "INBOX")

        controller.perform(.delete, messageID: message.rawValue)
        await controller.commitPendingAndWait()

        XCTAssertEqual(fixture.client("b").moved, ["7->Trash"])
        XCTAssertTrue(fixture.client("b").deleted.isEmpty)
        XCTAssertEqual(fixture.message(message)?.mailboxPath, "Trash")
    }
}

private final class Fixture: @unchecked Sendable {
    let store: SQLiteMailStore
    let vault = InMemoryCredentialVault()
    let scheduler = RecordingFlagScheduler()
    private var clients: [String: RecordingIMAPClient] = [:]
    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-direct-actions-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var handler: IOSDirectInboxActionHandler {
        IOSDirectInboxActionHandler(store: store, mailboxFlagScheduler: scheduler, credentials: vault) { host, _ in
            self.client(host)
        }
    }

    func client(_ name: String) -> RecordingIMAPClient {
        if let existing = clients[name] { return existing }
        let result = RecordingIMAPClient()
        clients[name] = result
        return result
    }

    func add(
        _ name: String, uid: Int, mailbox: String = "INBOX", publishDirectSource: Bool = true,
        email: String? = nil, folders: [Mailbox]? = nil
    ) throws -> MessageID {
        let accountID = AccountID(name)
        let account = Account(id: accountID, displayName: name, email: EmailAddress(email ?? "\(name)@example.test"), imapHost: name, imapPort: 993, smtpHost: name, smtpPort: 465)
        let inbox = Mailbox(id: MailboxID("\(name)-inbox"), accountID: accountID, name: "INBOX", path: "INBOX", specialUse: "\\Inbox")
        let source = try AccountMailSource(accountID: accountID, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
        if publishDirectSource {
            try store.cacheAccountSetup(account: account, inbox: inbox, source: source)
        } else {
            try store.cacheAccountSetup(account: account, inbox: inbox)
        }
        // The folder list a sync caches; by default the account has Archive and Trash mailboxes.
        try store.cacheMailboxes(folders ?? [
            inbox, Mailbox(id: MailboxID("\(name)-trash"), accountID: accountID, name: "Trash", path: "Trash", specialUse: "\\Trash"),
            Mailbox(id: MailboxID("\(name)-archive"), accountID: accountID, name: "Archive", path: "Archive", specialUse: "\\Archive"),
        ])
        let id = MessageID("\(name)-message")
        let message = MessageSummary(id: id, threadID: ThreadID("\(name)-thread"), from: EmailAddress("sender@example.test"), subject: name, preview: name, smartCategory: .personal).withMailboxPath(mailbox)
        _ = try store.commitIncomingMessage(message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []), accountID: accountID, mailboxPath: mailbox, uidValidity: 10, uid: uid, notificationEligible: false)
        return id
    }

    /// Another copy of the same message, committed the way sync commits it: the
    /// summary names the mailbox being synced, so it becomes `messages.mailbox_path`.
    func addSyncedCopy(of id: MessageID, account name: String, mailbox: String, uid: Int) throws {
        guard let existing = message(id) else { return }
        _ = try store.commitIncomingMessage(existing.withMailboxPath(mailbox), metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []), accountID: AccountID(name), mailboxPath: mailbox, uidValidity: 10, uid: uid, notificationEligible: false)
    }

    /// Another copy of the same message in another mailbox of the account.
    func addCopy(of id: MessageID, account name: String, mailbox: String, uid: Int) throws {
        guard let existing = message(id) else { return }
        _ = try store.commitIncomingMessage(existing, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []), accountID: AccountID(name), mailboxPath: mailbox, uidValidity: 10, uid: uid, notificationEligible: false)
    }

    func addPassword(_ name: String) async throws {
        try await vault.store(Data("secret".utf8), for: MailCredentialKeys.imapPassword(AccountID(name)))
    }

    func message(_ id: MessageID) -> MessageSummary? { store.messages.first { $0.id == id } }
}

private final class RecordingFlagScheduler: MailboxFlagScheduling, @unchecked Sendable {
    func schedule(_ input: PlainpostMailboxFlagInput) throws {}
    func signalWork() async throws {}
}

private final class RecordingIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    var uidValidity = 10
    var usernames: [String] = []
    var selectedMailboxes: [String] = []
    var deleted: [Int] = []
    var moved: [String] = []
    /// UIDs moved to Archive: archive is a move that reports the new UID.
    var archived: [Int] { moved.compactMap { $0.hasSuffix("->Archive") ? Int($0.prefix { $0.isNumber }) : nil } }
    /// What the server's LIST returns; `listCount` counts the LISTs.
    var listed: [Mailbox] = []
    var listCount = 0
    /// The COPYUID the server reports for a move, if any.
    var copyUID: (uidValidity: Int, uid: Int)?
    var failure: IMAPClientError?
    /// UIDs whose move the server refuses.
    var failingMoveUIDs: Set<Int> = []
    var commandGate: SuspendedProviderCommand?
    func login(username: String, password: String) async throws { usernames.append(username) }
    func listMailboxes() async throws -> [Mailbox] { listCount += 1; return listed }
    func move(uid: Int, to mailbox: String) async throws -> IMAPMoveResult {
        moved.append("\(uid)->\(mailbox)")
        if let commandGate { await commandGate.pause() }
        if let failure { throw failure }
        if failingMoveUIDs.contains(uid) { throw IMAPClientError.protocolError("NO move refused") }
        return IMAPMoveResult(mailbox: mailbox, uidValidity: copyUID?.uidValidity, uid: copyUID?.uid)
    }
    func selectMailbox(_ path: String) async throws -> String { selectedMailboxes.append(path); return "* OK [UIDVALIDITY \(uidValidity)]" }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { "" }
    func fetchBody(uid: Int) async throws -> String { "" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    /// Flag changes as "<uid>+<flag>" / "<uid>-<flag>".
    var flagChanges: [String] = []
    func setFlags(uid: Int, add: [String], remove: [String], expectedModSequence: Int?) async throws {
        flagChanges += add.map { "\(uid)+\($0)" } + remove.map { "\(uid)-\($0)" }
        if let failure { throw failure }
    }
    func archive(uid: Int, archiveMailbox: String) async throws {
        XCTFail("archive must be a move that reports where the copy landed")
    }
    func delete(uid: Int) async throws {
        deleted.append(uid)
        if let commandGate { await commandGate.pause() }
        if let failure { throw failure }
    }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult { .init(mailbox: mailbox, uid: nil) }
}

private actor SuspendedProviderCommand {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { continuation in releaseWaiter = continuation }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in enteredWaiter = continuation }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class SwitchingCredentialVault: CredentialVault, @unchecked Sendable {
    private let mailStore: SQLiteMailStore
    private let accountID: AccountID

    init(store: SQLiteMailStore, accountID: AccountID) {
        self.mailStore = store
        self.accountID = accountID
    }

    func store(_ secret: Data, for key: CredentialRecordKey) async throws {}
    func load(_ key: CredentialRecordKey) async throws -> Data? {
        let source = try mailStore.mailSource(accountID: accountID)
        try mailStore.replaceMailSource(source.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "b@example.test"
        ), expectedGeneration: source.generation)
        return Data("secret".utf8)
    }
    func remove(_ key: CredentialRecordKey) async throws {}
    func loadOrCreate(_ keys: [CredentialRecordKey], create: @escaping @Sendable () throws -> [Data]) async throws -> [Data?] { [] }
}
