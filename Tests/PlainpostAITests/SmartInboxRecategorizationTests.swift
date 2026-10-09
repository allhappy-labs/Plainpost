import Foundation
import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB

final class SmartInboxRecategorizationTests: XCTestCase {
    private static let account = Account(
        id: AccountID("acc_smart_inbox_batch"),
        displayName: "Smart Inbox",
        email: EmailAddress("smart-inbox@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )

    func testSQLiteRecategorizationCommitsOneVisibleStoreChangeForWholeBatch() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-batch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        try store.cacheAccounts([Self.account])
        try store.cacheThread(Self.thread(id: "thr_msg_1"))
        try store.cacheThread(Self.thread(id: "thr_msg_2"))
        try store.cacheMessage(Self.message(id: "msg_1", subject: "Receipt"))
        try store.cacheMessage(Self.message(id: "msg_2", subject: "Newsletter"))

        let notifications = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName,
            object: nil,
            queue: nil
        ) { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let progress = LockedProgress()

        let result = try await SmartInboxRecategorizationService(
            provider: DeterministicAIProvider(),
            store: store
        ).recategorizeMessages { current, total in
            progress.update(current: current, total: total)
        }

        XCTAssertEqual(result.categorizedMessageCount, 2)
        XCTAssertEqual(notifications.value, 1)
        XCTAssertEqual(progress.value.current, 2)
        XCTAssertEqual(progress.value.total, 2)
    }

    private static func message(id: String, subject: String) -> MessageSummary {
        MessageSummary(
            id: MessageID(id),
            threadID: ThreadID("thr_\(id)"),
            from: EmailAddress("sender@example.com"),
            subject: subject,
            preview: "Message preview",
            smartCategory: .unknown
        )
    }

    private static func thread(id: String) -> MailThread {
        MailThread(
            id: ThreadID(id),
            accountID: account.id,
            subjectNormalized: id,
            participantEmails: []
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = (current: 0, total: 0)

    var value: (current: Int, total: Int) { lock.withLock { progress } }
    func update(current: Int, total: Int) { lock.withLock { progress = (current, total) } }
}
