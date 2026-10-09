import XCTest
import SQLite3
import PlainpostAccounts
import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations
import PlainpostSecrets
import PlainpostServiceIPC
@testable import PlainpostService
import PlainpostAccountDeletionTestSupport

final class AccountDeletionAcceptanceTests: XCTestCase {
    func testForegroundServiceIPCPurgesCompleteTargetOwnershipWithoutRemoteMutation() async throws {
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-account-deletion-ipc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let databaseURL = applicationSupportURL.appendingPathComponent("plainpost.sqlite")
        let store = try migratedStore(at: databaseURL)
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: store, databaseURL: databaseURL)
        let provider = AccountDeletionAcceptanceVaultKeyProvider()
        let assembly = SQLiteCredentialVaultAssembly(store: store, provider: provider)
        try await assembly.unlockForeground(prompt: "Account deletion acceptance")
        let targetKeys = [
            CredentialRecordKey(rawValue: "account:\(fixture.deleted.id.rawValue):imap-password"),
            CredentialRecordKey(rawValue: "account:\(fixture.deleted.id.rawValue):smtp-password"),
        ]
        let retainedKeys = [
            CredentialRecordKey(rawValue: "account:\(fixture.retained.id.rawValue):imap-password"),
            CredentialRecordKey(rawValue: "account:\(fixture.retained.id.rawValue):smtp-password"),
        ]
        for key in targetKeys {
            try await assembly.vault.store(Data("target-secret".utf8), for: key)
        }
        for key in retainedKeys {
            try await assembly.vault.store(Data("retained-secret".utf8), for: key)
        }
        let transports = AccountDeletionRemoteTransportProbe()
        let operations = accountDeletionAcceptanceOperations(
            applicationSupportURL: applicationSupportURL,
            store: store,
            assembly: assembly,
            transports: transports
        )
        await operations.reopenRuntimeConstruction()
        let requested = PlainpostForegroundOperation.deleteAccount(
            PlainpostAccountDeletionPayload(accountID: fixture.deleted.id.rawValue)
        )
        let decodedRequest = try PlainpostForegroundOperation(requestDTO: requested.requestDTO())

        let serviceResult = try await operations.perform(decodedRequest)
        let decodedResult = try PlainpostForegroundOperationResult(
            responseDTO: serviceResult.responseDTO()
        )

        guard case .deleteAccount = decodedResult else {
            return XCTFail("Expected account deletion response through the foreground IPC envelope.")
        }
        XCTAssertTrue(decodedResult.isSemanticallyCorrelated(with: requested))
        XCTAssertEqual(transports.snapshot(), .init(imap: 0, smtp: 0))
        XCTAssertFalse(store.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(store.accounts.contains { $0.id == fixture.retained.id })
        for key in targetKeys {
            let value = try await assembly.vault.load(key)
            XCTAssertNil(value, "Target credential survived: \(key.rawValue)")
        }
        for key in retainedKeys {
            let value = try await assembly.vault.load(key)
            XCTAssertEqual(
                value,
                Data("retained-secret".utf8),
                "Retained credential changed: \(key.rawValue)"
            )
        }
        let deletedOwnershipIDs = [
            fixture.deleted.id.rawValue,
            fixture.deletedDraftID.rawValue,
            "msg-delete-target",
            "thr-delete-target",
            "mbx-delete-inbox",
            "label-delete-target",
            "rule-delete-target",
            "schedule-delete-target",
            "artifact-delete-target",
            "receipt-delete-target",
            "device-compose:receipt-delete-target:recovery-key",
        ]
        try AccountDeletionFixtures.assertNoPersistedReferences(deletedOwnershipIDs, databaseURL: databaseURL)
        try AccountDeletionFixtures.assertNoAuditReferences(deletedOwnershipIDs, auditLogURL: store.auditLogURL)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM pragma_foreign_key_check", at: databaseURL), 0)
        XCTAssertEqual(try store.draft(id: fixture.retainedDraftID).id, fixture.retainedDraftID)
        XCTAssertEqual(try store.job(id: fixture.retainedJobID).id, fixture.retainedJobID)
        XCTAssertTrue(try store.mailRules(effectiveFor: fixture.retained.id).contains { $0.id == fixture.globalRule.id })
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM mail_labels WHERE id = 'label-global'", at: databaseURL), 1)
        XCTAssertEqual(try queryInteger("SELECT COUNT(*) FROM smart_inbox_batch_profiles", at: databaseURL), 1)
        XCTAssertTrue(store.auditEntries.contains { $0.id == "audit-retained" })
        XCTAssertFalse(store.auditEntries.contains { $0.id == "audit-delete-target" })
    }

