import Foundation
import GRDB
import PlainpostCore

public enum NodeMailModeStoreError: Error, Equatable, Sendable {
    /// The guarded Node-mode schema could not be migrated; every account is Direct.
    case schemaUnavailable
    /// The stored source moved on since the caller read it.
    case generationConflict
    /// A stable key resolved to a message whose RFC Message-ID differs.
    case messageIdentityMismatch
    /// No journaled mail intent has this operation ID.
    case mailIntentNotFound
    /// A mail intent's operation ID or targets are malformed, or a stored row
    /// cannot be decoded.
    case invalidMailIntent
    /// The account is not Node-backed for the mirror's Node and logical
    /// mailbox any more (it flipped to Direct, was rebound or was removed),
    /// so the mirror must not write into it.
    case mirrorScopeChanged
    /// A mirrored message, membership or hydration payload is malformed or
    /// out of bounds, or a stored mirror row cannot be decoded.
    case invalidMirrorPayload
    case directSendUnresolved
    case nodeSendUnresolved
    case operationUnresolved
    /// Another account already has this id or address.
    case accountExists
}

/// Remembers, per store instance and per Node-mode migration, that its
/// schema is present. A migration only ever moves to `available`: an applied
/// migration is never undone, so a later transient failure (a re-run of
/// `migrate()` hitting SQLITE_BUSY, say) cannot downgrade the instance and let
/// Node-mode accounts sync directly. Until then every read probes
/// `grdb_migrations`, so a table created later by another process or launch is
/// picked up.
final class NodeModeSchemaState: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Set<String> = []

    func isAvailable(_ migration: String) -> Bool { lock.withLock { available.contains(migration) } }

    func markAvailable(_ migrations: [String]) {
        lock.withLock { available.formUnion(migrations) }
    }
}

enum NodeModeSchemaStatus: Equatable, Sendable {
    case available
    /// The table is truly absent: every account is Direct.
    case absent
}

// Node-mode tables live in their own migrator whose identifiers all start
// with `node-mode-`. It runs after the main migrator, and GRDB 7 tolerates
// identifiers a migrator does not know in `grdb_migrations`, so neither
// migrator ever sees the other's rows as a conflict. A failure rolls back that
// migration's transaction and is never rethrown. When it leaves the schema
// absent it is audited without its error text and local mail keeps working
// as Direct; when the schema already exists nothing changes.
extension SQLiteMailStore {
    static let nodeModeAccountSourcesMigration = "node-mode-v1-account-sources"
    static let nodeModeMailIntentJournalMigration = "node-mode-v2-mail-intent-journal"
    static let nodeModeMirrorMigration = "node-mode-v3-mirror"
    static let nodeModeMailIntentFolderActionsMigration = "node-mode-v4-mail-intent-folder-actions"
    static let nodeModeMigrations = [
        nodeModeAccountSourcesMigration, nodeModeMailIntentJournalMigration, nodeModeMirrorMigration,
        nodeModeMailIntentFolderActionsMigration,
    ]

