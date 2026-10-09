import Combine
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport
@testable import PlainpostUI

final class ComposerViewModelTests: XCTestCase {
    func testNodeAuthorityComposerSenderSendsThroughMutationCapability() async throws {
        let mutations = RecordingMutationCapability()
        let draft = Draft(
            id: DraftID("drf_node"), accountID: AccountID("acc_node"),
            from: EmailAddress("me@example.com"), to: [EmailAddress("alice@example.com")],
            cc: [], bcc: [], subject: "Node", bodyPlain: "Body", createdBy: "local-user",
            aiGenerated: false, sourceThreadID: nil)

        let result = try await NodeAuthorityDirectComposerSender(mutations: mutations).send(draft: draft)

        XCTAssertEqual(result, DirectComposerSendResult(messageID: "msg-node", remoteSentCopyAppended: true))
        let intents = await mutations.intents
        XCTAssertEqual(intents, [.send(draft)])
    }

    func testNodeAuthorityComposerSenderFailsClosedWithoutLegacyProviderFallback() async {
        let draft = Draft(
            id: DraftID("drf_node"), accountID: AccountID("acc_node"),
            from: EmailAddress("me@example.com"), to: [EmailAddress("alice@example.com")],
            cc: [], bcc: [], subject: "Node", bodyPlain: "Body", createdBy: "local-user",
            aiGenerated: false, sourceThreadID: nil)

        do {
            _ = try await NodeAuthorityDirectComposerSender().send(draft: draft)
            XCTFail("Node composer sender must not route through the legacy provider path")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("Node mail sending requires an authenticated Node operation."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNodeAuthorityComposerResolvesSenderAtSubmitAfterFirstStatusRefresh() async throws {
        let mutations = RecordingMutationCapability()
        let sender = LockedSender()
        let handler = NodeAuthorityComposerDraftHandler(
            accountID: AccountID("acc_node"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
            mutations: mutations,
            senderProvider: { sender.value }
        )
        let input = ComposerDraftInput(to: "alice@example.com", cc: "", bcc: "", subject: "Node", bodyPlain: "Body")

        do {
            _ = try await handler.saveDraft(input: input)
            XCTFail("sender-less first-time Node composer must fail closed")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("No authenticated sender identity is available for this account."))
        }

        sender.value = EmailAddress("me@example.com")
        let draft = try await handler.saveDraft(input: input)
        XCTAssertEqual(draft.from, EmailAddress("me@example.com"))
    }

    func testNodeComposerSessionKeepsDraftIdentityAcrossTwoSavesAndSend() async throws {
        let mutations = RecordingMutationCapability()
        let generatedIDs = LockedDraftIDCounter()
        let handler = NodeAuthorityComposerDraftHandler(
            accountID: AccountID("acc_node"),
            from: EmailAddress("me@example.com"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
            mutations: mutations,
            idGenerator: {
                generatedIDs.next()
            }
        )
        let input = ComposerDraftInput(to: "alice@example.com", cc: "", bcc: "", subject: "Node", bodyPlain: "Body")

        let first = try await handler.saveDraft(input: input)
        let second = try await handler.saveDraft(input: ComposerDraftInput(
            to: input.to, cc: input.cc, bcc: input.bcc, subject: "Updated", bodyPlain: "Body 2"
        ))
        _ = try await NodeAuthorityDirectComposerSender(mutations: mutations).send(draft: second)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(generatedIDs.count, 1, "a composer session allocates one stable remote draft identity")
        let intents = await mutations.intents
        guard case let .saveDraft(savedFirst) = intents[0],
              case let .saveDraft(savedSecond) = intents[1],
              case let .send(sent) = intents[2]
        else { return XCTFail("expected two saves followed by send") }
        XCTAssertEqual(savedFirst.id, savedSecond.id)
        XCTAssertEqual(savedSecond.id, sent.id)
    }

    func testRestoredNodeComposerSessionReusesDurableDraftIdentity() async throws {
        let mutations = RecordingMutationCapability()
        let generatedIDs = LockedDraftIDCounter()
        let handler = NodeAuthorityComposerDraftHandler(
            accountID: AccountID("acc_node"),
            from: EmailAddress("me@example.com"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
            mutations: mutations,
            idGenerator: { generatedIDs.next() }
        )
        let input = ComposerDraftInput(to: "alice@example.com", cc: "", bcc: "", subject: "Node", bodyPlain: "Body")
        let first = try await handler.saveDraft(input: input)
        handler.restoreDraftSession(draftID: first.id.rawValue)
        let restored = try await handler.saveDraft(input: input)
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(generatedIDs.count, 1)
    }

    func testNodeComposerDeletesSavedDraftAndStartsFreshSession() async throws {
        let mutations = RecordingMutationCapability()
        let generatedIDs = LockedDraftIDCounter()
        let handler = NodeAuthorityComposerDraftHandler(
            accountID: AccountID("acc_node"), from: EmailAddress("me@example.com"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
            mutations: mutations, idGenerator: { generatedIDs.next() }
        )
        let input = ComposerDraftInput(to: "alice@example.com", cc: "", bcc: "", subject: "Node", bodyPlain: "Body")
        let first = try await handler.saveDraft(input: input)

        try await handler.discardDraft(draftID: first.id.rawValue)
        let second = try await handler.saveDraft(input: input)

        XCTAssertNotEqual(first.id, second.id)
        let intents = await mutations.intents
        XCTAssertEqual(intents, [.saveDraft(first), .deleteDraft(first.id), .saveDraft(second)])
    }

    func testNodeComposerPreservesDraftIdentityWhenDeletionNotConfirmed() async throws {
        let mutations = RecordingMutationCapability(deleteState: "pending")
        let generatedIDs = LockedDraftIDCounter()
        let handler = NodeAuthorityComposerDraftHandler(
            accountID: AccountID("acc_node"), from: EmailAddress("me@example.com"),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser),
            mutations: mutations, idGenerator: { generatedIDs.next() }
        )
        let input = ComposerDraftInput(to: "alice@example.com", cc: "", bcc: "", subject: "Node", bodyPlain: "Body")
        let first = try await handler.saveDraft(input: input)

        do {
            try await handler.discardDraft(draftID: first.id.rawValue)
            XCTFail("A pending deletion must not close or release the composer session")
        } catch let error as PlainpostError {
            XCTAssertEqual(error, .validationFailed("The Node could not confirm draft deletion."))
        }
        let savedAgain = try await handler.saveDraft(input: input)
        XCTAssertEqual(savedAgain.id, first.id)
        XCTAssertEqual(generatedIDs.count, 1)
    }

    func testComposerPresentationPolicyRoutesRuntimeAndSnapshotWindows() {
        let snapshot = ComposerRestoreSnapshot.preview()

        XCTAssertNil(
            ComposerPresentationPolicy.embedded.windowRequest(
                runtimeRequest: .newMessage,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(
            ComposerPresentationPolicy.runtimeWindow.windowRequest(
                runtimeRequest: .reply(sourceMessageID: "message-1"),
                snapshot: snapshot
            ),
            .reply(sourceMessageID: "message-1")
        )
        XCTAssertEqual(
            ComposerPresentationPolicy.snapshotWindow.windowRequest(
                runtimeRequest: .reply(sourceMessageID: "message-1"),
                snapshot: snapshot
            ),
            .restore(snapshot)
        )
    }

    @MainActor
    func testRestoreSnapshotRoundTripsAttachmentMetadataAndBytes() {
        let attachment = DraftAttachment(
            id: "att-restore",
            filename: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )
        let snapshot = ComposerRestoreSnapshot(
            to: "alice@example.com",
            cc: "",
            bcc: "",
            subject: "Attachment",
            bodyMarkdown: "Body",
            attachments: [attachment],
            presentationMode: .newMessage,
            replyContext: nil,
            includesQuotedHistory: true
        )
        let model = ComposerViewModel(composer: RecordingComposer())

        model.restore(from: snapshot)

        XCTAssertEqual(model.attachments, [attachment])
        XCTAssertEqual(model.restorationSnapshot.attachments, [attachment])
        model.subject = "Edited attachment"
        XCTAssertEqual(model.attachments, [attachment])
        model.prepareNewMessage()
        XCTAssertTrue(model.attachments.isEmpty)
    }

    @MainActor
    func testSaveDraftPreservesValidatedAttachments() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_attachment_composer") }
            )
        )
        let attachment = DraftAttachment(
            id: "att-save",
            filename: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )
        viewModel.to = "alice@example.com"
        viewModel.subject = "Attachment"
        viewModel.bodyMarkdown = "See attachment."
        viewModel.attachments = [attachment]

        try await viewModel.saveDraft()

        XCTAssertEqual(try store.draft(id: DraftID("drf_attachment_composer")).attachments, [attachment])
    }

    @MainActor
    func testInvalidAttachmentDoesNotReachDraftStore() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_invalid_attachment") }
            )
        )
        viewModel.to = "alice@example.com"
        viewModel.subject = "Attachment"
        viewModel.bodyMarkdown = "See attachment."
        viewModel.attachments = [DraftAttachment(
            id: "att-invalid",
            filename: "notes\r\nBcc: victim@example.com",
            mimeType: "text/plain",
            data: Data()
        )]

        try await viewModel.saveDraft()

        XCTAssertThrowsError(try store.draft(id: DraftID("drf_invalid_attachment")))
        XCTAssertEqual(viewModel.statusMessage, "An attachment is invalid.")
    }

    @MainActor
    func testPreparingNewMessageClearsStaleReplyContent() {
        let viewModel = ComposerViewModel.preview()

        viewModel.prepareNewMessage()

        XCTAssertEqual(viewModel.presentationMode, .newMessage)
        XCTAssertEqual(viewModel.to, "")
        XCTAssertEqual(viewModel.cc, "")
        XCTAssertEqual(viewModel.bcc, "")
        XCTAssertEqual(viewModel.subject, "")
        XCTAssertEqual(viewModel.bodyPlain, "")
        XCTAssertFalse(viewModel.canSaveDraft)
        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(viewModel.displayStatusMessage, "New local draft")
    }

    @MainActor
    func testPreparingReplyUsesCurrentThreadAndDoesNotDuplicateReplyPrefix() {
        let viewModel = ComposerViewModel.preview()

        viewModel.prepareReply(to: "current@example.com", subject: "RE: Current topic")

        XCTAssertEqual(
            viewModel.presentationMode,
            .reply(recipient: "current@example.com", subject: "RE: Current topic")
        )
        XCTAssertEqual(viewModel.to, "current@example.com")
        XCTAssertEqual(viewModel.subject, "RE: Current topic")
        XCTAssertEqual(viewModel.bodyPlain, "")
        XCTAssertEqual(viewModel.displayStatusMessage, "Unsaved changes")
    }

    @MainActor
    func testPreparingAIDraftReplyPopulatesEditableComposer() {
        let viewModel = ComposerViewModel.preview()

        viewModel.prepareAIDraftReply(
            to: "alice@example.com",
            subject: "Project update",
            bodyMarkdown: "Thanks, Alice.\n\nTuesday works."
        )

        XCTAssertEqual(viewModel.to, "alice@example.com")
        XCTAssertEqual(viewModel.subject, "Re: Project update")
        XCTAssertEqual(viewModel.bodyPlain, "Thanks, Alice.\n\nTuesday works.")
        XCTAssertEqual(viewModel.statusMessage, "AI draft ready for review")
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testPreparingAIDraftReplyWithoutRecipientRequiresRecipientBeforeSending() {
        let viewModel = ComposerViewModel.preview()

        viewModel.prepareAIDraftReply(
            to: "",
            subject: "Account verification",
            bodyMarkdown: "Testing local SMTP credentials."
        )

        XCTAssertEqual(viewModel.to, "")
        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(viewModel.statusMessage, "AI draft ready. Add a recipient before sending.")
    }

    @MainActor
    func testReplyIncludesCollapsedQuotedHistoryAndPreservesThreadAncestry() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_threaded_reply") }
            )
        )
        let context = ComposerReplyContext(
            sourceThreadID: ThreadID("thr_project"),
            sourceMessageID: MessageID("msg_source"),
            rfcMessageID: "<source@example.com>",
            references: ["<root@example.com>"],
            recipient: "alice@example.com",
            subject: "Project update",
            senderName: "Alice",
            dateLabel: "July 12, 2026 at 10:30 AM",
            quotedBody: "First line\n\nSecond line"
        )

