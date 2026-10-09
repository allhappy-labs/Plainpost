import Foundation
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
import PlainpostCore
import PlainpostDB
import PlainpostTestSupport
@testable import PlainpostAI

final class AIProviderTests: XCTestCase {
    func testDeterministicProviderReturnsOneBatchCandidatePerRequestedID() async throws {
        let request = classificationBatchRequest(ids: ["det-1", "det-2", "det-3"])

        let response = try await DeterministicAIProvider().classifyBatch(request)

        XCTAssertEqual(response.results.map(\.id), ["det-1", "det-2", "det-3"])
        XCTAssertEqual(response.results.map(\.category), ["unknown", "unknown", "unknown"])
        XCTAssertEqual(response.results.map(\.priority), ["normal", "normal", "normal"])
        XCTAssertEqual(response.results.map(\.requiresAction), [false, false, false])
        XCTAssertEqual(response.results.map(\.confidence), [0.92, 0.92, 0.92])
    }

    func testDefaultBatchAdapterPreservesInputOrderAndCallsLegacyClassifierOncePerItem() async throws {
        let recorder = LegacyClassificationRecorder()
        let provider = RecordingLegacyProvider(recorder: recorder)
        let request = classificationBatchRequest(ids: ["legacy-c", "legacy-a", "legacy-b"])

        let response = try await provider.classifyBatch(request)

        let recordedIDs = await recorder.messageIDs
        XCTAssertEqual(recordedIDs, ["legacy-c", "legacy-a", "legacy-b"])
        XCTAssertEqual(response.results.map(\.id), ["legacy-c", "legacy-a", "legacy-b"])
        XCTAssertEqual(response.results.map(\.category), ["personal", "personal", "personal"])
        XCTAssertEqual(response.results.map(\.priority), ["normal", "normal", "normal"])
        XCTAssertEqual(response.results.map(\.requiresAction), [false, false, false])
        XCTAssertEqual(response.results.map(\.confidence), [0.73, 0.73, 0.73])
    }

    func testFoundationModelsProviderIsLocalChatProvider() throws {
        let provider = try LocalAIProviderResolver.resolve(
            LocalAIProviderSelection(providerID: "foundation")
        )

        XCTAssertEqual(provider.id, "foundation")
        XCTAssertEqual(provider.displayName, "Apple Foundation Models")
        XCTAssertTrue(provider.capabilities.runsLocally)
        XCTAssertTrue(provider.capabilities.supportsChat)
        XCTAssertFalse(provider.capabilities.supportsEmbeddings)
    }

    func testFoundationModelsChatModelIDIsStable() {
        XCTAssertEqual(FoundationModelsAIProvider().chatModelID, "apple-foundation-system")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    func testFoundationModelsMapsUnsupportedLanguageWithoutPersistingFrameworkDetail() {
        let context = LanguageModelSession.GenerationError.Context(
            debugDescription: "sensitive unsupported-language framework detail"
        )

        let mapped = foundationModelsProviderError(
            from: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)
        )

        XCTAssertEqual(mapped, .unsupportedLanguageOrLocale)
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testFoundationModelsMapsGuardrailViolationWithoutPersistingFrameworkDetail() {
        let context = LanguageModelSession.GenerationError.Context(
            debugDescription: "sensitive guardrail framework detail"
        )

        let mapped = foundationModelsProviderError(
            from: LanguageModelSession.GenerationError.guardrailViolation(context)
        )

        XCTAssertEqual(mapped, .guardrailViolation)
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testFoundationModelsLeavesUnclassifiedGenerationErrorsOpaque() {
        let context = LanguageModelSession.GenerationError.Context(
            debugDescription: "sensitive context-window framework detail"
        )

        let mapped = foundationModelsProviderError(
            from: LanguageModelSession.GenerationError.exceededContextWindowSize(context)
        )

        XCTAssertNil(mapped)
    }
    #endif

    func testOllamaChatModelIDIncludesConfiguredModel() throws {
        XCTAssertEqual(try makeStubbedOllamaProvider().chatModelID, "ollama:qwen3:8b")
    }

    func testFoundationModelsStatusReflectsInjectedAvailability() {
        let ready = AIProviderStatusService.foundation(availability: .available)
        let unavailable = AIProviderStatusService.foundation(
            availability: .unavailable("Apple Intelligence is unavailable on this Mac.")
        )

        XCTAssertEqual(ready.providerID, "foundation")
        XCTAssertEqual(ready.displayName, "Apple Foundation Models")
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.chatModelID, "apple-foundation-system")
        XCTAssertNil(ready.embeddingModelID)
        XCTAssertTrue(ready.localOnly)
        XCTAssertEqual(ready.detail, "Apple on-device Foundation Models are available.")
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.detail, "Apple Intelligence is unavailable on this Mac.")
    }

