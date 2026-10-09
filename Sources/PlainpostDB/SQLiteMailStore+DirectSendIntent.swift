import Foundation
import GRDB
import PlainpostCore

public enum DirectSendState: String, Codable, Sendable {
    case reserved, submitting, sent, uncertain
}

public struct DirectSendIntent: Equatable, Sendable {
    public let draftID: DraftID
    public let contentHash: String
    public let accountID: AccountID
    /// Nil only for a legacy implicit Direct account.
    public let sourceGeneration: Int64?
    public let state: DirectSendState

    public init(draftID: DraftID, contentHash: String, accountID: AccountID, sourceGeneration: Int64?, state: DirectSendState) {
        self.draftID = draftID
        self.contentHash = contentHash
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.state = state
    }
}

public enum DirectSendIntentError: Error, Equatable, Sendable, LocalizedError {
    case draftMismatch
    case alreadySubmitted(DirectSendState)

    public var errorDescription: String? {
        switch self {
        case .draftMismatch: "The saved draft or its account changed before delivery."
        case .alreadySubmitted(.uncertain), .alreadySubmitted(.submitting):
            "Delivery is uncertain. Check Sent mail before taking further action."
        case .alreadySubmitted(.sent): "This draft was already sent."
        case .alreadySubmitted(.reserved): "This draft is already being sent."
        }
    }
}

extension SQLiteMailStore {
    func migrateDirectSendIntent() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v61-direct-send-intent") { database in
            try database.execute(sql: """
                CREATE TABLE direct_send_intents (
                    draft_id TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    state TEXT NOT NULL CHECK (state IN ('reserved', 'submitting', 'sent', 'uncertain')),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (draft_id, content_hash)
                );
                CREATE INDEX direct_send_intents_account ON direct_send_intents(account_id);
                """)
        }
        migrator.registerMigration("v62-direct-send-source-generation") { database in
            try database.execute(sql: "ALTER TABLE direct_send_intents ADD COLUMN source_generation INTEGER")
            let sourceTableExists = try Bool.fetchOne(database, sql: """
                SELECT EXISTS(SELECT 1 FROM sqlite_master
                              WHERE type = 'table' AND name = 'account_mail_sources')
                """) ?? false
            if sourceTableExists {
                try database.execute(sql: """
                    UPDATE direct_send_intents SET source_generation = (
                        SELECT generation FROM account_mail_sources
                        WHERE account_mail_sources.account_id = direct_send_intents.account_id
                          AND account_mail_sources.kind = 'direct'
                    )
                    """)
            }
        }
        try migrator.migrate(databasePool)
        try migrateNodeSendIntent()
        // A submitting row remains a durable no-retry barrier after a crash.
        // A second handle may migrate while SMTP is active, so opening the
        // cache must not change the first handle's settlement state.
    }
}

