import Foundation
import XCTest
@testable import PlainpostDB
import PlainpostSecrets

final class SQLiteCredentialCiphertextRepositoryTests: XCTestCase {
    func testCiphertextPersistsWithoutPlaintext() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SQLiteMailStore(path: path)
        try store.migrate()
        let repository = SQLiteCredentialCiphertextRepository(databaseWriter: store.databaseWriter)
        let key = CredentialRecordKey(rawValue: "account:a:imap")
        let value = SealedCredential(combined: Data([1, 2, 3]))

        try await repository.save(value, for: key)

        let loaded = try await repository.load(key)
        XCTAssertEqual(loaded, value)
    }

    func testRemovingCiphertextClearsRepository() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SQLiteMailStore(path: path)
        try store.migrate()
        let repository = SQLiteCredentialCiphertextRepository(databaseWriter: store.databaseWriter)
        let key = CredentialRecordKey(rawValue: "account:a:smtp")

        let isInitiallyEmpty = try await repository.hasRecords()
        XCTAssertFalse(isInitiallyEmpty)

        try await repository.save(SealedCredential(combined: Data([1, 4, 5, 6])), for: key)
        let hasSavedRecord = try await repository.hasRecords()
        XCTAssertTrue(hasSavedRecord)

        try await repository.remove(key)
        let hasRemainingRecords = try await repository.hasRecords()
        let loaded = try await repository.load(key)
        XCTAssertFalse(hasRemainingRecords)
        XCTAssertNil(loaded)
    }

    func testEncryptedSQLiteLoadOrCreateSkipsFailingFactoryForExistingRecord() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteMailStore(path: path)
        try store.migrate()
        let repository = SQLiteCredentialCiphertextRepository(databaseWriter: store.databaseWriter)
        let key = CredentialRecordKey(rawValue: "device:server-identity")
        let first = try await makeUnlockedVault(repository: repository)
        try await first.store(Data("persisted".utf8), for: key)
        let second = try await makeUnlockedVault(repository: repository)
        let counter = AtomicFactoryCounter()

        let values = try await second.loadOrCreate([key]) {
            counter.increment()
            throw CredentialVaultError.ciphertextInvalid
        }

        XCTAssertEqual(values, [Data("persisted".utf8)])
        XCTAssertEqual(counter.value, 0)
    }

    func testConcurrentEncryptedSQLiteLoadOrCreateInvokesOneFactoryAndPublishesCompleteSet() async throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteMailStore(path: path)
        try store.migrate()
        let repository = SQLiteCredentialCiphertextRepository(databaseWriter: store.databaseWriter)
        let keys = [
            CredentialRecordKey(rawValue: "device:tls-private-key"),
            CredentialRecordKey(rawValue: "device:tls-certificate"),
        ]
        let counter = AtomicFactoryCounter()
        let first = try await makeUnlockedVault(repository: repository)
        let second = try await makeUnlockedVault(repository: repository)

        async let firstValues = first.loadOrCreate(keys) {
            counter.increment()
            return [Data("private".utf8), Data("certificate".utf8)]
        }
        async let secondValues = second.loadOrCreate(keys) {
            counter.increment()
            return [Data("private".utf8), Data("certificate".utf8)]
        }
        let results = try await [firstValues, secondValues]

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0], [Data("private".utf8), Data("certificate".utf8)])
        let firstPersisted = try await repository.load(keys[0])
        let secondPersisted = try await repository.load(keys[1])
        XCTAssertNotNil(firstPersisted)
        XCTAssertNotNil(secondPersisted)
    }

    private func makeUnlockedVault(
        repository: SQLiteCredentialCiphertextRepository
    ) async throws -> EncryptedCredentialVault {
        let session = VaultSession(provider: FixedVaultKeyProvider())
        try await session.unlock(prompt: "Unlock Plainpost")
        return EncryptedCredentialVault(repository: repository, session: session)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-credential-ciphertexts-\(UUID().uuidString).sqlite")
            .path
    }
}

private actor FixedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { Data(repeating: 0x55, count: 32) }
    func countMatchingItems() async throws -> Int { 1 }
}

private final class AtomicFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
