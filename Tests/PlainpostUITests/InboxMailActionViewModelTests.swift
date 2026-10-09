import PlainpostRuntimeTestSupport
import PlainpostTestSupport
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostLocalServer
@testable import PlainpostOperations
import PlainpostTestSupport
@testable import PlainpostUI

final class InboxMailActionViewModelTests: XCTestCase {
    @MainActor func testNodeAuthorityActionHandlerUsesMutationCapability() async {
        let mutations = RecordingInboxMutationCapability()
        let viewModel = InboxMailActionViewModel(handler: NodeAuthorityInboxMailActionHandler(mutations: mutations))

        let outcome = await viewModel.perform(.markRead, messageID: "node-message-1")

        XCTAssertEqual(outcome, .succeeded(InboxMailActionResult(messageID: MessageID("node-message-1"), action: .markRead, seen: true)))
        let intents = await mutations.intents
        XCTAssertEqual(intents, [.setRead(messageIDs: [MessageID("node-message-1")], read: true)])
    }

    @MainActor func testNodeAuthorityRefusesDeletePermanentlyWithoutTouchingTheNode() async {
        let mutations = RecordingInboxMutationCapability()
        let viewModel = InboxMailActionViewModel(handler: NodeAuthorityInboxMailActionHandler(mutations: mutations))

        let outcome = await viewModel.perform(.deletePermanently, messageID: "node-message-1")

        XCTAssertEqual(outcome, .failed(message: "Delete Permanently isn't available while the Sync Node handles this account."))
        let intents = await mutations.intents
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor func testNodeAuthorityActionHandlerFailsClosedWithoutLegacyProviderFallback() async {
        let viewModel = InboxMailActionViewModel(handler: NodeAuthorityInboxMailActionHandler())

        let outcome = await viewModel.perform(.archive, messageID: "node-message-1")

        XCTAssertEqual(
            outcome,
            .failed(message: "Node mail mutations require an authenticated Node operation."))
    }

    @MainActor func testServiceAdapterRoutesUnreadWithoutChangingViewModelResult() async {
        let client = RuntimeServiceClientFake()
        let viewModel = InboxMailActionViewModel(
            handler: PlainpostServiceInboxMailActionAdapter(serviceClient: client))

        let outcome = await viewModel.perform(.markUnread, messageID: "message-1")

        XCTAssertEqual(
            outcome,
            .succeeded(
                InboxMailActionResult(
                    messageID: MessageID("message-1"), action: .markUnread, seen: false)))
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.foregroundOperationKinds, [.markUnread])
    }

    @MainActor func testActionFailureReturnsRollbackOutcomeInsteadOfOnlySwallowingTheError() async {
        let viewModel = InboxMailActionViewModel(handler: FailingInboxMailActionHandler())

        let outcome = await viewModel.perform(.delete, messageID: "msg_1")

        XCTAssertEqual(outcome, .failed(message: "Mail action failed"))
        XCTAssertFalse(viewModel.isPending(messageID: "msg_1"))
    }

    func testMessageRowsExposeContextualMailboxActions() {
        let unreadRow = MessageRowModel(message: message(id: "msg_unread", isSeen: false))
        let readRow = MessageRowModel(message: message(id: "msg_read", isSeen: true))

        XCTAssertEqual(unreadRow.actions.map(\.id), ["mark_read", "archive", "delete"])
        XCTAssertEqual(unreadRow.actions.map(\.systemImage), ["envelope.open", "archivebox", "trash"])
        XCTAssertEqual(readRow.actions.map(\.id), ["mark_unread", "archive", "delete"])
        XCTAssertEqual(readRow.actions.map(\.systemImage), ["envelope.badge", "archivebox", "trash"])
    }

    @MainActor
    func testHumanOpenMarksUnreadLocallyAndDoesNotDuplicateRemoteFlagJob() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("human-open-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        _ = try store.commitIncomingMessage(
            message(id: "msg_unread", isSeen: false),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let opening = MessageOpeningService(
            store: store,
            scheduler: DurableMailboxFlagScheduler(store: store)
        )
        let coordinator = HumanMessageOpenCoordinator { messageID in
            _ = try await opening.open(messageID)
        }

        try await coordinator.openIfPresent("msg_unread")
        try await coordinator.openIfPresent("msg_unread")

        XCTAssertEqual(store.messages.first?.isSeen, true)
        XCTAssertEqual(
            try store.jobs(limit: 10).filter { $0.kind == .mailboxFlag }.count,
            1
        )
    }

