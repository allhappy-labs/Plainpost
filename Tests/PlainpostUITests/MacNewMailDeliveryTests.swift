import XCTest
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB
@testable import PlainpostUI

final class MacNewMailDeliveryTests: XCTestCase {
    func testSchedulerChecksAuthorizationAndAddsWithoutRequestingPermission() async throws {
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let scheduler = UserNotificationsLocalScheduler(adapter: center)
        let notification = PlainpostNotification(
            id: "notification-1",
            title: "Title",
            body: "Body",
            categoryIdentifier: "test",
            userInfo: ["plainpost.openToken": "opaque"],
            playsSound: true
        )

        try await scheduler.schedule(notification)

        let authorizationRequestCount = await center.authorizationRequestCount
        let addedNotifications = await center.addedNotifications
        XCTAssertEqual(authorizationRequestCount, 0)
        XCTAssertEqual(addedNotifications, [notification])
    }

    func testIndividualDeliveryUsesOpaqueMessageTokenAndSubmitsOnce() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = fixture.delivery(center: center)

        await delivery.drainNowForTesting()

        let addedNotifications = await center.addedNotifications
        let authorizationRequestCount = await center.authorizationRequestCount
        let notification = try XCTUnwrap(addedNotifications.only)
        XCTAssertEqual(notification.id, fixture.deliveryID)
        XCTAssertEqual(notification.categoryIdentifier, "new_mail")
        XCTAssertEqual(notification.title, "Example Sender")
        XCTAssertEqual(notification.userInfo.keys.sorted(), ["plainpost.openToken"])
        XCTAssertEqual(
            notification.userInfo["plainpost.openToken"],
            NotificationOpaqueIdentities.messageToken(
                for: fixture.messageIDs[0].rawValue
            )
        )
        XCTAssertFalse(notification.userInfo.values.contains(fixture.messageIDs[0].rawValue))
        XCTAssertEqual(try fixture.deliveryRecord().state, .submitted)
        XCTAssertEqual(try fixture.deliveryRecord().attemptCount, 1)
        XCTAssertEqual(authorizationRequestCount, 0)
    }

    func testMessageAlreadyReadIsSuppressedWithoutAdding() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        _ = try fixture.store.markSeen(fixture.messageIDs[0], seen: true, actor: Actor(
            id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser
        ))
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = fixture.delivery(center: center)

        await delivery.drainNowForTesting()

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 0)
        XCTAssertEqual(try fixture.deliveryRecord().state, .suppressed)
    }

    func testMessageAPushAlreadyAlertedIsSuppressedWithoutAdding() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let token = NotificationOpaqueIdentities.messageToken(for: fixture.messageIDs[0].rawValue)
        let center = RecordingSystemNotificationCenter(status: .authorized, delivered: [token])
        let delivery = fixture.delivery(center: center)

        await delivery.drainNowForTesting()

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 0)
        XCTAssertEqual(try fixture.deliveryRecord().state, .suppressed)
    }

    func testSummaryWhosePushesAllAlertedIsSuppressedButNotWhenOneIsMissing() async throws {
        for missing in [false, true] {
            let fixture = try MacDeliveryFixture(messageCount: 6)
            let tokens = fixture.messageIDs.dropFirst(missing ? 1 : 0).map {
                NotificationOpaqueIdentities.messageToken(for: $0.rawValue)
            }
            let center = RecordingSystemNotificationCenter(status: .authorized, delivered: Set(tokens))
            let delivery = fixture.delivery(center: center)

            await delivery.drainNowForTesting()

            let addAttemptCount = await center.addAttemptCount
            XCTAssertEqual(addAttemptCount, missing ? 1 : 0)
            XCTAssertEqual(try fixture.deliveryRecord().state, missing ? .submitted : .suppressed)
        }
    }

    func testDeniedAndNotDeterminedAuthorizationSuppressWithoutAddingOrPrompting() async throws {
        for status in [LocalNotificationAuthorization.denied, .notDetermined] {
            let fixture = try MacDeliveryFixture(messageCount: 1)
            let center = RecordingSystemNotificationCenter(status: status)
            let delivery = fixture.delivery(center: center)

            await delivery.drainNowForTesting()

            let addedNotifications = await center.addedNotifications
            let authorizationRequestCount = await center.authorizationRequestCount
            XCTAssertEqual(addedNotifications, [])
            XCTAssertEqual(authorizationRequestCount, 0)
            XCTAssertEqual(try fixture.deliveryRecord().state, .suppressed)
        }
    }

    func testDisabledPreferenceSuppressesWithoutConsultingSystemAuthorization() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = MacNewMailDelivery(
            store: fixture.store,
            center: center,
            newMailEnabled: { false },
            previewEnabled: { true },
            soundsEnabled: { true },
            dateProvider: { fixture.drainAt }
        )

        await delivery.drainNowForTesting()

        let authorizationStatusCheckCount = await center.authorizationStatusCheckCount
        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(authorizationStatusCheckCount, 0)
        XCTAssertEqual(addAttemptCount, 0)
        XCTAssertEqual(try fixture.deliveryRecord().state, .suppressed)
    }

    func testTransientAddFailureRetriesThenSubmits() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let clock = TestNotificationClock(fixture.drainAt)
        let center = RecordingSystemNotificationCenter(
            status: .authorized,
            addResults: [.failure(SystemNotificationCenterFailure.transient), .success(())]
        )
        let delivery = fixture.delivery(center: center, now: { clock.now })

        await delivery.drainNowForTesting()
        XCTAssertEqual(try fixture.deliveryRecord().state, .retryWait)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.store.nextMacNewMailDeliveryWakeDate(now: fixture.drainAt)
            ).timeIntervalSince1970,
            fixture.drainAt.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )
        clock.now = fixture.drainAt.addingTimeInterval(5)
        await delivery.drainNowForTesting()

        let addedNotificationCount = await center.addedNotifications.count
        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addedNotificationCount, 1)
        XCTAssertEqual(addAttemptCount, 2)
        XCTAssertEqual(try fixture.deliveryRecord().state, .submitted)
        XCTAssertEqual(try fixture.deliveryRecord().attemptCount, 2)
    }

    func testPermanentAddFailureDoesNotRetry() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let center = RecordingSystemNotificationCenter(
            status: .authorized,
            addResults: [.failure(SystemNotificationCenterFailure.permanent)]
        )
        let delivery = fixture.delivery(center: center)

        await delivery.drainNowForTesting()
        await delivery.drainNowForTesting()

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 1)
        XCTAssertEqual(try fixture.deliveryRecord().state, .failed)
        XCTAssertNil(try fixture.deliveryRecord().nextAttemptAt)
    }

    func testSixMessagesRenderOneSummaryWithOpaqueAccountInboxToken() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 6)
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = fixture.delivery(center: center)

        await delivery.drainNowForTesting()

        let addedNotifications = await center.addedNotifications
        let notification = try XCTUnwrap(addedNotifications.only)
        XCTAssertEqual(notification.id, fixture.deliveryID)
        XCTAssertEqual(notification.body, "6 new messages arrived for me@example.com.")
        XCTAssertEqual(
            notification.userInfo["plainpost.openToken"],
            NotificationOpaqueIdentities.accountInboxToken(
                for: fixture.account.id.rawValue
            )
        )
        XCTAssertFalse(notification.userInfo.values.contains(fixture.account.id.rawValue))
    }

    func testStartupRecoveryTerminalizesAmbiguousSubmissionWithoutCallingSystemCenter() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let claim = try XCTUnwrap(fixture.store.claimMacNewMailDelivery(
            now: fixture.drainAt,
            leaseDuration: 30
        ))
        XCTAssertTrue(try fixture.store.beginMacNewMailSubmission(
            id: claim.id,
            leaseToken: claim.leaseToken,
            now: fixture.drainAt
        ))
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = fixture.delivery(center: center)

        await delivery.start()
        await delivery.stop()

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 0)
        XCTAssertEqual(try fixture.deliveryRecord().state, .failed)
    }

    func testTwoDeliveryActorsRaceButOnlyOneAddsTheRequest() async throws {
        let fixture = try MacDeliveryFixture(messageCount: 1)
        let secondStore = try SQLiteMailStore(path: fixture.url.path)
        try secondStore.migrate()
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let first = fixture.delivery(center: center)
        let second = MacNewMailDelivery(
            store: secondStore,
            center: center,
            newMailEnabled: { true },
            previewEnabled: { true },
            soundsEnabled: { true },
            dateProvider: { fixture.drainAt }
        )

        async let firstDrain: Void = first.drainNowForTesting()
        async let secondDrain: Void = second.drainNowForTesting()
        _ = await (firstDrain, secondDrain)

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 1)
        XCTAssertEqual(try fixture.deliveryRecord().state, .submitted)
    }

    func testStartedDeliveryWakesAtTwoSecondAggregationDeadlineWithoutAnotherStoreSignal() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mac-delivery-wake-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: AccountID("acc-mac-delivery-wake"),
            displayName: "Wake",
            email: EmailAddress("wake@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        let message = MessageSummary(
            id: MessageID("msg-mac-delivery-wake"),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "Wake",
            preview: "Wake at the batch deadline",
            smartCategory: .personal
        )
        let readyAt = Date()
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationDisposition: .candidate(
                providerArrivalAt: readyAt.addingTimeInterval(-1)
            )
        )
        try store.resolveMacNewMailEvents(
            accountID: account.id,
            messageIDs: [message.id],
            suppressedIDs: [],
            now: readyAt
        )
        let center = RecordingSystemNotificationCenter(status: .authorized)
        let delivery = MacNewMailDelivery(
            store: store,
            center: center,
            newMailEnabled: { true },
            previewEnabled: { true },
            soundsEnabled: { true }
        )

        await delivery.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while await center.addAttemptCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await delivery.stop()

        let addAttemptCount = await center.addAttemptCount
        XCTAssertEqual(addAttemptCount, 1)
    }
}

