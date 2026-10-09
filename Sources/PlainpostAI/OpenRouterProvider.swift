import Foundation
import PlainpostCore
import PlainpostSecrets

/// The user's OpenRouter connection: an API key and a free-text model slug such as
/// `anthropic/claude-sonnet-4.5` or `meta-llama/llama-3.3-70b-instruct:free`.
public struct OpenRouterConfiguration: Equatable, Codable, Sendable {
    public static let providerID = "openrouter"
    public static let displayName = "OpenRouter"

    public let apiKey: String
    public let modelID: String

    public init(apiKey: String, modelID: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !apiKey.isEmpty && !modelID.isEmpty }
}

public protocol OpenRouterConfigurationStoring: Sendable {
    func load() -> OpenRouterConfiguration?
    func save(_ configuration: OpenRouterConfiguration) throws
    func clear() throws
}

/// Keeps the OpenRouter key and model in one Keychain item. On macOS the item lives in the
/// access group the app shares with the background service, which runs the AI jobs; on iOS
/// it lives in the app's own group, out of the Notification Service extension's reach.
public struct KeychainOpenRouterConfigurationStore: OpenRouterConfigurationStoring {
    public static let shared = KeychainOpenRouterConfigurationStore()

    #if os(iOS)
    public static let defaultAccessGroup = "9XN7WN8JN2.com.marynavdovenko.Plainpost.iOS"
    #else
    public static let defaultAccessGroup = "9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
    #endif

    private let item: KeychainDataItem

    public init(
        service: String = "com.marynavdovenko.Plainpost.AI",
        account: String = "openrouter",
        accessGroup: String? = Self.defaultAccessGroup
    ) {
        item = KeychainDataItem(service: service, account: account, accessGroup: accessGroup)
    }

    public func load() -> OpenRouterConfiguration? {
        item.load().flatMap { try? JSONDecoder().decode(OpenRouterConfiguration.self, from: $0) }
    }

    public func save(_ configuration: OpenRouterConfiguration) throws {
        try item.save(JSONEncoder().encode(configuration))
    }

    public func clear() throws {
        try item.delete()
    }
}

public final class InMemoryOpenRouterConfigurationStore: OpenRouterConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: OpenRouterConfiguration?

    public init(_ configuration: OpenRouterConfiguration? = nil) {
        self.configuration = configuration
    }

    public func load() -> OpenRouterConfiguration? { lock.withLock { configuration } }
    public func save(_ configuration: OpenRouterConfiguration) throws { lock.withLock { self.configuration = configuration } }
    public func clear() throws { lock.withLock { configuration = nil } }
}

public enum OpenRouterError: Error, Equatable, Sendable {
    case notConfigured
    case requestFailed(status: Int, message: String)
    case emptyResponse
    /// The model stopped at its token limit before writing any answer, usually because a
    /// reasoning model spent the whole allowance thinking.
    case truncatedBeforeAnswer
}

extension OpenRouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add an OpenRouter API key and model."
        case let .requestFailed(status, message):
            switch status {
            case 401: "OpenRouter rejected the API key. \(message)"
            case 402: "Your OpenRouter account is out of credits. \(message)"
            case 404: "OpenRouter doesn’t know this model. Check the model name. \(message)"
            case 429: "OpenRouter is rate limiting requests. Try again shortly. \(message)"
            default: "OpenRouter request failed (\(status)). \(message)"
            }
        case .emptyResponse:
            "OpenRouter returned an empty reply. Try another model."
        case .truncatedBeforeAnswer:
            "The model used its whole reply allowance before answering. Try a model without extended reasoning."
        }
    }
}

/// A remote chat-completions provider. Mail content leaves the device, so this provider
/// exists only after the user picks OpenRouter and enters their own key.
public struct OpenRouterProvider: AIProvider {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public let id = OpenRouterConfiguration.providerID
    public let displayName = OpenRouterConfiguration.displayName
    public let configuration: OpenRouterConfiguration
    public var chatModelID: String { "openrouter:\(configuration.modelID)" }
    public let capabilities = AICapabilities(
        supportsChat: true,
        supportsEmbeddings: false,
        supportsJSONMode: true,
        supportsStreaming: false,
        maxContextTokens: 32_768,
        runsLocally: false
    )
    private let session: URLSession

    public init(configuration: OpenRouterConfiguration) {
        self.init(configuration: configuration, session: .shared)
    }

    init(configuration: OpenRouterConfiguration, session: URLSession) {
        self.configuration = configuration
        self.session = session
    }

    public func generate(_ request: AIGenerationRequest) async throws -> AIGenerationResponse {
        let text = try await complete(prompt: request.prompt)
        return AIGenerationResponse(text: text, modelID: chatModelID, localOnly: false)
    }

