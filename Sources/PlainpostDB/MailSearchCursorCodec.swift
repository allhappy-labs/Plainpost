import CryptoKit
import Foundation
import PlainpostCore

package struct MailSearchAuthenticatedCursor: Sendable {
    package let resolutionAnchor: Date
    fileprivate let payload: MailSearchCursorPayload
}

package struct MailSearchCursorCodec: Sendable {
    private static let version = 2
    private static let maximumEncodedLength = 4_096
    package static let maximumAge: TimeInterval = 24 * 60 * 60
    private static let payloadKeys: Set<String> = [
        "activityDate", "authTag", "conversationID", "exactTier", "expiresAtBits",
        "fingerprint", "lexicalBits", "limit", "mode", "resolutionAnchorBits", "revision",
        "scopeFingerprint", "sortDate", "stableID", "version",
    ]

    private let authenticationKey: SymmetricKey

    package init() {
        authenticationKey = SymmetricKey(size: .bits256)
    }

    package init(authenticationKey: Data) {
        self.authenticationKey = SymmetricKey(data: authenticationKey)
    }

    package func fingerprint(for input: String) -> String {
        Self.sha256(Data(input.utf8))
    }

    package func revisionDigest(_ entries: [String]) -> String {
        Self.sha256(Data(entries.joined(separator: "\n").utf8))
    }

    package func encode(
        boundary: SQLiteMailSearchCursorBoundary,
        resolutionAnchor: Date,
        fingerprint: String,
        mode: MailSearchMode,
        scope: MailSearchSelectionScope,
        limit: Int,
        revision: String
    ) throws -> MailSearchCursor {
        let anchor = resolutionAnchor.timeIntervalSince1970
        let expiresAt = anchor + Self.maximumAge
        guard Self.isDigest(fingerprint),
              Self.isDigest(revision),
              anchor.isFinite,
              expiresAt.isFinite,
              (1 ... MailSearchRequest.maximumLimit).contains(limit),
              Self.isValid(boundary, mode: mode)
        else {
            throw MailSearchError.invalidCursor
        }
        let unsigned = MailSearchUnsignedCursorPayload(
            version: Self.version,
            fingerprint: fingerprint,
            mode: mode,
            scopeFingerprint: scopeFingerprint(scope),
            limit: limit,
            revision: revision,
            resolutionAnchorBits: Self.hex(anchor.bitPattern),
            expiresAtBits: Self.hex(expiresAt.bitPattern),
            exactTier: boundary.exactTier,
            lexicalBits: Self.hex(boundary.lexicalScore.bitPattern),
            sortDate: boundary.sortDate,
            stableID: boundary.stableID,
            activityDate: boundary.activityDate,
            conversationID: boundary.conversationID
        )
        let unsignedData = try Self.makeEncoder().encode(unsigned)
        let tag = HMAC<SHA256>.authenticationCode(for: unsignedData, using: authenticationKey)
        let payload = MailSearchCursorPayload(unsigned: unsigned, authTag: Self.hex(Data(tag)))
        let data = try Self.makeEncoder().encode(payload)
        let rawValue = data.base64URLEncodedString()
        guard rawValue.count <= Self.maximumEncodedLength else {
            throw MailSearchError.invalidCursor
        }
        return MailSearchCursor(rawValue: rawValue)
    }

    package func authenticate(
        _ cursor: MailSearchCursor,
        now: Date
    ) throws -> MailSearchAuthenticatedCursor {
        guard !cursor.rawValue.isEmpty,
              cursor.rawValue.count <= Self.maximumEncodedLength,
              let data = Data(base64URLEncoded: cursor.rawValue),
              data.base64URLEncodedString() == cursor.rawValue,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.payloadKeys,
              let payload = try? Self.makeDecoder().decode(MailSearchCursorPayload.self, from: data),
              (try? Self.makeEncoder().encode(payload)) == data,
              payload.version == Self.version,
              Self.isDigest(payload.authTag),
              let receivedTag = Data(hexadecimal: payload.authTag)
        else {
            throw MailSearchError.invalidCursor
        }

        let unsigned = payload.unsigned
        guard let unsignedData = try? Self.makeEncoder().encode(unsigned),
              HMAC<SHA256>.isValidAuthenticationCode(
                  receivedTag,
                  authenticating: unsignedData,
                  using: authenticationKey
              )
        else {
            throw MailSearchError.invalidCursor
        }

        guard Self.isDigest(payload.fingerprint),
              Self.isDigest(payload.scopeFingerprint),
              Self.isDigest(payload.revision),
              (1 ... MailSearchRequest.maximumLimit).contains(payload.limit),
              let anchorBits = UInt64(payload.resolutionAnchorBits, radix: 16),
              payload.resolutionAnchorBits == Self.hex(anchorBits),
              let expiresAtBits = UInt64(payload.expiresAtBits, radix: 16),
              payload.expiresAtBits == Self.hex(expiresAtBits),
              let lexicalBits = UInt64(payload.lexicalBits, radix: 16),
              payload.lexicalBits == Self.hex(lexicalBits)
        else {
            throw MailSearchError.invalidCursor
        }
        let anchor = Double(bitPattern: anchorBits)
        let expiresAt = Double(bitPattern: expiresAtBits)
        let boundary = SQLiteMailSearchCursorBoundary(
            exactTier: payload.exactTier,
            lexicalScore: Double(bitPattern: lexicalBits),
            sortDate: payload.sortDate,
            stableID: payload.stableID,
            activityDate: payload.activityDate,
            conversationID: payload.conversationID
        )
        let currentTime = now.timeIntervalSince1970
        guard anchor.isFinite,
              expiresAt.isFinite,
              currentTime.isFinite,
              expiresAt == anchor + Self.maximumAge,
              currentTime <= expiresAt,
              Self.isValid(boundary, mode: payload.mode) else {
            throw MailSearchError.invalidCursor
        }
        return MailSearchAuthenticatedCursor(
            resolutionAnchor: Date(timeIntervalSince1970: anchor),
            payload: payload
        )
    }

    package func validate(
        _ cursor: MailSearchAuthenticatedCursor,
        fingerprint: String,
        mode: MailSearchMode,
        scope: MailSearchSelectionScope,
        limit: Int,
        revision: String
    ) throws -> SQLiteMailSearchCursorBoundary {
        let payload = cursor.payload
        guard payload.mode == mode,
              payload.scopeFingerprint == scopeFingerprint(scope),
              payload.limit == limit,
              payload.fingerprint == fingerprint
        else {
            throw MailSearchError.staleCursor
        }
        guard payload.revision == revision else {
            throw MailSearchError.staleCursor
        }
        guard let lexicalBits = UInt64(payload.lexicalBits, radix: 16) else {
            throw MailSearchError.invalidCursor
        }
        let boundary = SQLiteMailSearchCursorBoundary(
            exactTier: payload.exactTier,
            lexicalScore: Double(bitPattern: lexicalBits),
            sortDate: payload.sortDate,
            stableID: payload.stableID,
            activityDate: payload.activityDate,
            conversationID: payload.conversationID
        )
        guard Self.isValid(boundary, mode: mode) else {
            throw MailSearchError.invalidCursor
        }
        return boundary
    }

    private func scopeFingerprint(_ scope: MailSearchSelectionScope) -> String {
        let accounts = scope.accountIDs.map(\.rawValue)
        let mailboxes = scope.mailboxIDs.map(\.rawValue)
        let input = [
            "accounts:\(accounts.map { "\($0.utf8.count):\($0)" }.joined(separator: ","))",
            "mailboxes:\(mailboxes.map { "\($0.utf8.count):\($0)" }.joined(separator: ","))",
        ].joined(separator: "|")
        return fingerprint(for: input)
    }

    private static func isValid(
        _ boundary: SQLiteMailSearchCursorBoundary,
        mode: MailSearchMode
    ) -> Bool {
        let common = (0 ... 3).contains(boundary.exactTier)
            && boundary.lexicalScore.isFinite
            && (0 ... 1).contains(boundary.lexicalScore)
            && boundary.sortDate.isFinite
            && boundary.activityDate.isFinite
            && !boundary.stableID.isEmpty
            && boundary.stableID.utf8.count <= 1_024
            && !boundary.conversationID.isEmpty
            && boundary.conversationID.utf8.count <= 1_024
        guard common else { return false }
        switch mode {
        case .messages:
            return boundary.activityDate == boundary.sortDate
                && boundary.conversationID == boundary.stableID
        case .conversations:
            return true
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private struct MailSearchUnsignedCursorPayload: Codable, Sendable {
    let version: Int
    let fingerprint: String
    let mode: MailSearchMode
    let scopeFingerprint: String
    let limit: Int
    let revision: String
    let resolutionAnchorBits: String
    let expiresAtBits: String
    let exactTier: Int
    let lexicalBits: String
    let sortDate: Double
    let stableID: String
    let activityDate: Double
    let conversationID: String
}

private struct MailSearchCursorPayload: Codable, Sendable {
    let version: Int
    let fingerprint: String
    let mode: MailSearchMode
    let scopeFingerprint: String
    let limit: Int
    let revision: String
    let resolutionAnchorBits: String
    let expiresAtBits: String
    let exactTier: Int
    let lexicalBits: String
    let sortDate: Double
    let stableID: String
    let activityDate: Double
    let conversationID: String
    let authTag: String

    init(unsigned: MailSearchUnsignedCursorPayload, authTag: String) {
        version = unsigned.version
        fingerprint = unsigned.fingerprint
        mode = unsigned.mode
        scopeFingerprint = unsigned.scopeFingerprint
        limit = unsigned.limit
        revision = unsigned.revision
        resolutionAnchorBits = unsigned.resolutionAnchorBits
        expiresAtBits = unsigned.expiresAtBits
        exactTier = unsigned.exactTier
        lexicalBits = unsigned.lexicalBits
        sortDate = unsigned.sortDate
        stableID = unsigned.stableID
        activityDate = unsigned.activityDate
        conversationID = unsigned.conversationID
        self.authTag = authTag
    }

    var unsigned: MailSearchUnsignedCursorPayload {
        MailSearchUnsignedCursorPayload(
            version: version,
            fingerprint: fingerprint,
            mode: mode,
            scopeFingerprint: scopeFingerprint,
            limit: limit,
            revision: revision,
            resolutionAnchorBits: resolutionAnchorBits,
            expiresAtBits: expiresAtBits,
            exactTier: exactTier,
            lexicalBits: lexicalBits,
            sortDate: sortDate,
            stableID: stableID,
            activityDate: activityDate,
            conversationID: conversationID
        )
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    init?(hexadecimal value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
