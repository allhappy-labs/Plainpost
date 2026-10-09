import XCTest
@testable import PlainpostCore

final class DraftAndSendPolicyTests: XCTestCase {
    func testAttachmentContractRejectsHeaderAndPathInjectionAndAggregateOverflow() throws {
        let safe = DraftAttachment(
            id: "att-1",
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 7, count: 32)
        )
        XCTAssertNoThrow(try DraftAttachmentContract.validate([safe]))

        for attachment in [
            DraftAttachment(
                id: "att-2",
                filename: "evil\r\nBcc: victim@example.com",
                mimeType: "text/plain",
                data: Data()
            ),
            DraftAttachment(
                id: "att-3",
                filename: "../secret.txt",
                mimeType: "text/plain",
                data: Data()
            ),
            DraftAttachment(
                id: "att-4",
                filename: "safe.txt",
                mimeType: "text/plain\r\nX-Evil: 1",
                data: Data()
            ),
            DraftAttachment(
                id: "att-5",
                filename: "safe.txt",
                mimeType: "text",
                data: Data()
            )
        ] {
            XCTAssertThrowsError(
                try DraftAttachmentContract.validate([attachment]),
                "Expected \(attachment.id) to be rejected"
            )
        }

        let oversized = DraftAttachment(
            id: "att-big",
            filename: "large.bin",
            mimeType: "application/octet-stream",
            data: Data(repeating: 0, count: DraftAttachmentContract.maximumBytesPerAttachment + 1)
        )
        XCTAssertThrowsError(try DraftAttachmentContract.validate([oversized]))

