import Foundation

public enum NodeSessionLimits {
    public static let maximumRequestBodyBytes = 1_048_576
}

public enum NodeSessionError: Error, Equatable, Sendable {
    case invalidValue
    case authenticationRejected
    case transportFailure
    case transportFailureAfterDispatch
    case transportCancellationAfterDispatch
    case applicationResultUncertain
}

public struct EndpointEnvelopeV1: Equatable, Sendable {
    public let ciphertext: Data
    public init(ciphertext: Data) throws {
        guard !ciphertext.isEmpty else { throw NodeSessionError.invalidValue }
        self.ciphertext = ciphertext
    }
}

public struct ActivationRequestV1: Equatable, Sendable {
    public let resultWire, refreshWire, leaseWire, trustCommitWire, claimProofSignature: Data
    public init(resultWire: Data, refreshWire: Data, leaseWire: Data, trustCommitWire: Data, claimProofSignature: Data) throws {
        guard !resultWire.isEmpty, !refreshWire.isEmpty, !leaseWire.isEmpty, !trustCommitWire.isEmpty, claimProofSignature.count == 64 else { throw NodeSessionError.invalidValue }
        self.resultWire = resultWire; self.refreshWire = refreshWire; self.leaseWire = leaseWire; self.trustCommitWire = trustCommitWire; self.claimProofSignature = claimProofSignature
    }
}

// V1 remains a frozen historical decoder shape. New Node activation is v2 so
// its transcript carries the evidence used to recompute operation digests.
public struct ActivationRequestV2: Equatable, Sendable {
    public let resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, claimProofSignature: Data
    public init(resultWire: Data, refreshWire: Data, leaseWire: Data, trustCommitWire: Data, admissionEvidenceWire: Data, claimProofSignature: Data) throws {
        let fields = [resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, claimProofSignature]
        guard fields.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }), fields.reduce(0, { $0 + $1.count }) <= 128 * 1024, claimProofSignature.count == 64 else { throw NodeSessionError.invalidValue }
        self.resultWire = resultWire; self.refreshWire = refreshWire; self.leaseWire = leaseWire; self.trustCommitWire = trustCommitWire; self.admissionEvidenceWire = admissionEvidenceWire; self.claimProofSignature = claimProofSignature
    }
}

/// V3 is the only activation form permitted to establish a new production
/// installation. Its cleanup capability is Central-issued and digest-bound by
/// the three signed session documents.
public struct ActivationRequestV3: Equatable, Sendable {
    public let resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire, claimProofSignature: Data
    public init(resultWire: Data, refreshWire: Data, leaseWire: Data, trustCommitWire: Data, admissionEvidenceWire: Data, cleanupCapabilityWire: Data, claimProofSignature: Data) throws {
        let fields = [resultWire, refreshWire, leaseWire, trustCommitWire, admissionEvidenceWire, cleanupCapabilityWire, claimProofSignature]
        guard fields.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }), fields.reduce(0, { $0 + $1.count }) <= 128 * 1024, claimProofSignature.count == 64 else { throw NodeSessionError.invalidValue }
        self.resultWire = resultWire; self.refreshWire = refreshWire; self.leaseWire = leaseWire; self.trustCommitWire = trustCommitWire
        self.admissionEvidenceWire = admissionEvidenceWire; self.cleanupCapabilityWire = cleanupCapabilityWire; self.claimProofSignature = claimProofSignature
    }
}

public struct SignedRequestV1: Equatable, Sendable {
    public let accountID, clientID, nodeID: String
    public let trustEpoch, sequence: UInt64
    public let audience, method, path: String
    public let bodySHA256: Data
    public let issuedAt: String
    public let signature: Data
    public init(accountID: String, clientID: String, nodeID: String, trustEpoch: UInt64, audience: String, sequence: UInt64, method: String, path: String, bodySHA256: Data, issuedAt: String, signature: Data) throws {
        guard NodeSessionWire.canonicalUUID(accountID), NodeSessionWire.canonicalUUID(clientID), NodeSessionWire.canonicalUUID(nodeID), clientID != nodeID, trustEpoch > 0, sequence > 0, NodeSessionWire.validAudience(audience), NodeSessionWire.validMethod(method), NodeSessionWire.validPath(path), bodySHA256.count == 32, NodeSessionWire.parseWholeSecondTimestamp(issuedAt) != nil, signature.count == 64 else { throw NodeSessionError.invalidValue }
        self.accountID = accountID; self.clientID = clientID; self.nodeID = nodeID; self.trustEpoch = trustEpoch; self.audience = audience; self.sequence = sequence; self.method = method; self.path = path; self.bodySHA256 = bodySHA256; self.issuedAt = issuedAt; self.signature = signature
    }
}

