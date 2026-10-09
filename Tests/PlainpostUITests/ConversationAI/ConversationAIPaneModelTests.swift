import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostUI

@MainActor
final class ConversationAIPaneModelTests: XCTestCase {
    // MARK: Draft

    func testDraftToneAndInstructionsReachTheAssistant() async {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        model.showDraft()

        await model.chooseTone(.formal)?.value
        model.chooseTone(.custom)
        model.draftInstructions = "  Ask for an extension "
        await model.submitCustomInstructions()?.value

        XCTAssertEqual(assistant.draftRequests.map(\.messageID), [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(assistant.draftRequests.map(\.tone), [.formal, .neutral])
        XCTAssertEqual(assistant.draftRequests.map(\.instructions), ["", "Ask for an extension"])
        XCTAssertEqual(model.draftState, .ready)
        XCTAssertEqual(model.draftPreview?.bodyPlain, "Reply in neutral: Ask for an extension")
    }

    func testToneChipsMapToDraftTones() {
        XCTAssertEqual(ConversationDraftTone.allCases.map(\.title), ["Short", "Friendly", "Formal", "Custom…"])
        XCTAssertEqual(ConversationDraftTone.allCases.map(\.draftTone), [.concise, .friendly, .formal, .neutral])
    }

    func testRegenerateReusesToneAndInstructions() async {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        model.chooseTone(.custom)
        model.draftInstructions = "Ask for an extension"
        await model.submitCustomInstructions()?.value

        await model.regenerateDraft()?.value

        XCTAssertEqual(assistant.draftRequests.count, 2)
        XCTAssertEqual(assistant.draftRequests.map(\.tone), [.neutral, .neutral])
        XCTAssertEqual(assistant.draftRequests.map(\.instructions), ["Ask for an extension", "Ask for an extension"])
    }

    func testEditInComposeDispatchesTheAIDraftReplyWithThePreviewBody() async {
        let model = makeModel(assistant: PaneAssistant())
        model.setConversation(planContext(selected: "m2"))
        await model.chooseTone(.short)?.value

        XCTAssertEqual(
            model.editInComposeRequest(readOnlyReason: nil),
            .aiDraftReply(messageID: "m2", bodyMarkdown: "Reply in concise", recipient: "maria@northwind.example")
        )
    }

    /// Review Focus 3: the account turns read-only while a preview is showing.
    func testReadOnlyDisablesDraftReplyAndRefusesCompose() async {
        let model = makeModel(assistant: PaneAssistant())
        model.setConversation(planContext(selected: "m2"))
        await model.chooseTone(.friendly)?.value
        let reason = "Sending is paused while you're offline."

        let availability = model.draftAvailability(readOnlyReason: reason)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, reason)
        XCTAssertNil(model.editInComposeRequest(readOnlyReason: reason))
        XCTAssertTrue(model.draftAvailability(readOnlyReason: nil).isAvailable)
        XCTAssertNotNil(model.editInComposeRequest(readOnlyReason: nil))
    }

    /// Review Focus 2: Custom… with blank text drafts nothing.
    func testBlankCustomInstructionsDraftNothing() {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        model.showDraft()

        XCTAssertNil(model.chooseTone(.custom))
        model.draftInstructions = "   \n "
        XCTAssertNil(model.submitCustomInstructions())
        XCTAssertNil(model.regenerateDraft())

        XCTAssertTrue(assistant.draftRequests.isEmpty)
        XCTAssertEqual(model.draftState, .idle)
        XCTAssertEqual(model.route, .draft)
    }

    /// Compose renders a draft's body as Markdown; the preview shows it the same way, not as
    /// literal asterisks.
    func testDraftPreviewRendersMarkdown() async throws {
        let model = makeModel(assistant: PaneAssistant())
        model.setConversation(planContext(selected: "m2"))
        let pane = HostedConversationAIPane(model: model)
        defer { pane.close() }
        model.showDraft()
        model.chooseTone(.custom)
        model.draftInstructions = "**Thanks** for the update"
        await model.submitCustomInstructions()?.value

        let found = await pane.element("conversation.ai.draft.preview")
        let preview = try XCTUnwrap(found)
        XCTAssertEqual(pane.text(preview), "Reply in neutral: Thanks for the update")
    }

    // MARK: Conversation changes

    func testSwitchingConversationResetsRouteAndDraftAndDropsALateDraft() async {
        let gate = GatedPaneAssistant()
        let model = makeModel(assistant: gate)
        model.setConversation(planContext(selected: "m2"))
        model.showDraft()
        let pending = model.chooseTone(.friendly)
        await gate.waitForDraftRequest()

        model.setConversation(dinnerContext())
        await gate.resolveDraft()
        await pending?.value

        XCTAssertEqual(model.route, .overview)
        XCTAssertNil(model.draftPreview)
        XCTAssertNil(model.draftTone)
        XCTAssertEqual(model.draftState, .idle)
        XCTAssertEqual(model.context?.conversationKey, "thread-dinner")
    }

    /// Review Focus 1: another message of the same conversation keeps the pane's state.
    func testSameConversationNewSelectionKeepsRouteAndDraft() async {
        let model = makeModel(assistant: PaneAssistant())
        model.setConversation(planContext(selected: "m1"))
        model.showDraft()
        await model.chooseTone(.short)?.value

        model.setConversation(planContext(selected: "m2"))

        XCTAssertEqual(model.route, .draft)
        XCTAssertNotNil(model.draftPreview)
        XCTAssertEqual(model.draftTone, .short)
        XCTAssertEqual(model.context?.replyMessageID, MessageID("m2"))
    }

    /// Ruling 5: another message of the same conversation while a draft runs drafts again for
    /// that message instead of reporting the dropped draft as unavailable.
    func testSameConversationNewSelectionWhileDraftingRedraftsForTheNewMessage() async {
        let gate = GatedPaneAssistant()
        let model = makeModel(assistant: gate)
        model.setConversation(planContext(selected: "m1"))
        model.showDraft()
        let first = model.chooseTone(.friendly)
        await gate.waitForDraftRequests(count: 1)

        model.setConversation(planContext(selected: "m2"))
        await gate.waitForDraftRequests(count: 2)
        await gate.resolveDraft()
        await first?.value
        await waitWhileDrafting(model)

        let requested = await gate.draftMessageIDs
        XCTAssertEqual(requested, [MessageID("m1"), MessageID("m2")])
        XCTAssertEqual(model.draftState, .ready)
        XCTAssertEqual(model.draftPreview?.bodyPlain, "Late draft")
        XCTAssertEqual(model.draftTone, .friendly)
        XCTAssertEqual(model.route, .draft)
        XCTAssertEqual(model.context?.replyMessageID, MessageID("m2"))
    }

    func testLeaveClearsOnlyItsOwnConversation() {
        let model = makeModel(assistant: PaneAssistant())
        model.setConversation(planContext(selected: "m2"))

        model.leave(messageID: "dinner-1")
        XCTAssertEqual(model.context?.replyMessageID, MessageID("m2"))

        model.leave(messageID: "m2")
        XCTAssertNil(model.context)
    }

    // MARK: Summary

    func testOpeningThePaneLoadsTheSummaryOnceAndClosingKeepsIt() async {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        XCTAssertTrue(model.summaryIsCurrent)
        XCTAssertTrue(assistant.summaryRequests.isEmpty, "opening the conversation only prepares the summary")

        model.paneDidAppear()
        await model.ensureSummaryLoad()?.value
        model.paneDidDisappear()
        model.paneDidAppear()
        await model.ensureSummaryLoad()?.value

        XCTAssertEqual(assistant.summaryRequests, [MessageID("m2")])
        XCTAssertEqual(model.assistant.summaryText, "Summary of m2")
    }

    /// Final review I2: a failed summary isn't final. "Check again" loads it again.
    func testCheckAgainLoadsAFailedSummaryAgain() async {
        let assistant = PaneAssistant(summaryFailures: 1)
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        XCTAssertFalse(model.summaryFailed, "nothing has failed before the pane loads")
        model.paneDidAppear()
        await model.ensureSummaryLoad()?.value
        XCTAssertNil(model.assistant.summaryText)
        XCTAssertTrue(model.summaryFailed)

        model.checkAgain()
        await model.ensureSummaryLoad()?.value

        XCTAssertEqual(assistant.summaryRequests, [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(model.assistant.summaryText, "Summary of m2")
        XCTAssertFalse(model.summaryFailed)
    }

    /// Opening the pane never summarizes: a summary costs a model run, so it waits for
    /// "Summarize".
    func testOpeningThePaneOffersSummarizeWithoutSummarizing() async throws {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        let pane = HostedConversationAIPane(model: model)
        defer { pane.close() }
        let summarizeButton = await pane.element("conversation.ai.summarize")
        let summarize = try XCTUnwrap(summarizeButton)
        XCTAssertTrue(assistant.summaryRequests.isEmpty)

        XCTAssertTrue(pane.press(summarize))
        for _ in 0..<100 where model.assistant.summaryText == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(assistant.summaryRequests, [MessageID("m2")])
        XCTAssertEqual(model.assistant.summaryText, "Summary of m2")
    }

    /// Final review I2: the hosted pane shows "Check again" under a failed summary, and pressing
    /// it loads the summary.
    func testPaneOffersCheckAgainForAFailedSummary() async throws {
        let assistant = PaneAssistant(summaryFailures: 1)
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        // Showing the pane offers Summarize; pressing it loads the summary, which fails.
        let pane = HostedConversationAIPane(model: model)
        defer { pane.close() }
        let summarizeButton = await pane.element("conversation.ai.summarize")
        let summarize = try XCTUnwrap(summarizeButton)
        XCTAssertTrue(pane.press(summarize))
        for _ in 0..<100 where !model.summaryFailed {
            pane.host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(assistant.summaryRequests, [MessageID("m2")])

        let button = await pane.element("conversation.ai.check-again")
        let checkAgain = try XCTUnwrap(button, "a failed summary offers Check again")
        XCTAssertTrue(pane.press(checkAgain))
        for _ in 0..<100 where model.assistant.summaryText == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.assistant.summaryText, "Summary of m2")
        let gone = await pane.element("conversation.ai.check-again", tries: 5)
        XCTAssertNil(gone, "Check again goes once the summary loads")
    }

    // MARK: Assistant reconfigured

    /// Ruling 4: a provider change (or launch configuration) makes the assistant forget the
    /// prepared conversation; the pane prepares it again and reloads the summary while showing.
    func testReconfiguringTheAssistantReloadsTheVisiblePanesSummaryAndDrafts() async {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))
        model.paneDidAppear()
        await model.ensureSummaryLoad()?.value

        model.assistant.configure(assistant: assistant, providerID: "ollama")
        XCTAssertFalse(model.summaryIsCurrent)
        model.assistantDidReconfigure()
        XCTAssertTrue(model.summaryIsCurrent)
        await model.ensureSummaryLoad()?.value
        await model.chooseTone(.short)?.value

        XCTAssertEqual(assistant.summaryRequests, [MessageID("m2"), MessageID("m2")])
        XCTAssertEqual(model.assistant.summaryText, "Summary of m2")
        XCTAssertEqual(model.localityLabel, "Ollama")
        XCTAssertEqual(assistant.draftRequests.map(\.messageID), [MessageID("m2")])
        XCTAssertEqual(model.draftState, .ready)
    }

    func testReconfiguringWhileHiddenOnlyPreparesTheSummary() {
        let assistant = PaneAssistant()
        let model = makeModel(assistant: assistant)
        model.setConversation(planContext(selected: "m2"))

        model.assistant.configure(assistant: assistant)
        model.assistantDidReconfigure()

        XCTAssertTrue(model.summaryIsCurrent)
        XCTAssertTrue(assistant.summaryRequests.isEmpty)
    }

    func testReconfiguringWhileDraftingRedraftsWithTheNewAssistant() async {
        let gate = GatedPaneAssistant()
        let replacement = PaneAssistant()
        let model = makeModel(assistant: gate)
        model.setConversation(planContext(selected: "m2"))
        model.showDraft()
        let first = model.chooseTone(.formal)
        await gate.waitForDraftRequests(count: 1)

        model.assistant.configure(assistant: replacement)
        model.assistantDidReconfigure()
        await gate.resolveDraft()
        await first?.value
        await waitWhileDrafting(model)

        XCTAssertEqual(replacement.draftRequests.map(\.messageID), [MessageID("m2")])
        XCTAssertEqual(replacement.draftRequests.map(\.tone), [.formal])
        XCTAssertEqual(model.draftState, .ready)
        XCTAssertEqual(model.draftPreview?.bodyPlain, "Reply in formal")
    }

    // MARK: Translate and locality

    func testTranslateToggleNamesTheTargetLanguageThenShowsOriginal() async {
        let context = planContext(selected: "m2")
        let handler = EchoTranslationHandler(
            fingerprints: Dictionary(uniqueKeysWithValues: context.messages.map { (MessageID($0.id), $0.translationSourceFingerprint) })
        )
        let model = ConversationAIPaneModel(
            assistant: ThreadAIAssistantViewModel(assistant: PaneAssistant()),
            translation: ThreadTranslationViewModel(handler: handler),
            askMail: AskMailViewModel(handler: ScopedAskMailHandler())
        )
        model.setConversation(context)
        let english = ThreadTranslationConfiguration(targetLanguageID: "en", targetLanguageName: "English")

        XCTAssertEqual(model.translateButtonTitle(targetLanguageName: "English"), "Translate to English")
        await model.toggleTranslation(configuration: english)?.value
        XCTAssertEqual(model.translation.displayMode, .translated)
        XCTAssertEqual(model.translateButtonTitle(targetLanguageName: "English"), "Show original")
        XCTAssertNil(model.toggleTranslation(configuration: english))
        XCTAssertEqual(model.translation.displayMode, .original)
    }

    func testLocalityLabelComesFromTheResolvedProvider() {
        let model = ConversationAIPaneModel(
            assistant: ThreadAIAssistantViewModel(assistant: PaneAssistant(), providerID: "ollama"),
            translation: ThreadTranslationViewModel(handler: UnconfiguredThreadTranslationHandler()),
            askMail: AskMailViewModel(handler: ScopedAskMailHandler())
        )
        XCTAssertEqual(model.localityLabel, "Ollama")
    }

    // MARK: Session and view

    func testSessionOwnsOnePaneOverItsAssistantAndTranslation() {
        let session = MailSession.make()
        XCTAssertTrue(session.conversationAI.assistant === session.aiAssistant)
        XCTAssertTrue(session.conversationAI.translation === session.threadTranslation)
    }

    /// The hosted pane shows each route's controls: the overview, the draft preview and Ask.
    func testPaneRendersEveryRoute() async throws {
        let model = makeModel(assistant: PaneAssistant())
        let pane = HostedConversationAIPane(model: model)
        defer { pane.close() }
        let noConversationSummary = await pane.element("conversation.ai.summary", tries: 5)
        XCTAssertNil(noConversationSummary, "no summary without a conversation")

        model.setConversation(planContext(selected: "m2"))
        for identifier in ["conversation.ai.summary", "conversation.ai.translate", "conversation.ai.draft", "conversation.ai.ask-field"] {
            let element = await pane.element(identifier)
            XCTAssertNotNil(element, "overview shows \(identifier)")
        }

        model.showDraft()
        await model.chooseTone(.formal)?.value
        for identifier in ["conversation.ai.back", "conversation.ai.tone.formal", "conversation.ai.draft.preview", "conversation.ai.draft.edit"] {
            let element = await pane.element(identifier)
            XCTAssertNotNil(element, "the draft route shows \(identifier)")
        }

        await model.ask("What do they need?")?.value
        let turn = await pane.element("conversation.ai.turn")
        XCTAssertNotNil(turn, "the Ask route shows the turn")
        let preview = await pane.element("conversation.ai.draft.preview", tries: 5)
        XCTAssertNil(preview, "the Ask route replaces the draft route")
    }
}

// MARK: - Fixtures

@MainActor
func makeModel(assistant: any ThreadAIAssistantHandling) -> ConversationAIPaneModel {
    ConversationAIPaneModel(
        assistant: ThreadAIAssistantViewModel(assistant: assistant),
        translation: ThreadTranslationViewModel(handler: UnconfiguredThreadTranslationHandler()),
        askMail: AskMailViewModel(handler: ScopedAskMailHandler())
    )
}

func paneMessage(_ id: String, thread: String, body: String = "Looks good. See you Thursday at 10:00.") -> ThreadMessageModel {
    ThreadMessageModel(
        id: id,
        sender: "maria@northwind.example",
        body: .plainText(body),
        sourceThreadID: ThreadID(thread)
    )
}

/// Maria's planning thread: m1, then m2 (newest).
func planContext(selected: String, extra: [ThreadMessageModel] = []) -> ConversationAIContext {
    let messages = [paneMessage("m1", thread: "thread-plan"), paneMessage("m2", thread: "thread-plan")] + extra
    return ConversationAIContext.make(
        selectedMessageID: selected,
        thread: ThreadDetailModel(
            subject: "Quarterly planning", participants: [], summaryStatus: "",
            actionItems: [], availableActions: [], messages: messages
        )
    )!
}

func dinnerContext() -> ConversationAIContext {
    ConversationAIContext.make(
        selectedMessageID: "dinner-1",
        thread: ThreadDetailModel(
            subject: "Dinner on Saturday?", participants: [], summaryStatus: "",
            actionItems: [], availableActions: [],
            messages: [paneMessage("dinner-1", thread: "thread-dinner", body: "Are you free Saturday evening?")]
        )
    )!
}

/// Summarizes and drafts at once; the first `summaryFailures` summaries throw.
final class PaneAssistant: ThreadAIAssistantHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [MessageID] = []
    private var drafts: [(messageID: MessageID, tone: DraftTone, instructions: String)] = []
    private var summaryFailures: Int