    static func makeNodeModeMigrator(
        bodyFailpoint: (@Sendable () throws -> Void)? = nil
    ) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Immediate checks cover only this migration's own writes, so an
        // unrelated orphan row elsewhere cannot make it fail on every launch.
        migrator.registerMigration(nodeModeAccountSourcesMigration, foreignKeyChecks: .immediate) { database in
            try database.execute(sql: """
                CREATE TABLE account_mail_sources (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('direct', 'node_backed')),
                    mode TEXT CHECK (mode IN ('node', 'fallback')),
                    node_id TEXT CHECK (node_id = lower(node_id)),
                    logical_mailbox_id TEXT,
                    provider_identity TEXT,
                    generation INTEGER NOT NULL CHECK (generation >= 0),
                    mode_changed_at REAL NOT NULL,
                    CHECK (
                        (kind = 'direct' AND mode IS NULL AND node_id IS NULL
                            AND logical_mailbox_id IS NULL)
                        OR (kind = 'node_backed' AND mode IS NOT NULL AND node_id IS NOT NULL
                            AND length(logical_mailbox_id) = 43 AND provider_identity IS NOT NULL)
                    )
                );
                CREATE UNIQUE INDEX account_mail_sources_logical
                    ON account_mail_sources (node_id, logical_mailbox_id)
                    WHERE kind = 'node_backed';
                CREATE INDEX messages_account_rfc_message_id
                    ON messages (account_id, rfc_message_id);
                """)
            // Tests only: fails after the DDL to prove the migration rolls back.
            try bodyFailpoint?()
        }
        // Operation IDs are canonical lower-case UUIDs. Message kinds name a
        // message, draft kinds a draft, and credential pushes only their
        // account: no row holds a body, a recipient or a secret. A Node
        // intent keeps the exact signed operation it dispatched
        // (`canonical_operation`) so it can settle after a restart: a signature
        // over IDs, a draft revision or flags, never a body (`save_draft` and
        // `credential_push` rows never store one) and never a credential.
        // Edited in place during Task 16 review (journal v2 is unreleased).
        migrator.registerMigration(nodeModeMailIntentJournalMigration, foreignKeyChecks: .immediate) { database in
            try database.execute(sql: """
                CREATE TABLE mail_intent_journal (
                    operation_id TEXT PRIMARY KEY NOT NULL
                        CHECK (length(operation_id) = 36 AND operation_id = lower(operation_id)),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('mark_read','mark_unread','archive','delete','save_draft','send','credential_push')),
                    route TEXT CHECK (route IN ('node','direct')),
                    state TEXT NOT NULL,
                    message_id TEXT, draft_id TEXT,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    idempotency_key TEXT
                        CHECK (idempotency_key IS NULL OR (length(idempotency_key) = 36 AND idempotency_key = lower(idempotency_key))),
                    canonical_operation BLOB
                        CHECK (canonical_operation IS NULL OR length(canonical_operation) BETWEEN 1 AND 65536),
                    content_hash TEXT CHECK (content_hash IS NULL OR (kind = 'send' AND length(content_hash) BETWEEN 1 AND 128)),
                    archive_mailbox TEXT CHECK (archive_mailbox IS NULL OR (kind = 'archive' AND length(archive_mailbox) BETWEEN 1 AND 1024)),
                    send_revision TEXT CHECK (send_revision IS NULL OR (kind = 'send' AND length(send_revision) BETWEEN 1 AND 20)),
                    reported INTEGER NOT NULL DEFAULT 0 CHECK (reported IN (0, 1)),
                    deferral_count INTEGER NOT NULL DEFAULT 0 CHECK (deferral_count >= 0),
                    deferral_reason TEXT CHECK (deferral_reason IS NULL OR deferral_reason IN ('mail_server_unreachable','sign_in_refused_for_now','google_unreachable')),
                    first_deferred_at REAL,
                    deferral_due_at REAL,
                    next_attempt_at REAL,
                    CHECK (state IN ('pending','dispatching','admitted','confirmed','uncertain','failed','unconfirmed_after_removal','unconfirmed')),
                    CHECK (state IN ('pending','failed') OR route IS NOT NULL),
                    CHECK (state NOT IN ('admitted','uncertain','unconfirmed_after_removal','unconfirmed') OR route = 'node'),
                    CHECK (canonical_operation IS NULL OR (route = 'node' AND kind NOT IN ('save_draft','credential_push'))),
                    CHECK (idempotency_key IS NULL OR (route = 'node' AND kind != 'credential_push')),
                    CHECK ((message_id IS NOT NULL) = (kind IN ('mark_read','mark_unread','archive','delete'))),
                    CHECK ((draft_id IS NOT NULL) = (kind IN ('save_draft','send')))
                );
                CREATE INDEX mail_intent_journal_account_state ON mail_intent_journal (account_id, state, created_at);
                CREATE INDEX mail_intent_journal_message ON mail_intent_journal (message_id) WHERE message_id IS NOT NULL;
                CREATE INDEX mail_intent_journal_idempotency_key ON mail_intent_journal (idempotency_key)
                    WHERE idempotency_key IS NOT NULL;
                CREATE INDEX mail_intent_journal_updated_at ON mail_intent_journal (updated_at);
                -- Stamps follow commit order: a write never stamps a row
                -- earlier than a change already committed, so a sweep that
                -- remembers the newest stamp it read never skips a row
                -- committed after it (writes are serialized).
                CREATE TRIGGER mail_intent_journal_stamp_after_insert AFTER INSERT ON mail_intent_journal
                WHEN NEW.updated_at < (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                BEGIN
                    UPDATE mail_intent_journal
                    SET updated_at = (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                    WHERE operation_id = NEW.operation_id;
                END;
                CREATE TRIGGER mail_intent_journal_stamp_after_update AFTER UPDATE OF updated_at ON mail_intent_journal
                WHEN NEW.updated_at < (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                BEGIN
                    UPDATE mail_intent_journal
                    SET updated_at = (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                    WHERE operation_id = NEW.operation_id;
                END;
                CREATE INDEX mail_intent_journal_unreported_send_outcome ON mail_intent_journal (updated_at)
                    WHERE kind = 'send' AND reported = 0
                      AND state IN ('failed', 'unconfirmed', 'unconfirmed_after_removal');
                """)
            // Tests only: the same failpoint runs in every Node-mode body.
            try bodyFailpoint?()
        }
        // The Node mirror's own bookkeeping. Mail itself stays in `messages`
        // and `mailbox_messages`, exactly like direct sync. A bootstrap row
        // records the binding it was written for, so a changed Node or logical
        // mailbox is detected and re-mirrored. Membership links record which
        // Node message owns each mirrored membership, so one Node message
        // never removes another's.
        migrator.registerMigration(nodeModeMirrorMigration, foreignKeyChecks: .immediate) { database in
            try database.execute(sql: """
                CREATE TABLE node_mirror_cursors (
                    node_id TEXT PRIMARY KEY NOT NULL CHECK (node_id = lower(node_id)),
                    delta_cursor TEXT NOT NULL,
                    revision TEXT NOT NULL,
                    complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE TABLE node_mirror_account_bootstrap (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    node_id TEXT NOT NULL CHECK (node_id = lower(node_id)),
                    logical_mailbox_id TEXT NOT NULL CHECK (length(logical_mailbox_id) = 43),
                    snapshot_cursor TEXT NOT NULL,
                    complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
                    reconcile_state TEXT NOT NULL DEFAULT 'none'
                        CHECK (reconcile_state IN ('none', 'audit', 'awaiting_baseline')),
                    snapshot_generation INTEGER NOT NULL DEFAULT 0 CHECK (snapshot_generation >= 0),
                    sweep_pending INTEGER NOT NULL DEFAULT 0 CHECK (sweep_pending IN (0, 1)),
                    snapshot_retry_at REAL,
                    needs_reseed INTEGER NOT NULL DEFAULT 0 CHECK (needs_reseed IN (0, 1)),
                    ever_complete INTEGER NOT NULL DEFAULT 0 CHECK (ever_complete IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                CREATE TABLE node_mirror_message_links (
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    node_message_id TEXT NOT NULL CHECK (length(node_message_id) > 0),
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    hydration_state TEXT NOT NULL CHECK (hydration_state IN ('pending', 'complete', 'failed')),
                    hydration_attempts INTEGER NOT NULL DEFAULT 0 CHECK (hydration_attempts >= 0),
                    hydration_next_at REAL,
                    snapshot_generation INTEGER NOT NULL DEFAULT 0 CHECK (snapshot_generation >= 0),
                    audit_retry_at REAL,
                    PRIMARY KEY (account_id, node_message_id)
                );
                CREATE INDEX node_mirror_message_links_message ON node_mirror_message_links (message_id);
                CREATE TABLE node_mirror_membership_links (
                    account_id TEXT NOT NULL,
                    node_message_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    uid_validity INTEGER NOT NULL,
                    uid INTEGER NOT NULL,
                    PRIMARY KEY (account_id, mailbox_path, uid_validity, uid),
                    FOREIGN KEY (account_id, node_message_id)
                        REFERENCES node_mirror_message_links (account_id, node_message_id) ON DELETE CASCADE
                );
                CREATE INDEX node_mirror_membership_links_message
                    ON node_mirror_membership_links (account_id, node_message_id);
                CREATE TABLE node_mirror_attachment_links (
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                    node_attachment_id TEXT NOT NULL,
                    PRIMARY KEY (message_id, ordinal)
                );
                """)
            // Tests only: the same failpoint runs in every Node-mode body.
            try bodyFailpoint?()
        }
        // Journal v4: flag, unflag and move. A move journals its destination
        // folder in `archive_mailbox` (the column holds an archive's or a
        // move's target mailbox). SQLite can't alter a CHECK, so the table is
        // rebuilt with the same rows, indexes and triggers.
        migrator.registerMigration(nodeModeMailIntentFolderActionsMigration, foreignKeyChecks: .immediate) { database in
            try database.execute(sql: """
                CREATE TABLE mail_intent_journal_v4 (
                    operation_id TEXT PRIMARY KEY NOT NULL
                        CHECK (length(operation_id) = 36 AND operation_id = lower(operation_id)),
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('mark_read','mark_unread','archive','delete','flag','unflag','move','save_draft','send','credential_push')),
                    route TEXT CHECK (route IN ('node','direct')),
                    state TEXT NOT NULL,
                    message_id TEXT, draft_id TEXT,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    idempotency_key TEXT
                        CHECK (idempotency_key IS NULL OR (length(idempotency_key) = 36 AND idempotency_key = lower(idempotency_key))),
                    canonical_operation BLOB
                        CHECK (canonical_operation IS NULL OR length(canonical_operation) BETWEEN 1 AND 65536),
                    content_hash TEXT CHECK (content_hash IS NULL OR (kind = 'send' AND length(content_hash) BETWEEN 1 AND 128)),
                    archive_mailbox TEXT CHECK (archive_mailbox IS NULL OR (kind IN ('archive','move') AND length(archive_mailbox) BETWEEN 1 AND 1024)),
                    send_revision TEXT CHECK (send_revision IS NULL OR (kind = 'send' AND length(send_revision) BETWEEN 1 AND 20)),
                    reported INTEGER NOT NULL DEFAULT 0 CHECK (reported IN (0, 1)),
                    deferral_count INTEGER NOT NULL DEFAULT 0 CHECK (deferral_count >= 0),
                    deferral_reason TEXT CHECK (deferral_reason IS NULL OR deferral_reason IN ('mail_server_unreachable','sign_in_refused_for_now','google_unreachable')),
                    first_deferred_at REAL,
                    deferral_due_at REAL,
                    next_attempt_at REAL,
                    CHECK (state IN ('pending','dispatching','admitted','confirmed','uncertain','failed','unconfirmed_after_removal','unconfirmed')),
                    CHECK (state IN ('pending','failed') OR route IS NOT NULL),
                    CHECK (state NOT IN ('admitted','uncertain','unconfirmed_after_removal','unconfirmed') OR route = 'node'),
                    CHECK (canonical_operation IS NULL OR (route = 'node' AND kind NOT IN ('save_draft','credential_push'))),
                    CHECK (idempotency_key IS NULL OR (route = 'node' AND kind != 'credential_push')),
                    CHECK ((message_id IS NOT NULL) = (kind IN ('mark_read','mark_unread','archive','delete','flag','unflag','move'))),
                    CHECK (kind != 'move' OR archive_mailbox IS NOT NULL),
                    CHECK ((draft_id IS NOT NULL) = (kind IN ('save_draft','send')))
                );
                INSERT INTO mail_intent_journal_v4 SELECT * FROM mail_intent_journal;
                DROP TABLE mail_intent_journal;
                ALTER TABLE mail_intent_journal_v4 RENAME TO mail_intent_journal;
                CREATE INDEX mail_intent_journal_account_state ON mail_intent_journal (account_id, state, created_at);
                CREATE INDEX mail_intent_journal_message ON mail_intent_journal (message_id) WHERE message_id IS NOT NULL;
                CREATE INDEX mail_intent_journal_idempotency_key ON mail_intent_journal (idempotency_key)
                    WHERE idempotency_key IS NOT NULL;
                CREATE INDEX mail_intent_journal_updated_at ON mail_intent_journal (updated_at);
                -- Stamps follow commit order: a write never stamps a row
                -- earlier than a change already committed, so a sweep that
                -- remembers the newest stamp it read never skips a row
                -- committed after it (writes are serialized).
                CREATE TRIGGER mail_intent_journal_stamp_after_insert AFTER INSERT ON mail_intent_journal
                WHEN NEW.updated_at < (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                BEGIN
                    UPDATE mail_intent_journal
                    SET updated_at = (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                    WHERE operation_id = NEW.operation_id;
                END;
                CREATE TRIGGER mail_intent_journal_stamp_after_update AFTER UPDATE OF updated_at ON mail_intent_journal
                WHEN NEW.updated_at < (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                BEGIN
                    UPDATE mail_intent_journal
                    SET updated_at = (SELECT MAX(updated_at) FROM mail_intent_journal WHERE operation_id != NEW.operation_id)
                    WHERE operation_id = NEW.operation_id;
                END;
                CREATE INDEX mail_intent_journal_unreported_send_outcome ON mail_intent_journal (updated_at)
                    WHERE kind = 'send' AND reported = 0
                      AND state IN ('failed', 'unconfirmed', 'unconfirmed_after_removal');
                """)
            try bodyFailpoint?()
        }
        return migrator
    }

    /// Runs the Node-mode migrator. Returns `false`, never throws, on failure.
    func migrateNodeMode() -> Bool {
        do {
            try nodeModeMigrationFailpoint?()
            try Self.makeNodeModeMigrator(bodyFailpoint: nodeModeMigrationBodyFailpoint)
                .migrate(databasePool)
            nodeModeSchemaState.markAvailable(Self.nodeModeMigrations)
            return true
        } catch {
            return false
        }
    }

    /// Throws when the probe itself cannot read the database; callers fail
    /// closed on that. Each caller probes the one migration its queries depend
    /// on (v1 sources by default), so a later migration never hides earlier
    /// data from a store that has not migrated it, and an earlier one never
    /// stands in for a table that is missing.
    func nodeModeSchemaStatus(
        migration: String = SQLiteMailStore.nodeModeAccountSourcesMigration
    ) throws -> NodeModeSchemaStatus {
        if nodeModeSchemaState.isAvailable(migration) { return .available }
        let applied = try databasePool.read { database -> Bool in
            let hasLedger = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'grdb_migrations')"
            ) ?? false
            guard hasLedger else { return false }
            return try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?)",
                arguments: [migration]
            ) ?? false
        }
        guard applied else { return .absent }
        nodeModeSchemaState.markAvailable([migration])
        return .available
    }
}

