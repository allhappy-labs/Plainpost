import Foundation

public enum AccountWireCodec {
    public static let maxBodyBytes = 64 * 1024
    public static let maxEncryptedRecordBodyBytes = 90 * 1024
    public static let maxRecordInventoryBodyBytes = 2 * 1024 * 1024
    public static let maxTrustStatePageBodyBytes = 16 * 1024 * 1024
    public static let maxEncryptedRecordPageBodyBytes = 4 * 1024 * 1024
    private static let lowSHalfOrder = Data(hex: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!
    private static let p256Order = Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!

    public static func validateUniqueJSONKeys(_ data: Data) throws { guard data.count <= maxBodyBytes, String(data: data, encoding: .utf8) != nil else { throw AccountProtocolError.oversized }; try DuplicateJSONKeyScanner.validate(data) }
    public static func validateUniqueJSONKeys(_ data: Data, maximumBytes: Int, arrayLimits: [String: Int] = [:]) throws {
        guard maximumBytes > 0, data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else { throw AccountProtocolError.oversized }
        try DuplicateJSONKeyScanner.validate(data, arrayLimits: arrayLimits)
    }

    public static func decodeBase64URL(_ value: String, exactBytes: Int? = nil) throws -> Data {
        guard !value.isEmpty, !value.contains("="), value.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }) else { throw AccountProtocolError.nonCanonicalValue }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), encodeBase64URL(decoded) == value, exactBytes.map({ decoded.count == $0 }) ?? true else { throw AccountProtocolError.nonCanonicalValue }
        return decoded
    }

    public static func encodeBase64URL(_ value: Data) -> String { value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    public static func parseTimestamp(_ value: String) -> Date? {
        guard value.utf8.count == 20, value.utf8.enumerated().allSatisfy({ index, byte in
            [4, 7].contains(index) ? byte == 45 : [10].contains(index) ? byte == 84 : [13, 16].contains(index) ? byte == 58 : index == 19 ? byte == 90 : byte >= 48 && byte <= 57
        }) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let result = formatter.date(from: value) else { return nil }
        return formatter.string(from: result) == value ? result : nil
    }

    /// Trust pagination is signed by the Go service with `time.RFC3339Nano`,
    /// which omits the fractional component at whole seconds and otherwise
    /// emits one through nine digits without trailing zeroes.
    public static func parseTrustTimestamp(_ value: String) -> Date? {
        if let seconds = parseTimestamp(value) { return seconds }
        let bytes = Array(value.utf8)
        guard (22 ... 30).contains(bytes.count),
              bytes[19] == 46,
              bytes.last == 90,
              bytes[20 ..< bytes.count - 1].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[bytes.count - 2] != 48
        else { return nil }
        let wholeSeconds = String(decoding: bytes[0 ..< 19], as: UTF8.self) + "Z"
        guard parseTimestamp(wholeSeconds) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    public static func isKeyID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45 } }

    public static func validateLowSSignature(_ value: Data) throws {
        guard value.count == 64 else { throw AccountProtocolError.invalidSignature }
        let r = Data(value.prefix(32)), s = Data(value.suffix(32))
        guard !r.allSatisfy({ $0 == 0 }), !s.allSatisfy({ $0 == 0 }), r.lexicographicallyPrecedes(p256Order), s.lexicographicallyPrecedes(p256Order), s.lexicographicallyPrecedes(lowSHalfOrder) || s == lowSHalfOrder else { throw AccountProtocolError.invalidSignature }
    }

    public static func normalizedLowSSignature(_ value: Data) throws -> Data {
        guard value.count == 64 else { throw AccountProtocolError.invalidSignature }
        let s = Data(value.suffix(32))
        guard s.lexicographicallyPrecedes(p256Order) else { throw AccountProtocolError.invalidSignature }
        var result = value
        if lowSHalfOrder.lexicographicallyPrecedes(s) {
            var normalized = Array(p256Order)
            let source = Array(s)
            var borrow = 0
            for index in stride(from: 31, through: 0, by: -1) {
                let difference = Int(normalized[index]) - Int(source[index]) - borrow
                normalized[index] = UInt8(difference < 0 ? difference + 256 : difference)
                borrow = difference < 0 ? 1 : 0
            }
            result = Data(value.prefix(32)) + Data(normalized)
        }
        try validateLowSSignature(result)
        return result
    }

    public static func decodeExchangeRequest(_ data: Data) throws -> AccountExchangeRequest {
        let root = try object(data, fields: ["kind", "appleIdentityToken", "nonce", "deviceBundle", "deviceProof"])
        guard try string(root, "kind") == "account.exchange.v1" else { throw AccountProtocolError.malformedWire }
        let bundle = try decodeBundle(try object(root, "deviceBundle", fields: ["signingKey", "agreementKey"]))
        let proof = try decodeBase64URL(try string(root, "deviceProof"), exactBytes: 64)
        try validateLowSSignature(proof)
        return try AccountExchangeRequest(appleIdentityToken: try string(root, "appleIdentityToken"), nonce: try decodeBase64URL(try string(root, "nonce"), exactBytes: 32), deviceBundle: bundle, deviceProof: proof)
    }

    public static func decodePendingDevice(_ data: Data) throws -> AccountPendingDevice {
        try decodePendingDevice(try object(data, fields: pendingDeviceFields))
    }

    public static func decodePendingDevices(_ data: Data) throws -> [AccountPendingDevice] {
        let root = try object(data, fields: ["kind", "pendingDevices"], maximumBytes: 128 * 1024, scannerArrayLimits: ["pendingDevices": 10])
        guard try string(root, "kind") == "account.pending-devices.v1" else { throw AccountProtocolError.malformedWire }
        let devices = try array(root, "pendingDevices", maximumCount: 10).map { try decodePendingDevice(object($0, fields: pendingDeviceFields)) }
        guard devices.map(\.deviceID.rawValue) == devices.map(\.deviceID.rawValue).sorted(), Set(devices.map(\.deviceID)).count == devices.count else { throw AccountProtocolError.malformedWire }
        return devices
    }

    private static func decodePendingDevice(_ root: [String: Any]) throws -> AccountPendingDevice {
        guard try string(root, "kind") == "account.pending-device.v1", let platform = AccountPlatform(rawValue: try string(root, "platform")) else { throw AccountProtocolError.malformedWire }
        return try AccountPendingDevice(accountID: try PlainpostAccountID(try string(root, "accountID")), deviceID: try AccountDeviceID(try string(root, "deviceID")), platform: platform, publicBundle: try decodeBundle(try object(root, "publicBundle", fields: ["signingKey", "agreementKey"])), exchangeRequestDigest: try decodeBase64URL(try string(root, "exchangeRequestDigest"), exactBytes: 32), createdAt: try string(root, "createdAt"), expiresAt: try string(root, "expiresAt"))
    }

    public static func decodeRecoveryAuthorization(_ data: Data) throws -> AccountRecoveryAuthorization {
        try decodeRecoveryAuthorization(try object(data, fields: recoveryAuthorizationFields))
    }

    public static func decodeTrustAdmissionEvidence(_ data: Data) throws -> AccountTrustAdmissionEvidenceV1 {
        let root = try object(data, fields: ["kind", "pendingDevice", "response"])
        guard try string(root, "kind") == "account.trust-admission-evidence.v1" else { throw AccountProtocolError.malformedWire }
        let pending = try decodePendingDevice(try object(root, "pendingDevice", fields: pendingDeviceFields))
        let responseRoot = try object(root, "response", fields: ["offer", "pendingNonce"])
        let offerRoot = try object(responseRoot, "offer", fields: trustOfferFields)
        let offer = try TrustHandshakeOfferV1(
            accountID: try PlainpostAccountID(try string(offerRoot, "accountID")),
            existingDeviceID: try AccountDeviceID(try string(offerRoot, "existingDeviceID")),
            pendingDeviceID: try AccountDeviceID(try string(offerRoot, "pendingDeviceID")),
            existingPublicBundle: try decodeBundle(try object(offerRoot, "existingPublicBundle", fields: ["signingKey", "agreementKey"])),
            pendingPublicBundle: try decodeBundle(try object(offerRoot, "pendingPublicBundle", fields: ["signingKey", "agreementKey"])),
            existingNonce: try decodeBase64URL(try string(offerRoot, "existingNonce"), exactBytes: 32),
            createdAtUnixMilliseconds: try PositiveUInt64(wire: try string(offerRoot, "createdAtUnixMilliseconds")),
            expiresAtUnixMilliseconds: try PositiveUInt64(wire: try string(offerRoot, "expiresAtUnixMilliseconds"))
        )
        return AccountTrustAdmissionEvidenceV1(
            pendingDevice: pending,
            response: try TrustHandshakeResponseV1(
                offer: offer,
                pendingNonce: try decodeBase64URL(try string(responseRoot, "pendingNonce"), exactBytes: 32)
            )
        )
    }

    public static func decodeAdmissionOfferEnvelope(_ data: Data) throws -> AccountTrustAdmissionOfferEnvelopeV1 {
        let root = try object(data, fields: ["kind", "offer", "offerDigest"], maximumBytes: 4_096)
        guard try string(root, "kind") == "account.trust-admission-offer.v1" else { throw AccountProtocolError.malformedWire }
        let offer = try decodeTrustOffer(try object(root, "offer", fields: trustOfferFields))
        let canonical = try JSONSerialization.data(withJSONObject: encodeOffer(offer), options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = AccountSHA256.hash(canonical)
        guard digest == (try decodeBase64URL(try string(root, "offerDigest"), exactBytes: 32)) else { throw AccountProtocolError.malformedWire }
        let result = try AccountTrustAdmissionOfferEnvelopeV1(offerDigest: digest, offer: offer)
        guard try encodeAdmissionOfferEnvelope(offer) == data else { throw AccountProtocolError.nonCanonicalValue }
        return result
    }

    public static func decodeAdmissionResponseEnvelope(_ data: Data) throws -> AccountTrustAdmissionResponseEnvelopeV1 {
        let root = try object(data, fields: ["kind", "offerDigest", "response"], maximumBytes: 8_192)
        guard try string(root, "kind") == "account.trust-admission-response.v1" else { throw AccountProtocolError.malformedWire }
        let responseRoot = try object(root, "response", fields: ["offer", "pendingNonce"])
        let offer = try decodeTrustOffer(try object(responseRoot, "offer", fields: trustOfferFields))
        let response = try TrustHandshakeResponseV1(offer: offer, pendingNonce: decodeBase64URL(try string(responseRoot, "pendingNonce"), exactBytes: 32))
        let canonicalOffer = try JSONSerialization.data(withJSONObject: encodeOffer(offer), options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = AccountSHA256.hash(canonicalOffer)
        guard digest == (try decodeBase64URL(try string(root, "offerDigest"), exactBytes: 32)) else { throw AccountProtocolError.malformedWire }
        let result = try AccountTrustAdmissionResponseEnvelopeV1(offerDigest: digest, response: response)
        guard try encodeAdmissionResponseEnvelope(result) == data else { throw AccountProtocolError.nonCanonicalValue }
        return result
    }

    public static func decodeAdmissionCancelEnvelope(_ data: Data) throws -> AccountTrustAdmissionCancelEnvelopeV1 {
        let root = try object(data, fields: ["kind", "offerDigest"], maximumBytes: 256)
        guard try string(root, "kind") == "account.trust-admission-cancel.v1" else { throw AccountProtocolError.malformedWire }
        let result = try AccountTrustAdmissionCancelEnvelopeV1(offerDigest: decodeBase64URL(try string(root, "offerDigest"), exactBytes: 32))
        guard try encodeAdmissionCancelEnvelope(result) == data else { throw AccountProtocolError.nonCanonicalValue }
        return result
    }

    public static func decodeTrustRecoveryEvidence(_ data: Data) throws -> AccountTrustRecoveryEvidenceV1 {
        let root = try object(data, fields: ["kind", "authorization", "historicalManifest"])
        guard try string(root, "kind") == "account.trust-recovery-evidence.v1" else { throw AccountProtocolError.malformedWire }
        return AccountTrustRecoveryEvidenceV1(
            authorization: try decodeRecoveryAuthorization(try object(root, "authorization", fields: recoveryAuthorizationFields)),
            historicalManifest: try decodeManifest(try object(root, "historicalManifest", fields: manifestFields, optional: ["previousManifestDigest"]))
        )
    }

    public static func decodeTrustHistoryEntry(_ data: Data) throws -> AccountTrustHistoryEntryV1 {
        let root = try object(data, fields: ["kind", "commit", "evidence"])
        guard try string(root, "kind") == "account.trust-history-entry.v1" else { throw AccountProtocolError.malformedWire }
        let commit = try decodeTrustCommit(try object(root, "commit", fields: ["kind", "state", "keyPackages"]))
        let evidence: AccountTrustTransitionEvidenceV1?
        if root["evidence"] is NSNull {
            evidence = nil
        } else {
            let evidenceObject = try object(root["evidence"] as Any)
            switch try string(evidenceObject, "kind") {
            case "account.trust-admission-evidence.v1":
                let encoded = try JSONSerialization.data(withJSONObject: evidenceObject, options: [.sortedKeys, .withoutEscapingSlashes])
                evidence = .admission(try decodeTrustAdmissionEvidence(encoded))
            case "account.trust-recovery-evidence.v1":
                let encoded = try JSONSerialization.data(withJSONObject: evidenceObject, options: [.sortedKeys, .withoutEscapingSlashes])
                evidence = .recovery(try decodeTrustRecoveryEvidence(encoded))
            case "account.sync-node-admission-evidence.v1":
                let encoded = try JSONSerialization.data(withJSONObject: evidenceObject, options: [.sortedKeys, .withoutEscapingSlashes])
                evidence = .syncNodeEnrollment(try decodeNodeEnrollmentAdmissionEvidence(encoded))
            default:
                throw AccountProtocolError.malformedWire
            }
        }
        return try AccountTrustHistoryEntryV1(commit: commit, evidence: evidence)
    }

    private static func decodeRecoveryAuthorization(_ root: [String: Any]) throws -> AccountRecoveryAuthorization {
        guard try string(root, "kind") == "account.recovery-authorization.v1", let platform = AccountPlatform(rawValue: try string(root, "platform")) else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(try string(root, "serverSignature"), exactBytes: 64)
        try validateLowSSignature(signature)
        return try AccountRecoveryAuthorization(authorizationID: try AccountAuthorizationID(try string(root, "authorizationID")), accountID: try PlainpostAccountID(try string(root, "accountID")), epoch: try AccountTrustEpoch(wire: try string(root, "epoch")), deviceID: try AccountDeviceID(try string(root, "deviceID")), platform: platform, publicBundle: try decodeBundle(try object(root, "publicBundle", fields: ["signingKey", "agreementKey"])), priorCommitDigest: try decodeBase64URL(try string(root, "priorCommitDigest"), exactBytes: 32), exchangeRequestDigest: try decodeBase64URL(try string(root, "exchangeRequestDigest"), exactBytes: 32), issuedAt: try string(root, "issuedAt"), expiresAt: try string(root, "expiresAt"), serverKeyID: try string(root, "serverKeyID"), serverSignature: signature)
    }

    public static func decodeBootstrapChallenge(_ data: Data) throws -> AccountBootstrapChallenge { try decodeBootstrapChallenge(try object(data, fields: challengeFields)) }
    public static func decodeBootstrapFinalize(_ data: Data) throws -> AccountBootstrapFinalize {
        let root = try object(data, fields: ["kind", "challenge", "challengeDigest", "exchangeRequestDigest", "genesisCommit", "deviceSignature"])
        guard try string(root, "kind") == "account.bootstrap-finalize.v1" else { throw AccountProtocolError.malformedWire }
        let challenge = try decodeBootstrapChallenge(try object(root, "challenge", fields: challengeFields))
        let signature = try decodeBase64URL(try string(root, "deviceSignature"), exactBytes: 64)
        try validateLowSSignature(signature)
        let commit: AccountTrustStateCommit?
        if root["genesisCommit"] is NSNull { commit = nil } else { commit = try decodeTrustCommit(try object(root, "genesisCommit", fields: ["kind", "state", "keyPackages"])) }
        return try AccountBootstrapFinalize(challenge: challenge, challengeDigest: try decodeBase64URL(try string(root, "challengeDigest"), exactBytes: 32), exchangeRequestDigest: try decodeBase64URL(try string(root, "exchangeRequestDigest"), exactBytes: 32), genesisCommit: commit, deviceSignature: signature)
    }

    public static func decodeTrustCommit(_ data: Data) throws -> AccountTrustStateCommit { try decodeTrustCommit(try object(data, fields: ["kind", "state", "keyPackages"])) }
    public static func decodeTrustCursor(_ data: Data) throws -> AccountTrustCursorV1 {
        try decodeTrustCursor(try object(data, fields: ["kind", "accountID", "after", "snapshotHead", "issuedAt", "expiresAt", "serverKeyID", "signature"], maximumBytes: maxBodyBytes))
    }
    public static func decodeTrustStatePage(_ data: Data) throws -> AccountTrustStatePageV1 {
        let root = try object(data, fields: ["kind", "requestCursor", "accountID", "snapshotHead", "entries", "nextCursor", "terminal", "issuedAt", "expiresAt", "serverKeyID", "serverSignature"], maximumBytes: maxTrustStatePageBodyBytes, scannerArrayLimits: ["entries": 32])
        guard try string(root, "kind") == "account.trust-state-page.v1" else { throw AccountProtocolError.malformedWire }
        let entries = try array(root, "entries", maximumCount: 32).map { try decodeTrustHistoryEntry(JSONSerialization.data(withJSONObject: try object($0), options: [.sortedKeys, .withoutEscapingSlashes])) }
        let next: AccountTrustCursorV1? = root["nextCursor"] is NSNull ? nil : try decodeTrustCursor(try object(root, "nextCursor", fields: ["kind", "accountID", "after", "snapshotHead", "issuedAt", "expiresAt", "serverKeyID", "signature"]))
        let signature = try decodeBase64URL(try string(root, "serverSignature"), exactBytes: 64)
        return try AccountTrustStatePageV1(requestCursor: decodeTrustCursor(try object(root, "requestCursor", fields: ["kind", "accountID", "after", "snapshotHead", "issuedAt", "expiresAt", "serverKeyID", "signature"])), accountID: PlainpostAccountID(try string(root, "accountID")), snapshotHead: decodeTrustPageCheckpoint(try object(root, "snapshotHead", fields: ["epoch", "revision", "commitDigest"])), entries: entries, nextCursor: next, terminal: try boolean(root, "terminal"), issuedAt: try string(root, "issuedAt"), expiresAt: try string(root, "expiresAt"), serverKeyID: try string(root, "serverKeyID"), serverSignature: signature)
    }
    public static func decodeEncryptedAccountRecordPage(_ data: Data) throws -> EncryptedAccountRecordPageV1 {
        let root = try object(data, fields: ["kind", "records", "nextCursor", "terminal"], maximumBytes: maxEncryptedRecordPageBodyBytes, scannerArrayLimits: ["records": 32])
        guard try string(root, "kind") == "account.encrypted-record-page.v1" else { throw AccountProtocolError.malformedWire }
        let records = try array(root, "records", maximumCount: 32).map { try decodeEncryptedAccountRecord(JSONSerialization.data(withJSONObject: try object($0), options: [.sortedKeys, .withoutEscapingSlashes])) }
        let cursor = root["nextCursor"] is NSNull ? nil : try decodeBase64URL(try string(root, "nextCursor"), exactBytes: 8)
        return try EncryptedAccountRecordPageV1(records: records, nextCursor: cursor, terminal: try boolean(root, "terminal"))
    }
    public static func decodeEncryptedAccountRecord(_ data: Data) throws -> EncryptedAccountRecordV1 {
        let root = try object(data, fields: ["kind", "accountID", "recordID", "epoch", "keyGeneration", "trustRevision", "recordRevision", "envelope", "signerDeviceID", "signature"], maximumBytes: maxEncryptedRecordBodyBytes)
        guard try string(root, "kind") == "account.encrypted-record.v1" else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(try string(root, "signature"), exactBytes: 64)
        try validateLowSSignature(signature)
        return try EncryptedAccountRecordV1(
            accountID: try PlainpostAccountID(try string(root, "accountID")),
            recordID: try AccountRecordID(try string(root, "recordID")),
            epoch: try AccountTrustEpoch(wire: try string(root, "epoch")),
            keyGeneration: try PositiveUInt64(wire: try string(root, "keyGeneration")),
            trustRevision: try PositiveUInt64(wire: try string(root, "trustRevision")),
            recordRevision: try PositiveUInt64(wire: try string(root, "recordRevision")),
            envelope: try decodeBase64URL(try string(root, "envelope", maximumBytes: 87_382)),
            signerDeviceID: try AccountDeviceID(try string(root, "signerDeviceID")),
            signature: signature
        )
    }

    public static func decodeRecordInventoryProof(_ data: Data) throws -> AccountRecordInventoryProofV1 {
        let root = try object(
            data,
            fields: ["kind", "accountID", "trustCommitDigest", "epoch", "keyGeneration", "entries", "issuedAt", "expiresAt", "serverKeyID", "serverSignature"],
            maximumBytes: maxRecordInventoryBodyBytes,
            scannerArrayLimits: ["entries": AccountRecordInventoryProofV1.maximumEntries]
        )
        guard try string(root, "kind") == "account.record-inventory-proof.v1" else { throw AccountProtocolError.malformedWire }
        let entries = try array(root, "entries", maximumCount: AccountRecordInventoryProofV1.maximumEntries).map { item -> AccountRecordInventoryEntryV1 in
            let entry = try object(item, fields: ["recordID", "epoch", "keyGeneration", "trustRevision", "recordRevision", "envelopeDigest", "signatureDigest"])
            return try AccountRecordInventoryEntryV1(
                recordID: try AccountRecordID(try string(entry, "recordID")),
                epoch: try AccountTrustEpoch(wire: try string(entry, "epoch")),
                keyGeneration: try PositiveUInt64(wire: try string(entry, "keyGeneration")),
                trustRevision: try PositiveUInt64(wire: try string(entry, "trustRevision")),
                recordRevision: try PositiveUInt64(wire: try string(entry, "recordRevision")),
                envelopeDigest: try decodeBase64URL(try string(entry, "envelopeDigest"), exactBytes: 32),
                signatureDigest: try decodeBase64URL(try string(entry, "signatureDigest"), exactBytes: 32)
            )
        }
        let signature = try decodeBase64URL(try string(root, "serverSignature"), exactBytes: 64)
        return try AccountRecordInventoryProofV1(
            accountID: try PlainpostAccountID(try string(root, "accountID")),
            trustCommitDigest: try decodeBase64URL(try string(root, "trustCommitDigest"), exactBytes: 32),
            epoch: try AccountTrustEpoch(wire: try string(root, "epoch")),
            keyGeneration: try PositiveUInt64(wire: try string(root, "keyGeneration")),
            entries: entries,
            issuedAt: try string(root, "issuedAt"),
            expiresAt: try string(root, "expiresAt"),
            serverKeyID: try string(root, "serverKeyID"),
            serverSignature: signature
        )
    }
    public static func decodeManifest(_ data: Data) throws -> AccountBootstrapManifest {
        try decodeManifest(try object(data, fields: manifestFields, optional: ["previousManifestDigest"]))
    }
    public static func decodeManifestResponse(_ data: Data) throws -> AccountBootstrapManifestResponse {
        let root = try object(data, fields: ["kind", "current", "overlap"])
        guard try string(root, "kind") == "central.bootstrap-key-manifest-response.v1" else { throw AccountProtocolError.malformedWire }
        let current = try decodeManifest(try object(root, "current", fields: manifestFields, optional: ["previousManifestDigest"]))
        let overlap = try array(root, "overlap")
        guard overlap.count <= 4 else { throw AccountProtocolError.oversized }
        return try AccountBootstrapManifestResponse(current: current, overlap: try overlap.map { try decodeManifest(try object($0, fields: manifestFields, optional: ["previousManifestDigest"])) })
    }
    private static func decodeManifest(_ root: [String: Any]) throws -> AccountBootstrapManifest {
        guard try string(root, "kind") == "central.bootstrap-key-manifest.v1" else { throw AccountProtocolError.malformedWire }
        let keys = try array(root, "keys").map { item -> AccountBootstrapKey in
            let key = try object(item, fields: ["keyID", "purpose", "publicKey", "notBefore", "expiresAt", "status"])
            return try AccountBootstrapKey(keyID: try string(key, "keyID"), purpose: try accountKeyPurpose(try string(key, "purpose")), publicKey: try decodeBase64URL(try string(key, "publicKey"), exactBytes: 65), notBefore: try string(key, "notBefore"), expiresAt: try string(key, "expiresAt"), status: try accountKeyStatus(try string(key, "status")))
        }
        let previous: Data? = root["previousManifestDigest"] is NSNull || root["previousManifestDigest"] == nil ? nil : try decodeBase64URL(try string(root, "previousManifestDigest"), exactBytes: 32)
        let signature = try decodeBase64URL(try string(root, "rootSignature"), exactBytes: 64)
        try validateLowSSignature(signature)
        return try AccountBootstrapManifest(rootKeyID: try string(root, "rootKeyID"), manifestVersion: try PositiveUInt64(wire: try string(root, "manifestVersion")), notBefore: try string(root, "notBefore"), expiresAt: try string(root, "expiresAt"), previousManifestDigest: previous, keys: keys, rootSignature: signature)
    }

    public static func encodeExchangeRequest(_ value: AccountExchangeRequest) throws -> Data { try JSONSerialization.data(withJSONObject: ["kind": "account.exchange.v1", "appleIdentityToken": value.appleIdentityToken, "nonce": encodeBase64URL(value.nonce), "deviceBundle": encodeBundle(value.deviceBundle), "deviceProof": encodeBase64URL(value.deviceProof)], options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func encodeManifest(_ value: AccountBootstrapManifest) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeManifestObject(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeManifestResponse(_ value: AccountBootstrapManifestResponse) throws -> Data {
        for manifest in value.all { try validateLowSSignature(manifest.rootSignature) }
        return try JSONSerialization.data(
            withJSONObject: [
                "kind": "central.bootstrap-key-manifest-response.v1",
                "current": encodeManifestObject(value.current),
                "overlap": value.overlap.map(encodeManifestObject),
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
    public static func encodeTrustAdmissionEvidence(_ value: AccountTrustAdmissionEvidenceV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeAdmissionEvidence(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeTrustCommitSubmission(commit: AccountTrustStateCommit, evidence: AccountTrustAdmissionEvidenceV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.trust-commit-submission.v1", "commit": encodeCommit(commit), "evidence": encodeAdmissionEvidence(evidence)], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeAdmissionOfferEnvelope(_ offer: TrustHandshakeOfferV1) throws -> Data {
        let offerObject = encodeOffer(offer)
        let canonical = try JSONSerialization.data(withJSONObject: offerObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = AccountSHA256.hash(canonical)
        return try JSONSerialization.data(withJSONObject: ["kind": "account.trust-admission-offer.v1", "offer": offerObject, "offerDigest": encodeBase64URL(digest)], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeAdmissionResponseEnvelope(_ value: AccountTrustAdmissionResponseEnvelopeV1) throws -> Data {
        let canonicalOffer = try JSONSerialization.data(withJSONObject: encodeOffer(value.response.offer), options: [.sortedKeys, .withoutEscapingSlashes])
        guard AccountSHA256.hash(canonicalOffer) == value.offerDigest else { throw AccountProtocolError.malformedWire }
        return try JSONSerialization.data(withJSONObject: ["kind": "account.trust-admission-response.v1", "offerDigest": encodeBase64URL(value.offerDigest), "response": ["offer": encodeOffer(value.response.offer), "pendingNonce": encodeBase64URL(value.response.pendingNonce)]], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeAdmissionCancelEnvelope(_ value: AccountTrustAdmissionCancelEnvelopeV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.trust-admission-cancel.v1", "offerDigest": encodeBase64URL(value.offerDigest)], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeTrustRecoveryEvidence(_ value: AccountTrustRecoveryEvidenceV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeRecoveryEvidence(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeTrustHistoryEntry(_ value: AccountTrustHistoryEntryV1) throws -> Data {
        let evidence: Any
        switch value.evidence {
        case .admission(let admission): evidence = encodeAdmissionEvidence(admission)
        case .recovery(let recovery): evidence = encodeRecoveryEvidence(recovery)
        case .syncNodeEnrollment(let node): evidence = try JSONSerialization.jsonObject(with: encodeNodeEnrollmentAdmissionEvidence(node))
        case nil: evidence = NSNull()
        }
        return try JSONSerialization.data(withJSONObject: ["kind": "account.trust-history-entry.v1", "commit": encodeCommit(value.commit), "evidence": evidence], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeTrustCursor(_ value: AccountTrustCursorV1) throws -> Data { try JSONSerialization.data(withJSONObject: encodeTrustCursorObject(value), options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func encodeTrustStatePage(_ value: AccountTrustStatePageV1) throws -> Data {
        let entries = try value.entries.map { try JSONSerialization.jsonObject(with: encodeTrustHistoryEntry($0)) }
        return try JSONSerialization.data(withJSONObject: ["kind": "account.trust-state-page.v1", "requestCursor": encodeTrustCursorObject(value.requestCursor), "accountID": value.accountID.rawValue, "snapshotHead": encodeTrustPageCheckpoint(value.snapshotHead), "entries": entries, "nextCursor": value.nextCursor.map(encodeTrustCursorObject) ?? NSNull(), "terminal": value.terminal, "issuedAt": value.issuedAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "serverSignature": encodeBase64URL(value.serverSignature)], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeEncryptedAccountRecordPage(_ value: EncryptedAccountRecordPageV1) throws -> Data {
        let records = try value.records.map { try JSONSerialization.jsonObject(with: encodeEncryptedAccountRecord($0)) }
        let nextCursor: Any = value.nextCursor.map(encodeBase64URL) ?? NSNull()
        return try JSONSerialization.data(withJSONObject: ["kind": "account.encrypted-record-page.v1", "records": records, "nextCursor": nextCursor, "terminal": value.terminal], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeFinalize(_ value: AccountBootstrapFinalize) throws -> Data { try JSONSerialization.data(withJSONObject: ["kind": "account.bootstrap-finalize.v1", "challenge": encodeChallenge(value.challenge), "challengeDigest": encodeBase64URL(value.challengeDigest), "exchangeRequestDigest": encodeBase64URL(value.exchangeRequestDigest), "genesisCommit": value.genesisCommit.map(encodeCommit) ?? NSNull(), "deviceSignature": encodeBase64URL(value.deviceSignature)], options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func encodeTrustCommit(_ value: AccountTrustStateCommit) throws -> Data {
        try JSONSerialization.data(withJSONObject: encodeCommit(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeEncryptedAccountRecord(_ value: EncryptedAccountRecordV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "kind": "account.encrypted-record.v1",
            "accountID": value.accountID.rawValue,
            "recordID": value.recordID.rawValue,
            "epoch": value.epoch.wireValue,
            "keyGeneration": value.keyGeneration.wireValue,
            "trustRevision": value.trustRevision.wireValue,
            "recordRevision": value.recordRevision.wireValue,
            "envelope": encodeBase64URL(value.envelope),
            "signerDeviceID": value.signerDeviceID.rawValue,
            "signature": encodeBase64URL(value.signature),
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func encodeRecordInventoryProof(_ value: AccountRecordInventoryProofV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "kind": "account.record-inventory-proof.v1",
            "accountID": value.accountID.rawValue,
            "trustCommitDigest": encodeBase64URL(value.trustCommitDigest),
            "epoch": value.epoch.wireValue,
            "keyGeneration": value.keyGeneration.wireValue,
            "entries": value.entries.map { entry in
                [
                    "recordID": entry.recordID.rawValue,
                    "epoch": entry.epoch.wireValue,
                    "keyGeneration": entry.keyGeneration.wireValue,
                    "trustRevision": entry.trustRevision.wireValue,
                    "recordRevision": entry.recordRevision.wireValue,
                    "envelopeDigest": encodeBase64URL(entry.envelopeDigest),
                    "signatureDigest": encodeBase64URL(entry.signatureDigest),
                ]
            },
            "issuedAt": value.issuedAt,
            "expiresAt": value.expiresAt,
            "serverKeyID": value.serverKeyID,
            "serverSignature": encodeBase64URL(value.serverSignature),
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeActivation(_ data: Data) throws -> AccountActivation {
        let root = try object(data, fields: ["kind", "accountID", "deviceID", "accessToken", "refreshCredential", "offlineLease", "currentTrustCommit"])
        guard try string(root, "kind") == "account.activation.v1" else { throw AccountProtocolError.malformedWire }
        let commit = try decodeTrustCommit(try object(root, "currentTrustCommit", fields: ["kind", "state", "keyPackages"])), access = try string(root, "accessToken")
        guard let expiry = tokenExpiry(access) else { throw AccountProtocolError.malformedWire }
        let mode: AccountBootstrapMode = commit.state.transition.kind == .genesis ? .genesis : .pending
        return AccountActivation(accountID: try PlainpostAccountID(try string(root, "accountID")), deviceID: try AccountDeviceID(try string(root, "deviceID")), mode: mode, accessToken: access, accessExpiresAt: expiry, refreshCredential: try decodeBase64URL(string(root, "refreshCredential"), exactBytes: 32), offlineLease: try string(root, "offlineLease"), currentTrustCommit: commit)
    }
    private static func tokenExpiry(_ token: String) -> Date? { let parts = token.split(separator: "."); guard parts.count == 3, let payload = try? decodeBase64URL(String(parts[1])), let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let value = root["exp"] as? NSNumber else { return nil }; return Date(timeIntervalSince1970: value.doubleValue / 1_000_000_000) }

    private static let challengeFields = ["kind", "challengeID", "challengeNonce", "exchangeRequestDigest", "accountID", "deviceID", "mode", "platform", "publicBundle", "createdAt", "expiresAt", "serverKeyID", "serverSignature"]
    private static let manifestFields = ["kind", "rootKeyID", "manifestVersion", "notBefore", "expiresAt", "keys", "rootSignature"]
    private static let pendingDeviceFields = ["kind", "accountID", "deviceID", "platform", "publicBundle", "exchangeRequestDigest", "createdAt", "expiresAt"]
    private static let recoveryAuthorizationFields = ["kind", "authorizationID", "accountID", "epoch", "deviceID", "platform", "publicBundle", "priorCommitDigest", "exchangeRequestDigest", "issuedAt", "expiresAt", "serverKeyID", "serverSignature"]
    private static let trustOfferFields = ["accountID", "existingDeviceID", "pendingDeviceID", "existingPublicBundle", "pendingPublicBundle", "existingNonce", "createdAtUnixMilliseconds", "expiresAtUnixMilliseconds"]
    private static func decodeBootstrapChallenge(_ root: [String: Any]) throws -> AccountBootstrapChallenge {
        guard try string(root, "kind") == "account.bootstrap-challenge.v1", let mode = AccountBootstrapMode(rawValue: try string(root, "mode")), let platform = AccountPlatform(rawValue: try string(root, "platform")) else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(try string(root, "serverSignature"), exactBytes: 64)
        try validateLowSSignature(signature)
        return try AccountBootstrapChallenge(challengeID: try AccountChallengeID(try string(root, "challengeID")), challengeNonce: try decodeBase64URL(try string(root, "challengeNonce"), exactBytes: 32), exchangeRequestDigest: try decodeBase64URL(try string(root, "exchangeRequestDigest"), exactBytes: 32), accountID: try PlainpostAccountID(try string(root, "accountID")), deviceID: try AccountDeviceID(try string(root, "deviceID")), mode: mode, platform: platform, publicBundle: try decodeBundle(try object(root, "publicBundle", fields: ["signingKey", "agreementKey"])), createdAt: try string(root, "createdAt"), expiresAt: try string(root, "expiresAt"), serverKeyID: try string(root, "serverKeyID"), serverSignature: signature)
    }

    private static func decodeTrustCommit(_ root: [String: Any]) throws -> AccountTrustStateCommit {
        guard try string(root, "kind") == "account.trust-state-commit.v1" else { throw AccountProtocolError.malformedWire }
        let state = try decodeState(try object(root, "state", fields: ["accountID", "epoch", "revision", "previousCommitDigest", "transition", "keyGeneration", "keyCommitment", "members", "signerDeviceID", "signature"]))
        let packages = try array(root, "keyPackages").map(decodePackage)
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }

    private static func decodeState(_ root: [String: Any]) throws -> AccountTrustState {
        let members = try array(root, "members").map(decodeRecord)
        guard let transitionValue = root["transition"] else { throw AccountProtocolError.malformedWire }
        let transition = try decodeTransition(try object(transitionValue))
        let previous: Data? = root["previousCommitDigest"] is NSNull ? nil : try decodeBase64URL(try string(root, "previousCommitDigest"), exactBytes: 32)
        let signature = try decodeBase64URL(try string(root, "signature"), exactBytes: 64); try validateLowSSignature(signature)
        return try AccountTrustState(accountID: try PlainpostAccountID(try string(root, "accountID")), epoch: try AccountTrustEpoch(wire: try string(root, "epoch")), revision: try PositiveUInt64(wire: try string(root, "revision")), previousCommitDigest: previous, transition: transition, keyGeneration: try PositiveUInt64(wire: try string(root, "keyGeneration")), keyCommitment: try decodeBase64URL(try string(root, "keyCommitment"), exactBytes: 32), members: members, signerDeviceID: try AccountDeviceID(try string(root, "signerDeviceID")), signature: signature)
    }

    private static func decodeTransition(_ root: [String: Any]) throws -> AccountTrustTransition {
        guard let kind = AccountTrustTransitionKind(rawValue: try string(root, "kind")) else { throw AccountProtocolError.invalidTransition }
        var fields = ["kind", "targetDeviceIDs", "priorRecordDigests"]
        switch kind { case .admission: fields += ["handshakeDigest", "pendingDeviceDigest"]; case .recovery: fields += ["recoveryAuthorizationDigest"]; default: break }
        guard Set(root.keys) == Set(fields), root.keys.count == fields.count else { throw AccountProtocolError.malformedWire }
        let targets = try array(root, "targetDeviceIDs").map { item in guard let value = item as? String else { throw AccountProtocolError.malformedWire }; return try AccountDeviceID(value) }
        let priors = try array(root, "priorRecordDigests").map { item -> AccountPriorRecordDigest in let value = try object(item, fields: ["deviceID", "recordDigest"]); return try AccountPriorRecordDigest(deviceID: try AccountDeviceID(try string(value, "deviceID")), recordDigest: try decodeBase64URL(try string(value, "recordDigest"), exactBytes: 32)) }
        return try AccountTrustTransition(kind: kind, targetDeviceIDs: targets, priorRecordDigests: priors, handshakeDigest: try optionalBase64(root, "handshakeDigest"), pendingDeviceDigest: try optionalBase64(root, "pendingDeviceDigest"), recoveryAuthorizationDigest: try optionalBase64(root, "recoveryAuthorizationDigest"))
    }

    private static func decodeRecord(_ item: Any) throws -> AccountDeviceTrustRecord {
        let root = try object(item, fields: ["accountID", "epoch", "revision", "deviceID", "platform", "publicBundle", "signerDeviceID", "signature"])
        guard let platform = AccountPlatform(rawValue: try string(root, "platform")) else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(try string(root, "signature"), exactBytes: 64); try validateLowSSignature(signature)
        return try AccountDeviceTrustRecord(accountID: try PlainpostAccountID(try string(root, "accountID")), epoch: try AccountTrustEpoch(wire: try string(root, "epoch")), revision: try PositiveUInt64(wire: try string(root, "revision")), deviceID: try AccountDeviceID(try string(root, "deviceID")), platform: platform, publicBundle: try decodeBundle(try object(root, "publicBundle", fields: ["signingKey", "agreementKey"])), signerDeviceID: try AccountDeviceID(try string(root, "signerDeviceID")), signature: signature)
    }

    private static func decodePackage(_ item: Any) throws -> AccountGroupKeyPackage {
        let root = try object(item, fields: ["kind", "accountID", "epoch", "stateRevision", "keyGeneration", "stateDigest", "keyCommitment", "recipientDeviceID", "senderDeviceID", "senderEphemeralPublicKey", "nonce", "encryptedKeyMaterial", "signature"])
        guard try string(root, "kind") == "account.group-key-package.v1" else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(try string(root, "signature"), exactBytes: 64); try validateLowSSignature(signature)
        return try AccountGroupKeyPackage(accountID: try PlainpostAccountID(try string(root, "accountID")), epoch: try AccountTrustEpoch(wire: try string(root, "epoch")), stateRevision: try PositiveUInt64(wire: try string(root, "stateRevision")), keyGeneration: try PositiveUInt64(wire: try string(root, "keyGeneration")), stateDigest: try decodeBase64URL(try string(root, "stateDigest"), exactBytes: 32), keyCommitment: try decodeBase64URL(try string(root, "keyCommitment"), exactBytes: 32), recipientDeviceID: try AccountDeviceID(try string(root, "recipientDeviceID")), senderDeviceID: try AccountDeviceID(try string(root, "senderDeviceID")), senderEphemeralPublicKey: try decodeBase64URL(try string(root, "senderEphemeralPublicKey"), exactBytes: 65), nonce: try decodeBase64URL(try string(root, "nonce"), exactBytes: 12), encryptedKeyMaterial: try decodeBase64URL(try string(root, "encryptedKeyMaterial"), exactBytes: 80), signature: signature)
    }

    private static func decodeBundle(_ root: [String: Any]) throws -> AccountPublicKeyBundle { try AccountPublicKeyBundle(signingKey: decodeBase64URL(try string(root, "signingKey"), exactBytes: 65), agreementKey: decodeBase64URL(try string(root, "agreementKey"), exactBytes: 65)) }
    private static func decodeTrustOffer(_ root: [String: Any]) throws -> TrustHandshakeOfferV1 {
        try TrustHandshakeOfferV1(accountID: PlainpostAccountID(string(root, "accountID")), existingDeviceID: AccountDeviceID(string(root, "existingDeviceID")), pendingDeviceID: AccountDeviceID(string(root, "pendingDeviceID")), existingPublicBundle: decodeBundle(object(root, "existingPublicBundle", fields: ["signingKey", "agreementKey"])), pendingPublicBundle: decodeBundle(object(root, "pendingPublicBundle", fields: ["signingKey", "agreementKey"])), existingNonce: decodeBase64URL(string(root, "existingNonce"), exactBytes: 32), createdAtUnixMilliseconds: PositiveUInt64(wire: string(root, "createdAtUnixMilliseconds")), expiresAtUnixMilliseconds: PositiveUInt64(wire: string(root, "expiresAtUnixMilliseconds")))
    }
    private static func decodeTrustPageCheckpoint(_ root: [String: Any]) throws -> AccountTrustPageCheckpointV1 {
        try AccountTrustPageCheckpointV1(epoch: AccountTrustEpoch(wire: string(root, "epoch")), revision: PositiveUInt64(wire: string(root, "revision")), commitDigest: decodeBase64URL(string(root, "commitDigest"), exactBytes: 32))
    }
    private static func decodeTrustCursor(_ root: [String: Any]) throws -> AccountTrustCursorV1 {
        guard try string(root, "kind") == "account.trust-cursor.v1" else { throw AccountProtocolError.malformedWire }
        guard let afterRoot = root["after"] as? [String: Any] else { throw AccountProtocolError.malformedWire }
        let after: AccountTrustAfterV1
        if Set(afterRoot.keys) == ["kind"], try string(afterRoot, "kind") == "genesis" { after = .genesis }
        else { after = .checkpoint(try decodeTrustPageCheckpoint(try closed(afterRoot, fields: ["epoch", "revision", "commitDigest"], optional: []))) }
        return try AccountTrustCursorV1(accountID: PlainpostAccountID(string(root, "accountID")), after: after, snapshotHead: decodeTrustPageCheckpoint(object(root, "snapshotHead", fields: ["epoch", "revision", "commitDigest"])), issuedAt: string(root, "issuedAt"), expiresAt: string(root, "expiresAt"), serverKeyID: string(root, "serverKeyID"), signature: decodeBase64URL(string(root, "signature"), exactBytes: 64))
    }
    public static func encodeNodeEnrollmentClaim(_ value: AccountNodeEnrollmentClaimV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-claim.v1", "claimID": value.claimID.rawValue, "nodeDeviceID": value.nodeDeviceID.rawValue, "signingPublicKey": encodeBase64URL(value.signingPublicKey), "agreementPublicKey": encodeBase64URL(value.agreementPublicKey), "noiseStaticPublicKey": encodeBase64URL(value.noiseStaticPublicKey), "endpointCiphertext": encodeBase64URL(value.endpointCiphertext), "setupVerifier": encodeBase64URL(value.setupVerifier), "endpointDigest": encodeBase64URL(value.endpointDigest), "createdAt": value.createdAt, "expiresAt": value.expiresAt], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeNodeEnrollmentPublicClaim(_ value: AccountNodeEnrollmentPublicClaimV1) throws -> Data {
        var object: [String: Any] = ["kind": "account.sync-node-claim-public.v1", "claimID": value.claimID.rawValue, "nodeDeviceID": value.nodeDeviceID.rawValue, "signingPublicKey": encodeBase64URL(value.signingPublicKey), "agreementPublicKey": encodeBase64URL(value.agreementPublicKey), "noiseStaticPublicKey": encodeBase64URL(value.noiseStaticPublicKey), "endpointDigest": encodeBase64URL(value.endpointDigest), "createdAt": value.createdAt, "expiresAt": value.expiresAt]
        if let endpointCiphertext = value.endpointCiphertext { object["endpointCiphertext"] = encodeBase64URL(endpointCiphertext) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeNodeEnrollmentPublicClaim(_ data: Data) throws -> AccountNodeEnrollmentPublicClaimV1 {
        let root = try object(data, fields: ["kind", "claimID", "nodeDeviceID", "signingPublicKey", "agreementPublicKey", "noiseStaticPublicKey", "endpointDigest", "createdAt", "expiresAt"], optional: ["endpointCiphertext"])
        guard try string(root, "kind") == "account.sync-node-claim-public.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountNodeEnrollmentPublicClaimV1(claimID: NodeEnrollmentClaimID(try string(root, "claimID")), nodeDeviceID: AccountDeviceID(try string(root, "nodeDeviceID")), signingPublicKey: decodeBase64URL(try string(root, "signingPublicKey"), exactBytes: 65), agreementPublicKey: decodeBase64URL(try string(root, "agreementPublicKey"), exactBytes: 65), noiseStaticPublicKey: decodeBase64URL(try string(root, "noiseStaticPublicKey"), exactBytes: 32), endpointCiphertext: root["endpointCiphertext"].map { _ in try decodeBase64URL(try string(root, "endpointCiphertext", maximumBytes: 16 * 1024)) }, endpointDigest: decodeBase64URL(try string(root, "endpointDigest"), exactBytes: 32), createdAt: try string(root, "createdAt"), expiresAt: try string(root, "expiresAt"))
        guard try encodeNodeEnrollmentPublicClaim(value) == data else { throw AccountProtocolError.nonCanonicalValue }
        return value
    }
    public static func decodeNodeEnrollmentClaim(_ data: Data) throws -> AccountNodeEnrollmentClaimV1 {
        let root = try object(data, fields: ["kind", "claimID", "nodeDeviceID", "signingPublicKey", "agreementPublicKey", "noiseStaticPublicKey", "endpointCiphertext", "setupVerifier", "endpointDigest", "createdAt", "expiresAt"])
        guard try string(root, "kind") == "account.sync-node-claim.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountNodeEnrollmentClaimV1(claimID: NodeEnrollmentClaimID(try string(root, "claimID")), nodeDeviceID: AccountDeviceID(try string(root, "nodeDeviceID")), signingPublicKey: decodeBase64URL(try string(root, "signingPublicKey"), exactBytes: 65), agreementPublicKey: decodeBase64URL(try string(root, "agreementPublicKey"), exactBytes: 65), noiseStaticPublicKey: decodeBase64URL(try string(root, "noiseStaticPublicKey"), exactBytes: 32), endpointCiphertext: decodeBase64URL(try string(root, "endpointCiphertext", maximumBytes: 32 * 1024)), setupVerifier: decodeBase64URL(try string(root, "setupVerifier")), endpointDigest: decodeBase64URL(try string(root, "endpointDigest"), exactBytes: 32), createdAt: try string(root, "createdAt"), expiresAt: try string(root, "expiresAt"))
        let canonical = try encodeNodeEnrollmentClaim(value)
        guard (32...64).contains(value.setupVerifier.count), value.endpointCiphertext.count <= 16 * 1024, data == canonical else { throw AccountProtocolError.nonCanonicalValue }; return value
    }
    public static func encodeNodeEnrollmentAdmissionEvidence(_ value: AccountNodeEnrollmentAdmissionEvidenceV1) throws -> Data {
        let stepUp = try JSONSerialization.jsonObject(with: try encodeStepUpAuthorization(value.stepUp))
        return try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-admission-evidence.v1", "accountID": value.accountID.rawValue, "trustEpoch": value.trustEpoch.wireValue, "approverDeviceID": value.approverDeviceID.rawValue, "claimID": value.claimID.rawValue, "nodeDeviceID": value.nodeDeviceID.rawValue, "action": value.action.rawValue, "replacedNodeID": value.replacedNodeID?.rawValue ?? NSNull(), "signingPublicKey": encodeBase64URL(value.signingPublicKey), "agreementPublicKey": encodeBase64URL(value.agreementPublicKey), "noiseStaticPublicKey": encodeBase64URL(value.noiseStaticPublicKey), "endpointDigest": encodeBase64URL(value.endpointDigest), "matchingTranscriptDigest": encodeBase64URL(value.matchingTranscriptDigest), "stepUp": stepUp], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeNodeEnrollmentAdmissionEvidence(_ data: Data) throws -> AccountNodeEnrollmentAdmissionEvidenceV1 {
        let root = try object(data, fields: ["kind", "accountID", "trustEpoch", "approverDeviceID", "claimID", "nodeDeviceID", "action", "replacedNodeID", "signingPublicKey", "agreementPublicKey", "noiseStaticPublicKey", "endpointDigest", "matchingTranscriptDigest", "stepUp"])
        guard try string(root, "kind") == "account.sync-node-admission-evidence.v1", let action = AccountNodeEnrollmentAction(rawValue: try string(root, "action")) else { throw AccountProtocolError.malformedWire }
        let stepUpObject = try object(root["stepUp"] as Any)
        let stepUp = try decodeStepUpAuthorization(try JSONSerialization.data(withJSONObject: stepUpObject, options: [.sortedKeys, .withoutEscapingSlashes]))
        let value = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: PlainpostAccountID(try string(root, "accountID")), trustEpoch: AccountTrustEpoch(wire: try string(root, "trustEpoch")), approverDeviceID: AccountDeviceID(try string(root, "approverDeviceID")), claimID: NodeEnrollmentClaimID(try string(root, "claimID")), nodeDeviceID: AccountDeviceID(try string(root, "nodeDeviceID")), action: action, replacedNodeID: root["replacedNodeID"] is NSNull ? nil : AccountDeviceID(try string(root, "replacedNodeID")), signingPublicKey: decodeBase64URL(try string(root, "signingPublicKey"), exactBytes: 65), agreementPublicKey: decodeBase64URL(try string(root, "agreementPublicKey"), exactBytes: 65), noiseStaticPublicKey: decodeBase64URL(try string(root, "noiseStaticPublicKey"), exactBytes: 32), endpointDigest: decodeBase64URL(try string(root, "endpointDigest"), exactBytes: 32), matchingTranscriptDigest: decodeBase64URL(try string(root, "matchingTranscriptDigest"), exactBytes: 32), stepUp: stepUp)
        let canonical = try encodeNodeEnrollmentAdmissionEvidence(value)
        guard data == canonical else { throw AccountProtocolError.nonCanonicalValue }; return value
    }

    public static func encodeNodeEnrollmentResult(_ value: AccountNodeEnrollmentResultV1) throws -> Data {
        var object = nodeOperationBindingObject(value.binding); object["kind"] = "account.sync-node-enrollment-result.v1"; object["committedAt"] = value.committedAt
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeNodeEnrollmentResult(_ data: Data) throws -> AccountNodeEnrollmentResultV1 {
        let root = try object(data, fields: nodeOperationBindingFields + ["kind", "committedAt"]); guard try string(root, "kind") == "account.sync-node-enrollment-result.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountNodeEnrollmentResultV1(binding: decodeNodeOperationBinding(root), committedAt: string(root, "committedAt")); guard try encodeNodeEnrollmentResult(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value
    }
    public static func encodeNodeOfflineLease(_ value: AccountNodeOfflineLeaseV1) throws -> Data {
        try validateLowSSignature(value.signature)
        var object = nodeOperationBindingObject(value.binding); object["kind"] = "account.sync-node-offline-lease.v1"; object["leaseID"] = value.leaseID; object["issuedAt"] = value.issuedAt; object["expiresAt"] = value.expiresAt; object["serverKeyID"] = value.serverKeyID; object["signature"] = encodeBase64URL(value.signature)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeNodeOfflineLease(_ data: Data) throws -> AccountNodeOfflineLeaseV1 {
        let root = try object(data, fields: nodeOperationBindingFields + ["kind", "leaseID", "issuedAt", "expiresAt", "serverKeyID", "signature"]); guard try string(root, "kind") == "account.sync-node-offline-lease.v1" else { throw AccountProtocolError.malformedWire }
        let signature = try decodeBase64URL(string(root, "signature"), exactBytes: 64); try validateLowSSignature(signature)
        let value = try AccountNodeOfflineLeaseV1(binding: decodeNodeOperationBinding(root), leaseID: string(root, "leaseID"), issuedAt: string(root, "issuedAt"), expiresAt: string(root, "expiresAt"), serverKeyID: string(root, "serverKeyID"), signature: signature); guard try encodeNodeOfflineLease(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value
    }
    public static func encodeNodeRefreshCredential(_ value: AccountNodeRefreshCredentialV1) throws -> Data {
        var object = nodeOperationBindingObject(value.binding); object["kind"] = "account.sync-node-refresh-credential.v1"; object["credentialID"] = value.credentialID; object["issuedAt"] = value.issuedAt; object["expiresAt"] = value.expiresAt; object["credential"] = encodeBase64URL(value.credential)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeNodeRefreshCredential(_ data: Data) throws -> AccountNodeRefreshCredentialV1 {
        let root = try object(data, fields: nodeOperationBindingFields + ["kind", "credentialID", "issuedAt", "expiresAt", "credential"]); guard try string(root, "kind") == "account.sync-node-refresh-credential.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountNodeRefreshCredentialV1(binding: decodeNodeOperationBinding(root), credentialID: string(root, "credentialID"), issuedAt: string(root, "issuedAt"), expiresAt: string(root, "expiresAt"), credential: decodeBase64URL(string(root, "credential"), exactBytes: 32)); guard try encodeNodeRefreshCredential(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value
    }

    public static func encodeSyncNodeCleanupCapability(_ value: AccountSyncNodeCleanupCapabilityV1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-cleanup-capability.v1", "accountID": value.accountID.rawValue, "claimID": value.claimID.rawValue, "nodeDeviceID": value.nodeDeviceID.rawValue, "targetHandle": encodeBase64URL(value.targetHandle), "cleanupCredential": encodeBase64URL(value.cleanupCredential), "deletionGeneration": value.deletionGeneration.wireValue, "issuedAt": value.issuedAt], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func decodeSyncNodeCleanupCapability(_ data: Data) throws -> AccountSyncNodeCleanupCapabilityV1 {
        let root = try object(data, fields: ["kind", "accountID", "claimID", "nodeDeviceID", "targetHandle", "cleanupCredential", "deletionGeneration", "issuedAt"])
        guard try string(root, "kind") == "account.sync-node-cleanup-capability.v1" else { throw AccountProtocolError.malformedWire }
        let value = try AccountSyncNodeCleanupCapabilityV1(accountID: PlainpostAccountID(try string(root, "accountID")), claimID: NodeEnrollmentClaimID(try string(root, "claimID")), nodeDeviceID: AccountDeviceID(try string(root, "nodeDeviceID")), targetHandle: decodeBase64URL(try string(root, "targetHandle"), exactBytes: 32), cleanupCredential: decodeBase64URL(try string(root, "cleanupCredential"), exactBytes: 32), deletionGeneration: PositiveUInt64(wire: try string(root, "deletionGeneration")), issuedAt: try string(root, "issuedAt"))
        guard try encodeSyncNodeCleanupCapability(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value
    }

    public static func decodeNodeEnrollmentAdmissionResponseV2(_ data: Data) throws -> AccountNodeEnrollmentAdmissionResponseV2 {
        let root = try object(data, fields: ["kind", "result", "refreshCredential", "offlineLease", "cleanupCapability"])
        guard try string(root, "kind") == "account.sync-node-admission-response.v2" else { throw AccountProtocolError.malformedWire }
        let resultWire = try JSONSerialization.data(withJSONObject: try object(root, "result", fields: nodeOperationBindingV2Fields + ["kind", "committedAt"]), options: [.sortedKeys, .withoutEscapingSlashes])
        let refreshWire = try JSONSerialization.data(withJSONObject: try object(root, "refreshCredential", fields: nodeOperationBindingV2Fields + ["kind", "credentialID", "issuedAt", "expiresAt", "credential"]), options: [.sortedKeys, .withoutEscapingSlashes])
        let leaseWire = try JSONSerialization.data(withJSONObject: try object(root, "offlineLease", fields: nodeOperationBindingV2Fields + ["kind", "leaseID", "issuedAt", "expiresAt", "serverKeyID", "signature"]), options: [.sortedKeys, .withoutEscapingSlashes])
        let capabilityWire = try JSONSerialization.data(withJSONObject: try object(root, "cleanupCapability", fields: ["kind", "accountID", "claimID", "nodeDeviceID", "targetHandle", "cleanupCredential", "deletionGeneration", "issuedAt"]), options: [.sortedKeys, .withoutEscapingSlashes])
        let value = try AccountNodeEnrollmentAdmissionResponseV2(result: try decodeNodeEnrollmentResultV2(resultWire), refreshCredential: try decodeNodeRefreshCredentialV2(refreshWire), offlineLease: try decodeNodeOfflineLeaseV2(leaseWire), cleanupCapability: try decodeSyncNodeCleanupCapability(capabilityWire))
        guard try encodeNodeEnrollmentAdmissionResponseV2(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value
    }
    public static func encodeNodeEnrollmentAdmissionResponseV2(_ value: AccountNodeEnrollmentAdmissionResponseV2) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "account.sync-node-admission-response.v2", "result": try JSONSerialization.jsonObject(with: encodeNodeEnrollmentResultV2(value.result)), "refreshCredential": try JSONSerialization.jsonObject(with: encodeNodeRefreshCredentialV2(value.refreshCredential)), "offlineLease": try JSONSerialization.jsonObject(with: encodeNodeOfflineLeaseV2(value.offlineLease)), "cleanupCapability": try JSONSerialization.jsonObject(with: encodeSyncNodeCleanupCapability(value.cleanupCapability))], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func encodeNodeEnrollmentResultV2(_ value: AccountNodeEnrollmentResultV2) throws -> Data { var o = nodeOperationBindingV2Object(value.binding); o["kind"] = "account.sync-node-enrollment-result.v2"; o["committedAt"] = value.committedAt; return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func decodeNodeEnrollmentResultV2(_ data: Data) throws -> AccountNodeEnrollmentResultV2 { let root = try object(data, fields: nodeOperationBindingV2Fields + ["kind", "committedAt"]); guard try string(root, "kind") == "account.sync-node-enrollment-result.v2" else { throw AccountProtocolError.malformedWire }; let value = try AccountNodeEnrollmentResultV2(binding: decodeNodeOperationBindingV2(root), committedAt: try string(root, "committedAt")); guard try encodeNodeEnrollmentResultV2(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value }
    public static func encodeNodeOfflineLeaseV2(_ value: AccountNodeOfflineLeaseV2) throws -> Data { var o = nodeOperationBindingV2Object(value.binding); o["kind"] = "account.sync-node-offline-lease.v2"; o["leaseID"] = value.leaseID; o["issuedAt"] = value.issuedAt; o["expiresAt"] = value.expiresAt; o["serverKeyID"] = value.serverKeyID; o["signature"] = encodeBase64URL(value.signature); return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func decodeNodeOfflineLeaseV2(_ data: Data) throws -> AccountNodeOfflineLeaseV2 { let root = try object(data, fields: nodeOperationBindingV2Fields + ["kind", "leaseID", "issuedAt", "expiresAt", "serverKeyID", "signature"]); guard try string(root, "kind") == "account.sync-node-offline-lease.v2" else { throw AccountProtocolError.malformedWire }; let value = try AccountNodeOfflineLeaseV2(binding: decodeNodeOperationBindingV2(root), leaseID: try string(root, "leaseID"), issuedAt: try string(root, "issuedAt"), expiresAt: try string(root, "expiresAt"), serverKeyID: try string(root, "serverKeyID"), signature: decodeBase64URL(try string(root, "signature"), exactBytes: 64)); guard try encodeNodeOfflineLeaseV2(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value }
    public static func encodeNodeRefreshCredentialV2(_ value: AccountNodeRefreshCredentialV2) throws -> Data { var o = nodeOperationBindingV2Object(value.binding); o["kind"] = "account.sync-node-refresh-credential.v2"; o["credentialID"] = value.credentialID; o["issuedAt"] = value.issuedAt; o["expiresAt"] = value.expiresAt; o["credential"] = encodeBase64URL(value.credential); return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    public static func decodeNodeRefreshCredentialV2(_ data: Data) throws -> AccountNodeRefreshCredentialV2 { let root = try object(data, fields: nodeOperationBindingV2Fields + ["kind", "credentialID", "issuedAt", "expiresAt", "credential"]); guard try string(root, "kind") == "account.sync-node-refresh-credential.v2" else { throw AccountProtocolError.malformedWire }; let value = try AccountNodeRefreshCredentialV2(binding: decodeNodeOperationBindingV2(root), credentialID: try string(root, "credentialID"), issuedAt: try string(root, "issuedAt"), expiresAt: try string(root, "expiresAt"), credential: decodeBase64URL(try string(root, "credential"), exactBytes: 32)); guard try encodeNodeRefreshCredentialV2(value) == data else { throw AccountProtocolError.nonCanonicalValue }; return value }

    private static let nodeOperationBindingFields = ["accountID", "trustEpoch", "claimID", "nodeDeviceID", "centralAudience", "action", "replacedNodeID", "replacementRevocationDigest", "admissionEvidenceDigest", "issuanceDigest"]
    private static let nodeOperationBindingV2Fields = nodeOperationBindingFields + ["cleanupCapabilityDigest"]
    private static func nodeOperationBindingObject(_ value: AccountNodeOperationBindingV1) -> [String: Any] {
        ["accountID": value.accountID.rawValue, "trustEpoch": value.trustEpoch.wireValue, "claimID": value.claimID.rawValue, "nodeDeviceID": value.nodeDeviceID.rawValue, "centralAudience": value.centralAudience, "action": value.action.rawValue, "replacedNodeID": value.replacedNodeID?.rawValue ?? NSNull(), "replacementRevocationDigest": value.replacementRevocationDigest.map(encodeBase64URL) ?? NSNull(), "admissionEvidenceDigest": encodeBase64URL(value.admissionEvidenceDigest), "issuanceDigest": encodeBase64URL(value.issuanceDigest)]
    }
    private static func decodeNodeOperationBinding(_ root: [String: Any]) throws -> AccountNodeOperationBindingV1 {
        guard let action = AccountNodeEnrollmentAction(rawValue: try string(root, "action")) else { throw AccountProtocolError.malformedWire }
        return try AccountNodeOperationBindingV1(accountID: PlainpostAccountID(string(root, "accountID")), trustEpoch: AccountTrustEpoch(wire: string(root, "trustEpoch")), claimID: NodeEnrollmentClaimID(string(root, "claimID")), nodeDeviceID: AccountDeviceID(string(root, "nodeDeviceID")), centralAudience: string(root, "centralAudience"), action: action, replacedNodeID: root["replacedNodeID"] is NSNull ? nil : AccountDeviceID(string(root, "replacedNodeID")), replacementRevocationDigest: root["replacementRevocationDigest"] is NSNull ? nil : decodeBase64URL(string(root, "replacementRevocationDigest"), exactBytes: 32), admissionEvidenceDigest: decodeBase64URL(string(root, "admissionEvidenceDigest"), exactBytes: 32), issuanceDigest: decodeBase64URL(string(root, "issuanceDigest"), exactBytes: 32))
    }
    private static func nodeOperationBindingV2Object(_ value: AccountNodeOperationBindingV2) -> [String: Any] { var o = nodeOperationBindingObject(value.base); o["cleanupCapabilityDigest"] = encodeBase64URL(value.cleanupCapabilityDigest); return o }
    private static func decodeNodeOperationBindingV2(_ root: [String: Any]) throws -> AccountNodeOperationBindingV2 { try AccountNodeOperationBindingV2(base: decodeNodeOperationBinding(root), cleanupCapabilityDigest: decodeBase64URL(try string(root, "cleanupCapabilityDigest"), exactBytes: 32)) }

    private static func optionalBase64(_ root: [String: Any], _ key: String) throws -> Data? { guard root[key] != nil else { return nil }; return try decodeBase64URL(try string(root, key), exactBytes: 32) }
    private static func accountKeyPurpose(_ value: String) throws -> AccountKeyPurpose { guard let result = AccountKeyPurpose(rawValue: value) else { throw AccountProtocolError.malformedWire }; return result }
    private static func accountKeyStatus(_ value: String) throws -> AccountKeyStatus { guard let result = AccountKeyStatus(rawValue: value) else { throw AccountProtocolError.malformedWire }; return result }
    private static func object(
        _ data: Data,
        fields: [String],
        optional: [String] = [],
        maximumBytes: Int = maxBodyBytes,
        scannerArrayLimits: [String: Int] = [:]
    ) throws -> [String: Any] {
        guard data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else { throw AccountProtocolError.oversized }
        try DuplicateJSONKeyScanner.validate(data, arrayLimits: scannerArrayLimits)
        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { throw AccountProtocolError.malformedWire }
        return try closed(object, fields: fields, optional: optional)
    }
    private static func object(_ root: [String: Any], _ key: String, fields: [String], optional: [String] = []) throws -> [String: Any] { guard let raw = root[key] as? [String: Any] else { throw AccountProtocolError.malformedWire }; return try closed(raw, fields: fields, optional: optional) }
    private static func object(_ value: Any, fields: [String] = [], optional: [String] = []) throws -> [String: Any] { guard let root = value as? [String: Any] else { throw AccountProtocolError.malformedWire }; return fields.isEmpty ? root : try closed(root, fields: fields, optional: optional) }
    private static func closed(_ root: [String: Any], fields: [String], optional: [String]) throws -> [String: Any] { let expected = Set(fields + optional); guard root.keys.allSatisfy(expected.contains), root.keys.count == Set(root.keys).count, fields.allSatisfy({ root[$0] != nil }) else { throw AccountProtocolError.malformedWire }; return root }
    private static func string(_ root: [String: Any], _ key: String, maximumBytes: Int = 16_384) throws -> String { guard let value = root[key] as? String, value.lengthOfBytes(using: .utf8) <= maximumBytes else { throw AccountProtocolError.malformedWire }; return value }
    private static func array(_ root: [String: Any], _ key: String, maximumCount: Int = 32) throws -> [Any] { guard let value = root[key] as? [Any], value.count <= maximumCount else { throw AccountProtocolError.malformedWire }; return value }
    private static func boolean(_ root: [String: Any], _ key: String) throws -> Bool { guard let value = root[key] as? Bool else { throw AccountProtocolError.malformedWire }; return value }
    private static func encodeBundle(_ value: AccountPublicKeyBundle) -> [String: Any] { ["signingKey": encodeBase64URL(value.signingKey), "agreementKey": encodeBase64URL(value.agreementKey)] }
    private static func encodePendingDevice(_ value: AccountPendingDevice) -> [String: Any] { ["kind": "account.pending-device.v1", "accountID": value.accountID.rawValue, "deviceID": value.deviceID.rawValue, "platform": value.platform.rawValue, "publicBundle": encodeBundle(value.publicBundle), "exchangeRequestDigest": encodeBase64URL(value.exchangeRequestDigest), "createdAt": value.createdAt, "expiresAt": value.expiresAt] }
    private static func encodeOffer(_ value: TrustHandshakeOfferV1) -> [String: Any] { ["accountID": value.accountID.rawValue, "existingDeviceID": value.existingDeviceID.rawValue, "pendingDeviceID": value.pendingDeviceID.rawValue, "existingPublicBundle": encodeBundle(value.existingPublicBundle), "pendingPublicBundle": encodeBundle(value.pendingPublicBundle), "existingNonce": encodeBase64URL(value.existingNonce), "createdAtUnixMilliseconds": value.createdAtUnixMilliseconds.wireValue, "expiresAtUnixMilliseconds": value.expiresAtUnixMilliseconds.wireValue] }
    private static func encodeRecoveryAuthorization(_ value: AccountRecoveryAuthorization) -> [String: Any] { ["kind": "account.recovery-authorization.v1", "authorizationID": value.authorizationID.rawValue, "accountID": value.accountID.rawValue, "epoch": value.epoch.wireValue, "deviceID": value.deviceID.rawValue, "platform": value.platform.rawValue, "publicBundle": encodeBundle(value.publicBundle), "priorCommitDigest": encodeBase64URL(value.priorCommitDigest), "exchangeRequestDigest": encodeBase64URL(value.exchangeRequestDigest), "issuedAt": value.issuedAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "serverSignature": encodeBase64URL(value.serverSignature)] }
    private static func encodeManifestObject(_ value: AccountBootstrapManifest) -> [String: Any] { ["kind": "central.bootstrap-key-manifest.v1", "rootKeyID": value.rootKeyID, "manifestVersion": value.manifestVersion.wireValue, "notBefore": value.notBefore, "expiresAt": value.expiresAt, "previousManifestDigest": value.previousManifestDigest.map(encodeBase64URL) ?? NSNull(), "keys": value.keys.map { key in ["keyID": key.keyID, "purpose": key.purpose.rawValue, "publicKey": encodeBase64URL(key.publicKey), "notBefore": key.notBefore, "expiresAt": key.expiresAt, "status": key.status.rawValue] }, "rootSignature": encodeBase64URL(value.rootSignature)] }
    private static func encodeAdmissionEvidence(_ value: AccountTrustAdmissionEvidenceV1) -> [String: Any] { ["kind": "account.trust-admission-evidence.v1", "pendingDevice": encodePendingDevice(value.pendingDevice), "response": ["offer": encodeOffer(value.response.offer), "pendingNonce": encodeBase64URL(value.response.pendingNonce)]] }
    private static func encodeRecoveryEvidence(_ value: AccountTrustRecoveryEvidenceV1) -> [String: Any] { ["kind": "account.trust-recovery-evidence.v1", "authorization": encodeRecoveryAuthorization(value.authorization), "historicalManifest": encodeManifestObject(value.historicalManifest)] }
    private static func encodeTrustPageCheckpoint(_ value: AccountTrustPageCheckpointV1) -> [String: Any] { ["epoch": value.epoch.wireValue, "revision": value.revision.wireValue, "commitDigest": encodeBase64URL(value.commitDigest)] }
    private static func encodeTrustCursorObject(_ value: AccountTrustCursorV1) -> [String: Any] {
        let after: [String: Any]
        switch value.after { case .genesis: after = ["kind": "genesis"]; case .checkpoint(let checkpoint): after = encodeTrustPageCheckpoint(checkpoint) }
        return ["kind": "account.trust-cursor.v1", "accountID": value.accountID.rawValue, "after": after, "snapshotHead": encodeTrustPageCheckpoint(value.snapshotHead), "issuedAt": value.issuedAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "signature": encodeBase64URL(value.signature)]
    }
    private static func encodeChallenge(_ value: AccountBootstrapChallenge) -> [String: Any] { ["kind": "account.bootstrap-challenge.v1", "challengeID": value.challengeID.rawValue, "challengeNonce": encodeBase64URL(value.challengeNonce), "exchangeRequestDigest": encodeBase64URL(value.exchangeRequestDigest), "accountID": value.accountID.rawValue, "deviceID": value.deviceID.rawValue, "mode": value.mode.rawValue, "platform": value.platform.rawValue, "publicBundle": encodeBundle(value.publicBundle), "createdAt": value.createdAt, "expiresAt": value.expiresAt, "serverKeyID": value.serverKeyID, "serverSignature": encodeBase64URL(value.serverSignature)] }
    private static func encodeCommit(_ value: AccountTrustStateCommit) -> [String: Any] { ["kind": "account.trust-state-commit.v1", "state": encodeState(value.state), "keyPackages": value.keyPackages.map(encodePackage)] }
    private static func encodeState(_ value: AccountTrustState) -> [String: Any] { ["accountID": value.accountID.rawValue, "epoch": value.epoch.wireValue, "revision": value.revision.wireValue, "previousCommitDigest": value.previousCommitDigest.map(encodeBase64URL) ?? NSNull(), "transition": encodeTransition(value.transition), "keyGeneration": value.keyGeneration.wireValue, "keyCommitment": encodeBase64URL(value.keyCommitment), "members": value.members.map(encodeRecord), "signerDeviceID": value.signerDeviceID.rawValue, "signature": encodeBase64URL(value.signature)] }
    private static func encodeTransition(_ value: AccountTrustTransition) -> [String: Any] { var result: [String: Any] = ["kind": value.kind.rawValue, "targetDeviceIDs": value.targetDeviceIDs.map(\.rawValue), "priorRecordDigests": value.priorRecordDigests.map { ["deviceID": $0.deviceID.rawValue, "recordDigest": encodeBase64URL($0.recordDigest)] }]; if let digest = value.handshakeDigest { result["handshakeDigest"] = encodeBase64URL(digest) }; if let digest = value.pendingDeviceDigest { result["pendingDeviceDigest"] = encodeBase64URL(digest) }; if let digest = value.recoveryAuthorizationDigest { result["recoveryAuthorizationDigest"] = encodeBase64URL(digest) }; return result }
    private static func encodeRecord(_ value: AccountDeviceTrustRecord) -> [String: Any] { ["accountID": value.accountID.rawValue, "epoch": value.epoch.wireValue, "revision": value.revision.wireValue, "deviceID": value.deviceID.rawValue, "platform": value.platform.rawValue, "publicBundle": encodeBundle(value.publicBundle), "signerDeviceID": value.signerDeviceID.rawValue, "signature": encodeBase64URL(value.signature)] }
    private static func encodePackage(_ value: AccountGroupKeyPackage) -> [String: Any] { ["kind": "account.group-key-package.v1", "accountID": value.accountID.rawValue, "epoch": value.epoch.wireValue, "stateRevision": value.stateRevision.wireValue, "keyGeneration": value.keyGeneration.wireValue, "stateDigest": encodeBase64URL(value.stateDigest), "keyCommitment": encodeBase64URL(value.keyCommitment), "recipientDeviceID": value.recipientDeviceID.rawValue, "senderDeviceID": value.senderDeviceID.rawValue, "senderEphemeralPublicKey": encodeBase64URL(value.senderEphemeralPublicKey), "nonce": encodeBase64URL(value.nonce), "encryptedKeyMaterial": encodeBase64URL(value.encryptedKeyMaterial), "signature": encodeBase64URL(value.signature)] }
}

private enum DuplicateJSONKeyScanner {
    static func validate(_ data: Data, arrayLimits: [String: Int] = [:]) throws {
        var parser = Parser(bytes: Array(data), arrayLimits: arrayLimits)
        try parser.value(depth: 0, path: [])
        try parser.space()
        guard parser.position == parser.bytes.count else { throw AccountProtocolError.malformedWire }
    }
    private struct Parser {
        let bytes: [UInt8]
        let arrayLimits: [String: Int]
        var position = 0
        mutating func space() throws { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func value(depth: Int, path: [String]) throws { guard depth < 32 else { throw AccountProtocolError.oversized }; try space(); guard position < bytes.count else { throw AccountProtocolError.malformedWire }; switch bytes[position] { case 123: try object(depth: depth + 1, path: path); case 91: try array(depth: depth + 1, path: path); case 34: _ = try string(); case 116: try literal("true"); case 102: try literal("false"); case 110: try literal("null"); case 45, 48...57: try number(); default: throw AccountProtocolError.malformedWire } }
        mutating func object(depth: Int, path: [String]) throws { position += 1; try space(); var keys = Set<String>(); if position < bytes.count && bytes[position] == 125 { position += 1; return }; while true { try space(); let key = try string(); guard keys.insert(key).inserted else { throw AccountProtocolError.malformedWire }; try space(); guard consume(58) else { throw AccountProtocolError.malformedWire }; try value(depth: depth, path: path + [key]); try space(); if consume(125) { return }; guard consume(44) else { throw AccountProtocolError.malformedWire } } }
        mutating func array(depth: Int, path: [String]) throws { position += 1; try space(); if position < bytes.count && bytes[position] == 93 { position += 1; return }; let limit = arrayLimits[path.joined(separator: ".")] ?? 64; var count = 0; while true { count += 1; guard count <= limit else { throw AccountProtocolError.oversized }; try value(depth: depth, path: path + ["[]"]); try space(); if consume(93) { return }; guard consume(44) else { throw AccountProtocolError.malformedWire } } }
        mutating func string() throws -> String { guard consume(34) else { throw AccountProtocolError.malformedWire }; let start = position - 1; var escaped = false; while position < bytes.count { let byte = bytes[position]; position += 1; if escaped { guard [34, 92, 47, 98, 102, 110, 114, 116, 117].contains(byte) else { throw AccountProtocolError.malformedWire }; if byte == 117 { guard position + 4 <= bytes.count, bytes[position..<position + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw AccountProtocolError.malformedWire }; position += 4 }; escaped = false; continue }; if byte == 92 { escaped = true; continue }; if byte == 34 { let raw = Data(bytes[start..<position]); guard let string = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else { throw AccountProtocolError.malformedWire }; return string }; guard byte >= 32 else { throw AccountProtocolError.malformedWire } }; throw AccountProtocolError.malformedWire }
        mutating func literal(_ value: String) throws { let value = Array(value.utf8); guard position + value.count <= bytes.count, Array(bytes[position..<position + value.count]) == value else { throw AccountProtocolError.malformedWire }; position += value.count }
        mutating func number() throws { if consume(45) {} ; guard position < bytes.count else { throw AccountProtocolError.malformedWire }; if bytes[position] == 48 { position += 1 } else { guard (49...57).contains(bytes[position]) else { throw AccountProtocolError.malformedWire }; while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 } }; if consume(46) { guard position < bytes.count && (48...57).contains(bytes[position]) else { throw AccountProtocolError.malformedWire }; while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 } }; if position < bytes.count && [69, 101].contains(bytes[position]) { position += 1; _ = consume(43) || consume(45); guard position < bytes.count && (48...57).contains(bytes[position]) else { throw AccountProtocolError.malformedWire }; while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 } } }
        mutating func consume(_ value: UInt8) -> Bool { guard position < bytes.count && bytes[position] == value else { return false }; position += 1; return true }
    }
}

private extension Data {
    init?(hex: String) { guard hex.count.isMultiple(of: 2) else { return nil }; var result = Data(); var index = hex.startIndex; while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }; result.append(value); index = next }; self = result }
}
