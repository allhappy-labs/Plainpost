import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
import PlainpostTestSupport
@testable import PlainpostUI

@MainActor
final class ThreadAIAssistantViewModelTests: XCTestCase {
    func testCheckingUnchangedModelAvailabilityShowsFeedback() {
        let viewModel = ThreadAIAssistantViewModel(
            assistant: RecordingThreadAIAssistant(),
            availability: { _ in AIActionAvailability(
                isAvailable: false, reason: "Model not ready", canCheckAgain: true
            ) }
        )

        XCTAssertNil(viewModel.lastAvailabilityCheck)
        viewModel.checkAvailability()
        XCTAssertNotNil(viewModel.lastAvailabilityCheck)
        XCTAssertEqual(viewModel.summaryAvailability.reason, "Model not ready")
        viewModel.configure(assistant: RecordingThreadAIAssistant())
        XCTAssertNil(viewModel.lastAvailabilityCheck)
    }

    func testUnavailableProviderBlocksSummaryReplyAndChatBeforeDispatch() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        viewModel.configure(
            assistant: assistant,
            availability: { AIActionAvailability.resolve(
                provider: FoundationModelsAIProvider(),
                status: AIProviderStatusService.foundation(availability: .deviceNotEligible),
                operation: $0
            ) }
        )
        let context = EmailSummaryContext(messageID: MessageID("msg_unavailable"), contentFingerprint: "v1")
        viewModel.prepareSummary(for: context)
        await viewModel.refreshCurrentSummary()
        _ = await viewModel.draftReply(tone: .neutral, instructions: "")
        viewModel.chatInput = "What happened?"
        await viewModel.askCurrentQuestion()

