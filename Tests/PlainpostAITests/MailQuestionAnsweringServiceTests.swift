import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class MailQuestionAnsweringServiceTests: XCTestCase {
    func testAnswersMailboxQuestionWithTypedLocalSources() async throws {
        let message = MessageSummary(
            id: MessageID("msg_quote"),
            threadID: ThreadID("thr_contract"),
            from: EmailAddress("builder@example.com"),
            subject: "Final renovation quote",
            preview: "The total is 4,200 euros.",
            body: "The final contractor quote is 4,200 euros including materials.",
            smartCategory: .personal
        )
        let store = InMemoryMailStore(messages: [message])
        let service = LocalMailQuestionAnsweringService(provider: CitationTestProvider(), store: store)

        let answer = try await service.answer(
            AskMailboxQuestionInput(question: "What did the contractor quote?"),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertFalse(answer.insufficientEvidence)
        XCTAssertEqual(answer.sources.map(\.messageID), [message.id])
        XCTAssertEqual(answer.sources.first?.id, "S1")
        XCTAssertTrue(answer.answer.contains("4,200"))
        XCTAssertTrue(answer.localOnly)
    }

    func testAccountScopedQuestionRejectsForeignLexicalAndSemanticEvidence() async throws {
        let first = Account(id: AccountID("a"), displayName: "A", email: EmailAddress("a@example.com"),
                            imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let second = Account(id: AccountID("b"), displayName: "B", email: EmailAddress("b@example.com"),
                             imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        let own = MessageSummary(id: MessageID("own"), threadID: nil, from: first.email,
                                 subject: "Tuesday availability", preview: "Tuesday availability",
                                 smartCategory: .personal)
        let foreign = MessageSummary(id: MessageID("foreign"), threadID: nil, from: second.email,
                                     subject: "Tuesday availability", preview: "Tuesday availability",
                                     smartCategory: .personal)
        let store = InMemoryMailStore(accounts: [first, second], messages: [own, foreign], memberships: [
            MailboxMessageMembership(accountID: first.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1, messageID: own.id),
            MailboxMessageMembership(accountID: second.id, mailboxPath: "INBOX", uidValidity: 1, uid: 1, messageID: foreign.id),
        ])
        let provider = DeterministicAIProvider()
        _ = try await DurableMailEmbeddingIndexer(provider: provider, store: store).rebuild()
        let answer = try await LocalMailQuestionAnsweringService(provider: provider, store: store).answer(
            AskMailboxQuestionInput(question: "Tuesday availability", accountID: first.id),
            actor: PlainpostFixtures.guiUser)
        XCTAssertEqual(answer.sources.map(\.messageID), [own.id])
    }

    func testForeignHighScoreEmbeddingDoesNotChangeSelectedAccountRetrievalMode() async throws {
        let ownAccount = AccountID("own-account"), foreignAccount = AccountID("foreign-account")
        let own = MessageSummary(id: MessageID("own-lexical"), threadID: nil,
                                 from: EmailAddress("own@example.com"),
                                 subject: "Tuesday availability", preview: "Available Tuesday",
                                 smartCategory: .personal)
        let foreign = MessageSummary(id: MessageID("foreign-semantic"), threadID: nil,
                                     from: EmailAddress("foreign@example.com"),
                                     subject: "Private plan", preview: "Confidential details",
                                     smartCategory: .personal)
        let store = InMemoryMailStore(messages: [own, foreign], memberships: [
            MailboxMessageMembership(accountID: ownAccount, mailboxPath: "INBOX", uidValidity: 1,
                                     uid: 1, messageID: own.id),
            MailboxMessageMembership(accountID: foreignAccount, mailboxPath: "INBOX", uidValidity: 1,
                                     uid: 1, messageID: foreign.id),
        ])
        let provider = DeterministicAIProvider()
        let query = try await provider.embed(AIEmbeddingRequest(text: "Tuesday availability"))
        try store.replaceMailEmbeddingChunks(
            messageID: foreign.id, providerID: provider.id, modelID: query.modelID,
            contentFingerprint: MailEmbeddingContent.fingerprint(for: foreign),
            chunks: [StoredMailEmbeddingChunk(
                messageID: foreign.id, providerID: provider.id, modelID: query.modelID,
                contentFingerprint: MailEmbeddingContent.fingerprint(for: foreign), ordinal: 0,
                text: "Private plan", vector: query.vector)])

        let answer = try await LocalMailQuestionAnsweringService(provider: provider, store: store).answer(
            AskMailboxQuestionInput(question: "Tuesday availability", accountID: ownAccount),
            actor: PlainpostFixtures.guiUser)
        XCTAssertEqual(answer.sources.map(\.messageID), [own.id])
        XCTAssertEqual(answer.retrievalMode, .lexical)
    }

    func testActiveConversationIsAmbientEvidenceNotRequiredSearchText() async throws {
        let message = PlainpostFixtures.aliceMessage
        let store = InMemoryMailStore(messages: [message])
        let service = LocalMailQuestionAnsweringService(provider: CitationTestProvider(), store: store)

        let answer = try await service.answer(
            AskMailboxQuestionInput(
                question: "What is happening in this conversation?",
                activeConversationKey: MailThreading.conversationKey(for: message)
            ),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(answer.sources.map(\.messageID), [message.id])
    }

    func testReturnsInsufficientEvidenceWithoutCallingGeneration() async throws {
        let provider = CitationTestProvider()
        let store = InMemoryMailStore()
        let service = LocalMailQuestionAnsweringService(provider: provider, store: store)

        let answer = try await service.answer(
            AskMailboxQuestionInput(question: "Where is the signed contract?"),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertTrue(answer.insufficientEvidence)
        XCTAssertTrue(answer.sources.isEmpty)
        XCTAssertEqual(provider.generationCount, 0)
    }

    func testEmbeddingCapableProviderUsesHybridRetrieval() async throws {
        let store = InMemoryMailStore(messages: [PlainpostFixtures.aliceMessage])
        let provider = DeterministicAIProvider()
        _ = try await DurableMailEmbeddingIndexer(provider: provider, store: store).rebuild()
        let service = LocalMailQuestionAnsweringService(provider: provider, store: store)

        let answer = try await service.answer(
            AskMailboxQuestionInput(question: "meeting availability next Tuesday"),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(answer.retrievalMode, .hybrid)
        XCTAssertEqual(answer.sources.first?.messageID, PlainpostFixtures.aliceMessage.id)
    }

    func testConversationScopeWithoutContextFailsClosed() async {
        let service = LocalMailQuestionAnsweringService(
            provider: DeterministicAIProvider(),
            store: InMemoryMailStore(messages: [PlainpostFixtures.aliceMessage])
        )

        await XCTAssertThrowsErrorAsync(
            try await service.answer(
                AskMailboxQuestionInput(question: "What is this?", scope: .activeConversation),
                actor: PlainpostFixtures.guiUser
            )
        ) { error in
            XCTAssertEqual(
                error as? PlainpostError,
                .validationFailed("This Conversation scope requires an active conversation.")
            )
        }
    }

    func testUnknownCitationFailsClosed() async throws {
        let service = LocalMailQuestionAnsweringService(
            provider: CitationTestProvider(response: "Unsupported claim. [S99]"),
            store: InMemoryMailStore(messages: [PlainpostFixtures.aliceMessage])
        )

        let answer = try await service.answer(
            AskMailboxQuestionInput(question: "Tuesday availability"),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertTrue(answer.insufficientEvidence)
        XCTAssertTrue(answer.sources.isEmpty)
        XCTAssertFalse(answer.answer.contains("Unsupported claim"))
    }

    func testUnrelatedActiveConversationDoesNotBecomeEvidence() async throws {
        let message = PlainpostFixtures.aliceMessage
        let service = LocalMailQuestionAnsweringService(
            provider: CitationTestProvider(),
            store: InMemoryMailStore(messages: [message])
        )

        let answer = try await service.answer(
            AskMailboxQuestionInput(
                question: "Where is the signed contractor agreement?",
                activeConversationKey: MailThreading.conversationKey(for: message)
            ),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertTrue(answer.insufficientEvidence)
        XCTAssertTrue(answer.sources.isEmpty)
    }

    func testFollowUpRetrievalUsesRecentUserQuestion() async throws {
        let message = MessageSummary(
            id: MessageID("msg_followup_quote"),
            threadID: ThreadID("thr_followup_quote"),
            from: EmailAddress("builder@example.com"),
            subject: "Contractor quote",
            preview: "The amount is 4,200 euros.",
            body: "The contractor quote is 4,200 euros.",
            smartCategory: .personal
        )
        let service = LocalMailQuestionAnsweringService(
            provider: CitationTestProvider(),
            store: InMemoryMailStore(messages: [message])
        )

        let answer = try await service.answer(
            AskMailboxQuestionInput(
                question: "How much was it?",
                priorTurns: [
                    MailboxConversationTurn(
                        question: "What did the contractor quote?",
                        answer: "The quote was discussed. [S1]"
                    )
                ]
            ),
            actor: PlainpostFixtures.guiUser
        )

        XCTAssertEqual(answer.sources.first?.messageID, message.id)
    }
}

private final class CitationTestProvider: AIProvider, @unchecked Sendable {
    let id = "citation-test"
    let displayName = "Citation Test"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 4_096,
        runsLocally: true
    )
    private let lock = NSLock()
    private var generations = 0
    private let response: String

    init(response: String = "The contractor quoted 4,200 euros. [S1]") {
        self.response = response
    }

    var generationCount: Int { lock.withLock { generations } }

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        lock.withLock { generations += 1 }
        return AIGenerationResponse(
            text: response,
            modelID: "citation-test-model",
            localOnly: true
        )
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
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
