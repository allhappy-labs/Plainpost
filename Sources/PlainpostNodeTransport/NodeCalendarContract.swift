import Foundation

/// A strictly parsed node-calendar-v1 JSON value. Strings and object keys
/// compare by their exact UTF-8 bytes (never by Unicode canonical equivalence),
/// and numbers keep their lexeme, so decisions match the Go Node codec.
indirect enum NodeCalendarJSON: Equatable {
    case object([NodeCalendarJSONKey: NodeCalendarJSON])
    case array([NodeCalendarJSON])
    case string(NodeCalendarJSONKey)
    case number(String)
    case bool(Bool)
    case null
}

struct NodeCalendarJSONKey: Hashable {
    let bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.utf8) }
    init(bytes: [UInt8]) { self.bytes = bytes }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// Strict RFC 8259 parser: UTF-8 without BOM, duplicate keys rejected after
/// unescaping, paired surrogate escapes, no NUL in any string, bounded depth
/// and document size, exact number lexemes.
struct NodeCalendarJSONParser {
    static let maximumDepth = 64
    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> NodeCalendarJSON {
        guard !data.isEmpty, data.count <= NodeCalendarCodec.windowResponseLimit, String(data: data, encoding: .utf8) != nil else { throw NodeCalendarError.invalidResponse }
        var parser = NodeCalendarJSONParser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw NodeCalendarError.invalidResponse }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func literal(_ text: String) -> Bool {
        let expected = Array(text.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { return false }
        index += expected.count
        return true
    }

    private mutating func value(depth: Int) throws -> NodeCalendarJSON {
        whitespace()
        guard depth <= Self.maximumDepth, index < bytes.count else { throw NodeCalendarError.invalidResponse }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var object: [NodeCalendarJSONKey: NodeCalendarJSON] = [:]
            whitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                whitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw NodeCalendarError.invalidResponse }
                let key = try string()
                guard object[key] == nil else { throw NodeCalendarError.invalidResponse }
                whitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw NodeCalendarError.invalidResponse }
                index += 1
                object[key] = try value(depth: depth + 1)
                whitespace()
                guard index < bytes.count else { throw NodeCalendarError.invalidResponse }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                guard bytes[index] == UInt8(ascii: ",") else { throw NodeCalendarError.invalidResponse }
                index += 1
            }
        case UInt8(ascii: "["):
            index += 1
            var array: [NodeCalendarJSON] = []
            whitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            while true {
                array.append(try value(depth: depth + 1))
                whitespace()
                guard index < bytes.count else { throw NodeCalendarError.invalidResponse }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
                guard bytes[index] == UInt8(ascii: ",") else { throw NodeCalendarError.invalidResponse }
                index += 1
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t") where literal("true"):
            return .bool(true)
        case UInt8(ascii: "f") where literal("false"):
            return .bool(false)
        case UInt8(ascii: "n") where literal("null"):
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        default:
            throw NodeCalendarError.invalidResponse
        }
    }

    private mutating func digits() -> Int {
        var count = 0
        while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1; count += 1 }
        return count
    }

    private mutating func number() throws -> NodeCalendarJSON {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        if index < bytes.count, bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            throw NodeCalendarError.invalidResponse
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw NodeCalendarError.invalidResponse }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw NodeCalendarError.invalidResponse }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { return nil }
        index += 4
        return value
    }

    private mutating func string() throws -> NodeCalendarJSONKey {
        index += 1
        var out: [UInt8] = []
        func append(_ scalar: Unicode.Scalar) { out.append(contentsOf: Array(String(scalar).utf8)) }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard !out.contains(0) else { throw NodeCalendarError.invalidResponse }
                return NodeCalendarJSONKey(bytes: out)
            case 0..<0x20:
                throw NodeCalendarError.invalidResponse
            case UInt8(ascii: "\\"):
                guard index + 1 < bytes.count else { throw NodeCalendarError.invalidResponse }
                let escape = bytes[index + 1]
                index += 2
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "u"):
                    guard let unit = hex4() else { throw NodeCalendarError.invalidResponse }
                    if unit >= 0xD800 && unit < 0xDC00 {
                        guard literal("\\u"), let low = hex4(), low >= 0xDC00, low <= 0xDFFF,
                              let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else { throw NodeCalendarError.invalidResponse }
                        append(scalar)
                    } else if unit >= 0xDC00 && unit <= 0xDFFF {
                        throw NodeCalendarError.invalidResponse
                    } else {
                        guard let scalar = Unicode.Scalar(unit) else { throw NodeCalendarError.invalidResponse }
                        append(scalar)
                    }
                default:
                    throw NodeCalendarError.invalidResponse
                }
            default:
                out.append(byte)
                index += 1
            }
        }
        throw NodeCalendarError.invalidResponse
    }
}

