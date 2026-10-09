import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport
@testable import PlainpostUI

final class ApprovalQueueViewModelTests: XCTestCase {
    /// Ledger Task 6: a failed pull to refresh stays visible on the approvals list until a
    /// refresh succeeds. Both refreshes run on the same view model (task-3-review Minor 7): a
    /// fresh, never-failed view model would also start with `refreshFailure == nil`, so testing
    /// the clear requires watching one view model's failure actually go away.
    @MainActor
    func testAFailedRefreshIsReportedUntilOneSucceeds() async {
        let viewModel = ApprovalQueueViewModel(queue: FlakyThenHealthyApprovalQueueForTests())
        do {
            try await viewModel.refresh()
            XCTFail("the first refresh fails")
        } catch {}
        XCTAssertEqual(viewModel.refreshFailure, "Unable to refresh approval queue.")

        try? await viewModel.refresh()
        XCTAssertNil(viewModel.refreshFailure, "a later successful refresh clears the earlier failure")
    }

    @MainActor
    func testAPossiblySentApprovalNeverInvitesARetry() async throws {
        let viewModel = ApprovalQueueViewModel(queue: PossiblySentApprovalQueue(), items: [
            ApprovalQueueItemModel(id: "srq_1", agentName: "Agent", subject: "Offer", recipientSummary: "a@example.com",
                                   riskFlags: [], hasAttachments: false, status: "approved"),
        ])
        do {
            try await viewModel.approve(requestID: "srq_1", username: "", password: "")
            XCTFail("expected the approval to fail")
        } catch {}
        XCTAssertEqual(viewModel.statusMessage, "This message may have been sent. Check Sent before sending it again.")
        XCTAssertFalse(viewModel.statusMessage?.contains("Try again") ?? true)
        XCTAssertEqual(ApprovalStatusPresentation.title(for: "delivery_uncertain"), "May have been sent")
        XCTAssertEqual(ApprovalStatusPresentation.title(for: "failed"), "Failed")
    }

    @MainActor
    func testPendingItemCountOnlyIncludesPendingRequests() {
        let viewModel = ApprovalQueueViewModel(
            queue: PreviewApprovalQueueForTests(),
            items: [
                ApprovalQueueItemModel(
                    id: "pending",
                    agentName: "Agent",
                    subject: "Pending",
                    recipientSummary: "person@example.com",
                    riskFlags: [],
                    hasAttachments: false,
                    status: "pending"
                ),
                ApprovalQueueItemModel(
                    id: "sent",
                    agentName: "Agent",
                    subject: "Sent",
                    recipientSummary: "person@example.com",
                    riskFlags: [],
                    hasAttachments: false,
                    status: "sent"
                )
            ]
        )

        XCTAssertEqual(viewModel.pendingItemCount, 1)
    }

