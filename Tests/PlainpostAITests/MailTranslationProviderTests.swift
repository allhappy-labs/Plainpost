import Foundation
import XCTest
import PlainpostTestSupport
@testable import PlainpostAI

final class MailTranslationProviderTests: XCTestCase {
    func testDeterministicTranslationPreservesRequestedIDs() async throws {
        let response = try await DeterministicAIProvider().translate(
            AITranslationRequest(
                targetLanguageID: "en",
                targetLanguageName: "English",
                segments: [
                    .init(id: "s0", text: "Hallo"),
                    .init(id: "s1", text: "Welt"),
                ]
            )
        )

        XCTAssertEqual(response.segments, [
            .init(id: "s0", translation: "Hallo"),
            .init(id: "s1", translation: "Welt"),
        ])
        XCTAssertEqual(response.modelID, "deterministic-local")
        XCTAssertTrue(response.localOnly)
    }

    func testOllamaTranslationRequestsJSONAndDecodesSegments() async throws {
        let server = LocalOllamaServer()
        server.generateResponseText = #"{"segments":[{"id":"s0","translation":"Hello"}]}"#
        try await server.start()
        defer { server.stop() }

        let provider = OllamaProvider(
            configuration: try OllamaProviderConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                chatModelID: "qwen3:8b"
            )
        )

        let response = try await provider.translate(
            AITranslationRequest(
                targetLanguageID: "en",
                targetLanguageName: "English",
                segments: [.init(id: "s0", text: "Hallo")]
            )
        )

        XCTAssertEqual(response.segments, [.init(id: "s0", translation: "Hello")])
        XCTAssertEqual(response.modelID, "ollama:qwen3:8b")
        XCTAssertTrue(response.localOnly)

        let request = try await server.request(at: 0)
        XCTAssertEqual(request.path, "/api/generate")
        let body = try request.jsonBody()
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["format"] as? String, "json")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertTrue((body["prompt"] as? String)?.contains(#""id":"s0""#) == true)
    }

    func testDefaultTranslationAdapterDecodesOneMarkdownFencedJSONResponse() async throws {
        let response = try await FencedTranslationProvider().translate(
            AITranslationRequest(
                targetLanguageID: "en",
                targetLanguageName: "English",
                segments: [.init(id: "s0", text: "Hallo")]
            )
        )

        XCTAssertEqual(response.segments, [.init(id: "s0", translation: "Hello")])
        XCTAssertEqual(response.modelID, "fenced-model")
        XCTAssertTrue(response.localOnly)
    }

    func testOrderedFoundationTranslationsUseTrustedRequestIDs() throws {
        let request = AITranslationRequest(
            targetLanguageID: "en",
            targetLanguageName: "English",
            segments: [
                .init(id: "segment-41", text: "Hallo"),
                .init(id: "segment-99", text: "Welt"),
            ]
        )

        XCTAssertEqual(
            try aligningFoundationTranslations(["Hello", "World"], to: request),
            [
                .init(id: "segment-41", translation: "Hello"),
                .init(id: "segment-99", translation: "World"),
            ]
        )
    }

    func testOrderedFoundationTranslationsRejectWrongCount() throws {
        let request = AITranslationRequest(
            targetLanguageID: "en",
            targetLanguageName: "English",
            segments: [.init(id: "segment-0", text: "Hallo")]
        )

        XCTAssertThrowsError(
            try aligningFoundationTranslations(["Hello", "invented"], to: request)
        ) { error in
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
    }
}

private struct FencedTranslationProvider: AIProvider {
    let id = "fenced"
    let displayName = "Fenced"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 1,
        runsLocally: true
    )

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(
            text: "```json\n{\"segments\":[{\"id\":\"s0\",\"translation\":\"Hello\"}]}\n```",
            modelID: "fenced-model",
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

private extension LocalOllamaHTTPRequest {
    func jsonBody() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
