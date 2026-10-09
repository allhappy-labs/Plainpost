import Foundation
import PlainpostCore
@testable import PlainpostAI
import XCTest

final class OpenRouterProviderTests: XCTestCase {
    private let configuration = OpenRouterConfiguration(apiKey: " sk-or-test ", modelID: " meta-llama/llama-3.3-70b-instruct:free ")

    override func tearDown() {
        OpenRouterURLProtocolStub.reset(status: 200, body: [:])
        super.tearDown()
    }

    func testConfigurationTrimsAndRequiresKeyAndModel() {
        XCTAssertEqual(configuration.apiKey, "sk-or-test")
        XCTAssertEqual(configuration.modelID, "meta-llama/llama-3.3-70b-instruct:free")
        XCTAssertTrue(configuration.isComplete)
        XCTAssertFalse(OpenRouterConfiguration(apiKey: "key", modelID: "  ").isComplete)
        XCTAssertFalse(OpenRouterConfiguration(apiKey: "", modelID: "model").isComplete)
    }

    func testGenerateSendsChatCompletionWithBearerKeyAndFreeTextModel() async throws {
        OpenRouterURLProtocolStub.reset(content: "Tuesday works.")

        let response = try await makeProvider().generate(AIGenerationRequest(prompt: "When?"))

        XCTAssertEqual(response.text, "Tuesday works.")
        XCTAssertEqual(response.modelID, "openrouter:meta-llama/llama-3.3-70b-instruct:free")
        XCTAssertFalse(response.localOnly)
        let request = try XCTUnwrap(OpenRouterURLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.url, OpenRouterProvider.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        let body = try request.openRouterJSONBody()
        XCTAssertEqual(body["model"] as? String, "meta-llama/llama-3.3-70b-instruct:free")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "When?"]])
        XCTAssertNil(body["response_format"])
    }

    func testClassifyBatchRequestsJSONSchemaAndParsesFencedReply() async throws {
        OpenRouterURLProtocolStub.reset(content: """
        ```json
        {"results":[{"id":"m1","category":"personal","priority":"high","requires_action":true,"confidence":0.9,"labels":[]}]}
        ```
        """)
        let request = AIClassificationBatchRequest(messages: [
            AIClassificationMessage(
                MailboxListMessage(
                    id: MessageID("m1"),
                    threadID: nil,
                    from: EmailAddress("a@example.com"),
                    subject: "Hi",
                    preview: "Hello",
                    smartCategory: .unknown
                )
            ),
        ])

        let response = try await makeProvider().classifyBatch(request)

        XCTAssertEqual(response.results.map(\.id), ["m1"])
        XCTAssertEqual(response.results.first?.category, "personal")
        XCTAssertEqual(response.results.first?.requiresAction, true)
        let body = try XCTUnwrap(OpenRouterURLProtocolStub.recordedRequests.first).openRouterJSONBody()
        XCTAssertEqual(body["temperature"] as? Int, 0)
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["results"])
    }

    func testTranslateDecodesSegmentsFromJSONObjectReply() async throws {
        OpenRouterURLProtocolStub.reset(content: #"Sure! {"segments":[{"id":"s1","translation":"Hallo"}]}"#)

        let response = try await makeProvider().translate(AITranslationRequest(
            targetLanguageID: "de", targetLanguageName: "German",
            segments: [AITranslationSegment(id: "s1", text: "Hello")]
        ))

        XCTAssertEqual(response.segments, [AITranslatedSegment(id: "s1", translation: "Hallo")])
        XCTAssertFalse(response.localOnly)
        let body = try XCTUnwrap(OpenRouterURLProtocolStub.recordedRequests.first).openRouterJSONBody()
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    func testGenerateStructuredExtractsObject() async throws {
        OpenRouterURLProtocolStub.reset(content: #"{"answer":"yes"}"#)
        let schema = AIStructuredSchema.object(name: "Answer", description: nil, properties: [
            AIStructuredProperty(name: "answer", schema: .string(description: nil, choices: nil), isOptional: false),
        ])

        let response = try await makeProvider().generateStructured(
            AIStructuredGenerationRequest(prompt: "Answer.", schema: schema)
        )

        let object = try JSONSerialization.jsonObject(with: response.json) as? [String: String]
        XCTAssertEqual(object, ["answer": "yes"])
    }

    func testErrorInsideSuccessfulResponseIsUnavailableForAIActions() async throws {
        OpenRouterURLProtocolStub.reset(status: 200, body: ["error": ["code": 502, "message": "Upstream failed"]])

        do {
            _ = try await makeProvider().generate(AIGenerationRequest(prompt: "Hi"))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
    }

    func testCheckConnectionReportsOpenRoutersOwnMessage() async throws {
        OpenRouterURLProtocolStub.reset(status: 401, body: ["error": ["code": 401, "message": "No auth credentials found"]])

        do {
            try await makeProvider().checkConnection()
            XCTFail("Expected failure")
        } catch let error as OpenRouterError {
            XCTAssertEqual(error, .requestFailed(status: 401, message: "No auth credentials found"))
            XCTAssertEqual(error.errorDescription, "OpenRouter rejected the API key. No auth credentials found")
        }
        let body = try XCTUnwrap(OpenRouterURLProtocolStub.recordedRequests.first).openRouterJSONBody()
        XCTAssertEqual(body["max_tokens"] as? Int, 2_048)
    }

    func testCheckConnectionExplainsReasoningModelThatRanOutOfTokens() async throws {
        OpenRouterURLProtocolStub.reset(status: 200, body: ["choices": [[
            "message": ["role": "assistant", "content": "", "reasoning": "The user wants OK..."],
            "finish_reason": "length",
        ]]])

        do {
            try await makeProvider().checkConnection()
            XCTFail("Expected failure")
        } catch let error as OpenRouterError {
            XCTAssertEqual(error, .truncatedBeforeAnswer)
        }
    }

    func testGenerateReadsContentReturnedAsTextParts() async throws {
        OpenRouterURLProtocolStub.reset(status: 200, body: ["choices": [[
            "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Tuesday "],
                ["type": "image_url", "image_url": ["url": "x"]],
                ["type": "text", "text": "works."],
            ]],
            "finish_reason": "stop",
        ]]])

        let response = try await makeProvider().generate(AIGenerationRequest(prompt: "When?"))

        XCTAssertEqual(response.text, "Tuesday works.")
    }

    func testResolverReadsStoredConfigurationAndRejectsIncompleteOne() throws {
        let store = InMemoryOpenRouterConfigurationStore(configuration)
        let provider = try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: "openrouter"), openRouterStore: store
        )
        XCTAssertEqual(provider.id, "openrouter")
        XCTAssertEqual(provider.chatModelID, "openrouter:meta-llama/llama-3.3-70b-instruct:free")
        XCTAssertFalse(provider.capabilities.runsLocally)
        XCTAssertTrue(provider.isPermittedMailProcessor)

        try store.save(OpenRouterConfiguration(apiKey: "key", modelID: ""))
        XCTAssertThrowsError(try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: "openrouter"), openRouterStore: store
        ))
        XCTAssertThrowsError(try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: "openrouter"),
            openRouterStore: InMemoryOpenRouterConfigurationStore()
        ))
    }

    func testOnlyLocalProvidersAndOpenRouterMayProcessMail() {
        XCTAssertTrue(DeterministicAIProvider().isPermittedMailProcessor)
        XCTAssertTrue(FoundationModelsAIProvider().isPermittedMailProcessor)
        XCTAssertFalse(UnknownRemoteProvider().isPermittedMailProcessor)
    }

    func testStatusSnapshotReflectsConfiguration() {
        XCTAssertEqual(AIProviderStatusService.openRouter(configuration: nil).state, .unavailable)
        let ready = AIProviderStatusService.openRouter(configuration: configuration)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.chatModelID, "meta-llama/llama-3.3-70b-instruct:free")
        XCTAssertFalse(ready.localOnly)
    }

    private func makeProvider() -> OpenRouterProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OpenRouterURLProtocolStub.self]
        return OpenRouterProvider(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
    }
}

private struct UnknownRemoteProvider: AIProvider {
    let id = "remote"
    let displayName = "Remote"
    let chatModelID = "remote"
    let capabilities = AICapabilities(
        supportsChat: true, supportsEmbeddings: false, supportsJSONMode: false,
        supportsStreaming: false, maxContextTokens: 1, runsLocally: false
    )
    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse { throw AIProviderError.unavailable }
    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse { throw AIProviderError.unavailable }
    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse { throw AIProviderError.unavailable }
}

private extension URLRequest {
    func openRouterJSONBody() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(httpBody)) as? [String: Any])
    }
}

private final class OpenRouterURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: [String: Any] = [:]

    static var recordedRequests: [URLRequest] { lock.withLock { requests } }

    static func reset(content: String) {
        reset(status: 200, body: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    static func reset(status: Int, body: [String: Any]) {
        lock.withLock {
            requests = []
            self.status = status
            self.body = body
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.requests.append(Self.materializingBody(in: request))
            return (Self.status, Self.body)
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func materializingBody(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var materialized = request
        materialized.httpBody = data
        return materialized
    }
}