/// The JSON Schema 2020-12 subset used by node-calendar-v1, interpreted from
/// the embedded authoritative schema exactly as the Go Node interprets it.
struct NodeCalendarSchema {
    static let shared: NodeCalendarSchema = {
        guard case .object(let root) = try! NodeCalendarJSONParser.parse(Data(NodeCalendarSchemaSource.json.utf8)),
              case .object(let definitions) = root[NodeCalendarJSONKey("$defs")] else { fatalError("node-calendar-v1 schema is malformed") }
        var families: [String: String] = [:]
        var defs: [String: NodeCalendarJSON] = [:]
        for (name, definition) in definitions {
            defs[name.text] = definition
            if case .object(let object) = definition, case .object(let properties)? = object[NodeCalendarJSONKey("properties")],
               case .object(let kind)? = properties[NodeCalendarJSONKey("kind")], case .string(let constant)? = kind[NodeCalendarJSONKey("const")] {
                let text = constant.text
                if text.hasPrefix("node-calendar."), text.hasSuffix(".v1") {
                    families[String(text.dropFirst("node-calendar.".count).dropLast(".v1".count))] = name.text
                }
            }
        }
        return NodeCalendarSchema(definitions: defs, families: families)
    }()

    let definitions: [String: NodeCalendarJSON]
    let families: [String: String]

    func validate(_ value: NodeCalendarJSON, definition: String) throws {
        guard let node = definitions[definition], valid(value, node) else { throw NodeCalendarError.invalidResponse }
    }

    private func member(_ node: [NodeCalendarJSONKey: NodeCalendarJSON], _ name: String) -> NodeCalendarJSON? { node[NodeCalendarJSONKey(name)] }

    private func integer(_ value: NodeCalendarJSON?) -> UInt64? {
        guard case .number(let lexeme)? = value else { return nil }
        return UInt64(lexeme)
    }

    private func valid(_ value: NodeCalendarJSON, _ schema: NodeCalendarJSON) -> Bool {
        guard case .object(var node) = schema else { return false }
        while case .string(let reference)? = member(node, "$ref") {
            let name = String(reference.text.dropFirst("#/$defs/".count))
            guard case .object(let next)? = definitions[name] else { return false }
            if name == "calendarTime", !Self.validCalendarTimeZone(value) { return false }
            if name == "floatingTime", !Self.validFloatingTime(value) { return false }
            node = next
        }
        if let declared = member(node, "type") {
            let names: [String]
            switch declared {
            case .string(let name): names = [name.text]
            case .array(let items): names = items.compactMap { if case .string(let name) = $0 { return name.text } else { return nil } }
            default: return false
            }
            guard names.contains(where: { Self.hasType(value, $0) }) else { return false }
        }
        if let constant = member(node, "const"), !Self.equal(value, constant) { return false }
        if case .array(let options)? = member(node, "enum"), !options.contains(where: { Self.equal(value, $0) }) { return false }
        switch value {
        case .string(let key):
            let text = key.text
            let length = text.unicodeScalars.count
            if let minimum = integer(member(node, "minLength")), length < minimum { return false }
            if let maximum = integer(member(node, "maxLength")), length > maximum { return false }
            if case .string(let pattern)? = member(node, "pattern"), !Self.matches(pattern.text, text) { return false }
            if case .string(let format)? = member(node, "format"), format.text == "date-time", !Self.validDateTime(text) { return false }
        case .number(let lexeme):
            guard let number = Self.canonicalInteger(lexeme) else { return false }
            if let minimum = integer(member(node, "minimum")), number < minimum { return false }
            if let maximum = integer(member(node, "maximum")), number > maximum { return false }
        case .array(let items):
            if let maximum = integer(member(node, "maxItems")), items.count > maximum { return false }
            if case .bool(true)? = member(node, "uniqueItems") {
                for (offset, item) in items.enumerated() where items[..<offset].contains(item) { return false }
            }
            if let schema = member(node, "items"), !items.allSatisfy({ valid($0, schema) }) { return false }
        case .object(let object):
            if case .array(let required)? = member(node, "required") {
                for case .string(let name) in required where object[name] == nil { return false }
            }
            var properties: [NodeCalendarJSONKey: NodeCalendarJSON] = [:]
            if case .object(let declared)? = member(node, "properties") { properties = declared }
            for (key, child) in object {
                if let names = member(node, "propertyNames"), !valid(.string(key), names) { return false }
                if let property = properties[key] {
                    if !valid(child, property) { return false }
                    continue
                }
                switch member(node, "additionalProperties") {
                case .bool(false)?: return false
                case .some(let additional) where additional != .bool(true):
                    if !valid(child, additional) { return false }
                default: break
                }
            }
        case .bool, .null:
            break
        }
        if case .array(let variants)? = member(node, "oneOf"), variants.filter({ valid(value, $0) }).count != 1 { return false }
        if case .array(let variants)? = member(node, "anyOf"), !variants.contains(where: { valid(value, $0) }) { return false }
        if let negated = member(node, "not"), valid(value, negated) { return false }
        return true
    }

