import Foundation

public enum AccountSessionKeyPurpose: String, Codable, Hashable, Sendable {
    case access
    case offlineLease = "offline_lease"
}

public enum AccountSessionKeyStatus: String, Codable, Hashable, Sendable {
    case active
    case retired
}

public struct AccountSessionManifestKey: Hashable, Sendable {
    public let keyID: String
    public let purpose: AccountSessionKeyPurpose
    public let publicKey: Data
    public let notBefore: String
    public let expiresAt: String
    public let status: AccountSessionKeyStatus

    public init(keyID: String, purpose: AccountSessionKeyPurpose, publicKey: Data, notBefore: String, expiresAt: String, status: AccountSessionKeyStatus) throws {
        guard !keyID.isEmpty, keyID.utf8.count <= 128,
              AccountP256SEC1Validator.isValidUncompressedPoint(publicKey),
              let start = AccountWireCodec.parseTimestamp(notBefore),
              let end = AccountWireCodec.parseTimestamp(expiresAt), start < end
        else { throw AccountProtocolError.malformedWire }
        self.keyID = keyID
        self.purpose = purpose
        self.publicKey = publicKey
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.status = status
    }
}

public struct AccountSessionManifest: Hashable, Sendable {
    public let rootKeyID: String
    public let manifestVersion: PositiveUInt64
    public let notBefore: String
    public let expiresAt: String
    public let keys: [AccountSessionManifestKey]
    public let rootSignature: Data

    public init(rootKeyID: String, manifestVersion: PositiveUInt64, notBefore: String, expiresAt: String, keys: [AccountSessionManifestKey], rootSignature: Data) throws {
        guard AccountWireCodec.isKeyID(rootKeyID),
              rootSignature.count == 64,
              (2 ... 16).contains(keys.count),
              keys.map(\.keyID) == keys.map(\.keyID).sorted(),
              Set(keys.map(\.keyID)).count == keys.count,
              Set(keys.map(\.publicKey)).count == keys.count,
              let start = AccountWireCodec.parseTimestamp(notBefore),
              let end = AccountWireCodec.parseTimestamp(expiresAt), start < end,
              keys.allSatisfy({ key in
                  guard let keyStart = AccountWireCodec.parseTimestamp(key.notBefore),
                        let keyEnd = AccountWireCodec.parseTimestamp(key.expiresAt)
                  else { return false }
                  return keyStart >= start && keyStart < keyEnd && keyEnd <= end
              })
        else { throw AccountProtocolError.malformedWire }
        self.rootKeyID = rootKeyID
        self.manifestVersion = manifestVersion
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.keys = keys
        self.rootSignature = rootSignature
    }
}

public struct AccountSessionManifestResponse: Hashable, Sendable {
    public let current: AccountSessionManifest
    public init(current: AccountSessionManifest) { self.current = current }
}

public enum AccountSessionManifestCodec {
    public static func decodeResponse(_ data: Data) throws -> AccountSessionManifestResponse {
        try AccountWireCodec.validateUniqueJSONKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["kind", "current"],
              root["kind"] as? String == "account.session-key-manifest-response.v1",
              let current = root["current"] as? [String: Any]
        else { throw AccountProtocolError.malformedWire }
        return AccountSessionManifestResponse(current: try decodeManifest(current))
    }

    public static func encodeResponse(_ response: AccountSessionManifestResponse) throws -> Data {
        try AccountWireCodec.validateLowSSignature(response.current.rootSignature)
        return try JSONSerialization.data(
            withJSONObject: [
                "kind": "account.session-key-manifest-response.v1",
                "current": manifestObject(response.current),
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func transcript(_ manifest: AccountSessionManifest) -> Data {
        var values = [
            Data("Plainpost.SessionKeyManifest.v1".utf8),
            unsigned16(1),
            Data(manifest.rootKeyID.utf8),
            unsigned64(manifest.manifestVersion.value),
            Data(manifest.notBefore.utf8),
            Data(manifest.expiresAt.utf8),
            unsigned16(UInt16(manifest.keys.count)),
        ]
        for key in manifest.keys {
            values += [
                Data(key.keyID.utf8), Data(key.purpose.rawValue.utf8), key.publicKey,
                Data(key.notBefore.utf8), Data(key.expiresAt.utf8), Data(key.status.rawValue.utf8),
            ]
        }
        return AccountTranscript.parts(values)
    }

    private static func decodeManifest(_ object: [String: Any]) throws -> AccountSessionManifest {
        guard Set(object.keys) == ["kind", "rootKeyID", "manifestVersion", "notBefore", "expiresAt", "keys", "rootSignature"],
              object["kind"] as? String == "account.session-key-manifest.v1",
              let rootKeyID = object["rootKeyID"] as? String,
              let versionText = object["manifestVersion"] as? String,
              let version = try? PositiveUInt64(wire: versionText),
              let notBefore = object["notBefore"] as? String,
              let expiresAt = object["expiresAt"] as? String,
              let rawKeys = object["keys"] as? [[String: Any]],
              let signatureText = object["rootSignature"] as? String
        else { throw AccountProtocolError.malformedWire }
        let signature = try AccountWireCodec.decodeBase64URL(signatureText, exactBytes: 64)
        try AccountWireCodec.validateLowSSignature(signature)
        let keys = try rawKeys.map(decodeKey)
        return try AccountSessionManifest(rootKeyID: rootKeyID, manifestVersion: version, notBefore: notBefore, expiresAt: expiresAt, keys: keys, rootSignature: signature)
    }

    private static func decodeKey(_ object: [String: Any]) throws -> AccountSessionManifestKey {
        guard Set(object.keys) == ["keyID", "purpose", "publicKey", "notBefore", "expiresAt", "status"],
              let keyID = object["keyID"] as? String,
              let purposeText = object["purpose"] as? String,
              let purpose = AccountSessionKeyPurpose(rawValue: purposeText),
              let publicText = object["publicKey"] as? String,
              let notBefore = object["notBefore"] as? String,
              let expiresAt = object["expiresAt"] as? String,
              let statusText = object["status"] as? String,
              let status = AccountSessionKeyStatus(rawValue: statusText)
        else { throw AccountProtocolError.malformedWire }
        return try AccountSessionManifestKey(
            keyID: keyID,
            purpose: purpose,
            publicKey: AccountWireCodec.decodeBase64URL(publicText, exactBytes: 65),
            notBefore: notBefore,
            expiresAt: expiresAt,
            status: status
        )
    }

    private static func manifestObject(_ manifest: AccountSessionManifest) -> [String: Any] {
        [
            "kind": "account.session-key-manifest.v1",
            "rootKeyID": manifest.rootKeyID,
            "manifestVersion": manifest.manifestVersion.wireValue,
            "notBefore": manifest.notBefore,
            "expiresAt": manifest.expiresAt,
            "keys": manifest.keys.map { key in
                [
                    "keyID": key.keyID,
                    "purpose": key.purpose.rawValue,
                    "publicKey": AccountWireCodec.encodeBase64URL(key.publicKey),
                    "notBefore": key.notBefore,
                    "expiresAt": key.expiresAt,
                    "status": key.status.rawValue,
                ]
            },
            "rootSignature": AccountWireCodec.encodeBase64URL(manifest.rootSignature),
        ]
    }

    private static func unsigned16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func unsigned64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
