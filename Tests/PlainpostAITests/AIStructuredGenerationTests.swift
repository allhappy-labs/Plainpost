import XCTest
@testable import PlainpostAI
@testable import PlainpostCore

private struct EchoProvider: AIProvider {
    let id = "echo"
    let displayName = "Echo"
    let chatModelID = "echo-1"
    let capabilities = AICapabilities(supportsChat: true, supportsEmbeddings: false, supportsJSONMode: false,
                                      supportsStreaming: false, maxContextTokens: 4096, runsLocally: true)
    let reply: String
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: reply, modelID: chatModelID, localOnly: true)
    }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
    func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse { throw AIProviderError.unavailable }
}

final class AIStructuredGenerationTests: XCTestCase {
    private let schema = AIStructuredSchema.object(name: "Card", description: nil, properties: [
        AIStructuredProperty(name: "kind", schema: .string(description: nil, choices: ["flight", "other"]), isOptional: false),
        AIStructuredProperty(name: "fields", schema: .array(.string(description: nil, choices: nil), description: nil, maxCount: 3), isOptional: true),
    ])

    func testDefaultImplementationExtractsJSONFromProse() async throws {
        let provider = EchoProvider(reply: "Sure! Here it is:\n```json\n{\"kind\": \"flight\", \"fields\": [\"14A\"]}\n```")
        let response = try await provider.generateStructured(AIStructuredGenerationRequest(prompt: "p", schema: schema))
        let object = try JSONSerialization.jsonObject(with: response.json) as? [String: Any]
        XCTAssertEqual(object?["kind"] as? String, "flight")
    }

    func testDefaultImplementationThrowsWhenNoJSON() async {
        let provider = EchoProvider(reply: "I cannot help with that.")
        do {
            _ = try await provider.generateStructured(AIStructuredGenerationRequest(prompt: "p", schema: schema))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
    }

    func testJSONSchemaRendering() throws {
        let json = schema.jsonSchema
        XCTAssertEqual(json["type"] as? String, "object")
        XCTAssertEqual(json["required"] as? [String], ["kind"])
        let props = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual((props["kind"] as? [String: Any])?["enum"] as? [String], ["flight", "other"])
        XCTAssertEqual((props["fields"] as? [String: Any])?["maxItems"] as? Int, 3)
    }

    func testExtractionHandlesBracesInsideStrings() {
        let data = AIJSONExtraction.firstObject(in: "x {\"a\": \"}{\", \"b\": {\"c\": 1}} y")
        XCTAssertNotNil(data)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data!))
    }
}
