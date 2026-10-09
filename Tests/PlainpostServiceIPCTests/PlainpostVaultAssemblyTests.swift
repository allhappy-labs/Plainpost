import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostSecrets

final class PlainpostVaultAssemblyTests: XCTestCase {
    func testVaultAssemblySourceRequiresExplicitProvider() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/PlainpostDB/SQLiteCredentialVaultAssembly.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let explicitInitializer = try NSRegularExpression(
            pattern: """
            public\\s+init\\s*\\(\\s*store:\\s*SQLiteMailStore\\s*,\\s*provider:\\s*any\\s+VaultKeyProvider\\s*\\)
            """
        )
        let implicitInitializer = try NSRegularExpression(
            pattern: """
            public\\s+init\\s*\\(\\s*store:\\s*SQLiteMailStore\\s*\\)
            """
        )
        let range = NSRange(source.startIndex..., in: source)

        XCTAssertEqual(
            explicitInitializer.numberOfMatches(
                in: source,
                range: range
            ),
            1
        )
        XCTAssertEqual(
            implicitInitializer.numberOfMatches(
                in: source,
                range: range
            ),
            0
        )
        XCTAssertFalse(source.contains("VaultKeyProvider ="))
    }

    func testExistingCiphertextAndMissingKeyNeverCreatesReplacementKey() async throws {
        let fixture = try CredentialAssemblyFixture()
        let key = CredentialRecordKey(rawValue: "account:existing:imap")
        let ciphertext = SealedCredential(combined: Data([7, 0xAA]))
        try await fixture.repository.save(ciphertext, for: key)
        let provider = RuntimeVaultKeyProvider(
            matchingItemCount: 0,
            keyData: nil
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: provider
        )

        await XCTAssertCredentialVaultError(
            try await assembly.prepareForegroundUnlock(),
            equals: .keyMissing
        )

        let calls = await provider.calls
        let persisted = try await fixture.repository.load(key)
        XCTAssertEqual(calls.countMatchingItems, 1)
        XCTAssertEqual(calls.createIfMissing, 0)
        XCTAssertEqual(calls.interactiveLoads, 0)
        XCTAssertEqual(persisted, ciphertext)
    }

    func testEmptyRepositoryAndNoKeyCreatesExactlyOnceDuringForegroundUnlock() async throws {
        let fixture = try CredentialAssemblyFixture()
        let provider = RuntimeVaultKeyProvider(
            matchingItemCount: 0,
            keyData: nil,
            keyAfterCreation: Data(repeating: 0x31, count: 32)
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: provider
        )

        try await assembly.prepareForegroundUnlock()

        let preparationCalls = await provider.calls
        let preparedState = await assembly.session.state
        XCTAssertEqual(preparationCalls.countMatchingItems, 1)
        XCTAssertEqual(preparationCalls.createIfMissing, 1)
        XCTAssertEqual(preparationCalls.interactiveLoads, 0)
        XCTAssertEqual(preparedState, .locked)

        try await assembly.session.unlock(prompt: "Unlock Plainpost")

        let unlockedCalls = await provider.calls
        let unlockedState = await assembly.session.state
        XCTAssertEqual(unlockedCalls.interactiveLoads, 1)
        XCTAssertEqual(unlockedState, .unlocked)
    }

    func testDuplicateKeyItemsUseOnlyExactCountAndNeverMutateSelectOrDelete() async throws {
        let fixture = try CredentialAssemblyFixture()
        let provider = RuntimeVaultKeyProvider(
            matchingItemCount: 2,
            keyData: Data(repeating: 0x77, count: 32)
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: provider
        )

        await XCTAssertCredentialVaultError(
            try await assembly.prepareForegroundUnlock(),
            equals: .keyAmbiguous
        )

        let operations = await provider.operations
        XCTAssertEqual(operations, [.countMatchingItems])
    }

    func testStartOverArchivesEveryRecordAndEmptiesTheVaultTable() async throws {
        let fixture = try CredentialAssemblyFixture()
        let records: [(CredentialRecordKey, SealedCredential)] = [
            (CredentialRecordKey(rawValue: "account:a:imap"), SealedCredential(combined: Data([1, 0xA1]))),
            (CredentialRecordKey(rawValue: "account:a:smtp"), SealedCredential(combined: Data([1, 0xA2]))),
            (CredentialRecordKey(rawValue: "device:server-identity"), SealedCredential(combined: Data([1, 0xA3]))),
        ]
        for (key, value) in records {
            try await fixture.repository.save(value, for: key)
        }
        let provider = RuntimeVaultKeyProvider(matchingItemCount: 0, keyData: nil)
        let assembly = SQLiteCredentialVaultAssembly(store: fixture.store, provider: provider)

        try await assembly.archiveRecordsAfterKeyLoss()

        let hasRecords = try await fixture.repository.hasRecords()
        XCTAssertFalse(hasRecords)
        let archived = try fixture.archivedRows()
        XCTAssertEqual(archived.map(\.recordKey), records.map(\.0.rawValue).sorted())
        XCTAssertEqual(archived.map(\.combined), records.sorted { $0.0.rawValue < $1.0.rawValue }.map(\.1.combined))
        XCTAssertEqual(Set(archived.map(\.reason)), ["key_missing"])
        XCTAssertTrue(archived.allSatisfy { !$0.archivedAt.isEmpty })
        let calls = await provider.calls
        XCTAssertEqual(calls.createIfMissing, 0)
        XCTAssertEqual(calls.interactiveLoads, 0)
    }

    func testStartOverAsksEachAccountThatLostItsSignInToSignInAgain() async throws {
        let fixture = try CredentialAssemblyFixture()
        let password = AccountID("acc:password")
        let google = AccountID("acc_google")
        let untouched = AccountID("acc_no_records")
        try fixture.store.cacheAccounts([password, google, untouched].map {
            Account(
                id: $0,
                displayName: $0.rawValue,
                email: EmailAddress("\($0.rawValue.replacingOccurrences(of: ":", with: "_"))@example.com"),
                imapHost: "imap.example.com",
                smtpHost: "smtp.example.com"
            )
        })
        try fixture.store.setAccountAuthentication(accountID: google, method: .googleOAuth, state: .ready)
        try await fixture.repository.save(
            SealedCredential(combined: Data([1, 0x01])),
            for: CredentialRecordKey(rawValue: "account:acc:password:imap-password")
        )
        try await fixture.repository.save(
            SealedCredential(combined: Data([1, 0x02])),
            for: CredentialRecordKey(rawValue: "account:acc_google:google-refresh-token")
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: RuntimeVaultKeyProvider(matchingItemCount: 0, keyData: nil)
        )

        try await assembly.archiveRecordsAfterKeyLoss()

        let passwordAuthentication = try fixture.store.accountAuthentication(accountID: password)
        let googleAuthentication = try fixture.store.accountAuthentication(accountID: google)
        let untouchedAuthentication = try fixture.store.accountAuthentication(accountID: untouched)
        XCTAssertEqual(passwordAuthentication.method, .password)
        XCTAssertEqual(passwordAuthentication.state, .reauthorizationRequired)
        XCTAssertEqual(googleAuthentication.method, .googleOAuth)
        XCTAssertEqual(googleAuthentication.state, .reauthorizationRequired)
        XCTAssertEqual(untouchedAuthentication.state, .ready)
        XCTAssertEqual(try fixture.store.reauthorizationRequiredAccountIDs(), [password, google].sorted { $0.rawValue < $1.rawValue })
    }

    func testStartOverIsAllOrNothing() async throws {
        let fixture = try CredentialAssemblyFixture()
        let first = CredentialRecordKey(rawValue: "account:a:imap")
        let poisoned = CredentialRecordKey(rawValue: "account:poison:imap")
        try await fixture.repository.save(SealedCredential(combined: Data([1, 0x01])), for: first)
        try await fixture.repository.save(SealedCredential(combined: Data([1, 0x02])), for: poisoned)
        try await fixture.store.databaseWriter.write { database in
            try database.execute(sql: """
                CREATE TRIGGER test_archive_poison BEFORE INSERT ON credential_ciphertexts_archive
                WHEN NEW.record_key = 'account:poison:imap'
                BEGIN SELECT RAISE(ABORT, 'poisoned'); END;
                """)
        }
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: RuntimeVaultKeyProvider(matchingItemCount: 0, keyData: nil)
        )

        do {
            try await assembly.archiveRecordsAfterKeyLoss()
            XCTFail("Expected the archive to fail")
        } catch {}

        let keptFirst = try await fixture.repository.load(first)
        let keptPoisoned = try await fixture.repository.load(poisoned)
        XCTAssertNotNil(keptFirst)
        XCTAssertNotNil(keptPoisoned)
        XCTAssertEqual(try fixture.archivedRows().count, 0)
    }

    func testStartOverRefusesWhileAKeyItemExists() async throws {
        for count in [1, 2] {
            let fixture = try CredentialAssemblyFixture()
            let key = CredentialRecordKey(rawValue: "account:readable:imap")
            let ciphertext = SealedCredential(combined: Data([1, 0xBB]))
            try await fixture.repository.save(ciphertext, for: key)
            let provider = RuntimeVaultKeyProvider(
                matchingItemCount: count,
                keyData: Data(repeating: 0x42, count: 32)
            )
            let assembly = SQLiteCredentialVaultAssembly(store: fixture.store, provider: provider)

            do {
                try await assembly.archiveRecordsAfterKeyLoss()
                XCTFail("Expected a refusal with \(count) key items")
            } catch {}

            let persisted = try await fixture.repository.load(key)
            XCTAssertEqual(persisted, ciphertext, "\(count)")
            XCTAssertEqual(try fixture.archivedRows().count, 0, "\(count)")
            let operations = await provider.operations
            XCTAssertEqual(operations, [.countMatchingItems], "\(count)")
        }
    }

    func testStartOverWithoutRecordsChangesNothing() async throws {
        let fixture = try CredentialAssemblyFixture()
        let provider = RuntimeVaultKeyProvider(matchingItemCount: 0, keyData: nil)
        let assembly = SQLiteCredentialVaultAssembly(store: fixture.store, provider: provider)

        try await assembly.archiveRecordsAfterKeyLoss()

        XCTAssertEqual(try fixture.archivedRows().count, 0)
        let calls = await provider.calls
        XCTAssertEqual(calls.createIfMissing, 0)
    }

    func testAfterStartOverForegroundUnlockCreatesAFreshKeyAndOpensTheVault() async throws {
        let fixture = try CredentialAssemblyFixture()
        try await fixture.repository.save(
            SealedCredential(combined: Data([1, 0xCC])),
            for: CredentialRecordKey(rawValue: "account:old:imap")
        )
        let provider = RuntimeVaultKeyProvider(
            matchingItemCount: 0,
            keyData: nil,
            keyAfterCreation: Data(repeating: 0x5A, count: 32)
        )
        let assembly = SQLiteCredentialVaultAssembly(store: fixture.store, provider: provider)
        await XCTAssertCredentialVaultError(
            try await assembly.prepareForegroundUnlock(),
            equals: .keyMissing
        )

        try await assembly.archiveRecordsAfterKeyLoss()
        try await assembly.unlockForeground(prompt: "Unlock Plainpost")

        let state = await assembly.session.state
        XCTAssertEqual(state, .unlocked)
        let calls = await provider.calls
        XCTAssertEqual(calls.createIfMissing, 1)
        let key = CredentialRecordKey(rawValue: "account:new:imap")
        try await assembly.vault.store(Data("fresh".utf8), for: key)
        let loaded = try await assembly.vault.load(key)
        XCTAssertEqual(loaded, Data("fresh".utf8))
        XCTAssertEqual(try fixture.archivedRows().map(\.recordKey), ["account:old:imap"])
    }

    func testInvalidAndUnsupportedCiphertextRemainByteIdentical() async throws {
        let fixture = try CredentialAssemblyFixture()
        let keyData = Data(repeating: 0x49, count: 32)
        let provider = RuntimeVaultKeyProvider(
            matchingItemCount: 1,
            keyData: keyData,
            keyAfterCreation: keyData
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: fixture.store,
            provider: provider
        )
        try await assembly.unlockForeground(prompt: "Unlock Plainpost")
        let cases: [
            (
                key: CredentialRecordKey,
                ciphertext: SealedCredential,
                expected: CredentialVaultError
            )
        ] = [
            (
                CredentialRecordKey(rawValue: "account:invalid:imap"),
                SealedCredential(combined: Data([1, 0x00])),
                .ciphertextInvalid
            ),
            (
                CredentialRecordKey(rawValue: "account:future:imap"),
                SealedCredential(combined: Data([7, 0xCA, 0xFE])),
                .unsupportedVersion(7)
            ),
        ]

        for item in cases {
            try await fixture.repository.save(
                item.ciphertext,
                for: item.key
            )
            await XCTAssertCredentialVaultError(
                try await assembly.vault.load(item.key),
                equals: item.expected
            )
            let persisted = try await fixture.repository.load(item.key)
            XCTAssertEqual(persisted, item.ciphertext)
        }
    }

}