        XCTAssertTrue(assistant.requestedMessageIDs.isEmpty)
        XCTAssertTrue(assistant.draftRequestedMessageIDs.isEmpty)
        XCTAssertTrue(assistant.questions.isEmpty)
        XCTAssertFalse(viewModel.summaryAvailability.isAvailable)
        XCTAssertFalse(viewModel.replyAvailability.isAvailable)
        XCTAssertFalse(viewModel.chatAvailability.isAvailable)
        XCTAssertTrue(viewModel.statusMessage?.contains("device") == true)
        XCTAssertEqual(viewModel.chatInput, "What happened?")
    }

    func testUnavailableModelDoesNotLeavePreviousMessageSummaryVisible() async {
        let assistant = RecordingThreadAIAssistant()
        var available = true
        let viewModel = ThreadAIAssistantViewModel(
            assistant: assistant,
            availability: { _ in AIActionAvailability(isAvailable: available, reason: "Model unavailable") }
        )
        await viewModel.loadSummary(for: EmailSummaryContext(
            messageID: MessageID("message-a"), contentFingerprint: "a"
        ))
        available = false

        await viewModel.loadSummary(for: EmailSummaryContext(
            messageID: MessageID("message-b"), contentFingerprint: "b"
        ))

        XCTAssertNil(viewModel.summaryText)
        XCTAssertEqual(assistant.requestedMessageIDs, [MessageID("message-a")])
    }

    func testCheckingAgainEnablesSummaryAfterModelBecomesReady() async {
        let assistant = RecordingThreadAIAssistant()
        var ready = false
        let viewModel = ThreadAIAssistantViewModel(
            assistant: assistant,
            availability: { _ in AIActionAvailability(
                isAvailable: ready,
                reason: ready ? nil : "Model downloading",
                canCheckAgain: !ready
            ) }
        )
        viewModel.prepareSummary(for: EmailSummaryContext(
            messageID: MessageID("message-ready"), contentFingerprint: "v1"
        ))
        await viewModel.refreshCurrentSummary()
        XCTAssertEqual(viewModel.statusMessage, "Model downloading")

        ready = true
        viewModel.refreshAvailability()
        XCTAssertNil(viewModel.statusMessage)
        await viewModel.refreshCurrentSummary()

        XCTAssertTrue(viewModel.summaryAvailability.isAvailable)
        XCTAssertEqual(assistant.requestedMessageIDs, [MessageID("message-ready")])
        XCTAssertNil(viewModel.statusMessage)
    }



    func testPermanentGenerationErrorExplainsNextStepWithoutGenericRetry() async {
        let viewModel = ThreadAIAssistantViewModel(
            assistant: ErrorThreadAIAssistant(error: .unsupportedLanguageOrLocale)
        )
        await viewModel.loadSummary(for: EmailSummaryContext(
            messageID: MessageID("msg_language"), contentFingerprint: "v1"
        ))

        XCTAssertTrue(viewModel.statusMessage?.contains("language") == true)
        XCTAssertFalse(viewModel.statusMessage?.contains("Try again.") == true)
    }

    func testPreparingEmailSummaryDoesNotStartGenerationUntilRequested() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let context = EmailSummaryContext(messageID: MessageID("msg_alice_1"), contentFingerprint: "v1")

        viewModel.prepareSummary(for: context)

        XCTAssertTrue(assistant.requestedMessageIDs.isEmpty)
        XCTAssertNil(viewModel.summaryText)
        XCTAssertFalse(viewModel.isWorking)

        await viewModel.refreshCurrentSummary()

        XCTAssertEqual(assistant.requestedMessageIDs, [MessageID("msg_alice_1")])
        XCTAssertEqual(viewModel.summaryText, "Summary for msg_alice_1")
    }

    func testRequestedEmailSummaryUsesSelectedMessageAndCachesItForTheSession() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let context = EmailSummaryContext(messageID: MessageID("msg_alice_1"), contentFingerprint: "v1")

        await viewModel.loadSummary(for: context)
        await viewModel.loadSummary(for: context)

        XCTAssertEqual(assistant.requestedMessageIDs, [MessageID("msg_alice_1")])
        XCTAssertEqual(viewModel.summaryText, "Summary for msg_alice_1")
        XCTAssertEqual(viewModel.localityLabel, "On-device 🔒")
        XCTAssertEqual(viewModel.contextMessageIDs, ["msg_alice_1"])
        XCTAssertNil(viewModel.statusMessage)
    }

    func testLocalityLabelNamesTheResolvedProvider() {
        XCTAssertEqual(
            ThreadAIAssistantViewModel(assistant: RecordingThreadAIAssistant(), providerID: "foundation").localityLabel,
            "On-device 🔒"
        )
        XCTAssertEqual(
            ThreadAIAssistantViewModel(assistant: RecordingThreadAIAssistant(), providerID: "ollama").localityLabel,
            "Ollama"
        )
        XCTAssertEqual(ThreadAIAssistantViewModel.localityLabel(providerID: "disabled"), "AI off")
        XCTAssertEqual(ThreadAIAssistantViewModel.localityLabel(providerID: "openrouter"), "OpenRouter")
        let viewModel = ThreadAIAssistantViewModel(assistant: RecordingThreadAIAssistant())
        viewModel.configure(assistant: RecordingThreadAIAssistant(), providerID: "ollama")
        XCTAssertEqual(viewModel.localityLabel, "Ollama")
    }

    func testDraftReplyPassesToneAndInstructionsToTheAssistant() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        viewModel.prepareSummary(for: EmailSummaryContext(messageID: MessageID("msg_alice_1"), contentFingerprint: "v1"))

        let draft = await viewModel.draftReply(tone: .formal, instructions: "Ask for an extension")

        XCTAssertEqual(draft?.bodyPlain, "AI reply body")
        XCTAssertEqual(assistant.draftRequestedMessageIDs, [MessageID("msg_alice_1")])
        XCTAssertEqual(assistant.draftRequests.map(\.tone), [.formal])
        XCTAssertEqual(assistant.draftRequests.map(\.instructions), ["Ask for an extension"])
        XCTAssertFalse(viewModel.isDraftingReply)
    }

    func testStaleSummaryResultCannotReplaceTheNewlySelectedEmail() async {
        let assistant = DeferredThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let first = EmailSummaryContext(messageID: MessageID("msg_first"), contentFingerprint: "first")
        let second = EmailSummaryContext(messageID: MessageID("msg_second"), contentFingerprint: "second")

        async let firstLoad: Void = viewModel.loadSummary(for: first)
        await assistant.waitForRequest(messageID: first.messageID)
        async let secondLoad: Void = viewModel.loadSummary(for: second)
        await assistant.waitForRequest(messageID: second.messageID)

        await assistant.resolve(messageID: first.messageID, text: "Old email")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(viewModel.summaryText)

        await assistant.resolve(messageID: second.messageID, text: "Current email")
        _ = await (firstLoad, secondLoad)

        XCTAssertEqual(viewModel.summaryText, "Current email")
        XCTAssertEqual(viewModel.contextMessageIDs, ["msg_second"])
    }

    /// Ledger Task 5: a new conversation never shows the previous one's summary, even for the
    /// frame before it prepares its own.
    func testTheSummaryStateBelongsToThePreparedConversationOnly() async {
        let viewModel = ThreadAIAssistantViewModel(assistant: RecordingThreadAIAssistant())
        let first = EmailSummaryContext(messageID: MessageID("msg_first"), contentFingerprint: "v1")
        let second = EmailSummaryContext(messageID: MessageID("msg_second"), contentFingerprint: "v1")
        await viewModel.loadSummary(for: first)
        XCTAssertEqual(viewModel.summaryText, "Summary for msg_first")
        XCTAssertTrue(viewModel.isPrepared(for: first))
        XCTAssertFalse(viewModel.isPrepared(for: second), "still the first conversation's summary")

        viewModel.prepareSummary(for: second)
        XCTAssertTrue(viewModel.isPrepared(for: second))
        XCTAssertNil(viewModel.summaryText)
    }

    /// Ledger Task 5: hiding the summary cancels its load.
    func testCancellingASummaryLoadDropsItsAnswer() async {
        let assistant = DeferredThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let context = EmailSummaryContext(messageID: MessageID("msg_hidden"), contentFingerprint: "v1")

        let load = Task { await viewModel.loadSummary(for: context) }
        await assistant.waitForRequest(messageID: context.messageID)
        XCTAssertTrue(viewModel.isWorking)

        load.cancel()
        viewModel.cancelSummaryLoad()
        XCTAssertFalse(viewModel.isWorking, "no spinner once hidden")

        await assistant.resolve(messageID: context.messageID, text: "Late answer")
        await load.value
        XCTAssertNil(viewModel.summaryText, "the cancelled answer isn't shown")
        XCTAssertNil(viewModel.statusMessage, "a cancelled load isn't a failure")
        XCTAssertFalse(viewModel.isWorking)

        // Showing it again asks anew: nothing was cached.
        let again = Task { await viewModel.loadSummary(for: context) }
        await assistant.waitForRequest(messageID: context.messageID)
        await assistant.resolve(messageID: context.messageID, text: "Fresh answer")
        await again.value
        XCTAssertEqual(viewModel.summaryText, "Fresh answer")
    }

    func testRefreshInvalidatesOnlyTheCurrentEmailCache() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let context = EmailSummaryContext(messageID: MessageID("msg_alice_1"), contentFingerprint: "v1")

        await viewModel.loadSummary(for: context)
        await viewModel.refreshCurrentSummary()

        XCTAssertEqual(assistant.requestedMessageIDs, [MessageID("msg_alice_1"), MessageID("msg_alice_1")])
    }

    func testDraftReplyUsesSelectedMessageAndReturnsEditableDraft() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_alice_1"), contentFingerprint: "v1")
        )

        let draft = await viewModel.draftReply(tone: .neutral, instructions: "")

        XCTAssertEqual(assistant.draftRequestedMessageIDs, [MessageID("msg_alice_1")])
        XCTAssertEqual(draft?.bodyPlain, "AI reply body")
        XCTAssertEqual(viewModel.replyStatusMessage, "Reply draft is ready to review.")
        XCTAssertFalse(viewModel.isDraftingReply)
    }

    func testDraftReplyFromPreviousSelectionCannotOpenForCurrentMessage() async {
        let assistant = DeferredDraftThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let first = EmailSummaryContext(messageID: MessageID("msg_first"), contentFingerprint: "first")
        let second = EmailSummaryContext(messageID: MessageID("msg_second"), contentFingerprint: "second")
        viewModel.prepareSummary(for: first)

        let firstDraft = Task { await viewModel.draftReply(tone: .neutral, instructions: "") }
        await assistant.waitForRequest(messageID: first.messageID)
        viewModel.prepareSummary(for: second)
        XCTAssertFalse(viewModel.isDraftingReply)

        await assistant.resolve(messageID: first.messageID)
        let staleDraft = await firstDraft.value
        XCTAssertNil(staleDraft)
        XCTAssertNil(viewModel.replyStatusMessage)

        let secondDraft = Task { await viewModel.draftReply(tone: .neutral, instructions: "") }
        await assistant.waitForRequest(messageID: second.messageID)
        await assistant.resolve(messageID: second.messageID)
        let currentDraft = await secondDraft.value
        XCTAssertEqual(currentDraft?.bodyPlain, "AI reply for msg_second")
    }

    /// The iPhone conversation prepares its own summary context on open, so Draft with AI
    /// replies to the conversation on screen, not the one summarized before it.
    func testPreparingTheOpenedConversationPointsDraftWithAIAtIt() async throws {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let first = Self.conversation(messageID: "msg_first")
        let second = Self.conversation(messageID: "msg_second")
        await viewModel.loadSummary(
            for: try XCTUnwrap(PlainpostRootView.summaryContext(selectedMessageID: "msg_first", thread: first))
        )

        viewModel.prepareSummary(
            for: try XCTUnwrap(PlainpostRootView.summaryContext(selectedMessageID: "msg_second", thread: second))
        )
        _ = await viewModel.draftReply(tone: .neutral, instructions: "")

        XCTAssertNil(viewModel.summaryText)
        XCTAssertEqual(assistant.draftRequestedMessageIDs, [MessageID("msg_second")])
    }

    func testDraftWithAIDoesNothingUntilAConversationIsPrepared() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)

        let draft = await viewModel.draftReply(tone: .neutral, instructions: "")

        XCTAssertNil(draft)
        XCTAssertTrue(assistant.draftRequestedMessageIDs.isEmpty)
    }

    private static func conversation(messageID: String) -> ThreadDetailModel {
        ThreadDetailModel(
            subject: messageID,
            participants: [],
            summaryStatus: "",
            actionItems: [],
            availableActions: [],
            messages: [ThreadMessageModel(id: messageID, sender: "a@example.test", body: .plainText("Body of \(messageID)"))]
        )
    }

    func testSummaryFailureIsNotCachedAndRemainsRetryable() async {
        let assistant = FailingThenWorkingAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        let context = EmailSummaryContext(messageID: MessageID("msg_retry"), contentFingerprint: "v1")

        await viewModel.loadSummary(for: context)
        XCTAssertEqual(viewModel.statusMessage, "Summary unavailable. Try again.")

        await viewModel.loadSummary(for: context)
        XCTAssertEqual(assistant.callCount, 2)
        XCTAssertEqual(viewModel.summaryText, "Recovered")
    }

    func testThreadChatCarriesPriorTurnsIntoTheNextQuestion() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_chat"), contentFingerprint: "chat-v1")
        )

        viewModel.chatInput = "When is the review?"
        await viewModel.askCurrentQuestion()
        viewModel.chatInput = "Who is attending?"
        await viewModel.askCurrentQuestion()

        XCTAssertEqual(viewModel.chatTurns.map(\.question), ["When is the review?", "Who is attending?"])
        XCTAssertEqual(assistant.questions.map(\.question), ["When is the review?", "Who is attending?"])
        XCTAssertTrue(assistant.questions[0].priorTurns.isEmpty)
        XCTAssertEqual(assistant.questions[1].priorTurns, [viewModel.chatTurns[0]])
        XCTAssertFalse(viewModel.isAnsweringQuestion)
        XCTAssertNil(viewModel.chatStatusMessage)
    }

    func testThreadChatResetsWhenTheSelectedThreadChanges() async {
        let viewModel = ThreadAIAssistantViewModel(assistant: RecordingThreadAIAssistant())
        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_first"), contentFingerprint: "first")
        )
        viewModel.chatInput = "What changed?"
        await viewModel.askCurrentQuestion()

        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_second"), contentFingerprint: "second")
        )

        XCTAssertTrue(viewModel.chatTurns.isEmpty)
        XCTAssertTrue(viewModel.chatInput.isEmpty)
        XCTAssertNil(viewModel.chatStatusMessage)
    }

    func testThreadChatFailureRestoresTheQuestionForRetry() async {
        let viewModel = ThreadAIAssistantViewModel(assistant: FailingQuestionAssistant())
        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_retry_chat"), contentFingerprint: "retry")
        )
        viewModel.chatInput = "What was decided?"

        await viewModel.askCurrentQuestion()

        XCTAssertEqual(viewModel.chatInput, "What was decided?")
        XCTAssertTrue(viewModel.chatTurns.isEmpty)
        XCTAssertEqual(viewModel.chatStatusMessage, "Answer unavailable. Try again.")
        XCTAssertFalse(viewModel.isAnsweringQuestion)
    }

    func testThreadChatBoundsModelHistoryToSixRecentTurns() async {
        let assistant = RecordingThreadAIAssistant()
        let viewModel = ThreadAIAssistantViewModel(assistant: assistant)
        viewModel.prepareSummary(
            for: EmailSummaryContext(messageID: MessageID("msg_long_chat"), contentFingerprint: "long-chat")
        )

        for index in 0..<8 {
            viewModel.chatInput = "Question \(index)"
            await viewModel.askCurrentQuestion()
        }

        XCTAssertEqual(assistant.questions.last?.priorTurns.count, 6)
        XCTAssertEqual(
            assistant.questions.last?.priorTurns.map(\.question),
            (1...6).map { "Question \($0)" }
        )
        XCTAssertEqual(viewModel.chatTurns.count, 8)
    }
}

