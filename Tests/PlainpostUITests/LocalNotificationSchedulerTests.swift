import XCTest
@testable import PlainpostAI
import PlainpostCore
import PlainpostAccountProtocol
import PlainpostDB
@testable import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport
@testable import PlainpostUI

final class LocalNotificationSchedulerTests: XCTestCase {
    override func tearDown() {
        for key in [
            PlainpostNotificationPreference.newMailKey,
            PlainpostNotificationPreference.newMailPreviewKey,
            PlainpostNotificationPreference.notificationSoundsKey,
            PlainpostNotificationPreference.pendingSendApprovalsKey,
            PlainpostNotificationPreference.syncFailuresKey
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testAudibleNotificationResolvesBundledChime() {
        let notification = PlainpostNotification(
            id: "audible",
            title: "New mail",
            body: "A message arrived.",
            categoryIdentifier: "new_mail",
            userInfo: [:],
            playsSound: true
        )

        XCTAssertEqual(
            PlainpostNotificationSound.resolveResourceName(for: notification),
            "PlainpostNotification.caf"
        )
    }

    func testSilentNotificationDoesNotResolveSoundResource() {
        let notification = PlainpostNotification(
            id: "silent",
            title: "Mail sync completed",
            body: "No new messages.",
            categoryIdentifier: "sync_completed",
            userInfo: [:],
            playsSound: false
        )

        XCTAssertNil(PlainpostNotificationSound.resolveResourceName(for: notification))
    }

    func testDisabledSoundPreferenceSuppressesNewMailSound() {
        UserDefaults.standard.set(false, forKey: PlainpostNotificationPreference.notificationSoundsKey)

        let notification = PlainpostNotification.newMail(Self.message)

        XCTAssertFalse(notification.playsSound)
        XCTAssertNil(PlainpostNotificationSound.resolveResourceName(for: notification))
    }

    func testNotificationFactoriesPreserveCategorySoundPolicies() {
        let request = SendRequest(
            id: SendRequestID("srq_notification_sound"),
            draftID: DraftID("drf_notification_sound"),
            requestedBy: "codex",
            status: .pending,
            requestedDraftHash: "hash",
            riskScore: 0,
            riskFlags: [],
            reason: nil,
            approvedBy: nil,
            approvedDraftHash: nil
        )
        let input = ComposerDraftInput(
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            subject: "Review",
            bodyPlain: "Please review."
        )

        let approval = PlainpostNotification.pendingSendApproval(request: request, input: input)
        let syncFailure = PlainpostNotification.syncFailed(account: Self.account)
        let syncCompleted = PlainpostNotification.syncCompleted(account: Self.account, newMessageCount: 0)

        XCTAssertEqual(
            PlainpostNotificationSound.resolveResourceName(for: approval),
            "PlainpostNotification.caf"
        )
        XCTAssertEqual(
            PlainpostNotificationSound.resolveResourceName(for: syncFailure),
            "PlainpostNotification.caf"
        )
        XCTAssertNil(PlainpostNotificationSound.resolveResourceName(for: syncCompleted))
    }

    func testNewMailNotificationIncludesMessageContextWhenPreviewsAreEnabled() {
        UserDefaults.standard.set(true, forKey: PlainpostNotificationPreference.newMailPreviewKey)
        let notification = PlainpostNotification.newMail(Self.message)

        XCTAssertEqual(notification.categoryIdentifier, "new_mail")
        XCTAssertEqual(notification.title, "Example Sender")
        XCTAssertEqual(notification.body, "A useful subject — Short preview")
        XCTAssertEqual(notification.userInfo["message_id"], Self.message.id.rawValue)
        XCTAssertTrue(notification.playsSound)
    }

    func testNewMailNotificationHidesMessageContextWhenPreviewsAreDisabled() {
        UserDefaults.standard.set(false, forKey: PlainpostNotificationPreference.newMailPreviewKey)
        let notification = PlainpostNotification.newMail(Self.message)

        XCTAssertEqual(notification.title, "New message")
        XCTAssertEqual(notification.body, "Open Plainpost to view it.")
        XCTAssertFalse(notification.body.contains(Self.message.subject))
        XCTAssertFalse(notification.title.contains(Self.message.from.rawValue))
    }

    func testScopedNewMailNotificationUsesAccountSourceBoundTapAndIdentifier() {
        let first = PlainpostNotification.newMail(
            Self.message, accountID: Self.account.id, sourceKind: .direct,
            sourceGeneration: 0
        )
        let otherAccount = PlainpostNotification.newMail(
            Self.message, accountID: AccountID("other-account"), sourceKind: .direct,
            sourceGeneration: 0
        )
        let node = PlainpostNotification.newMail(
            Self.message, accountID: Self.account.id, sourceKind: .nodeBacked,
            sourceGeneration: 1
        )

        XCTAssertEqual(first.userInfo.keys.sorted(), ["plainpost.openToken"])
        XCTAssertEqual(first.userInfo["plainpost.openToken"],
            NotificationOpaqueIdentities.messageToken(
                for: Self.message.id.rawValue,
                accountID: Self.account.id.rawValue,
                sourceKind: "direct",
                sourceGeneration: 0
            ))
        XCTAssertFalse(first.id.contains(Self.message.id.rawValue))
        XCTAssertNotEqual(first.id, otherAccount.id)
        XCTAssertNotEqual(first.id, node.id)
        XCTAssertNotEqual(first.userInfo, otherAccount.userInfo)
        XCTAssertNotEqual(first.userInfo, node.userInfo)
    }

    func testManualSyncSchedulesOnlySyncResultNotification() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let scheduler = RecordingNotificationScheduler()
        let client = NotificationSyncClient(store: store, message: Self.message)
        let syncer = LocalOperationAccountInboxSyncer(
            client: client,
            notificationScheduler: scheduler
        )

        let result = try await syncer.syncInbox(for: Self.account, reason: .manual)
        let notifications = await scheduler.recorded()

        XCTAssertEqual(result.newlyDiscoveredMessageCount, 1)
        XCTAssertEqual(notifications.map(\.categoryIdentifier), ["sync_completed"])
    }

    func testSelectedDirectSyncerCapturesGenerationInQueuedInput() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let client = NotificationSyncClient(
            store: store, messages: [], suppressedMessageIDs: []
        )
        let syncer = LocalOperationAccountInboxSyncer(
            client: client,
            notificationScheduler: RecordingNotificationScheduler(),
            directSourceProvider: { (Self.account.id, 7) }
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)

        XCTAssertEqual(client.lastSyncInput()?.expectedDirectSourceGeneration, 7)
    }