private final class MacDeliveryFixture: @unchecked Sendable {
    let url: URL
    let store: SQLiteMailStore
    let account: Account
    let messageIDs: [MessageID]
    let drainAt: Date
    let deliveryID: String

    init(messageCount: Int) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mac-delivery-\(UUID().uuidString).sqlite")
        store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        account = Account(
            id: AccountID("acc-mac-delivery"),
            displayName: "Delivery",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        let readyAt = Date()
        messageIDs = (0..<messageCount).map { MessageID("msg-mac-delivery-\($0)") }
        for (index, messageID) in messageIDs.enumerated() {
            _ = try store.commitIncomingMessage(
                MessageSummary(
                    id: messageID,
                    threadID: nil,
                    from: EmailAddress("sender@example.com"),
                    fromDisplayName: "Example Sender",
                    subject: "Subject \(index)",
                    preview: "Preview \(index)",
                    body: "Body \(index)",
                    smartCategory: .personal
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: index + 1,
                notificationDisposition: .candidate(
                    providerArrivalAt: readyAt.addingTimeInterval(-10 + Double(index) / 1_000)
                )
            )
        }
        try store.resolveMacNewMailEvents(
            accountID: account.id,
            messageIDs: messageIDs,
            suppressedIDs: [],
            now: readyAt
        )
        drainAt = readyAt.addingTimeInterval(2)
        _ = try store.formMacNewMailDeliveries(now: drainAt)
        deliveryID = try XCTUnwrap(store.macNewMailDeliveries(accountID: account.id).first?.id)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: store.auditLogURL)
    }

