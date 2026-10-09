import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class SmartInboxBatchServiceTests: XCTestCase {
    func testArchiveReadArchivesNewsletterThroughIMAPAndMarksLocalSeen() async throws {
        let newsletter = MessageSummary(
            id: MessageID("msg_newsletter_1"),
            threadID: nil,
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter
        )
        let store = InMemoryMailStore(
            accounts: [PlainpostFixtures.personalAccount],
            mailboxes: [PlainpostFixtures.inboxMailbox],
            messages: [newsletter]
        )
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: newsletter,
            extraMailboxes: [.init(path: "Archive")]
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let service = SmartInboxBatchService(store: store, imapClient: client)

        let result = try await service.run(
            SmartInboxBatchRequest(
                category: .newsletter,
                action: .archiveRead,
                messageUIDs: [newsletter.id: 1],
                archiveMailbox: "Archive"
            ),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(result.category, .newsletter)
        XCTAssertEqual(result.action, .archiveRead)
        XCTAssertEqual(result.affectedMessageIDs, [newsletter.id])
        XCTAssertEqual(result.affectedCount, 1)
        XCTAssertEqual(result.archiveMailbox, "Archive")
        XCTAssertEqual(store.messages.first?.isSeen, true)
        XCTAssertEqual(server.archivedUIDs, [1])
        XCTAssertEqual(server.deletedUIDs, [1])
        XCTAssertEqual(server.expungeCount, 1)
    }

    func testArchiveReadOnGmailMovesToAllMail() async throws {
        let newsletter = MessageSummary(
            id: MessageID("msg_newsletter_gmail"),
            threadID: nil,
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter
        )
        let store = InMemoryMailStore(
            accounts: [PlainpostFixtures.personalAccount],
            mailboxes: [PlainpostFixtures.inboxMailbox],
            messages: [newsletter]
        )
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: newsletter,
            peer: LocalIMAPPeerResponse(
                capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"],
                mailboxes: [
                    .init(path: "INBOX", specialUse: "\\Inbox"), .init(path: "[Gmail]/All Mail", specialUse: "\\All"),
                    .init(path: "[Gmail]/Trash", specialUse: "\\Trash"),
                ],
                uidValidity: 1, messageUID: 1,
                messageData: Data("Subject: news\r\n\r\nbody".utf8)
            )
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let service = SmartInboxBatchService(store: store, imapClient: client)

        let result = try await service.run(
            SmartInboxBatchRequest(category: .newsletter, action: .archiveRead, messageUIDs: [newsletter.id: 1]),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(result.archiveMailbox, "[Gmail]/All Mail")
        XCTAssertEqual(server.uidCommands, [#"MOVE 1 "[Gmail]/All Mail""#])
        XCTAssertEqual(store.messages.first?.isSeen, true)
    }

    func testArchiveReadRejectsRestrictedActorBeforeIMAPArchive() async throws {
        let newsletter = MessageSummary(
            id: MessageID("msg_newsletter_1"),
            threadID: nil,
            from: EmailAddress("newsletter@example.com"),
            subject: "Weekly Product Updates",
            preview: "This week in product news.",
            smartCategory: .newsletter
        )
        let store = InMemoryMailStore(messages: [newsletter])
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: newsletter
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let service = SmartInboxBatchService(store: store, imapClient: client)
        let restrictedActor = Actor(
            id: "restricted",
            kind: .cli,
            displayName: "Restricted",
            permissions: .agentRequested(
                readBody: true,
                createDrafts: true,
                requestSend: true,
                markSeen: false
            )
        )

        do {
            _ = try await service.run(
                SmartInboxBatchRequest(
                    category: .newsletter,
                    action: .archiveRead,
                    messageUIDs: [newsletter.id: 1],
                    archiveMailbox: "Archive"
                ),
                actor: restrictedActor
            )
            XCTFail("Expected permission denial")
        } catch {
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to change seen state."))
        }

        XCTAssertEqual(store.messages.first?.isSeen, false)
        XCTAssertEqual(server.archivedUIDs, [])
        XCTAssertEqual(server.deletedUIDs, [])
        XCTAssertEqual(server.expungeCount, 0)
    }
}
