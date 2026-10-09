import Foundation
import GRDB
import PlainpostSecrets

public final class SQLiteCredentialCiphertextRepository: CredentialCiphertextRepository, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func save(_ value: SealedCredential, for key: CredentialRecordKey) async throws {
        let timestamp = String(Date().timeIntervalSince1970)
        let version = Int(value.combined.first ?? 0)

        try await databaseWriter.write { database in
            try database.execute(
                sql: """
                    INSERT INTO credential_ciphertexts (
                        record_key, version, combined, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(record_key) DO UPDATE SET
                        version = excluded.version,
                        combined = excluded.combined,
                        updated_at = excluded.updated_at
                    """,
                arguments: [key.rawValue, version, value.combined, timestamp, timestamp]
            )
        }
    }

    public func load(_ key: CredentialRecordKey) async throws -> SealedCredential? {
        try await databaseWriter.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT combined FROM credential_ciphertexts WHERE record_key = ?",
                arguments: [key.rawValue]
            ).map(SealedCredential.init(combined:))
        }
    }

    public func remove(_ key: CredentialRecordKey) async throws {
        try await databaseWriter.write { database in
            try database.execute(
                sql: "DELETE FROM credential_ciphertexts WHERE record_key = ?",
                arguments: [key.rawValue]
            )
        }
    }

    public func loadOrCreate(
        _ keys: [CredentialRecordKey],
        create: @escaping @Sendable () throws -> [SealedCredential]
    ) async throws -> [SealedCredential?] {
        try await databaseWriter.write { database in
            let current = try keys.map { key in
                try Data.fetchOne(
                    database,
                    sql: "SELECT combined FROM credential_ciphertexts WHERE record_key = ?",
                    arguments: [key.rawValue]
                ).map(SealedCredential.init(combined:))
            }
            guard current.allSatisfy({ $0 == nil }) else { return current }
            let created = try create()
            guard created.count == keys.count,
                  Set(keys).count == keys.count else {
                throw CredentialVaultError.ciphertextInvalid
            }
            try Task.checkCancellation()
            let timestamp = String(Date().timeIntervalSince1970)
            for (key, value) in zip(keys, created) {
                try database.execute(
                    sql: """
                        INSERT INTO credential_ciphertexts (
                            record_key, version, combined, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        key.rawValue,
                        Int(value.combined.first ?? 0),
                        value.combined,
                        timestamp,
                        timestamp,
                    ]
                )
            }
            return created.map(Optional.some)
        }
    }

    /// Moves every encrypted credential into `credential_ciphertexts_archive`
    /// and marks each account whose sign-in was among them as needing to sign
    /// in again, in one transaction. Only for a vault key that is gone for good:
    /// the caller must have confirmed that no key item exists. Returns how many
    /// records were archived.
    @discardableResult
    func archiveAllAfterKeyLoss() async throws -> Int {
        let timestamp = Date().timeIntervalSince1970
        return try await databaseWriter.write { database in
            try database.execute(
                sql: """
                    INSERT INTO credential_ciphertexts_archive (
                        record_key, version, combined, created_at, updated_at, archived_at, reason
                    )
                    SELECT record_key, version, combined, created_at, updated_at, ?, 'key_missing'
                    FROM credential_ciphertexts
                    ORDER BY record_key
                    """,
                arguments: [String(timestamp)]
            )
            let archived = database.changesCount
            guard archived > 0 else { return 0 }
            // An absent row is a ready password account, so every account
            // that lost a record gets an explicit row.
            try database.execute(
                sql: """
                    INSERT INTO account_authentication (account_id, method, state, updated_at)
                    SELECT accounts.id, 'password', 'reauthorization_required', ?
                    FROM accounts
                    WHERE EXISTS (
                        SELECT 1 FROM credential_ciphertexts credentials
                        WHERE substr(credentials.record_key, 1, length('account:' || accounts.id || ':'))
                            = 'account:' || accounts.id || ':'
                    )
                    ON CONFLICT(account_id) DO UPDATE SET
                        state = 'reauthorization_required',
                        updated_at = excluded.updated_at
                    """,
                arguments: [timestamp]
            )
            try database.execute(sql: "DELETE FROM credential_ciphertexts")
            return archived
        }
    }

    public func hasRecords() async throws -> Bool {
        try await databaseWriter.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM credential_ciphertexts)"
            ) ?? false
        }
    }

}
