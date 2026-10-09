import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostLocalAPI
@testable import PlainpostLocalServer
@testable import PlainpostOperationRuntime
@testable import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport
import GRDB

final class LocalAPIDeliveryRouteTests: XCTestCase {
    func testSameIdempotencyKeyCreatesOneDeliveryJob() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        let first = try await harness.send(idempotencyKey: "send-1")
        let second = try await harness.send(idempotencyKey: "send-1")

        XCTAssertEqual(first, second)
        XCTAssertEqual(harness.jobs.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testConcurrentSameIdempotencyKeyCreatesOneDeliveryJob() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        async let first = harness.send(idempotencyKey: "send-concurrent")
        async let second = harness.send(idempotencyKey: "send-concurrent")
        let receipts = try await (first, second)

        XCTAssertEqual(receipts.0, receipts.1)
        XCTAssertEqual(harness.jobs.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testChangedDraftHashFailsBeforeAuthorizationOrSMTP() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.send(expectedHash: "old-hash", idempotencyKey: "send-2")
        }

        XCTAssertTrue(harness.jobs.isEmpty)
        XCTAssertTrue(harness.sendRequestAuditEntries.isEmpty)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testInvalidIdempotencyKeysFailBeforeAuthorizationOrSMTP() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        for key in ["", String(repeating: "é", count: 43)] {
            await XCTAssertThrowsLocalAPIError(.invalidRequest) {
                _ = try await harness.send(idempotencyKey: key)
            }
        }

        XCTAssertTrue(harness.jobs.isEmpty)
        XCTAssertTrue(harness.sendRequestAuditEntries.isEmpty)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testSendRejectsDraftOutsideBrowserOwnershipBoundary() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        let foreign = try harness.createForeignDraft(
            id: DraftID("drf_browser_foreign"),
            createdBy: "mac-user"
        )

        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.send(
                draftID: foreign.id.rawValue,
                expectedHash: foreign.contentHash,
                idempotencyKey: "send-foreign"
            )
        }

