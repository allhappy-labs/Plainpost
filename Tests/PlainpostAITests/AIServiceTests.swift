import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class AIServiceTests: XCTestCase {
    func testLegacyThreadSummaryUsesOnlySelectedAccountMessages() async throws {
        let store = InMemoryMailStore()
        let selected = MessageSummary(
            id: MessageID("legacy-selected"), threadID: ThreadID("thr_uid_selected"),
            from: EmailAddress("selected@example.com"), subject: "Project update",
            preview: "Selected detail", body: "Selected account detail",
            smartCategory: .personal
        )
        let foreign = MessageSummary(
            id: MessageID("legacy-foreign"), threadID: ThreadID("thr_uid_foreign"),
            from: EmailAddress("foreign@example.com"), subject: "Re: Project update",
            preview: "Foreign detail", body: "Foreign account secret",
            smartCategory: .personal
        )
        try store.cacheMessage(selected)
        try store.cacheMessage(foreign)
        let provider = PromptRecordingAIProvider(maxContextTokens: 4_096)
        let service = LocalAIService(
            provider: provider, store: store, selectedMessages: [selected]
        )

        _ = try await service.summarizeThread(
            SummarizeThreadInput(
                threadID: ThreadID(MailThreading.conversationKey(for: selected)), style: .short
            ), actor: PlainpostFixtures.codexActor
        )

        let recordedPrompt = await provider.lastPrompt
        let prompt = try XCTUnwrap(recordedPrompt)
        XCTAssertTrue(prompt.contains("Selected account detail"))
        XCTAssertFalse(prompt.contains("Foreign account secret"))
    }

    func testSummarizeThreadUsesLocalProviderAndReturnsActionItems() async throws {
        let service = LocalAIService(provider: DeterministicAIProvider(), store: InMemoryMailStore.seededForStage0())

        let summary = try await service.summarizeThread(
            SummarizeThreadInput(threadID: ThreadID("thr_alice_1"), style: .actionPoints),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(summary.threadID, ThreadID("thr_alice_1"))
        XCTAssertTrue(summary.summary.contains("Alice asked about availability"))
        XCTAssertEqual(summary.actionItems.map(\.text), ["Reply with availability"])
        XCTAssertEqual(summary.modelID, "deterministic-local")
        XCTAssertTrue(summary.localOnly)
    }

    func testSummarizeThreadIncludesEveryMessageWithinProviderContextBudget() async throws {
        let store = InMemoryMailStore()
        let threadID = ThreadID("thr_complete")
        for index in (0..<12).reversed() {
            try store.cacheMessage(
                MessageSummary(
                    id: MessageID("msg_\(index)"),
                    threadID: threadID,
                    from: EmailAddress("sender\(index)@example.com"),
                    subject: "Update \(index)",
                    preview: "preview \(index)",
                    body: index == 5
                        ? String(repeating: "long-context-5 ", count: 3_000)
                        : "complete thread detail \(index)",
                    smartCategory: .personal,
                    sentAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        let provider = PromptRecordingAIProvider(maxContextTokens: 4_096)
        let service = LocalAIService(provider: provider, store: store)

        _ = try await service.summarizeThread(
            SummarizeThreadInput(threadID: threadID, style: .short),
            actor: PlainpostFixtures.codexActor
        )

        let recordedPrompt = await provider.lastPrompt
        let prompt = try XCTUnwrap(recordedPrompt)
        XCTAssertTrue(prompt.contains("The thread contains 12 messages"))
        for index in 0..<12 {
            XCTAssertTrue(prompt.contains("Message \(index + 1) of 12"))
            if index != 5 {
                XCTAssertTrue(prompt.contains("complete thread detail \(index)"))
            }
        }
        XCTAssertLessThan(prompt.count, 13_000)
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: "Message 1 of 12")?.lowerBound),
            try XCTUnwrap(prompt.range(of: "Message 12 of 12")?.lowerBound)
        )
    }

    func testAnswerThreadQuestionUsesFullThreadAndRecentConversation() async throws {
        let store = InMemoryMailStore()
        let threadID = ThreadID("thr_questions")
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_question_1"),
                threadID: threadID,
                from: EmailAddress("alice@example.com"),
                subject: "Planning",
                preview: "First detail",
                body: "The launch review is on Tuesday.",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 1)
            )
        )
        try store.cacheMessage(
            MessageSummary(
                id: MessageID("msg_question_2"),
                threadID: threadID,
                from: EmailAddress("bob@example.com"),
                subject: "Re: Planning",
                preview: "Second detail",
                body: "Bob will bring the final metrics.",
                smartCategory: .personal,
                sentAt: Date(timeIntervalSince1970: 2)
            )
        )
        let provider = PromptRecordingAIProvider(maxContextTokens: 4_096)
        let service = LocalAIService(provider: provider, store: store)

        _ = try await service.answerThreadQuestion(
            AskThreadQuestionInput(
                threadID: threadID,
                question: "Who is bringing the metrics?",
                priorTurns: [ThreadQuestionTurn(question: "When is the review?", answer: "Tuesday.")]
            ),
            actor: PlainpostFixtures.codexActor
        )

        let recordedPrompt = await provider.lastPrompt
        let prompt = try XCTUnwrap(recordedPrompt)
        XCTAssertTrue(prompt.contains("The launch review is on Tuesday."))
        XCTAssertTrue(prompt.contains("Bob will bring the final metrics."))
        XCTAssertTrue(prompt.contains("User: When is the review?"))
        XCTAssertTrue(prompt.contains("Assistant: Tuesday."))
        XCTAssertTrue(prompt.contains("User question: Who is bringing the metrics?"))
    }

    func testDraftReplyCreatesLocalDraftRequiringReview() async throws {
        let store = InMemoryMailStore.seededForStage0()
        let service = LocalAIService(provider: DeterministicAIProvider(), store: store)

        let draft = try await service.draftReply(
            DraftReplyInput(
                threadID: ThreadID("thr_alice_1"),
                tone: .friendly,
                instructions: "Say Tuesday works",
                replyAll: false
            ),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(draft.to, [EmailAddress("alice@example.com")])
        XCTAssertTrue(draft.bodyPlain.contains("Tuesday works"))
        XCTAssertTrue(draft.aiGenerated)
        XCTAssertEqual(try store.draft(id: draft.id), draft)
    }

    func testDraftReplyCreatesEditableDraftWithoutRecipientForSelfOnlyThread() async throws {
        let account = PlainpostFixtures.personalAccount
        let thread = MailThread(
            id: ThreadID("thr_self_only"),
            accountID: account.id,
            subjectNormalized: "account verification",
            participantEmails: [account.email]
        )
        let store = InMemoryMailStore(
            accounts: [account],
            messages: [
                MessageSummary(
                    id: MessageID("msg_self_only"),
                    threadID: thread.id,
                    from: account.email,
                    subject: "Account verification",
                    preview: "Testing local SMTP credentials.",
                    smartCategory: .personal
                ),
            ],
            threads: [thread]
        )
        let service = LocalAIService(provider: DeterministicAIProvider(), store: store)

        let draft = try await service.draftReply(
            DraftReplyInput(threadID: thread.id, tone: .neutral, instructions: "", replyAll: false),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(draft.to, [])
        XCTAssertTrue(draft.aiGenerated)
        XCTAssertEqual(try store.draft(id: draft.id), draft)
    }

    func testDraftReplyPromptCarriesToneInstructionsAndThreadLanguage() async throws {
        let store = InMemoryMailStore.seededForStage0()
        let provider = PromptRecordingAIProvider(maxContextTokens: 4_096)
        let service = LocalAIService(provider: provider, store: store)

        _ = try await service.draftReply(
            DraftReplyInput(
                threadID: ThreadID("thr_alice_1"),
                tone: .formal,
                instructions: "Ask for an extension",
                replyAll: false
            ),
            actor: PlainpostFixtures.codexActor
        )

        let recordedPrompt = await provider.lastPrompt
        let prompt = try XCTUnwrap(recordedPrompt)
        XCTAssertTrue(prompt.contains("Write an editable formal email reply"), prompt)
        XCTAssertTrue(prompt.contains("User instructions: Ask for an extension"), prompt)
        XCTAssertTrue(prompt.contains("Write the reply in the same language as the newest message in the thread."), prompt)
    }

    func testRewriteDraftReturnsRevisionWithoutMutatingDraft() async throws {
        let store = InMemoryMailStore()
        let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let service = LocalAIService(provider: DeterministicAIProvider(), store: store)

        let revision = try await service.rewriteDraft(
            RewriteDraftInput(draftID: draft.id, mode: .makeFriendly),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(revision.draftID, draft.id)
        XCTAssertTrue(revision.body.contains("friendly"))
        XCTAssertEqual(try store.draft(id: draft.id), draft)
    }

    func testClassifyMessageReturnsLocalCategory() async throws {
        let service = LocalAIService(provider: DeterministicAIProvider(), store: InMemoryMailStore.seededForStage0())

        let classification = try await service.classifyMessage(
            ClassifyMessageInput(messageID: MessageID("msg_alice_1")),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(classification.category, .personal)
        XCTAssertGreaterThanOrEqual(classification.confidence, 0.8)
        XCTAssertTrue(classification.localOnly)
    }

    func testOllamaConfigurationRejectsNonLocalEndpoint() {
        XCTAssertThrowsError(try OllamaProviderConfiguration(baseURL: URL(string: "https://api.example.com")!)) { error in
            XCTAssertEqual(error as? AIProviderError, .remoteEndpointDisallowed)
        }
    }

    func testAIServiceRejectsRestrictedAgentAIUsage() async throws {
        let store = InMemoryMailStore.seededForStage0()
        _ = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
        let service = LocalAIService(provider: DeterministicAIProvider(), store: store)
        let restrictedActor = Actor(
            id: "restricted-ai-agent",
            kind: .mcpAgent,
            displayName: "Restricted AI Agent",
            permissions: .agentRequested(
                readBody: true,
                createDrafts: true,
                requestSend: true,
                useAISummary: false,
                useAIDraftReply: false,
                useAISemanticSearch: false,
                useAIClassification: false
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await service.summarizeThread(
                SummarizeThreadInput(threadID: ThreadID("thr_alice_1"), style: .short),
                actor: restrictedActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to use AI summaries."))
        }

        await XCTAssertThrowsErrorAsync(
            try await service.draftReply(
                DraftReplyInput(threadID: ThreadID("thr_alice_1"), tone: .friendly, instructions: "", replyAll: false),
                actor: restrictedActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to use AI draft replies."))
        }

        await XCTAssertThrowsErrorAsync(
            try await service.rewriteDraft(
                RewriteDraftInput(draftID: PlainpostFixtures.replyDraft.id, mode: .makeFriendly),
                actor: restrictedActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to use AI draft replies."))
        }

        await XCTAssertThrowsErrorAsync(
            try await service.classifyMessage(
                ClassifyMessageInput(messageID: MessageID("msg_alice_1")),
                actor: restrictedActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to use AI classification."))
        }
    }
}

private actor PromptRecordingAIProvider: AIProvider {
    nonisolated let id = "prompt-recording"
    nonisolated let displayName = "Prompt Recording"
    nonisolated let capabilities: AICapabilities
    private(set) var lastPrompt: String?

    init(maxContextTokens: Int) {
        self.capabilities = AICapabilities(
            supportsChat: true,
            supportsEmbeddings: false,
            supportsJSONMode: false,
            supportsStreaming: false,
            maxContextTokens: maxContextTokens,
            runsLocally: true
        )
    }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        lastPrompt = request.prompt
        return AIGenerationResponse(text: "Complete summary", modelID: id, localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        throw AIProviderError.unavailable
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