    func testForegroundServiceIPCCleanupPendingRecoversAfterRestartAndRetryIsStateIdempotent() async throws {
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-account-deletion-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationSupportURL) }
        let databaseURL = applicationSupportURL.appendingPathComponent("plainpost.sqlite")
        let initial = try migratedStore(at: databaseURL)
        let fixture = try AccountDeletionFixtures.makeAccountDeletionFixture(store: initial, databaseURL: databaseURL)
        let flushed = try SQLiteMailStore(path: databaseURL.path)
        try flushed.migrate()
        let crashingStore = try SQLiteMailStore(
            path: databaseURL.path,
            auditRedactionFailpoint: { phase in
                if phase == .afterSQLiteCommit { throw SimulatedAuditRedactionCrash() }
            }
        )
        let provider = AccountDeletionAcceptanceVaultKeyProvider()
        let assembly = SQLiteCredentialVaultAssembly(store: crashingStore, provider: provider)
        try await assembly.unlockForeground(prompt: "Account deletion restart acceptance")
        let targetIMAP = CredentialRecordKey(
            rawValue: "account:\(fixture.deleted.id.rawValue):imap-password"
        )
        let targetSMTP = CredentialRecordKey(
            rawValue: "account:\(fixture.deleted.id.rawValue):smtp-password"
        )
        try await assembly.vault.store(Data("target-imap".utf8), for: targetIMAP)
        try await assembly.vault.store(Data("target-smtp".utf8), for: targetSMTP)
        let transports = AccountDeletionRemoteTransportProbe()
        let crashingOperations = accountDeletionAcceptanceOperations(
            applicationSupportURL: applicationSupportURL,
            store: crashingStore,
            assembly: assembly,
            transports: transports
        )
        await crashingOperations.reopenRuntimeConstruction()
        let request = PlainpostForegroundOperation.deleteAccount(
            PlainpostAccountDeletionPayload(accountID: fixture.deleted.id.rawValue)
        )
        let decoded = try PlainpostForegroundOperation(requestDTO: request.requestDTO())

        do {
            _ = try await crashingOperations.perform(decoded)
            XCTFail("Expected committed deletion to report pending audit cleanup.")
        } catch let error as AccountDeletionCleanupPendingError {
            XCTAssertEqual(error.accountID, fixture.deleted.id)
        }
        let removedIMAP = try await assembly.vault.load(targetIMAP)
        let removedSMTP = try await assembly.vault.load(targetSMTP)
        XCTAssertNil(removedIMAP)
        XCTAssertNil(removedSMTP)
        XCTAssertEqual(transports.snapshot(), .init(imap: 0, smtp: 0))

        let recoveredStore = try SQLiteMailStore(path: databaseURL.path)
        try recoveredStore.migrate()
        try recoveredStore.migrate()
        XCTAssertFalse(recoveredStore.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(recoveredStore.accounts.contains { $0.id == fixture.retained.id })
        XCTAssertFalse(recoveredStore.auditEntries.contains { $0.id == "audit-delete-target" })
        XCTAssertTrue(recoveredStore.auditEntries.contains { $0.id == "audit-retained" })
        let recoveredAssembly = SQLiteCredentialVaultAssembly(
            store: recoveredStore,
            provider: provider
        )
        try await recoveredAssembly.unlockForeground(prompt: "Account deletion retry acceptance")
        let retryOperations = accountDeletionAcceptanceOperations(
            applicationSupportURL: applicationSupportURL,
            store: recoveredStore,
            assembly: recoveredAssembly,
            transports: transports
        )
        await retryOperations.reopenRuntimeConstruction()
        do {
            _ = try await retryOperations.perform(decoded)
            XCTFail("A retry for the already-deleted account must not report a second deletion.")
        } catch {
            XCTAssertEqual(error as? PlainpostError, .notFound("Account not found."))
        }
        XCTAssertFalse(recoveredStore.accounts.contains { $0.id == fixture.deleted.id })
        XCTAssertTrue(recoveredStore.accounts.contains { $0.id == fixture.retained.id })
        XCTAssertFalse(recoveredStore.auditEntries.contains { $0.id == "audit-delete-target" })
        XCTAssertTrue(recoveredStore.auditEntries.contains { $0.id == "audit-retained" })
        XCTAssertEqual(transports.snapshot(), .init(imap: 0, smtp: 0))
    }

    private func accountDeletionAcceptanceOperations(
        applicationSupportURL: URL,
        store: SQLiteMailStore,
        assembly: SQLiteCredentialVaultAssembly,
        transports: AccountDeletionRemoteTransportProbe
    ) -> PlainpostServiceOperations {
        PlainpostServiceOperations(
            applicationSupportURL: applicationSupportURL,
            store: store,
            assembly: assembly,
            backgroundJobWakeScheduler: AccountDeletionNoopWakeScheduler(),
            accountRuntimeFactory: {
                AccountSetupService(
                    store: store,
                    credentials: assembly.vault,
                    imapClientFactory: { _, _ in
                        transports.recordIMAPConstruction()
                        fatalError("Account deletion must not construct an IMAP transport.")
                    },
                    smtpClientFactory: { _, _ in
                        transports.recordSMTPConstruction()
                        fatalError("Account deletion must not construct an SMTP transport.")
                    }
                )
            }
        )
    }

    private func migratedStore(at url: URL) throws -> SQLiteMailStore {
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        return store
    }

    /// These fixtures deliberately model a source change that happened outside
    /// the guarded CAS path, so the tests can verify stale-job fences even when
    /// an unresolved job is present. Production source changes must use CAS.
    private func queryInteger(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not prepare SQLite query.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PlainpostError.validationFailed("SQLite query returned no row.")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

}

private actor AccountDeletionAcceptanceVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x5A, count: 32)

    func createIfMissing() async throws {}

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        key
    }

    func countMatchingItems() async throws -> Int {
        1
    }
}

private final class AccountDeletionRemoteTransportProbe: @unchecked Sendable {
    struct Snapshot: Equatable {
        let imap: Int
        let smtp: Int
    }

    private let lock = NSLock()
    private var imapConstructions = 0
    private var smtpConstructions = 0

    func recordIMAPConstruction() {
        lock.withLock { imapConstructions += 1 }
    }

    func recordSMTPConstruction() {
        lock.withLock { smtpConstructions += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(imap: imapConstructions, smtp: smtpConstructions) }
    }
}

private actor AccountDeletionNoopWakeScheduler: BackgroundJobWakeScheduling {
    func replaceWake(
        at date: Date?,
        action: @escaping @Sendable () async -> Void
    ) async {}
}

private struct SimulatedAuditRedactionCrash: Error {}
