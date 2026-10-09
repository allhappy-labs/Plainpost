import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class SQLiteMailSearchMigrationTests: XCTestCase {
    func testV23AddsDurableAttachmentMetadataWithoutMutatingV22() throws {
        let fixture = try LegacySearchDatabaseFixture.make()
        try fixture.write(SQLiteMailSearchSchema.migrateV22)

        XCTAssertEqual(try fixture.scalar("PRAGMA user_version"), 22)
        XCTAssertFalse(try fixture.columnNames(table: "mail_search_documents").contains("attachment_metadata_json"))
        let revisionBefore = try fixture.scalar(
            "SELECT revision FROM mail_search_state WHERE account_id = 'a1'"
        )

        try fixture.write(SQLiteMailSearchSchema.migrateV23)

        XCTAssertEqual(try fixture.scalar("PRAGMA user_version"), 23)
        XCTAssertEqual(
            try fixture.text("SELECT attachment_metadata_json FROM mail_search_documents"),
            #"[{"filename":"forecast.pdf"}]"#
        )
        XCTAssertEqual(
            try fixture.scalar("SELECT revision FROM mail_search_state WHERE account_id = 'a1'"),
            revisionBefore
        )
        XCTAssertNoThrow(try fixture.read(SQLiteMailSearchSchema.validate))
    }

    func testProjectionUsesMIMEBeforeFilenameAndRetainsMetadataAcrossRefresh() throws {
        let fixture = try SearchSchemaFixture.make()

        try fixture.write { database in
            try SQLiteMailSearchSchema.migrateV23(database)
            try SQLiteMailSearchProjectionWriter.upsert(
                messageID: MessageID("m1"),
                metadata: IncomingMessageSearchMetadata(
                    to: [],
                    cc: [],
                    bcc: [],
                    attachments: [
                        .init(filename: "extensionless", mimeType: "application/pdf"),
                        .init(filename: "misleading.pdf", mimeType: "image/png"),
                    ],
                    messageIdentifiers: []
                ),
                database: database
            )
        }

        XCTAssertEqual(try fixture.scalar("SELECT has_attachments FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 1)
        XCTAssertEqual(
            try fixture.text("SELECT attachment_metadata_json FROM mail_search_documents"),
            #"[{"filename":"extensionless","mimeType":"application/pdf"},{"filename":"misleading.pdf","mimeType":"image/png"}]"#
        )

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID("m1"), database: database)
        }
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 1)
        XCTAssertEqual(
            try fixture.text("SELECT attachment_metadata_json FROM mail_search_documents"),
            #"[{"filename":"extensionless","mimeType":"application/pdf"},{"filename":"misleading.pdf","mimeType":"image/png"}]"#
        )

        try fixture.write(SQLiteMailSearchSchema.rebuild)
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 1)
        XCTAssertEqual(
            try fixture.text("SELECT attachment_metadata_json FROM mail_search_documents"),
            #"[{"filename":"extensionless","mimeType":"application/pdf"},{"filename":"misleading.pdf","mimeType":"image/png"}]"#
        )

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.upsert(
                messageID: MessageID("m1"),
                metadata: IncomingMessageSearchMetadata(
                    to: [],
                    cc: [],
                    bcc: [],
                    attachments: [
                        .init(filename: "misleading.pdf", mimeType: "image/png"),
                    ],
                    messageIdentifiers: []
                ),
                database: database
            )
        }
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 0)
        try fixture.write(SQLiteMailSearchSchema.rebuild)
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 0)
        XCTAssertEqual(
            try fixture.text("SELECT attachment_metadata_json FROM mail_search_documents"),
            #"[{"filename":"misleading.pdf","mimeType":"image/png"}]"#
        )
    }
    func testV22BackfillsExternalContentAndDropsLegacySearchTables() throws {
        let fixture = try LegacySearchDatabaseFixture.make()

        try fixture.write(SQLiteMailSearchSchema.migrateV22)

        XCTAssertEqual(try fixture.scalar("SELECT count(*) FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT count(*) FROM mail_search_fts"), 1)
        XCTAssertEqual(try fixture.text("SELECT bcc_value FROM mail_search_documents"), "legal@example.com")
        XCTAssertEqual(try fixture.text("SELECT filenames FROM mail_search_documents"), "forecast.pdf")
        XCTAssertEqual(try fixture.text("SELECT identifiers FROM mail_search_documents"), "<forecast@example.com>")
        XCTAssertEqual(try fixture.scalar("SELECT has_attachments FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_flagged FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_delegated FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_inbox FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.text("SELECT mailbox_ids FROM mail_search_documents"), "mb-inbox")
        XCTAssertEqual(try fixture.text("SELECT mailbox_names FROM mail_search_documents"), "Inbox")
        XCTAssertFalse(try fixture.tableExists("message_search_metadata"))
        XCTAssertFalse(try fixture.tableExists("message_fts"))
        try fixture.write(SQLiteMailSearchSchema.migrateV23)
        XCTAssertNoThrow(try fixture.read(SQLiteMailSearchSchema.validate))
    }

    func testV22UsesExternalContentFTSWithoutPrefixOrTrigramIndexes() throws {
        let fixture = try LegacySearchDatabaseFixture.make()
        try fixture.write(SQLiteMailSearchSchema.migrateV22)

        let ftsSQL = try XCTUnwrap(try fixture.schemaSQL(type: "table", name: "mail_search_fts"))
        XCTAssertTrue(ftsSQL.contains("content='mail_search_documents'"))
        XCTAssertTrue(ftsSQL.contains("content_rowid='rowid'"))
        XCTAssertTrue(ftsSQL.contains("tokenize='unicode61 remove_diacritics 2'"))
        XCTAssertFalse(ftsSQL.localizedCaseInsensitiveContains("prefix"))
        XCTAssertFalse(ftsSQL.localizedCaseInsensitiveContains("trigram"))

        XCTAssertEqual(
            Set(try fixture.schemaNames(type: "index", prefix: "mail_search_documents_")),
            [
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
        )
        XCTAssertEqual(
            Set(try fixture.schemaNames(type: "trigger", prefix: "mail_search_documents_")),
            [
                "mail_search_documents_after_delete",
                "mail_search_documents_after_insert",
                "mail_search_documents_after_update",
            ]
        )
    }

    func testProjectionTriggerUpdatesFTSAndRevision() throws {
        let fixture = try SearchSchemaFixture.make()
        let before = try fixture.revision(accountID: "a1")

        try fixture.updateProjectionSubject("Revised forecast")

        XCTAssertEqual(try fixture.ftsMatch("revised"), ["m1"])
        XCTAssertEqual(try fixture.ftsMatch("quarterly"), [])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }

    func testProjectionWriterPreservesRowIDAndLegacyOnlyMetadataWhenMetadataIsNil() throws {
        let fixture = try SearchSchemaFixture.make()
        let before = try fixture.scalar("SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'")
        let revisionBefore = try fixture.revision(accountID: "a1")
        try fixture.execute("""
            UPDATE messages
            SET subject = 'Canonical revision', body_text = 'Updated body', labels_json = '["Client"]'
            WHERE id = 'm1'
            """)

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.upsert(
                messageID: MessageID("m1"),
                metadata: nil,
                database: database
            )
        }

        XCTAssertEqual(try fixture.scalar("SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'"), before)
        XCTAssertEqual(try fixture.text("SELECT subject FROM mail_search_documents WHERE message_id = 'm1'"), "Canonical revision")
        XCTAssertEqual(try fixture.text("SELECT bcc_value FROM mail_search_documents WHERE message_id = 'm1'"), "legal@example.com")
        XCTAssertEqual(try fixture.text("SELECT filenames FROM mail_search_documents WHERE message_id = 'm1'"), "forecast.pdf")
        XCTAssertEqual(try fixture.text("SELECT identifiers FROM mail_search_documents WHERE message_id = 'm1'"), "<forecast@example.com>")
        XCTAssertEqual(try fixture.ftsMatch("updated"), ["m1"])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), revisionBefore + 1)
    }

    func testProjectionWriterNoOpDoesNotUpdateProjectionFTSOrRevision() throws {
        let fixture = try SearchSchemaFixture.make()
        let rowIDBefore = try fixture.scalar(
            "SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'"
        )
        let revisionBefore = try fixture.revision(accountID: "a1")
        var changedRows = -1

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: MessageID("m1"),
                database: database
            )
            changedRows = database.changesCount
        }

        XCTAssertEqual(changedRows, 0)
        XCTAssertEqual(
            try fixture.scalar("SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'"),
            rowIDBefore
        )
        XCTAssertEqual(try fixture.ftsMatch("quarterly"), ["m1"])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), revisionBefore)
    }

    func testProjectionTriggersPreserveRebuildingAndUnavailableStates() throws {
        let fixture = try SearchSchemaFixture.make()
        let revisionBefore = try fixture.revision(accountID: "a1")
        try fixture.execute("UPDATE mail_search_state SET state = 'rebuilding' WHERE account_id = 'a1'")

        try fixture.updateProjectionSubject("Rebuilding forecast")

        XCTAssertEqual(
            try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"),
            "rebuilding"
        )
        XCTAssertEqual(try fixture.ftsMatch("rebuilding"), ["m1"])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), revisionBefore + 1)

        try fixture.execute("UPDATE mail_search_state SET state = 'unavailable' WHERE account_id = 'a1'")
        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.remove(
                messageID: MessageID("m1"),
                database: database
            )
        }
        XCTAssertEqual(
            try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"),
            "unavailable"
        )
        XCTAssertEqual(try fixture.revision(accountID: "a1"), revisionBefore + 2)

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: MessageID("m1"),
                database: database
            )
        }
        XCTAssertEqual(
            try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"),
            "unavailable"
        )
        XCTAssertEqual(try fixture.ftsMatch("quarterly"), ["m1"])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), revisionBefore + 3)
    }

    func testSuccessfulRebuildRecoversUnavailableStateAfterOrdinaryWriteDoesNot() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("UPDATE mail_search_state SET state = 'unavailable' WHERE account_id = 'a1'")
        try fixture.execute("UPDATE messages SET subject = 'Recovered forecast' WHERE id = 'm1'")

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: MessageID("m1"),
                database: database
            )
        }
        XCTAssertEqual(
            try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"),
            "unavailable"
        )

        try fixture.write(SQLiteMailSearchSchema.rebuild)

        XCTAssertEqual(
            try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"),
            "ready"
        )
        XCTAssertEqual(try fixture.ftsMatch("recovered"), ["m1"])
    }

    func testRefreshDerivesMailboxRolesAndFlagsFromCanonicalRows() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("""
            INSERT INTO mailboxes (id, account_id, name, path, special_use)
            VALUES ('mb-sent', 'a1', 'Sent Items', 'Sent Items', NULL);
            INSERT INTO mailboxes (id, account_id, name, path, special_use)
            VALUES ('mb-trash', 'a1', 'Bin', 'Bin', '\\Trash');
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id, flags
            ) VALUES ('a1', 'Sent Items', 1, 2, 'm1', '\\Flagged');
            INSERT INTO mailbox_messages (
                account_id, mailbox_path, uid_validity, uid, message_id, flags
            ) VALUES ('a1', 'Bin', 1, 3, 'm1', 'Delegated');
            """)

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID("m1"), database: database)
        }

        XCTAssertEqual(try fixture.scalar("SELECT is_inbox FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_sent FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_trash FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_flagged FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT is_delegated FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.text("SELECT mailbox_ids FROM mail_search_documents"), "mb-inbox mb-sent mb-trash")
        XCTAssertEqual(try fixture.text("SELECT mailbox_names FROM mail_search_documents"), "Bin Inbox Sent Items")
    }

    func testRefreshDoesNotLeakMembershipStateAcrossCanonicalAccounts() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("""
            INSERT INTO accounts(id) VALUES ('a2');
            INSERT INTO mailboxes(id, account_id, name, path, special_use)
            VALUES ('mb-other-trash', 'a2', 'Trash', 'Trash', '\\Trash');
            INSERT INTO mailbox_messages(
                account_id, mailbox_path, uid_validity, uid, message_id, flags
            ) VALUES ('a2', 'Trash', 1, 8, 'm1', '\\Flagged');
            """)

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID("m1"), database: database)
        }

        XCTAssertEqual(try fixture.scalar("SELECT is_trash FROM mail_search_documents"), 0)
        XCTAssertEqual(try fixture.text("SELECT mailbox_ids FROM mail_search_documents"), "mb-inbox")
    }

    func testRefreshUsesSortDateOnlyFromCanonicalAccountMemberships() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("""
            UPDATE messages SET sent_at = NULL WHERE id = 'm1';
            UPDATE mailbox_messages SET internal_date = 100
            WHERE message_id = 'm1' AND account_id = 'a1';
            INSERT INTO accounts(id) VALUES ('a2');
            INSERT INTO mailbox_messages(
                account_id, mailbox_path, uid_validity, uid, message_id, flags, internal_date
            ) VALUES ('a2', 'Archive', 1, 8, 'm1', '', 500);
            """)

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID("m1"), database: database)
        }

        XCTAssertEqual(try fixture.scalar("SELECT sort_date FROM mail_search_documents"), 100)
    }

    func testDocumentClassifierSharesApprovedExtensionAndOptionalMIMEBoundary() {
        for filename in ["brief.PDF", "draft.docx", "notes.txt", "ledger.csv", "slides.odp"] {
            XCTAssertTrue(MailSearchDocumentClassifier.isDocument(filename: filename, mimeType: nil), filename)
        }
        for filename in ["photo.png", "invite.ics", "archive.zip", "README"] {
            XCTAssertFalse(MailSearchDocumentClassifier.isDocument(filename: filename, mimeType: nil), filename)
        }
        XCTAssertTrue(MailSearchDocumentClassifier.isDocument(filename: "scan.bin", mimeType: "application/pdf"))
        XCTAssertFalse(MailSearchDocumentClassifier.isDocument(filename: "invite.ics", mimeType: "text/calendar"))
        XCTAssertFalse(MailSearchDocumentClassifier.isDocument(filename: "photo.png", mimeType: "image/png"))
    }

    func testV21BackfillClassifiesDocumentsFromFilenamesOnly() throws {
        let fixture = try LegacySearchDatabaseFixture.make(filenameValue: "photo.png invite.ics")

        try fixture.write(SQLiteMailSearchSchema.migrateV22)

        XCTAssertEqual(try fixture.scalar("SELECT has_attachments FROM mail_search_documents"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT has_documents FROM mail_search_documents"), 0)
    }

    func testMigrationFailureRollsBackLegacyTablesAndSchemaMarker() throws {
        let fixture = try LegacySearchDatabaseFixture.make(corrupt: true)

        XCTAssertThrowsError(try fixture.write(SQLiteMailSearchSchema.migrateV22))

        XCTAssertTrue(try fixture.tableExists("message_search_metadata"))
        XCTAssertTrue(try fixture.tableExists("message_fts"))
        XCTAssertFalse(try fixture.tableExists("mail_search_documents"))
        XCTAssertEqual(try fixture.scalar("PRAGMA user_version"), 21)
    }

    func testMigrationIsIdempotentAfterLegacyTablesAreGone() throws {
        let fixture = try LegacySearchDatabaseFixture.make()
        try fixture.write(SQLiteMailSearchSchema.migrateV22)
        let rowID = try fixture.scalar("SELECT rowid FROM mail_search_documents")

        try fixture.write(SQLiteMailSearchSchema.migrateV22)

        XCTAssertEqual(try fixture.scalar("SELECT rowid FROM mail_search_documents"), rowID)
        try fixture.write(SQLiteMailSearchSchema.migrateV23)
        XCTAssertNoThrow(try fixture.read(SQLiteMailSearchSchema.validate))
    }

    func testCompletedMigrationRejectsMissingSynchronizationTrigger() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("DROP TRIGGER mail_search_documents_after_update")

        XCTAssertThrowsError(try fixture.write(SQLiteMailSearchSchema.migrateV22))
    }

    func testCompletedMigrationRejectsMissingRequiredIndex() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("DROP INDEX mail_search_documents_unread")

        XCTAssertThrowsError(try fixture.write(SQLiteMailSearchSchema.migrateV22))
    }

    func testCompletedMigrationRejectsMismatchedUserVersion() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("PRAGMA user_version = 21")

        XCTAssertThrowsError(try fixture.write(SQLiteMailSearchSchema.migrateV22))
    }

    func testRebuildRepairsProjectionAndFTSAtomically() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("""
            INSERT INTO mail_search_fts(mail_search_fts) VALUES('delete-all');
            UPDATE messages SET subject = 'Restored budget' WHERE id = 'm1';
            """)

        XCTAssertThrowsError(try fixture.read(SQLiteMailSearchSchema.validate))
        try fixture.write(SQLiteMailSearchSchema.rebuild)

        XCTAssertEqual(try fixture.ftsMatch("restored"), ["m1"])
        XCTAssertEqual(try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"), "ready")
        XCTAssertNoThrow(try fixture.read(SQLiteMailSearchSchema.validate))
    }

    func testRebuildPreservesExistingProjectionRowIDs() throws {
        let fixture = try SearchSchemaFixture.make()
        try fixture.execute("UPDATE mail_search_documents SET rowid = 41 WHERE message_id = 'm1'")

        try fixture.write(SQLiteMailSearchSchema.rebuild)

        XCTAssertEqual(try fixture.scalar("SELECT rowid FROM mail_search_documents WHERE message_id = 'm1'"), 41)
        XCTAssertNoThrow(try fixture.read(SQLiteMailSearchSchema.validate))
    }

    func testRebuildAdvancesRevisionWhenAccountLosesFinalProjectionRow() throws {
        let fixture = try SearchSchemaFixture.make()
        let before = try fixture.revision(accountID: "a1")
        try fixture.execute("DELETE FROM messages WHERE id = 'm1'")

        try fixture.write(SQLiteMailSearchSchema.rebuild)

        XCTAssertEqual(try fixture.scalar("SELECT count(*) FROM mail_search_documents"), 0)
        XCTAssertEqual(try fixture.text("SELECT state FROM mail_search_state WHERE account_id = 'a1'"), "ready")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }

    func testAccountChangingProjectionUpdateAdvancesOldAndNewAccountRevisions() throws {
        let fixture = try SearchSchemaFixture.make()
        let oldBefore = try fixture.revision(accountID: "a1")
        try fixture.execute("INSERT INTO accounts(id) VALUES ('a2')")
        try fixture.execute("UPDATE messages SET account_id = 'a2' WHERE id = 'm1'")

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID("m1"), database: database)
        }

        XCTAssertEqual(try fixture.text("SELECT account_id FROM mail_search_documents"), "a2")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), oldBefore + 1)
        XCTAssertEqual(try fixture.revision(accountID: "a2"), 1)
    }

    func testProjectionWriterRemoveDeletesFTSAndAdvancesRevision() throws {
        let fixture = try SearchSchemaFixture.make()
        let before = try fixture.revision(accountID: "a1")

        try fixture.write { database in
            try SQLiteMailSearchProjectionWriter.remove(messageID: MessageID("m1"), database: database)
        }

        XCTAssertEqual(try fixture.scalar("SELECT count(*) FROM mail_search_documents"), 0)
        XCTAssertEqual(try fixture.ftsMatch("quarterly"), [])
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }
}