extension SQLiteMailStore {
    /// The first Node-mode migration whose table is truly absent, in migrator
    /// order. A probe error returns nil: the schema may exist, so nothing is
    /// audited.
    func firstAbsentNodeModeMigration() -> String? {
        Self.nodeModeMigrations.first { (try? nodeModeSchemaStatus(migration: $0)) == .absent }
    }
}

public extension SQLiteMailStore {
    /// The account is Direct at `generation`; with `allowNodeFallback`, a Node account in
    /// fallback (synced by this device while its Node is away) passes too.
    static func requireDirectSource(
        accountID: AccountID,
        generation: Int64,
        allowNodeFallback: Bool = false,
        database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, mode, generation FROM account_mail_sources WHERE account_id = ?",
            arguments: [accountID.rawValue]
        )
        guard let row,
              Self.runsDirectSync(row, allowNodeFallback: allowNodeFallback),
              (row["generation"] as Int64) == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
    }

    private static func runsDirectSync(_ row: Row, allowNodeFallback: Bool) -> Bool {
        if (row["kind"] as String) == AccountMailSourceKind.direct.rawValue { return true }
        return allowNodeFallback
            && (row["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue
            && (row["mode"] as String?) == NodeBackedMode.fallback.rawValue
    }

    /// The account is still Node-backed at `generation`.
    static func requireNodeBackedSource(
        accountID: AccountID,
        generation: Int64,
        database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, generation FROM account_mail_sources WHERE account_id = ?",
            arguments: [accountID.rawValue]
        )
        guard let row,
              (row["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue,
              (row["generation"] as Int64) == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
    }

    /// Like `requireDirectSource`, but also accepts a Sync Node account the device mirrors
    /// (`node_backed` in `node` mode): for changes that stay in this database, such as labels.
    static func requireLocalMailSource(
        accountID: AccountID,
        generation: Int64,
        database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, mode, generation FROM account_mail_sources WHERE account_id = ?",
            arguments: [accountID.rawValue]
        )
        guard let row, (row["generation"] as Int64) == generation else {
            throw NodeMailModeStoreError.generationConflict
        }
        let kind: String = row["kind"]
        let mode: String? = row["mode"]
        guard kind == AccountMailSourceKind.direct.rawValue
                || (kind == AccountMailSourceKind.nodeBacked.rawValue && mode == NodeBackedMode.node.rawValue)
        else { throw NodeMailModeStoreError.generationConflict }
    }

    var nodeModeSchemaAvailable: Bool {
        (try? nodeModeSchemaStatus()) == .available
    }

    /// An account without a stored row, or any account while the schema is
    /// absent, is Direct at generation 0. Throws when the store is unreadable.
    func mailSource(accountID: AccountID) throws -> AccountMailSource {
        try explicitMailSource(accountID: accountID) ?? .direct(accountID)
    }

    /// A legacy account can still be read as Direct, but local iOS provider
    /// access requires an explicit source row.
    func explicitMailSource(accountID: AccountID) throws -> AccountMailSource? {
        guard try nodeModeSchemaStatus() == .available else { return nil }
        let row = try databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT account_id, kind, mode, node_id, logical_mailbox_id,
                           provider_identity, generation
                    FROM account_mail_sources WHERE account_id = ?
                    """,
                arguments: [accountID.rawValue]
            )
        }
        guard let row else { return nil }
        return try Self.decodeMailSource(row)
    }

    func requireDirectMailSource(accountID: AccountID) throws {
        guard try nodeModeSchemaStatus() == .available,
              let source = try explicitMailSource(accountID: accountID) else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
        guard source.kind == .direct else { throw NodeMailModeStoreError.generationConflict }
    }

    /// The account syncs with its provider on this device: Direct, or a Node account in
    /// fallback while its Node is away.
    func requireDirectSyncSource(accountID: AccountID) throws {
        guard try nodeModeSchemaStatus() == .available,
              let source = try explicitMailSource(accountID: accountID) else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
        guard source.runsDirectSync else { throw NodeMailModeStoreError.generationConflict }
    }

    /// One source per cached account, in account order.
    func mailSources() throws -> [AccountMailSource] {
        let accounts = self.accounts
        guard try nodeModeSchemaStatus() == .available else { return accounts.map { .direct($0.id) } }
        let stored = try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT account_id, kind, mode, node_id, logical_mailbox_id,
                           provider_identity, generation
                    FROM account_mail_sources
                    """
            )
        }
        var byAccount: [AccountID: AccountMailSource] = [:]
        for row in stored {
            let source = try Self.decodeMailSource(row)
            byAccount[source.accountID] = source
        }
        return accounts.map { byAccount[$0.id] ?? .direct($0.id) }
    }

    /// Accounts whose mail this Mac syncs with the provider. With the schema
    /// absent that is every account; if the schema or the sources cannot be
    /// read it is none, so a Node-mode account is never synced directly by
    /// mistake.
    var directSyncAccounts: [Account] {
        let accounts = self.accounts
        switch try? nodeModeSchemaStatus() {
        case .absent:
            return accounts
        case nil:
            return []
        case .available:
            break
        }
        guard let nodeModeAccountIDs = try? databasePool.read({ database in
            try String.fetchSet(
                database,
                sql: """
                    SELECT account_id FROM account_mail_sources
                    WHERE kind = 'node_backed' AND mode = 'node'
                    """
            )
        }) else { return [] }
        return accounts.filter { !nodeModeAccountIDs.contains($0.id.rawValue) }
    }

    /// Fails closed: an unreadable source does not run direct sync.
    func runsDirectSync(accountID: AccountID) -> Bool {
        (try? mailSource(accountID: accountID))?.runsDirectSync ?? false
    }

    /// Adds an account that lives on a Sync Node: the account, its inbox and its
    /// Node-backed source in one write. A Node mailbox already bound to an
    /// account returns that account unchanged, so running it again on every
    /// launch is safe. Another account with the same id or address is refused.
    /// Posts an `.accounts` change when it writes.
    @discardableResult
    func createNodeBackedAccount(_ account: Account, source: AccountMailSource) throws -> AccountID {
        guard try nodeModeSchemaStatus() == .available else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
        try source.validate()
        guard source.accountID == account.id, source.kind == .nodeBacked, source.mode == .node, source.generation == 1,
              let nodeID = source.nodeID, let logicalMailboxID = source.logicalMailboxID
        else { throw AccountMailSourceError.invalidSource }
        let created: AccountID? = try databasePool.write { database in
            if let bound = try String.fetchOne(
                database,
                sql: """
                    SELECT account_id FROM account_mail_sources
                    WHERE kind = 'node_backed' AND node_id = ? AND logical_mailbox_id = ?
                    """,
                arguments: [nodeID, logicalMailboxID]
            ) {
                return AccountID(bound)
            }
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ? OR lower(email) = lower(?))",
                arguments: [account.id.rawValue, account.email.rawValue]
            ) ?? false
            guard !exists else { throw NodeMailModeStoreError.accountExists }
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, display_name, email, username, sent_mailbox,
                        imap_host, imap_port, smtp_host, smtp_port
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    account.id.rawValue, account.displayName, account.email.rawValue, account.username,
                    account.sentMailbox, account.imapHost, String(account.imapPort), account.smtpHost,
                    String(account.smtpPort),
                ]
            )
            try database.execute(
                sql: "INSERT INTO mailboxes (id, account_id, name, path, special_use) VALUES (?, ?, ?, ?, ?)",
                arguments: ["mbx_\(account.id.rawValue)_inbox", account.id.rawValue, "INBOX", "INBOX", "\\Inbox"]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_mail_sources (
                        account_id, kind, mode, node_id, logical_mailbox_id,
                        provider_identity, generation, mode_changed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    account.id.rawValue, source.kind.rawValue, source.mode?.rawValue, nodeID, logicalMailboxID,
                    source.providerIdentity, source.generation, Date().timeIntervalSince1970,
                ]
            )
            return nil
        }
        if let created { return created }
        MailStoreChangeSignal.post(scope: .accounts)
        return account.id
    }

    /// Compare-and-swap. `source` must be derived from the stored source at
    /// `expectedGeneration` (its generation is exactly one ahead); a stale
    /// writer gets `generationConflict`. Posts an `.accounts` change.
    @discardableResult
    func replaceMailSource(
        _ source: AccountMailSource,
        expectedGeneration: Int64
    ) throws -> AccountMailSource {
        guard try nodeModeSchemaStatus() == .available else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
        try source.validate()
        guard expectedGeneration >= 0, expectedGeneration < Int64.max,
              source.generation == expectedGeneration + 1
        else { throw NodeMailModeStoreError.generationConflict }
        try databasePool.write { database in
            let storedGeneration = try Int64.fetchOne(
                database,
                sql: "SELECT generation FROM account_mail_sources WHERE account_id = ?",
                arguments: [source.accountID.rawValue]
            ) ?? 0
            guard storedGeneration == expectedGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
            let directSendUnresolved = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM direct_send_intents WHERE account_id = ? AND state IN ('submitting', 'uncertain'))",
                arguments: [source.accountID.rawValue]
            ) ?? false
            guard !directSendUnresolved else { throw NodeMailModeStoreError.directSendUnresolved }
            let nodeSendUnresolved = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM node_send_intents WHERE account_id = ? AND state IN ('reserved', 'pending', 'uncertain'))",
                arguments: [source.accountID.rawValue]
            ) ?? false
            guard !nodeSendUnresolved else { throw NodeMailModeStoreError.nodeSendUnresolved }
            let operationUnresolved = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM durable_jobs
                        WHERE state IN ('queued', 'running', 'paused', 'delivery-uncertain')
                          AND ((ownership_kind = 'account' AND owner_account_id = ?)
                               OR ownership_kind != 'account')
                    )
                    """,
                arguments: [source.accountID.rawValue]
            ) ?? false
            guard !operationUnresolved else { throw NodeMailModeStoreError.operationUnresolved }
            let deletionPending = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM account_deletion_intents WHERE account_id = ?)",
                arguments: [source.accountID.rawValue]
            ) ?? false
            guard !deletionPending else { throw NodeMailModeStoreError.generationConflict }
            try database.execute(
                sql: """
                    INSERT INTO account_mail_sources (
                        account_id, kind, mode, node_id, logical_mailbox_id,
                        provider_identity, generation, mode_changed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        kind = excluded.kind,
                        mode = excluded.mode,
                        node_id = excluded.node_id,
                        logical_mailbox_id = excluded.logical_mailbox_id,
                        provider_identity = excluded.provider_identity,
                        generation = excluded.generation,
                        mode_changed_at = excluded.mode_changed_at
                    """,
                arguments: [
                    source.accountID.rawValue,
                    source.kind.rawValue,
                    source.mode?.rawValue,
                    source.nodeID,
                    source.logicalMailboxID,
                    source.providerIdentity,
                    source.generation,
                    Date().timeIntervalSince1970,
                ]
            )
        }
        MailStoreChangeSignal.post(scope: .accounts)
        return source
    }

    /// The local message holding the exact IMAP membership, if any.
    func resolveStableMessageKey(_ key: StableMessageKey) throws -> MessageID? {
        try stableMessageKeyRow(key).map { MessageID($0.messageID) }
    }

    /// Returns the existing message ID for the key; throws messageIdentityMismatch when the stored RFC Message-ID differs from `rfcMessageID` (secondary check).
    func verifyStableMessageKey(_ key: StableMessageKey, rfcMessageID: String?) throws -> MessageID? {
        guard let row = try stableMessageKeyRow(key) else { return nil }
        if let expected = rfcMessageID.flatMap(Self.normalizedRFCMessageID),
           let stored = row.rfcMessageID.flatMap(Self.normalizedRFCMessageID),
           expected != stored {
            throw NodeMailModeStoreError.messageIdentityMismatch
        }
        return MessageID(row.messageID)
    }
}

// MARK: - Mail intent journal

// Every user mail change on a Node-backed account is journaled before it is
// dispatched, and the journal is the admitted-work guard: once work may have
// left toward the Node it can never be dispatched directly or resent. The
// APIs probe only `node-mode-v2-mail-intent-journal`. While that table is
// truly absent there are no intents: reads return nothing and writes throw
// `schemaUnavailable`. A probe or read error always propagates.
public extension SQLiteMailStore {
    /// False while the journal table is absent or its probe cannot read the database.
    var mailIntentJournalAvailable: Bool {
        (try? mailIntentJournalStatus()) == .available
    }

    /// Journals a new intent as `pending` with no route. Re-journaling the same
    /// intent returns the stored row; a different intent under the same ID is
    /// a `generationConflict`.
    func journalMailIntent(
        operationID: String,
        accountID: AccountID,
        kind: MailIntentKind,
        messageID: MessageID?,
        draftID: DraftID?,
        contentHash: String? = nil,
        archiveMailbox: String? = nil,
        now: Date
    ) throws -> MailIntentRecord {
        guard MailIntentRecord.isValidOperationID(operationID),
              MailIntentRecord.hasValidTarget(kind: kind, messageID: messageID, draftID: draftID),
              contentHash == nil || kind == .send,
              MailIntentRecord.hasValidFolder(kind: kind, folder: archiveMailbox)
        else { throw NodeMailModeStoreError.invalidMailIntent }
        try requireMailIntentJournal()
        return try databasePool.write { database in
            if let existing = try Self.fetchMailIntent(database, operationID: operationID) {
                guard existing.accountID == accountID, existing.kind == kind,
                      existing.messageID == messageID, existing.draftID == draftID,
                      existing.contentHash == contentHash, existing.archiveMailbox == archiveMailbox
                else { throw NodeMailModeStoreError.generationConflict }
                return existing
            }
            try database.execute(
                sql: """
                    INSERT INTO mail_intent_journal (
                        operation_id, account_id, kind, route, state, message_id, draft_id,
                        created_at, updated_at, content_hash, archive_mailbox
                    ) VALUES (?, ?, ?, NULL, 'pending', ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    operationID, accountID.rawValue, kind.rawValue, messageID?.rawValue, draftID?.rawValue,
                    now.timeIntervalSince1970, now.timeIntervalSince1970, contentHash, archiveMailbox,
                ]
            )
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// Compare-and-swap `pending → dispatching` that fixes the route. Direct
    /// dispatch needs `MailIntentGuard.mayDispatchDirect`; a second caller, or
    /// any intent that already started, gets `generationConflict`.
    func beginMailIntentDispatch(
        operationID: String,
        route: MailIntentRoute,
        canonicalOperation: Data? = nil,
        idempotencyKey: String? = nil,
        sendRevision: String? = nil,
        now: Date
    ) throws -> MailIntentRecord {
        guard (canonicalOperation == nil && idempotencyKey == nil && sendRevision == nil) || route == .node,
              idempotencyKey.map(MailIntentRecord.isValidOperationID) ?? true,
              sendRevision.map({ UInt64($0) != nil }) ?? true
        else { throw NodeMailModeStoreError.invalidMailIntent }
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard let current = try Self.fetchMailIntent(database, operationID: operationID) else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            let allowed = switch route {
            case .direct: MailIntentGuard.mayDispatchDirect(current)
            case .node: current.state == .pending && current.route == nil
            }
            guard allowed else { throw NodeMailModeStoreError.generationConflict }
            // A direct dispatch never overtakes an older, still-unrouted
            // change to the same message or draft: the drain sends them in
            // order (the provider's final state is the newer change's).
            if route == .direct, try Self.fetchOlderPendingIntent(database, sharingTargetWith: current) != nil {
                throw NodeMailModeStoreError.generationConflict
            }
            // A dispatch that begins is the attempt the back-off waited for.
            // A Node dispatch also ends any run of direct deferrals: their
            // count, window and reason are the mail server's, not the Node's.
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal
                    SET state = 'dispatching', route = ?, updated_at = ?,
                        canonical_operation = ?, idempotency_key = ?, send_revision = ?,
                        next_attempt_at = NULL
                    WHERE operation_id = ? AND state = 'pending' AND route IS NULL
                    """,
                arguments: [
                    route.rawValue, now.timeIntervalSince1970,
                    canonicalOperation, idempotencyKey ?? (canonicalOperation == nil ? nil : operationID), sendRevision,
                    operationID,
                ]
            )
            if route == .node, database.changesCount == 1 {
                try Self.clearDirectDeferrals(database, operationID: operationID)
            }
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// Records a dispatch outcome. Only the moves in `MailIntentTransition`
    /// are allowed; anything else is a `generationConflict`.
    func recordMailIntentOutcome(
        operationID: String,
        state: MailIntentState,
        now: Date
    ) throws -> MailIntentRecord {
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard let current = try Self.fetchMailIntent(database, operationID: operationID) else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            guard MailIntentTransition.mayRecordOutcome(from: current.state, to: state, route: current.route) else {
                throw NodeMailModeStoreError.generationConflict
            }
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET state = ?, updated_at = ?
                    WHERE operation_id = ? AND state = ? AND route = ?
                    """,
                arguments: [
                    state.rawValue, now.timeIntervalSince1970, operationID,
                    current.state.rawValue, current.route?.rawValue,
                ]
            )
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            // An outcome ends the run of deferrals (a refusal has its own
            // message, so an earlier network reason is not kept for it).
            try Self.clearDirectDeferrals(database, operationID: operationID)
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// One intent by its operation ID, or nil when it was never journaled
    /// (or the journal table is absent). A read error propagates.
    func mailIntent(operationID: String) throws -> MailIntentRecord? {
        guard try mailIntentJournalStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Self.fetchMailIntent(database, operationID: operationID)
        }
    }

    /// The intent a Node receipt belongs to: its operation ID or the key it
    /// was re-signed under.
    func mailIntent(idempotencyKey: String) throws -> MailIntentRecord? {
        guard try mailIntentJournalStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT * FROM mail_intent_journal WHERE operation_id = ? OR idempotency_key = ? LIMIT 1",
                arguments: [idempotencyKey, idempotencyKey]
            ).map(Self.decodeMailIntent)
        }
    }

    /// The exact signed operation a Node intent dispatched, for replay.
    func mailIntentCanonicalOperation(operationID: String) throws -> Data? {
        guard try mailIntentJournalStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT canonical_operation FROM mail_intent_journal WHERE operation_id = ?",
                arguments: [operationID]
            )
        }
    }

    /// Stores the exact signed operation a Node intent is about to send.
    /// Only a `dispatching` intent may replace its operation (a re-signing
    /// after a stale authority epoch); an `uncertain` one may only gain the
    /// first one (a send whose draft save landed). Admitted work is never
    /// re-signed.
    func storeMailIntentOperation(
        operationID: String,
        idempotencyKey: String,
        canonicalOperation: Data,
        now: Date
    ) throws -> MailIntentRecord {
        guard MailIntentRecord.isValidOperationID(idempotencyKey), !canonicalOperation.isEmpty else {
            throw NodeMailModeStoreError.invalidMailIntent
        }
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard try Self.fetchMailIntent(database, operationID: operationID) != nil else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal
                    SET canonical_operation = ?, idempotency_key = ?, updated_at = ?
                    WHERE operation_id = ? AND route = 'node' AND kind NOT IN ('save_draft', 'credential_push')
                      AND (state = 'dispatching' OR (state = 'uncertain' AND canonical_operation IS NULL))
                    """,
                arguments: [canonicalOperation, idempotencyKey, now.timeIntervalSince1970, operationID]
            )
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// Journals the key a draft save is (re)signed under, and for a send the
    /// Node draft revision its send will be signed at, before the save
    /// leaves. Only a Node save stage may change it: a `save_draft` intent, or
    /// a send whose own operation was never stored.
    func storeMailIntentSaveKey(
        operationID: String,
        idempotencyKey: String,
        sendRevision: String?,
        now: Date
    ) throws -> MailIntentRecord {
        guard MailIntentRecord.isValidOperationID(idempotencyKey),
              sendRevision.map({ UInt64($0) != nil }) ?? true
        else { throw NodeMailModeStoreError.invalidMailIntent }
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard let current = try Self.fetchMailIntent(database, operationID: operationID) else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            guard sendRevision == nil || current.kind == .send else { throw NodeMailModeStoreError.invalidMailIntent }
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET idempotency_key = ?, send_revision = ?, updated_at = ?
                    WHERE operation_id = ? AND route = 'node' AND kind IN ('send', 'save_draft')
                      AND canonical_operation IS NULL AND state IN ('dispatching', 'admitted', 'uncertain')
                    """,
                arguments: [idempotencyKey, sendRevision, now.timeIntervalSince1970, operationID]
            )
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// Fails a Node draft-save stage: a `save_draft` intent, or a send whose
    /// own operation was never stored and therefore never left. The same
    /// UPDATE requires `canonical_operation IS NULL`, so a send whose bytes
    /// were stored (it may have been posted) is never failed through here.
    func failMailIntentSaveStage(operationID: String, now: Date) throws -> MailIntentRecord {
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard try Self.fetchMailIntent(database, operationID: operationID) != nil else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET state = 'failed', updated_at = ?
                    WHERE operation_id = ? AND route = 'node' AND kind IN ('send', 'save_draft')
                      AND canonical_operation IS NULL AND state IN ('dispatching', 'admitted', 'uncertain')
                    """,
                arguments: [now.timeIntervalSince1970, operationID]
            )
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// A row-specific refusal before any dispatch (its draft or message is
    /// gone, or the draft changed since the user approved the send):
    /// `pending` with no route → `failed` with no route. Only an explicit
    /// user action resends it.
    func refuseUnroutedMailIntent(operationID: String, now: Date) throws -> MailIntentRecord {
        try requireMailIntentJournal()
        return try databasePool.write { database in
            guard try Self.fetchMailIntent(database, operationID: operationID) != nil else {
                throw NodeMailModeStoreError.mailIntentNotFound
            }
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET state = 'failed', updated_at = ?,
                        deferral_count = 0, deferral_reason = NULL, first_deferred_at = NULL,
                        deferral_due_at = NULL, next_attempt_at = NULL
                    WHERE operation_id = ? AND state = 'pending' AND route IS NULL AND kind != 'credential_push'
                    """,
                arguments: [now.timeIntervalSince1970, operationID]
            )
            guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
            return try Self.requireMailIntent(database, operationID: operationID)
        }
    }

    /// A direct dispatch that provably never reached the provider (the vault
    /// locked, the service runtime closed, or the account left fallback
    /// before any provider effect): `dispatching(direct)` → `pending` with
    /// no route, so a later pass dispatches it by the account's mode then.
    /// A `transient` deferral (the network, a temporary sign-in refusal)
    /// stores its reason and run and holds the row until its next attempt;
    /// a passing one (locked, back in node mode) leaves the run and the
    /// reason as they are.
    func deferDirectMailIntent(
        operationID: String, now: Date, transient: TransientDirectDeferral? = nil
    ) throws -> MailIntentRecord {
        guard (transient?.attempts ?? 1) >= 1 else {
            throw NodeMailModeStoreError.invalidMailIntent
        }
        // Retried once: a provably pre-effect deferral must not be stranded
        // in `dispatching(direct)` by a busy database.
        return try Self.retryingOnceWhenBusy {
            try requireMailIntentJournal()
            return try databasePool.write { database in
                guard try Self.fetchMailIntent(database, operationID: operationID) != nil else {
                    throw NodeMailModeStoreError.mailIntentNotFound
                }
                if let transient {
                    try database.execute(
                        sql: """
                            UPDATE mail_intent_journal SET state = 'pending', route = NULL, updated_at = ?,
                                deferral_reason = ?, deferral_count = ?, first_deferred_at = ?,
                                deferral_due_at = ?, next_attempt_at = ?
                            WHERE operation_id = ? AND state = 'dispatching' AND route = 'direct'
                            """,
                        arguments: [now.timeIntervalSince1970, transient.reason.rawValue, transient.attempts,
                                    transient.startedAt.timeIntervalSince1970, transient.nextAttemptAt.timeIntervalSince1970,
                                    transient.nextAttemptAt.timeIntervalSince1970, operationID]
                    )
                } else {
                    try database.execute(
                        sql: """
                            UPDATE mail_intent_journal SET state = 'pending', route = NULL, updated_at = ?
                            WHERE operation_id = ? AND state = 'dispatching' AND route = 'direct'
                            """,
                        arguments: [now.timeIntervalSince1970, operationID]
                    )
                }
                guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
                return try Self.requireMailIntent(database, operationID: operationID)
            }
        }
    }

    /// A direct dispatch deferred too often or too long for a transient
    /// reason: `dispatching(direct)` → `failed` (nothing was sent), keeping
    /// the reason for the notice. Retried once on a busy database.
    func failDeferredDirectMailIntent(operationID: String, reason: DirectDeferralReason, now: Date) throws -> MailIntentRecord {
        return try Self.retryingOnceWhenBusy {
            try requireMailIntentJournal()
            return try databasePool.write { database in
                guard try Self.fetchMailIntent(database, operationID: operationID) != nil else {
                    throw NodeMailModeStoreError.mailIntentNotFound
                }
                try database.execute(
                    sql: """
                        UPDATE mail_intent_journal SET state = 'failed', updated_at = ?,
                            deferral_reason = ?, next_attempt_at = NULL
                        WHERE operation_id = ? AND state = 'dispatching' AND route = 'direct'
                        """,
                    arguments: [now.timeIntervalSince1970, reason.rawValue, operationID]
                )
                guard database.changesCount == 1 else { throw NodeMailModeStoreError.generationConflict }
                return try Self.requireMailIntent(database, operationID: operationID)
            }
        }
    }

    /// The oldest still-unrouted pending change (in drain order) that is
    /// older than `operationID`'s and touches the same message or draft.
    func olderPendingIntent(sharingTargetWith operationID: String) throws -> MailIntentRecord? {
        guard try mailIntentJournalStatus() == .available else { return nil }
        return try databasePool.read { database in
            guard let record = try Self.fetchMailIntent(database, operationID: operationID) else { return nil }
            return try Self.fetchOlderPendingIntent(database, sharingTargetWith: record)
        }
    }

    private static func fetchOlderPendingIntent(_ database: Database, sharingTargetWith record: MailIntentRecord) throws -> MailIntentRecord? {
        guard record.messageID != nil || record.draftID != nil else { return nil }
        return try Row.fetchOne(
            database,
            sql: """
                SELECT * FROM mail_intent_journal
                WHERE account_id = ? AND state = 'pending' AND route IS NULL AND kind != 'credential_push'
                  AND operation_id != ?
                  AND ((? IS NOT NULL AND message_id = ?) OR (? IS NOT NULL AND draft_id = ?))
                  AND (created_at < ? OR (created_at = ? AND operation_id < ?))
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
            arguments: [
                record.accountID.rawValue, record.operationID,
                record.messageID?.rawValue, record.messageID?.rawValue, record.draftID?.rawValue, record.draftID?.rawValue,
                record.createdAt.timeIntervalSince1970, record.createdAt.timeIntervalSince1970, record.operationID,
            ]
        ).map(decodeMailIntent)
    }

    private static func retryingOnceWhenBusy<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            return try body()
        }
    }

    private static func clearDirectDeferrals(_ database: Database, operationID: String) throws {
        try database.execute(
            sql: """
                UPDATE mail_intent_journal
                SET deferral_count = 0, deferral_reason = NULL, first_deferred_at = NULL,
                    deferral_due_at = NULL, next_attempt_at = NULL
                WHERE operation_id = ?
                """,
            arguments: [operationID]
        )
    }

    /// Per account in fallback, the latest reason one of its still-pending
    /// changes is waiting on a transient failure (the mail server or Google
    /// unreachable), most recent first. Rows of accounts in Node mode are
    /// not waiting on the mail server and do not count.
    func pendingDirectDeferrals() throws -> [PendingDirectDeferral] {
        guard try mailIntentJournalStatus() == .available else { return [] }
        return try databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT j.account_id, a.display_name, j.deferral_reason
                    FROM mail_intent_journal j
                    JOIN account_mail_sources s ON s.account_id = j.account_id
                    JOIN accounts a ON a.id = j.account_id
                    WHERE j.state = 'pending' AND j.route IS NULL AND j.kind != 'credential_push'
                      AND j.deferral_count > 0 AND j.deferral_reason IS NOT NULL
                      AND s.kind = 'node_backed' AND s.mode = 'fallback'
                    ORDER BY j.updated_at DESC, j.operation_id DESC
                    """
            )
            var seen: Set<String> = []
            return rows.compactMap { row -> PendingDirectDeferral? in
                let accountID: String = row["account_id"]
                guard let reason = DirectDeferralReason(rawValue: row["deferral_reason"]),
                      seen.insert(accountID).inserted
                else { return nil }
                return PendingDirectDeferral(accountID: AccountID(accountID), accountName: row["display_name"], reason: reason)
            }
        }
    }

    /// The user's own request reported this intent's outcome (the router
    /// returned it to the interactive caller), so no later notice repeats it.
    func markMailIntentReported(operationID: String) throws {
        try requireMailIntentJournal()
        try databasePool.write { database in
            try database.execute(
                sql: "UPDATE mail_intent_journal SET reported = 1 WHERE operation_id = ?",
                arguments: [operationID]
            )
        }
    }

    /// Sends that ended `failed`, `unconfirmed` or `unconfirmed_after_removal`
    /// after the watermark `(after, afterOperationID)`, whose outcome no
    /// request reported: oldest first, at most `limit`. The operation ID
    /// breaks ties, so two outcomes with one timestamp are both shown.
    func unreportedSendOutcomes(after: Date, afterOperationID: String = "", limit: Int) throws -> [MailIntentRecord] {
        guard limit > 0, try mailIntentJournalStatus() == .available else { return [] }
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM mail_intent_journal
                    WHERE kind = 'send' AND reported = 0
                      AND state IN ('failed', 'unconfirmed', 'unconfirmed_after_removal')
                      AND (updated_at > ? OR (updated_at = ? AND operation_id > ?))
                    ORDER BY updated_at, operation_id
                    LIMIT ?
                    """,
                arguments: [after.timeIntervalSince1970, after.timeIntervalSince1970, afterOperationID, limit]
            ).map(Self.decodeMailIntent)
        }
    }

    /// True while a send of `draftID` is queued, in flight, admitted, may
    /// have gone out, or went out: the draft is locked against a second send.
    func mailIntentSendInFlight(draftID: DraftID) throws -> Bool {
        guard try mailIntentJournalStatus() == .available else { return false }
        return try databasePool.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM mail_intent_journal
                        WHERE kind = 'send' AND draft_id = ? AND state != 'failed'
                    )
                    """,
                arguments: [draftID.rawValue]
            ) ?? false
        }
    }

    /// Send intents in `states` last written after `after` (bound as a
    /// Double against the REAL `updated_at`), oldest first.
    func sendIntents(states: Set<MailIntentState>, updatedAfter after: Date) throws -> [MailIntentRecord] {
        guard !states.isEmpty, try mailIntentJournalStatus() == .available else { return [] }
        let stateValues = states.map(\.rawValue).sorted()
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM mail_intent_journal
                    WHERE kind = 'send' AND state IN (\(Self.placeholders(stateValues.count))) AND updated_at > ?
                    ORDER BY updated_at, operation_id
                    """,
                arguments: StatementArguments(stateValues) + [after.timeIntervalSince1970]
            ).map(Self.decodeMailIntent)
        }
    }

    /// The account's intents in `states`, oldest first.
    func mailIntents(accountID: AccountID, states: Set<MailIntentState>) throws -> [MailIntentRecord] {
        guard !states.isEmpty, try mailIntentJournalStatus() == .available else { return [] }
        let stateValues = states.map(\.rawValue).sorted()
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM mail_intent_journal
                    WHERE account_id = ? AND state IN (\(Self.placeholders(stateValues.count)))
                    ORDER BY created_at, operation_id
                    """,
                arguments: StatementArguments([accountID.rawValue] + stateValues)
            ).map(Self.decodeMailIntent)
        }
    }

    /// Messages with an `admitted` or `uncertain` Node intent: the ones the UI
    /// marks "Waiting for Sync Node".
    func mailIntentsWaitingForNode(messageIDs: [MessageID]) throws -> Set<MessageID> {
        guard !messageIDs.isEmpty, try mailIntentJournalStatus() == .available else { return [] }
        var seen = Set<String>()
        let unique = messageIDs.map(\.rawValue).filter { seen.insert($0).inserted }
        return try databasePool.read { database in
            var waiting = Set<MessageID>()
            for start in stride(from: 0, to: unique.count, by: Self.mailIntentLookupChunk) {
                let chunk = Array(unique[start..<min(start + Self.mailIntentLookupChunk, unique.count)])
                let found = try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT message_id FROM mail_intent_journal
                        WHERE route = 'node' AND state IN ('admitted', 'uncertain')
                          AND message_id IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk)
                )
                waiting.formUnion(found.map { MessageID($0) })
            }
            return waiting
        }
    }

    /// Reconnect: returns the account's route-nil `pending` mail intents (the
    /// only unstarted ones; fallback dispatch always moves a row to
    /// `dispatching(direct)` first) so they are dispatched through the Node.
    /// Their route is fixed only when that dispatch begins, so nothing is
    /// written here, and `dispatching(direct)` or any other state is never
    /// touched. Lifecycle-owned `credential_push` rows are left out.
    func rerouteUnstartedDirectIntents(accountID: AccountID, now: Date) throws -> [MailIntentRecord] {
        guard try mailIntentJournalStatus() == .available else { return [] }
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM mail_intent_journal
                    WHERE account_id = ? AND state = 'pending' AND route IS NULL
                      AND kind != 'credential_push'
                    ORDER BY created_at, operation_id
                    """,
                arguments: [accountID.rawValue]
            ).map(Self.decodeMailIntent)
        }
    }

    /// Node removal: admitted/uncertain/dispatching(node) become unconfirmedAfterRemoval.
    func markNodeIntentsUnconfirmed(accountID: AccountID, now: Date) throws -> Int {
        guard try mailIntentJournalStatus() == .available else { return 0 }
        return try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal
                    SET state = 'unconfirmed_after_removal', updated_at = ?
                    WHERE account_id = ? AND route = 'node'
                      AND state IN ('dispatching', 'admitted', 'uncertain')
                    """,
                arguments: [now.timeIntervalSince1970, accountID.rawValue]
            )
            return database.changesCount
        }
    }

    /// Credential pushes: every `pending` credential_push row of the account except `keeping` moves `pending → failed` (superseded).
    func supersedePendingCredentialPushes(
        accountID: AccountID,
        keeping operationID: String,
        now: Date
    ) throws -> Int {
        guard try mailIntentJournalStatus() == .available else { return 0 }
        return try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET state = 'failed', updated_at = ?
                    WHERE account_id = ? AND kind = 'credential_push' AND state = 'pending'
                      AND route IS NULL AND operation_id != ?
                    """,
                arguments: [now.timeIntervalSince1970, accountID.rawValue, operationID]
            )
            return database.changesCount
        }
    }

    /// Service start: a `dispatching(node)` intent last written before this
    /// process started (`dispatchedBefore`) was interrupted after its request
    /// may have left, so it becomes `uncertain` and is never replayed
    /// directly. An interrupted `dispatching(direct)` intent is left as it is:
    /// it may have reached the provider, the guard already refuses to resend
    /// it, and `uncertain` is Node-only.
    func recoverInterruptedMailIntentDispatches(dispatchedBefore cutoff: Date, now: Date) throws -> Int {
        guard try mailIntentJournalStatus() == .available else { return 0 }
        return try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE mail_intent_journal SET state = 'uncertain', updated_at = ?
                    WHERE route = 'node' AND state = 'dispatching' AND updated_at < ?
                    """,
                arguments: [now.timeIntervalSince1970, cutoff.timeIntervalSince1970]
            )
            return database.changesCount
        }
    }
}

