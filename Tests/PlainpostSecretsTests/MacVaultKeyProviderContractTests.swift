import CryptoKit
import Foundation
import Security
import XCTest
@testable import PlainpostSecrets

/// These tests intentionally use injected operations only. They live in the
/// explicit Security acceptance target so ordinary suites can never construct
/// a production Security provider.
final class MacVaultKeyProviderContractTests: XCTestCase {
    func testCreateAddsTheSoleProtectedDeviceOnlyKey() async throws {
        let recorder = MacVaultOperationRecorder(copyResults: [.init(status: errSecItemNotFound, value: nil)])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        try await provider.createIfMissing()

        let query = try XCTUnwrap(recorder.addQueries.first)
        XCTAssertEqual(query[kSecAttrLabel as String] as? String, "Plainpost Vault Key")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.marynavdovenko.Plainpost.Vault")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "primary-v1")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data(repeating: 0xA5, count: 32))
        XCTAssertNotNil(query[kSecAttrAccessControl as String])
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertEqual(recorder.randomByteCount, 32)
        XCTAssertEqual(recorder.accessibility as String?, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(recorder.accessControlFlags, .userPresence)
    }

    func testNoninteractiveLoadFailsAuthenticationUIAndReturnsOneKey() async throws {
        let expected = Data(repeating: 0x3C, count: 32)
        let recorder = MacVaultOperationRecorder(copyResults: [.init(status: errSecSuccess, value: [expected])])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        let loaded = try await provider.load(interactive: false, prompt: nil)
        XCTAssertEqual(loaded, expected)
        let query = try XCTUnwrap(recorder.copyQueries.last)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertNil(query[kSecUseOperationPrompt as String])
        assertSoleIdentity(query)
    }

    func testInteractiveLoadIncludesHumanReadablePrompt() async throws {
        let recorder = MacVaultOperationRecorder(copyResults: [.init(status: errSecSuccess, value: [Data(repeating: 0x7E, count: 32)])])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        _ = try await provider.load(interactive: true, prompt: "Unlock Plainpost to access your saved mail credentials.")

        let query = try XCTUnwrap(recorder.copyQueries.last)
        XCTAssertEqual(query[kSecUseOperationPrompt as String] as? String, "Unlock Plainpost to access your saved mail credentials.")
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
        assertSoleIdentity(query)
    }

    func testCreateFailsClosedWhenAddReportsDuplicate() async {
        let recorder = MacVaultOperationRecorder(
            copyResults: [.init(status: errSecItemNotFound, value: nil)],
            addStatus: errSecDuplicateItem
        )
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        do {
            try await provider.createIfMissing()
            XCTFail("Expected duplicate vault key creation to fail closed.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .keyAmbiguous)
        }
    }

    func testLoadRejectsMultipleReturnedKeysRatherThanChoosingOne() async {
        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(status: errSecSuccess, value: [Data(repeating: 0x01, count: 32), Data(repeating: 0x02, count: 32)]),
        ])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        do {
            _ = try await provider.load(interactive: false, prompt: nil)
            XCTFail("Expected multiple vault roots to fail closed.")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .keyAmbiguous)
        }
        XCTAssertEqual(recorder.copyQueries.count, 1)
    }

    func testUserCancellationRemainsAuthorizationCancelled() async {
        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(status: errSecUserCanceled, value: nil),
        ])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        do {
            _ = try await provider.load(
                interactive: true,
                prompt: "Unlock Plainpost"
            )
            XCTFail("Expected cancellation to remain distinct.")
        } catch {
            XCTAssertEqual(
                error as? CredentialVaultError,
                .authorizationCancelled
            )
        }
    }

    func testAuthenticationDeniedStatusesRemainAuthorizationFailed() async {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed] {
            let recorder = MacVaultOperationRecorder(copyResults: [
                .init(status: status, value: nil),
            ])
            let provider = MacVaultKeyProvider.injecting(recorder.operations)

            do {
                _ = try await provider.load(
                    interactive: true,
                    prompt: "Unlock Plainpost"
                )
                XCTFail("Expected authentication denial for \(status).")
            } catch {
                XCTAssertEqual(
                    error as? CredentialVaultError,
                    .authorizationFailed
                )
            }
        }
    }

    func testNoninteractiveCountTreatsProtectedMatchingKeyAsPresent() async throws {
        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(status: errSecInteractionNotAllowed, value: nil),
        ])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        let count = try await provider.countMatchingItems()

        XCTAssertEqual(count, 1)
        let query = try XCTUnwrap(recorder.copyQueries.last)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        assertSoleIdentity(query)
    }

    func testNoninteractiveCountTreatsAuthenticationDeniedMatchingKeyAsPresent() async throws {
        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(status: errSecAuthFailed, value: nil),
        ])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        let count = try await provider.countMatchingItems()

        XCTAssertEqual(count, 1)
        let query = try XCTUnwrap(recorder.copyQueries.last)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        assertSoleIdentity(query)
    }

    func testUnexpectedStatusRemainsNonDestructiveOperationFailure() async {
        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(status: errSecDecode, value: nil),
        ])
        let provider = MacVaultKeyProvider.injecting(recorder.operations)

        do {
            _ = try await provider.load(
                interactive: true,
                prompt: "Unlock Plainpost"
            )
            XCTFail("Expected the unexpected status to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? MacVaultKeyProviderError,
                .unexpectedStatus(errSecDecode)
            )
            XCTAssertNil(error as? CredentialVaultError)
        }
        XCTAssertEqual(recorder.addQueries.count, 0)
    }

    func testMissingKeyPreservesExactCiphertextRepositorySnapshot() async {
        await assertUnlockFailurePreservesRepository(
            .init(status: errSecItemNotFound, value: nil),
            expectedError: .keyMissing
        )
    }

    func testAmbiguousKeyPreservesExactCiphertextRepositorySnapshot() async {
        await assertUnlockFailurePreservesRepository(
            .init(
                status: errSecSuccess,
                value: [
                    Data(repeating: 0x11, count: 32),
                    Data(repeating: 0x22, count: 32),
                ]
            ),
            expectedError: .keyAmbiguous
        )
    }

    func testCancelledUnlockPreservesExactCiphertextRepositorySnapshot() async {
        await assertUnlockFailurePreservesRepository(
            .init(status: errSecUserCanceled, value: nil),
            expectedError: .authorizationCancelled
        )
    }

    func testAuthorizationFailurePreservesExactCiphertextRepositorySnapshot() async {
        await assertUnlockFailurePreservesRepository(
            .init(status: errSecAuthFailed, value: nil),
            expectedError: .authorizationFailed
        )
    }

    func testInvalidCiphertextPreservesExactCiphertextRepositorySnapshot() async {
        await assertCiphertextFailurePreservesRepository(
            sealed: SealedCredential(combined: Data([1])),
            expectedHash:
                "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a",
            expectedError: .ciphertextInvalid
        )
    }

    func testUnsupportedCiphertextVersionPreservesExactRepositorySnapshot() async {
        await assertCiphertextFailurePreservesRepository(
            sealed: SealedCredential(combined: Data([2])),
            expectedHash:
                "dbc1b4c900ffe48d575b5da5c638040125f65db0fe3e24494b76ea986457d986",
            expectedError: .unsupportedVersion(2)
        )
    }

    private func assertUnlockFailurePreservesRepository(
        _ copyResult: MacVaultKeyProvider.SecItemResult,
        expectedError: CredentialVaultError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let repository = SnapshottingCiphertextRepository(
            records: Self.baselineCiphertextRecords
        )
        let before = await repository.snapshot()
        XCTAssertEqual(
            before,
            Self.baselineCiphertextSnapshot,
            file: file,
            line: line
        )
        let recorder = MacVaultOperationRecorder(copyResults: [copyResult])
        let session = VaultSession(
            provider: MacVaultKeyProvider.injecting(recorder.operations)
        )
        let vault = EncryptedCredentialVault(
            repository: repository,
            session: session
        )
        let foregroundLoad = RepositoryBackedForegroundVaultLoad(
            vault: vault,
            session: session
        )

        do {
            _ = try await foregroundLoad.load(
                CredentialRecordKey(rawValue: "account:alice:imap"),
                prompt: "Unlock Plainpost"
            )
            XCTFail("Expected \(expectedError) from the vault load flow.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CredentialVaultError,
                expectedError,
                file: file,
                line: line
            )
        }

        let after = await repository.snapshot()
        XCTAssertEqual(after, before, file: file, line: line)
        let repositoryLoadCallCount = await repository.loadCallCount()
        XCTAssertEqual(
            repositoryLoadCallCount,
            1,
            "The repository-backed vault load must be reached before the injected provider failure.",
            file: file,
            line: line
        )
    }

    private func assertCiphertextFailurePreservesRepository(
        sealed: SealedCredential,
        expectedHash: String,
        expectedError: CredentialVaultError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let target = CredentialRecordKey(rawValue: "account:failure:imap")
        var records = Self.baselineCiphertextRecords
        records[target] = sealed
        let repository = SnapshottingCiphertextRepository(records: records)
        let before = await repository.snapshot()
        var expectedHashes = Self.baselineCiphertextSnapshot.byteHashes
        expectedHashes[target.rawValue] = expectedHash
        XCTAssertEqual(
            before,
            CiphertextRepositorySnapshot(
                recordCount: 3,
                byteHashes: expectedHashes
            ),
            file: file,
            line: line
        )

        let recorder = MacVaultOperationRecorder(copyResults: [
            .init(
                status: errSecSuccess,
                value: [Data(repeating: 0x5A, count: 32)]
            ),
        ])
        let session = VaultSession(
            provider: MacVaultKeyProvider.injecting(recorder.operations)
        )
        let vault = EncryptedCredentialVault(
            repository: repository,
            session: session
        )

        do {
            try await session.unlock(prompt: "Unlock Plainpost")
            _ = try await vault.load(target)
            XCTFail(
                "Expected \(expectedError) while opening ciphertext.",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? CredentialVaultError,
                expectedError,
                file: file,
                line: line
            )
        }

        let after = await repository.snapshot()
        XCTAssertEqual(after, before, file: file, line: line)
    }

    private static var baselineCiphertextRecords:
        [CredentialRecordKey: SealedCredential]
    {
        [
            CredentialRecordKey(rawValue: "account:alice:imap"):
                SealedCredential(combined: Data([1, 2, 3])),
            CredentialRecordKey(rawValue: "device:transport:identity"):
                SealedCredential(combined: Data([4, 5, 6, 7])),
        ]
    }

    private static var baselineCiphertextSnapshot: CiphertextRepositorySnapshot {
        CiphertextRepositorySnapshot(
            recordCount: 2,
            byteHashes: [
                "account:alice:imap":
                    "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
                "device:transport:identity":
                    "c6d44cf418f610e3fe9e1d9294ff43def81c6cdcad6cbb1820cff48d3aa4355d",
            ]
        )
    }

    private func assertSoleIdentity(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecAttrLabel as String] as? String, "Plainpost Vault Key", file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.marynavdovenko.Plainpost.Vault", file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "primary-v1", file: file, line: line)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true, file: file, line: line)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, file: file, line: line)
    }
}

