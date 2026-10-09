import CryptoKit
import Foundation
import GRDB
import PlainpostCore

/// The Node-wide delta position of the mirror. `deltaCursor` is the replay
/// start captured once, before the first account snapshot, so changes made
/// while accounts bootstrap are replayed afterwards.
public struct NodeMirrorCursor: Equatable, Sendable {
    public let nodeID: String
    public let deltaCursor: String
    public let revision: String
    /// As of the last pass, every account then in node mode on this Node had
    /// a complete bootstrap. A seed, reset or re-seed clears it; accounts not
    /// in node mode are not counted.
    public let complete: Bool

    public init(nodeID: String, deltaCursor: String, revision: String, complete: Bool) {
        self.nodeID = nodeID
        self.deltaCursor = deltaCursor
        self.revision = revision
        self.complete = complete
    }
}

/// Deferred work an account-level delta asked for. `membership_removed` and
/// `epoch_reset` name no message, so the mirror re-coordinates the account's
/// linked messages: at once after a removal (`audit`), and only after the
/// account's next `baseline_complete` after an epoch reset
/// (`awaitingBaseline`), because until then the new epoch's coordinates are
/// omitted and omission must not remove rows.
public enum NodeMirrorReconcileState: String, Equatable, Sendable, CaseIterable {
    case none
    case audit
    case awaitingBaseline = "awaiting_baseline"
}

/// Per-account bootstrap state, written for one Node binding.
public struct NodeMirrorAccountBootstrap: Equatable, Sendable {
    public let accountID: AccountID
    public let nodeID: String
    public let logicalMailboxID: String
    /// "" before the first committed page.
    public let snapshotCursor: String
    public let complete: Bool
    public let reconcileState: NodeMirrorReconcileState
    /// Advanced by every re-bootstrap over existing links (stale cursor,
    /// rebuilt Node, re-seed). A link the snapshot of this generation lists
    /// carries it.
    public let snapshotGeneration: Int64
    /// After this generation's snapshot completes, linked messages it did not
    /// list were removed on the Node while this Mac was not following it.
    public let sweepPending: Bool
    /// The Node refused a snapshot page (`conflict`: a message that cannot
    /// fit any page). The account's snapshot is retried after this, not on
    /// every pass; the other accounts and the deltas go on.
    public let snapshotRetryAt: Date?
    /// A pass ran while the account was out of node mode, so the shared delta
    /// cursor moved past changes the mirror did not apply to it. It is
    /// re-seeded (full re-snapshot with a sweep) before its next delta apply.
    public let needsReseed: Bool
    /// The account completed a bootstrap under this binding before. A
    /// re-seed or reset reopens the bootstrap but keeps this, so mail that
    /// arrives during a re-bootstrap still notifies; only a new binding
    /// clears it.
    public let everComplete: Bool

    public init(
        accountID: AccountID, nodeID: String, logicalMailboxID: String, snapshotCursor: String,
        complete: Bool, reconcileState: NodeMirrorReconcileState = .none,
        snapshotGeneration: Int64 = 0, sweepPending: Bool = false,
        snapshotRetryAt: Date? = nil, needsReseed: Bool = false, everComplete: Bool = false
    ) {
        self.accountID = accountID
        self.nodeID = nodeID
        self.logicalMailboxID = logicalMailboxID
        self.snapshotCursor = snapshotCursor
        self.complete = complete
        self.reconcileState = reconcileState
        self.snapshotGeneration = snapshotGeneration
        self.sweepPending = sweepPending
        self.snapshotRetryAt = snapshotRetryAt
        self.needsReseed = needsReseed
        self.everComplete = everComplete || complete
    }

    public func updating(
        snapshotCursor: String? = nil, complete: Bool? = nil, reconcileState: NodeMirrorReconcileState? = nil
    ) -> NodeMirrorAccountBootstrap {
        NodeMirrorAccountBootstrap(
            accountID: accountID, nodeID: nodeID, logicalMailboxID: logicalMailboxID,
            snapshotCursor: snapshotCursor ?? self.snapshotCursor, complete: complete ?? self.complete,
            reconcileState: reconcileState ?? self.reconcileState, snapshotGeneration: snapshotGeneration,
            sweepPending: sweepPending, snapshotRetryAt: snapshotRetryAt, needsReseed: needsReseed,
            everComplete: everComplete
        )
    }

    public func retryingSnapshot(at date: Date?) -> NodeMirrorAccountBootstrap {
        NodeMirrorAccountBootstrap(
            accountID: accountID, nodeID: nodeID, logicalMailboxID: logicalMailboxID, snapshotCursor: snapshotCursor,
            complete: complete, reconcileState: reconcileState, snapshotGeneration: snapshotGeneration,
            sweepPending: sweepPending, snapshotRetryAt: date, needsReseed: needsReseed, everComplete: everComplete
        )
    }

    public var scope: NodeMirrorScope {
        NodeMirrorScope(accountID: accountID, nodeID: nodeID, logicalMailboxID: logicalMailboxID)
    }
}

/// The account binding every mirror write is checked against, inside its
/// own transaction: the account must still be Node-backed in `node` mode for
/// exactly this Node and logical mailbox. A Direct account, an account in
/// fallback (direct sync owns its mail then), a rebound account or a removed
/// one refuses with `mirrorScopeChanged`.
public struct NodeMirrorScope: Equatable, Hashable, Sendable {
    public let accountID: AccountID
    public let nodeID: String
    public let logicalMailboxID: String

    public init(accountID: AccountID, nodeID: String, logicalMailboxID: String) {
        self.accountID = accountID
        self.nodeID = nodeID
        self.logicalMailboxID = logicalMailboxID
    }

    /// The scope of a Node-backed source in `node` mode, else nil. The
    /// mirror pauses while an account is in fallback.
    public init?(source: AccountMailSource) {
        guard source.kind == .nodeBacked, source.mode == .node, let nodeID = source.nodeID, let logical = source.logicalMailboxID else { return nil }
        self.init(accountID: source.accountID, nodeID: nodeID, logicalMailboxID: logical)
    }
}

/// One provider coordinate of a mirrored message. `flags` are the Node's
/// lower-case flag names (`answered`, `deleted`, `draft`, `flagged`, `seen`).
public struct MirroredMembership: Equatable, Sendable {
    public let key: StableMessageKey
    public let isSeen: Bool
    public let isDeleted: Bool
    public let flags: [String]

