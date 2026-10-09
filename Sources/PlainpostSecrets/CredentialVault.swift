import Foundation

public struct CredentialRecordKey: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case locked
    case authorizationCancelled
    case authorizationFailed
    case keyMissing
    case keyAmbiguous
    case invalidKeyLength
    case ciphertextInvalid
    case unsupportedVersion(Int)
    case clientUnauthorized
}

public protocol CredentialVault: Sendable {
    func store(_ secret: Data, for key: CredentialRecordKey) async throws
    func load(_ key: CredentialRecordKey) async throws -> Data?
    func remove(_ key: CredentialRecordKey) async throws
    /// Atomically observes a fixed record set and, only when every record is
    /// absent, publishes a complete replacement set. A partial existing set
    /// is returned unchanged so callers can classify it as corruption.
    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) async throws -> [Data?]
}

public actor InMemoryCredentialVault: CredentialVault {
    private var secrets: [CredentialRecordKey: Data] = [:]

    public init() {
        secrets = [:]
    }

    public init(records: [CredentialRecordKey: Data]) {
        secrets = records
    }

    public func store(_ secret: Data, for key: CredentialRecordKey) throws {
        secrets[key] = secret
    }

    public func load(_ key: CredentialRecordKey) throws -> Data? {
        secrets[key]
    }

    public func remove(_ key: CredentialRecordKey) throws {
        secrets.removeValue(forKey: key)
    }

    public func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) throws -> [Data?] {
        try Task.checkCancellation()
        let current = keys.map { secrets[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard keys.count == created.count,
              Set(keys).count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        try Task.checkCancellation()
        for (key, value) in zip(keys, created) {
            secrets[key] = value
        }
        return created.map(Optional.some)
    }
}
