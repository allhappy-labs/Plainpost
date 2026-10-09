import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostSecrets
import PlainpostTestSupport
import PlainpostRuntimeTestSupport
@testable import PlainpostUI

final class PlainpostEndToEndWorkflowTests: XCTestCase {
    @MainActor
    func testAccountSetupUnlocksTabsAndSupportsApprovalSendAuditWorkflow() async throws {
        let imapPassword = "e2e-imap-secret"
        let smtpPassword = "e2e-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(username: "me@example.com", password: smtpPassword)
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-e2e-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let isolation = RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: dbURL,
            keychainService: "PlainpostE2ETests.\(UUID().uuidString)"
        )
        let setupRuntime = try PlainpostAppRuntime(
            configuration: isolation.configuration,
            notificationScheduler: NoopLocalNotificationScheduler()
        )

        XCTAssertTrue(setupRuntime.makeInboxViewModel().requiresAccountSetup)
        XCTAssertEqual(setupRuntime.makeAccountSetupViewModel().status, .idle)

        let setup = setupRuntime.makeAccountSetupViewModel()
        setup.displayName = "Personal"
        setup.email = "me@example.com"
        setup.imapHost = "127.0.0.1"
        setup.imapPort = "\(imap.port)"
        setup.smtpHost = "127.0.0.1"
        setup.smtpPort = "\(smtp.port)"
        setup.username = "me@example.com"
        setup.imapPassword = imapPassword
        setup.smtpPassword = smtpPassword
        try await setup.submit()

        XCTAssertEqual(setup.status, .connected(accountID: "acc_me_example_com"))
        await setupRuntime.shutdown()
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: dbURL,
                serviceClient: isolation.serviceClient,
                selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: isolation.runtimeDependencies
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        XCTAssertFalse(runtime.makeInboxViewModel().requiresAccountSetup)
        XCTAssertEqual(runtime.makeAccountSetupViewModel().status, .connected(accountID: "acc_me_example_com"))

        let destinations = PlainpostDestination.primaryDestinations
        XCTAssertTrue(destinations.contains(.smartInbox))
        XCTAssertTrue(destinations.contains(.approvalQueue))
        XCTAssertTrue(destinations.contains(.settings))
        XCTAssertTrue(destinations.contains(.aiIndexStatus))
        XCTAssertFalse(destinations.filter(\.usesMailboxList).isEmpty)

        _ = try runtime.store.commitIncomingMessage(
            MessageSummary(
                id: MessageID("msg_e2e_1"),
                threadID: ThreadID("thr_e2e"),
                from: EmailAddress("alice@example.com"),
                subject: "E2E inbound",
                preview: "Message available after account setup",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false
            ),
            metadata: IncomingMessageSearchMetadata(
                to: [EmailAddress("me@example.com")],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: ["<msg-e2e-1@example.com>"]
            ),
            accountID: AccountID("acc_me_example_com"),
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )
        let inbox = runtime.makeInboxViewModel()
        XCTAssertEqual(Set(inbox.classicRows.map(\.subject)), Set(["E2E inbound", "Availability"]))
        XCTAssertEqual(inbox.smartCards.flatMap(\.messages).count, 2)

        let agentDraft = try runtime.store.createDraft(
            Draft(
                id: DraftID("drf_e2e_agent_request"),
                accountID: AccountID("acc_me_example_com"),
                from: EmailAddress("me@example.com"),
                to: [EmailAddress("alice@example.com")],
                cc: [],
                bcc: [],
                subject: "E2E approved send",
                bodyPlain: "Approved by the end-to-end workflow.",
                createdBy: PlainpostFixtures.codexActor.id,
                aiGenerated: true,
                sourceThreadID: nil
            ),
            actor: PlainpostFixtures.codexActor
        )
        let requestID = try runtime.store.requestSend(
            draftID: agentDraft.id,
            actor: PlainpostFixtures.codexActor,
            reason: "E2E approval"
        ).id.rawValue

        let approval = runtime.makeApprovalQueueViewModel()
        try await approval.refresh()
        XCTAssertEqual(approval.items.map(\.id), [requestID])
        XCTAssertEqual(approval.items.first?.status, "pending")

        try await approval.approve(
            requestID: requestID,
            username: "ignored@example.com",
            password: "ignored-password"
        )

        let acceptedMessages = await smtp.acceptedMessages()
        XCTAssertEqual(acceptedMessages.count, 2)
        let delivered = try XCTUnwrap(acceptedMessages.last)
        XCTAssertEqual(delivered.mailFrom, EmailAddress("me@example.com"))
        XCTAssertEqual(delivered.recipients, [EmailAddress("alice@example.com")])
        XCTAssertTrue(delivered.data.contains("Subject: E2E approved send"))
        XCTAssertTrue(delivered.data.contains("Approved by the end-to-end workflow."))

        XCTAssertEqual(try runtime.store.sendRequest(id: SendRequestID(requestID)).status, .sent)
        XCTAssertEqual(runtime.store.messages.first(where: { $0.mailboxPath == "Sent" })?.subject, "E2E approved send")

        let audit = runtime.makeAuditLogViewModel()
        try await audit.refresh()
        XCTAssertTrue(audit.rows.contains { $0.action == "draft.create" })
        XCTAssertTrue(audit.rows.contains { $0.action == "send.approved" })
        XCTAssertTrue(audit.rows.contains { $0.action == "message.sent_copy" })
    }
}