extension SQLiteMailStore {
    /// Throws when the probe cannot read the database; callers fail closed.
    func mailIntentJournalStatus() throws -> NodeModeSchemaStatus {
        try nodeModeSchemaStatus(migration: Self.nodeModeMailIntentJournalMigration)
    }
}

private extension SQLiteMailStore {
    static let mailIntentLookupChunk = 500

    func requireMailIntentJournal() throws {
        guard try mailIntentJournalStatus() == .available else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static func fetchMailIntent(_ database: Database, operationID: String) throws -> MailIntentRecord? {
        try Row.fetchOne(
            database,
            sql: "SELECT * FROM mail_intent_journal WHERE operation_id = ?",
            arguments: [operationID]
        ).map(decodeMailIntent)
    }

    static func requireMailIntent(_ database: Database, operationID: String) throws -> MailIntentRecord {
        guard let record = try fetchMailIntent(database, operationID: operationID) else {
            throw NodeMailModeStoreError.mailIntentNotFound
        }
        return record
    }

    static func decodeMailIntent(_ row: Row) throws -> MailIntentRecord {
        guard let kind = MailIntentKind(rawValue: row["kind"]),
              let state = MailIntentState(rawValue: row["state"])
        else { throw NodeMailModeStoreError.invalidMailIntent }
        let rawRoute: String? = row["route"]
        let route = try rawRoute.map { raw -> MailIntentRoute in
            guard let route = MailIntentRoute(rawValue: raw) else { throw NodeMailModeStoreError.invalidMailIntent }
            return route
        }
        let messageID: String? = row["message_id"]
        let draftID: String? = row["draft_id"]
        let idempotencyKey: String? = row["idempotency_key"]
        let contentHash: String? = row["content_hash"]
        let archiveMailbox: String? = row["archive_mailbox"]
        let sendRevision: String? = row["send_revision"]
        let deferralReason: String? = row["deferral_reason"]
        guard deferralReason.map({ DirectDeferralReason(rawValue: $0) != nil }) ?? true else {
            throw NodeMailModeStoreError.invalidMailIntent
        }
        let firstDeferredAt: Double? = row["first_deferred_at"]
        let deferralDueAt: Double? = row["deferral_due_at"]
        let nextAttemptAt: Double? = row["next_attempt_at"]
        return MailIntentRecord(
            operationID: row["operation_id"],
            accountID: AccountID(row["account_id"] as String),
            kind: kind,
            route: route,
            state: state,
            messageID: messageID.map { MessageID($0) },
            draftID: draftID.map { DraftID($0) },
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            idempotencyKey: idempotencyKey,
            contentHash: contentHash,
            archiveMailbox: archiveMailbox,
            sendRevision: sendRevision,
            deferralCount: row["deferral_count"] ?? 0,
            deferralReason: deferralReason.flatMap(DirectDeferralReason.init(rawValue:)),
            firstDeferredAt: firstDeferredAt.map { Date(timeIntervalSince1970: $0) },
            deferralDueAt: deferralDueAt.map { Date(timeIntervalSince1970: $0) },
            nextAttemptAt: nextAttemptAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private extension SQLiteMailStore {
    func stableMessageKeyRow(_ key: StableMessageKey) throws -> (messageID: String, rfcMessageID: String?)? {
        try databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT mm.message_id, m.rfc_message_id
                    FROM mailbox_messages mm
                    JOIN messages m ON m.id = mm.message_id
                    WHERE mm.account_id = ? AND mm.mailbox_path = ?
                      AND mm.uid_validity = ? AND mm.uid = ?
                    """,
                arguments: [key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid]
            ).map { ($0["message_id"], $0["rfc_message_id"]) }
        }
    }

    /// Trims whitespace and one pair of angle brackets, and lowercases only
    /// the domain (after the last `@`); the local part stays case-sensitive.
    static func normalizedRFCMessageID(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        guard !trimmed.isEmpty else { return nil }
        guard let at = trimmed.lastIndex(of: "@") else { return trimmed }
        return String(trimmed[..<at]) + "@" + trimmed[trimmed.index(after: at)...].lowercased()
    }

    static func decodeMailSource(_ row: Row) throws -> AccountMailSource {
        guard let kind = AccountMailSourceKind(rawValue: row["kind"]) else {
            throw AccountMailSourceError.invalidSource
        }
        let rawMode: String? = row["mode"]
        let mode = try rawMode.map { raw -> NodeBackedMode in
            guard let mode = NodeBackedMode(rawValue: raw) else { throw AccountMailSourceError.invalidSource }
            return mode
        }
        return try AccountMailSource(
            accountID: AccountID(row["account_id"] as String),
            kind: kind,
            mode: mode,
            nodeID: row["node_id"],
            logicalMailboxID: row["logical_mailbox_id"],
            providerIdentity: row["provider_identity"],
            generation: row["generation"]
        )
    }
}

public extension SQLiteMailStore {
    /// The send request routed under `operationID`, if any.
    func sendRequestID(deliveryOperationID operationID: String) throws -> SendRequestID? {
        try databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT id FROM send_requests WHERE json_extract(payload_json, '$.deliveryOperationID') = ? LIMIT 1",
                arguments: [operationID]
            ).map { SendRequestID($0) }
        }
    }

    /// Send requests in `status`, by ID (reconciling approved sends routed
    /// through the mail-intent journal).
    func sendRequestIDs(status: SendRequestStatus) throws -> [SendRequestID] {
        try databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT id FROM send_requests WHERE json_extract(payload_json, '$.status') = ? ORDER BY id",
                arguments: [status.rawValue]
            ).map { SendRequestID($0) }
        }
    }
}
