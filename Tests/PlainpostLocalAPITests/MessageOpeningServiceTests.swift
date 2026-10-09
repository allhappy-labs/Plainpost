import XCTest
import GRDB
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostLocalServer
@testable import PlainpostOperations

final class MessageOpeningServiceTests: XCTestCase {
    func testDurableSchedulerEnqueuesIdempotentMailboxFlagJob() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-message-opening-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try cacheFixtureMessage(in: store, isSeen: false)
        let scheduler = DurableMailboxFlagScheduler(store: store)
        let input = PlainpostMailboxFlagInput(
            messageID: MessageID("msg-1"),
            accountID: fixtureAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            desiredSeen: true
        )

        try scheduler.schedule(input)
        try scheduler.schedule(input)

        let job = try XCTUnwrap(store.jobs(limit: 10).only)
        XCTAssertEqual(job.kind, .mailboxFlag)
        XCTAssertEqual(job.priority, 100)
        XCTAssertEqual(job.idempotencyKey, "mailbox-flag:acc-1:INBOX:1:1:msg-1:true")
        XCTAssertEqual(
            try JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: Data(job.payloadJSON.utf8)),
            input
        )
    }

    func testOpeningUnreadMessageMarksLocalStateBeforeSchedulingRemoteFlag() async throws {
        let store = fixtureInMemoryStore(isSeen: false)
        let scheduler = RecordingMailboxFlagScheduler()
        let service = MessageOpeningService(store: store, scheduler: scheduler)

        let opened = try await service.open(MessageID("msg-1"))

        XCTAssertTrue(opened.isSeen)
        XCTAssertTrue(store.messages[0].isSeen)
        XCTAssertEqual(scheduler.inputs, [
            PlainpostMailboxFlagInput(
                messageID: MessageID("msg-1"),
                accountID: fixtureAccount.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                desiredSeen: true
            )
        ])
        XCTAssertEqual(scheduler.signalCount, 1)
    }

    func testDurableSchedulerSeparatesSameMessageIdentityAcrossAccounts() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-message-opening-accounts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let other = Account(
            id: AccountID("acc-2"), displayName: "Other",
            email: EmailAddress("other@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([fixtureAccount, other])
        try store.cacheMessage(fixtureMessage(isSeen: false))
        try store.recordCachedUID(
            accountID: fixtureAccount.id, mailboxPath: "INBOX",
            uidValidity: 1, uid: 1, messageID: MessageID("msg-1")
        )
        try store.recordCachedUID(
            accountID: other.id, mailboxPath: "Archive",
            uidValidity: 2, uid: 2, messageID: MessageID("msg-1")
        )
        let scheduler = DurableMailboxFlagScheduler(store: store)

        try scheduler.schedule(.init(
            messageID: MessageID("msg-1"), accountID: fixtureAccount.id,
            mailboxPath: "INBOX", uidValidity: 1, uid: 1, desiredSeen: true
        ))
        try scheduler.schedule(.init(
            messageID: MessageID("msg-1"), accountID: other.id,
            mailboxPath: "Archive", uidValidity: 2, uid: 2, desiredSeen: true
        ))

        let jobs = try store.jobs(limit: 10)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(
            Set(try jobs.compactMap {
                try JSONDecoder().decode(
                    PlainpostMailboxFlagInput.self, from: Data($0.payloadJSON.utf8)
                ).accountID
            }),
            Set([fixtureAccount.id, other.id])
        )
    }

    func testOpeningAlreadyReadMessageDoesNotScheduleDuplicateFlag() async throws {
        let store = fixtureInMemoryStore(isSeen: true)
        let scheduler = RecordingMailboxFlagScheduler()
        let service = MessageOpeningService(store: store, scheduler: scheduler)

        _ = try await service.open(MessageID("msg-1"))

        XCTAssertTrue(scheduler.inputs.isEmpty)
        XCTAssertEqual(scheduler.signalCount, 0)
    }

    func testSchedulingFailureRestoresUnreadStateSoLaterOpenCanRetry() async throws {
        let store = fixtureInMemoryStore(isSeen: false)
        let failingService = MessageOpeningService(
            store: store,
            scheduler: ThrowingMailboxFlagScheduler()
        )

        do {
            _ = try await failingService.open(MessageID("msg-1"))
            XCTFail("Expected mailbox flag scheduling to fail.")
        } catch TestSchedulerError.failed {
            // Expected.
        }

        XCTAssertFalse(store.messages[0].isSeen)

        let succeedingScheduler = RecordingMailboxFlagScheduler()
        let succeedingService = MessageOpeningService(store: store, scheduler: succeedingScheduler)
        let opened = try await succeedingService.open(MessageID("msg-1"))

        XCTAssertTrue(opened.isSeen)
        XCTAssertTrue(store.messages[0].isSeen)
        XCTAssertEqual(succeedingScheduler.inputs, [
            PlainpostMailboxFlagInput(
                messageID: MessageID("msg-1"),
                accountID: fixtureAccount.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                desiredSeen: true
            )
        ])
    }

    func testWorkerWakeFailureDoesNotUndoDurableLocalOpen() async throws {
        let store = fixtureInMemoryStore(isSeen: false)
        let service = MessageOpeningService(
            store: store,
            scheduler: WakeFailingMailboxFlagScheduler()
        )

        let opened = try await service.open(MessageID("msg-1"))

        XCTAssertTrue(opened.isSeen)
        XCTAssertTrue(store.messages[0].isSeen)
    }

    func testSQLiteOpenAtomicallyPersistsSeenStateAuditAndMailboxFlagJob() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-atomic-message-opening-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try cacheFixtureMessage(in: store, isSeen: false)
        let faultConnection = try DatabaseQueue(path: url.path)
        try await faultConnection.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_mailbox_flag_insert
                BEFORE INSERT ON durable_jobs
                WHEN NEW.kind = 'mailbox-flag'
                BEGIN
                    SELECT RAISE(FAIL, 'forced mailbox flag insert failure');
                END;
                """)
        }
        let service = MessageOpeningService(
            store: store,
            scheduler: DurableMailboxFlagScheduler(store: store)
        )

        do {
            _ = try await service.open(MessageID("msg-1"))
            XCTFail("Expected the forced durable job insert failure.")
        } catch {
            // Expected.
        }

        let afterFailure = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(try XCTUnwrap(afterFailure.messageSummary(id: MessageID("msg-1"))).isSeen)
        XCTAssertTrue(try afterFailure.jobs(limit: 10).isEmpty)
        XCTAssertTrue(afterFailure.auditEntries.filter { $0.targetID == "msg-1" }.isEmpty)

        try await faultConnection.write { database in
            try database.execute(sql: "DROP TRIGGER fail_mailbox_flag_insert")
        }

        let opened = try await service.open(MessageID("msg-1"))

        XCTAssertTrue(opened.isSeen)
        let afterSuccess = try SQLiteMailStore(path: url.path)
        XCTAssertTrue(try XCTUnwrap(afterSuccess.messageSummary(id: MessageID("msg-1"))).isSeen)
        let job = try XCTUnwrap(afterSuccess.jobs(limit: 10).only)
        XCTAssertEqual(job.kind, .mailboxFlag)
        XCTAssertEqual(job.idempotencyKey, "mailbox-flag:acc-1:INBOX:1:1:msg-1:true")
        XCTAssertEqual(
            afterSuccess.auditEntries.filter { $0.targetID == "msg-1" }.map(\.action),
            ["message.mark_seen"]
        )

        _ = try await service.open(MessageID("msg-1"))

        let afterRepeatedOpen = try SQLiteMailStore(path: url.path)
        XCTAssertEqual(try afterRepeatedOpen.jobs(limit: 10).count, 1)
        XCTAssertEqual(
            afterRepeatedOpen.auditEntries.filter { $0.targetID == "msg-1" }.map(\.action),
            ["message.mark_seen"]
        )
    }

    private func fixtureMessage(isSeen: Bool) -> MessageSummary {
        MessageSummary(
            id: MessageID("msg-1"),
            threadID: ThreadID("thr-1"),
            from: EmailAddress("alice@example.com"),
            subject: "Hello",
            preview: "Opening semantics",
            smartCategory: .personal,
            isSeen: isSeen
        )
    }

    private var fixtureAccount: Account {
        Account(
            id: AccountID("acc-1"),
            displayName: "Fixture",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
    }

    private var fixtureThread: MailThread {
        MailThread(
            id: ThreadID("thr-1"),
            accountID: fixtureAccount.id,
            subjectNormalized: "hello",
            participantEmails: [EmailAddress("alice@example.com"), fixtureAccount.email]
        )
    }

    private func fixtureInMemoryStore(isSeen: Bool) -> InMemoryMailStore {
        InMemoryMailStore(
            accounts: [fixtureAccount],
            messages: [fixtureMessage(isSeen: isSeen)],
            memberships: [MailboxMessageMembership(
                accountID: fixtureAccount.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                messageID: MessageID("msg-1")
            )],
            threads: [fixtureThread]
        )
    }

    private func cacheFixtureMessage(in store: SQLiteMailStore, isSeen: Bool) throws {
        try store.cacheAccounts([fixtureAccount])
        try store.cacheThread(fixtureThread)
        _ = try store.commitIncomingMessage(
            fixtureMessage(isSeen: isSeen),
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: fixtureAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private final class RecordingMailboxFlagScheduler: MailboxFlagScheduling, @unchecked Sendable {
    private(set) var inputs: [PlainpostMailboxFlagInput] = []
    private(set) var signalCount = 0

    func schedule(_ input: PlainpostMailboxFlagInput) throws {
        inputs.append(input)
    }

    func signalWork() async throws {
        signalCount += 1
    }
}

private enum TestSchedulerError: Error {
    case failed
}

private struct ThrowingMailboxFlagScheduler: MailboxFlagScheduling {
    func schedule(_ input: PlainpostMailboxFlagInput) throws {
        throw TestSchedulerError.failed
    }

    func signalWork() async throws {}
}

private struct WakeFailingMailboxFlagScheduler: MailboxFlagScheduling {
    func schedule(_ input: PlainpostMailboxFlagInput) throws {}

    func signalWork() async throws {
        throw TestSchedulerError.failed
    }
}