private final class CredentialAssemblyFixture: @unchecked Sendable {
    let store: SQLiteMailStore
    let repository: SQLiteCredentialCiphertextRepository

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-task2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteMailStore(
            path: directory.appendingPathComponent("mail.sqlite").path
        )
        try store.migrate()
        repository = SQLiteCredentialCiphertextRepository(
            databaseWriter: store.databaseWriter
        )
    }

    struct ArchivedRow: Equatable {
        let recordKey: String
        let combined: Data
        let reason: String
        let archivedAt: String
    }

    func archivedRows() throws -> [ArchivedRow] {
        try store.databaseWriter.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT record_key, combined, reason, archived_at
                    FROM credential_ciphertexts_archive
                    ORDER BY record_key
                    """
            ).map {
                ArchivedRow(
                    recordKey: $0["record_key"],
                    combined: $0["combined"],
                    reason: $0["reason"],
                    archivedAt: $0["archived_at"]
                )
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RuntimeVaultKeyProvider: VaultKeyProvider {
    enum Operation: Equatable, Sendable {
        case countMatchingItems
        case createIfMissing
        case load(interactive: Bool)
    }

    struct Calls: Equatable, Sendable {
        var countMatchingItems = 0
        var createIfMissing = 0
        var interactiveLoads = 0
    }

    private let matchingItemCount: Int
    private let keyAfterCreation: Data?
    private var keyData: Data?
    private(set) var calls = Calls()
    private(set) var operations: [Operation] = []

    init(
        matchingItemCount: Int,
        keyData: Data?,
        keyAfterCreation: Data? = nil
    ) {
        self.matchingItemCount = matchingItemCount
        self.keyData = keyData
        self.keyAfterCreation = keyAfterCreation
    }

    func createIfMissing() {
        operations.append(.createIfMissing)
        calls.createIfMissing += 1
        keyData = keyAfterCreation
    }

    func load(interactive: Bool, prompt: String?) -> Data? {
        operations.append(.load(interactive: interactive))
        if interactive {
            calls.interactiveLoads += 1
        }
        return keyData
    }

    func countMatchingItems() -> Int {
        operations.append(.countMatchingItems)
        calls.countMatchingItems += 1
        return matchingItemCount
    }
}

private func XCTAssertCredentialVaultError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: CredentialVaultError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? CredentialVaultError,
            expected,
            file: file,
            line: line
        )
    }
}
