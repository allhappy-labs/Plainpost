import CryptoKit
import Foundation
import XCTest
@testable import PlainpostSecrets

final class VaultSessionTests: XCTestCase {
    func testConcurrentUnlockRequestsCoalesceIntoOneInteractiveLoad() async throws {
        let provider = ControlledVaultKeyProvider(
            loadResult: Data(repeating: 0x42, count: 32)
        )
        let session = VaultSession(provider: provider)

        async let first: Void = session.unlock(prompt: "Unlock Plainpost")
        async let second: Void = session.unlock(prompt: "Unlock Plainpost")

        await provider.waitUntilLoadStarts()
        let unlockingState = await session.state
        XCTAssertEqual(unlockingState, .unlocking)
        await provider.releaseLoad()
        try await first
        try await second

        let loadCallCount = await provider.loadCallCount
        let finalState = await session.state
        let firstByte = try await session.withKey { key in
            key.withUnsafeBytes { bytes in
                bytes.first
            }
        }
        XCTAssertEqual(loadCallCount, 1)
        XCTAssertEqual(finalState, .unlocked)
        XCTAssertEqual(firstByte, 0x42)
    }

    func testAuthorizationCancellationLeavesSessionLockedWithoutRetry() async {
        let provider = ControlledVaultKeyProvider(
            loadResult: nil,
            loadError: .authorizationCancelled,
            startsSuspended: false
        )
        let session = VaultSession(provider: provider)

        await XCTAssertAsyncThrows(
            try await session.unlock(prompt: "Unlock Plainpost")
        ) { error in
            XCTAssertEqual(
                error as? CredentialVaultError,
                .authorizationCancelled
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        let loadCallCount = await provider.loadCallCount
        let finalState = await session.state
        XCTAssertEqual(loadCallCount, 1)
        XCTAssertEqual(finalState, .locked)
    }

    func testLockMakesLaterKeyReadsThrowLocked() async throws {
        let provider = ControlledVaultKeyProvider(
            loadResult: Data(repeating: 0x24, count: 32),
            startsSuspended: false
        )
        let session = VaultSession(provider: provider)
        try await session.unlock(prompt: "Unlock Plainpost")
        let byteCount = try await session.withKey { key in
            key.withUnsafeBytes { $0.count }
        }
        XCTAssertEqual(byteCount, 32)

        await session.lock()

        await XCTAssertAsyncThrows(
            try await session.withKey { _ in true }
        ) { error in
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }
        let finalState = await session.state
        XCTAssertEqual(finalState, .locked)
    }

    func testFailedUnlockReturnsToLockedAndRejectsInvalidKeyLength() async {
        let provider = ControlledVaultKeyProvider(
            loadResult: Data(repeating: 0x55, count: 31),
            startsSuspended: false
        )
        let session = VaultSession(provider: provider)

        await XCTAssertAsyncThrows(
            try await session.unlock(prompt: "Unlock Plainpost")
        ) { error in
            XCTAssertEqual(error as? CredentialVaultError, .invalidKeyLength)
        }

        let finalState = await session.state
        XCTAssertEqual(finalState, .locked)
        await XCTAssertAsyncThrows(
            try await session.withKey { _ in true }
        ) { error in
            XCTAssertEqual(error as? CredentialVaultError, .locked)
        }
    }

    func testEncryptedVaultSealsAndOpensThroughUnlockedSession() async throws {
        let provider = ControlledVaultKeyProvider(
            loadResult: Data(repeating: 0x68, count: 32),
            startsSuspended: false
        )
        let session = VaultSession(provider: provider)
        let repository = InMemoryCiphertextRepository()
        let vault = EncryptedCredentialVault(
            repository: repository,
            session: session,
            cryptor: VaultCryptor()
        )
        let recordKey = CredentialRecordKey(rawValue: "account:alice:imap")
        let secret = Data("not stored as plaintext".utf8)
        try await session.unlock(prompt: "Unlock Plainpost")

        try await vault.store(secret, for: recordKey)

        let persistedValue = await repository.value(for: recordKey)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertNotEqual(persisted.combined, secret)
        let loaded = try await vault.load(recordKey)
        XCTAssertEqual(loaded, secret)
        try await vault.remove(recordKey)
        let removedValue = await repository.value(for: recordKey)
        XCTAssertNil(removedValue)
    }

    func testEncryptedLoadOrCreateDoesNotInvokeFactoryForExistingRecords() async throws {
        let provider = ControlledVaultKeyProvider(
            loadResult: Data(repeating: 0x31, count: 32), startsSuspended: false
        )
        let session = VaultSession(provider: provider)
        let repository = InMemoryCiphertextRepository()
        let vault = EncryptedCredentialVault(repository: repository, session: session)
        let key = CredentialRecordKey(rawValue: "device:server-identity")
        let counter = SynchronousCounter()
        try await session.unlock(prompt: "Unlock Plainpost")
        try await vault.store(Data("persisted".utf8), for: key)

        let values = try await vault.loadOrCreate([key]) {
            counter.increment()
            throw CredentialVaultError.ciphertextInvalid
        }

        XCTAssertEqual(values, [Data("persisted".utf8)])
        XCTAssertEqual(counter.value, 0)
    }
}

private final class SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor ControlledVaultKeyProvider: VaultKeyProvider {
    private let loadResult: Data?
    private let loadError: CredentialVaultError?
    private var suspended: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCallCount = 0
    private var didStart = false

    init(
        loadResult: Data?,
        loadError: CredentialVaultError? = nil,
        startsSuspended: Bool = true
    ) {
        self.loadResult = loadResult
        self.loadError = loadError
        suspended = startsSuspended
    }

    func createIfMissing() async throws {}

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        loadCallCount += 1
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        if suspended {
            await withCheckedContinuation { continuation = $0 }
        }
        if let loadError {
            throw loadError
        }
        return loadResult
    }

    func countMatchingItems() async throws -> Int {
        loadResult == nil ? 0 : 1
    }

    func waitUntilLoadStarts() async {
        guard !didStart else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releaseLoad() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }
}

private actor InMemoryCiphertextRepository: CredentialCiphertextRepository {
    private var values: [CredentialRecordKey: SealedCredential] = [:]

    func save(_ value: SealedCredential, for key: CredentialRecordKey) {
        values[key] = value
    }

    func load(_ key: CredentialRecordKey) -> SealedCredential? {
        values[key]
    }

    func remove(_ key: CredentialRecordKey) {
        values.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [SealedCredential]
    ) throws -> [SealedCredential?] {
        let current = keys.map { values[$0] }
        guard current.allSatisfy({ $0 == nil }) else { return current }
        let created = try create()
        guard created.count == keys.count, Set(keys).count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) {
            values[key] = value
        }
        return created.map(Optional.some)
    }

    func hasRecords() -> Bool {
        !values.isEmpty
    }

    func value(for key: CredentialRecordKey) -> SealedCredential? {
        values[key]
    }
}

private func XCTAssertAsyncThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