    func testAIActionAvailabilityUsesProviderStatusAndOperationCapabilities() {
        let foundation = FoundationModelsAIProvider()
        let ready = AIProviderStatusService.foundation(availability: .available)
        XCTAssertTrue(AIActionAvailability.resolve(provider: foundation, status: ready, operation: .summary).isAvailable)
        XCTAssertTrue(AIActionAvailability.resolve(provider: foundation, status: ready, operation: .draftReply).isAvailable)
        XCTAssertTrue(AIActionAvailability.resolve(provider: foundation, status: ready, operation: .askMail).isAvailable)
        XCTAssertTrue(AIActionAvailability.resolve(provider: foundation, status: ready, operation: .translation).isAvailable)
        XCTAssertFalse(AIActionAvailability.resolve(provider: foundation, status: ready, operation: .embeddings).isAvailable)

        let unavailable = AIProviderStatusService.foundation(availability: .deviceNotEligible)
        let summary = AIActionAvailability.resolve(provider: foundation, status: unavailable, operation: .summary)
        XCTAssertFalse(summary.isAvailable)
        XCTAssertTrue(summary.reason?.contains("device") == true)
        XCTAssertFalse(summary.canCheckAgain)

        let oldOS = AIProviderStatusService.foundation(availability: .requiresNewerOS)
        XCTAssertTrue(oldOS.detail.contains("iOS 26"))
        XCTAssertFalse(AIActionAvailability.resolve(provider: foundation, status: oldOS, operation: .threadQuestion).isAvailable)
        XCTAssertFalse(AIActionAvailability.resolve(provider: foundation, status: oldOS, operation: .translation).isAvailable)
        let disabled = AIProviderStatusService.foundation(availability: .appleIntelligenceDisabled)
        XCTAssertTrue(disabled.detail.contains("Settings"))
        XCTAssertTrue(disabled.canCheckAgain)

        let notReady = AIProviderStatusService.foundation(availability: .modelNotReady)
        XCTAssertTrue(AIActionAvailability.resolve(provider: foundation, status: notReady, operation: .summary).canCheckAgain)
        XCTAssertTrue(notReady.localOnly)
        XCTAssertTrue(notReady.detail.contains("on-device model isn’t ready"))
        XCTAssertTrue(notReady.detail.contains("Apple Intelligence in Settings"))
        XCTAssertTrue(notReady.detail.contains("device and Siri languages"))
        XCTAssertTrue(notReady.detail.contains("free storage"))
        XCTAssertTrue(notReady.detail.contains("Siri AI beta"))
        XCTAssertLessThanOrEqual(notReady.detail.count, 210)
        XCTAssertFalse(notReady.detail.contains("downloading"))
        XCTAssertTrue(AIActionAvailability.resolve(
            provider: DeterministicAIProvider(), status: AIProviderStatusService.deterministic(), operation: .askMail
        ).isAvailable)
    }

    func testOlderIOSDisablesEveryAIActionEvenWhenAnotherProviderIsReady() {
        let provider = DeterministicAIProvider()
        let ready = AIProviderStatusService.deterministic()
        let operations: [AIActionOperation] = [
            .summary, .threadQuestion, .draftReply, .askMail, .translation, .embeddings
        ]

        for operation in operations {
            let availability = AIActionAvailability.resolve(
                provider: provider,
                status: ready,
                operation: operation,
                platformAvailability: .requiresNewerOS
            )
            XCTAssertFalse(availability.isAvailable, "Expected \(operation) to be unavailable before iOS 26")
            XCTAssertTrue(availability.reason?.contains("iOS 26") == true)
        }
    }