        XCTAssertTrue(harness.jobs.isEmpty)
        XCTAssertTrue(harness.sendRequestAuditEntries.isEmpty)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testSendRejectsNonBrowserDraftIDEvenWithBrowserActor() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        let foreign = try harness.createForeignDraft(
            id: DraftID("drf_mac_foreign"),
            createdBy: "browser-extension-user"
        )

        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.send(
                draftID: foreign.id.rawValue,
                expectedHash: foreign.contentHash,
                idempotencyKey: "send-mac-draft"
            )
        }

        XCTAssertTrue(harness.jobs.isEmpty)
        XCTAssertTrue(harness.sendRequestAuditEntries.isEmpty)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testAFailureBeforeDataFailsAndANewKeyIsAccepted() async throws {
        for make in [DeliveryRouteHarness.makeUnreachable, DeliveryRouteHarness.makeRefusingBeforeData] {
            let harness = try await make()
            let first = try await harness.send(idempotencyKey: "send-before-data-first")
            XCTAssertEqual(first.state, .failed, "nothing was sent")

            let retry = try await harness.send(idempotencyKey: "send-before-data-second")
            XCTAssertNotEqual(retry.jobID, first.jobID, "a new key runs a new delivery")
            XCTAssertEqual(harness.jobs.count, 2)
            let acceptedMessageCount = await harness.acceptedMessageCount()
            XCTAssertEqual(acceptedMessageCount, 0)
        }
    }

    func testAmbiguousSMTPFailureReturnsDeliveryUncertainAndCannotRetry() async throws {
        let harness = try await DeliveryRouteHarness.makeAmbiguousSMTP()

        let result = try await harness.send(idempotencyKey: "send-3")
        XCTAssertEqual(result.state, .deliveryUncertain)

        let retry = try await harness.send(idempotencyKey: "send-3")
        XCTAssertEqual(retry, result)
        XCTAssertEqual(harness.attemptCount(idempotencyKey: "send-3"), 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1, "the one possibly-delivered copy, never a second")
    }

    func testAmbiguousSMTPFailureCannotRetryWithDifferentIdempotencyKey() async throws {
        let harness = try await DeliveryRouteHarness.makeAmbiguousSMTP()

        let first = try await harness.send(idempotencyKey: "send-uncertain-first")
        let retry = try await harness.send(idempotencyKey: "send-uncertain-new-key")

        XCTAssertEqual(first.state, .deliveryUncertain)
        XCTAssertEqual(retry, first)
        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        XCTAssertNil(try harness.store.job(idempotencyKey: "browser-send:send-uncertain-new-key"))
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1, "the one possibly-delivered copy, never a second")
    }

    func testAmbiguousSMTPFailureCannotRetryChangedDraftWithDifferentKey() async throws {
        let harness = try await DeliveryRouteHarness.makeAmbiguousSMTP()
        _ = try await harness.send(idempotencyKey: "send-uncertain-before-change")
        let changed = try harness.store.updateDraft(
            id: harness.draft.id,
            patch: DraftPatch(bodyPlain: "Changed after uncertain delivery."),
            actor: DeliveryRouteHarness.browserActor
        )

        let retry = try await harness.send(
            expectedHash: changed.contentHash,
            idempotencyKey: "send-uncertain-after-change"
        )

        XCTAssertEqual(retry.state, .deliveryUncertain)
        XCTAssertEqual(retry.jobID, harness.jobs[0].id)
        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        XCTAssertNil(try harness.store.job(idempotencyKey: "browser-send:send-uncertain-after-change"))
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1, "the one possibly-delivered copy, never a second")
    }

    func testExistingKeyCannotReturnReceiptForDifferentBrowserDraft() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        _ = try await harness.send(idempotencyKey: "send-bound-draft")
        let other = try harness.createForeignDraft(
            id: DraftID("drf_browser_other"),
            createdBy: "browser-extension-user"
        )

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.send(
                draftID: other.id.rawValue,
                expectedHash: other.contentHash,
                idempotencyKey: "send-bound-draft"
            )
        }

        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testExistingKeyCannotBypassForeignDraftOwnership() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        _ = try await harness.send(idempotencyKey: "send-bound-owner")
        let foreign = try harness.createForeignDraft(
            id: DraftID("drf_browser_foreign_reuse"),
            createdBy: "mac-user"
        )

        await XCTAssertThrowsLocalAPIError(.permissionDenied) {
            _ = try await harness.send(
                draftID: foreign.id.rawValue,
                expectedHash: foreign.contentHash,
                idempotencyKey: "send-bound-owner"
            )
        }

        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testExistingKeyCannotReturnReceiptAfterDraftContentChanges() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        _ = try await harness.send(idempotencyKey: "send-bound-hash")
        let changed = try harness.store.updateDraft(
            id: harness.draft.id,
            patch: DraftPatch(bodyPlain: "Changed after delivery."),
            actor: DeliveryRouteHarness.browserActor
        )

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.send(
                expectedHash: changed.contentHash,
                idempotencyKey: "send-bound-hash"
            )
        }

        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testExistingKeyCannotReuseJobAuthorizedByDifferentActor() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        let request = try harness.store.requestSend(
            draftID: harness.draft.id,
            actor: DeliveryRouteHarness.browserActor,
            reason: "Injected request"
        )
        let payload = PlainpostApprovalDecisionInput(
            requestID: request.id,
            actorID: "foreign-user"
        )
        _ = try harness.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery,
            payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
            priority: 100,
            maxAttempts: 1,
            idempotencyKey: "browser-send:send-foreign-actor"
        ))

        await XCTAssertThrowsLocalAPIError(.conflict) {
            _ = try await harness.send(idempotencyKey: "send-foreign-actor")
        }

        XCTAssertEqual(harness.jobs.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testDefiniteSMTPFailureReturnsFailedAndCannotRetry() async throws {
        let harness = try await DeliveryRouteHarness.makeRecipientRejecting()

        let result = try await harness.send(idempotencyKey: "send-failed")
        XCTAssertEqual(result.state, .failed)

        let retry = try await harness.send(idempotencyKey: "send-failed")
        XCTAssertEqual(retry, result)
        XCTAssertEqual(harness.attemptCount(idempotencyKey: "send-failed"), 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testDefiniteFailureAllowsExplicitRetryWithNewIdempotencyKey() async throws {
        let harness = try await DeliveryRouteHarness.makeRecipientRejecting()

        let first = try await harness.send(idempotencyKey: "send-failed-first")
        let retry = try await harness.send(idempotencyKey: "send-failed-new-key")

        XCTAssertEqual(first.state, .failed)
        XCTAssertEqual(retry.state, .failed)
        XCTAssertNotEqual(retry.jobID, first.jobID)
        XCTAssertEqual(harness.jobs.count, 2)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 2)
        XCTAssertEqual(harness.attemptCount(idempotencyKey: "send-failed-first"), 1)
        XCTAssertEqual(harness.attemptCount(idempotencyKey: "send-failed-new-key"), 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testCompletedDeliveryReturnsStableReceiptForNewIdempotencyKey() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        let first = try await harness.send(idempotencyKey: "send-completed-first")
        let duplicate = try await harness.send(idempotencyKey: "send-completed-new-key")

        XCTAssertEqual(first.state, .sent)
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        XCTAssertNil(try harness.store.job(idempotencyKey: "browser-send:send-completed-new-key"))
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testReplySendRouteReturnsAuditedDeliveryReceipt() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()

        let result = try await harness.sendThroughRoute(idempotencyKey: "send-route")

        XCTAssertEqual(result.state, .sent)
        let request = try harness.store.sendRequest(id: SendRequestID(result.requestID))
        XCTAssertEqual(request.requestedBy, "browser-extension-user")
        XCTAssertEqual(request.reason, "Direct reply authorized in Plainpost browser extension")
        XCTAssertEqual(request.status, .sent)
        XCTAssertEqual(request.approvedDraftHash, harness.draft.contentHash)
        let job = try harness.store.job(id: result.jobID)
        XCTAssertEqual(job.kind, .approvedDelivery)
        XCTAssertEqual(job.priority, 100)
        XCTAssertEqual(job.maxAttempts, 1)
        XCTAssertEqual(job.idempotencyKey, "browser-send:send-route")
        let payload = try JSONDecoder().decode(
            PlainpostApprovalDecisionInput.self,
            from: Data(job.payloadJSON.utf8)
        )
        XCTAssertEqual(payload.requestID, request.id)
        XCTAssertEqual(payload.actorID, "browser-extension-user")
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries[0].actorID, "browser-extension-user")
        XCTAssertTrue(harness.store.auditEntries.contains {
            $0.action == "message.sent_copy" && $0.actorID == "browser-extension-user"
        })
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }

    func testAuthorizationAndJobEnqueueRollbackTogetherWhenJobInsertFails() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        let faultConnection = try DatabaseQueue(path: harness.databaseURL.path)
        try await faultConnection.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_browser_delivery_insert
                BEFORE INSERT ON durable_jobs
                WHEN NEW.kind = 'approved-delivery'
                BEGIN
                    SELECT RAISE(FAIL, 'forced browser delivery insert failure');
                END;
                """)
        }

        do {
            _ = try await harness.send(idempotencyKey: "send-atomic-failure")
            XCTFail("Expected forced durable job insert failure.")
        } catch {
            // Expected.
        }

        XCTAssertTrue(harness.jobs.isEmpty)
        XCTAssertTrue(harness.sendRequestAuditEntries.isEmpty)
        XCTAssertTrue(harness.store.approvalQueueRequests.isEmpty)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 0)
    }

    func testMultipleDeliveryServiceInstancesCreateOneAuthorizationAndJob() async throws {
        let harness = try await DeliveryRouteHarness.makeSMTPAccepting()
        let services = (0..<8).map { _ in harness.makeDeliveryService() }

        let receipts = try await withThrowingTaskGroup(of: LocalAPIDeliveryResult.self) { group in
            for service in services {
                group.addTask {
                    try await service.send(
                        draftID: harness.draft.id.rawValue,
                        expectedHash: harness.draft.contentHash,
                        idempotencyKey: "send-multi-service"
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(receipts.map(\.jobID)).count, 1)
        XCTAssertEqual(Set(receipts.map(\.requestID)).count, 1)
        XCTAssertEqual(harness.jobs.count, 1)
        XCTAssertEqual(harness.sendRequestAuditEntries.count, 1)
        let acceptedMessageCount = await harness.acceptedMessageCount()
        XCTAssertEqual(acceptedMessageCount, 1)
    }
}

private final class DeliveryRouteHarness: @unchecked Sendable {
    static let browserActor = Actor(
        id: "browser-extension-user",
        kind: .user,
        displayName: "Plainpost Browser Extension",
        permissions: .guiUser
    )

    let store: SQLiteMailStore
    let smtp: LocalSMTPServer
    let draft: Draft
    let service: BrowserReplyDeliveryService
    let route: ReplySendRoute

    let databaseURL: URL
    private let runtime: LocalOperationRuntime

    var jobs: [PlainpostDurableJob] {
        (try? store.jobs(limit: 100)) ?? []
    }

    var sendRequestAuditEntries: [AuditEntry] {
        store.auditEntries.filter { $0.action == "send.request" }
    }

    deinit {
        smtp.stop()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    static func makeSMTPAccepting() async throws -> DeliveryRouteHarness {
        try await make()
    }

    static func makeRecipientRejecting() async throws -> DeliveryRouteHarness {
        try await make(rejectedRecipients: [EmailAddress("team@example.com")])
    }

    /// The server drops the connection after the message content (DATA):
    /// it may have been delivered. (A server that cannot be reached is a
    /// definite failure before DATA, not an ambiguous one.)
    static func makeAmbiguousSMTP() async throws -> DeliveryRouteHarness {
        try await make(disconnectAfterData: true)
    }

    /// Refuses at MAIL FROM, before any message content.
    static func makeRefusingBeforeData() async throws -> DeliveryRouteHarness {
        try await make(mailFromReply: "554 5.7.1 Sender rejected")
    }

    /// No SMTP server is listening: the connection fails before any content.
    static func makeUnreachable() async throws -> DeliveryRouteHarness {
        let harness = try await make()
        harness.smtp.stop()
        return harness
    }

    private static func make(
        rejectedRecipients: [EmailAddress] = [],
        disconnectAfterData: Bool = false,
        mailFromReply: String? = nil
    ) async throws -> DeliveryRouteHarness {
        let smtpPassword = "local-test-secret"
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: smtpPassword,
            rejectedRecipients: rejectedRecipients,
            disconnectAfterData: disconnectAfterData,
            mailFromReply: mailFromReply
        )
        try await smtp.start()

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-local-delivery-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let account = Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1",
            smtpHost: "127.0.0.1",
            smtpPort: smtp.port
        )
        try store.cacheAccounts([account])
        try store.cacheThreads([MailThread(
            id: ThreadID("thread-1"),
            accountID: account.id,
            subjectNormalized: "Status",
            participantEmails: [account.email, EmailAddress("team@example.com")]
        )])

        let draft = try store.createDraft(
            Draft(
                id: DraftID("drf_browser_delivery"),
                accountID: account.id,
                from: account.email,
                to: [EmailAddress("team@example.com")],
                cc: [],
                bcc: [],
                subject: "Re: Status",
                bodyPlain: "Friday works for me.",
                createdBy: browserActor.id,
                aiGenerated: false,
                sourceThreadID: ThreadID("thread-1")
            ),
            actor: browserActor
        )

        let credentials = InMemoryCredentialVault()
        try await credentials.store(
            Data(smtpPassword.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):smtp-password"
            )
        )
        let runtime = LocalOperationRuntime(
            store: store,
            credentials: credentials,
            allowedJobKinds: [.approvedDelivery]
        )
        let service = BrowserReplyDeliveryService(store: store, runtime: runtime)
        return DeliveryRouteHarness(
            store: store,
            smtp: smtp,
            draft: draft,
            service: service,
            route: ReplySendRoute(deliveryService: service),
            databaseURL: databaseURL,
            runtime: runtime
        )
    }

    private init(
        store: SQLiteMailStore,
        smtp: LocalSMTPServer,
        draft: Draft,
        service: BrowserReplyDeliveryService,
        route: ReplySendRoute,
        databaseURL: URL,
        runtime: LocalOperationRuntime
    ) {
        self.store = store
        self.smtp = smtp
        self.draft = draft
        self.service = service
        self.route = route
        self.databaseURL = databaseURL
        self.runtime = runtime
    }

    func send(
        draftID: String? = nil,
        expectedHash: String? = nil,
        idempotencyKey: String
    ) async throws -> LocalAPIDeliveryResult {
        try await service.send(
            draftID: draftID ?? draft.id.rawValue,
            expectedHash: expectedHash ?? draft.contentHash,
            idempotencyKey: idempotencyKey
        )
    }

    func sendThroughRoute(idempotencyKey: String) async throws -> LocalAPIDeliveryResult {
        let requestID = "route-request"
        let request = LocalAPIRequest(
            requestID: requestID,
            method: .replySend,
            parameters: LocalAPISendParameters(
                draftID: draft.id.rawValue,
                expectedHash: draft.contentHash,
                idempotencyKey: idempotencyKey
            )
        )
        let response = try await route.handle(
            requestData: JSONEncoder().encode(request),
            requestID: requestID
        )
        return try JSONDecoder().decode(LocalAPISuccess<LocalAPIDeliveryResult>.self, from: response).result
    }

    func acceptedMessageCount() async -> Int {
        await smtp.acceptedMessages().count
    }

    func attemptCount(idempotencyKey: String) -> Int? {
        try? store.job(idempotencyKey: "browser-send:\(idempotencyKey)")?.attempt
    }

    func makeDeliveryService() -> BrowserReplyDeliveryService {
        BrowserReplyDeliveryService(store: store, runtime: runtime)
    }

    func createForeignDraft(id: DraftID, createdBy: String) throws -> Draft {
        try store.createDraft(
            Draft(
                id: id,
                accountID: draft.accountID,
                from: draft.from,
                to: draft.to,
                cc: [],
                bcc: [],
                subject: draft.subject,
                bodyPlain: "Foreign draft",
                createdBy: createdBy,
                aiGenerated: false,
                sourceThreadID: draft.sourceThreadID
            ),
            actor: Actor(
                id: createdBy,
                kind: .user,
                displayName: "Foreign",
                permissions: .guiUser
            )
        )
    }
}

private func XCTAssertThrowsLocalAPIError<T>(
    _ expectedCode: LocalAPIErrorCode,
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected LocalAPIRouteError", file: file, line: line)
    } catch let error as LocalAPIRouteError {
        XCTAssertEqual(error.code, expectedCode, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
