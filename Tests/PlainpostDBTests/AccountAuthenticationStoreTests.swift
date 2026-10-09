import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB
import PlainpostSecrets

final class AccountAuthenticationStoreTests: XCTestCase {
    func testAbsentRowIsAReadyPasswordAccountAndWritesRoundTrip() throws {
        let (store, url, account) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .password)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        XCTAssertEqual(try store.reauthorizationRequiredAccountIDs(), [])

        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .reauthorizationRequired)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .googleOAuth)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .reauthorizationRequired)
        XCTAssertEqual(try store.reauthorizationRequiredAccountIDs(), [account.id])

        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).state, .ready)
        XCTAssertEqual(try store.reauthorizationRequiredAccountIDs(), [])
    }

    func testWritePostsAccountsChangeAndRefusesUnknownAccounts() throws {
        let (store, url, account) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let posted = expectation(forNotification: MailStoreChangeSignal.notificationName, object: nil) { notification in
            MailStoreChangeSignal.scope(from: notification) == .accounts
        }

        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        wait(for: [posted], timeout: 2)

        XCTAssertThrowsError(
            try store.setAccountAuthentication(accountID: AccountID("acc-missing"), method: .googleOAuth, state: .ready)
        ) { XCTAssertEqual($0 as? PlainpostError, .notFound("Account not found.")) }
    }

    func testMigrationIsRegisteredAndConstrainsValues() throws {
        let (store, url, account) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }

        let applied = try store.databasePool.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        let accountAuthentication = try XCTUnwrap(applied.firstIndex(of: "v60-account-authentication"))
        let accountSources = try XCTUnwrap(applied.firstIndex(of: "node-mode-v1-account-sources"))
        XCTAssertLessThan(accountAuthentication, accountSources)
        XCTAssertThrowsError(try store.databasePool.write { database in
            try database.execute(
                sql: "INSERT INTO account_authentication (account_id, method, state, updated_at) VALUES (?, 'app_password', 'ready', 0)",
                arguments: [account.id.rawValue])
        })
        XCTAssertThrowsError(try store.databasePool.write { database in
            try database.execute(
                sql: "INSERT INTO account_authentication (account_id, method, state, updated_at) VALUES (?, 'password', 'expired', 0)",
                arguments: [account.id.rawValue])
        })
    }

    func testV61WidensMethodConstraintWithoutChangingLegacyRowsOrForeignKeys() throws {
        let (store, url, first) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let second = Account(
            id: AccountID("acc_google_ready"), displayName: "Google Ready",
            email: EmailAddress("ready@gmail.com"), imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com"
        )
        let third = Account(
            id: AccountID("acc_google_expired"), displayName: "Google Expired",
            email: EmailAddress("expired@gmail.com"), imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com"
        )
        try store.cacheAccounts([first, second, third])

        // Recreate the shipped v60 table and remove only the new marker. This
        // models an on-disk v60 database with all three existing auth states.
        try store.databasePool.write { database in
            try database.execute(sql: """
                DROP TABLE account_authentication;
                CREATE TABLE account_authentication (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    method TEXT NOT NULL CHECK (method IN ('password', 'google_oauth')),
                    state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'reauthorization_required')),
                    updated_at REAL NOT NULL
                );
                """)
            try database.execute(
                sql: "INSERT INTO account_authentication VALUES (?, 'password', 'ready', 11)",
                arguments: [first.id.rawValue]
            )
            try database.execute(
                sql: "INSERT INTO account_authentication VALUES (?, 'google_oauth', 'ready', 22)",
                arguments: [second.id.rawValue]
            )
            try database.execute(
                sql: "INSERT INTO account_authentication VALUES (?, 'google_oauth', 'reauthorization_required', 33)",
                arguments: [third.id.rawValue]
            )
            try database.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v61-microsoft-account-authentication'"
            )
        }

        try store.migrate()
        let rows = try store.databasePool.read { database in
            try Row.fetchAll(database, sql: "SELECT account_id, method, state, updated_at FROM account_authentication ORDER BY updated_at")
        }
        XCTAssertEqual(rows.map { $0["account_id"] as String }, [first.id.rawValue, second.id.rawValue, third.id.rawValue])
        XCTAssertEqual(rows.map { $0["method"] as String }, ["password", "google_oauth", "google_oauth"])
        XCTAssertEqual(rows.map { $0["state"] as String }, ["ready", "ready", "reauthorization_required"])
        XCTAssertEqual(rows.map { $0["updated_at"] as Double }, [11, 22, 33])
        XCTAssertEqual(try store.reauthorizationRequiredAccountIDs(), [third.id])

        try store.setAccountAuthentication(accountID: first.id, method: .microsoftOAuth, state: .ready)
        XCTAssertEqual(try store.accountAuthentication(accountID: first.id).method, .microsoftOAuth)
        XCTAssertThrowsError(try store.databasePool.write { database in
            try database.execute(
                sql: "INSERT INTO account_authentication VALUES ('missing-account', 'microsoft_oauth', 'ready', 1)"
            )
        })
        try store.databasePool.write { database in
            try database.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [first.id.rawValue])
        }
        let remaining = try store.databasePool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account_authentication WHERE account_id = ?", arguments: [first.id.rawValue]) ?? -1
        }
        XCTAssertEqual(remaining, 0)
        try store.migrate()
        XCTAssertEqual(try store.accountAuthentication(accountID: third.id).state, .reauthorizationRequired)
    }

    func testMicrosoftAuthenticationWritePostsAccountsChange() throws {
        let (store, url, account) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let posted = expectation(forNotification: MailStoreChangeSignal.notificationName, object: nil) {
            MailStoreChangeSignal.scope(from: $0) == .accounts
        }
        try store.setAccountAuthentication(accountID: account.id, method: .microsoftOAuth, state: .reauthorizationRequired)
        wait(for: [posted], timeout: 2)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .microsoftOAuth)
        XCTAssertEqual(try store.reauthorizationRequiredAccountIDs(), [account.id])
    }

    func testAccountDeletionRemovesRefreshTokenRecordAndAuthenticationRow() async throws {
        let (store, url, account) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        try store.setAccountAuthentication(accountID: account.id, method: .googleOAuth, state: .ready)
        let refreshKey = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):google-refresh-token")
        let microsoftKey = CredentialRecordKey(rawValue: "account:\(account.id.rawValue):microsoft-refresh-token")
        let vault = InMemoryCredentialVault(records: [
            refreshKey: Data("1//refresh".utf8), microsoftKey: Data("other-refresh".utf8)
        ])

        try await store.deleteAccountData(accountID: account.id, credentials: vault)

        let remaining = try await vault.load(refreshKey)
        XCTAssertNil(remaining)
        let microsoftRemaining = try await vault.load(microsoftKey)
        XCTAssertNil(microsoftRemaining)
        let rows = try await store.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM account_authentication") ?? -1
        }
        XCTAssertEqual(rows, 0)
        XCTAssertEqual(try store.accountAuthentication(accountID: account.id).method, .password)
    }

    private func makeStore(testName: String) throws -> (SQLiteMailStore, URL, Account) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-account-auth-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: AccountID("acc_ada_gmail_com"),
            displayName: "Ada",
            email: EmailAddress("ada@gmail.com"),
            imapHost: "imap.gmail.com",
            smtpHost: "smtp.gmail.com"
        )
        try store.cacheAccounts([account])
        return (store, url, account)
    }
}
