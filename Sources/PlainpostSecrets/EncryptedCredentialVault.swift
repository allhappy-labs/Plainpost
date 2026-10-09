import Foundation

public protocol CredentialCiphertextRepository: Sendable {
    func save(_ value: SealedCredential, for key: CredentialRecordKey) async throws
    func load(_ key: CredentialRecordKey) async throws -> SealedCredential?
    func remove(_ key: CredentialRecordKey) async throws
    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [SealedCredential]
    ) async throws -> [SealedCredential?]
    func hasRecords() async throws -> Bool
}

public struct EncryptedCredentialVault: CredentialVault, Sendable {
    private let repository: any CredentialCiphertextRepository
    private let session: VaultSession
    private let cryptor: VaultCryptor

    public init(
        repository: any CredentialCiphertextRepository,
        session: VaultSession,
        cryptor: VaultCryptor = VaultCryptor()
    ) {
        self.repository = repository
        self.session = session
        self.cryptor = cryptor
    }

    public func store(_ secret: Data, for key: CredentialRecordKey) async throws {
        let sealed = try await session.withKey { masterKey in
            try cryptor.seal(secret, for: key, using: masterKey)
        }
        try await repository.save(sealed, for: key)
    }

    public func load(_ key: CredentialRecordKey) async throws -> Data? {
        guard let sealed = try await repository.load(key) else {
            return nil
        }
        return try await session.withKey { masterKey in
            try cryptor.open(sealed, for: key, using: masterKey)
        }
    }

    public func remove(_ key: CredentialRecordKey) async throws {
        try await repository.remove(key)
    }

    public func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [Data]
    ) async throws -> [Data?] {
        guard Set(keys).count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        let encryptedCreated: @Sendable () throws -> [SealedCredential] = try await session.withKey { masterKey in
            { @Sendable [cryptor, keys, create] in
                let created = try create()
                guard created.count == keys.count else {
                    throw CredentialVaultError.ciphertextInvalid
                }
                return try zip(keys, created).map { key, value in
                    try cryptor.seal(value, for: key, using: masterKey)
                }
            }
        }
        let sealed = try await repository.loadOrCreate(keys, create: encryptedCreated)
        guard sealed.count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        return try await session.withKey { masterKey in
            try zip(keys, sealed).map { key, value in
                try value.map { try cryptor.open($0, for: key, using: masterKey) }
            }
        }
    }
}