private struct ErrorThreadAIAssistant: ThreadAIAssistantHandling {
    let error: AIProviderError

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw error
    }
}

private final class RecordingThreadAIAssistant: ThreadAIAssistantHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [MessageID] = []
    private var drafts: [(messageID: MessageID, tone: DraftTone, instructions: String)] = []
    private var questionRequests: [(question: String, priorTurns: [ThreadAIAssistantChatTurn])] = []

    var requestedMessageIDs: [MessageID] { lock.withLock { requests } }
    var draftRequests: [(messageID: MessageID, tone: DraftTone, instructions: String)] { lock.withLock { drafts } }
    var draftRequestedMessageIDs: [MessageID] { draftRequests.map(\.messageID) }
    var questions: [(question: String, priorTurns: [ThreadAIAssistantChatTurn])] { lock.withLock { questionRequests } }

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        lock.withLock { requests.append(messageID) }
        return ThreadAIAssistantSummaryResult(
            summaryText: "Summary for \(messageID.rawValue)",
            providerName: "Deterministic Local",
            modelID: "deterministic-local",
            localOnly: true,
            contextMessageIDs: [messageID.rawValue]
        )
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        lock.withLock { drafts.append((messageID, tone, instructions)) }
        return Draft(
            id: DraftID("drf_ai_test"),
            accountID: AccountID("acc_test"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Test",
            bodyPlain: "AI reply body",
            createdBy: "local-user",
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_test")
        )
    }

    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        lock.withLock { questionRequests.append((question, priorTurns)) }
        return ThreadAIAssistantAnswerResult(
            answer: "Answer for \(question)",
            providerName: "Deterministic Local",
            modelID: "deterministic-local",
            localOnly: true
        )
    }
}

