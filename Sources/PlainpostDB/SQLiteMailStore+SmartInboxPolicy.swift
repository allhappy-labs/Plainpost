import Foundation
import GRDB
import PlainpostOperations

public enum SmartInboxPolicyError: Error, Equatable, Sendable {
    case disabled
}

extension SQLiteMailStore {
    package func migrateSmartInboxPolicy() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v66-smart-inbox-policy") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_policy (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    enabled INTEGER NOT NULL CHECK(enabled IN (0, 1))
                )
                """)
        }
        migrator.registerMigration("v68-smart-inbox-mode") { database in
            try database.execute(sql: """
                ALTER TABLE smart_inbox_policy ADD COLUMN mode TEXT CHECK(mode IN ('off', 'new', 'all'));
                ALTER TABLE smart_inbox_policy ADD COLUMN new_mail_since REAL;
                UPDATE smart_inbox_policy SET mode = CASE enabled WHEN 1 THEN 'all' ELSE 'off' END;
                """)
        }
        try migrator.migrate(databasePool)
    }

    public func smartInboxEnabled() throws -> Bool {
        try databasePool.read { try Self.smartInboxEnabled(in: $0) }
    }

    package static func smartInboxEnabled(in database: Database) throws -> Bool {
        try smartInboxMode(in: database).isEnabled
    }

    package static func requireSmartInboxEnabled(in database: Database) throws {
        guard try smartInboxEnabled(in: database) else { throw SmartInboxPolicyError.disabled }
    }

    public func smartInboxMode() throws -> SmartInboxMode {
        try databasePool.read { try Self.smartInboxMode(in: $0) }
    }

    package static func smartInboxMode(in database: Database) throws -> SmartInboxMode {
        try smartInboxPolicyRow(in: database).mode
    }

    /// Also returns the raw stored `new_mail_since` seconds-since-epoch value (when the
    /// mode is `.newMailOnly`), so callers that need to compare cutoffs can do so in the
    /// same representation the database holds rather than through a `Date` round trip.
    private static func smartInboxPolicyRow(
        in database: Database
    ) throws -> (mode: SmartInboxMode, rawNewMailSince: Double?) {
        guard let row = try Row.fetchOne(
            database, sql: "SELECT enabled, mode, new_mail_since FROM smart_inbox_policy WHERE singleton = 1"
        ) else { return (.allMail, nil) }
        let rawSince: Double? = row["new_mail_since"]
        switch row["mode"] as String? {
        case "off": return (.off, rawSince)
        case "new": return (.newMailOnly(since: Date(timeIntervalSince1970: rawSince ?? 0)), rawSince)
        case "all": return (.allMail, rawSince)
        default:
            // A row with no `mode` predates this column (or was seeded directly by a
            // test that only writes `enabled`); derive the mode from the legacy flag.
            return ((row["enabled"] as Bool) ? .allMail : .off, rawSince)
        }
    }

    public func setSmartInboxEnabled(_ enabled: Bool) throws {
        try setSmartInboxMode(enabled ? .allMail : .off)
    }

    /// Policy and admitted-owner pause intent share the classification writer transaction.
    /// Re-enabling never clears an in-flight intent: the provider must join before that lease is released.
    /// Moving to New mail only cancels sorting jobs seeded under the old policy; disabling only pauses
    /// running ones. The mode write and any resulting cancellations happen in the
    /// same transaction so a cancellation failure can never leave the policy row out of sync with the
    /// jobs it was supposed to stop.
    public func setSmartInboxMode(_ mode: SmartInboxMode) throws {
        try databasePool.write { database in
            let (previousMode, previousRawSince) = try Self.smartInboxPolicyRow(in: database)
            let (raw, since): (String, Double?) = switch mode {
            case .off: ("off", nil)
            case .newMailOnly(let date): ("new", date.timeIntervalSince1970)
            case .allMail: ("all", nil)
            }
            try database.execute(sql: """
                INSERT INTO smart_inbox_policy (singleton, enabled, mode, new_mail_since) VALUES (1, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET enabled = excluded.enabled,
                    mode = excluded.mode, new_mail_since = excluded.new_mail_since
                """, arguments: [mode.isEnabled, raw, since])

            if mode == .off {
                let rows = try Row.fetchAll(database, sql: """
                    SELECT id, payload_json FROM durable_jobs
                    WHERE kind = 'ai-operation' AND state = 'running'
                      AND cancellation_requested = 0 AND pause_requested = 0
                    """)
                for row in rows {
                    guard let input = try? JSONDecoder().decode(
                        PlainpostAIOperationInput.self,
                        from: Data((row["payload_json"] as String).utf8)
                    ), input.operation == .recategorizeInbox else { continue }
                    try database.execute(sql: """
                        UPDATE durable_jobs SET pause_requested = 1,
                            pause_reason = 'smart-inbox-disabled', updated_at = ? WHERE id = ?
                        """, arguments: [Date().timeIntervalSince1970, row["id"] as String])
                }
                return
            }

            guard case .newMailOnly(let newSince) = mode else { return }
            // Re-applying the stored mode must be idempotent: a device re-reads its
            // mode from storage on every launch and calls this setter with it, so a
            // no-op (or a cutoff that only moves earlier) must never cancel work that
            // the previously-seeded work already covered. Moving from `.off` is not a
            // no-op even though `.off` leaves queued jobs queued and only pauses
            // running ones — both were seeded under whatever mode preceded the pause
            // (commonly `.allMail`), so they can still include pre-cutoff mail and must
            // be cancelled, same as `.allMail`. The cutoff comparison uses the raw
            // stored seconds-since-epoch value (not a `Date` round trip through
            // `timeIntervalSince1970`, which can perturb a fractional date by a sub-
            // millisecond amount) with a 1ms tolerance, since the device's stored
            // mode keeps its cutoff as JSON and may re-derive a `Date` that differs
            // from the stored value by less than that.
            let shouldCancel: Bool = switch previousMode {
            case .allMail, .off: true
            case .newMailOnly: newSince.timeIntervalSince1970 - (previousRawSince ?? 0) > 0.001
            }
            guard shouldCancel else { return }

            let rows = try Row.fetchAll(database, sql: """
                SELECT id, payload_json FROM durable_jobs
                WHERE kind = 'ai-operation' AND state IN ('queued', 'running', 'paused')
                  AND cancellation_requested = 0
                """)
            let now = Date()
            for row in rows {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), input.operation == .recategorizeInbox else { continue }
                try self.cancelJob(database: database, id: row["id"], now: now)
            }
        }
        MailStoreChangeSignal.post(scope: .operations)
    }
}