    @MainActor
    func testRefreshShowsPendingAgentSendRequestWithRiskDetails() async throws {
        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "User asked me to reply")
        let smtp = RecordingSMTPClient()
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(
                store: store,
                smtpClient: smtp
            )
        )

        try await viewModel.refresh()

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items[0].id, request.id.rawValue)
        XCTAssertEqual(viewModel.items[0].agentName, "codex")
        XCTAssertEqual(viewModel.items[0].subject, "Re: Availability")
        XCTAssertEqual(viewModel.items[0].recipientSummary, "alice@example.com")
        XCTAssertEqual(viewModel.items[0].riskFlags, ["agent_requested_send", "ai_generated_body"])
        XCTAssertFalse(viewModel.items[0].hasAttachments)
        XCTAssertFalse(viewModel.items[0].requiresAuthentication)
        XCTAssertEqual(viewModel.items[0].status, "pending")
        XCTAssertEqual(viewModel.items[0].reviewDetails?.from, "me@example.com")
        XCTAssertEqual(viewModel.items[0].reviewDetails?.to, ["alice@example.com"])
        XCTAssertEqual(viewModel.items[0].reviewDetails?.cc, [])
        XCTAssertEqual(viewModel.items[0].reviewDetails?.bcc, [])
        XCTAssertEqual(viewModel.items[0].reviewDetails?.bodyPlain, "Tuesday works for me.")
        XCTAssertEqual(viewModel.items[0].reviewDetails?.attachments, [])
        XCTAssertEqual(viewModel.items[0].reviewDetails?.requestReason, "User asked me to reply")
        XCTAssertEqual(viewModel.items[0].reviewDetails?.riskScore, request.riskScore)
    }

    @MainActor
    func testApproveSendsDraftThroughLocalSMTPHarnessAndRefreshesStatus() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "User asked me to reply")
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(
                store: store,
                smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
            )
        )

        try await viewModel.approve(
            requestID: request.id.rawValue,
            username: "me@example.com",
            password: "secret"
        )

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(accepted[0].data.contains("Subject: Re: Availability"))
        XCTAssertFalse(accepted[0].data.contains("Bcc:"))
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertEqual(viewModel.items.first?.status, "sent")
        XCTAssertEqual(viewModel.statusMessage, "Sent Re: Availability")
    }

    @MainActor
    func testDenyDoesNotSendSMTPAndRefreshesStatus() async throws {
        let smtp = RecordingSMTPClient()
        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(store: store, smtpClient: smtp)
        )

        try await viewModel.deny(requestID: request.id.rawValue, reason: "Needs edit")

        XCTAssertEqual(smtp.sentMessages.count, 0)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .denied)
        XCTAssertEqual(viewModel.items.first?.status, "denied")
        XCTAssertEqual(viewModel.statusMessage, "Denied Re: Availability")
    }

    @MainActor
    func testSuccessfulDenialLeavesPendingStateEvenWhenProjectionRefreshFails() async throws {
        let request = ApprovalQueueItemModel(
            id: "request",
            agentName: "Agent",
            subject: "Needs review",
            recipientSummary: "person@example.com",
            riskFlags: [],
            hasAttachments: false,
            status: "pending"
        )
        let viewModel = ApprovalQueueViewModel(
            queue: CompletedActionWithFailingRefreshQueue(),
            items: [request]
        )

        try await viewModel.deny(requestID: request.id, reason: nil)

        XCTAssertEqual(viewModel.items.first?.status, "denied")
        XCTAssertEqual(viewModel.pendingItemCount, 0)
        XCTAssertEqual(viewModel.statusMessage, "Denied Needs review")
    }

    @MainActor
    func testHighRiskApprovalRequiresLocalAuthenticationBeforeSMTP() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(highRiskDraft(), actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Please send this")
        let authenticator = RecordingApprovalAuthenticator(result: .success(()))
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(
                store: store,
                smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port),
                authenticator: authenticator
            )
        )

        try await viewModel.refresh()

        XCTAssertEqual(viewModel.items[0].requiresAuthentication, true)

        try await viewModel.approve(
            requestID: request.id.rawValue,
            username: "me@example.com",
            password: "secret"
        )

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(authenticator.reasons, ["Authenticate to approve high-risk send \"Quarterly wire details\"."])
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertEqual(viewModel.statusMessage, "Sent Quarterly wire details")
    }

    @MainActor
    func testDeniedHighRiskAuthenticationDoesNotSendSMTP() async throws {
        let smtp = RecordingSMTPClient()
        let store = InMemoryMailStore()
        let draft = try store.createDraft(highRiskDraft(), actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let authenticator = RecordingApprovalAuthenticator(result: .failure(LocalApprovalAuthenticationError.denied))
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(
                store: store,
                smtpClient: smtp,
                authenticator: authenticator
            )
        )

        do {
            try await viewModel.approve(
                requestID: request.id.rawValue,
                username: "me@example.com",
                password: "secret"
            )
            XCTFail("Expected authentication denial")
        } catch {
            XCTAssertEqual(error as? LocalApprovalAuthenticationError, .denied)
        }

        XCTAssertEqual(authenticator.reasons, ["Authenticate to approve high-risk send \"Quarterly wire details\"."])
        XCTAssertEqual(smtp.sentMessages.count, 0)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .pending)
        XCTAssertEqual(viewModel.statusMessage, "Approval cancelled. Local authentication was not completed.")
        XCTAssertFalse(viewModel.isWorking)
    }

    @MainActor
    func testCancellationAtSynchronousReadReturnKeepsItemsAndErrorState() async {
        let cached = ApprovalQueueItemModel(id: "cached", agentName: "Agent", subject: "Cached",
                                            recipientSummary: "a@example.com", riskFlags: [],
                                            hasAttachments: false, status: "pending")
        for fails in [false, true] {
            let model = ApprovalQueueViewModel(queue: CancellingReadApprovalQueue(fails: fails), items: [cached])
            let refresh = Task { try? await model.refresh() }
            await refresh.value
            XCTAssertEqual(model.items.map(\.id), ["cached"])
            XCTAssertNil(model.statusMessage, "cancellation is not a new refresh error")
            XCTAssertFalse(model.isWorking)
        }
    }

    @MainActor
    func testRefreshFailureExposesSafeStatusAndEndsLoading() async {
        let viewModel = ApprovalQueueViewModel(queue: FailingApprovalQueueForTests())

        do {
            try await viewModel.refresh()
            XCTFail("Expected refresh to fail")
        } catch {
            XCTAssertEqual(error as? PlainpostError, .notFound("fixture failure"))
        }

        XCTAssertEqual(viewModel.statusMessage, "Unable to refresh approval queue.")
        XCTAssertFalse(viewModel.isWorking)
    }

    @MainActor
    func testServiceMapsActualAttachmentAndRiskReviewDetails() async throws {
        let store = InMemoryMailStore()
        let draft = try store.createDraft(highRiskDraft(), actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Please send this")
        let viewModel = ApprovalQueueViewModel(
            queue: ApprovalQueueService(store: store, smtpClient: RecordingSMTPClient())
        )

        try await viewModel.refresh()

        let details = try XCTUnwrap(viewModel.items.first?.reviewDetails)
        XCTAssertEqual(details.from, "me@example.com")
        XCTAssertEqual(details.to, ["alice@example.com"])
        XCTAssertEqual(details.bcc, ["finance@example.com"])
        XCTAssertEqual(details.bodyPlain, draft.bodyPlain)
        XCTAssertEqual(details.requestReason, "Please send this")
        XCTAssertEqual(details.riskScore, request.riskScore)
        XCTAssertEqual(
            details.attachments,
            [ApprovalQueueAttachmentModel(id: "att_wire", filename: "wire.txt", mimeType: "text/plain", byteCount: 12)]
        )
    }

    private func highRiskDraft() -> Draft {
        Draft(
            id: DraftID("drf_high_risk"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [EmailAddress("finance@example.com")],
            subject: "Quarterly wire details",
            bodyPlain: "Please review the attachment at http://billing.example.test before sending.",
            createdBy: "codex",
            aiGenerated: true,
            sourceThreadID: nil,
            attachments: [
                DraftAttachment(
                    id: "att_wire",
                    filename: "wire.txt",
                    mimeType: "text/plain",
                    data: Data("wire details".utf8)
                )
            ]
        )
    }
}

private struct PossiblySentApprovalQueue: ApprovalQueueHandling {
    func items() throws -> [ApprovalQueueItemModel] {
        [ApprovalQueueItemModel(id: "srq_1", agentName: "Agent", subject: "Offer", recipientSummary: "a@example.com",
                                riskFlags: [], hasAttachments: false, status: "delivery_uncertain")]
    }
    func approve(requestID: String, username: String, password: String) async throws {
        throw PlainpostError.validationFailed("SMTP delivery may have crossed the server acceptance boundary. Review before retrying.")
    }
    func deny(requestID: String, reason: String?) async throws {}
}

private struct PreviewApprovalQueueForTests: ApprovalQueueHandling {
    func items() throws -> [ApprovalQueueItemModel] { [] }
    func approve(requestID: String, username: String, password: String) async throws {}
    func deny(requestID: String, reason: String?) async throws {}
}

/// Fails its first `items()` call and succeeds on every call after, so a test can watch one
/// view model's `refreshFailure` actually clear, not just compare it to a never-failed instance.
private final class FlakyThenHealthyApprovalQueueForTests: ApprovalQueueHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func items() throws -> [ApprovalQueueItemModel] {
        let count = lock.withLock { () -> Int in
            callCount += 1
            return callCount
        }
        if count == 1 {
            throw PlainpostError.notFound("fixture failure")
        }
        return []
    }
    func approve(requestID: String, username: String, password: String) async throws {}
    func deny(requestID: String, reason: String?) async throws {}
}