private class LegacySearchDatabaseFixture {
    let databaseQueue: DatabaseQueue

    fileprivate init(databaseQueue: DatabaseQueue) {
        self.databaseQueue = databaseQueue
    }

    static func make(
        corrupt: Bool = false,
        filenameValue: String = "forecast.pdf"
    ) throws -> LegacySearchDatabaseFixture {
        let fixture = LegacySearchDatabaseFixture(databaseQueue: try DatabaseQueue())
        try fixture.execute("""
            PRAGMA user_version = 21;
            CREATE TABLE accounts (id TEXT PRIMARY KEY);
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                subject_normalized TEXT NOT NULL DEFAULT '',
                participant_emails TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                account_id TEXT,
                thread_id TEXT,
                from_email TEXT NOT NULL,
                from_display_name TEXT,
                subject TEXT NOT NULL,
                preview TEXT NOT NULL,
                body_text TEXT NOT NULL DEFAULT '',
                labels_json TEXT NOT NULL DEFAULT '[]',
                is_seen INTEGER NOT NULL DEFAULT 0,
                mailbox_path TEXT NOT NULL DEFAULT 'INBOX',
                is_deleted INTEGER NOT NULL DEFAULT 0,
                sent_at REAL,
                to_emails TEXT NOT NULL DEFAULT '',
                cc_emails TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE mailboxes (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                special_use TEXT
            );
            CREATE TABLE mailbox_messages (
                account_id TEXT NOT NULL,
                mailbox_path TEXT NOT NULL,
                uid_validity INTEGER NOT NULL,
                uid INTEGER NOT NULL,
                message_id TEXT NOT NULL,
                flags TEXT NOT NULL DEFAULT '',
                internal_date REAL,
                PRIMARY KEY (account_id, mailbox_path, uid_validity, uid)
            );
            CREATE TABLE message_search_metadata (
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
            CREATE VIRTUAL TABLE message_fts USING fts5(
                message_id UNINDEXED, from_value, to_value, cc_value, bcc_value,
                subject, body_text, attachment_filenames, message_identifiers, mailbox_path, labels
            );
            INSERT INTO accounts(id) VALUES ('a1');
            INSERT INTO threads(id, account_id) VALUES ('t1', 'a1');
            INSERT INTO mailboxes(id, account_id, name, path, special_use)
            VALUES ('mb-inbox', 'a1', 'Inbox', 'INBOX', '\\Inbox');
            """)
        try fixture.write { database in
            try database.execute(
                sql: """
                    INSERT INTO messages(
                        id, account_id, thread_id, from_email, from_display_name, subject, preview,
                        body_text, labels_json, is_seen, mailbox_path, is_deleted, sent_at, to_emails, cc_emails
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: StatementArguments([
                    "m1", corrupt ? nil : "a1", corrupt ? nil : "t1",
                    "analyst@example.com", "Alex Analyst", "Quarterly forecast", "Forecast preview",
                    "Revenue rises next quarter.", "[\"Client\"]", "0", "INBOX", "0", "1720000000",
                    "board@example.com", "finance@example.com",
                ] as [String?])
            )
        }
        if !corrupt {
            try fixture.execute("""
                INSERT INTO mailbox_messages(
                    account_id, mailbox_path, uid_validity, uid, message_id, flags
                ) VALUES ('a1', 'INBOX', 1, 1, 'm1', '\\Flagged Delegated');
                """)
        }
        try fixture.write { database in
            try database.execute(
                sql: """
                    INSERT INTO message_search_metadata(
                        message_id, from_value, to_value, cc_value, bcc_value, subject, body_text,
                        attachment_filenames, message_identifiers, mailbox_path, labels
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "m1", "Alex Analyst analyst@example.com", "board@example.com", "finance@example.com",
                    "legal@example.com", "Quarterly forecast", "Revenue rises next quarter.",
                    filenameValue, "<forecast@example.com>", "INBOX", "Client",
                ]
            )
            try database.execute(sql: "INSERT INTO message_fts SELECT * FROM message_search_metadata")
        }
        return fixture
    }