        let aggregateOverflow = (0..<5).map { index in
            DraftAttachment(
                id: "att-aggregate-\(index)",
                filename: "part-\(index).bin",
                mimeType: "application/octet-stream",
                data: Data(repeating: 0, count: DraftAttachmentContract.maximumBytesPerAttachment)
            )
        }
        XCTAssertNoThrow(try DraftAttachmentContract.validate(Array(aggregateOverflow.prefix(4))))
        XCTAssertThrowsError(try DraftAttachmentContract.validate(aggregateOverflow))
    }

    func testRendererEscapesQuotesInValidatedAttachmentFilenames() throws {
        let attachment = DraftAttachment(
            id: "att-quotes",
            filename: "quarterly \"final\".pdf",
            mimeType: "application/pdf",
            data: Data()
        )
        let draft = Draft(
            id: DraftID("drf_attachment_quotes"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Report",
            bodyPlain: "Attached.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil,
            attachments: [attachment]
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.body.contains("filename=\"quarterly \\\"final\\\".pdf\""))
        XCTAssertFalse(rendered.body.contains("filename=\"quarterly \"final\".pdf\""))
    }

    /// Purelymail does not offer SMTPUTF8, so a raw `ü` in Subject made every
    /// reply to "Med. Kundenrückfrage" fail before MAIL FROM.
    func testNonASCIISubjectIsEncodedSoTheHeaderStaysASCII() throws {
        let subject = "Re: FW: Med. Kundenrückfrage, VN 102028042 (delete in 10 days) — Дякую за відповідь"
        let draft = Draft(
            id: DraftID("drf_unicode_subject"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: subject,
            bodyPlain: "Ärztezentrum Kloten?",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertFalse(rendered.headers.unicodeScalars.contains { $0.value > 0x7F })
        let lines = rendered.headers.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 78 })
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Subject: ") })
        var value = String(lines[start].dropFirst("Subject: ".count))
        for line in lines[(start + 1)...] {
            guard line.hasPrefix(" ") else { break }
            value += line
        }
        XCTAssertEqual(MIMEMessageDecoder.decodeHeader(value), subject)
    }

    func testASCIISubjectIsUnchanged() throws {
        let draft = Draft(
            id: DraftID("drf_ascii_subject"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Report",
            bodyPlain: "Thanks.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.components(separatedBy: "\r\n").contains("Subject: Re: Report"))
    }

    /// The Date header was a fixed `Thu, 08 Jul 2026`, so every direct send
    /// reached the recipient with that date.
    func testDateHeaderIsTheTimeOfRendering() throws {
        let draft = Draft(
            id: DraftID("drf_date"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Hello",
            bodyPlain: "Hi.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil
        )

        let rendered = try DraftRenderer(now: { Date(timeIntervalSince1970: 1_791_456_000) }).render(draft)

        XCTAssertTrue(
            rendered.headers.components(separatedBy: "\r\n").contains("Date: Thu, 08 Oct 2026 10:40:00 +0000"),
            rendered.headers
        )
    }

    func testAttachmentContractEnforcesExactMetadataCountAndSizeBounds() throws {
        let maximumSizedAttachment = DraftAttachment(
            id: String(repeating: "i", count: DraftAttachmentContract.maximumIDUTF8Length),
            filename: String(repeating: "f", count: DraftAttachmentContract.maximumFilenameUTF8Length),
            mimeType: "application/" + String(
                repeating: "x",
                count: DraftAttachmentContract.maximumMIMETypeUTF8Length - "application/".utf8.count
            ),
            data: Data(repeating: 0, count: DraftAttachmentContract.maximumBytesPerAttachment)
        )
        XCTAssertNoThrow(try DraftAttachmentContract.validate([maximumSizedAttachment]))

        let duplicate = DraftAttachment(id: "same", filename: "safe.txt", mimeType: "text/plain", data: Data())
        XCTAssertThrowsError(try DraftAttachmentContract.validate([duplicate, duplicate]))

        let tooMany = (0...DraftAttachmentContract.maximumCount).map { index in
            DraftAttachment(id: "att-\(index)", filename: "safe-\(index).txt", mimeType: "text/plain", data: Data())
        }
        XCTAssertThrowsError(try DraftAttachmentContract.validate(tooMany))

        for invalid in [
            DraftAttachment(id: "", filename: "safe.txt", mimeType: "text/plain", data: Data()),
            DraftAttachment(
                id: String(repeating: "i", count: DraftAttachmentContract.maximumIDUTF8Length + 1),
                filename: "safe.txt",
                mimeType: "text/plain",
                data: Data()
            ),
            DraftAttachment(id: "att-dot", filename: ".", mimeType: "text/plain", data: Data()),
            DraftAttachment(id: "att-dotdot", filename: "..", mimeType: "text/plain", data: Data()),
            DraftAttachment(id: "att-slash", filename: "a/b.txt", mimeType: "text/plain", data: Data()),
            DraftAttachment(id: "att-backslash", filename: "a\\b.txt", mimeType: "text/plain", data: Data()),
            DraftAttachment(id: "att-space", filename: "safe.txt", mimeType: "text/ plain", data: Data()),
            DraftAttachment(id: "att-extra-slash", filename: "safe.txt", mimeType: "text/plain/extra", data: Data()),
            DraftAttachment(id: "att-control", filename: "safe.txt", mimeType: "text/pla\u{7f}in", data: Data())
        ] {
            XCTAssertThrowsError(try DraftAttachmentContract.validate([invalid]))
        }
    }

    func testReplyAllExcludesLocalAccountAndPreservesRFCAncestry() throws {
        let source = MessageSummary(
            id: MessageID("msg-source"),
            threadID: ThreadID("thr-source"),
            from: EmailAddress("alice@example.com"),
            subject: "Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Original body",
            sentAt: Date(timeIntervalSince1970: 1_000),
            rfcMessageID: "<source@example.com>",
            references: ["<parent@example.com>"],
            to: [EmailAddress("me@example.com"), EmailAddress("bob@example.com")],
            cc: [EmailAddress("carol@example.com"), EmailAddress("BOB@example.com")]
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("ME@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-reply-all"),
            kind: .replyAll
        )

        XCTAssertEqual(draft.to.map(\.rawValue), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(draft.cc.map(\.rawValue), ["carol@example.com"])
        XCTAssertEqual(draft.inReplyTo, "<source@example.com>")
        XCTAssertEqual(draft.references, ["<parent@example.com>", "<source@example.com>"])
        XCTAssertEqual(draft.sourceThreadID, ThreadID("thr-source"))
    }

    func testReplyAllExcludesLocalAccountWhenItIsTheReplyRecipient() throws {
        let source = MessageSummary(
            id: MessageID("msg-sent"),
            threadID: ThreadID("thr-sent"),
            from: EmailAddress("ME@example.com"),
            subject: "Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "Sent",
            isDeleted: false,
            body: "Original body",
            to: [EmailAddress("bob@example.com")],
            cc: [EmailAddress("me@example.com"), EmailAddress("carol@example.com")]
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-sent-reply-all"),
            kind: .replyAll
        )

        XCTAssertEqual(draft.to.map(\.rawValue), ["bob@example.com"])
        XCTAssertEqual(draft.cc.map(\.rawValue), ["carol@example.com"])
    }

    func testReplyUsesValidInReplyToAsFallbackParentWhenReferencesAreEmpty() throws {
        let source = MessageSummary(
            id: MessageID("msg-child"),
            threadID: ThreadID("thr-child"),
            from: EmailAddress("alice@example.com"),
            subject: "Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Original body",
            rfcMessageID: "<child@example.com>",
            inReplyTo: "<parent@example.com>"
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-child-reply"),
            kind: .reply
        )

        XCTAssertEqual(draft.references, ["<parent@example.com>", "<child@example.com>"])
    }

    func testReplyAncestryDeduplicatesMessageIDsByExactEquality() throws {
        let source = MessageSummary(
            id: MessageID("msg-case"),
            threadID: ThreadID("thr-case"),
            from: EmailAddress("alice@example.com"),
            subject: "Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Original body",
            rfcMessageID: "<parent@example.com>",
            references: ["<Parent@example.com>", "<Parent@example.com>"]
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-case-reply"),
            kind: .replyAll
        )
        let rendered = try DraftRenderer().render(draft)

        XCTAssertEqual(draft.references, ["<Parent@example.com>", "<parent@example.com>"])
        XCTAssertTrue(rendered.headers.contains("References: <Parent@example.com> <parent@example.com>"))
    }

    func testReplyIgnoresInvalidInReplyToFallbackParent() throws {
        let source = MessageSummary(
            id: MessageID("msg-invalid-parent"),
            threadID: ThreadID("thr-invalid-parent"),
            from: EmailAddress("alice@example.com"),
            subject: "Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Original body",
            rfcMessageID: "<child@example.com>",
            inReplyTo: "<parent@example.com>\r\nBcc: victim@example.com"
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-invalid-parent-reply"),
            kind: .reply
        )

        XCTAssertEqual(draft.references, ["<child@example.com>"])
    }

    func testForwardClearsRecipientsAndRFCAncestryAndQuotesBody() throws {
        let source = MessageSummary(
            id: MessageID("msg-forward"),
            threadID: ThreadID("thr-forward"),
            from: EmailAddress("alice@example.com"),
            subject: "FWD: Status",
            preview: "Preview",
            smartCategory: .personal,
            labels: [],
            isSeen: true,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "First line\n\nSecond line",
            rfcMessageID: "<source@example.com>",
            inReplyTo: "<parent@example.com>",
            references: ["<parent@example.com>"]
        )
        let account = Account(
            id: AccountID("acc-me"),
            displayName: "Me",
            email: EmailAddress("me@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

        let draft = try ReplyDraftFactory().makeDraft(
            source: source,
            account: account,
            actor: actor,
            id: DraftID("drf-forward"),
            kind: .forward
        )

        XCTAssertTrue(draft.to.isEmpty)
        XCTAssertTrue(draft.cc.isEmpty)
        XCTAssertTrue(draft.bcc.isEmpty)
        XCTAssertEqual(draft.subject, "FWD: Status")
        XCTAssertNil(draft.inReplyTo)
        XCTAssertTrue(draft.references.isEmpty)
        XCTAssertEqual(draft.bodyMarkdown, "> First line\n>\n> Second line")
    }

    func testMarkdownDraftRendersSafeMultipartAlternativeWithoutPersistingHTML() throws {
        let markdown = """
        Hello **team**,

        - First item
        - [Project](https://example.com/project)

        > Keep this private.

        `let ready = true`

        <script>alert(1)</script> [bad](javascript:alert(1))
        """
        let draft = Draft(
            id: DraftID("drf_markdown"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Formatted update",
            bodyPlain: MarkdownEmailRenderer.plainText(from: markdown),
            bodyMarkdown: MarkdownEmailRenderer.canonicalize(markdown),
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.contains("Content-Type: multipart/alternative"))
        XCTAssertTrue(rendered.body.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(rendered.body.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(rendered.body.contains("<strong>team</strong>"))
        XCTAssertTrue(rendered.body.contains("<ul>"))
        XCTAssertTrue(rendered.body.contains("href=\"https://example.com/project\""))
        XCTAssertTrue(rendered.body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(rendered.body.contains("href=\"javascript:"))
        XCTAssertEqual(draft.bodyMarkdown, MarkdownEmailRenderer.canonicalize(markdown))
    }

    func testMarkdownAttachmentRendersMixedWithNestedAlternative() throws {
        let draft = Draft(
            id: DraftID("drf_markdown_attachment"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Formatted proposal",
            bodyPlain: "See proposal.",
            bodyMarkdown: "See **proposal**.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: nil,
            attachments: [DraftAttachment(id: "att_1", filename: "proposal.txt", mimeType: "text/plain", data: Data("Proposal".utf8))]
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.contains("Content-Type: multipart/mixed"))
        XCTAssertTrue(rendered.body.contains("Content-Type: multipart/alternative"))
        XCTAssertTrue(rendered.body.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(rendered.body.contains("Content-Disposition: attachment; filename=\"proposal.txt\""))
    }

    func testLegacyDraftPayloadWithoutMarkdownRemainsPlainTextCompatible() throws {
        let legacyPayload = """
        {"id":"drf_legacy","accountID":"acc_personal","from":"me@example.com","to":["alice@example.com"],"cc":[],"bcc":[],"subject":"Legacy","bodyPlain":"Plain legacy body","createdBy":"local-user","aiGenerated":false,"sourceThreadID":null,"attachments":[]}
        """
        let draft = try JSONDecoder().decode(Draft.self, from: Data(legacyPayload.utf8))

        let rendered = try DraftRenderer().render(draft)

        XCTAssertNil(draft.bodyMarkdown)
        XCTAssertEqual(draft.bodyPlain, "Plain legacy body")
        XCTAssertTrue(rendered.headers.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertFalse(rendered.headers.contains("multipart/alternative"))
        XCTAssertEqual(rendered.body, "Plain legacy body")
    }

    func testBccIsExcludedFromMimeHeadersButKeptForEnvelope() throws {
        let draft = Draft(
            id: DraftID("drf_test"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [EmailAddress("team@example.com")],
            bcc: [EmailAddress("hidden@example.com")],
            subject: "Hello",
            bodyPlain: "Body",
            createdBy: "codex",
            aiGenerated: false,
            sourceThreadID: nil
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.contains("To: alice@example.com"))
        XCTAssertTrue(rendered.headers.contains("Cc: team@example.com"))
        XCTAssertFalse(rendered.headers.contains("Bcc:"))
        XCTAssertEqual(rendered.envelopeRecipients.map(\.rawValue), ["alice@example.com", "team@example.com", "hidden@example.com"])
    }

    func testRendererUsesAggregateEnvelopeRecipientContract() throws {
        let bccOnly = Draft(
            id: DraftID("drf_bcc_only"), accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"), to: [], cc: [],
            bcc: [EmailAddress("hidden@example.com")], subject: "Private",
            bodyPlain: "Body", createdBy: "local-user", aiGenerated: false,
            sourceThreadID: nil
        )
        XCTAssertNoThrow(try DraftRenderer().render(bccOnly))

        let overLimit = Draft(
            id: DraftID("drf_over_limit"), accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: (0..<256).map { EmailAddress("to\($0)@example.com") }, cc: [],
            bcc: [EmailAddress("hidden@example.com")], subject: "Too many",
            bodyPlain: "Body", createdBy: "local-user", aiGenerated: false,
            sourceThreadID: nil
        )
        XCTAssertThrowsError(try DraftRenderer().render(overLimit))
    }

    func testReplyRendererEmitsRFCThreadingHeadersInStableOrder() throws {
        let draft = Draft(
            id: DraftID("drf_reply"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Project update",
            bodyPlain: "Thanks.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: ThreadID("thr_project"),
            inReplyTo: "<reply@example.com>",
            references: ["<root@example.com>", "<reply@example.com>", "<root@example.com>"]
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.contains("In-Reply-To: <reply@example.com>"))
        XCTAssertTrue(rendered.headers.contains("References: <root@example.com> <reply@example.com>"))
    }

    func testReplyRendererRejectsAncestryHeaderInjection() {
        let draft = Draft(
            id: DraftID("drf_reply_injection"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Project update",
            bodyPlain: "Thanks.",
            createdBy: "local-user",
            aiGenerated: false,
            sourceThreadID: ThreadID("thr_project"),
            inReplyTo: "<reply@example.com>\r\nBcc: hidden@example.com"
        )

        XCTAssertThrowsError(try DraftRenderer().render(draft))
    }

    func testAttachmentRendersAsMultipartWithoutBccHeader() throws {
        let draft = Draft(
            id: DraftID("drf_attachment"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [EmailAddress("hidden@example.com")],
            subject: "Proposal",
            bodyPlain: "See attached.",
            createdBy: "codex",
            aiGenerated: false,
            sourceThreadID: nil,
            attachments: [
                DraftAttachment(
                    id: "att_1",
                    filename: "proposal.txt",
                    mimeType: "text/plain",
                    data: Data("Hello Alice".utf8)
                )
            ]
        )

        let rendered = try DraftRenderer().render(draft)

        XCTAssertTrue(rendered.headers.contains("MIME-Version: 1.0"))
        XCTAssertTrue(rendered.headers.contains("Message-ID: <drf_attachment@plainpost.local>"))
        XCTAssertTrue(rendered.headers.contains("Content-Type: multipart/mixed; boundary="))
        XCTAssertFalse(rendered.headers.contains("Bcc:"))
        XCTAssertTrue(rendered.body.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(rendered.body.contains("Content-Disposition: attachment; filename=\"proposal.txt\""))
        XCTAssertTrue(rendered.body.contains("SGVsbG8gQWxpY2U="))
        XCTAssertEqual(rendered.envelopeRecipients.map(\.rawValue), ["alice@example.com", "hidden@example.com"])
    }

    func testRendererRejectsHeaderInjectionInSubject() {
        let draft = Draft(
            id: DraftID("drf_injection"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [EmailAddress("hidden@example.com")],
            subject: "Hello\r\nBcc: hidden@example.com",
            bodyPlain: "Body",
            createdBy: "codex",
            aiGenerated: false,
            sourceThreadID: nil
        )

        XCTAssertThrowsError(try DraftRenderer().render(draft)) { error in
            XCTAssertEqual(error as? PlainpostError, .validationFailed("Header values cannot contain CR or LF."))
        }
    }

    func testSendRequestLocksDraftHash() throws {
        let actor = Actor(
            id: "codex",
            kind: .cli,
            displayName: "Codex CLI",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
        let draft = Draft(
            id: DraftID("drf_test"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Follow up",
            bodyPlain: "Tuesday works for me.",
            createdBy: actor.id,
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_1")
        )

        let request = try SendRequestPolicy().requestSend(draft: draft, actor: actor, reason: "User asked me to reply")

        XCTAssertEqual(request.status, .pending)
        XCTAssertEqual(request.approvedDraftHash, nil)
        XCTAssertEqual(request.requestedDraftHash, draft.contentHash)
        XCTAssertTrue(request.riskFlags.contains(.aiGeneratedBody))
        XCTAssertTrue(request.riskFlags.contains(.agentRequestedSend))
    }

    func testSendRequestFlagsDeterministicApprovalRisks() throws {
        let actor = Actor(
            id: "codex",
            kind: .mcpAgent,
            displayName: "Codex MCP",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
        let draft = Draft(
            id: DraftID("drf_risky"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [
                EmailAddress("alice@example.com"),
                EmailAddress("bob@example.com"),
                EmailAddress("carol@example.com"),
                EmailAddress("dana@example.com")
            ],
            cc: [EmailAddress("finance@example.com")],
            bcc: [EmailAddress("hidden@example.com")],
            subject: "   ",
            bodyPlain: "Please review the attachment and open http://billing.example.test before Friday.",
            createdBy: actor.id,
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_1"),
            attachments: [
                DraftAttachment(
                    id: "att_invoice",
                    filename: "invoice.pdf",
                    mimeType: "application/pdf",
                    data: Data("fake-pdf".utf8)
                )
            ]
        )

        let request = try SendRequestPolicy().requestSend(draft: draft, actor: actor, reason: "Prepare invoice reply")

        XCTAssertEqual(
            request.riskFlags,
            [
                .agentRequestedSend,
                .aiGeneratedBody,
                .bccPresent,
                .emptySubject,
                .manyRecipients,
                .attachmentPresent,
                .suspiciousLink
            ]
        )
        XCTAssertEqual(request.riskScore, 100)
    }

    func testApprovalRejectsChangedDraftHash() throws {
        let request = SendRequest(
            id: SendRequestID("srq_test"),
            draftID: DraftID("drf_test"),
            requestedBy: "codex",
            status: .pending,
            requestedDraftHash: "hash_a",
            riskScore: 10,
            riskFlags: [],
            reason: nil,
            approvedBy: nil,
            approvedDraftHash: nil
        )

        XCTAssertThrowsError(try ApprovalPolicy.validateApprovedDraftHash(request: request, currentDraftHash: "hash_b")) { error in
            XCTAssertEqual(error as? PlainpostError, .validationFailed("Draft changed after send request was created."))
        }
    }

    func testApprovalValidationRequiresGuiUserActor() throws {
        let request = SendRequest(
            id: SendRequestID("srq_test"),
            draftID: DraftID("drf_test"),
            requestedBy: "codex",
            status: .pending,
            requestedDraftHash: "hash_a",
            riskScore: 10,
            riskFlags: [],
            reason: nil,
            approvedBy: nil,
            approvedDraftHash: nil
        )
        let agent = Actor(
            id: "codex",
            kind: .cli,
            displayName: "Codex CLI",
            permissions: .agentRequested(readBody: true, createDrafts: true, requestSend: true)
        )
        let guiUser = Actor(
            id: "local-user",
            kind: .user,
            displayName: "Local User",
            permissions: .guiUser
        )

        XCTAssertThrowsError(try ApprovalPolicy.validateApproval(request: request, currentDraftHash: "hash_a", actor: agent)) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Only the local GUI user can approve sends."))
        }
        XCTAssertNoThrow(try ApprovalPolicy.validateApproval(request: request, currentDraftHash: "hash_a", actor: guiUser))
    }
}