    init(summaryFailures: Int = 0) {
        self.summaryFailures = summaryFailures
    }

    var summaryRequests: [MessageID] { lock.withLock { summaries } }
    var draftRequests: [(messageID: MessageID, tone: DraftTone, instructions: String)] { lock.withLock { drafts } }

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        let fails = lock.withLock { () -> Bool in
            summaries.append(messageID)
            guard summaryFailures > 0 else { return false }
            summaryFailures -= 1
            return true
        }
        if fails { throw AIProviderError.unavailable }
        return ThreadAIAssistantSummaryResult(
            summaryText: "Summary of \(messageID.rawValue)", providerName: "Stub",
            modelID: "stub", localOnly: true, contextMessageIDs: [messageID.rawValue]
        )
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        lock.withLock { drafts.append((messageID, tone, instructions)) }
        return paneDraft(body: instructions.isEmpty ? "Reply in \(tone.rawValue)" : "Reply in \(tone.rawValue): \(instructions)")
    }
}

/// Holds each draft until the test resolves it.
actor GatedPaneAssistant: ThreadAIAssistantHandling {
    private var continuations: [CheckedContinuation<Draft, Error>] = []
    /// Every draft request so far, in order.
    private(set) var draftMessageIDs: [MessageID] = []

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw AIProviderError.unavailable
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        draftMessageIDs.append(messageID)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForDraftRequest() async {
        while continuations.isEmpty { await Task.yield() }
    }

    /// Waits until `count` drafts have been requested and are held, or gives up after a while
    /// so a missing request fails the test instead of hanging it.
    func waitForDraftRequests(count: Int) async {
        for _ in 0..<10_000 where draftMessageIDs.count < count || continuations.isEmpty {
            await Task.yield()
        }
    }

    /// Resolves every held draft.
    func resolveDraft() {
        let held = continuations
        continuations = []
        held.forEach { $0.resume(returning: paneDraft(body: "Late draft")) }
    }
}