    public init(key: StableMessageKey, flags: [String]) {
        self.key = key
        self.flags = flags.sorted()
        isSeen = flags.contains("seen")
        isDeleted = flags.contains("deleted")
    }

    /// The flags as direct IMAP sync stores them (`\\seen \\flagged`).
    var storedFlags: String {
        flags.map { "\\" + $0 }.sorted().joined(separator: " ")
    }
}

public enum NodeMirrorHydrationState: String, Equatable, Sendable, CaseIterable {
    case pending
    case complete
    case failed
}

public struct NodeMirrorHydrationItem: Equatable, Sendable {
    public let messageID: MessageID
    public let nodeMessageID: String
    public let state: NodeMirrorHydrationState

    public init(messageID: MessageID, nodeMessageID: String, state: NodeMirrorHydrationState) {
        self.messageID = messageID
        self.nodeMessageID = nodeMessageID
        self.state = state
    }
}

// Every API probes only `node-mode-v3-mirror`. While those tables are truly
// absent, reads return nothing (no mirror row can exist) and writes throw
// `schemaUnavailable`. A probe or read error always propagates: it is never
// an authoritative "no cursor" or "nothing pending". No API posts a change
// signal; the mirror posts one per pass.
public extension SQLiteMailStore {
    /// False while the mirror tables are absent or the probe cannot read the database.
    var nodeMirrorAvailable: Bool {
        (try? nodeMirrorStatus()) == .available
    }

    /// Throws `schemaUnavailable` while the mirror tables are truly absent,
    /// and the read error when the probe cannot read the database.
    func requireNodeMirrorSchema() throws {
        try requireNodeMirror()
    }

