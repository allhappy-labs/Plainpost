import Foundation
import XCTest
import PlainpostAccountProtocol
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostIOSRuntime
import PlainpostSecrets
import PlainpostTestSupport
@testable import PlainpostUI

/// The iPhone's background refresh: one incremental Inbox pass for every Direct account,
/// then its new-mail alerts, with only the IMAP server and the system notification
/// center replaced.
final class IOSBackgroundMailRefreshTests: XCTestCase {
    @MainActor func testBackgroundRefreshAlertsForMailThatArrivedSinceTheLastSync() async throws {
        let fixture = try await BackgroundRefreshFixture()
        defer { fixture.remove() }
        let runtime = try fixture.runtime()
        _ = await runtime.syncAllDirectMailNow()
        let baseline = await fixture.center.addedNotifications
        XCTAssertEqual(baseline, [], "The first import is silent")

        fixture.provider.arrive(uid: 2, at: Date().addingTimeInterval(-60))
        let synced = await runtime.refreshDirectMailInBackground()
        await runtime.shutdown()

        XCTAssertTrue(synced)
        let added = await fixture.center.addedNotifications
        let notification = try XCTUnwrap(added.only)
        XCTAssertEqual(notification.categoryIdentifier, "new_mail")
        let messageID = try XCTUnwrap(fixture.store.messageIDs(accountID: fixture.account.id, uid: 2))
        XCTAssertEqual(
            notification.userInfo["plainpost.openToken"],
            NotificationOpaqueIdentities.messageToken(for: messageID.rawValue)
        )
    }

    @MainActor func testBackgroundRefreshWithNothingNewAddsNoAlert() async throws {
        let fixture = try await BackgroundRefreshFixture()
        defer { fixture.remove() }
        let runtime = try fixture.runtime()
        _ = await runtime.syncAllDirectMailNow()

        let synced = await runtime.refreshDirectMailInBackground()
        await runtime.shutdown()

        XCTAssertTrue(synced)
        let added = await fixture.center.addedNotifications
        XCTAssertEqual(added, [])
    }
}

@MainActor
private final class BackgroundRefreshFixture {
    let url: URL
    let store: SQLiteMailStore
    let vault = InMemoryCredentialVault()
    let account: Account
    let provider: ArrivingInboxIMAPClient
    let center = RecordingNotificationCenter()

    init() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-background-refresh-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        account = Account(
            id: AccountID("acc_background_example_test"), displayName: "Reader",
            email: EmailAddress("reader@example.test"),
            imapHost: "127.0.0.1", imapPort: 993,
            smtpHost: "127.0.0.1", smtpPort: 465
        )
        let inbox = Mailbox(
            id: MailboxID("mbx_\(account.id.rawValue)_inbox"), accountID: account.id,
            name: "INBOX", path: "INBOX", specialUse: "\\Inbox"
        )
        let direct = try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: account, inbox: inbox, source: direct)
        try await vault.store(Data("incoming".utf8), for: MailCredentialKeys.imapPassword(account.id))
        provider = ArrivingInboxIMAPClient(accountID: account.id, uids: [1])
    }

    func runtime() throws -> PlainpostAppRuntime {
        let provider = provider
        let center = center
        return try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: url, selectedAccountID: nil,
                runtimeDependencies: IOSLocalMailRuntimeDependencies(
                    credentials: vault, imapClientFactory: { _, _ in provider }
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler(),
            macNewMailDeliveryFactory: { store in
                MacNewMailDelivery(
                    store: store, center: center,
                    newMailEnabled: { true }, previewEnabled: { true }, soundsEnabled: { false }
                )
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: store.auditLogURL)
    }
}

private extension SQLiteMailStore {
    func messageIDs(accountID: AccountID, uid: Int) throws -> MessageID? {
        try databasePool.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT message_id FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = 'INBOX' AND uid = ?
                    """,
                arguments: [accountID.rawValue, uid]
            )
        }.map { MessageID($0) }
    }
}

/// An Inbox whose mail can arrive between passes.
private final class ArrivingInboxIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let accountID: AccountID
    private let lock = NSLock()
    private var uids: [Int]
    private var arrivals: [Int: Date] = [:]

    init(accountID: AccountID, uids: [Int]) {
        self.accountID = accountID
        self.uids = uids
    }

    func arrive(uid: Int, at date: Date) {
        lock.withLock {
            uids.append(uid)
            arrivals[uid] = date
        }
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(
            id: MailboxID("mbx_\(accountID.rawValue)_inbox"), accountID: accountID,
            name: "INBOX", path: "INBOX", specialUse: "\\Inbox"
        )]
    }

    func selectMailbox(_ path: String) async throws -> String {
        let count = lock.withLock { uids.count }
        return "* \(count) EXISTS\n* OK [UIDVALIDITY 7] UIDs valid"
    }

    func allMessageUIDs() async throws -> [Int] { lock.withLock { uids } }

    func messageUIDs(after uid: Int?) async throws -> [Int] {
        lock.withLock { uids.filter { $0 > (uid ?? 0) } }
    }

    func fetchHeader(uid: Int) async throws -> String {
        "From: alice@example.com\r\nSubject: Arrival \(uid)\r\nDate: Tue, 6 Oct 2026 10:00:00 +0000\r\n\r\n"
    }

    func fetchBody(uid: Int) async throws -> String { "Body \(uid)" }

    func fetchInternalDate(uid: Int) async throws -> Date? { lock.withLock { arrivals[uid] } }

    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private actor RecordingNotificationCenter: SystemNotificationCenterAdapting {
    private(set) var addedNotifications: [PlainpostNotification] = []

    func authorizationStatus() async -> LocalNotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> LocalNotificationAuthorization { .authorized }
    func add(_ notification: PlainpostNotification) async throws { addedNotifications.append(notification) }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