    func testSuccessfulSyncSchedulesIncrementalSmartInboxOnlyForChangedCache() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let provider = DeterministicAIProvider()
        let aiClient = CountingSmartInboxOperationClient(base: LocalOperationClient(
            runtime: LocalOperationRuntime(
                store: store,
                credentials: InMemoryCredentialVault(),
                allowedJobKinds: [.aiOperation, .searchRebuild],
                aiProviderResolver: { _ in provider }
            )
        ))
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: aiClient,
            selectedAIProviderID: { "deterministic" }
        )
        let syncedMessage = MessageSummary(
            id: MessageID("msg_sync_completion"),
            threadID: ThreadID("thr_sync_completion"),
            from: EmailAddress("sender@example.com"),
            subject: "Synced",
            preview: "Classify this after sync",
            smartCategory: .unknown
        )
        let syncClient = NotificationSyncClient(store: store, message: syncedMessage)
        let syncer = LocalOperationAccountInboxSyncer(
            client: syncClient,
            notificationScheduler: RecordingNotificationScheduler(),
            didCompleteSync: { await organizer.requestIncrementalOrganization() }
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        try await waitForSmartInboxCompletion(
            in: store,
            messageID: syncedMessage.id,
            count: 1
        )
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count, 1)
        let initialSmartInboxCallCount = await aiClient.smartInboxCallCount()
        XCTAssertEqual(initialSmartInboxCallCount, 1)

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        XCTAssertEqual(try store.jobs(limit: 100).filter { $0.kind == .aiOperation }.count, 1)
        let finalSmartInboxCallCount = await aiClient.smartInboxCallCount()
        XCTAssertEqual(finalSmartInboxCallCount, 2)
    }

    func testSuccessfulSyncReturnsPromptlyAndCoalescesWhileSmartInboxIsPaused() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let aiClient = SuspendedSmartInboxOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: aiClient,
            selectedAIProviderID: { "deterministic" }
        )
        let syncer = LocalOperationAccountInboxSyncer(
            client: NotificationSyncClient(store: store, message: Self.message),
            notificationScheduler: RecordingNotificationScheduler(),
            didCompleteSync: { await organizer.requestIncrementalOrganization() }
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        await aiClient.waitUntilCallCount(1)

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        let smartInboxCallCount = await aiClient.smartInboxCallCount()
        XCTAssertEqual(smartInboxCallCount, 2)

        await aiClient.release()
    }

    func testSuccessfulSyncUsesCurrentClassifierIdentityWhileAnotherOrganizerIsPaused() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let providerSelection = MutableProviderSelection("deterministic")
        let aiClient = SuspendedSmartInboxOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: aiClient,
            selectedAIProviderID: { providerSelection.value }
        )
        let syncer = LocalOperationAccountInboxSyncer(
            client: NotificationSyncClient(store: store, message: Self.message),
            notificationScheduler: RecordingNotificationScheduler(),
            didCompleteSync: { await organizer.requestIncrementalOrganization() }
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        await aiClient.waitUntilCallCount(1)
        providerSelection.value = "ollama"

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)
        await aiClient.waitUntilCallCount(2)
        let providerIDs = await aiClient.providerIDs()
        XCTAssertEqual(providerIDs, ["deterministic", "ollama"])

        await aiClient.release()
    }

    func testDirectSyncOrganizerPassesSelectedAccountAndGeneration() async throws {
        let accountID = AccountID("direct-sync-organizer")
        let client = SuspendedSmartInboxOperationClient()
        let organizer = SmartInboxSyncCompletionOrganizer(
            client: client,
            selectedAIProviderID: { "deterministic" },
            scopeProvider: { .account(accountID) },
            directSourceProvider: { (accountID, 7) }
        )

        await organizer.requestIncrementalOrganization()
        let recordedInput = await client.latestInput()
        let input = try XCTUnwrap(recordedInput)
        XCTAssertEqual(input.accountID, accountID)
        XCTAssertEqual(input.expectedDirectSourceGeneration, 7)
        XCTAssertEqual(input.smartInboxRunRequest.scope, .account(accountID))

        let wrongScope = SmartInboxSyncCompletionOrganizer(
            client: client,
            selectedAIProviderID: { "deterministic" },
            scopeProvider: { .allAccounts },
            directSourceProvider: { (accountID, 7) }
        )
        await wrongScope.requestIncrementalOrganization()
        let callCount = await client.smartInboxCallCount()
        XCTAssertEqual(callCount, 1)
    }

    private func waitForSmartInboxCompletion(
        in store: SQLiteMailStore,
        messageID: MessageID,
        count: Int
    ) async throws {
        // A deadline, not a poll count: under full-suite load the durable
        // job can need far longer than a second to run.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let organizers = try store.jobs(limit: 100).filter { $0.kind == .aiOperation }
            let completed = organizers.count == count && organizers.allSatisfy { $0.state == .completed }
            if completed, try store.smartInboxClassificationCache()[messageID] != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for completed Smart Inbox work and applied cache.")
    }

    func testAccountSetupImportDoesNotScheduleNotifications() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let scheduler = RecordingNotificationScheduler()
        let client = NotificationSyncClient(store: store, message: Self.message)
        let syncer = LocalOperationAccountInboxSyncer(
            client: client,
            notificationScheduler: scheduler
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .accountSetup)

        let notifications = await scheduler.recorded()
        XCTAssertTrue(notifications.isEmpty)
    }

    func testManualSyncDoesNotNotifySuppressedMessagesOrCountThemInSummary() async throws {
        let store = try makeStore()
        try store.cacheAccounts([Self.account])
        let messages = (0..<8).map { index in
            MessageSummary(
                id: MessageID("msg-rule-notification-\(index)"),
                threadID: nil,
                from: EmailAddress("sender\(index)@example.com"),
                subject: "Message \(index)",
                preview: "Preview",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let scheduler = RecordingNotificationScheduler()
        let client = NotificationSyncClient(
            store: store,
            messages: messages,
            suppressedMessageIDs: Set(messages.prefix(2).map(\.id))
        )
        let syncer = LocalOperationAccountInboxSyncer(
            client: client,
            notificationScheduler: scheduler
        )

        _ = try await syncer.syncInbox(for: Self.account, reason: .manual)

        let notifications = await scheduler.recorded()
        XCTAssertFalse(notifications.contains { $0.categoryIdentifier == "new_mail" })
        XCTAssertEqual(notifications.map(\.categoryIdentifier), ["sync_completed"])
    }

    private func makeStore() throws -> SQLiteMailStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-tests-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return store
    }

    private static let account = Account(
        id: AccountID("acc_notifications"),
        displayName: "Notifications",
        email: EmailAddress("me@example.com"),
        username: "me@example.com",
        imapHost: "imap.example.com",
        imapPort: 993,
        smtpHost: "smtp.example.com",
        smtpPort: 587
    )

    private static let message = MessageSummary(
        id: MessageID("msg_new_notification"),
        threadID: ThreadID("thr_new_notification"),
        from: EmailAddress("sender@example.com"),
        fromDisplayName: "Example Sender",
        subject: "A useful subject",
        preview: "Short preview",
        smartCategory: .personal,
        labels: [],
        isSeen: false,
        mailboxPath: "INBOX",
        isDeleted: false,
        body: "Body",
        sentAt: Date(timeIntervalSince1970: 100)
    )
}