    func testNewerIOSDoesNotDisableConfiguredProvider() {
        let provider = DeterministicAIProvider()
        let availability = AIActionAvailability.resolve(
            provider: provider,
            status: AIProviderStatusService.deterministic(),
            operation: .summary,
            platformAvailability: .available
        )

        XCTAssertTrue(availability.isAvailable)
    }

    func testFoundationModelsClassifiesWithTheOnDeviceModelWhenAvailable() async throws {
        guard FoundationModelsAvailability.current() == .available else {
            throw XCTSkip("Apple Foundation Models are unavailable on this test machine.")
        }
        let message = MessageSummary(
            id: MessageID("msg_foundation_category"),
            threadID: nil,
            from: EmailAddress("newsletter@example.com"),
            subject: "Your weekly product newsletter",
            preview: "This week’s stories and analysis.",
            smartCategory: .unknown
        )

        let response = try await FoundationModelsAIProvider().classify(
            AIClassificationRequest(message: message)
        )

        XCTAssertEqual(response.reason, "Classified by Apple Foundation Models.")
        XCTAssertNotEqual(response.category, .unknown)
    }

    func testFoundationModelsSerializesConcurrentRequestsWhenAvailable() async throws {
        guard FoundationModelsAvailability.current() == .available else {
            throw XCTSkip("Apple Foundation Models are unavailable on this test machine.")
        }
        let provider = FoundationModelsAIProvider()
        let first = MessageSummary(
            id: MessageID("msg_foundation_concurrent_1"),
            threadID: nil,
            from: EmailAddress("alerts@example.com"),
            subject: "Security alert",
            preview: "A new sign-in was detected.",
            smartCategory: .unknown
        )
        let second = MessageSummary(
            id: MessageID("msg_foundation_concurrent_2"),
            threadID: nil,
            from: EmailAddress("digest@example.com"),
            subject: "Weekly digest",
            preview: "Stories from this week.",
            smartCategory: .unknown
        )

        async let firstResult = provider.classify(AIClassificationRequest(message: first))
        async let secondResult = provider.classify(AIClassificationRequest(message: second))
        let results = try await [firstResult, secondResult]

        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(results.contains { $0.category == .unknown })
    }

    func testFoundationModelsBatchUsesStructuredFiveFieldDecodingWhenAvailable() async throws {
        guard FoundationModelsAvailability.current() == .available else {
            throw XCTSkip("Apple Foundation Models are unavailable on this test machine.")
        }
        let request = classificationBatchRequest(ids: ["foundation-structured"])

        let response = try await FoundationModelsAIProvider().classifyBatch(request)

        let candidate = try XCTUnwrap(response.results.first)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(candidate.id, "foundation-structured")
        XCTAssertNotNil(candidate.category)
        XCTAssertNotNil(candidate.priority)
        XCTAssertNotNil(candidate.requiresAction)
        XCTAssertNotNil(candidate.confidence)
    }

