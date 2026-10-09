import Foundation
import GRDB
import PlainpostCore

enum SQLiteMailSearchSchemaError: Error, Equatable {
    case incompleteV22Schema
    case incompleteV23Schema
    case invalidProjectionCount(documents: Int, fts: Int)
    case missingCanonicalAccount(String)
    case missingCanonicalMessage(String)
}

package enum SQLiteMailSearchSchema {
    private static let requiredIndexes: Set<String> = [
        "mail_search_documents_account_sort",
        "mail_search_documents_attachments",
        "mail_search_documents_delegated",
        "mail_search_documents_documents",
        "mail_search_documents_flagged",
        "mail_search_documents_inbox",
        "mail_search_documents_sent",
        "mail_search_documents_thread_sort",
        "mail_search_documents_trash",
        "mail_search_documents_unread",
    ]

    private static let requiredTriggers: Set<String> = [
        "mail_search_documents_after_delete",
        "mail_search_documents_after_insert",
        "mail_search_documents_after_update",
    ]

    package static func createLegacyStructures(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS message_search_metadata (
                message_id TEXT PRIMARY KEY,
                from_value TEXT NOT NULL DEFAULT '',
                to_value TEXT NOT NULL DEFAULT '',
                cc_value TEXT NOT NULL DEFAULT '',
                bcc_value TEXT NOT NULL DEFAULT '',
                subject TEXT NOT NULL DEFAULT '',
                body_text TEXT NOT NULL DEFAULT '',
                attachment_filenames TEXT NOT NULL DEFAULT '',
                message_identifiers TEXT NOT NULL DEFAULT '',
                mailbox_path TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT ''
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
                message_id UNINDEXED,
                from_value,
                to_value,
                cc_value,
                bcc_value,
                subject,
                body_text,
                attachment_filenames,
                message_identifiers,
                mailbox_path,
                labels,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
    }

    package static func backfillLegacyStructures(_ database: Database) throws {
        try database.execute(sql: """
            INSERT OR IGNORE INTO message_search_metadata (
                message_id, from_value, subject, body_text, mailbox_path, labels
            )
            SELECT id, from_email, subject, body_text, mailbox_path, labels_json FROM messages;

            DELETE FROM message_fts;
            INSERT INTO message_fts (
                message_id, from_value, to_value, cc_value, bcc_value, subject, body_text,
                attachment_filenames, message_identifiers, mailbox_path, labels
            )
            SELECT message_id, from_value, to_value, cc_value, bcc_value, subject, body_text,
                attachment_filenames, message_identifiers, mailbox_path, labels
            FROM message_search_metadata;
            """)
    }

    package static func upgradeLegacySenderProjection(_ database: Database) throws {
        try database.execute(sql: """
            UPDATE message_search_metadata
            SET from_value = (
                SELECT trim(
                    m.from_email || CASE
                        WHEN NULLIF(trim(COALESCE(m.from_display_name, '')), '') IS NULL THEN ''
                        ELSE ' ' || trim(m.from_display_name)
                    END
                )
                FROM messages m
                WHERE m.id = message_search_metadata.message_id
            )
            WHERE EXISTS (
                SELECT 1 FROM messages m WHERE m.id = message_search_metadata.message_id
            );

            DELETE FROM message_fts;
            INSERT INTO message_fts (
                message_id, from_value, to_value, cc_value, bcc_value, subject, body_text,
                attachment_filenames, message_identifiers, mailbox_path, labels
            )
            SELECT message_id, from_value, to_value, cc_value, bcc_value, subject, body_text,
                attachment_filenames, message_identifiers, mailbox_path, labels
            FROM message_search_metadata;
            """)
    }

    package static func legacyStructuresAreAbsent(_ database: Database) throws -> Bool {
        try !database.tableExists("message_search_metadata")
            && !database.tableExists("message_fts")
    }

    package static func migrateV22(_ database: Database) throws {
        let newTables = try [
            "mail_search_documents", "mail_search_fts", "mail_search_state",
            "mail_search_maintenance",
        ].map {
            try database.tableExists($0)
        }
        let legacyTables = try ["message_search_metadata", "message_fts"].map {
            try database.tableExists($0)
        }

        if newTables.contains(true) {
            guard newTables.allSatisfy({ $0 }), legacyTables.allSatisfy({ !$0 }) else {
                throw SQLiteMailSearchSchemaError.incompleteV22Schema
            }
            try runFTSIntegrityCheck(database)
            try validateV22(database)
            return
        }
        guard legacyTables.allSatisfy({ $0 }) else {
            throw SQLiteMailSearchSchemaError.incompleteV22Schema
        }

        let legacyMetadata = try readLegacySearchMetadata(database)
        try createTablesAndIndexes(database)
        try database.execute(sql: """
            INSERT INTO mail_search_state(account_id, revision, state, updated_at)
            SELECT id, 0, 'preparing', CAST(strftime('%s', 'now') AS REAL)
            FROM accounts
            """)

        try backfillProjectionV22Migration(
            database,
            retainedMetadataByMessageID: legacyMetadata
        )
        try database.execute(sql: "INSERT INTO mail_search_fts(mail_search_fts) VALUES('rebuild')")
        try createSynchronizationTriggers(database)
        try runFTSIntegrityCheck(database)
        try validateProjectionRows(database)
        try dropLegacySearchStructures(database)

        try database.execute(sql: """
            INSERT INTO mail_search_state(account_id, revision, state, updated_at)
            SELECT account_id, 1, 'ready', CAST(strftime('%s', 'now') AS REAL)
            FROM mail_search_documents
            GROUP BY account_id
            ON CONFLICT(account_id) DO UPDATE SET
                revision = CASE WHEN mail_search_state.revision < 1 THEN 1 ELSE mail_search_state.revision + 1 END,
                state = 'ready',
                updated_at = excluded.updated_at;

            UPDATE mail_search_state
            SET revision = CASE WHEN revision < 1 THEN 1 ELSE revision END,
                state = 'ready',
                updated_at = CAST(strftime('%s', 'now') AS REAL);

            PRAGMA user_version = 22;
            """)
        try validateV22(database)
    }

    package static func validate(_ database: Database) throws {
        try validateV22(database, expectedUserVersion: 23)
        let columns = try Set(database.columns(in: "mail_search_documents").map(\.name))
        guard columns.contains("attachment_metadata_json") else {
            throw SQLiteMailSearchSchemaError.incompleteV23Schema
        }
    }

    package static func migrateV23(_ database: Database) throws {
        let userVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        let columns = try Set(database.columns(in: "mail_search_documents").map(\.name))
        if userVersion == 23 {
            try validate(database)
            return
        }
        guard userVersion == 22,
              !columns.contains("attachment_metadata_json") else {
            throw SQLiteMailSearchSchemaError.incompleteV23Schema
        }

        // The JSON column is not FTS content. Pausing the projection triggers
        // prevents the one-time metadata backfill from appending a delete and
        // insert segment for every existing message or advancing search state.
        try validateV22(database)
        try dropSynchronizationTriggers(database)
        try database.execute(sql: """
            ALTER TABLE mail_search_documents
            ADD COLUMN attachment_metadata_json TEXT NOT NULL DEFAULT '[]';
            """)
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT message_id, filenames FROM mail_search_documents ORDER BY message_id"
        )
        for row in rows {
            let filenames: String = row["filenames"]
            // v22 durably retained only a whitespace-delimited filename projection.
            // v23 records those legacy names with absent MIME so the shared classifier
            // deliberately falls back to extensions until fresh sync metadata arrives.
            let attachments = filenames
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { IncomingMessageAttachmentMetadata(filename: $0, mimeType: nil) }
            let encoded = String(
                decoding: try MailSearchJSON.encoder().encode(attachments),
                as: UTF8.self
            )
            try database.execute(
                sql: """
                    UPDATE mail_search_documents
                    SET attachment_metadata_json = ?
                    WHERE message_id = ?
                    """,
                arguments: [encoded, row["message_id"] as String]
            )
        }
        try createSynchronizationTriggers(database)
        try database.execute(sql: "PRAGMA user_version = 23")
        try validate(database)
    }

    private static func validateV22(
        _ database: Database,
        expectedUserVersion: Int = 22
    ) throws {
        let requiredTables = [
            "mail_search_documents", "mail_search_fts", "mail_search_state",
            "mail_search_maintenance",
        ]
        let hasRequiredTables = try requiredTables.allSatisfy { try database.tableExists($0) }
        let hasLegacyTables = try !legacyStructuresAreAbsent(database)
        let indexes = try Set(String.fetchAll(
            database,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index'
                  AND tbl_name = 'mail_search_documents'
                  AND sql IS NOT NULL
                """
        ))
        let triggers = try Set(String.fetchAll(
            database,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND tbl_name = 'mail_search_documents'
                """
        ))
        let userVersion = try Int.fetchOne(database, sql: "PRAGMA user_version")
        guard hasRequiredTables,
              !hasLegacyTables,
              indexes == requiredIndexes,
              triggers == requiredTriggers,
              userVersion == expectedUserVersion else {
            throw SQLiteMailSearchSchemaError.incompleteV22Schema
        }

        try validateProjectionRows(database)
    }

    package static func validateFTSIntegrity(_ database: Database) throws {
        try runFTSIntegrityCheck(database)
    }

    private static func validateProjectionRows(_ database: Database) throws {
        let documentCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_documents") ?? 0
        let ftsCount = try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_fts") ?? 0
        let indexedDocumentCount = try Int.fetchOne(
            database,
            sql: "SELECT count(*) FROM mail_search_fts_docsize"
        ) ?? 0
        let missingIndexedRows = try Int.fetchOne(
            database,
            sql: """
                SELECT count(*)
                FROM mail_search_documents d
                LEFT JOIN mail_search_fts_docsize s ON s.id = d.rowid
                WHERE s.id IS NULL
                """
        ) ?? 0
        guard documentCount == ftsCount,
              documentCount == indexedDocumentCount,
              missingIndexedRows == 0 else {
            throw SQLiteMailSearchSchemaError.invalidProjectionCount(
                documents: documentCount,
                fts: indexedDocumentCount
            )
        }
    }

    package static func rebuild(_ database: Database) throws {
        try markRebuilding(database, now: Date())
        try rebuildMarked(database)
    }

    package static func prepareDatabase(_ database: Database) throws {
        try database.execute(sql: "PRAGMA optimize=0x10002")
    }

    package static func markRebuilding(_ database: Database, now: Date) throws {
        let alreadyRebuilding = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM mail_search_state WHERE state = 'rebuilding')"
        ) ?? false
        guard !alreadyRebuilding else { throw MailSearchError.rebuilding }
        let timestamp = now.timeIntervalSince1970
        try database.execute(
            sql: """
                INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                SELECT id, 0, 'rebuilding', ? FROM accounts WHERE 1
                ON CONFLICT(account_id) DO UPDATE SET
                    state = 'rebuilding',
                    updated_at = excluded.updated_at;

                UPDATE mail_search_state
                SET state = 'rebuilding', updated_at = ?;
                """,
            arguments: [timestamp, timestamp]
        )
    }

    package static func markUnavailable(_ database: Database, now: Date) throws {
        try database.execute(
            sql: """
                UPDATE mail_search_state
                SET state = 'unavailable', updated_at = ?
                WHERE state = 'rebuilding'
                """,
            arguments: [now.timeIntervalSince1970]
        )
    }

    package static func performMaintenanceIfDue(
        _ database: Database,
        now: Date,
        minimumInterval: TimeInterval = 24 * 60 * 60,
        optimize: (Database) throws -> Void = { database in
            try database.execute(sql: "PRAGMA optimize")
        }
    ) throws {
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else { return }
        let guardRow = try Row.fetchOne(
            database,
            sql: """
                SELECT typeof(last_optimized_at) AS storage_class, last_optimized_at
                FROM mail_search_maintenance WHERE singleton = 1
                """
        )
        if let guardRow {
            let storageClass: String = guardRow["storage_class"]
            if storageClass == "integer" || storageClass == "real" {
                let last: Double? = guardRow["last_optimized_at"]
                if let last,
                   last.isFinite,
                   last >= 0,
                   last <= timestamp,
                   timestamp - last < minimumInterval {
                    return
                }
            }
        }

        try optimize(database)
        try database.execute(
            sql: """
                INSERT INTO mail_search_maintenance(singleton, last_optimized_at)
                VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    last_optimized_at = excluded.last_optimized_at
                """,
            arguments: [timestamp]
        )
    }

    package static func rebuildMarked(
        _ database: Database,
        beforeReadyPublication: @Sendable () -> Void = {}
    ) throws {
        try Task.checkCancellation()
        var affectedAccountIDs = try Set(String.fetchAll(
            database,
            sql: """
                SELECT account_id FROM mail_search_state
                UNION
                SELECT account_id FROM mail_search_documents
                UNION
                SELECT id FROM accounts
                """
        ))
        try dropSynchronizationTriggers(database)
        try Task.checkCancellation()
        try database.execute(sql: """
            DELETE FROM mail_search_documents
            WHERE NOT EXISTS (
                SELECT 1 FROM messages WHERE messages.id = mail_search_documents.message_id
            )
        """)
        try refreshProjectionForRebuild(database)
        try Task.checkCancellation()
        affectedAccountIDs.formUnion(try String.fetchAll(
            database,
            sql: "SELECT DISTINCT account_id FROM mail_search_documents"
        ))
        try database.execute(sql: "INSERT INTO mail_search_fts(mail_search_fts) VALUES('rebuild')")
        try Task.checkCancellation()
        try createSynchronizationTriggers(database)
        try runFTSIntegrityCheck(database)
        try validate(database)
        try database.execute(sql: "INSERT INTO mail_search_fts(mail_search_fts) VALUES('optimize')")
        beforeReadyPublication()
        try Task.checkCancellation()
        for accountID in affectedAccountIDs.sorted() {
            try database.execute(
                sql: """
                    INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                    VALUES (?, 1, 'ready', CAST(strftime('%s', 'now') AS REAL))
                    ON CONFLICT(account_id) DO UPDATE SET
                        revision = mail_search_state.revision + 1,
                        state = 'ready',
                        updated_at = excluded.updated_at
                    """,
                arguments: [accountID]
            )
        }
    }

    private static func createTablesAndIndexes(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE mail_search_documents (
                rowid INTEGER PRIMARY KEY,
                message_id TEXT NOT NULL UNIQUE,
                thread_id TEXT,
                account_id TEXT NOT NULL,
                sent_at REAL,
                sort_date REAL NOT NULL,
                sender TEXT NOT NULL DEFAULT '',
                sender_email TEXT NOT NULL DEFAULT '',
                sender_display_name TEXT,
                to_value TEXT NOT NULL DEFAULT '',
                cc_value TEXT NOT NULL DEFAULT '',
                bcc_value TEXT NOT NULL DEFAULT '',
                subject TEXT NOT NULL DEFAULT '',
                preview TEXT NOT NULL DEFAULT '',
                body_text TEXT NOT NULL DEFAULT '',
                filenames TEXT NOT NULL DEFAULT '',
                identifiers TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT '',
                mailbox_ids TEXT NOT NULL DEFAULT '',
                mailbox_names TEXT NOT NULL DEFAULT '',
                is_seen INTEGER NOT NULL CHECK (is_seen IN (0, 1)),
                is_flagged INTEGER NOT NULL CHECK (is_flagged IN (0, 1)),
                is_delegated INTEGER NOT NULL CHECK (is_delegated IN (0, 1)),
                is_deleted INTEGER NOT NULL CHECK (is_deleted IN (0, 1)),
                is_trash INTEGER NOT NULL CHECK (is_trash IN (0, 1)),
                is_inbox INTEGER NOT NULL CHECK (is_inbox IN (0, 1)),
                is_sent INTEGER NOT NULL CHECK (is_sent IN (0, 1)),
                has_attachments INTEGER NOT NULL CHECK (has_attachments IN (0, 1)),
                has_documents INTEGER NOT NULL CHECK (has_documents IN (0, 1))
            );

            CREATE VIRTUAL TABLE mail_search_fts USING fts5(
                sender, to_value, cc_value, bcc_value, subject, filenames,
                labels, mailbox_names, identifiers, body_text,
                content='mail_search_documents',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TABLE mail_search_state (
                account_id TEXT PRIMARY KEY,
                revision INTEGER NOT NULL CHECK (revision >= 0),
                state TEXT NOT NULL CHECK (state IN ('preparing', 'ready', 'rebuilding', 'unavailable')),
                updated_at REAL NOT NULL
            );

            CREATE TABLE mail_search_maintenance (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                last_optimized_at REAL
            );

            INSERT INTO mail_search_maintenance(singleton, last_optimized_at)
            VALUES (1, NULL);

            CREATE INDEX mail_search_documents_account_sort
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC);
            CREATE INDEX mail_search_documents_thread_sort
                ON mail_search_documents(thread_id, sort_date DESC, message_id ASC);
            CREATE INDEX mail_search_documents_unread
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_seen = 0;
            CREATE INDEX mail_search_documents_flagged
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_flagged = 1;
            CREATE INDEX mail_search_documents_delegated
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_delegated = 1;
            CREATE INDEX mail_search_documents_attachments
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE has_attachments = 1;
            CREATE INDEX mail_search_documents_documents
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE has_documents = 1;
            CREATE INDEX mail_search_documents_inbox
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_inbox = 1;
            CREATE INDEX mail_search_documents_sent
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_sent = 1;
            CREATE INDEX mail_search_documents_trash
                ON mail_search_documents(account_id, sort_date DESC, message_id ASC) WHERE is_trash = 1;
            """)
    }

    private static func runFTSIntegrityCheck(_ database: Database) throws {
        try database.execute(
            sql: "INSERT INTO mail_search_fts(mail_search_fts, rank) VALUES('integrity-check', 1)"
        )
    }

    private static func backfillProjectionV22Migration(
        _ database: Database,
        retainedMetadataByMessageID: [String: SQLiteMailSearchRetainedMetadata] = [:]
    ) throws {
        let messageIDs = try String.fetchAll(database, sql: "SELECT id FROM messages ORDER BY id")
        for messageID in messageIDs {
            try Task.checkCancellation()
            try SQLiteMailSearchProjectionWriter.upsertV22Migration(
                messageID: MessageID(messageID),
                retainedMetadata: retainedMetadataByMessageID[messageID],
                database: database
            )
        }
    }

    private static func refreshProjectionForRebuild(_ database: Database) throws {
        let messageIDs = try String.fetchAll(database, sql: "SELECT id FROM messages ORDER BY id")
        for messageID in messageIDs {
            try Task.checkCancellation()
            try SQLiteMailSearchProjectionWriter.upsert(
                messageID: MessageID(messageID),
                metadata: nil,
                database: database
            )
        }
    }

    private static func readLegacySearchMetadata(
        _ database: Database
    ) throws -> [String: SQLiteMailSearchRetainedMetadata] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT message_id, to_value, cc_value, bcc_value,
                       attachment_filenames, message_identifiers
                FROM message_search_metadata
                """
        )
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let messageID: String = row["message_id"]
            return (
                messageID,
                SQLiteMailSearchRetainedMetadata(
                    to: row["to_value"],
                    cc: row["cc_value"],
                    bcc: row["bcc_value"],
                    filenames: row["attachment_filenames"],
                    attachments: String(row["attachment_filenames"] as String)
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .map { IncomingMessageAttachmentMetadata(filename: $0, mimeType: nil) },
                    identifiers: row["message_identifiers"]
                )
            )
        })
    }

    private static func createSynchronizationTriggers(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TRIGGER mail_search_documents_after_insert
            AFTER INSERT ON mail_search_documents BEGIN
                INSERT INTO mail_search_fts(
                    rowid, sender, to_value, cc_value, bcc_value, subject, filenames,
                    labels, mailbox_names, identifiers, body_text
                ) VALUES (
                    new.rowid, new.sender, new.to_value, new.cc_value, new.bcc_value,
                    new.subject, new.filenames, new.labels, new.mailbox_names,
                    new.identifiers, new.body_text
                );
                INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                VALUES (new.account_id, 1, 'ready', CAST(strftime('%s', 'now') AS REAL))
                ON CONFLICT(account_id) DO UPDATE SET
                    revision = mail_search_state.revision + 1,
                    updated_at = excluded.updated_at;
            END;

            CREATE TRIGGER mail_search_documents_after_delete
            AFTER DELETE ON mail_search_documents BEGIN
                INSERT INTO mail_search_fts(
                    mail_search_fts, rowid, sender, to_value, cc_value, bcc_value, subject,
                    filenames, labels, mailbox_names, identifiers, body_text
                ) VALUES (
                    'delete', old.rowid, old.sender, old.to_value, old.cc_value, old.bcc_value,
                    old.subject, old.filenames, old.labels, old.mailbox_names,
                    old.identifiers, old.body_text
                );
                INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                VALUES (old.account_id, 1, 'ready', CAST(strftime('%s', 'now') AS REAL))
                ON CONFLICT(account_id) DO UPDATE SET
                    revision = mail_search_state.revision + 1,
                    updated_at = excluded.updated_at;
            END;

            CREATE TRIGGER mail_search_documents_after_update
            AFTER UPDATE ON mail_search_documents BEGIN
                INSERT INTO mail_search_fts(
                    mail_search_fts, rowid, sender, to_value, cc_value, bcc_value, subject,
                    filenames, labels, mailbox_names, identifiers, body_text
                ) VALUES (
                    'delete', old.rowid, old.sender, old.to_value, old.cc_value, old.bcc_value,
                    old.subject, old.filenames, old.labels, old.mailbox_names,
                    old.identifiers, old.body_text
                );
                INSERT INTO mail_search_fts(
                    rowid, sender, to_value, cc_value, bcc_value, subject, filenames,
                    labels, mailbox_names, identifiers, body_text
                ) VALUES (
                    new.rowid, new.sender, new.to_value, new.cc_value, new.bcc_value,
                    new.subject, new.filenames, new.labels, new.mailbox_names,
                    new.identifiers, new.body_text
                );
                UPDATE mail_search_state
                SET revision = revision + 1,
                    updated_at = CAST(strftime('%s', 'now') AS REAL)
                WHERE account_id = old.account_id AND old.account_id <> new.account_id;
                INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                VALUES (new.account_id, 1, 'ready', CAST(strftime('%s', 'now') AS REAL))
                ON CONFLICT(account_id) DO UPDATE SET
                    revision = mail_search_state.revision + 1,
                    updated_at = excluded.updated_at;
            END;
            """)
    }

    private static func dropSynchronizationTriggers(_ database: Database) throws {
        try database.execute(sql: """
            DROP TRIGGER IF EXISTS mail_search_documents_after_insert;
            DROP TRIGGER IF EXISTS mail_search_documents_after_delete;
            DROP TRIGGER IF EXISTS mail_search_documents_after_update;
            """)
    }

    private static func dropLegacySearchStructures(_ database: Database) throws {
        let triggerNames = try String.fetchAll(
            database,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'trigger' AND tbl_name IN ('message_search_metadata', 'message_fts')
                """
        )
        for triggerName in triggerNames {
            let quoted = triggerName.replacingOccurrences(of: "\"", with: "\"\"")
            try database.execute(sql: "DROP TRIGGER IF EXISTS \"\(quoted)\"")
        }
        try database.execute(sql: """
            DROP TABLE message_fts;
            DROP TABLE message_search_metadata;
            """)
    }
}