/// Lets the pane's draft task finish after the test resolved the assistant's draft.
@MainActor
func waitWhileDrafting(_ model: ConversationAIPaneModel) async {
    for _ in 0..<1_000 where model.draftState == .drafting {
        await Task.yield()
    }
}

func paneDraft(body: String) -> Draft {
    Draft(
        id: DraftID("drf_pane"), accountID: AccountID("acc_test"),
        from: EmailAddress("reader@example.test"), to: [EmailAddress("maria@northwind.example")],
        cc: [], bcc: [], subject: "Re: Quarterly planning", bodyPlain: body,
        createdBy: "local-user", aiGenerated: true, sourceThreadID: ThreadID("thread-plan")
    )
}

struct EchoTranslationHandler: ThreadTranslationHandling {
    let providerID = "stub"
    let modelID = "stub-model"
    let fingerprints: [MessageID: String]

    func cachedTranslation(messageID: MessageID, targetLanguageID: String) throws -> MessageTranslationResult? { nil }

    func translate(messageID: MessageID, targetLanguageID: String, targetLanguageName: String) async throws -> MessageTranslationResult {
        MessageTranslationResult(
            messageID: messageID,
            renderedBody: RenderedEmailBody(kind: .plainText, safeText: "Translated", blockedRemoteImageURLs: []),
            sourceFingerprint: fingerprints[messageID] ?? "",
            providerID: providerID, modelID: modelID,
            targetLanguageID: targetLanguageID, wasCached: false
        )
    }
}