private actor RecordingNotificationScheduler: LocalNotificationScheduling {
    private var notifications: [PlainpostNotification] = []

    func schedule(_ notification: PlainpostNotification) async throws {
        notifications.append(notification)
    }

    func recorded() -> [PlainpostNotification] {
        notifications
    }
}

private final class NotificationSyncClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let messages: [MessageSummary]
    private let suppressedMessageIDs: Set<MessageID>
    private let inputLock = NSLock()
    private var capturedInput: PlainpostInboxSyncInput?

    func lastSyncInput() -> PlainpostInboxSyncInput? {
        inputLock.withLock { capturedInput }
    }

    init(store: SQLiteMailStore, message: MessageSummary) {
        self.store = store
        self.messages = [message]
        self.suppressedMessageIDs = []
    }

    init(
        store: SQLiteMailStore,
        messages: [MessageSummary],
        suppressedMessageIDs: Set<MessageID>
    ) {
        self.store = store
        self.messages = messages
        self.suppressedMessageIDs = suppressedMessageIDs
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        inputLock.withLock { capturedInput = input }
        for (index, message) in messages.enumerated() {
            _ = try store.commitIncomingMessage(
                message,
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: input.accountID,
                mailboxPath: message.mailboxPath,
                uidValidity: 1,
                uid: index + 1,
                notificationEligible: false
            )
        }
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: messages.count,
            newlyDiscoveredMessageCount: messages.count,
            source: .incremental,
            newMessageIDs: messages.map(\.id),
            suppressedNotificationMessageIDs: messages
                .map(\.id)
                .filter(suppressedMessageIDs.contains),
            jobID: "job_notification_sync"
        )
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw PlainpostError.validationFailed("Not used")
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw PlainpostError.validationFailed("Not used")
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw PlainpostError.validationFailed("Not used")
    }
}