    func delivery(
        center: RecordingSystemNotificationCenter,
        now: @escaping @Sendable () -> Date? = { nil }
    ) -> MacNewMailDelivery {
        MacNewMailDelivery(
            store: store,
            center: center,
            newMailEnabled: { true },
            previewEnabled: { true },
            soundsEnabled: { true },
            dateProvider: { now() ?? self.drainAt }
        )
    }

    func deliveryRecord() throws -> MacNewMailDeliveryRecord {
        try XCTUnwrap(store.macNewMailDeliveries(accountID: account.id).first)
    }
}

private actor RecordingSystemNotificationCenter: SystemNotificationCenterAdapting {
    private(set) var authorizationRequestCount = 0
    private(set) var authorizationStatusCheckCount = 0
    private(set) var addAttemptCount = 0
    private(set) var addedNotifications: [PlainpostNotification] = []
    private var status: LocalNotificationAuthorization
    private var addResults: [Result<Void, Error>]
    private let delivered: Set<String>

    init(
        status: LocalNotificationAuthorization,
        addResults: [Result<Void, Error>] = [],
        delivered: Set<String> = []
    ) {
        self.status = status
        self.addResults = addResults
        self.delivered = delivered
    }

    func deliveredMessageTokens() async -> Set<String> { delivered }

    func authorizationStatus() async -> LocalNotificationAuthorization {
        authorizationStatusCheckCount += 1
        return status
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorization {
        authorizationRequestCount += 1
        return status
    }

    func add(_ notification: PlainpostNotification) async throws {
        addAttemptCount += 1
        if !addResults.isEmpty {
            let result = addResults.removeFirst()
            try result.get()
        }
        addedNotifications.append(notification)
    }
}

private final class TestNotificationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