private actor DeferredThreadAIAssistant: ThreadAIAssistantHandling {
    private var continuations: [MessageID: CheckedContinuation<ThreadAIAssistantSummaryResult, Error>] = [:]

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        try await withCheckedThrowingContinuation { continuation in
            continuations[messageID] = continuation
        }
    }

    func waitForRequest(messageID: MessageID) async {
        while continuations[messageID] == nil {
            await Task.yield()
        }
    }

    func resolve(messageID: MessageID, text: String) {
        continuations.removeValue(forKey: messageID)?.resume(returning: ThreadAIAssistantSummaryResult(
            summaryText: text,
            providerName: "Deterministic Local",
            modelID: "deterministic-local",
            localOnly: true,
            contextMessageIDs: [messageID.rawValue]
        ))
    }
}

private actor DeferredDraftThreadAIAssistant: ThreadAIAssistantHandling {
    private var continuations: [MessageID: CheckedContinuation<Draft, Error>] = [:]

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw AIProviderError.unavailable
    }

    func draftReply(messageID: MessageID, tone: DraftTone, instructions: String) async throws -> Draft {
        try await withCheckedThrowingContinuation { continuation in
            continuations[messageID] = continuation
        }
    }

    func waitForRequest(messageID: MessageID) async {
        while continuations[messageID] == nil {
            await Task.yield()
        }
    }

    func resolve(messageID: MessageID) {
        continuations.removeValue(forKey: messageID)?.resume(returning: Draft(
            id: DraftID("drf_\(messageID.rawValue)"),
            accountID: AccountID("acc_test"),
            from: EmailAddress("me@example.com"),
            to: [EmailAddress("alice@example.com")],
            cc: [],
            bcc: [],
            subject: "Re: Test",
            bodyPlain: "AI reply for \(messageID.rawValue)",
            createdBy: "local-user",
            aiGenerated: true,
            sourceThreadID: ThreadID("thr_test")
        ))
    }
}

private final class FailingThenWorkingAssistant: ThreadAIAssistantHandling, @unchecked Sendable {
    private(set) var callCount = 0

    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        callCount += 1
        if callCount == 1 {
            throw AIProviderError.unavailable
        }
        return ThreadAIAssistantSummaryResult(
            summaryText: "Recovered",
            providerName: "Deterministic Local",
            modelID: "deterministic-local",
            localOnly: true,
            contextMessageIDs: [messageID.rawValue]
        )
    }
}

private struct FailingQuestionAssistant: ThreadAIAssistantHandling {
    func summarize(messageID: MessageID) async throws -> ThreadAIAssistantSummaryResult {
        throw AIProviderError.unavailable
    }

    func answerQuestion(
        messageID: MessageID,
        question: String,
        priorTurns: [ThreadAIAssistantChatTurn]
    ) async throws -> ThreadAIAssistantAnswerResult {
        throw AIProviderError.unavailable
    }
}