    private static func hasType(_ value: NodeCalendarJSON, _ name: String) -> Bool {
        switch (value, name) {
        case (.string, "string"), (.number, "integer"), (.bool, "boolean"), (.null, "null"), (.object, "object"), (.array, "array"): return true
        default: return false
        }
    }

    private static func equal(_ value: NodeCalendarJSON, _ constant: NodeCalendarJSON) -> Bool {
        if case .bool(let expected) = constant { return value == .bool(expected) }
        guard case .string(let text) = value, case .string(let expected) = constant else { return false }
        return text == expected
    }

    private static func canonicalInteger(_ lexeme: String) -> UInt64? {
        let digits = Array(lexeme.utf8)
        guard !digits.isEmpty, digits.count <= 16, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              lexeme == "0" || digits[0] != UInt8(ascii: "0") else { return nil }
        return UInt64(lexeme)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        switch pattern {
        case "^[^\\u0000]*$":
            return !text.utf8.contains(0)
        case "^[A-Za-z0-9_+/-]+$":
            return !text.isEmpty && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || [UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "-")].contains(byte)
            }
        default:
            // An unsupported schema pattern fails closed.
            return false
        }
    }

    /// Strict RFC 3339 profile: YYYY-MM-DDTHH:MM:SS then Z or a nonzero offset.
    static func validDateTime(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 20 || bytes.count == 25 else { return false }
        func digits(_ from: Int, _ to: Int) -> Int? {
            var number = 0
            for offset in from..<to {
                guard bytes[offset] >= UInt8(ascii: "0"), bytes[offset] <= UInt8(ascii: "9") else { return nil }
                number = number * 10 + Int(bytes[offset] - UInt8(ascii: "0"))
            }
            return number
        }
        guard let year = digits(0, 4), let month = digits(5, 7), let day = digits(8, 10), let hour = digits(11, 13), let minute = digits(14, 16), let second = digits(17, 19),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              (1...12).contains(month), hour <= 23, minute <= 59, second <= 59 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...days).contains(day) else { return false }
        if bytes.count == 20 { return bytes[19] == UInt8(ascii: "Z") }
        guard let offsetHour = digits(20, 22), let offsetMinute = digits(23, 25) else { return false }
        return (bytes[19] == UInt8(ascii: "+") || bytes[19] == UInt8(ascii: "-")) && bytes[22] == UInt8(ascii: ":") && offsetHour <= 23 && offsetMinute <= 59 && offsetHour + offsetMinute > 0
    }

    /// A floating time's value is a strict offset-free YYYY-MM-DDTHH:MM:SS wall time.
    static func validFloatingTime(_ value: NodeCalendarJSON) -> Bool {
        guard case .object(let object) = value, case .string(let key)? = object[NodeCalendarJSONKey("value")] else { return true }
        return key.text.utf8.count == 19 && validDateTime(key.text + "Z")
    }

    /// Calendar times name an IANA zone both codecs resolve; never Local or a
    /// GMT/UTC offset alias.
    static func validCalendarTimeZone(_ value: NodeCalendarJSON) -> Bool {
        guard case .object(let object) = value, case .string(let key)? = object[NodeCalendarJSONKey("timezone")] else { return true }
        let zone = key.text
        guard !zone.isEmpty, zone != "Local", !["GMT+", "GMT-", "UTC+", "UTC-"].contains(where: zone.hasPrefix) else { return false }
        // Exact IANA case on every host: a platform that resolves a miscased name
        // to its canonical identifier must not make that name valid.
        guard let resolved = TimeZone(identifier: zone)?.identifier else { return false }
        return resolved == zone || resolved.caseInsensitiveCompare(zone) != .orderedSame
    }
}
