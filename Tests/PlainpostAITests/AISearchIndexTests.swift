import XCTest
@testable import PlainpostAI
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class AISearchIndexTests: XCTestCase {
    func testDeterministicEmbeddingIsLocalAndRepeatable() async throws {
        let provider = DeterministicAIProvider()

        let first = try await provider.embed(AIEmbeddingRequest(text: "Can you meet next Tuesday?"))
        let second = try await provider.embed(AIEmbeddingRequest(text: "Can you meet next Tuesday?"))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.modelID, "deterministic-local-embedding")
        XCTAssertFalse(first.vector.isEmpty)
    }

    func testSemanticSearchRanksIndexedLocalMessages() async throws {
        let provider = DeterministicAIProvider()
        let store = InMemoryMailStore.seededForStage0()
        let index = LocalAISearchIndex(provider: provider)

        try await index.indexMessages(store.messages, actor: PlainpostFixtures.codexActor)
        let results = try await index.search(
            AISearchInput(query: "meeting availability next Tuesday", limit: 5),
            actor: PlainpostFixtures.codexActor
        )

        XCTAssertEqual(results.query, "meeting availability next Tuesday")
        XCTAssertEqual(results.hits.map(\.message.id), [MessageID("msg_alice_1")])
        XCTAssertGreaterThan(results.hits[0].score, 0.5)
        XCTAssertTrue(results.hits[0].localOnly)
        XCTAssertTrue(results.hits[0].snippet.contains("Tuesday"))
    }

    func testSemanticSearchRejectsRestrictedAgentPermission() async throws {
        let provider = DeterministicAIProvider()
        let store = InMemoryMailStore.seededForStage0()
        let index = LocalAISearchIndex(provider: provider)
        let restrictedActor = Actor(
            id: "restricted-search-agent",
            kind: .mcpAgent,
            displayName: "Restricted Search Agent",
            permissions: .agentRequested(
                readBody: true,
                createDrafts: true,
                requestSend: true,
                useAISummary: true,
                useAIDraftReply: true,
                useAISemanticSearch: false,
                useAIClassification: true
            )
        )

        try await index.indexMessages(store.messages, actor: PlainpostFixtures.codexActor)

        await XCTAssertThrowsErrorAsync(
            try await index.search(
                AISearchInput(query: "meeting availability next Tuesday", limit: 5),
                actor: restrictedActor
            )
        ) { error in
            XCTAssertEqual(error as? PlainpostError, .permissionDenied("Actor is not allowed to use AI semantic search."))
        }
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