        viewModel.prepareReply(context: context)
        viewModel.bodyMarkdown = "Thanks, Alice."
        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_threaded_reply"))
        XCTAssertEqual(draft.sourceThreadID, ThreadID("thr_project"))
        XCTAssertEqual(draft.inReplyTo, "<source@example.com>")
        XCTAssertEqual(draft.references, ["<root@example.com>", "<source@example.com>"])
        XCTAssertTrue(draft.bodyMarkdown?.hasPrefix("Thanks, Alice.\n\nOn July 12, 2026 at 10:30 AM, Alice wrote:") == true)
        XCTAssertTrue(draft.bodyMarkdown?.contains("> First line\n>\n> Second line") == true)
    }

    @MainActor
    func testRemovingVisibleQuoteKeepsRFCThreading() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_unquoted_reply") }
            )
        )
        viewModel.prepareReply(context: ComposerReplyContext(
            sourceThreadID: ThreadID("thr_project"),
            sourceMessageID: MessageID("msg_source"),
            rfcMessageID: "<source@example.com>",
            references: [],
            recipient: "alice@example.com",
            subject: "Project update",
            senderName: "Alice",
            dateLabel: "Today",
            quotedBody: "Original"
        ))
        viewModel.bodyMarkdown = "Reply only."
        viewModel.includesQuotedHistory = false

        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_unquoted_reply"))
        XCTAssertEqual(draft.bodyMarkdown, "Reply only.")
        XCTAssertEqual(draft.inReplyTo, "<source@example.com>")
        XCTAssertEqual(draft.references, ["<source@example.com>"])
    }

    @MainActor
    func testQuotedPlainTextKeepsLiteralMarkdownCharacters() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_literal_quote") }
            )
        )
        viewModel.prepareReply(context: ComposerReplyContext(
            sourceThreadID: ThreadID("thr_project"),
            sourceMessageID: MessageID("msg_source"),
            rfcMessageID: "<source@example.com>",
            references: [],
            recipient: "alice@example.com",
            subject: "Project update",
            senderName: "Alice",
            dateLabel: "Today",
            quotedBody: "Use **literal stars**, `ticks`, and [brackets](https://example.com)."
        ))
        viewModel.bodyMarkdown = "Reply."

        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_literal_quote"))
        XCTAssertTrue(draft.bodyPlain.contains("> Use **literal stars**, `ticks`, and [brackets](https://example.com)."))
    }

    @MainActor
    func testSaveDraftStoresRecipientsSubjectAndBody() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.codexActor,
                idGenerator: { DraftID("drf_composer_1") }
            )
        )
        viewModel.to = "alice@example.com, bob@example.com"
        viewModel.cc = "team@example.com"
        viewModel.bcc = "audit@example.com"
        viewModel.subject = "Project update"
        viewModel.bodyPlain = "The local draft body."

        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_composer_1"))
        XCTAssertEqual(draft.to.map(\.rawValue), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(draft.cc.map(\.rawValue), ["team@example.com"])
        XCTAssertEqual(draft.bcc.map(\.rawValue), ["audit@example.com"])
        XCTAssertEqual(draft.subject, "Project update")
        XCTAssertEqual(draft.bodyPlain, "The local draft body.")
        XCTAssertEqual(viewModel.lastDraftID, "drf_composer_1")
        XCTAssertEqual(viewModel.statusMessage, "Draft saved")
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testPartialDraftCanBeKeptWithoutBecomingSendable() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_partial") }
            )
        )
        viewModel.subject = "Unfinished thought"

        XCTAssertTrue(viewModel.canSaveDraft)
        XCTAssertFalse(viewModel.canSend)
        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_partial"))
        XCTAssertTrue(draft.to.isEmpty)
        XCTAssertEqual(draft.subject, "Unfinished thought")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    @MainActor
    func testMarkdownComposerStoresCanonicalMarkdownAndPlainTextFallback() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_markdown_composer") }
            )
        )
        viewModel.to = "alice@example.com"
        viewModel.subject = "Formatted update"
        viewModel.bodyMarkdown = "Hello **Alice**\r\n\r\n- One"

        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_markdown_composer"))
        XCTAssertEqual(draft.bodyMarkdown, "Hello **Alice**\n\n- One")
        XCTAssertEqual(draft.bodyPlain, "Hello Alice\n\n- One")
        XCTAssertFalse(draft.bodyPlain.contains("<strong>"))
    }

    @MainActor
    func testUnfinishedRecipientCanBeKeptButNotSent() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.codexActor,
                idGenerator: { DraftID("drf_invalid") }
            )
        )
        viewModel.to = "Post"
        viewModel.subject = "Invalid"
        viewModel.bodyPlain = "Body"

        XCTAssertFalse(viewModel.canSend)
        try await viewModel.saveDraft()

        XCTAssertEqual(try store.draft(id: DraftID("drf_invalid")).to, [EmailAddress("Post")])
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        let scheduled = try await viewModel.send()
        XCTAssertFalse(scheduled)
    }

    @MainActor
    func testUserSendSavesAndSchedulesWithoutDirectDelivery() async throws {
        let store = InMemoryMailStore()
        let scheduler = RecordingComposerSendScheduler()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_composer_request") }
            ),
            sendScheduler: scheduler
        )
        viewModel.to = "alice@example.com"
        viewModel.bcc = "audit@example.com"
        viewModel.subject = "Delayed"
        viewModel.bodyPlain = "This was explicitly sent by the local user."

        let didSchedule = try await viewModel.send()
        XCTAssertTrue(didSchedule)

        XCTAssertEqual(viewModel.lastDraftID, "drf_composer_request")
        XCTAssertTrue(viewModel.isSendScheduled)
        XCTAssertEqual(viewModel.statusMessage, "Sending in 10s")
        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(scheduler.scheduledDrafts.map(\.subject), ["Delayed"])
        XCTAssertEqual(scheduler.scheduledDrafts.first?.bcc.map(\.rawValue), ["audit@example.com"])
        XCTAssertEqual(scheduler.snapshots.first?.subject, "Delayed")
        XCTAssertTrue(store.approvalQueueRequests.isEmpty)
        XCTAssertThrowsError(try store.sendRequest(id: SendRequestID("srq_drf_composer_request")))
    }

    @MainActor
    func testPendingSendRejectsComposerWithoutSavingOrScheduling() async throws {
        let composer = RecordingComposer()
        let scheduler = PendingComposerSendScheduler()
        let viewModel = ComposerViewModel(composer: composer, sendScheduler: scheduler)
        viewModel.to = "alice@example.com"
        viewModel.subject = "Second message"
        viewModel.bodyPlain = "This must remain in the open composer."

        let didSchedule = try await viewModel.send()

        XCTAssertFalse(didSchedule)
        XCTAssertFalse(viewModel.isSendScheduled)
        XCTAssertNil(viewModel.lastDraftID)
        XCTAssertEqual(viewModel.statusMessage, "A send is already pending")
        XCTAssertEqual(composer.saveCallCount, 0)
        XCTAssertEqual(scheduler.scheduleCallCount, 0)
    }

    @MainActor
    func testSendBlockedReasonStopsSendWithoutSavingOrScheduling() async throws {
        let composer = RecordingComposer()
        let scheduler = RecordingComposerSendScheduler()
        let viewModel = ComposerViewModel(composer: composer, sendScheduler: scheduler)
        viewModel.to = "alice@example.com"
        viewModel.subject = "Read-only"
        viewModel.bodyPlain = "This account can't send."
        XCTAssertTrue(viewModel.canSend)

        viewModel.sendBlockedReason = "Sending is paused while this account is read-only."
        XCTAssertFalse(viewModel.canSend)
        XCTAssertTrue(viewModel.canSaveDraft, "the draft can still be kept")
        let didSchedule = try await viewModel.send()

        XCTAssertFalse(didSchedule)
        XCTAssertEqual(composer.saveCallCount, 0)
        XCTAssertTrue(scheduler.scheduledDrafts.isEmpty)

        viewModel.sendBlockedReason = nil
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testAttachmentImportReadsOffTheMainThreadAndSendWaitsForIt() async throws {
        let viewModel = ComposerViewModel(composer: RecordingComposer(), sendScheduler: RecordingComposerSendScheduler())
        viewModel.to = "alice@example.com"
        viewModel.subject = "Files"
        viewModel.bodyPlain = "Two files."
        let reader = BlockingAttachmentReader()
        let urls = [URL(fileURLWithPath: "/picked/a.pdf"), URL(fileURLWithPath: "/picked/b.pdf")]

        let importing = Task { await viewModel.importAttachments(from: urls, read: reader.read) }
        await reader.waitForReads(1)
        XCTAssertEqual(viewModel.attachmentImport, ComposerAttachmentImport(filename: "a.pdf", completed: 0, total: 2))
        XCTAssertFalse(viewModel.canSend, "Send waits for the picked files")
        reader.releaseOne()
        await reader.waitForReads(2)
        XCTAssertEqual(viewModel.attachmentImport, ComposerAttachmentImport(filename: "b.pdf", completed: 1, total: 2))
        XCTAssertEqual(viewModel.attachments.map(\.filename), ["a.pdf"])
        reader.releaseOne()
        let failures = await importing.value

        XCTAssertEqual(failures, [])
        XCTAssertEqual(viewModel.attachments.map(\.filename), ["a.pdf", "b.pdf"])
        XCTAssertEqual(reader.existingCounts, [0, 1], "each file is checked against the ones already attached")
        XCTAssertEqual(reader.readsOnMainThread, [false, false])
        XCTAssertNil(viewModel.attachmentImport)
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testAttachmentImportNamesRefusedFiles() async {
        let viewModel = ComposerViewModel(composer: RecordingComposer())
        let failures = await viewModel.importAttachments(
            from: [URL(fileURLWithPath: "/picked/huge.mov"), URL(fileURLWithPath: "/picked/gone.txt")]
        ) { url, _ in
            if url.lastPathComponent == "huge.mov" { throw MobileAttachmentImport.Failure.fileTooLarge }
            throw CocoaError(.fileReadNoSuchFile)
        }
        XCTAssertEqual(failures, [
            "huge.mov: That file is too large to attach (limit 2 MB).",
            "gone.txt: Plainpost couldn't read that file.",
        ])
        XCTAssertTrue(viewModel.attachments.isEmpty)
        XCTAssertNil(viewModel.attachmentImport)
    }

    @MainActor
    func testReplacingTheDraftDropsAnAttachmentImportInProgress() async {
        let viewModel = ComposerViewModel(composer: RecordingComposer())
        let reader = BlockingAttachmentReader()
        let importing = Task {
            await viewModel.importAttachments(from: [URL(fileURLWithPath: "/picked/late.pdf")], read: reader.read)
        }
        await reader.waitForReads(1)
        viewModel.prepareNewMessage()
        XCTAssertNil(viewModel.attachmentImport)
        reader.releaseOne()
        _ = await importing.value

        XCTAssertTrue(viewModel.attachments.isEmpty, "a late file never lands in the new draft")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    @MainActor
    func testRestoringReplySnapshotPreservesThreadMetadataWhenSaving() async throws {
        let store = InMemoryMailStore()
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_restored_reply") }
            )
        )
        let replyContext = ComposerReplyContext(
            sourceThreadID: ThreadID("thr_project"),
            sourceMessageID: MessageID("msg_source"),
            rfcMessageID: "<source@example.com>",
            sourceInReplyTo: "<root@example.com>",
            references: ["<older@example.com>"],
            recipient: "alice@example.com",
            subject: "Project update",
            senderName: "Alice",
            dateLabel: "Today",
            quotedBody: "Original message"
        )
        let snapshot = ComposerRestoreSnapshot(
            to: "alice@example.com",
            cc: "",
            bcc: "",
            subject: "Re: Project update",
            bodyMarkdown: "Original reply",
            presentationMode: .reply(recipient: "alice@example.com", subject: "Project update"),
            replyContext: replyContext,
            includesQuotedHistory: false
        )

        viewModel.restore(from: snapshot)
        viewModel.bodyMarkdown = "Updated reply"
        try await viewModel.saveDraft()

        let draft = try store.draft(id: DraftID("drf_restored_reply"))
        XCTAssertEqual(draft.sourceThreadID, ThreadID("thr_project"))
        XCTAssertEqual(draft.inReplyTo, "<source@example.com>")
        XCTAssertEqual(draft.references, ["<older@example.com>", "<root@example.com>", "<source@example.com>"])
        XCTAssertEqual(draft.bodyMarkdown, "Updated reply")
    }

    /// A draft listed in the Drafts folder reopens as it was saved: its quote
    /// is already in the body, so saving it again neither drops nor doubles it.
    @MainActor
    func testReopenedSavedReplyDraftSavesBackUnchanged() async throws {
        let store = InMemoryMailStore()
        let saved = Draft(
            id: DraftID("drf_saved_reply"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("jeremy@example.com")],
            cc: [EmailAddress("team@example.com")],
            bcc: [],
            subject: "Re: Kundenrückfrage",
            bodyPlain: "Thanks.\n\nOn Oct 5, Jeremy wrote:\n> Hello",
            bodyMarkdown: "Thanks.\n\nOn Oct 5, Jeremy wrote:\n> Hello",
            createdBy: PlainpostFixtures.guiUser.id,
            aiGenerated: false,
            sourceThreadID: ThreadID("thr_helsana"),
            inReplyTo: "<source@example.com>",
            references: ["<root@example.com>", "<source@example.com>"]
        )
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_saved_reply") }
            )
        )

        viewModel.restore(from: ComposerRestoreSnapshot(savedDraft: saved, sourceMessageID: MessageID("msg_source")))
        XCTAssertEqual(viewModel.lastDraftID, "drf_saved_reply")
        XCTAssertEqual(viewModel.replyContext?.sourceMessageID, MessageID("msg_source"))
        XCTAssertFalse(viewModel.hasUnsavedChanges, "a reopened saved draft is not an edit")
        try await viewModel.saveDraft()

        let resaved = try store.draft(id: DraftID("drf_saved_reply"))
        XCTAssertEqual(resaved.bodyMarkdown, saved.bodyMarkdown)
        XCTAssertEqual(resaved.to, saved.to)
        XCTAssertEqual(resaved.cc, saved.cc)
        XCTAssertEqual(resaved.subject, saved.subject)
        XCTAssertEqual(resaved.sourceThreadID, saved.sourceThreadID)
        XCTAssertEqual(resaved.inReplyTo, saved.inReplyTo)
        XCTAssertEqual(resaved.references, saved.references)
    }

    @MainActor
    func testReopenedSavedNewMessageDraftHasNoReplyContext() {
        let saved = Draft(
            id: DraftID("drf_saved_new"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [], cc: [], bcc: [],
            subject: "",
            bodyPlain: "Idea",
            createdBy: PlainpostFixtures.guiUser.id,
            aiGenerated: false,
            sourceThreadID: nil
        )
        let snapshot = ComposerRestoreSnapshot(savedDraft: saved, sourceMessageID: nil)
        XCTAssertNil(snapshot.replyContext)
        XCTAssertEqual(snapshot.presentationMode, .newMessage)
        XCTAssertEqual(snapshot.draftID, "drf_saved_new")
        XCTAssertEqual(snapshot.fromAccountID, AccountID("acc_personal"))
    }

    @MainActor
    func testUnsavedChangesFollowEditsSavesAndPreparedContent() async throws {
        let viewModel = ComposerViewModel(composer: RecordingComposer())
        XCTAssertFalse(viewModel.hasUnsavedChanges, "a fresh composer has nothing to lose")

        // Prepared content alone is not an edit.
        viewModel.prepareReply(to: "alice@example.com", subject: "Project")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        viewModel.prepareNewMessage()
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.to = "alice@example.com"
        viewModel.subject = "Update"
        viewModel.bodyPlain = "Typed text"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        try await viewModel.saveDraft()
        XCTAssertFalse(viewModel.hasUnsavedChanges, "a saved draft is safe")

        viewModel.bodyPlain = "Typed text, more"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        // Clearing every field leaves nothing to lose.
        viewModel.to = ""
        viewModel.subject = ""
        viewModel.bodyPlain = ""
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        // An AI body is new content until it is saved.
        viewModel.prepareAIDraftReply(to: "alice@example.com", subject: "Project", bodyMarkdown: "Drafted by AI")
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    @MainActor
    func testFailedSaveKeepsUnsavedChanges() async throws {
        let viewModel = ComposerViewModel(composer: UnavailableComposerDraftHandler())
        viewModel.to = "alice@example.com"
        viewModel.subject = "Update"
        viewModel.bodyPlain = "Typed text"

        try await viewModel.saveDraft()

        XCTAssertEqual(viewModel.statusMessage, "No authenticated sender identity is available for this account.")
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    @MainActor
    func testEditDuringSaveStaysUnsaved() async throws {
        let gate = ComposerSaveGate()
        let viewModel = ComposerViewModel(composer: RecordingComposer(), asyncComposer: GatedAsyncComposer(gate: gate))
        viewModel.to = "alice@example.com"
        viewModel.subject = "Update"
        viewModel.bodyPlain = "First"

        let saving = Task { try await viewModel.saveDraft() }
        await gate.waitUntilStarted()
        viewModel.bodyPlain = "First, then more while saving"
        await gate.release()
        try await saving.value

        XCTAssertTrue(viewModel.hasUnsavedChanges, "text typed during the save was not saved")
    }

    @MainActor
    func testRestoreIsUnsavedOnlyWithoutASavedDraft() {
        let viewModel = ComposerViewModel(composer: RecordingComposer())
        let saved = ComposerRestoreSnapshot(
            to: "alice@example.com", cc: "", bcc: "", subject: "Update", bodyMarkdown: "Body",
            presentationMode: .newMessage, replyContext: nil, includesQuotedHistory: false, draftID: "drf_saved"
        )
        viewModel.restore(from: saved)
        XCTAssertFalse(viewModel.hasUnsavedChanges, "a restored draft is already saved")

        let unsaved = ComposerRestoreSnapshot(
            to: "alice@example.com", cc: "", bcc: "", subject: "Update", bodyMarkdown: "Body",
            presentationMode: .newMessage, replyContext: nil, includesQuotedHistory: false
        )
        viewModel.restore(from: unsaved)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    @MainActor
    func testScheduledSendLeavesNoUnsavedChanges() async throws {
        let viewModel = ComposerViewModel(composer: RecordingComposer(), sendScheduler: RecordingComposerSendScheduler())
        viewModel.to = "alice@example.com"
        viewModel.subject = "Update"
        viewModel.bodyPlain = "Body"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        let scheduled = try await viewModel.send()

        XCTAssertTrue(scheduled)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    /// Ledger Task 21: Undo in the undo-send window reopens the draft as saved, not as unsaved
    /// changes.
    @MainActor
    func testUndoSendReopensTheDraftAsSaved() async throws {
        let store = InMemoryMailStore()
        let undoSend = UndoSendCoordinator(sender: UnconfiguredDirectComposerSender(), delay: .seconds(600))
        let viewModel = ComposerViewModel(
            composer: ComposerDraftService(
                store: store,
                accountID: AccountID("acc_personal"),
                from: EmailAddress("me@example.com"),
                actor: PlainpostFixtures.guiUser,
                idGenerator: { DraftID("drf_undo_send") }
            ),
            sendScheduler: undoSend
        )
        viewModel.to = "alice@example.com"
        viewModel.subject = "Undo me"
        viewModel.bodyPlain = "Sent, then undone."
        let scheduled = try await viewModel.send()
        XCTAssertTrue(scheduled)

        let snapshot = try XCTUnwrap(undoSend.undoLatestSend())
        viewModel.restore(from: snapshot)

        XCTAssertEqual(viewModel.lastDraftID, "drf_undo_send")
        XCTAssertFalse(viewModel.hasUnsavedChanges, "the reopened draft is the saved one")
        XCTAssertEqual(try store.draft(id: DraftID("drf_undo_send")).subject, "Undo me")
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testComposerActivityPublishesOnlyChanges() {
        let activity = PlainpostComposerActivity()
        var received: [Bool] = []
        let observation = activity.unsavedOpenComposerPublisher.sink { received.append($0) }
        defer { observation.cancel() }

        activity.update(hasUnsavedOpenComposer: true)
        activity.update(hasUnsavedOpenComposer: true)
        activity.update(hasUnsavedOpenComposer: false)

        XCTAssertFalse(activity.hasUnsavedOpenComposer)
        XCTAssertEqual(received, [false, true, false])
    }

    // The root reporting its open composer to the runtime (so a notification tap defers and
    // shows "Save or close the draft to open the notification.") used to be checked here by
    // grepping source text for the wiring, which is brittle (any rename or reformat breaks it)
    // and doesn't exercise the SwiftUI modifier at all. That behaviour is covered end-to-end by
    // `testDeferredNotificationLineShowsInCompose` (MobileMailUITests.swift), which drives a real
    // composer with unsaved changes through a real notification tap. Final-review Minor 5.
}

private actor RecordingMutationCapability: MailMutationServing {
    var intents: [MailMutationIntent] = []
    let deleteState: String

    init(deleteState: String = "applied") { self.deleteState = deleteState }

    func apply(canonicalOperation: Data) async throws -> MailMutationResult {
        MailMutationResult(idempotencyKey: "unused", state: "applied")
    }

    func perform(_ intent: MailMutationIntent) async throws -> MailMutationResult {
        intents.append(intent)
        if case .deleteDraft = intent {
            return MailMutationResult(idempotencyKey: "msg-node", state: deleteState)
        }
        return MailMutationResult(idempotencyKey: "msg-node", state: "applied")
    }
}

private final class LockedSender: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: EmailAddress?

    var value: EmailAddress? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

@MainActor
private final class RecordingComposerSendScheduler: ComposerSendScheduling {
    private(set) var scheduledDrafts: [Draft] = []
    private(set) var snapshots: [ComposerRestoreSnapshot] = []

    var isSendPending: Bool { false }

    func schedule(draft: Draft, restoring snapshot: ComposerRestoreSnapshot) -> Bool {
        scheduledDrafts.append(draft)
        snapshots.append(snapshot)
        return true
    }
}

private final class PendingComposerSendScheduler: ComposerSendScheduling {
    var isSendPending: Bool { true }
    private(set) var scheduleCallCount = 0

    func schedule(draft: Draft, restoring snapshot: ComposerRestoreSnapshot) -> Bool {
        scheduleCallCount += 1
        return false
    }
}

private final class LockedDraftIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> DraftID {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return DraftID("drf_persistent_\(value)")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RecordingComposer: ComposerHandling, @unchecked Sendable {
    private(set) var saveCallCount = 0

    func saveDraft(input: ComposerDraftInput) throws -> Draft {
        saveCallCount += 1
        return Draft(
            id: DraftID("drf_unexpected"),
            accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: input.subject,
            bodyPlain: input.bodyPlain,
            createdBy: "test",
            aiGenerated: false,
            sourceThreadID: nil
        )
    }
}

private actor ComposerSaveGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func enter() async {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }

    func waitUntilStarted() async {
        for _ in 0..<300 where !started {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started, "save never started")
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedAsyncComposer: AsyncComposerHandling {
    let gate: ComposerSaveGate

    func saveDraft(input: ComposerDraftInput) async throws -> Draft {
        await gate.enter()
        return Draft(
            id: DraftID("drf_gated"), accountID: AccountID("acc_personal"),
            from: EmailAddress("me@example.com"), to: [EmailAddress("alice@example.com")],
            cc: [], bcc: [], subject: input.subject, bodyPlain: input.bodyPlain,
            createdBy: "test", aiGenerated: false, sourceThreadID: nil
        )
    }
}

/// Reads a picked file on whatever thread calls it, blocking until the test releases it.
final class BlockingAttachmentReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var mainThreadFlags: [Bool] = []
    private var existing: [Int] = []

    var readsOnMainThread: [Bool] { lock.withLock { mainThreadFlags } }
    var existingCounts: [Int] { lock.withLock { existing } }

    func read(_ url: URL, _ attached: [DraftAttachment]) throws -> DraftAttachment {
        let onMain = Thread.isMainThread
        lock.withLock {
            mainThreadFlags.append(onMain)
            existing.append(attached.count)
        }
        gate.wait()
        return DraftAttachment(id: url.lastPathComponent, filename: url.lastPathComponent, mimeType: "application/pdf", data: Data([1]))
    }

    func releaseOne() { gate.signal() }

    /// Waits until `count` reads have started.
    func waitForReads(_ count: Int) async {
        while lock.withLock({ existing.count }) < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