    @MainActor
    func testInboxActionViewModelMarksReadAndArchivesThroughLocalIMAPHarness() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "ui-action-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await client.login(username: "me@example.com", password: "ui-action-imap-secret")
        _ = try await client.selectMailbox("INBOX")

        let store = InMemoryMailStore(messages: [message(id: "msg_uid_1", isSeen: false)])
        let viewModel = InboxMailActionViewModel(
            handler: InboxMailActionService(store: store, imapClient: client)
        )

        _ = await viewModel.perform(.markRead, messageID: "msg_uid_1")

        let readHeader = try await client.fetchHeader(uid: 1)
        XCTAssertTrue(readHeader.contains("\\Seen"))
        XCTAssertEqual(store.messages.first?.isSeen, true)
        XCTAssertEqual(viewModel.lastResult?.action, .markRead)
        XCTAssertEqual(viewModel.statusMessage, "Marked read")

        _ = await viewModel.perform(.archive, messageID: "msg_uid_1")

        XCTAssertEqual(imap.archivedUIDs, [1])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)
        XCTAssertEqual(store.messages.first?.mailboxPath, "Archive")
        XCTAssertEqual(store.messages.first?.isDeleted, false)
        XCTAssertEqual(viewModel.lastResult?.action, .archive)
        XCTAssertEqual(viewModel.statusMessage, "Archived")
    }

    @MainActor
    func testInboxActionViewModelDeletesThroughLocalIMAPHarness() async throws {
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "ui-delete-imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await imap.start()
        defer { imap.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        try await client.login(username: "me@example.com", password: "ui-delete-imap-secret")
        _ = try await client.selectMailbox("INBOX")

        let store = InMemoryMailStore(messages: [message(id: "msg_uid_1", isSeen: false)])
        let viewModel = InboxMailActionViewModel(
            handler: InboxMailActionService(store: store, imapClient: client)
        )

        _ = await viewModel.perform(.delete, messageID: "msg_uid_1")

        // Delete moves to Trash (copy, then expunge that UID from the Inbox).
        XCTAssertEqual(imap.copyAttempts, [LocalIMAPCopyAttempt(uid: 1, mailbox: "Trash")])
        XCTAssertEqual(imap.deletedUIDs, [1])
        XCTAssertEqual(imap.expungeCount, 1)
        XCTAssertEqual(store.messages.first?.mailboxPath, "Trash")
        XCTAssertEqual(store.messages.first?.isDeleted, false)
        XCTAssertEqual(viewModel.lastResult?.deleteOutcome, .movedToTrash)
        XCTAssertEqual(viewModel.statusMessage, "Deleted")
    }

    @MainActor
    func testAlreadyInTrashIsReportedAsANonErrorOutcome() async {
        struct AlreadyInTrash: InboxMailActionHandling {
            func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
                InboxMailActionResult(messageID: messageID, action: action, mailboxPath: "Trash", deleteOutcome: .alreadyInTrash)
            }
        }
        let viewModel = InboxMailActionViewModel(handler: AlreadyInTrash())

        let outcome = await viewModel.perform(.delete, messageID: "m1")

        guard case .succeeded(let result) = outcome else { return XCTFail("already in Trash is not a failure") }
        XCTAssertEqual(result.deleteOutcome, .alreadyInTrash)
        XCTAssertEqual(viewModel.statusMessage, "This message is already in Trash.")
    }

    private func message(id: String, isSeen: Bool) -> MessageSummary {
        MessageSummary(
            id: MessageID(id),
            threadID: ThreadID("thr_\(id)"),
            from: EmailAddress("alice@example.com"),
            subject: "Availability",
            preview: "Can you meet next Tuesday?",
            smartCategory: .personal,
            isSeen: isSeen
        )
    }
}

private actor RecordingInboxMutationCapability: MailMutationServing {
    var intents: [MailMutationIntent] = []

    func apply(canonicalOperation: Data) async throws -> MailMutationResult {
        MailMutationResult(idempotencyKey: "unused", state: "applied")
    }

    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        intents.append(intent)
        return MailMutationResult(idempotencyKey: "action-1", state: "applied")
    }
}

private struct FailingInboxMailActionHandler: InboxMailActionHandling {
    func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        throw Failure()
    }

    private struct Failure: Error {}
}