public enum NodeSessionTranscript {
    public static func endpoint(_ value: EndpointEnvelopeV1) throws -> Data { parts([Data("Plainpost.NodeEndpoint.v1".utf8), u16(1), value.ciphertext]) }
    public static func activation(_ value: ActivationRequestV1) throws -> Data { parts([Data("Plainpost.NodeActivation.v1".utf8), u16(1), value.resultWire, value.refreshWire, value.leaseWire, value.trustCommitWire, value.claimProofSignature]) }
    public static func activationV2(_ value: ActivationRequestV2) throws -> Data { parts([Data("Plainpost.NodeActivation.v2".utf8), u16(2), value.resultWire, value.refreshWire, value.leaseWire, value.trustCommitWire, value.admissionEvidenceWire, value.claimProofSignature]) }
    public static func activationV3(_ value: ActivationRequestV3) throws -> Data { parts([Data("Plainpost.NodeActivation.v3".utf8), u16(3), value.resultWire, value.refreshWire, value.leaseWire, value.trustCommitWire, value.admissionEvidenceWire, value.cleanupCapabilityWire, value.claimProofSignature]) }
    public static func request(_ value: SignedRequestV1) throws -> Data { parts([Data("Plainpost.NodeRequest.v1".utf8), u16(1), try NodeSessionWire.uuid(value.accountID), try NodeSessionWire.uuid(value.clientID), try NodeSessionWire.uuid(value.nodeID), u64(value.trustEpoch), Data(value.audience.utf8), u64(value.sequence), Data(value.method.utf8), Data(value.path.utf8), value.bodySHA256, Data(value.issuedAt.utf8)]) }
    private static func parts(_ values: [Data]) -> Data { values.reduce(into: Data()) { result, value in result += part(value) } }
    private static func part(_ value: Data) -> Data { var count = UInt32(value.count).bigEndian; return Data(bytes: &count, count: 4) + value }
    private static func u16(_ value: UInt16) -> Data { var item = value.bigEndian; return Data(bytes: &item, count: 2) }
    private static func u64(_ value: UInt64) -> Data { var item = value.bigEndian; return Data(bytes: &item, count: 8) }
}

public enum NodeSessionWire {
    public static func decodeBase64URL(_ value: String) throws -> Data {
        guard !value.isEmpty, !value.contains("="), value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else { throw NodeSessionError.invalidValue }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), encodeBase64URL(decoded) == value else { throw NodeSessionError.invalidValue }
        return decoded
    }
    public static func encodeBase64URL(_ value: Data) -> String { value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func canonicalUUID(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value, let uuid = UUID(uuidString: value) else { return false }
        var raw = uuid.uuid; let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        return bytes.contains(where: { $0 != 0 }) && (1...5).contains(Int(bytes[6] >> 4)) && bytes[8] & 0xc0 == 0x80
    }
    static func uuid(_ value: String) throws -> Data { guard let uuid = UUID(uuidString: value) else { throw NodeSessionError.invalidValue }; var raw = uuid.uuid; return withUnsafeBytes(of: &raw) { Data($0) } }
    static func validAudience(_ value: String) -> Bool {
        let bytes = Array(value.utf8); guard !bytes.isEmpty, bytes.count <= 255, bytes.filter({ $0 == 58 }).count <= 1 else { return false }
        let colon = bytes.lastIndex(of: 58), host = Array(bytes[..<(colon ?? bytes.endIndex)]), port = colon.map { Array(bytes[bytes.index(after: $0)...]) }
        guard let first = host.first, let last = host.last, asciiAlphaNumeric(first), asciiAlphaNumeric(last), host.allSatisfy({ asciiAlphaNumeric($0) || $0 == 46 || $0 == 45 }) else { return false }
        guard let port else { return true }
        return !port.isEmpty && port.count <= 5 && (49...57).contains(port[0]) && port.allSatisfy({ (48...57).contains($0) })
    }
    public static func validMethod(_ value: String) -> Bool { let bytes = Array(value.utf8); return !bytes.isEmpty && bytes.count <= 16 && bytes.allSatisfy({ (65...90).contains($0) }) }
    public static func validPath(_ value: String) -> Bool { let bytes = Array(value.utf8); guard !bytes.isEmpty && bytes.count <= 2_048 && bytes[0] == 47 && bytes.filter({ $0 == 63 }).count <= 1 else { return false }; let parts = bytes.split(separator: 63, maxSplits: 1, omittingEmptySubsequences: false); guard parts[0].allSatisfy(pathByte) else { return false }; guard parts.count == 2 else { return true }; return !parts[1].isEmpty && parts[1].split(separator: 38, omittingEmptySubsequences: false).allSatisfy { pair in let fields = pair.split(separator: 61, maxSplits: 1, omittingEmptySubsequences: false); return fields.count == 2 && validQueryKey(Array(fields[0])) && validQueryValue(Array(fields[1])) } }
    public static func validateRequestBody(_ value: Data) throws { guard value.count <= NodeSessionLimits.maximumRequestBodyBytes else { throw NodeSessionError.invalidValue } }
    public static func parseWholeSecondTimestamp(_ value: String) -> Date? {
        guard value.utf8.count == 20, value.utf8.enumerated().allSatisfy({ index, byte in [4, 7].contains(index) ? byte == 45 : index == 10 ? byte == 84 : [13, 16].contains(index) ? byte == 58 : index == 19 ? byte == 90 : byte >= 48 && byte <= 57 }) else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else { return nil }
        return parsed
    }
    private static func asciiAlphaNumeric(_ value: UInt8) -> Bool { (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) }
    private static func pathByte(_ value: UInt8) -> Bool { asciiAlphaNumeric(value) || Data("._~!$&'()*+,;=:@/-".utf8).contains(value) }
    private static func validQueryKey(_ value: [UInt8]) -> Bool { !value.isEmpty && value.count <= 64 && ((65...90).contains(value[0]) || (97...122).contains(value[0])) && value.allSatisfy({ asciiAlphaNumeric($0) || $0 == 95 || $0 == 45 }) }
    private static func validQueryValue(_ value: [UInt8]) -> Bool { !value.isEmpty && value.count <= 256 && value.allSatisfy({ asciiAlphaNumeric($0) || $0 == 95 || $0 == 45 }) }
}
