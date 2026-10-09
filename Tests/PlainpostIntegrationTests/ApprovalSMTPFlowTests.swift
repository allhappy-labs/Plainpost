import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class ApprovalSMTPFlowTests: XCTestCase {
    func testGuiApprovalSendsDraftThroughLocalSMTPMarksRequestSentAndRecordsSentCopy() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "User asked me to reply")
        let service = ApprovalSMTPService(store: store, smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port))

        try await service.approveAndSend(
            requestID: request.id,
            actor: PlainpostFixtures.guiUser,
            configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret")
        )

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(accepted[0].data.contains("Subject: Re: Availability"))
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertEqual(try store.sendRequest(id: request.id).approvedDraftHash, draft.contentHash)
        XCTAssertEqual(store.mailboxes.first(where: { $0.path == "Sent" })?.specialUse, "\\Sent")
        let sentMessage = try XCTUnwrap(store.messages.first(where: { $0.id == MessageID("msg_sent_\(request.id.rawValue)") }))
        XCTAssertEqual(sentMessage.threadID, draft.sourceThreadID)
        XCTAssertEqual(sentMessage.from, draft.from)
        XCTAssertEqual(sentMessage.subject, draft.subject)
        XCTAssertEqual(sentMessage.preview, draft.bodyPlain)
        XCTAssertEqual(sentMessage.labels, ["Sent"])
        XCTAssertTrue(sentMessage.isSeen)
        XCTAssertTrue(store.auditEntries.contains { entry in
            entry.action == "message.sent_copy" && entry.targetID == sentMessage.id.rawValue
        })
        XCTAssertFalse(store.auditEntries.map(\.targetID).joined(separator: " ").contains("secret"))
    }

    func testGuiApprovalAppendsRemoteSentCopyAfterSMTPDelivery() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await smtp.start()
        try await imap.start()
        defer {
            smtp.stop()
            imap.stop()
        }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "User asked me to reply")
        let service = ApprovalSMTPService(
            store: store,
            smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: smtp.port),
            sentAppendClient: PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        )

        try await service.approveAndSend(
            requestID: request.id,
            actor: PlainpostFixtures.guiUser,
            configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret"),
            sentAppend: RemoteSentAppendConfiguration(
                username: "me@example.com",
                password: "imap-secret",
                mailbox: "Sent"
            )
        )

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        let appended = imap.appendedMessages
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended[0].mailbox, "Sent")
        XCTAssertEqual(appended[0].flags, ["\\Seen"])
        XCTAssertTrue(appended[0].data.contains("Subject: Re: Availability"))
        XCTAssertTrue(appended[0].data.contains("Tuesday works for me."))
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertTrue(store.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })
    }

    func testRemoteSentAppendFailureDoesNotUndoAcceptedSMTPDelivery() async throws {
        let smtp = LocalSMTPServer(username: "me@example.com", password: "secret")
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await smtp.start()
        try await imap.start()
        defer {
            smtp.stop()
            imap.stop()
        }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: "User asked me to reply")
        let service = ApprovalSMTPService(
            store: store,
            smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: smtp.port),
            sentAppendClient: PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        )

        try await service.approveAndSend(
            requestID: request.id,
            actor: PlainpostFixtures.guiUser,
            configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret"),
            sentAppend: RemoteSentAppendConfiguration(
                username: "me@example.com",
                password: "wrong-imap-secret",
                mailbox: "Sent"
            )
        )

        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(imap.appendedMessages.isEmpty)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertTrue(store.messages.contains { $0.id == MessageID("msg_sent_\(request.id.rawValue)") })
        XCTAssertTrue(store.auditEntries.contains { entry in
            entry.action == "send.remote_sent_append_failed"
                && entry.targetType == "send_request"
                && entry.targetID == request.id.rawValue
        })
        XCTAssertFalse(store.auditEntries.map(\.targetID).joined(separator: " ").contains("wrong-imap-secret"))
    }

    func testDraftHashMismatchBlocksSMTPDelivery() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        _ = try store.updateDraft(
            id: draft.id,
            patch: DraftPatch(bodyPlain: "Changed after request."),
            actor: PlainpostFixtures.codexActor
        )
        let service = ApprovalSMTPService(store: store, smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port))

        do {
            try await service.approveAndSend(
                requestID: request.id,
                actor: PlainpostFixtures.guiUser,
                configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret")
            )
            XCTFail("Expected draft hash mismatch")
        } catch {
            XCTAssertEqual(error as? PlainpostError, .validationFailed("Draft changed after send request was created."))
        }

        let accepted = await server.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .pending)
    }

    func testDenySendRequestDoesNotSendSMTP() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let service = ApprovalSMTPService(store: store, smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port))

        try service.deny(requestID: request.id, actor: PlainpostFixtures.guiUser, reason: "Not ready")

        let accepted = await server.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .denied)
    }

    func testSMTPRecipientRejectionMarksRequestFailed() async throws {
        let rejected = EmailAddress("alice@example.com")
        let server = LocalSMTPServer(username: "me@example.com", password: "secret", rejectedRecipients: [rejected])
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let service = ApprovalSMTPService(store: store, smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port))

        do {
            try await service.approveAndSend(
                requestID: request.id,
                actor: PlainpostFixtures.guiUser,
                configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret")
            )
            XCTFail("Expected SMTP rejection")
        } catch {
            XCTAssertEqual(error as? SMTPClientError, .recipientRejected(rejected, code: 550, message: "Recipient rejected"))
        }

        let accepted = await server.acceptedMessages()
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .failed)
    }

    func testAcceptedSMTPWithLocalSentPersistenceFailureMarksRequestDeliveryUncertain() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-post-smtp-persistence-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(
            draftID: draft.id,
            actor: PlainpostFixtures.codexActor,
            reason: nil
        )
        try await store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_search_fts")
        }
        let service = ApprovalSMTPService(
            store: store,
            smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
        )

        do {
            try await service.approveAndSend(
                requestID: request.id,
                actor: PlainpostFixtures.guiUser,
                configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret")
            )
            XCTFail("Expected local Sent persistence failure after SMTP acceptance.")
        } catch {
            XCTAssertEqual(error as? PostSMTPPersistenceError, .localPersistenceFailed)
            XCTAssertEqual(
                error.localizedDescription,
                "SMTP accepted the message, but its local Sent copy could not be persisted. Review delivery before retrying."
            )
            XCTAssertFalse(error.localizedDescription.contains("mail_search_fts"))
        }

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .deliveryUncertain)
    }

    func testConcurrentSQLiteApprovalsSendOnlyOnce() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-concurrent-approval-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let service = ApprovalSMTPService(
            store: store,
            smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
        )
        let concurrentService = UncheckedApprovalService(service)

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        try await concurrentService.service.approveAndSend(
                            requestID: request.id,
                            actor: PlainpostFixtures.guiUser,
                            configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret")
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        let acceptedMessages = await server.acceptedMessages()
        XCTAssertEqual(acceptedMessages.count, 1)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
        XCTAssertEqual(store.auditEntries.filter { $0.action == "send.sending" }.count, 1)
    }
}

private final class UncheckedApprovalService<Store: ApprovalSendStore>: @unchecked Sendable {
    let service: ApprovalSMTPService<Store>

    init(_ service: ApprovalSMTPService<Store>) {
        self.service = service
    }
}
