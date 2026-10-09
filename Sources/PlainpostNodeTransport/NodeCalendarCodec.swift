import Foundation

public enum NodeCalendarCodec {
    public static let commandBodyLimit = 256 * 1024
    public static let connectionBodyLimit = 64 * 1024
    public static let windowResponseLimit = 8 * 1024 * 1024

    public static func decodeReceipt(_ data: Data) throws -> NodeCalendarReceipt { try decodeDefinition(data, definition: "receipt") }
    public static func encodeOperationRead(_ operationIDs: [String]) throws -> Data {
        try validateIDs(operationIDs)
        return try encodeFamily(NodeCalendarOperationReadRequest(operationIDs: operationIDs), kind: "operation-read-request")
    }
    /// Throws `unknownOperation` when the Node reports any requested operation as
    /// never admitted for this account; other failures keep their own errors.
    public static func decodeOperationReadResponse(_ response: NodeHTTPResponse, requested: [String]) throws -> [NodeCalendarReceipt] {
        try validateStatus(response)
        let result: NodeCalendarOperationReadResult = try decodeFamily(response.body, kind: "operation-read-result")
        let requestedIDs = Set(requested)
        guard Set(result.unknownOperationIDs).count == result.unknownOperationIDs.count,
              result.unknownOperationIDs.allSatisfy(requestedIDs.contains),
              result.receipts.count + result.unknownOperationIDs.count <= requested.count else { throw NodeCalendarError.invalidResponse }
        if !result.unknownOperationIDs.isEmpty { throw NodeCalendarError.unknownOperation }
        return result.receipts
    }
    static func validateIDs(_ ids: [String]) throws {
        guard ids.count <= 200, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) else { throw NodeCalendarError.invalidResponse }
    }
    static func validateStatus(_ response: NodeHTTPResponse, capability: Bool = false) throws {
        switch response.statusCode {
        case 200...299: return
        case 404 where capability, 501 where capability: throw NodeCalendarError.unsupported
        case 401, 403: throw NodeCalendarError.unauthorized
        case 409:
            // A bounded problem code refines a conflict; anything else stays a conflict.
            struct Problem: Decodable { let code: String? }
            switch (try? JSONDecoder().decode(Problem.self, from: response.body))?.code {
            case "target_calendar_required": throw NodeCalendarError.targetCalendarRequired
            case "snapshot_changed": throw NodeCalendarError.snapshotChanged
            case "calendar_index_pending": throw NodeCalendarError.calendarIndexPending
            default: break
            }
            throw NodeCalendarError.conflict
        case 500...599: throw NodeCalendarError.unavailable
        default: throw NodeCalendarError.invalidResponse
        }
    }
    static func encode<T: Encodable>(_ value: T, limit: Int = windowResponseLimit) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let canonical = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029").utf8)
        guard canonical.count <= limit else { throw NodeCalendarError.invalidResponse }
        return canonical
    }
    static func decode<T: Codable>(_ data: Data) throws -> T {
        do {
            guard data.count <= windowResponseLimit, String(data: data, encoding: .utf8) != nil else { throw NodeCalendarError.invalidResponse }
            let input = try JSONSerialization.jsonObject(with: data)
            var scanner = CalendarJSONScanner(bytes: Array(data))
            try scanner.value(depth: 0)
            let result = try JSONDecoder().decode(T.self, from: data)
            let output = try JSONSerialization.jsonObject(with: encode(result))
            guard let a = input as? NSObject, let b = output as? NSObject, a == b else { throw NodeCalendarError.invalidResponse }
            try validateJSON(input)
            return result
        } catch { throw NodeCalendarError.invalidResponse }
    }
    /// Emits canonical bytes only for a family valid against the closed schema.
    static func encodeFamily<T: Encodable>(_ value: T, kind: String, limit: Int = commandBodyLimit) throws -> Data {
        guard let definition = NodeCalendarSchema.shared.families[kind] else { throw NodeCalendarError.invalidResponse }
        let data = try encode(CalendarFamily(value: value, kind: "node-calendar.\(kind).v1"), limit: limit)
        try NodeCalendarSchema.shared.validate(NodeCalendarJSONParser.parse(data), definition: definition)
        return data
    }
    /// Validates a kind-tagged family against the closed schema, then decodes the
    /// typed value and requires an exact canonical round trip.
    static func decodeFamily<T: Codable>(_ data: Data, kind: String) throws -> T {
        guard let definition = NodeCalendarSchema.shared.families[kind] else { throw NodeCalendarError.invalidResponse }
        return try decodeValidated(data, definition: definition) { value in try encode(CalendarFamily(value: value, kind: "node-calendar.\(kind).v1")) }
    }
    static func decodeDefinition<T: Codable>(_ data: Data, definition: String) throws -> T {
        try decodeValidated(data, definition: definition) { value in try encode(value) }
    }
    static func encodeDefinition<T: Encodable>(_ value: T, definition: String, limit: Int = windowResponseLimit) throws -> Data {
        let data = try encode(value, limit: limit)
        try NodeCalendarSchema.shared.validate(NodeCalendarJSONParser.parse(data), definition: definition)
        return data
    }
    private static func decodeValidated<T: Codable>(_ data: Data, definition: String, reencode: (T) throws -> Data) throws -> T {
        do {
            let input = try NodeCalendarJSONParser.parse(data)
            try NodeCalendarSchema.shared.validate(input, definition: definition)
            let result = try JSONDecoder().decode(T.self, from: data)
            guard try NodeCalendarJSONParser.parse(reencode(result)) == input else { throw NodeCalendarError.invalidResponse }
            return result
        } catch { throw NodeCalendarError.invalidResponse }
    }
    private static func validateJSON(_ value: Any) throws {
        if value is NSNull { return }
        if let string = value as? String {
            guard !string.contains("\0"), string.utf8.count <= 1_048_576 else { throw NodeCalendarError.invalidResponse }
        } else if let number = value as? NSNumber {
            guard abs(number.doubleValue) <= 9_007_199_254_740_991 else { throw NodeCalendarError.invalidResponse }
        } else if let object = value as? [String: Any] {
            for (_, child) in object { try validateJSON(child) }
        } else if let array = value as? [Any] {
            guard array.count <= 10_000 else { throw NodeCalendarError.invalidResponse }
            for child in array { try validateJSON(child) }
        } else { throw NodeCalendarError.invalidResponse }
    }
}