    public func embed(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResponse {
        throw AIProviderError.unavailable
    }

    public func classify(_ request: AIClassificationRequest) async throws -> AIClassificationResponse {
        let generation = try await generate(
            AIGenerationRequest(prompt: smartInboxClassificationPrompt(for: request.message))
        )
        guard let category = smartInboxCategory(from: generation.text) else {
            throw AIProviderError.unavailable
        }
        return AIClassificationResponse(category: category, confidence: 0.8, reason: "Classified by OpenRouter.")
    }

    public func classifyBatch(_ request: AIClassificationBatchRequest) async throws -> AIClassificationBatchResponse {
        let text = try await complete(
            prompt: SmartInboxClassificationPrompt.render(request),
            schemaName: "smart_inbox_batch",
            schema: SmartInboxClassificationPrompt.jsonSchema
        )
        let json = AIJSONExtraction.firstObject(in: text).map { String(decoding: $0, as: UTF8.self) } ?? text
        return try AIClassificationBatchJSON.parse(json)
    }

    public func translate(_ request: AITranslationRequest) async throws -> AITranslationResponse {
        let text = try await complete(prompt: translationPrompt(request), jsonObject: true)
        let json = AIJSONExtraction.firstObject(in: text).map { String(decoding: $0, as: UTF8.self) } ?? text
        return AITranslationResponse(
            segments: try decodeTranslationSegments(from: json),
            modelID: chatModelID,
            localOnly: false
        )
    }

    public func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        let prompt = """
        \(request.prompt)

        Respond with only a JSON object that matches this JSON Schema. No prose, no code fences.
        \(request.schema.jsonSchemaText)
        """
        let text = try await complete(prompt: prompt, schemaName: "response", schema: request.schema.jsonSchema)
        guard let json = AIJSONExtraction.firstObject(in: text) else {
            throw AIProviderError.unavailable
        }
        return AIStructuredGenerationResponse(json: json, modelID: chatModelID, localOnly: false)
    }

    /// Sends a one-word request so Settings can report a bad key, unknown model, or empty
    /// balance with OpenRouter's own message. The token cap stays generous because reasoning
    /// models count their thinking against it and would otherwise stop before saying "OK".
    public func checkConnection() async throws {
        _ = try await complete(prompt: "Reply with the single word OK.", maxTokens: 2_048, mapsErrors: false)
    }

    private func complete(
        prompt: String,
        schemaName: String? = nil,
        schema: [String: Any]? = nil,
        jsonObject: Bool = false,
        maxTokens: Int? = nil,
        mapsErrors: Bool = true
    ) async throws -> String {
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        if let schemaName, let schema {
            body["temperature"] = 0
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": false, "schema": schema],
            ]
        } else if jsonObject {
            body["temperature"] = 0
            body["response_format"] = ["type": "json_object"]
        }
        if let maxTokens { body["max_tokens"] = maxTokens }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("Plainpost", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // OpenRouter can report a failure inside a 200 response.
            if let error = payload?["error"] as? [String: Any] {
                let code = (error["code"] as? Int) ?? (status == 200 ? 502 : status)
                throw OpenRouterError.requestFailed(status: code, message: error["message"] as? String ?? "")
            }
            guard (200..<300).contains(status) else {
                throw OpenRouterError.requestFailed(status: status, message: "")
            }
            let choice = (payload?["choices"] as? [[String: Any]])?.first
            let content = Self.text(of: (choice?["message"] as? [String: Any])?["content"])
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw choice?["finish_reason"] as? String == "length"
                    ? OpenRouterError.truncatedBeforeAnswer
                    : OpenRouterError.emptyResponse
            }
            return content
        } catch {
            if !mapsErrors, error is OpenRouterError || error is URLError { throw error }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AIProviderError.unavailable
        }
    }

    /// Message content is normally a string, but some upstream providers return a list of
    /// typed parts; only the text parts make up the answer.
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}

public extension AIProviderStatusService {
    static func openRouter(configuration: OpenRouterConfiguration?) -> AIProviderStatusSnapshot {
        let isComplete = configuration?.isComplete == true
        return AIProviderStatusSnapshot(
            providerID: OpenRouterConfiguration.providerID,
            displayName: OpenRouterConfiguration.displayName,
            state: isComplete ? .ready : .unavailable,
            chatModelID: configuration.flatMap { $0.modelID.isEmpty ? nil : $0.modelID },
            embeddingModelID: nil,
            localOnly: false,
            detail: isComplete
                ? "Mail you use with AI is sent to OpenRouter."
                : "Add an OpenRouter API key and model to use OpenRouter."
        )
    }
}

public extension AIProvider {
    /// Whether this provider may receive mail content. Local providers always may; the only
    /// remote one is OpenRouter, which exists only once the user has configured it.
    var isPermittedMailProcessor: Bool {
        capabilities.runsLocally || id == OpenRouterConfiguration.providerID
    }
}