private struct FailingApprovalQueueForTests: ApprovalQueueHandling {
    func items() throws -> [ApprovalQueueItemModel] {
        throw PlainpostError.notFound("fixture failure")
    }

    func approve(requestID: String, username: String, password: String) async throws {
        throw PlainpostError.notFound("fixture failure")
    }

    func deny(requestID: String, reason: String?) async throws {
        throw PlainpostError.notFound("fixture failure")
    }
}

private struct CompletedActionWithFailingRefreshQueue: ApprovalQueueHandling {
    func items() throws -> [ApprovalQueueItemModel] {
        throw PlainpostError.notFound("projection temporarily unavailable")
    }

    func approve(requestID: String, username: String, password: String) async throws {}
    func deny(requestID: String, reason: String?) async throws {}
}

private final class RecordingSMTPClient: SMTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(username: String, password: String, from: EmailAddress, to: [EmailAddress], data: String)] = []

    var sentMessages: [(username: String, password: String, from: EmailAddress, to: [EmailAddress], data: String)] {
        lock.withLock { messages }
    }

    func send(username: String, password: String, from: EmailAddress, to: [EmailAddress], data: String) async throws {
        lock.withLock {
            messages.append((username, password, from, to, data))
        }
    }
}

private final class RecordingApprovalAuthenticator: LocalApprovalAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Void, Error>
    private var recordedReasons: [String] = []

    init(result: Result<Void, Error>) {
        self.result = result
    }

    var reasons: [String] {
        lock.withLock { recordedReasons }
    }

    func authenticate(reason: String) async throws {
        lock.withLock {
            recordedReasons.append(reason)
        }
        try result.get()
    }
}

/// Cancellation happens synchronously at the admitted dependency's return boundary;
/// it deliberately does not pretend that cancellation interrupts the underlying read.
private struct CancellingReadApprovalQueue: ApprovalQueueHandling {
    let fails: Bool
    func items() throws -> [ApprovalQueueItemModel] {
        withUnsafeCurrentTask { $0?.cancel() }
        if fails { throw PlainpostError.notFound("cancelled fixture read") }
        return []
    }
    func approve(requestID: String, username: String, password: String) async throws {}
    func deny(requestID: String, reason: String?) async throws {}
}