// Foundation accepts duplicate keys. This bounded syntax walk checks decoded
// key identity before Foundation performs DTO decoding, including escaped keys.
private struct CalendarJSONScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func string() throws -> String {
        let start = index; index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            index += 1
        }
        throw NodeCalendarError.invalidResponse
    }
    mutating func value(depth: Int) throws {
        whitespace()
        guard depth < 64, index < bytes.count else { throw NodeCalendarError.invalidResponse }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var keys: Set<String> = []
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while index < bytes.count {
                whitespace(); guard index < bytes.count && bytes[index] == 34 else { throw NodeCalendarError.invalidResponse }
                guard keys.insert(try string()).inserted else { throw NodeCalendarError.invalidResponse }
                whitespace(); guard index < bytes.count && bytes[index] == 58 else { throw NodeCalendarError.invalidResponse }; index += 1
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw NodeCalendarError.invalidResponse }
                if bytes[index] == 125 { index += 1; return }
                guard bytes[index] == 44 else { throw NodeCalendarError.invalidResponse }; index += 1
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while index < bytes.count {
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw NodeCalendarError.invalidResponse }
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw NodeCalendarError.invalidResponse }; index += 1
            }
        case 34: _ = try string(); return
        default:
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            return
        }
        throw NodeCalendarError.invalidResponse
    }
}

private struct CalendarFamily<Value: Encodable>: Encodable {
    let value: Value
    let kind: String
    private enum CodingKeys: String, CodingKey { case kind }
    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
    }
}
