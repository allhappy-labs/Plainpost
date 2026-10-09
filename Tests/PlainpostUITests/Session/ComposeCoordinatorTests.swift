import XCTest
import PlainpostAI
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class ComposeCoordinatorTests: XCTestCase {
    private func message(id: String = "m1", from: String = "maria@northwind.example") -> ThreadMessageModel {
        ThreadMessageModel(
            id: id, sender: from, senderDisplayName: "Maria Chen", replyTo: nil, dateLabel: "Sep 26",
            body: .plainText("Hello"), sourceThreadID: ThreadID("t1"), rfcMessageID: "<m1@x>",
            inReplyTo: nil, references: [], attachments: []
        )
    }

    private func planningThread(_ messages: [ThreadMessageModel]? = nil) -> ThreadDetailModel {
        ThreadDetailModel(
            subject: "Planning", participants: [], summaryStatus: "", actionItems: [], availableActions: [],
            messages: messages ?? [message()]
        )
    }

    private func make(
        policy: ComposerPresentationPolicy,
        thread: ThreadDetailModel?,
        undoSend: UndoSendCoordinator = .preview(state: .sent),
        aiAssistant: ThreadAIAssistantViewModel = .preview(),
        ownAddresses: Set<String> = [],
        loadForwardAttachments: @escaping (String) async -> (attachments: [DraftAttachment], unavailable: [String]) = { _ in ([], []) }
    ) -> ComposeCoordinator {
        ComposeCoordinator(
            composer: .preview(), undoSend: undoSend, policy: policy,
            aiAssistant: aiAssistant, thread: { thread },
            ownAddresses: { ownAddresses },
            loadForwardAttachments: loadForwardAttachments
        )
    }

    // MARK: - An account removed under an open composer

    private final class AccountList {
        var accounts: [Account]
        init(_ accounts: [Account]) { self.accounts = accounts }
    }

    private func account(_ id: String) -> Account {
        Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.com"),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    /// A coordinator whose composer sends from `list`'s accounts, New Message open from the first.
    private func makeWithAccounts(_ list: AccountList) async -> ComposeCoordinator {
        let composer = ComposerViewModel(
            composer: UnavailableComposerDraftHandler(),
            fromAccounts: ComposerFromAccounts(
                accounts: { list.accounts }, defaultAccountID: { list.accounts.first?.id },
                owner: { _ in nil }, makeComposer: { _ in UnavailableComposerDraftHandler() }
            )
        )
        let coordinator = ComposeCoordinator(
            composer: composer, undoSend: .preview(state: .sent), policy: .embedded,
            aiAssistant: .preview(), thread: { nil }
        )
        _ = await coordinator.request(.new)
        return coordinator
    }

    func testARemovedAccountsEmptyDraftClosesWithoutAsking() async {
        let list = AccountList([account("home"), account("work")])
        let coordinator = await makeWithAccounts(list)
        XCTAssertEqual(coordinator.composer.fromAccountID, AccountID("home"))
        list.accounts = [account("work")]
        coordinator.accountsChanged()
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(coordinator.asksToDiscardRemovedAccountDraft)
    }

    func testARemovedAccountsDraftWithTextAsksBeforeDiscarding() async {
        let list = AccountList([account("home"), account("work")])
        let coordinator = await makeWithAccounts(list)
        coordinator.composer.bodyMarkdown = "Half a thought"
        list.accounts = [account("work")]
        coordinator.accountsChanged()
        XCTAssertTrue(coordinator.isPresented, "nothing is lost before the user answers")
        XCTAssertTrue(coordinator.asksToDiscardRemovedAccountDraft)
        XCTAssertEqual(coordinator.composer.sendBlockedReason, ComposerViewModel.removedFromAccountReason)
        XCTAssertNil(coordinator.composer.fromAccountID, "never moved to another account")
        coordinator.discardRemovedAccountDraft()
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(coordinator.asksToDiscardRemovedAccountDraft)
    }

    func testKeepingTheDraftLeavesItOpenWithSendBlocked() async {
        let list = AccountList([account("home"), account("work")])
        let coordinator = await makeWithAccounts(list)
        coordinator.composer.bodyMarkdown = "Half a thought"
        list.accounts = [account("work")]
        coordinator.accountsChanged()
        coordinator.asksToDiscardRemovedAccountDraft = false
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertFalse(coordinator.composer.canSend)
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "Half a thought")
    }

    func testAnotherAccountsRemovalLeavesTheComposerAlone() async {
        let list = AccountList([account("home"), account("work")])
        let coordinator = await makeWithAccounts(list)
        coordinator.composer.bodyMarkdown = "Half a thought"
        list.accounts = [account("home")]
        coordinator.accountsChanged()
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertFalse(coordinator.asksToDiscardRemovedAccountDraft)
        XCTAssertEqual(coordinator.composer.fromAccountID, AccountID("home"))
        XCTAssertNil(coordinator.composer.sendBlockedReason)
    }

    func testNewMessageIsEmbeddedForEmbeddedPolicy() async {
        let coordinator = make(policy: .embedded, thread: nil)
        let presentation = await coordinator.request(.new)
        XCTAssertEqual(presentation, .embedded)
        XCTAssertTrue(coordinator.isPresented)
    }

    func testReplyBuildsContextFromTheSelectedMessage() async {
        let coordinator = make(policy: .embedded, thread: planningThread())
        let presentation = await coordinator.request(.reply(messageID: "m1"))
        XCTAssertEqual(presentation, .embedded)
        XCTAssertEqual(coordinator.composer.replyContext?.recipient, "maria@northwind.example")
        XCTAssertEqual(coordinator.composer.subject, "Re: Planning")
    }

    func testReplyToUnknownMessagePresentsNothing() async {
        let coordinator = make(policy: .embedded, thread: nil)
        let presentation = await coordinator.request(.reply(messageID: "missing"))
        XCTAssertEqual(presentation, ComposePresentation.none)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testRuntimeWindowPolicyAsksForAWindow() async {
        let coordinator = make(policy: .runtimeWindow, thread: nil)
        guard case .window = await coordinator.request(.new) else {
            return XCTFail("expected a window request")
        }
    }

    func testRuntimeWindowReplyNeedsNoLoadedThread() async {
        let coordinator = make(policy: .runtimeWindow, thread: nil)
        let presentation = await coordinator.request(.reply(messageID: "m9"))
        XCTAssertEqual(presentation, .window(.reply(sourceMessageID: "m9")))
        XCTAssertFalse(coordinator.isPresented)
    }

    func testRuntimeWindowReplyAllNeedsNoLoadedThread() async {
        let coordinator = make(policy: .runtimeWindow, thread: nil)
        let presentation = await coordinator.request(.replyAll(messageID: "m9"))
        XCTAssertEqual(presentation, .window(.replyAll(sourceMessageID: "m9")))
        XCTAssertFalse(coordinator.isPresented)
    }

    func testSnapshotWindowPolicyOpensThePreparedDraft() async {
        let coordinator = make(policy: .snapshotWindow, thread: planningThread())
        let presentation = await coordinator.request(.reply(messageID: "m1"))
        XCTAssertEqual(presentation, .window(.restore(coordinator.composer.restorationSnapshot)))
        XCTAssertEqual(coordinator.composer.subject, "Re: Planning")
        XCTAssertFalse(coordinator.isPresented)
    }

    func testReplySourceFallsBackToTheLastMessage() {
        let thread = planningThread([message(id: "m1"), message(id: "m2")])
        XCTAssertEqual(ComposeCoordinator.replySourceMessageID(selectedMessageID: "m1", in: thread), "m1")
        XCTAssertEqual(ComposeCoordinator.replySourceMessageID(selectedMessageID: "gone", in: thread), "m2")
        XCTAssertEqual(ComposeCoordinator.replySourceMessageID(selectedMessageID: nil, in: thread), "m2")
        XCTAssertNil(ComposeCoordinator.replySourceMessageID(selectedMessageID: nil, in: planningThread([])))
    }

    func testReplyContextUsesTheGivenRecipient() {
        let context = ComposeCoordinator.replyContext(for: message(), subject: "Planning", recipient: "team@x.example")
        XCTAssertEqual(context?.recipient, "team@x.example")
        XCTAssertEqual(context?.senderName, "Maria Chen")
        XCTAssertEqual(context?.sourceMessageID, MessageID("m1"))
        XCTAssertEqual(
            ComposeCoordinator.replyContext(for: message(), subject: "Planning", recipient: nil)?.recipient,
            "maria@northwind.example"
        )
    }

    func testAskMailDraftReplyPrefillsTheGivenBody() async {
        let coordinator = make(policy: .embedded, thread: planningThread())
        let presentation = await coordinator.request(
            .aiDraftReply(messageID: "m1", bodyMarkdown: "Sounds good.", recipient: "maria@northwind.example")
        )
        XCTAssertEqual(presentation, .embedded)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.composer.replyContext?.sourceMessageID, MessageID("m1"))
        XCTAssertTrue(coordinator.composer.bodyMarkdown.contains("Sounds good."))
    }

    func testRuntimeWindowAskMailDraftNeedsNoLoadedThread() async {
        let coordinator = make(policy: .runtimeWindow, thread: nil)
        let presentation = await coordinator.request(
            .aiDraftReply(messageID: "m1", bodyMarkdown: "Body", recipient: "a@x.example")
        )
        XCTAssertEqual(
            presentation,
            .window(.aiReply(sourceMessageID: "m1", bodyMarkdown: "Body", recipient: "a@x.example"))
        )
    }

    // MARK: ✦ Draft with AI inside an open composer (Ruling 23)

    func testDraftBodyWithAIFillsOnlyTheBody() async throws {
        let backend = RecordingDraftAssistant(body: "Tuesday at 10 works.")
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        let composer = coordinator.composer
        composer.to = "maria@northwind.example, lee@northwind.example"
        composer.cc = "ops@northwind.example"
        composer.bcc = "me@example.com"
        composer.subject = "Re: Planning — agenda"
        composer.attachments = [DraftAttachment(id: "a1", filename: "agenda.pdf", mimeType: "application/pdf", data: Data([1]))]
        composer.bodyMarkdown = "My own words"
        try await composer.saveDraft()
        let draftID = try XCTUnwrap(composer.lastDraftID)
        let context = composer.replyContext

        let result = await coordinator.draftBodyWithAI()

        XCTAssertEqual(result, .filled(previousBody: "My own words"))
        XCTAssertTrue(composer.bodyMarkdown.contains("Tuesday at 10 works."), composer.bodyMarkdown)
        XCTAssertEqual(composer.to, "maria@northwind.example, lee@northwind.example")
        XCTAssertEqual(composer.cc, "ops@northwind.example")
        XCTAssertEqual(composer.bcc, "me@example.com")
        XCTAssertEqual(composer.subject, "Re: Planning — agenda")
        XCTAssertEqual(composer.attachments.map(\.id), ["a1"])
        XCTAssertEqual(composer.lastDraftID, draftID, "the saved draft keeps its identity")
        XCTAssertEqual(composer.replyContext, context)
        XCTAssertTrue(composer.hasUnsavedChanges, "the new body is an edit to save")
    }

    func testDraftBodyWithAIDraftsForTheRepliedToMessageNotTheSelection() async {
        let backend = RecordingDraftAssistant(body: "Reply to the second one")
        let assistant = ThreadAIAssistantViewModel(assistant: backend)
        // The reader shows m1, so the assistant is prepared for it; the reply is to m2.
        assistant.prepareSummary(for: EmailSummaryContext(messageID: MessageID("m1"), contentFingerprint: "v1"))
        let coordinator = make(
            policy: .embedded,
            thread: planningThread([message(id: "m1"), message(id: "m2", from: "lee@northwind.example")]),
            aiAssistant: assistant
        )
        _ = await coordinator.request(.reply(messageID: "m2"))

        let result = await coordinator.draftBodyWithAI()

        XCTAssertEqual(result, .filled(previousBody: ""))
        let requested = await backend.requestedMessageIDs
        XCTAssertEqual(requested, [MessageID("m2")])
        XCTAssertEqual(coordinator.composer.to, "lee@northwind.example")
    }

    func testDraftBodyWithAIFailureLeavesTheBodyAndSaysWhy() async {
        let backend = RecordingDraftAssistant(body: nil)
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        coordinator.composer.bodyMarkdown = "Keep me"

        let result = await coordinator.draftBodyWithAI()

        XCTAssertEqual(result, .failed("Reply draft unavailable. Try again."))
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "Keep me")
    }

    func testDraftBodyWithAIReportsUnavailableAI() async {
        let backend = RecordingDraftAssistant(body: "unused")
        let assistant = ThreadAIAssistantViewModel(assistant: backend) { _ in
            AIActionAvailability(isAvailable: false, reason: "Apple Intelligence is off.")
        }
        let coordinator = make(policy: .embedded, thread: planningThread(), aiAssistant: assistant)
        _ = await coordinator.request(.reply(messageID: "m1"))

        let result = await coordinator.draftBodyWithAI()

        XCTAssertEqual(result, .failed("Apple Intelligence is off."))
        let requested = await backend.requestedMessageIDs
        XCTAssertEqual(requested, [])
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "")
    }

    func testDraftBodyWithAINeedsAReplyContext() async {
        let backend = RecordingDraftAssistant(body: "unused")
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.new)
        coordinator.composer.bodyMarkdown = "Hello"

        let result = await coordinator.draftBodyWithAI()

        XCTAssertEqual(result, .failed("Draft with AI needs a message to reply to."))
        let requested = await backend.requestedMessageIDs
        XCTAssertEqual(requested, [])
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "Hello")
    }

    func testDraftBodyWithAIIsDroppedWhenTheComposerMovesOnWhileDrafting() async {
        let backend = GatedDraftAssistant()
        let coordinator = make(
            policy: .embedded,
            thread: planningThread([message(id: "m1"), message(id: "m2")]),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.reply(messageID: "m1"))

        let pending = Task { await coordinator.draftBodyWithAI() }
        await backend.waitForRequest()
        _ = await coordinator.request(.reply(messageID: "m2"))
        await backend.resolve()

        let result = await pending.value
        XCTAssertEqual(result, .failed("The message changed while the AI was writing, so its draft wasn't used."))
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "")
        XCTAssertEqual(coordinator.composer.replyContext?.sourceMessageID, MessageID("m2"))
    }

    func testClosingTheSheetDropsAnAttachmentImportInProgress() async {
        let coordinator = make(policy: .embedded, thread: nil)
        _ = await coordinator.request(.new)
        let reader = BlockingAttachmentReader()
        let composer = coordinator.composer
        let importing = Task {
            await composer.importAttachments(from: [URL(fileURLWithPath: "/picked/late.pdf")], read: reader.read)
        }
        await reader.waitForReads(1)

        coordinator.isPresented = false
        reader.releaseOne()
        _ = await importing.value

        XCTAssertTrue(composer.attachments.isEmpty, "a file read after the sheet closed isn't attached")
        XCTAssertNil(composer.attachmentImport)
        XCTAssertFalse(composer.hasUnsavedChanges)
    }

    /// Ledger Task 21: closing the sheet mid-draft (Save Draft, say) leaves the composer as
    /// it was; the AI text doesn't land in it unseen.
    func testDraftBodyWithAIIsDroppedWhenTheComposerClosesWhileDrafting() async {
        let backend = GatedDraftAssistant()
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        coordinator.composer.bodyMarkdown = "Mine"

        let pending = Task { await coordinator.draftBodyWithAI() }
        await backend.waitForRequest()
        coordinator.isPresented = false
        await backend.resolve()

        let result = await pending.value
        XCTAssertEqual(result, .failed("The message was closed while the AI was writing, so its draft wasn't used."))
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "Mine")
    }

    /// Ledger Task 21: Send is off while Draft with AI writes the body.
    func testSendWaitsWhileDraftWithAIWrites() async {
        let backend = GatedDraftAssistant()
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: backend)
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        let composer = coordinator.composer
        composer.bodyMarkdown = "Ready to send"
        XCTAssertTrue(composer.canSend)

        let pending = Task { await coordinator.draftBodyWithAI() }
        await backend.waitForRequest()
        XCTAssertTrue(composer.isDraftingAIBody)
        XCTAssertFalse(composer.canSend, "the body is about to change")
        let second = await coordinator.draftBodyWithAI()
        XCTAssertEqual(second, .failed("Draft with AI is already writing this message."))
        await backend.resolve()
        _ = await pending.value

        XCTAssertFalse(composer.isDraftingAIBody)
        XCTAssertTrue(composer.canSend)
    }

    /// Ledger Task 21: Undo of an AI body on a saved draft leaves the draft saved.
    func testUndoingAnAIBodyOnASavedDraftLeavesItSaved() async throws {
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: RecordingDraftAssistant(body: "AI words"))
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        let composer = coordinator.composer
        composer.bodyMarkdown = "My own words"
        try await composer.saveDraft()
        XCTAssertFalse(composer.hasUnsavedChanges)

        guard case let .filled(previous) = await coordinator.draftBodyWithAI() else { return XCTFail("no AI body") }
        XCTAssertTrue(composer.hasUnsavedChanges)
        composer.undoAIDraftBody(previous)

        XCTAssertEqual(composer.bodyMarkdown, "My own words")
        XCTAssertFalse(composer.hasUnsavedChanges, "the draft is back to what was saved")
        XCTAssertNotNil(composer.lastDraftID)
    }

    func testUndoingAnAIBodyAfterAnotherEditOrASaveStaysUnsaved() async throws {
        let coordinator = make(
            policy: .embedded,
            thread: planningThread(),
            aiAssistant: ThreadAIAssistantViewModel(assistant: RecordingDraftAssistant(body: "AI words"))
        )
        _ = await coordinator.request(.reply(messageID: "m1"))
        let composer = coordinator.composer
        composer.bodyMarkdown = "My own words"
        try await composer.saveDraft()

        guard case let .filled(previous) = await coordinator.draftBodyWithAI() else { return XCTFail("no AI body") }
        composer.subject = "Re: Planning, edited"
        composer.undoAIDraftBody(previous)
        XCTAssertTrue(composer.hasUnsavedChanges, "the subject edit is still unsaved")

        guard case let .filled(again) = await coordinator.draftBodyWithAI() else { return XCTFail("no AI body") }
        try await composer.saveDraft()
        composer.undoAIDraftBody(again)
        XCTAssertTrue(composer.hasUnsavedChanges, "the saved draft holds the AI body, so Undo is an edit")
    }

    func testUndoLatestSendRestoresTheDraft() async {
        let snapshot = ComposerRestoreSnapshot.preview()
        let undoSend = UndoSendCoordinator.preview(state: .pending(snapshot: snapshot, deadline: .distantFuture))
        let coordinator = make(policy: .embedded, thread: nil, undoSend: undoSend)

        let presentation = await coordinator.request(.undoLatestSend)

        XCTAssertEqual(presentation, .embedded)
        XCTAssertEqual(coordinator.composer.subject, "Undo send")
        XCTAssertNil(undoSend.snackbarState)
    }

    func testUndoWithNothingPendingPresentsNothing() async {
        let coordinator = make(policy: .embedded, thread: nil)
        let presentation = await coordinator.request(.undoLatestSend)
        XCTAssertEqual(presentation, ComposePresentation.none)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testRestoreFailedSendUsesRuntimeWindow() async {
        let snapshot = ComposerRestoreSnapshot.preview()
        let undoSend = UndoSendCoordinator.preview(state: .failed(snapshot: snapshot))
        let coordinator = make(policy: .runtimeWindow, thread: nil, undoSend: undoSend)

        let presentation = await coordinator.request(.restoreFailedSend)

        XCTAssertEqual(presentation, .window(.restore(snapshot)))
        XCTAssertFalse(coordinator.isPresented)
    }

    func testForwardQuotesTheMessageAndAttachesItsFiles() async {
        let file = DraftAttachment(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", data: Data([1]))
        var requestedIDs: [String] = []
        let coordinator = make(policy: .embedded, thread: planningThread()) { messageID in
            requestedIDs.append(messageID)
            return ([file], ["photo.heic"])
        }

        let presentation = await coordinator.request(.forward(messageID: "m1"))

        XCTAssertEqual(presentation, .embedded)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(requestedIDs, ["m1"])
        XCTAssertEqual(coordinator.composer.subject, "Fwd: Planning")
        XCTAssertEqual(coordinator.composer.to, "")
        XCTAssertNil(coordinator.composer.replyContext)
        XCTAssertTrue(coordinator.composer.bodyMarkdown.contains("From: Maria Chen <maria@northwind.example>"))
        XCTAssertTrue(coordinator.composer.bodyMarkdown.contains("Hello"))
        XCTAssertEqual(coordinator.composer.attachments, [file])
        XCTAssertEqual(coordinator.composer.statusMessage, "Couldn't attach photo.heic. Forwarding without it.")
    }

    func testForwardOfUnknownMessagePresentsNothingAndLoadsNoFiles() async {
        var loaded = false
        let coordinator = make(policy: .embedded, thread: planningThread()) { _ in
            loaded = true
            return ([], [])
        }
        let presentation = await coordinator.request(.forward(messageID: "missing"))
        XCTAssertEqual(presentation, ComposePresentation.none)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(loaded)
    }

    func testRuntimeWindowForwardNeedsNoLoadedThread() async {
        var loaded = false
        let coordinator = make(policy: .runtimeWindow, thread: nil) { _ in
            loaded = true
            return ([], [])
        }
        let presentation = await coordinator.request(.forward(messageID: "m9"))
        XCTAssertEqual(presentation, .window(.forward(sourceMessageID: "m9")))
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(loaded)
    }

    func testSnapshotWindowForwardOpensThePreparedDraftWithItsFiles() async {
        let file = DraftAttachment(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", data: Data([1]))
        let coordinator = make(policy: .snapshotWindow, thread: planningThread()) { _ in ([file], []) }
        let presentation = await coordinator.request(.forward(messageID: "m1"))
        XCTAssertEqual(presentation, .window(.restore(coordinator.composer.restorationSnapshot)))
        XCTAssertEqual(coordinator.composer.restorationSnapshot.attachments, [file])
        XCTAssertEqual(coordinator.composer.subject, "Fwd: Planning")
        XCTAssertFalse(coordinator.isPresented)
    }

    /// A Reply issued while a Forward's files load wins: the late forward is dropped and
    /// the reply the user is typing survives, sendable and without a loading status.
    func testForwardSupersededByAReplyIsDroppedAndTheReplySurvives() async {
        let gate = ForwardFileGate()
        let coordinator = make(policy: .embedded, thread: planningThread()) { await gate.load($0) }

        let forward = Task { await coordinator.request(.forward(messageID: "m1")) }
        await gate.waitForLoads(1)
        let reply = await coordinator.request(.reply(messageID: "m1"))
        XCTAssertEqual(reply, .embedded)
        coordinator.composer.bodyMarkdown = "Typed while the forward loaded"

        let file = DraftAttachment(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", data: Data([1]))
        gate.resolve(0, with: ([file], ["photo.heic"]))
        let presentation = await forward.value

        XCTAssertEqual(presentation, ComposePresentation.none)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.composer.subject, "Re: Planning")
        XCTAssertEqual(coordinator.composer.replyContext?.recipient, "maria@northwind.example")
        XCTAssertEqual(coordinator.composer.bodyMarkdown, "Typed while the forward loaded")
        XCTAssertEqual(coordinator.composer.attachments, [])
        XCTAssertFalse(coordinator.composer.isLoadingForwardAttachments)
        XCTAssertTrue(coordinator.composer.canSend)
        XCTAssertEqual(coordinator.composer.displayStatusMessage, "Unsaved changes")
    }

    /// Tapping Forward twice: whichever load finishes last, only the newest forward is shown,
    /// and an older one arriving late never wipes what the user typed into it.
    func testOlderForwardFinishingLateDoesNotOverwriteTheNewerForward() async {
        let gate = ForwardFileGate()
        let coordinator = make(
            policy: .embedded,
            thread: planningThread([message(id: "m1"), message(id: "m2")])
        ) { await gate.load($0) }

        let first = Task { await coordinator.request(.forward(messageID: "m1")) }
        await gate.waitForLoads(1)
        let second = Task { await coordinator.request(.forward(messageID: "m2")) }
        await gate.waitForLoads(2)
        XCTAssertEqual(gate.requestedIDs, ["m1", "m2"])

        let newer = DraftAttachment(id: "a2", filename: "newer.pdf", mimeType: "application/pdf", data: Data([2]))
        gate.resolve(1, with: ([newer], []))
        let secondPresentation = await second.value
        XCTAssertEqual(secondPresentation, .embedded)
        coordinator.composer.to = "ben@x.example"
        coordinator.composer.bodyMarkdown = "FYI\n" + coordinator.composer.bodyMarkdown

        let older = DraftAttachment(id: "a1", filename: "older.pdf", mimeType: "application/pdf", data: Data([1]))
        gate.resolve(0, with: ([older], []))
        let firstPresentation = await first.value

        XCTAssertEqual(firstPresentation, ComposePresentation.none)
        XCTAssertEqual(coordinator.composer.to, "ben@x.example")
        XCTAssertTrue(coordinator.composer.bodyMarkdown.hasPrefix("FYI\n"))
        XCTAssertEqual(coordinator.composer.attachments, [newer])
        XCTAssertFalse(coordinator.composer.isLoadingForwardAttachments)
        XCTAssertTrue(coordinator.composer.canSend)
    }

    func testReplyAllBuildsContextWithCcFromTheSelectedMessage() async {
        let m = message()
        let withRecipients = ThreadMessageModel(
            id: m.id, sender: m.sender, senderDisplayName: m.senderDisplayName, replyTo: m.replyTo,
            dateLabel: m.dateLabel, body: .plainText("Hello"), sourceThreadID: m.sourceThreadID,
            rfcMessageID: m.rfcMessageID, inReplyTo: m.inReplyTo, references: m.references,
            attachments: m.attachments, to: ["me@northwind.example", "tom@northwind.example"], cc: ["ann@northwind.example"]
        )
        let coordinator = make(
            policy: .embedded, thread: planningThread([withRecipients]),
            ownAddresses: ["me@northwind.example"]
        )
        let presentation = await coordinator.request(.replyAll(messageID: "m1"))
        XCTAssertEqual(presentation, .embedded)
        XCTAssertEqual(coordinator.composer.replyContext?.recipient, "maria@northwind.example")
        XCTAssertEqual(coordinator.composer.subject, "Re: Planning")
        XCTAssertEqual(coordinator.composer.cc, "tom@northwind.example, ann@northwind.example")
    }

    func testReplyAllToUnknownMessagePresentsNothing() async {
        let coordinator = make(policy: .embedded, thread: nil)
        let presentation = await coordinator.request(.replyAll(messageID: "missing"))
        XCTAssertEqual(presentation, ComposePresentation.none)
        XCTAssertFalse(coordinator.isPresented)
    }
}

/// Records which messages it drafts for; answers with `body`, or fails when it's nil.
private actor RecordingDraftAssistant: ThreadAIAssistantHandling {
    private struct Unused: Error {}
    private struct Failed: Error {}
    private let body: String?
    private(set) var requestedMessageIDs: [MessageID] = []

    init(body: String?) { self.body = body }

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw Unused()
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        requestedMessageIDs.append(messageID)
        guard let body else { throw Failed() }
        return Draft(
            id: DraftID("drf_ai"),
            accountID: AccountID("acc_test"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("someone-else@example.com")],
            cc: [],
            bcc: [],
            subject: "AI subject",
            bodyPlain: body,
            createdBy: "local-user",
            aiGenerated: true,
            sourceThreadID: ThreadID("t1")
        )
    }
}

/// Holds the AI draft until the test resolves it, so the selection can change mid-draft.
private actor GatedDraftAssistant: ThreadAIAssistantHandling {
    private struct Unused: Error {}
    private var continuation: CheckedContinuation<Draft, Error>?

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw Unused()
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForRequest() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resolve() {
        continuation?.resume(returning: Draft(
            id: DraftID("drf_gated"),
            accountID: AccountID("acc_test"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("maria@northwind.example")],
            cc: [],
            bcc: [],
            subject: "Re: Planning",
            bodyPlain: "Gated reply",
            createdBy: "local-user",
            aiGenerated: true,
            sourceThreadID: ThreadID("t1")
        ))
        continuation = nil
    }
}

/// Holds each forward's file load until the test resolves it, in any order.
@MainActor
private final class ForwardFileGate {
    typealias Files = (attachments: [DraftAttachment], unavailable: [String])
    private(set) var requestedIDs: [String] = []
    private var continuations: [Int: CheckedContinuation<Files, Never>] = [:]

    func load(_ messageID: String) async -> Files {
        let index = requestedIDs.count
        requestedIDs.append(messageID)
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func waitForLoads(_ count: Int) async {
        while continuations.count < count || requestedIDs.count < count {
            await Task.yield()
        }
    }

    func resolve(_ index: Int, with files: Files) {
        continuations.removeValue(forKey: index)?.resume(returning: files)
    }
}