public extension SQLiteMailStore {
    func directSendIntent(draftID: DraftID, contentHash: String) throws -> DirectSendIntent? {
        try databasePool.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT draft_id, content_hash, account_id, source_generation, state FROM direct_send_intents WHERE draft_id = ? AND content_hash = ?", arguments: [draftID.rawValue, contentHash]) else { return nil }
            return try Self.decodeDirectSendIntent(row)
        }
    }

    func uncertainDirectSendIntents(accountID: AccountID) throws -> [DirectSendIntent] {
        try databasePool.read { database in
            try Row.fetchAll(database, sql: "SELECT draft_id, content_hash, account_id, source_generation, state FROM direct_send_intents WHERE account_id = ? AND state IN ('submitting', 'uncertain')", arguments: [accountID.rawValue])
                .map(Self.decodeDirectSendIntent)
        }
    }

    func reserveDirectSend(draftID: DraftID, contentHash: String, accountID: AccountID, allowImplicitDirectSource: Bool = false, allowNodeFallback: Bool = false) throws -> DirectSendIntent {
        try databasePool.write { database in
            guard let rawDraft = try String.fetchOne(database, sql: "SELECT payload_json FROM drafts WHERE id = ?", arguments: [draftID.rawValue]),
                  let draft = try? JSONDecoder().decode(Draft.self, from: Data(rawDraft.utf8)),
                  draft.accountID == accountID, draft.contentHash == contentHash else { throw DirectSendIntentError.draftMismatch }
            let source = try Row.fetchOne(database, sql: "SELECT kind, mode, generation FROM account_mail_sources WHERE account_id = ?", arguments: [accountID.rawValue])
            let generation: Int64?
            if let source {
                guard Self.isEligibleDirectSource(source, allowNodeFallback: allowNodeFallback) else { throw NodeMailModeStoreError.generationConflict }
                generation = source["generation"]
            } else {
                guard allowImplicitDirectSource else { throw NodeMailModeStoreError.schemaUnavailable }
                generation = nil
            }
            if let row = try Row.fetchOne(database, sql: "SELECT draft_id, content_hash, account_id, source_generation, state FROM direct_send_intents WHERE draft_id = ? AND content_hash = ?", arguments: [draftID.rawValue, contentHash]) {
                let existing = try Self.decodeDirectSendIntent(row)
                guard existing.accountID == accountID, existing.sourceGeneration == generation else { throw NodeMailModeStoreError.generationConflict }
                return existing
            }
            let now = Date().timeIntervalSince1970
            try database.execute(sql: "INSERT INTO direct_send_intents (draft_id, content_hash, account_id, source_generation, state, created_at, updated_at) VALUES (?, ?, ?, ?, 'reserved', ?, ?)", arguments: [draftID.rawValue, contentHash, accountID.rawValue, generation, now, now])
            return DirectSendIntent(draftID: draftID, contentHash: contentHash, accountID: accountID, sourceGeneration: generation, state: .reserved)
        }
    }

    func markDirectSendSubmitting(draftID: DraftID, contentHash: String) throws {
        guard let intent = try directSendIntent(draftID: draftID, contentHash: contentHash) else { throw DirectSendIntentError.draftMismatch }
        try markDirectSendSubmitting(intent, allowImplicitDirectSource: intent.sourceGeneration == nil)
    }

    func markDirectSendSubmitting(_ intent: DirectSendIntent, allowImplicitDirectSource: Bool, allowNodeFallback: Bool = false) throws {
        try databasePool.write { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT source_generation, state FROM direct_send_intents WHERE draft_id = ? AND content_hash = ?", arguments: [intent.draftID.rawValue, intent.contentHash]),
                  (row["source_generation"] as Int64?) == intent.sourceGeneration else {
                throw DirectSendIntentError.draftMismatch
            }
            try Self.checkDirectSource(database, intent: intent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
            try database.execute(sql: "UPDATE direct_send_intents SET state = 'submitting', updated_at = ? WHERE draft_id = ? AND content_hash = ? AND state = 'reserved'", arguments: [Date().timeIntervalSince1970, intent.draftID.rawValue, intent.contentHash])
            guard database.changesCount == 1 else { throw DirectSendIntentError.alreadySubmitted(try Self.directSendState(database, draftID: intent.draftID, contentHash: intent.contentHash)) }
        }
    }

    func requireUnchangedDirectSendSource(_ intent: DirectSendIntent, allowImplicitDirectSource: Bool, allowNodeFallback: Bool = false) throws {
        try databasePool.read { database in
            try Self.checkDirectSource(database, intent: intent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
        }
    }

    func markDirectSendUncertain(draftID: DraftID, contentHash: String) throws {
        try transitionDirectSend(draftID: draftID, contentHash: contentHash, from: .submitting, to: .uncertain)
    }

    func markDirectSendSent(_ intent: DirectSendIntent, allowImplicitDirectSource: Bool, allowNodeFallback: Bool = false) throws {
        try databasePool.write { database in
            try Self.checkDirectSource(database, intent: intent, allowImplicitDirectSource: allowImplicitDirectSource, allowNodeFallback: allowNodeFallback)
            try database.execute(sql: "UPDATE direct_send_intents SET state = 'sent', updated_at = ? WHERE draft_id = ? AND content_hash = ? AND state = 'submitting'", arguments: [Date().timeIntervalSince1970, intent.draftID.rawValue, intent.contentHash])
            guard database.changesCount == 1 else { throw DirectSendIntentError.alreadySubmitted(try Self.directSendState(database, draftID: intent.draftID, contentHash: intent.contentHash)) }

            // The SMTP outcome and durable intent have settled. Remove only
            // the exact revision that was sent; a newer local edit is still a
            // draft and must survive. The transition and deletion commit in
            // one SQLite transaction, so a crash cannot leave a sent draft.
            if let payload = try String.fetchOne(
                database, sql: "SELECT payload_json FROM drafts WHERE id = ?",
                arguments: [intent.draftID.rawValue]
            ) {
                let draft = try JSONDecoder().decode(Draft.self, from: Data(payload.utf8))
                if draft.accountID == intent.accountID && draft.contentHash == intent.contentHash {
                    try database.execute(sql: "DELETE FROM drafts WHERE id = ?", arguments: [intent.draftID.rawValue])
                }
            }
        }
    }

    func releaseDirectSendBeforeSubmission(draftID: DraftID, contentHash: String) throws {
        try databasePool.write { database in
            try database.execute(sql: "DELETE FROM direct_send_intents WHERE draft_id = ? AND content_hash = ? AND state = 'reserved'", arguments: [draftID.rawValue, contentHash])
        }
    }

    func releaseDirectSendAfterProvenPreSubmissionFailure(draftID: DraftID, contentHash: String) throws {
        try databasePool.write { database in
            try database.execute(sql: "DELETE FROM direct_send_intents WHERE draft_id = ? AND content_hash = ? AND state = 'submitting'", arguments: [draftID.rawValue, contentHash])
        }
    }

    private func transitionDirectSend(draftID: DraftID, contentHash: String, from: DirectSendState, to: DirectSendState) throws {
        try databasePool.write { database in
            try database.execute(sql: "UPDATE direct_send_intents SET state = ?, updated_at = ? WHERE draft_id = ? AND content_hash = ? AND state = ?", arguments: [to.rawValue, Date().timeIntervalSince1970, draftID.rawValue, contentHash, from.rawValue])
            guard database.changesCount == 1 else { throw DirectSendIntentError.alreadySubmitted(try Self.directSendState(database, draftID: draftID, contentHash: contentHash)) }
        }
    }

    private static func directSendState(_ database: Database, draftID: DraftID, contentHash: String) throws -> DirectSendState {
        let raw = try String.fetchOne(database, sql: "SELECT state FROM direct_send_intents WHERE draft_id = ? AND content_hash = ?", arguments: [draftID.rawValue, contentHash])
        return raw.flatMap(DirectSendState.init(rawValue:)) ?? .uncertain
    }

    private static func decodeDirectSendIntent(_ row: Row) throws -> DirectSendIntent {
        guard let state = DirectSendState(rawValue: row["state"]) else { throw DirectSendIntentError.draftMismatch }
        return DirectSendIntent(draftID: DraftID(row["draft_id"]), contentHash: row["content_hash"], accountID: AccountID(row["account_id"]), sourceGeneration: row["source_generation"], state: state)
    }

    private static func checkDirectSource(_ database: Database, intent: DirectSendIntent, allowImplicitDirectSource: Bool, allowNodeFallback: Bool) throws {
        let row = try Row.fetchOne(database, sql: "SELECT kind, mode, generation FROM account_mail_sources WHERE account_id = ?", arguments: [intent.accountID.rawValue])
        if let expected = intent.sourceGeneration, let row,
           Self.isEligibleDirectSource(row, allowNodeFallback: allowNodeFallback),
           (row["generation"] as Int64) == expected { return }
        if intent.sourceGeneration == nil, row == nil, allowImplicitDirectSource { return }
        throw NodeMailModeStoreError.generationConflict
    }

    private static func isEligibleDirectSource(_ row: Row, allowNodeFallback: Bool) -> Bool {
        if (row["kind"] as String) == AccountMailSourceKind.direct.rawValue { return true }
        return allowNodeFallback
            && (row["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue
            && (row["mode"] as String?) == NodeBackedMode.fallback.rawValue
    }
}
