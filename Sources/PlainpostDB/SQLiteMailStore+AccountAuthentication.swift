import Foundation
import GRDB
import PlainpostCore

/// How a local device authenticates to an account's IMAP and SMTP servers.
public enum AccountAuthenticationMethod: String, Codable, Sendable {
    case password
    case googleOAuth = "google_oauth"
    case microsoftOAuth = "microsoft_oauth"
}

public enum AccountAuthenticationState: String, Codable, Sendable {
    case ready
    /// The provider refused the stored grant; the user must sign in again.
    case reauthorizationRequired = "reauthorization_required"
}

public extension SQLiteMailStore {
    /// An absent row is a password account in the ready state: every account
    /// created before `v60-account-authentication` authenticates with passwords.
    func accountAuthentication(
        accountID: AccountID
    ) throws -> (method: AccountAuthenticationMethod, state: AccountAuthenticationState) {
        let row = try databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT method, state FROM account_authentication WHERE account_id = ?",
                arguments: [accountID.rawValue]
            )
        }
        guard let row else { return (.password, .ready) }
        guard let method = AccountAuthenticationMethod(rawValue: row["method"]),
              let state = AccountAuthenticationState(rawValue: row["state"])
        else { throw PlainpostError.validationFailed("Stored account authentication is invalid.") }
        return (method, state)
    }

    /// Accounts whose OAuth grant must be renewed, sorted by account ID.
    func reauthorizationRequiredAccountIDs() throws -> [AccountID] {
        let rawIDs: [String] = try databasePool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT account_id FROM account_authentication
                    WHERE state = 'reauthorization_required'
                    ORDER BY account_id
                    """
            )
        }
        return rawIDs.map { AccountID($0) }
    }

    func setAccountAuthentication(
        accountID: AccountID,
        method: AccountAuthenticationMethod,
        state: AccountAuthenticationState
    ) throws {
        try databasePool.write { database in
            guard try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
                arguments: [accountID.rawValue]
            ) == true else {
                throw PlainpostError.notFound("Account not found.")
            }
            try database.execute(
                sql: """
                    INSERT INTO account_authentication (account_id, method, state, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        method = excluded.method,
                        state = excluded.state,
                        updated_at = excluded.updated_at
                    """,
                arguments: [accountID.rawValue, method.rawValue, state.rawValue, Date().timeIntervalSince1970]
            )
        }
        MailStoreChangeSignal.post(scope: .accounts)
    }

    static func registerAccountAuthenticationV60(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v60-account-authentication") { database in
            try database.execute(sql: """
                CREATE TABLE account_authentication (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    method TEXT NOT NULL CHECK (method IN ('password', 'google_oauth')),
                    state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'reauthorization_required')),
                    updated_at REAL NOT NULL
                );
                """)
        }
    }

    static func registerMicrosoftAccountAuthenticationV61(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v61-microsoft-account-authentication") { database in
            // SQLite cannot widen a CHECK in place. Keep the shipped v60
            // migration unchanged and copy every existing row, including its
            // original state and timestamp, into the widened table.
            try database.execute(sql: """
                CREATE TABLE account_authentication_v61 (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    method TEXT NOT NULL CHECK (method IN ('password', 'google_oauth', 'microsoft_oauth')),
                    state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'reauthorization_required')),
                    updated_at REAL NOT NULL
                );
                INSERT INTO account_authentication_v61 (account_id, method, state, updated_at)
                SELECT account_id, method, state, updated_at FROM account_authentication;
                DROP TABLE account_authentication;
                ALTER TABLE account_authentication_v61 RENAME TO account_authentication;
                """)
        }
    }
}
