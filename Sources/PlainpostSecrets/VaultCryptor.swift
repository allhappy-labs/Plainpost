import CryptoKit
import Foundation

public struct SealedCredential: Equatable, Sendable {
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

public struct VaultCryptor: Sendable {
    private static let currentVersion = 1

    public init() {}

    public func seal(
        _ plaintext: Data,
        for recordKey: CredentialRecordKey,
        using masterKey: SymmetricKey
    ) throws -> SealedCredential {
        try validateMasterKey(masterKey)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: masterKey,
            nonce: AES.GCM.Nonce(),
            authenticating: associatedData(for: recordKey)
        )
        guard let combined = sealedBox.combined else {
            throw CredentialVaultError.ciphertextInvalid
        }

        return SealedCredential(combined: Data([UInt8(Self.currentVersion)]) + combined)
    }

    public func open(
        _ sealed: SealedCredential,
        for recordKey: CredentialRecordKey,
        using masterKey: SymmetricKey
    ) throws -> Data {
        try validateMasterKey(masterKey)
        guard let encodedVersion = sealed.combined.first else {
            throw CredentialVaultError.ciphertextInvalid
        }
        guard Int(encodedVersion) == Self.currentVersion else {
            throw CredentialVaultError.unsupportedVersion(Int(encodedVersion))
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(sealed.combined.dropFirst()))
            return try AES.GCM.open(
                sealedBox,
                using: masterKey,
                authenticating: associatedData(for: recordKey)
            )
        } catch {
            throw CredentialVaultError.ciphertextInvalid
        }
    }

    private func associatedData(for recordKey: CredentialRecordKey) -> Data {
        let segments = recordKey.rawValue.split(separator: ":", omittingEmptySubsequences: false)
        let ownerSegment = segments.count > 1 ? String(segments[1]) : ""
        let secretKind = segments.count > 2 ? String(segments[2]) : ""

        return Self.lengthPrefixedData([
            String(Self.currentVersion),
            recordKey.rawValue,
            ownerSegment,
            secretKind,
        ])
    }

    private func validateMasterKey(_ masterKey: SymmetricKey) throws {
        guard masterKey.withUnsafeBytes({ $0.count == 32 }) else {
            throw CredentialVaultError.invalidKeyLength
        }
    }

    private static func lengthPrefixedData(_ fields: [String]) -> Data {
        fields.reduce(into: Data()) { result, field in
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
    }
}