private actor CountingSmartInboxOperationClient: PlainpostOperationClientProtocol {
    private let base: LocalOperationClient
    private var calls = 0

    init(base: LocalOperationClient) {
        self.base = base
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        try await base.executeInboxSync(input)
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        if input.operation == .recategorizeInbox {
            calls += 1
        }
        return try await base.executeAI(input)
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        calls += 1
        try await base.enqueueIncrementalSmartInbox(input)
    }

    func smartInboxCallCount() -> Int {
        calls
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        try await base.approveSend(requestID: requestID, approvedBy: approvedBy)
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        try await base.denySend(requestID: requestID, deniedBy: deniedBy)
    }
}

private actor SuspendedSmartInboxOperationClient: PlainpostOperationClientProtocol {
    private var smartInboxCalls = 0
    private var scheduledProviderIDs: [String] = []
    private var scheduledInputs: [PlainpostAIOperationInput] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        throw PlainpostError.validationFailed("Not used")
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        smartInboxCalls += 1
        scheduledProviderIDs.append(input.providerID)
        scheduledInputs.append(input)
        let readyWaiters = callCountWaiters.filter { smartInboxCalls >= $0.0 }
        callCountWaiters.removeAll { smartInboxCalls >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: "unused",
            jobID: "paused-organizer"
        )
    }

    func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        smartInboxCalls += 1
        scheduledProviderIDs.append(input.providerID)
        scheduledInputs.append(input)
        let readyWaiters = callCountWaiters.filter { smartInboxCalls >= $0.0 }
        callCountWaiters.removeAll { smartInboxCalls >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
    }

    func smartInboxCallCount() -> Int {
        smartInboxCalls
    }

    func providerIDs() -> [String] {
        scheduledProviderIDs
    }

    func latestInput() -> PlainpostAIOperationInput? {
        scheduledInputs.last
    }

    func waitUntilCallCount(_ expected: Int) async {
        if smartInboxCalls >= expected { return }
        await withCheckedContinuation { callCountWaiters.append((expected, $0)) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw PlainpostError.validationFailed("Not used")
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw PlainpostError.validationFailed("Not used")
    }
}

private final class MutableProviderSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var selectedProviderID: String

    init(_ selectedProviderID: String) {
        self.selectedProviderID = selectedProviderID
    }

    var value: String {
        get { lock.withLock { selectedProviderID } }
        set { lock.withLock { selectedProviderID = newValue } }
    }
}