    func write(_ body: (Database) throws -> Void) throws {
        try databaseQueue.write(body)
    }

    func read(_ body: (Database) throws -> Void) throws {
        try databaseQueue.read(body)
    }

    func execute(_ sql: String) throws {
        try write { try $0.execute(sql: sql) }
    }

    func scalar(_ sql: String) throws -> Int {
        try databaseQueue.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    func text(_ sql: String) throws -> String? {
        try databaseQueue.read { try String.fetchOne($0, sql: sql) }
    }

    func tableExists(_ name: String) throws -> Bool {
        try scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") == 1
    }

    func columnNames(table: String) throws -> [String] {
        try databaseQueue.read { database in
            try database.columns(in: table).map(\.name)
        }
    }

    func schemaSQL(type: String, name: String) throws -> String? {
        try databaseQueue.read {
            try String.fetchOne(
                $0,
                sql: "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?",
                arguments: [type, name]
            )
        }
    }

    func schemaNames(type: String, prefix: String) throws -> [String] {
        try databaseQueue.read {
            try String.fetchAll(
                $0,
                sql: "SELECT name FROM sqlite_master WHERE type = ? AND name LIKE ? ORDER BY name",
                arguments: [type, prefix + "%"]
            )
        }
    }
}

private final class SearchSchemaFixture: LegacySearchDatabaseFixture {
    static func make() throws -> SearchSchemaFixture {
        let legacy = try LegacySearchDatabaseFixture.make()
        try legacy.write(SQLiteMailSearchSchema.migrateV22)
        try legacy.write(SQLiteMailSearchSchema.migrateV23)
        return SearchSchemaFixture(databaseQueue: legacy.databaseQueue)
    }

    func revision(accountID: String) throws -> Int {
        try scalar("SELECT revision FROM mail_search_state WHERE account_id = '\(accountID)'")
    }

    func updateProjectionSubject(_ subject: String) throws {
        try write {
            try $0.execute(
                sql: "UPDATE mail_search_documents SET subject = ? WHERE message_id = 'm1'",
                arguments: [subject]
            )
        }
    }

    func ftsMatch(_ query: String) throws -> [String] {
        try databaseQueue.read {
            try String.fetchAll(
                $0,
                sql: """
                    SELECT d.message_id
                    FROM mail_search_fts
                    JOIN mail_search_documents d ON d.rowid = mail_search_fts.rowid
                    WHERE mail_search_fts MATCH ?
                    ORDER BY d.message_id
                    """,
                arguments: [query]
            )
        }
    }
}
