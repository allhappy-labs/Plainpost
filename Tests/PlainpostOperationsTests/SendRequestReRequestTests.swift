import Foundation
import Security
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
@testable import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostTestSupport

/// A draft has one send request ID (`srq_<draftID>`), so asking to send it
/// again replaces the earlier request. That must never reopen a request
/// that was approved, is sending, was sent or may have been sent, and a
/// replaced finished request's approval job must not absorb the new one.
final class SendRequestReRequestTests: XCTestCase {
    func testASentOrPossiblySentRequestIsNeverReopened() throws {
        for terminal in [SendRequestStatus.sent, .deliveryUncertain] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
            let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
            _ = try fixture.store.updateSendRequest(id: request.id, status: .approved, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
            _ = try fixture.store.updateSendRequest(id: request.id, status: .sending, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
            _ = try fixture.store.updateSendRequest(id: request.id, status: terminal, approvedBy: "local-user", approvedDraftHash: draft.contentHash)

            XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")) {
                XCTAssertEqual($0 as? PlainpostError, .validationFailed(
                    terminal == .sent ? SQLiteMailStore.sendRequestInProgressMessage : SQLiteMailStore.sendRequestPossiblySentMessage))
            }
            XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, terminal, "\(terminal) stays as it was")
        }
    }

    func testAnApprovedOrSendingRequestIsNeverReopened() throws {
        for state in [SendRequestStatus.approved, .sending] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
            let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
            _ = try fixture.store.updateSendRequest(id: request.id, status: .approved, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
            if state == .sending {
                _ = try fixture.store.updateSendRequest(id: request.id, status: .sending, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
            }
            XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again"))
            XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, state)
        }
    }

    func testAFailedSendRequestedAgainRunsANewApprovalAndSendsExactlyOnce() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try Fixture(smtpPort: Int(smtp.port))
        defer { fixture.cleanUp() }
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery]))
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let first = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")

        // No SMTP credential yet: the approved delivery job fails before SMTP.
        try? await client.approveSend(requestID: first.id, approvedBy: PlainpostFixtures.guiUser.id)
        XCTAssertNotEqual(try fixture.store.sendRequest(id: first.id).status, .sent)
        let firstAccepted = await smtp.acceptedMessages()
        XCTAssertEqual(firstAccepted.count, 0)

        try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
        let again = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.status, .pending)
        try await client.approveSend(requestID: again.id, approvedBy: PlainpostFixtures.guiUser.id)

        XCTAssertEqual(try fixture.store.sendRequest(id: again.id).status, .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1, "the new approval ran its own job, once")
        // A repeated approval of the sent request runs nothing.
        try? await client.approveSend(requestID: again.id, approvedBy: PlainpostFixtures.guiUser.id)
        let afterRepeat = await smtp.acceptedMessages()
        XCTAssertEqual(afterRepeat.count, 1)
    }

    func testReplacingAFailedRequestRetiresItsFinishedDeliveryJob() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
        let input = PlainpostApprovalDecisionInput(requestID: request.id, actorID: PlainpostFixtures.guiUser.id)
        let job = try fixture.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery, payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: 100, maxAttempts: 1, idempotencyKey: "approved-delivery:\(request.id.rawValue)"))
        _ = try fixture.store.updateSendRequest(id: request.id, status: .approved, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
        _ = try fixture.store.updateSendRequest(id: request.id, status: .failed, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
        let claimed = try XCTUnwrap(try fixture.store.claimNextJob(allowedKinds: [.approvedDelivery]))
        try fixture.store.failJob(id: claimed.id, leaseToken: try XCTUnwrap(claimed.leaseToken), code: "SMTP", message: "refused", retryAt: nil)

        _ = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")

        XCTAssertTrue(try fixture.store.job(id: job.id).idempotencyKey.hasPrefix("retired:"))
        let fresh = try fixture.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery, payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: 100, maxAttempts: 1, idempotencyKey: "approved-delivery:\(request.id.rawValue)"))
        XCTAssertNotEqual(fresh.id, job.id, "the new approval runs a job of its own")
    }

    func testAConcurrentDoubleApprovalSendsOnce() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try Fixture(smtpPort: Int(smtp.port))
        defer { fixture.cleanUp() }
        try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery]))
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Once")

        async let one: Void = client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)
        async let two: Void = client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)
        _ = try? await (one, two)

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .sent)
    }

    // MARK: - Fix round 4

    func testAnAmbiguousSMTPFailureIsPossiblySentAndNeverSentAgain() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret", disconnectAfterData: true)
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try Fixture(smtpPort: Int(smtp.port))
        defer { fixture.cleanUp() }
        try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery]))
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Once")

        try? await client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)

        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .deliveryUncertain,
                       "a dropped connection after DATA may have delivered it")
        XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed(SQLiteMailStore.sendRequestPossiblySentMessage))
        }
        try? await client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1, "nothing is sent a second time")
    }

    func testAPossiblySentJobBlocksARequestEvenAfterItsRequestReadFailedOrItsKeyWasRetired() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
        let job = try enqueueApproval(fixture, request.id)
        _ = try fixture.store.updateSendRequest(id: request.id, status: .approved, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
        _ = try fixture.store.updateSendRequest(id: request.id, status: .failed, approvedBy: "local-user", approvedDraftHash: draft.contentHash)
        let claimed = try XCTUnwrap(try fixture.store.claimNextJob(allowedKinds: [.approvedDelivery]))
        try fixture.store.markDeliveryUncertain(id: claimed.id, leaseToken: try XCTUnwrap(claimed.leaseToken), message: "lost")
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .failed, "the request reads failed")

        XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed(SQLiteMailStore.sendRequestPossiblySentMessage))
        }
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .deliveryUncertain)
        XCTAssertFalse(try fixture.store.job(id: job.id).idempotencyKey.hasPrefix("retired:"), "never retired")

        try fixture.store.databasePool.write { database in
            try database.execute(sql: "UPDATE durable_jobs SET idempotency_key = 'retired:x:' || idempotency_key WHERE id = ?",
                                 arguments: [job.id])
        }
        XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again"),
                             "found by its payload, not its key")
    }

    func testARequestWithAnApprovalStillQueuedOrRunningIsNotReplaced() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try Fixture(smtpPort: Int(smtp.port))
        defer { fixture.cleanUp() }
        try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
        _ = try enqueueApproval(fixture, request.id)   // approved, queued

        _ = try fixture.store.updateDraft(id: draft.id, patch: DraftPatch(bodyPlain: "Edited after approval"),
                                          actor: PlainpostFixtures.codexActor)
        XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Edited")) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed(SQLiteMailStore.sendRequestApprovalRunningMessage))
        }
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).requestedDraftHash, draft.contentHash,
                       "the earlier approval keeps the content it approved")

        // The running-job window: a request reading `failed` while its job runs.
        let claimed = try XCTUnwrap(try fixture.store.claimNextJob(allowedKinds: [.approvedDelivery]))
        XCTAssertEqual(claimed.state, .running)
        XCTAssertThrowsError(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Edited"))

        // The queued approval cannot send the edited content either.
        try fixture.store.releaseJobLeaseForRetry(id: claimed.id, leaseToken: try XCTUnwrap(claimed.leaseToken))
        let runtime = LocalOperationRuntime(store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery])
        _ = try? await runtime.processNextJob()
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 0)
    }

    func testASecondDenialAfterARequestAgainDeniesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.denySend]))
        let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")
        try await client.denySend(requestID: request.id, deniedBy: PlainpostFixtures.guiUser.id)
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .denied)

        _ = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again")
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .pending)
        try await client.denySend(requestID: request.id, deniedBy: PlainpostFixtures.guiUser.id)

        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .denied)
    }

    func testABrowserRetryNeverResendsAMessageTheUserAlreadySent() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await smtp.start()
        defer { smtp.stop() }
        let fixture = try Fixture(smtpPort: Int(smtp.port))
        defer { fixture.cleanUp() }
        try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
        let browser = Actor(id: "browser-extension-user", kind: .user, displayName: "Plainpost Browser Extension", permissions: .guiUser)
        let draft = try fixture.store.createDraft(
            Draft(id: DraftID("drf_browser_reply"), accountID: PlainpostFixtures.personalAccount.id,
                  from: PlainpostFixtures.personalAccount.email, to: [EmailAddress("alice@example.com")], cc: [], bcc: [],
                  subject: "Re: hi", bodyPlain: "Browser reply", createdBy: browser.id, aiGenerated: false, sourceThreadID: nil),
            actor: browser)
        let client = LocalOperationClient(runtime: LocalOperationRuntime(
            store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery]))
        let request = try fixture.store.requestSend(draftID: draft.id, actor: browser, reason: "GUI approval")
        try await client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .sent)

        XCTAssertThrowsError(try fixture.store.authorizeAndEnqueueApprovedDelivery(
            draftID: draft.id, expectedHash: draft.contentHash, actor: browser,
            reason: "Direct reply authorized in Plainpost browser extension",
            idempotencyKey: "browser-send:retry-with-a-new-key", requiredDraftIDPrefix: "drf_browser_")) {
            XCTAssertEqual($0 as? PlainpostError, .validationFailed(SQLiteMailStore.sendRequestInProgressMessage))
        }
        XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    // MARK: - Fix round 5: the SMTP stage decides

    func testARefusalBeforeTheMessageWasSentFailsTheRequestAndItCanBeAskedAgain() async throws {
        let recipient = try XCTUnwrap(PlainpostFixtures.replyDraft.to.first)
        let servers: [(String, LocalSMTPServer?)] = [
            ("553 at RCPT", LocalSMTPServer(username: "me@example.com", password: "secret",
                                            recipientReplies: [recipient: "553 5.1.3 The recipient address is not valid"])),
            ("554 at MAIL FROM", LocalSMTPServer(username: "me@example.com", password: "secret",
                                                 mailFromReply: "554 5.7.1 Sender rejected")),
            ("dropped before MAIL", LocalSMTPServer(username: "me@example.com", password: "secret", disconnectAtMailFrom: true)),
            ("connection refused", nil),
        ]
        for (label, server) in servers {
            try await server?.start()
            defer { server?.stop() }
            let fixture = try Fixture(smtpPort: server.map { Int($0.port) } ?? 1)
            defer { fixture.cleanUp() }
            try await fixture.credentials.store(Data("secret".utf8), for: fixture.smtpKey)
            let client = LocalOperationClient(runtime: LocalOperationRuntime(
                store: fixture.store, credentials: fixture.credentials, allowedJobKinds: [.approvedDelivery]))
            let draft = try fixture.store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
            let request = try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "First")

            try? await client.approveSend(requestID: request.id, approvedBy: PlainpostFixtures.guiUser.id)

            XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .failed, "\(label): nothing was sent")
            XCTAssertNoThrow(try fixture.store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "Again"),
                             "\(label): asking again is allowed")
            XCTAssertEqual(try fixture.store.sendRequest(id: request.id).status, .pending)
            let accepted = await server?.acceptedMessages() ?? []
            XCTAssertEqual(accepted.count, 0)
        }
    }

    func testTheSMTPClientReportsPreDataFailuresAsRefusalsAndPostDataLossAsUncertain() async throws {
        let recipient = EmailAddress("alice@example.com")
        let refusing = LocalSMTPServer(username: "me@example.com", password: "secret",
                                       recipientReplies: [recipient: "553 5.1.3 Bad recipient address"])
        let dropping = LocalSMTPServer(username: "me@example.com", password: "secret", disconnectAfterData: true)
        try await refusing.start()
        try await dropping.start()
        defer {
            refusing.stop()
            dropping.stop()
        }
        func send(_ port: Int) async -> Error? {
            do {
                try await PlaintextSMTPClient(host: "127.0.0.1", port: port).send(
                    username: "me@example.com", password: "secret", from: EmailAddress("me@example.com"),
                    to: [recipient], data: "Subject: stage\r\n\r\nbody")
                return nil
            } catch { return error }
        }
        let refused = await send(Int(refusing.port))
        XCTAssertEqual(refused as? SMTPClientError, .refusedBeforeData("553 5.1.3 Bad recipient address"))
        XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(try XCTUnwrap(refused)))
        let unreachable = await send(1)
        XCTAssertEqual(unreachable as? SMTPClientError, .unreachableBeforeData)
        XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(try XCTUnwrap(unreachable)))
        let lost = await send(Int(dropping.port))
        XCTAssertEqual(lost as? SMTPClientError, .deliveryUncertain)
        XCTAssertTrue(SMTPDeliveryAmbiguity.isAmbiguous(try XCTUnwrap(lost)))
    }

    func testACompletedBrowserJobIsNoReceiptOnceItsRequestSettledOtherwise() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let browser = Actor(id: "browser-extension-user", kind: .user, displayName: "Plainpost Browser Extension", permissions: .guiUser)
        let draft = try fixture.store.createDraft(
            Draft(id: DraftID("drf_browser_settled"), accountID: PlainpostFixtures.personalAccount.id,
                  from: PlainpostFixtures.personalAccount.email, to: [EmailAddress("alice@example.com")], cc: [], bcc: [],
                  subject: "Re: hi", bodyPlain: "Browser reply", createdBy: browser.id, aiGenerated: false, sourceThreadID: nil),
            actor: browser)
        func authorize(_ key: String) throws -> PlainpostApprovedDeliveryAuthorization {
            try fixture.store.authorizeAndEnqueueApprovedDelivery(
                draftID: draft.id, expectedHash: draft.contentHash, actor: browser,
                reason: "Direct reply authorized in Plainpost browser extension",
                idempotencyKey: key, requiredDraftIDPrefix: "drf_browser_")
        }
        let first = try authorize("browser-send:first")
        // Its job completed, but its request settled `failed` (a routed send
        // the Sync Node later rejected).
        let claimed = try XCTUnwrap(try fixture.store.claimNextJob(allowedKinds: [.approvedDelivery]))
        try fixture.store.completeJob(id: claimed.id, leaseToken: try XCTUnwrap(claimed.leaseToken), resultArtifactID: nil)
        if try fixture.store.sendRequest(id: first.request.id).status == .pending {
            _ = try fixture.store.updateSendRequest(id: first.request.id, status: .approved, approvedBy: browser.id, approvedDraftHash: draft.contentHash)
        }
        _ = try fixture.store.updateSendRequest(id: first.request.id, status: .failed, approvedBy: browser.id, approvedDraftHash: draft.contentHash)

        let retry = try authorize("browser-send:second")

        XCTAssertNotEqual(retry.job.id, first.job.id, "the old failed attempt is not handed back as a receipt")
        XCTAssertEqual(retry.job.state, .queued)
        XCTAssertNotEqual(try fixture.store.sendRequest(id: first.request.id).status, .failed, "a new request replaced it")
    }

    func testThePayloadScanUsesThePartialExpressionIndex() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let plan = try fixture.store.databasePool.read { database in
            try Row.fetchAll(database, sql: """
                EXPLAIN QUERY PLAN
                SELECT state FROM durable_jobs
                WHERE kind = 'approved-delivery' AND json_extract(payload_json, '$.requestID') = ?
                """, arguments: ["srq_x"]).map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains(SQLiteMailStore.approvedDeliveryRequestIndex) }, "\(plan)")
    }

    func testTLSClientsReportAClosedPortAsUnreachableBeforeData() async throws {
        let clients: [(String, any SMTPClientProtocol)] = [
            ("implicit TLS", SecureSMTPClient(host: "127.0.0.1", port: 1, certificateValidation: .disabledForLocalTesting)),
            ("STARTTLS", StartTLSSMTPClient(host: "127.0.0.1", port: 1, certificateValidation: .disabledForLocalTesting)),
        ]
        for (label, client) in clients {
            do {
                try await client.send(username: "me@example.com", password: "secret", from: EmailAddress("me@example.com"),
                                      to: [EmailAddress("alice@example.com")], data: "Subject: x\r\n\r\nbody")
                XCTFail("\(label): expected a failure")
            } catch {
                XCTAssertEqual(error as? SMTPClientError, .unreachableBeforeData, "\(label): \(error)")
                XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(error))
            }
        }
    }

    func testEverySMTPClientTimesOutOnAServerThatAcceptsAndStaysSilent() async throws {
        let server = try SilentTCPServer(behavior: .holdOpen)
        defer { server.stop() }
        let port = Int(server.port)
        var plaintext = PlaintextSMTPClient(host: "127.0.0.1", port: port)
        plaintext.readTimeout = 1
        var implicitTLS = SecureSMTPClient(host: "127.0.0.1", port: port, certificateValidation: .disabledForLocalTesting)
        implicitTLS.readTimeout = 1
        var startTLS = StartTLSSMTPClient(host: "127.0.0.1", port: port, certificateValidation: .disabledForLocalTesting)
        startTLS.readTimeout = 1
        let clients: [(String, any SMTPClientProtocol)] = [
            ("plaintext", plaintext), ("implicit TLS", implicitTLS), ("STARTTLS", startTLS),
        ]
        for (label, client) in clients {
            let outcome = LockedSMTPSendOutcome()
            let started = ContinuousClock.now
            Task.detached {
                do {
                    try await client.send(username: "me@example.com", password: "secret", from: EmailAddress("me@example.com"),
                                          to: [EmailAddress("alice@example.com")], data: "Subject: x\r\n\r\nbody")
                    outcome.set(nil)
                } catch {
                    outcome.set(error)
                }
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while !outcome.finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard outcome.finished else {
                XCTFail("\(label): a silent server hung the send")
                continue
            }
            XCTAssertEqual(outcome.error as? SMTPClientError, .unreachableBeforeData, "\(label): \(String(describing: outcome.error))")
            XCTAssertLessThan(started.duration(to: .now), .seconds(10), "\(label): the read timeout applies from the greeting")
        }
    }

    func testStreamErrorsAreClassedByDomain() {
        XCTAssertEqual(smtpStreamErrorClass(domain: NSPOSIXErrorDomain, code: 61), .connectionFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: kCFErrorDomainCFNetwork as String, code: 2), .connectionFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: -9807), .tlsFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: kCFErrorDomainCFNetwork as String, code: -9813), .tlsFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: NSURLErrorDomain, code: -1202), .tlsFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: "SomethingElse", code: 1), .tlsFailed)
        XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(MailAuthenticationError.rejected), "OAuth refusals never reached SMTP")
        XCTAssertFalse(SMTPDeliveryAmbiguity.isAmbiguous(MailAuthenticationError.temporarilyRefused))
    }

    func testAConnectionDropDuringAuthIsUnreachableAndARefusedSignInIsAnAuthenticationFailure() async throws {
        let dropping = LocalSMTPServer(username: "me@example.com", password: "secret", disconnectAtAuth: true)
        let refusing = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await dropping.start()
        try await refusing.start()
        defer {
            dropping.stop()
            refusing.stop()
        }
        func send(_ port: Int, password: String) async -> Error? {
            do {
                try await PlaintextSMTPClient(host: "127.0.0.1", port: port).send(
                    username: "me@example.com", password: password, from: EmailAddress("me@example.com"),
                    to: [EmailAddress("alice@example.com")], data: "Subject: auth\r\n\r\nbody")
                return nil
            } catch { return error }
        }
        let dropped = await send(Int(dropping.port), password: "secret")
        XCTAssertEqual(dropped as? SMTPClientError, .unreachableBeforeData)
        let refused = await send(Int(refusing.port), password: "wrong")
        XCTAssertEqual(refused as? SMTPClientError, .authenticationFailed, "a 535 reply is a real sign-in refusal")
    }

    func testAnUnknownOSStatusStaysATLSFailure() {
        XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: Int(errSecNotTrusted)), .tlsFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: Int(errSecCertificateExpired)), .tlsFailed)
        XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: -1), .tlsFailed)
    }

    func testATemporaryAuthPlainRefusalIsATemporarySignInRefusal() async throws {
        let throttling = LocalSMTPServer(username: "me@example.com", password: "secret",
                                         authReply: "454 4.7.0 Too many login attempts, try again later")
        try await throttling.start()
        defer { throttling.stop() }
        do {
            try await PlaintextSMTPClient(host: "127.0.0.1", port: Int(throttling.port)).send(
                username: "me@example.com", password: "secret", from: EmailAddress("me@example.com"),
                to: [EmailAddress("alice@example.com")], data: "Subject: auth\r\n\r\nbody")
            XCTFail("a 454 reply to AUTH must not be a delivery")
        } catch {
            XCTAssertEqual(error as? MailAuthenticationError, .temporarilyRefused,
                           "a 4xx reply to AUTH PLAIN is temporary, not a credential refusal")
        }
    }

    func testAnAbortiveTLSCloseAfterTheHandshakeIsTheNetwork() {
        // errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify.
        for code in [-9805, -9806, -9816] {
            XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: code, handshakeCompleted: true),
                           .connectionFailed, "\(code) after the handshake is a dropped connection")
            XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: code, handshakeCompleted: false),
                           .tlsFailed, "\(code) during the handshake stays a TLS failure")
        }
        // Certificate and handshake failures stay TLS even after a handshake.
        for code in [-9807, -9813, -9824, Int(errSecNotTrusted)] {
            XCTAssertEqual(smtpStreamErrorClass(domain: NSOSStatusErrorDomain, code: code, handshakeCompleted: true), .tlsFailed)
        }
        XCTAssertThrowsError(try smtpBeforeData { throw smtpStreamErrorClass(
            domain: NSOSStatusErrorDomain, code: -9806, handshakeCompleted: true) }) { error in
            XCTAssertEqual(error as? SMTPClientError, .unreachableBeforeData)
        }
    }

    private func enqueueApproval(_ fixture: Fixture, _ requestID: SendRequestID) throws -> PlainpostDurableJob {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: PlainpostFixtures.guiUser.id)
        return try fixture.store.enqueueJob(PlainpostJobRequest(
            kind: .approvedDelivery, payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            priority: 100, maxAttempts: 1, idempotencyKey: "approved-delivery:\(requestID.rawValue)"))
    }

    private struct Fixture {
        let url: URL
        let store: SQLiteMailStore
        let credentials = InMemoryCredentialVault()
        let smtpKey: CredentialRecordKey

        init(smtpPort: Int = 1) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-rerequest-\(UUID().uuidString).sqlite")
            store = try SQLiteMailStore(path: url.path)
            try store.migrate()
            let account = Account(
                id: PlainpostFixtures.personalAccount.id, displayName: "Personal", email: PlainpostFixtures.personalAccount.email,
                imapHost: "127.0.0.1", smtpHost: "127.0.0.1", smtpPort: smtpPort
            )
            try store.cacheAccounts([account])
            smtpKey = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):smtp-password")
        }

        func cleanUp() { try? FileManager.default.removeItem(at: url) }
    }
}

private final class LockedSMTPSendOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var stored: Error?
    var finished: Bool { lock.withLock { done } }
    var error: Error? { lock.withLock { stored } }
    func set(_ error: Error?) { lock.withLock { done = true; stored = error } }
}