private struct CiphertextRepositorySnapshot: Equatable {
    let recordCount: Int
    let byteHashes: [String: String]
}

private struct RepositoryBackedForegroundVaultLoad: Sendable {
    let vault: EncryptedCredentialVault
    let session: VaultSession

    func load(
        _ key: CredentialRecordKey,
        prompt: String
    ) async throws -> Data? {
        do {
            return try await vault.load(key)
        } catch CredentialVaultError.locked {
            try await session.unlock(prompt: prompt)
            return try await vault.load(key)
        }
    }
}

private actor SnapshottingCiphertextRepository:
    CredentialCiphertextRepository
{
    private var records: [CredentialRecordKey: SealedCredential]
    private var loadCalls = 0

    init(records: [CredentialRecordKey: SealedCredential]) {
        self.records = records
    }

    func save(
        _ value: SealedCredential,
        for key: CredentialRecordKey
    ) async throws {
        records[key] = value
    }

    func load(
        _ key: CredentialRecordKey
    ) async throws -> SealedCredential? {
        loadCalls += 1
        return records[key]
    }

    func remove(_ key: CredentialRecordKey) async throws {
        records.removeValue(forKey: key)
    }

    func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [SealedCredential]
    ) async throws -> [SealedCredential?] {
        let current = keys.map { records[$0] }
        guard current.allSatisfy({ $0 == nil }) else {
            return current
        }
        let created = try create()
        guard created.count == keys.count, Set(keys).count == keys.count else {
            throw CredentialVaultError.ciphertextInvalid
        }
        for (key, value) in zip(keys, created) {
            records[key] = value
        }
        return created.map(Optional.some)
    }

    func hasRecords() async throws -> Bool {
        !records.isEmpty
    }

    func snapshot() -> CiphertextRepositorySnapshot {
        CiphertextRepositorySnapshot(
            recordCount: records.count,
            byteHashes: Dictionary(uniqueKeysWithValues: records.map {
                (
                    $0.key.rawValue,
                    SHA256.hash(data: $0.value.combined)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            })
        )
    }

    func loadCallCount() -> Int {
        loadCalls
    }
}

private final class MacVaultOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [MacVaultKeyProvider.SecItemResult]
    private let addStatus: OSStatus
    private(set) var addQueries: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var accessibility: CFString?
    private(set) var accessControlFlags: SecAccessControlCreateFlags = []
    private(set) var randomByteCount: Int?

    init(copyResults: [MacVaultKeyProvider.SecItemResult], addStatus: OSStatus = errSecSuccess) {
        results = copyResults
        self.addStatus = addStatus
    }

    var operations: MacVaultKeyProvider.SecItemOperations {
        .init(
            add: { [self] query in
                lock.withLock { addQueries.append(query) }
                return addStatus
            },
            copyMatching: { [self] query in
                lock.withLock {
                    copyQueries.append(query)
                    return results.removeFirst()
                }
            },
            makeAccessControl: { [self] accessibility, flags in
                lock.withLock {
                    self.accessibility = accessibility
                    accessControlFlags = flags
                }
                return NSObject()
            },
            randomData: { [self] count in
                lock.withLock { randomByteCount = count }
                return Data(repeating: 0xA5, count: count)
            }
        )
    }
}
