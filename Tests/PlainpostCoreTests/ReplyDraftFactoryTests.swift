import XCTest
@testable import PlainpostCore

final class ReplyDraftFactoryTests: XCTestCase {
    private let browserActor = Actor(
        id: "browser-extension-user",
        kind: .user,
        displayName: "Plainpost Browser Extension",
        permissions: .guiUser
    )

    func testReplyFactoryPrefersReplyToAndPreservesThreadHeaders() throws {
        let source = fixtureMessage(
            from: "sender@example.com",
            replyTo: "team@example.com",
            subject: "Status",
            rfcMessageID: "<source@example.com>",
            references: ["<older@example.com>"]
        )

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: fixtureAccount(),
            actor: browserActor,
            id: DraftID("draft-1")
        )

        XCTAssertEqual(draft.to, [EmailAddress("team@example.com")])
        XCTAssertEqual(draft.subject, "Re: Status")
        XCTAssertEqual(draft.inReplyTo, "<source@example.com>")
        XCTAssertEqual(draft.references, ["<older@example.com>", "<source@example.com>"])
        XCTAssertEqual(draft.sourceThreadID, ThreadID("thread-1"))
        XCTAssertEqual(draft.createdBy, browserActor.id)
        XCTAssertFalse(draft.aiGenerated)
    }

    func testReplyFactoryDoesNotDuplicateReplyPrefixOrMessageIDReference() throws {
        let source = fixtureMessage(
            subject: "rE: Status",
            rfcMessageID: "<source@example.com>",
            references: ["<source@example.com>"]
        )

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: fixtureAccount(),
            actor: browserActor,
            id: DraftID("draft-2")
        )

        XCTAssertEqual(draft.subject, "rE: Status")
        XCTAssertEqual(draft.references, ["<source@example.com>"])
    }

    func testReplyFactoryRejectsMalformedSenders() {
        for address in [
            "missing-at.example.com",
            "two@@example.com",
            "local @example.com",
            "@example.com",
            "local@",
        ] {
            XCTAssertThrowsError(try makeDraft(from: address), "Expected \(address) to be rejected") { error in
                XCTAssertEqual(
                    error as? PlainpostError,
                    .validationFailed("This message does not have a safe reply address.")
                )
            }
        }
    }

    func testReplyFactoryAllowsAutomatedLookingSenders() throws {
        let draft = try makeDraft(from: "notifications@example.com")

        XCTAssertEqual(draft.to, [EmailAddress("notifications@example.com")])
    }

    func testReplyFactoryFallsBackToSenderWhenReplyToIsMalformed() throws {
        let source = fixtureMessage(from: "sender@example.com", replyTo: "not-an-address")

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: fixtureAccount(),
            actor: browserActor,
            id: DraftID("draft-malformed-reply-to")
        )

        XCTAssertEqual(draft.to, [EmailAddress("sender@example.com")])
    }

    private func makeDraft(from: String) throws -> Draft {
        try ReplyDraftFactory().makeDraft(
            source: fixtureMessage(from: from),
            account: fixtureAccount(),
            actor: browserActor,
            id: DraftID("draft-unsafe")
        )
    }

    private func fixtureMessage(
        from: String = "sender@example.com",
        replyTo: String? = nil,
        subject: String = "Status",
        rfcMessageID: String? = nil,
        references: [String] = []
    ) -> MessageSummary {
        MessageSummary(
            id: MessageID("message-1"),
            threadID: ThreadID("thread-1"),
            from: EmailAddress(from),
            subject: subject,
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Body",
            rfcMessageID: rfcMessageID,
            references: references,
            replyTo: replyTo.map { EmailAddress($0) }
        )
    }

    private func fixtureAccount() -> Account {
        Account(
            id: AccountID("account-1"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
    }
}
