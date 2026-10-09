import Foundation
import CryptoKit
import GRDB
import PlainpostCore

/// An authenticated Node result may close a send reservation. Pending and
/// delivery-uncertain results keep the source transition fenced. The Node's
/// terminal conflict means the provider was not asked to submit this send.
public enum NodeSendSettlement: String, Sendable {
    case pending, applied, rejected, conflicted, deliveryUncertain = "delivery_uncertain"
}

public enum NodeSendIntentError: Error, Equatable, Sendable {
    case missingReservation
    case operationMismatch
    case terminalReservation
    case missingCanonicalOperation
}

extension SQLiteMailStore {
    func migrateNodeSendIntent() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v63-node-send-intent") { database in
            try database.execute(sql: """
                CREATE TABLE node_send_intents (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    source_generation INTEGER NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    canonical_operation_sha256 BLOB NOT NULL CHECK (length(canonical_operation_sha256) = 32),
                    state TEXT NOT NULL CHECK (state IN ('reserved', 'pending', 'uncertain', 'applied', 'rejected', 'conflicted')),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (account_id, idempotency_key)
                );
                CREATE INDEX node_send_intents_unresolved
                    ON node_send_intents (account_id, state);
                """)
        }
        migrator.registerMigration("v64-node-send-canonical-operation") { database in
            try database.execute(sql: "ALTER TABLE node_send_intents ADD COLUMN canonical_operation BLOB")
        }
        try migrator.migrate(databasePool)
    }
}

public extension SQLiteMailStore {
    /// Exact signed bytes are required to reconcile a send after process death.
    /// A legacy hash-only reservation remains a fail-closed source fence.
    func unresolvedNodeSends(accountID: AccountID) throws -> [Data] {
        try databasePool.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT canonical_operation, canonical_operation_sha256
                FROM node_send_intents WHERE account_id = ?
                  AND state IN ('reserved', 'pending', 'uncertain')
                ORDER BY created_at, idempotency_key
                """, arguments: [accountID.rawValue])
            return try rows.map { row in
                guard let operation = row["canonical_operation"] as Data?,
                      !operation.isEmpty, operation.count <= 1_048_576,
                      Data(SHA256.hash(data: operation)) == (row["canonical_operation_sha256"] as Data) else {
                    throw NodeSendIntentError.missingCanonicalOperation
                }
                return operation
            }
        }
    }

    /// Call before a signed Node send leaves the process. Repeating
    /// the same idempotency key is allowed only for the same exact canonical
    /// operation at the same source generation. No message body is stored.
    func reserveNodeSend(accountID: AccountID, expectedGeneration: Int64,
                         nodeID: String, logicalMailboxID: String,
                         idempotencyKey: String, canonicalOperationSHA256: Data,
                         canonicalOperation: Data? = nil) throws {
        guard !idempotencyKey.isEmpty else { throw NodeSendIntentError.missingReservation }
        guard canonicalOperationSHA256.count == 32 else { throw NodeSendIntentError.operationMismatch }
        if let canonicalOperation {
            guard !canonicalOperation.isEmpty, canonicalOperation.count <= 1_048_576,
                  Data(SHA256.hash(data: canonicalOperation)) == canonicalOperationSHA256 else {
                throw NodeSendIntentError.operationMismatch
            }
        }
        try databasePool.write { database in
            let source = try Row.fetchOne(database, sql: """
                SELECT kind, generation, node_id, logical_mailbox_id
                FROM account_mail_sources WHERE account_id = ?
                """, arguments: [accountID.rawValue])
            guard let source,
                  (source["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue,
                  (source["generation"] as Int64) == expectedGeneration,
                  (source["node_id"] as String) == nodeID,
                  (source["logical_mailbox_id"] as String) == logicalMailboxID else {
                throw NodeMailModeStoreError.generationConflict
            }
            if let existing = try Row.fetchOne(database, sql: """
                SELECT source_generation, canonical_operation_sha256, canonical_operation, state FROM node_send_intents
                WHERE account_id = ? AND idempotency_key = ?
                """, arguments: [accountID.rawValue, idempotencyKey]) {
                guard (existing["source_generation"] as Int64) == expectedGeneration else {
                    throw NodeMailModeStoreError.generationConflict
                }
                guard (existing["canonical_operation_sha256"] as Data) == canonicalOperationSHA256 else {
                    throw NodeSendIntentError.operationMismatch
                }
                let state: String = existing["state"]
                guard ["reserved", "pending", "uncertain"].contains(state) else {
                    throw NodeSendIntentError.terminalReservation
                }
                if let canonicalOperation {
                    guard (existing["canonical_operation"] as Data?) == nil ||
                          (existing["canonical_operation"] as Data?) == canonicalOperation else {
                        throw NodeSendIntentError.operationMismatch
                    }
                    try database.execute(sql: """
                        UPDATE node_send_intents SET canonical_operation = ?
                        WHERE account_id = ? AND idempotency_key = ?
                        """, arguments: [canonicalOperation, accountID.rawValue, idempotencyKey])
                }
                return
            }
            let now = Date().timeIntervalSince1970
            try database.execute(sql: """
                INSERT INTO node_send_intents (account_id, source_generation,
                    idempotency_key, canonical_operation_sha256, canonical_operation, state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'reserved', ?, ?)
                """, arguments: [accountID.rawValue, expectedGeneration,
                                 idempotencyKey, canonicalOperationSHA256, canonicalOperation, now, now])
        }
    }

    /// Invoke only after an authenticated result with the matching operation
    /// idempotency key; transport errors do not settle delivery.
    func settleNodeSend(accountID: AccountID, expectedGeneration: Int64,
                        idempotencyKey: String, canonicalOperationSHA256: Data,
                        state: NodeSendSettlement) throws {
        guard canonicalOperationSHA256.count == 32 else { throw NodeSendIntentError.operationMismatch }
        try databasePool.write { database in
            let source = try Row.fetchOne(database, sql: """
                SELECT kind, generation FROM account_mail_sources WHERE account_id = ?
                """, arguments: [accountID.rawValue])
            guard let source,
                  (source["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue,
                  (source["generation"] as Int64) == expectedGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
            let existingDigest = try Data.fetchOne(database, sql: """
                SELECT canonical_operation_sha256 FROM node_send_intents
                WHERE account_id = ? AND source_generation = ? AND idempotency_key = ?
                """, arguments: [accountID.rawValue, expectedGeneration, idempotencyKey])
            guard let existingDigest else { throw NodeSendIntentError.missingReservation }
            guard existingDigest == canonicalOperationSHA256 else { throw NodeSendIntentError.operationMismatch }
            let mappedState: String = switch state {
            case .pending: "pending"
            case .deliveryUncertain: "uncertain"
            case .applied: "applied"
            case .rejected: "rejected"
            case .conflicted: "conflicted"
            }
            try database.execute(sql: """
                UPDATE node_send_intents SET state = ?, updated_at = ?
                WHERE account_id = ? AND source_generation = ? AND idempotency_key = ?
                  AND state IN ('reserved', 'pending', 'uncertain')
                """, arguments: [mappedState, Date().timeIntervalSince1970,
                                 accountID.rawValue, expectedGeneration, idempotencyKey])
            guard database.changesCount == 1 else { throw NodeSendIntentError.missingReservation }
        }
    }
}
