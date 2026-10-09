import CryptoKit
import Foundation

/// A bounded, integrity-checked credential record set used only to hand test
/// credentials to a spawned child process. It intentionally has no disk,
/// environment, or argument representation.
public enum CredentialCapabilityCodec {
    public static let maximumRecordCount = 32
    public static let maximumKeyLength = 512
    public static let maximumSecretLength = 16 * 1024
    public static let maximumPayloadLength = 128 * 1024

    private static let magic = Data([0x50, 0x50, 0x43, 0x56]) // PPCV
    private static let version: UInt8 = 1
    private static let checksumLength = 32

    public static func encode(records: [CredentialRecordKey: Data]) throws -> Data {
        try validate(records: records)
        return try encodeRecords(records.sorted { $0.key.rawValue < $1.key.rawValue })
    }

    public static func decode(_ encoded: Data) throws -> [CredentialRecordKey: Data] {
        guard encoded.count >= magic.count + 1 + 2 + checksumLength,
              encoded.count <= maximumPayloadLength else {
            throw CredentialVaultError.ciphertextInvalid
        }
        let body = encoded.dropLast(checksumLength)
        let expectedChecksum = Data(SHA256.hash(data: body))
        guard expectedChecksum == encoded.suffix(checksumLength) else {
            throw CredentialVaultError.ciphertextInvalid
        }

        var cursor = Data(body)
        guard cursor.consume(magic.count) == magic,
              cursor.consumeByte() == version,
              let recordCount = cursor.consumeUInt16(),
              recordCount <= maximumRecordCount else {
            throw CredentialVaultError.ciphertextInvalid
        }

        var records: [CredentialRecordKey: Data] = [:]
        for _ in 0..<recordCount {
            guard let keyLength = cursor.consumeUInt16(),
                  keyLength > 0,
                  keyLength <= maximumKeyLength,
                  let keyData = cursor.consume(Int(keyLength)),
                  let keyString = String(data: keyData, encoding: .utf8),
                  let secretLength = cursor.consumeUInt32(),
                  secretLength <= maximumSecretLength,
                  let secret = cursor.consume(Int(secretLength)) else {
                throw CredentialVaultError.ciphertextInvalid
            }
            let key = CredentialRecordKey(rawValue: keyString)
            guard isPermitted(key), records[key] == nil else {
                throw CredentialVaultError.ciphertextInvalid
            }
            records[key] = secret
        }
        guard cursor.isEmpty else {
            throw CredentialVaultError.ciphertextInvalid
        }
        return records
    }

    static func encodeUncheckedForTesting(_ records: [(CredentialRecordKey, Data)]) throws -> Data {
        try encodeRecords(records)
    }

    private static func validate(records: [CredentialRecordKey: Data]) throws {
        guard records.count <= maximumRecordCount,
              records.allSatisfy({ isPermitted($0.key) && $0.value.count <= maximumSecretLength }) else {
            throw CredentialVaultError.ciphertextInvalid
        }
    }

    private static func isPermitted(_ key: CredentialRecordKey) -> Bool {
        let suffixes = [":imap-password", ":smtp-password", ":google-refresh-token", ":microsoft-refresh-token"]
        guard key.rawValue.utf8.count <= maximumKeyLength,
              key.rawValue.hasPrefix("account:"),
              let suffix = suffixes.first(where: key.rawValue.hasSuffix) else {
            return false
        }
        let account = key.rawValue.dropFirst("account:".count).dropLast(suffix.count)
        return !account.isEmpty
    }

    private static func encodeRecords(_ records: [(CredentialRecordKey, Data)]) throws -> Data {
        guard records.count <= maximumRecordCount else {
            throw CredentialVaultError.ciphertextInvalid
        }
        var body = magic
        body.append(version)
        body.appendUInt16(UInt16(records.count))
        for (key, secret) in records {
            let keyData = Data(key.rawValue.utf8)
            guard keyData.count > 0,
                  keyData.count <= maximumKeyLength,
                  secret.count <= maximumSecretLength else {
                throw CredentialVaultError.ciphertextInvalid
            }
            body.appendUInt16(UInt16(keyData.count))
            body.append(keyData)
            body.appendUInt32(UInt32(secret.count))
            body.append(secret)
        }
        guard body.count + checksumLength <= maximumPayloadLength else {
            throw CredentialVaultError.ciphertextInvalid
        }
        body.append(Data(SHA256.hash(data: body)))
        return body
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func consume(_ count: Int) -> Data? {
        guard count >= 0, self.count >= count else { return nil }
        let value = prefix(count)
        removeFirst(count)
        return Data(value)
    }

    mutating func consumeByte() -> UInt8? {
        guard let value = first else { return nil }
        removeFirst()
        return value
    }

    mutating func consumeUInt16() -> UInt16? {
        guard let bytes = consume(2) else { return nil }
        return (UInt16(bytes[bytes.startIndex]) << 8) | UInt16(bytes[bytes.index(after: bytes.startIndex)])
    }

    mutating func consumeUInt32() -> UInt32? {
        guard let bytes = consume(4) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