    func testDisabledProviderIsLocalAndUnavailable() async {
        let provider = DisabledAIProvider()

        XCTAssertEqual(provider.id, "disabled")
        XCTAssertTrue(provider.capabilities.runsLocally)

        do {
            _ = try await provider.generate(AIGenerationRequest(prompt: "Summarize this"))
            XCTFail("Expected disabled provider to throw")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unavailable)
        }
    }

    func testOllamaProviderGeneratesThroughLocalHTTP() async throws {
        let server = LocalOllamaServer()
        try await server.start()
        defer { server.stop() }

        let configuration = try OllamaProviderConfiguration(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            chatModelID: "qwen3:8b",
            embeddingModelID: "mxbai-embed-large"
        )
        let provider = OllamaProvider(configuration: configuration)

        let response = try await provider.generate(AIGenerationRequest(prompt: "Summarize locally"))

        XCTAssertEqual(response.text, "Local Ollama summary.")
        XCTAssertEqual(response.modelID, "ollama:qwen3:8b")
        XCTAssertTrue(response.localOnly)
        XCTAssertEqual(provider.capabilities.runsLocally, true)

        let request = try await server.request(at: 0)
        XCTAssertEqual(request.path, "/api/generate")
        let body = try request.jsonBody()
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["prompt"] as? String, "Summarize locally")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testOllamaProviderEmbedsThroughLocalHTTP() async throws {
        let server = LocalOllamaServer()
        try await server.start()
        defer { server.stop() }

        let configuration = try OllamaProviderConfiguration(
            baseURL: URL(string: "http://localhost:\(server.port)")!,
            chatModelID: "qwen3:8b",
            embeddingModelID: "mxbai-embed-large"
        )
        let provider = OllamaProvider(configuration: configuration)

        let response = try await provider.embed(AIEmbeddingRequest(text: "contract draft"))

        XCTAssertEqual(response.vector, [0.25, 0.5, 0.75])
        XCTAssertEqual(response.modelID, "ollama:mxbai-embed-large")

        let request = try await server.request(at: 0)
        XCTAssertEqual(request.path, "/api/embeddings")
        let body = try request.jsonBody()
        XCTAssertEqual(body["model"] as? String, "mxbai-embed-large")
        XCTAssertEqual(body["prompt"] as? String, "contract draft")
    }

    func testOllamaProviderClassifiesLocalJSONResponse() async throws {
        let server = LocalOllamaServer()
        server.generateResponseText = #"{"category":"personal","confidence":0.84,"reason":"Local Ollama classifier."}"#
        try await server.start()
        defer { server.stop() }

        let configuration = try OllamaProviderConfiguration(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            chatModelID: "qwen3:8b",
            embeddingModelID: "mxbai-embed-large"
        )
        let provider = OllamaProvider(configuration: configuration)
        let message = MessageSummary(
            id: MessageID("msg_ollama"),
            threadID: ThreadID("thr_ollama"),
            from: EmailAddress("alice@example.com"),
            subject: "Availability",
            preview: "Can you meet Tuesday?",
            smartCategory: .unknown
        )

        let response = try await provider.classify(AIClassificationRequest(message: message))

        XCTAssertEqual(response.category, .personal)
        XCTAssertEqual(response.confidence, 0.84)
        XCTAssertEqual(response.reason, "Local Ollama classifier.")

        let request = try await server.request(at: 0)
        XCTAssertEqual(request.path, "/api/generate")
        let body = try request.jsonBody()
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertTrue((body["prompt"] as? String)?.contains("Allowed categories:") == true)
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testOllamaProviderClassifiesCategoryTokenResponse() async throws {
        let server = LocalOllamaServer()
        server.generateResponseText = "newsletter"
        try await server.start()
        defer { server.stop() }

        let configuration = try OllamaProviderConfiguration(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!
        )
        let provider = OllamaProvider(configuration: configuration)
        let message = MessageSummary(
            id: MessageID("msg_ollama_token"),
            threadID: nil,
            from: EmailAddress("digest@example.com"),
            subject: "Weekly digest",
            preview: "Stories from this week.",
            smartCategory: .unknown
        )

        let response = try await provider.classify(AIClassificationRequest(message: message))

        XCTAssertEqual(response.category, .newsletter)
        XCTAssertEqual(response.confidence, 0.8)
        XCTAssertEqual(response.reason, "Classified by Ollama Local.")
    }

    func testOllamaBatchUsesOneStructuredGenerationWithoutReason() async throws {
        OllamaURLProtocolStub.reset(
            responseText: #"{"results":[{"id":"ollama-1","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[]},{"id":"ollama-2","category":"newsletter","priority":"low","requires_action":false,"confidence":0.83,"labels":[]},{"id":"ollama-3","category":"finance","priority":"normal","requires_action":true,"confidence":0.77,"labels":[]},{"id":"ollama-4","category":"notification","priority":"normal","requires_action":false,"confidence":0.72,"labels":[]}]}"#
        )
        let provider = try makeStubbedOllamaProvider()
        let request = classificationBatchRequest(ids: ["ollama-1", "ollama-2", "ollama-3", "ollama-4"])

        let response = try await provider.classifyBatch(request)

        XCTAssertEqual(response.results.map(\.id), ["ollama-1", "ollama-2", "ollama-3", "ollama-4"])
        let requests = OllamaURLProtocolStub.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let captured = try XCTUnwrap(requests.first)
        XCTAssertEqual(captured.url?.path, "/api/generate")
        let body = try captured.jsonBody()
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["temperature"] as? Int, 0)
        let format = try XCTUnwrap(body["format"] as? [String: Any])
        let properties = try XCTUnwrap(format["properties"] as? [String: Any])
        let results = try XCTUnwrap(properties["results"] as? [String: Any])
        let items = try XCTUnwrap(results["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertEqual(Set(itemProperties.keys), ["id", "category", "priority", "requires_action", "confidence", "labels"])
        XCTAssertNil(itemProperties["reason"])
    }

    func testOllamaBatchLossyParserRetainsValidSiblings() async throws {
        OllamaURLProtocolStub.reset(
            responseText: #"{"results":[{"id":"valid-1","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[]},{"id":"malformed","category":7,"priority":"normal","requires_action":"yes","confidence":"high","labels":[]},{"id":"valid-2","category":"newsletter","priority":"low","requires_action":false,"confidence":0.82,"labels":[]}]}"#
        )
        let provider = try makeStubbedOllamaProvider()
        let request = classificationBatchRequest(ids: ["valid-1", "malformed", "valid-2"])

        let response = try await provider.classifyBatch(request)
        let validation = SmartInboxBatchValidator.validate(request: request, response: response)

        XCTAssertEqual(response.results.count, 3)
        XCTAssertEqual(validation.valid.map(\.messageID.rawValue), ["valid-1", "valid-2"])
        XCTAssertEqual(validation.unresolved, [MessageID("malformed")])
    }

    func testOllamaBatchRejectsUnexpectedResultKeysAndRetainsValidSibling() async throws {
        OllamaURLProtocolStub.reset(
            responseText: #"{"results":[{"id":"extra-key","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[],"unexpected":"reject me"},{"id":"valid","category":"newsletter","priority":"low","requires_action":false,"confidence":0.82,"labels":[]}]}"#
        )
        let provider = try makeStubbedOllamaProvider()
        let request = classificationBatchRequest(ids: ["extra-key", "valid"])

        let response = try await provider.classifyBatch(request)
        let validation = SmartInboxBatchValidator.validate(request: request, response: response)

        XCTAssertEqual(response.results.map(\.id), ["extra-key", "valid"])
        XCTAssertEqual(validation.valid.map(\.messageID), [MessageID("valid")])
        XCTAssertEqual(validation.unresolved, [MessageID("extra-key")])
        XCTAssertEqual(validation.diagnostics, [.init(code: .invalidCategory, count: 1)])
    }

    func testOllamaMalformedResultKeepsDuplicateIDInvalidAndRetainsSibling() async throws {
        OllamaURLProtocolStub.reset(
            responseText: #"{"results":[{"id":"duplicate","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[],"unexpected":"reject me"},{"id":"duplicate","category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[]},{"id":"valid","category":"newsletter","priority":"low","requires_action":false,"confidence":0.82,"labels":[]}]}"#
        )
        let provider = try makeStubbedOllamaProvider()
        let request = classificationBatchRequest(ids: ["duplicate", "valid"])

        let response = try await provider.classifyBatch(request)
        let validation = SmartInboxBatchValidator.validate(request: request, response: response)

        XCTAssertEqual(response.results.map(\.id), ["duplicate", "duplicate", "valid"])
        XCTAssertEqual(validation.valid.map(\.messageID), [MessageID("valid")])
        XCTAssertEqual(validation.unresolved, [MessageID("duplicate")])
        XCTAssertEqual(validation.diagnostics, [.init(code: .duplicateResult, count: 1)])
    }

    func testOllamaMalformedResultWithoutIDCannotMutateRequestedSibling() async throws {
        OllamaURLProtocolStub.reset(
            responseText: #"{"results":[{"category":"personal","priority":"high","requires_action":true,"confidence":0.91,"labels":[],"unexpected":"reject me"},{"id":"valid","category":"newsletter","priority":"low","requires_action":false,"confidence":0.82,"labels":[]}]}"#
        )
        let provider = try makeStubbedOllamaProvider()
        let request = classificationBatchRequest(ids: ["missing", "valid"])

        let response = try await provider.classifyBatch(request)
        let validation = SmartInboxBatchValidator.validate(request: request, response: response)

        XCTAssertEqual(response.results.map(\.id), [nil, "valid"])
        XCTAssertEqual(validation.valid.map(\.messageID), [MessageID("valid")])
        XCTAssertEqual(validation.unresolved, [MessageID("missing")])
        XCTAssertEqual(validation.diagnostics, [
            .init(code: .missingID, count: 1),
            .init(code: .missingResult, count: 1),
        ])
    }

    func testSmartInboxRecategorizationPersistsProviderCategories() async throws {
        let message = MessageSummary(
            id: MessageID("msg_category"),
            threadID: nil,
            from: EmailAddress("updates@example.com"),
            subject: "Product update",
            preview: "A new update is available.",
            smartCategory: .unknown
        )
        let store = InMemoryMailStore(messages: [message])
        let service = SmartInboxRecategorizationService(
            provider: StaticCategoryProvider(category: .notification),
            store: store
        )

        let result = try await service.recategorizeMessages()

        XCTAssertEqual(result.providerID, "test-provider")
        XCTAssertEqual(result.categorizedMessageCount, 1)
        XCTAssertEqual(result.failedMessageCount, 0)
        XCTAssertEqual(store.messages.first?.smartCategory, .notification)
    }
}

private func classificationBatchRequest(ids: [String]) -> AIClassificationBatchRequest {
    AIClassificationBatchRequest(messages: ids.map { id in
        AIClassificationMessage(
            MailboxListMessage(
                id: MessageID(id),
                threadID: nil,
                from: EmailAddress("sender@example.com"),
                subject: "Subject for \(id)",
                preview: "Preview for \(id)",
                smartCategory: .unknown
            )
        )
    })
}

private func makeStubbedOllamaProvider() throws -> OllamaProvider {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [OllamaURLProtocolStub.self]
    return OllamaProvider(
        configuration: try OllamaProviderConfiguration(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            chatModelID: "qwen3:8b"
        ),
        session: URLSession(configuration: sessionConfiguration)
    )
}

private actor LegacyClassificationRecorder {
    private(set) var messageIDs: [String] = []

    func record(_ message: MessageSummary) {
        messageIDs.append(message.id.rawValue)
    }
}

private struct RecordingLegacyProvider: AIProvider {
    let recorder: LegacyClassificationRecorder
    let id = "recording-legacy"
    let displayName = "Recording Legacy"
    let capabilities = AICapabilities(
        supportsChat: false,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 1,
        runsLocally: true
    )

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        throw AIProviderError.unavailable
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        await recorder.record(request.message)
        return AIClassificationResponse(category: .personal, confidence: 0.73, reason: "legacy-only")
    }
}

private final class OllamaURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responseText = ""

    static var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    static func reset(responseText: String) {
        lock.withLock {
            requests = []
            self.responseText = responseText
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responseText = Self.lock.withLock {
            Self.requests.append(Self.materializingBody(in: request))
            return Self.responseText
        }
        let payload: [String: Any] = [
            "model": "qwen3:8b",
            "response": responseText,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
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

private struct StaticCategoryProvider: AIProvider {
    let category: SmartCategory
    let id = "test-provider"
    let displayName = "Test Provider"
    let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: false,
        supportsStreaming: false,
        maxContextTokens: 1,
        runsLocally: true
    )

    func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        AIGenerationResponse(text: category.rawValue, modelID: "test", localOnly: true)
    }

    func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        AIClassificationResponse(category: category, confidence: 1, reason: "Test category")
    }
}

private extension LocalOllamaHTTPRequest {
    func jsonBody() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

private extension URLRequest {
    func jsonBody() throws -> [String: Any] {
        let data = try XCTUnwrap(httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
