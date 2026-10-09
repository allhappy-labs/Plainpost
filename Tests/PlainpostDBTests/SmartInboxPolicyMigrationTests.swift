import GRDB
import PlainpostOperations
import XCTest
@testable import PlainpostDB

/// A store that ran v66 but not v68 keeps only `enabled`; v68 backfills `mode` from it.
final class SmartInboxPolicyMigrationTests: XCTestCase {
    func testV68BackfillsOffFromADisabledPolicy() throws {
        try assertV68Backfill(enabled: false, storedMode: "off", reads: .off)
    }

    func testV68BackfillsAllMailFromAnEnabledPolicy() throws {
        try assertV68Backfill(enabled: true, storedMode: "all", reads: .allMail)
    }

    private func assertV68Backfill(
        enabled: Bool, storedMode: String, reads expected: SmartInboxMode,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-inbox-v68-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        // Rewind to the v66 shape with a legacy row.
        try store.databasePool.write { database in
            try database.execute(sql: """
                DROP TABLE smart_inbox_policy;
                CREATE TABLE smart_inbox_policy (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    enabled INTEGER NOT NULL CHECK(enabled IN (0, 1))
                );
                DELETE FROM grdb_migrations WHERE identifier = 'v68-smart-inbox-mode';
                """)
            try database.execute(
                sql: "INSERT INTO smart_inbox_policy (singleton, enabled) VALUES (1, ?)", arguments: [enabled]
            )
        }

        let migrated = try SQLiteMailStore(path: url.path)
        try migrated.migrate()

        let row = try migrated.databasePool.read { database in
            try Row.fetchOne(database, sql: "SELECT mode, new_mail_since FROM smart_inbox_policy WHERE singleton = 1")
        }
        XCTAssertEqual(row?["mode"] as String?, storedMode, file: file, line: line)
        XCTAssertNil(row?["new_mail_since"] as Double?, file: file, line: line)
        XCTAssertEqual(try migrated.smartInboxMode(), expected, file: file, line: line)
    }
}