    func nodeMirrorCursor(nodeID: String) throws -> NodeMirrorCursor? {
        guard try nodeMirrorStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Self.fetchNodeMirrorCursor(database, nodeID: nodeID)
        }
    }

    /// Compare-and-swap on the whole stored cursor: `expected` nil inserts only
    /// when no cursor exists; otherwise the stored cursor must equal `expected`.
    func saveNodeMirrorCursor(_ cursor: NodeMirrorCursor, expected: NodeMirrorCursor?) throws {
        try requireNodeMirror()
        guard cursor.nodeID == cursor.nodeID.lowercased(), !cursor.nodeID.isEmpty,
              expected.map({ $0.nodeID == cursor.nodeID }) ?? true
        else { throw NodeMailModeStoreError.invalidMirrorPayload }
        try databasePool.write { database in
            guard try Self.fetchNodeMirrorCursor(database, nodeID: cursor.nodeID) == expected else {
                throw NodeMailModeStoreError.generationConflict
            }
            try database.execute(
                sql: """
                    INSERT INTO node_mirror_cursors (node_id, delta_cursor, revision, complete, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(node_id) DO UPDATE SET
                        delta_cursor = excluded.delta_cursor, revision = excluded.revision,
                        complete = excluded.complete, updated_at = excluded.updated_at
                    """,
                arguments: [cursor.nodeID, cursor.deltaCursor, cursor.revision, cursor.complete,
                            Date().timeIntervalSince1970]
            )
        }
    }

    func nodeMirrorAccountBootstrap(accountID: AccountID) throws -> NodeMirrorAccountBootstrap? {
        guard try nodeMirrorStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: "SELECT * FROM node_mirror_account_bootstrap WHERE account_id = ?",
                arguments: [accountID.rawValue]
            ).map(Self.decodeBootstrap)
        }
    }

    /// Upsert. A bootstrap row writes no mail, so it may be written before
    /// the flip (handover seeds while the account is still Direct): the
    /// account must exist and must not be Node-backed under another binding.
    func saveNodeMirrorAccountBootstrap(_ bootstrap: NodeMirrorAccountBootstrap) throws {
        try requireNodeMirror()
        try databasePool.write { database in
            try Self.requireBootstrapScope(database, bootstrap.scope)
            try Self.upsertBootstrap(database, bootstrap)
        }
    }

    /// Stale delta cursor or rebuilt Node: drops the Node's cursor and reopens
    /// every bootstrap row written for it under a new snapshot generation,
    /// with a sweep pending. Links stay, so the re-mirror resolves every
    /// message to the row it already has; a pending audit or epoch reset is
    /// kept, never downgraded.
    func resetNodeMirror(nodeID: String) throws {
        try requireNodeMirror()
        try databasePool.write { database in
            try database.execute(sql: "DELETE FROM node_mirror_cursors WHERE node_id = ?", arguments: [nodeID])
            try database.execute(
                sql: """
                    UPDATE node_mirror_account_bootstrap
                    SET snapshot_cursor = '', complete = 0, snapshot_generation = snapshot_generation + 1,
                        sweep_pending = 1, updated_at = ?
                    WHERE node_id = ?
                    """,
                arguments: [Date().timeIntervalSince1970, nodeID]
            )
        }
    }

    /// Handover step, before or after the flip: opens the account's bootstrap
    /// for `scope`. A new row starts fresh; a row for the same binding is
    /// re-bootstrapped under a new generation with a sweep pending (its links
    /// may be stale after a Direct period), keeping any pending audit; a row
    /// for another binding is rebound. Writes no mail.
    func seedNodeMirrorAccount(_ scope: NodeMirrorScope) throws {
        try requireNodeMirror()
        guard scope.nodeID == scope.nodeID.lowercased(), scope.logicalMailboxID.utf8.count == 43 else {
            throw NodeMailModeStoreError.invalidMirrorPayload
        }
        try databasePool.write { database in
            try Self.requireBootstrapScope(database, scope)
            let existing = try Row.fetchOne(
                database, sql: "SELECT * FROM node_mirror_account_bootstrap WHERE account_id = ?",
                arguments: [scope.accountID.rawValue]
            ).map(Self.decodeBootstrap)
            if let existing, existing.scope == scope {
                try database.execute(
                    sql: """
                        UPDATE node_mirror_account_bootstrap
                        SET snapshot_cursor = '', complete = 0, snapshot_generation = snapshot_generation + 1,
                            sweep_pending = 1, needs_reseed = 0, updated_at = ?
                        WHERE account_id = ?
                        """,
                    arguments: [Date().timeIntervalSince1970, scope.accountID.rawValue]
                )
                return
            }
            if existing != nil {
                try database.execute(sql: "DELETE FROM node_mirror_message_links WHERE account_id = ?",
                                     arguments: [scope.accountID.rawValue])
            }
            try Self.upsertBootstrap(database, NodeMirrorAccountBootstrap(
                accountID: scope.accountID, nodeID: scope.nodeID, logicalMailboxID: scope.logicalMailboxID,
                snapshotCursor: "", complete: false
            ))
        }
    }

    /// Every bootstrap row of `nodeID` whose account is not in `mirrored`
    /// (it is Direct or in fallback right now) is flagged for a re-seed: the
    /// pass about to run moves the shared delta cursor past its changes.
    func markNodeMirrorAccountsExcluded(nodeID: String, mirrored: [AccountID]) throws {
        try requireNodeMirror()
        try databasePool.write { database in
            let ids = mirrored.map(\.rawValue)
            let filter = ids.isEmpty ? "" : " AND account_id NOT IN (\(Array(repeating: "?", count: ids.count).joined(separator: ", ")))"
            try database.execute(
                sql: "UPDATE node_mirror_account_bootstrap SET needs_reseed = 1, updated_at = ? WHERE node_id = ? AND needs_reseed = 0" + filter,
                arguments: StatementArguments([Date().timeIntervalSince1970, nodeID] as [DatabaseValueConvertible] + ids)
            )
        }
    }

    /// Links this generation's snapshot listed but the mirror could not
    /// commit (no coordinates right now, a conflict): they still exist on the
    /// Node, so the sweep must keep them.
    func markNodeMirrorLinksListed(accountID: AccountID, nodeMessageIDs: [String]) throws {
        guard !nodeMessageIDs.isEmpty else { return }
        try requireNodeMirror()
        try databasePool.write { database in
            for id in nodeMessageIDs {
                try database.execute(
                    sql: """
                        UPDATE node_mirror_message_links SET snapshot_generation = \(Self.currentGenerationSQL)
                        WHERE account_id = ? AND node_message_id = ?
                        """,
                    arguments: [accountID.rawValue, accountID.rawValue, id]
                )
            }
        }
    }

    /// How many messages the current snapshot of the account listed so far.
    /// A window stops the snapshot once it reaches its size.
    func nodeMirrorListedCount(accountID: AccountID) throws -> Int {
        try requireNodeMirror()
        return try databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM node_mirror_message_links
                    WHERE account_id = ? AND snapshot_generation = \(Self.currentGenerationSQL)
                    """,
                arguments: [accountID.rawValue, accountID.rawValue]
            ) ?? 0
        }
    }

    /// The mirrored messages of the account: how many, and the oldest send
    /// date among them, the floor of a recent-mail window.
    func nodeMirrorWindow(accountID: AccountID) throws -> (count: Int, oldestSentAt: Date?) {
        try requireNodeMirror()
        return try databasePool.read { database in
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) AS count, MIN(message.sent_at) AS oldest
                    FROM node_mirror_message_links AS link
                    JOIN messages AS message ON message.id = link.message_id
                    WHERE link.account_id = ?
                    """,
                arguments: [accountID.rawValue]
            )
            let oldest: Double? = row?["oldest"]
            return (row?["count"] ?? 0, oldest.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// After a completed re-bootstrap: removes the linked messages the fresh
    /// snapshot did not list (they left the Node in the undelivered window)
    /// and clears the sweep. Returns how many were removed.
    @discardableResult
    func sweepUnlistedMirroredMessages(scope: NodeMirrorScope) throws -> Int {
        try requireNodeMirror()
        return try databasePool.write { database in
            try Self.requireMirrorScope(database, scope)
            guard let row = try Row.fetchOne(
                database, sql: "SELECT * FROM node_mirror_account_bootstrap WHERE account_id = ?",
                arguments: [scope.accountID.rawValue]
            ).map(Self.decodeBootstrap), row.scope == scope, row.complete, row.sweepPending,
                row.reconcileState != .awaitingBaseline else { return 0 }
            let stale = try String.fetchAll(
                database,
                sql: """
                    SELECT node_message_id FROM node_mirror_message_links
                    WHERE account_id = ? AND snapshot_generation < ? ORDER BY node_message_id
                    """,
                arguments: [scope.accountID.rawValue, row.snapshotGeneration]
            )
            var removed = 0
            for id in stale where try Self.removeLinked(database, scope: scope, nodeMessageID: id, ownedOnly: true) { removed += 1 }
            try database.execute(
                sql: "UPDATE node_mirror_account_bootstrap SET sweep_pending = 0, updated_at = ? WHERE account_id = ?",
                arguments: [Date().timeIntervalSince1970, scope.accountID.rawValue]
            )
            return removed
        }
    }

    /// An audit could not resolve these IDs (a coordinate conflict can be
    /// permanent): retry them at `at`, not on every pass.
    func scheduleMirrorAuditRetry(accountID: AccountID, nodeMessageIDs: [String], at: Date) throws {
        guard !nodeMessageIDs.isEmpty else { return }
        try requireNodeMirror()
        try databasePool.write { database in
            for id in nodeMessageIDs {
                try database.execute(
                    sql: "UPDATE node_mirror_message_links SET audit_retry_at = ? WHERE account_id = ? AND node_message_id = ?",
                    arguments: [at.timeIntervalSince1970, accountID.rawValue, id]
                )
            }
        }
    }

    /// Audit retries due at `now`, in ID order.
    func dueMirrorAuditRetries(accountID: AccountID, now: Date, limit: Int) throws -> [String] {
        guard limit > 0, try nodeMirrorStatus() == .available else { return [] }
        return try databasePool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT node_message_id FROM node_mirror_message_links
                    WHERE account_id = ? AND audit_retry_at IS NOT NULL AND audit_retry_at <= ?
                    ORDER BY node_message_id LIMIT ?
                    """,
                arguments: [accountID.rawValue, now.timeIntervalSince1970, limit]
            )
        }
    }

    /// The account is mirrored under a new binding (another Node or logical
    /// mailbox): the old Node message IDs mean nothing there, so its links go
    /// and its bootstrap starts again. Local mail stays.
    func rebindNodeMirrorAccount(_ scope: NodeMirrorScope) throws {
        try requireNodeMirror()
        try databasePool.write { database in
            try Self.requireBootstrapScope(database, scope)
            try database.execute(
                sql: "DELETE FROM node_mirror_message_links WHERE account_id = ?",
                arguments: [scope.accountID.rawValue]
            )
            try Self.upsertBootstrap(database, NodeMirrorAccountBootstrap(
                accountID: scope.accountID, nodeID: scope.nodeID, logicalMailboxID: scope.logicalMailboxID,
                snapshotCursor: "", complete: false
            ))
        }
    }

    /// Commits one Node message into `scope`'s account in one transaction:
    /// every membership through the direct-sync commit (INBOX first, so only
    /// an INBOX membership can notify), the membership flags, the Node link,
    /// and the removal of this account's memberships of the local message
    /// that no Node message lists any more. A key already held by another
    /// local message refuses with `messageIdentityMismatch` and nothing is
    /// written. `preserveExistingBodies` keeps a stored body when the Node
    /// page omitted it. A link that is already hydrated stays hydrated.
    func commitMirroredMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        scope: NodeMirrorScope,
        nodeMessageID: String,
        memberships: [MirroredMembership],
        notification: IncomingNotificationDisposition,
        preserveExistingBodies: Bool = false,
        hydration: NodeMirrorHydrationState = .complete,
        nodeAttachmentIDs: [String] = [],
        thread: MailThread? = nil
    ) throws -> IncomingMessageCommitResult {
        try requireNodeMirror()
        try Self.validateMirroredMemberships(memberships, scope: scope, nodeMessageID: nodeMessageID)
        guard hydration != .failed else { throw NodeMailModeStoreError.invalidMirrorPayload }
        let result = try databasePool.write { database -> (IncomingMessageCommitResult, Bool) in
            try Self.requireMirrorScope(database, scope)
            try Self.requireOwnedKeys(database, memberships, messageID: message.id)
            if let linked = try Self.linkedMessageID(database, accountID: scope.accountID, nodeMessageID: nodeMessageID),
               linked != message.id {
                throw NodeMailModeStoreError.messageIdentityMismatch
            }
            if let thread {
                guard thread.accountID == scope.accountID else { throw NodeMailModeStoreError.invalidMirrorPayload }
                try Self.writeThread(database, thread)
            }
            var summary = message
            if preserveExistingBodies, let stored = try Row.fetchOne(
                database,
                sql: "SELECT preview, body_text, body_html FROM messages WHERE id = ?",
                arguments: [message.id.rawValue]
            ) {
                summary = Self.replacingBodies(of: message, preview: stored["preview"], body: stored["body_text"],
                                               bodyHTML: stored["body_html"])
            }
            try Self.ensureMirroredMailboxes(database, accountID: scope.accountID, paths: memberships.map(\.key.mailboxPath))
            var insertedMembership = false
            var insertedCanonical = false
            var notified = false
            for (index, membership) in Self.inboxFirst(memberships).enumerated() {
                let written = try writeIncomingMessage(
                    summary, metadata: metadata, persistedAttachments: nil, accountID: scope.accountID,
                    mailboxPath: membership.key.mailboxPath, uidValidity: membership.key.uidValidity,
                    uid: membership.key.uid, notificationEligible: notification.isEligible,
                    notificationDisposition: notification, database: database
                )
                if index == 0 { insertedCanonical = written.insertedCanonicalMessage }
                insertedMembership = insertedMembership || written.insertedMembership
                notified = notified || written.insertedMacNotificationEvent
            }
            try database.execute(
                sql: """
                    INSERT INTO node_mirror_message_links (
                        account_id, node_message_id, message_id, hydration_state, snapshot_generation
                    ) VALUES (?, ?, ?, ?, \(Self.currentGenerationSQL))
                    ON CONFLICT(account_id, node_message_id) DO UPDATE SET
                        message_id = excluded.message_id,
                        snapshot_generation = excluded.snapshot_generation,
                        audit_retry_at = NULL,
                        hydration_state = CASE
                            WHEN node_mirror_message_links.hydration_state = 'complete' THEN 'complete'
                            WHEN node_mirror_message_links.hydration_state = 'failed'
                                AND excluded.hydration_state != 'complete' THEN 'failed'
                            ELSE excluded.hydration_state END
                    """,
                arguments: [scope.accountID.rawValue, nodeMessageID, message.id.rawValue, hydration.rawValue,
                            scope.accountID.rawValue]
            )
            try Self.applyMemberships(database, scope: scope, nodeMessageID: nodeMessageID, messageID: message.id,
                                      memberships: memberships, insertMissing: false)
            try database.execute(sql: "DELETE FROM node_mirror_attachment_links WHERE message_id = ?", arguments: [message.id.rawValue])
            for (ordinal, attachmentID) in nodeAttachmentIDs.enumerated() {
                try database.execute(
                    sql: "INSERT INTO node_mirror_attachment_links (message_id, ordinal, node_attachment_id) VALUES (?, ?, ?)",
                    arguments: [message.id.rawValue, ordinal, attachmentID]
                )
            }
            return (IncomingMessageCommitResult(messageID: message.id, insertedMembership: insertedMembership,
                                                insertedCanonicalMessage: insertedCanonical), notified)
        }
        if result.1 { MailStoreChangeSignal.post(scope: .operations) }
        return result.0
    }

    /// Re-coordination without content: sets the linked message's memberships
    /// in this account to exactly `memberships` (plus those other Node
    /// messages own). Returns false when the Node message is not linked.
    @discardableResult
    func syncMirroredMemberships(
        scope: NodeMirrorScope, nodeMessageID: String, memberships: [MirroredMembership]
    ) throws -> Bool {
        try requireNodeMirror()
        try Self.validateMirroredMemberships(memberships, scope: scope, nodeMessageID: nodeMessageID)
        return try databasePool.write { database in
            try Self.requireMirrorScope(database, scope)
            guard let messageID = try Self.linkedMessageID(database, accountID: scope.accountID, nodeMessageID: nodeMessageID) else {
                return false
            }
            try Self.requireOwnedKeys(database, memberships, messageID: messageID)
            try Self.ensureMirroredMailboxes(database, accountID: scope.accountID, paths: memberships.map(\.key.mailboxPath))
            try Self.applyMemberships(database, scope: scope, nodeMessageID: nodeMessageID, messageID: messageID,
                                      memberships: memberships, insertMissing: true)
            try database.execute(
                sql: "UPDATE node_mirror_message_links SET audit_retry_at = NULL WHERE account_id = ? AND node_message_id = ?",
                arguments: [scope.accountID.rawValue, nodeMessageID]
            )
            return true
        }
    }

    /// Removes folder rows an earlier build seeded from the Node catalog's mailbox handles,
    /// which are opaque and never match a mirrored message's folder path.
    func removeLegacyNodeHandleMailboxes() throws {
        try databasePool.write { database in
            try database.execute(sql: """
                DELETE FROM mailboxes
                WHERE id LIKE 'mbx\\_%\\_node\\_%' ESCAPE '\\'
                  AND account_id IN (SELECT account_id FROM account_mail_sources WHERE kind = 'node_backed')
                """)
        }
    }

    /// Each provider folder a mirrored message is in becomes one of the account's folders,
    /// as Direct sync lists them, so a Sync Node account's Mailboxes section shows it and a
    /// Move can name it. A folder the account already has stays as it is.
    static func ensureMirroredMailboxes(_ database: Database, accountID: AccountID, paths: [String]) throws {
        for path in Set(paths) {
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM mailboxes WHERE account_id = ? AND path = ?)",
                arguments: [accountID.rawValue, path]
            ) ?? false
            guard !exists else { continue }
            let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            try database.execute(
                sql: "INSERT INTO mailboxes (id, account_id, name, path, special_use) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    "mbx_\(accountID.rawValue)_mirror_\(digest)", accountID.rawValue,
                    path.split(separator: "/").last.map(String.init) ?? path, path, mirroredSpecialUse(path: path),
                ]
            )
        }
    }

    /// The special use of a provider folder known by its name alone: Gmail's system folders
    /// and the generic names the Node itself recognizes.
    static func mirroredSpecialUse(path: String) -> String? {
        switch path.lowercased() {
        case "inbox": "\\Inbox"
        case "[gmail]/sent mail", "[google mail]/sent mail", "sent", "sent messages", "sent items": "\\Sent"
        case "[gmail]/drafts", "[google mail]/drafts", "drafts": "\\Drafts"
        case "[gmail]/trash", "[google mail]/trash", "[gmail]/bin", "trash", "deleted", "deleted messages", "deleted items": "\\Trash"
        case "[gmail]/spam", "[google mail]/spam", "junk", "spam": "\\Junk"
        case "[gmail]/all mail", "[google mail]/all mail", "all": "\\All"
        case "archive": "\\Archive"
        default: nil
        }
    }

    func messageID(forNodeMessageID nodeMessageID: String, accountID: AccountID) throws -> MessageID? {
        guard try nodeMirrorStatus() == .available else { return nil }
        return try databasePool.read { database in
            try Self.linkedMessageID(database, accountID: accountID, nodeMessageID: nodeMessageID)
        }
    }

    /// The Node message a local message is linked to (the lowest when two
    /// Node messages share one RFC Message-ID).
    func nodeMessageID(for messageID: MessageID) throws -> String? {
        guard try nodeMirrorStatus() == .available else { return nil }
        return try databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT MIN(node_message_id) FROM node_mirror_message_links WHERE message_id = ?",
                arguments: [messageID.rawValue]
            )
        }
    }

    /// The account's linked Node message IDs after `after`, in byte order.
    func mirroredNodeMessageIDs(accountID: AccountID, after: String, limit: Int) throws -> [String] {
        guard limit > 0, try nodeMirrorStatus() == .available else { return [] }
        return try databasePool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT node_message_id FROM node_mirror_message_links
                    WHERE account_id = ? AND node_message_id > ?
                    ORDER BY node_message_id LIMIT ?
                    """,
                arguments: [accountID.rawValue, after, limit]
            )
        }
    }

    /// Tombstone, or a removal that left the Node message no membership in
    /// this account: removes its memberships (keeping those other Node
    /// messages own) and its link. Like direct sync, a message left with no
    /// membership is marked deleted, not erased. Returns false when unlinked.
    @discardableResult
    func removeMirroredMessage(nodeMessageID: String, scope: NodeMirrorScope) throws -> Bool {
        try requireNodeMirror()
        return try databasePool.write { database in
            try Self.requireMirrorScope(database, scope)
            return try Self.removeLinked(database, scope: scope, nodeMessageID: nodeMessageID)
        }
    }

    /// Links waiting for bodies or attachments: pending ones, then failed
    /// ones whose backoff has passed at `now`.
    func pendingMirrorHydration(accountID: AccountID, limit: Int, now: Date = Date()) throws -> [NodeMirrorHydrationItem] {
        guard limit > 0, try nodeMirrorStatus() == .available else { return [] }
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT message_id, node_message_id, hydration_state FROM node_mirror_message_links
                    WHERE account_id = ? AND (hydration_state = 'pending'
                        OR (hydration_state = 'failed' AND (hydration_next_at IS NULL OR hydration_next_at <= ?)))
                    ORDER BY hydration_state = 'failed', node_message_id LIMIT ?
                    """,
                arguments: [accountID.rawValue, now.timeIntervalSince1970, limit]
            ).map { row in
                guard let state = NodeMirrorHydrationState(rawValue: row["hydration_state"]) else {
                    throw NodeMailModeStoreError.invalidMirrorPayload
                }
                return NodeMirrorHydrationItem(messageID: MessageID(row["message_id"] as String),
                                               nodeMessageID: row["node_message_id"], state: state)
            }
        }
    }

    /// Stores hydrated bodies (nil keeps the stored one) and attachment
    /// payloads (at most 256, 50 MiB each and 100 MiB together) and marks
    /// the message hydrated.
    func completeMirrorHydration(
        messageID: MessageID, scope: NodeMirrorScope, textBody: String?, htmlBody: String?,
        attachments: [IncomingMessageAttachmentPayload]
    ) throws {
        try requireNodeMirror()
        guard Self.validHydrationAttachments(attachments) else { throw NodeMailModeStoreError.invalidMirrorPayload }
        try databasePool.write { database in
            try Self.requireMirrorScope(database, scope)
            try Self.requireLinked(database, scope: scope, messageID: messageID)
            if let textBody {
                try database.execute(
                    sql: "UPDATE messages SET body_text = ?, preview = ? WHERE id = ?",
                    arguments: [textBody, Self.preview(textBody), messageID.rawValue]
                )
            }
            if let htmlBody {
                try database.execute(sql: "UPDATE messages SET body_html = ? WHERE id = ?",
                                     arguments: [htmlBody.isEmpty ? nil : htmlBody, messageID.rawValue])
            }
            try database.execute(sql: "DELETE FROM incoming_message_attachments WHERE message_id = ?", arguments: [messageID.rawValue])
            for (ordinal, attachment) in attachments.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO incoming_message_attachments (
                            message_id, part_path, ordinal, filename, mime_type, byte_count, sha256, payload, content_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [messageID.rawValue, attachment.partPath, ordinal, attachment.filename,
                                attachment.mimeType, attachment.byteCount, attachment.sha256, attachment.data,
                                attachment.contentID]
                )
            }
            try database.execute(
                sql: """
                    UPDATE node_mirror_message_links SET hydration_state = 'complete'
                    WHERE account_id = ? AND message_id = ?
                    """,
                arguments: [scope.accountID.rawValue, messageID.rawValue]
            )
            try SQLiteMailSearchProjectionWriter.refresh(messageID: messageID, database: database)
        }
    }

    /// A hydration attempt failed: retry after `60 s · 2^attempts` (capped at
    /// one day) times `jitter`, so a failing message is not re-downloaded on
    /// every pass.
    func failMirrorHydration(messageID: MessageID, scope: NodeMirrorScope, now: Date = Date(), jitter: Double = 1) throws {
        try requireNodeMirror()
        try databasePool.write { database in
            try Self.requireMirrorScope(database, scope)
            try Self.requireLinked(database, scope: scope, messageID: messageID)
            let attempts = try Int.fetchOne(
                database,
                sql: "SELECT MAX(hydration_attempts) FROM node_mirror_message_links WHERE account_id = ? AND message_id = ?",
                arguments: [scope.accountID.rawValue, messageID.rawValue]
            ) ?? 0
            let delay = min(60.0 * pow(2.0, Double(min(attempts, 20))), 86_400.0) * min(max(jitter, 0.5), 1.0)
            try database.execute(
                sql: """
                    UPDATE node_mirror_message_links
                    SET hydration_state = 'failed', hydration_attempts = hydration_attempts + 1, hydration_next_at = ?
                    WHERE account_id = ? AND message_id = ? AND hydration_state != 'complete'
                    """,
                arguments: [now.timeIntervalSince1970 + delay, scope.accountID.rawValue, messageID.rawValue]
            )
        }
    }
}

extension SQLiteMailStore {
    /// Throws when the probe cannot read the database; callers fail closed.
    func nodeMirrorStatus() throws -> NodeModeSchemaStatus {
        try nodeModeSchemaStatus(migration: Self.nodeModeMirrorMigration)
    }
}

private extension SQLiteMailStore {
    static let maximumMirroredMemberships = 200

    func requireNodeMirror() throws {
        guard try nodeMirrorStatus() == .available else { throw NodeMailModeStoreError.schemaUnavailable }
    }

    static func fetchNodeMirrorCursor(_ database: Database, nodeID: String) throws -> NodeMirrorCursor? {
        try Row.fetchOne(
            database,
            sql: "SELECT node_id, delta_cursor, revision, complete FROM node_mirror_cursors WHERE node_id = ?",
            arguments: [nodeID]
        ).map { row in
            NodeMirrorCursor(nodeID: row["node_id"], deltaCursor: row["delta_cursor"], revision: row["revision"],
                             complete: row["complete"])
        }
    }

    static func decodeBootstrap(_ row: Row) throws -> NodeMirrorAccountBootstrap {
        guard let state = NodeMirrorReconcileState(rawValue: row["reconcile_state"]) else {
            throw NodeMailModeStoreError.invalidMirrorPayload
        }
        return NodeMirrorAccountBootstrap(
            accountID: AccountID(row["account_id"] as String), nodeID: row["node_id"],
            logicalMailboxID: row["logical_mailbox_id"], snapshotCursor: row["snapshot_cursor"],
            complete: row["complete"], reconcileState: state,
            snapshotGeneration: row["snapshot_generation"], sweepPending: row["sweep_pending"],
            snapshotRetryAt: (row["snapshot_retry_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
            needsReseed: row["needs_reseed"], everComplete: row["ever_complete"]
        )
    }

    static func upsertBootstrap(_ database: Database, _ bootstrap: NodeMirrorAccountBootstrap) throws {
        try database.execute(
            sql: """
                INSERT INTO node_mirror_account_bootstrap (
                    account_id, node_id, logical_mailbox_id, snapshot_cursor, complete, reconcile_state,
                    snapshot_generation, sweep_pending, snapshot_retry_at, needs_reseed, ever_complete, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    node_id = excluded.node_id, logical_mailbox_id = excluded.logical_mailbox_id,
                    snapshot_cursor = excluded.snapshot_cursor, complete = excluded.complete,
                    reconcile_state = excluded.reconcile_state, snapshot_generation = excluded.snapshot_generation,
                    sweep_pending = excluded.sweep_pending, snapshot_retry_at = excluded.snapshot_retry_at,
                    needs_reseed = excluded.needs_reseed, ever_complete = excluded.ever_complete,
                    updated_at = excluded.updated_at
                """,
            arguments: [bootstrap.accountID.rawValue, bootstrap.nodeID, bootstrap.logicalMailboxID,
                        bootstrap.snapshotCursor, bootstrap.complete, bootstrap.reconcileState.rawValue,
                        bootstrap.snapshotGeneration, bootstrap.sweepPending,
                        bootstrap.snapshotRetryAt?.timeIntervalSince1970, bootstrap.needsReseed,
                        bootstrap.everComplete, Date().timeIntervalSince1970]
        )
    }

    /// SQL for the account's current snapshot generation (binds the account ID).
    static let currentGenerationSQL =
        "COALESCE((SELECT snapshot_generation FROM node_mirror_account_bootstrap WHERE account_id = ?), 0)"

    /// Bookkeeping guard: the account exists and is not Node-backed under
    /// another binding. Direct and fallback accounts pass; no mail is written.
    static func requireBootstrapScope(_ database: Database, _ scope: NodeMirrorScope) throws {
        let exists = try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
                                       arguments: [scope.accountID.rawValue]) ?? false
        guard exists else { throw NodeMailModeStoreError.mirrorScopeChanged }
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, node_id, logical_mailbox_id FROM account_mail_sources WHERE account_id = ?",
            arguments: [scope.accountID.rawValue]
        ), (row["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue,
           (row["node_id"] as String?) != scope.nodeID || (row["logical_mailbox_id"] as String?) != scope.logicalMailboxID {
            throw NodeMailModeStoreError.mirrorScopeChanged
        }
    }

    /// The mail-writing guard, read inside the writing transaction: Node-backed
    /// in `node` mode for exactly this binding.
    static func requireMirrorScope(_ database: Database, _ scope: NodeMirrorScope) throws {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, mode, node_id, logical_mailbox_id FROM account_mail_sources WHERE account_id = ?",
            arguments: [scope.accountID.rawValue]
        ),
            (row["kind"] as String) == AccountMailSourceKind.nodeBacked.rawValue,
            (row["mode"] as String?) == NodeBackedMode.node.rawValue,
            (row["node_id"] as String?) == scope.nodeID,
            (row["logical_mailbox_id"] as String?) == scope.logicalMailboxID
        else { throw NodeMailModeStoreError.mirrorScopeChanged }
    }

    static func validateMirroredMemberships(
        _ memberships: [MirroredMembership], scope: NodeMirrorScope, nodeMessageID: String
    ) throws {
        let keys = memberships.map(\.key)
        guard !nodeMessageID.isEmpty, !memberships.isEmpty, memberships.count <= maximumMirroredMemberships,
              keys.allSatisfy({ $0.accountID == scope.accountID && !$0.mailboxPath.isEmpty && $0.uidValidity > 0 && $0.uid > 0 }),
              Set(keys).count == keys.count
        else { throw NodeMailModeStoreError.invalidMirrorPayload }
    }

    /// Never overwrites: every key must be free or already this message's.
    static func requireOwnedKeys(_ database: Database, _ memberships: [MirroredMembership], messageID: MessageID) throws {
        for membership in memberships {
            let key = membership.key
            if let owner = try String.fetchOne(
                database,
                sql: """
                    SELECT message_id FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                    """,
                arguments: [key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid]
            ), owner != messageID.rawValue {
                throw NodeMailModeStoreError.messageIdentityMismatch
            }
        }
    }

    static func linkedMessageID(_ database: Database, accountID: AccountID, nodeMessageID: String) throws -> MessageID? {
        try String.fetchOne(
            database,
            sql: "SELECT message_id FROM node_mirror_message_links WHERE account_id = ? AND node_message_id = ?",
            arguments: [accountID.rawValue, nodeMessageID]
        ).map { MessageID($0) }
    }

    static func requireLinked(_ database: Database, scope: NodeMirrorScope, messageID: MessageID) throws {
        let linked = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM node_mirror_message_links WHERE account_id = ? AND message_id = ?)",
            arguments: [scope.accountID.rawValue, messageID.rawValue]
        ) ?? false
        guard linked else { throw NodeMailModeStoreError.mirrorScopeChanged }
    }

    /// Sets this Node message's memberships of `messageID` in the account to
    /// exactly `memberships`, records their ownership, and updates flags and
    /// the message's seen and deleted state (a pending local seen intent wins,
    /// as in direct sync).
    static func applyMemberships(
        _ database: Database, scope: NodeMirrorScope, nodeMessageID: String, messageID: MessageID,
        memberships: [MirroredMembership], insertMissing: Bool
    ) throws {
        try removeUnownedMemberships(database, scope: scope, nodeMessageID: nodeMessageID, messageID: messageID,
                                     keeping: Set(memberships.map(\.key)))
        for membership in memberships {
            let key = membership.key
            if insertMissing {
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid, messageID.rawValue]
                )
            }
            try database.execute(
                sql: """
                    UPDATE mailbox_messages SET flags = ?
                    WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                    """,
                arguments: [membership.storedFlags, key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid]
            )
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO node_mirror_membership_links (
                        account_id, node_message_id, mailbox_path, uid_validity, uid
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [key.accountID.rawValue, nodeMessageID, key.mailboxPath, key.uidValidity, key.uid]
            )
        }
        let preferred = inboxFirst(memberships)[0]
        try database.execute(
            sql: """
                UPDATE messages SET
                    is_seen = COALESCE((SELECT desired_seen FROM message_seen_intents WHERE message_id = ?), ?),
                    is_deleted = ?
                WHERE id = ?
                """,
            arguments: [messageID.rawValue, preferred.isSeen, preferred.isDeleted, messageID.rawValue]
        )
        try database.execute(
            sql: "DELETE FROM message_seen_intents WHERE message_id = ? AND desired_seen = ?",
            arguments: [messageID.rawValue, preferred.isSeen]
        )
        try SQLiteMailSearchProjectionWriter.refresh(messageID: messageID, database: database)
    }

    /// Removes the account's memberships of `messageID` that are not in
    /// `keeping` and that no other Node message owns.
    static func removeUnownedMemberships(
        _ database: Database, scope: NodeMirrorScope, nodeMessageID: String, messageID: MessageID,
        keeping: Set<StableMessageKey>
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT mm.mailbox_path, mm.uid_validity, mm.uid, link.node_message_id AS owner
                FROM mailbox_messages mm
                LEFT JOIN node_mirror_membership_links link
                    ON link.account_id = mm.account_id AND link.mailbox_path = mm.mailbox_path
                    AND link.uid_validity = mm.uid_validity AND link.uid = mm.uid
                WHERE mm.account_id = ? AND mm.message_id = ?
                """,
            arguments: [scope.accountID.rawValue, messageID.rawValue]
        )
        for row in rows {
            let key = StableMessageKey(accountID: scope.accountID, mailboxPath: row["mailbox_path"],
                                       uidValidity: row["uid_validity"], uid: row["uid"])
            let owner: String? = row["owner"]
            guard !keeping.contains(key) else { continue }
            if let owner, owner != nodeMessageID,
               try linkedMessageID(database, accountID: scope.accountID, nodeMessageID: owner) == messageID {
                continue
            }
            try database.execute(
                sql: """
                    DELETE FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                    """,
                arguments: [key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid]
            )
            try database.execute(
                sql: """
                    DELETE FROM node_mirror_membership_links
                    WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                    """,
                arguments: [key.accountID.rawValue, key.mailboxPath, key.uidValidity, key.uid]
            )
        }
    }

    /// `ownedOnly` (the sweep) removes the memberships this link owns and,
    /// while another link to the message remains, leaves unowned ones (for
    /// example added by direct sync during fallback) alone; with no link left
    /// it removes them too. A tombstone removes every membership no other
    /// link owns.
    static func removeLinked(
        _ database: Database, scope: NodeMirrorScope, nodeMessageID: String, ownedOnly: Bool = false
    ) throws -> Bool {
        guard let messageID = try linkedMessageID(database, accountID: scope.accountID, nodeMessageID: nodeMessageID) else {
            return false
        }
        if ownedOnly {
            try database.execute(
                sql: """
                    DELETE FROM mailbox_messages
                    WHERE message_id = ? AND EXISTS (
                        SELECT 1 FROM node_mirror_membership_links link
                        WHERE link.account_id = mailbox_messages.account_id AND link.node_message_id = ?
                          AND link.mailbox_path = mailbox_messages.mailbox_path
                          AND link.uid_validity = mailbox_messages.uid_validity AND link.uid = mailbox_messages.uid
                          AND link.account_id = ?)
                    """,
                arguments: [messageID.rawValue, nodeMessageID, scope.accountID.rawValue]
            )
            // With no other Node message left for this local message, nothing
            // on the Node vouches for its unowned memberships either (a direct
            // archive the server deleted before direct sync polled again):
            // remove them all, as a tombstone would.
            let successorLinked = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM node_mirror_message_links
                    WHERE account_id = ? AND message_id = ? AND node_message_id != ?)
                    """,
                arguments: [scope.accountID.rawValue, messageID.rawValue, nodeMessageID]
            ) ?? false
            if !successorLinked {
                try removeUnownedMemberships(database, scope: scope, nodeMessageID: nodeMessageID, messageID: messageID, keeping: [])
            }
        } else {
            try removeUnownedMemberships(database, scope: scope, nodeMessageID: nodeMessageID, messageID: messageID, keeping: [])
        }
        try database.execute(
            sql: "DELETE FROM node_mirror_message_links WHERE account_id = ? AND node_message_id = ?",
            arguments: [scope.accountID.rawValue, nodeMessageID]
        )
        try markDeletedWithoutMemberships(database, messageID: messageID)
        try SQLiteMailSearchProjectionWriter.refresh(messageID: messageID, database: database)
        return true
    }

    /// `cacheThreads`, inside the caller's transaction.
    static func writeThread(_ database: Database, _ thread: MailThread) throws {
        try database.execute(
            sql: """
                INSERT OR REPLACE INTO threads (id, account_id, subject_normalized, participant_emails)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [thread.id.rawValue, thread.accountID.rawValue, thread.subjectNormalized,
                        thread.participantEmails.map(\.rawValue).joined(separator: "\n")]
        )
        for messageID in try String.fetchAll(database, sql: "SELECT id FROM messages WHERE thread_id = ? ORDER BY id",
                                             arguments: [thread.id.rawValue]) {
            try SQLiteMailSearchProjectionWriter.refresh(messageID: MessageID(messageID), database: database)
        }
    }

    static func markDeletedWithoutMemberships(_ database: Database, messageID: MessageID) throws {
        try database.execute(
            sql: """
                UPDATE messages SET is_deleted = 1 WHERE id = ?
                AND NOT EXISTS (SELECT 1 FROM mailbox_messages WHERE message_id = ?)
                """,
            arguments: [messageID.rawValue, messageID.rawValue]
        )
    }

    /// INBOX (any case) first, then by path, UIDVALIDITY and UID bytes.
    static func inboxFirst(_ memberships: [MirroredMembership]) -> [MirroredMembership] {
        memberships.sorted { left, right in
            let leftInbox = left.key.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            let rightInbox = right.key.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            if leftInbox != rightInbox { return leftInbox }
            if left.key.mailboxPath != right.key.mailboxPath {
                return Array(left.key.mailboxPath.utf8).lexicographicallyPrecedes(Array(right.key.mailboxPath.utf8))
            }
            if left.key.uidValidity != right.key.uidValidity { return left.key.uidValidity < right.key.uidValidity }
            return left.key.uid < right.key.uid
        }
    }

    static func replacingBodies(of message: MessageSummary, preview: String, body: String, bodyHTML: String?) -> MessageSummary {
        MessageSummary(
            id: message.id, threadID: message.threadID, from: message.from, fromDisplayName: message.fromDisplayName,
            subject: message.subject, preview: preview, smartCategory: message.smartCategory, labels: message.labels,
            isSeen: message.isSeen, mailboxPath: message.mailboxPath, isDeleted: message.isDeleted, body: body,
            bodyHTML: bodyHTML, sentAt: message.sentAt, rfcMessageID: message.rfcMessageID, inReplyTo: message.inReplyTo,
            references: message.references, replyTo: message.replyTo, to: message.to, cc: message.cc,
            attachments: message.attachments
        )
    }

    static func preview(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
            .description
    }

    static func validHydrationAttachments(_ attachments: [IncomingMessageAttachmentPayload]) -> Bool {
        guard attachments.count <= IncomingMessageAttachmentPayload.maximumAttachmentCount,
              Set(attachments.map(\.partPath)).count == attachments.count else { return false }
        var total = 0
        for attachment in attachments {
            let segments = attachment.partPath.split(separator: ".", omittingEmptySubsequences: false)
            guard !segments.isEmpty,
                  segments.allSatisfy({ segment in Int(segment).map { $0 > 0 && String($0) == segment } ?? false }),
                  !attachment.filename.isEmpty,
                  attachment.byteCount == attachment.data.count,
                  attachment.byteCount <= IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment
            else { return false }
            total += attachment.byteCount
            guard total <= IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes else { return false }
        }
        return true
    }
}
