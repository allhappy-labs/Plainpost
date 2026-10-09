import Foundation

public struct AIStructuredProperty: Equatable, Sendable {
    public let name: String
    public let schema: AIStructuredSchema
    public let isOptional: Bool
    public init(name: String, schema: AIStructuredSchema, isOptional: Bool) {
        self.name = name
        self.schema = schema
        self.isOptional = isOptional
    }
}

public indirect enum AIStructuredSchema: Equatable, Sendable {
    case object(name: String, description: String?, properties: [AIStructuredProperty])
    case string(description: String?, choices: [String]?)
    case integer(description: String?)
    case boolean(description: String?)
    case array(AIStructuredSchema, description: String?, maxCount: Int?)

    /// JSON Schema dictionary, used by Ollama's `format` and by the default prompt.
    public var jsonSchema: [String: Any] {
        switch self {
        case let .object(_, description, properties):
            var props: [String: Any] = [:]
            for property in properties { props[property.name] = property.schema.jsonSchema }
            var result: [String: Any] = ["type": "object", "properties": props,
                                         "required": properties.filter { !$0.isOptional }.map(\.name)]
            if let description { result["description"] = description }
            return result
        case let .string(description, choices):
            var result: [String: Any] = ["type": "string"]
            if let choices { result["enum"] = choices }
            if let description { result["description"] = description }
            return result
        case let .integer(description):
            return ["type": "integer"].merging(description.map { ["description": $0] } ?? [:]) { a, _ in a }
        case let .boolean(description):
            return ["type": "boolean"].merging(description.map { ["description": $0] } ?? [:]) { a, _ in a }
        case let .array(element, description, maxCount):
            var result: [String: Any] = ["type": "array", "items": element.jsonSchema]
            if let maxCount { result["maxItems"] = maxCount }
            if let description { result["description"] = description }
            return result
        }
    }

    var jsonSchemaText: String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonSchema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct AIStructuredGenerationRequest: Sendable {
    public let prompt: String
    public let schema: AIStructuredSchema
    public init(prompt: String, schema: AIStructuredSchema) {
        self.prompt = prompt
        self.schema = schema
    }
}

public struct AIStructuredGenerationResponse: Sendable {
    public let json: Data
    public let modelID: String
    public let localOnly: Bool
    public init(json: Data, modelID: String, localOnly: Bool) {
        self.json = json
        self.modelID = modelID
        self.localOnly = localOnly
    }
}

public extension AIProvider {
    /// Fallback for providers without native structured output: ask for JSON, then extract it.
    func generateStructured(_ request: AIStructuredGenerationRequest) async throws -> AIStructuredGenerationResponse {
        let prompt = """
        \(request.prompt)

        Respond with only a JSON object that matches this JSON Schema. No prose, no code fences.
        \(request.schema.jsonSchemaText)
        """
        let response = try await generate(AIGenerationRequest(prompt: prompt))
        guard let json = AIJSONExtraction.firstObject(in: response.text) else {
            throw AIProviderError.unavailable
        }
        return AIStructuredGenerationResponse(json: json, modelID: response.modelID, localOnly: response.localOnly)
    }
}

enum AIJSONExtraction {
    /// First balanced `{…}` in `text` that parses as JSON, respecting string literals.
    static func firstObject(in text: String) -> Data? {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index] == "{", let end = matchingBrace(characters, from: index) {
                let data = Data(String(characters[index...end]).utf8)
                if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
            }
            index += 1
        }
        return nil
    }

    private static func matchingBrace(_ c: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<c.count {
            let ch = c[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true } else if ch == "{" { depth += 1 } else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }
}
