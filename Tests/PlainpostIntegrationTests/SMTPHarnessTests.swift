import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class SMTPHarnessTests: XCTestCase {
    func testDisconnectAfterDataIsDeliveryUncertainAndNeverRetried() async throws {
        let server = LocalSMTPServer(
            username: "me@example.com",
            password: "secret",
            disconnectAfterData: true
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
        do {
            try await client.send(
                username: "me@example.com",
                password: "secret",
                from: EmailAddress("me@example.com"),
                to: [EmailAddress("alice@example.com")],
                data: "Subject: uncertain\r\n\r\nbody"
            )
            XCTFail("Expected the post-DATA disconnect to be delivery-uncertain")
        } catch {
            XCTAssertEqual(error as? SMTPClientError, .deliveryUncertain)
        }
        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    func testFinalAcceptanceSurvivesQuitAndSentAppendFailure() async throws {
        let server = LocalSMTPServer(
            username: "me@example.com",
            password: "secret",
            disconnectOnQuit: true
        )
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: "imap-secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        try await imap.start()
        defer {
            server.stop()
            imap.stop()
        }

        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
        let service = ApprovalSMTPService(
            store: store,
            smtpClient: PlaintextSMTPClient(host: "127.0.0.1", port: server.port),
            sentAppendClient: PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
        )

        try await service.approveAndSend(
            requestID: request.id,
            actor: PlainpostFixtures.guiUser,
            configuration: SMTPDeliveryConfiguration(username: "me@example.com", password: "secret"),
            sentAppend: RemoteSentAppendConfiguration(username: "me@example.com", password: "wrong-imap-secret", mailbox: "Sent")
        )

        let accepted = await server.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(imap.appendedMessages.isEmpty)
        XCTAssertEqual(try store.sendRequest(id: request.id).status, .sent)
    }

    func testSMTPDeliveryCapturesRenderedMessage() async throws {
        let server = LocalSMTPServer(username: "me@example.com", password: "secret")
        try await server.start()
        defer { server.stop() }

        let client = PlaintextSMTPClient(host: "127.0.0.1", port: server.port)
        let message = """
        From: me@example.com
        To: alice@example.com
        Subject: Re: Availability

        Tuesday works for me.
        """

        try await client.send(
            username: "me@example.com",
            password: "secret",
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            data: message
        )

        let acceptedMessages = await server.acceptedMessages()
        XCTAssertEqual(acceptedMessages.count, 1)
        XCTAssertEqual(acceptedMessages[0].mailFrom, EmailAddress("me@example.com"))
        XCTAssertEqual(acceptedMessages[0].recipients, [EmailAddress("alice@example.com")])
        XCTAssertTrue(acceptedMessages[0].data.contains("Subject: Re: Availability"))
        XCTAssertTrue(acceptedMessages[0].data.contains("Tuesday works for me."))
    }

    func testRecipientRejectionReturnsTypedSMTPError() async throws {
        let rejectedRecipient = EmailAddress("blocked@example.com")
        let server = LocalSMTPServer(
            username: "me@example.com",
            password: "secret",
            rejectedRecipients: [rejectedRecipient]
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextSMTPClient(host: "127.0.0.1", port: server.port)

        do {
            try await client.send(
                username: "me@example.com",
                password: "secret",
                from: EmailAddress("me@example.com"),
                to: [rejectedRecipient],
                data: "Subject: Blocked\n\nThis should not be accepted."
            )
            XCTFail("Expected recipient rejection")
        } catch {
            XCTAssertEqual(
                error as? SMTPClientError,
                .recipientRejected(rejectedRecipient, code: 550, message: "Recipient rejected")
            )
        }

        let acceptedMessages = await server.acceptedMessages()
        XCTAssertTrue(acceptedMessages.isEmpty)
    }
}
