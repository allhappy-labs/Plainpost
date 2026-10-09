import CryptoKit
import GRDB
import PlainpostCore
import PlainpostTestSupport
import XCTest
@testable import PlainpostDB

final class LegacyPairingStorageMigrationTests: XCTestCase {
    func testPreV51MigrationSourceRemainsByteIdenticalToHistoricalBaseline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/PlainpostDB/SQLiteMailStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let startMarker = "    public func migrate() throws {\n"
        let endMarker = "        Self.registerLegacyPairingRemovalV51(on: &migrator)\n"
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        else {
            return XCTFail("SQLiteMailStore migration source markers are missing")
        }

        let historicalSource = String(source[start..<end])
        let digest = SHA256.hash(data: Data(historicalSource.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            digest,
            "3e43f6f78ad1be972cce4d86fd31e87d67c8ba0dd343d1b465b4b6d3c8b21801",
            "Never edit a shipped migration. Put cleanup in a newly registered migration."
        )
    }

    func testPreV51MigrationHelpersRemainByteIdenticalToHistoricalBaseline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/PlainpostDB/SQLiteMailStore.swift"),
            encoding: .utf8
        )
        let helpers = [
            (
                "    private static func sanitizeLegacyDeviceComposeMutationReceipts(",
                "    public var accounts: [Account] {",
                "8e7177cb8379c01350de60b6a354e2815276266634d8bb2589f216f4d1faf995"
            ),
            (
                "    private static func reconcileOwnershipV46(_ database: Database) throws {",
                "    private static func recreateOwnershipValidationTriggersV46(",
                "c883a93472b92326a3fa639e260921149a857a190cbd4c23e58d0988df5f2ce4"
            ),
            (
                "    private static func recreateOwnershipValidationTriggersV46(",
                "    private static func migrateLegacyRecoveryCredentialAssociationsV46(",
                "083af564860704720a7cfaffd3e093e6923e439ec851fb464400764c954bf556"
            ),
            (
                "    private static func migrateLegacyRecoveryCredentialAssociationsV46(",
                "    private static func accountDeletionOwnership(",
                "25bb8a17338a0408265a22956265bfb104da82b3be98c7ab59e90ac3b2f840e3"
            ),
        ]

        for (startMarker, endMarker, expectedDigest) in helpers {
            guard let start = source.range(of: startMarker)?.lowerBound,
                  let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
            else {
                XCTFail("Historical migration helper markers are missing: \(startMarker)")
                continue
            }
            let digest = SHA256.hash(data: Data(source[start..<end].utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(
                digest,
                expectedDigest,
                "Never edit a shipped migration helper: \(startMarker)"
            )
        }
    }

    func testFreshBootstrapMailWritesAndAccountDeletionDoNotUseLegacyTables() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-v51-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        try store.cacheAccountSetup(
            account: PlainpostFixtures.personalAccount,
            inbox: PlainpostFixtures.inboxMailbox
        )
        try store.cacheThreads([PlainpostFixtures.aliceThread])
        try store.cacheMessage(PlainpostFixtures.aliceMessage)

        XCTAssertEqual(store.accounts.map(\.id), [PlainpostFixtures.personalAccount.id])
        XCTAssertEqual(store.messages.map(\.id), [PlainpostFixtures.aliceMessage.id])

        try store.deleteAccountData(accountID: PlainpostFixtures.personalAccount.id)
        XCTAssertEqual(store.accounts, [])
        XCTAssertEqual(store.messages, [])
    }

    func testV57RemovesLegacyWakeOutboxFromExistingStores() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-v57-wake-outbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var store: SQLiteMailStore? = try SQLiteMailStore(path: url.path)
        try store?.migrate()
        store = nil

        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE wake_outbox (
                    id TEXT PRIMARY KEY,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    opaque_token BLOB NOT NULL,
                    available_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    delivered_at REAL
                )
                """)
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v57-remove-legacy-wake-outbox"]
            )
        }

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        let wakeTableCount = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'wake_outbox'"
            ) ?? 0
        }
        XCTAssertEqual(wakeTableCount, 0)
    }

    func testV51HardDeletesLegacyPairingSchemaAndKeepsMailWritesUsable() throws {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(sql: Self.preV51FixtureSQL)
        }

        var migrator = DatabaseMigrator()
        SQLiteMailStore.registerLegacyPairingRemovalV51(on: &migrator)
        try migrator.migrate(database)

        try database.read { db in
            let survivors = try Row.fetchAll(
                db,
                sql: """
                    SELECT type, name
                    FROM sqlite_master
                    WHERE name LIKE 'device_projection%'
                       OR name LIKE 'device_compose%'
                       OR name = 'device_send_reviews'
                       OR name IN (
                           'messages_device_smart_inbox_projection',
                           'send_requests_device_approval_queue'
                       )
                       OR tbl_name LIKE 'device_projection%'
                       OR tbl_name LIKE 'device_compose%'
                       OR tbl_name = 'device_send_reviews'
                    ORDER BY type, name
                    """
            ).map { "\($0["type"] as String):\($0["name"] as String)" }
            XCTAssertEqual(survivors, [])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages"), 1)
        }

        XCTAssertNoThrow(try database.write { db in
            try db.execute(
                sql: "UPDATE accounts SET display_name = ? WHERE id = ?",
                arguments: ["Updated", "account-1"]
            )
            try db.execute(
                sql: "INSERT INTO mailboxes (id, account_id, name) VALUES (?, ?, ?)",
                arguments: ["archive", "account-1", "Archive"]
            )
            try db.execute(
                sql: "UPDATE messages SET subject = ? WHERE id = ?",
                arguments: ["Updated subject", "message-1"]
            )
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: ["account-1"])
        })
    }

    private static let preV51FixtureSQL = """
        PRAGMA foreign_keys = ON;

        CREATE TABLE accounts (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL
        );
        CREATE TABLE mailboxes (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            name TEXT NOT NULL
        );
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
            subject TEXT NOT NULL
        );
        CREATE INDEX messages_device_smart_inbox_projection ON messages(subject);
        CREATE TABLE send_requests (id TEXT PRIMARY KEY, payload_json TEXT NOT NULL);
        CREATE INDEX send_requests_device_approval_queue ON send_requests(payload_json);

        INSERT INTO accounts VALUES ('account-1', 'Personal');
        INSERT INTO mailboxes VALUES ('inbox', 'account-1', 'Inbox');
        INSERT INTO threads VALUES ('thread-1', 'account-1');
        INSERT INTO messages VALUES ('message-1', 'account-1', 'thread-1', 'Before');

        CREATE TABLE device_projection_source_generation (
            singleton INTEGER PRIMARY KEY,
            generation INTEGER NOT NULL
        );
        INSERT INTO device_projection_source_generation VALUES (1, 8);
        CREATE TABLE device_projection_head (
            singleton INTEGER PRIMARY KEY,
            cursor TEXT NOT NULL
        );
        INSERT INTO device_projection_head VALUES (1, 'cursor-1');
        CREATE TABLE device_projection_history (
            cursor TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL
        );
        INSERT INTO device_projection_history VALUES ('cursor-1', '{"messages":[]}');
        CREATE TABLE device_projection_pages (
            token TEXT PRIMARY KEY,
            base_cursor TEXT NOT NULL REFERENCES device_projection_history(cursor) ON DELETE CASCADE
        );
        INSERT INTO device_projection_pages VALUES ('page-1', 'cursor-1');
        CREATE INDEX device_projection_history_revision ON device_projection_history(cursor);
        CREATE INDEX device_projection_pages_lookup ON device_projection_pages(base_cursor);
        CREATE VIEW device_projection_current AS
            SELECT history.cursor, history.payload_json
            FROM device_projection_history history
            JOIN device_projection_head head ON head.cursor = history.cursor;

        CREATE TRIGGER device_projection_accounts_insert AFTER INSERT ON accounts BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;
        CREATE TRIGGER device_projection_accounts_update AFTER UPDATE ON accounts BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;
        CREATE TRIGGER device_projection_accounts_delete AFTER DELETE ON accounts BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;
        CREATE TRIGGER device_projection_mailboxes_insert AFTER INSERT ON mailboxes BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;
        CREATE TRIGGER device_projection_threads_update AFTER UPDATE ON threads BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;
        CREATE TRIGGER device_projection_messages_update AFTER UPDATE ON messages BEGIN
            UPDATE device_projection_source_generation SET generation = generation + 1 WHERE singleton = 1;
        END;

        CREATE TABLE device_send_reviews (
            review_id TEXT PRIMARY KEY,
            draft_id TEXT NOT NULL
        );
        INSERT INTO device_send_reviews VALUES ('review-1', 'draft-1');
        CREATE INDEX device_send_reviews_owner_account ON device_send_reviews(draft_id);

        CREATE TABLE device_compose_mutation_receipts (
            device_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            response_json TEXT NOT NULL,
            PRIMARY KEY (device_id, idempotency_key)
        );
        INSERT INTO device_compose_mutation_receipts VALUES ('device-1', 'mutation-1', '{}');
        CREATE INDEX device_compose_mutation_receipts_owner_account
            ON device_compose_mutation_receipts(device_id);
        CREATE TRIGGER device_compose_mutation_receipts_ownership_validate_update
        BEFORE UPDATE ON device_compose_mutation_receipts BEGIN SELECT 1; END;

        CREATE TABLE device_compose_mutation_recovery_payloads (
            device_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            PRIMARY KEY (device_id, idempotency_key),
            FOREIGN KEY (device_id, idempotency_key)
                REFERENCES device_compose_mutation_receipts(device_id, idempotency_key)
                ON DELETE CASCADE
        );
        INSERT INTO device_compose_mutation_recovery_payloads VALUES ('device-1', 'mutation-1', '{}');
        CREATE TABLE device_compose_recovery_credentials (
            device_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            credential_record_key TEXT NOT NULL,
            PRIMARY KEY (device_id, idempotency_key),
            FOREIGN KEY (device_id, idempotency_key)
                REFERENCES device_compose_mutation_receipts(device_id, idempotency_key)
                ON DELETE CASCADE
        );
        INSERT INTO device_compose_recovery_credentials VALUES ('device-1', 'mutation-1', 'credential-1');
        """
}
