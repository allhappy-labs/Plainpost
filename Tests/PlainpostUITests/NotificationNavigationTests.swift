import XCTest
import PlainpostAccountProtocol
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI

@MainActor
final class NotificationNavigationTests: XCTestCase {
    func testNotificationResolutionReadsNoBodies() async throws {
        let runtime = try makeRuntime()
        try runtime.store.cacheAccounts([Self.account])
        try runtime.store.cacheMessageReliably(Self.message)
        let trace = ProjectionSQLTrace()
        try trace.install(on: runtime.store)

        let destination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(for: Self.message.id.rawValue)
        )

        XCTAssertEqual(destination, .message(Self.message.id.rawValue))
        XCTAssertEqual(trace.bodyReads, 0)
        XCTAssertEqual(trace.mainThreadReads, 0, "the caller must suspend instead of waiting synchronously for SQLite")
        XCTAssertGreaterThan(trace.messageReads, 0)
        await runtime.shutdown()
    }

    func testUnknownNotificationTokenUsesBoundedMemory() async throws {
        for count in [10_000, 100_000] {
            let runtime = try makeRuntime()
            try runtime.store.cacheAccounts([Self.account])
            try await runtime.store.databasePool.write { database in
                try database.execute(sql: """
                    WITH RECURSIVE fixture(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM fixture WHERE n < ?)
                    INSERT INTO messages(id, from_email, subject, preview, body_text, smart_category)
                    SELECT printf('synthetic-%06d', n), 'sender@example.test', 'Synthetic', '',
                           'Synthetic body must never be read', 'personal' FROM fixture
                    """, arguments: [count])
            }
            let trace = ProjectionSQLTrace()
            try trace.install(on: runtime.store)
            let destination = await runtime.resolveNotificationOpen("unknown-synthetic-token")
            XCTAssertEqual(destination, .allInboxes)
            XCTAssertEqual(trace.bodyReads, 0)
            XCTAssertEqual(trace.mainThreadReads, 0)
            XCTAssertEqual(trace.messageReads, (count + 255) / 256)
            XCTAssertEqual(trace.unboundedMessageReads, 0)
            print("TASK5_TRACE fixture=\(count) identity_batches=\(trace.messageReads) body_reads=\(trace.bodyReads) main_thread_sql=\(trace.mainThreadReads) unbounded_queries=\(trace.unboundedMessageReads)")

            let heartbeat = expectation(description: "MainActor runs while the waiting-intent SQL is held")
            let inboxTrace = ProjectionSQLTrace(trigger: "from mail_intent_journal") {
                let released = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    heartbeat.fulfill()
                    released.signal()
                }
                XCTAssertEqual(released.wait(timeout: .now() + 5), .success,
                               "the waiting-intent read must not synchronously hold MainActor")
            }
            try inboxTrace.install(on: runtime.store)
            let inbox = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
            await fulfillment(of: [heartbeat], timeout: 1)
            XCTAssertEqual(inbox.totalRowCount, count)
            XCTAssertFalse(inbox.classicRows.isEmpty)
            XCTAssertLessThanOrEqual(inbox.classicRows.count, 200)
            XCTAssertEqual(inboxTrace.bodyReads, 0)
            XCTAssertEqual(inboxTrace.mainThreadReads, 0)
            XCTAssertEqual(inboxTrace.waitingReads, 1)
            print("TASK5_INBOX_TRACE fixture=\(count) projected_rows=\(inbox.classicRows.count) waiting_queries=\(inboxTrace.waitingReads) body_reads=\(inboxTrace.bodyReads) main_thread_sql=\(inboxTrace.mainThreadReads) main_actor_heartbeat=1")
            await runtime.shutdown()
        }
    }

    func testNotificationReadFailureFailsClosedEvenForKnownAccountToken() async throws {
        let runtime = try makeRuntime()
        try runtime.store.cacheAccounts([Self.account])
        try await runtime.store.databasePool.write { try $0.execute(sql: "DROP TABLE messages") }
        let destination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.accountInboxToken(for: Self.account.id.rawValue)
        )
        XCTAssertEqual(destination, .allInboxes)
        await runtime.shutdown()
    }

    func testRemovedSelectedAccountCannotResolveAnOrphanMessage() async throws {
        let configuration = configuration()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(databaseURL: configuration.databaseURL, selectedAccountID: Self.account.id),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        try runtime.store.cacheAccounts([Self.account])
        try runtime.store.cacheMessageReliably(Self.message)
        let accountID = Self.account.id.rawValue
        try await runtime.store.databasePool.write { database in
            try database.execute(sql: "UPDATE messages SET account_id = ?", arguments: [accountID])
            try database.execute(sql: "DELETE FROM accounts")
        }
        let destination = await runtime.resolveNotificationOpen(NotificationOpaqueIdentities.messageToken(
            for: Self.message.id.rawValue, accountID: Self.account.id.rawValue, sourceKind: "direct", sourceGeneration: 0
        ))
        XCTAssertEqual(destination, .allInboxes)
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: configuration.databaseURL.deletingLastPathComponent())
    }

    func testKnownOpaqueTokenResolvesToLocalMessage() {
        XCTAssertEqual(
            PlainpostNotificationOpenDestination.resolve(
                token: "opaque-sha256-token",
                deepLinkMapping: ["opaque-sha256-token": "message-42"]
            ),
            .message("message-42")
        )
    }

    func testUnknownOrUnsafeTokenFallsBackToAllInboxes() {
        XCTAssertEqual(
            PlainpostNotificationOpenDestination.resolve(
                token: "not-local",
                deepLinkMapping: [:]
            ),
            .allInboxes
        )
        XCTAssertEqual(
            PlainpostNotificationOpenDestination.resolve(
                token: "message\n-token",
                deepLinkMapping: ["message\n-token": "message-42"]
            ),
            .allInboxes
        )
    }

    func testMessageIdentityIsOpaqueAndNotTheMessageIdentifier() {
        let token = NotificationOpaqueIdentities.messageToken(for: "message-42")
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotEqual(token, "message-42")
        XCTAssertEqual(token, NotificationOpaqueIdentities.messageToken(for: "message-42"))
    }

    func testKnownAccountInboxTokenResolvesToAccountInbox() {
        XCTAssertEqual(
            PlainpostNotificationOpenDestination.resolve(
                token: "opaque-account-token",
                messageMapping: [:],
                accountInboxMapping: ["opaque-account-token": "account-7"]
            ),
            .accountInbox("account-7")
        )
    }

    func testAccountInboxScopeFiltersRowsAndExposesTheSelectedAccount() {
        let base = InboxViewModel.preview()
        let selectedID = try! XCTUnwrap(base.classicRows.first?.id)
        let scope = PlainpostNotificationInboxScope(
            accountID: "account-7",
            messageIDs: [selectedID],
            accountIdentity: MailboxAccountIdentity(
                displayName: "Work",
                email: "work@example.com"
            )
        )

        let scoped = scope.apply(to: base)

        XCTAssertEqual(scoped.classicRows.map(\.id), [selectedID])
        XCTAssertEqual(scoped.totalRowCount, 1)
        XCTAssertEqual(scoped.accountIdentity?.email, "work@example.com")
    }

    func testRuntimeResolvesLocalMessageAndAccountInboxTokens() async throws {
        let runtime = try makeRuntime()
        let account = Self.account
        try runtime.store.cacheAccounts([account])
        _ = try runtime.store.commitIncomingMessage(
            Self.message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )

        let messageDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.messageToken(for: Self.message.id.rawValue)
        )
        let accountDestination = await runtime.resolveNotificationOpen(
            NotificationOpaqueIdentities.accountInboxToken(for: account.id.rawValue)
        )

        XCTAssertEqual(messageDestination, .message(Self.message.id.rawValue))
        XCTAssertEqual(accountDestination, .accountInbox(account.id.rawValue))
        await runtime.shutdown()
    }

    func testForegroundPresentationIsQuietOnlyForRelevantVisibleMail() {
        let messageToken = "message-token"
        let accountToken = "account-token"
        let context = PlainpostNotificationAttentionContext(
            visibleMessageToken: messageToken,
            visibleAccountInboxTokens: [accountToken]
        )

        for token in [messageToken, accountToken] {
            XCTAssertEqual(
                PlainpostNotificationPresentationPolicy.resolve(
                    isApplicationActive: true,
                    openToken: token,
                    contexts: [context],
                    playsSound: true
                ),
                .init(showsBanner: false, addsToList: true, playsSound: false, updatesBadge: false)
            )
        }

        for isActive in [true, false] {
            XCTAssertEqual(
                PlainpostNotificationPresentationPolicy.resolve(
                    isApplicationActive: isActive,
                    openToken: "unrelated",
                    contexts: [context],
                    playsSound: true
                ),
                .init(showsBanner: true, addsToList: true, playsSound: true, updatesBadge: false)
            )
        }
    }

    func testLaunchTimeTapWaitsForRuntimeThenPublishesDestination() async throws {
        let runtime = try makeRuntime()
        try runtime.store.cacheAccounts([Self.account])
        let token = NotificationOpaqueIdentities.accountInboxToken(
            for: Self.account.id.rawValue
        )
        let model = PlainpostApplicationModel(
            makeRuntime: { runtime },
            monitor: { _ in },
            initializeImmediately: false
        )

        model.requestNotificationOpen(token: token)
        XCTAssertNil(model.notificationOpenRequest)
        model.start()

        for _ in 0..<100 where model.notificationOpenRequest == nil {
            await Task.yield()
        }
        XCTAssertEqual(
            model.notificationOpenRequest?.destination,
            .accountInbox(Self.account.id.rawValue)
        )
        await model.shutdown()
    }

    func testRuntimeStartsAndJoinsDeliveryOnlyForReadWriteAccess() async throws {
        let delivery = RecordingMacNewMailDelivery()
        let runtime = try PlainpostAppRuntime(
            configuration: configuration(),
            notificationScheduler: NoopLocalNotificationScheduler(),
            macNewMailDeliveryFactory: { _ in delivery }
        )

        await runtime.startNewMailAlerts()
        await runtime.shutdown()

        var calls = await delivery.calls()
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 1)

        let readOnlyDelivery = RecordingMacNewMailDelivery()
        let readOnly = try PlainpostAppRuntime(
            configuration: runtime.configuration,
            notificationScheduler: NoopLocalNotificationScheduler(),
            accountAccess: .cachedReadOnly,
            macNewMailDeliveryFactory: { _ in readOnlyDelivery }
        )
        await readOnly.startNewMailAlerts()
        await readOnly.shutdown()
        calls = await readOnlyDelivery.calls()
        XCTAssertEqual(calls.starts, 0)
        XCTAssertEqual(calls.stops, 0)
    }

    private func makeRuntime() throws -> PlainpostAppRuntime {
        try PlainpostAppRuntime(
            configuration: configuration(),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
    }

    private func configuration() -> PlainpostAppRuntimeConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-nav-\(UUID().uuidString.prefix(8))", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PlainpostAppRuntimeConfiguration(
            databaseURL: directory.appendingPathComponent("Plainpost.sqlite")
        )
    }

    private static let account = Account(
        id: AccountID("acc-notification-navigation"),
        displayName: "Navigation",
        email: EmailAddress("me@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )

    private static let message = MessageSummary(
        id: MessageID("msg-notification-navigation"),
        threadID: nil,
        from: EmailAddress("sender@example.com"),
        subject: "Notification",
        preview: "Open me",
        smartCategory: .personal
    )
}

private actor RecordingMacNewMailDelivery: MacNewMailDelivering {
    private var startCount = 0
    private var stopCount = 0

    func start() async { startCount += 1 }
    func stop() async { stopCount += 1 }
    func deliverPending(maxWait: Duration) async {}

    func calls() -> (starts: Int, stops: Int) {
        (startCount, stopCount)
    }
}

/// Counts only; neither message contents nor SQL arguments leave the fixture.
final class ProjectionSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies = 0
    private var mainReads = 0
    private var messages = 0
    private var unbounded = 0
    private var waiting = 0
    private var action: (@Sendable () -> Void)?
    private let trigger: String?

    init(trigger: String? = nil, action: (@Sendable () -> Void)? = nil) {
        self.trigger = trigger
        self.action = action
    }

    var bodyReads: Int { lock.withLock { bodies } }
    var mainThreadReads: Int { lock.withLock { mainReads } }
    var messageReads: Int { lock.withLock { messages } }
    var unboundedMessageReads: Int { lock.withLock { unbounded } }
    var waitingReads: Int { lock.withLock { waiting } }

    func install(on store: SQLiteMailStore) throws {
        try store.databasePool.read { database in
            database.trace { [self] event in record(String(describing: event)) }
        }
    }

    private func record(_ sql: String) {
        let sql = sql.lowercased()
        guard sql.contains("select") else { return }
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            if sql.contains("body_text") || sql.contains("body_html") { bodies += 1 }
            if Thread.isMainThread { mainReads += 1 }
            if sql.contains("from mail_intent_journal") { waiting += 1 }
            if sql.contains("from messages") {
                messages += 1
                if !sql.contains("limit") { unbounded += 1 }
            }
            if let trigger, sql.contains(trigger) {
                defer { action = nil }
                return action
            }
            return nil
        }
        callback?()
    }
}
