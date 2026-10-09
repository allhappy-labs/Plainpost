import CryptoKit
import Foundation
import GRDB
import PlainpostCore
import PlainpostOperations
import PlainpostSecrets

public enum ConfirmedMailboxActionConflict: Error, Equatable, Sendable, LocalizedError {
    case sourceChanged
    case membershipChanged

    public var errorDescription: String? {
        "The provider confirmed this action, but local account or mailbox state changed. Sync to reconcile before acting again."
    }
}

public enum ConfirmedMailboxCacheAction: Sendable {
    /// An archive (a move to `to`). Like `.trash`, the copy is keyed by the
    /// provider's new UID from COPYUID, or by a local key when that is unknown;
    /// it never keeps the source UID, which can name another message there.
    case archive(to: String, uidValidity: Int?, uid: Int?)
    /// Delete as a move to Trash. `uidValidity` and `uid` are the provider's
    /// key for the message in Trash (from COPYUID); without them the row gets
    /// a local key no server mailbox matches, so nothing can act on it under
    /// its old Inbox UID before a sync.
    case trash(to: String, uidValidity: Int?, uid: Int?)
    case delete
    /// The provider set (true) or cleared (false) \\Flagged on the copy.
    case flag(Bool)
}

public enum ConfirmedMailboxSourceSnapshot: Sendable {
    case direct(generation: Int64)
    case implicitDirect
}

public struct AccountDeletionCleanupPendingError: Error, Sendable, CustomStringConvertible
{
    public let accountID: AccountID
    public let operationError: any Error

    init(accountID: AccountID, operationError: Error) {
        self.accountID = accountID
        self.operationError = operationError
    }

    public var operationDescription: String {
        String(describing: operationError)
    }

    public var description: String {
        "Account \(accountID.rawValue) was deleted; audit cleanup remains pending: \(operationDescription)"
    }
}

public struct AccountDeletionCompensationError: Error, Sendable, CustomStringConvertible
{
    public let operationError: any Error
    public let compensationError: any Error

    init(operationError: Error, compensationError: Error) {
        self.operationError = operationError
        self.compensationError = compensationError
    }

    public var operationDescription: String {
        String(describing: operationError)
    }

    public var compensationDescription: String {
        String(describing: compensationError)
    }

    public var description: String {
        "Account deletion failed: \(operationDescription); credential restoration also failed: \(compensationDescription)"
    }
}

enum AccountDeletionFailpoint: Equatable, Sendable {
    case afterCredentialRemovalBeforeSQLiteCommit
}

public struct SmartInboxClassificationCacheRecord: Equatable, Sendable {
    public let messageID: MessageID
    public let sourceFingerprint: String
    public let category: SmartCategory
    public let priority: SmartPriority
    public let requiresAction: Bool
    public let confidence: Double?
    public let labelMatches: [SmartInboxLabelMatch]
    public let catalogFingerprint: String
    public let providerID: String
    public let modelID: String?
    public let classifiedAt: Date
}

private struct SmartInboxCatalogFingerprintEntry: Codable {
    let id: String
    let scope: String
    let title: String
    let description: String
    let isSmartInboxEnabled: Bool
}

private struct SmartInboxReconciliationAuditResult: Codable {
    let category: String
    let addedLabelIDs: [String]
    let modelID: String?
    let providerID: String
    let removedLabelIDs: [String]
}

private struct MailLabelDefinitionAuditResult: Codable {
    let isSmartInboxEnabled: Bool
    let labelID: String
    let scope: String
    let title: String
}

private struct MailLabelRenameAuditResult: Codable {
    let labelID: String
    let newTitle: String
    let oldTitle: String
    let scope: String
}

private struct MailLabelEligibilityAuditResult: Codable {
    let isSmartInboxEnabled: Bool
    let labelID: String
    let scope: String
}

private struct MailLabelAssignmentAuditResult: Codable {
    let addedLabelIDs: [String]
    let removedLabelIDs: [String]
    let ruleID: String?
    let source: String
}

private struct MailLabelExclusionAuditResult: Codable {
    let labelID: String
    let source: String
}

private struct MailLabelRuleDiagnosticAuditResult: Codable {
    let errorClass: String
    let labelID: String
    let ruleID: String
    let source: String
}

private struct MailLabelDeletionAuditResult: Codable {
    let affectedMessageCount: Int
    let affectedRuleCount: Int
    let exclusionCount: Int
    let labelID: String
    let ruleAssignmentCount: Int
    let scope: String
    let smartInboxAssignmentCount: Int
    let title: String
    let userAssignmentCount: Int
}

private struct SmartInboxReclassificationStartAuditResult: Codable {
    let jobID: String
    let messageCount: Int
    let modelID: String?
    let providerID: String
    let requestedLabelID: String?
    let scope: String
}

private struct SmartInboxReclassificationCompletionAuditResult: Codable {
    let errorClass: String?
    let failed: Int
    let jobID: String
    let modelID: String?
    let providerID: String
    let requestedLabelID: String?
    let scope: String
    let status: String
    let unchanged: Int
    let updated: Int
}

public enum PlainpostSmartInboxJobEnqueueResult: Sendable {
    case upToDate
    case job(PlainpostDurableJob)
}

public struct PlainpostSyncExecutionScope: Equatable, Sendable {
    public let mailboxPaths: [String]
    public let recentMessageLimit: Int
    public let downloadCompleteHistory: Bool
    public let incrementalOnly: Bool
}

public enum DraftOptimisticUpdateError: Error, Equatable, Sendable {
    case conflict
}

public struct SQLiteIncomingAttachmentMetadata: Equatable, Sendable {
    public let partPath: String
    public let filename: String
    public let mimeType: String?
    public let byteCount: Int
    public let sha256: String

    public init(
        partPath: String,
        filename: String,
        mimeType: String?,
        byteCount: Int,
        sha256: String
    ) {
        self.partPath = partPath
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SQLiteIncomingAttachmentChunk: Equatable, Sendable {
    public let metadata: SQLiteIncomingAttachmentMetadata
    public let offset: Int
    public let data: Data

    public init(
        metadata: SQLiteIncomingAttachmentMetadata,
        offset: Int,
        data: Data
    ) {
        self.metadata = metadata
        self.offset = offset
        self.data = data
    }
}

public struct BackgroundJobRecoverySummary: Equatable, Sendable {
    public let requeuedExpiredCount: Int
    public let cancelledDuplicateCount: Int
    public let cancelledExpiredCount: Int

    public init(
        requeuedExpiredCount: Int,
        cancelledDuplicateCount: Int,
        cancelledExpiredCount: Int = 0
    ) {
        self.requeuedExpiredCount = requeuedExpiredCount
        self.cancelledDuplicateCount = cancelledDuplicateCount
        self.cancelledExpiredCount = cancelledExpiredCount
    }
}

private struct AccountDeletionPermitKey: Hashable, Sendable {
    let databaseIdentity: String
    let accountID: String
}

private actor AccountDeletionCoordinator {
    private var activeKeys: Set<AccountDeletionPermitKey> = []
    private var waiters: [AccountDeletionPermitKey: [CheckedContinuation<Void, Never>]] = [:]

    func withPermit<T: Sendable>(
        for key: AccountDeletionPermitKey,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(for: key)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(for: key)
            return result
        } catch {
            release(for: key)
            throw error
        }
    }

    private func acquire(for key: AccountDeletionPermitKey) async {
        if activeKeys.insert(key).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(for key: AccountDeletionPermitKey) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters.removeValue(forKey: key)
            activeKeys.remove(key)
            return
        }
        let next = queued.removeFirst()
        if queued.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queued
        }
        next.resume()
    }
}

/// Who asked a Smart Inbox job to pause. The worker honors both the same way;
/// they differ only in who may resume the job.
public enum PlainpostJobPauseRequestReason: String, Equatable, Sendable {
    /// The user chose Pause. Only the user resumes the job.
    case userRequested = "user-requested"
    /// Low Power Mode paused the job. It resumes when Low Power Mode ends.
    case lowPower = "low-power"
}

public enum PlainpostSmartInboxBoundaryOutcome: Equatable, Sendable {
    case continueRunning
    case yielded
    case leaseLost
}

/// Someone an account has mailed with: a received message's sender, or a To or Cc
/// recipient of a sent one.
public struct Correspondent: Equatable, Sendable {
    public let address: String
    public let displayName: String?
    /// When the newest message with them was sent.
    public let lastSeen: Date?

    public init(address: String, displayName: String?, lastSeen: Date?) {
        self.address = address
        self.displayName = displayName
        self.lastSeen = lastSeen
    }

    /// Recent correspondents taken from `messages` by the rules
    /// `SQLiteMailStore.recentCorrespondents` uses, newest first. Mail from any of
    /// `ownAddresses` counts as sent.
    public static func recent(
        in messages: [MessageSummary],
        ownAddresses: Set<String>,
        limit: Int = 200
    ) -> [Correspondent] {
        var collector = Collector(ownAddresses: ownAddresses)
        let newestFirst = messages.enumerated().sorted { lhs, rhs in
            switch (lhs.element.sentAt, rhs.element.sentAt) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }
        for message in newestFirst.map(\.element) where !message.isDeleted {
            collector.note(
                from: message.from.rawValue,
                name: message.fromDisplayName,
                recipients: (message.to + message.cc).map(\.rawValue),
                sentAt: message.sentAt
            )
        }
        return collector.correspondents(limit: limit)
    }

    /// Several accounts' correspondents as one list, newest first; the first address to
    /// appear wins, keeping any name another list knows for it.
    public static func merged(_ lists: [[Correspondent]], limit: Int = 200) -> [Correspondent] {
        let newestFirst = lists.joined().enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastSeen, rhs.element.lastSeen) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }
        var collector = Collector(ownAddresses: [])
        for correspondent in newestFirst.map(\.element) {
            collector.add(correspondent.address, name: correspondent.displayName, sentAt: correspondent.lastSeen)
        }
        return collector.correspondents(limit: limit)
    }

    /// Distinct addresses in the order they're first seen, compared ignoring case.
    struct Collector {
        private let ownAddresses: Set<String>
        private var order: [String] = []
        private var byKey: [String: Correspondent] = [:]

        init(ownAddresses: Set<String>) {
            self.ownAddresses = Set(ownAddresses.map(Self.key))
        }

        /// One message, no newer than any message noted before it.
        mutating func note(from: String, name: String?, recipients: [String], sentAt: Date?) {
            if ownAddresses.contains(Self.key(from)) {
                for recipient in recipients { add(recipient, name: nil, sentAt: sentAt) }
            } else {
                add(from, name: name, sentAt: sentAt)
            }
        }

        mutating func add(_ address: String, name: String?, sentAt: Date?) {
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(address)
            guard key.contains("@"), !ownAddresses.contains(key) else { return }
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let knownName = name?.isEmpty == false ? name : nil
            if let existing = byKey[key] {
                if existing.displayName == nil, let knownName {
                    byKey[key] = Correspondent(address: existing.address, displayName: knownName, lastSeen: existing.lastSeen)
                }
                return
            }
            order.append(key)
            byKey[key] = Correspondent(address: address, displayName: knownName, lastSeen: sentAt)
        }

        func correspondents(limit: Int) -> [Correspondent] {
            order.prefix(max(0, limit)).compactMap { byKey[$0] }
        }

        private static func key(_ address: String) -> String {
            address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

public final class SQLiteMailStore: AccountRepository, MailboxRepository, MessageRepository, MailboxMembershipRepository, ThreadRepository, MailCache, ThreadMailCache, AtomicIncomingAttachmentCache, MailboxStateReconciliationCache, MailboxSyncCheckpointCache, MissingSentDateRepairCache, MisreadSenderRepairCache, DraftRepository, SendRequestRepository, AuditRepository, MessageMetadataRepository, MailRuleRepository, MailLabelDefinitionRepository, MessageLabelAssignmentRepository, MessageLabelActionSnapshotRepository, ApprovalSendStore, SentMailRecordingStore, SendWarningRecordingStore, LocalAIStore, MailKnowledgeRepository, DurableOperationArtifactRepository, DurableJobRepository, MailSyncPreferenceRepository, NotificationPublicationStore, @unchecked Sendable {
    private struct CompiledMailSearch {
        var joins: [String] = []
        var predicates: [String] = ["m.is_deleted = 0"]
        var arguments: [(any DatabaseValueConvertible)?] = []
        var ftsQuery: String?
    }

    private struct SmartInboxIncrementalCompatibilityKey: Hashable {
        let classifierDiscriminator: String
        let scopeIdentity: String
        let catalogFingerprint: String?
    }

    private static let documentExtensions = [
        "pdf", "doc", "docx", "odt", "rtf", "txt", "md", "pages",
        "xls", "xlsx", "ods", "numbers", "ppt", "pptx", "odp", "key"
    ]

    package let databasePool: DatabasePool
    package var databaseWriter: any DatabaseWriter { databasePool }
    private static let accountDeletionCoordinator = AccountDeletionCoordinator()
    private let auditLog: RotatingAuditLog
    public let auditLogURL: URL
    private let accountDeletionDatabaseIdentity: String
    private let approvalLock = NSRecursiveLock()
    private let onTransientContention: (@Sendable () throws -> Void)?
    private let onSmartInboxClassificationInputRead: (@Sendable () -> Void)?
    private let onSmartInboxReclassificationPreviewCountRead: (@Sendable () -> Void)?
    private let onJobCancellationBeforeUpdate: (@Sendable () throws -> Void)?
    private let accountDeletionFailpoint: (@Sendable (AccountDeletionFailpoint) throws -> Void)?
    /// Whether the guarded Node-mode schema is usable; see `SQLiteMailStore+NodeMailMode.swift`.
    let nodeModeSchemaState = NodeModeSchemaState()
    let nodeModeMigrationFailpoint: (@Sendable () throws -> Void)?
    let nodeModeMigrationBodyFailpoint: (@Sendable () throws -> Void)?

    public convenience init(
        path: String,
        busyTimeout: TimeInterval = 5,
        readOnly: Bool = false
    ) throws {
        try self.init(
            path: path,
            busyTimeout: busyTimeout,
            readOnly: readOnly,
            onTransientContention: nil,
            onSmartInboxClassificationInputRead: nil,
            onSmartInboxReclassificationPreviewCountRead: nil,
            onJobCancellationBeforeUpdate: nil
        )
    }

    convenience init(
        path: String,
        auditRedactionFailpoint: @escaping @Sendable (AuditRedactionFailpoint) throws -> Void
    ) throws {
        try self.init(
            path: path,
            busyTimeout: 5,
            onTransientContention: nil,
            onSmartInboxClassificationInputRead: nil,
            onSmartInboxReclassificationPreviewCountRead: nil,
            onJobCancellationBeforeUpdate: nil,
            auditRedactionFailpoint: auditRedactionFailpoint
        )
    }

    convenience init(
        path: String,
        accountDeletionFailpoint: @escaping @Sendable (AccountDeletionFailpoint) throws -> Void
    ) throws {
        try self.init(
            path: path,
            busyTimeout: 5,
            onTransientContention: nil,
            onSmartInboxClassificationInputRead: nil,
            onSmartInboxReclassificationPreviewCountRead: nil,
            onJobCancellationBeforeUpdate: nil,
            accountDeletionFailpoint: accountDeletionFailpoint
        )
    }

    convenience init(
        path: String,
        nodeModeMigrationFailpoint: @escaping @Sendable () throws -> Void
    ) throws {
        try self.init(
            path: path,
            busyTimeout: 5,
            onTransientContention: nil,
            nodeModeMigrationFailpoint: nodeModeMigrationFailpoint
        )
    }

    convenience init(
        path: String,
        nodeModeMigrationBodyFailpoint: @escaping @Sendable () throws -> Void
    ) throws {
        try self.init(
            path: path,
            busyTimeout: 5,
            onTransientContention: nil,
            nodeModeMigrationBodyFailpoint: nodeModeMigrationBodyFailpoint
        )
    }

    init(
        path: String,
        busyTimeout: TimeInterval,
        readOnly: Bool = false,
        onTransientContention: (@Sendable () throws -> Void)?,
        onSmartInboxClassificationInputRead: (@Sendable () -> Void)? = nil,
        onSmartInboxReclassificationPreviewCountRead: (@Sendable () -> Void)? = nil,
        onJobCancellationBeforeUpdate: (@Sendable () throws -> Void)? = nil,
        auditRedactionFailpoint: (@Sendable (AuditRedactionFailpoint) throws -> Void)? = nil,
        accountDeletionFailpoint: (@Sendable (AccountDeletionFailpoint) throws -> Void)? = nil,
        nodeModeMigrationFailpoint: (@Sendable () throws -> Void)? = nil,
        nodeModeMigrationBodyFailpoint: (@Sendable () throws -> Void)? = nil
    ) throws {
        let auditLog = try RotatingAuditLog(
            databaseURL: URL(fileURLWithPath: path),
            auditRedactionFailpoint: auditRedactionFailpoint,
            readOnly: readOnly
        )
        self.auditLog = auditLog
        self.auditLogURL = auditLog.fileURL
        self.onTransientContention = onTransientContention
        self.onSmartInboxClassificationInputRead = onSmartInboxClassificationInputRead
        self.onSmartInboxReclassificationPreviewCountRead =
            onSmartInboxReclassificationPreviewCountRead
        self.onJobCancellationBeforeUpdate = onJobCancellationBeforeUpdate
        self.accountDeletionFailpoint = accountDeletionFailpoint
        self.nodeModeMigrationFailpoint = nodeModeMigrationFailpoint
        self.nodeModeMigrationBodyFailpoint = nodeModeMigrationBodyFailpoint
        var configuration = Configuration()
        configuration.label = "Plainpost"
        configuration.maximumReaderCount = 4
        configuration.busyMode = .timeout(max(0, busyTimeout))
        configuration.readonly = readOnly
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            database.add(function: DatabaseFunction(
                "plainpost_normalized_subject",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let subject = String.fromDatabaseValue(values[0]) else { return nil }
                return MailThreading.normalizedSubject(subject)
            })
            // Swift String equality includes canonical Unicode equivalence;
            // SQLite BINARY equality on normalized text does not.
            database.add(function: DatabaseFunction(
                "plainpost_subject_matches", argumentCount: 2, pure: true
            ) { values in
                guard let subject = String.fromDatabaseValue(values[0]),
                      let normalized = String.fromDatabaseValue(values[1]) else { return false }
                return MailThreading.normalizedSubject(subject) == normalized
            })
            database.add(function: DatabaseFunction(
                "plainpost_mailbox_is_trash_or_junk", argumentCount: 3, pure: true
            ) { values in
                guard let path = String.fromDatabaseValue(values[0]) else { return false }
                return MailMailboxFilter.isTrashOrJunk(
                    path, specialUse: String.fromDatabaseValue(values[1]),
                    accountHasMarkedTrash: Bool.fromDatabaseValue(values[2]) ?? false
                )
            })
        }
        databasePool = try DatabasePool(path: path, configuration: configuration)
        accountDeletionDatabaseIdentity = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-existing-mail-store") { database in
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            email TEXT NOT NULL,
            username TEXT NOT NULL DEFAULT '',
            sent_mailbox TEXT NOT NULL DEFAULT 'Sent',
            imap_host TEXT NOT NULL,
            imap_port INTEGER NOT NULL DEFAULT 993,
            smtp_host TEXT NOT NULL,
            smtp_port INTEGER NOT NULL DEFAULT 587
        );
        """)
            try Self.addColumnIfMissing(database: database, table: "accounts", column: "username", definition: "TEXT NOT NULL DEFAULT ''")
            try Self.addColumnIfMissing(database: database, table: "accounts", column: "sent_mailbox", definition: "TEXT NOT NULL DEFAULT 'Sent'")
            try Self.addColumnIfMissing(database: database, table: "accounts", column: "imap_port", definition: "INTEGER NOT NULL DEFAULT 993")
            try Self.addColumnIfMissing(database: database, table: "accounts", column: "smtp_port", definition: "INTEGER NOT NULL DEFAULT 587")
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS mailboxes (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            special_use TEXT
        );
        """)
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            subject_normalized TEXT NOT NULL,
            participant_emails TEXT NOT NULL
        );
        """)
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT,
            from_email TEXT NOT NULL,
            from_display_name TEXT,
            subject TEXT NOT NULL,
            preview TEXT NOT NULL,
            body_text TEXT NOT NULL DEFAULT '',
            body_html TEXT,
            smart_category TEXT NOT NULL,
            smart_priority TEXT NOT NULL DEFAULT 'normal',
            smart_requires_action INTEGER NOT NULL DEFAULT 0,
            smart_confidence REAL,
            labels_json TEXT NOT NULL DEFAULT '[]',
            is_seen INTEGER NOT NULL DEFAULT 0,
            mailbox_path TEXT NOT NULL DEFAULT 'INBOX',
            is_deleted INTEGER NOT NULL DEFAULT 0,
            sent_at REAL
        );
        """)
            try Self.addColumnIfMissing(database: database, table: "messages", column: "labels_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "body_text", definition: "TEXT NOT NULL DEFAULT ''")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "from_display_name", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "body_html", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "is_seen", definition: "INTEGER NOT NULL DEFAULT 0")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "mailbox_path", definition: "TEXT NOT NULL DEFAULT 'INBOX'")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "is_deleted", definition: "INTEGER NOT NULL DEFAULT 0")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "sent_at", definition: "REAL")
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS drafts (
            id TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL
        );
        """)
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS send_requests (
            id TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL
        );
        """)
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS audit_entries (
            id TEXT PRIMARY KEY,
            actor_id TEXT NOT NULL,
            action TEXT NOT NULL,
            target_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            result TEXT NOT NULL
        );
        """)
            try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS durable_operation_artifacts (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            record_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        }
        migrator.registerMigration("v2-local-operations-sync-and-search") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS durable_jobs (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    state TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    available_at REAL NOT NULL,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    max_attempts INTEGER NOT NULL DEFAULT 5,
                    lease_token TEXT,
                    lease_expires_at REAL,
                    cancellation_requested INTEGER NOT NULL DEFAULT 0,
                    pause_requested INTEGER NOT NULL DEFAULT 0,
                    pause_attempt_credit INTEGER NOT NULL DEFAULT 0,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    pause_reason TEXT,
                    progress_current INTEGER,
                    progress_total INTEGER,
                    progress_phase TEXT,
                    progress_label TEXT,
                    result_artifact_id TEXT,
                    error_code TEXT,
                    error_message TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS durable_jobs_claim
                    ON durable_jobs (state, available_at, priority DESC, created_at);

                CREATE TABLE IF NOT EXISTS operation_schedules (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    interval_seconds REAL NOT NULL,
                    next_run_at REAL NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS sync_preferences (
                    account_id TEXT PRIMARY KEY,
                    download_complete_history INTEGER NOT NULL DEFAULT 0,
                    recent_message_limit INTEGER NOT NULL DEFAULT 100,
                    real_time_monitoring_enabled INTEGER NOT NULL DEFAULT 1
                );

                CREATE TABLE IF NOT EXISTS mailbox_sync_preferences (
                    account_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    PRIMARY KEY (account_id, mailbox_path)
                );

                CREATE TABLE IF NOT EXISTS mailbox_sync_state (
                    account_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    phase TEXT NOT NULL DEFAULT 'discovery',
                    uid_validity INTEGER,
                    uid_next INTEGER,
                    highest_mod_sequence INTEGER,
                    oldest_uid INTEGER,
                    newest_uid INTEGER,
                    downloaded_count INTEGER NOT NULL DEFAULT 0,
                    estimated_total INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (account_id, mailbox_path)
                );

                CREATE TABLE IF NOT EXISTS mailbox_messages (
                    account_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    uid_validity INTEGER NOT NULL,
                    uid INTEGER NOT NULL,
                    message_id TEXT NOT NULL,
                    flags TEXT NOT NULL DEFAULT '',
                    mod_sequence INTEGER,
                    internal_date REAL,
                    byte_size INTEGER,
                    PRIMARY KEY (account_id, mailbox_path, uid_validity, uid)
                );
                CREATE INDEX IF NOT EXISTS mailbox_messages_message_id ON mailbox_messages (message_id);

                CREATE INDEX IF NOT EXISTS messages_thread_id ON messages (thread_id);
                CREATE INDEX IF NOT EXISTS messages_sent_at ON messages (sent_at DESC);
                CREATE INDEX IF NOT EXISTS mailboxes_account_id ON mailboxes (account_id);
                """)
            try SQLiteMailSearchSchema.createLegacyStructures(database)
        }
        migrator.registerMigration("v3-backfill-existing-message-search") { database in
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
        migrator.registerMigration("v4-wake-outbox") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS wake_outbox (
                    id TEXT PRIMARY KEY,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    opaque_token BLOB NOT NULL,
                    available_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    delivered_at REAL
                );
                CREATE INDEX IF NOT EXISTS wake_outbox_pending
                    ON wake_outbox (delivered_at, available_at);
                """)
        }
        migrator.registerMigration("v5-mailbox-baseline-state") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "mailbox_sync_state",
                column: "baseline_complete",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("v6-wake-token") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "wake_outbox",
                column: "opaque_token",
                definition: "BLOB"
            )
        }
        migrator.registerMigration("v7-audit-file-outbox") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "audit_entries",
                column: "occurred_at",
                definition: "REAL"
            )
        }
        migrator.registerMigration("v8-message-reply-ancestry") { database in
            try Self.addColumnIfMissing(database: database, table: "messages", column: "rfc_message_id", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "in_reply_to", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "references_json", definition: "TEXT NOT NULL DEFAULT '[]'")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "reply_to_email", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "to_emails", definition: "TEXT NOT NULL DEFAULT ''")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "cc_emails", definition: "TEXT NOT NULL DEFAULT ''")
        }
        migrator.registerMigration("v9-interactive-ai-preemption") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "durable_jobs",
                column: "pause_reason",
                definition: "TEXT"
            )
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS durable_jobs_priority_claim
                    ON durable_jobs (state, cancellation_requested, available_at, priority DESC, created_at);

                CREATE TABLE IF NOT EXISTS smart_inbox_work_items (
                    job_id TEXT NOT NULL REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    message_id TEXT NOT NULL,
                    source_fingerprint TEXT NOT NULL,
                    state TEXT NOT NULL,
                    category TEXT,
                    error_message TEXT,
                    retry_reset_attempt INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (job_id, ordinal),
                    UNIQUE (job_id, message_id)
                );
                CREATE INDEX IF NOT EXISTS smart_inbox_work_pending
                    ON smart_inbox_work_items (job_id, state, ordinal);
                """)
        }
        migrator.registerMigration("v10-smart-inbox-retry-checkpoint") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "retry_reset_attempt",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("v11-durable-mail-embedding-chunks") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS mail_embedding_chunks (
                    message_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    content_fingerprint TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    chunk_text TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (message_id, provider_id, model_id, ordinal)
                );
                CREATE INDEX IF NOT EXISTS mail_embedding_chunks_profile
                    ON mail_embedding_chunks (provider_id, model_id, message_id);
                """)
        }
        migrator.registerMigration("v12-sync-gated-smart-inbox-cache") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_classification_cache (
                    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    source_fingerprint TEXT NOT NULL,
                    category TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    model_id TEXT,
                    classified_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS account_sync_readiness (
                    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    sync_job_id TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("v13-durable-smart-inbox-preparation") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_work_preparations (
                    job_id TEXT PRIMARY KEY REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    prepared_at REAL NOT NULL
                );

                INSERT OR IGNORE INTO smart_inbox_work_preparations (job_id, prepared_at)
                SELECT id, updated_at
                FROM durable_jobs
                WHERE progress_label = 'Smart Inbox' AND progress_total IS NOT NULL;

                INSERT OR IGNORE INTO smart_inbox_work_preparations (job_id, prepared_at)
                SELECT job_id, MIN(updated_at)
                FROM smart_inbox_work_items
                GROUP BY job_id;
                """)
        }
        migrator.registerMigration("v14-sync-scope-readiness") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "account_sync_readiness",
                column: "scope_fingerprint",
                definition: "TEXT"
            )
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_job_scopes (
                    job_id TEXT PRIMARY KEY REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    scope_fingerprint TEXT NOT NULL,
                    mailbox_paths_json TEXT NOT NULL,
                    recent_message_limit INTEGER NOT NULL,
                    download_complete_history INTEGER NOT NULL,
                    incremental_only INTEGER NOT NULL,
                    establishes_readiness INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration("v12-structured-mail-search") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "messages",
                column: "account_id",
                definition: "TEXT"
            )
            try database.execute(sql: """
                UPDATE messages
                SET account_id = (
                    SELECT MIN(mm.account_id)
                    FROM mailbox_messages mm
                    WHERE mm.message_id = messages.id
                )
                WHERE NULLIF(account_id, '') IS NULL
                  AND EXISTS (
                    SELECT 1 FROM mailbox_messages mm WHERE mm.message_id = messages.id
                  );

                UPDATE messages
                SET account_id = (
                    SELECT t.account_id FROM threads t WHERE t.id = messages.thread_id LIMIT 1
                )
                WHERE NULLIF(account_id, '') IS NULL
                  AND EXISTS (
                    SELECT 1 FROM threads t WHERE t.id = messages.thread_id
                  );

                """)
            try SQLiteMailSearchSchema.upgradeLegacySenderProjection(database)
        }
        migrator.registerMigration("v15-durable-desired-seen") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_seen_intents (
                    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    desired_seen INTEGER NOT NULL CHECK (desired_seen IN (0, 1)),
                    updated_at REAL NOT NULL
                );
                """)
            let legacyJobs = try Row.fetchAll(
                database,
                sql: """
                    SELECT payload_json, updated_at
                    FROM durable_jobs
                    WHERE kind = 'mailbox-flag'
                      AND state IN ('queued', 'running', 'paused', 'failed')
                    ORDER BY created_at, rowid
                    """
            )
            for row in legacyJobs {
                guard let input = try? JSONDecoder().decode(
                    PlainpostMailboxFlagInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ) else { continue }
                try database.execute(
                    sql: """
                        INSERT INTO message_seen_intents (message_id, desired_seen, updated_at)
                        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM messages WHERE id = ?)
                        ON CONFLICT(message_id) DO UPDATE SET
                            desired_seen = excluded.desired_seen,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        input.messageID.rawValue,
                        input.desiredSeen ? 1 : 0,
                        row["updated_at"] as Double,
                        input.messageID.rawValue,
                    ]
                )
            }
            try database.execute(sql: """
                UPDATE messages
                SET is_seen = (
                    SELECT desired_seen FROM message_seen_intents
                    WHERE message_id = messages.id
                )
                WHERE id IN (SELECT message_id FROM message_seen_intents)
                """)
        }
        migrator.registerMigration("v16-mailbox-list-paging-indexes") { database in
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS messages_mailbox_list_page
                    ON messages (sent_at DESC, id DESC)
                    WHERE is_deleted = 0;
                CREATE INDEX IF NOT EXISTS mailbox_messages_message_path
                    ON mailbox_messages (message_id, mailbox_path COLLATE NOCASE);
                """)
        }
        migrator.registerMigration("v17-device-compose-reviews") { database in
            try database.execute(sql: """
                CREATE TABLE device_send_reviews (
                    review_id TEXT PRIMARY KEY NOT NULL,
                    device_id TEXT NOT NULL,
                    draft_id TEXT NOT NULL,
                    draft_hash TEXT NOT NULL,
                    risk_flags_json TEXT NOT NULL,
                    recipient_count INTEGER NOT NULL,
                    attachment_count INTEGER NOT NULL,
                    requires_local_authentication INTEGER NOT NULL,
                    expires_at REAL NOT NULL,
                    committed_send_id TEXT,
                    created_at REAL NOT NULL
                );
                CREATE UNIQUE INDEX device_send_review_commit
                    ON device_send_reviews(device_id, committed_send_id)
                    WHERE committed_send_id IS NOT NULL;

                CREATE TABLE device_compose_mutation_receipts (
                    device_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    method TEXT NOT NULL,
                    request_hash TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('in-flight', 'completed')),
                    response_json TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (device_id, idempotency_key)
                );
                """)
        }
        migrator.registerMigration("v18-body-free-device-compose-receipts") { database in
            try Self.sanitizeLegacyDeviceComposeMutationReceipts(database)
        }
        migrator.registerMigration("v19-encrypted-device-compose-recovery") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS device_compose_mutation_recovery_payloads (
                    device_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    ciphertext BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (device_id, idempotency_key),
                    FOREIGN KEY (device_id, idempotency_key)
                        REFERENCES device_compose_mutation_receipts(device_id, idempotency_key)
                        ON DELETE CASCADE
                );
                """)
        }
        migrator.registerMigration("v20-device-projection-history") { database in
            try database.execute(sql: """
                CREATE TABLE device_projection_head (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                    revision INTEGER NOT NULL,
                    cursor TEXT NOT NULL UNIQUE,
                    payload_hash TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );

                CREATE TABLE device_projection_history (
                    revision INTEGER PRIMARY KEY NOT NULL,
                    cursor TEXT NOT NULL UNIQUE,
                    payload_hash TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("v21-device-projection-cursor-windows") { database in
            try database.execute(sql: """
                ALTER TABLE device_projection_head
                    ADD COLUMN source_generation INTEGER NOT NULL DEFAULT 0;

                CREATE TABLE device_projection_source_generation (
                    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
                    generation INTEGER NOT NULL
                );
                INSERT INTO device_projection_source_generation(singleton, generation)
                    VALUES (1, 0);

                ALTER TABLE device_projection_history
                    RENAME TO device_projection_history_v20;

                CREATE TABLE device_projection_history (
                    cursor TEXT PRIMARY KEY NOT NULL,
                    revision INTEGER NOT NULL,
                    page_size INTEGER NOT NULL CHECK (page_size BETWEEN 1 AND 500),
                    payload_hash TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );

                INSERT INTO device_projection_history (
                    cursor, revision, page_size, payload_hash, payload_json, created_at
                )
                SELECT cursor, revision, 500, payload_hash, payload_json, created_at
                FROM device_projection_history_v20;

                DROP TABLE device_projection_history_v20;

                CREATE INDEX device_projection_history_revision
                    ON device_projection_history(revision DESC, page_size, created_at DESC);

                CREATE TRIGGER device_projection_accounts_insert
                AFTER INSERT ON accounts BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_accounts_update
                AFTER UPDATE ON accounts BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_accounts_delete
                AFTER DELETE ON accounts BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;

                CREATE TRIGGER device_projection_mailboxes_insert
                AFTER INSERT ON mailboxes BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_mailboxes_update
                AFTER UPDATE ON mailboxes BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_mailboxes_delete
                AFTER DELETE ON mailboxes BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;

                CREATE TRIGGER device_projection_threads_insert
                AFTER INSERT ON threads BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_threads_update
                AFTER UPDATE ON threads BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_threads_delete
                AFTER DELETE ON threads BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;

                CREATE TRIGGER device_projection_messages_insert
                AFTER INSERT ON messages BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_messages_update
                AFTER UPDATE ON messages BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                CREATE TRIGGER device_projection_messages_delete
                AFTER DELETE ON messages BEGIN
                    UPDATE device_projection_source_generation
                    SET generation = generation + 1 WHERE singleton = 1;
                END;
                """)
        }
        migrator.registerMigration("v22-repair-message-search-metadata") { database in
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
        migrator.registerMigration("v23-account-scoped-mail-rules") { database in
            try database.execute(sql: """
                CREATE TABLE mail_rules (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL CHECK (is_enabled IN (0, 1)),
                    scope_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX mail_rules_scope
                    ON mail_rules(scope_account_id, is_enabled, updated_at);

                CREATE TABLE mail_rule_conditions (
                    id TEXT PRIMARY KEY NOT NULL,
                    rule_id TEXT NOT NULL REFERENCES mail_rules(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    field TEXT NOT NULL,
                    operator TEXT NOT NULL,
                    value TEXT NOT NULL,
                    UNIQUE(rule_id, ordinal)
                );

                CREATE TABLE mail_rule_actions (
                    rule_id TEXT NOT NULL REFERENCES mail_rules(id) ON DELETE CASCADE,
                    action TEXT NOT NULL,
                    PRIMARY KEY(rule_id, action)
                );
                """)
        }
        migrator.registerMigration("v24-mail-rule-actions") { database in
            try database.execute(sql: """
                CREATE TABLE mail_rule_message_actions (
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    source_rule_ids_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(message_id, action)
                );
                CREATE INDEX mail_rule_message_actions_account
                    ON mail_rule_message_actions(account_id, action);
                """)
        }
        migrator.registerMigration("v25-mail-rule-runs") { database in
            try database.execute(sql: """
                CREATE TABLE mail_rule_runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    rule_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    total_items INTEGER NOT NULL,
                    enqueued_items INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE mail_rule_run_items (
                    run_id TEXT NOT NULL REFERENCES mail_rule_runs(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL,
                    actions_json TEXT NOT NULL,
                    job_ids_json TEXT NOT NULL DEFAULT '[]',
                    state TEXT NOT NULL,
                    error_message TEXT,
                    PRIMARY KEY(run_id, ordinal)
                );
                """)
        }
        migrator.registerMigration("v26_smart_inbox_triage") { database in
            try Self.addColumnIfMissing(database: database, table: "messages", column: "smart_priority", definition: "TEXT NOT NULL DEFAULT 'normal'")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "smart_requires_action", definition: "INTEGER NOT NULL DEFAULT 0")
            try Self.addColumnIfMissing(database: database, table: "messages", column: "smart_confidence", definition: "REAL")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_work_items", column: "priority", definition: "TEXT")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_work_items", column: "requires_action", definition: "INTEGER")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_work_items", column: "confidence", definition: "REAL")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_classification_cache", column: "priority", definition: "TEXT NOT NULL DEFAULT 'normal'")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_classification_cache", column: "requires_action", definition: "INTEGER NOT NULL DEFAULT 0")
            try Self.addColumnIfMissing(database: database, table: "smart_inbox_classification_cache", column: "confidence", definition: "REAL")
            try Self.createSmartInboxBatchProfilesTable(database)
        }
        migrator.registerMigration("v26-device-projection-pages") { database in
            try database.execute(sql: """
                CREATE TABLE device_projection_pages (
                    token TEXT PRIMARY KEY,
                    base_cursor TEXT NOT NULL REFERENCES device_projection_history(cursor) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    page_size INTEGER NOT NULL CHECK(page_size BETWEEN 1 AND 500),
                    page_start_index INTEGER NOT NULL CHECK(page_start_index > 0),
                    next_token TEXT,
                    created_at REAL NOT NULL,
                    UNIQUE(base_cursor, device_id, page_size, page_start_index)
                );
                CREATE INDEX device_projection_pages_lookup
                    ON device_projection_pages(base_cursor, device_id, page_size, page_start_index);
                """)
        }
        migrator.registerMigration("v27-smart-inbox-labels") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS mail_labels (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    normalized_title TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    smart_inbox_enabled INTEGER NOT NULL DEFAULT 0,
                    scope_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS mail_labels_scope_title_idx
                    ON mail_labels(scope_account_id, normalized_title);

                CREATE TABLE IF NOT EXISTS message_label_assignments (
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    label_id TEXT NOT NULL REFERENCES mail_labels(id) ON DELETE CASCADE,
                    source_kind TEXT NOT NULL CHECK(source_kind IN ('user', 'rule', 'smartInbox')),
                    source_id TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    PRIMARY KEY(message_id, label_id, source_kind, source_id)
                );
                CREATE INDEX IF NOT EXISTS message_label_assignments_label_idx
                    ON message_label_assignments(label_id, message_id);

                CREATE TABLE IF NOT EXISTS message_label_exclusions (
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    label_id TEXT NOT NULL REFERENCES mail_labels(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(message_id, label_id)
                );

                CREATE TABLE IF NOT EXISTS mail_rule_label_actions (
                    rule_id TEXT NOT NULL REFERENCES mail_rules(id) ON DELETE CASCADE,
                    label_id TEXT NOT NULL REFERENCES mail_labels(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    PRIMARY KEY(rule_id, label_id)
                );

                CREATE TABLE IF NOT EXISTS smart_inbox_label_catalog_snapshots (
                    job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    catalog_fingerprint TEXT NOT NULL,
                    labels_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """)
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "label_matches_json",
                definition: "TEXT NOT NULL DEFAULT '[]'"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "catalog_fingerprint",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_classification_cache",
                column: "label_matches_json",
                definition: "TEXT NOT NULL DEFAULT '[]'"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_classification_cache",
                column: "catalog_fingerprint",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "classifier_discriminator",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "provider_id",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "model_id",
                definition: "TEXT"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "writes_enriched_projection",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "was_updated",
                definition: "INTEGER"
            )
            try Self.backfillLegacyMailLabels(database)
        }
        migrator.registerMigration("v28-smart-inbox-label-runtime") { database in
            // Task 6 extends work-item state after the v27 schema landed. Keep
            // this idempotent so databases that already recorded v27 receive
            // the runtime columns while fresh databases remain unchanged.
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "classifier_discriminator",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "provider_id",
                definition: "TEXT NOT NULL DEFAULT ''"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "model_id",
                definition: "TEXT"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "writes_enriched_projection",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "smart_inbox_work_items",
                column: "was_updated",
                definition: "INTEGER"
            )
            let activeRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, payload_json, state, cancellation_requested
                    FROM durable_jobs
                    WHERE kind = 'ai-operation' AND state IN ('queued', 'running', 'paused')
                    ORDER BY created_at, id
                    """
            )
            let now = Date().timeIntervalSince1970
            for row in activeRows {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), input.operation == .recategorizeInbox else {
                    continue
                }
                let jobID: String = row["id"]
                let prepared = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM smart_inbox_work_preparations WHERE job_id = ?
                        )
                        """,
                    arguments: [jobID]
                ) ?? false
                let workCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = ?",
                    arguments: [jobID]
                ) ?? 0
                guard prepared || workCount > 0 else { continue }
                let snapshotExists = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM smart_inbox_label_catalog_snapshots
                            WHERE job_id = ? AND NULLIF(catalog_fingerprint, '') IS NOT NULL
                        )
                        """,
                    arguments: [jobID]
                ) ?? false
                let emptyCatalogWorkCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM smart_inbox_work_items
                        WHERE job_id = ? AND NULLIF(catalog_fingerprint, '') IS NULL
                        """,
                    arguments: [jobID]
                ) ?? 0
                guard !snapshotExists || emptyCatalogWorkCount > 0 else { continue }

                try database.execute(
                    sql: "DELETE FROM smart_inbox_work_items WHERE job_id = ?",
                    arguments: [jobID]
                )
                try database.execute(
                    sql: "DELETE FROM smart_inbox_work_preparations WHERE job_id = ?",
                    arguments: [jobID]
                )
                try database.execute(
                    sql: "DELETE FROM smart_inbox_label_catalog_snapshots WHERE job_id = ?",
                    arguments: [jobID]
                )
                let priorState: String = row["state"]
                let cancellationRequested: Bool = row["cancellation_requested"]
                let migratedState = cancellationRequested ? "cancelled" : "queued"
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = ?,
                            attempt = CASE
                                WHEN ? = 'queued' AND ? IN ('running', 'paused')
                                    THEN MAX(0, attempt - 1)
                                ELSE attempt
                            END,
                            available_at = MIN(available_at, ?),
                            lease_token = NULL,
                            lease_expires_at = NULL,
                            pause_reason = NULL,
                            progress_current = NULL,
                            progress_total = NULL,
                            progress_phase = NULL,
                            progress_label = NULL,
                            error_code = NULL,
                            error_message = NULL,
                            result_artifact_id = NULL,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        migratedState,
                        migratedState,
                        priorState,
                        now,
                        now,
                        jobID,
                    ]
                )
            }
        }
        migrator.registerMigration("v29-smart-inbox-completion-audit-marker") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "durable_jobs",
                column: "smart_inbox_completion_audit_recorded",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
            let terminalRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, payload_json FROM durable_jobs
                    WHERE kind = 'ai-operation'
                      AND state IN ('completed', 'failed', 'cancelled')
                    ORDER BY id
                    """
            )
            for row in terminalRows {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ),
                input.operation == .recategorizeInbox,
                input.smartInboxRunMode == .rerunAll else {
                    continue
                }
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET smart_inbox_completion_audit_recorded = 1
                        WHERE id = ?
                        """,
                    arguments: [row["id"] as String]
                )
            }
        }
        migrator.registerMigration("v30-smart-inbox-user-pause") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "durable_jobs",
                column: "pause_requested",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("v31-smart-inbox-pause-attempt-credit") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "durable_jobs",
                column: "pause_attempt_credit",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("v32-unified-local-mail-search") { database in
            try SQLiteMailSearchSchema.migrateV22(database)
        }
        migrator.registerMigration("v33-search-attachment-mime-metadata") { database in
            try SQLiteMailSearchSchema.migrateV23(database)
        }
        migrator.registerMigration("v34-credential-ciphertexts") { database in
            try database.execute(sql: """
                CREATE TABLE credential_ciphertexts (
                    record_key TEXT PRIMARY KEY,
                    version INTEGER NOT NULL,
                    combined BLOB NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v35-device-smart-inbox-projection") { database in
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS messages_device_smart_inbox_projection
                    ON messages (smart_requires_action DESC, sent_at DESC, id)
                    WHERE is_deleted = 0;
                """)
        }
        migrator.registerMigration("v36-device-approval-queue") { database in
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS send_requests_device_approval_queue
                    ON send_requests (
                        json_extract(payload_json, '$.status'),
                        json_extract(payload_json, '$.expiresAt'),
                        id
                    );
                """)
        }
        migrator.registerMigration("v37-incoming-message-attachments") { database in
            try database.execute(sql: """
                CREATE TABLE incoming_message_attachments (
                    message_id TEXT NOT NULL
                        REFERENCES messages(id) ON DELETE CASCADE,
                    part_path TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    filename TEXT NOT NULL,
                    mime_type TEXT,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (message_id, part_path)
                );
                """)
        }
        migrator.registerMigration("v38-message-translation-cache") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_translations (
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    target_language_id TEXT NOT NULL,
                    source_fingerprint TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    contract_version TEXT NOT NULL,
                    body_kind TEXT NOT NULL,
                    translated_body TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (message_id, target_language_id)
                );

                CREATE TRIGGER IF NOT EXISTS message_translations_delete_on_soft_delete
                AFTER UPDATE OF is_deleted ON messages
                WHEN NEW.is_deleted = 1
                BEGIN
                    DELETE FROM message_translations WHERE message_id = NEW.id;
                END;
                """)
        }
        migrator.registerMigration("v39-durable-job-terminal-sequence") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "durable_jobs",
                column: "terminal_sequence",
                definition: "INTEGER"
            )
            try database.execute(sql: """
                CREATE TABLE durable_job_terminal_events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL
                );
                """)
            let terminalJobIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id FROM durable_jobs
                    WHERE state NOT IN ('queued', 'running', 'paused')
                    ORDER BY updated_at, id
                    """
            )
            for jobID in terminalJobIDs {
                try database.execute(
                    sql: "INSERT INTO durable_job_terminal_events (job_id) VALUES (?)",
                    arguments: [jobID]
                )
                try database.execute(
                    sql: "UPDATE durable_jobs SET terminal_sequence = ? WHERE id = ?",
                    arguments: [database.lastInsertedRowID, jobID]
                )
            }
            try database.execute(sql: """
                CREATE INDEX durable_jobs_terminal_diagnostics
                    ON durable_jobs (terminal_sequence, updated_at DESC, id DESC)
                    WHERE state NOT IN ('queued', 'running', 'paused');

                CREATE TRIGGER durable_jobs_assign_terminal_sequence_after_insert
                AFTER INSERT ON durable_jobs
                WHEN NEW.state NOT IN ('queued', 'running', 'paused')
                BEGIN
                    INSERT INTO durable_job_terminal_events (job_id) VALUES (NEW.id);
                    UPDATE durable_jobs
                    SET terminal_sequence = last_insert_rowid()
                    WHERE id = NEW.id;
                END;

                CREATE TRIGGER durable_jobs_assign_terminal_sequence_after_update
                AFTER UPDATE OF state ON durable_jobs
                WHEN OLD.state IN ('queued', 'running', 'paused')
                  AND NEW.state NOT IN ('queued', 'running', 'paused')
                BEGIN
                    INSERT INTO durable_job_terminal_events (job_id) VALUES (NEW.id);
                    UPDATE durable_jobs
                    SET terminal_sequence = last_insert_rowid()
                    WHERE id = NEW.id;
                END;
                """)
        }
        migrator.registerMigration("v40-durable-job-diagnostics-order-index") { database in
            try database.execute(sql: """
                DROP INDEX IF EXISTS durable_jobs_terminal_diagnostics;
                CREATE INDEX durable_jobs_terminal_diagnostics_order
                    ON durable_jobs (updated_at DESC, id DESC, terminal_sequence)
                    WHERE state NOT IN ('queued', 'running', 'paused');
                """)
        }
        migrator.registerMigration("v41-inbox-sync-reconciliation-generation") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "sync_job_scopes",
                column: "reconciliation_generation",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
            let activeSyncRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, payload_json FROM durable_jobs
                    WHERE kind IN ('inbox-sync', 'historical-sync')
                      AND state IN ('queued', 'running', 'paused')
                    ORDER BY id
                    """
            )
            for row in activeSyncRows {
                guard let input = try? JSONDecoder().decode(
                    PlainpostInboxSyncInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ) else {
                    continue
                }
                try Self.ensureSyncJobScope(
                    database: database,
                    jobID: row["id"],
                    input: input
                )
            }
        }
        migrator.registerMigration("v42-smart-inbox-incremental-follow-up-demand") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_incremental_follow_up_demands (
                    predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                    successor_job_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(predecessor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE
                )
                """)
        }
        migrator.registerMigration("v43-smart-inbox-promoted-successor") { database in
            let demandColumns = try Row.fetchAll(
                database,
                sql: "PRAGMA table_info(smart_inbox_incremental_follow_up_demands)"
            ).map { row in row["name"] as String }
            if !demandColumns.contains("successor_job_id") {
                try database.execute(
                    sql: "ALTER TABLE smart_inbox_incremental_follow_up_demands ADD COLUMN successor_job_id TEXT"
                )
            }
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_promoted_successors (
                    predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                    successor_job_id TEXT NOT NULL
                )
                """)
        }
        migrator.registerMigration("v44-repair-smart-inbox-follow-up-pairs") { database in
            let now = Date().timeIntervalSince1970
            func canonicalKey(predecessorID: String) -> String {
                "ai:recategorizeInbox:follow-up:\(predecessorID)"
            }
            func repairKeyBase(predecessorID: String, payloadJSON: String) -> String {
                let identity = "\(predecessorID)\u{0}\(payloadJSON)"
                let digest = SHA256.hash(data: Data(identity.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return "\(canonicalKey(predecessorID: predecessorID)):repair:\(digest)"
            }
            func isAcceptedSuccessorKey(
                _ key: String,
                predecessorID: String,
                payloadJSON: String
            ) -> Bool {
                let canonical = canonicalKey(predecessorID: predecessorID)
                guard key != canonical else { return true }
                let base = repairKeyBase(
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                )
                guard key != base else { return true }
                guard key.hasPrefix("\(base):") else { return false }
                let suffix = key.dropFirst(base.count + 1).utf8
                guard let first = suffix.first, (49...57).contains(first) else {
                    return false
                }
                return suffix.dropFirst().allSatisfy { (48...57).contains($0) }
            }
            func decodesCompatibleFollowUp(_ payloadJSON: String) -> Bool {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(payloadJSON.utf8)
                ) else {
                    return false
                }
                return input.operation == .recategorizeInbox
                    && input.smartInboxRunMode == .incremental
                    && input.smartInboxClassifierIdentity != nil
            }
            func isCompatibleUnownedSuccessor(
                _ successorID: String,
                predecessorID: String,
                payloadJSON: String
            ) throws -> Bool {
                guard successorID != predecessorID,
                      decodesCompatibleFollowUp(payloadJSON),
                      let successor = try Row.fetchOne(
                        database,
                        sql: """
                            SELECT kind, payload_json, idempotency_key
                            FROM durable_jobs WHERE id = ?
                            """,
                        arguments: [successorID]
                      ),
                      successor["kind"] as String == PlainpostOperationKind.aiOperation.rawValue,
                      successor["payload_json"] as String == payloadJSON,
                      isAcceptedSuccessorKey(
                        successor["idempotency_key"] as String,
                        predecessorID: predecessorID,
                        payloadJSON: payloadJSON
                      ) else {
                    return false
                }
                return !(try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM smart_inbox_incremental_follow_up_demands
                            WHERE successor_job_id = ? AND predecessor_job_id != ?
                            UNION ALL
                            SELECT 1
                            FROM smart_inbox_promoted_successors
                            WHERE successor_job_id = ? AND predecessor_job_id != ?
                        )
                        """,
                    arguments: [successorID, predecessorID, successorID, predecessorID]
                ) ?? false)
            }
            let demands = try Row.fetchAll(
                database,
                sql: """
                    SELECT predecessor_job_id, successor_job_id, payload_json, created_at
                    FROM smart_inbox_incremental_follow_up_demands
                    ORDER BY created_at, predecessor_job_id
                    """
            )
            for demand in demands {
                let predecessorID: String = demand["predecessor_job_id"]
                guard let predecessorState = try String.fetchOne(
                    database,
                    sql: "SELECT state FROM durable_jobs WHERE id = ?",
                    arguments: [predecessorID]
                ) else {
                    let payloadJSON: String = demand["payload_json"]
                    let expectedKey = canonicalKey(predecessorID: predecessorID)
                    if let successorID: String = demand["successor_job_id"] {
                        try database.execute(
                            sql: """
                                UPDATE durable_jobs
                                SET state = 'cancelled', cancellation_requested = 1,
                                    lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                                WHERE id = ? AND kind = 'ai-operation'
                                  AND idempotency_key = ? AND payload_json = ?
                                  AND pause_reason = 'smart-inbox-follow-up'
                                  AND state IN ('queued', 'running', 'paused')
                                """,
                            arguments: [now, successorID, expectedKey, payloadJSON]
                        )
                    }
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                    continue
                }
                let payloadJSON: String = demand["payload_json"]
                let recordedSuccessorID: String? = demand["successor_job_id"]
                guard decodesCompatibleFollowUp(payloadJSON) else {
                    if let recordedSuccessorID,
                       let reserved = try Row.fetchOne(
                        database,
                        sql: "SELECT idempotency_key FROM durable_jobs WHERE id = ?",
                        arguments: [recordedSuccessorID]
                       ) {
                        let reservedKey: String = reserved["idempotency_key"]
                        if isAcceptedSuccessorKey(
                            reservedKey,
                            predecessorID: predecessorID,
                            payloadJSON: payloadJSON
                        ) {
                            try database.execute(
                                sql: """
                                    UPDATE durable_jobs
                                    SET state = 'cancelled', cancellation_requested = 1,
                                        lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                                    WHERE id = ? AND kind = 'ai-operation' AND payload_json = ?
                                      AND pause_reason = 'smart-inbox-follow-up'
                                      AND idempotency_key = ?
                                      AND state IN ('queued', 'running', 'paused')
                                    """,
                                arguments: [
                                    now,
                                    recordedSuccessorID,
                                    payloadJSON,
                                    reservedKey,
                                ]
                            )
                        }
                    }
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                    continue
                }
                let successorID: String
                if let recordedSuccessorID,
                   try isCompatibleUnownedSuccessor(
                    recordedSuccessorID,
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                   ) {
                    successorID = recordedSuccessorID
                } else if let existingID = try String.fetchOne(
                    database,
                    sql: "SELECT id FROM durable_jobs WHERE idempotency_key = ?",
                    arguments: [canonicalKey(predecessorID: predecessorID)]
                ), try isCompatibleUnownedSuccessor(
                    existingID,
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                ) {
                    successorID = existingID
                } else {
                    let canonical = canonicalKey(predecessorID: predecessorID)
                    let canonicalOccupied = try Bool.fetchOne(
                        database,
                        sql: "SELECT EXISTS(SELECT 1 FROM durable_jobs WHERE idempotency_key = ?)",
                        arguments: [canonical]
                    ) ?? false
                    let materialization: (id: String, key: String, needsInsert: Bool)
                    if canonicalOccupied {
                        let base = repairKeyBase(
                            predecessorID: predecessorID,
                            payloadJSON: payloadJSON
                        )
                        materialization = try {
                            var suffix = 0
                            while true {
                                let candidateKey = suffix == 0 ? base : "\(base):\(suffix)"
                                if let candidateID = try String.fetchOne(
                                    database,
                                    sql: "SELECT id FROM durable_jobs WHERE idempotency_key = ?",
                                    arguments: [candidateKey]
                                ) {
                                    if try isCompatibleUnownedSuccessor(
                                        candidateID,
                                        predecessorID: predecessorID,
                                        payloadJSON: payloadJSON
                                    ) {
                                        return (candidateID, candidateKey, false)
                                    }
                                    suffix += 1
                                    continue
                                }
                                return (
                                    "job_\(UUID().uuidString.lowercased())",
                                    candidateKey,
                                    true
                                )
                            }
                        }()
                    } else {
                        materialization = (
                            "job_\(UUID().uuidString.lowercased())",
                            canonical,
                            true
                        )
                    }
                    successorID = materialization.id
                    if materialization.needsInsert {
                        let priority = (try? JSONDecoder().decode(
                            PlainpostAIOperationInput.self,
                            from: Data(payloadJSON.utf8)
                        ).operation.priority) ?? 10
                        try database.execute(
                            sql: """
                                INSERT INTO durable_jobs (
                                    id, kind, payload_json, state, priority, available_at,
                                    attempt, max_attempts, cancellation_requested,
                                    idempotency_key, created_at, updated_at,
                                    pause_reason, progress_phase
                                ) VALUES (?, 'ai-operation', ?, 'paused', ?, ?, 0, 5, 0, ?, ?, ?,
                                    'smart-inbox-follow-up', 'paused')
                                """,
                            arguments: [
                                successorID,
                                payloadJSON,
                                priority,
                                now,
                                materialization.key,
                                now,
                                now,
                            ]
                        )
                        try database.execute(
                            sql: """
                                INSERT OR IGNORE INTO smart_inbox_label_catalog_snapshots (
                                    job_id, catalog_fingerprint, labels_json, created_at
                                )
                                SELECT ?, catalog_fingerprint, labels_json, created_at
                                FROM smart_inbox_label_catalog_snapshots
                                WHERE job_id = ?
                                """,
                            arguments: [successorID, predecessorID]
                        )
                    }
                }
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_incremental_follow_up_demands
                        SET successor_job_id = ?
                        WHERE predecessor_job_id = ?
                        """,
                    arguments: [successorID, predecessorID]
                )
                if ["completed", "failed"].contains(predecessorState) {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'queued', cancellation_requested = 0,
                                pause_reason = NULL, progress_phase = 'queued',
                                error_code = NULL, error_message = NULL,
                                lease_token = NULL, lease_expires_at = NULL,
                                available_at = ?, updated_at = ?
                            WHERE id = ? AND state != 'completed'
                            """,
                        arguments: [now, now, successorID]
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO smart_inbox_promoted_successors (
                                predecessor_job_id, successor_job_id
                            ) VALUES (?, ?)
                            ON CONFLICT(predecessor_job_id) DO UPDATE SET
                                successor_job_id = excluded.successor_job_id
                            """,
                        arguments: [predecessorID, successorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                } else if ["cancelled", "delivery-uncertain"].contains(predecessorState) {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'cancelled', cancellation_requested = 1,
                                lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                            WHERE id = ? AND state IN ('queued', 'running', 'paused')
                            """,
                        arguments: [now, successorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                } else {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'paused', cancellation_requested = 0,
                                pause_requested = 0,
                                pause_reason = 'smart-inbox-follow-up',
                                progress_phase = 'paused',
                                error_code = NULL, error_message = NULL,
                                lease_token = NULL, lease_expires_at = NULL,
                                updated_at = ?
                            WHERE id = ?
                            """,
                        arguments: [now, successorID]
                    )
                }
            }
            let mappings = try Row.fetchAll(
                database,
                sql: """
                    SELECT predecessor_job_id, successor_job_id
                    FROM smart_inbox_promoted_successors
                    ORDER BY predecessor_job_id
                    """
            )
            for mapping in mappings {
                let predecessorID: String = mapping["predecessor_job_id"]
                let successorID: String = mapping["successor_job_id"]
                let hasCompatibleIdentity = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM durable_jobs predecessor
                            JOIN durable_jobs successor ON successor.id = ?
                            WHERE predecessor.id = ?
                              AND successor.kind = 'ai-operation'
                              AND NOT EXISTS (
                                  SELECT 1
                                  FROM smart_inbox_incremental_follow_up_demands demand
                                  WHERE demand.successor_job_id = successor.id
                                    AND demand.predecessor_job_id != ?
                              )
                        )
                        """,
                    arguments: [
                        successorID,
                        predecessorID,
                        predecessorID,
                    ]
                ) ?? false
                let successorPayload = try String.fetchOne(
                    database,
                    sql: "SELECT payload_json FROM durable_jobs WHERE id = ?",
                    arguments: [successorID]
                )
                let successorKey = try String.fetchOne(
                    database,
                    sql: "SELECT idempotency_key FROM durable_jobs WHERE id = ?",
                    arguments: [successorID]
                )
                let valid = successorID != predecessorID
                    && hasCompatibleIdentity
                    && (successorPayload.map(decodesCompatibleFollowUp) ?? false)
                    && (successorPayload.flatMap { payloadJSON in
                        successorKey.map {
                            isAcceptedSuccessorKey(
                                $0,
                                predecessorID: predecessorID,
                                payloadJSON: payloadJSON
                            )
                        }
                    } ?? false)
                if !valid {
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                }
            }
            try database.execute(sql: """
                CREATE TABLE smart_inbox_incremental_follow_up_demands_v44 (
                    predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                    successor_job_id TEXT NOT NULL UNIQUE,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(predecessor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    FOREIGN KEY(successor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE
                );
                INSERT INTO smart_inbox_incremental_follow_up_demands_v44 (
                    predecessor_job_id, successor_job_id, payload_json, created_at
                )
                SELECT demands.predecessor_job_id, demands.successor_job_id,
                    demands.payload_json, demands.created_at
                FROM smart_inbox_incremental_follow_up_demands demands
                JOIN durable_jobs predecessor ON predecessor.id = demands.predecessor_job_id
                JOIN durable_jobs successor ON successor.id = demands.successor_job_id;
                DROP TABLE smart_inbox_incremental_follow_up_demands;
                ALTER TABLE smart_inbox_incremental_follow_up_demands_v44
                    RENAME TO smart_inbox_incremental_follow_up_demands;

                CREATE TABLE smart_inbox_promoted_successors_v44 (
                    predecessor_job_id TEXT NOT NULL PRIMARY KEY,
                    successor_job_id TEXT NOT NULL UNIQUE,
                    FOREIGN KEY(predecessor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    FOREIGN KEY(successor_job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE
                );
                INSERT INTO smart_inbox_promoted_successors_v44 (
                    predecessor_job_id, successor_job_id
                )
                SELECT mappings.predecessor_job_id, mappings.successor_job_id
                FROM smart_inbox_promoted_successors mappings
                JOIN durable_jobs predecessor ON predecessor.id = mappings.predecessor_job_id
                JOIN durable_jobs successor ON successor.id = mappings.successor_job_id;
                DROP TABLE smart_inbox_promoted_successors;
                ALTER TABLE smart_inbox_promoted_successors_v44
                    RENAME TO smart_inbox_promoted_successors;
                """)
        }
        migrator.registerMigration("v45-repair-smart-inbox-follow-up-collisions") { database in
            let now = Date().timeIntervalSince1970
            func canonicalKey(predecessorID: String) -> String {
                "ai:recategorizeInbox:follow-up:\(predecessorID)"
            }
            func repairKeyBase(predecessorID: String, payloadJSON: String) -> String {
                let identity = "\(predecessorID)\u{0}\(payloadJSON)"
                let digest = SHA256.hash(data: Data(identity.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return "\(canonicalKey(predecessorID: predecessorID)):repair:\(digest)"
            }
            func isAcceptedRepairKey(
                _ key: String,
                predecessorID: String,
                payloadJSON: String
            ) -> Bool {
                let canonical = canonicalKey(predecessorID: predecessorID)
                guard key != canonical else { return true }
                let base = repairKeyBase(
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                )
                guard key != base else { return true }
                guard key.hasPrefix("\(base):") else { return false }
                let suffix = key.dropFirst(base.count + 1).utf8
                guard let first = suffix.first, (49...57).contains(first) else {
                    return false
                }
                return suffix.dropFirst().allSatisfy { (48...57).contains($0) }
            }
            func isValidDemandPayload(_ payloadJSON: String) -> Bool {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(payloadJSON.utf8)
                ) else {
                    return false
                }
                return input.operation == .recategorizeInbox
                    && input.smartInboxRunMode == .incremental
                    && input.smartInboxClassifierIdentity != nil
            }
            func isCompatibleUnownedSuccessor(
                _ successorID: String,
                predecessorID: String,
                payloadJSON: String
            ) throws -> Bool {
                guard successorID != predecessorID,
                      let successor = try Row.fetchOne(
                        database,
                        sql: """
                            SELECT kind, payload_json, idempotency_key
                            FROM durable_jobs WHERE id = ?
                            """,
                        arguments: [successorID]
                      ),
                      successor["kind"] as String == PlainpostOperationKind.aiOperation.rawValue,
                      successor["payload_json"] as String == payloadJSON,
                      isAcceptedRepairKey(
                        successor["idempotency_key"] as String,
                        predecessorID: predecessorID,
                        payloadJSON: payloadJSON
                      ) else {
                    return false
                }
                return !(try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM smart_inbox_incremental_follow_up_demands
                            WHERE successor_job_id = ? AND predecessor_job_id != ?
                            UNION ALL
                            SELECT 1
                            FROM smart_inbox_promoted_successors
                            WHERE successor_job_id = ? AND predecessor_job_id != ?
                        )
                        """,
                    arguments: [successorID, predecessorID, successorID, predecessorID]
                ) ?? false)
            }
            func cancelIdentifiedReservation(
                successorID: String?,
                predecessorID: String,
                payloadJSON: String
            ) throws {
                guard let successorID else { return }
                guard let reservation = try Row.fetchOne(
                    database,
                    sql: "SELECT idempotency_key FROM durable_jobs WHERE id = ?",
                    arguments: [successorID]
                ) else { return }
                let reservationKey: String = reservation["idempotency_key"]
                guard isAcceptedRepairKey(
                    reservationKey,
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                ) else { return }
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = 'cancelled', cancellation_requested = 1,
                            lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND kind = 'ai-operation' AND payload_json = ?
                          AND pause_reason = 'smart-inbox-follow-up'
                          AND idempotency_key = ?
                          AND state IN ('queued', 'running', 'paused')
                        """,
                    arguments: [
                        now,
                        successorID,
                        payloadJSON,
                        reservationKey,
                    ]
                )
            }
            func discardDemand(predecessorID: String) throws {
                try database.execute(
                    sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                    arguments: [predecessorID]
                )
                try database.execute(
                    sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                    arguments: [predecessorID]
                )
            }
            func insertReservedSuccessor(
                predecessorID: String,
                payloadJSON: String,
                idempotencyKey: String
            ) throws -> String {
                let successorID = "job_\(UUID().uuidString.lowercased())"
                let priority = try JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(payloadJSON.utf8)
                ).operation.priority
                try database.execute(
                    sql: """
                        INSERT INTO durable_jobs (
                            id, kind, payload_json, state, priority, available_at,
                            attempt, max_attempts, cancellation_requested,
                            idempotency_key, created_at, updated_at,
                            pause_reason, progress_phase
                        ) VALUES (?, 'ai-operation', ?, 'paused', ?, ?, 0, 5, 0, ?, ?, ?,
                            'smart-inbox-follow-up', 'paused')
                        """,
                    arguments: [
                        successorID,
                        payloadJSON,
                        priority,
                        now,
                        idempotencyKey,
                        now,
                        now,
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO smart_inbox_label_catalog_snapshots (
                            job_id, catalog_fingerprint, labels_json, created_at
                        )
                        SELECT ?, catalog_fingerprint, labels_json, created_at
                        FROM smart_inbox_label_catalog_snapshots
                        WHERE job_id = ?
                        """,
                    arguments: [successorID, predecessorID]
                )
                return successorID
            }

            let demands = try Row.fetchAll(
                database,
                sql: """
                    SELECT predecessor_job_id, successor_job_id, payload_json
                    FROM smart_inbox_incremental_follow_up_demands
                    ORDER BY created_at, predecessor_job_id
                    """
            )
            for demand in demands {
                let predecessorID: String = demand["predecessor_job_id"]
                let recordedSuccessorID: String? = demand["successor_job_id"]
                let payloadJSON: String = demand["payload_json"]
                guard isValidDemandPayload(payloadJSON) else {
                    try cancelIdentifiedReservation(
                        successorID: recordedSuccessorID,
                        predecessorID: predecessorID,
                        payloadJSON: payloadJSON
                    )
                    try discardDemand(predecessorID: predecessorID)
                    continue
                }
                guard let predecessorState = try String.fetchOne(
                    database,
                    sql: "SELECT state FROM durable_jobs WHERE id = ?",
                    arguments: [predecessorID]
                ) else {
                    try cancelIdentifiedReservation(
                        successorID: recordedSuccessorID,
                        predecessorID: predecessorID,
                        payloadJSON: payloadJSON
                    )
                    try discardDemand(predecessorID: predecessorID)
                    continue
                }

                let successorID: String
                if let recordedSuccessorID,
                   try isCompatibleUnownedSuccessor(
                    recordedSuccessorID,
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                   ) {
                    successorID = recordedSuccessorID
                } else if let canonicalSuccessorID = try String.fetchOne(
                    database,
                    sql: "SELECT id FROM durable_jobs WHERE idempotency_key = ?",
                    arguments: [canonicalKey(predecessorID: predecessorID)]
                ), try isCompatibleUnownedSuccessor(
                    canonicalSuccessorID,
                    predecessorID: predecessorID,
                    payloadJSON: payloadJSON
                ) {
                    successorID = canonicalSuccessorID
                } else {
                    let base = repairKeyBase(
                        predecessorID: predecessorID,
                        payloadJSON: payloadJSON
                    )
                    var suffix = 0
                    while true {
                        let candidateKey = suffix == 0 ? base : "\(base):\(suffix)"
                        if let candidateID = try String.fetchOne(
                            database,
                            sql: "SELECT id FROM durable_jobs WHERE idempotency_key = ?",
                            arguments: [candidateKey]
                        ) {
                            if try isCompatibleUnownedSuccessor(
                                candidateID,
                                predecessorID: predecessorID,
                                payloadJSON: payloadJSON
                            ) {
                                successorID = candidateID
                                break
                            }
                            suffix += 1
                            continue
                        }
                        successorID = try insertReservedSuccessor(
                            predecessorID: predecessorID,
                            payloadJSON: payloadJSON,
                            idempotencyKey: candidateKey
                        )
                        break
                    }
                }
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_incremental_follow_up_demands
                        SET successor_job_id = ?
                        WHERE predecessor_job_id = ?
                        """,
                    arguments: [successorID, predecessorID]
                )
                if ["completed", "failed"].contains(predecessorState) {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'queued', cancellation_requested = 0,
                                pause_reason = NULL, progress_phase = 'queued',
                                error_code = NULL, error_message = NULL,
                                lease_token = NULL, lease_expires_at = NULL,
                                available_at = ?, updated_at = ?
                            WHERE id = ? AND state != 'completed'
                            """,
                        arguments: [now, now, successorID]
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO smart_inbox_promoted_successors (
                                predecessor_job_id, successor_job_id
                            ) VALUES (?, ?)
                            ON CONFLICT(predecessor_job_id) DO UPDATE SET
                                successor_job_id = excluded.successor_job_id
                            """,
                        arguments: [predecessorID, successorID]
                    )
                    try database.execute(
                        sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
                        arguments: [predecessorID]
                    )
                } else if ["cancelled", "delivery-uncertain"].contains(predecessorState) {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'cancelled', cancellation_requested = 1,
                                lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                            WHERE id = ? AND state IN ('queued', 'running', 'paused')
                            """,
                        arguments: [now, successorID]
                    )
                    try discardDemand(predecessorID: predecessorID)
                } else {
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'paused', cancellation_requested = 0,
                                pause_requested = 0,
                                pause_reason = 'smart-inbox-follow-up',
                                progress_phase = 'paused',
                                error_code = NULL, error_message = NULL,
                                lease_token = NULL, lease_expires_at = NULL,
                                updated_at = ?
                            WHERE id = ?
                            """,
                        arguments: [now, successorID]
                    )
                }
            }
        }
        migrator.registerMigration("v46-account-owned-local-data") { database in
            let ownerTables = [
                "drafts", "send_requests", "durable_jobs", "operation_schedules",
                "durable_operation_artifacts", "smart_inbox_work_items",
                "mail_rule_run_items", "device_send_reviews",
                "device_compose_mutation_receipts",
                "device_compose_mutation_recovery_payloads", "audit_entries",
            ]
            for table in ownerTables {
                try Self.addColumnIfMissing(
                    database: database,
                    table: table,
                    column: "owner_account_id",
                    definition: "TEXT"
                )
                try database.execute(sql: "CREATE INDEX IF NOT EXISTS \(table)_owner_account ON \(table) (owner_account_id)")
                try Self.addColumnIfMissing(
                    database: database,
                    table: table,
                    column: "ownership_kind",
                    definition: "TEXT NOT NULL DEFAULT 'ambiguous'"
                )
                try database.execute(
                    sql: "CREATE INDEX IF NOT EXISTS \(table)_ownership_kind_owner ON \(table) (ownership_kind, owner_account_id)"
                )
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(table)_ownership_validate_insert")
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(table)_ownership_validate_update")
            }

            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS device_compose_recovery_credentials (
                    device_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    credential_record_key TEXT NOT NULL UNIQUE,
                    owner_account_id TEXT NOT NULL,
                    PRIMARY KEY (device_id, idempotency_key),
                    FOREIGN KEY (device_id, idempotency_key)
                        REFERENCES device_compose_mutation_receipts(device_id, idempotency_key)
                        ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS device_compose_recovery_credentials_owner
                    ON device_compose_recovery_credentials (owner_account_id);
                """)

            try Self.reconcileOwnershipV46(database)
            try Self.migrateLegacyRecoveryCredentialAssociationsV46(database)
            try Self.recreateOwnershipValidationTriggersV46(database, tables: ownerTables)
        }
        migrator.registerMigration("v47-account-ownership-foundations") { database in
            let ownerTables = [
                "drafts", "send_requests", "durable_jobs", "operation_schedules",
                "durable_operation_artifacts", "smart_inbox_work_items",
                "mail_rule_run_items", "device_send_reviews",
                "device_compose_mutation_receipts",
                "device_compose_mutation_recovery_payloads", "audit_entries",
            ]
            for table in ownerTables {
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(table)_ownership_validate_insert")
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(table)_ownership_validate_update")
                try Self.addColumnIfMissing(
                    database: database,
                    table: table,
                    column: "owner_account_id",
                    definition: "TEXT"
                )
                try Self.addColumnIfMissing(
                    database: database,
                    table: table,
                    column: "ownership_kind",
                    definition: "TEXT NOT NULL DEFAULT 'ambiguous'"
                )
                try database.execute(sql: "CREATE INDEX IF NOT EXISTS \(table)_owner_account ON \(table) (owner_account_id)")
                try database.execute(
                    sql: "CREATE INDEX IF NOT EXISTS \(table)_ownership_kind_owner ON \(table) (ownership_kind, owner_account_id)"
                )
            }
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS device_compose_recovery_credentials (
                    device_id TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    credential_record_key TEXT NOT NULL UNIQUE,
                    owner_account_id TEXT NOT NULL,
                    PRIMARY KEY (device_id, idempotency_key),
                    FOREIGN KEY (device_id, idempotency_key)
                        REFERENCES device_compose_mutation_receipts(device_id, idempotency_key)
                        ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS device_compose_recovery_credentials_owner
                    ON device_compose_recovery_credentials (owner_account_id);
                CREATE TABLE IF NOT EXISTS local_account_orphan_owner_queue (
                    owner_account_id TEXT PRIMARY KEY,
                    discovered_at REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'purged'))
                );
                CREATE INDEX IF NOT EXISTS local_account_orphan_owner_queue_status
                    ON local_account_orphan_owner_queue (status, discovered_at);
                """)

            try Self.reconcileOwnershipV46(database)
            try Self.migrateLegacyRecoveryCredentialAssociationsV46(database)
            let discoveredAt = Date().timeIntervalSince1970
            for table in ownerTables {
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO local_account_orphan_owner_queue (
                            owner_account_id, discovered_at, status
                        )
                        SELECT DISTINCT owned.owner_account_id, ?, 'pending'
                        FROM \(table) owned
                        WHERE owned.ownership_kind = 'account'
                          AND owned.owner_account_id IS NOT NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM accounts
                              WHERE accounts.id = owned.owner_account_id
                          )
                        """,
                    arguments: [discoveredAt]
                )
            }
            try Self.recreateOwnershipValidationTriggersV46(database, tables: ownerTables)
        }
        migrator.registerMigration("v48-durable-job-produced-drafts") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS durable_job_produced_drafts (
                    job_id TEXT PRIMARY KEY,
                    draft_id TEXT NOT NULL UNIQUE,
                    FOREIGN KEY (job_id) REFERENCES durable_jobs(id) ON DELETE CASCADE,
                    FOREIGN KEY (draft_id) REFERENCES drafts(id) ON DELETE CASCADE
                );
                """)
        }
        migrator.registerMigration("v49-account-deletion-audit-redaction") { database in
            try database.execute(sql: """
                CREATE TABLE account_deletion_audit_redaction_commits (
                    journal_id TEXT PRIMARY KEY NOT NULL,
                    committed_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("v50-account-deletion-credential-intent") { database in
            try database.execute(sql: """
                CREATE TABLE account_deletion_intents (
                    account_id TEXT PRIMARY KEY NOT NULL,
                    credential_record_keys_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """)
        }
        Self.registerLegacyPairingRemovalV51(on: &migrator)
        migrator.registerMigration("v52-direct-notification-producer") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS local_notification_mailboxes (
                    account_id TEXT NOT NULL,
                    plainpost_account_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    logical_mailbox_id TEXT NOT NULL,
                    logical_mailbox_id_bytes BLOB NOT NULL DEFAULT X'0000000000000000000000000000000000000000000000000000000000000000',
                    uid_validity INTEGER NOT NULL,
                    selected_producer_device_id TEXT,
                    selected_producer_kind TEXT NOT NULL DEFAULT 'mac',
                    policy_mode TEXT NOT NULL DEFAULT 'off',
                    policy_version INTEGER NOT NULL DEFAULT 0,
                    config_revision INTEGER NOT NULL DEFAULT 0,
                    config_version TEXT NOT NULL DEFAULT 'default',
                    producer_generation INTEGER NOT NULL DEFAULT 0,
                    baseline_complete INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (account_id, mailbox_path),
                    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS local_notification_watermarks (
                    account_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    uid_validity INTEGER NOT NULL,
                    watermark_uid INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (account_id, mailbox_path, uid_validity),
                    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS local_notification_publications (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    plainpost_account_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    mailbox_path TEXT NOT NULL,
                    logical_mailbox_id TEXT NOT NULL,
                    logical_mailbox_id_bytes BLOB NOT NULL DEFAULT X'0000000000000000000000000000000000000000000000000000000000000000',
                    uid_validity INTEGER NOT NULL,
                    uid INTEGER NOT NULL,
                    thread_id TEXT,
                    provider_arrival_at REAL,
                    producer_device_id TEXT,
                    producer_kind TEXT NOT NULL DEFAULT 'mac',
                    policy_mode TEXT NOT NULL DEFAULT 'off',
                    policy_version INTEGER NOT NULL DEFAULT 0,
                    config_revision INTEGER NOT NULL DEFAULT 0,
                    config_version TEXT NOT NULL,
                    producer_generation INTEGER NOT NULL,
                    committed_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending','claimed','frozen','cancelled','completed')),
                    terminal_reason TEXT,
                    last_error TEXT,
                    lease_token TEXT,
                    lease_expires_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE (account_id, mailbox_path, uid_validity, uid),
                    UNIQUE (account_id, message_id, config_version, producer_generation),
                    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE,
                    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS local_notification_publications_claim
                    ON local_notification_publications (state, lease_expires_at, created_at);
                CREATE TABLE IF NOT EXISTS local_notification_deliveries (
                    publication_id TEXT NOT NULL,
                    recipient_id TEXT NOT NULL,
                    producer_device_id TEXT,
                    producer_generation INTEGER NOT NULL DEFAULT 0,
                    policy_version INTEGER NOT NULL DEFAULT 0,
                    replay_id TEXT,
                    collapse_digest BLOB,
                    routing_handle BLOB NOT NULL,
                    agreement_public_key BLOB NOT NULL,
                    envelope_bytes BLOB NOT NULL,
                    envelope_digest BLOB,
                    outcome TEXT,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at REAL,
                    lease_token TEXT,
                    lease_expires_at REAL,
                    completed_at REAL,
                    PRIMARY KEY (publication_id, recipient_id),
                    FOREIGN KEY (publication_id) REFERENCES local_notification_publications(id)
                        ON DELETE CASCADE
                );
                """)
        }
        migrator.registerMigration("v53-direct-notification-eligibility") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "local_notification_mailboxes",
                column: "notification_eligible",
                definition: "INTEGER NOT NULL DEFAULT 1"
            )
            try Self.addColumnIfMissing(
                database: database,
                table: "local_notification_mailboxes",
                column: "notification_revoked",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("v54-direct-notification-assignment-identity") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "local_notification_mailboxes",
                column: "producer_identity_digest",
                definition: "TEXT"
            )
        }
        migrator.registerMigration("v55-direct-notification-policy-scope") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "local_notification_mailboxes",
                column: "policy_override",
                definition: "INTEGER"
            )
        }
        migrator.registerMigration("v56-direct-notification-scope-coordinate") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "local_notification_mailboxes",
                column: "direct_policy_scope_version",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
            // v55 temporarily stored the Direct scope high-water in
            // config_revision because the dedicated column did not yet
            // exist.  ADD COLUMN ... DEFAULT 0 makes those rows look like
            // scope zero, so identify the old Direct rows by their metadata
            // rather than by NULL in the new column.  Pre-Task4 rows have no
            // Direct metadata and retain their legacy config revision.
            // v55 did not persist an authoritative non-Direct revision to
            // restore; reset the overloaded field instead of fabricating
            // trust/config authority.  The next authenticated reconciliation
            // supplies the current assignment revision when applicable.
            try database.execute(sql: """
                UPDATE local_notification_mailboxes
                SET direct_policy_scope_version = config_revision,
                    config_revision = 0
                WHERE (policy_override IS NOT NULL OR producer_identity_digest IS NOT NULL)
                  AND direct_policy_scope_version = 0
                """)
            try database.execute(sql: """
                UPDATE local_notification_mailboxes
                SET direct_policy_scope_version = 0
                WHERE direct_policy_scope_version IS NULL
                """)
        }
        migrator.registerMigration("v57-remove-legacy-wake-outbox") { database in
            // The wake-outbox path was removed, but its historical v4/v6
            // registrations remain so existing migration histories stay valid.
            try database.execute(sql: "DROP TABLE IF EXISTS wake_outbox")
        }
        migrator.registerMigration("v58-smart-inbox-failure-suppressions") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_inbox_failure_suppressions (
                    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    source_fingerprint TEXT NOT NULL,
                    catalog_fingerprint TEXT NOT NULL,
                    classifier_discriminator TEXT NOT NULL,
                    diagnostic_codes_json TEXT NOT NULL,
                    failed_at REAL NOT NULL
                );
                """)
            let latestFailedRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT work.message_id, work.source_fingerprint,
                        work.catalog_fingerprint, work.updated_at, jobs.payload_json
                    FROM smart_inbox_work_items work
                    JOIN durable_jobs jobs ON jobs.id = work.job_id
                    WHERE work.state = 'failed'
                      AND NOT EXISTS (
                        SELECT 1
                        FROM smart_inbox_work_items newer
                        WHERE newer.message_id = work.message_id
                          AND (
                            newer.updated_at > work.updated_at
                            OR (newer.updated_at = work.updated_at AND newer.rowid > work.rowid)
                          )
                      )
                    ORDER BY work.message_id
                    """
            )
            let diagnosticCodesJSON = String(
                decoding: try JSONEncoder().encode(["validation.invalid_response"]),
                as: UTF8.self
            )
            for row in latestFailedRows {
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), input.operation == .recategorizeInbox else {
                    continue
                }
                try database.execute(
                    sql: """
                        INSERT INTO smart_inbox_failure_suppressions (
                            message_id, source_fingerprint, catalog_fingerprint,
                            classifier_discriminator, diagnostic_codes_json, failed_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(message_id) DO UPDATE SET
                            source_fingerprint = excluded.source_fingerprint,
                            catalog_fingerprint = excluded.catalog_fingerprint,
                            classifier_discriminator = excluded.classifier_discriminator,
                            diagnostic_codes_json = excluded.diagnostic_codes_json,
                            failed_at = excluded.failed_at
                        """,
                    arguments: [
                        row["message_id"] as String,
                        row["source_fingerprint"] as String,
                        row["catalog_fingerprint"] as String,
                        input.resolvedSmartInboxClassifierIdentity.discriminator,
                        diagnosticCodesJSON,
                        row["updated_at"] as Double,
                    ]
                )
            }
        }
        migrator.registerMigration("v59-mac-new-mail-notifications") { database in
            try database.execute(sql: """
                CREATE TABLE mac_new_mail_deliveries (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('individual', 'summary')),
                    state TEXT NOT NULL CHECK (state IN (
                        'ready', 'leased', 'submitting', 'submitted',
                        'retry_wait', 'suppressed', 'expired', 'failed'
                    )),
                    event_count INTEGER NOT NULL CHECK (event_count > 0),
                    first_provider_arrival_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at REAL,
                    lease_token TEXT,
                    lease_expires_at REAL,
                    terminal_reason TEXT,
                    last_error_category TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE mac_new_mail_events (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    state TEXT NOT NULL CHECK (state IN (
                        'awaiting_rules', 'ready', 'assigned', 'suppressed', 'expired'
                    )),
                    provider_arrival_at REAL NOT NULL,
                    ready_at REAL,
                    expires_at REAL NOT NULL,
                    delivery_id TEXT REFERENCES mac_new_mail_deliveries(id) ON DELETE SET NULL,
                    terminal_reason TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE (account_id, message_id),
                    CHECK (state != 'assigned' OR delivery_id IS NOT NULL)
                );

                CREATE INDEX mac_new_mail_events_rule_work
                    ON mac_new_mail_events (state, expires_at, provider_arrival_at, id);
                CREATE INDEX mac_new_mail_events_ready_account
                    ON mac_new_mail_events (account_id, state, ready_at, provider_arrival_at, id);
                CREATE INDEX mac_new_mail_events_terminal_cleanup
                    ON mac_new_mail_events (state, updated_at, id);
                CREATE INDEX mac_new_mail_deliveries_due
                    ON mac_new_mail_deliveries (state, next_attempt_at, expires_at, created_at, id);
                CREATE INDEX mac_new_mail_deliveries_expired_lease
                    ON mac_new_mail_deliveries (state, lease_expires_at, id);
                CREATE INDEX mac_new_mail_deliveries_terminal_cleanup
                    ON mac_new_mail_deliveries (state, updated_at, id);

                CREATE TRIGGER mac_new_mail_events_delivery_account_insert
                BEFORE INSERT ON mac_new_mail_events
                WHEN NEW.delivery_id IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM mac_new_mail_deliveries delivery
                    WHERE delivery.id = NEW.delivery_id
                      AND delivery.account_id = NEW.account_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'mac notification event and delivery accounts differ');
                END;

                CREATE TRIGGER mac_new_mail_events_delivery_account_update
                BEFORE UPDATE OF account_id, delivery_id ON mac_new_mail_events
                WHEN NEW.delivery_id IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM mac_new_mail_deliveries delivery
                    WHERE delivery.id = NEW.delivery_id
                      AND delivery.account_id = NEW.account_id
                  )
                BEGIN
                    SELECT RAISE(ABORT, 'mac notification event and delivery accounts differ');
                END;
                """)
        }
        Self.registerAccountAuthenticationV60(on: &migrator)
        Self.registerMicrosoftAccountAuthenticationV61(on: &migrator)
        try migrator.migrate(databasePool)
        // Guarded and never rethrown: a failure before the schema exists
        // leaves every account Direct; one after it changes nothing.
        let nodeModeSchemaMigrated = migrateNodeMode()
        try migrateDirectSendIntent()
        try migrateDirectAccountDeletionIntentSource()
        try migrateRecentCorrespondentsIndex()
        try migrateSmartInboxPolicy()
        try migrateForegroundInboxRefresh()
        try migrateMessageFlagged()
        try migrateIncomingAttachmentContentID()
        try migrateCredentialCiphertextArchive()
        try databasePool.write { database in
            try SQLiteMailSearchSchema.prepareDatabase(database)
            try Self.repairCredentialBlockedSyncJobs(database)
            try Self.ensureApprovedDeliveryRequestIndex(database)
        }
        try recoverAuditRedactionJournal()
        try flushAuditOutbox()
        // Audited only when the failure really leaves a Node-mode table absent
        // (v1 sources or the v2 intent journal); a failed re-run over an
        // existing schema changes nothing.
        if !nodeModeSchemaMigrated, let missing = firstAbsentNodeModeMigration() {
            recordNodeModeSchemaUnavailable(missingMigration: missing)
        }
    }

    /// A redacted, global audit entry. The target is the missing migration's
    /// fixed identifier; the underlying error is never recorded.
    func recordNodeModeSchemaUnavailable(missingMigration: String) {
        precondition(Self.nodeModeMigrations.contains(missingMigration))
        try? databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO audit_entries (
                        id, actor_id, action, target_type, target_id, result, occurred_at,
                        owner_account_id, ownership_kind
                    ) VALUES (?, 'plainpost-runtime', 'node_mode.schema_unavailable',
                              'node_mode', ?, 'failed', ?, NULL, 'global')
                    """,
                arguments: [
                    "aud_\(UUID().uuidString.lowercased())",
                    missingMigration,
                    Date().timeIntervalSince1970,
                ]
            )
        }
        try? flushAuditOutbox()
    }

    private func migrateDirectAccountDeletionIntentSource() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v64-direct-account-deletion-intent-source") { database in
            try database.execute(sql: "ALTER TABLE account_deletion_intents ADD COLUMN direct_source_generation INTEGER")
        }
        try migrator.migrate(databasePool)
    }

    /// Lets `recentCorrespondents` read one account's newest messages in order and stop at its
    /// scan limit.
    private func migrateRecentCorrespondentsIndex() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v65-messages-account-sent-at-index") { database in
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS messages_account_sent_at
                    ON messages (account_id, sent_at DESC)
                    WHERE is_deleted = 0
                """)
        }
        try migrator.migrate(databasePool)
    }

    private func migrateForegroundInboxRefresh() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v67-foreground-inbox-refresh-checkpoint") { database in
            try database.execute(sql: """
                ALTER TABLE sync_job_scopes ADD COLUMN foreground_requested_revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE sync_job_scopes ADD COLUMN foreground_requested_recent_limit INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE sync_job_scopes ADD COLUMN foreground_checkpoint_json TEXT;
                """)
        }
        try migrator.migrate(databasePool)
    }

    /// `messages.is_flagged`: whether any copy of the message carries \\Flagged, kept by
    /// triggers on its memberships so every writer (sync, the mirror, a Flag action) keeps it.
    private func migrateMessageFlagged() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v69-message-flagged") { database in
            try database.execute(sql: """
                ALTER TABLE messages ADD COLUMN is_flagged INTEGER NOT NULL DEFAULT 0;
                UPDATE messages SET is_flagged = EXISTS (
                    SELECT 1 FROM mailbox_messages
                    WHERE message_id = messages.id AND lower(flags) LIKE '%flagged%'
                );
                CREATE TRIGGER messages_flagged_after_membership_insert AFTER INSERT ON mailbox_messages
                BEGIN
                    UPDATE messages SET is_flagged = EXISTS (
                        SELECT 1 FROM mailbox_messages
                        WHERE message_id = NEW.message_id AND lower(flags) LIKE '%flagged%'
                    ) WHERE id = NEW.message_id;
                END;
                CREATE TRIGGER messages_flagged_after_membership_flags AFTER UPDATE OF flags, message_id ON mailbox_messages
                BEGIN
                    UPDATE messages SET is_flagged = EXISTS (
                        SELECT 1 FROM mailbox_messages
                        WHERE message_id = NEW.message_id AND lower(flags) LIKE '%flagged%'
                    ) WHERE id = NEW.message_id;
                    UPDATE messages SET is_flagged = EXISTS (
                        SELECT 1 FROM mailbox_messages
                        WHERE message_id = OLD.message_id AND lower(flags) LIKE '%flagged%'
                    ) WHERE id = OLD.message_id;
                END;
                CREATE TRIGGER messages_flagged_after_membership_delete AFTER DELETE ON mailbox_messages
                BEGIN
                    UPDATE messages SET is_flagged = EXISTS (
                        SELECT 1 FROM mailbox_messages
                        WHERE message_id = OLD.message_id AND lower(flags) LIKE '%flagged%'
                    ) WHERE id = OLD.message_id;
                END;
                """)
        }
        try migrator.migrate(databasePool)
    }

    /// `cid:` image sources in a message's HTML name their part by Content-ID.
    private func migrateIncomingAttachmentContentID() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v70-incoming-attachment-content-id") { database in
            try Self.addColumnIfMissing(
                database: database,
                table: "incoming_message_attachments",
                column: "content_id",
                definition: "TEXT"
            )
        }
        try migrator.migrate(databasePool)
    }

    /// Where "Start Over with Saved Sign-ins" keeps the encrypted credentials a
    /// lost vault key can no longer open. Rows are only ever added: they are
    /// kept, not deleted, in case the old key ever turns up.
    private func migrateCredentialCiphertextArchive() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v71-credential-ciphertexts-archive") { database in
            try database.execute(sql: """
                CREATE TABLE credential_ciphertexts_archive (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    record_key TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    combined BLOB NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    archived_at TEXT NOT NULL,
                    reason TEXT NOT NULL CHECK (reason IN ('key_missing'))
                );
                """)
        }
        try migrator.migrate(databasePool)
    }

    static func registerLegacyPairingRemovalV51(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v51-remove-legacy-device-pairing-state") { database in
            // Triggers attached to ordinary mail tables must be removed before their
            // projection target disappears or later account/mail writes will fail.
            for type in ["trigger", "view", "index"] {
                let names = try String.fetchAll(
                    database,
                    sql: """
                        SELECT name
                        FROM sqlite_master
                        WHERE type = ?
                          AND (
                              name LIKE 'device_projection%'
                              OR name LIKE 'device_compose%'
                              OR name LIKE 'device_send%'
                          )
                        ORDER BY name
                        """,
                    arguments: [type]
                )
                for name in names {
                    let quotedName = name.replacingOccurrences(of: "\"", with: "\"\"")
                    try database.execute(sql: "DROP \(type.uppercased()) IF EXISTS \"\(quotedName)\"")
                }
            }
            try database.execute(sql: """
                DROP INDEX IF EXISTS messages_device_smart_inbox_projection;
                DROP INDEX IF EXISTS send_requests_device_approval_queue;
                """)

            // Pairing clients were removed in the clean break. Child tables are
            // dropped before their referenced parents; their rows are not preserved.
            try database.execute(sql: """
                DROP TABLE IF EXISTS device_compose_recovery_credentials;
                DROP TABLE IF EXISTS device_compose_mutation_recovery_payloads;
                DROP TABLE IF EXISTS device_compose_mutation_receipts;
                DROP TABLE IF EXISTS device_send_reviews;
                DROP TABLE IF EXISTS device_projection_pages;
                DROP TABLE IF EXISTS device_projection_history;
                DROP TABLE IF EXISTS device_projection_head;
                DROP TABLE IF EXISTS device_projection_source_generation;
                """)
        }
    }

    /// Additive and idempotent (never an edit of an applied migration): a
    /// partial expression index for finding a send request's approval jobs
    /// by their payload, whatever their idempotency key.
    static let approvedDeliveryRequestIndex = "durable_jobs_approved_delivery_request"

    static func ensureApprovedDeliveryRequestIndex(_ database: Database) throws {
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS \(approvedDeliveryRequestIndex)
                ON durable_jobs (json_extract(payload_json, '$.requestID'))
                WHERE kind = 'approved-delivery'
            """)
    }

    private static func repairCredentialBlockedSyncJobs(_ database: Database) throws {
        try database.execute(sql: """
            UPDATE durable_jobs
            SET state = 'paused', attempt = 0, pause_reason = 'credentials-unavailable',
                progress_phase = 'paused', progress_label = 'Waiting for Mail Keychain',
                lease_token = NULL, lease_expires_at = NULL,
                error_code = NULL, error_message = NULL,
                updated_at = CAST(strftime('%s', 'now') AS REAL)
            WHERE kind IN ('inbox-sync', 'historical-sync')
              AND state = 'failed'
              AND error_code = 'VALIDATION_FAILED'
              AND error_message = 'IMAP credentials are not available.'
            """)
    }

    private static func sanitizeLegacyDeviceComposeMutationReceipts(
        _ database: Database
    ) throws {
        try database.execute(
            sql: """
                UPDATE device_compose_mutation_receipts
                SET response_json = CASE
                    WHEN json_valid(response_json) = 0 THEN json_object(
                        'kind', 'invalid',
                        'draftID', '',
                        'draftHash', '',
                        'deletedHash', NULL
                    )
                    WHEN method IN (
                        'compose.draftCreate',
                        'compose.replyBegin',
                        'compose.attachmentPut',
                        'compose.attachmentRemove'
                    ) THEN json_object(
                        'kind', 'draft',
                        'draftID', json_extract(response_json, '$.draft.id'),
                        'draftHash', json_extract(response_json, '$.draft.contentHash'),
                        'deletedHash', NULL
                    )
                    WHEN method = 'compose.draftUpdate'
                         AND json_extract(response_json, '$.outcome') = 'conflict'
                    THEN json_object(
                        'kind', 'conflict',
                        'draftID', json_extract(response_json, '$.conflict.authoritative.id'),
                        'draftHash', json_extract(response_json, '$.conflict.authoritative.contentHash'),
                        'deletedHash', NULL
                    )
                    WHEN method = 'compose.draftUpdate' THEN json_object(
                        'kind', 'draft',
                        'draftID', json_extract(response_json, '$.draft.id'),
                        'draftHash', json_extract(response_json, '$.draft.contentHash'),
                        'deletedHash', NULL
                    )
                    WHEN method = 'compose.draftDelete' THEN json_object(
                        'kind', 'deleted',
                        'draftID', json_extract(response_json, '$.draftID'),
                        'draftHash', json_extract(response_json, '$.deletedHash'),
                        'deletedHash', json_extract(response_json, '$.deletedHash')
                    )
                    ELSE json_object(
                        'kind', 'invalid',
                        'draftID', '',
                        'draftHash', '',
                        'deletedHash', NULL
                    )
                END
                WHERE state = 'completed'
                  AND response_json IS NOT NULL
                  -- Approval decisions use the same durable receipt table,
                  -- but their completed response is a protocol result rather
                  -- than a compose recovery descriptor.
                  AND method <> 'approval-decision-v1'
                  AND CASE
                      WHEN json_valid(response_json) = 0 THEN 1
                      ELSE json_extract(response_json, '$.kind') IS NULL
                  END
                """
        )
    }

    public var accounts: [Account] {
        (try? readAccounts()) ?? []
    }

    public var mailboxes: [Mailbox] {
        (try? readMailboxes()) ?? []
    }

    public func mailboxes(limit: Int, accountID: AccountID? = nil) throws -> [Mailbox] {
        try mailboxes(limit: limit, accountFilter: MailboxAccountFilter(accountID))
    }

    /// Up to `limit` mailboxes of the filter's accounts, by id.
    public func mailboxes(limit: Int, accountFilter: MailboxAccountFilter) throws -> [Mailbox] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let (clause, values) = accountFilter.sql(column: "account_id")
        return try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id, account_id, name, path, special_use FROM mailboxes WHERE 1 \(clause) ORDER BY id LIMIT ?",
                arguments: StatementArguments(values + [String(boundedLimit)])
            ).map { row in
                Mailbox(
                    id: MailboxID(row["id"]),
                    accountID: AccountID(row["account_id"]),
                    name: row["name"],
                    path: row["path"],
                    specialUse: row["special_use"]
                )
            }
        }
    }

    public func mailboxPaths(accountID: AccountID) throws -> [String] {
        try databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT DISTINCT path FROM mailboxes WHERE account_id = ? ORDER BY path COLLATE NOCASE, path",
                arguments: [accountID.rawValue]
            )
        }
    }

    public var messages: [MessageSummary] {
        (try? readMessages()) ?? []
    }

    /// Reads one account in a single SQL query. Old cached rows may lack
    /// messages.account_id, so ownership falls back to membership, then thread.
    public func messages(accountID: AccountID? = nil) -> [MessageSummary] {
        guard let accountID else { return messages }
        let rows = try? fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.body_text, m.body_html, m.smart_category,
                m.labels_json, m.is_seen, m.is_flagged, m.mailbox_path, m.is_deleted, m.sent_at,
                m.rfc_message_id, m.in_reply_to, m.references_json, m.reply_to_email,
                m.to_emails, m.cc_emails
            FROM messages m
            LEFT JOIN threads t ON t.id = m.thread_id
            WHERE m.account_id = ?
               OR (m.account_id IS NULL
                   AND EXISTS (SELECT 1 FROM mailbox_messages mm
                               WHERE mm.message_id = m.id AND mm.account_id = ?)
                   AND NOT EXISTS (SELECT 1 FROM mailbox_messages other
                                   WHERE other.message_id = m.id AND other.account_id <> ?))
               OR (m.account_id IS NULL AND t.account_id = ?
                   AND NOT EXISTS (SELECT 1 FROM mailbox_messages mm
                                   WHERE mm.message_id = m.id))
            ORDER BY m.id
            """,
            [accountID.rawValue, accountID.rawValue, accountID.rawValue, accountID.rawValue]
        )
        return rows?.map(decodeMessage) ?? []
    }

    /// Body-free keyset batches for opaque notification token resolution. Keep the
    /// same explicit/membership/thread ownership precedence as `messages(accountID:)`.
    /// A caller cannot accidentally materialize an entire mailbox with Int.max.
    package func notificationMessageIDs(
        accountFilter: MailboxAccountFilter, after: MessageID?, limit: Int = 256
    ) throws -> [MessageID] {
        switch accountFilter {
        case .all:
            return try notificationMessageIDs(accountID: nil, after: after, limit: limit)
        case .accounts(let ids):
            // Each account's own keyset batch, merged in id order: the ownership precedence
            // stays the single-account query's.
            let merged = try ids.flatMap { try notificationMessageIDs(accountID: $0, after: after, limit: limit) }
            return Array(Set(merged)).sorted { $0.rawValue < $1.rawValue }.prefix(min(limit, 256)).map { $0 }
        }
    }

    package func notificationMessageIDs(
        accountID: AccountID?, after: MessageID?, limit: Int = 256
    ) throws -> [MessageID] {
        guard limit > 0 else { return [] }
        var predicates = ["m.is_deleted = 0"]
        var arguments: [String?] = []
        if let after {
            predicates.append("m.id > ?")
            arguments.append(after.rawValue)
        }
        if let accountID {
            predicates.append("""
                (m.account_id = ?
                 OR (m.account_id IS NULL
                     AND EXISTS (SELECT 1 FROM mailbox_messages mm
                                 WHERE mm.message_id = m.id AND mm.account_id = ?)
                     AND NOT EXISTS (SELECT 1 FROM mailbox_messages other
                                     WHERE other.message_id = m.id AND other.account_id <> ?))
                 OR (m.account_id IS NULL AND t.account_id = ?
                     AND NOT EXISTS (SELECT 1 FROM mailbox_messages mm WHERE mm.message_id = m.id)))
                """)
            arguments += Array(repeating: accountID.rawValue, count: 4)
        }
        arguments.append(String(min(limit, 256)))
        return try fetchRows("""
            SELECT m.id FROM messages m
            \(accountID == nil ? "" : "LEFT JOIN threads t ON t.id = m.thread_id")
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY m.id LIMIT ?
            """, arguments).map { MessageID($0["id"]) }
    }

    /// Notification resolver ownership without the legacy full-message fallback.
    package func notificationMessageAccountID(_ messageID: MessageID) throws -> AccountID? {
        if let owner: String = try fetchRows(
            "SELECT account_id FROM mailbox_messages WHERE message_id = ? LIMIT 1", [messageID.rawValue]
        ).first?["account_id"] { return AccountID(owner) }
        let owner: String? = try fetchRows("""
            SELECT t.account_id FROM messages m JOIN threads t ON t.id = m.thread_id
            WHERE m.id = ? LIMIT 1
            """, [messageID.rawValue]).first?["account_id"]
        return owner.map { AccountID($0) }
    }

    public func smartInboxClassificationCache() throws -> [MessageID: SmartInboxClassificationCacheRecord] {
        let rows = try fetchRows("SELECT * FROM smart_inbox_classification_cache ORDER BY message_id")
        return Dictionary(uniqueKeysWithValues: try rows.map { row in
            guard let category = SmartCategory(rawValue: row["category"]) else {
                throw PlainpostError.validationFailed("Smart Inbox cache category is invalid.")
            }
            let record = SmartInboxClassificationCacheRecord(
                messageID: MessageID(row["message_id"]),
                sourceFingerprint: row["source_fingerprint"],
                category: category,
                priority: SmartPriority(rawValue: row["priority"]) ?? .normal,
                requiresAction: row["requires_action"],
                confidence: row["confidence"],
                labelMatches: try decodeSmartInboxLabelMatches(row["label_matches_json"]),
                catalogFingerprint: row["catalog_fingerprint"],
                providerID: row["provider_id"],
                modelID: row["model_id"],
                classifiedAt: Date(timeIntervalSince1970: row["classified_at"])
            )
            return (record.messageID, record)
        })
    }

    public func cachedTranslation(
        messageID: MessageID,
        targetLanguageID: String
    ) throws -> CachedMessageTranslation? {
        guard let row = try fetchRows(
            """
            SELECT message_id, target_language_id, source_fingerprint, provider_id, model_id,
                contract_version, body_kind, translated_body, created_at, updated_at
            FROM message_translations
            WHERE message_id = ? AND target_language_id = ?
            """,
            [messageID.rawValue, targetLanguageID]
        ).first else {
            return nil
        }
        guard let bodyKind = EmailBodyKind(rawValue: row["body_kind"]) else {
            throw PlainpostError.validationFailed("Message translation cache body kind is invalid.")
        }
        return CachedMessageTranslation(
            messageID: MessageID(row["message_id"]),
            targetLanguageID: row["target_language_id"],
            sourceFingerprint: row["source_fingerprint"],
            providerID: row["provider_id"],
            modelID: row["model_id"],
            contractVersion: row["contract_version"],
            bodyKind: bodyKind,
            translatedBody: row["translated_body"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    public func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String
    ) throws -> MailTranslationCacheSaveResult {
        try compareAndSaveCachedTranslation(
            translation, expectedSourceFingerprint: expectedSourceFingerprint,
            expectedDirectSourceGeneration: nil
        )
    }

    public func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String,
        expectedDirectSourceGeneration: Int64
    ) throws -> MailTranslationCacheSaveResult {
        try compareAndSaveCachedTranslation(
            translation, expectedSourceFingerprint: expectedSourceFingerprint,
            expectedDirectSourceGeneration: Optional(expectedDirectSourceGeneration)
        )
    }

    private func compareAndSaveCachedTranslation(
        _ translation: CachedMessageTranslation,
        expectedSourceFingerprint: String,
        expectedDirectSourceGeneration: Int64?
    ) throws -> MailTranslationCacheSaveResult {
        guard translation.sourceFingerprint == expectedSourceFingerprint else {
            return .sourceChanged
        }
        do {
            return try databasePool.write { database in
                if let expectedDirectSourceGeneration {
                    let ownership = try Self.messageRelationOwnership(
                        messageID: translation.messageID.rawValue,
                        explicitAccountID: nil,
                        database: database
                    )
                    guard ownership.kind == .account, let accountID = ownership.owner else {
                        throw NodeMailModeStoreError.generationConflict
                    }
                    try Self.requireDirectSource(
                        accountID: AccountID(accountID),
                        generation: expectedDirectSourceGeneration,
                        database: database
                    )
                }
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT body_text, body_html, is_deleted
                        FROM messages
                        WHERE id = ?
                        """,
                    arguments: [translation.messageID.rawValue]
                ) else {
                    return .sourceChanged
                }
                let plainBody: String = row["body_text"]
                let htmlBody: String? = row["body_html"]
                let isDeleted: Bool = row["is_deleted"]
                guard !isDeleted,
                      MailTranslationFingerprint.source(
                          messageID: translation.messageID,
                          plainBody: plainBody,
                          htmlBody: htmlBody
                      ) == expectedSourceFingerprint
                else {
                    return .sourceChanged
                }

                try database.execute(
                    sql: """
                        INSERT INTO message_translations (
                            message_id, target_language_id, source_fingerprint, provider_id, model_id,
                            contract_version, body_kind, translated_body, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(message_id, target_language_id) DO UPDATE SET
                            source_fingerprint = excluded.source_fingerprint,
                            provider_id = excluded.provider_id,
                            model_id = excluded.model_id,
                            contract_version = excluded.contract_version,
                            body_kind = excluded.body_kind,
                            translated_body = excluded.translated_body,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        translation.messageID.rawValue,
                        translation.targetLanguageID,
                        translation.sourceFingerprint,
                        translation.providerID,
                        translation.modelID,
                        translation.contractVersion,
                        translation.bodyKind.rawValue,
                        translation.translatedBody,
                        translation.createdAt.timeIntervalSince1970,
                        translation.updatedAt.timeIntervalSince1970,
                    ]
                )
                return .saved
            }
        } catch let error as NodeMailModeStoreError {
            throw error
        } catch {
            throw databaseError(error)
        }
    }

    public func smartInboxBatchProfile(
        providerID: String,
        modelID: String,
        classifierDiscriminator: String
    ) throws -> SmartInboxBatchProfile? {
        guard let row = try fetchRows(
            """
            SELECT provider_id, model_id, classifier_discriminator, max_message_count,
                max_prompt_characters, memory_ceiling_bytes, benchmarked_at
            FROM smart_inbox_batch_profiles
            WHERE provider_id = ? AND model_id = ? AND classifier_discriminator = ?
            """,
            [providerID, modelID, classifierDiscriminator]
        ).first else { return nil }
        let memoryCeilingBytes: Int64? = row["memory_ceiling_bytes"]
        return SmartInboxBatchProfile(
            providerID: row["provider_id"],
            modelID: row["model_id"],
            classifierDiscriminator: row["classifier_discriminator"],
            maxMessageCount: row["max_message_count"],
            maxPromptCharacters: row["max_prompt_characters"],
            memoryCeilingBytes: memoryCeilingBytes.map(UInt64.init),
            benchmarkedAt: Date(timeIntervalSince1970: row["benchmarked_at"])
        )
    }

    public func saveSmartInboxBatchProfile(_ profile: SmartInboxBatchProfile) throws {
        guard profile.maxMessageCount > 0, profile.maxPromptCharacters > 0 else {
            throw PlainpostError.validationFailed("Smart Inbox batch profile limits must be positive.")
        }
        guard profile.memoryCeilingBytes.map({ $0 <= UInt64(Int64.max) }) ?? true else {
            throw PlainpostError.validationFailed("Smart Inbox batch profile memory ceiling is too large.")
        }
        try databasePool.write { database in
            try Self.createSmartInboxBatchProfilesTable(database)
            try database.execute(
                sql: """
                    INSERT INTO smart_inbox_batch_profiles (
                        provider_id, model_id, classifier_discriminator, max_message_count,
                        max_prompt_characters, memory_ceiling_bytes, benchmarked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider_id, model_id, classifier_discriminator) DO UPDATE SET
                        max_message_count = excluded.max_message_count,
                        max_prompt_characters = excluded.max_prompt_characters,
                        memory_ceiling_bytes = excluded.memory_ceiling_bytes,
                        benchmarked_at = excluded.benchmarked_at
                    """,
                arguments: [
                    profile.providerID,
                    profile.modelID,
                    profile.classifierDiscriminator,
                    profile.maxMessageCount,
                    profile.maxPromptCharacters,
                    profile.memoryCeilingBytes.map(Int64.init),
                    profile.benchmarkedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    private static func createSmartInboxBatchProfilesTable(_ database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS smart_inbox_batch_profiles (
                provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                classifier_discriminator TEXT NOT NULL,
                max_message_count INTEGER NOT NULL CHECK (max_message_count > 0),
                max_prompt_characters INTEGER NOT NULL CHECK (max_prompt_characters > 0),
                memory_ceiling_bytes INTEGER,
                benchmarked_at REAL NOT NULL,
                PRIMARY KEY (provider_id, model_id, classifier_discriminator)
            );
            """)
    }

    private struct LegacyMailLabelVariant {
        let title: String
        let count: Int
    }

    private static func backfillLegacyMailLabels(_ database: Database) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, labels_json
                FROM messages
                WHERE labels_json <> '' AND labels_json <> '[]'
                ORDER BY id
                """
        )
        var variantCounts: [String: [String: Int]] = [:]
        var messageRelationships: [String: Set<String>] = [:]

        for row in rows {
            let messageID: String = row["id"]
            let labelsJSON: String = row["labels_json"]
            let labels = try JSONDecoder().decode([String].self, from: Data(labelsJSON.utf8))
            for rawTitle in labels {
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedTitle = normalizeMailLabelTitle(title)
                guard !normalizedTitle.isEmpty else { continue }
                variantCounts[normalizedTitle, default: [:]][title, default: 0] += 1
                messageRelationships[messageID, default: []].insert(normalizedTitle)
            }
        }

        let now = Date().timeIntervalSince1970
        var definitionsByNormalizedTitle: [String: (id: String, title: String)] = [:]
        for normalizedTitle in variantCounts.keys.sorted() {
            let variants = variantCounts[normalizedTitle, default: [:]]
                .map { LegacyMailLabelVariant(title: $0.key, count: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return lhs.title < rhs.title
                }
            guard let chosen = variants.first else { continue }
            let labelID = legacyMailLabelID(normalizedTitle: normalizedTitle)
            definitionsByNormalizedTitle[normalizedTitle] = (labelID, chosen.title)
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO mail_labels (
                        id, title, normalized_title, description, smart_inbox_enabled,
                        scope_account_id, created_at, updated_at
                    ) VALUES (?, ?, ?, '', 0, NULL, ?, ?)
                    """,
                arguments: [labelID, chosen.title, normalizedTitle, now, now]
            )

            let resultData = try JSONSerialization.data(
                withJSONObject: [
                    "chosenTitle": chosen.title,
                    "discardedVariants": variants.dropFirst().map(\.title),
                    "normalizedTitle": normalizedTitle,
                ],
                options: [.sortedKeys]
            )
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO audit_entries (
                        id, actor_id, action, target_type, target_id, result, occurred_at
                    ) VALUES (?, 'migration-v27', 'mail_label.legacy_backfill',
                        'mail_label', ?, ?, ?)
                    """,
                arguments: [
                    "aud-v27-\(legacyMailLabelDigest(normalizedTitle))",
                    labelID,
                    String(decoding: resultData, as: UTF8.self),
                    now,
                ]
            )
        }

        for messageID in messageRelationships.keys.sorted() {
            let definitions = messageRelationships[messageID, default: []]
                .compactMap { definitionsByNormalizedTitle[$0] }
                .sorted { lhs, rhs in
                    let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return lhs.id < rhs.id
                }
            for definition in definitions {
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO message_label_assignments (
                            message_id, label_id, source_kind, source_id, created_at
                        ) VALUES (?, ?, 'user', '', ?)
                        """,
                    arguments: [messageID, definition.id, now]
                )
            }
            let titles = definitions.map(\.title)
            try database.execute(
                sql: "UPDATE messages SET labels_json = ? WHERE id = ?",
                arguments: [labelsJSON(titles), messageID]
            )
            if try database.tableExists("mail_search_documents") {
                try Self.refreshSearchProjectionIfIndexable(
                    messageID: MessageID(messageID),
                    database: database
                )
            }
        }
    }

    private static func normalizeMailLabelTitle(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    private static func legacyMailLabelDigest(_ normalizedTitle: String) -> String {
        SHA256.hash(data: Data(normalizedTitle.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func legacyMailLabelID(normalizedTitle: String) -> String {
        "legacy-label-\(legacyMailLabelDigest(normalizedTitle))"
    }

    public func messageSummary(id: MessageID) throws -> MessageSummary? {
        try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html,
                smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, rfc_message_id,
                in_reply_to, references_json, reply_to_email, to_emails, cc_emails
            FROM messages WHERE id = ?
            """,
            [id.rawValue]
        ).first.map(decodeMessage)
    }

    /// The people one account has mailed with, newest first: the sender of each received
    /// message and the To and Cc recipients of each sent one, where mail from any of
    /// `ownAddresses` counts as sent. Reads the account's newest `scanLimit` messages that
    /// aren't deleted or in a junk folder. Addresses compare ignoring case, own addresses
    /// never appear, and an address keeps the newest name any scanned message gives it.
    /// Legacy rows without an account belong to their thread's account.
    public func recentCorrespondents(
        accountID: AccountID,
        ownAddresses: Set<String>,
        scanLimit: Int = 2000,
        limit: Int = 200
    ) throws -> [Correspondent] {
        let scanLimit = String(max(0, scanLimit))
        let rows = try fetchRows(
            Self.recentCorrespondentsSQL,
            [accountID.rawValue, scanLimit, accountID.rawValue, scanLimit, scanLimit]
        )
        var collector = Correspondent.Collector(ownAddresses: ownAddresses)
        for row in rows {
            let mailboxPath: String = row["mailbox_path"]
            guard !Self.isJunkMailboxPath(mailboxPath) else { continue }
            let toEmails: String = row["to_emails"]
            let ccEmails: String = row["cc_emails"]
            let sentAt: Double? = row["sent_at"]
            collector.note(
                from: row["from_email"],
                name: row["from_display_name"],
                recipients: (toEmails.split(separator: "\n") + ccEmails.split(separator: "\n")).map(String.init),
                sentAt: sentAt.map(Date.init(timeIntervalSince1970:))
            )
        }
        return collector.correspondents(limit: limit)
    }

    /// The account's newest rows are read in two index-ordered branches, each stopping at the
    /// scan limit: rows the account owns (`messages_account_sent_at`), and legacy rows without
    /// an account that belong to one of the account's threads. The merged rows keep the newest
    /// `scanLimit`. A single `COALESCE(m.account_id, t.account_id)` filter can't use an index,
    /// so it walked every message in the store.
    static let recentCorrespondentsSQL = """
        SELECT from_email, from_display_name, to_emails, cc_emails, sent_at, mailbox_path
        FROM (
            SELECT * FROM (
                SELECT m.from_email, m.from_display_name, m.to_emails, m.cc_emails, m.sent_at, m.mailbox_path
                FROM messages m
                WHERE m.account_id = ? AND m.is_deleted = 0
                ORDER BY m.sent_at DESC
                LIMIT ?
            )
            UNION ALL
            SELECT * FROM (
                SELECT m.from_email, m.from_display_name, m.to_emails, m.cc_emails, m.sent_at, m.mailbox_path
                FROM messages m
                JOIN threads t ON t.id = m.thread_id
                WHERE m.account_id IS NULL AND t.account_id = ? AND m.is_deleted = 0
                ORDER BY m.sent_at DESC
                LIMIT ?
            )
        )
        ORDER BY sent_at DESC
        LIMIT ?
        """

    /// Whether a folder's last path component names it junk ("Junk", "[Gmail]/Spam").
    private static func isJunkMailboxPath(_ path: String) -> Bool {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path
        return ["junk", "spam", "junk e-mail", "junk email", "bulk mail"].contains(name.lowercased())
    }

    /// The message's image parts that its HTML can show inline, within the resolver's limits.
    public func inlineImageParts(messageID: MessageID) throws -> [InlineImagePart] {
        do {
            return try databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT filename, mime_type, content_id, payload
                        FROM incoming_message_attachments
                        WHERE message_id = ? AND lower(mime_type) LIKE 'image/%' AND byte_count <= ?
                        ORDER BY ordinal, part_path
                        """,
                    arguments: [messageID.rawValue, InlineImageResolver.maximumImageBytes]
                ).map { row in
                    InlineImagePart(
                        contentID: row["content_id"], filename: row["filename"],
                        mimeType: row["mime_type"], data: row["payload"]
                    )
                }
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func incomingMessageAttachments(
        messageID: MessageID
    ) throws -> [IncomingMessageAttachmentPayload] {
        do {
            return try databasePool.read { database in
                let metadataRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT part_path, ordinal, filename, mime_type, byte_count, sha256,
                            length(payload) AS payload_byte_count, content_id
                        FROM incoming_message_attachments
                        WHERE message_id = ?
                        ORDER BY ordinal, part_path
                        """,
                    arguments: [messageID.rawValue]
                )
                guard metadataRows.count <=
                    IncomingMessageAttachmentPayload.maximumAttachmentCount
                else {
                    throw PlainpostError.validationFailed(
                        "Stored incoming attachment collection is invalid."
                    )
                }

                var aggregateByteCount = 0
                var partPaths = Set<String>()
                for (expectedOrdinal, row) in metadataRows.enumerated() {
                    let partPath: String = row["part_path"]
                    let ordinal: Int = row["ordinal"]
                    let filename: String = row["filename"]
                    let mimeType: String? = row["mime_type"]
                    let byteCount: Int = row["byte_count"]
                    let sha256: String = row["sha256"]
                    let payloadByteCount: Int = row["payload_byte_count"]
                    let (nextAggregate, overflow) =
                        aggregateByteCount.addingReportingOverflow(byteCount)
                    guard ordinal == expectedOrdinal,
                          partPaths.insert(partPath).inserted,
                          Self.validStoredIncomingAttachmentMetadata(
                              partPath: partPath,
                              filename: filename,
                              mimeType: mimeType,
                              byteCount: byteCount,
                              sha256: sha256
                          ),
                          byteCount >= 0,
                          byteCount <=
                            IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment,
                          payloadByteCount == byteCount,
                          !overflow,
                          nextAggregate <=
                            IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes
                    else {
                        throw PlainpostError.validationFailed(
                            "Stored incoming attachment collection is invalid."
                        )
                    }
                    aggregateByteCount = nextAggregate
                }

                let payloadRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT payload
                        FROM incoming_message_attachments
                        WHERE message_id = ?
                        ORDER BY ordinal, part_path
                        """,
                    arguments: [messageID.rawValue]
                )
                guard payloadRows.count == metadataRows.count else {
                    throw PlainpostError.validationFailed(
                        "Stored incoming attachment collection changed during read."
                    )
                }
                return try zip(metadataRows, payloadRows).map { metadataRow, payloadRow in
                    let partPath: String = metadataRow["part_path"]
                    let filename: String = metadataRow["filename"]
                    let mimeType: String? = metadataRow["mime_type"]
                    let data: Data = payloadRow["payload"]
                    let payload = IncomingMessageAttachmentPayload(
                        partPath: partPath,
                        filename: filename,
                        mimeType: mimeType,
                        data: data,
                        contentID: metadataRow["content_id"]
                    )
                    let byteCount: Int = metadataRow["byte_count"]
                    let sha256: String = metadataRow["sha256"]
                    guard payload.byteCount == byteCount,
                          payload.sha256 == sha256,
                          payload.partPath == partPath,
                          payload.filename == filename,
                          payload.mimeType == mimeType,
                          Self.validIncomingAttachment(payload)
                    else {
                        throw PlainpostError.validationFailed(
                            "Stored incoming attachment payload is invalid."
                        )
                    }
                    return payload
                }
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func incomingMessageClaimsAttachments(messageID: MessageID) throws -> Bool {
        do {
            return try databasePool.read { database in
                guard try database.tableExists("mail_search_documents") else {
                    return false
                }
                return try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT has_attachments
                        FROM mail_search_documents
                        WHERE message_id = ?
                        """,
                    arguments: [messageID.rawValue]
                ) ?? false
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func incomingMessageAttachmentMetadata(
        messageID: MessageID
    ) throws -> [SQLiteIncomingAttachmentMetadata] {
        do {
            return try databasePool.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT part_path, ordinal, filename, mime_type, byte_count, sha256,
                            length(payload) AS payload_byte_count
                        FROM incoming_message_attachments
                        WHERE message_id = ?
                        ORDER BY ordinal, part_path
                        """,
                    arguments: [messageID.rawValue]
                )
                guard rows.count <= IncomingMessageAttachmentPayload.maximumAttachmentCount else {
                    throw PlainpostError.validationFailed(
                        "Stored incoming attachment collection is invalid."
                    )
                }
                var aggregate = 0
                var partPaths = Set<String>()
                return try rows.enumerated().map { expectedOrdinal, row in
                    let partPath: String = row["part_path"]
                    let ordinal: Int = row["ordinal"]
                    let filename: String = row["filename"]
                    let mimeType: String? = row["mime_type"]
                    let byteCount: Int = row["byte_count"]
                    let sha256: String = row["sha256"]
                    let payloadByteCount: Int = row["payload_byte_count"]
                    let (nextAggregate, overflow) = aggregate.addingReportingOverflow(byteCount)
                    guard ordinal == expectedOrdinal,
                          partPaths.insert(partPath).inserted,
                          Self.validStoredIncomingAttachmentMetadata(
                              partPath: partPath,
                              filename: filename,
                              mimeType: mimeType,
                              byteCount: byteCount,
                              sha256: sha256
                          ),
                          payloadByteCount == byteCount,
                          !overflow,
                          nextAggregate <=
                            IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes else {
                        throw PlainpostError.validationFailed(
                            "Stored incoming attachment collection is invalid."
                        )
                    }
                    aggregate = nextAggregate
                    return SQLiteIncomingAttachmentMetadata(
                        partPath: partPath,
                        filename: filename,
                        mimeType: mimeType,
                        byteCount: byteCount,
                        sha256: sha256
                    )
                }
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func incomingMessageAttachmentChunk(
        messageID: MessageID,
        partPath: String,
        offset: Int,
        length: Int
    ) throws -> SQLiteIncomingAttachmentChunk? {
        guard offset >= 0,
              offset <= IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment,
              (1 ... 512 * 1_024).contains(length),
              let metadata = try incomingMessageAttachmentMetadata(messageID: messageID)
                .first(where: { $0.partPath == partPath }),
              offset <= metadata.byteCount else {
            return nil
        }
        do {
            return try databasePool.read { database in
                guard let data = try Data.fetchOne(
                    database,
                    sql: """
                        SELECT substr(payload, ?, ?)
                        FROM incoming_message_attachments
                        WHERE message_id = ? AND part_path = ?
                        """,
                    arguments: [offset + 1, length, messageID.rawValue, partPath]
                ) else {
                    return nil
                }
                let (end, overflow) = offset.addingReportingOverflow(data.count)
                guard data.count <= length,
                      !overflow,
                      end <= metadata.byteCount else {
                    throw PlainpostError.validationFailed(
                        "Stored incoming attachment chunk is invalid."
                    )
                }
                return SQLiteIncomingAttachmentChunk(
                    metadata: metadata,
                    offset: offset,
                    data: data
                )
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func publishHydratedIncomingAttachments(
        expectedMembership: MailboxMessageMembership,
        attachments: [IncomingMessageAttachmentPayload]
    ) throws -> Bool {
        guard !attachments.isEmpty,
              attachments.count <= IncomingMessageAttachmentPayload.maximumAttachmentCount,
              Set(attachments.map(\.partPath)).count == attachments.count,
              attachments.allSatisfy(Self.validIncomingAttachment),
              Self.validIncomingAttachmentAggregate(attachments) else {
            throw PlainpostError.validationFailed(
                "Hydrated incoming attachment payloads are invalid."
            )
        }
        do {
            return try databasePool.write { database in
                let identityMatches = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM mailbox_messages
                            WHERE account_id = ?
                              AND mailbox_path = ?
                              AND uid_validity = ?
                              AND uid = ?
                              AND message_id = ?
                        )
                        """,
                    arguments: [
                        expectedMembership.accountID.rawValue,
                        expectedMembership.mailboxPath,
                        expectedMembership.uidValidity,
                        expectedMembership.uid,
                        expectedMembership.messageID.rawValue
                    ]
                ) ?? false
                guard identityMatches else { return false }

                let existingCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM incoming_message_attachments
                        WHERE message_id = ?
                        """,
                    arguments: [expectedMembership.messageID.rawValue]
                ) ?? 0
                guard existingCount == 0 else { return true }

                for (ordinal, attachment) in attachments.enumerated() {
                    try database.execute(
                        sql: """
                            INSERT INTO incoming_message_attachments (
                                message_id, part_path, ordinal, filename, mime_type,
                                byte_count, sha256, payload, content_id
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            expectedMembership.messageID.rawValue,
                            attachment.partPath,
                            ordinal,
                            attachment.filename,
                            attachment.mimeType,
                            attachment.byteCount,
                            attachment.sha256,
                            attachment.data,
                            attachment.contentID
                        ]
                    )
                }
                return true
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func messageSummaries(ids: [MessageID]) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html,
                smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, rfc_message_id,
                in_reply_to, references_json, reply_to_email, to_emails, cc_emails
            FROM messages
            WHERE id IN (\(placeholders))
            ORDER BY COALESCE(sent_at, 0) ASC, id ASC
            """,
            ids.map(\.rawValue)
        ).map(decodeMessage)
    }

    public func messageSummaries(threadID: ThreadID) throws -> [MessageSummary] {
        try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html,
                smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, rfc_message_id,
                in_reply_to, references_json, reply_to_email, to_emails, cc_emails
            FROM messages
            WHERE thread_id = ? AND is_deleted = 0
            ORDER BY COALESCE(sent_at, 0) ASC, id ASC
            """,
            [threadID.rawValue]
        ).map(decodeMessage)
    }

    public func messageSummaries(threadID: ThreadID, accountID: AccountID) throws -> [MessageSummary] {
        try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html,
                smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, rfc_message_id,
                in_reply_to, references_json, reply_to_email, to_emails, cc_emails
            FROM messages
            WHERE thread_id = ? AND account_id = ? AND is_deleted = 0
            ORDER BY COALESCE(sent_at, 0) ASC, id ASC
            """,
            [threadID.rawValue, accountID.rawValue]
        ).map(decodeMessage)
    }

    public func desiredSeenState(messageID: MessageID) throws -> Bool? {
        try databasePool.read { database in
            try desiredSeenState(messageID: messageID, database: database)
        }
    }

    private func desiredSeenState(messageID: MessageID, database: Database) throws -> Bool? {
        try Bool.fetchOne(
            database,
            sql: "SELECT desired_seen FROM message_seen_intents WHERE message_id = ?",
            arguments: [messageID.rawValue]
        )
    }

    private func acknowledgeDesiredSeenIfObserved(
        messageID: MessageID,
        observedSeen: Bool,
        database: Database
    ) throws {
        guard try desiredSeenState(messageID: messageID, database: database) == observedSeen else {
            return
        }
        try database.execute(
            sql: "DELETE FROM message_seen_intents WHERE message_id = ?",
            arguments: [messageID.rawValue]
        )
    }

    public func enqueueMailboxFlagRecoveryIfSuperseded(
        completedInput: PlainpostMailboxFlagInput,
        sourceJobID: String,
        beganWithDurableIntent: Bool
    ) throws -> PlainpostDurableJob? {
        let now = Date()
        let recoveryJob: PlainpostDurableJob? = try databasePool.write { database in
            let durableDesiredSeen = try desiredSeenState(
                messageID: completedInput.messageID,
                database: database
            )
            let localSeen = try Bool.fetchOne(
                database,
                sql: "SELECT is_seen FROM messages WHERE id = ?",
                arguments: [completedInput.messageID.rawValue]
            )
            guard let localSeen else {
                throw PlainpostError.notFound("Message not found.")
            }

            let recoveryDesiredSeen: Bool
            if let durableDesiredSeen {
                guard durableDesiredSeen != completedInput.desiredSeen else { return nil }
                recoveryDesiredSeen = durableDesiredSeen
            } else {
                guard beganWithDurableIntent,
                      localSeen != completedInput.desiredSeen else {
                    return nil
                }
                recoveryDesiredSeen = localSeen
            }
            guard let completedAccountID = completedInput.accountID,
                  let mailboxPath = completedInput.mailboxPath,
                  let uidValidity = completedInput.uidValidity,
                  let uid = completedInput.uid else {
                throw PlainpostError.validationFailed("A mailbox flag requires an exact mailbox membership.")
            }

            let recoveryInput = PlainpostMailboxFlagInput(
                messageID: completedInput.messageID,
                accountID: completedAccountID,
                mailboxPath: mailboxPath,
                uidValidity: uidValidity,
                uid: uid,
                desiredSeen: recoveryDesiredSeen,
                expectedDirectSourceGeneration: completedInput.expectedDirectSourceGeneration
            )
            if let generation = completedInput.expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: completedAccountID, generation: generation, allowNodeFallback: true, database: database
                )
            }
            let payload = try JSONEncoder().encode(recoveryInput)
            try database.execute(
                sql: "UPDATE messages SET is_seen = ? WHERE id = ?",
                arguments: [recoveryDesiredSeen ? 1 : 0, completedInput.messageID.rawValue]
            )
            try Self.refreshSearchProjectionIfIndexable(
                messageID: completedInput.messageID,
                database: database
            )
            try database.execute(
                sql: """
                    INSERT INTO message_seen_intents (message_id, desired_seen, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET
                        desired_seen = excluded.desired_seen,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    completedInput.messageID.rawValue,
                    recoveryDesiredSeen ? 1 : 0,
                    now.timeIntervalSince1970,
                ]
            )
            return try enqueueJob(
                PlainpostJobRequest(
                    kind: .mailboxFlag,
                    payloadJSON: String(decoding: payload, as: UTF8.self),
                    priority: 100,
                    idempotencyKey: "mailbox-flag-recovery:\(completedInput.messageID.rawValue):\(recoveryDesiredSeen):after:\(sourceJobID)",
                    replaceTerminalDuplicate: true
                ),
                database: database,
                now: now
            )
        }
        if recoveryJob != nil {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return recoveryJob
    }

    public func messages(inMailboxPath mailboxPath: String, accountID: AccountID? = nil) -> [MessageSummary] {
        let membershipAccountClause = accountID == nil
            ? "" : "AND mm.account_id = ? AND (m.account_id IS NULL OR m.account_id = mm.account_id)"
        let accountValues = accountID.map { [$0.rawValue] } ?? []
        guard let rows = try? fetchRows(
            """
            SELECT DISTINCT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.body_text, m.body_html, m.smart_category,
                m.labels_json, m.is_seen, m.is_flagged, m.mailbox_path, m.is_deleted, m.sent_at,
                m.rfc_message_id, m.in_reply_to, m.references_json, m.reply_to_email,
                m.to_emails, m.cc_emails
            FROM messages m
            JOIN mailbox_messages mm ON mm.message_id = m.id
            WHERE mm.mailbox_path = ? COLLATE NOCASE AND m.is_deleted = 0
            \(membershipAccountClause)
            ORDER BY m.id
            """,
            [mailboxPath] + accountValues
        ) else {
            return []
        }
        if !rows.isEmpty {
            return rows.map(decodeMessage)
        }

        // Pre-membership stores and unit fixtures only persisted messages.mailbox_path.
        // Use that legacy projection solely while no mailbox membership exists at all;
        // once membership data exists, unlinked rows are stale and must stay hidden.
        let hasAnyMembership = ((try? fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")) ?? []).isEmpty == false
        guard !hasAnyMembership else { return [] }
        let legacyAccountClause = accountID == nil ? "" : "AND COALESCE(m.account_id, t.account_id) = ?"
        let legacyRows = try? fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.body_text, m.body_html, m.smart_category,
                m.labels_json, m.is_seen, m.is_flagged, m.mailbox_path, m.is_deleted, m.sent_at,
                m.rfc_message_id, m.in_reply_to, m.references_json, m.reply_to_email,
                m.to_emails, m.cc_emails
            FROM messages m
            LEFT JOIN threads t ON t.id = m.thread_id
            WHERE m.mailbox_path = ? COLLATE NOCASE AND m.is_deleted = 0
            \(legacyAccountClause)
            ORDER BY m.id
            """,
            [mailboxPath] + accountValues
        )
        return legacyRows?.map(decodeMessage) ?? []
    }

    public func mailboxListMessages(inMailboxPath mailboxPath: String) throws -> [MailboxListMessage] {
        try mailboxListMessages(
            inMailboxPath: mailboxPath,
            limit: Int.max,
            query: ""
        )
    }

    public func mailboxListMessageIDs(inMailboxPath mailboxPath: String) throws -> [MessageID] {
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        let ruleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        let rows: [Row]
        if hasAnyMembership {
            rows = try fetchRows(
                """
                SELECT DISTINCT m.id
                FROM messages m
                JOIN mailbox_messages mm ON mm.message_id = m.id
                WHERE mm.mailbox_path = ? COLLATE NOCASE AND m.is_deleted = 0
                \(ruleActionExclusion)
                """,
                [mailboxPath]
            )
        } else {
            let legacyRuleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
                ? """
                  AND NOT EXISTS (
                      SELECT 1 FROM mail_rule_message_actions ra
                      WHERE ra.message_id = messages.id AND ra.action = 'skipInbox'
                  )
                  """
                : ""
            rows = try fetchRows(
                """
                SELECT id
                FROM messages
                WHERE mailbox_path = ? COLLATE NOCASE AND is_deleted = 0
                \(legacyRuleActionExclusion)
                """,
                [mailboxPath]
            )
        }
        return rows.map { MessageID($0["id"] as String) }
    }

    public func mailboxListMessageIDs(
        accountID: AccountID,
        inMailboxPath mailboxPath: String
    ) throws -> [MessageID] {
        let ruleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        let rows = try fetchRows(
            """
            SELECT DISTINCT m.id
            FROM messages m
            JOIN mailbox_messages mm ON mm.message_id = m.id
            WHERE mm.account_id = ?
              AND mm.mailbox_path = ? COLLATE NOCASE
              AND m.is_deleted = 0
              \(ruleActionExclusion)
            ORDER BY m.id
            """,
            [accountID.rawValue, mailboxPath]
        )
        return rows.map { MessageID($0["id"] as String) }
    }

    /// A legacy UID conversation includes every matching Inbox subject, even
    /// when another member has a native thread ID or no thread. Subject matching
    /// still visits account candidates; only matching identities are materialized.
    package func legacyInboxConversationMessageIDs(
        accountID: AccountID,
        normalizedSubject: String
    ) throws -> [MessageID] {
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        let inboxClause = hasAnyMembership
            ? """
              AND EXISTS (
                  SELECT 1 FROM mailbox_messages mm
                  WHERE mm.message_id = m.id AND mm.account_id = m.account_id
                    AND mm.mailbox_path = 'INBOX' COLLATE NOCASE
              )
              """
            : "AND m.mailbox_path = 'INBOX' COLLATE NOCASE"
        return try fetchRows(
            """
            SELECT m.id FROM messages m
            WHERE m.account_id = ? AND m.is_deleted = 0
              AND plainpost_subject_matches(m.subject, ?)
              \(inboxClause)
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
            """,
            [accountID.rawValue, normalizedSubject]
        ).map { MessageID($0["id"] as String) }
    }

    public func mailboxListMessages(
        inMailboxPath mailboxPath: String,
        accountID: AccountID? = nil,
        limit: Int,
        query: String
    ) throws -> [MailboxListMessage] {
        try mailboxListMessages(
            inMailboxPath: mailboxPath, accountFilter: MailboxAccountFilter(accountID), limit: limit, query: query
        )
    }

    public func mailboxListMessages(
        inMailboxPath mailboxPath: String,
        accountFilter: MailboxAccountFilter,
        limit: Int,
        query: String
    ) throws -> [MailboxListMessage] {
        let boundedLimit = max(limit, 1)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        let searchClause = normalizedQuery.isEmpty ? "" : """
            AND (
                m.from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                COALESCE(m.from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.preview LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
            """
        let searchValues = normalizedQuery.isEmpty
            ? []
            : Array(repeating: Self.mailboxSearchPattern(normalizedQuery), count: 4)
        let (membershipAccountClause, accountValues) = accountFilter.sql(column: "mm.account_id")
        let canonicalAccountClause = accountFilter.isAll ? "" : "AND m.account_id = mm.account_id"
        let legacyAccountClause = accountFilter.sql(column: "account_id").clause
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        if hasAnyMembership {
            return try fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.smart_category, m.smart_priority,
                m.smart_requires_action, m.smart_confidence, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.account_id AS owner_account_id
            FROM messages m
            WHERE m.is_deleted = 0
              AND EXISTS (
                  SELECT 1
                  FROM mailbox_messages mm
                  WHERE mm.message_id = m.id
                    AND mm.mailbox_path = ? COLLATE NOCASE
                    \(membershipAccountClause)
                    \(canonicalAccountClause)
              )
            \(ruleActionExclusion)
            \(searchClause)
            ORDER BY m.sent_at DESC, m.id DESC
            LIMIT ?
            """,
                [mailboxPath] + accountValues + searchValues + [String(boundedLimit)]
            ).map(decodeMailboxListMessage)
        }

        let legacySearchClause = normalizedQuery.isEmpty ? "" : """
            AND (
                from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                COALESCE(from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                preview LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
            """
        let legacyRuleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = messages.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        return try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview,
                smart_category, smart_priority, smart_requires_action, smart_confidence,
                labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, account_id AS owner_account_id
            FROM messages
            WHERE mailbox_path = ? COLLATE NOCASE AND is_deleted = 0
            \(legacyAccountClause)
            \(legacyRuleActionExclusion)
            \(legacySearchClause)
            ORDER BY COALESCE(sent_at, 0) DESC, id DESC
            LIMIT ?
            """,
            [mailboxPath] + accountValues + searchValues + [String(boundedLimit)]
        ).map(decodeMailboxListMessage)
    }

    /// One account folder's messages, newest first: the rows
    /// `mailboxListMessages(inMailboxPath:accountID:limit:query: "")` returns. That query walks
    /// every message by date until it has `limit` of the folder's, so a folder holding a few of
    /// a big store's messages (or none) scans the whole store. A folder with fewer than
    /// `sparseFolderFactor` × `limit` memberships is read from them instead, through the
    /// memberships' primary key, and sorted; a fuller folder fills its page early in the scan.
    public func folderListMessages(accountID: AccountID, mailboxPath: String, limit: Int) throws -> [MailboxListMessage] {
        let boundedLimit = max(limit, 1)
        let (product, overflow) = boundedLimit.multipliedReportingOverflow(by: Self.sparseFolderFactor)
        let sparseBound = overflow ? Int.max : product
        let members = try fetchRows(
            Self.folderMembershipCountSQL,
            [accountID.rawValue, mailboxPath, String(sparseBound)]
        ).first.map { $0["member_count"] as Int } ?? 0
        guard members < sparseBound else {
            return try mailboxListMessages(inMailboxPath: mailboxPath, accountID: accountID, limit: boundedLimit, query: "")
        }
        if members == 0 {
            // No membership anywhere means a store from before memberships; its folders
            // come from the messages' own paths.
            let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
            return hasAnyMembership
                ? []
                : try mailboxListMessages(inMailboxPath: mailboxPath, accountID: accountID, limit: boundedLimit, query: "")
        }
        let isInbox = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
        return try fetchRows(
            isInbox ? Self.sparseInboxListSQL : Self.sparseFolderListSQL,
            [accountID.rawValue, mailboxPath, accountID.rawValue, String(boundedLimit)]
        ).map(decodeMailboxListMessage)
    }

    static let sparseFolderFactor = 20

    static let folderMembershipCountSQL = """
        SELECT COUNT(*) AS member_count FROM (
            SELECT 1 FROM mailbox_messages
            WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
            LIMIT ?
        )
        """

    static let sparseFolderListSQL = sparseFolderListSQL(excludingSkippedInbox: false)
    static let sparseInboxListSQL = sparseFolderListSQL(excludingSkippedInbox: true)

    /// A folder's messages from its memberships. CROSS JOIN keeps the memberships as the
    /// outer loop, so the planner never swaps back to the date scan.
    private static func sparseFolderListSQL(excludingSkippedInbox: Bool) -> String {
        let ruleActionExclusion = excludingSkippedInbox
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        return """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.smart_category, m.smart_priority,
                m.smart_requires_action, m.smart_confidence, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.account_id AS owner_account_id
            FROM (
                SELECT DISTINCT message_id FROM mailbox_messages
                WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
            ) folder
            CROSS JOIN messages m ON m.id = folder.message_id
            WHERE m.is_deleted = 0 AND m.account_id = ?
            \(ruleActionExclusion)
            ORDER BY m.sent_at DESC, m.id DESC
            LIMIT ?
            """
    }

    /// A Sent row belongs to the account whose configured Sent mailbox owns
    /// its membership. Matching a path alone can cross accounts or display a
    /// local copy after that account has moved to Node ownership.
    public func sentMailboxListMessages(
        accountID: AccountID? = nil,
        limit: Int,
        query: String
    ) throws -> [MailboxListMessage] {
        try sentMailboxListMessages(accountFilter: MailboxAccountFilter(accountID), limit: limit, query: query)
    }

    public func sentMailboxListMessages(
        accountFilter: MailboxAccountFilter,
        limit: Int,
        query: String
    ) throws -> [MailboxListMessage] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (accountClause, accountValues) = accountFilter.sql(column: "a.id")
        let searchClause = normalizedQuery.isEmpty ? "" : """
            AND (m.from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 COALESCE(m.from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 m.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 m.preview LIKE ? ESCAPE '\\' COLLATE NOCASE)
            """
        let searchValues = normalizedQuery.isEmpty
            ? [] : Array(repeating: Self.mailboxSearchPattern(normalizedQuery), count: 4)
        let arguments = accountValues + searchValues + [String(max(limit, 1))]
        return try fetchRows(
            """
            SELECT DISTINCT m.id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.smart_category, m.smart_priority,
                m.smart_requires_action, m.smart_confidence, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, a.id AS owner_account_id
            FROM accounts a
            JOIN messages m ON m.account_id = a.id
            JOIN mailbox_messages mm ON mm.message_id = m.id
                AND mm.account_id = a.id
                AND mm.mailbox_path = a.sent_mailbox COLLATE NOCASE
            LEFT JOIN account_mail_sources source ON source.account_id = a.id
            WHERE m.is_deleted = 0 AND (source.kind IS NULL OR source.kind = 'direct')
              AND NOT EXISTS (
                  SELECT 1 FROM direct_send_intents intent
                  WHERE intent.account_id = a.id
                    AND m.rfc_message_id = '<' || intent.draft_id || '@plainpost.local>'
                    AND intent.state <> 'sent'
                    AND NOT EXISTS (
                        SELECT 1 FROM mailbox_messages remote
                        WHERE remote.message_id = m.id AND remote.account_id = a.id
                          AND remote.mailbox_path = a.sent_mailbox COLLATE NOCASE
                          AND remote.uid_validity > 0 AND remote.uid > 0
                    )
              )
              \(accountClause)
              \(searchClause)
            ORDER BY m.sent_at DESC, m.id DESC
            LIMIT ?
            """,
            arguments
        ).map(decodeMailboxListMessage)
    }

    public func sentMailboxListMessageCount(accountID: AccountID? = nil, query: String) throws -> Int {
        try sentMailboxListMessageCount(accountFilter: MailboxAccountFilter(accountID), query: query)
    }

    public func sentMailboxListMessageCount(accountFilter: MailboxAccountFilter, query: String) throws -> Int {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (accountClause, accountValues) = accountFilter.sql(column: "a.id")
        let searchClause = normalizedQuery.isEmpty ? "" : """
            AND (m.from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 COALESCE(m.from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 m.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                 m.preview LIKE ? ESCAPE '\\' COLLATE NOCASE)
            """
        let searchValues = normalizedQuery.isEmpty
            ? [] : Array(repeating: Self.mailboxSearchPattern(normalizedQuery), count: 4)
        let row = try fetchRows(
            """
            SELECT COUNT(DISTINCT m.id) AS message_count
            FROM accounts a
            JOIN messages m ON m.account_id = a.id
            JOIN mailbox_messages mm ON mm.message_id = m.id
                AND mm.account_id = a.id
                AND mm.mailbox_path = a.sent_mailbox COLLATE NOCASE
            LEFT JOIN account_mail_sources source ON source.account_id = a.id
            WHERE m.is_deleted = 0 AND (source.kind IS NULL OR source.kind = 'direct')
              AND NOT EXISTS (
                  SELECT 1 FROM direct_send_intents intent
                  WHERE intent.account_id = a.id
                    AND m.rfc_message_id = '<' || intent.draft_id || '@plainpost.local>'
                    AND intent.state <> 'sent'
                    AND NOT EXISTS (
                        SELECT 1 FROM mailbox_messages remote
                        WHERE remote.message_id = m.id AND remote.account_id = a.id
                          AND remote.mailbox_path = a.sent_mailbox COLLATE NOCASE
                          AND remote.uid_validity > 0 AND remote.uid > 0
                    )
              )
              \(accountClause)
              \(searchClause)
            """,
            accountValues + searchValues
        ).first
        return row?["message_count"] ?? 0
    }

    public func mailboxListMessageCount(
        inMailboxPath mailboxPath: String,
        accountID: AccountID? = nil,
        query: String
    ) throws -> Int {
        try mailboxListMessageCount(inMailboxPath: mailboxPath, accountFilter: MailboxAccountFilter(accountID), query: query)
    }

    public func mailboxListMessageCount(
        inMailboxPath mailboxPath: String,
        accountFilter: MailboxAccountFilter,
        query: String
    ) throws -> Int {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        let searchClause = normalizedQuery.isEmpty ? "" : """
            AND (
                m.from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                COALESCE(m.from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.preview LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
            """
        let searchValues = normalizedQuery.isEmpty
            ? []
            : Array(repeating: Self.mailboxSearchPattern(normalizedQuery), count: 4)
        let (membershipAccountClause, accountValues) = accountFilter.sql(column: "mm.account_id")
        let canonicalAccountClause = accountFilter.isAll ? "" : "AND m.account_id = mm.account_id"
        let legacyAccountClause = accountFilter.sql(column: "account_id").clause
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        let row: Row?
        if hasAnyMembership {
            row = try fetchRows(
                """
                SELECT COUNT(DISTINCT m.id) AS message_count
                FROM messages m
                JOIN mailbox_messages mm ON mm.message_id = m.id
                WHERE mm.mailbox_path = ? COLLATE NOCASE AND m.is_deleted = 0
                \(membershipAccountClause)
                \(canonicalAccountClause)
                \(ruleActionExclusion)
                \(searchClause)
                """,
                [mailboxPath] + accountValues + searchValues
            ).first
        } else {
            let legacySearchClause = normalizedQuery.isEmpty ? "" : """
                AND (
                    from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    COALESCE(from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    preview LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                """
            let legacyRuleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
                ? """
                  AND NOT EXISTS (
                      SELECT 1 FROM mail_rule_message_actions ra
                      WHERE ra.message_id = messages.id AND ra.action = 'skipInbox'
                  )
                  """
                : ""
            row = try fetchRows(
                """
                SELECT COUNT(*) AS message_count
                FROM messages
                WHERE mailbox_path = ? COLLATE NOCASE AND is_deleted = 0
                \(legacyAccountClause)
                \(legacyRuleActionExclusion)
                \(legacySearchClause)
                """,
                [mailboxPath] + accountValues + searchValues
            ).first
        }
        return row?["message_count"] ?? 0
    }

    public func mailboxUnreadConversationCounts(
        inMailboxPath mailboxPath: String,
        accountID: AccountID? = nil,
        query: String
    ) throws -> MailboxUnreadConversationCounts {
        try mailboxUnreadConversationCounts(
            inMailboxPath: mailboxPath, accountFilter: MailboxAccountFilter(accountID), query: query
        )
    }

    public func mailboxUnreadConversationCounts(
        inMailboxPath mailboxPath: String,
        accountFilter: MailboxAccountFilter,
        query: String
    ) throws -> MailboxUnreadConversationCounts {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleActionExclusion = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            ? """
              AND NOT EXISTS (
                  SELECT 1 FROM mail_rule_message_actions ra
                  WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
              )
              """
            : ""
        let searchClause = normalizedQuery.isEmpty ? "" : """
            AND (
                m.from_email LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                COALESCE(m.from_display_name, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.subject LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                m.preview LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
            """
        let searchValues = normalizedQuery.isEmpty
            ? []
            : Array(repeating: Self.mailboxSearchPattern(normalizedQuery), count: 4)
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        let mailboxClause: String
        let accountValues: [String]
        if hasAnyMembership {
            let membership = accountFilter.sql(column: "mm.account_id")
            accountValues = membership.values
            mailboxClause = """
                AND EXISTS (
                    SELECT 1
                    FROM mailbox_messages mm
                    WHERE mm.message_id = m.id
                      AND mm.mailbox_path = ? COLLATE NOCASE
                      \(membership.clause)
                      \(accountFilter.isAll ? "" : "AND m.account_id = mm.account_id")
                )
                """
        } else {
            let legacy = accountFilter.sql(column: "m.account_id")
            accountValues = legacy.values
            mailboxClause = "AND m.mailbox_path = ? COLLATE NOCASE \(legacy.clause)"
        }
        let row = try fetchRows(
            """
            WITH candidates AS (
                SELECT
                    CASE
                        WHEN m.thread_id IS NULL THEN 'message_' || m.id
                        WHEN m.thread_id LIKE 'thr_uid_%'
                            THEN 'legacy_subject_' || plainpost_normalized_subject(m.subject)
                        ELSE m.thread_id
                    END AS conversation_key,
                    m.id,
                    m.smart_category,
                    m.is_seen,
                    m.sent_at
                FROM messages m
                WHERE m.is_deleted = 0
                \(mailboxClause)
                \(ruleActionExclusion)
                \(searchClause)
            ), ranked AS (
                SELECT
                    smart_category,
                    MAX(CASE WHEN is_seen = 0 THEN 1 ELSE 0 END)
                        OVER (PARTITION BY conversation_key) AS is_unread,
                    ROW_NUMBER() OVER (
                        PARTITION BY conversation_key
                        ORDER BY sent_at DESC, id DESC
                    ) AS recency_rank
                FROM candidates
            )
            SELECT
                COUNT(*) AS total_count,
                COALESCE(SUM(CASE WHEN smart_category = ? THEN 1 ELSE 0 END), 0)
                    AS personal_count,
                COALESCE(SUM(CASE WHEN smart_category = ? THEN 1 ELSE 0 END), 0)
                    AS notification_count,
                COALESCE(SUM(CASE WHEN smart_category = ? THEN 1 ELSE 0 END), 0)
                    AS newsletter_count
            FROM ranked
            WHERE recency_rank = 1 AND is_unread = 1
            """,
            [mailboxPath] + accountValues + searchValues + [
                SmartCategory.personal.rawValue,
                SmartCategory.notification.rawValue,
                SmartCategory.newsletter.rawValue,
            ]
        ).first
        return MailboxUnreadConversationCounts(
            total: row?["total_count"] ?? 0,
            personal: row?["personal_count"] ?? 0,
            notifications: row?["notification_count"] ?? 0,
            newsletters: row?["newsletter_count"] ?? 0
        )
    }

    /// Unread, non-deleted messages per mailbox path for one account, read through
    /// `mailbox_messages` membership. Every path the account has mail in is a key, so a
    /// folder of read mail maps to 0; this is also the only folder list a Node mirror
    /// account has, since the mirror writes memberships but no `mailboxes` rows. Paths
    /// group case-insensitively, and the inbox leaves out messages a rule kept out of it,
    /// as the inbox list does. Before any membership exists, legacy rows group by their
    /// own `mailbox_path`, owned by their account or else their thread's account (as
    /// `messages(inMailboxPath:accountID:)` resolves them).
    public func folderUnreadCounts(accountID: AccountID) throws -> [String: Int] {
        let hasAnyMembership = !(try fetchRows("SELECT 1 FROM mailbox_messages LIMIT 1;")).isEmpty
        let rows: [Row]
        if hasAnyMembership {
            rows = try fetchRows(
                """
                SELECT mm.mailbox_path AS path,
                    COUNT(DISTINCT CASE
                        WHEN m.is_seen = 0 AND m.is_deleted = 0
                            AND NOT (
                                mm.mailbox_path = 'INBOX' COLLATE NOCASE
                                AND EXISTS (
                                    SELECT 1 FROM mail_rule_message_actions ra
                                    WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
                                )
                            )
                        THEN m.id
                    END) AS unread
                FROM mailbox_messages mm
                JOIN messages m ON m.id = mm.message_id AND m.account_id = mm.account_id
                WHERE mm.account_id = ?
                GROUP BY mm.mailbox_path COLLATE NOCASE
                """,
                [accountID.rawValue]
            )
        } else {
            rows = try fetchRows(
                """
                SELECT m.mailbox_path AS path,
                    COUNT(CASE
                        WHEN m.is_seen = 0 AND m.is_deleted = 0
                            AND NOT (
                                m.mailbox_path = 'INBOX' COLLATE NOCASE
                                AND EXISTS (
                                    SELECT 1 FROM mail_rule_message_actions ra
                                    WHERE ra.message_id = m.id AND ra.action = 'skipInbox'
                                )
                            )
                        THEN 1
                    END) AS unread
                FROM messages m
                LEFT JOIN threads t ON t.id = m.thread_id
                WHERE COALESCE(m.account_id, t.account_id) = ?
                GROUP BY m.mailbox_path COLLATE NOCASE
                """,
                [accountID.rawValue]
            )
        }
        return Dictionary(
            rows.map { row -> (String, Int) in (row["path"], row["unread"]) },
            uniquingKeysWith: +
        )
    }

    public func smartInboxListMessages() throws -> [MailboxListMessage] {
        try fetchRows(
            """
            SELECT id, thread_id, from_email, from_display_name, subject, preview,
                smart_category, smart_priority, smart_requires_action, smart_confidence,
                labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at
            FROM messages
            WHERE is_deleted = 0
            ORDER BY id
            """
        ).map(decodeMailboxListMessage)
    }

    /// Fetches only the device projection window in its final, deterministic
    /// order. This is intentionally not built by fetching all messages then
    /// resolving account identity one card at a time.
    public func smartInboxClassificationInputs(
        scope: PlainpostSmartInboxRunScope
    ) throws -> [SmartInboxClassificationInput] {
        onSmartInboxClassificationInputRead?()
        return try databasePool.read { database in
            try smartInboxClassificationInputs(database: database, scope: scope)
        }
    }

    private func smartInboxClassificationInputs(
        database: Database,
        scope: PlainpostSmartInboxRunScope
    ) throws -> [SmartInboxClassificationInput] {
        let accountExpression = Self.smartInboxMessageAccountExpression(messageAlias: "m")
        var sql = """
            SELECT m.id, m.account_id, m.thread_id, m.from_email, m.from_display_name,
                m.subject, m.preview, m.body_text, m.to_emails, m.cc_emails,
                m.smart_category, m.smart_priority, m.smart_requires_action,
                m.smart_confidence, m.labels_json, m.is_seen, m.is_flagged, m.mailbox_path,
                m.is_deleted, m.sent_at, \(accountExpression) AS resolved_account_id
            FROM messages m
            WHERE m.is_deleted = 0
            """
        var arguments = StatementArguments()
        if case .account(let accountID) = scope {
            sql += " AND \(accountExpression) = ?"
            arguments += [accountID.rawValue]
        }
        if let since = try Self.smartInboxMode(in: database).newMailSince {
            sql += " AND (m.sent_at IS NULL OR m.sent_at >= ?)"
            arguments += [since.timeIntervalSince1970]
        }
        sql += " ORDER BY m.id"
        return try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
            let toEmails: String = row["to_emails"]
            let ccEmails: String = row["cc_emails"]
            let rawAccountID: String? = row["resolved_account_id"]
            return SmartInboxClassificationInput(
                message: decodeMailboxListMessage(row),
                accountID: AccountID(rawAccountID ?? ""),
                recipients: (toEmails + "\n" + ccEmails)
                    .split(separator: "\n")
                    .map { EmailAddress(String($0)) },
                bodyExcerpt: String((row["body_text"] as String).prefix(3_000))
            )
        }
    }

    public func hasEligibleIncrementalSmartInboxWork(
        for input: PlainpostAIOperationInput
    ) throws -> Bool {
        let durableInput = try resolvedSmartInboxInput(input)
        let classifierDiscriminator = durableInput.resolvedSmartInboxClassifierIdentity.discriminator
        let classificationInputs = try smartInboxClassificationInputs(
            scope: durableInput.smartInboxRunRequest.scope
        )
        let catalogFingerprint = try smartInboxLabelCatalogSnapshot().fingerprint
        return try !eligibleIncrementalSmartInboxInputs(
            classificationInputs,
            classifierDiscriminator: classifierDiscriminator,
            catalogFingerprint: catalogFingerprint
        ).isEmpty
    }

    package func eligibleIncrementalSmartInboxInputs(
        _ classificationInputs: [SmartInboxClassificationInput],
        classifierDiscriminator: String,
        catalogFingerprint: String
    ) throws -> [SmartInboxClassificationInput] {
        try databasePool.read { database in
            try eligibleIncrementalSmartInboxInputs(
                database: database,
                classificationInputs: classificationInputs,
                classifierDiscriminator: classifierDiscriminator,
                catalogFingerprint: catalogFingerprint
            )
        }
    }

    private func eligibleIncrementalSmartInboxInputs(
        database: Database,
        classificationInputs: [SmartInboxClassificationInput],
        classifierDiscriminator: String,
        catalogFingerprint: String
    ) throws -> [SmartInboxClassificationInput] {
        let cache = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
            database,
            sql: "SELECT message_id, source_fingerprint FROM smart_inbox_classification_cache"
        ).map { row in
            (MessageID(row["message_id"]), row["source_fingerprint"] as String)
        })
        let suppressions = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
            database,
            sql: """
                SELECT message_id, source_fingerprint, catalog_fingerprint,
                    classifier_discriminator
                FROM smart_inbox_failure_suppressions
                """
        ).map { row in
            (
                MessageID(row["message_id"]),
                (
                    sourceFingerprint: row["source_fingerprint"] as String,
                    catalogFingerprint: row["catalog_fingerprint"] as String,
                    classifierDiscriminator: row["classifier_discriminator"] as String
                )
            )
        })
        return classificationInputs.filter { classificationInput in
            let messageID = classificationInput.message.id
            let sourceFingerprint = SmartInboxClassificationFingerprint.message(
                classificationInput,
                classifierDiscriminator: classifierDiscriminator
            )
            guard cache[messageID] != sourceFingerprint else { return false }
            guard let suppression = suppressions[messageID] else { return true }
            return suppression.sourceFingerprint != sourceFingerprint
                || suppression.catalogFingerprint != catalogFingerprint
                || suppression.classifierDiscriminator != classifierDiscriminator
        }
    }

    public func smartInboxLabelCatalogSnapshot() throws -> MailLabelCatalogSnapshot {
        let labels = try mailLabels(effectiveFor: nil).sorted { $0.id < $1.id }
        let fingerprint = try Self.smartInboxCatalogFingerprint(labels)
        return MailLabelCatalogSnapshot(
            labels: labels,
            fingerprint: fingerprint,
            createdAt: Date()
        )
    }

    static func smartInboxCatalogFingerprint(
        _ labels: [MailLabelDefinition]
    ) throws -> String {
        let entries = labels.map {
            SmartInboxCatalogFingerprintEntry(
                id: $0.id,
                scope: $0.scope.accountID.map { "account:\($0.rawValue)" } ?? "allAccounts",
                title: $0.title,
                description: $0.description,
                isSmartInboxEnabled: $0.isSmartInboxEnabled
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonicalData = try encoder.encode(entries)
        let fingerprint = SHA256.hash(data: canonicalData)
            .map { String(format: "%02x", $0) }
            .joined()
        return fingerprint
    }

    public func smartInboxLabelCatalogSnapshot(jobID: String) throws -> MailLabelCatalogSnapshot? {
        try databasePool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT catalog_fingerprint, labels_json, created_at
                    FROM smart_inbox_label_catalog_snapshots
                    WHERE job_id = ?
                    """,
                arguments: [jobID]
            ) else {
                return nil
            }
            let labelsJSON: String = row["labels_json"]
            return MailLabelCatalogSnapshot(
                labels: try JSONDecoder().decode(
                    [MailLabelDefinition].self,
                    from: Data(labelsJSON.utf8)
                ),
                fingerprint: row["catalog_fingerprint"],
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    public func activeMessageCount() throws -> Int {
        try databasePool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM messages WHERE is_deleted = 0") ?? 0
        }
    }

    /// Counts active messages owned by one account. Legacy rows without an
    /// explicit owner follow the same exclusive membership/thread fallback as
    /// `messages(accountID:)`; ambiguous and unowned rows are excluded.
    public func activeMessageCount(accountID: AccountID) throws -> Int {
        try databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM messages m
                    LEFT JOIN threads t ON t.id = m.thread_id
                    WHERE m.is_deleted = 0
                      AND (
                        m.account_id = ?
                        OR (m.account_id IS NULL
                            AND EXISTS (SELECT 1 FROM mailbox_messages mm
                                        WHERE mm.message_id = m.id AND mm.account_id = ?)
                            AND NOT EXISTS (SELECT 1 FROM mailbox_messages other
                                            WHERE other.message_id = m.id AND other.account_id <> ?))
                        OR (m.account_id IS NULL AND t.account_id = ?
                            AND NOT EXISTS (SELECT 1 FROM mailbox_messages mm
                                            WHERE mm.message_id = m.id))
                      )
                    """,
                arguments: [
                    accountID.rawValue,
                    accountID.rawValue,
                    accountID.rawValue,
                    accountID.rawValue,
                ]
            ) ?? 0
        }
    }

    public var threads: [MailThread] {
        (try? readThreads()) ?? []
    }

    public func thread(id: ThreadID) throws -> MailThread? {
        try fetchRows(
            "SELECT id, account_id, subject_normalized, participant_emails FROM threads WHERE id = ?",
            [id.rawValue]
        ).first.map(decodeThread)
    }

    public func aiConversationReference(
        messageID: MessageID?,
        threadID: ThreadID?,
        accountID: AccountID
    ) throws -> PlainpostAIConversationReference {
        try databasePool.read { database in
            _ = try Self.payloadAccountOwnership(
                accountID,
                database: database,
                resolutionMode: .runtime
            )

            if let messageID {
                _ = try Self.messageRelationOwnership(
                    messageID: messageID.rawValue,
                    explicitAccountID: accountID,
                    database: database
                )
                let storedThreadID = try String.fetchOne(
                    database,
                    sql: "SELECT thread_id FROM messages WHERE id = ?",
                    arguments: [messageID.rawValue]
                )
                if let threadID, threadID.rawValue != storedThreadID {
                    let isCanonicalUnthreadedIdentity = storedThreadID == nil
                        && MailSearchStableIdentity.isMessageBackedThreadIdentity(
                            threadID.rawValue,
                            accountID: accountID,
                            messageID: messageID
                        )
                    guard isCanonicalUnthreadedIdentity else {
                        throw PlainpostError.validationFailed(
                            "The requested thread does not match the message conversation."
                        )
                    }
                }
                if let storedThreadID {
                    let threadExists = try Bool.fetchOne(
                        database,
                        sql: "SELECT EXISTS(SELECT 1 FROM threads WHERE id = ?)",
                        arguments: [storedThreadID]
                    ) == true
                    let threadOwner = try String.fetchOne(
                        database,
                        sql: "SELECT account_id FROM threads WHERE id = ?",
                        arguments: [storedThreadID]
                    )
                    if threadExists {
                        guard threadOwner == accountID.rawValue else {
                            throw PlainpostError.validationFailed(
                                "The message thread does not belong to the explicit account context."
                            )
                        }
                        return PlainpostAIConversationReference(
                            recordID: storedThreadID,
                            kind: .thread
                        )
                    }
                }
                return PlainpostAIConversationReference(recordID: messageID.rawValue, kind: .message)
            }

            guard let threadID else {
                throw PlainpostError.validationFailed("An AI conversation reference is required.")
            }
            let threadOwner = try String.fetchOne(
                database,
                sql: "SELECT account_id FROM threads WHERE id = ?",
                arguments: [threadID.rawValue]
            )
            guard threadOwner == accountID.rawValue else {
                throw PlainpostError.validationFailed(
                    "The thread does not belong to the explicit account context."
                )
            }
            return PlainpostAIConversationReference(recordID: threadID.rawValue, kind: .thread)
        }
    }

    public var auditEntries: [AuditEntry] {
        combinedAuditEntries()
    }

    public func recentAuditEntries(limit: Int) throws -> [AuditEntry] {
        guard limit > 0 else { return [] }
        return Array(combinedAuditEntries().suffix(limit).reversed())
    }

    public func recentAuditEntries(
        limit: Int,
        accountID: AccountID,
        sourceGeneration: Int64
    ) throws -> [AuditEntry] {
        try recentTimestampedAuditEntries(
            limit: limit, accountID: accountID, sourceGeneration: sourceGeneration
        ).map(\.entry)
    }

    /// The account-scoped audit query with each entry's own time, for the export.
    public func recentTimestampedAuditEntries(
        limit: Int,
        accountID: AccountID,
        sourceGeneration: Int64
    ) throws -> [TimestampedAuditEntry] {
        // The file log retains ownership while AuditEntry intentionally does not.
        // Filter both stores before applying the display limit.
        let persisted = try auditLog.timestampedEntries(ownerAccountID: accountID.rawValue)
        return try databasePool.read { database in
            try Self.requireDirectSource(
                accountID: accountID, generation: sourceGeneration, database: database
            )
            guard limit > 0 else { return [] }
            let pending = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, actor_id, action, target_type, target_id, result, occurred_at
                    FROM audit_entries
                    WHERE ownership_kind = 'account' AND owner_account_id = ?
                    ORDER BY rowid
                    """,
                arguments: [accountID.rawValue]
            ).map { row in
                TimestampedAuditEntry(
                    entry: decodeAuditEntry(row),
                    occurredAt: (row["occurred_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
            var seen = Set<String>()
            let owned = (persisted + pending).filter { seen.insert($0.entry.id).inserted }
            return Array(owned.suffix(limit).reversed())
        }
    }

    public func recordSearchMaintenanceFailure() throws {
        try databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO audit_entries (
                        id, actor_id, action, target_type, target_id, result, occurred_at,
                        owner_account_id, ownership_kind
                    ) VALUES (?, 'plainpost-runtime', 'search.maintenance.failed',
                              'mail_search', 'maintenance', 'failed', ?, NULL, 'global')
                    """,
                arguments: [
                    "aud_\(UUID().uuidString.lowercased())",
                    Date().timeIntervalSince1970,
                ]
            )
        }
        try flushAuditOutbox()
    }

    public func saveDurableOperationArtifact(
        _ artifact: DurableOperationArtifact,
        forJobID jobID: String
    ) throws {
        try databasePool.write { database in
            guard let jobRow = try Row.fetchOne(
                database,
                sql: "SELECT kind, payload_json, owner_account_id, ownership_kind FROM durable_jobs WHERE id = ?",
                arguments: [jobID]
            ),
            let jobKind = PlainpostOperationKind(rawValue: jobRow["kind"] as String) else {
                throw PlainpostError.validationFailed("The artifact job is missing or invalid.")
            }
            let descriptor = try Self.requiredJobOwnership(jobID: jobID, database: database)
            if jobKind == .aiOperation || jobKind == .searchRebuild {
                let input = try JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((jobRow["payload_json"] as String).utf8)
                )
                if let expected = input.expectedDirectSourceGeneration {
                    guard let accountID = input.accountID else {
                        throw NodeMailModeStoreError.generationConflict
                    }
                    try Self.requireDirectSource(accountID: accountID, generation: expected, database: database)
                }
            }
            try Self.validateArtifact(
                artifact,
                forJobID: jobID,
                jobKind: jobKind,
                jobPayloadJSON: jobRow["payload_json"],
                descriptor: descriptor,
                database: database
            )
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO durable_operation_artifacts (
                        id, kind, record_id, payload_json, created_at, owner_account_id,
                        ownership_kind
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    artifact.id, artifact.kind, artifact.recordID, artifact.payloadJSON,
                    artifact.createdAt.timeIntervalSince1970, descriptor.owner,
                    descriptor.kind.rawValue,
                ]
            )
        }
    }

    private static func validateArtifact(
        _ artifact: DurableOperationArtifact,
        forJobID jobID: String,
        jobKind: PlainpostOperationKind,
        jobPayloadJSON: String,
        descriptor: OwnershipClassification,
        database: Database
    ) throws {
        switch jobKind {
        case .inboxSync, .historicalSync:
            let input = try JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data(jobPayloadJSON.utf8)
            )
            let result = try JSONDecoder().decode(
                PlainpostInboxSyncResult.self,
                from: Data(artifact.payloadJSON.utf8)
            )
            guard artifact.kind == PlainpostOperationKind.inboxSync.rawValue,
                  artifact.recordID == input.accountID.rawValue,
                  result.accountID == input.accountID,
                  result.jobID == jobID else {
                throw PlainpostError.validationFailed("The inbox sync artifact does not match its persisted job.")
            }
        case .aiOperation, .searchRebuild:
            let input = try JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data(jobPayloadJSON.utf8)
            )
            guard (jobKind == .searchRebuild) == (input.operation == .rebuildIndex),
                  artifact.kind == input.operation.rawValue,
                  artifact.recordID == input.recordID,
                  let payload = try? JSONDecoder().decode(
                      PlainpostLocalAIArtifactPayload.self,
                      from: Data(artifact.payloadJSON.utf8)
                  ),
                  aiArtifactPayload(payload, matches: input) else {
                throw PlainpostError.validationFailed("The AI artifact does not match its persisted job.")
            }
            let resolved = try operationOwnership(
                kind: jobKind,
                payloadJSON: jobPayloadJSON,
                database: database,
                resolutionMode: .migration(explicit: descriptor)
            )
            guard resolved.kind == descriptor.kind, resolved.owner == descriptor.owner else {
                throw PlainpostError.validationFailed("The AI artifact job ownership is inconsistent.")
            }
            if input.operation == .draftReply {
                let expectedDraftID = "drf_ai_\(jobID)"
                let expectedSourceThreadID: ThreadID?
                switch input.conversationReferenceKind {
                case .thread:
                    expectedSourceThreadID = ThreadID(input.recordID)
                case .message:
                    let sourceThreadID: String? = try String.fetchOne(
                        database,
                        sql: "SELECT thread_id FROM messages WHERE id = ?",
                        arguments: [input.recordID]
                    )
                    expectedSourceThreadID = sourceThreadID.map { ThreadID($0) }
                case nil:
                    expectedSourceThreadID = nil
                }
                guard descriptor.kind == .account,
                      let owner = descriptor.owner,
                      payload.resultRecordID == expectedDraftID,
                      let draftJSON = try String.fetchOne(
                          database,
                          sql: "SELECT payload_json FROM drafts WHERE id = ?",
                          arguments: [expectedDraftID]
                      ),
                      let draft = try? JSONDecoder().decode(
                          Draft.self,
                          from: Data(draftJSON.utf8)
                      ),
                      draft.id.rawValue == expectedDraftID,
                      draft.accountID.rawValue == owner,
                      draft.createdBy == "local-operation-agent",
                      draft.aiGenerated,
                      draft.sourceThreadID == expectedSourceThreadID else {
                    throw PlainpostError.validationFailed("The reply artifact does not reference the draft produced by its job.")
                }
                try database.execute(
                    sql: "INSERT OR REPLACE INTO durable_job_produced_drafts (job_id, draft_id) VALUES (?, ?)",
                    arguments: [jobID, expectedDraftID]
                )
            }
        case .approvedDelivery, .denySend, .mailboxFlag, .mailboxArchive:
            throw PlainpostError.validationFailed("This operation kind does not produce a durable artifact.")
        }
    }

    public func saveTypedAIOperationArtifact(
        _ artifact: DurableOperationArtifact,
        input: PlainpostAIOperationInput
    ) throws {
        guard artifact.kind == input.operation.rawValue,
              artifact.recordID == input.recordID,
              let payload = try? JSONDecoder().decode(
                  PlainpostLocalAIArtifactPayload.self,
                  from: Data(artifact.payloadJSON.utf8)
              ),
              Self.aiArtifactPayload(payload, matches: input) else {
            throw PlainpostError.validationFailed("The typed AI artifact does not match its operation input.")
        }
        try databasePool.write { database in
            if let expected = input.expectedDirectSourceGeneration {
                guard let accountID = input.accountID else {
                    throw NodeMailModeStoreError.generationConflict
                }
                try Self.requireDirectSource(accountID: accountID, generation: expected, database: database)
            }
            let descriptor = try Self.operationOwnership(
                kind: input.operation == .rebuildIndex ? .searchRebuild : .aiOperation,
                payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                database: database
            )
            if input.operation == .draftReply {
                guard descriptor.kind == .account,
                      let descriptorOwner = descriptor.owner,
                      let resultDraftID = payload.resultRecordID,
                      try String.fetchOne(
                          database,
                          sql: "SELECT owner_account_id FROM drafts WHERE id = ?",
                          arguments: [resultDraftID]
                      ) == descriptorOwner else {
                    throw PlainpostError.validationFailed("The reply artifact draft does not match its operation owner.")
                }
            }
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO durable_operation_artifacts (
                        id, kind, record_id, payload_json, created_at, owner_account_id,
                        ownership_kind
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    artifact.id, artifact.kind, artifact.recordID, artifact.payloadJSON,
                    artifact.createdAt.timeIntervalSince1970, descriptor.owner,
                    descriptor.kind.rawValue,
                ]
            )
        }
    }

    private static func aiArtifactPayload(
        _ payload: PlainpostLocalAIArtifactPayload,
        matches input: PlainpostAIOperationInput
    ) -> Bool {
        switch input.operation {
        case .summarizeThread, .summarizeMessage, .answerThreadQuestion:
            return payload.text != nil && payload.resultRecordID == input.recordID
        case .translateMessage:
            return payload.resultRecordID == input.recordID
                && payload.translatedBodyKind != nil
                && payload.translatedBody != nil
                && payload.sourceFingerprint != nil
        case .answerMailboxQuestion:
            return payload.text != nil
        case .draftReply:
            return payload.resultRecordID?.isEmpty == false
        case .rewriteDraft:
            return payload.text != nil && payload.resultRecordID == input.recordID
        case .classifyMessage:
            return payload.resultRecordID == input.recordID && payload.category != nil
        case .recategorizeInbox:
            return payload.categorizedMessageCount != nil
                && payload.failedMessageCount != nil
        case .rebuildIndex:
            return payload.indexedMessageCount != nil
        }
    }

    public func durableOperationArtifact(id: String) throws -> DurableOperationArtifact {
        let row = try fetchRows(
            "SELECT id, kind, record_id, payload_json, created_at FROM durable_operation_artifacts WHERE id = ?;",
            [id]
        ).first
        guard let row else {
            throw PlainpostError.notFound("Durable operation artifact not found.")
        }
        return DurableOperationArtifact(
            id: row["id"],
            kind: row["kind"],
            recordID: row["record_id"],
            payloadJSON: row["payload_json"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    public func durableOperationArtifact(id: String, accountID: AccountID) throws -> DurableOperationArtifact {
        let row = try fetchRows(
            """
                SELECT id, kind, record_id, payload_json, created_at
                FROM durable_operation_artifacts
                WHERE id = ? AND ownership_kind = 'account' AND owner_account_id = ?
                """,
            [id, accountID.rawValue]
        ).first
        guard let row else {
            throw PlainpostError.permissionDenied("The operation artifact does not belong to the selected account.")
        }
        return DurableOperationArtifact(
            id: row["id"], kind: row["kind"], recordID: row["record_id"],
            payloadJSON: row["payload_json"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    public func operationAccountID(
        forMessageID messageID: MessageID,
        explicitAccountID: AccountID?
    ) throws -> AccountID {
        try databasePool.read { database in
            let ownership = try Self.messageRelationOwnership(
                messageID: messageID.rawValue,
                explicitAccountID: explicitAccountID,
                database: database
            )
            guard ownership.kind == .account, let owner = ownership.owner else {
                throw PlainpostError.validationFailed("The message requires an explicit account context.")
            }
            return AccountID(owner)
        }
    }

    /// Purges local state explicitly owned by one account after removing its
    /// semantic credential-vault records. Vault state is restored if either
    /// credential removal or the accepted SQLite deletion transaction fails.
    public func deleteAccountData(
        accountID: AccountID,
        credentials: any CredentialVault
    ) async throws {
        try await deleteAccountData(
            accountID: accountID, expectedDirectSourceGeneration: nil, credentials: credentials
        )
    }

    /// Removes a mirrored Sync Node account from this device while its source is still the
    /// Node-backed one the caller read. The Node keeps the account and its mail.
    public func deleteNodeBackedAccountData(
        accountID: AccountID,
        expectedSourceGeneration: Int64,
        credentials: any CredentialVault
    ) async throws {
        let source = try mailSource(accountID: accountID)
        guard source.kind == .nodeBacked, source.generation == expectedSourceGeneration else {
            throw NodeMailModeStoreError.generationConflict
        }
        let permitKey = AccountDeletionPermitKey(
            databaseIdentity: accountDeletionDatabaseIdentity, accountID: accountID.rawValue
        )
        try await Self.accountDeletionCoordinator.withPermit(for: permitKey) { [self] in
            if try hasPendingAccountDeletionIntent(accountID: accountID) {
                try await recoverPendingAccountDeletion(
                    accountID: accountID, credentials: credentials, expectedDirectSourceGeneration: nil
                )
                return
            }
            // The commit checks the source again: one rebound or flipped meanwhile is kept.
            try await performSemanticAccountDeletion(
                accountID: accountID, credentials: credentials,
                expectedDirectSourceGeneration: nil, expectedNodeSourceGeneration: expectedSourceGeneration
            )
        }
    }

    /// iOS deletion is authorized by the exact persisted Direct source that
    /// initiated it. Its intent carries that generation across a restart.
    public func deleteDirectAccountData(
        accountID: AccountID,
        expectedSourceGeneration: Int64,
        credentials: any CredentialVault
    ) async throws {
        try await deleteAccountData(
            accountID: accountID,
            expectedDirectSourceGeneration: expectedSourceGeneration,
            credentials: credentials
        )
    }

    private func deleteAccountData(
        accountID: AccountID,
        expectedDirectSourceGeneration: Int64?,
        credentials: any CredentialVault
    ) async throws {
        let permitKey = AccountDeletionPermitKey(
            databaseIdentity: accountDeletionDatabaseIdentity,
            accountID: accountID.rawValue
        )
        try await Self.accountDeletionCoordinator.withPermit(for: permitKey) { [self] in
            if try hasPendingAccountDeletionIntent(accountID: accountID) {
                if let expectedDirectSourceGeneration {
                    try authorizeExplicitRetryOfLegacyDeletion(
                        accountID: accountID,
                        expectedDirectSourceGeneration: expectedDirectSourceGeneration
                    )
                }
                try await recoverPendingAccountDeletion(
                    accountID: accountID,
                    credentials: credentials,
                    expectedDirectSourceGeneration: expectedDirectSourceGeneration
                )
                return
            }
            try await performSemanticAccountDeletion(
                accountID: accountID,
                credentials: credentials,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration
            )
        }
    }

    private func performSemanticAccountDeletion(
        accountID: AccountID,
        credentials: any CredentialVault,
        expectedDirectSourceGeneration: Int64?,
        expectedNodeSourceGeneration: Int64? = nil
    ) async throws {
        try recoverAuditRedactionJournal()
        let acceptedPlan = try await databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: accountID,
                requiresLiveAccount: true,
                database: database
            )
        }
        let keys = Set(
            [
                CredentialRecordKey(rawValue: "account:\(accountID.rawValue):imap-password"),
                CredentialRecordKey(rawValue: "account:\(accountID.rawValue):smtp-password"),
                CredentialRecordKey(rawValue: "account:\(accountID.rawValue):google-refresh-token"),
                CredentialRecordKey(rawValue: "account:\(accountID.rawValue):microsoft-refresh-token"),
            ]
        ).sorted { $0.rawValue < $1.rawValue }
        var snapshot: [(key: CredentialRecordKey, value: Data?)] = []
        for key in keys {
            snapshot.append((key, try await credentials.load(key)))
        }
        try recordAccountDeletionIntent(
            accountID: accountID, credentialKeys: keys,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration
        )

        do {
            for key in keys {
                try await credentials.remove(key)
            }
        } catch {
            let removalError = error
            do {
                try await Self.restoreCredentials(snapshot, in: credentials)
                try clearAccountDeletionIntent(accountID: accountID)
            } catch {
                throw AccountDeletionCompensationError(
                    operationError: removalError,
                    compensationError: error
                )
            }
            throw removalError
        }
        try accountDeletionFailpoint?(.afterCredentialRemovalBeforeSQLiteCommit)

        do {
            try deleteAccountData(
                acceptedPlan: acceptedPlan,
                requiresLiveAccount: true,
                clearingCredentialIntentFor: accountID,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration,
                expectedNodeSourceGeneration: expectedNodeSourceGeneration
            )
        } catch {
            let deletionError = error
            if let cleanupPending = deletionError as? AuditRedactionCleanupPendingError {
                throw AccountDeletionCleanupPendingError(
                    accountID: accountID,
                    operationError: cleanupPending.operationError
                )
            }
            do {
                try await Self.restoreCredentials(snapshot, in: credentials)
                try clearAccountDeletionIntent(accountID: accountID)
            } catch {
                throw AccountDeletionCompensationError(
                    operationError: deletionError,
                    compensationError: error
                )
            }
            throw deletionError
        }
    }

    public func recoverPendingAccountDeletions(
        credentials: any CredentialVault
    ) async throws {
        let accountIDs = try pendingAccountDeletionIDs()
        for accountID in accountIDs {
            let permitKey = AccountDeletionPermitKey(
                databaseIdentity: accountDeletionDatabaseIdentity,
                accountID: accountID.rawValue
            )
            try await Self.accountDeletionCoordinator.withPermit(for: permitKey) { [self] in
                try await recoverPendingAccountDeletion(
                    accountID: accountID,
                    credentials: credentials
                )
            }
        }
    }

    /// Replays only intents issued by an explicit Direct source. Legacy
    /// unscoped and Node intents never grant iOS access to credential keys.
    public func recoverPendingDirectAccountDeletions(
        credentials: any CredentialVault
    ) async throws {
        let accountIDs = try pendingAccountDeletionIDs()
        for accountID in accountIDs {
            let permitKey = AccountDeletionPermitKey(
                databaseIdentity: accountDeletionDatabaseIdentity,
                accountID: accountID.rawValue
            )
            try await Self.accountDeletionCoordinator.withPermit(for: permitKey) { [self] in
                guard let generation = try pendingDirectDeletionGeneration(accountID: accountID) else {
                    return
                }
                try await recoverPendingAccountDeletion(
                    accountID: accountID, credentials: credentials,
                    expectedDirectSourceGeneration: generation
                )
            }
        }
    }

    private func recoverPendingAccountDeletion(
        accountID: AccountID,
        credentials: any CredentialVault,
        expectedDirectSourceGeneration: Int64? = nil
    ) async throws {
        if let expectedDirectSourceGeneration {
            guard try pendingDirectDeletionGeneration(accountID: accountID) == expectedDirectSourceGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
        }
        guard accounts.contains(where: { $0.id == accountID }) else {
            try clearAccountDeletionIntent(accountID: accountID)
            return
        }
        try recoverAuditRedactionJournal()
        let acceptedPlan = try await databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: accountID,
                requiresLiveAccount: true,
                database: database
            )
        }
        for key in try pendingAccountDeletionCredentialKeys(accountID: accountID) {
            try await credentials.remove(key)
        }
        do {
            try deleteAccountData(
                acceptedPlan: acceptedPlan,
                requiresLiveAccount: true,
                clearingCredentialIntentFor: accountID,
                expectedDirectSourceGeneration: expectedDirectSourceGeneration
            )
        } catch let error as AuditRedactionCleanupPendingError {
            throw AccountDeletionCleanupPendingError(
                accountID: accountID,
                operationError: error.operationError
            )
        }
    }

    /// Internal database-only primitive retained for isolated store tests and
    /// orphan repair. Production callers must use the semantic vault overload.
    func deleteAccountData(accountID: AccountID) throws {
        try deleteAccountData(accountID: accountID, requiresLiveAccount: true)
    }

    func deleteAccountData(accountID: AccountID, requiresLiveAccount: Bool) throws {
        try recoverAuditRedactionJournal()
        let acceptedPlan = try databasePool.read { database in
            try LocalAccountDeletion.makePlan(
                accountID: accountID,
                requiresLiveAccount: requiresLiveAccount,
                database: database
            )
        }
        try deleteAccountData(
            acceptedPlan: acceptedPlan,
            requiresLiveAccount: requiresLiveAccount
        )
    }

    private func deleteAccountData(
        acceptedPlan: LocalAccountDeletion.Plan,
        requiresLiveAccount: Bool,
        clearingCredentialIntentFor accountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        expectedNodeSourceGeneration: Int64? = nil
    ) throws {
        do {
            try auditLog.withRedactionJournal(
                ownerAccountID: acceptedPlan.accountID.rawValue,
                acceptedRecordIDs: Set(acceptedPlan.directDeletion.auditEntryIDs),
                performSQLiteCommit: { journalID in
                    try databasePool.write { database in
                        if let expectedDirectSourceGeneration {
                            try Self.requireDirectSource(
                                accountID: acceptedPlan.accountID,
                                generation: expectedDirectSourceGeneration,
                                database: database
                            )
                        }
                        if let expectedNodeSourceGeneration {
                            try Self.requireNodeBackedSource(
                                accountID: acceptedPlan.accountID,
                                generation: expectedNodeSourceGeneration,
                                database: database
                            )
                        }
                        if requiresLiveAccount {
                            guard try Bool.fetchOne(
                                database,
                                sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
                                arguments: [acceptedPlan.accountID.rawValue]
                            ) == true else {
                                throw PlainpostError.notFound("Account not found.")
                            }
                        }
                        try Self.deleteAccountData(
                            plan: acceptedPlan,
                            database: database
                        )
                        if let accountID {
                            try database.execute(
                                sql: "DELETE FROM account_deletion_intents WHERE account_id = ?",
                                arguments: [accountID.rawValue]
                            )
                        }
                        try database.execute(
                            sql: """
                                INSERT INTO account_deletion_audit_redaction_commits (
                                    journal_id, committed_at
                                ) VALUES (?, ?)
                                """,
                            arguments: [journalID, Date().timeIntervalSince1970]
                        )
                    }
                },
                clearSQLiteCommit: { journalID in
                    try clearAuditRedactionCommit(journalID: journalID)
                }
            )
        } catch let error as AuditRedactionCleanupPendingError {
            postAccountDeletionChangeSignals()
            throw error
        }
        postAccountDeletionChangeSignals()
    }

    private func postAccountDeletionChangeSignals() {
        MailStoreChangeSignal.post(scope: .accounts)
        MailStoreChangeSignal.post(scope: .mailbox)
        MailStoreChangeSignal.post(scope: .operations)
    }

    private func recoverAuditRedactionJournal() throws {
        try auditLog.recoverRedactionJournal(
            isSQLiteCommitted: { journalID in
                try databasePool.read { database in
                    try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM account_deletion_audit_redaction_commits
                                WHERE journal_id = ?
                            )
                            """,
                        arguments: [journalID]
                    ) == true
                }
            },
            clearSQLiteCommit: { journalID in
                try clearAuditRedactionCommit(journalID: journalID)
            }
        )
    }

    private func clearAuditRedactionCommit(journalID: String) throws {
        try databasePool.write { database in
            try database.execute(
                sql: "DELETE FROM account_deletion_audit_redaction_commits WHERE journal_id = ?",
                arguments: [journalID]
            )
        }
    }

    private func recordAccountDeletionIntent(
        accountID: AccountID,
        credentialKeys: [CredentialRecordKey],
        expectedDirectSourceGeneration: Int64?
    ) throws {
        let keyData = try JSONEncoder().encode(credentialKeys.map(\.rawValue))
        try databasePool.write { database in
            if let expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: accountID, generation: expectedDirectSourceGeneration,
                    database: database
                )
            }
            try database.execute(
                sql: """
                    INSERT INTO account_deletion_intents (
                        account_id, credential_record_keys_json, created_at,
                        direct_source_generation
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        credential_record_keys_json = excluded.credential_record_keys_json,
                        direct_source_generation = excluded.direct_source_generation
                    """,
                arguments: [
                    accountID.rawValue,
                    String(decoding: keyData, as: UTF8.self),
                    Date().timeIntervalSince1970,
                    expectedDirectSourceGeneration,
                ]
            )
        }
    }

    /// Nil means an unscoped legacy or Node-owned intent. Automatic iOS
    /// recovery never guesses which source issued an unscoped intent.
    private func pendingDirectDeletionGeneration(accountID: AccountID) throws -> Int64? {
        try databasePool.read { database in
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT source.kind AS source_kind, source.generation AS source_generation,
                           intent.direct_source_generation AS intent_generation
                    FROM account_deletion_intents intent
                    LEFT JOIN account_mail_sources source ON source.account_id = intent.account_id
                    WHERE intent.account_id = ?
                    """,
                arguments: [accountID.rawValue]
            )
            guard let row else { return nil }
            let kind: String? = row["source_kind"]
            if kind == AccountMailSourceKind.nodeBacked.rawValue { return nil }
            let intentGeneration: Int64? = row["intent_generation"]
            guard let intentGeneration else { return nil }
            guard kind == AccountMailSourceKind.direct.rawValue,
                  let sourceGeneration: Int64 = row["source_generation"],
                  sourceGeneration == intentGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
            return intentGeneration
        }
    }

    /// A fresh explicit iOS delete may adopt an old unscoped intent. The
    /// current Direct source and the expected semantic vault keys are checked
    /// in the same write that binds the intent to the caller's generation.
    private func authorizeExplicitRetryOfLegacyDeletion(
        accountID: AccountID,
        expectedDirectSourceGeneration: Int64
    ) throws {
        try databasePool.write { database in
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT direct_source_generation, credential_record_keys_json
                    FROM account_deletion_intents WHERE account_id = ?
                    """,
                arguments: [accountID.rawValue]
            )
            guard let row else { throw NodeMailModeStoreError.generationConflict }
            let existingGeneration: Int64? = row["direct_source_generation"]
            guard existingGeneration == nil else { return }
            try Self.requireDirectSource(
                accountID: accountID,
                generation: expectedDirectSourceGeneration,
                database: database
            )
            let keyJSON: String = row["credential_record_keys_json"]
            let keys = try JSONDecoder().decode([String].self, from: Data(keyJSON.utf8))
            let expectedKeys = Set([
                "account:\(accountID.rawValue):imap-password",
                "account:\(accountID.rawValue):smtp-password",
                "account:\(accountID.rawValue):google-refresh-token",
                "account:\(accountID.rawValue):microsoft-refresh-token",
            ])
            guard keys.count == expectedKeys.count, Set(keys) == expectedKeys else {
                throw PlainpostError.validationFailed(
                    "The pending account deletion has unexpected credential keys."
                )
            }
            try database.execute(
                sql: """
                    UPDATE account_deletion_intents
                    SET direct_source_generation = ?
                    WHERE account_id = ? AND direct_source_generation IS NULL
                    """,
                arguments: [expectedDirectSourceGeneration, accountID.rawValue]
            )
            guard database.changesCount == 1 else {
                throw NodeMailModeStoreError.generationConflict
            }
        }
    }

    private func pendingAccountDeletionIDs() throws -> [AccountID] {
        try databasePool.read { database -> [AccountID] in
            try String.fetchAll(
                database,
                sql: "SELECT account_id FROM account_deletion_intents ORDER BY account_id"
            ).map { AccountID($0) }
        }
    }

    private func hasPendingAccountDeletionIntent(accountID: AccountID) throws -> Bool {
        try databasePool.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM account_deletion_intents WHERE account_id = ?)",
                arguments: [accountID.rawValue]
            ) == true
        }
    }

    private func pendingAccountDeletionCredentialKeys(
        accountID: AccountID
    ) throws -> [CredentialRecordKey] {
        try databasePool.read { database in
            guard let json = try String.fetchOne(
                database,
                sql: """
                    SELECT credential_record_keys_json
                    FROM account_deletion_intents
                    WHERE account_id = ?
                    """,
                arguments: [accountID.rawValue]
            ) else {
                return []
            }
            return try JSONDecoder().decode(
                [String].self,
                from: Data(json.utf8)
            ).map { CredentialRecordKey(rawValue: $0) }
        }
    }

    private func clearAccountDeletionIntent(accountID: AccountID) throws {
        try databasePool.write { database in
            try database.execute(
                sql: "DELETE FROM account_deletion_intents WHERE account_id = ?",
                arguments: [accountID.rawValue]
            )
        }
    }

    private static func restoreCredentials(
        _ snapshot: [(key: CredentialRecordKey, value: Data?)],
        in credentials: any CredentialVault
    ) async throws {
        var firstError: Error?
        for entry in snapshot {
            do {
                if let value = entry.value {
                    try await credentials.store(value, for: entry.key)
                } else {
                    try await credentials.remove(entry.key)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    public func cacheAccounts(_ accounts: [Account]) throws {
        for account in accounts {
            try execute(
                """
                INSERT INTO accounts (
                    id, display_name, email, username, sent_mailbox,
                    imap_host, imap_port, smtp_host, smtp_port
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    email = excluded.email,
                    username = excluded.username,
                    sent_mailbox = excluded.sent_mailbox,
                    imap_host = excluded.imap_host,
                    imap_port = excluded.imap_port,
                    smtp_host = excluded.smtp_host,
                    smtp_port = excluded.smtp_port;
                """,
                [
                    account.id.rawValue,
                    account.displayName,
                    account.email.rawValue,
                    account.username,
                    account.sentMailbox,
                    account.imapHost,
                    String(account.imapPort),
                    account.smtpHost,
                    String(account.smtpPort)
                ]
            )
        }
        MailStoreChangeSignal.post(scope: .accounts)
    }

    public func cacheAccountSetup(account: Account, inbox: Mailbox) throws {
        try cacheAccountSetup(account: account, inbox: inbox, source: nil)
    }

    public func cacheAccountSetup(account: Account, inbox: Mailbox, source: AccountMailSource) throws {
        try cacheAccountSetup(account: account, inbox: inbox, source: source, authentication: nil)
    }

    /// Publishes a verified OAuth account, its Direct source and its auth
    /// method in one SQLite write. Readers can never observe the account as a
    /// password account through the absent-auth-row legacy default.
    public func cacheOAuthAccountSetup(
        account: Account, inbox: Mailbox, source: AccountMailSource,
        authentication: AccountAuthenticationMethod
    ) throws {
        guard authentication != .password else { throw PlainpostError.validationFailed("OAuth account method required.") }
        try cacheAccountSetup(account: account, inbox: inbox, source: source, authentication: authentication)
    }

    private func cacheAccountSetup(
        account: Account, inbox: Mailbox, source: AccountMailSource,
        authentication: AccountAuthenticationMethod?
    ) throws {
        guard source.accountID == account.id, inbox.accountID == account.id,
              source.kind == .direct, source.generation == 1 else {
            throw AccountMailSourceError.invalidSource
        }
        try source.validate()
        guard try nodeModeSchemaStatus() == .available else {
            throw NodeMailModeStoreError.schemaUnavailable
        }
        try cacheAccountSetup(account: account, inbox: inbox, source: Optional(source), authentication: authentication)
    }

    private func cacheAccountSetup(
        account: Account, inbox: Mailbox, source: AccountMailSource?,
        authentication: AccountAuthenticationMethod? = nil
    ) throws {
        try databasePool.write { database in
            if source != nil {
                let exists = try Bool.fetchOne(
                    database, sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
                    arguments: [account.id.rawValue]
                ) ?? false
                guard !exists else { throw AccountMailSourceError.invalidSource }
            }
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, display_name, email, username, sent_mailbox,
                        imap_host, imap_port, smtp_host, smtp_port
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        email = excluded.email,
                        username = excluded.username,
                        sent_mailbox = excluded.sent_mailbox,
                        imap_host = excluded.imap_host,
                        imap_port = excluded.imap_port,
                        smtp_host = excluded.smtp_host,
                        smtp_port = excluded.smtp_port
                    """,
                arguments: [
                    account.id.rawValue,
                    account.displayName,
                    account.email.rawValue,
                    account.username,
                    account.sentMailbox,
                    account.imapHost,
                    String(account.imapPort),
                    account.smtpHost,
                    String(account.smtpPort),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO mailboxes (id, account_id, name, path, special_use)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        name = excluded.name,
                        path = excluded.path,
                        special_use = excluded.special_use
                    """,
                arguments: [
                    inbox.id.rawValue,
                    inbox.accountID.rawValue,
                    inbox.name,
                    inbox.path,
                    inbox.specialUse,
                ]
            )
            if let source {
                try database.execute(
                    sql: """
                        INSERT INTO account_mail_sources (
                            account_id, kind, mode, node_id, logical_mailbox_id,
                            provider_identity, generation, mode_changed_at
                        ) VALUES (?, 'direct', NULL, NULL, NULL, NULL, ?, ?)
                        """,
                    arguments: [source.accountID.rawValue, source.generation, Date().timeIntervalSince1970]
                )
            }
            if let authentication {
                try database.execute(
                    sql: """
                        INSERT INTO account_authentication (account_id, method, state, updated_at)
                        VALUES (?, ?, 'ready', ?)
                        """,
                    arguments: [account.id.rawValue, authentication.rawValue, Date().timeIntervalSince1970]
                )
            }
        }
        MailStoreChangeSignal.post(scope: .accounts)
    }

    public func cacheMailboxes(_ mailboxes: [Mailbox]) throws {
        guard !mailboxes.isEmpty else { return }
        try databasePool.write { database in
            for mailbox in mailboxes {
                var affectedMessageIDs: Set<String> = []
                if let displacedMailbox = try Row.fetchOne(
                    database,
                    sql: "SELECT account_id, path FROM mailboxes WHERE id = ?",
                    arguments: [mailbox.id.rawValue]
                ) {
                    let displacedAccountID: String = displacedMailbox["account_id"]
                    let displacedPath: String = displacedMailbox["path"]
                    affectedMessageIDs.formUnion(try String.fetchAll(
                        database,
                        sql: """
                            SELECT DISTINCT message_id FROM mailbox_messages
                            WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                            """,
                        arguments: [displacedAccountID, displacedPath]
                    ))
                }
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO mailboxes (id, account_id, name, path, special_use)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        mailbox.id.rawValue,
                        mailbox.accountID.rawValue,
                        mailbox.name,
                        mailbox.path,
                        mailbox.specialUse,
                    ]
                )
                affectedMessageIDs.formUnion(try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT message_id FROM mailbox_messages
                        WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                        """,
                    arguments: [mailbox.accountID.rawValue, mailbox.path]
                ))
                for messageID in affectedMessageIDs.sorted() {
                    try Self.refreshSearchProjectionIfIndexable(
                        messageID: MessageID(messageID),
                        database: database
                    )
                }
            }
        }
        MailStoreChangeSignal.post(scope: .accounts)
    }

    public func cacheThreads(_ threads: [MailThread]) throws {
        try databasePool.write { database in
            for thread in threads {
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO threads (id, account_id, subject_normalized, participant_emails)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        thread.id.rawValue,
                        thread.accountID.rawValue,
                        thread.subjectNormalized,
                        thread.participantEmails.map(\.rawValue).joined(separator: "\n"),
                    ]
                )
                let messageIDs = try String.fetchAll(
                    database,
                    sql: "SELECT id FROM messages WHERE thread_id = ? ORDER BY id",
                    arguments: [thread.id.rawValue]
                )
                for messageID in messageIDs {
                    try Self.refreshSearchProjectionIfIndexable(
                        messageID: MessageID(messageID),
                        database: database
                    )
                }
            }
        }
    }

    public func cacheThread(_ thread: MailThread) throws {
        let existing = threads.first { $0.id == thread.id }
        let participants = Array(Set((existing?.participantEmails ?? []) + thread.participantEmails))
            .sorted { $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == .orderedAscending }
        try cacheThreads([MailThread(
            id: thread.id,
            accountID: thread.accountID,
            subjectNormalized: thread.subjectNormalized,
            participantEmails: participants
        )])
    }

    public func accountID(forMessageID messageID: MessageID) -> AccountID? {
        if let row = try? fetchRows(
            "SELECT account_id FROM mailbox_messages WHERE message_id = ? LIMIT 1",
            [messageID.rawValue]
        ).first, let rawValue: String = row["account_id"] {
            return AccountID(rawValue)
        }
        guard let threadID = messages.first(where: { $0.id == messageID })?.threadID else { return nil }
        return threads.first(where: { $0.id == threadID })?.accountID
    }

    public func membership(for messageID: MessageID) throws -> MailboxMessageMembership {
        let row = try fetchRows(
            """
            SELECT account_id, mailbox_path, uid_validity, uid, message_id
            FROM mailbox_messages
            WHERE message_id = ?
            ORDER BY CASE WHEN mailbox_path = 'INBOX' THEN 0 ELSE 1 END, mailbox_path, uid
            LIMIT 1
            """,
            [messageID.rawValue]
        ).first
        guard let row else {
            throw PlainpostError.notFound("Message mailbox membership was not found.")
        }
        return MailboxMessageMembership(
            accountID: AccountID(row["account_id"]),
            mailboxPath: row["mailbox_path"],
            uidValidity: row["uid_validity"],
            uid: row["uid"],
            messageID: MessageID(row["message_id"])
        )
    }

    /// The copy of a message an archive or delete acts on. A message can have
    /// several copies (a self-addressed message in INBOX and Sent), and
    /// `messages.mailbox_path` is only the copy sync committed last, so:
    /// - with `shownIn`, the copy in that mailbox (with `uid`, exactly that
    ///   one), preferring a provider key over a local one; it throws, before
    ///   any server contact, when that mailbox holds no such copy;
    /// - without it, the INBOX copy, else the copy in `messages.mailbox_path`.
    public func actionMembership(
        for messageID: MessageID, shownIn mailboxPath: String? = nil, uid: Int? = nil
    ) throws -> MailboxMessageMembership {
        let row: Row?
        if let mailboxPath {
            let isInbox = mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame
            row = try fetchRows(
                """
                SELECT account_id, mailbox_path, uid_validity, uid, message_id
                FROM mailbox_messages
                WHERE message_id = ? AND \(isInbox ? "mailbox_path = 'INBOX' COLLATE NOCASE" : "mailbox_path = ?")
                  \(uid == nil ? "" : "AND uid = ?")
                ORDER BY CASE WHEN uid_validity = 0 THEN 1 ELSE 0 END, uid
                LIMIT 1
                """,
                [messageID.rawValue] + (isInbox ? [] : [mailboxPath]) + (uid.map { [String($0)] } ?? [])
            ).first
            guard row != nil else {
                throw PlainpostError.validationFailed(
                    "This message is no longer in \(mailboxPath). Refresh, then try again."
                )
            }
        } else {
            row = try fetchRows(
                """
                SELECT mm.account_id, mm.mailbox_path, mm.uid_validity, mm.uid, mm.message_id
                FROM mailbox_messages mm JOIN messages m ON m.id = mm.message_id
                WHERE mm.message_id = ?
                  AND (mm.mailbox_path = 'INBOX' COLLATE NOCASE OR mm.mailbox_path = m.mailbox_path)
                ORDER BY CASE WHEN mm.mailbox_path = 'INBOX' COLLATE NOCASE THEN 0 ELSE 1 END,
                         CASE WHEN mm.uid_validity = 0 THEN 1 ELSE 0 END, mm.uid
                LIMIT 1
                """,
                [messageID.rawValue]
            ).first
            guard row != nil else {
                throw PlainpostError.validationFailed("This message changed. Sync, then try again.")
            }
        }
        let found = row!
        return MailboxMessageMembership(
            accountID: AccountID(found["account_id"]),
            mailboxPath: found["mailbox_path"],
            uidValidity: found["uid_validity"],
            uid: found["uid"],
            messageID: MessageID(found["message_id"])
        )
    }

    /// `actionMembership(for:)` without a shown mailbox.
    public func displayedMembership(for messageID: MessageID) throws -> MailboxMessageMembership {
        try actionMembership(for: messageID)
    }

    /// The other server UIDs of `membership`'s message in the same mailbox and
    /// UIDVALIDITY. Some servers (Purelymail) deliver one message twice: two
    /// UIDs under one Message-ID, shown as one row. An archive or delete of
    /// that row moves every copy.
    public func duplicateCopyUIDs(of membership: MailboxMessageMembership) throws -> [Int] {
        try fetchRows(
            """
            SELECT uid FROM mailbox_messages
            WHERE account_id = ? AND message_id = ? AND mailbox_path = ? AND uid_validity = ?
              AND uid > 0 AND uid <> ?
            ORDER BY uid
            """,
            [
                membership.accountID.rawValue, membership.messageID.rawValue, membership.mailboxPath,
                String(membership.uidValidity), String(membership.uid),
            ]
        ).map { $0["uid"] }
    }

    public func membership(
        for messageID: MessageID,
        accountID: AccountID
    ) throws -> MailboxMessageMembership {
        let rows = try fetchRows(
            """
            SELECT account_id, mailbox_path, uid_validity, uid, message_id
            FROM mailbox_messages
            WHERE message_id = ? AND account_id = ?
            ORDER BY CASE WHEN mailbox_path = 'INBOX' THEN 0 ELSE 1 END, mailbox_path, uid
            """,
            [messageID.rawValue, accountID.rawValue]
        )
        guard !rows.isEmpty else {
            throw PlainpostError.notFound("Message mailbox membership was not found for the explicit account.")
        }
        let identities = Set(rows.map {
            "\($0["mailbox_path"] as String)|\($0["uid_validity"] as Int)|\($0["uid"] as Int)"
        })
        guard identities.count == rows.count else {
            throw PlainpostError.validationFailed("Message mailbox membership is ambiguous for the explicit account.")
        }
        let row = rows[0]
        return MailboxMessageMembership(
            accountID: AccountID(row["account_id"]),
            mailboxPath: row["mailbox_path"],
            uidValidity: row["uid_validity"],
            uid: row["uid"],
            messageID: MessageID(row["message_id"])
        )
    }

    public func membership(
        for messageID: MessageID,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int
    ) throws -> MailboxMessageMembership {
        try databasePool.read { database in
            try Self.exactMailboxFlagMembership(
                PlainpostMailboxFlagInput(
                    messageID: messageID,
                    accountID: accountID,
                    mailboxPath: mailboxPath,
                    uidValidity: uidValidity,
                    uid: uid,
                    desiredSeen: true
                ),
                database: database
            )
        }
    }

    public func cacheMessage(_ message: MessageSummary) throws {
        try cacheMessageReliably(message)
    }

    public func cacheMessageReliably(_ message: MessageSummary) throws {
        try databasePool.write { database in
            let insertedCanonicalMessage = !(try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id = ?)",
                arguments: [message.id.rawValue]
            ) ?? false)
            let values: [String?] = [
                message.id.rawValue, message.threadID?.rawValue, message.from.rawValue,
                message.fromDisplayName, message.subject, message.preview, message.body, message.bodyHTML,
                message.smartCategory.rawValue, labelsJSON(message.labels), message.isSeen ? "1" : "0",
                message.mailboxPath, message.isDeleted ? "1" : "0",
                message.sentAt.map { String($0.timeIntervalSince1970) }, message.rfcMessageID,
                message.inReplyTo, labelsJSON(message.references), message.replyTo?.rawValue,
                message.to.map(\.rawValue).joined(separator: "\n"),
                message.cc.map(\.rawValue).joined(separator: "\n")
            ]
            try database.execute(
                sql: """
                    INSERT INTO messages (id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html, smart_category, labels_json, is_seen, mailbox_path, is_deleted, sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email, to_emails, cc_emails)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        thread_id = excluded.thread_id, from_email = excluded.from_email,
                        from_display_name = excluded.from_display_name, subject = excluded.subject,
                        preview = excluded.preview, body_text = excluded.body_text, body_html = excluded.body_html,
                        smart_category = excluded.smart_category, labels_json = messages.labels_json,
                        is_seen = COALESCE(
                            (SELECT desired_seen FROM message_seen_intents WHERE message_id = excluded.id),
                            excluded.is_seen
                        ), mailbox_path = excluded.mailbox_path,
                        is_deleted = excluded.is_deleted, sent_at = excluded.sent_at,
                        rfc_message_id = excluded.rfc_message_id, in_reply_to = excluded.in_reply_to,
                        references_json = excluded.references_json, reply_to_email = excluded.reply_to_email,
                        to_emails = excluded.to_emails, cc_emails = excluded.cc_emails
                    """,
                arguments: StatementArguments(values)
            )
            if insertedCanonicalMessage {
                try importUserVisibleLabels(
                    message.labels,
                    database: database,
                    messageID: message.id.rawValue,
                    accountID: try messageAccountID(
                        database: database,
                        messageID: message.id.rawValue
                    ),
                    actorID: "mail-ingestion"
                )
            }
            try Self.refreshSearchProjectionIfIndexable(
                messageID: message.id,
                database: database
            )
        }
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message,
            metadata: metadata,
            persistedAttachments: nil,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationEligible
        )
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message, metadata: metadata, persistedAttachments: nil,
            accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
            notificationEligible: notificationDisposition.isEligible,
            notificationDisposition: notificationDisposition,
            notificationConfiguration: notificationConfiguration
        )
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0
    ) throws -> IncomingMessageCommitResult {
        try commitIncomingMessage(
            message,
            metadata: metadata,
            persistedAttachments: nil,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationDisposition.isEligible,
            notificationDisposition: notificationDisposition,
            notificationConfigVersion: notificationConfigVersion,
            notificationProducerGeneration: notificationProducerGeneration
        )
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfiguration: NotificationProducerConfiguration
    ) throws -> IncomingMessageCommitResult {
        let payloadMetadata = attachments.map {
            IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mimeType)
        }
        guard payloadMetadata == metadata.attachments else {
            throw PlainpostError.validationFailed("Incoming attachment metadata and payloads do not match.")
        }
        return try commitIncomingMessage(
            message, metadata: metadata, persistedAttachments: attachments,
            accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
            notificationEligible: notificationDisposition.isEligible,
            notificationDisposition: notificationDisposition,
            notificationConfiguration: notificationConfiguration
        )
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationDisposition: IncomingNotificationDisposition,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0
    ) throws -> IncomingMessageCommitResult {
        let payloadMetadata = attachments.map {
            IncomingMessageAttachmentMetadata(filename: $0.filename, mimeType: $0.mimeType)
        }
        guard payloadMetadata == metadata.attachments else {
            throw PlainpostError.validationFailed("Incoming attachment metadata and payloads do not match.")
        }
        return try commitIncomingMessage(
            message,
            metadata: metadata,
            persistedAttachments: attachments,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationDisposition.isEligible,
            notificationDisposition: notificationDisposition,
            notificationConfigVersion: notificationConfigVersion,
            notificationProducerGeneration: notificationProducerGeneration
        )
    }

    public func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        let payloadMetadata = attachments.map {
            IncomingMessageAttachmentMetadata(
                filename: $0.filename,
                mimeType: $0.mimeType
            )
        }
        guard payloadMetadata == metadata.attachments,
              attachments.count <= IncomingMessageAttachmentPayload.maximumAttachmentCount,
              Set(attachments.map(\.partPath)).count == attachments.count,
              attachments.allSatisfy(Self.validIncomingAttachment),
              Self.validIncomingAttachmentAggregate(attachments)
        else {
            throw PlainpostError.validationFailed(
                "Incoming attachment metadata and payloads do not match."
            )
        }
        return try commitIncomingMessage(
            message,
            metadata: metadata,
            persistedAttachments: attachments,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: uidValidity,
            uid: uid,
            notificationEligible: notificationEligible
        )
    }

    private func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        persistedAttachments: [IncomingMessageAttachmentPayload]?,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool,
        notificationDisposition: IncomingNotificationDisposition = .ineligible,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0,
        notificationConfiguration: NotificationProducerConfiguration? = nil
    ) throws -> IncomingMessageCommitResult {
        do {
            let result = try databasePool.write { database in
                try writeIncomingMessage(
                    message, metadata: metadata, persistedAttachments: persistedAttachments,
                    accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
                    notificationEligible: notificationEligible,
                    notificationDisposition: notificationDisposition,
                    notificationConfigVersion: notificationConfigVersion,
                    notificationProducerGeneration: notificationProducerGeneration,
                    notificationConfiguration: notificationConfiguration,
                    database: database
                )
            }
            MailStoreChangeSignal.post(scope: .mailbox)
            if result.insertedMacNotificationEvent {
                MailStoreChangeSignal.post(scope: .operations)
            }
            return IncomingMessageCommitResult(
                messageID: message.id,
                insertedMembership: result.insertedMembership,
                insertedCanonicalMessage: result.insertedCanonicalMessage
            )
        } catch {
            throw databaseError(error)
        }
    }

    /// The body of `commitIncomingMessage` inside the caller's write
    /// transaction, so the Node mirror can commit every membership of one
    /// message, its link and its membership removals atomically. Posts no
    /// change signal; the caller does.
    func writeIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        persistedAttachments: [IncomingMessageAttachmentPayload]?,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool,
        notificationDisposition: IncomingNotificationDisposition = .ineligible,
        notificationConfigVersion: String = "default",
        notificationProducerGeneration: Int64 = 0,
        notificationConfiguration: NotificationProducerConfiguration? = nil,
        database: Database
    ) throws -> (insertedMembership: Bool, insertedCanonicalMessage: Bool, insertedMacNotificationEvent: Bool) {
        let canonicalMessageExists = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id = ?)",
            arguments: [message.id.rawValue]
        ) ?? false
        let insertedCanonicalMessage = !canonicalMessageExists
        let values: [String?] = [
            message.id.rawValue, accountID.rawValue, message.threadID?.rawValue, message.from.rawValue,
            message.fromDisplayName, message.subject, message.preview, message.body, message.bodyHTML,
            message.smartCategory.rawValue, labelsJSON(message.labels), message.isSeen ? "1" : "0",
            message.mailboxPath, message.isDeleted ? "1" : "0",
            message.sentAt.map { String($0.timeIntervalSince1970) }, message.rfcMessageID,
            message.inReplyTo, labelsJSON(message.references), message.replyTo?.rawValue,
            message.to.map(\.rawValue).joined(separator: "\n"),
            message.cc.map(\.rawValue).joined(separator: "\n")
        ]
        try database.execute(
            sql: """
                INSERT INTO messages (id, account_id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html, smart_category, labels_json, is_seen, mailbox_path, is_deleted, sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email, to_emails, cc_emails)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    account_id = excluded.account_id, thread_id = excluded.thread_id, from_email = excluded.from_email,
                    from_display_name = excluded.from_display_name, subject = excluded.subject,
                    preview = excluded.preview, body_text = excluded.body_text, body_html = excluded.body_html,
                    labels_json = messages.labels_json,
                    is_seen = COALESCE(
                        (SELECT desired_seen FROM message_seen_intents WHERE message_id = excluded.id),
                        excluded.is_seen
                    ), mailbox_path = excluded.mailbox_path,
                    is_deleted = excluded.is_deleted, sent_at = excluded.sent_at,
                    rfc_message_id = excluded.rfc_message_id, in_reply_to = excluded.in_reply_to,
                    references_json = excluded.references_json, reply_to_email = excluded.reply_to_email,
                    to_emails = excluded.to_emails, cc_emails = excluded.cc_emails
                """,
            arguments: StatementArguments(values)
        )
        try acknowledgeDesiredSeenIfObserved(
            messageID: message.id,
            observedSeen: message.isSeen,
            database: database
        )
        if insertedCanonicalMessage {
            try importUserVisibleLabels(
                message.labels,
                database: database,
                messageID: message.id.rawValue,
                accountID: accountID.rawValue,
                actorID: "mail-ingestion"
            )
        }
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [accountID.rawValue, mailboxPath, uidValidity, uid, message.id.rawValue]
        )
        let insertedMembership = database.changesCount > 0
        if uidValidity > 0 {
            // The server's copy has arrived: it replaces the local key a move
            // without COPYUID left in this mailbox (UIDVALIDITY 0, negative UID),
            // so actions on the message can reach the server again.
            try database.execute(
                sql: """
                    DELETE FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ? AND message_id = ?
                      AND uid_validity = 0 AND uid < 0
                      AND EXISTS(
                          SELECT 1 FROM mailbox_messages
                          WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ? AND message_id = ?
                      )
                    """,
                arguments: [
                    accountID.rawValue, mailboxPath, message.id.rawValue,
                    accountID.rawValue, mailboxPath, uidValidity, uid, message.id.rawValue,
                ]
            )
        }
        try database.execute(
            sql: """
                UPDATE mailbox_messages SET internal_date = COALESCE(?, internal_date)
                WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                """,
            arguments: [notificationDisposition.providerArrivalAt?.timeIntervalSince1970,
                         accountID.rawValue, mailboxPath, uidValidity, uid]
        )
        if let persistedAttachments {
            try database.execute(
                sql: "DELETE FROM incoming_message_attachments WHERE message_id = ?",
                arguments: [message.id.rawValue]
            )
            for (ordinal, attachment) in persistedAttachments.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO incoming_message_attachments (
                            message_id, part_path, ordinal, filename, mime_type,
                            byte_count, sha256, payload, content_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        message.id.rawValue,
                        attachment.partPath,
                        ordinal,
                        attachment.filename,
                        attachment.mimeType,
                        attachment.byteCount,
                        attachment.sha256,
                        attachment.data,
                        attachment.contentID,
                    ]
                )
            }
        }
        try SQLiteMailSearchProjectionWriter.upsert(
            messageID: message.id,
            metadata: metadata,
            database: database
        )
        let insertedMacNotificationEvent: Bool
        if notificationEligible || notificationDisposition != .ineligible {
            insertedMacNotificationEvent = try Self.applyLocalNotificationState(
                database: database,
                accountID: accountID,
                mailboxPath: mailboxPath,
                uidValidity: uidValidity,
                uid: uid,
                messageID: message.id,
                threadID: message.threadID,
                canonicalMessageInserted: insertedCanonicalMessage,
                membershipInserted: insertedMembership,
                disposition: notificationDisposition,
                configVersion: notificationConfiguration?.configVersion ?? notificationConfigVersion,
                producerGeneration: notificationConfiguration?.producerGeneration ?? notificationProducerGeneration,
                configuration: notificationConfiguration,
                now: Date()
            )
        } else {
            insertedMacNotificationEvent = false
        }
        return (insertedMembership, insertedCanonicalMessage, insertedMacNotificationEvent)
    }

    private static func validIncomingAttachment(
        _ attachment: IncomingMessageAttachmentPayload
    ) -> Bool {
        validStoredIncomingAttachmentMetadata(
            partPath: attachment.partPath,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount,
            sha256: attachment.sha256
        ) &&
            attachment.byteCount == attachment.data.count
    }

    private static func applyLocalNotificationState(
        database: Database,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        messageID: MessageID,
        threadID: ThreadID?,
        canonicalMessageInserted: Bool,
        membershipInserted: Bool,
        disposition: IncomingNotificationDisposition,
        configVersion: String,
        producerGeneration: Int64,
        configuration: NotificationProducerConfiguration? = nil,
        now: Date
    ) throws -> Bool {
        guard mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame else { return false }
        let timestamp = now.timeIntervalSince1970
        try database.execute(
            sql: """
                INSERT INTO local_notification_mailboxes (
                    account_id, plainpost_account_id, mailbox_path, logical_mailbox_id, logical_mailbox_id_bytes, uid_validity,
                    selected_producer_device_id, selected_producer_kind, policy_mode, policy_version,
                    config_revision, config_version, producer_generation, baseline_complete, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, mailbox_path) DO UPDATE SET
                    uid_validity = excluded.uid_validity,
                    baseline_complete = CASE WHEN local_notification_mailboxes.uid_validity != excluded.uid_validity
                        THEN 0 ELSE local_notification_mailboxes.baseline_complete END,
                    updated_at = excluded.updated_at
                """,
            arguments: [accountID.rawValue, configuration?.plainpostAccountID?.rawValue ?? accountID.rawValue, mailboxPath,
                        configuration?.logicalMailboxID ?? "",
                        configuration?.logicalMailboxIDBytes ?? Data(repeating: 0, count: 32),
                        uidValidity,
                        configuration?.producerDeviceIDValue?.rawValue ?? configuration?.producerDeviceID, configuration?.producerKind ?? "mac",
                        configuration?.policyMode ?? "off", configuration?.policyVersion ?? 0,
                        configuration?.configRevision ?? 0, configVersion, producerGeneration,
                        disposition == .establishWatermark ? 0 : 1, timestamp]
        )
        try database.execute(
            sql: """
                INSERT INTO local_notification_watermarks (
                    account_id, mailbox_path, uid_validity, watermark_uid, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, mailbox_path, uid_validity) DO UPDATE SET
                    watermark_uid = MAX(local_notification_watermarks.watermark_uid, excluded.watermark_uid),
                    updated_at = excluded.updated_at
                """,
            arguments: [accountID.rawValue, mailboxPath, uidValidity, uid, timestamp]
        )
        // A local alert may follow a slower background refresh (see
        // `newMailNotificationWindow`); a push from this producer stays at 15 minutes.
        let localAlertWindow = Self.newMailNotificationWindow
        let freshArrivalAt: Date?
        if membershipInserted,
           case .candidate(let candidateArrivalAt) = disposition,
           let candidateArrivalAt,
           timestamp >= candidateArrivalAt.timeIntervalSince1970,
           timestamp - candidateArrivalAt.timeIntervalSince1970 <= max(15 * 60, localAlertWindow) {
            freshArrivalAt = candidateArrivalAt
        } else {
            freshArrivalAt = nil
        }
        let providerArrivalAt = freshArrivalAt.flatMap {
            timestamp - $0.timeIntervalSince1970 <= 15 * 60 ? $0 : nil
        }

        var insertedMacNotificationEvent = false
        if canonicalMessageInserted, let freshArrivalAt,
           timestamp - freshArrivalAt.timeIntervalSince1970 <= localAlertWindow {
            let eventID = "mac-mail-event-" + stableNotificationID(
                "\(accountID.rawValue)\u{1f}\(messageID.rawValue)"
            )
            let providerTimestamp = freshArrivalAt.timeIntervalSince1970
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO mac_new_mail_events (
                        id, account_id, message_id, state, provider_arrival_at,
                        expires_at, created_at, updated_at
                    ) VALUES (?, ?, ?, 'awaiting_rules', ?, ?, ?, ?)
                    """,
                arguments: [
                    eventID, accountID.rawValue, messageID.rawValue,
                    providerTimestamp, providerTimestamp + localAlertWindow,
                    timestamp, timestamp,
                ]
            )
            insertedMacNotificationEvent = database.changesCount > 0
        }

        guard membershipInserted, let providerArrivalAt else {
            return insertedMacNotificationEvent
        }
        guard let mailbox = try Row.fetchOne(
            database,
            sql: """
                SELECT plainpost_account_id, logical_mailbox_id, logical_mailbox_id_bytes,
                       selected_producer_device_id, selected_producer_kind, policy_mode,
                       policy_version, config_revision, config_version, producer_generation,
                       notification_eligible, notification_revoked
                FROM local_notification_mailboxes WHERE account_id = ? AND mailbox_path = ?
                """,
            arguments: [accountID.rawValue, mailboxPath]
        ),
        let selectedDevice = mailbox["selected_producer_device_id"] as String?,
        (mailbox["selected_producer_kind"] as String) == "mac",
        (mailbox["policy_mode"] as String) != "off",
        (mailbox["policy_version"] as Int64) > 0,
        (mailbox["producer_generation"] as Int64) > 0,
        (mailbox["notification_eligible"] as Int64) == 1,
        (mailbox["notification_revoked"] as Int64) == 0,
        let logicalMailboxBytes = mailbox["logical_mailbox_id_bytes"] as Data?,
        logicalMailboxBytes.count == 32,
        logicalMailboxBytes.contains(where: { $0 != 0 }) else {
            return insertedMacNotificationEvent
        }
        let storedConfigVersion: String = mailbox["config_version"]
        let storedProducerGeneration: Int64 = mailbox["producer_generation"]
        let publicationID = "local-pub-" + stableNotificationID(
            "\(accountID.rawValue)\u{1f}\(mailboxPath)\u{1f}\(uidValidity)\u{1f}\(uid)\u{1f}\(messageID.rawValue)\u{1f}\(storedConfigVersion)\u{1f}\(storedProducerGeneration)"
        )
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO local_notification_publications (
                    id, account_id, plainpost_account_id, message_id, mailbox_path, logical_mailbox_id, logical_mailbox_id_bytes,
                    uid_validity, uid, thread_id, provider_arrival_at, producer_device_id, producer_kind,
                    policy_mode, policy_version, config_revision, config_version, producer_generation,
                    committed_at, expires_at, state, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [publicationID, accountID.rawValue, mailbox["plainpost_account_id"], messageID.rawValue,
                        mailboxPath, mailbox["logical_mailbox_id"], logicalMailboxBytes, uidValidity, uid,
                        threadID?.rawValue, providerArrivalAt.timeIntervalSince1970, selectedDevice,
                        mailbox["selected_producer_kind"], mailbox["policy_mode"], mailbox["policy_version"],
                        mailbox["config_revision"], mailbox["config_version"], mailbox["producer_generation"],
                        timestamp, timestamp + 15 * 60, "pending", timestamp, timestamp]
        )
        return insertedMacNotificationEvent
    }

    private static func stableNotificationID(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validStoredIncomingAttachmentMetadata(
        partPath: String,
        filename: String,
        mimeType: String?,
        byteCount: Int,
        sha256: String
    ) -> Bool {
        let pathSegments = partPath.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        let validPartPath =
            !pathSegments.isEmpty &&
            partPath.utf8.count <=
                IncomingMessageAttachmentPayload.maximumPartPathUTF8Length &&
            pathSegments.allSatisfy { segment in
                guard let value = Int(segment) else { return false }
                return value > 0 && String(value) == segment
            }
        let validFilename =
            !filename.isEmpty &&
            filename != "." &&
            filename != ".." &&
            filename == filename.precomposedStringWithCanonicalMapping &&
            filename == filename.trimmingCharacters(in: .whitespacesAndNewlines) &&
            filename.utf8.count <=
                IncomingMessageAttachmentPayload.maximumFilenameUTF8Length &&
            !filename.contains("/") &&
            !filename.contains("\\") &&
            !filename.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            }
        let validMIMEType = mimeType.map { mimeType in
            mimeType.utf8.count <=
                IncomingMessageAttachmentPayload.maximumMIMETypeUTF8Length &&
            MailSearchDocumentClassifier.canonicalMIMEType(mimeType) == mimeType
        } ?? true
        return validPartPath &&
            validFilename &&
            validMIMEType &&
            byteCount >= 0 &&
            byteCount <=
                IncomingMessageAttachmentPayload.maximumDecodedBytesPerAttachment &&
            sha256.count == 64 &&
            sha256.utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
    }

    private static func validIncomingAttachmentAggregate(
        _ attachments: [IncomingMessageAttachmentPayload]
    ) -> Bool {
        var aggregate = 0
        for attachment in attachments {
            let (next, overflow) = aggregate.addingReportingOverflow(attachment.byteCount)
            guard !overflow,
                  next <= IncomingMessageAttachmentPayload.maximumAggregateDecodedBytes
            else {
                return false
            }
            aggregate = next
        }
        return true
    }

    public func reconcileMailboxState(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        states: [IMAPRemoteMessageState]
    ) throws {
        do {
            try databasePool.write { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT uid, message_id FROM mailbox_messages
                        WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ?
                        """,
                    arguments: [accountID.rawValue, mailboxPath, uidValidity]
                )
                let membership = Dictionary(uniqueKeysWithValues: rows.map { row in
                    (row["uid"] as Int, row["message_id"] as String)
                })
                var affectedMessageIDs = Set<String>()
                let remoteUIDs = Set(states.map(\.uid))
                for (uid, messageID) in membership where !remoteUIDs.contains(uid) {
                    affectedMessageIDs.insert(messageID)
                    try database.execute(
                        sql: """
                            DELETE FROM mailbox_messages
                            WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                            """,
                        arguments: [accountID.rawValue, mailboxPath, uidValidity, uid]
                    )
                    try database.execute(
                        sql: """
                            UPDATE messages SET is_deleted = 1 WHERE id = ?
                            AND NOT EXISTS (SELECT 1 FROM mailbox_messages WHERE message_id = ?)
                            """,
                        arguments: [messageID, messageID]
                    )
                }
                for state in states {
                    guard let messageID = membership[state.uid] else { continue }
                    affectedMessageIDs.insert(messageID)
                    let normalized = Set(state.flags.compactMap { flag -> String? in
                        let value = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return value.isEmpty ? nil : value
                    })
                    try database.execute(
                        sql: """
                            UPDATE mailbox_messages SET flags = ?
                            WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                            """,
                        arguments: [
                            normalized.sorted().joined(separator: " "), accountID.rawValue,
                            mailboxPath, uidValidity, state.uid
                        ]
                    )
                    let observedSeen = normalized.contains("\\seen")
                    let desiredSeen = try desiredSeenState(
                        messageID: MessageID(messageID),
                        database: database
                    )
                    try database.execute(
                        sql: "UPDATE messages SET is_seen = ?, is_deleted = ? WHERE id = ?",
                        arguments: [
                            (desiredSeen ?? observedSeen) ? 1 : 0,
                            normalized.contains("\\deleted") ? 1 : 0,
                            messageID
                        ]
                    )
                    if desiredSeen == observedSeen {
                        try database.execute(
                            sql: "DELETE FROM message_seen_intents WHERE message_id = ?",
                            arguments: [messageID]
                        )
                    }
                }
                for messageID in affectedMessageIDs.sorted() {
                    try Self.refreshSearchProjectionIfIndexable(
                        messageID: MessageID(messageID),
                        database: database
                    )
                }
            }
            MailStoreChangeSignal.post(scope: .mailbox)
        } catch {
            throw databaseError(error)
        }
    }

    public func addLabel(_ label: String, to messageID: MessageID, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw PlainpostError.validationFailed("Label cannot be empty.")
        }
        let validatedTitle = try MailLabelDefinition.validated(
            title: title,
            description: "",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        )
        do {
            try databasePool.write { database in
                let accountID = try messageAccountID(
                    database: database,
                    messageID: messageID.rawValue
                )
                let labelID = try resolveOrCreateLegacyMailLabel(
                    database: database,
                    validatedTitle: validatedTitle,
                    accountID: accountID,
                    actorID: actor.id
                )
                let hadExclusion = try labelExclusionExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let assignmentAdded = try addUserLabelOwnership(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "label.add",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: assignmentAdded ? [labelID] : [],
                            removedLabelIDs: [],
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
                if hadExclusion {
                    try insertAudit(
                        database: database,
                        actorID: actor.id,
                        action: "mail_label.exclusion_clear",
                        targetType: "message",
                        targetID: messageID.rawValue,
                        result: try canonicalAuditResult(
                            MailLabelExclusionAuditResult(
                                labelID: labelID,
                                source: "user"
                            )
                        )
                    )
                }
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        guard let updated = messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        return updated
    }

    public func removeLabel(_ label: String, from messageID: MessageID, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        let normalizedTitle = Self.normalizeMailLabelTitle(label)
        do {
            try databasePool.write { database in
                let accountID = try messageAccountID(
                    database: database,
                    messageID: messageID.rawValue
                )
                let labelIDs = try String.fetchAll(
                    database,
                    sql: """
                        SELECT id FROM mail_labels
                        WHERE normalized_title = ?
                          AND (
                            scope_account_id IS NULL
                            OR scope_account_id = ?
                          )
                        ORDER BY id
                        """,
                    arguments: [normalizedTitle, accountID]
                )
                var removedLabelIDs: [String] = []
                for labelID in labelIDs {
                    let hadUserOwnership = try labelAssignmentExists(
                        database: database,
                        labelID: labelID,
                        messageID: messageID.rawValue,
                        sourceKind: "user",
                        sourceID: ""
                    )
                    let hadSmartInboxOwnership = try labelAssignmentExists(
                        database: database,
                        labelID: labelID,
                        messageID: messageID.rawValue,
                        sourceKind: "smartInbox",
                        sourceID: ""
                    )
                    let hadExclusion = try labelExclusionExists(
                        database: database,
                        labelID: labelID,
                        messageID: messageID.rawValue
                    )
                    try removeUserOrSmartInboxLabelOwnership(
                        database: database,
                        labelID: labelID,
                        messageID: messageID.rawValue
                    )
                    if hadUserOwnership || hadSmartInboxOwnership {
                        removedLabelIDs.append(labelID)
                    }
                    if hadSmartInboxOwnership, !hadExclusion {
                        try insertAudit(
                            database: database,
                            actorID: actor.id,
                            action: "mail_label.exclusion_create",
                            targetType: "message",
                            targetID: messageID.rawValue,
                            result: try canonicalAuditResult(
                                MailLabelExclusionAuditResult(
                                    labelID: labelID,
                                    source: "user"
                                )
                            )
                        )
                    }
                }
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "label.remove",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: [],
                            removedLabelIDs: removedLabelIDs.sorted(),
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
            }
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        guard let updated = messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        return updated
    }

    public func recategorize(_ messageID: MessageID, as category: SmartCategory, actor: Actor) throws -> MessageSummary {
        guard actor.permissions.recategorize else {
            throw PlainpostError.permissionDenied("Actor is not allowed to recategorize messages.")
        }
        return try updateMessage(messageID, actor: actor, action: "category.change") { message in
            message.withSmartCategory(category)
        }
    }

    public func recategorize(_ updates: [MessageCategoryUpdate], actor: Actor) throws {
        guard actor.permissions.recategorize else {
            throw PlainpostError.permissionDenied("Actor is not allowed to recategorize messages.")
        }
        guard !updates.isEmpty else { return }
        try databasePool.write { database in
            for update in updates {
                try database.execute(
                    sql: "UPDATE messages SET smart_category = ? WHERE id = ?",
                    arguments: [update.category.rawValue, update.messageID.rawValue]
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "category.change",
                    targetType: "message",
                    targetID: update.messageID.rawValue
                )
            }
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    public func markSeen(_ messageID: MessageID, seen: Bool, actor: Actor) throws -> MessageSummary {
        try markSeen(messageID, seen: seen, actor: actor, schedulesDirectFlag: true)
    }

    /// `schedulesDirectFlag: false` records the user's desired seen state
    /// locally (message, search projection, durable seen intent and audit)
    /// without enqueuing the direct IMAP flag job: the Sync Node carries the
    /// change for an account in Node mode, and the mirror acknowledges the
    /// intent once it observes the provider state.
    public func markSeen(
        _ messageID: MessageID,
        seen: Bool,
        actor: Actor,
        schedulesDirectFlag: Bool
    ) throws -> MessageSummary {
        guard actor.permissions.markSeen else {
            throw PlainpostError.permissionDenied("Actor is not allowed to change seen state.")
        }
        if actor.kind == .user {
            let result = try persistHumanDesiredSeen(
                messageID,
                seen: seen,
                actor: actor,
                onlyIfChanged: false,
                schedulesDirectFlag: schedulesDirectFlag
            )
            try? flushAuditOutbox()
            MailStoreChangeSignal.post(scope: .mailbox)
            return result.message
        }
        return try updateMessage(messageID, actor: actor, action: seen ? "message.mark_seen" : "message.mark_unseen") { message in
            message.withSeen(seen)
        }
    }

    /// Persist a selected iOS Direct action and its provider flag job under
    /// the same source-generation check. An old runtime cannot enqueue work
    /// after this account has moved away and back to Direct mail.
    public func markSelectedDirectSeen(
        _ messageID: MessageID,
        seen: Bool,
        actor: Actor,
        accountID: AccountID,
        expectedSourceGeneration: Int64
    ) throws -> MessageSummary {
        guard actor.permissions.markSeen, actor.kind == .user else {
            throw PlainpostError.permissionDenied("Actor is not allowed to change seen state.")
        }
        let result = try persistHumanDesiredSeen(
            messageID,
            seen: seen,
            actor: actor,
            onlyIfChanged: false,
            selectedDirectSource: (accountID, expectedSourceGeneration)
        )
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        return result.message
    }

    public func openMessageForHuman(_ messageID: MessageID, actor: Actor) throws -> MessageSummary {
        try openMessageForHumanResult(messageID, actor: actor).message
    }

    public func openMessageForHumanResult(
        _ messageID: MessageID,
        actor: Actor
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool) {
        try openMessageForHumanResult(
            messageID, actor: actor, selectedDirectSource: nil
        )
    }

    public func openSelectedDirectMessageForHumanResult(
        _ messageID: MessageID,
        actor: Actor,
        accountID: AccountID,
        expectedSourceGeneration: Int64
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool) {
        try openMessageForHumanResult(
            messageID, actor: actor,
            selectedDirectSource: (accountID, expectedSourceGeneration)
        )
    }

    private func openMessageForHumanResult(
        _ messageID: MessageID,
        actor: Actor,
        selectedDirectSource: (AccountID, Int64)?
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool) {
        guard actor.permissions.markSeen else {
            throw PlainpostError.permissionDenied("Actor is not allowed to change seen state.")
        }
        let result = try persistHumanDesiredSeen(
            messageID,
            seen: true,
            actor: actor,
            onlyIfChanged: true,
            selectedDirectSource: selectedDirectSource
        )
        if result.changed {
            try? flushAuditOutbox()
            MailStoreChangeSignal.post(scope: .mailbox)
        }
        return (result.message, result.changed)
    }

    private func persistHumanDesiredSeen(
        _ messageID: MessageID,
        seen: Bool,
        actor: Actor,
        onlyIfChanged: Bool,
        schedulesDirectFlag: Bool = true,
        selectedDirectSource: (AccountID, Int64)? = nil
    ) throws -> (message: MessageSummary, changed: Bool) {
        return try databasePool.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text,
                        body_html, smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted,
                        sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email,
                        to_emails, cc_emails
                    FROM messages
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [messageID.rawValue]
            ) else {
                throw PlainpostError.notFound("Message not found.")
            }
            let message = decodeMessage(row)
            guard !message.isDeleted else {
                throw PlainpostError.notFound("Message not found.")
            }
            let accountID = AccountID(try Self.requiredMessageRelationOwner(
                messageID: messageID.rawValue,
                database: database
            ))
            if let selectedDirectSource {
                guard accountID == selectedDirectSource.0 else {
                    throw PlainpostError.permissionDenied("The message does not belong to the selected Direct account.")
                }
                try Self.requireDirectSource(
                    accountID: accountID,
                    generation: selectedDirectSource.1,
                    allowNodeFallback: true,
                    database: database
                )
            }
            guard !onlyIfChanged || message.isSeen != seen else { return (message, false) }
            let membership = try Self.canonicalMailboxFlagMembership(
                messageID: messageID,
                accountID: accountID,
                database: database
            )
            let input = PlainpostMailboxFlagInput(
                messageID: messageID,
                accountID: accountID,
                mailboxPath: membership.mailboxPath,
                uidValidity: membership.uidValidity,
                uid: membership.uid,
                desiredSeen: seen,
                expectedDirectSourceGeneration: selectedDirectSource?.1
            )
            let payload = try JSONEncoder().encode(input)

            try database.execute(
                sql: "UPDATE messages SET is_seen = ? WHERE id = ?",
                arguments: [seen ? 1 : 0, messageID.rawValue]
            )
            try Self.refreshSearchProjectionIfIndexable(
                messageID: messageID,
                database: database
            )
            try database.execute(
                sql: """
                    INSERT INTO message_seen_intents (message_id, desired_seen, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET
                        desired_seen = excluded.desired_seen,
                        updated_at = excluded.updated_at
                    """,
                arguments: [messageID.rawValue, seen ? 1 : 0, Date().timeIntervalSince1970]
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: seen ? "message.mark_seen" : "message.mark_unseen",
                targetType: "message",
                targetID: messageID.rawValue
            )
            if schedulesDirectFlag {
                _ = try enqueueJob(
                    PlainpostJobRequest(
                        kind: .mailboxFlag,
                        payloadJSON: String(decoding: payload, as: UTF8.self),
                        priority: 100,
                        idempotencyKey: Self.mailboxFlagIdempotencyKey(input),
                        replaceTerminalDuplicate: true
                    ),
                    database: database,
                    now: Date()
                )
            }
            return (message.withSeen(seen), true)
        }
    }

    public func moveMessage(_ messageID: MessageID, toMailboxPath mailboxPath: String, actor: Actor) throws -> MessageSummary {
        guard let existing = messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let updated = existing.withMailboxPath(mailboxPath)
        try databasePool.write { database in
            _ = try Self.moveCanonicalMailboxMembership(
                messageID: messageID,
                accountID: nil,
                sourceMailboxPath: existing.mailboxPath,
                destinationMailboxPath: mailboxPath,
                database: database
            )
            try Self.refreshSearchProjectionIfIndexable(
                messageID: messageID,
                database: database
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: "message.move",
                targetType: "message",
                targetID: messageID.rawValue
            )
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        return updated
    }

    public func markDeleted(_ messageID: MessageID, deleted: Bool, actor: Actor) throws -> MessageSummary {
        try updateMessage(messageID, actor: actor, action: "message.delete") { message in
            message.withDeleted(deleted)
        }
    }

    /// Commits a confirmed provider action only while its original Direct source
    /// and canonical mailbox membership still own the local message. The check
    /// and mutation share one write transaction with sync and source changes.
    /// `duplicateUIDs` are the other copies of the message in the same mailbox
    /// (see `duplicateCopyUIDs`) the provider also moved or erased.
    public func applyConfirmedMailboxAction(
        _ action: ConfirmedMailboxCacheAction,
        membership: MailboxMessageMembership,
        duplicateUIDs: [Int] = [],
        sourceSnapshot: ConfirmedMailboxSourceSnapshot,
        actor: Actor
    ) throws -> MessageSummary {
        let message = try databasePool.write { database in
            switch sourceSnapshot {
            case .direct(let expectedSourceGeneration):
                let sourceMatches = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM account_mail_sources
                            WHERE account_id = ? AND generation = ?
                              AND (kind = 'direct' OR (kind = 'node_backed' AND mode = 'fallback'))
                        )
                        """,
                    arguments: [membership.accountID.rawValue, expectedSourceGeneration]
                ) ?? false
                guard sourceMatches else { throw ConfirmedMailboxActionConflict.sourceChanged }
            case .implicitDirect:
                let schemaExists = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'account_mail_sources')"
                ) ?? false
                if schemaExists {
                    let sourceAppeared = try Bool.fetchOne(
                        database,
                        sql: "SELECT EXISTS(SELECT 1 FROM account_mail_sources WHERE account_id = ?)",
                        arguments: [membership.accountID.rawValue]
                    ) ?? false
                    guard !sourceAppeared else { throw ConfirmedMailboxActionConflict.sourceChanged }
                }
            }
            // The exact copy the action targeted (see `displayedMembership`) must
            // still exist; another copy of the same message is not a substitute.
            let targetExists = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM mailbox_messages
                        WHERE message_id = ? AND account_id = ? AND mailbox_path = ?
                          AND uid_validity = ? AND uid = ?
                    )
                    """,
                arguments: [
                    membership.messageID.rawValue, membership.accountID.rawValue,
                    membership.mailboxPath, membership.uidValidity, membership.uid,
                ]
            ) ?? false
            guard targetExists else {
                throw ConfirmedMailboxActionConflict.membershipChanged
            }
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text,
                        body_html, smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted,
                        sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email,
                        to_emails, cc_emails
                    FROM messages WHERE id = ? LIMIT 1
                    """,
                arguments: [membership.messageID.rawValue]
            )
            guard let row else { throw ConfirmedMailboxActionConflict.membershipChanged }
            let current = decodeMessage(row)
            // The target copy need not be the one `messages.mailbox_path` names (the
            // last copy synced): a self-addressed message has INBOX and Sent copies.
            // The returned summary describes the copy acted on.
            guard !current.isDeleted else {
                throw ConfirmedMailboxActionConflict.membershipChanged
            }
            let updated: MessageSummary
            let auditAction: String
            switch action {
            case .flag(let flagged):
                let stored = try String.fetchOne(
                    database,
                    sql: """
                        SELECT flags FROM mailbox_messages
                        WHERE message_id = ? AND account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                        """,
                    arguments: [
                        membership.messageID.rawValue, membership.accountID.rawValue,
                        membership.mailboxPath, membership.uidValidity, membership.uid,
                    ]
                ) ?? ""
                var flags = Set(stored.split(separator: " ").map { $0.lowercased() })
                if flagged { flags.insert("\\flagged") } else { flags = flags.filter { !$0.hasSuffix("flagged") } }
                try database.execute(
                    sql: """
                        UPDATE mailbox_messages SET flags = ?
                        WHERE message_id = ? AND account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                        """,
                    arguments: [
                        flags.sorted().joined(separator: " "), membership.messageID.rawValue, membership.accountID.rawValue,
                        membership.mailboxPath, membership.uidValidity, membership.uid,
                    ]
                )
                updated = current.flagged(flagged)
                auditAction = flagged ? "message.flag" : "message.unflag"
            case .archive(let destination, let uidValidity, let uid):
                let providerKey = uidValidity.flatMap { validity in uid.map { (uidValidity: validity, uid: $0) } }
                try Self.moveConfirmedMembership(
                    membership, to: destination, providerKey: providerKey,
                    duplicateUIDs: duplicateUIDs, database: database
                )
                updated = current.withMailboxPath(destination)
                auditAction = "message.move"
            case .trash(let destination, let uidValidity, let uid):
                let providerKey = uidValidity.flatMap { validity in uid.map { (uidValidity: validity, uid: $0) } }
                try Self.moveConfirmedMembership(
                    membership, to: destination, providerKey: providerKey,
                    duplicateUIDs: duplicateUIDs, database: database
                )
                updated = current.withMailboxPath(destination)
                auditAction = "message.trash"
            case .delete:
                // The erased copies: the target and its erased duplicates.
                let erasedUIDs = [membership.uid] + duplicateUIDs
                let erasedCopies = """
                    account_id = ? AND mailbox_path = ? AND uid_validity = ?
                      AND uid IN (\(databaseQuestionMarks(count: erasedUIDs.count)))
                    """
                let erasedArguments = StatementArguments(
                    [membership.accountID.rawValue, membership.mailboxPath, membership.uidValidity]
                        as [DatabaseValueConvertible]
                ) + StatementArguments(erasedUIDs)
                let otherCopy = try String.fetchOne(
                    database,
                    sql: """
                        SELECT mailbox_path FROM mailbox_messages
                        WHERE message_id = ? AND NOT (\(erasedCopies))
                        ORDER BY CASE WHEN mailbox_path = 'INBOX' COLLATE NOCASE THEN 0 ELSE 1 END, mailbox_path
                        LIMIT 1
                        """,
                    arguments: [membership.messageID.rawValue] + erasedArguments
                )
                if let otherCopy {
                    // Another copy (say in Sent) survives: drop only the erased ones.
                    try database.execute(
                        sql: "DELETE FROM mailbox_messages WHERE message_id = ? AND \(erasedCopies)",
                        arguments: [membership.messageID.rawValue] + erasedArguments
                    )
                    try database.execute(
                        sql: "UPDATE messages SET mailbox_path = ? WHERE id = ? AND mailbox_path = ?",
                        arguments: [otherCopy, membership.messageID.rawValue, membership.mailboxPath]
                    )
                } else {
                    try database.execute(
                        sql: "UPDATE messages SET is_deleted = 1 WHERE id = ?",
                        arguments: [membership.messageID.rawValue]
                    )
                }
                // The message itself: still there (in its remaining copy's mailbox)
                // when another copy survives, deleted only when none does.
                updated = otherCopy.map { current.mailboxPath == membership.mailboxPath ? current.withMailboxPath($0) : current }
                    ?? current.withDeleted(true)
                auditAction = "message.delete"
            }
            try Self.refreshSearchProjectionIfIndexable(
                messageID: membership.messageID, database: database
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: auditAction,
                targetType: "message",
                targetID: membership.messageID.rawValue
            )
            return updated
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        return message
    }

    private func updateMessage(
        _ messageID: MessageID,
        actor: Actor,
        action: String,
        transform: (MessageSummary) throws -> MessageSummary
    ) throws -> MessageSummary {
        guard let existing = messages.first(where: { $0.id == messageID }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let updated = try transform(existing)
        try cacheMessageReliably(updated)
        try appendAudit(actorID: actor.id, action: action, targetType: "message", targetID: messageID.rawValue)
        return updated
    }

    public func createDraft(_ draft: Draft, actor: Actor) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to create drafts.")
        }

        try saveDraft(draft)
        try appendAudit(actorID: actor.id, action: "draft.create", targetType: "draft", targetID: draft.id.rawValue)
        return draft
    }

    /// Commits an AI draft only while the account still has the Direct source
    /// generation captured before provider work began.
    public func createAIDraft(
        _ draft: Draft,
        actor: Actor,
        expectedDirectSourceGeneration: Int64
    ) throws -> Draft {
        try createDirectDraft(
            draft, actor: actor,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration
        )
    }

    /// Persists a device-local draft only while its selected Direct source
    /// still matches the generation captured by the runtime.
    public func createDirectDraft(
        _ draft: Draft,
        actor: Actor,
        expectedDirectSourceGeneration: Int64
    ) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to create drafts.")
        }
        try databasePool.write { database in
            try Self.requireDirectSource(
                accountID: draft.accountID,
                generation: expectedDirectSourceGeneration,
                database: database
            )
            // Saving again under a draft's id never moves it to another account.
            if let owner = try String.fetchOne(
                database, sql: "SELECT owner_account_id FROM drafts WHERE id = ?", arguments: [draft.id.rawValue]
            ), owner != draft.accountID.rawValue {
                throw PlainpostError.permissionDenied("This draft belongs to another account.")
            }
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO drafts (id, payload_json, owner_account_id, ownership_kind)
                    VALUES (?, ?, ?, 'account')
                    """,
                arguments: [draft.id.rawValue, try encodeJSON(draft), draft.accountID.rawValue]
            )
        }
        try appendAudit(actorID: actor.id, action: "draft.create", targetType: "draft", targetID: draft.id.rawValue)
        return draft
    }

    public func draft(id: DraftID) throws -> Draft {
        guard let draft = try readDraft(id: id) else {
            throw PlainpostError.notFound("Draft not found.")
        }
        return draft
    }

    public func updateDraft(id: DraftID, patch: DraftPatch, actor: Actor) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to update drafts.")
        }
        let existing = try draft(id: id)
        let updated = existing.applying(patch)
        try saveDraft(updated)
        try appendAudit(actorID: actor.id, action: "draft.update", targetType: "draft", targetID: id.rawValue)
        return updated
    }

    public func updateDraft(
        id: DraftID,
        expectedHash: String,
        patch: DraftPatch,
        actor: Actor,
        requiredIDPrefix: String? = nil,
        requiredCreatorID: String? = nil
    ) throws -> Draft {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to update drafts.")
        }
        let updated = try databasePool.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT payload_json FROM drafts WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                throw PlainpostError.notFound("Draft not found.")
            }
            let existing = try decodeJSON(Draft.self, from: row["payload_json"])
            if let requiredIDPrefix, !id.rawValue.hasPrefix(requiredIDPrefix) {
                throw PlainpostError.permissionDenied("This client cannot access that draft.")
            }
            if let requiredCreatorID, existing.createdBy != requiredCreatorID {
                throw PlainpostError.permissionDenied("This client cannot access that draft.")
            }
            guard existing.contentHash == expectedHash else {
                throw DraftOptimisticUpdateError.conflict
            }

            let updated = existing.applying(patch)
            guard updated != existing else { return existing }
            try database.execute(
                sql: "UPDATE drafts SET payload_json = ? WHERE id = ?",
                arguments: [try encodeJSON(updated), id.rawValue]
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: "draft.update",
                targetType: "draft",
                targetID: id.rawValue
            )
            return updated
        }
        try? flushAuditOutbox()
        return updated
    }

    public func drafts(
        requiredIDPrefix: String,
        requiredCreatorID: String,
        accountID: AccountID,
        limit: Int
    ) throws -> [Draft] {
        let safeLimit = max(1, min(limit, 1_000))
        return try databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT payload_json FROM drafts
                    WHERE substr(id, 1, ?) = ?
                      AND json_extract(payload_json, '$.createdBy') = ?
                      AND COALESCE(
                          json_extract(payload_json, '$.accountID.rawValue'),
                          json_extract(payload_json, '$.accountID')
                      ) = ?
                    ORDER BY id
                    LIMIT ?
                    """,
                arguments: [
                    requiredIDPrefix.utf8.count,
                    requiredIDPrefix,
                    requiredCreatorID,
                    accountID.rawValue,
                    safeLimit,
                ]
            )
            return try rows.map { row in
                let draft = try decodeJSON(Draft.self, from: row["payload_json"])
                guard draft.id.rawValue.hasPrefix(requiredIDPrefix),
                      draft.createdBy == requiredCreatorID,
                      draft.accountID == accountID else {
                    throw PlainpostError.validationFailed("The stored device draft scope is invalid.")
                }
                return draft
            }
        }
    }

    /// The stored message an account holds under this Message-ID, if any.
    public func messageID(accountID: AccountID, rfcMessageID: String) throws -> MessageID? {
        try databasePool.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM messages
                    WHERE account_id = ? AND rfc_message_id = ? AND is_deleted = 0
                    ORDER BY id LIMIT 1
                    """,
                arguments: [accountID.rawValue, rfcMessageID]
            ).map { MessageID($0) }
        }
    }

    public func deleteDraft(
        id: DraftID,
        expectedHash: String,
        actor: Actor,
        requiredIDPrefix: String,
        requiredCreatorID: String
    ) throws {
        guard actor.permissions.createDrafts else {
            throw PlainpostError.permissionDenied("Actor is not allowed to delete drafts.")
        }
        try databasePool.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT payload_json FROM drafts WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                throw PlainpostError.notFound("Draft not found.")
            }
            let existing = try decodeJSON(Draft.self, from: row["payload_json"])
            guard id.rawValue.hasPrefix(requiredIDPrefix),
                  existing.createdBy == requiredCreatorID else {
                throw PlainpostError.permissionDenied("This client cannot access that draft.")
            }
            guard existing.contentHash == expectedHash else {
                throw DraftOptimisticUpdateError.conflict
            }
            try database.execute(
                sql: "DELETE FROM drafts WHERE id = ?",
                arguments: [id.rawValue]
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: "draft.delete",
                targetType: "draft",
                targetID: id.rawValue
            )
        }
        try? flushAuditOutbox()
    }

    public func recordServerDraft(id: DraftID, uid: Int?, mailboxID: String, actor: Actor) throws -> Draft {
        let existing = try draft(id: id)
        let updated = existing.recordingServerDraft(uid: uid, mailboxID: mailboxID)
        try saveDraft(updated)
        try appendAudit(actorID: actor.id, action: "draft.server_sync", targetType: "draft", targetID: id.rawValue)
        return updated
    }

    /// A draft has one send request ID, so asking again replaces the
    /// earlier request. In one write it is refused while an earlier approval
    /// can still send the message or may have sent it
    /// (`refuseReopeningSendRequest`), and replacing a finished request
    /// retires its finished approval and denial jobs, so the new request's
    /// decision runs a job of its own.
    public func requestSend(draftID: DraftID, actor: Actor, reason: String?) throws -> SendRequest {
        let draft = try draft(id: draftID)
        let request = try SendRequestPolicy().requestSend(draft: draft, actor: actor, reason: reason)
        try approvalLock.withLock {
            try databasePool.write { database in
                try refuseReopeningSendRequest(request.id, database: database)
                try retireFinishedDecisionJobs(for: request.id, database: database)
                let ownerAccountID = try String.fetchOne(
                    database,
                    sql: "SELECT owner_account_id FROM drafts WHERE id = ?",
                    arguments: [request.draftID.rawValue]
                )
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO send_requests (id, payload_json, owner_account_id, ownership_kind)
                        VALUES (?, ?, ?, 'account')
                        """,
                    arguments: [request.id.rawValue, try encodeJSON(request), ownerAccountID]
                )
            }
        }
        try appendAudit(actorID: actor.id, action: "send.request", targetType: "send_request", targetID: request.id.rawValue)
        return request
    }

    public static let sendRequestInProgressMessage =
        "This message was already approved or sent. Check Sent before asking to send it again."
    public static let sendRequestPossiblySentMessage =
        "This message may already have been sent. Check Sent before asking to send it again."
    public static let sendRequestApprovalRunningMessage =
        "This message's approved send hasn't finished yet (it's waiting, paused or running). Wait for it before asking again."

    /// A send request may be replaced (asked for again) only when no earlier
    /// approval can still send it or may have sent it:
    /// - its status is not `approved`, `sending`, `sent` or `deliveryUncertain`;
    /// - no approved-delivery job for it, whatever its idempotency key
    ///   (retired or not) or actor, is `delivery-uncertain`;
    /// - no approved-delivery job for it is still queued, running or paused
    ///   (its approval would send the new content, and a request can read
    ///   `failed` while its job is still finishing).
    private func refuseReopeningSendRequest(_ id: SendRequestID, database: Database) throws {
        if let existing = try sendRequest(id: id, database: database) {
            switch existing.status {
            case .approved, .sending, .sent:
                throw PlainpostError.validationFailed(Self.sendRequestInProgressMessage)
            case .deliveryUncertain:
                throw PlainpostError.validationFailed(Self.sendRequestPossiblySentMessage)
            case .pending, .failed, .denied, .cancelled, .expired:
                break
            }
        }
        let states = try String.fetchAll(
            database,
            sql: """
                SELECT state FROM durable_jobs
                WHERE kind = 'approved-delivery' AND json_extract(payload_json, '$.requestID') = ?
                """,
            arguments: [id.rawValue]
        )
        if states.contains(PlainpostOperationState.deliveryUncertain.rawValue) {
            throw PlainpostError.validationFailed(Self.sendRequestPossiblySentMessage)
        }
        let active = [PlainpostOperationState.queued, .running, .paused].map(\.rawValue)
        if states.contains(where: active.contains) {
            throw PlainpostError.validationFailed(Self.sendRequestApprovalRunningMessage)
        }
    }

    /// Retires the replaced request's finished approval and denial jobs, so
    /// the new request's approval or denial runs a job of its own. A
    /// `delivery-uncertain` job is never retired (the refusal above stops
    /// the re-request first).
    private func retireFinishedDecisionJobs(for id: SendRequestID, database: Database) throws {
        try database.execute(
            sql: """
                UPDATE durable_jobs SET idempotency_key = 'retired:' || lower(hex(randomblob(16))) || ':' || idempotency_key
                WHERE idempotency_key IN (?, ?) AND state IN ('completed', 'failed', 'cancelled')
                """,
            arguments: ["approved-delivery:\(id.rawValue)", "deny-send:\(id.rawValue)"]
        )
    }

    public func authorizeAndEnqueueApprovedDelivery(
        draftID: DraftID,
        expectedHash: String,
        actor: Actor,
        reason: String,
        idempotencyKey: String,
        requiredDraftIDPrefix: String
    ) throws -> PlainpostApprovedDeliveryAuthorization {
        let now = Date()
        let authorization = try databasePool.write { database in
            guard let draftRow = try Row.fetchOne(
                database,
                sql: "SELECT payload_json FROM drafts WHERE id = ?",
                arguments: [draftID.rawValue]
            ) else {
                throw PlainpostError.notFound("Draft not found.")
            }
            let draft = try decodeJSON(Draft.self, from: draftRow["payload_json"])
            guard draft.id.rawValue.hasPrefix(requiredDraftIDPrefix), draft.createdBy == actor.id else {
                throw PlainpostError.permissionDenied("This client cannot access that draft.")
            }
            guard draft.contentHash == expectedHash else {
                throw PlainpostError.validationFailed("The draft changed. Reload it before sending.")
            }

            let candidateRequest = try SendRequestPolicy().requestSend(
                draft: draft,
                actor: actor,
                reason: reason
            )
            if let existingRow = try Row.fetchOne(
                database,
                sql: "SELECT * FROM durable_jobs WHERE idempotency_key = ?",
                arguments: [idempotencyKey]
            ) {
                let existing = try decodeJob(existingRow)
                let existingInput = try approvedDeliveryInput(job: existing)
                guard existingInput.requestID == candidateRequest.id,
                      existingInput.actorID == actor.id,
                      let request = try sendRequest(
                          id: candidateRequest.id,
                          database: database
                      ),
                      request.draftID == draft.id,
                      request.requestedDraftHash == expectedHash,
                      request.requestedBy == actor.id else {
                    throw PlainpostError.validationFailed(
                        "The idempotency key belongs to a different delivery."
                    )
                }
                return PlainpostApprovedDeliveryAuthorization(request: request, job: existing)
            }

            let prior = try Row.fetchAll(
                database,
                // Served by the partial expression index on the payload's
                // request ID; the decode below still checks the actor.
                sql: """
                    SELECT * FROM durable_jobs
                    WHERE kind = 'approved-delivery' AND json_extract(payload_json, '$.requestID') = ?
                    ORDER BY created_at DESC, rowid DESC
                    """,
                arguments: [candidateRequest.id.rawValue]
            ).compactMap { row -> PlainpostDurableJob? in
                let job = try decodeJob(row)
                guard let input = try? approvedDeliveryInput(job: job),
                      input.requestID == candidateRequest.id,
                      input.actorID == actor.id else {
                    return nil
                }
                return job
            }
            if let uncertain = prior.first(where: { $0.state == .deliveryUncertain }) {
                guard let request = try sendRequest(id: candidateRequest.id, database: database),
                      request.draftID == draft.id,
                      request.requestedBy == actor.id else {
                    throw PlainpostError.validationFailed(
                        "A prior uncertain delivery receipt does not match this draft."
                    )
                }
                return PlainpostApprovedDeliveryAuthorization(request: request, job: uncertain)
            }

            // A completed job answers a retry only while its request says it
            // sent (or is sending/approved). A completed job whose request
            // settled otherwise (a routed send that later failed) is no
            // receipt: fall through to the re-request.
            let currentStatus = try sendRequest(id: candidateRequest.id, database: database)?.status
            let completedIsReceipt = currentStatus.map { [.sent, .sending, .approved].contains($0) } ?? false
            let reusable = prior.first { [.queued, .running, .paused].contains($0.state) }
                ?? (completedIsReceipt ? prior.first { $0.state == .completed } : nil)
            if let reusable {
                guard let request = try sendRequest(id: candidateRequest.id, database: database),
                      request.draftID == draft.id,
                      request.requestedDraftHash == expectedHash,
                      request.requestedBy == actor.id else {
                    throw PlainpostError.validationFailed(
                        "A prior delivery receipt does not match the current draft."
                    )
                }
                return PlainpostApprovedDeliveryAuthorization(request: request, job: reusable)
            }

            // A new browser authorization replaces the request: never over
            // one another approval can still send or may have sent.
            try refuseReopeningSendRequest(candidateRequest.id, database: database)
            try retireFinishedDecisionJobs(for: candidateRequest.id, database: database)
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO send_requests (id, payload_json, owner_account_id, ownership_kind)
                    VALUES (?, ?, ?, 'account')
                    """,
                arguments: [
                    candidateRequest.id.rawValue,
                    try encodeJSON(candidateRequest),
                    draft.accountID.rawValue,
                ]
            )
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: "send.request",
                targetType: "send_request",
                targetID: candidateRequest.id.rawValue
            )
            let input = PlainpostApprovalDecisionInput(
                requestID: candidateRequest.id,
                actorID: actor.id
            )
            let job = try enqueueJob(
                PlainpostJobRequest(
                    kind: .approvedDelivery,
                    payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                    priority: 100,
                    maxAttempts: 1,
                    idempotencyKey: idempotencyKey
                ),
                database: database,
                now: now
            )
            return PlainpostApprovedDeliveryAuthorization(request: candidateRequest, job: job)
        }
        try? flushAuditOutbox()
        return authorization
    }

    private func approvedDeliveryInput(job: PlainpostDurableJob) throws -> PlainpostApprovalDecisionInput {
        guard job.kind == .approvedDelivery else {
            throw PlainpostError.validationFailed("The delivery job is invalid.")
        }
        return try JSONDecoder().decode(
            PlainpostApprovalDecisionInput.self,
            from: Data(job.payloadJSON.utf8)
        )
    }

    private func ensureApprovedDeliveryJob(
        requestID: SendRequestID,
        actorID: String,
        database: Database,
        now: Date
    ) throws {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: actorID)
        let payload = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        _ = try enqueueJob(
            PlainpostJobRequest(
                kind: .approvedDelivery,
                payloadJSON: payload,
                priority: 100,
                maxAttempts: 1,
                idempotencyKey: "approved-delivery:\(requestID.rawValue)"
            ),
            database: database,
            now: now
        )
    }

    private func sendRequest(id: SendRequestID, database: Database) throws -> SendRequest? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT payload_json FROM send_requests WHERE id = ?",
            arguments: [id.rawValue]
        ) else {
            return nil
        }
        return try decodeJSON(SendRequest.self, from: row["payload_json"])
    }

    public func sendRequest(id: SendRequestID) throws -> SendRequest {
        guard let request = try readSendRequest(id: id) else {
            throw PlainpostError.notFound("Send request not found.")
        }
        return request
    }

    public func cancelSendRequest(id: SendRequestID, actor: Actor) throws -> SendRequest {
        let updated = try approvalLock.withLock {
            try databasePool.write { database in
                guard let request = try sendRequest(id: id, database: database) else {
                    throw PlainpostError.notFound("Send request not found.")
                }
                guard Self.isCanonicalSendTransition(from: request.status, to: .cancelled) else {
                    throw PlainpostError.validationFailed("The send request is no longer eligible for this transition.")
                }
                let updated = request.updating(status: .cancelled)
                try database.execute(
                    sql: "UPDATE send_requests SET payload_json = ? WHERE id = ?",
                    arguments: [try encodeJSON(updated), id.rawValue]
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "send.cancel",
                    targetType: "send_request",
                    targetID: id.rawValue
                )
                return updated
            }
        }
        try? flushAuditOutbox()
        return updated
    }

    public var approvalQueueRequests: [SendRequest] {
        (try? readSendRequests()) ?? []
    }

    public func updateSendRequest(
        id: SendRequestID,
        status: SendRequestStatus,
        approvedBy: String?,
        approvedDraftHash: String?
    ) throws -> SendRequest {
        let updated = try approvalLock.withLock {
            try databasePool.write { database in
                guard let request = try sendRequest(id: id, database: database) else {
                    throw PlainpostError.notFound("Send request not found.")
                }
                guard Self.isCanonicalSendTransition(from: request.status, to: status) else {
                    throw PlainpostError.validationFailed("The send request is no longer eligible for this transition.")
                }
                let updated = request.updating(
                    status: status,
                    approvedBy: approvedBy,
                    approvedDraftHash: approvedDraftHash
                )
                try database.execute(
                    sql: "UPDATE send_requests SET payload_json = ? WHERE id = ?",
                    arguments: [try encodeJSON(updated), id.rawValue]
                )
                try insertAudit(
                    database: database,
                    actorID: approvedBy ?? request.requestedBy,
                    action: "send.\(status.rawValue)",
                    targetType: "send_request",
                    targetID: id.rawValue
                )
                return updated
            }
        }
        try? flushAuditOutbox()
        return updated
    }

    /// Settles a send routed through the mail-intent journal, in one write
    /// and only for the request's own operation (`deliveryOperationID`), so
    /// a re-approval never inherits an earlier approval's outcome. Allowed:
    /// `sending` → `sent`/`failed`/`deliveryUncertain`, and, because the
    /// journal is authoritative where lease recovery acted on missing
    /// information, `deliveryUncertain` → `sent` (the intent is `confirmed`)
    /// or `failed` (the intent failed provably before any provider effect,
    /// or its exact replay was rejected). Returns false when nothing moved,
    /// so exactly one caller acts on a transition (the Sent copy).
    public func settleRoutedSendRequest(id: SendRequestID, operationID: String, to status: SendRequestStatus) throws -> Bool {
        let settled = try approvalLock.withLock {
            try databasePool.write { database -> Bool in
                guard let request = try sendRequest(id: id, database: database),
                      request.deliveryOperationID == operationID
                else { return false }
                switch (request.status, status) {
                case (.sending, .sent), (.sending, .failed), (.sending, .deliveryUncertain),
                     (.deliveryUncertain, .sent), (.deliveryUncertain, .failed):
                    break
                default:
                    return false
                }
                let updated = request.updating(status: status)
                try database.execute(
                    sql: "UPDATE send_requests SET payload_json = ? WHERE id = ?",
                    arguments: [try encodeJSON(updated), id.rawValue]
                )
                try insertAudit(
                    database: database, actorID: request.approvedBy ?? request.requestedBy,
                    action: "send.\(status.rawValue)", targetType: "send_request", targetID: id.rawValue
                )
                return true
            }
        }
        if settled { try? flushAuditOutbox() }
        return settled
    }

    private static func isCanonicalSendTransition(
        from current: SendRequestStatus,
        to next: SendRequestStatus
    ) -> Bool {
        switch (current, next) {
        case (.pending, .approved), (.pending, .denied), (.pending, .cancelled), (.pending, .expired),
             (.approved, .sending), (.approved, .failed), (.approved, .deliveryUncertain),
             (.sending, .sent), (.sending, .failed), (.sending, .deliveryUncertain):
            return true
        default:
            return false
        }
    }

    public func claimSendRequestForDelivery(
        id: SendRequestID,
        currentDraftHash: String,
        actor: Actor
    ) throws -> SendRequest {
        try claimSendRequestForDelivery(id: id, currentDraftHash: currentDraftHash, actor: actor, deliveryOperationID: nil)
    }

    /// `deliveryOperationID`: the mail-intent operation this approval is
    /// routed under, written atomically with the `sending` claim.
    public func claimSendRequestForDelivery(
        id: SendRequestID,
        currentDraftHash: String,
        actor: Actor,
        deliveryOperationID: String?
    ) throws -> SendRequest {
        let request = try approvalLock.withLock {
            try databasePool.write { database in
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT payload_json FROM send_requests WHERE id = ?",
                    arguments: [id.rawValue]
                ) else {
                    throw PlainpostError.notFound("Send request not found.")
                }
                let request = try decodeJSON(SendRequest.self, from: row["payload_json"])
            try ApprovalPolicy.validateApproval(request: request, currentDraftHash: currentDraftHash, actor: actor)
            guard request.status == .pending || request.status == .approved else {
                throw PlainpostError.validationFailed("Send request is already being processed or is no longer pending.")
            }

            let approved: SendRequest
            if request.status == .pending {
                approved = request.updating(
                    status: .approved,
                    approvedBy: actor.id,
                    approvedDraftHash: currentDraftHash
                )
            } else {
                // Preserve an existing approval and only claim the subsequent
                // sending transition.
                guard request.approvedDraftHash == currentDraftHash else {
                    throw PlainpostError.validationFailed("Approved draft hash does not match the current draft.")
                }
                approved = request
            }
            var sending = approved.updating(status: .sending)
            if let deliveryOperationID {
                sending = sending.claimedForRoutedDelivery(operationID: deliveryOperationID)
            }
                try database.execute(
                    sql: "UPDATE send_requests SET payload_json = ? WHERE id = ?",
                    arguments: [try encodeJSON(sending), id.rawValue]
                )
                if request.status == .pending {
                    try insertAudit(
                        database: database,
                        actorID: actor.id,
                        action: "send.approved",
                        targetType: "send_request",
                        targetID: id.rawValue
                    )
                }
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "send.sending",
                    targetType: "send_request",
                    targetID: id.rawValue
                )
                return sending
            }
        }
        try? flushAuditOutbox()
        return request
    }

    private func insertAudit(
        database: Database,
        actorID: String,
        action: String,
        targetType: String,
        targetID: String,
        result: String = "ok",
        ownership explicitOwnership: OwnershipClassification? = nil
    ) throws {
        let ownership = try explicitOwnership ?? Self.auditOwnership(
            action: action, targetType: targetType, targetID: targetID, database: database
        )
        try database.execute(
            sql: """
                INSERT INTO audit_entries (
                    id, actor_id, action, target_type, target_id, result, occurred_at,
                    owner_account_id, ownership_kind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                "aud_\(UUID().uuidString.lowercased())", actorID, action, targetType, targetID, result,
                Date().timeIntervalSince1970, ownership.owner,
                ownership.kind.rawValue,
            ]
            )
    }

    private func canonicalAuditResult<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func auditScope(_ scope: MailLabelScope) -> String {
        switch scope {
        case .allAccounts:
            return "allAccounts"
        case .account(let accountID):
            return "account:\(accountID.rawValue)"
        }
    }

    private func auditScope(_ scope: PlainpostSmartInboxRunScope) -> String {
        switch scope {
        case .allAccounts:
            return "allAccounts"
        case .account(let accountID):
            return "account:\(accountID.rawValue)"
        }
    }

    public func recordSentMessage(draft: Draft, requestID: SendRequestID, actor: Actor) throws -> MessageSummary {
        return try recordSentMessage(
            draft: draft,
            messageID: MessageID("msg_sent_\(requestID.rawValue)"),
            actor: actor,
            auditAction: "message.sent_copy"
        )
    }

    public func recordDirectSentMessage(draft: Draft, actor: Actor) throws -> MessageSummary {
        let rfcMessageID = "<\(draft.id.rawValue)@plainpost.local>"
        return try recordSentMessage(
            draft: draft,
            messageID: MessageID(IMAPSyncService.canonicalMessageID(accountID: draft.accountID, rfcMessageID: rfcMessageID)),
            actor: actor,
            auditAction: "message.direct_send"
        )
    }

    private func recordSentMessage(
        draft: Draft,
        messageID: MessageID,
        actor: Actor,
        auditAction: String
    ) throws -> MessageSummary {
        let sentAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let rfcMessageID = "<\(draft.id.rawValue)@plainpost.local>"
        let sentMailboxID = MailboxID("mbx_\(draft.accountID.rawValue)_sent")
        let message = try databasePool.write { database in
            let sentMailbox = try String.fetchOne(
                database,
                sql: "SELECT sent_mailbox FROM accounts WHERE id = ?",
                arguments: [draft.accountID.rawValue]
            ) ?? "Sent"
            var affectedMailboxOwnerIDs: Set<String> = []
            if let displacedMailbox = try Row.fetchOne(
                database,
                sql: "SELECT account_id, path FROM mailboxes WHERE id = ?",
                arguments: [sentMailboxID.rawValue]
            ) {
                let displacedAccountID: String = displacedMailbox["account_id"]
                let displacedPath: String = displacedMailbox["path"]
                affectedMailboxOwnerIDs.formUnion(try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT message_id FROM mailbox_messages
                        WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                        """,
                    arguments: [displacedAccountID, displacedPath]
                ))
            }
            let message = MessageSummary(
                id: messageID,
                threadID: draft.sourceThreadID,
                from: draft.from,
                subject: draft.subject,
                preview: draft.bodyPlain,
                smartCategory: .personal,
                labels: ["Sent"],
                isSeen: true,
                mailboxPath: sentMailbox,
                isDeleted: false,
                body: draft.bodyPlain,
                sentAt: sentAt,
                rfcMessageID: rfcMessageID,
                inReplyTo: draft.inReplyTo,
                references: draft.references,
                to: draft.to,
                cc: draft.cc
            )
            try database.execute(
                sql: """
                    INSERT INTO mailboxes (id, account_id, name, path, special_use)
                    VALUES (?, ?, ?, ?, '\\Sent')
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        name = excluded.name,
                        path = excluded.path,
                        special_use = excluded.special_use
                    """,
                arguments: [
                    sentMailboxID.rawValue,
                    draft.accountID.rawValue,
                    sentMailbox,
                    sentMailbox,
                ]
            )
            affectedMailboxOwnerIDs.formUnion(try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT message_id FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                    """,
                arguments: [draft.accountID.rawValue, sentMailbox]
            ))
            let values: [String?] = [
                message.id.rawValue, draft.accountID.rawValue, message.threadID?.rawValue,
                message.from.rawValue, message.fromDisplayName, message.subject, message.preview,
                message.body, message.bodyHTML, message.smartCategory.rawValue,
                labelsJSON(message.labels), "1", message.mailboxPath, "0",
                String(sentAt.timeIntervalSince1970), rfcMessageID, message.inReplyTo,
                labelsJSON(message.references), message.replyTo?.rawValue,
                message.to.map(\.rawValue).joined(separator: "\n"),
                message.cc.map(\.rawValue).joined(separator: "\n"),
            ]
            try database.execute(
                sql: """
                    INSERT INTO messages (
                        id, account_id, thread_id, from_email, from_display_name, subject,
                        preview, body_text, body_html, smart_category, labels_json, is_seen,
                        mailbox_path, is_deleted, sent_at, rfc_message_id, in_reply_to,
                        references_json, reply_to_email, to_emails, cc_emails
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id,
                        thread_id = excluded.thread_id,
                        from_email = excluded.from_email,
                        from_display_name = excluded.from_display_name,
                        subject = excluded.subject,
                        preview = excluded.preview,
                        body_text = excluded.body_text,
                        body_html = excluded.body_html,
                        smart_category = excluded.smart_category,
                        labels_json = excluded.labels_json,
                        is_seen = excluded.is_seen,
                        mailbox_path = excluded.mailbox_path,
                        is_deleted = excluded.is_deleted,
                        sent_at = excluded.sent_at,
                        rfc_message_id = excluded.rfc_message_id,
                        in_reply_to = excluded.in_reply_to,
                        references_json = excluded.references_json,
                        reply_to_email = excluded.reply_to_email,
                        to_emails = excluded.to_emails,
                        cc_emails = excluded.cc_emails
                """,
                arguments: StatementArguments(values)
            )
            try importUserVisibleLabels(
                message.labels,
                database: database,
                messageID: message.id.rawValue,
                accountID: draft.accountID.rawValue,
                actorID: actor.id
            )
            let existingLocalUID = try Int.fetchOne(
                database,
                sql: """
                    SELECT uid FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                      AND uid_validity = 0 AND message_id = ?
                    LIMIT 1
                    """,
                arguments: [draft.accountID.rawValue, sentMailbox, message.id.rawValue]
            )
            let localUID = try existingLocalUID ?? Self.allocateLocalMailboxUID(
                accountID: draft.accountID.rawValue,
                mailboxPath: sentMailbox,
                database: database
            )
            if existingLocalUID == nil {
                try database.execute(
                    sql: """
                        INSERT INTO mailbox_messages (
                            account_id, mailbox_path, uid_validity, uid, message_id,
                            flags, internal_date
                        ) VALUES (?, ?, 0, ?, ?, '\\Seen', ?)
                        """,
                    arguments: [
                        draft.accountID.rawValue,
                        sentMailbox,
                        localUID,
                        message.id.rawValue,
                        sentAt.timeIntervalSince1970,
                    ]
                )
            }
            try SQLiteMailSearchProjectionWriter.upsert(
                messageID: message.id,
                metadata: IncomingMessageSearchMetadata(
                    to: draft.to,
                    cc: draft.cc,
                    bcc: draft.bcc,
                    attachments: draft.attachments.map {
                        IncomingMessageAttachmentMetadata(
                            filename: $0.filename,
                            mimeType: $0.mimeType
                        )
                    },
                    messageIdentifiers: [rfcMessageID] + draft.references
                ),
                database: database
            )
            affectedMailboxOwnerIDs.remove(message.id.rawValue)
            for affectedMessageID in affectedMailboxOwnerIDs.sorted() {
                try Self.refreshSearchProjectionIfIndexable(
                    messageID: MessageID(affectedMessageID),
                    database: database
                )
            }
            try insertAudit(
                database: database,
                actorID: actor.id,
                action: auditAction,
                targetType: "message",
                targetID: message.id.rawValue
            )
            return message
        }
        MailStoreChangeSignal.post(scope: .mailbox)
        return message
    }

    public func recordSendWarning(requestID: SendRequestID, action: String, actor: Actor) {
        try? appendAudit(actorID: actor.id, action: action, targetType: "send_request", targetID: requestID.rawValue)
    }

    // MARK: - Durable local operations

    public func enqueueJob(_ request: PlainpostJobRequest) throws -> PlainpostDurableJob {
        let now = Date()
        let result: PlainpostDurableJob = try databasePool.write { database in
            try enqueueJob(request, database: database, now: now)
        }
        MailStoreChangeSignal.post(scope: .operations)
        return result
    }

    public func enqueueCoalescedInboxSyncJob(
        _ input: PlainpostInboxSyncInput,
        priority: Int? = nil,
        idempotencyKey: String? = nil,
        replaceTerminalDuplicate: Bool = true
    ) throws -> PlainpostDurableJob {
        let payload = try JSONEncoder().encode(input)
        let accountID = input.accountID.rawValue
        let effectivePriority = priority ?? input.schedulingPriority
        let sourceIdentity = input.expectedDirectSourceGeneration.map { ":direct-generation:\($0)" } ?? ""
        let canonicalIdentity = "sync-active:v6:\(accountID.utf8.count):\(accountID):\(input.scope.rawValue):\(Self.inboxSyncDurableIdentity(input))\(sourceIdentity)"
        let explicitIdentity = idempotencyKey.map { key in
            guard let generation = input.expectedDirectSourceGeneration else { return key }
            return "sync-direct-request:v1:\(accountID.utf8.count):\(accountID):\(generation):\(key.utf8.count):\(key)"
        }
        let durableIdentity = Self.isBackgroundInboxSync(input)
            ? canonicalIdentity
            : (explicitIdentity ?? canonicalIdentity)
        let request = PlainpostJobRequest(
            kind: input.scope == .completeHistory ? .historicalSync : .inboxSync,
            payloadJSON: String(decoding: payload, as: UTF8.self),
            priority: effectivePriority,
            idempotencyKey: durableIdentity,
            replaceTerminalDuplicate: replaceTerminalDuplicate
        )
        let now = Date()
        return try databasePool.write { database in
            if let generation = input.expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: input.accountID, generation: generation, allowNodeFallback: true, database: database
                )
                if let existing = try Row.fetchOne(
                    database,
                    sql: "SELECT * FROM durable_jobs WHERE idempotency_key = ?",
                    arguments: [durableIdentity]
                ) {
                    let job = try decodeJob(existing)
                    let existingInput = try? JSONDecoder().decode(
                        PlainpostInboxSyncInput.self, from: Data(job.payloadJSON.utf8)
                    )
                    guard job.kind == request.kind, existingInput == input else {
                        throw NodeMailModeStoreError.generationConflict
                    }
                }
            }
            if Self.isBackgroundInboxSync(input) {
                try retireCancellationRequestedBackgroundIdentity(
                    matching: input,
                    canonicalIdentity: durableIdentity,
                    database: database
                )
            }
            let activeJobRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM durable_jobs
                    WHERE kind IN ('inbox-sync', 'historical-sync')
                      AND state IN ('queued', 'running', 'paused')
                      AND cancellation_requested = 0
                    ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END, created_at, id
                    """
            )
            let activeRows = try activeJobRows.lazy.compactMap { row -> (PlainpostDurableJob, PlainpostInboxSyncInput)? in
                guard let activeInput = try? JSONDecoder().decode(
                    PlainpostInboxSyncInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), activeInput.accountID == input.accountID else {
                    return nil
                }
                return (try decodeJob(row), activeInput)
            }
            if let equivalent = activeRows.first(where: {
                Self.equivalentInboxSyncWork($0.1, input)
            }) {
                return try mergeEquivalentInboxSyncWork(
                    equivalent.0,
                    existingInput: equivalent.1,
                    requestedInput: input,
                    priority: effectivePriority,
                    database: database,
                    now: now
                )
            }
            if let queuedBackground = activeRows.first(where: {
                $0.0.state == .queued && Self.canUpgradeQueuedInboxSync($0.1, with: input)
            }) {
                let upgraded = try upgradeQueuedInboxSync(
                    queuedBackground.0,
                    with: input,
                    priority: effectivePriority,
                    database: database,
                    now: now
                )
                return upgraded
            }
            return try enqueueJob(request, database: database, now: now)
        }
    }

    private func retireCancellationRequestedBackgroundIdentity(
        matching requestedInput: PlainpostInboxSyncInput,
        canonicalIdentity: String,
        database: Database
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, payload_json FROM durable_jobs
                WHERE kind IN ('inbox-sync', 'historical-sync')
                  AND state = 'running'
                  AND cancellation_requested = 1
                  AND idempotency_key = ?
                ORDER BY id
                """,
            arguments: [canonicalIdentity]
        )
        for row in rows {
            guard let existingInput = try? JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data((row["payload_json"] as String).utf8)
            ), Self.equivalentInboxSyncWork(existingInput, requestedInput) else {
                continue
            }
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET idempotency_key = ?
                    WHERE id = ? AND state = 'running'
                      AND cancellation_requested = 1
                      AND idempotency_key = ?
                    """,
                arguments: [
                    "retired:cancelled-predecessor:\(UUID().uuidString.lowercased())",
                    row["id"] as String,
                    canonicalIdentity,
                ]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed(
                    "Cancellation-requested inbox sync identity could not be retired."
                )
            }
        }
    }

    private static func equivalentInboxSyncWork(
        _ existing: PlainpostInboxSyncInput,
        _ requested: PlainpostInboxSyncInput
    ) -> Bool {
        guard existing.accountID == requested.accountID,
              existing.scope == requested.scope,
              existing.expectedDirectSourceGeneration == requested.expectedDirectSourceGeneration else {
            return false
        }
        if isBackgroundInboxSync(existing), isBackgroundInboxSync(requested) {
            return true
        }
        return existing.trigger == requested.trigger
    }

    private static func isBackgroundInboxSync(_ input: PlainpostInboxSyncInput) -> Bool {
        input.trigger == .schedule || input.trigger == .realTimeSignal
    }

    private static func inboxSyncDurableIdentity(_ input: PlainpostInboxSyncInput) -> String {
        isBackgroundInboxSync(input) ? "background" : input.trigger.rawValue
    }

    private static func mergedBackgroundTrigger(
        _ existing: PlainpostInboxSyncInput,
        _ requested: PlainpostInboxSyncInput
    ) -> PlainpostInboxSyncTrigger {
        if existing.trigger == .schedule || requested.trigger == .schedule {
            return .schedule
        }
        return .realTimeSignal
    }

    private static func canUpgradeQueuedInboxSync(
        _ existing: PlainpostInboxSyncInput,
        with requested: PlainpostInboxSyncInput
    ) -> Bool {
        existing.accountID == requested.accountID
            && existing.expectedDirectSourceGeneration == requested.expectedDirectSourceGeneration
            && (existing.trigger == .realTimeSignal || existing.trigger == .schedule)
            && isStrongerInboxSyncWork(requested, than: existing)
    }

    private static func isStrongerInboxSyncWork(
        _ existing: PlainpostInboxSyncInput,
        than requested: PlainpostInboxSyncInput
    ) -> Bool {
        guard existing.accountID == requested.accountID else { return false }
        guard existing.expectedDirectSourceGeneration == requested.expectedDirectSourceGeneration else { return false }
        let scopeStrength: (PlainpostSyncScope) -> Int = {
            switch $0 {
            case .incremental: 0
            case .recent: 1
            case .completeHistory: 2
            }
        }
        let existingScopeStrength = scopeStrength(existing.scope)
        let requestedScopeStrength = scopeStrength(requested.scope)
        let existingPriority = existing.schedulingPriority
        let requestedPriority = requested.schedulingPriority
        return existingScopeStrength >= requestedScopeStrength
            && existingPriority >= requestedPriority
            && (existingScopeStrength > requestedScopeStrength || existingPriority > requestedPriority)
    }

    private func upgradeQueuedInboxSync(
        _ queued: PlainpostDurableJob,
        with input: PlainpostInboxSyncInput,
        priority: Int,
        database: Database,
        now: Date
    ) throws -> PlainpostDurableJob {
        let payloadJSON = String(
            decoding: try JSONEncoder().encode(input),
            as: UTF8.self
        )
        let kind: PlainpostOperationKind = input.scope == .completeHistory
            ? .historicalSync
            : .inboxSync
        let scope = try Self.makeSyncJobScope(database: database, input: input)
        try database.execute(
            sql: """
                UPDATE durable_jobs
                SET kind = ?, payload_json = ?, priority = MAX(priority, ?), updated_at = ?
                WHERE id = ? AND state = 'queued'
                """,
            arguments: [
                kind.rawValue,
                payloadJSON,
                priority,
                now.timeIntervalSince1970,
                queued.id,
            ]
        )
        guard database.changesCount == 1 else {
            throw PlainpostError.validationFailed("Queued inbox sync job could not be upgraded.")
        }
        try Self.ensureSyncJobScope(database: database, jobID: queued.id, input: input)
        try database.execute(
            sql: """
                UPDATE sync_job_scopes
                SET scope_fingerprint = ?, mailbox_paths_json = ?, recent_message_limit = ?,
                    download_complete_history = ?, incremental_only = ?, establishes_readiness = ?,
                    reconciliation_generation = MAX(reconciliation_generation, ?)
                WHERE job_id = ?
                """,
            arguments: [
                scope.fingerprint,
                String(decoding: try JSONEncoder().encode(scope.mailboxPaths), as: UTF8.self),
                scope.recentMessageLimit,
                scope.downloadCompleteHistory,
                scope.incrementalOnly,
                scope.establishesReadiness,
                scope.reconciliationGeneration,
                queued.id,
            ]
        )
        guard database.changesCount == 1 else {
            throw PlainpostError.validationFailed("Queued inbox sync scope could not be upgraded.")
        }
        try database.execute(
            sql: """
                UPDATE account_sync_readiness
                SET sync_job_id = ?, scope_fingerprint = ?, updated_at = ?
                WHERE account_id = ?
                """,
            arguments: [
                queued.id,
                scope.establishesReadiness ? scope.fingerprint : nil,
                now.timeIntervalSince1970,
                input.accountID.rawValue,
            ]
        )
        guard let upgradedRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM durable_jobs WHERE id = ?",
            arguments: [queued.id]
        ) else {
            throw PlainpostError.notFound("Inbox sync job not found.")
        }
        return try decodeJob(upgradedRow)
    }

    private func mergeEquivalentInboxSyncWork(
        _ active: PlainpostDurableJob,
        existingInput: PlainpostInboxSyncInput,
        requestedInput: PlainpostInboxSyncInput,
        priority: Int,
        database: Database,
        now: Date
    ) throws -> PlainpostDurableJob {
        guard Self.isBackgroundInboxSync(existingInput),
              Self.isBackgroundInboxSync(requestedInput) else {
            return try resumeCredentialBlockedInboxSyncIfNeeded(
                active,
                database: database,
                now: now
            )
        }
        let mergedInput = PlainpostInboxSyncInput(
            accountID: existingInput.accountID,
            trigger: Self.mergedBackgroundTrigger(existingInput, requestedInput),
            scope: existingInput.scope,
            expectedDirectSourceGeneration: existingInput.expectedDirectSourceGeneration
        )
        let mergedPayload = String(
            decoding: try JSONEncoder().encode(mergedInput),
            as: UTF8.self
        )
        try database.execute(
            sql: """
                UPDATE durable_jobs
                SET payload_json = CASE WHEN state = 'running' THEN payload_json ELSE ? END,
                    priority = MAX(priority, ?), updated_at = ?
                WHERE id = ? AND state IN ('queued', 'running', 'paused')
                """,
            arguments: [mergedPayload, priority, now.timeIntervalSince1970, active.id]
        )
        guard database.changesCount == 1 else {
            throw PlainpostError.validationFailed("Equivalent inbox sync job is no longer active.")
        }
        try Self.ensureSyncJobScope(
            database: database,
            jobID: active.id,
            input: existingInput
        )
        if Self.requiresRemoteStateReconciliation(requestedInput) {
            try database.execute(
                sql: """
                    UPDATE sync_job_scopes
                    SET reconciliation_generation = reconciliation_generation + 1
                    WHERE job_id = ?
                    """,
                arguments: [active.id]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed(
                    "Equivalent inbox sync reconciliation could not be retained."
                )
            }
        }
        guard let mergedRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM durable_jobs WHERE id = ?",
            arguments: [active.id]
        ) else {
            throw PlainpostError.notFound("Inbox sync job not found.")
        }
        return try resumeCredentialBlockedInboxSyncIfNeeded(
            try decodeJob(mergedRow),
            database: database,
            now: now
        )
    }

    private func resumeCredentialBlockedInboxSyncIfNeeded(
        _ job: PlainpostDurableJob,
        database: Database,
        now: Date
    ) throws -> PlainpostDurableJob {
        guard job.state == .paused, job.pauseReason == "credentials-unavailable" else {
            return job
        }
        try database.execute(
            sql: """
                UPDATE durable_jobs
                SET state = 'queued', pause_reason = NULL, progress_phase = 'queued',
                    progress_label = NULL, available_at = ?, updated_at = ?
                WHERE id = ? AND state = 'paused' AND pause_reason = 'credentials-unavailable'
                """,
            arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, job.id]
        )
        guard let resumed = try Row.fetchOne(
            database,
            sql: "SELECT * FROM durable_jobs WHERE id = ?",
            arguments: [job.id]
        ) else {
            throw PlainpostError.notFound("Inbox sync job not found.")
        }
        return try decodeJob(resumed)
    }

    package func resolvedSmartInboxInput(
        _ input: PlainpostAIOperationInput
    ) throws -> PlainpostAIOperationInput {
        let resolvedInput = input.resolvingSmartInboxClassifierIdentity()
        if resolvedInput.smartInboxRunMode == .rerunAll,
           let requestedLabelID = resolvedInput.smartInboxRunRequest.requestedLabelID {
            guard let requestedLabel = try mailLabel(id: requestedLabelID) else {
                throw MailLabelValidationError.unknownLabel
            }
            let scope: PlainpostSmartInboxRunScope = requestedLabel.scope.accountID
                .map(PlainpostSmartInboxRunScope.account)
                ?? .allAccounts
            return PlainpostAIOperationInput(
                operation: resolvedInput.operation,
                recordID: resolvedInput.recordID,
                conversationReferenceKind: resolvedInput.conversationReferenceKind,
                accountID: resolvedInput.accountID,
                expectedDirectSourceGeneration: resolvedInput.expectedDirectSourceGeneration,
                providerID: resolvedInput.providerID,
                modelID: resolvedInput.modelID,
                question: resolvedInput.question,
                conversation: resolvedInput.conversation,
                retrievalScope: resolvedInput.retrievalScope,
                activeConversationKey: resolvedInput.activeConversationKey,
                smartInboxRunRequest: PlainpostSmartInboxRunRequest(
                    mode: .rerunAll,
                    scope: scope,
                    requestedLabelID: requestedLabelID
                ),
                smartInboxRequestID: resolvedInput.smartInboxRequestID,
                smartInboxClassifierIdentity: resolvedInput.smartInboxClassifierIdentity,
                enqueueOnly: resolvedInput.enqueueOnly,
                askMailFilterOverride: resolvedInput.askMailFilterOverride
            )
        }
        return resolvedInput
    }

    func enqueueSmartInboxJob(
        input: PlainpostAIOperationInput
    ) throws -> PlainpostSmartInboxJobEnqueueResult {
        let durableInput = try resolvedSmartInboxInput(input)
        let catalogSnapshot = try smartInboxLabelCatalogSnapshot()
        let classificationInputs = try smartInboxClassificationInputs(
            scope: durableInput.smartInboxRunRequest.scope
        )
        return try enqueueSmartInboxJob(
            input: durableInput,
            classificationInputs: classificationInputs,
            catalogSnapshot: catalogSnapshot
        )
    }

    package func enqueueSmartInboxJob(
        input: PlainpostAIOperationInput,
        classificationInputs: [SmartInboxClassificationInput],
        catalogSnapshot: MailLabelCatalogSnapshot
    ) throws -> PlainpostSmartInboxJobEnqueueResult {
        let durableInput = try resolvedSmartInboxInput(input)
        if case .account(let accountID) = durableInput.smartInboxRunRequest.scope,
           classificationInputs.contains(where: { $0.accountID != accountID }) {
            throw PlainpostError.validationFailed(
                "Smart Inbox classification inputs must match the requested account scope."
            )
        }
        let payload = try JSONEncoder().encode(durableInput)
        let classifierDiscriminator = durableInput.resolvedSmartInboxClassifierIdentity.discriminator
        let now = Date()
        let result: PlainpostSmartInboxJobEnqueueResult = try databasePool.write { database in
            try Self.requireSmartInboxEnabled(in: database)
            try Self.requireSmartInboxDirectSource(input: durableInput, database: database)
            if let requestedLabelID = durableInput.smartInboxRunRequest.requestedLabelID {
                guard let labelRow = try Row.fetchOne(
                    database,
                    sql: "SELECT scope_account_id FROM mail_labels WHERE id = ?",
                    arguments: [requestedLabelID]
                ) else {
                    throw MailLabelValidationError.unknownLabel
                }
                let rawAccountID: String? = labelRow["scope_account_id"]
                let currentScope: PlainpostSmartInboxRunScope = rawAccountID
                    .map { .account(AccountID($0)) }
                    ?? .allAccounts
                guard currentScope == durableInput.smartInboxRunRequest.scope else {
                    throw PlainpostError.validationFailed(
                        "The requested Smart Inbox label scope changed before enqueue."
                    )
                }
            }
            if durableInput.smartInboxRunMode == .rerunAll {
                guard durableInput.smartInboxRequestID?.isEmpty == false else {
                    throw PlainpostError.validationFailed("A full Smart Inbox rerun requires a request ID.")
                }
                if let active = try activeSmartInboxRerunJob(
                    database: database,
                    classifierIdentity: durableInput.resolvedSmartInboxClassifierIdentity,
                    scope: durableInput.smartInboxRunRequest.scope,
                    catalogFingerprint: catalogSnapshot.fingerprint
                ) {
                    if let activeInput = try? JSONDecoder().decode(
                        PlainpostAIOperationInput.self, from: Data(active.payloadJSON.utf8)
                    ), activeInput.expectedDirectSourceGeneration == durableInput.expectedDirectSourceGeneration {
                    return .job(active)
                    }
                }
            } else if let activeIncremental = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM durable_jobs
                    WHERE kind = 'ai-operation' AND state IN ('queued', 'running', 'paused')
                      AND NOT (state = 'paused' AND pause_reason = 'smart-inbox-follow-up')
                    ORDER BY created_at, id
                    """
            ).lazy.compactMap({ row -> PlainpostDurableJob? in
                guard let activeInput = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), activeInput.operation == .recategorizeInbox,
                   activeInput.smartInboxRunMode == .incremental,
                   activeInput.smartInboxRunRequest.scope == durableInput.smartInboxRunRequest.scope,
                   activeInput.expectedDirectSourceGeneration == durableInput.expectedDirectSourceGeneration,
                   activeInput.resolvedSmartInboxClassifierIdentity
                    == durableInput.resolvedSmartInboxClassifierIdentity else {
                    return nil
                }
                let activeCatalogFingerprint = try? String.fetchOne(
                    database,
                    sql: """
                        SELECT catalog_fingerprint
                        FROM smart_inbox_label_catalog_snapshots
                        WHERE job_id = ?
                        """,
                    arguments: [row["id"] as String]
                )
                guard activeCatalogFingerprint == catalogSnapshot.fingerprint else {
                    return nil
                }
                return try decodeJob(row)
            }).first {
                let hasEligibleWork = try !eligibleIncrementalSmartInboxInputs(
                    database: database,
                    classificationInputs: classificationInputs,
                    classifierDiscriminator: classifierDiscriminator,
                    catalogFingerprint: catalogSnapshot.fingerprint
                ).isEmpty
                let isPrepared = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM smart_inbox_work_preparations WHERE job_id = ?)",
                    arguments: [activeIncremental.id]
                ) ?? false
                if isPrepared, hasEligibleWork {
                    let existingSuccessorID = try String.fetchOne(
                        database,
                        sql: """
                            SELECT successor_job_id
                            FROM smart_inbox_incremental_follow_up_demands
                            WHERE predecessor_job_id = ?
                            """,
                        arguments: [activeIncremental.id]
                    )
                    let successorID: String
                    if let existingSuccessorID {
                        successorID = existingSuccessorID
                    } else {
                        let successor = try enqueueJob(
                            PlainpostJobRequest(
                                kind: .aiOperation,
                                payloadJSON: String(decoding: payload, as: UTF8.self),
                                priority: durableInput.operation.priority,
                                idempotencyKey: "ai:recategorizeInbox:follow-up:\(activeIncremental.id)"
                            ),
                            database: database,
                            now: now
                        )
                        successorID = successor.id
                        try database.execute(
                            sql: """
                                UPDATE durable_jobs
                                SET state = 'paused', pause_reason = 'smart-inbox-follow-up',
                                    progress_phase = 'paused'
                                WHERE id = ?
                            """,
                            arguments: [successorID]
                        )
                        let labelsJSON = String(
                            decoding: try JSONEncoder().encode(catalogSnapshot.labels),
                            as: UTF8.self
                        )
                        try database.execute(
                            sql: """
                                INSERT INTO smart_inbox_label_catalog_snapshots (
                                    job_id, catalog_fingerprint, labels_json, created_at
                                ) VALUES (?, ?, ?, ?)
                                """,
                            arguments: [
                                successorID,
                                catalogSnapshot.fingerprint,
                                labelsJSON,
                                catalogSnapshot.createdAt.timeIntervalSince1970,
                            ]
                        )
                    }
                    try database.execute(
                        sql: """
                            INSERT INTO smart_inbox_incremental_follow_up_demands (
                                predecessor_job_id, successor_job_id, payload_json, created_at
                            ) VALUES (?, ?, ?, ?)
                            ON CONFLICT(predecessor_job_id) DO UPDATE SET
                                successor_job_id = excluded.successor_job_id,
                                payload_json = excluded.payload_json,
                                created_at = excluded.created_at
                            """,
                        arguments: [activeIncremental.id, successorID, String(decoding: payload, as: UTF8.self), now.timeIntervalSince1970]
                    )
                }
                return .job(activeIncremental)
            }
            let eligible = durableInput.smartInboxRunMode == .rerunAll
                ? classificationInputs
                : try eligibleIncrementalSmartInboxInputs(
                    database: database,
                    classificationInputs: classificationInputs,
                    classifierDiscriminator: classifierDiscriminator,
                    catalogFingerprint: catalogSnapshot.fingerprint
                )
            if durableInput.smartInboxRunMode == .incremental, eligible.isEmpty {
                return .upToDate
            }
            let discriminator: String
            switch durableInput.smartInboxRunMode {
            case .incremental:
                discriminator = "incremental:\(durableInput.smartInboxRunRequest.scope.identityValue)"
            case .rerunAll:
                discriminator = "rerun-current-workset:\(durableInput.smartInboxRunRequest.scope.identityValue)"
            }
            let sourceDiscriminator = durableInput.expectedDirectSourceGeneration.map {
                ":direct-generation:\($0)"
            } ?? ""
            let fingerprint = SmartInboxClassificationFingerprint.workSet(
                inputs: eligible,
                discriminator: discriminator + sourceDiscriminator,
                classifierDiscriminator: classifierDiscriminator,
                catalogFingerprint: catalogSnapshot.fingerprint
            )
            let request = PlainpostJobRequest(
                kind: .aiOperation,
                payloadJSON: String(decoding: payload, as: UTF8.self),
                priority: durableInput.operation.priority,
                idempotencyKey: "ai:recategorizeInbox:v3:\(fingerprint)",
                replaceTerminalDuplicate: durableInput.smartInboxRunMode == .rerunAll
            )
            let job = try enqueueJob(request, database: database, now: now)
            let labelsJSON = String(
                decoding: try JSONEncoder().encode(catalogSnapshot.labels),
                as: UTF8.self
            )
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO smart_inbox_label_catalog_snapshots (
                        job_id, catalog_fingerprint, labels_json, created_at
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    job.id,
                    catalogSnapshot.fingerprint,
                    labelsJSON,
                    catalogSnapshot.createdAt.timeIntervalSince1970,
                ]
            )
            if durableInput.smartInboxRunMode == .rerunAll {
                let ownership = try Self.requiredJobOwnership(jobID: job.id, database: database)
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "smart_inbox.reclassification.start",
                    targetType: "smart_inbox_reclassification",
                    targetID: job.id,
                    result: try canonicalAuditResult(
                        SmartInboxReclassificationStartAuditResult(
                            jobID: job.id,
                            messageCount: eligible.count,
                            modelID: durableInput.resolvedSmartInboxClassifierIdentity.modelID,
                            providerID: durableInput.resolvedSmartInboxClassifierIdentity.providerID,
                            requestedLabelID: durableInput.smartInboxRunRequest.requestedLabelID,
                            scope: auditScope(durableInput.smartInboxRunRequest.scope)
                        )
                    ),
                    ownership: ownership
                )
            }
            return .job(job)
        }
        if durableInput.smartInboxRunMode == .rerunAll {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return result
    }

    public func activeSmartInboxRerunJob() throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            try activeSmartInboxRerunJob(
                database: database,
                classifierIdentity: nil,
                scope: nil,
                catalogFingerprint: nil
            )
        }
    }

    public func activeSmartInboxRerunJob(
        accountID: AccountID,
        sourceGeneration: Int64
    ) throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            try Self.requireDirectSource(
                accountID: accountID, generation: sourceGeneration, database: database
            )
            return try activeSmartInboxRerunJob(
                database: database,
                classifierIdentity: nil,
                scope: .account(accountID),
                catalogFingerprint: nil,
                selectedAccountID: accountID,
                selectedSourceGeneration: sourceGeneration
            )
        }
    }

    public func latestSmartInboxRerunJob() throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM durable_jobs
                    WHERE kind = 'ai-operation'
                    ORDER BY created_at DESC, rowid DESC
                    """
            )
            return try rows.lazy.compactMap { row -> PlainpostDurableJob? in
                guard let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data((row["payload_json"] as String).utf8)
                ), input.operation == .recategorizeInbox, input.smartInboxRunMode == .rerunAll else {
                    return nil
                }
                return try decodeJob(row)
            }.first
        }
    }

    public func smartInboxActivityJob(now: Date = Date()) throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            try smartInboxActivityJob(database: database, now: now)
        }
    }

    public func smartInboxActivityJob(
        accountID: AccountID,
        sourceGeneration: Int64,
        now: Date = Date()
    ) throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            try Self.requireDirectSource(
                accountID: accountID, generation: sourceGeneration, database: database
            )
            return try smartInboxActivityJob(
                database: database, now: now,
                selectedAccountID: accountID, selectedSourceGeneration: sourceGeneration
            )
        }
    }

    private func smartInboxActivityJob(
        database: Database,
        now: Date,
        selectedAccountID: AccountID? = nil,
        selectedSourceGeneration: Int64? = nil
    ) throws -> PlainpostDurableJob? {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT * FROM durable_jobs
                WHERE kind = 'ai-operation'
                  AND (? IS NULL OR (owner_account_id = ? AND ownership_kind = 'account'))
                  AND (
                    state IN ('queued', 'running', 'paused')
                    OR (state = 'failed' AND updated_at >= ?)
                  )
                ORDER BY
                  CASE state
                    WHEN 'running' THEN 0
                    WHEN 'paused' THEN CASE pause_reason
                      WHEN 'user-requested' THEN 1
                      WHEN 'low-power' THEN 1
                      WHEN 'smart-inbox-follow-up' THEN 4
                      ELSE 2
                    END
                    WHEN 'queued' THEN 3
                    WHEN 'failed' THEN 5
                    ELSE 6
                  END,
                  updated_at DESC,
                  rowid DESC
                """,
            arguments: [
                selectedAccountID?.rawValue, selectedAccountID?.rawValue,
                now.addingTimeInterval(-3_600).timeIntervalSince1970,
            ]
        )
        return try rows.lazy.compactMap { row -> PlainpostDurableJob? in
            guard let input = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data((row["payload_json"] as String).utf8)
            ), input.operation == .recategorizeInbox else {
                return nil
            }
            if let selectedAccountID {
                guard input.smartInboxRunRequest.scope == .account(selectedAccountID),
                      input.accountID == selectedAccountID,
                      input.expectedDirectSourceGeneration == selectedSourceGeneration else {
                    return nil
                }
            }
            return try decodeJob(row)
        }.first
    }

    private func activeSmartInboxRerunJob(
        database: Database,
        classifierIdentity: SmartInboxClassifierIdentity?,
        scope: PlainpostSmartInboxRunScope?,
        catalogFingerprint: String?,
        selectedAccountID: AccountID? = nil,
        selectedSourceGeneration: Int64? = nil
    ) throws -> PlainpostDurableJob? {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT * FROM durable_jobs
                WHERE kind = 'ai-operation' AND state IN ('queued', 'running', 'paused')
                  AND (? IS NULL OR (owner_account_id = ? AND ownership_kind = 'account'))
                ORDER BY created_at, id
                """,
            arguments: [selectedAccountID?.rawValue, selectedAccountID?.rawValue]
        )
        for row in rows {
            guard let input = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data((row["payload_json"] as String).utf8)
            ), input.operation == .recategorizeInbox, input.smartInboxRunMode == .rerunAll else {
                continue
            }
            if let classifierIdentity,
               input.resolvedSmartInboxClassifierIdentity != classifierIdentity {
                continue
            }
            if let scope, input.smartInboxRunRequest.scope != scope {
                continue
            }
            if let selectedAccountID,
               (input.smartInboxRunRequest.scope != .account(selectedAccountID)
                || input.accountID != selectedAccountID
                || input.expectedDirectSourceGeneration != selectedSourceGeneration) {
                continue
            }
            if let catalogFingerprint {
                let storedFingerprint = try String.fetchOne(
                    database,
                    sql: """
                        SELECT catalog_fingerprint
                        FROM smart_inbox_label_catalog_snapshots
                        WHERE job_id = ?
                        """,
                    arguments: [row["id"] as String]
                )
                if storedFingerprint != catalogFingerprint {
                    continue
                }
            }
            return try decodeJob(row)
        }
        return nil
    }

    private func enqueueJob(
        _ request: PlainpostJobRequest,
        database: Database,
        now: Date
    ) throws -> PlainpostDurableJob {
        if request.kind == .aiOperation,
           let input = try? JSONDecoder().decode(PlainpostAIOperationInput.self, from: Data(request.payloadJSON.utf8)),
           input.operation == .recategorizeInbox {
            try Self.requireSmartInboxEnabled(in: database)
        }
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM durable_jobs WHERE idempotency_key = ?",
            arguments: [request.idempotencyKey]
        ) {
            let existing = try decodeJob(row)
            if request.replaceTerminalDuplicate,
               [.completed, .failed, .cancelled, .deliveryUncertain].contains(existing.state) {
                try database.execute(
                    sql: "UPDATE durable_jobs SET idempotency_key = ? WHERE id = ?",
                    arguments: [
                        "retired:\(UUID().uuidString.lowercased()):\(existing.idempotencyKey)",
                        existing.id,
                    ]
                )
            } else {
                return existing
            }
        }

        let job = PlainpostDurableJob(
            id: "job_\(UUID().uuidString.lowercased())",
            kind: request.kind,
            payloadJSON: request.payloadJSON,
            priority: request.priority,
            availableAt: request.availableAt ?? now,
            maxAttempts: request.maxAttempts,
            idempotencyKey: request.idempotencyKey,
            createdAt: now,
            updatedAt: now
        )
        let ownership = try Self.operationOwnership(
            kind: request.kind,
            payloadJSON: request.payloadJSON,
            database: database
        )
        try database.execute(
            sql: """
                INSERT INTO durable_jobs (
                    id, kind, payload_json, state, priority, available_at, attempt, max_attempts,
                    cancellation_requested, idempotency_key, created_at, updated_at,
                    owner_account_id, ownership_kind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                """,
            arguments: [
                job.id, job.kind.rawValue, job.payloadJSON, job.state.rawValue,
                job.priority, job.availableAt.timeIntervalSince1970, job.attempt,
                job.maxAttempts, job.idempotencyKey,
                job.createdAt.timeIntervalSince1970, job.updatedAt.timeIntervalSince1970,
                ownership.owner,
                ownership.kind.rawValue,
            ]
        )
        if request.kind == .inboxSync || request.kind == .historicalSync,
           let input = try? JSONDecoder().decode(
               PlainpostInboxSyncInput.self,
               from: Data(request.payloadJSON.utf8)
           ) {
            let scope = try Self.makeSyncJobScope(database: database, input: input)
            try database.execute(
                sql: """
                INSERT INTO sync_job_scopes (
                    job_id, scope_fingerprint, mailbox_paths_json, recent_message_limit,
                    download_complete_history, incremental_only, establishes_readiness,
                    reconciliation_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    job.id,
                    scope.fingerprint,
                    String(decoding: try JSONEncoder().encode(scope.mailboxPaths), as: UTF8.self),
                    scope.recentMessageLimit,
                    scope.downloadCompleteHistory,
                    scope.incrementalOnly,
                    scope.establishesReadiness,
                    scope.reconciliationGeneration,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_sync_readiness (
                        account_id, state, sync_job_id, scope_fingerprint, updated_at
                    ) VALUES (?, 'pending', ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        state = 'pending', sync_job_id = excluded.sync_job_id,
                        scope_fingerprint = excluded.scope_fingerprint, updated_at = excluded.updated_at
                    """,
                arguments: [
                    input.accountID.rawValue,
                    job.id,
                    scope.establishesReadiness ? scope.fingerprint : nil,
                    now.timeIntervalSince1970,
                ]
            )
        }
        return job
    }

    private struct SyncJobScope {
        let fingerprint: String
        let mailboxPaths: [String]
        let recentMessageLimit: Int
        let downloadCompleteHistory: Bool
        let incrementalOnly: Bool
        let establishesReadiness: Bool
        let reconciliationGeneration: Int
    }

    private static func makeSyncJobScope(
        database: Database,
        input: PlainpostInboxSyncInput
    ) throws -> SyncJobScope {
        let accountID = input.accountID.rawValue
        let preferenceRow = try Row.fetchOne(
            database,
            sql: "SELECT * FROM sync_preferences WHERE account_id = ?",
            arguments: [accountID]
        )
        let preferences = MailSyncPreferences(
            accountID: input.accountID,
            downloadCompleteHistory: preferenceRow?["download_complete_history"] ?? false,
            recentMessageLimit: preferenceRow?["recent_message_limit"] ?? 100,
            realTimeMonitoringEnabled: preferenceRow?["real_time_monitoring_enabled"] ?? true
        )
        let mailboxPreferences = try Row.fetchAll(
            database,
            sql: """
                SELECT mailbox_path, mode FROM mailbox_sync_preferences
                WHERE account_id = ? ORDER BY mailbox_path
                """,
            arguments: [accountID]
        ).compactMap { row -> MailboxSyncPreference? in
            guard let mode = MailboxSyncMode(rawValue: row["mode"]) else { return nil }
            return MailboxSyncPreference(
                accountID: input.accountID,
                mailboxPath: row["mailbox_path"],
                mode: mode
            )
        }
        let availableMailboxes = try Row.fetchAll(
            database,
            sql: "SELECT path, name, special_use FROM mailboxes WHERE account_id = ? ORDER BY path",
            arguments: [accountID]
        ).map { row in
            let path: String = row["path"]
            return Mailbox(
                id: MailboxID("sync-scope-\(path)"),
                accountID: input.accountID,
                name: row["name"],
                path: path,
                specialUse: row["special_use"]
            )
        }
        let effectiveModes = MailboxSyncSelection.effectiveModes(
            availableMailboxes: availableMailboxes,
            preferences: mailboxPreferences
        )
        let selectedModes = effectiveModes
            .filter { $0.value != .off }
            .sorted { $0.key < $1.key }
        let mailboxPaths = selectedModes.map(\.key)
        let fingerprint = Self.syncScopeFingerprint(
            preferences: preferences,
            selectedModes: selectedModes
        )
        let previouslyReadyForScope = try Row.fetchOne(
            database,
            sql: """
                SELECT 1 FROM account_sync_readiness
                WHERE account_id = ? AND state = 'ready' AND scope_fingerprint = ?
                """,
            arguments: [accountID, fingerprint]
        ) != nil
        let establishesReadiness = input.scope != .incremental || previouslyReadyForScope
        let wantsCompleteHistory = preferences.downloadCompleteHistory
            || selectedModes.contains(where: { $0.value == .complete })
        // A UIDVALIDITY change resets the phase to discovery, so a stale
        // `complete` flag never counts as a finished download.
        let finishedHistoryMailboxes = wantsCompleteHistory && !mailboxPaths.isEmpty
            ? Set(try String.fetchAll(
                database,
                sql: """
                    SELECT mailbox_path FROM mailbox_sync_state
                    WHERE account_id = ? AND phase = 'backfill' AND complete = 1
                    """,
                arguments: [accountID]
            ))
            : []
        let completeHistoryFinished = wantsCompleteHistory
            && !mailboxPaths.isEmpty
            && finishedHistoryMailboxes.isSuperset(of: mailboxPaths)
        return SyncJobScope(
            fingerprint: fingerprint,
            mailboxPaths: mailboxPaths,
            recentMessageLimit: preferences.recentMessageLimit,
            downloadCompleteHistory: input.scope == .completeHistory
                || preferences.downloadCompleteHistory
                || selectedModes.contains(where: { $0.value == .complete }),
            // A pending history import must still inspect older UIDs when a
            // scheduled or real-time sync is the next pass after suspension.
            // Once every selected mailbox finished it, new mail is fresh mail
            // and the pass stays incremental, so Inbox arrivals can notify.
            incrementalOnly: input.scope == .incremental
                && (!wantsCompleteHistory || completeHistoryFinished),
            establishesReadiness: establishesReadiness,
            reconciliationGeneration: Self.requiresRemoteStateReconciliation(input) ? 1 : 0
        )
    }

    private static func requiresRemoteStateReconciliation(_ input: PlainpostInboxSyncInput) -> Bool {
        input.trigger != .realTimeSignal
    }

    private static func ensureSyncJobScope(
        database: Database,
        jobID: String,
        input: PlainpostInboxSyncInput
    ) throws {
        guard try Row.fetchOne(
            database,
            sql: "SELECT 1 FROM sync_job_scopes WHERE job_id = ?",
            arguments: [jobID]
        ) == nil else {
            return
        }
        let scope = try makeSyncJobScope(database: database, input: input)
        try database.execute(
            sql: """
                INSERT INTO sync_job_scopes (
                    job_id, scope_fingerprint, mailbox_paths_json, recent_message_limit,
                    download_complete_history, incremental_only, establishes_readiness,
                    reconciliation_generation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id) DO NOTHING
                """,
            arguments: [
                jobID,
                scope.fingerprint,
                String(decoding: try JSONEncoder().encode(scope.mailboxPaths), as: UTF8.self),
                scope.recentMessageLimit,
                scope.downloadCompleteHistory,
                scope.incrementalOnly,
                scope.establishesReadiness,
                scope.reconciliationGeneration,
            ]
        )
        if database.changesCount != 1 {
            guard try Row.fetchOne(
                database,
                sql: "SELECT 1 FROM sync_job_scopes WHERE job_id = ?",
                arguments: [jobID]
            ) != nil else {
                throw PlainpostError.validationFailed("Inbox sync scope could not be persisted.")
            }
        }
    }

    private func currentSyncScopeFingerprint(
        database: Database,
        accountID: AccountID
    ) throws -> String {
        try Self.makeSyncJobScope(
            database: database,
            input: PlainpostInboxSyncInput(accountID: accountID, trigger: .manual)
        ).fingerprint
    }

    private static func syncScopeFingerprint(
        preferences: MailSyncPreferences,
        selectedModes: [(key: String, value: MailboxSyncMode)]
    ) -> String {
        var data = Data()
        let values = [
            "sync-scope-v1",
            String(preferences.recentMessageLimit),
            preferences.downloadCompleteHistory ? "complete" : "recent",
        ] + selectedModes.flatMap { [$0.key, $0.value.rawValue] }
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Enroll a foreground request in one compatible durable execution, or an
    /// ordinary serialized follower. Selection and revision admission are atomic.
    public func requestForegroundInboxRefresh(
        _ input: PlainpostInboxSyncInput
    ) throws -> PlainpostForegroundInboxRefreshRequest {
        guard let generation = input.expectedDirectSourceGeneration else {
            throw NodeMailModeStoreError.generationConflict
        }
        return try databasePool.write { database in
            try Self.requireDirectSource(accountID: input.accountID, generation: generation, allowNodeFallback: true, database: database)
            let currentScope = try Self.makeSyncJobScope(database: database, input: input)
            guard currentScope.mailboxPaths.contains(where: { $0.caseInsensitiveCompare("INBOX") == .orderedSame }) else {
                throw PlainpostError.validationFailed("Enable INBOX sync before refreshing it.")
            }
            let rows = try Row.fetchAll(database, sql: """
                SELECT j.*, s.mailbox_paths_json FROM durable_jobs j
                JOIN sync_job_scopes s ON s.job_id = j.id
                WHERE j.kind IN ('inbox-sync', 'historical-sync')
                  AND j.state IN ('queued', 'running', 'paused') AND j.cancellation_requested = 0
                ORDER BY CASE j.state WHEN 'running' THEN 0 ELSE 1 END, j.created_at, j.id
                """)
            var selected: PlainpostDurableJob?
            for row in rows {
                let job = try decodeJob(row)
                guard let existing = try? JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data(job.payloadJSON.utf8)),
                      existing.accountID == input.accountID,
                      existing.expectedDirectSourceGeneration == generation else { continue }
                let paths = try JSONDecoder().decode([String].self, from: Data((row["mailbox_paths_json"] as String).utf8))
                // The recent limit is deliberately not a compatibility key:
                // this request's entire configured window is captured below.
                guard Set(paths) == Set(currentScope.mailboxPaths) else { continue }
                selected = job
                break
            }
            let createdJob = selected == nil
            let job: PlainpostDurableJob
            if let selected {
                job = try resumeCredentialBlockedInboxSyncIfNeeded(selected, database: database, now: Date())
            } else {
                // Do not route back through normal scope coalescing: it may
                // return an owner with an incompatible frozen mailbox selection.
                // Existing account lease arbitration serializes this follower.
                job = try enqueueJob(PlainpostJobRequest(
                    kind: .inboxSync,
                    payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                    priority: input.schedulingPriority,
                    idempotencyKey: "foreground-inbox:\(UUID().uuidString.lowercased())"
                ), database: database, now: Date())
            }
            try database.execute(sql: """
                UPDATE sync_job_scopes SET
                    foreground_requested_revision = foreground_requested_revision + 1,
                    foreground_requested_recent_limit = MAX(foreground_requested_recent_limit, ?)
                WHERE job_id = ?
                """, arguments: [currentScope.recentMessageLimit, job.id])
            guard database.changesCount == 1,
                  let revision = try Int64.fetchOne(database,
                    sql: "SELECT foreground_requested_revision FROM sync_job_scopes WHERE job_id = ?",
                    arguments: [job.id]) else {
                throw PlainpostError.validationFailed("Foreground inbox request could not be admitted.")
            }
            return PlainpostForegroundInboxRefreshRequest(
                jobID: job.id, accountID: input.accountID, sourceGeneration: generation,
                revision: revision, recentMessageLimit: currentScope.recentMessageLimit, createdJob: createdJob
            )
        }
    }

    public func captureForegroundInboxRefresh(
        jobID: String, leaseToken: String
    ) throws -> IMAPForegroundRefreshDemand? {
        try databasePool.read { database in
            guard let pendingScope = try Row.fetchOne(database, sql: "SELECT * FROM sync_job_scopes WHERE job_id = ?", arguments: [jobID]),
                  (pendingScope["foreground_requested_revision"] as Int64) > 0 else { return nil }
            let (job, input, scope) = try foregroundInboxAuthority(database: database, jobID: jobID, requireCurrentSelection: false)
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            guard !job.cancellationRequested else { throw CancellationError() }
            let revision: Int64 = scope["foreground_requested_revision"]
            guard revision > 0 else { return nil }
            if let receipt = try Self.foregroundReceipt(scope), receipt.revision >= revision,
               try Self.foregroundUIDValidity(database: database, accountID: input.accountID, path: receipt.mailboxPath) == receipt.uidValidity {
                return nil
            }
            return IMAPForegroundRefreshDemand(
                revision: revision, recentMessageLimit: scope["foreground_requested_recent_limit"]
            )
        }
    }

    public func publishForegroundInboxRefresh(
        jobID: String, leaseToken: String, demand: IMAPForegroundRefreshDemand,
        mailboxPath: String, uidValidity: Int, targetUIDs: [Int], newlyDiscoveredCount: Int
    ) throws {
        try databasePool.write { database in
            let (job, input, scope) = try foregroundInboxAuthority(database: database, jobID: jobID, requireCurrentSelection: false)
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            guard !job.cancellationRequested else { throw CancellationError() }
            let requested: Int64 = scope["foreground_requested_revision"]
            guard mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame,
                  demand.revision > 0, demand.revision <= requested,
                  try Self.foregroundUIDValidity(database: database, accountID: input.accountID, path: mailboxPath) == uidValidity else {
                throw NodeMailModeStoreError.generationConflict
            }
            let cached = Set(try Int.fetchAll(database, sql: """
                SELECT uid FROM mailbox_messages WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ?
                """, arguments: [input.accountID.rawValue, mailboxPath, uidValidity]))
            guard Set(targetUIDs).count == targetUIDs.count,
                  targetUIDs.count <= demand.recentMessageLimit,
                  cached.isSuperset(of: targetUIDs) else {
                throw PlainpostError.validationFailed("Foreground inbox window has not committed.")
            }
            if let existing = try Self.foregroundReceipt(scope), existing.revision > demand.revision { return }
            let receipt = PlainpostForegroundInboxRefreshReceipt(
                jobID: jobID, accountID: input.accountID,
                sourceGeneration: input.expectedDirectSourceGeneration!,
                revision: demand.revision, recentMessageLimit: demand.recentMessageLimit,
                mailboxPath: mailboxPath, uidValidity: uidValidity, leaseToken: leaseToken, attempt: job.attempt,
                committedMessageCount: targetUIDs.count, newlyDiscoveredMessageCount: newlyDiscoveredCount
            )
            try database.execute(sql: "UPDATE sync_job_scopes SET foreground_checkpoint_json = ? WHERE job_id = ?",
                arguments: [String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self), jobID])
        }
    }

    public func foregroundInboxRefreshReceipt(
        _ request: PlainpostForegroundInboxRefreshRequest
    ) throws -> PlainpostForegroundInboxRefreshReceipt? {
        try databasePool.read { database in
            let (job, input, scope) = try foregroundInboxAuthority(database: database, jobID: request.jobID)
            guard input.accountID == request.accountID,
                  input.expectedDirectSourceGeneration == request.sourceGeneration else {
                throw NodeMailModeStoreError.generationConflict
            }
            if let receipt = try Self.foregroundReceipt(scope), receipt.revision >= request.revision,
               receipt.recentMessageLimit >= request.recentMessageLimit,
               receipt.jobID == request.jobID, receipt.accountID == request.accountID,
               receipt.sourceGeneration == request.sourceGeneration,
               try Self.foregroundUIDValidity(database: database, accountID: request.accountID, path: receipt.mailboxPath) == receipt.uidValidity {
                // The original lease may now be completed/replaced. Its already
                // published proof remains valid for this exact request revision.
                return receipt
            }
            switch job.state {
            case .completed, .failed, .cancelled, .deliveryUncertain:
                throw PlainpostError.validationFailed(job.errorMessage ?? "A fresh inbox checkpoint is unavailable.")
            case .paused:
                throw PlainpostError.validationFailed("Inbox sync is paused. Check the account and retry.")
            case .queued, .running:
                guard !job.cancellationRequested else { throw CancellationError() }
                return nil
            }
        }
    }

    private func foregroundInboxAuthority(
        database: Database, jobID: String, requireCurrentSelection: Bool = true
    ) throws -> (PlainpostDurableJob, PlainpostInboxSyncInput, Row) {
        guard let row = try Row.fetchOne(database, sql: "SELECT * FROM durable_jobs WHERE id = ?", arguments: [jobID]),
              let scope = try Row.fetchOne(database, sql: "SELECT * FROM sync_job_scopes WHERE job_id = ?", arguments: [jobID]) else {
            throw PlainpostError.validationFailed("Foreground inbox job is unavailable.")
        }
        let job = try decodeJob(row)
        let input = try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data(job.payloadJSON.utf8))
        guard job.kind == .inboxSync || job.kind == .historicalSync,
              let generation = input.expectedDirectSourceGeneration else { throw NodeMailModeStoreError.generationConflict }
        try Self.requireDirectSource(accountID: input.accountID, generation: generation, allowNodeFallback: true, database: database)
        let paths = try JSONDecoder().decode([String].self, from: Data((scope["mailbox_paths_json"] as String).utf8))
        guard paths.contains(where: { $0.caseInsensitiveCompare("INBOX") == .orderedSame }) else {
            throw PlainpostError.validationFailed("The frozen sync scope does not include INBOX.")
        }
        // A UI policy change invalidates its observer, not the independent
        // worker finishing an already admitted, source-fenced frozen scope.
        if requireCurrentSelection,
           Set(paths) != Set(try Self.makeSyncJobScope(database: database, input: input).mailboxPaths) {
            throw PlainpostError.validationFailed("The selected inbox sync scope changed. Refresh again.")
        }
        return (job, input, scope)
    }

    private static func foregroundReceipt(_ row: Row) throws -> PlainpostForegroundInboxRefreshReceipt? {
        guard let json: String = row["foreground_checkpoint_json"] else { return nil }
        return try JSONDecoder().decode(PlainpostForegroundInboxRefreshReceipt.self, from: Data(json.utf8))
    }

    private static func foregroundUIDValidity(database: Database, accountID: AccountID, path: String) throws -> Int? {
        try Int.fetchOne(database, sql: "SELECT uid_validity FROM mailbox_sync_state WHERE account_id = ? AND mailbox_path = ?",
            arguments: [accountID.rawValue, path])
    }

    public func syncExecutionScope(jobID: String) throws -> PlainpostSyncExecutionScope? {
        try databasePool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM sync_job_scopes WHERE job_id = ?",
                arguments: [jobID]
            ) else {
                return nil
            }
            let paths = try JSONDecoder().decode(
                [String].self,
                from: Data((row["mailbox_paths_json"] as String).utf8)
            )
            return PlainpostSyncExecutionScope(
                mailboxPaths: paths,
                recentMessageLimit: row["recent_message_limit"],
                downloadCompleteHistory: row["download_complete_history"],
                incrementalOnly: row["incremental_only"]
            )
        }
    }

    public func smartInboxReadiness() throws -> PlainpostSmartInboxReadiness {
        try databasePool.read { database in
            try smartInboxReadiness(database: database)
        }
    }

    public func smartInboxSyncBlockers() throws -> [PlainpostSyncBlocker] {
        try smartInboxSyncBlockers(selectedDirectSource: nil)
    }

    public func smartInboxSyncBlockers(
        accountID: AccountID,
        sourceGeneration: Int64
    ) throws -> [PlainpostSyncBlocker] {
        try smartInboxSyncBlockers(selectedDirectSource: (accountID, sourceGeneration))
    }

    private func smartInboxSyncBlockers(
        selectedDirectSource: (AccountID, Int64)?
    ) throws -> [PlainpostSyncBlocker] {
        try databasePool.read { database in
            if let (accountID, generation) = selectedDirectSource {
                try Self.requireDirectSource(
                    accountID: accountID, generation: generation, database: database
                )
            }
            let accounts = try Row.fetchAll(
                database,
                sql: selectedDirectSource == nil
                    ? "SELECT id, email FROM accounts ORDER BY id"
                    : "SELECT id, email FROM accounts WHERE id = ? ORDER BY id",
                arguments: selectedDirectSource.map { [$0.0.rawValue] } ?? []
            )
            let readinessRows = try Row.fetchAll(
                database,
                sql: selectedDirectSource == nil
                    ? "SELECT account_id, state, scope_fingerprint FROM account_sync_readiness"
                    : "SELECT account_id, state, scope_fingerprint FROM account_sync_readiness WHERE account_id = ?",
                arguments: selectedDirectSource.map { [$0.0.rawValue] } ?? []
            )
            let readiness = Dictionary(uniqueKeysWithValues: readinessRows.map { row in
                (
                    row["account_id"] as String,
                    (row["state"] as String, row["scope_fingerprint"] as String?)
                )
            })
            let selectedJobPredicate = selectedDirectSource == nil
                ? ""
                : " AND ownership_kind = 'account' AND owner_account_id = ?"
            let activeSyncAccountIDs = Set(try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT json_extract(payload_json, '$.accountID')
                    FROM durable_jobs
                    WHERE kind IN ('inbox-sync', 'historical-sync')
                      AND state IN ('queued', 'running')
                      \(selectedJobPredicate)
                    """,
                arguments: selectedDirectSource.map { [$0.0.rawValue] } ?? []
            ))
            return try accounts.compactMap { account in
                let accountID: String = account["id"]
                let accountEmail: String = account["email"]
                let currentFingerprint = try currentSyncScopeFingerprint(
                    database: database,
                    accountID: AccountID(accountID)
                )
                if let readinessRow = readiness[accountID],
                   readinessRow.0 != "failed",
                   readinessRow.1 == currentFingerprint {
                    if activeSyncAccountIDs.contains(accountID) {
                        return PlainpostSyncBlocker(
                            accountID: AccountID(accountID),
                            accountEmail: accountEmail,
                            state: .waitingForSync
                        )
                    }
                    if readinessRow.0 == "pending" {
                        return PlainpostSyncBlocker(
                            accountID: AccountID(accountID),
                            accountEmail: accountEmail,
                            state: .waitingForSync
                        )
                    }
                    return nil
                }
                return PlainpostSyncBlocker(
                    accountID: AccountID(accountID),
                    accountEmail: accountEmail,
                    state: .waitingForSuccessfulSync
                )
            }
        }
    }

    private func smartInboxReadiness(database: Database) throws -> PlainpostSmartInboxReadiness {
        let accountIDs = try String.fetchAll(database, sql: "SELECT id FROM accounts ORDER BY id")
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT account_id, state, scope_fingerprint FROM account_sync_readiness"
        )
        let readiness = Dictionary(uniqueKeysWithValues: rows.map { row in
            (
                row["account_id"] as String,
                (row["state"] as String, row["scope_fingerprint"] as String?)
            )
        })
        if try accountIDs.contains(where: { accountID in
            guard let row = readiness[accountID], row.0 != "failed" else { return true }
            return row.1 != (try currentSyncScopeFingerprint(
                database: database,
                accountID: AccountID(accountID)
            ))
        }) {
            return .waitingForSuccessfulSync
        }
        let hasActiveSync = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM durable_jobs
                    WHERE kind IN ('inbox-sync', 'historical-sync')
                      AND state IN ('queued', 'running')
                )
                """
        ) ?? false
        if hasActiveSync {
            return .waitingForSync
        }
        if accountIDs.contains(where: { readiness[$0]?.0 == "pending" }) {
            return .waitingForSync
        }
        return .ready
    }

    public func job(id: String) throws -> PlainpostDurableJob {
        guard let row = try fetchRows("SELECT * FROM durable_jobs WHERE id = ?", [id]).first else {
            throw PlainpostError.notFound("Local operation not found.")
        }
        return try decodeJob(row)
    }

    public func job(idempotencyKey: String) throws -> PlainpostDurableJob? {
        guard let row = try fetchRows(
            "SELECT * FROM durable_jobs WHERE idempotency_key = ?",
            [idempotencyKey]
        ).first else {
            return nil
        }
        return try decodeJob(row)
    }

    public func jobs(limit: Int = 100) throws -> [PlainpostDurableJob] {
        let rows = try fetchRows(
            "SELECT * FROM durable_jobs ORDER BY created_at DESC LIMIT ?",
            [String(max(1, min(limit, 1_000)))]
        )
        return try rows.map(decodeJob)
    }

    public func earliestQueuedJobAvailability(
        allowedKinds: Set<PlainpostOperationKind>
    ) throws -> Date? {
        try earliestQueuedJobAvailability(
            strictlyAfter: nil,
            allowedKinds: allowedKinds
        )
    }

    public func earliestQueuedJobAvailability(
        strictlyAfterReadyCutoff date: Date,
        allowedKinds: Set<PlainpostOperationKind>
    ) throws -> Date? {
        try earliestQueuedJobAvailability(
            strictlyAfter: date,
            allowedKinds: allowedKinds
        )
    }

    private func earliestQueuedJobAvailability(
        strictlyAfter date: Date?,
        allowedKinds: Set<PlainpostOperationKind>
    ) throws -> Date? {
        guard !allowedKinds.isEmpty else { return nil }
        let kinds = allowedKinds.map(\.rawValue).sorted()
        let placeholders = Array(
            repeating: "?",
            count: kinds.count
        ).joined(separator: ", ")
        let availabilityClause =
            date == nil ? "" : "AND available_at > ?"
        var arguments: StatementArguments = date.map { [$0.timeIntervalSince1970] } ?? []
        _ = arguments.append(contentsOf: StatementArguments(kinds))
        let rows: [Row]
        do {
            rows = try databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT MIN(available_at) AS next_available_at
                        FROM durable_jobs
                        WHERE state = 'queued'
                          \(availabilityClause)
                          AND kind IN (\(placeholders))
                        """,
                    arguments: arguments
                )
            }
        } catch {
            throw databaseError(error)
        }
        let timestamp: Double? = rows.first?["next_available_at"]
        return timestamp.map(Date.init(timeIntervalSince1970:))
    }

    public func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int
    ) throws -> PlainpostDiagnosticsJobPage {
        try diagnosticsJobPage(
            now: now, anchor: anchor, offset: offset, limit: limit, selectedDirectSource: nil
        )
    }

    public func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int,
        accountID: AccountID,
        sourceGeneration: Int64
    ) throws -> PlainpostDiagnosticsJobPage {
        try diagnosticsJobPage(
            now: now, anchor: anchor, offset: offset, limit: limit,
            selectedDirectSource: (accountID, sourceGeneration)
        )
    }

    private func diagnosticsJobPage(
        now: Date,
        anchor: PlainpostDiagnosticsPageAnchor?,
        offset: Int,
        limit: Int,
        selectedDirectSource: (AccountID, Int64)?
    ) throws -> PlainpostDiagnosticsJobPage {
        let normalizedOffset = max(0, offset)
        let normalizedLimit = max(0, limit)
        do {
            return try databasePool.read { database in
                if let (accountID, generation) = selectedDirectSource {
                    try Self.requireDirectSource(
                        accountID: accountID, generation: generation, database: database
                    )
                }
                let ownerPredicate = selectedDirectSource == nil
                    ? ""
                    : " AND ownership_kind = 'account' AND owner_account_id = ?"
                let ownerArguments: StatementArguments = selectedDirectSource.map {
                    [$0.0.rawValue]
                } ?? []
                let activeRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT * FROM durable_jobs
                        WHERE state IN ('queued', 'running', 'paused')
                          \(ownerPredicate)
                          AND NOT (
                            state = 'paused'
                            AND pause_reason = 'smart-inbox-follow-up'
                          )
                        ORDER BY updated_at DESC, id DESC
                        """,
                    arguments: ownerArguments
                )
                let terminalCutoff = anchor?.terminalCutoff ?? now.addingTimeInterval(-3_600)
                let maximumTerminalSequence: Int64
                if let anchoredMaximumTerminalSequence = anchor?.maximumTerminalSequence {
                    maximumTerminalSequence = anchoredMaximumTerminalSequence
                } else {
                    maximumTerminalSequence = try Int64.fetchOne(
                        database,
                        sql: """
                            SELECT COALESCE(
                                (SELECT seq FROM sqlite_sequence
                                 WHERE name = 'durable_job_terminal_events'),
                                0
                            )
                            """
                    ) ?? 0
                }
                let resolvedAnchor: PlainpostDiagnosticsPageAnchor?
                if let anchor {
                    resolvedAnchor = PlainpostDiagnosticsPageAnchor(
                        updatedAt: anchor.updatedAt,
                        id: anchor.id,
                        terminalCutoff: terminalCutoff,
                        maximumTerminalSequence: maximumTerminalSequence,
                        terminalJobIDs: anchor.terminalJobIDs
                    )
                } else {
                    let row = try Row.fetchOne(
                        database,
                        sql: """
                            SELECT updated_at, id FROM durable_jobs
                            WHERE state NOT IN ('queued', 'running', 'paused')
                              \(ownerPredicate)
                              AND updated_at >= ?
                              AND terminal_sequence <= ?
                            ORDER BY updated_at DESC, id DESC
                            LIMIT 1
                            """,
                        arguments: ownerArguments + [
                            terminalCutoff.timeIntervalSince1970, maximumTerminalSequence
                        ]
                    )
                    let timestamp: Double? = row?["updated_at"]
                    let id: String? = row?["id"]
                    resolvedAnchor = timestamp.flatMap { timestamp in
                        id.map {
                            PlainpostDiagnosticsPageAnchor(
                                updatedAt: Date(timeIntervalSince1970: timestamp),
                                id: $0,
                                terminalCutoff: terminalCutoff,
                                maximumTerminalSequence: maximumTerminalSequence
                            )
                        }
                    }
                }
                guard let resolvedAnchor else {
                    return PlainpostDiagnosticsJobPage(
                        activeJobs: try activeRows.map(decodeJob),
                        terminalJobs: [],
                        anchor: nil,
                        totalTerminalCount: 0,
                        offset: 0,
                        limit: normalizedLimit
                    )
                }
                let terminalArguments: StatementArguments = ownerArguments + [
                    terminalCutoff.timeIntervalSince1970,
                    resolvedAnchor.updatedAt.timeIntervalSince1970,
                    resolvedAnchor.updatedAt.timeIntervalSince1970,
                    resolvedAnchor.id,
                    maximumTerminalSequence,
                ]
                let totalTerminalCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM durable_jobs
                        WHERE state NOT IN ('queued', 'running', 'paused')
                          \(ownerPredicate)
                          AND updated_at >= ?
                          AND (updated_at < ? OR (updated_at = ? AND id <= ?))
                          AND terminal_sequence <= ?
                        """,
                    arguments: terminalArguments
                ) ?? 0
                let effectiveOffset: Int
                if normalizedLimit == 0 || totalTerminalCount == 0 {
                    effectiveOffset = 0
                } else if normalizedOffset >= totalTerminalCount {
                    effectiveOffset = ((totalTerminalCount - 1) / normalizedLimit) * normalizedLimit
                } else {
                    effectiveOffset = normalizedOffset
                }
                let terminalRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT * FROM durable_jobs
                        WHERE state NOT IN ('queued', 'running', 'paused')
                          \(ownerPredicate)
                          AND updated_at >= ?
                          AND (updated_at < ? OR (updated_at = ? AND id <= ?))
                          AND terminal_sequence <= ?
                        ORDER BY updated_at DESC, id DESC
                        LIMIT ? OFFSET ?
                        """,
                    arguments: terminalArguments + [normalizedLimit, effectiveOffset]
                )
                return try PlainpostDiagnosticsJobPage(
                    activeJobs: activeRows.map(decodeJob),
                    terminalJobs: terminalRows.map(decodeJob),
                    anchor: resolvedAnchor,
                    totalTerminalCount: totalTerminalCount,
                    offset: effectiveOffset,
                    limit: normalizedLimit
                )
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func diagnosticsJobs(
        now: Date = Date(),
        recentTerminalLimit: Int = 50
    ) throws -> [PlainpostDurableJob] {
        let page = try diagnosticsJobPage(
            now: now,
            anchor: nil,
            offset: 0,
            limit: recentTerminalLimit
        )
        return (page.activeJobs + page.terminalJobs)
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func claimNextJob(now: Date = Date(), leaseDuration: TimeInterval = 120) throws -> PlainpostDurableJob? {
        try claimNextJob(now: now, leaseDuration: leaseDuration, allowedKinds: nil)
    }

    public func cancelQueuedJobBeforeAvailability(id: String, now: Date = Date()) throws -> Bool {
        let cancelled = try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'cancelled', updated_at = ?
                    WHERE id = ? AND state = 'queued' AND available_at > ?
                    """,
                arguments: [now.timeIntervalSince1970, id, now.timeIntervalSince1970]
            )
            let cancelled = database.changesCount == 1
            if cancelled {
                try self.resolveSmartInboxFollowUpPair(
                    database: database,
                    predecessorID: id,
                    resolution: .cancel,
                    now: now
                )
            }
            return cancelled
        }
        if cancelled {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return cancelled
    }

    public func recoverBackgroundAgentJobs(
        allowedKinds: Set<PlainpostOperationKind>,
        now: Date = Date()
    ) throws -> BackgroundJobRecoverySummary {
        guard !allowedKinds.isEmpty else {
            return BackgroundJobRecoverySummary(requeuedExpiredCount: 0, cancelledDuplicateCount: 0)
        }
        let kindValues = allowedKinds.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: kindValues.count).joined(separator: ", ")
        let uncertainDeliveryKinds = [PlainpostOperationKind.approvedDelivery]
            .filter(allowedKinds.contains).map(\.rawValue).sorted()
        let uncertainPlaceholders = Array(
            repeating: "?",
            count: uncertainDeliveryKinds.count
        ).joined(separator: ", ")
        let cancellationExclusionPredicate = uncertainDeliveryKinds.isEmpty
            ? ""
            : " AND kind NOT IN (\(uncertainPlaceholders))"
        func recoveryArguments(_ timestamps: [TimeInterval]) -> StatementArguments {
            var arguments = StatementArguments(timestamps)
            _ = arguments.append(contentsOf: StatementArguments(kindValues))
            return arguments
        }
        func cancellationRecoveryArguments(_ timestamps: [TimeInterval]) -> StatementArguments {
            var arguments = recoveryArguments(timestamps)
            _ = arguments.append(contentsOf: StatementArguments(uncertainDeliveryKinds))
            return arguments
        }
        let recovery = try databasePool.write {
            database -> (summary: BackgroundJobRecoverySummary, acknowledgedPauseCount: Int) in
            let expiredCancellationJobIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id FROM durable_jobs
                    WHERE state = 'running' AND cancellation_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind IN (\(placeholders))\(cancellationExclusionPredicate)
                    ORDER BY id
                    """,
                arguments: cancellationRecoveryArguments([now.timeIntervalSince1970])
            )
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'cancelled', lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE state = 'running' AND cancellation_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind IN (\(placeholders))\(cancellationExclusionPredicate)
                    """,
                arguments: cancellationRecoveryArguments([
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ])
            )
            for jobID in expiredCancellationJobIDs {
                try self.recordSmartInboxReclassificationCompletion(
                    database: database,
                    jobID: jobID,
                    status: "cancelled",
                    errorClass: "cancelled"
                )
                try self.resolveSmartInboxFollowUpPair(
                    database: database,
                    predecessorID: jobID,
                    resolution: .cancel,
                    now: now
                )
                try self.updateSyncReadiness(
                    database: database,
                    syncJobID: jobID,
                    state: "failed",
                    updatedAt: now
                )
            }
            for jobID in expiredCancellationJobIDs where try self.isSyncJob(database: database, id: jobID) {
                try self.resumeSystemPausedSmartInboxWhenSyncInactive(database: database, now: now)
            }
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'paused',
                        pause_requested = 0,
                        pause_attempt_credit = 1,
                        pause_reason = CASE WHEN pause_reason IN ('smart-inbox-disabled', 'low-power') THEN pause_reason ELSE 'user-requested' END,
                        lease_token = NULL,
                        lease_expires_at = NULL,
                        updated_at = ?
                    WHERE state = 'running'
                      AND cancellation_requested = 0
                      AND pause_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind IN (\(placeholders))
                    """,
                arguments: recoveryArguments([
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ])
            )
            let acknowledgedPauseCount = database.changesCount
            if !uncertainDeliveryKinds.isEmpty {
                try self.markExpiredApprovedDeliveriesUncertain(database: database, now: now)
            }
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued', lease_token = NULL, lease_expires_at = NULL,
                        attempt = MIN(attempt, MAX(max_attempts - 1, 0)),
                        available_at = MIN(available_at, ?), updated_at = ?
                    WHERE state = 'running' AND cancellation_requested = 0
                      AND pause_requested = 0
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind IN (\(placeholders))
                    """,
                arguments: recoveryArguments([
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ])
            )
            let requeuedExpiredCount = database.changesCount

            var cancelledDuplicateCount = 0
            if allowedKinds.contains(.inboxSync) || allowedKinds.contains(.historicalSync) {
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT * FROM durable_jobs
                        WHERE kind IN ('inbox-sync', 'historical-sync')
                          AND state IN ('queued', 'running', 'paused')
                          AND cancellation_requested = 0
                        ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END, created_at, id
                        """
                )
                var retainedSyncWork: [(job: PlainpostDurableJob, input: PlainpostInboxSyncInput)] = []
                for row in rows {
                    guard let input = try? JSONDecoder().decode(
                        PlainpostInboxSyncInput.self,
                        from: Data((row["payload_json"] as String).utf8)
                    ), let candidate = try? decodeJob(row) else { continue }
                    guard let retainedIndex = retainedSyncWork.firstIndex(where: {
                        Self.equivalentInboxSyncWork($0.input, input)
                    }) else {
                        retainedSyncWork.append((candidate, input))
                        continue
                    }
                    guard candidate.state != .running else {
                        retainedSyncWork.append((candidate, input))
                        continue
                    }
                    let retained = retainedSyncWork[retainedIndex]
                    let merged = try mergeEquivalentInboxSyncWork(
                        retained.job,
                        existingInput: retained.input,
                        requestedInput: input,
                        priority: candidate.priority,
                        database: database,
                        now: now
                    )
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'cancelled', error_code = 'SUPERSEDED_INBOX_SYNC',
                                error_message = 'Superseded by equivalent active inbox sync work.',
                                lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                            WHERE id = ? AND state IN ('queued', 'paused')
                            """,
                        arguments: [now.timeIntervalSince1970, row["id"] as String]
                    )
                    cancelledDuplicateCount += database.changesCount
                    if database.changesCount == 1,
                       let mergedInput = try? JSONDecoder().decode(
                           PlainpostInboxSyncInput.self,
                           from: Data(merged.payloadJSON.utf8)
                       ) {
                        retainedSyncWork[retainedIndex] = (merged, mergedInput)
                    }
                }
            }
            if allowedKinds.contains(.aiOperation) {
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT jobs.id, jobs.payload_json, jobs.state, jobs.pause_reason,
                            snapshots.catalog_fingerprint
                        FROM durable_jobs jobs
                        LEFT JOIN smart_inbox_label_catalog_snapshots snapshots
                          ON snapshots.job_id = jobs.id
                        WHERE jobs.kind = 'ai-operation'
                          AND jobs.state IN ('queued', 'running', 'paused')
                          AND NOT (
                            jobs.state = 'paused'
                            AND jobs.pause_reason = 'smart-inbox-follow-up'
                          )
                        ORDER BY CASE
                            WHEN jobs.state = 'paused'
                              AND jobs.pause_reason = 'user-requested' THEN 0
                            WHEN jobs.state = 'running' THEN 1
                            ELSE 2
                        END, jobs.created_at, jobs.id
                        """
                )
                let incrementalRows = rows.compactMap { row
                    -> (row: Row, key: SmartInboxIncrementalCompatibilityKey)? in
                    guard let input = try? JSONDecoder().decode(
                        PlainpostAIOperationInput.self,
                        from: Data((row["payload_json"] as String).utf8)
                    ), input.operation == .recategorizeInbox,
                       input.smartInboxRunMode == .incremental else {
                        return nil
                    }
                    let catalogFingerprint: String? = row["catalog_fingerprint"]
                    return (
                        row,
                        SmartInboxIncrementalCompatibilityKey(
                            classifierDiscriminator: input.resolvedSmartInboxClassifierIdentity.discriminator,
                            scopeIdentity: input.smartInboxRunRequest.scope.identityValue,
                            catalogFingerprint: catalogFingerprint
                        )
                    )
                }
                var retainedIncrementalKeys = Set<SmartInboxIncrementalCompatibilityKey>()
                for candidate in incrementalRows {
                    let state = candidate.row["state"] as String
                    let pauseReason: String? = candidate.row["pause_reason"]
                    if state == PlainpostOperationState.paused.rawValue,
                       pauseReason == "user-requested" {
                        retainedIncrementalKeys.insert(candidate.key)
                        continue
                    }
                    guard !retainedIncrementalKeys.insert(candidate.key).inserted,
                          state != PlainpostOperationState.running.rawValue else {
                        continue
                    }
                    try database.execute(
                        sql: """
                            UPDATE durable_jobs
                            SET state = 'cancelled', error_code = 'SUPERSEDED_INCREMENTAL',
                                error_message = 'Superseded by existing incremental Smart Inbox work.',
                                lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                            WHERE id = ? AND state IN ('queued', 'paused')
                              AND NOT (
                                state = 'paused' AND pause_reason = 'user-requested'
                              )
                            """,
                        arguments: [now.timeIntervalSince1970, candidate.row["id"] as String]
                    )
                    cancelledDuplicateCount += database.changesCount
                    if database.changesCount == 1 {
                        try self.resolveSmartInboxFollowUpPair(
                            database: database,
                            predecessorID: candidate.row["id"],
                            resolution: .cancel,
                            now: now
                        )
                    }
                }
            }
            return (
                BackgroundJobRecoverySummary(
                    requeuedExpiredCount: requeuedExpiredCount,
                    cancelledDuplicateCount: cancelledDuplicateCount,
                    cancelledExpiredCount: expiredCancellationJobIDs.count
                ),
                acknowledgedPauseCount
            )
        }
        if recovery.acknowledgedPauseCount > 0
            || recovery.summary.requeuedExpiredCount > 0
            || recovery.summary.cancelledDuplicateCount > 0
            || recovery.summary.cancelledExpiredCount > 0 {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return recovery.summary
    }

    public func claimNextJob(
        now: Date = Date(),
        leaseDuration: TimeInterval = 120,
        allowedKinds: Set<PlainpostOperationKind>?,
        selectedDirectAccountID: AccountID? = nil,
        expectedDirectSourceGeneration: Int64? = nil,
        everyDirectAccount: Bool = false,
        onlyJobID: String? = nil
    ) throws -> PlainpostDurableJob? {
        guard (selectedDirectAccountID == nil) == (expectedDirectSourceGeneration == nil) else {
            throw PlainpostError.validationFailed("A selected Direct claim requires account and source generation.")
        }
        if let allowedKinds, allowedKinds.isEmpty {
            return nil
        }
        let kindValues = allowedKinds?.map(\.rawValue).sorted() ?? []
        let kindClause = kindValues.isEmpty
            ? ""
            : "AND kind IN (\(Array(repeating: "?", count: kindValues.count).joined(separator: ", ")))"
        let ownerClause = selectedDirectAccountID == nil
            ? "" : "AND ownership_kind = 'account' AND owner_account_id = ?"
        func scopedArguments(_ values: StatementArguments) -> StatementArguments {
            var result = values
            if let selectedDirectAccountID {
                _ = result.append(contentsOf: StatementArguments([selectedDirectAccountID.rawValue]))
            }
            return result
        }
        var selectArguments: StatementArguments = [now.timeIntervalSince1970, now.timeIntervalSince1970]
        if let selectedDirectAccountID {
            _ = selectArguments.append(contentsOf: StatementArguments([selectedDirectAccountID.rawValue]))
        }
        _ = selectArguments.append(contentsOf: StatementArguments(kindValues))
        // A caller waiting on its own job claims only that one, never an older job of the same kind.
        let onlyJobClause = onlyJobID == nil ? "" : "AND id = ?"
        if let onlyJobID {
            _ = selectArguments.append(contentsOf: StatementArguments([onlyJobID]))
        }
        let claimResult: (job: PlainpostDurableJob?, acknowledgedPauseCount: Int, cancelledExpiredCount: Int) =
            try databasePool.write { database in
            if let selectedDirectAccountID, let expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: selectedDirectAccountID,
                    generation: expectedDirectSourceGeneration,
                    database: database
                )
            }
            let expiredCancellationJobIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT id FROM durable_jobs
                    WHERE state = 'running' AND cancellation_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind != 'approved-delivery'
                      \(ownerClause)
                    ORDER BY id
                    """,
                arguments: scopedArguments([now.timeIntervalSince1970])
            )
            // An expired approved delivery may already have crossed the SMTP
            // boundary, so a cancellation cannot make it `cancelled`; it is
            // marked uncertain below.
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'cancelled', lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE state = 'running' AND cancellation_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      AND kind != 'approved-delivery'
                      \(ownerClause)
                """,
                arguments: scopedArguments([now.timeIntervalSince1970, now.timeIntervalSince1970])
            )
            for jobID in expiredCancellationJobIDs {
                try self.recordSmartInboxReclassificationCompletion(
                    database: database,
                    jobID: jobID,
                    status: "cancelled",
                    errorClass: "cancelled"
                )
                try self.resolveSmartInboxFollowUpPair(
                    database: database,
                    predecessorID: jobID,
                    resolution: .cancel,
                    now: now
                )
                try self.updateSyncReadiness(
                    database: database,
                    syncJobID: jobID,
                    state: "failed",
                    updatedAt: now
                )
            }
            if selectedDirectAccountID == nil, !everyDirectAccount {
                for jobID in expiredCancellationJobIDs where try self.isSyncJob(database: database, id: jobID) {
                    try self.resumeSystemPausedSmartInboxWhenSyncInactive(database: database, now: now)
                }
            }
            try database.execute(
                sql: """
                    UPDATE account_sync_readiness
                    SET state = 'failed', updated_at = ?
                    WHERE state != 'failed' AND sync_job_id IN (
                        SELECT id FROM durable_jobs
                        WHERE state = 'cancelled' AND cancellation_requested = 1
                          \(ownerClause)
                    )
                """,
                arguments: scopedArguments([now.timeIntervalSince1970])
            )
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'paused',
                        pause_requested = 0,
                        pause_attempt_credit = 1,
                        pause_reason = CASE WHEN pause_reason IN ('smart-inbox-disabled', 'low-power') THEN pause_reason ELSE 'user-requested' END,
                        lease_token = NULL,
                        lease_expires_at = NULL,
                        updated_at = ?
                    WHERE state = 'running'
                      AND cancellation_requested = 0
                      AND pause_requested = 1
                      AND COALESCE(lease_expires_at, 0) < ?
                      \(ownerClause)
                    """,
                arguments: scopedArguments([now.timeIntervalSince1970, now.timeIntervalSince1970])
            )
            let acknowledgedPauseCount = database.changesCount
            // A requeued delivery could never be claimed again (one attempt,
            // already spent) and would sit `queued` with no review prompt.
            try self.markExpiredApprovedDeliveriesUncertain(
                database: database, now: now, selectedAccountID: selectedDirectAccountID
            )
            // Keep one attempt available, as background recovery does, so an
            // expired one-shot job such as a deny is not requeued dead.
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued',
                        attempt = MIN(attempt, MAX(max_attempts - 1, 0)),
                        lease_token = NULL,
                        lease_expires_at = NULL,
                        updated_at = ?
                    WHERE state = 'running'
                      AND cancellation_requested = 0
                      AND pause_requested = 0
                      AND COALESCE(lease_expires_at, 0) < ?
                      \(ownerClause)
                    """,
                arguments: scopedArguments([now.timeIntervalSince1970, now.timeIntervalSince1970])
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM durable_jobs
                    WHERE cancellation_requested = 0
                      AND (state = 'paused' OR attempt < max_attempts)
                      AND available_at <= ?
                      AND (state IN ('queued', 'paused') OR (state = 'running' AND lease_expires_at < ?))
                      AND NOT (state = 'paused' AND pause_reason IN (
                          'credentials-unavailable',
                          'user-requested',
                          'low-power',
                          'smart-inbox-follow-up'
                      ))
                      \(ownerClause)
                    \(kindClause)
                    \(onlyJobClause)
                    ORDER BY priority DESC, available_at, created_at
                    """,
                arguments: selectArguments
            )
            guard let row = try rows.first(where: { candidate in
                try isClaimableCandidate(
                    candidate,
                    database: database,
                    now: now,
                    explicitAllowedKindValues: allowedKinds == nil ? nil : kindValues,
                    selectedAccountID: selectedDirectAccountID,
                    selectedSourceGeneration: expectedDirectSourceGeneration,
                    requiresOwnDirectGeneration: everyDirectAccount
                )
            }) else {
                return (nil, acknowledgedPauseCount, expiredCancellationJobIDs.count)
            }

            let id: String = row["id"]
            let previousState: String = row["state"]
            let leaseToken = UUID().uuidString.lowercased()
            let expiry = now.addingTimeInterval(max(10, leaseDuration))
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'running',
                        attempt = CASE WHEN ? = 'paused' THEN attempt ELSE attempt + 1 END,
                        lease_token = ?, lease_expires_at = ?, pause_reason = NULL, pause_attempt_credit = 0, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [previousState, leaseToken, expiry.timeIntervalSince1970, now.timeIntervalSince1970, id]
            )
            guard let claimed = try Row.fetchOne(database, sql: "SELECT * FROM durable_jobs WHERE id = ?", arguments: [id]) else {
                return (nil, acknowledgedPauseCount, expiredCancellationJobIDs.count)
            }
            return (try decodeJob(claimed), acknowledgedPauseCount, expiredCancellationJobIDs.count)
        }
        if claimResult.job != nil
            || claimResult.acknowledgedPauseCount > 0
            || claimResult.cancelledExpiredCount > 0 {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return claimResult.job
    }

    private func isClaimableCandidate(
        _ row: Row,
        database: Database,
        now: Date,
        explicitAllowedKindValues: [String]?,
        selectedAccountID: AccountID?,
        selectedSourceGeneration: Int64?,
        requiresOwnDirectGeneration: Bool = false
    ) throws -> Bool {
        let kind = PlainpostOperationKind(rawValue: row["kind"] as String)
        if requiresOwnDirectGeneration {
            // The device-wide iOS worker: a mailbox job runs only at its own account's
            // current Direct generation, so one account's source switch strands only its jobs.
            let payload = Data((row["payload_json"] as String).utf8)
            let owner: (AccountID?, Int64?)?
            switch kind {
            case .inboxSync, .historicalSync:
                owner = (try? JSONDecoder().decode(PlainpostInboxSyncInput.self, from: payload))
                    .map { ($0.accountID, $0.expectedDirectSourceGeneration) }
            case .mailboxFlag:
                owner = (try? JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: payload))
                    .map { ($0.accountID, $0.expectedDirectSourceGeneration) }
            case .mailboxArchive:
                owner = (try? JSONDecoder().decode(PlainpostMailboxArchiveInput.self, from: payload))
                    .map { ($0.accountID, $0.expectedDirectSourceGeneration) }
            default:
                owner = nil
            }
            if kind == .inboxSync || kind == .historicalSync || kind == .mailboxFlag || kind == .mailboxArchive {
                guard let owner, let accountID = owner.0, let generation = owner.1,
                      (try? Self.requireDirectSource(accountID: accountID, generation: generation, allowNodeFallback: true, database: database)) != nil
                else { return false }
            }
        }
        if let selectedAccountID, let selectedSourceGeneration {
            let payload = Data((row["payload_json"] as String).utf8)
            switch kind {
            case .inboxSync, .historicalSync:
                guard let input = try? JSONDecoder().decode(PlainpostInboxSyncInput.self, from: payload),
                      input.accountID == selectedAccountID,
                      input.expectedDirectSourceGeneration == selectedSourceGeneration else { return false }
            case .mailboxFlag:
                guard let input = try? JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: payload),
                      input.accountID == selectedAccountID,
                      input.expectedDirectSourceGeneration == selectedSourceGeneration else { return false }
            case .mailboxArchive:
                guard let input = try? JSONDecoder().decode(PlainpostMailboxArchiveInput.self, from: payload),
                      input.accountID == selectedAccountID,
                      input.expectedDirectSourceGeneration == selectedSourceGeneration else { return false }
            default:
                break
            }
        }
        if kind == .aiOperation,
           let input = try? JSONDecoder().decode(
               PlainpostAIOperationInput.self,
               from: Data((row["payload_json"] as String).utf8)
           ), input.operation == .recategorizeInbox {
            guard try Self.smartInboxEnabled(in: database) else { return false }
            do {
                try Self.requireSmartInboxDirectSource(input: input, database: database)
            } catch {
                return false
            }
        }
        if kind == .aiOperation,
           let input = try? JSONDecoder().decode(
               PlainpostAIOperationInput.self,
               from: Data((row["payload_json"] as String).utf8)
           ),
           input.operation == .recategorizeInbox,
           try hasActiveBlockingSync(database: database, selectedAccountID: selectedAccountID) {
            return false
        }
        let aiKindValues = [
            PlainpostOperationKind.aiOperation.rawValue,
            PlainpostOperationKind.searchRebuild.rawValue,
        ]
        let serializedKindValues: [String]
        if kind == .aiOperation || kind == .searchRebuild {
            serializedKindValues = aiKindValues
        } else if let explicitAllowedKindValues {
            serializedKindValues = explicitAllowedKindValues.filter { !aiKindValues.contains($0) }
        } else if kind == .inboxSync || kind == .historicalSync {
            serializedKindValues = [
                PlainpostOperationKind.inboxSync.rawValue,
                PlainpostOperationKind.historicalSync.rawValue,
            ]
        } else {
            return true
        }
        guard !serializedKindValues.isEmpty else { return true }
        let placeholders = Array(repeating: "?", count: serializedKindValues.count).joined(separator: ", ")
        var arguments: StatementArguments = [now.timeIntervalSince1970]
        _ = arguments.append(contentsOf: StatementArguments(serializedKindValues))
        if let selectedAccountID {
            _ = arguments.append(contentsOf: StatementArguments([selectedAccountID.rawValue]))
        }
        let runningRows = try Row.fetchAll(
            database,
            sql: """
                SELECT kind, payload_json FROM durable_jobs
                WHERE state = 'running' AND lease_expires_at >= ?
                  AND kind IN (\(placeholders))
                  \(selectedAccountID == nil ? "" : "AND ownership_kind = 'account' AND owner_account_id = ?")
                """,
            arguments: arguments
        )
        guard kind == .inboxSync || kind == .historicalSync,
              let candidateInput = try? JSONDecoder().decode(
                  PlainpostInboxSyncInput.self,
                  from: Data((row["payload_json"] as String).utf8)
              ) else {
            return runningRows.isEmpty
        }
        return runningRows.allSatisfy { runningRow in
            guard let runningKind = PlainpostOperationKind(rawValue: runningRow["kind"] as String),
                  runningKind == .inboxSync || runningKind == .historicalSync,
                  let runningInput = try? JSONDecoder().decode(
                      PlainpostInboxSyncInput.self,
                      from: Data((runningRow["payload_json"] as String).utf8)
                  ) else {
                return false
            }
            return runningInput.accountID != candidateInput.accountID
        }
    }

    public func nextPendingJob(
        higherPriorityThan priority: Int,
        now: Date = Date(),
        allowedKinds: Set<PlainpostOperationKind>? = nil
    ) throws -> PlainpostDurableJob? {
        try databasePool.read { database in
            try nextPendingJob(
                database: database,
                higherPriorityThan: priority,
                now: now,
                allowedKinds: allowedKinds
            )
        }
    }

    public func acknowledgeSmartInboxBoundary(
        jobID: String,
        leaseToken: String,
        priority: Int,
        allowedKinds: Set<PlainpostOperationKind>,
        now: Date = Date()
    ) throws -> PlainpostSmartInboxBoundaryOutcome {
        let outcome: PlainpostSmartInboxBoundaryOutcome = try databasePool.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM durable_jobs WHERE id = ?",
                arguments: [jobID]
            ) else { return .leaseLost }
            let job = try decodeJob(row)
            if job.cancellationRequested {
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = 'cancelled', lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND lease_token = ? AND state = 'running' AND cancellation_requested = 1
                    """,
                    arguments: [now.timeIntervalSince1970, jobID, leaseToken]
                )
                guard database.changesCount == 1 else { return .leaseLost }
                try self.recordSmartInboxReclassificationCompletion(
                    database: database,
                    jobID: jobID,
                    status: "cancelled",
                    errorClass: "cancelled"
                )
                try self.resolveSmartInboxFollowUpPair(
                    database: database,
                    predecessorID: jobID,
                    resolution: .cancel,
                    now: now
                )
                return .yielded
            }
            if try job.pauseRequested || !Self.smartInboxEnabled(in: database) {
                let pauseReason: String
                if job.pauseRequested,
                   job.pauseReason == PlainpostJobPauseRequestReason.lowPower.rawValue {
                    pauseReason = PlainpostJobPauseRequestReason.lowPower.rawValue
                } else if job.pauseRequested, job.pauseReason != "smart-inbox-disabled" {
                    pauseReason = PlainpostJobPauseRequestReason.userRequested.rawValue
                } else {
                    pauseReason = "smart-inbox-disabled"
                }
                let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = 'paused', pause_requested = 0, pause_attempt_credit = 1,
                            pause_reason = ?, progress_current = ?, progress_total = ?,
                            progress_phase = 'paused', progress_label = ?, lease_token = NULL,
                            lease_expires_at = NULL, updated_at = ?
                        WHERE id = ? AND state = 'running' AND lease_token = ?
                          AND cancellation_requested = 0
                        """,
                    arguments: [pauseReason, summary.processed, summary.total, "Smart Inbox", now.timeIntervalSince1970, jobID, leaseToken]
                )
                return database.changesCount == 1 ? .yielded : .leaseLost
            }
            guard job.state == .running, job.leaseToken == leaseToken else { return .leaseLost }
            let reason: String?
            if try hasActiveBlockingSync(database: database) {
                reason = "mail-sync"
            } else if let pending = try nextPendingJob(
                database: database,
                higherPriorityThan: priority,
                now: now,
                allowedKinds: allowedKinds
            ) {
                let input = try? JSONDecoder().decode(
                    PlainpostAIOperationInput.self,
                    from: Data(pending.payloadJSON.utf8)
                )
                reason = input?.operation.schedulerPauseReason ?? "interactive-ai"
            } else {
                reason = nil
            }
            guard let reason else { return .continueRunning }
            let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'paused', pause_reason = ?, progress_current = ?, progress_total = ?,
                        progress_phase = 'paused', progress_label = ?, lease_token = NULL,
                        lease_expires_at = NULL, updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                      AND cancellation_requested = 0 AND pause_requested = 0
                    """,
                arguments: [reason, summary.processed, summary.total, "Smart Inbox", now.timeIntervalSince1970, jobID, leaseToken]
            )
            return database.changesCount == 1 ? .yielded : .leaseLost
        }
        if outcome == .yielded { MailStoreChangeSignal.post(scope: .operations) }
        return outcome
    }

    private func nextPendingJob(
        database: Database,
        higherPriorityThan priority: Int,
        now: Date,
        allowedKinds: Set<PlainpostOperationKind>?
    ) throws -> PlainpostDurableJob? {
        if let allowedKinds, allowedKinds.isEmpty { return nil }
        let kindValues = allowedKinds?.map(\.rawValue).sorted() ?? []
        let kindClause = kindValues.isEmpty
            ? ""
            : "AND kind IN (\(Array(repeating: "?", count: kindValues.count).joined(separator: ", ")))"
        var arguments: StatementArguments = [priority, now.timeIntervalSince1970]
        _ = arguments.append(contentsOf: StatementArguments(kindValues))
        guard let row = try Row.fetchOne(
            database,
            sql: """
                    SELECT * FROM durable_jobs
                    WHERE cancellation_requested = 0
                      AND priority > ?
                      AND available_at <= ?
                      AND state IN ('queued', 'paused')
                      AND NOT (state = 'paused' AND pause_reason IN (
                          'credentials-unavailable',
                          'user-requested',
                          'low-power'
                      ))
                      \(kindClause)
                    ORDER BY priority DESC, available_at, created_at, id
                    LIMIT 1
            """,
            arguments: arguments
        ) else { return nil }
        return try decodeJob(row)
    }

    public func pauseJob(
        id: String,
        leaseToken: String,
        reason: String,
        progress: PlainpostOperationProgress
    ) throws {
        try pauseJob(
            id: id,
            leaseToken: leaseToken,
            reason: reason,
            progress: progress,
            restoreAttempt: false
        )
    }

    public func pauseJob(
        id: String,
        leaseToken: String,
        reason: String,
        progress: PlainpostOperationProgress,
        restoreAttempt: Bool
    ) throws {
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs
                SET state = 'paused', attempt = CASE WHEN ? THEN MAX(0, attempt - 1) ELSE attempt END,
                    pause_reason = ?, progress_current = ?, progress_total = ?,
                    progress_phase = 'paused', progress_label = ?, lease_token = NULL,
                    lease_expires_at = NULL, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running' AND cancellation_requested = 0
            """,
            values: [
                restoreAttempt ? "1" : "0", reason, String(progress.current), progress.total.map(String.init), progress.label,
                Date().timeIntervalSince1970, id, leaseToken
            ]
        )
        MailStoreChangeSignal.post(scope: .operations)
    }

    @discardableResult
    public func releaseJobLeaseForRetry(
        id: String,
        leaseToken: String,
        now: Date = Date()
    ) throws -> Bool {
        let released = try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued', attempt = MAX(0, attempt - 1),
                        available_at = ?, pause_reason = NULL,
                        lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                      AND cancellation_requested = 0
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id, leaseToken]
            )
            return database.changesCount == 1
        }
        if released {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return released
    }

    /// Pauses a queued job at once, or asks a running one to pause at its next
    /// boundary. A Low Power pause never replaces a pause already requested.
    public func requestJobPause(
        id: String,
        accountID: AccountID? = nil,
        sourceGeneration: Int64? = nil,
        reason: PlainpostJobPauseRequestReason = .userRequested
    ) throws {
        let now = Date()
        try databasePool.write { database in
            let job = try self.userPausableSmartInboxJob(
                database: database, id: id,
                selectedAccountID: accountID, selectedSourceGeneration: sourceGeneration
            )
            switch job.state {
            case .running where reason == .lowPower && job.pauseRequested:
                return
            case .queued, .running:
                guard !job.cancellationRequested else {
                    throw PlainpostError.validationFailed("Cancelled local operations cannot be paused.")
                }
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = CASE WHEN state = 'queued' THEN 'paused' ELSE state END,
                            pause_reason = ?,
                            pause_requested = CASE WHEN state = 'running' THEN 1 ELSE 0 END,
                            lease_token = CASE WHEN state = 'queued' THEN NULL ELSE lease_token END,
                            lease_expires_at = CASE WHEN state = 'queued' THEN NULL ELSE lease_expires_at END,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [reason.rawValue, now.timeIntervalSince1970, id]
                )
                guard database.changesCount == 1 else {
                    throw PlainpostError.validationFailed("Local operation pause request could not be recorded.")
                }
            case .paused where reason == .lowPower && job.pauseReason == PlainpostJobPauseRequestReason.lowPower.rawValue:
                return
            case .paused where reason == .lowPower && !job.cancellationRequested &&
                ["mail-sync", "mail-sync-failed", "interactive-ai"].contains(job.pauseReason ?? ""):
                // A system pause would be lifted (or claimed through) during Low Power
                // Mode. Take it over; lifting the Low Power pause later re-queues the job
                // and returns the attempt the system resume would have.
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET pause_reason = 'low-power', pause_attempt_credit = 1, updated_at = ?
                        WHERE id = ? AND state = 'paused'
                        """,
                    arguments: [now.timeIntervalSince1970, id]
                )
            case .paused where reason == .userRequested && !job.cancellationRequested &&
                (job.pauseReason == "user-requested" || job.pauseReason == "smart-inbox-disabled"
                    || job.pauseReason == PlainpostJobPauseRequestReason.lowPower.rawValue):
                try database.execute(sql: "UPDATE durable_jobs SET pause_reason = 'user-requested', updated_at = ? WHERE id = ?",
                                     arguments: [now.timeIntervalSince1970, id])
            default:
                throw PlainpostError.validationFailed("Local operation cannot be paused in its current state.")
            }
        }
        MailStoreChangeSignal.post(scope: .operations)
    }

    /// Lifts every Low Power pause: a paused job is queued again, and a running
    /// job that has not reached its pause yet keeps running. A user's own pause
    /// is never lifted. Returns how many jobs changed.
    @discardableResult
    public func resumeLowPowerPausedJobs(now: Date = Date()) throws -> Int {
        let changed = try databasePool.write { database -> Int in
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued',
                        attempt = MAX(0, attempt - pause_attempt_credit),
                        pause_attempt_credit = 0,
                        pause_requested = 0,
                        pause_reason = NULL,
                        available_at = ?,
                        updated_at = ?
                    WHERE state = 'paused'
                      AND pause_reason = 'low-power'
                      AND cancellation_requested = 0
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
            var changed = database.changesCount
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET pause_requested = 0, pause_reason = NULL, updated_at = ?
                    WHERE state = 'running'
                      AND pause_requested = 1
                      AND pause_reason = 'low-power'
                      AND cancellation_requested = 0
                    """,
                arguments: [now.timeIntervalSince1970]
            )
            changed += database.changesCount
            return changed
        }
        if changed > 0 { MailStoreChangeSignal.post(scope: .operations) }
        return changed
    }

    public func acknowledgeJobPause(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws {
        let now = Date()
        try databasePool.write { database in
            _ = try self.userPausableSmartInboxJob(database: database, id: id)
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'paused',
                        pause_requested = 0,
                        pause_attempt_credit = 1,
                        pause_reason = CASE WHEN pause_reason IN ('smart-inbox-disabled', 'low-power') THEN pause_reason ELSE 'user-requested' END,
                        progress_current = ?,
                        progress_total = ?,
                        progress_phase = 'paused',
                        progress_label = ?,
                        lease_token = NULL,
                        lease_expires_at = NULL,
                        updated_at = ?
                    WHERE id = ?
                      AND state = 'running'
                      AND lease_token = ?
                      AND pause_requested = 1
                      AND cancellation_requested = 0
                    """,
                arguments: [
                    progress.current,
                    progress.total,
                    progress.label,
                    now.timeIntervalSince1970,
                    id,
                    leaseToken,
                ]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed("Local operation pause request is no longer valid.")
            }
        }
        MailStoreChangeSignal.post(scope: .operations)
    }

    public func resumeUserPausedJob(
        id: String,
        accountID: AccountID? = nil,
        sourceGeneration: Int64? = nil,
        now: Date
    ) throws {
        try databasePool.write { database in
            try Self.requireSmartInboxEnabled(in: database)
            let job = try self.userPausableSmartInboxJob(
                database: database, id: id,
                selectedAccountID: accountID, selectedSourceGeneration: sourceGeneration
            )
            switch job.state {
            // The caller checks Low Power Mode is off before resuming a job still
            // paused for it.
            case .paused where (job.pauseReason == "user-requested" || job.pauseReason == "low-power")
                && !job.cancellationRequested:
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET state = 'queued',
                            attempt = MAX(0, attempt - pause_attempt_credit),
                            pause_attempt_credit = 0,
                            pause_requested = 0,
                            pause_reason = NULL,
                            available_at = ?,
                            updated_at = ?
                        WHERE id = ?
                          AND state = 'paused'
                          AND pause_reason IN ('user-requested', 'low-power')
                          AND cancellation_requested = 0
                        """,
                    arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id]
                )
                guard database.changesCount == 1 else {
                    throw PlainpostError.validationFailed("Local operation pause could not be resumed.")
                }
            case .queued where !job.cancellationRequested,
                 .running where !job.cancellationRequested:
                break
            default:
                throw PlainpostError.validationFailed("Local operation is not paused by the user.")
            }
        }
        MailStoreChangeSignal.post(scope: .operations)
    }

    public func acknowledgeJobCancellation(id: String, leaseToken: String) throws {
        let now = Date()
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs
                SET state = 'cancelled', lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running' AND cancellation_requested = 1
                """,
            values: [now.timeIntervalSince1970, id, leaseToken],
            afterUpdate: { database in
                try self.reconcileApprovedDeliveryTerminalOutcome(
                    database: database,
                    jobID: id,
                    terminalStatus: .cancelled,
                    updatedAt: now
                )
                try self.updateSyncReadiness(
                    database: database,
                    syncJobID: id,
                    state: "failed",
                    updatedAt: now
                )
                try self.recordSmartInboxReclassificationCompletion(
                    database: database,
                    jobID: id,
                    status: "cancelled",
                    errorClass: "cancelled"
                )
                try self.resolveSmartInboxFollowUpPair(
                    database: database,
                    predecessorID: id,
                    resolution: .cancel,
                    now: now
                )
                if try self.isSyncJob(database: database, id: id) {
                    try self.resumeSystemPausedSmartInboxWhenSyncInactive(
                        database: database,
                        now: now
                    )
                }
            }
        )
        MailStoreChangeSignal.post(scope: .operations)
    }

    public func prepareSmartInboxWork(
        jobID: String,
        leaseToken: String,
        seeds: [PlainpostSmartInboxWorkSeed],
        catalogSnapshot: MailLabelCatalogSnapshot? = nil
    ) throws {
        try databasePool.write { database in
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            let storedCatalogFingerprint = try String.fetchOne(
                database,
                sql: """
                    SELECT catalog_fingerprint
                    FROM smart_inbox_label_catalog_snapshots
                    WHERE job_id = ?
                    """,
                arguments: [jobID]
            )
            if storedCatalogFingerprint == nil, let catalogSnapshot {
                let labelsJSON = String(
                    decoding: try JSONEncoder().encode(
                        catalogSnapshot.labels.sorted { $0.id < $1.id }
                    ),
                    as: UTF8.self
                )
                try database.execute(
                    sql: """
                        INSERT INTO smart_inbox_label_catalog_snapshots (
                            job_id, catalog_fingerprint, labels_json, created_at
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        jobID,
                        catalogSnapshot.fingerprint,
                        labelsJSON,
                        catalogSnapshot.createdAt.timeIntervalSince1970,
                    ]
                )
            }
            let catalogFingerprint = storedCatalogFingerprint
                ?? catalogSnapshot?.fingerprint
                ?? ""
            let existingCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM smart_inbox_work_items WHERE job_id = ?",
                arguments: [jobID]
            ) ?? 0
            let jobRow = try Row.fetchOne(
                database,
                sql: "SELECT attempt FROM durable_jobs WHERE id = ?",
                arguments: [jobID]
            )
            let isPrepared = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM smart_inbox_work_preparations WHERE job_id = ?)",
                arguments: [jobID]
            ) ?? false
            if existingCount > 0 || isPrepared {
                let attempt: Int = jobRow?["attempt"] ?? 0
                if attempt > 1 {
                    try database.execute(
                        sql: """
                            UPDATE smart_inbox_work_items
                            SET state = 'pending', error_message = NULL, retry_reset_attempt = ?, updated_at = ?
                            WHERE job_id = ? AND state = 'failed' AND retry_reset_attempt < ?
                            """,
                        arguments: [attempt, Date().timeIntervalSince1970, jobID, attempt]
                    )
                }
                let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET progress_current = ?, progress_total = ?, progress_phase = 'classifying',
                            progress_label = 'Smart Inbox', updated_at = ?
                        WHERE id = ? AND lease_token = ? AND state = 'running'
                        """,
                    arguments: [
                        summary.processed, summary.total, Date().timeIntervalSince1970, jobID, leaseToken,
                    ]
                )
                return
            }
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: "INSERT INTO smart_inbox_work_preparations (job_id, prepared_at) VALUES (?, ?)",
                arguments: [jobID, now]
            )
            for seed in seeds {
                let ownership = try Self.messageRelationOwnership(
                    messageID: seed.messageID,
                    explicitAccountID: nil,
                    database: database
                )
                try database.execute(
                    sql: """
                        INSERT INTO smart_inbox_work_items (
                            job_id, ordinal, message_id, source_fingerprint, state,
                            catalog_fingerprint, updated_at, owner_account_id,
                            ownership_kind
                        ) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?)
                        """,
                    arguments: [
                        jobID, seed.ordinal, seed.messageID, seed.sourceFingerprint,
                        catalogFingerprint, now, ownership.owner, ownership.kind.rawValue,
                    ]
                )
            }
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET progress_current = 0, progress_total = ?, progress_phase = 'classifying',
                        progress_label = 'Smart Inbox', updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                    """,
                arguments: [seeds.count, now, jobID, leaseToken]
            )
        }
    }

    public func nextSmartInboxWorkItem(
        jobID: String,
        leaseToken: String
    ) throws -> PlainpostSmartInboxWorkItem? {
        try nextSmartInboxWorkItems(jobID: jobID, leaseToken: leaseToken, limit: 1).first
    }

    public func nextSmartInboxWorkItems(
        jobID: String,
        leaseToken: String,
        limit: Int
    ) throws -> [PlainpostSmartInboxWorkItem] {
        guard limit > 0 else {
            throw PlainpostError.validationFailed("Smart Inbox work item limit must be positive.")
        }
        return try databasePool.read { database in
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT job_id, ordinal, message_id, source_fingerprint, state,
                        category, priority, requires_action, confidence, label_matches_json,
                        catalog_fingerprint, error_message
                    FROM smart_inbox_work_items
                    WHERE job_id = ? AND state = 'pending'
                    ORDER BY ordinal ASC
                    LIMIT ?
                    """,
                arguments: [jobID, limit]
            )
            return try rows.map(decodeSmartInboxWorkItem)
        }
    }

    @discardableResult
    public func recordSmartInboxWorkItem(
        jobID: String,
        leaseToken: String,
        ordinal: Int,
        state requestedState: PlainpostSmartInboxWorkState,
        classifierDiscriminator: String = SmartInboxClassifierContract.legacyDiscriminator,
        category: SmartCategory? = nil,
        diagnosticCodes: [String] = [],
        errorMessage: String? = nil
    ) throws -> PlainpostSmartInboxWorkSummary {
        try databasePool.write { database in
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            guard let workRow = try Row.fetchOne(
                database,
                sql: "SELECT message_id, source_fingerprint, catalog_fingerprint FROM smart_inbox_work_items WHERE job_id = ? AND ordinal = ? AND state = 'pending'",
                arguments: [jobID, ordinal]
            ) else {
                throw PlainpostError.validationFailed("Smart Inbox checkpoint is no longer pending.")
            }

            let expectedFingerprint: String = workRow["source_fingerprint"]
            let messageID: String = workRow["message_id"]
            let catalogFingerprint: String = workRow["catalog_fingerprint"]
            let classificationInput = try smartInboxClassificationInput(
                database: database,
                messageID: messageID
            )
            let isCurrent = classificationInput.map { input in
                return !input.message.isDeleted
                    && SmartInboxClassificationFingerprint.message(
                        input,
                        classifierDiscriminator: classifierDiscriminator
                    ) == expectedFingerprint
            } ?? false
            let state = isCurrent ? requestedState : .skipped
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                    UPDATE smart_inbox_work_items
                    SET state = ?, category = ?, priority = NULL, requires_action = NULL,
                        confidence = NULL, error_message = ?, updated_at = ?
                    WHERE job_id = ? AND ordinal = ? AND state = 'pending'
                    """,
                arguments: [state.rawValue, state == .completed ? category?.rawValue : nil,
                            state == .failed ? errorMessage : nil, now, jobID, ordinal]
            )
            if state == .failed {
                let codes = diagnosticCodes.isEmpty
                    ? ["validation.invalid_response"]
                    : Array(Set(diagnosticCodes)).sorted()
                let codesJSON = String(
                    decoding: try JSONEncoder().encode(codes),
                    as: UTF8.self
                )
                try database.execute(
                    sql: """
                        INSERT INTO smart_inbox_failure_suppressions (
                            message_id, source_fingerprint, catalog_fingerprint,
                            classifier_discriminator, diagnostic_codes_json, failed_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(message_id) DO UPDATE SET
                            source_fingerprint = excluded.source_fingerprint,
                            catalog_fingerprint = excluded.catalog_fingerprint,
                            classifier_discriminator = excluded.classifier_discriminator,
                            diagnostic_codes_json = excluded.diagnostic_codes_json,
                            failed_at = excluded.failed_at
                        """,
                    arguments: [
                        messageID, expectedFingerprint, catalogFingerprint,
                        classifierDiscriminator, codesJSON, now,
                    ]
                )
            }
            let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET progress_current = ?, progress_total = ?, progress_phase = 'classifying',
                        progress_label = 'Smart Inbox', updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                    """,
                arguments: [summary.processed, summary.total, now, jobID, leaseToken]
            )
            return summary
        }
    }

    @discardableResult
    public func recordSmartInboxClassification(
        jobID: String,
        leaseToken: String,
        ordinal: Int,
        classification: SmartInboxClassification,
        providerID: String,
        modelID: String,
        classifierDiscriminator: String? = nil,
        actor: Actor
    ) throws -> PlainpostSmartInboxWorkSummary {
        try recordSmartInboxClassification(
            jobID: jobID,
            leaseToken: leaseToken,
            ordinal: ordinal,
            expectedMessageID: classification.messageID,
            category: classification.category,
            priority: classification.priority,
            requiresAction: classification.requiresAction,
            confidence: classification.confidence,
            labelMatches: classification.labelMatches,
            providerID: providerID,
            modelID: modelID,
            classifierDiscriminator: classifierDiscriminator
                ?? SmartInboxClassifierContract.discriminator(providerID: providerID, modelID: modelID),
            writesEnrichedProjection: true,
            actor: actor
        )
    }

    @discardableResult
    public func recordSmartInboxClassification(
        jobID: String,
        leaseToken: String,
        ordinal: Int,
        category: SmartCategory,
        providerID: String,
        modelID: String?,
        actor: Actor
    ) throws -> PlainpostSmartInboxWorkSummary {
        try recordSmartInboxClassification(
            jobID: jobID,
            leaseToken: leaseToken,
            ordinal: ordinal,
            expectedMessageID: nil,
            category: category,
            priority: nil,
            requiresAction: nil,
            confidence: nil,
            labelMatches: [],
            providerID: providerID,
            modelID: modelID,
            classifierDiscriminator: SmartInboxClassifierContract.legacyDiscriminator,
            writesEnrichedProjection: false,
            actor: actor
        )
    }

    private func recordSmartInboxClassification(
        jobID: String,
        leaseToken: String,
        ordinal: Int,
        expectedMessageID: MessageID?,
        category: SmartCategory,
        priority: SmartPriority?,
        requiresAction: Bool?,
        confidence: Double?,
        labelMatches: [SmartInboxLabelMatch],
        providerID: String,
        modelID: String?,
        classifierDiscriminator: String,
        writesEnrichedProjection: Bool,
        actor: Actor
    ) throws -> PlainpostSmartInboxWorkSummary {
        guard actor.permissions.recategorize else {
            throw PlainpostError.permissionDenied("Actor is not allowed to recategorize messages.")
        }
        return try databasePool.write { database in
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            guard let workRow = try Row.fetchOne(
                database,
                sql: "SELECT message_id, source_fingerprint FROM smart_inbox_work_items WHERE job_id = ? AND ordinal = ? AND state = 'pending'",
                arguments: [jobID, ordinal]
            ) else {
                throw PlainpostError.validationFailed("Smart Inbox checkpoint is no longer pending.")
            }

            let expectedFingerprint: String = workRow["source_fingerprint"]
            let messageID: String = workRow["message_id"]
            if let expectedMessageID {
                guard expectedMessageID.rawValue == messageID else {
                    throw PlainpostError.validationFailed("Smart Inbox classification message does not match its checkpoint.")
                }
            }
            let classificationInput = try smartInboxClassificationInput(
                database: database,
                messageID: messageID
            )
            let isCurrent = classificationInput.map { input in
                return !input.message.isDeleted
                    && SmartInboxClassificationFingerprint.message(
                        input,
                        classifierDiscriminator: classifierDiscriminator
                    ) == expectedFingerprint
            } ?? false
            let now = Date().timeIntervalSince1970
            if isCurrent {
                let labelMatchesJSON = try encodeSmartInboxLabelMatches(labelMatches)
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_work_items
                        SET state = 'completed', category = ?, priority = ?, requires_action = ?,
                            confidence = ?, label_matches_json = ?, classifier_discriminator = ?,
                            provider_id = ?, model_id = ?, writes_enriched_projection = ?,
                            error_message = NULL, updated_at = ?
                        WHERE job_id = ? AND ordinal = ? AND state = 'pending'
                        """,
                    arguments: [
                        category.rawValue, priority?.rawValue, requiresAction, confidence,
                        labelMatchesJSON, classifierDiscriminator, providerID, modelID,
                        writesEnrichedProjection, now, jobID, ordinal,
                    ]
                )
            } else {
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_work_items
                        SET state = 'skipped', category = NULL, priority = NULL,
                            requires_action = NULL, confidence = NULL, label_matches_json = '[]',
                            error_message = NULL, updated_at = ?
                        WHERE job_id = ? AND ordinal = ? AND state = 'pending'
                        """,
                    arguments: [now, jobID, ordinal]
                )
            }
            let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET progress_current = ?, progress_total = ?, progress_phase = 'classifying',
                        progress_label = 'Smart Inbox', updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                    """,
                arguments: [summary.processed, summary.total, now, jobID, leaseToken]
            )
            return summary
        }
    }

    public func smartInboxWorkSummary(jobID: String) throws -> PlainpostSmartInboxWorkSummary {
        try databasePool.read { database in
            try smartInboxWorkSummary(database: database, jobID: jobID)
        }
    }

    @discardableResult
    public func applySmartInboxWork(
        jobID: String,
        leaseToken: String,
        actor: Actor
    ) throws -> PlainpostSmartInboxWorkSummary {
        guard actor.permissions.recategorize else {
            throw PlainpostError.permissionDenied("Actor is not allowed to recategorize messages.")
        }
        let ordinals = try databasePool.read { database in
            try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
            return try Int.fetchAll(
                database,
                sql: """
                    SELECT ordinal
                    FROM smart_inbox_work_items
                    WHERE job_id = ? AND state = 'completed'
                    ORDER BY ordinal
                    """,
                arguments: [jobID]
            )
        }
        var appliedCount = 0
        for ordinal in ordinals {
            let applied = try databasePool.write { database in
                try validateRunningLease(database: database, jobID: jobID, leaseToken: leaseToken)
                let auditOwnership = try Self.requiredJobOwnership(jobID: jobID, database: database)
                guard let work = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT message_id, source_fingerprint, category, priority,
                            requires_action, confidence, label_matches_json,
                            catalog_fingerprint, classifier_discriminator, provider_id,
                            model_id, writes_enriched_projection
                        FROM smart_inbox_work_items
                        WHERE job_id = ? AND ordinal = ? AND state = 'completed'
                        """,
                    arguments: [jobID, ordinal]
                ) else {
                    return false
                }
                let messageID: String = work["message_id"]
                let classifierDiscriminator: String = work["classifier_discriminator"]
                let expectedFingerprint: String = work["source_fingerprint"]
                guard let input = try smartInboxClassificationInput(
                    database: database,
                    messageID: messageID
                ), !input.message.isDeleted,
                   SmartInboxClassificationFingerprint.message(
                       input,
                       classifierDiscriminator: classifierDiscriminator
                   ) == expectedFingerprint else {
                    try database.execute(
                        sql: """
                            UPDATE smart_inbox_work_items
                            SET state = 'skipped', category = NULL, priority = NULL,
                                requires_action = NULL, confidence = NULL,
                                label_matches_json = '[]', was_updated = NULL, updated_at = ?
                            WHERE job_id = ? AND ordinal = ? AND state = 'completed'
                            """,
                        arguments: [Date().timeIntervalSince1970, jobID, ordinal]
                    )
                    return false
                }
                guard let category = SmartCategory(rawValue: work["category"]) else {
                    throw PlainpostError.validationFailed(
                        "Smart Inbox checkpoint category is invalid."
                    )
                }
                let priority = (work["priority"] as String?).flatMap(SmartPriority.init(rawValue:))
                let requiresAction: Bool? = work["requires_action"]
                let confidence: Double? = work["confidence"]
                let requestedMatches = try decodeSmartInboxLabelMatches(
                    work["label_matches_json"]
                )
                let snapshotRow = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT labels_json
                        FROM smart_inbox_label_catalog_snapshots
                        WHERE job_id = ?
                        """,
                    arguments: [jobID]
                )
                let snapshotLabels: [MailLabelDefinition]
                if let snapshotRow {
                    let labelsJSON: String = snapshotRow["labels_json"]
                    snapshotLabels = try JSONDecoder().decode(
                        [MailLabelDefinition].self,
                        from: Data(labelsJSON.utf8)
                    )
                } else {
                    snapshotLabels = []
                }
                let eligibleSnapshotIDs = Set(
                    snapshotLabels
                        .filter {
                            $0.isSmartInboxEnabled
                                && !$0.description.isEmpty
                                && $0.scope.includes(input.accountID)
                        }
                        .map(\.id)
                )
                let exclusions = Set(try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id
                        FROM message_label_exclusions
                        WHERE message_id = ?
                        """,
                    arguments: [messageID]
                ))
                var acceptedMatches: [SmartInboxLabelMatch] = []
                for match in requestedMatches where eligibleSnapshotIDs.contains(match.labelID) {
                    guard !exclusions.contains(match.labelID),
                          let currentLabel = try Row.fetchOne(
                              database,
                              sql: """
                                  SELECT scope_account_id
                                  FROM mail_labels
                                  WHERE id = ?
                                  """,
                              arguments: [match.labelID]
                          ) else {
                        continue
                    }
                    let scopedAccountID: String? = currentLabel["scope_account_id"]
                    guard scopedAccountID == nil || scopedAccountID == input.accountID.rawValue else {
                        continue
                    }
                    acceptedMatches.append(match)
                }
                acceptedMatches.sort { $0.labelID < $1.labelID }
                let desiredSmartLabelIDs = Set(acceptedMatches.map(\.labelID))
                let previousSmartLabelIDs = Set(try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id
                        FROM message_label_assignments
                        WHERE message_id = ? AND source_kind = 'smartInbox' AND source_id = ''
                        """,
                    arguments: [messageID]
                ))
                let previousMessage = input.message
                let writesEnrichedProjection: Bool = work["writes_enriched_projection"]
                if writesEnrichedProjection {
                    try database.execute(
                        sql: """
                            UPDATE messages
                            SET smart_category = ?, smart_priority = ?,
                                smart_requires_action = ?, smart_confidence = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            category.rawValue,
                            priority?.rawValue ?? SmartPriority.normal.rawValue,
                            requiresAction ?? false,
                            confidence,
                            messageID,
                        ]
                    )
                } else {
                    try database.execute(
                        sql: "UPDATE messages SET smart_category = ? WHERE id = ?",
                        arguments: [category.rawValue, messageID]
                    )
                }
                try database.execute(
                    sql: """
                        DELETE FROM message_label_assignments
                        WHERE message_id = ? AND source_kind = 'smartInbox' AND source_id = ''
                        """,
                    arguments: [messageID]
                )
                let now = Date().timeIntervalSince1970
                for labelID in desiredSmartLabelIDs.sorted() {
                    try database.execute(
                        sql: """
                            INSERT INTO message_label_assignments (
                                message_id, label_id, source_kind, source_id, created_at
                            ) VALUES (?, ?, 'smartInbox', '', ?)
                            """,
                        arguments: [messageID, labelID, now]
                    )
                }
                try rebuildEffectiveLabelProjection(database: database, messageID: messageID)
                let acceptedMatchesJSON = try encodeSmartInboxLabelMatches(acceptedMatches)
                let catalogFingerprint: String = work["catalog_fingerprint"]
                let providerID: String = work["provider_id"]
                let modelID: String? = work["model_id"]
                try database.execute(
                    sql: """
                        INSERT INTO smart_inbox_classification_cache (
                            message_id, source_fingerprint, category, priority, requires_action,
                            confidence, label_matches_json, catalog_fingerprint, provider_id,
                            model_id, classified_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(message_id) DO UPDATE SET
                            source_fingerprint = excluded.source_fingerprint,
                            category = excluded.category,
                            priority = excluded.priority,
                            requires_action = excluded.requires_action,
                            confidence = excluded.confidence,
                            label_matches_json = excluded.label_matches_json,
                            catalog_fingerprint = excluded.catalog_fingerprint,
                            provider_id = excluded.provider_id,
                            model_id = excluded.model_id,
                            classified_at = excluded.classified_at,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        messageID,
                        expectedFingerprint,
                        category.rawValue,
                        priority?.rawValue ?? SmartPriority.normal.rawValue,
                        requiresAction ?? false,
                        confidence,
                        acceptedMatchesJSON,
                        catalogFingerprint,
                        providerID,
                        modelID,
                        now,
                        now,
                    ]
                )
                try database.execute(
                    sql: "DELETE FROM smart_inbox_failure_suppressions WHERE message_id = ?",
                    arguments: [messageID]
                )
                let triageChanged = previousMessage.smartCategory != category
                    || (
                        writesEnrichedProjection
                            && (
                                previousMessage.smartPriority != (priority ?? .normal)
                                    || previousMessage.smartRequiresAction != (requiresAction ?? false)
                                    || previousMessage.smartConfidence != confidence
                            )
                    )
                let wasUpdated = triageChanged || previousSmartLabelIDs != desiredSmartLabelIDs
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_work_items
                        SET state = 'applied', label_matches_json = ?, was_updated = ?, updated_at = ?
                        WHERE job_id = ? AND ordinal = ? AND state = 'completed'
                        """,
                    arguments: [
                        acceptedMatchesJSON, wasUpdated, now, jobID, ordinal,
                    ]
                )
                let auditResult = SmartInboxReconciliationAuditResult(
                    category: category.rawValue,
                    addedLabelIDs: desiredSmartLabelIDs
                        .subtracting(previousSmartLabelIDs)
                        .sorted(),
                    modelID: modelID,
                    providerID: providerID,
                    removedLabelIDs: previousSmartLabelIDs
                        .subtracting(desiredSmartLabelIDs)
                        .sorted()
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "smart_inbox.reconcile",
                    targetType: "message",
                    targetID: messageID,
                    result: try canonicalAuditResult(auditResult),
                    ownership: auditOwnership
                )
                return true
            }
            if applied {
                appliedCount += 1
            }
        }
        if appliedCount > 0 {
            try? flushAuditOutbox()
            MailStoreChangeSignal.post(scope: .mailbox)
        }
        return try smartInboxWorkSummary(jobID: jobID)
    }

    public func updateJobProgress(id: String, leaseToken: String, progress: PlainpostOperationProgress) throws {
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs SET progress_current = ?, progress_total = ?, progress_phase = ?,
                    progress_label = ?, updated_at = ? WHERE id = ? AND lease_token = ? AND state = 'running'
                """,
            values: [
                String(progress.current), progress.total.map(String.init), progress.phase, progress.label,
                Date().timeIntervalSince1970, id, leaseToken
            ]
        )
    }

    public func updateSmartInboxPreemptionProgress(
        id: String,
        leaseToken: String,
        phase: String
    ) throws -> Bool {
        try databasePool.write { database in
            try database.execute(
                sql: """
                UPDATE durable_jobs SET progress_phase = ?, progress_label = 'Smart Inbox', updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running'
                  AND cancellation_requested = 0 AND pause_requested = 0
                """,
                arguments: [phase, Date().timeIntervalSince1970, id, leaseToken]
            )
            return database.changesCount == 1
        }
    }

    public func clearSmartInboxPreemptionProgress(id: String, leaseToken: String) throws {
        try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET progress_phase = 'classifying', progress_label = 'Smart Inbox', updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running' AND progress_phase = 'pausing'
                    """,
                arguments: [Date().timeIntervalSince1970, id, leaseToken]
            )
        }
    }

    public func renewJobLease(id: String, leaseToken: String, now: Date = Date(), leaseDuration: TimeInterval = 180) throws {
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs SET lease_expires_at = ?, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running'
                """,
            values: [now.addingTimeInterval(max(10, leaseDuration)).timeIntervalSince1970,
                     now.timeIntervalSince1970, id, leaseToken]
        )
    }

    public func renewSmartInboxLease(
        id: String,
        leaseToken: String,
        now: Date = Date(),
        leaseDuration: TimeInterval = 180
    ) throws -> Bool {
        try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE durable_jobs SET lease_expires_at = ?, updated_at = ?
                    WHERE id = ? AND lease_token = ? AND state = 'running'
                    """,
                arguments: [
                    now.addingTimeInterval(max(10, leaseDuration)).timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    id,
                    leaseToken,
                ]
            )
            return database.changesCount == 1
        }
    }

    public func inboxSyncReconciliationGeneration(id: String, leaseToken: String) throws -> Int {
        try databasePool.write { database in
            try validateRunningLease(database: database, jobID: id, leaseToken: leaseToken)
            let cancellationRequested = try Bool.fetchOne(
                database,
                sql: "SELECT cancellation_requested FROM durable_jobs WHERE id = ?",
                arguments: [id]
            ) ?? false
            guard !cancellationRequested else {
                throw PlainpostError.validationFailed("Local operation is being cancelled.")
            }
            guard let generation = try Int.fetchOne(
                database,
                sql: "SELECT reconciliation_generation FROM sync_job_scopes WHERE job_id = ?",
                arguments: [id]
            ) else {
                throw PlainpostError.validationFailed("Inbox sync reconciliation scope is unavailable.")
            }
            return generation
        }
    }

    /// Completes a successful inbox-sync pass only when no reconciliation
    /// request arrived after that pass observed its generation. Returning
    /// `true` keeps the leased job running for one coalesced follow-up pass.
    public func completeInboxSyncPass(
        id: String,
        leaseToken: String,
        observedReconciliationGeneration: Int,
        resultArtifactID: String?
    ) throws -> Bool {
        let now = Date()
        let needsRerun = try databasePool.write { database in
            try validateRunningLease(database: database, jobID: id, leaseToken: leaseToken)
            let cancellationRequested = try Bool.fetchOne(
                database,
                sql: "SELECT cancellation_requested FROM durable_jobs WHERE id = ?",
                arguments: [id]
            ) ?? false
            guard !cancellationRequested else {
                throw PlainpostError.validationFailed("Local operation is being cancelled.")
            }
            guard let currentGeneration = try Int.fetchOne(
                database,
                sql: "SELECT reconciliation_generation FROM sync_job_scopes WHERE job_id = ?",
                arguments: [id]
            ) else {
                throw PlainpostError.validationFailed("Inbox sync reconciliation scope is unavailable.")
            }
            if currentGeneration > observedReconciliationGeneration {
                return true
            }
            if let scope = try Row.fetchOne(database, sql: "SELECT * FROM sync_job_scopes WHERE job_id = ?", arguments: [id]) {
                let requested: Int64 = scope["foreground_requested_revision"]
                if requested > 0 {
                    guard let receipt = try Self.foregroundReceipt(scope), receipt.revision >= requested else { return true }
                    guard try Self.foregroundUIDValidity(database: database, accountID: receipt.accountID, path: receipt.mailboxPath) == receipt.uidValidity else { return true }
                }
            }
            try Self.validateResultArtifactOwnership(
                database: database,
                jobID: id,
                resultArtifactID: resultArtifactID
            )
            try database.execute(
                sql: """
                    UPDATE durable_jobs SET state = 'completed', result_artifact_id = ?, lease_token = NULL,
                        lease_expires_at = NULL, updated_at = ? WHERE id = ? AND lease_token = ? AND state = 'running'
                        AND cancellation_requested = 0
                    """,
                arguments: [resultArtifactID, now.timeIntervalSince1970, id, leaseToken]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed("Local operation lease is no longer valid.")
            }
            try completeSyncReadiness(
                database: database,
                syncJobID: id,
                updatedAt: now
            )
            try recordSmartInboxReclassificationCompletion(
                database: database,
                jobID: id,
                status: "completed",
                errorClass: nil
            )
            return false
        }
        if !needsRerun {
            MailStoreChangeSignal.post(scope: .operations)
        }
        return needsRerun
    }

    public func completeJob(id: String, leaseToken: String, resultArtifactID: String?) throws {
        let now = Date()
        _ = try databasePool.write { database in
            try validateRunningLease(database: database, jobID: id, leaseToken: leaseToken)
            try Self.validateResultArtifactOwnership(
                database: database,
                jobID: id,
                resultArtifactID: resultArtifactID
            )
            let completionErrorCode = try self.smartInboxCompletionErrorCode(
                database: database,
                resultArtifactID: resultArtifactID
            )
            try database.execute(sql: """
                UPDATE durable_jobs SET state = 'completed', result_artifact_id = ?, lease_token = NULL,
                    lease_expires_at = NULL, error_code = ?, error_message = NULL, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running'
                    AND cancellation_requested = 0
                """, arguments: [
                    resultArtifactID, completionErrorCode, now.timeIntervalSince1970, id, leaseToken,
                ])
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed("Local operation lease is no longer valid.")
            }
            try self.completeSyncReadiness(database: database, syncJobID: id, updatedAt: now)
            try self.recordSmartInboxReclassificationCompletion(
                database: database, jobID: id, status: "completed", errorClass: nil
            )
            try self.resolveSmartInboxFollowUpPair(
                database: database,
                predecessorID: id,
                resolution: .promote,
                now: now
            )
        }
        MailStoreChangeSignal.post(scope: .operations)
    }

    private func smartInboxCompletionErrorCode(
        database: Database,
        resultArtifactID: String?
    ) throws -> String? {
        guard let resultArtifactID,
              let payloadJSON = try String.fetchOne(
                database,
                sql: "SELECT payload_json FROM durable_operation_artifacts WHERE id = ?",
                arguments: [resultArtifactID]
              ),
              let payload = try? JSONDecoder().decode(
                PlainpostLocalAIArtifactPayload.self,
                from: Data(payloadJSON.utf8)
              ),
              (payload.failedMessageCount ?? 0) > 0 else {
            return nil
        }
        return "SMART_INBOX_PARTIAL_FAILURE"
    }

    private enum SmartInboxFollowUpResolution {
        case promote
        case cancel
    }

    private func resolveSmartInboxFollowUpPair(
        database: Database,
        predecessorID: String,
        resolution: SmartInboxFollowUpResolution,
        now: Date
    ) throws {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT predecessor_job_id, successor_job_id
                FROM smart_inbox_incremental_follow_up_demands
                WHERE predecessor_job_id = ? OR successor_job_id = ?
                """,
            arguments: [predecessorID, predecessorID]
        ) else { return }
        let resolvedPredecessorID: String = row["predecessor_job_id"]
        guard let successorID = row["successor_job_id"] as String? else {
            throw PlainpostError.validationFailed("Smart Inbox follow-up pair is incomplete.")
        }
        let effectiveResolution: SmartInboxFollowUpResolution
        switch resolution {
        case .promote:
            effectiveResolution = try smartInboxFollowUpHasEligibleWork(
                database: database,
                successorID: successorID
            ) ? .promote : .cancel
        case .cancel:
            effectiveResolution = .cancel
        }
        switch effectiveResolution {
        case .promote:
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued', pause_reason = NULL, progress_phase = 'queued',
                        available_at = ?, updated_at = ?
                    WHERE id = ? AND state = 'paused'
                      AND pause_reason = 'smart-inbox-follow-up'
                    """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, successorID]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed("Smart Inbox follow-up could not be promoted.")
            }
            try database.execute(
                sql: """
                    INSERT INTO smart_inbox_promoted_successors (
                        predecessor_job_id, successor_job_id
                    ) VALUES (?, ?)
                    ON CONFLICT(predecessor_job_id) DO UPDATE SET
                        successor_job_id = excluded.successor_job_id
                    """,
                arguments: [resolvedPredecessorID, successorID]
            )
        case .cancel:
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'cancelled', cancellation_requested = 1,
                        lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE id = ? AND state IN ('queued', 'running', 'paused')
                    """,
                arguments: [now.timeIntervalSince1970, successorID]
            )
            try database.execute(
                sql: "DELETE FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                arguments: [resolvedPredecessorID]
            )
        }
        try database.execute(
            sql: "DELETE FROM smart_inbox_incremental_follow_up_demands WHERE predecessor_job_id = ?",
            arguments: [resolvedPredecessorID]
        )
    }

    private func smartInboxFollowUpHasEligibleWork(
        database: Database,
        successorID: String
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT payload_json FROM durable_jobs WHERE id = ?",
            arguments: [successorID]
        ),
        let input = try? JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data((row["payload_json"] as String).utf8)
        ),
        input.operation == .recategorizeInbox,
        input.smartInboxRunMode == .incremental,
        let catalogFingerprint = try String.fetchOne(
            database,
            sql: """
                SELECT catalog_fingerprint
                FROM smart_inbox_label_catalog_snapshots
                WHERE job_id = ?
                """,
            arguments: [successorID]
        ) else {
            return true
        }
        let classifierDiscriminator = input.resolvedSmartInboxClassifierIdentity.discriminator
        let classificationInputs = try smartInboxClassificationInputs(
            database: database,
            scope: input.smartInboxRunRequest.scope
        )
        return try !eligibleIncrementalSmartInboxInputs(
            database: database,
            classificationInputs: classificationInputs,
            classifierDiscriminator: classifierDiscriminator,
            catalogFingerprint: catalogFingerprint
        ).isEmpty
    }

    public func terminalSmartInboxSuccessor(after jobID: String) throws -> String? {
        try databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT successor_job_id FROM smart_inbox_promoted_successors WHERE predecessor_job_id = ?",
                arguments: [jobID]
            )
        }
    }

    public func failJob(id: String, leaseToken: String, code: String, message: String, retryAt: Date?) throws {
        let state = retryAt == nil ? PlainpostOperationState.failed.rawValue : PlainpostOperationState.queued.rawValue
        let now = Date()
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs SET state = ?, available_at = COALESCE(?, available_at), error_code = ?,
                    error_message = ?, lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running'
                """,
            values: [state, retryAt?.timeIntervalSince1970, code, message,
                     now.timeIntervalSince1970, id, leaseToken],
            afterUpdate: { database in
                try self.updateSyncReadiness(
                    database: database,
                    syncJobID: id,
                    state: retryAt == nil ? "failed" : "pending",
                    updatedAt: now
                )
                if retryAt == nil {
                    let isTerminalSync = try self.isSyncJob(database: database, id: id)
                    try self.reconcileApprovedDeliveryTerminalOutcome(
                        database: database,
                        jobID: id,
                        terminalStatus: .failed,
                        updatedAt: now
                    )
                    try self.recordSmartInboxReclassificationCompletion(
                        database: database,
                        jobID: id,
                        status: "failed",
                        errorClass: code
                    )
                    try self.resolveSmartInboxFollowUpPair(
                        database: database,
                        predecessorID: id,
                        resolution: .promote,
                        now: now
                    )
                    if isTerminalSync {
                        try self.resumeSystemPausedSmartInboxWhenSyncInactive(
                            database: database,
                            now: now
                        )
                    }
                }
            }
        )
        MailStoreChangeSignal.post(scope: .operations)
    }

    public func markDeliveryUncertain(id: String, leaseToken: String, message: String) throws {
        let now = Date()
        try updateLeasedJob(
            id: id,
            leaseToken: leaseToken,
            sql: """
                UPDATE durable_jobs SET state = 'delivery-uncertain', error_code = 'DELIVERY_UNCERTAIN',
                    error_message = ?, lease_token = NULL, lease_expires_at = NULL, updated_at = ?
                WHERE id = ? AND lease_token = ? AND state = 'running'
                """,
            values: [message, now.timeIntervalSince1970, id, leaseToken],
            afterUpdate: { database in
                try self.reconcileApprovedDeliveryTerminalOutcome(
                    database: database,
                    jobID: id,
                    terminalStatus: .deliveryUncertain,
                    updatedAt: now
                )
            }
        )
        MailStoreChangeSignal.post(scope: .operations)
    }

    public func requestJobCancellation(id: String) throws {
        let isTerminal = try databasePool.read { database in
            guard let state = try String.fetchOne(
                database,
                sql: "SELECT state FROM durable_jobs WHERE id = ?",
                arguments: [id]
            ) else {
                return true
            }
            return ["completed", "failed", "cancelled", "delivery-uncertain"].contains(state)
        }
        // This is only a contention-avoidance fast path. The state predicate
        // in the write below remains authoritative if a peer completes after
        // this read and before the write transaction begins.
        guard !isTerminal else { return }
        let now = Date()
        try onJobCancellationBeforeUpdate?()
        try databasePool.write { database in
            try self.cancelJob(database: database, id: id, now: now)
        }
        MailStoreChangeSignal.post(scope: .operations)
    }

    /// The database-transaction core of job cancellation, shared by
    /// `requestJobCancellation` and any other write that must cancel a job as
    /// part of a larger atomic transaction (e.g. switching the Smart Inbox
    /// mode). Callers own their own write transaction and the
    /// `MailStoreChangeSignal.post` that follows it.
    package func cancelJob(database: Database, id: String, now: Date) throws {
        try database.execute(
            sql: """
                UPDATE durable_jobs SET cancellation_requested = 1,
                    state = CASE WHEN state IN ('queued', 'paused') THEN 'cancelled' ELSE state END,
                    lease_token = CASE WHEN state IN ('queued', 'paused') THEN NULL ELSE lease_token END,
                    lease_expires_at = CASE WHEN state IN ('queued', 'paused') THEN NULL ELSE lease_expires_at END,
                    updated_at = ?
                WHERE id = ?
                  AND state NOT IN ('completed', 'failed', 'cancelled', 'delivery-uncertain')
            """,
            arguments: [now.timeIntervalSince1970, id]
        )
        guard database.changesCount == 1 else { return }
        let isCancelled = try Bool.fetchOne(
            database,
            sql: "SELECT state = 'cancelled' FROM durable_jobs WHERE id = ?",
            arguments: [id]
        ) ?? false
        if isCancelled {
            try self.reconcileApprovedDeliveryTerminalOutcome(
                database: database,
                jobID: id,
                terminalStatus: .cancelled,
                updatedAt: now
            )
            try updateSyncReadiness(
                database: database,
                syncJobID: id,
                state: "failed",
                updatedAt: now
            )
            try recordSmartInboxReclassificationCompletion(
                database: database,
                jobID: id,
                status: "cancelled",
                errorClass: "cancelled"
            )
            try resolveSmartInboxFollowUpPair(
                database: database,
                predecessorID: id,
                resolution: .cancel,
                now: now
            )
            if try self.isSyncJob(database: database, id: id) {
                try self.resumeSystemPausedSmartInboxWhenSyncInactive(
                    database: database,
                    now: now
                )
            }
        }
    }

    public func pruneTerminalJobs(before: Date) throws {
        do {
            try databasePool.write { database in
                try database.execute(
                    sql: "DELETE FROM durable_jobs WHERE state IN ('completed', 'failed', 'cancelled') AND updated_at < ?",
                    arguments: [before.timeIntervalSince1970]
                )
                try database.execute(sql: """
                    DELETE FROM durable_job_terminal_events
                    WHERE NOT EXISTS (
                        SELECT 1 FROM durable_jobs
                        WHERE durable_jobs.id = durable_job_terminal_events.job_id
                    )
                    """)
            }
        } catch {
            throw databaseError(error)
        }
    }

    private func validateRunningLease(database: Database, jobID: String, leaseToken: String) throws {
        let valid = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM durable_jobs
                    WHERE id = ? AND lease_token = ? AND state = 'running' AND cancellation_requested = 0
                )
                """,
            arguments: [jobID, leaseToken]
        ) ?? false
        guard valid else {
            throw PlainpostError.validationFailed("Local operation lease is no longer valid.")
        }
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, payload_json, pause_requested, pause_reason FROM durable_jobs WHERE id = ?",
            arguments: [jobID]
        ) {
            try Self.requireVersionedJobDirectSource(row, database: database)
        }
        if let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, payload_json, pause_requested, pause_reason FROM durable_jobs WHERE id = ?",
            arguments: [jobID]
        ), (row["kind"] as String) == PlainpostOperationKind.aiOperation.rawValue,
           let input = try? JSONDecoder().decode(
               PlainpostAIOperationInput.self,
               from: Data((row["payload_json"] as String).utf8)
           ), input.operation == .recategorizeInbox {
            try Self.requireSmartInboxEnabled(in: database)
            if row["pause_requested"] as Bool {
                throw SmartInboxPolicyError.disabled
            }
            try Self.requireSmartInboxDirectSource(input: input, database: database)
        }
    }

    private static func requireVersionedJobDirectSource(_ row: Row, database: Database) throws {
        let payload = Data((row["payload_json"] as String).utf8)
        let kind = PlainpostOperationKind(rawValue: row["kind"] as String)
        let source: (AccountID, Int64)?
        switch kind {
        case .inboxSync, .historicalSync:
            let input = try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: payload)
            source = input.expectedDirectSourceGeneration.map { (input.accountID, $0) }
        case .mailboxFlag:
            let input = try JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: payload)
            source = input.accountID.flatMap { accountID in
                input.expectedDirectSourceGeneration.map { (accountID, $0) }
            }
            if input.expectedDirectSourceGeneration != nil && source == nil {
                throw PlainpostError.validationFailed("A versioned mailbox flag requires its account.")
            }
        case .mailboxArchive:
            let input = try JSONDecoder().decode(PlainpostMailboxArchiveInput.self, from: payload)
            source = input.expectedDirectSourceGeneration.map { (input.accountID, $0) }
        default:
            source = nil
        }
        if let source {
            try requireDirectSource(accountID: source.0, generation: source.1, allowNodeFallback: true, database: database)
        }
    }

    private static func requireSmartInboxDirectSource(
        input: PlainpostAIOperationInput,
        database: Database
    ) throws {
        guard input.operation == .recategorizeInbox else { return }
        guard input.accountID != nil || input.expectedDirectSourceGeneration != nil else { return }
        guard let accountID = input.accountID,
              let generation = input.expectedDirectSourceGeneration,
              input.smartInboxRunRequest.scope == .account(accountID) else {
            throw PlainpostError.validationFailed(
                "A Direct Smart Inbox job requires its account and source generation."
            )
        }
        try requireDirectSource(accountID: accountID, generation: generation, database: database)
    }

    public func requireSmartInboxDirectSource(_ input: PlainpostAIOperationInput) throws {
        try databasePool.read { database in
            try Self.requireSmartInboxDirectSource(input: input, database: database)
        }
    }

    private func decodeSmartInboxWorkItem(_ row: Row) throws -> PlainpostSmartInboxWorkItem {
        guard let state = PlainpostSmartInboxWorkState(rawValue: row["state"]) else {
            throw PlainpostError.validationFailed("Smart Inbox checkpoint is invalid.")
        }
        return PlainpostSmartInboxWorkItem(
            jobID: row["job_id"],
            ordinal: row["ordinal"],
            messageID: row["message_id"],
            sourceFingerprint: row["source_fingerprint"],
            state: state,
            category: row["category"],
            priority: row["priority"],
            requiresAction: row["requires_action"],
            confidence: row["confidence"],
            labelMatches: try decodeSmartInboxLabelMatches(row["label_matches_json"]),
            catalogFingerprint: row["catalog_fingerprint"],
            errorMessage: row["error_message"]
        )
    }

    private func decodeSmartInboxLabelMatches(_ json: String) throws -> [SmartInboxLabelMatch] {
        try JSONDecoder().decode([SmartInboxLabelMatch].self, from: Data(json.utf8))
    }

    private func encodeSmartInboxLabelMatches(_ matches: [SmartInboxLabelMatch]) throws -> String {
        String(decoding: try JSONEncoder().encode(matches), as: UTF8.self)
    }

    private func smartInboxClassificationInput(
        database: Database,
        messageID: String
    ) throws -> SmartInboxClassificationInput? {
        onSmartInboxClassificationInputRead?()
        let accountExpression = Self.smartInboxMessageAccountExpression(messageAlias: "m")
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT m.id, m.account_id, m.thread_id, m.from_email, m.from_display_name,
                    m.subject, m.preview, m.body_text, m.to_emails, m.cc_emails,
                    m.smart_category, m.smart_priority, m.smart_requires_action,
                    m.smart_confidence, m.labels_json, m.is_seen, m.is_flagged, m.mailbox_path,
                    m.is_deleted, m.sent_at, \(accountExpression) AS resolved_account_id
                FROM messages m
                WHERE m.id = ?
                """,
            arguments: [messageID]
        ) else {
            return nil
        }
        let toEmails: String = row["to_emails"]
        let ccEmails: String = row["cc_emails"]
        let rawAccountID: String? = row["resolved_account_id"]
        return SmartInboxClassificationInput(
            message: decodeMailboxListMessage(row),
            accountID: AccountID(rawAccountID ?? ""),
            recipients: (toEmails + "\n" + ccEmails)
                .split(separator: "\n")
                .map { EmailAddress(String($0)) },
            bodyExcerpt: String((row["body_text"] as String).prefix(3_000))
        )
    }

    private func smartInboxWorkSummary(
        database: Database,
        jobID: String
    ) throws -> PlainpostSmartInboxWorkSummary {
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) AS total,
                    SUM(CASE WHEN state != 'pending' THEN 1 ELSE 0 END) AS processed,
                    SUM(CASE WHEN state = 'applied' AND was_updated = 1 THEN 1 ELSE 0 END) AS categorized,
                    SUM(CASE WHEN state = 'applied' AND was_updated = 0 THEN 1 ELSE 0 END) AS unchanged,
                    SUM(CASE WHEN state = 'failed' THEN 1 ELSE 0 END) AS failed
                FROM smart_inbox_work_items WHERE job_id = ?
                """,
            arguments: [jobID]
        )
        return PlainpostSmartInboxWorkSummary(
            total: row?["total"] ?? 0,
            processed: row?["processed"] ?? 0,
            categorized: row?["categorized"] ?? 0,
            unchanged: row?["unchanged"] ?? 0,
            failed: row?["failed"] ?? 0
        )
    }

    private func recordSmartInboxReclassificationCompletion(
        database: Database,
        jobID: String,
        status: String,
        errorClass: String?
    ) throws {
        guard let payloadJSON = try String.fetchOne(
            database,
            sql: "SELECT payload_json FROM durable_jobs WHERE id = ?",
            arguments: [jobID]
        ),
        let input = try? JSONDecoder().decode(
            PlainpostAIOperationInput.self,
            from: Data(payloadJSON.utf8)
        ),
        input.operation == .recategorizeInbox,
        input.smartInboxRunMode == .rerunAll else {
            return
        }
        try database.execute(
            sql: """
                UPDATE durable_jobs
                SET smart_inbox_completion_audit_recorded = 1
                WHERE id = ? AND smart_inbox_completion_audit_recorded = 0
                """,
            arguments: [jobID]
        )
        guard database.changesCount == 1 else { return }
        let summary = try smartInboxWorkSummary(database: database, jobID: jobID)
        let classifierIdentity = input.resolvedSmartInboxClassifierIdentity
        let ownership = try Self.requiredJobOwnership(jobID: jobID, database: database)
        try insertAudit(
            database: database,
            actorID: "local-user",
            action: "smart_inbox.reclassification.complete",
            targetType: "smart_inbox_reclassification",
            targetID: jobID,
            result: try canonicalAuditResult(
                SmartInboxReclassificationCompletionAuditResult(
                    errorClass: errorClass.map(safeAuditErrorClass),
                    failed: summary.failed,
                    jobID: jobID,
                    modelID: classifierIdentity.modelID,
                    providerID: classifierIdentity.providerID,
                    requestedLabelID: input.smartInboxRunRequest.requestedLabelID,
                    scope: auditScope(input.smartInboxRunRequest.scope),
                    status: status,
                    unchanged: summary.unchanged,
                    updated: summary.categorized
                )
            ),
            ownership: ownership
        )
    }

    private func safeAuditErrorClass(_ value: String) -> String {
        switch value {
        case "cancelled", "CANCELLED", "JOB_CANCELLED":
            return "cancelled"
        case "SMART_INBOX_ALL_FAILED", "ALL_FAILED":
            return "all-failed"
        case "AI_PROVIDER_UNAVAILABLE", "PROVIDER_UNAVAILABLE", "AI_UNAVAILABLE":
            return "provider-unavailable"
        case "OPERATION_FAILED":
            return "operation-failed"
        case "VALIDATION_FAILED":
            return "validation-failed"
        case "DATABASE_BUSY":
            return "database-busy"
        default:
            return "unknown"
        }
    }

    private func updateLeasedJob(
        id: String,
        leaseToken: String,
        sql: String,
        values: StatementArguments,
        afterUpdate: ((Database) throws -> Void)? = nil
    ) throws {
        try databasePool.write { database in
            try database.execute(sql: sql, arguments: values)
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed("Local operation lease is no longer valid.")
            }
            try afterUpdate?(database)
        }
    }

    /// Marks each running approved delivery whose lease expired as
    /// delivery-uncertain, and its send request with it. The sender may have
    /// crossed the SMTP acceptance boundary before it stopped, so the job is
    /// neither retried nor cancelled; it waits for review. Both recovery
    /// paths share this so neither can strand a delivery.
    private func markExpiredApprovedDeliveriesUncertain(
        database: Database, now: Date, selectedAccountID: AccountID? = nil
    ) throws {
        // Bind timestamps as REAL: `COALESCE(...)` has no column affinity,
        // and a TEXT argument would make every lease look expired.
        let expiredIDs = try String.fetchAll(
            database,
            sql: """
                SELECT id FROM durable_jobs
                WHERE kind = 'approved-delivery' AND state = 'running'
                  AND pause_requested = 0
                  AND COALESCE(lease_expires_at, 0) < ?
                  \(selectedAccountID == nil ? "" : "AND ownership_kind = 'account' AND owner_account_id = ?")
                ORDER BY id
                """,
            arguments: selectedAccountID.map { [now.timeIntervalSince1970, $0.rawValue] }
                ?? [now.timeIntervalSince1970]
        )
        for jobID in expiredIDs {
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'delivery-uncertain', error_code = 'DELIVERY_UNCERTAIN',
                        error_message = ?, lease_token = NULL, lease_expires_at = NULL,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    "Delivery may have crossed the SMTP acceptance boundary before restart. Review before any new send.",
                    now.timeIntervalSince1970,
                    jobID,
                ]
            )
            try reconcileApprovedDeliveryTerminalOutcome(
                database: database,
                jobID: jobID,
                terminalStatus: .deliveryUncertain,
                updatedAt: now
            )
        }
    }

    /// Makes an approved-delivery terminal result durable at the same time as
    /// the job state. Retried or paused work deliberately stays approved.
    private func reconcileApprovedDeliveryTerminalOutcome(
        database: Database,
        jobID: String,
        terminalStatus: SendRequestStatus,
        updatedAt: Date
    ) throws {
        guard [.failed, .cancelled, .deliveryUncertain].contains(terminalStatus),
              let row = try Row.fetchOne(
                  database,
                  sql: "SELECT kind, payload_json FROM durable_jobs WHERE id = ?",
                  arguments: [jobID]
              ),
              PlainpostOperationKind(rawValue: row["kind"] as String) == .approvedDelivery,
              let input = try? JSONDecoder().decode(
                  PlainpostApprovalDecisionInput.self,
                  from: Data((row["payload_json"] as String).utf8)
              ),
              let request = try sendRequest(id: input.requestID, database: database),
              [.approved, .sending].contains(request.status)
        else {
            return
        }

        let updated = request.updating(status: terminalStatus)
        try database.execute(
            sql: "UPDATE send_requests SET payload_json = ? WHERE id = ?",
            arguments: [try encodeJSON(updated), request.id.rawValue]
        )
        try insertAudit(
            database: database,
            actorID: input.actorID,
            action: "send.\(terminalStatus.rawValue)",
            targetType: "send_request",
            targetID: request.id.rawValue
        )

    }

    private func hasActiveBlockingSync(
        database: Database, selectedAccountID: AccountID? = nil
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM durable_jobs
                    WHERE kind IN ('inbox-sync', 'historical-sync')
                      AND state IN ('queued', 'running')
                      \(selectedAccountID == nil ? "" : "AND ownership_kind = 'account' AND owner_account_id = ?")
                )
                """,
            arguments: selectedAccountID.map { [$0.rawValue] } ?? []
        ) ?? false
    }

    /// The active-sync query keeps raw values for SQLite's static IN binding;
    /// every non-query sync-kind check shares this enum boundary instead.
    private func isSyncJob(database: Database, id: String) throws -> Bool {
        guard let rawKind = try String.fetchOne(
            database,
            sql: "SELECT kind FROM durable_jobs WHERE id = ?",
            arguments: [id]
        ), let kind = PlainpostOperationKind(rawValue: rawKind) else {
            return false
        }
        return kind == .inboxSync || kind == .historicalSync
    }

    private func resumeSystemPausedSmartInboxWhenSyncInactive(
        database: Database,
        now: Date
    ) throws {
        guard try !hasActiveBlockingSync(database: database) else { return }
        let candidates = try Row.fetchAll(
            database,
            sql: """
                SELECT id, payload_json FROM durable_jobs
                WHERE state = 'paused'
                  AND pause_reason IN ('mail-sync', 'mail-sync-failed')
                  AND kind = 'ai-operation'
                """
        )
        for candidate in candidates {
            let id: String = candidate["id"]
            let payloadJSON: String = candidate["payload_json"]
            guard let input = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data(payloadJSON.utf8)
            ), input.operation == .recategorizeInbox else {
                continue
            }
            try database.execute(
                sql: """
                    UPDATE durable_jobs
                    SET state = 'queued', pause_reason = NULL,
                        attempt = MAX(0, attempt - 1), available_at = ?, updated_at = ?
                    WHERE id = ? AND state = 'paused'
                      AND pause_reason IN ('mail-sync', 'mail-sync-failed')
                """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id]
            )
        }
    }

    private func userPausableSmartInboxJob(
        database: Database,
        id: String,
        selectedAccountID: AccountID? = nil,
        selectedSourceGeneration: Int64? = nil
    ) throws -> PlainpostDurableJob {
        if let selectedAccountID, let selectedSourceGeneration {
            try Self.requireDirectSource(
                accountID: selectedAccountID,
                generation: selectedSourceGeneration,
                database: database
            )
        } else if selectedAccountID != nil || selectedSourceGeneration != nil {
            throw PlainpostError.validationFailed("A selected Smart Inbox account needs its source generation.")
        }
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM durable_jobs WHERE id = ?",
            arguments: [id]
        ) else {
            throw PlainpostError.notFound("Local operation not found.")
        }
        guard PlainpostOperationKind(rawValue: row["kind"] as String) == .aiOperation,
              let payloadJSON: String = row["payload_json"],
              let input = try? JSONDecoder().decode(
                PlainpostAIOperationInput.self,
                from: Data(payloadJSON.utf8)
              ),
              input.operation == .recategorizeInbox else {
            throw PlainpostError.validationFailed("Only Smart Inbox operations can be paused by the user.")
        }
        if let selectedAccountID {
            let owner: String? = row["owner_account_id"]
            let ownershipKind: String = row["ownership_kind"]
            guard ownershipKind == "account", owner == selectedAccountID.rawValue,
                  input.smartInboxRunRequest.scope == .account(selectedAccountID),
                  input.accountID == selectedAccountID,
                  input.expectedDirectSourceGeneration == selectedSourceGeneration else {
                throw PlainpostError.permissionDenied(
                    "This Smart Inbox operation belongs to another account or source."
                )
            }
        }
        return try decodeJob(row)
    }

    private func updateSyncReadiness(
        database: Database,
        syncJobID: String,
        state: String,
        updatedAt: Date
    ) throws {
        try database.execute(
            sql: """
                UPDATE account_sync_readiness
                SET state = ?, updated_at = ?
                WHERE sync_job_id = ?
                """,
            arguments: [state, updatedAt.timeIntervalSince1970, syncJobID]
        )
    }

    private func completeSyncReadiness(
        database: Database,
        syncJobID: String,
        updatedAt: Date
    ) throws {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT kind, payload_json, created_at FROM durable_jobs WHERE id = ?",
            arguments: [syncJobID]
        ),
        let kind = PlainpostOperationKind(rawValue: row["kind"] as String),
        kind == .inboxSync || kind == .historicalSync,
        let input = try? JSONDecoder().decode(
            PlainpostInboxSyncInput.self,
            from: Data((row["payload_json"] as String).utf8)
        ) else {
            return
        }
        let createdAt: Double = row["created_at"]
        let scopeRow = try Row.fetchOne(
            database,
            sql: """
                SELECT scope_fingerprint, establishes_readiness
                FROM sync_job_scopes WHERE job_id = ?
                """,
            arguments: [syncJobID]
        )
        let scopeFingerprint: String? = (scopeRow?["establishes_readiness"] as Bool? == true)
            ? scopeRow?["scope_fingerprint"]
            : nil
        try database.execute(
            sql: """
                INSERT INTO account_sync_readiness (
                    account_id, state, sync_job_id, scope_fingerprint, updated_at
                ) VALUES (?, 'ready', ?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    state = 'ready', sync_job_id = excluded.sync_job_id,
                    scope_fingerprint = excluded.scope_fingerprint, updated_at = excluded.updated_at
                WHERE account_sync_readiness.sync_job_id = excluded.sync_job_id
                   OR COALESCE(
                        (SELECT created_at FROM durable_jobs
                         WHERE id = account_sync_readiness.sync_job_id),
                        account_sync_readiness.updated_at
                   ) < ?
                """,
            arguments: [
                input.accountID.rawValue,
                syncJobID,
                scopeFingerprint,
                updatedAt.timeIntervalSince1970,
                createdAt,
            ]
        )
        try resumeSystemPausedSmartInboxWhenSyncInactive(database: database, now: updatedAt)
    }

    private func decodeJob(_ row: Row) throws -> PlainpostDurableJob {
        guard let kind = PlainpostOperationKind(rawValue: row["kind"]),
              let state = PlainpostOperationState(rawValue: row["state"]) else {
            throw PlainpostError.validationFailed("Local operation record is invalid.")
        }
        let progressPhase: String? = row["progress_phase"]
        let progress: PlainpostOperationProgress? = progressPhase.map { phase in
            PlainpostOperationProgress(
                current: row["progress_current"] ?? 0,
                total: row["progress_total"],
                phase: phase,
                label: row["progress_label"]
            )
        }
        let leaseExpiry: Double? = row["lease_expires_at"]
        return PlainpostDurableJob(
            id: row["id"],
            kind: kind,
            payloadJSON: row["payload_json"],
            state: state,
            priority: row["priority"],
            availableAt: Date(timeIntervalSince1970: row["available_at"]),
            attempt: row["attempt"],
            maxAttempts: row["max_attempts"],
            leaseToken: row["lease_token"],
            leaseExpiresAt: leaseExpiry.map(Date.init(timeIntervalSince1970:)),
            cancellationRequested: row["cancellation_requested"],
            pauseRequested: row["pause_requested"],
            idempotencyKey: row["idempotency_key"],
            pauseReason: row["pause_reason"],
            progress: progress,
            resultArtifactID: row["result_artifact_id"],
            errorCode: row["error_code"],
            errorMessage: row["error_message"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    // MARK: - Durable mail-rule actions

    public func enqueueMailRuleActions(
        messageID: MessageID,
        accountID: AccountID,
        actions: Set<MailRuleAction>,
        sourceRuleIDs: [String],
        expectedDirectSourceGeneration: Int64? = nil
    ) throws -> [MailRuleMessageActionRecord] {
        guard !actions.isEmpty else { return [] }
        let now = Date()
        let sourceRuleIDsJSON = labelsJSON(Array(Set(sourceRuleIDs)).sorted())
        let records = try databasePool.write { database in
            if let expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: accountID, generation: expectedDirectSourceGeneration,
                    database: database
                )
            }
            var records: [MailRuleMessageActionRecord] = []
            for action in actions.sorted(by: { $0.rawValue < $1.rawValue }) {
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO mail_rule_message_actions (
                            message_id, account_id, action, source_rule_ids_json, created_at
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        messageID.rawValue,
                        accountID.rawValue,
                        action.rawValue,
                        sourceRuleIDsJSON,
                        now.timeIntervalSince1970,
                    ]
                )
                guard database.changesCount == 1 else { continue }

                var durableJobIDs: [String] = []
                switch action {
                case .markAsRead:
                    try database.execute(
                        sql: "UPDATE messages SET is_seen = 1 WHERE id = ? AND is_deleted = 0",
                        arguments: [messageID.rawValue]
                    )
                    guard database.changesCount == 1 else {
                        throw PlainpostError.notFound("Message not found.")
                    }
                    try database.execute(
                        sql: """
                            INSERT INTO message_seen_intents (message_id, desired_seen, updated_at)
                            VALUES (?, 1, ?)
                            ON CONFLICT(message_id) DO UPDATE SET
                                desired_seen = 1,
                                updated_at = excluded.updated_at
                            """,
                        arguments: [messageID.rawValue, now.timeIntervalSince1970]
                    )
                    let membership = try Self.canonicalMailboxFlagMembership(
                        messageID: messageID,
                        accountID: accountID,
                        database: database
                    )
                    let input = PlainpostMailboxFlagInput(
                        messageID: messageID,
                        accountID: accountID,
                        mailboxPath: membership.mailboxPath,
                        uidValidity: membership.uidValidity,
                        uid: membership.uid,
                        desiredSeen: true,
                        expectedDirectSourceGeneration: expectedDirectSourceGeneration
                    )
                    let job = try enqueueJob(
                        PlainpostJobRequest(
                            kind: .mailboxFlag,
                            payloadJSON: String(
                                decoding: try JSONEncoder().encode(input),
                                as: UTF8.self
                            ),
                            priority: 100,
                            idempotencyKey: Self.mailboxFlagIdempotencyKey(input),
                            replaceTerminalDuplicate: true
                        ),
                        database: database,
                        now: now
                    )
                    durableJobIDs.append(job.id)
                case .skipInbox:
                    let input = try mailboxArchiveInput(
                        messageID: messageID,
                        accountID: accountID,
                        database: database,
                        expectedDirectSourceGeneration: expectedDirectSourceGeneration
                    )
                    let job = try enqueueMailboxArchive(input, database: database, now: now)
                    durableJobIDs.append(job.id)
                case .suppressNotification:
                    break
                }
                records.append(.init(
                    messageID: messageID,
                    action: action,
                    durableJobIDs: durableJobIDs
                ))
            }
            return records
        }
        if !records.isEmpty {
            MailStoreChangeSignal.post(scope: .mailbox)
        }
        return records
    }

    public func hasMailRuleAction(
        _ action: MailRuleAction,
        messageID: MessageID
    ) throws -> Bool {
        try databasePool.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM mail_rule_message_actions
                        WHERE message_id = ? AND action = ?
                    )
                    """,
                arguments: [messageID.rawValue, action.rawValue]
            ) ?? false
        }
    }

    public func recordMailRuleEvaluationFailure(messageID: MessageID, error: Error) throws {
        _ = error
        try recordMailRuleDiagnostic(
            action: "mail_rule.evaluate_failed",
            targetID: messageID.rawValue
        )
    }

    public func mailRuleCandidateMessages(accountID: AccountID?) throws -> [MailRuleCandidateMessage] {
        let accountExpression = """
            COALESCE(
                (SELECT mm.account_id FROM mailbox_messages mm
                 WHERE mm.message_id = m.id
                 ORDER BY CASE WHEN mm.mailbox_path = 'INBOX' COLLATE NOCASE THEN 0 ELSE 1 END,
                     mm.mailbox_path, mm.uid
                 LIMIT 1),
                m.account_id
            )
            """
        let accountClause = accountID == nil ? "" : "AND \(accountExpression) = ?"
        let rows = try fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name, m.subject, m.preview,
                m.body_text, m.body_html, m.smart_category, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.rfc_message_id, m.in_reply_to,
                m.references_json, m.reply_to_email, m.to_emails, m.cc_emails,
                \(accountExpression) AS rule_account_id
            FROM messages m
            WHERE m.is_deleted = 0
              AND \(accountExpression) IS NOT NULL
              \(accountClause)
            ORDER BY COALESCE(m.sent_at, 0), m.id
            """,
            accountID.map { [$0.rawValue] } ?? []
        )
        return rows.compactMap { row in
            guard let rawAccountID: String = row["rule_account_id"] else { return nil }
            return MailRuleCandidateMessage(
                message: decodeMessage(row),
                accountID: AccountID(rawAccountID)
            )
        }
    }

    public func hasInboxMembership(messageID: MessageID, accountID: AccountID) throws -> Bool {
        try databasePool.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM mailbox_messages mm
                        LEFT JOIN mailboxes mb
                          ON mb.account_id = mm.account_id AND mb.path = mm.mailbox_path
                        WHERE mm.message_id = ? AND mm.account_id = ?
                          AND (
                            mm.mailbox_path = 'INBOX' COLLATE NOCASE
                            OR mb.special_use = ? COLLATE NOCASE
                          )
                    )
                    """,
                arguments: [messageID.rawValue, accountID.rawValue, "\\Inbox"]
            ) ?? false
        }
    }

    public func createMailRuleRun(
        ruleID: String,
        matches: [MailRuleExistingMatch]
    ) throws -> String {
        let runID = "rule_run_\(UUID().uuidString.lowercased())"
        try databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [runID, ruleID, Date().timeIntervalSince1970, matches.count]
            )
            for (ordinal, match) in matches.enumerated() {
                let actions = match.actions.map(\.rawValue).sorted()
                try database.execute(
                    sql: """
                        INSERT INTO mail_rule_run_items (
                            run_id, ordinal, message_id, account_id, actions_json, state,
                            owner_account_id, ownership_kind
                        ) VALUES (?, ?, ?, ?, ?, 'pending', ?, 'account')
                        """,
                    arguments: [
                        runID,
                        ordinal,
                        match.messageID.rawValue,
                        match.accountID.rawValue,
                        labelsJSON(actions),
                        match.accountID.rawValue,
                    ]
                )
            }
        }
        return runID
    }

    public func updateMailRuleRunItem(
        runID: String,
        messageID: MessageID,
        jobIDs: [String],
        error: Error?
    ) throws {
        try databasePool.write { database in
            let state: String
            if error != nil {
                state = "failed"
            } else if jobIDs.isEmpty {
                state = "completed"
            } else {
                state = "enqueued"
            }
            try database.execute(
                sql: """
                    UPDATE mail_rule_run_items
                    SET job_ids_json = ?, state = ?, error_message = ?
                    WHERE run_id = ? AND message_id = ? AND state = 'pending'
                    """,
                arguments: [
                    labelsJSON(jobIDs),
                    state,
                    error.map { String(describing: $0) },
                    runID,
                    messageID.rawValue,
                ]
            )
            guard error == nil, database.changesCount == 1 else { return }
            try database.execute(
                sql: "UPDATE mail_rule_runs SET enqueued_items = enqueued_items + 1 WHERE id = ?",
                arguments: [runID]
            )
        }
    }

    public func mailRuleRun(id: String) throws -> MailRuleRun {
        guard let run = try fetchRows(
            "SELECT rule_id, total_items, enqueued_items FROM mail_rule_runs WHERE id = ?",
            [id]
        ).first else {
            throw PlainpostError.notFound("Mail rule run not found.")
        }
        let items = try fetchRows(
            """
            SELECT message_id, job_ids_json, state
            FROM mail_rule_run_items WHERE run_id = ? ORDER BY ordinal
            """,
            [id]
        )
        var completed = 0
        var failed = 0
        for item in items {
            let state: String = item["state"]
            if state == "failed" {
                failed += 1
                continue
            }
            if state == "completed" {
                completed += 1
                continue
            }
            let jobIDs = try decodeJSON([String].self, from: item["job_ids_json"])
            let jobs = try jobIDs.map { try job(id: $0) }
            if jobs.contains(where: { [.failed, .cancelled, .deliveryUncertain].contains($0.state) }) {
                failed += 1
            } else if !jobs.isEmpty && jobs.allSatisfy({ $0.state == .completed }) {
                completed += 1
            }
        }
        return MailRuleRun(
            id: id,
            ruleID: run["rule_id"],
            messageIDs: items.map { MessageID($0["message_id"] as String) },
            totalItemCount: run["total_items"],
            enqueuedItemCount: run["enqueued_items"],
            completedItemCount: completed,
            failedItemCount: failed
        )
    }

    public func enqueueMailboxArchive(
        _ input: PlainpostMailboxArchiveInput
    ) throws -> PlainpostDurableJob {
        let now = Date()
        return try databasePool.write { database in
            try enqueueMailboxArchive(input, database: database, now: now)
        }
    }

    public func completeMailboxArchive(_ input: PlainpostMailboxArchiveInput) throws {
        try databasePool.write { database in
            if let generation = input.expectedDirectSourceGeneration {
                try Self.requireDirectSource(
                    accountID: input.accountID, generation: generation, allowNodeFallback: true, database: database
                )
            }
            try database.execute(
                sql: """
                    DELETE FROM mailbox_messages
                    WHERE message_id = ? AND account_id = ?
                      AND mailbox_path = ? COLLATE NOCASE
                      AND uid_validity = ? AND uid = ?
                    """,
                arguments: [
                    input.messageID.rawValue,
                    input.accountID.rawValue,
                    input.sourceMailboxPath,
                    input.uidValidity,
                    input.uid,
                ]
            )
            try database.execute(
                sql: "UPDATE messages SET mailbox_path = ? WHERE id = ?",
                arguments: [input.destinationMailboxPath, input.messageID.rawValue]
            )
        }
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    private func enqueueMailboxArchive(
        _ input: PlainpostMailboxArchiveInput,
        database: Database,
        now: Date
    ) throws -> PlainpostDurableJob {
        if let generation = input.expectedDirectSourceGeneration {
            try Self.requireDirectSource(
                accountID: input.accountID, generation: generation, allowNodeFallback: true, database: database
            )
        }
        return try enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxArchive,
                payloadJSON: String(
                    decoding: try JSONEncoder().encode(input),
                    as: UTF8.self
                ),
                priority: 100,
                idempotencyKey: "mailbox-archive:\(input.messageID.rawValue):\(input.sourceMailboxPath):\(input.destinationMailboxPath)\(input.expectedDirectSourceGeneration.map { ":direct-generation:\($0)" } ?? "")"
            ),
            database: database,
            now: now
        )
    }

    private func mailboxArchiveInput(
        messageID: MessageID,
        accountID: AccountID,
        database: Database,
        expectedDirectSourceGeneration: Int64? = nil
    ) throws -> PlainpostMailboxArchiveInput {
        guard let membership = try Row.fetchOne(
            database,
            sql: """
                SELECT mm.mailbox_path, mm.uid_validity, mm.uid
                FROM mailbox_messages mm
                LEFT JOIN mailboxes mb
                  ON mb.account_id = mm.account_id AND mb.path = mm.mailbox_path
                WHERE mm.message_id = ? AND mm.account_id = ?
                  AND (
                    mm.mailbox_path = 'INBOX' COLLATE NOCASE
                    OR mb.special_use = ? COLLATE NOCASE
                  )
                ORDER BY CASE WHEN mb.special_use = ? COLLATE NOCASE THEN 0 ELSE 1 END,
                    mm.mailbox_path, mm.uid
                LIMIT 1
                """,
            arguments: [messageID.rawValue, accountID.rawValue, "\\Inbox", "\\Inbox"]
        ) else {
            throw PlainpostError.notFound("Inbox mailbox membership was not found.")
        }
        // The account's own Archive (Gmail: All Mail). Without one the job
        // names the default, and resolves (or refuses) against the server's list.
        let accountMailboxes = try Row.fetchAll(
            database,
            sql: "SELECT id, account_id, name, path, special_use FROM mailboxes WHERE account_id = ? ORDER BY path",
            arguments: [accountID.rawValue]
        ).map { row in
            Mailbox(
                id: MailboxID(row["id"]), accountID: AccountID(row["account_id"]),
                name: row["name"], path: row["path"], specialUse: row["special_use"]
            )
        }
        let destinationPath = ArchiveMailbox.path(in: accountMailboxes) ?? ArchiveMailbox.defaultName
        return PlainpostMailboxArchiveInput(
            messageID: messageID,
            accountID: accountID,
            sourceMailboxPath: membership["mailbox_path"],
            destinationMailboxPath: destinationPath,
            uidValidity: membership["uid_validity"],
            uid: membership["uid"],
            expectedDirectSourceGeneration: expectedDirectSourceGeneration
        )
    }

    // MARK: - Mail labels

    public func mailLabels(effectiveFor accountID: AccountID?) throws -> [MailLabelDefinition] {
        let rows: [Row]
        if let accountID {
            rows = try fetchRows(
                """
                SELECT id, title, normalized_title, description, smart_inbox_enabled,
                    scope_account_id, created_at, updated_at
                FROM mail_labels
                WHERE scope_account_id IS NULL OR scope_account_id = ?
                ORDER BY CASE WHEN scope_account_id IS NULL THEN 0 ELSE 1 END,
                    title COLLATE NOCASE, id
                """,
                [accountID.rawValue]
            )
        } else {
            rows = try fetchRows(
                """
                SELECT id, title, normalized_title, description, smart_inbox_enabled,
                    scope_account_id, created_at, updated_at
                FROM mail_labels
                ORDER BY CASE WHEN scope_account_id IS NULL THEN 0 ELSE 1 END,
                    title COLLATE NOCASE, id
                """
            )
        }
        return rows.map(decodeMailLabel)
    }

    public func mailLabel(id: String) throws -> MailLabelDefinition? {
        try fetchRows(
            """
            SELECT id, title, normalized_title, description, smart_inbox_enabled,
                scope_account_id, created_at, updated_at
            FROM mail_labels
            WHERE id = ?
            LIMIT 1
            """,
            [id]
        ).first.map(decodeMailLabel)
    }

    public func saveMailLabel(_ label: MailLabelDefinition) throws {
        let validated = try MailLabelDefinition.validated(
            id: label.id,
            title: label.title,
            description: label.description,
            isSmartInboxEnabled: label.isSmartInboxEnabled,
            scope: label.scope,
            createdAt: label.createdAt,
            updatedAt: label.updatedAt
        )
        do {
            try databasePool.write { database in
                let existing = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, title, normalized_title, description, smart_inbox_enabled,
                            scope_account_id, created_at, updated_at
                        FROM mail_labels
                        WHERE id = ?
                        """,
                    arguments: [validated.id]
                )
                let previous = existing.map(decodeMailLabel)
                if let previous {
                    let storedAccountID = previous.scope.accountID?.rawValue
                    guard storedAccountID == validated.scope.accountID?.rawValue else {
                        throw MailLabelValidationError.immutableScope
                    }
                }
                try validateEffectiveTitleUniqueness(database: database, label: validated)
                try validateEffectiveSmartInboxLimit(database: database, replacing: validated)
                try database.execute(
                    sql: """
                        INSERT INTO mail_labels (
                            id, title, normalized_title, description, smart_inbox_enabled,
                            scope_account_id, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            title = excluded.title,
                            normalized_title = excluded.normalized_title,
                            description = excluded.description,
                            smart_inbox_enabled = excluded.smart_inbox_enabled,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        validated.id,
                        validated.title,
                        validated.normalizedTitle,
                        validated.description,
                        validated.isSmartInboxEnabled,
                        validated.scope.accountID?.rawValue,
                        validated.createdAt.timeIntervalSince1970,
                        validated.updatedAt.timeIntervalSince1970,
                    ]
                )
                try rebuildEffectiveLabelProjection(database: database, labelID: validated.id)
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: existing == nil ? "mail_label.create" : "mail_label.update",
                    targetType: "mail_label",
                    targetID: validated.id,
                    result: try canonicalAuditResult(
                        MailLabelDefinitionAuditResult(
                            isSmartInboxEnabled: validated.isSmartInboxEnabled,
                            labelID: validated.id,
                            scope: auditScope(validated.scope),
                            title: validated.title
                        )
                    )
                )
                if let previous, previous.title != validated.title {
                    try insertAudit(
                        database: database,
                        actorID: "local-user",
                        action: "mail_label.rename",
                        targetType: "mail_label",
                        targetID: validated.id,
                        result: try canonicalAuditResult(
                            MailLabelRenameAuditResult(
                                labelID: validated.id,
                                newTitle: validated.title,
                                oldTitle: previous.title,
                                scope: auditScope(validated.scope)
                            )
                        )
                    )
                }
                if let previous,
                   previous.isSmartInboxEnabled != validated.isSmartInboxEnabled {
                    try insertAudit(
                        database: database,
                        actorID: "local-user",
                        action: "mail_label.eligibility_change",
                        targetType: "mail_label",
                        targetID: validated.id,
                        result: try canonicalAuditResult(
                            MailLabelEligibilityAuditResult(
                                isSmartInboxEnabled: validated.isSmartInboxEnabled,
                                labelID: validated.id,
                                scope: auditScope(validated.scope)
                            )
                        )
                    )
                }
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
        MailStoreChangeSignal.post(scope: .all)
    }

    public func setMailLabelSmartInboxEnabled(id: String, isEnabled: Bool) throws {
        do {
            try databasePool.write { database in
                guard let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, title, normalized_title, description, smart_inbox_enabled,
                            scope_account_id, created_at, updated_at
                        FROM mail_labels
                        WHERE id = ?
                        LIMIT 1
                        """,
                    arguments: [id]
                ) else {
                    throw MailLabelValidationError.unknownLabel
                }
                let stored = decodeMailLabel(row)
                let updatedAt = Date()
                let validated = try MailLabelDefinition.validated(
                    id: stored.id,
                    title: stored.title,
                    description: stored.description,
                    isSmartInboxEnabled: isEnabled,
                    scope: stored.scope,
                    createdAt: stored.createdAt,
                    updatedAt: updatedAt
                )
                try validateEffectiveSmartInboxLimit(
                    database: database,
                    replacing: validated
                )
                try database.execute(
                    sql: """
                        UPDATE mail_labels
                        SET smart_inbox_enabled = ?, updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [isEnabled, updatedAt.timeIntervalSince1970, id]
                )
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_label.update",
                    targetType: "mail_label",
                    targetID: id,
                    result: try canonicalAuditResult(
                        MailLabelDefinitionAuditResult(
                            isSmartInboxEnabled: isEnabled,
                            labelID: id,
                            scope: auditScope(stored.scope),
                            title: stored.title
                        )
                    )
                )
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_label.eligibility_change",
                    targetType: "mail_label",
                    targetID: id,
                    result: try canonicalAuditResult(
                        MailLabelEligibilityAuditResult(
                            isSmartInboxEnabled: isEnabled,
                            labelID: id,
                            scope: auditScope(stored.scope)
                        )
                    )
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
        MailStoreChangeSignal.post(scope: .all)
    }

    public func previewMailLabelDeletion(id: String) throws -> MailLabelDeletionPreview {
        do {
            return try databasePool.read { database in
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT scope_account_id FROM mail_labels WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MailLabelValidationError.unknownLabel
                }
                let accountID: String? = row["scope_account_id"]
                let affectedMessageCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(DISTINCT message_id)
                        FROM message_label_assignments
                        WHERE label_id = ?
                        """,
                    arguments: [id]
                ) ?? 0
                let affectedRuleCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(DISTINCT rule_id)
                        FROM mail_rule_label_actions
                        WHERE label_id = ?
                        """,
                    arguments: [id]
                ) ?? 0
                return MailLabelDeletionPreview(
                    labelID: id,
                    scope: accountID.map { .account(AccountID($0)) } ?? .allAccounts,
                    affectedMessageCount: affectedMessageCount,
                    affectedRuleCount: affectedRuleCount
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
    }

    public func previewMailLabelReclassification(
        id: String
    ) async throws -> MailLabelReclassificationPreview {
        do {
            return try await databasePool.read { [onSmartInboxReclassificationPreviewCountRead] database in
                onSmartInboxReclassificationPreviewCountRead?()
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT scope_account_id FROM mail_labels WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MailLabelValidationError.unknownLabel
                }
                let accountID: String? = row["scope_account_id"]
                let affectedMessageCount: Int
                if let accountID {
                    let accountExpression = Self.smartInboxMessageAccountExpression(
                        messageAlias: "m"
                    )
                    affectedMessageCount = try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM messages m
                            WHERE m.is_deleted = 0 AND \(accountExpression) = ?
                            """,
                        arguments: [accountID]
                    ) ?? 0
                } else {
                    affectedMessageCount = try Int.fetchOne(
                        database,
                        sql: """
                            SELECT COUNT(*)
                            FROM messages
                            WHERE is_deleted = 0
                            """
                    ) ?? 0
                }
                return MailLabelReclassificationPreview(
                    labelID: id,
                    scope: accountID.map { .account(AccountID($0)) } ?? .allAccounts,
                    affectedMessageCount: affectedMessageCount
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
    }

    public func deleteMailLabel(id: String) throws {
        do {
            try databasePool.write { database in
                guard let labelRow = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT id, title, normalized_title, description, smart_inbox_enabled,
                            scope_account_id, created_at, updated_at
                        FROM mail_labels
                        WHERE id = ?
                        """,
                    arguments: [id]
                ) else {
                    throw MailLabelValidationError.unknownLabel
                }
                let label = decodeMailLabel(labelRow)
                let messageIDs = try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT message_id
                        FROM message_label_assignments
                        WHERE label_id = ?
                        ORDER BY message_id
                        """,
                    arguments: [id]
                )
                let ruleIDs = try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT rule_id
                        FROM mail_rule_label_actions
                        WHERE label_id = ?
                        ORDER BY rule_id
                    """,
                    arguments: [id]
                )
                let userAssignmentCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM message_label_assignments
                        WHERE label_id = ? AND source_kind = 'user'
                        """,
                    arguments: [id]
                ) ?? 0
                let ruleAssignmentCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM message_label_assignments
                        WHERE label_id = ? AND source_kind = 'rule'
                        """,
                    arguments: [id]
                ) ?? 0
                let smartInboxAssignmentCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM message_label_assignments
                        WHERE label_id = ? AND source_kind = 'smartInbox'
                        """,
                    arguments: [id]
                ) ?? 0
                let exclusionCount = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM message_label_exclusions WHERE label_id = ?",
                    arguments: [id]
                ) ?? 0
                let auditResult = try canonicalAuditResult(
                    MailLabelDeletionAuditResult(
                        affectedMessageCount: messageIDs.count,
                        affectedRuleCount: ruleIDs.count,
                        exclusionCount: exclusionCount,
                        labelID: id,
                        ruleAssignmentCount: ruleAssignmentCount,
                        scope: auditScope(label.scope),
                        smartInboxAssignmentCount: smartInboxAssignmentCount,
                        title: label.title,
                        userAssignmentCount: userAssignmentCount
                    )
                )
                let auditOwnership: OwnershipClassification
                switch label.scope {
                case .account(let accountID):
                    auditOwnership = .account(accountID.rawValue)
                case .allAccounts:
                    auditOwnership = .init(kind: .shared, owner: nil)
                }

                try database.execute(
                    sql: "DELETE FROM mail_labels WHERE id = ?",
                    arguments: [id]
                )
                for ruleID in ruleIDs {
                    try database.execute(
                        sql: """
                            UPDATE mail_rules
                            SET is_enabled = 0, updated_at = ?
                            WHERE id = ?
                              AND NOT EXISTS (
                                SELECT 1 FROM mail_rule_actions
                                WHERE mail_rule_actions.rule_id = mail_rules.id
                              )
                              AND NOT EXISTS (
                                SELECT 1 FROM mail_rule_label_actions
                                WHERE mail_rule_label_actions.rule_id = mail_rules.id
                              )
                            """,
                        arguments: [Date().timeIntervalSince1970, ruleID]
                    )
                }
                try rebuildEffectiveLabelProjections(database: database, messageIDs: messageIDs)
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_label.delete",
                    targetType: "mail_label",
                    targetID: id,
                    result: auditResult,
                    ownership: auditOwnership
                )
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_label.assignment_cleanup",
                    targetType: "mail_label",
                    targetID: id,
                    result: auditResult,
                    ownership: auditOwnership
                )
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_label.rule_cleanup",
                    targetType: "mail_label",
                    targetID: id,
                    result: auditResult,
                    ownership: auditOwnership
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
        MailStoreChangeSignal.post(scope: .all)
    }

    public func labelAssignments(for messageID: MessageID) throws -> [MailLabelAssignment] {
        do {
            return try databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message_id, label_id, source_kind, source_id, created_at
                        FROM message_label_assignments
                        WHERE message_id = ?
                        ORDER BY label_id, source_kind, source_id
                        """,
                    arguments: [messageID.rawValue]
                ).map { row in
                    let kind: String = row["source_kind"]
                    let sourceID: String = row["source_id"]
                    let source: MailLabelAssignmentSource
                    switch kind {
                    case "user":
                        source = .user
                    case "smartInbox":
                        source = .smartInbox
                    case "rule":
                        guard !sourceID.isEmpty else {
                            throw PlainpostError.validationFailed(
                                "A rule-owned label assignment must identify its rule."
                            )
                        }
                        source = .rule(ruleID: sourceID)
                    default:
                        throw PlainpostError.validationFailed(
                            "A label assignment has an unknown source."
                        )
                    }
                    return MailLabelAssignment(
                        messageID: MessageID(row["message_id"]),
                        labelID: row["label_id"],
                        source: source,
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
            }
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
    }

    public func labelExclusions(for messageID: MessageID) throws -> [MailLabelExclusion] {
        do {
            return try databasePool.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message_id, label_id, created_at
                        FROM message_label_exclusions
                        WHERE message_id = ?
                        ORDER BY label_id
                        """,
                    arguments: [messageID.rawValue]
                ).map { row in
                    MailLabelExclusion(
                        messageID: MessageID(row["message_id"]),
                        labelID: row["label_id"],
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
            }
        } catch {
            throw databaseError(error)
        }
    }

    public func messageLabelActionSnapshot(
        for messageID: MessageID
    ) async throws -> MessageLabelActionSnapshot {
        do {
            return try await databasePool.read { database in
                guard let accountIDValue = try self.messageAccountID(
                    database: database,
                    messageID: messageID.rawValue
                ) else {
                    return MessageLabelActionSnapshot(
                        accountID: nil,
                        labels: [],
                        assignments: [],
                        exclusions: [],
                        ruleNames: [:]
                    )
                }
                let accountID = AccountID(accountIDValue)
                let labels = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, title, normalized_title, description, smart_inbox_enabled,
                            scope_account_id, created_at, updated_at
                        FROM mail_labels
                        WHERE scope_account_id IS NULL OR scope_account_id = ?
                        ORDER BY title COLLATE NOCASE, id
                        """,
                    arguments: [accountID.rawValue]
                ).map(self.decodeMailLabel)
                let assignments = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message_id, label_id, source_kind, source_id, created_at
                        FROM message_label_assignments
                        WHERE message_id = ?
                        ORDER BY label_id, source_kind, source_id
                        """,
                    arguments: [messageID.rawValue]
                ).map { row in
                    let kind: String = row["source_kind"]
                    let sourceID: String = row["source_id"]
                    let source: MailLabelAssignmentSource
                    switch kind {
                    case "user":
                        source = .user
                    case "smartInbox":
                        source = .smartInbox
                    case "rule":
                        guard !sourceID.isEmpty else {
                            throw PlainpostError.validationFailed(
                                "A rule-owned label assignment must identify its rule."
                            )
                        }
                        source = .rule(ruleID: sourceID)
                    default:
                        throw PlainpostError.validationFailed(
                            "A label assignment has an unknown source."
                        )
                    }
                    return MailLabelAssignment(
                        messageID: MessageID(row["message_id"]),
                        labelID: row["label_id"],
                        source: source,
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
                let exclusions = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message_id, label_id, created_at
                        FROM message_label_exclusions
                        WHERE message_id = ?
                        ORDER BY label_id
                        """,
                    arguments: [messageID.rawValue]
                ).map { row in
                    MailLabelExclusion(
                        messageID: MessageID(row["message_id"]),
                        labelID: row["label_id"],
                        createdAt: Date(timeIntervalSince1970: row["created_at"])
                    )
                }
                let ruleNames = Dictionary(
                    uniqueKeysWithValues: try Row.fetchAll(
                        database,
                        sql: """
                            SELECT DISTINCT assignments.source_id AS rule_id, rules.name AS rule_name
                            FROM message_label_assignments AS assignments
                            LEFT JOIN mail_rules AS rules ON rules.id = assignments.source_id
                            WHERE assignments.message_id = ?
                              AND assignments.source_kind = 'rule'
                            ORDER BY assignments.source_id
                            """,
                        arguments: [messageID.rawValue]
                    ).compactMap { row -> (String, String)? in
                        let ruleID: String = row["rule_id"]
                        let ruleName: String? = row["rule_name"]
                        return ruleName.map { (ruleID, $0) }
                    }
                )
                return MessageLabelActionSnapshot(
                    accountID: accountID,
                    labels: labels,
                    assignments: assignments,
                    exclusions: exclusions,
                    ruleNames: ruleNames
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
    }

    public func addUserLabel(labelID: String, to messageID: MessageID, actor: Actor) throws {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        do {
            try databasePool.write { database in
                _ = try accessibleMailLabel(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let hadExclusion = try labelExclusionExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let assignmentAdded = try addUserLabelOwnership(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "mail_label.user_add",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: assignmentAdded ? [labelID] : [],
                            removedLabelIDs: [],
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
                if hadExclusion {
                    try insertAudit(
                        database: database,
                        actorID: actor.id,
                        action: "mail_label.exclusion_clear",
                        targetType: "message",
                        targetID: messageID.rawValue,
                        result: try canonicalAuditResult(
                            MailLabelExclusionAuditResult(
                                labelID: labelID,
                                source: "user"
                            )
                        )
                    )
                }
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    private static func requireSelectedDirectMessage(
        messageID: MessageID,
        accountID: AccountID,
        generation: Int64,
        database: Database
    ) throws {
        let ownership = try messageRelationOwnership(
            messageID: messageID.rawValue,
            explicitAccountID: accountID,
            database: database
        )
        guard ownership.kind == .account,
              ownership.owner == accountID.rawValue else {
            throw PlainpostError.permissionDenied(
                "The message does not belong to the selected Direct account."
            )
        }
        // Labels never leave this database, so a mirrored Sync Node account's mail takes them too.
        try requireLocalMailSource(
            accountID: accountID, generation: generation, database: database
        )
    }

    public func establishUserLabel(
        labelID: String,
        on messageID: MessageID,
        actor: Actor
    ) throws {
        try establishUserLabel(
            labelID: labelID, on: messageID, actor: actor,
            selectedDirectSource: nil
        )
    }

    public func establishUserLabel(
        labelID: String,
        on messageID: MessageID,
        actor: Actor,
        selectedDirectSource: (AccountID, Int64)?
    ) throws {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        do {
            try databasePool.write { database in
                if let (accountID, generation) = selectedDirectSource {
                    try Self.requireSelectedDirectMessage(
                        messageID: messageID, accountID: accountID,
                        generation: generation, database: database
                    )
                }
                _ = try accessibleMailLabel(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let hadExclusion = try labelExclusionExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let hadSmartInboxOwnership = try labelAssignmentExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue,
                    sourceKind: "smartInbox",
                    sourceID: ""
                )
                try database.execute(
                    sql: """
                        DELETE FROM message_label_assignments
                        WHERE message_id = ?
                          AND label_id = ?
                          AND source_kind = 'smartInbox'
                        """,
                    arguments: [messageID.rawValue, labelID]
                )
                let assignmentAdded = try addUserLabelOwnership(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "mail_label.user_establish",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: assignmentAdded ? [labelID] : [],
                            removedLabelIDs: hadSmartInboxOwnership ? [labelID] : [],
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
                if hadExclusion {
                    try insertAudit(
                        database: database,
                        actorID: actor.id,
                        action: "mail_label.exclusion_clear",
                        targetType: "message",
                        targetID: messageID.rawValue,
                        result: try canonicalAuditResult(
                            MailLabelExclusionAuditResult(
                                labelID: labelID,
                                source: "user"
                            )
                        )
                    )
                }
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch let error as NodeMailModeStoreError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    public func removeUserOrSmartInboxLabel(
        labelID: String,
        from messageID: MessageID,
        actor: Actor
    ) throws {
        try removeUserOrSmartInboxLabel(
            labelID: labelID, from: messageID, actor: actor,
            selectedDirectSource: nil
        )
    }

    public func removeUserOrSmartInboxLabel(
        labelID: String,
        from messageID: MessageID,
        actor: Actor,
        selectedDirectSource: (AccountID, Int64)?
    ) throws {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        do {
            try databasePool.write { database in
                if let (accountID, generation) = selectedDirectSource {
                    try Self.requireSelectedDirectMessage(
                        messageID: messageID, accountID: accountID,
                        generation: generation, database: database
                    )
                }
                _ = try accessibleMailLabel(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                let hadUserOwnership = try labelAssignmentExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue,
                    sourceKind: "user",
                    sourceID: ""
                )
                let hadSmartInboxOwnership = try labelAssignmentExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue,
                    sourceKind: "smartInbox",
                    sourceID: ""
                )
                let hadExclusion = try labelExclusionExists(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                try removeUserOrSmartInboxLabelOwnership(
                    database: database,
                    labelID: labelID,
                    messageID: messageID.rawValue
                )
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "mail_label.user_remove",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: [],
                            removedLabelIDs: hadUserOwnership || hadSmartInboxOwnership
                                ? [labelID]
                                : [],
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
                if hadSmartInboxOwnership, !hadExclusion {
                    try insertAudit(
                        database: database,
                        actorID: actor.id,
                        action: "mail_label.exclusion_create",
                        targetType: "message",
                        targetID: messageID.rawValue,
                        result: try canonicalAuditResult(
                            MailLabelExclusionAuditResult(
                                labelID: labelID,
                                source: "user"
                            )
                        )
                    )
                }
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch let error as NodeMailModeStoreError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    public func replaceRuleLabels(
        ruleID: String,
        labelIDs: [String],
        on messageID: MessageID,
        actor: Actor
    ) throws {
        try replaceRuleLabels(
            ruleID: ruleID, labelIDs: labelIDs, on: messageID,
            actor: actor, selectedDirectSource: nil
        )
    }

    public func replaceRuleLabels(
        ruleID: String,
        labelIDs: [String],
        on messageID: MessageID,
        actor: Actor,
        selectedDirectSource: (AccountID, Int64)?
    ) throws {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        let ruleID = ruleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ruleID.isEmpty else {
            throw PlainpostError.validationFailed("A rule-owned label assignment requires a rule ID.")
        }
        do {
            try databasePool.write { database in
                if let (accountID, generation) = selectedDirectSource {
                    try Self.requireSelectedDirectMessage(
                        messageID: messageID, accountID: accountID,
                        generation: generation, database: database
                    )
                }
                var acceptedLabelIDs = Set<String>()
                for labelID in Set(labelIDs).sorted() {
                    do {
                        _ = try accessibleMailLabel(
                            database: database,
                            labelID: labelID,
                            messageID: messageID.rawValue
                        )
                        acceptedLabelIDs.insert(labelID)
                    } catch MailLabelValidationError.unknownLabel {
                        try? insertAudit(
                            database: database,
                            actorID: actor.id,
                            action: "mail_rule.label_missing",
                            targetType: "mail_label",
                            targetID: labelID,
                            result: try canonicalAuditResult(
                                MailLabelRuleDiagnosticAuditResult(
                                    errorClass: "unknownLabel",
                                    labelID: labelID,
                                    ruleID: ruleID,
                                    source: "rule"
                                )
                            )
                        )
                    }
                }
                let existingLabelIDs = try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id FROM message_label_assignments
                        WHERE message_id = ? AND source_kind = 'rule' AND source_id = ?
                        """,
                    arguments: [messageID.rawValue, ruleID]
                )
                for labelID in existingLabelIDs where !acceptedLabelIDs.contains(labelID) {
                    try database.execute(
                        sql: """
                            DELETE FROM message_label_assignments
                            WHERE message_id = ? AND label_id = ?
                              AND source_kind = 'rule' AND source_id = ?
                            """,
                        arguments: [messageID.rawValue, labelID, ruleID]
                    )
                }
                let now = Date().timeIntervalSince1970
                for labelID in acceptedLabelIDs.sorted() {
                    try database.execute(
                        sql: """
                            INSERT OR IGNORE INTO message_label_assignments (
                                message_id, label_id, source_kind, source_id, created_at
                            ) VALUES (?, ?, 'rule', ?, ?)
                            """,
                        arguments: [messageID.rawValue, labelID, ruleID, now]
                    )
                }
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "mail_label.rule_replace",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: acceptedLabelIDs
                                .subtracting(Set(existingLabelIDs))
                                .sorted(),
                            removedLabelIDs: Set(existingLabelIDs)
                                .subtracting(acceptedLabelIDs)
                                .sorted(),
                            ruleID: ruleID,
                            source: "rule"
                        )
                    )
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch let error as NodeMailModeStoreError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    public func replaceSmartInboxLabels(
        labelIDs: [String],
        on messageID: MessageID,
        actor: Actor
    ) throws {
        guard actor.permissions.addLabels else {
            throw PlainpostError.permissionDenied("Actor is not allowed to modify labels.")
        }
        do {
            try databasePool.write { database in
                let requestedLabelIDs = Set(labelIDs)
                for labelID in requestedLabelIDs {
                    _ = try accessibleMailLabel(
                        database: database,
                        labelID: labelID,
                        messageID: messageID.rawValue
                    )
                }
                let excludedLabelIDs = Set(try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id FROM message_label_exclusions
                        WHERE message_id = ?
                        """,
                    arguments: [messageID.rawValue]
                ))
                let acceptedLabelIDs = requestedLabelIDs.subtracting(excludedLabelIDs)
                let existingLabelIDs = try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id FROM message_label_assignments
                        WHERE message_id = ?
                          AND source_kind = 'smartInbox' AND source_id = ''
                        """,
                    arguments: [messageID.rawValue]
                )
                for labelID in existingLabelIDs where !acceptedLabelIDs.contains(labelID) {
                    try database.execute(
                        sql: """
                            DELETE FROM message_label_assignments
                            WHERE message_id = ? AND label_id = ?
                              AND source_kind = 'smartInbox' AND source_id = ''
                            """,
                        arguments: [messageID.rawValue, labelID]
                    )
                }
                let now = Date().timeIntervalSince1970
                for labelID in acceptedLabelIDs.sorted() {
                    try database.execute(
                        sql: """
                            INSERT OR IGNORE INTO message_label_assignments (
                                message_id, label_id, source_kind, source_id, created_at
                            ) VALUES (?, ?, 'smartInbox', '', ?)
                            """,
                        arguments: [messageID.rawValue, labelID, now]
                    )
                }
                try rebuildEffectiveLabelProjection(
                    database: database,
                    messageID: messageID.rawValue
                )
                try insertAudit(
                    database: database,
                    actorID: actor.id,
                    action: "mail_label.smart_inbox_replace",
                    targetType: "message",
                    targetID: messageID.rawValue,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: acceptedLabelIDs
                                .subtracting(Set(existingLabelIDs))
                                .sorted(),
                            removedLabelIDs: Set(existingLabelIDs)
                                .subtracting(acceptedLabelIDs)
                                .sorted(),
                            ruleID: nil,
                            source: "smartInbox"
                        )
                    )
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
    }

    @discardableResult
    private func addUserLabelOwnership(
        database: Database,
        labelID: String,
        messageID: String
    ) throws -> Bool {
        try database.execute(
            sql: """
                DELETE FROM message_label_exclusions
                WHERE message_id = ? AND label_id = ?
                """,
            arguments: [messageID, labelID]
        )
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO message_label_assignments (
                    message_id, label_id, source_kind, source_id, created_at
                ) VALUES (?, ?, 'user', '', ?)
                """,
            arguments: [messageID, labelID, Date().timeIntervalSince1970]
        )
        return database.changesCount == 1
    }

    private func removeUserOrSmartInboxLabelOwnership(
        database: Database,
        labelID: String,
        messageID: String
    ) throws {
        let smartInboxOwned = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message_label_assignments
                    WHERE message_id = ? AND label_id = ?
                      AND source_kind = 'smartInbox' AND source_id = ''
                )
                """,
            arguments: [messageID, labelID]
        ) ?? false
        try database.execute(
            sql: """
                DELETE FROM message_label_assignments
                WHERE message_id = ? AND label_id = ?
                  AND source_kind IN ('user', 'smartInbox')
                """,
            arguments: [messageID, labelID]
        )
        if smartInboxOwned {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO message_label_exclusions (
                        message_id, label_id, created_at
                    ) VALUES (?, ?, ?)
                    """,
                arguments: [messageID, labelID, Date().timeIntervalSince1970]
            )
        }
    }

    private func labelAssignmentExists(
        database: Database,
        labelID: String,
        messageID: String,
        sourceKind: String,
        sourceID: String
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message_label_assignments
                    WHERE message_id = ? AND label_id = ?
                      AND source_kind = ? AND source_id = ?
                )
                """,
            arguments: [messageID, labelID, sourceKind, sourceID]
        ) ?? false
    }

    private func labelExclusionExists(
        database: Database,
        labelID: String,
        messageID: String
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message_label_exclusions
                    WHERE message_id = ? AND label_id = ?
                )
                """,
            arguments: [messageID, labelID]
        ) ?? false
    }

    private func accessibleMailLabel(
        database: Database,
        labelID: String,
        messageID: String
    ) throws -> Row {
        let accountID = try messageAccountID(database: database, messageID: messageID)
        guard let labelRow = try Row.fetchOne(
            database,
            sql: """
                SELECT id, title, normalized_title, description, smart_inbox_enabled,
                    scope_account_id, created_at, updated_at
                FROM mail_labels
                WHERE id = ?
                """,
            arguments: [labelID]
        ) else {
            throw MailLabelValidationError.unknownLabel
        }
        let scopeAccountID: String? = labelRow["scope_account_id"]
        guard scopeAccountID == nil || scopeAccountID == accountID else {
            throw MailLabelValidationError.outOfScopeLabel
        }
        return labelRow
    }

    private func messageAccountID(database: Database, messageID: String) throws -> String? {
        let accountExpression = Self.smartInboxMessageAccountExpression(messageAlias: "m")
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT \(accountExpression) AS account_id
                FROM messages m
                WHERE m.id = ?
                """,
            arguments: [messageID]
        ) else {
            throw PlainpostError.notFound("Message not found.")
        }
        return row["account_id"]
    }

    private static func smartInboxMessageAccountExpression(messageAlias: String) -> String {
        """
        COALESCE(
            (
                SELECT NULLIF(trim(mm.account_id), '')
                FROM mailbox_messages mm
                WHERE mm.message_id = \(messageAlias).id
                ORDER BY CASE
                    WHEN mm.mailbox_path = 'INBOX' COLLATE NOCASE THEN 0 ELSE 1
                END, mm.mailbox_path, mm.uid
                LIMIT 1
            ),
            NULLIF(trim(\(messageAlias).account_id), ''),
            (
                SELECT NULLIF(trim(t.account_id), '')
                FROM threads t
                WHERE t.id = \(messageAlias).thread_id
                LIMIT 1
            )
        )
        """
    }

    private func resolveOrCreateLegacyMailLabel(
        database: Database,
        validatedTitle: MailLabelDefinition,
        accountID: String?,
        actorID: String
    ) throws -> String {
        if let existingID = try String.fetchOne(
            database,
            sql: """
                SELECT id
                FROM mail_labels
                WHERE normalized_title = ?
                  AND (
                    scope_account_id IS NULL
                    OR scope_account_id = ?
                  )
                ORDER BY CASE WHEN scope_account_id IS NULL THEN 0 ELSE 1 END, id
                LIMIT 1
                """,
            arguments: [validatedTitle.normalizedTitle, accountID]
        ) {
            return existingID
        }

        let normalizedTitleExists = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mail_labels WHERE normalized_title = ?
                )
                """,
            arguments: [validatedTitle.normalizedTitle]
        ) ?? false
        let scopeAccountID: String?
        if normalizedTitleExists {
            guard let accountID else {
                throw MailLabelValidationError.duplicateEffectiveTitle
            }
            scopeAccountID = accountID
        } else {
            scopeAccountID = nil
        }
        let id = UUID().uuidString.lowercased()
        let now = Date().timeIntervalSince1970
        try database.execute(
            sql: """
                INSERT INTO mail_labels (
                    id, title, normalized_title, description, smart_inbox_enabled,
                    scope_account_id, created_at, updated_at
                ) VALUES (?, ?, ?, '', 0, ?, ?, ?)
                """,
            arguments: [
                id, validatedTitle.title, validatedTitle.normalizedTitle,
                scopeAccountID, now, now,
            ]
        )
        try insertAudit(
            database: database,
            actorID: actorID,
            action: "mail_label.create",
            targetType: "mail_label",
            targetID: id,
            result: try canonicalAuditResult(
                MailLabelDefinitionAuditResult(
                    isSmartInboxEnabled: false,
                    labelID: id,
                    scope: scopeAccountID
                        .map { auditScope(MailLabelScope.account(AccountID($0))) }
                        ?? auditScope(MailLabelScope.allAccounts),
                    title: validatedTitle.title
                )
            )
        )
        return id
    }

    private func importUserVisibleLabels(
        _ titles: [String],
        database: Database,
        messageID: String,
        accountID: String?,
        actorID: String
    ) throws {
        guard !titles.isEmpty else { return }
        for rawTitle in titles {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let validatedTitle = try MailLabelDefinition.validated(
                title: title,
                description: "",
                isSmartInboxEnabled: false,
                scope: .allAccounts
            )
            let labelID = try resolveOrCreateLegacyMailLabel(
                database: database,
                validatedTitle: validatedTitle,
                accountID: accountID,
                actorID: actorID
            )
            if try addUserLabelOwnership(
                database: database,
                labelID: labelID,
                messageID: messageID
            ) {
                try insertAudit(
                    database: database,
                    actorID: actorID,
                    action: "label.add",
                    targetType: "message",
                    targetID: messageID,
                    result: try canonicalAuditResult(
                        MailLabelAssignmentAuditResult(
                            addedLabelIDs: [labelID],
                            removedLabelIDs: [],
                            ruleID: nil,
                            source: "user"
                        )
                    )
                )
            }
        }
        try rebuildEffectiveLabelProjection(database: database, messageID: messageID)
    }

    private func decodeMailLabel(_ row: Row) -> MailLabelDefinition {
        let accountID: String? = row["scope_account_id"]
        return MailLabelDefinition(
            id: row["id"],
            title: row["title"],
            description: row["description"],
            isSmartInboxEnabled: row["smart_inbox_enabled"],
            scope: accountID.map { .account(AccountID($0)) } ?? .allAccounts,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    private func validateEffectiveTitleUniqueness(
        database: Database,
        label: MailLabelDefinition
    ) throws {
        let duplicate: Bool
        if let accountID = label.scope.accountID {
            duplicate = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM mail_labels
                        WHERE id <> ?
                          AND normalized_title = ?
                          AND (scope_account_id IS NULL OR scope_account_id = ?)
                    )
                    """,
                arguments: [label.id, label.normalizedTitle, accountID.rawValue]
            ) ?? false
        } else {
            duplicate = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM mail_labels
                        WHERE id <> ? AND normalized_title = ?
                    )
                    """,
                arguments: [label.id, label.normalizedTitle]
            ) ?? false
        }
        guard !duplicate else {
            throw MailLabelValidationError.duplicateEffectiveTitle
        }
    }

    private func validateEffectiveSmartInboxLimit(
        database: Database,
        replacing label: MailLabelDefinition
    ) throws {
        guard label.isSmartInboxEnabled else { return }
        let enabledGlobalCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM mail_labels
                WHERE id <> ? AND smart_inbox_enabled = 1 AND scope_account_id IS NULL
                """,
            arguments: [label.id]
        ) ?? 0

        if let accountID = label.scope.accountID {
            let enabledAccountCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM mail_labels
                    WHERE id <> ? AND smart_inbox_enabled = 1 AND scope_account_id = ?
                    """,
                arguments: [label.id, accountID.rawValue]
            ) ?? 0
            guard enabledGlobalCount + enabledAccountCount + 1 <= 24 else {
                throw MailLabelValidationError.effectiveSmartInboxLimitExceeded(
                    scope: .account(accountID)
                )
            }
            return
        }

        let replacingGlobalCount = enabledGlobalCount + 1
        guard replacingGlobalCount <= 24 else {
            throw MailLabelValidationError.effectiveSmartInboxLimitExceeded(
                scope: .allAccounts
            )
        }
        let accountRows = try Row.fetchAll(
            database,
            sql: """
                SELECT scope_account_id, COUNT(*) AS enabled_count
                FROM mail_labels
                WHERE id <> ? AND smart_inbox_enabled = 1 AND scope_account_id IS NOT NULL
                GROUP BY scope_account_id
                ORDER BY scope_account_id
                """,
            arguments: [label.id]
        )
        for row in accountRows {
            let accountID: String = row["scope_account_id"]
            let enabledCount: Int = row["enabled_count"]
            guard replacingGlobalCount + enabledCount <= 24 else {
                throw MailLabelValidationError.effectiveSmartInboxLimitExceeded(
                    scope: .account(AccountID(accountID))
                )
            }
        }
    }

    private func rebuildEffectiveLabelProjection(database: Database, labelID: String) throws {
        let messageIDs = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT message_id
                FROM message_label_assignments
                WHERE label_id = ?
                ORDER BY message_id
                """,
            arguments: [labelID]
        )
        try rebuildEffectiveLabelProjections(database: database, messageIDs: messageIDs)
    }

    private func rebuildEffectiveLabelProjections(
        database: Database,
        messageIDs: [String]
    ) throws {
        for messageID in messageIDs {
            try rebuildEffectiveLabelProjection(database: database, messageID: messageID)
        }
    }

    private func rebuildEffectiveLabelProjection(
        database: Database,
        messageID: String
    ) throws {
        let titles = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT labels.title
                FROM message_label_assignments assignments
                JOIN mail_labels labels ON labels.id = assignments.label_id
                WHERE assignments.message_id = ?
                ORDER BY labels.normalized_title ASC, labels.id ASC
                """,
            arguments: [messageID]
        )
        try database.execute(
            sql: "UPDATE messages SET labels_json = ? WHERE id = ?",
            arguments: [labelsJSON(titles), messageID]
        )
        try Self.refreshSearchProjectionIfIndexable(
            messageID: MessageID(messageID),
            database: database
        )
    }

    // MARK: - Mail rules

    public func mailRules(effectiveFor accountID: AccountID?) throws -> [MailRule] {
        let rows: [Row]
        if let accountID {
            rows = try fetchRows(
                """
                SELECT id, name, is_enabled, scope_account_id, created_at, updated_at
                FROM mail_rules
                WHERE scope_account_id IS NULL OR scope_account_id = ?
                ORDER BY CASE WHEN scope_account_id IS NULL THEN 0 ELSE 1 END,
                    name COLLATE NOCASE, id
                """,
                [accountID.rawValue]
            )
        } else {
            rows = try fetchRows(
                """
                SELECT id, name, is_enabled, scope_account_id, created_at, updated_at
                FROM mail_rules
                ORDER BY CASE WHEN scope_account_id IS NULL THEN 0 ELSE 1 END,
                    name COLLATE NOCASE, id
                """
            )
        }

        var rules: [MailRule] = []
        for row in rows {
            do {
                rules.append(try decodeMailRule(row))
            } catch {
                try? recordMailRuleDiagnostic(
                    action: "mail_rule.decode_failed",
                    targetID: row["id"] as String
                )
            }
        }
        return rules
    }

    public func mailRule(id: String) throws -> MailRule? {
        guard let row = try fetchRows(
            """
            SELECT id, name, is_enabled, scope_account_id, created_at, updated_at
            FROM mail_rules WHERE id = ? LIMIT 1
            """,
            [id]
        ).first else {
            return nil
        }
        return try decodeMailRule(row)
    }

    public func saveMailRule(_ rule: MailRule) throws {
        let validated = try MailRule.validated(
            id: rule.id,
            name: rule.name,
            isEnabled: rule.isEnabled,
            scope: rule.scope,
            conditions: rule.conditions,
            actions: rule.actions,
            labelIDs: rule.labelIDs,
            createdAt: rule.createdAt,
            updatedAt: rule.updatedAt
        )
        let scopeAccountID: String?
        switch validated.scope {
        case .allAccounts:
            scopeAccountID = nil
        case .account(let accountID):
            scopeAccountID = accountID.rawValue
        }

        do {
            try databasePool.write { database in
                for labelID in validated.labelIDs {
                    guard let row = try Row.fetchOne(
                        database,
                        sql: "SELECT scope_account_id FROM mail_labels WHERE id = ?",
                        arguments: [labelID]
                    ) else {
                        throw MailLabelValidationError.unknownLabel
                    }
                    let labelAccountID: String? = row["scope_account_id"]
                    switch validated.scope {
                    case .allAccounts:
                        guard labelAccountID == nil else {
                            throw MailLabelValidationError.outOfScopeLabel
                        }
                    case .account(let accountID):
                        guard labelAccountID == nil || labelAccountID == accountID.rawValue else {
                            throw MailLabelValidationError.outOfScopeLabel
                        }
                    }
                }
                let previousLabelIDs = Set(try String.fetchAll(
                    database,
                    sql: """
                        SELECT label_id
                        FROM mail_rule_label_actions
                        WHERE rule_id = ?
                        """,
                    arguments: [validated.id]
                ))
                try database.execute(
                    sql: """
                        INSERT INTO mail_rules (
                            id, name, is_enabled, scope_account_id, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            is_enabled = excluded.is_enabled,
                            scope_account_id = excluded.scope_account_id,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        validated.id,
                        validated.name,
                        validated.isEnabled ? 1 : 0,
                        scopeAccountID,
                        validated.createdAt.timeIntervalSince1970,
                        validated.updatedAt.timeIntervalSince1970
                    ]
                )
                try database.execute(
                    sql: "DELETE FROM mail_rule_conditions WHERE rule_id = ?",
                    arguments: [validated.id]
                )
                try database.execute(
                    sql: "DELETE FROM mail_rule_actions WHERE rule_id = ?",
                    arguments: [validated.id]
                )
                try database.execute(
                    sql: "DELETE FROM mail_rule_label_actions WHERE rule_id = ?",
                    arguments: [validated.id]
                )
                for (ordinal, condition) in validated.conditions.enumerated() {
                    try database.execute(
                        sql: """
                            INSERT INTO mail_rule_conditions (
                                id, rule_id, ordinal, field, operator, value
                            ) VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            condition.id,
                            validated.id,
                            ordinal,
                            condition.field.rawValue,
                            condition.operator.rawValue,
                            condition.value
                        ]
                    )
                }
                for action in validated.actions.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try database.execute(
                        sql: "INSERT INTO mail_rule_actions (rule_id, action) VALUES (?, ?)",
                        arguments: [validated.id, action.rawValue]
                    )
                }
                for (ordinal, labelID) in validated.labelIDs.enumerated() {
                    try database.execute(
                        sql: """
                            INSERT INTO mail_rule_label_actions (rule_id, label_id, ordinal)
                            VALUES (?, ?, ?)
                            """,
                        arguments: [validated.id, labelID, ordinal]
                    )
                }

                var affectedMessageIDs = Set<String>()
                for labelID in previousLabelIDs.subtracting(validated.labelIDs) {
                    let removedMessageIDs = try String.fetchAll(
                        database,
                        sql: """
                            SELECT message_id
                            FROM message_label_assignments
                            WHERE label_id = ?
                              AND source_kind = 'rule'
                              AND source_id = ?
                            """,
                        arguments: [labelID, validated.id]
                    )
                    affectedMessageIDs.formUnion(removedMessageIDs)
                    try database.execute(
                        sql: """
                            DELETE FROM message_label_assignments
                            WHERE label_id = ?
                              AND source_kind = 'rule'
                              AND source_id = ?
                            """,
                        arguments: [labelID, validated.id]
                    )
                    for messageID in removedMessageIDs {
                        try insertMailRuleLabelAssignmentRemovalAudit(
                            database: database,
                            actorID: "local-user",
                            ruleID: validated.id,
                            labelID: labelID,
                            messageID: messageID
                        )
                    }
                }
                try rebuildEffectiveLabelProjections(
                    database: database,
                    messageIDs: affectedMessageIDs.sorted()
                )
            }
        } catch let error as MailLabelValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .all)
    }

    public func setMailRuleEnabled(id: String, isEnabled: Bool) throws {
        do {
            try databasePool.write { database in
                if isEnabled {
                    let actionCount = try Int.fetchOne(
                        database,
                        sql: """
                            SELECT (
                                SELECT COUNT(*) FROM mail_rule_actions WHERE rule_id = ?
                            ) + (
                                SELECT COUNT(*) FROM mail_rule_label_actions WHERE rule_id = ?
                            )
                            """,
                        arguments: [id, id]
                    ) ?? 0
                    guard actionCount > 0 else {
                        throw MailRuleValidationError.missingActions
                    }
                }
                try database.execute(
                    sql: """
                        UPDATE mail_rules
                        SET is_enabled = ?, updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [isEnabled, Date().timeIntervalSince1970, id]
                )
            }
        } catch let error as MailRuleValidationError {
            throw error
        } catch {
            throw databaseError(error)
        }
        MailStoreChangeSignal.post(scope: .all)
    }

    public func deleteMailRule(id: String) throws {
        do {
            try databasePool.write { database in
                guard let ruleRow = try Row.fetchOne(
                    database,
                    sql: "SELECT scope_account_id FROM mail_rules WHERE id = ?",
                    arguments: [id]
                ) else {
                    return
                }
                let scopeAccountID: String? = ruleRow["scope_account_id"]
                let auditOwnership = scopeAccountID.map(OwnershipClassification.account)
                    ?? .init(kind: .shared, owner: nil)
                let assignmentRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT message_id, label_id
                        FROM message_label_assignments
                        WHERE source_kind = 'rule' AND source_id = ?
                        ORDER BY message_id, label_id
                        """,
                    arguments: [id]
                )
                let messageIDs = Set(assignmentRows.map {
                    $0["message_id"] as String
                }).sorted()
                try database.execute(
                    sql: """
                        DELETE FROM message_label_assignments
                        WHERE source_kind = 'rule' AND source_id = ?
                        """,
                    arguments: [id]
                )
                for row in assignmentRows {
                    try insertMailRuleLabelAssignmentRemovalAudit(
                        database: database,
                        actorID: "local-user",
                        ruleID: id,
                        labelID: row["label_id"],
                        messageID: row["message_id"]
                    )
                }
                try rebuildEffectiveLabelProjections(
                    database: database,
                    messageIDs: messageIDs
                )
                try database.execute(
                    sql: "DELETE FROM mail_rules WHERE id = ?",
                    arguments: [id]
                )
                try insertAudit(
                    database: database,
                    actorID: "local-user",
                    action: "mail_rule.delete",
                    targetType: "mail_rule",
                    targetID: id,
                    ownership: auditOwnership
                )
            }
        } catch {
            throw databaseError(error)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .all)
    }

    private func decodeMailRule(_ row: Row) throws -> MailRule {
        let id: String = row["id"]
        let conditionRows = try fetchRows(
            """
            SELECT id, field, operator, value
            FROM mail_rule_conditions
            WHERE rule_id = ?
            ORDER BY ordinal
            """,
            [id]
        )
        let actionRows = try fetchRows(
            "SELECT action FROM mail_rule_actions WHERE rule_id = ? ORDER BY action",
            [id]
        )
        let labelIDs = try fetchRows(
            """
            SELECT label_id
            FROM mail_rule_label_actions
            WHERE rule_id = ?
            ORDER BY ordinal, label_id
            """,
            [id]
        ).map { $0["label_id"] as String }
        let conditions = try conditionRows.map { conditionRow in
            guard let field = MailRuleConditionField(rawValue: conditionRow["field"] as String),
                  let conditionOperator = MailRuleConditionOperator(
                    rawValue: conditionRow["operator"] as String
                  ) else {
                throw PlainpostError.validationFailed("Stored mail rule condition is invalid.")
            }
            return MailRuleCondition(
                id: conditionRow["id"],
                field: field,
                operator: conditionOperator,
                value: conditionRow["value"]
            )
        }
        let actions = try Set(actionRows.map { actionRow in
            guard let action = MailRuleAction(rawValue: actionRow["action"] as String) else {
                throw PlainpostError.validationFailed("Stored mail rule action is invalid.")
            }
            return action
        })
        let scope: MailRuleScope
        if let accountID: String = row["scope_account_id"] {
            scope = .account(AccountID(accountID))
        } else {
            scope = .allAccounts
        }
        return try MailRule.validated(
            id: id,
            name: row["name"],
            isEnabled: row["is_enabled"],
            scope: scope,
            conditions: conditions,
            actions: actions,
            labelIDs: labelIDs,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    private func recordMailRuleDiagnostic(action: String, targetID: String) throws {
        try databasePool.write { database in
            try insertAudit(
                database: database,
                actorID: "mail-rule-engine",
                action: action,
                targetType: "mail_rule",
                targetID: targetID
            )
        }
        try? flushAuditOutbox()
    }

    private func insertMailRuleLabelAssignmentRemovalAudit(
        database: Database,
        actorID: String,
        ruleID: String,
        labelID: String,
        messageID: String
    ) throws {
        try insertAudit(
            database: database,
            actorID: actorID,
            action: "mail_rule.label_assignment_removed",
            targetType: "message_label_assignment",
            targetID: "\(messageID):\(labelID):rule:\(ruleID)",
            result: try canonicalAuditResult(
                MailLabelAssignmentAuditResult(
                    addedLabelIDs: [],
                    removedLabelIDs: [labelID],
                    ruleID: ruleID,
                    source: "rule"
                )
            )
        )
    }

    // MARK: - Sync preferences and persisted progress

    public func cachedUIDs(accountID: AccountID, mailboxPath: String, uidValidity: Int) throws -> Set<Int> {
        let rows = try fetchRows(
            "SELECT uid FROM mailbox_messages WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ?",
            [accountID.rawValue, mailboxPath, String(uidValidity)]
        )
        return Set(rows.map { row in row["uid"] as Int })
    }

    public func recordMailboxGeneration(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int
    ) throws -> MailboxGenerationStatus {
        do {
            let status = try databasePool.write { database in
                let previous = try Row.fetchOne(
                    database,
                    sql: "SELECT uid_validity, baseline_complete FROM mailbox_sync_state WHERE account_id = ? AND mailbox_path = ?",
                    arguments: [accountID.rawValue, mailboxPath]
                )
                let previousUIDValidity: Int? = previous?["uid_validity"]
                let baselineComplete: Bool = previous?["baseline_complete"] ?? false
                let status: MailboxGenerationStatus = if let previousUIDValidity {
                    previousUIDValidity == uidValidity && baselineComplete ? .unchanged : .replacedBaseline
                } else {
                    .initialBaseline
                }
                if status == .replacedBaseline, previousUIDValidity != uidValidity {
                    let oldMessageIDs = try String.fetchAll(
                        database,
                        sql: "SELECT message_id FROM mailbox_messages WHERE account_id = ? AND mailbox_path = ?",
                        arguments: [accountID.rawValue, mailboxPath]
                    )
                    try database.execute(
                        sql: "DELETE FROM mailbox_messages WHERE account_id = ? AND mailbox_path = ?",
                        arguments: [accountID.rawValue, mailboxPath]
                    )
                    for messageID in oldMessageIDs {
                        try database.execute(
                            sql: """
                                UPDATE messages SET is_deleted = 1 WHERE id = ?
                                AND NOT EXISTS (SELECT 1 FROM mailbox_messages WHERE message_id = ?)
                                """,
                            arguments: [messageID, messageID]
                        )
                        try Self.refreshSearchProjectionIfIndexable(
                            messageID: MessageID(messageID),
                            database: database
                        )
                    }
                }
                try database.execute(
                    sql: """
                        INSERT INTO mailbox_sync_state (
                            account_id, mailbox_path, phase, uid_validity, baseline_complete, updated_at
                        ) VALUES (?, ?, 'discovery', ?, 0, ?)
                        ON CONFLICT(account_id, mailbox_path) DO UPDATE SET
                            uid_validity = excluded.uid_validity,
                            baseline_complete = CASE WHEN mailbox_sync_state.uid_validity IS NOT excluded.uid_validity
                                THEN 0 ELSE mailbox_sync_state.baseline_complete END,
                            phase = CASE WHEN mailbox_sync_state.uid_validity IS NOT excluded.uid_validity
                                THEN 'discovery' ELSE mailbox_sync_state.phase END,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [accountID.rawValue, mailboxPath, uidValidity, Date().timeIntervalSince1970]
                )
                return status
            }
            if status == .replacedBaseline { MailStoreChangeSignal.post(scope: .operations) }
            return status
        } catch {
            throw databaseError(error)
        }
    }

    public func markMailboxBaselineComplete(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int
    ) throws {
        try execute(
            """
            UPDATE mailbox_sync_state SET baseline_complete = 1, updated_at = ?
            WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ?
            """,
            [String(Date().timeIntervalSince1970), accountID.rawValue, mailboxPath, String(uidValidity)]
        )
    }

    public func cachedUIDsMissingSentDate(
        accountID: AccountID, mailboxPath: String, uidValidity: Int, limit: Int
    ) throws -> [(uid: Int, messageID: MessageID)] {
        try fetchRows(
            """
            SELECT mm.uid, mm.message_id FROM mailbox_messages mm
            JOIN messages m ON m.id = mm.message_id
            WHERE mm.account_id = ? AND mm.mailbox_path = ? AND mm.uid_validity = ? AND m.sent_at IS NULL
            ORDER BY mm.uid DESC LIMIT \(max(0, limit))
            """,
            [accountID.rawValue, mailboxPath, String(uidValidity)]
        ).map { row in (uid: row["uid"] as Int, messageID: MessageID(row["message_id"] as String)) }
    }

    public func repairMissingSentDate(_ date: Date, messageID: MessageID) throws {
        let repaired = try databasePool.write { database in
            try database.execute(
                sql: "UPDATE messages SET sent_at = ? WHERE id = ? AND sent_at IS NULL",
                arguments: [date.timeIntervalSince1970, messageID.rawValue]
            )
            guard database.changesCount == 1 else { return false }
            try SQLiteMailSearchProjectionWriter.refresh(messageID: messageID, database: database)
            return true
        }
        if repaired {
            MailStoreChangeSignal.post(scope: .mailbox)
        }
    }

    public func cachedUIDsWithMisreadSender(
        accountID: AccountID, mailboxPath: String, uidValidity: Int, limit: Int
    ) throws -> [(uid: Int, messageID: MessageID)] {
        try fetchRows(
            """
            SELECT mm.uid, mm.message_id FROM mailbox_messages mm
            JOIN messages m ON m.id = mm.message_id
            WHERE mm.account_id = ? AND mm.mailbox_path = ? AND mm.uid_validity = ? AND mm.uid > 0
              AND (instr(m.from_display_name, char(10)) > 0 OR instr(m.from_display_name, char(13)) > 0)
            ORDER BY mm.uid DESC LIMIT \(max(0, limit))
            """,
            [accountID.rawValue, mailboxPath, String(uidValidity)]
        ).map { row in (uid: row["uid"] as Int, messageID: MessageID(row["message_id"] as String)) }
    }

    public func repairMisreadSender(
        messageID: MessageID, from: EmailAddress, displayName: String?,
        replyTo: EmailAddress?, to: [EmailAddress], cc: [EmailAddress]
    ) throws {
        let repaired = try databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE messages SET from_email = ?, from_display_name = ?, reply_to_email = ?,
                        to_emails = ?, cc_emails = ?
                    WHERE id = ?
                      AND (instr(from_display_name, char(10)) > 0 OR instr(from_display_name, char(13)) > 0)
                    """,
                arguments: [
                    from.rawValue, displayName, replyTo?.rawValue,
                    to.map(\.rawValue).joined(separator: "\n"),
                    cc.map(\.rawValue).joined(separator: "\n"),
                    messageID.rawValue,
                ]
            )
            guard database.changesCount == 1 else { return false }
            try SQLiteMailSearchProjectionWriter.refresh(messageID: messageID, database: database)
            return true
        }
        if repaired {
            MailStoreChangeSignal.post(scope: .mailbox)
        }
    }

    public func newestCachedUID(accountID: AccountID, mailboxPath: String, uidValidity: Int) throws -> Int? {
        let row = try fetchRows(
            "SELECT MAX(uid) AS newest_uid FROM mailbox_messages WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ?",
            [accountID.rawValue, mailboxPath, String(uidValidity)]
        ).first
        return row?["newest_uid"]
    }

    public func recordCachedUID(
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        messageID: MessageID
    ) throws {
        try databasePool.write { database in
            let displacedMessageID = try String.fetchOne(
                database,
                sql: """
                    SELECT message_id FROM mailbox_messages
                    WHERE account_id = ? AND mailbox_path = ?
                      AND uid_validity = ? AND uid = ?
                    """,
                arguments: [accountID.rawValue, mailboxPath, uidValidity, uid]
            )
            try database.execute(
                sql: """
                    INSERT INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, mailbox_path, uid_validity, uid)
                    DO UPDATE SET message_id = excluded.message_id
                """,
                arguments: [accountID.rawValue, mailboxPath, uidValidity, uid, messageID.rawValue]
            )
            let affectedMessageIDs = Set([displacedMessageID, messageID.rawValue].compactMap { $0 })
            for affectedMessageID in affectedMessageIDs.sorted() {
                try Self.refreshSearchProjectionIfIndexable(
                    messageID: MessageID(affectedMessageID),
                    database: database
                )
            }
        }
    }

    public func recordMailboxSyncProgress(
        accountID: AccountID,
        mailboxPath: String,
        phase: String,
        downloaded: Int,
        estimatedTotal: Int,
        complete: Bool,
        error: String?
    ) throws {
        try execute(
            """
            INSERT INTO mailbox_sync_state (
                account_id, mailbox_path, phase, downloaded_count, estimated_total, complete, last_error, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, mailbox_path) DO UPDATE SET
                phase = excluded.phase, downloaded_count = excluded.downloaded_count,
                estimated_total = excluded.estimated_total, complete = excluded.complete,
                last_error = excluded.last_error, updated_at = excluded.updated_at
            """,
            [accountID.rawValue, mailboxPath, phase, String(downloaded), String(estimatedTotal),
             complete ? "1" : "0", error, String(Date().timeIntervalSince1970)]
        )
        let updateStride = max(1, estimatedTotal / 20)
        if complete || downloaded.isMultiple(of: updateStride) {
            MailStoreChangeSignal.post(scope: .operations)
        }
    }

    public func syncPreferences(accountID: AccountID) throws -> MailSyncPreferences {
        guard let row = try fetchRows("SELECT * FROM sync_preferences WHERE account_id = ?", [accountID.rawValue]).first else {
            return MailSyncPreferences(accountID: accountID)
        }
        return MailSyncPreferences(
            accountID: accountID,
            downloadCompleteHistory: row["download_complete_history"],
            recentMessageLimit: row["recent_message_limit"],
            realTimeMonitoringEnabled: row["real_time_monitoring_enabled"]
        )
    }

    public func saveSyncPreferences(_ preferences: MailSyncPreferences) throws {
        try execute(
            """
            INSERT INTO sync_preferences (account_id, download_complete_history, recent_message_limit, real_time_monitoring_enabled)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                download_complete_history = excluded.download_complete_history,
                recent_message_limit = excluded.recent_message_limit,
                real_time_monitoring_enabled = excluded.real_time_monitoring_enabled
            """,
            [preferences.accountID.rawValue, preferences.downloadCompleteHistory ? "1" : "0",
             String(preferences.recentMessageLimit), preferences.realTimeMonitoringEnabled ? "1" : "0"]
        )
        MailStoreChangeSignal.post(scope: .accounts)
    }

    public func mailboxSyncPreferences(accountID: AccountID) throws -> [MailboxSyncPreference] {
        try fetchRows(
            "SELECT account_id, mailbox_path, mode FROM mailbox_sync_preferences WHERE account_id = ? ORDER BY mailbox_path",
            [accountID.rawValue]
        ).compactMap { row in
            guard let mode = MailboxSyncMode(rawValue: row["mode"]) else { return nil }
            return MailboxSyncPreference(accountID: accountID, mailboxPath: row["mailbox_path"], mode: mode)
        }
    }

    public func saveMailboxSyncPreference(_ preference: MailboxSyncPreference) throws {
        try execute(
            """
            INSERT INTO mailbox_sync_preferences (account_id, mailbox_path, mode) VALUES (?, ?, ?)
            ON CONFLICT(account_id, mailbox_path) DO UPDATE SET mode = excluded.mode
            """,
            [preference.accountID.rawValue, preference.mailboxPath, preference.mode.rawValue]
        )
        MailStoreChangeSignal.post(scope: .accounts)
    }

    /// The newest error-free mailbox sync update of `accountID`, or of every cached
    /// account when it is nil. Nil when none has synced.
    public func lastSuccessfulMailboxSyncAt(accountID: AccountID? = nil) throws -> Date? {
        try databasePool.read { database in
            try Double.fetchOne(
                database,
                sql: """
                    SELECT MAX(updated_at) FROM mailbox_sync_state
                    WHERE last_error IS NULL
                      AND account_id IN (SELECT id FROM accounts)
                      \(accountID == nil ? "" : "AND account_id = ?")
                    """,
                arguments: accountID.map { [$0.rawValue] } ?? []
            )
        }.map(Date.init(timeIntervalSince1970:))
    }

    public func mailboxSyncStatuses(accountID: AccountID) throws -> [MailboxSyncStatus] {
        try fetchRows(
            "SELECT * FROM mailbox_sync_state WHERE account_id = ? ORDER BY mailbox_path",
            [accountID.rawValue]
        ).map { row in
            let rawPhase: String = row["phase"]
            let phase = MailboxSyncPhase(rawValue: rawPhase) ?? .failed
            return MailboxSyncStatus(
                accountID: accountID,
                mailboxPath: row["mailbox_path"],
                phase: phase,
                downloaded: row["downloaded_count"],
                estimatedTotal: row["estimated_total"],
                complete: row["complete"],
                lastError: row["last_error"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    public func searchMessages(_ query: String, limit: Int = 100) throws -> [MessageID] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let matchQuery = "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
        let rows = try fetchRows(
            """
            SELECT documents.message_id
            FROM mail_search_fts
            JOIN mail_search_documents documents ON documents.rowid = mail_search_fts.rowid
            WHERE mail_search_fts MATCH ?
            ORDER BY bm25(mail_search_fts), documents.message_id
            LIMIT ?
            """,
            [matchQuery, String(max(1, min(limit, 1_000)))]
        )
        return rows.map { row in MessageID(row["message_id"] as String) }
    }

    /// SQL for `MailKnowledgeFilter` against `messages` aliased as `m`. `sent_at` is stored as
    /// seconds since 1970 (see `decodeMessage`).
    static func knowledgeFilterPredicate(_ filter: MailKnowledgeFilter) -> (sql: String, arguments: [String?]) {
        var clauses: [String] = []
        var arguments: [String?] = []
        if filter.unreadOnly { clauses.append("m.is_seen = 0") }
        switch filter.mailbox {
        case .any: break
        case .inbox: clauses.append("lower(m.mailbox_path) = 'inbox'")
        case .sent: clauses.append("lower(m.mailbox_path) LIKE '%sent%'")
        case .archive: clauses.append("(lower(m.mailbox_path) LIKE '%archive%' OR lower(m.mailbox_path) LIKE '%all mail%')")
        }
        if let sender = filter.senderContains?.lowercased(), !sender.isEmpty {
            clauses.append("(lower(m.from_email) LIKE ? ESCAPE '\\' OR lower(COALESCE(m.from_display_name, '')) LIKE ? ESCAPE '\\')")
            let escaped = sender.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            arguments.append("%\(escaped)%")
            arguments.append("%\(escaped)%")
        }
        if let after = filter.sentAfter {
            clauses.append("m.sent_at >= ?")
            arguments.append(String(after.timeIntervalSince1970))
        }
        if let before = filter.sentBefore {
            clauses.append("m.sent_at < ?")
            arguments.append(String(before.timeIntervalSince1970))
        }
        if !filter.categories.isEmpty {
            clauses.append("m.smart_category IN (\(Array(repeating: "?", count: filter.categories.count).joined(separator: ", ")))")
            arguments.append(contentsOf: filter.categories.map(\.rawValue))
        }
        return (clauses.map { " AND \($0)" }.joined(), arguments)
    }

    /// Full account-ownership test used everywhere a query must be scoped to one account: matches
    /// the effective account (`smartInboxMessageAccountExpression`) and excludes messages with any
    /// `mailbox_messages` row for another account, a mismatching `account_id`, or a thread owned by
    /// another account. Keep `filteredMailMessages` and `accountMessageIDs` sharing this fragment so
    /// their notions of "belongs to this account" never drift apart.
    private static func accountOwnershipPredicate(messageAlias: String) -> String {
        """
         AND \(smartInboxMessageAccountExpression(messageAlias: messageAlias)) = ?
         AND NOT EXISTS (
             SELECT 1 FROM mailbox_messages mm
             WHERE mm.message_id = \(messageAlias).id AND mm.account_id <> ?
         )
         AND (\(messageAlias).account_id IS NULL OR \(messageAlias).account_id = ?)
         AND NOT EXISTS (
             SELECT 1 FROM threads t
             WHERE t.id = \(messageAlias).thread_id AND t.account_id IS NOT NULL
               AND t.account_id <> ?
         )
        """
    }

    /// WHERE clause shared by `filteredMailMessages` and `filteredMailCategoryCounts`. `.any`
    /// lists leave out Trash and Junk (see `MailMailboxFilter.isTrashOrJunk`).
    private func filteredMailWhere(
        _ filter: MailKnowledgeFilter, accountID: AccountID?
    ) throws -> (sql: String, arguments: [String?]) {
        let predicate = Self.knowledgeFilterPredicate(filter)
        var trashPredicate = ""
        var trashArguments: [String?] = []
        if filter.mailbox == .any {
            // The Trash and Junk paths in use, recognized in Swift (special-use,
            // localized and modified UTF-7 names) rather than by SQL LIKE.
            let excluded = try trashAndJunkMailboxes(accountID: accountID)
            var indexedExclusion = "0"
            if !excluded.isEmpty {
                let pairs = excluded.map { _ in "(m.account_id = ? AND m.mailbox_path = ?)" }.joined(separator: " OR ")
                // A message row without an account falls back to the path alone.
                let paths = Array(Set(excluded.map(\.path))).sorted()
                let unowned = "(COALESCE(m.account_id, '') = '' AND m.mailbox_path IN (\(paths.map { _ in "?" }.joined(separator: ", "))))"
                indexedExclusion = "(\(pairs) OR \(unowned))"
                trashArguments = excluded.flatMap { [Optional($0.accountID), Optional($0.path)] } + paths.map { Optional($0) }
            }
            // Legacy caches can contain canonical rows without provider memberships.
            // Classify those within the existing query, using indexed catalog lookups,
            // rather than enumerating all message paths in a separate scan.
            let owner = Self.smartInboxMessageAccountExpression(messageAlias: "m")
            trashPredicate = """
             AND NOT (CASE WHEN NOT EXISTS (
                 SELECT 1 FROM mailbox_messages legacy_membership WHERE legacy_membership.message_id = m.id
             ) THEN plainpost_mailbox_is_trash_or_junk(
                 m.mailbox_path,
                 (SELECT special_use FROM mailboxes WHERE account_id = (\(owner)) AND path = m.mailbox_path LIMIT 1),
                 EXISTS (SELECT 1 FROM mailboxes WHERE account_id = (\(owner)) AND special_use = '\\Trash' COLLATE NOCASE)
             ) ELSE \(indexedExclusion) END)
            """
        }
        let accountPredicate = accountID == nil ? "" : Self.accountOwnershipPredicate(messageAlias: "m")
        var arguments = predicate.arguments + trashArguments
        if let accountID { arguments.append(contentsOf: Array(repeating: accountID.rawValue, count: 4)) }
        return ("WHERE m.is_deleted = 0\(predicate.sql)\(trashPredicate)\(accountPredicate)", arguments)
    }

    /// The (account, mailbox) pairs in use that are Trash or Junk by
    /// `MailMailboxFilter.isTrashOrJunk`, judged with each account's own folder
    /// list. The paths come from `mailbox_messages`' primary key, not a scan of
    /// `messages`.
    private func trashAndJunkMailboxes(accountID: AccountID?) throws -> [(accountID: String, path: String)] {
        try databasePool.read { database in
            let accountFilter = accountID == nil ? "" : " WHERE account_id = ?"
            let accountArguments: StatementArguments = accountID.map { [$0.rawValue] } ?? []
            let folders = try Row.fetchAll(
                database,
                sql: "SELECT id, account_id, name, path, special_use FROM mailboxes\(accountFilter)",
                arguments: accountArguments
            ).map { row in
                Mailbox(
                    id: MailboxID(row["id"]), accountID: AccountID(row["account_id"]),
                    name: row["name"], path: row["path"], specialUse: row["special_use"]
                )
            }
            let foldersByAccount = Dictionary(grouping: folders) { $0.accountID.rawValue }
            let inUse = try Row.fetchAll(
                database,
                sql: "SELECT DISTINCT account_id, mailbox_path FROM mailbox_messages\(accountFilter)",
                arguments: accountArguments
            )
            return inUse.compactMap { row -> (accountID: String, path: String)? in
                let account: String = row["account_id"]
                let path: String = row["mailbox_path"]
                let accountFolders = foldersByAccount[account] ?? []
                let specialUse = accountFolders.first { $0.path == path }?.specialUse
                guard MailMailboxFilter.isTrashOrJunk(path, specialUse: specialUse, accountMailboxes: accountFolders)
                else { return nil }
                return (account, path)
            }
        }
    }

    public func filteredMailCategoryCounts(
        _ filter: MailKnowledgeFilter, accountID: AccountID?
    ) throws -> [SmartCategory: Int] {
        let clause = try filteredMailWhere(filter, accountID: accountID)
        let rows = try fetchRows(
            "SELECT m.smart_category AS category, COUNT(*) AS total FROM messages m \(clause.sql) GROUP BY m.smart_category",
            clause.arguments
        )
        return rows.reduce(into: [:]) { counts, row in
            let category = SmartCategory(rawValue: row["category"] as String) ?? .unknown
            counts[category, default: 0] += Int(row["total"] as Int64)
        }
    }

    public func conversationMessages(conversationKey: String, accountID: AccountID?) throws -> [MessageSummary] {
        let keyPredicate: String
        let keyArguments: [String?]
        if conversationKey.hasPrefix("message_") {
            keyPredicate = " AND m.id = ?"
            keyArguments = [String(conversationKey.dropFirst("message_".count))]
        } else if conversationKey.hasPrefix("legacy_subject_") {
            // Legacy per-UID threads group by subject; narrow to them in SQL, match the key below.
            keyPredicate = " AND m.thread_id LIKE 'thr\\_uid\\_%' ESCAPE '\\'"
            keyArguments = []
        } else {
            keyPredicate = " AND m.thread_id = ?"
            keyArguments = [conversationKey]
        }
        let accountPredicate = accountID == nil ? "" : Self.accountOwnershipPredicate(messageAlias: "m")
        let rows = try fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name, m.subject, m.preview,
                m.body_text, m.body_html, m.smart_category, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.rfc_message_id, m.in_reply_to,
                m.references_json, m.reply_to_email, m.to_emails, m.cc_emails
            FROM messages m
            WHERE m.is_deleted = 0\(keyPredicate)\(accountPredicate)
            ORDER BY m.sent_at, m.id
            """,
            keyArguments + (accountID.map { Array(repeating: $0.rawValue, count: 4) } ?? [])
        )
        return rows.map(decodeMessage).filter { MailThreading.conversationKey(for: $0) == conversationKey }
    }

    public func filteredMailMessages(
        _ filter: MailKnowledgeFilter, accountID: AccountID?, limit: Int
    ) throws -> MailFilterResult {
        let clause = try filteredMailWhere(filter, accountID: accountID)
        let arguments = clause.arguments
        let whereSQL = clause.sql
        let countRows = try fetchRows("SELECT COUNT(*) AS total FROM messages m \(whereSQL)", arguments)
        let total = countRows.first.map { Int($0["total"] as Int64) } ?? 0
        let rows = try fetchRows(
            """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name, m.subject, m.preview,
                m.body_text, m.body_html, m.smart_category, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.rfc_message_id, m.in_reply_to,
                m.references_json, m.reply_to_email, m.to_emails, m.cc_emails
            FROM messages m \(whereSQL)
            ORDER BY m.sent_at DESC, m.id DESC
            LIMIT ?
            """,
            arguments + [String(max(0, min(limit, 1_000)))]
        )
        return MailFilterResult(totalCount: total, messages: rows.map(decodeMessage))
    }

    public func rankedMailSearch(_ query: MailKnowledgeQuery) throws -> [RankedMailKnowledgeCandidate] {
        let matchQuery = Self.naturalLanguageFTSQuery(query.text)
        guard !matchQuery.isEmpty else { return [] }

        let filterPredicate = Self.knowledgeFilterPredicate(query.filter)
        let accountPredicate = query.accountID == nil ? "" :
            " AND \(Self.smartInboxMessageAccountExpression(messageAlias: "m")) = ?"
        var conversationPredicate = ""
        var conversationArgument: String?
        if query.scope == .activeConversation, let activeKey = query.activeConversationKey {
            if activeKey.hasPrefix("message_") {
                conversationPredicate = " AND m.id = ?"
                conversationArgument = String(activeKey.dropFirst("message_".count))
            } else if !activeKey.hasPrefix("legacy_subject_") {
                conversationPredicate = " AND m.thread_id = ?"
                conversationArgument = activeKey
            }
        }
        let requiresLegacyPostFilter = query.scope == .activeConversation
            && query.activeConversationKey?.hasPrefix("legacy_subject_") == true
        let fetchLimit = requiresLegacyPostFilter
            ? 1_000
            : max(1, min(max(query.limit, 1) * 4, 1_000))
        let sql = """
            SELECT m.id, m.thread_id, m.from_email, m.from_display_name, m.subject, m.preview,
                m.body_text, m.body_html, m.smart_category, m.labels_json, m.is_seen, m.is_flagged,
                m.mailbox_path, m.is_deleted, m.sent_at, m.rfc_message_id, m.in_reply_to,
                m.references_json, m.reply_to_email, m.to_emails, m.cc_emails,
                snippet(mail_search_fts, 9, '', '', ' … ', 24) AS evidence_snippet,
                bm25(mail_search_fts) AS lexical_rank
            FROM mail_search_fts
            JOIN mail_search_documents d ON d.rowid = mail_search_fts.rowid
            JOIN messages m ON m.id = d.message_id
            WHERE mail_search_fts MATCH ? AND d.is_deleted = 0\(filterPredicate.sql)\(accountPredicate)\(conversationPredicate)
            ORDER BY lexical_rank
            LIMIT ?
            """
        var arguments: [String?] = [matchQuery]
        arguments.append(contentsOf: filterPredicate.arguments)
        if let accountID = query.accountID { arguments.append(accountID.rawValue) }
        if let conversationArgument { arguments.append(conversationArgument) }
        arguments.append(String(fetchLimit))
        let rows = try fetchRows(
            sql,
            arguments
        )

        let activeKey = query.activeConversationKey
        let candidates = rows.enumerated().compactMap { offset, row -> RankedMailKnowledgeCandidate? in
            let message = decodeMessage(row)
            if query.scope == .activeConversation,
               MailThreading.conversationKey(for: message) != activeKey {
                return nil
            }
            let rawRank = (row["lexical_rank"] as Double?) ?? Double(offset)
            let rawSnippet = (row["evidence_snippet"] as String?) ?? message.preview
            let snippet = rawSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            return RankedMailKnowledgeCandidate(
                message: message,
                snippet: snippet.isEmpty ? message.preview : snippet,
                lexicalRank: offset + 1,
                lexicalScore: 1 / (1 + abs(rawRank))
            )
        }
        return Array(candidates.prefix(max(1, min(query.limit, 100))))
    }

    public func accountMessageIDs(accountID: AccountID) throws -> Set<MessageID> {
        try databasePool.read { database in
            let identifiers = try String.fetchAll(
                database,
                sql: """
                    SELECT m.id FROM messages m
                    WHERE m.is_deleted = 0\(Self.accountOwnershipPredicate(messageAlias: "m"))
                    """,
                arguments: StatementArguments(Array(repeating: accountID.rawValue, count: 4))
            )
            return Set(identifiers.map { MessageID($0) })
        }
    }

    private static func naturalLanguageFTSQuery(_ text: String) -> String {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "can", "did", "do", "find", "for", "from", "have",
            "i", "in", "is", "it", "mail", "me", "my", "of", "on", "or", "please", "show",
            "that", "the", "this", "to", "was", "what", "when", "where", "who", "with"
        ]
        var seen: Set<String> = []
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(12)
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " OR ")
    }

    public func storedMailEmbeddingChunks(
        providerID: String,
        modelID: String
    ) throws -> [StoredMailEmbeddingChunk] {
        try databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT message_id, provider_id, model_id, content_fingerprint, ordinal,
                        chunk_text, dimensions, vector, updated_at
                    FROM mail_embedding_chunks
                    WHERE provider_id = ? AND model_id = ?
                    ORDER BY message_id, ordinal
                    """,
                arguments: [providerID, modelID]
            ).compactMap { row in
                let data: Data = row["vector"]
                let dimensions: Int = row["dimensions"]
                let vector = Self.decodeEmbeddingVector(data, dimensions: dimensions)
                guard vector.count == dimensions else { return nil }
                return StoredMailEmbeddingChunk(
                    messageID: MessageID(row["message_id"]),
                    providerID: row["provider_id"],
                    modelID: row["model_id"],
                    contentFingerprint: row["content_fingerprint"],
                    ordinal: row["ordinal"],
                    text: row["chunk_text"],
                    vector: vector,
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    public func replaceMailEmbeddingChunks(
        messageID: MessageID,
        providerID: String,
        modelID: String,
        contentFingerprint: String,
        chunks: [StoredMailEmbeddingChunk]
    ) throws {
        try databasePool.write { database in
            try database.execute(
                sql: "DELETE FROM mail_embedding_chunks WHERE message_id = ? AND provider_id = ? AND model_id = ?",
                arguments: [messageID.rawValue, providerID, modelID]
            )
            for chunk in chunks {
                let vector = Self.encodeEmbeddingVector(chunk.vector)
                try database.execute(
                    sql: """
                        INSERT INTO mail_embedding_chunks (
                            message_id, provider_id, model_id, content_fingerprint, ordinal,
                            chunk_text, dimensions, vector, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        messageID.rawValue, providerID, modelID, contentFingerprint, chunk.ordinal,
                        chunk.text, chunk.vector.count, vector, chunk.updatedAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    private static func encodeEmbeddingVector(_ vector: [Double]) -> Data {
        vector.map(Float32.init).withUnsafeBytes { Data($0) }
    }

    private static func decodeEmbeddingVector(_ data: Data, dimensions: Int) -> [Double] {
        guard dimensions >= 0, data.count == dimensions * MemoryLayout<Float32>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float32.self)).map(Double.init)
        }
    }

    private struct AccountDeletionOwnership {
        let accountID: AccountID
        let mailboxIDs: Set<String>
        let threadIDs: Set<String>
        let messageIDs: Set<String>
        let draftIDs: Set<String>
        let sendRequestIDs: Set<String>
        let jobIDs: Set<String>
        let scheduleIDs: Set<String>
        let ruleIDs: Set<String>
        let labelIDs: Set<String>
        let artifactIDs: Set<String>
        let auditEntryIDs: Set<String>

        var referenceIDs: Set<String> {
            var ids: Set<String> = [accountID.rawValue]
            ids.formUnion(mailboxIDs)
            ids.formUnion(threadIDs)
            ids.formUnion(messageIDs)
            ids.formUnion(draftIDs)
            ids.formUnion(sendRequestIDs)
            ids.formUnion(jobIDs)
            ids.formUnion(scheduleIDs)
            ids.formUnion(ruleIDs)
            ids.formUnion(labelIDs)
            ids.formUnion(artifactIDs)
            return ids
        }
    }

    static func validateAccountDeletionJobPayload(
        kindRaw: String,
        payloadJSON: String,
        accountID: AccountID,
        database: Database
    ) throws {
        guard let kind = PlainpostOperationKind(rawValue: kindRaw) else {
            throw PlainpostError.validationFailed(
                "An account-owned durable job has an unknown kind."
            )
        }
        let explicit = OwnershipClassification.account(accountID.rawValue)
        let resolved: OwnershipClassification
        do {
            resolved = try operationOwnership(
                kind: kind,
                payloadJSON: payloadJSON,
                database: database,
                resolutionMode: .migration(explicit: explicit)
            )
        } catch let error as PlainpostError {
            throw error
        } catch {
            throw PlainpostError.validationFailed(
                "An account-owned durable job payload could not be decoded."
            )
        }
        guard resolved.kind == .account, resolved.owner == accountID.rawValue else {
            throw PlainpostError.validationFailed(
                "An account-owned durable job conflicts with its typed payload."
            )
        }
    }

    private static func auditOwnership(
        action: String,
        targetType: String,
        targetID: String,
        database: Database
    ) throws -> OwnershipClassification {
        let knownGlobalTargets: Set<String> = [
            "search.maintenance.failed|mail_search",
            "node_mode.schema_unavailable|node_mode",
        ]
        if knownGlobalTargets.contains("\(action)|\(targetType)") {
            return .init(kind: .global, owner: nil)
        }
        if targetType == "account" {
            return .account(targetID)
        }
        if targetType == "mail_label" || targetType == "mail_rule" {
            let table = targetType == "mail_label" ? "mail_labels" : "mail_rules"
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT scope_account_id FROM \(table) WHERE id = ?",
                arguments: [targetID]
            ) else { return .init(kind: .ambiguous, owner: nil) }
            let owner: String? = row["scope_account_id"]
            return owner.map(OwnershipClassification.account)
                ?? .init(kind: .shared, owner: nil)
        }
        if targetType == "message_label_assignment" {
            let owner = try String.fetchOne(
                database,
                sql: """
                    SELECT m.account_id
                    FROM messages m
                    JOIN mail_labels l
                    JOIN mail_rules r
                    WHERE ? = m.id || ':' || l.id || ':rule:' || r.id
                      AND (l.scope_account_id IS NULL OR l.scope_account_id = m.account_id)
                      AND (r.scope_account_id IS NULL OR r.scope_account_id = m.account_id)
                    LIMIT 1
                    """,
                arguments: [targetID]
            )
            return owner.map(OwnershipClassification.account)
                ?? .init(kind: .ambiguous, owner: nil)
        }
        switch targetType {
        case "message":
            return try messageRelationOwnership(
                messageID: targetID,
                explicitAccountID: nil,
                database: database
            )
        case "draft":
            return try optionalAccountOwnership(
                table: "drafts", idColumn: "id", ownerColumn: "owner_account_id",
                referenceID: targetID, database: database
            )
        case "send_request":
            return try optionalAccountOwnership(
                table: "send_requests", idColumn: "id", ownerColumn: "owner_account_id",
                referenceID: targetID, database: database
            )
        case "smart_inbox_reclassification":
            return try optionalJobOwnership(jobID: targetID, database: database)
                ?? .init(kind: .ambiguous, owner: nil)
        default:
            return .init(kind: .ambiguous, owner: nil)
        }
    }

    private static func operationOwnership(
        kind: PlainpostOperationKind,
        payloadJSON: String,
        database: Database,
        resolutionMode: OwnershipResolutionMode = .runtime
    ) throws -> OwnershipClassification {
        let data = Data(payloadJSON.utf8)
        switch kind {
        case .inboxSync, .historicalSync:
            let input = try JSONDecoder().decode(PlainpostInboxSyncInput.self, from: data)
            return try payloadAccountOwnership(
                input.accountID, database: database, resolutionMode: resolutionMode
            )
        case .aiOperation:
            let input = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: data)
            switch input.operation {
            case .recategorizeInbox:
                switch input.smartInboxRunRequest.scope {
                case .account(let accountID):
                    return try payloadAccountOwnership(
                        accountID, database: database, resolutionMode: resolutionMode
                    )
                case .allAccounts:
                    return .init(kind: .shared, owner: nil)
                }
            case .answerMailboxQuestion:
                switch input.retrievalScope ?? .allMail {
                case .allMail:
                    if let accountID = input.accountID {
                        return try payloadAccountOwnership(
                            accountID, database: database, resolutionMode: resolutionMode)
                    }
                    return .init(kind: .shared, owner: nil)
                case .activeConversation:
                    guard let key = input.activeConversationKey, !key.isEmpty else {
                        throw PlainpostError.validationFailed("The active conversation owner could not be resolved.")
                    }
                    if let accountID = input.accountID {
                        _ = try payloadAccountOwnership(
                            accountID, database: database, resolutionMode: resolutionMode)
                    }
                    let owner = try requiredConversationOwnerAccountID(
                        forConversationKey: key,
                        selectedAccountID: input.accountID?.rawValue,
                        database: database)
                    if let accountID = input.accountID {
                        guard owner == accountID.rawValue else {
                            throw PlainpostError.permissionDenied("The active conversation belongs to another account.")
                        }
                    }
                    return .account(owner)
                }
            case .summarizeThread, .answerThreadQuestion:
                return try conversationOperationOwnership(
                    input: input,
                    requiredKind: nil,
                    database: database,
                    resolutionMode: resolutionMode
                )
            case .draftReply:
                return try conversationOperationOwnership(
                    input: input,
                    requiredKind: nil,
                    database: database,
                    resolutionMode: resolutionMode
                )
            case .summarizeMessage, .translateMessage, .classifyMessage:
                return try conversationOperationOwnership(
                    input: input,
                    requiredKind: .message,
                    database: database,
                    resolutionMode: resolutionMode
                )
            case .rewriteDraft:
                let draftExists = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM drafts WHERE id = ?)",
                    arguments: [input.recordID]
                ) == true
                if !draftExists,
                   input.accountID == nil,
                   case .migration(let storedDescriptor?) = resolutionMode,
                   storedDescriptor.kind == .account,
                   storedDescriptor.owner != nil {
                    return storedDescriptor
                }
                return try relationalOperationOwnership(
                    in: "drafts", idColumn: "id", ownerColumn: "owner_account_id",
                    referenceID: input.recordID, payloadAccountID: input.accountID,
                    database: database, resolutionMode: resolutionMode
                )
            case .rebuildIndex:
                throw PlainpostError.validationFailed("A rebuild operation must use the search rebuild job kind.")
            }
        case .approvedDelivery, .denySend:
            let input = try JSONDecoder().decode(PlainpostApprovalDecisionInput.self, from: data)
            return .account(try requiredOwnerAccountID(
                in: "send_requests", idColumn: "id", ownerColumn: "owner_account_id",
                referenceID: input.requestID.rawValue, database: database
            ))
        case .mailboxFlag:
            let input = try JSONDecoder().decode(PlainpostMailboxFlagInput.self, from: data)
            let membership = try exactMailboxFlagMembership(input, database: database)
            return try payloadAccountOwnership(
                membership.accountID, database: database, resolutionMode: resolutionMode
            )
        case .mailboxArchive:
            let input = try JSONDecoder().decode(PlainpostMailboxArchiveInput.self, from: data)
            guard try archiveMembershipMatches(input: input, database: database) else {
                throw PlainpostError.validationFailed("The archive operation account does not own the referenced mailbox message.")
            }
            return .account(input.accountID.rawValue)
        case .searchRebuild:
            let input = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: data)
            guard input.operation == .rebuildIndex else {
                throw PlainpostError.validationFailed("The search rebuild payload is invalid.")
            }
            return .init(kind: .global, owner: nil)
        }
    }

    private static func requiredConversationOwnerAccountID(
        forConversationKey key: String,
        selectedAccountID: String? = nil,
        database: Database
    ) throws -> String {
        if key.hasPrefix("message_") {
            return try requiredMessageRelationOwner(
                messageID: String(key.dropFirst("message_".count)), database: database
            )
        }
        if key.hasPrefix("legacy_subject_") {
            let normalizedSubject = String(key.dropFirst("legacy_subject_".count))
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT DISTINCT \(smartInboxMessageAccountExpression(messageAlias: "m")) account_id, subject FROM messages m"
            )
            let owners = Set(rows.compactMap { row -> String? in
                let subject: String = row["subject"]
                guard MailThreading.normalizedSubject(subject) == normalizedSubject else { return nil }
                let owner: String? = row["account_id"]
                guard selectedAccountID == nil || owner == selectedAccountID else { return nil }
                return owner
            })
            guard owners.count == 1, let owner = owners.first else {
                throw PlainpostError.validationFailed("The active conversation owner could not be resolved.")
            }
            return owner
        }
        let owners = try String.fetchAll(
            database,
            sql: """
                SELECT account_id FROM threads WHERE id = ? AND account_id IS NOT NULL
                UNION
                SELECT \(smartInboxMessageAccountExpression(messageAlias: "m"))
                FROM messages m
                WHERE (m.thread_id = ? OR m.id = ?)
                  AND \(smartInboxMessageAccountExpression(messageAlias: "m")) IS NOT NULL
                """,
            arguments: [key, key, key]
        )
        let matchingOwners = selectedAccountID.map { selected in
            owners.filter { $0 == selected }
        } ?? owners
        guard matchingOwners.count == 1, let owner = matchingOwners.first else {
            throw PlainpostError.validationFailed("The active conversation owner could not be resolved.")
        }
        return owner
    }

    private static func requiredMessageRelationOwner(
        messageID: String,
        database: Database
    ) throws -> String {
        let ownership = try messageRelationOwnership(
            messageID: messageID,
            explicitAccountID: nil,
            database: database
        )
        guard ownership.kind == .account, let owner = ownership.owner else {
            throw PlainpostError.validationFailed("The operation owner could not be resolved.")
        }
        return owner
    }

    private static func conversationOperationOwnership(
        input: PlainpostAIOperationInput,
        requiredKind: PlainpostAIConversationReferenceKind?,
        database: Database,
        resolutionMode: OwnershipResolutionMode
    ) throws -> OwnershipClassification {
        if let referenceKind = input.conversationReferenceKind {
            if let requiredKind, referenceKind != requiredKind {
                throw PlainpostError.validationFailed("The AI operation conversation reference kind is invalid.")
            }
            if case .runtime = resolutionMode, input.accountID == nil {
                throw PlainpostError.validationFailed("A new AI conversation operation requires an account context.")
            }
            switch referenceKind {
            case .thread:
                return try relationalOperationOwnership(
                    in: "threads", idColumn: "id", ownerColumn: "account_id",
                    referenceID: input.recordID,
                    payloadAccountID: input.accountID,
                    database: database,
                    resolutionMode: resolutionMode
                )
            case .message:
                return try messageRelationOwnership(
                    messageID: input.recordID,
                    explicitAccountID: input.accountID,
                    database: database,
                    resolutionMode: resolutionMode
                )
            }
        }

        guard case .migration(let explicit) = resolutionMode else {
            throw PlainpostError.validationFailed("A new AI conversation operation requires an explicit reference kind.")
        }
        let threadExists = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM threads WHERE id = ?)",
            arguments: [input.recordID]
        ) == true
        let messageExists = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id = ?)",
            arguments: [input.recordID]
        ) == true
        guard threadExists != messageExists else {
            if !threadExists,
               input.accountID == nil,
               let explicit,
               explicit.kind == .account,
               let owner = explicit.owner {
                return try payloadAccountOwnership(
                    AccountID(owner), database: database, resolutionMode: resolutionMode
                )
            }
            throw PlainpostError.validationFailed("A legacy AI conversation reference is ambiguous.")
        }
        if threadExists {
            return try relationalOperationOwnership(
                in: "threads", idColumn: "id", ownerColumn: "account_id",
                referenceID: input.recordID,
                payloadAccountID: input.accountID,
                database: database,
                resolutionMode: resolutionMode
            )
        }
        return try messageRelationOwnership(
            messageID: input.recordID,
            explicitAccountID: input.accountID,
            database: database,
            resolutionMode: resolutionMode
        )
    }

    private static func messageRelationOwnership(
        messageID: String,
        explicitAccountID: AccountID?,
        database: Database,
        resolutionMode: OwnershipResolutionMode = .runtime
    ) throws -> OwnershipClassification {
        guard try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id = ?)",
            arguments: [messageID]
        ) == true else {
            if let explicitAccountID,
               case .migration = resolutionMode {
                return try payloadAccountOwnership(
                    explicitAccountID,
                    database: database,
                    resolutionMode: resolutionMode
                )
            }
            throw PlainpostError.validationFailed("The operation owner could not be resolved.")
        }
        let membershipOwners = try String.fetchAll(
            database,
            sql: "SELECT DISTINCT account_id FROM mailbox_messages WHERE message_id = ? ORDER BY account_id",
            arguments: [messageID]
        )
        let fallbackOwners = try String.fetchAll(
            database,
            sql: """
                SELECT account_id FROM messages WHERE id = ? AND account_id IS NOT NULL
                UNION
                SELECT t.account_id
                FROM messages m JOIN threads t ON t.id = m.thread_id
                WHERE m.id = ? AND t.account_id IS NOT NULL
                """,
            arguments: [messageID, messageID]
        )
        if let explicitAccountID {
            _ = try payloadAccountOwnership(
                explicitAccountID, database: database, resolutionMode: resolutionMode
            )
            let explicit = explicitAccountID.rawValue
            let matches = membershipOwners.isEmpty
                ? Set(fallbackOwners) == Set([explicit])
                : membershipOwners.contains(explicit)
            guard matches else {
                throw PlainpostError.validationFailed("The message does not belong to the explicit account context.")
            }
            return .account(explicit)
        }
        let candidates = membershipOwners.isEmpty ? fallbackOwners : membershipOwners
        guard !candidates.isEmpty else {
            throw PlainpostError.validationFailed("The operation owner could not be resolved.")
        }
        if Set(candidates).count > 1 { return .init(kind: .shared, owner: nil) }
        guard let owner = candidates.first,
              fallbackOwners.allSatisfy({ $0 == owner }) else {
            return .init(kind: .shared, owner: nil)
        }
        return .account(owner)
    }

    private enum OwnershipResolutionMode {
        case runtime
        case migration(explicit: OwnershipClassification?)
    }

    private static func payloadAccountOwnership(
        _ accountID: AccountID,
        database: Database,
        resolutionMode: OwnershipResolutionMode
    ) throws -> OwnershipClassification {
        let raw = accountID.rawValue
        if try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
            arguments: [raw]
        ) == true {
            return .account(raw)
        }
        if case .migration(let explicit?) = resolutionMode,
           explicit.kind == .account,
           explicit.owner == raw {
            return .account(raw)
        }
        throw PlainpostError.validationFailed("The operation account is unavailable.")
    }

    private static func relationalOperationOwnership(
        in table: String,
        idColumn: String,
        ownerColumn: String,
        referenceID: String,
        payloadAccountID: AccountID?,
        database: Database,
        resolutionMode: OwnershipResolutionMode
    ) throws -> OwnershipClassification {
        if let owner: String = try String.fetchOne(
            database,
            sql: "SELECT \(ownerColumn) FROM \(table) WHERE \(idColumn) = ?",
            arguments: [referenceID]
        ) {
            if let payloadAccountID, payloadAccountID.rawValue != owner {
                throw PlainpostError.validationFailed("The operation account context conflicts with its referenced record.")
            }
            return try payloadAccountOwnership(
                AccountID(owner), database: database, resolutionMode: resolutionMode
            )
        }
        if let payloadAccountID,
           case .migration = resolutionMode {
            return try payloadAccountOwnership(
                payloadAccountID,
                database: database,
                resolutionMode: resolutionMode
            )
        }
        throw PlainpostError.validationFailed("The operation owner could not be resolved.")
    }

    private static func requiredOwnerAccountID(
        in table: String,
        idColumn: String,
        ownerColumn: String,
        referenceID: String,
        database: Database
    ) throws -> String {
        guard let owner = try String.fetchOne(
            database,
            sql: "SELECT \(ownerColumn) FROM \(table) WHERE \(idColumn) = ?",
            arguments: [referenceID]
        ) else {
            throw PlainpostError.validationFailed("The operation owner could not be resolved.")
        }
        return owner
    }

    private static func optionalAccountOwnership(
        table: String,
        idColumn: String,
        ownerColumn: String,
        referenceID: String,
        database: Database
    ) throws -> OwnershipClassification {
        let owner = try String.fetchOne(
            database,
            sql: "SELECT \(ownerColumn) FROM \(table) WHERE \(idColumn) = ?",
            arguments: [referenceID]
        )
        return owner.map(OwnershipClassification.account)
            ?? .init(kind: .ambiguous, owner: nil)
    }

    private static func optionalJobOwnership(
        jobID: String,
        database: Database
    ) throws -> OwnershipClassification? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT owner_account_id, ownership_kind FROM durable_jobs WHERE id = ?",
            arguments: [jobID]
        ) else { return nil }
        guard let kind = PersistedOwnershipKind(rawValue: row["ownership_kind"] as String) else {
            throw PlainpostError.validationFailed("The job ownership descriptor is invalid.")
        }
        let owner: String? = row["owner_account_id"]
        guard (kind == .account && owner != nil) || (kind != .account && owner == nil) else {
            throw PlainpostError.validationFailed("The job ownership descriptor is invalid.")
        }
        return OwnershipClassification(kind: kind, owner: owner)
    }

    private static func requiredJobOwnership(
        jobID: String,
        database: Database
    ) throws -> OwnershipClassification {
        guard let ownership = try optionalJobOwnership(jobID: jobID, database: database) else {
            throw PlainpostError.validationFailed("The artifact job is unavailable.")
        }
        return ownership
    }

    private static func requiredMailboxMutationOwner(
        messageID: String,
        database: Database
    ) throws -> String {
        guard try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE id = ?)",
            arguments: [messageID]
        ) == true else {
            throw PlainpostError.validationFailed("The mailbox operation message is unavailable.")
        }
        let owners = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT mm.account_id
                FROM mailbox_messages mm
                JOIN messages m ON m.id = mm.message_id
                WHERE mm.message_id = ?
                  AND (m.account_id IS NULL OR m.account_id = mm.account_id)
                """,
            arguments: [messageID]
        )
        guard owners.count == 1, let owner = owners.first else {
            throw PlainpostError.validationFailed("The mailbox operation owner could not be resolved.")
        }
        return owner
    }

    private static func archiveMembershipMatches(
        input: PlainpostMailboxArchiveInput,
        database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM mailbox_messages mm
                    JOIN messages m ON m.id = mm.message_id
                    WHERE mm.message_id = ?
                      AND mm.account_id = ?
                      AND mm.mailbox_path = ? COLLATE NOCASE
                      AND mm.uid_validity = ?
                      AND mm.uid = ?
                      AND (m.account_id IS NULL OR m.account_id = mm.account_id)
                )
                """,
            arguments: [
                input.messageID.rawValue, input.accountID.rawValue,
                input.sourceMailboxPath, input.uidValidity, input.uid,
            ]
        ) ?? false
    }

    private static func exactMailboxFlagMembership(
        _ input: PlainpostMailboxFlagInput,
        database: Database
    ) throws -> MailboxMessageMembership {
        guard let accountID = input.accountID,
              let mailboxPath = input.mailboxPath,
              let uidValidity = input.uidValidity,
              let uid = input.uid else {
            throw PlainpostError.validationFailed(
                "A mailbox flag requires an exact mailbox membership."
            )
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT mm.account_id, mm.mailbox_path, mm.uid_validity, mm.uid, mm.message_id
                FROM mailbox_messages mm
                JOIN messages m ON m.id = mm.message_id
                WHERE mm.message_id = ?
                  AND mm.account_id = ?
                  AND mm.mailbox_path = ? COLLATE NOCASE
                  AND mm.uid_validity = ?
                  AND mm.uid = ?
                  AND (m.account_id IS NULL OR m.account_id = mm.account_id)
                """,
            arguments: [
                input.messageID.rawValue, accountID.rawValue, mailboxPath, uidValidity, uid,
            ]
        ) else {
            throw PlainpostError.validationFailed(
                "The mailbox flag membership is unavailable or changed."
            )
        }
        return MailboxMessageMembership(
            accountID: AccountID(row["account_id"]),
            mailboxPath: row["mailbox_path"],
            uidValidity: row["uid_validity"],
            uid: row["uid"],
            messageID: MessageID(row["message_id"])
        )
    }

    private static func mailboxFlagIdempotencyKey(_ input: PlainpostMailboxFlagInput) -> String {
        "mailbox-flag:\(input.accountID?.rawValue ?? "missing-account"):\(input.mailboxPath ?? "missing-mailbox"):\(input.uidValidity.map(String.init) ?? "missing-validity"):\(input.uid.map(String.init) ?? "missing-uid"):\(input.messageID.rawValue):\(input.desiredSeen)\(input.expectedDirectSourceGeneration.map { ":direct-generation:\($0)" } ?? "")"
    }

    private static func canonicalMailboxFlagMembership(
        messageID: MessageID,
        accountID: AccountID,
        database: Database
    ) throws -> MailboxMessageMembership {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT mm.account_id, mm.mailbox_path, mm.uid_validity, mm.uid, mm.message_id
                FROM mailbox_messages mm
                JOIN messages m ON m.id = mm.message_id
                WHERE mm.message_id = ?
                  AND mm.account_id = ?
                  AND mm.mailbox_path = m.mailbox_path COLLATE NOCASE
                  AND (m.account_id IS NULL OR m.account_id = mm.account_id)
                """,
            arguments: [messageID.rawValue, accountID.rawValue]
        )
        guard rows.count == 1, let row = rows.first else {
            throw PlainpostError.validationFailed(
                "The canonical mailbox flag membership is unavailable or ambiguous."
            )
        }
        return MailboxMessageMembership(
            accountID: AccountID(row["account_id"]),
            mailboxPath: row["mailbox_path"],
            uidValidity: row["uid_validity"],
            uid: row["uid"],
            messageID: MessageID(row["message_id"])
        )
    }

    private static func artifactRecordOwnership(
        kind: String,
        recordID: String,
        database: Database
    ) throws -> OwnershipClassification? {
        if kind == "inbox-sync" {
            let ownership = try optionalAccountOwnership(
                table: "accounts", idColumn: "id", ownerColumn: "id",
                referenceID: recordID, database: database
            )
            return ownership.kind == .account ? ownership : nil
        }
        guard let operation = PlainpostAIOperationKind(rawValue: kind) else { return nil }
        switch operation {
        case .summarizeThread, .answerThreadQuestion, .draftReply:
            return try? OwnershipClassification.account(requiredConversationOwnerAccountID(
                forConversationKey: recordID,
                database: database
            ))
        case .summarizeMessage, .translateMessage, .classifyMessage:
            return try? OwnershipClassification.account(requiredMessageRelationOwner(
                messageID: recordID, database: database
            ))
        case .rewriteDraft:
            let ownership = try optionalAccountOwnership(
                table: "drafts", idColumn: "id", ownerColumn: "owner_account_id",
                referenceID: recordID, database: database
            )
            return ownership.kind == .account ? ownership : nil
        case .answerMailboxQuestion:
            let ownership = try optionalAccountOwnership(
                table: "accounts", idColumn: "id", ownerColumn: "id",
                referenceID: recordID, database: database
            )
            return ownership.kind == .account ? ownership : nil
        case .rebuildIndex:
            return .init(kind: .global, owner: nil)
        case .recategorizeInbox:
            return nil
        }
    }

    private static func validateResultArtifactOwnership(
        database: Database,
        jobID: String,
        resultArtifactID: String?
    ) throws {
        guard let resultArtifactID else { return }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT j.owner_account_id job_owner, j.ownership_kind job_kind,
                       a.owner_account_id artifact_owner, a.ownership_kind artifact_kind
                FROM durable_jobs j
                JOIN durable_operation_artifacts a ON a.id = ?
                WHERE j.id = ?
                """,
            arguments: [resultArtifactID, jobID]
        ) else {
            throw PlainpostError.validationFailed("The result artifact is unavailable.")
        }
        let jobOwner: String? = row["job_owner"]
        let artifactOwner: String? = row["artifact_owner"]
        let jobKind: String = row["job_kind"]
        let artifactKind: String = row["artifact_kind"]
        guard jobOwner == artifactOwner, jobKind == artifactKind else {
            throw PlainpostError.validationFailed("The result artifact ownership conflicts with its job.")
        }
    }

    private enum PersistedOwnershipKind: String {
        case account, global, shared, ambiguous
    }

    private struct OwnershipClassification {
        let kind: PersistedOwnershipKind
        let owner: String?

        static func account(_ owner: String?) -> Self {
            guard let owner else { return .init(kind: .ambiguous, owner: nil) }
            return .init(kind: .account, owner: owner)
        }
    }

    private static func validateStoredOwnership(
        table: String,
        identity: String,
        storedOwner: String?,
        storedKindRaw: String,
        derived: OwnershipClassification?
    ) throws -> OwnershipClassification {
        guard let storedKind = PersistedOwnershipKind(rawValue: storedKindRaw) else {
            throw PlainpostError.validationFailed("\(table) \(identity) has an invalid ownership kind.")
        }
        if let storedOwner {
            guard storedKind == .account || storedKind == .ambiguous else {
                throw PlainpostError.validationFailed("\(table) \(identity) conflicts with its explicit owner.")
            }
            if let derived {
                guard derived.kind == .account, derived.owner == storedOwner else {
                    throw PlainpostError.validationFailed("\(table) \(identity) conflicts with its explicit owner.")
                }
            }
            return .account(storedOwner)
        }
        guard storedKind != .account else {
            throw PlainpostError.validationFailed("\(table) \(identity) has an account descriptor without an owner.")
        }
        if let derived { return derived }
        if storedKind == .global || storedKind == .shared {
            return OwnershipClassification(kind: storedKind, owner: nil)
        }
        return OwnershipClassification(kind: .ambiguous, owner: nil)
    }

    private static func validateStoredArtifactOwnership(
        identity: String,
        storedOwner: String?,
        storedKindRaw: String,
        authoritative: OwnershipClassification?
    ) throws -> OwnershipClassification {
        guard let storedKind = PersistedOwnershipKind(rawValue: storedKindRaw) else {
            throw PlainpostError.validationFailed(
                "durable_operation_artifacts \(identity) has an invalid ownership kind."
            )
        }
        let normalizedStoredKind: PersistedOwnershipKind = storedOwner != nil && storedKind == .ambiguous
            ? .account
            : storedKind
        let stored = OwnershipClassification(kind: normalizedStoredKind, owner: storedOwner)
        let isValidStoredDescriptor = (normalizedStoredKind == .account && storedOwner != nil)
            || (normalizedStoredKind != .account && storedOwner == nil)
        guard isValidStoredDescriptor else {
            throw PlainpostError.validationFailed(
                "durable_operation_artifacts \(identity) has an invalid ownership descriptor."
            )
        }
        guard let authoritative else { return stored }
        if normalizedStoredKind == .ambiguous { return authoritative }
        guard stored.kind == authoritative.kind, stored.owner == authoritative.owner else {
            throw PlainpostError.validationFailed(
                "durable_operation_artifacts \(identity) conflicts with its authoritative owner."
            )
        }
        return stored
    }

    private static func reconcileOwnershipV46(_ database: Database) throws {
        for row in try Row.fetchAll(database, sql: "SELECT id, payload_json, owner_account_id, ownership_kind FROM drafts") {
            let id: String = row["id"]
            let derived: OwnershipClassification?
            do {
                let draft = try JSONDecoder().decode(Draft.self, from: Data((row["payload_json"] as String).utf8))
                derived = .account(draft.accountID.rawValue)
            } catch {
                derived = nil
            }
            let resolved = try validateStoredOwnership(
                table: "drafts", identity: id, storedOwner: row["owner_account_id"],
                storedKindRaw: row["ownership_kind"], derived: derived
            )
            try database.execute(
                sql: "UPDATE drafts SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        for row in try Row.fetchAll(database, sql: "SELECT id, kind, payload_json, owner_account_id, ownership_kind FROM durable_jobs") {
            let id: String = row["id"]
            let kindRaw: String = row["kind"]
            let storedOwner: String? = row["owner_account_id"]
            let storedKindRaw: String = row["ownership_kind"]
            let storedKind = PersistedOwnershipKind(rawValue: storedKindRaw)
            let migrationExplicit = storedKind.flatMap { kind -> OwnershipClassification? in
                guard storedOwner != nil || kind != .ambiguous else { return nil }
                return OwnershipClassification(kind: kind, owner: storedOwner)
            }
            let derived: OwnershipClassification?
            if let kind = PlainpostOperationKind(rawValue: kindRaw) {
                do {
                    derived = try operationOwnership(
                        kind: kind,
                        payloadJSON: row["payload_json"],
                        database: database,
                        resolutionMode: .migration(explicit: migrationExplicit)
                    )
                } catch {
                    if storedOwner != nil || storedKindRaw != PersistedOwnershipKind.ambiguous.rawValue {
                        throw PlainpostError.validationFailed(
                            "durable_jobs \(id) has an explicit descriptor but its typed payload cannot be decoded."
                        )
                    }
                    derived = nil
                }
            } else {
                if storedOwner != nil || storedKindRaw != PersistedOwnershipKind.ambiguous.rawValue {
                    throw PlainpostError.validationFailed(
                        "durable_jobs \(id) has an explicit descriptor but an unknown operation kind."
                    )
                }
                derived = nil
            }
            let resolved = try validateStoredOwnership(
                table: "durable_jobs", identity: id, storedOwner: storedOwner,
                storedKindRaw: storedKindRaw, derived: derived
            )
            try database.execute(
                sql: "UPDATE durable_jobs SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        for row in try Row.fetchAll(database, sql: "SELECT id, payload_json, owner_account_id, ownership_kind FROM send_requests") {
            let id: String = row["id"]
            let derived: OwnershipClassification?
            do {
                let request = try JSONDecoder().decode(
                    SendRequest.self,
                    from: Data((row["payload_json"] as String).utf8)
                )
                derived = .account(try String.fetchOne(
                    database,
                    sql: "SELECT owner_account_id FROM drafts WHERE id = ?",
                    arguments: [request.draftID.rawValue]
                ))
            } catch {
                derived = nil
            }
            let resolved = try validateStoredOwnership(
                table: "send_requests", identity: id, storedOwner: row["owner_account_id"],
                storedKindRaw: row["ownership_kind"], derived: derived
            )
            try database.execute(
                sql: "UPDATE send_requests SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        struct ScheduledAccountPayload: Decodable { let accountID: AccountID }
        for row in try Row.fetchAll(database, sql: "SELECT id, payload_json, owner_account_id, ownership_kind FROM operation_schedules") {
            let id: String = row["id"]
            let derived: ScheduledAccountPayload?
            do {
                derived = try JSONDecoder().decode(
                    ScheduledAccountPayload.self,
                    from: Data((row["payload_json"] as String).utf8)
                )
            } catch {
                derived = nil
            }
            let resolved = try validateStoredOwnership(
                table: "operation_schedules", identity: id, storedOwner: row["owner_account_id"],
                storedKindRaw: row["ownership_kind"],
                derived: derived.map { .account($0.accountID.rawValue) }
            )
            try database.execute(
                sql: "UPDATE operation_schedules SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        for row in try Row.fetchAll(
            database,
            sql: "SELECT id, kind, record_id, owner_account_id, ownership_kind FROM durable_operation_artifacts"
        ) {
            let id: String = row["id"]
            let kind: String = row["kind"]
            let recordID: String = row["record_id"]
            let linkedRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT owner_account_id, ownership_kind
                    FROM durable_jobs
                    WHERE result_artifact_id = ?
                    """,
                arguments: [id]
            )
            let linkedDescriptors = Set(linkedRows.map { linkedRow in
                "\(linkedRow["ownership_kind"] as String)|\((linkedRow["owner_account_id"] as String?) ?? "")"
            })
            guard linkedDescriptors.count <= 1 else {
                throw PlainpostError.validationFailed("durable_operation_artifacts \(id) has conflicting linked jobs.")
            }
            let linked: OwnershipClassification? = try linkedRows.first.map { linkedRow in
                guard let kind = PersistedOwnershipKind(rawValue: linkedRow["ownership_kind"] as String) else {
                    throw PlainpostError.validationFailed("durable_jobs linked to \(id) has invalid ownership.")
                }
                return OwnershipClassification(kind: kind, owner: linkedRow["owner_account_id"])
            }
            let recordOwner = try artifactRecordOwnership(
                kind: kind,
                recordID: recordID,
                database: database
            )
            let resolved = try validateStoredArtifactOwnership(
                identity: id,
                storedOwner: row["owner_account_id"],
                storedKindRaw: row["ownership_kind"],
                authoritative: linked ?? recordOwner
            )
            try database.execute(
                sql: "UPDATE durable_operation_artifacts SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        let relationalTables: [(String, String, String)] = [
            ("device_send_reviews", "review_id", "SELECT drafts.owner_account_id FROM drafts WHERE drafts.id = device_send_reviews.draft_id"),
        ]
        for (table, key, ownerSQL) in relationalTables {
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT \(key) row_key, owner_account_id, ownership_kind, (\(ownerSQL)) derived_owner FROM \(table)"
            )
            for row in rows {
                let identity: String = row["row_key"]
                let derivedOwner: String? = row["derived_owner"]
                let resolved = try validateStoredOwnership(
                    table: table, identity: identity, storedOwner: row["owner_account_id"],
                    storedKindRaw: row["ownership_kind"], derived: derivedOwner.map(OwnershipClassification.account)
                )
                try database.execute(
                    sql: "UPDATE \(table) SET owner_account_id = ?, ownership_kind = ? WHERE \(key) = ?",
                    arguments: [resolved.owner, resolved.kind.rawValue, identity]
                )
            }
        }

        for row in try Row.fetchAll(
            database,
            sql: "SELECT id, action, target_type, target_id, owner_account_id, ownership_kind FROM audit_entries"
        ) {
            let id: String = row["id"]
            let action: String = row["action"]
            let targetType: String = row["target_type"]
            let targetID: String = row["target_id"]
            let derived = try auditOwnership(
                action: action, targetType: targetType, targetID: targetID, database: database
            )
            let resolved = try validateStoredOwnership(
                table: "audit_entries", identity: id, storedOwner: row["owner_account_id"],
                storedKindRaw: row["ownership_kind"], derived: derived
            )
            try database.execute(
                sql: "UPDATE audit_entries SET owner_account_id = ?, ownership_kind = ? WHERE id = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, id]
            )
        }

        let rowIDOwnershipQueries: [(String, String)] = [
            ("smart_inbox_work_items", "SELECT account_id FROM messages WHERE id = smart_inbox_work_items.message_id"),
            ("mail_rule_run_items", "SELECT account_id"),
            ("device_compose_mutation_recovery_payloads", "SELECT owner_account_id FROM device_compose_mutation_receipts r WHERE r.device_id = device_compose_mutation_recovery_payloads.device_id AND r.idempotency_key = device_compose_mutation_recovery_payloads.idempotency_key"),
        ]
        for (table, ownerSQL) in rowIDOwnershipQueries {
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT rowid row_key, owner_account_id, ownership_kind, (\(ownerSQL)) derived_owner FROM \(table)"
            )
            for row in rows {
                let rowID: Int64 = row["row_key"]
                let derivedOwner: String? = row["derived_owner"]
                let resolved = try validateStoredOwnership(
                    table: table, identity: String(rowID), storedOwner: row["owner_account_id"],
                    storedKindRaw: row["ownership_kind"], derived: derivedOwner.map(OwnershipClassification.account)
                )
                try database.execute(
                    sql: "UPDATE \(table) SET owner_account_id = ?, ownership_kind = ? WHERE rowid = ?",
                    arguments: [resolved.owner, resolved.kind.rawValue, rowID]
                )
            }
        }

        for row in try Row.fetchAll(
            database,
            sql: "SELECT rowid row_key, device_id, idempotency_key, response_json, owner_account_id, ownership_kind FROM device_compose_mutation_receipts"
        ) {
            let rowID: Int64 = row["row_key"]
            let storedOwner: String? = row["owner_account_id"]
            var derived = storedOwner.map(OwnershipClassification.account)
            if storedOwner == nil, let responseJSON: String = row["response_json"] {
                let object: [String: Any]
                do {
                    object = try JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any] ?? [:]
                } catch {
                    derived = nil
                    let resolved = try validateStoredOwnership(
                        table: "device_compose_mutation_receipts", identity: String(rowID),
                        storedOwner: storedOwner, storedKindRaw: row["ownership_kind"], derived: derived
                    )
                    _ = resolved
                    continue
                }
                if let accountID = object["accountID"] as? String {
                    derived = .account(accountID)
                } else if let draftID = object["draftID"] as? String {
                    derived = .account(try String.fetchOne(
                        database, sql: "SELECT owner_account_id FROM drafts WHERE id = ?",
                        arguments: [draftID]
                    ))
                }
            }
            let resolved = try validateStoredOwnership(
                table: "device_compose_mutation_receipts", identity: String(rowID),
                storedOwner: storedOwner, storedKindRaw: row["ownership_kind"], derived: derived
            )
            try database.execute(
                sql: "UPDATE device_compose_mutation_receipts SET owner_account_id = ?, ownership_kind = ? WHERE rowid = ?",
                arguments: [resolved.owner, resolved.kind.rawValue, rowID]
            )
        }
    }

    private static func recreateOwnershipValidationTriggersV46(
        _ database: Database,
        tables: [String]
    ) throws {
        let legacyInferenceTriggers = [
            "smart_inbox_work_owner_after_insert", "mail_rule_run_item_owner_after_insert",
            "device_send_review_owner_after_insert", "operation_schedule_owner_after_insert",
            "durable_job_owner_after_insert", "durable_artifact_owner_after_insert",
            "audit_entry_owner_after_insert", "device_receipt_owner_after_insert",
            "device_receipt_owner_after_response", "device_recovery_owner_after_insert",
        ]
        for trigger in legacyInferenceTriggers {
            try database.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
        }
        for table in tables {
            for event in ["INSERT", "UPDATE"] {
                let suffix = event.lowercased()
                let trigger = "\(table)_ownership_validate_\(suffix)"
                try database.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
                try database.execute(sql: """
                    CREATE TRIGGER \(trigger)
                    BEFORE \(event) ON \(table)
                    WHEN NOT (
                        (NEW.ownership_kind = 'account' AND NEW.owner_account_id IS NOT NULL)
                        OR
                        (NEW.ownership_kind IN ('global', 'shared', 'ambiguous')
                         AND NEW.owner_account_id IS NULL)
                    )
                    BEGIN
                        SELECT RAISE(ABORT, 'invalid ownership descriptor');
                    END
                    """)
            }
        }
    }

    private static func migrateLegacyRecoveryCredentialAssociationsV46(_ database: Database) throws {
        try database.execute(sql: """
            INSERT OR IGNORE INTO device_compose_recovery_credentials (
                device_id, idempotency_key, credential_record_key, owner_account_id
            )
            SELECT receipts.device_id, receipts.idempotency_key,
                   'device-compose:' || receipts.idempotency_key || ':recovery-key',
                   receipts.owner_account_id
            FROM device_compose_mutation_receipts receipts
            WHERE receipts.owner_account_id IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM credential_ciphertexts credentials
                  WHERE credentials.record_key =
                      'device-compose:' || receipts.idempotency_key || ':recovery-key'
              )
              AND 1 = (
                  SELECT COUNT(*) FROM device_compose_mutation_receipts peers
                  WHERE peers.idempotency_key = receipts.idempotency_key
              );
            """)
    }

    private static func accountDeletionOwnership(
        accountID: AccountID,
        requiresLiveAccount: Bool,
        database: Database
    ) throws -> AccountDeletionOwnership {
        let liveAccountExists = try Row.fetchOne(
            database,
            sql: "SELECT id FROM accounts WHERE id = ?",
            arguments: [accountID.rawValue]
        ) != nil
        guard !requiresLiveAccount || liveAccountExists else {
            throw PlainpostError.notFound("Account not found.")
        }

        let ownerTables = [
            "drafts", "send_requests", "durable_jobs", "operation_schedules",
            "durable_operation_artifacts", "smart_inbox_work_items",
            "mail_rule_run_items", "audit_entries",
        ]
        for table in ownerTables where try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM \(table) WHERE ownership_kind = 'ambiguous'"
        ) ?? 0 > 0 {
            throw PlainpostError.validationFailed(
                "Account deletion is blocked by ambiguous local ownership in \(table)."
            )
        }

        let mailboxIDs = Set(try String.fetchAll(
            database,
            sql: "SELECT id FROM mailboxes WHERE account_id = ?",
            arguments: [accountID.rawValue]
        ))
        let threadIDs = Set(try String.fetchAll(
            database,
            sql: "SELECT id FROM threads WHERE account_id = ?",
            arguments: [accountID.rawValue]
        ))
        let messageIDs = Set(try String.fetchAll(
            database,
            sql: "SELECT id FROM messages WHERE account_id = ?",
            arguments: [accountID.rawValue]
        ))

        let draftIDs = try ownedDraftIDs(accountID: accountID, database: database)
        let sendRequestIDs = try ownedSendRequestIDs(
            accountID: accountID,
            draftIDs: draftIDs,
            database: database
        )
        let ruleIDs = Set(try String.fetchAll(
            database,
            sql: "SELECT id FROM mail_rules WHERE scope_account_id = ?",
            arguments: [accountID.rawValue]
        ))
        let labelIDs = Set(try String.fetchAll(
            database,
            sql: "SELECT id FROM mail_labels WHERE scope_account_id = ?",
            arguments: [accountID.rawValue]
        ))
        var referenceIDs: Set<String> = [accountID.rawValue]
        referenceIDs.formUnion(mailboxIDs)
        referenceIDs.formUnion(threadIDs)
        referenceIDs.formUnion(messageIDs)
        referenceIDs.formUnion(draftIDs)
        referenceIDs.formUnion(sendRequestIDs)
        referenceIDs.formUnion(ruleIDs)
        referenceIDs.formUnion(labelIDs)
        let jobIDs = try ownedJobIDs(
            accountID: accountID,
            referenceIDs: referenceIDs,
            messageIDs: messageIDs,
            database: database
        )
        let scheduleIDs = try ownedScheduleIDs(
            accountID: accountID,
            referenceIDs: referenceIDs,
            database: database
        )
        let artifactIDs = try ownedArtifactIDs(
            accountID: accountID,
            referenceIDs: referenceIDs.union(jobIDs).union(scheduleIDs),
            database: database
        )
        let auditEntryIDs = try ownedAuditEntryIDs(
            accountID: accountID,
            referenceIDs: referenceIDs
                .union(jobIDs)
                .union(scheduleIDs)
                .union(artifactIDs),
            database: database
        )
        return AccountDeletionOwnership(
            accountID: accountID,
            mailboxIDs: mailboxIDs,
            threadIDs: threadIDs,
            messageIDs: messageIDs,
            draftIDs: draftIDs,
            sendRequestIDs: sendRequestIDs,
            jobIDs: jobIDs,
            scheduleIDs: scheduleIDs,
            ruleIDs: ruleIDs,
            labelIDs: labelIDs,
            artifactIDs: artifactIDs,
            auditEntryIDs: auditEntryIDs
        )
    }

    private static func ownedDraftIDs(accountID: AccountID, database: Database) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: "SELECT id, payload_json FROM drafts WHERE owner_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            let payload: String = row["payload_json"]
            do {
                guard try JSONDecoder().decode(Draft.self, from: Data(payload.utf8)).accountID == accountID else {
                    throw PlainpostError.validationFailed("A draft owner does not match its payload.")
                }
                owned.insert(id)
            } catch {
                throw PlainpostError.validationFailed("An account-owned draft could not be decoded.")
            }
        }
        return owned
    }

    private static func ownedSendRequestIDs(
        accountID: AccountID,
        draftIDs: Set<String>,
        database: Database
    ) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: "SELECT id, payload_json FROM send_requests WHERE owner_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            let payload: String = row["payload_json"]
            do {
                let request = try JSONDecoder().decode(SendRequest.self, from: Data(payload.utf8))
                if draftIDs.contains(request.draftID.rawValue) {
                    owned.insert(id)
                }
            } catch {
                throw PlainpostError.validationFailed("An account-owned send request could not be decoded.")
            }
        }
        return owned
    }

    private static func ownedJobIDs(
        accountID: AccountID,
        referenceIDs: Set<String>,
        messageIDs _: Set<String>,
        database: Database
    ) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: """
                SELECT id
                FROM durable_jobs
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            owned.insert(id)
        }
        return owned
    }

    private static func ownedScheduleIDs(
        accountID: AccountID,
        referenceIDs: Set<String>,
        database: Database
    ) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: "SELECT id, kind, payload_json FROM operation_schedules WHERE owner_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            let rawKind: String = row["kind"]
            let payload: String = row["payload_json"]
            guard let kind = PlainpostOperationKind(rawValue: rawKind) else {
                throw PlainpostError.validationFailed("An account-owned schedule has an unknown kind.")
            }
            if try operationPayloadBelongs(
                kind: kind,
                payload: payload,
                accountID: accountID,
                referenceIDs: referenceIDs,
                malformedIsOwned: true
            ) {
                owned.insert(id)
            } else {
                throw PlainpostError.validationFailed("A schedule owner does not match its payload.")
            }
        }
        return owned
    }

    private static func operationPayloadBelongs(
        kind: PlainpostOperationKind,
        payload: String,
        accountID: AccountID,
        referenceIDs: Set<String>,
        malformedIsOwned: Bool
    ) throws -> Bool {
        do {
            switch kind {
            case .inboxSync, .historicalSync:
                return try JSONDecoder().decode(
                    PlainpostInboxSyncInput.self,
                    from: Data(payload.utf8)
                ).accountID == accountID
            case .aiOperation:
                let input = try JSONDecoder().decode(PlainpostAIOperationInput.self, from: Data(payload.utf8))
                if case .account(let scopedAccountID) = input.smartInboxRunRequest.scope,
                   scopedAccountID == accountID {
                    return true
                }
                return referenceIDs.contains(input.recordID)
            case .approvedDelivery, .denySend:
                let input = try JSONDecoder().decode(
                    PlainpostApprovalDecisionInput.self,
                    from: Data(payload.utf8)
                )
                return referenceIDs.contains(input.requestID.rawValue)
            case .mailboxFlag:
                let input = try JSONDecoder().decode(
                    PlainpostMailboxFlagInput.self,
                    from: Data(payload.utf8)
                )
                return referenceIDs.contains(input.messageID.rawValue)
            case .mailboxArchive:
                let input = try JSONDecoder().decode(
                    PlainpostMailboxArchiveInput.self,
                    from: Data(payload.utf8)
                )
                return input.accountID == accountID || referenceIDs.contains(input.messageID.rawValue)
            case .searchRebuild:
                return false
            }
        } catch {
            if malformedIsOwned {
                throw PlainpostError.validationFailed("An account-owned durable-operation input could not be decoded.")
            }
            return false
        }
    }

    private static func ownedArtifactIDs(
        accountID: AccountID,
        referenceIDs: Set<String>,
        database: Database
    ) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: "SELECT id FROM durable_operation_artifacts WHERE owner_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            owned.insert(id)
        }
        let ownedJobResults = try String.fetchAll(
            database,
            sql: "SELECT result_artifact_id FROM durable_jobs WHERE id IN (SELECT value FROM json_each(?)) AND result_artifact_id IS NOT NULL",
            arguments: [String(decoding: try JSONEncoder().encode(referenceIDs.sorted()), as: UTF8.self)]
        )
        owned.formUnion(ownedJobResults)
        let retainedReferences = Set(try String.fetchAll(
            database,
            sql: "SELECT result_artifact_id FROM durable_jobs WHERE id NOT IN (SELECT value FROM json_each(?)) AND result_artifact_id IS NOT NULL",
            arguments: [String(decoding: try JSONEncoder().encode(referenceIDs.sorted()), as: UTF8.self)]
        ))
        owned.subtract(retainedReferences)
        return owned
    }

    private static func ownedAuditEntryIDs(
        accountID: AccountID,
        referenceIDs: Set<String>,
        database: Database
    ) throws -> Set<String> {
        var owned: Set<String> = []
        for row in try Row.fetchAll(
            database,
            sql: "SELECT id FROM audit_entries WHERE owner_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        ) {
            let id: String = row["id"]
            owned.insert(id)
        }
        return owned
    }

    private static func deleteAccountData(
        plan: LocalAccountDeletion.Plan,
        database: Database
    ) throws {
        let accountID = plan.accountID.rawValue

        // Message, thread, mailbox, and search mutations are the first SQLite
        // writes and execute only after the accepted immutable plan is revalidated.
        try LocalAccountDeletion.executePlannedSurgeries(plan: plan, database: database)

        let jobIDs = Set(plan.directDeletion.jobIDs)
        try deleteRows(from: "durable_job_terminal_events", where: "job_id", matching: jobIDs, database: database)
        try deleteRows(from: "smart_inbox_incremental_follow_up_demands", where: "predecessor_job_id", matching: jobIDs, database: database)
        try deleteRows(from: "smart_inbox_incremental_follow_up_demands", where: "successor_job_id", matching: jobIDs, database: database)
        try deleteRows(from: "smart_inbox_promoted_successors", where: "predecessor_job_id", matching: jobIDs, database: database)
        try deleteRows(from: "smart_inbox_promoted_successors", where: "successor_job_id", matching: jobIDs, database: database)
        try deleteRows(from: "durable_operation_artifacts", where: "id", matching: Set(plan.directDeletion.artifactIDs), database: database)
        try deleteRows(from: "operation_schedules", where: "id", matching: Set(plan.directDeletion.scheduleIDs), database: database)

        try deleteRows(from: "durable_jobs", where: "id", matching: jobIDs, database: database)
        try database.execute(
            sql: "DELETE FROM mail_rule_message_actions WHERE account_id = ?",
            arguments: [accountID]
        )
        try deleteRows(from: "audit_entries", where: "id", matching: Set(plan.directDeletion.auditEntryIDs), database: database)

        try deleteRows(from: "send_requests", where: "id", matching: Set(plan.directDeletion.sendRequestIDs), database: database)
        try deleteRows(from: "drafts", where: "id", matching: Set(plan.directDeletion.draftIDs), database: database)
        try database.execute(sql: "DELETE FROM mailbox_sync_preferences WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM mailbox_sync_state WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM sync_preferences WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM account_sync_readiness WHERE account_id = ?", arguments: [accountID])
        try deleteRows(from: "mail_rules", where: "id", matching: Set(plan.directDeletion.ruleIDs), database: database)
        try deleteRows(from: "mail_labels", where: "id", matching: Set(plan.directDeletion.labelIDs), database: database)
        // Notification state is account-scoped and must be erased in the same
        // accepted deletion transaction as mail/account state.
        try database.execute(sql: "DELETE FROM mac_new_mail_events WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM mac_new_mail_deliveries WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM local_notification_publications WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM local_notification_watermarks WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM local_notification_mailboxes WHERE account_id = ?", arguments: [accountID])
        try database.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [accountID])
    }

    private static func deleteRows(
        from table: String,
        where column: String,
        matching values: Set<String>,
        database: Database
    ) throws {
        for value in values.sorted() {
            try database.execute(
                sql: "DELETE FROM \(table) WHERE \(column) = ?",
                arguments: [value]
            )
        }
    }

    package func readAccounts() throws -> [Account] {
        try fetchRows("SELECT id, display_name, email, username, sent_mailbox, imap_host, imap_port, smtp_host, smtp_port FROM accounts ORDER BY id;").map { row in
            Account(
                id: AccountID(row["id"]),
                displayName: row["display_name"],
                email: EmailAddress(row["email"]),
                username: row["username"],
                sentMailbox: row["sent_mailbox"],
                imapHost: row["imap_host"],
                imapPort: UInt16(row["imap_port"] as Int),
                smtpHost: row["smtp_host"],
                smtpPort: row["smtp_port"]
            )
        }
    }

    private func readMailboxes() throws -> [Mailbox] {
        try fetchRows("SELECT id, account_id, name, path, special_use FROM mailboxes ORDER BY id;").map { row in
            Mailbox(
                id: MailboxID(row["id"]),
                accountID: AccountID(row["account_id"]),
                name: row["name"],
                path: row["path"],
                specialUse: row["special_use"]
            )
        }
    }

    private func readThreads() throws -> [MailThread] {
        try fetchRows("SELECT id, account_id, subject_normalized, participant_emails FROM threads ORDER BY id;")
            .map(decodeThread)
    }

    private func decodeThread(_ row: Row) -> MailThread {
        let participantEmails: String = row["participant_emails"]
        return MailThread(
            id: ThreadID(row["id"]),
            accountID: AccountID(row["account_id"]),
            subjectNormalized: row["subject_normalized"],
            participantEmails: participantEmails.split(separator: "\n").map { EmailAddress(String($0)) }
        )
    }

    private func readMessages() throws -> [MessageSummary] {
        try fetchRows("SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text, body_html, smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted, sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email, to_emails, cc_emails FROM messages ORDER BY id;")
            .map(decodeMessage)
    }

    private func decodeMessage(_ row: Row) -> MessageSummary {
        let category: String = row["smart_category"]
        let labels: String = row["labels_json"]
        let referencesJSON: String = row["references_json"]
        let toEmails: String = row["to_emails"]
        let ccEmails: String = row["cc_emails"]
        let sentAt: Double? = row["sent_at"]
        return MessageSummary(
            id: MessageID(row["id"]),
            threadID: (row["thread_id"] as String?).map { ThreadID($0) },
            from: EmailAddress(row["from_email"]),
            fromDisplayName: row["from_display_name"],
            subject: row["subject"],
            preview: row["preview"],
            smartCategory: SmartCategory(rawValue: category) ?? .unknown,
            labels: parseLabelsJSON(labels),
            isSeen: row["is_seen"],
            mailboxPath: row["mailbox_path"],
            isDeleted: row["is_deleted"],
            body: row["body_text"],
            bodyHTML: row["body_html"],
            sentAt: sentAt.map(Date.init(timeIntervalSince1970:)),
            rfcMessageID: row["rfc_message_id"],
            inReplyTo: row["in_reply_to"],
            references: parseLabelsJSON(referencesJSON),
            replyTo: (row["reply_to_email"] as String?).map { EmailAddress($0) },
            to: toEmails.split(separator: "\n").map { EmailAddress(String($0)) },
            cc: ccEmails.split(separator: "\n").map { EmailAddress(String($0)) }
        ).flagged(row.hasColumn("is_flagged") ? row["is_flagged"] : false)
    }

    private func decodeMailboxListMessage(_ row: Row) -> MailboxListMessage {
        let category: String = row["smart_category"]
        let priority: String = row["smart_priority"]
        let labels: String = row["labels_json"]
        let sentAt: Double? = row["sent_at"]
        return MailboxListMessage(
            id: MessageID(row["id"]),
            threadID: (row["thread_id"] as String?).map { ThreadID($0) },
            from: EmailAddress(row["from_email"]),
            fromDisplayName: row["from_display_name"],
            subject: row["subject"],
            preview: row["preview"],
            smartCategory: SmartCategory(rawValue: category) ?? .unknown,
            smartPriority: SmartPriority(rawValue: priority) ?? .normal,
            smartRequiresAction: row["smart_requires_action"],
            smartConfidence: row["smart_confidence"],
            labels: parseLabelsJSON(labels),
            isSeen: row["is_seen"],
            mailboxPath: row["mailbox_path"],
            isDeleted: row["is_deleted"],
            sentAt: sentAt.map(Date.init(timeIntervalSince1970:)),
            accountID: row.hasColumn("owner_account_id")
                ? (row["owner_account_id"] as String?).map { AccountID($0) } : nil,
            isFlagged: row.hasColumn("is_flagged") ? row["is_flagged"] : false
        )
    }

    private func readAuditEntries() throws -> [AuditEntry] {
        try fetchRows("SELECT id, actor_id, action, target_type, target_id, result FROM audit_entries ORDER BY rowid;")
            .map(decodeAuditEntry)
    }

    private func decodeAuditEntry(_ row: Row) -> AuditEntry {
        AuditEntry(
            id: row["id"],
            actorID: row["actor_id"],
            action: row["action"],
            targetType: row["target_type"],
            targetID: row["target_id"],
            result: row["result"]
        )
    }

    private func saveDraft(_ draft: Draft) throws {
        try execute(
            """
            INSERT OR REPLACE INTO drafts (id, payload_json, owner_account_id, ownership_kind)
            VALUES (?, ?, ?, 'account');
            """,
            [
                draft.id.rawValue,
                try encodeJSON(draft),
                draft.accountID.rawValue,
            ]
        )
    }

    private func readDraft(id: DraftID) throws -> Draft? {
        guard let row = try fetchRows("SELECT payload_json FROM drafts WHERE id = ?;", [id.rawValue]).first else {
            return nil
        }
        return try decodeJSON(Draft.self, from: row["payload_json"])
    }

    private func readSendRequest(id: SendRequestID) throws -> SendRequest? {
        guard let row = try fetchRows("SELECT payload_json FROM send_requests WHERE id = ?;", [id.rawValue]).first else {
            return nil
        }
        return try decodeJSON(SendRequest.self, from: row["payload_json"])
    }

    private func readSendRequests() throws -> [SendRequest] {
        try fetchRows("SELECT payload_json FROM send_requests ORDER BY id;").map { row in
            try decodeJSON(SendRequest.self, from: row["payload_json"])
        }
    }

    private static func refreshSearchProjectionIfIndexable(
        messageID: MessageID,
        database: Database
    ) throws {
        let hasCanonicalAccount = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM messages m
                    WHERE m.id = ?
                      AND COALESCE(
                          NULLIF(m.account_id, ''),
                          (SELECT MIN(mm.account_id) FROM mailbox_messages mm WHERE mm.message_id = m.id),
                          (SELECT t.account_id FROM threads t WHERE t.id = m.thread_id LIMIT 1)
                      ) IS NOT NULL
                )
                """,
            arguments: [messageID.rawValue]
        ) ?? false
        if hasCanonicalAccount {
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: messageID,
                database: database
            )
        } else {
            try SQLiteMailSearchProjectionWriter.remove(
                messageID: messageID,
                database: database
            )
        }
    }

    private static func moveCanonicalMailboxMembership(
        messageID: MessageID,
        accountID requestedAccountID: AccountID?,
        sourceMailboxPath: String,
        destinationMailboxPath: String,
        database: Database
    ) throws -> Bool {
        guard let message = try Row.fetchOne(
            database,
            sql: """
                SELECT m.mailbox_path, m.account_id, m.thread_id, m.is_seen, m.sent_at,
                       COALESCE(
                           NULLIF(m.account_id, ''),
                           (SELECT MIN(mm.account_id) FROM mailbox_messages mm WHERE mm.message_id = m.id),
                           (SELECT t.account_id FROM threads t WHERE t.id = m.thread_id LIMIT 1)
                       ) AS resolved_account_id
                FROM messages m WHERE m.id = ?
                """,
            arguments: [messageID.rawValue]
        ) else {
            throw PlainpostError.notFound("Message not found.")
        }
        let canonicalMailboxPath: String = message["mailbox_path"]
        guard sourceMailboxPath.caseInsensitiveCompare(destinationMailboxPath) != .orderedSame else {
            return false
        }
        let resolvedAccountID: String? = message["resolved_account_id"]
        let accountID = requestedAccountID?.rawValue ?? resolvedAccountID
        guard let accountID, !accountID.isEmpty else {
            throw SQLiteMailSearchSchemaError.missingCanonicalAccount(messageID.rawValue)
        }

        let sourceMemberships = try Row.fetchAll(
            database,
            sql: """
                SELECT uid_validity, uid, flags, mod_sequence, internal_date, byte_size
                FROM mailbox_messages
                WHERE account_id = ? AND message_id = ?
                  AND mailbox_path = ? COLLATE NOCASE
                ORDER BY uid_validity, uid
                """,
            arguments: [accountID, messageID.rawValue, sourceMailboxPath]
        )
        let destinationExists = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mailbox_messages
                    WHERE account_id = ? AND message_id = ?
                      AND mailbox_path = ? COLLATE NOCASE
                )
                """,
            arguments: [accountID, messageID.rawValue, destinationMailboxPath]
        ) ?? false
        if sourceMemberships.isEmpty,
           canonicalMailboxPath.caseInsensitiveCompare(sourceMailboxPath) != .orderedSame {
            return false
        }

        if !destinationExists {
            if sourceMemberships.isEmpty {
                let localUID = try allocateLocalMailboxUID(
                    accountID: accountID,
                    mailboxPath: destinationMailboxPath,
                    database: database
                )
                let isSeen: Bool = message["is_seen"]
                try database.execute(
                    sql: """
                        INSERT INTO mailbox_messages (
                            account_id, mailbox_path, uid_validity, uid, message_id,
                            flags, internal_date
                        ) VALUES (?, ?, 0, ?, ?, ?, ?)
                        """,
                    arguments: [
                        accountID,
                        destinationMailboxPath,
                        localUID,
                        messageID.rawValue,
                        isSeen ? "\\Seen" : "",
                        message["sent_at"] as Double?,
                    ]
                )
            } else {
                for source in sourceMemberships {
                    var uidValidity: Int = source["uid_validity"]
                    var uid: Int = source["uid"]
                    let keyOccupied = try Bool.fetchOne(
                        database,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM mailbox_messages
                                WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                                  AND uid_validity = ? AND uid = ?
                            )
                            """,
                        arguments: [accountID, destinationMailboxPath, uidValidity, uid]
                    ) ?? false
                    if keyOccupied {
                        uidValidity = 0
                        uid = try allocateLocalMailboxUID(
                            accountID: accountID,
                            mailboxPath: destinationMailboxPath,
                            database: database
                        )
                    }
                    try database.execute(
                        sql: """
                            INSERT INTO mailbox_messages (
                                account_id, mailbox_path, uid_validity, uid, message_id,
                                flags, mod_sequence, internal_date, byte_size
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            accountID,
                            destinationMailboxPath,
                            uidValidity,
                            uid,
                            messageID.rawValue,
                            source["flags"] as String,
                            source["mod_sequence"] as Int?,
                            source["internal_date"] as Double?,
                            source["byte_size"] as Int?,
                        ]
                    )
                }
            }
        }

        try database.execute(
            sql: """
                DELETE FROM mailbox_messages
                WHERE account_id = ? AND message_id = ?
                  AND mailbox_path = ? COLLATE NOCASE
            """,
            arguments: [accountID, messageID.rawValue, sourceMailboxPath]
        )
        if canonicalMailboxPath.caseInsensitiveCompare(sourceMailboxPath) == .orderedSame {
            try database.execute(
                sql: "UPDATE messages SET mailbox_path = ?, account_id = ? WHERE id = ?",
                arguments: [destinationMailboxPath, accountID, messageID.rawValue]
            )
        }
        return true
    }

    /// Records a move to Trash that the provider confirmed on a path with no
    /// Direct source to check (the Mac's direct route for a Node-backed account
    /// in fallback). Keys the Trash copy like `.trash` in
    /// `applyConfirmedMailboxAction`, never with the old Inbox UID.
    public func recordConfirmedTrashMove(
        membership: MailboxMessageMembership,
        to trashMailbox: String,
        uidValidity: Int?,
        uid: Int?,
        duplicateUIDs: [Int] = [],
        actor: Actor
    ) throws -> MessageSummary {
        try recordConfirmedMove(
            membership: membership, to: trashMailbox, uidValidity: uidValidity, uid: uid,
            duplicateUIDs: duplicateUIDs, auditAction: "message.trash", actor: actor
        )
    }

    /// Records a provider-confirmed move (an archive or a move to Trash) on a
    /// path with no Direct source to check, keyed like `moveConfirmedMembership`.
    public func recordConfirmedMove(
        membership: MailboxMessageMembership,
        to trashMailbox: String,
        uidValidity: Int?,
        uid: Int?,
        duplicateUIDs: [Int] = [],
        auditAction: String = "message.move",
        actor: Actor
    ) throws -> MessageSummary {
        let message = try databasePool.write { database -> MessageSummary in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, thread_id, from_email, from_display_name, subject, preview, body_text,
                        body_html, smart_category, labels_json, is_seen, is_flagged, mailbox_path, is_deleted,
                        sent_at, rfc_message_id, in_reply_to, references_json, reply_to_email,
                        to_emails, cc_emails
                    FROM messages WHERE id = ? LIMIT 1
                    """,
                arguments: [membership.messageID.rawValue]
            ) else { throw ConfirmedMailboxActionConflict.membershipChanged }
            let current = decodeMessage(row)
            guard !current.isDeleted else { throw ConfirmedMailboxActionConflict.membershipChanged }
            let providerKey = uidValidity.flatMap { validity in uid.map { (uidValidity: validity, uid: $0) } }
            try Self.moveConfirmedMembership(
                membership, to: trashMailbox, providerKey: providerKey,
                duplicateUIDs: duplicateUIDs, database: database
            )
            try Self.refreshSearchProjectionIfIndexable(messageID: membership.messageID, database: database)
            try insertAudit(
                database: database, actorID: actor.id, action: auditAction,
                targetType: "message", targetID: membership.messageID.rawValue
            )
            return current.withMailboxPath(trashMailbox)
        }
        try? flushAuditOutbox()
        MailStoreChangeSignal.post(scope: .mailbox)
        return message
    }

    /// Moves a provider-confirmed membership to `destinationMailboxPath` under
    /// the provider's new key, or a local one (UIDVALIDITY 0, negative UID)
    /// when the key is unknown or already taken. Unlike
    /// `moveCanonicalMailboxMembership` it never carries the source UID over:
    /// in another mailbox that UID can name a different message.
    ///
    /// Only the moved copies leave the source mailbox: `membership` and the
    /// duplicate UIDs in `duplicateUIDs` (see `duplicateCopyUIDs`), plus any
    /// local-key copy there. A copy the server still holds stays, or the next
    /// sync would find its UID uncached and bring the message back.
    private static func moveConfirmedMembership(
        _ membership: MailboxMessageMembership,
        to destinationMailboxPath: String,
        providerKey: (uidValidity: Int, uid: Int)?,
        duplicateUIDs: [Int] = [],
        database: Database
    ) throws {
        let accountID = membership.accountID.rawValue
        let messageID = membership.messageID.rawValue
        guard let source = try Row.fetchOne(
            database,
            sql: """
                SELECT flags, internal_date, byte_size FROM mailbox_messages
                WHERE account_id = ? AND message_id = ? AND mailbox_path = ?
                  AND uid_validity = ? AND uid = ?
                """,
            arguments: [accountID, messageID, membership.mailboxPath, membership.uidValidity, membership.uid]
        ) else {
            throw ConfirmedMailboxActionConflict.membershipChanged
        }
        let destinationHasMessage = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mailbox_messages
                    WHERE account_id = ? AND message_id = ? AND mailbox_path = ?
                )
                """,
            arguments: [accountID, messageID, destinationMailboxPath]
        ) ?? false
        if !destinationHasMessage {
            var key = providerKey
            if let candidate = key {
                let occupied = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM mailbox_messages
                            WHERE account_id = ? AND mailbox_path = ? AND uid_validity = ? AND uid = ?
                        )
                        """,
                    arguments: [accountID, destinationMailboxPath, candidate.uidValidity, candidate.uid]
                ) ?? true
                if occupied { key = nil }
            }
            let resolved = try key ?? (
                uidValidity: 0,
                uid: allocateLocalMailboxUID(accountID: accountID, mailboxPath: destinationMailboxPath, database: database)
            )
            let flags = (source["flags"] as String? ?? "")
                .split(separator: " ")
                .filter { $0.caseInsensitiveCompare("\\Deleted") != .orderedSame }
                .joined(separator: " ")
            try database.execute(
                sql: """
                    INSERT INTO mailbox_messages (
                        account_id, mailbox_path, uid_validity, uid, message_id,
                        flags, internal_date, byte_size
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    accountID, destinationMailboxPath, resolved.uidValidity, resolved.uid, messageID,
                    flags, source["internal_date"] as Double?, source["byte_size"] as Int?,
                ]
            )
        }
        let movedUIDs = [membership.uid] + duplicateUIDs
        try database.execute(
            sql: """
                DELETE FROM mailbox_messages
                WHERE account_id = ? AND message_id = ? AND mailbox_path = ?
                  AND ((uid_validity = ? AND uid IN (\(databaseQuestionMarks(count: movedUIDs.count))))
                       OR uid_validity = 0)
                """,
            arguments: StatementArguments(
                [accountID, messageID, membership.mailboxPath, membership.uidValidity] as [DatabaseValueConvertible]
            ) + StatementArguments(movedUIDs)
        )
        let sourceKeepsACopy = try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mailbox_messages
                    WHERE account_id = ? AND message_id = ? AND mailbox_path = ?
                )
                """,
            arguments: [accountID, messageID, membership.mailboxPath]
        ) ?? false
        guard !sourceKeepsACopy else { return }
        try database.execute(
            sql: "UPDATE messages SET mailbox_path = ?, account_id = ? WHERE id = ? AND mailbox_path = ?",
            arguments: [destinationMailboxPath, accountID, messageID, membership.mailboxPath]
        )
    }

    private static func allocateLocalMailboxUID(
        accountID: String,
        mailboxPath: String,
        database: Database
    ) throws -> Int {
        let minimumUID = try Int.fetchOne(
            database,
            sql: """
                SELECT MIN(uid) FROM mailbox_messages
                WHERE account_id = ? AND mailbox_path = ? COLLATE NOCASE
                  AND uid_validity = 0 AND uid < 0
                """,
            arguments: [accountID, mailboxPath]
        ) ?? 0
        return minimumUID - 1
    }

    private func appendAudit(actorID: String, action: String, targetType: String, targetID: String) throws {
        try databasePool.write { database in
            try insertAudit(
                database: database,
                actorID: actorID,
                action: action,
                targetType: targetType,
                targetID: targetID
            )
        }
        try? flushAuditOutbox()
    }

    private func combinedAuditEntries() -> [AuditEntry] {
        let persisted = (try? auditLog.entries()) ?? []
        let pending = (try? readAuditEntries()) ?? []
        var seen = Set<String>()
        return (persisted + pending).filter { seen.insert($0.id).inserted }
    }

    private func flushAuditOutbox() throws {
        let batchSize = 500
        try auditLog.drainAll(
            loadNextBatch: { [databasePool] in
                try databasePool.read { database in
                    try Row.fetchAll(
                        database,
                        sql: "SELECT id, actor_id, action, target_type, target_id, result, occurred_at, owner_account_id FROM audit_entries ORDER BY rowid LIMIT ?",
                        arguments: [batchSize]
                    ).map { row in
                        let occurredAt = (row["occurred_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                        return PersistedAuditRecord(
                            entry: self.decodeAuditEntry(row),
                            occurredAt: occurredAt,
                            ownerAccountID: row["owner_account_id"]
                        )
                    }
                }
            },
            didPersist: { [databasePool] ids in
                guard !ids.isEmpty else { return }
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                try databasePool.write { database in
                    try database.execute(
                        sql: "DELETE FROM audit_entries WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(ids)
                    )
                }
            }
        )
    }

    private func execute(_ sql: String, _ values: [String?] = []) throws {
        do {
            try databasePool.write { database in
                try database.execute(sql: sql, arguments: StatementArguments(values))
            }
        } catch {
            throw databaseError(error)
        }
    }

    private static func addColumnIfMissing(
        database: Database,
        table: String,
        column: String,
        definition: String
    ) throws {
        guard try database.columns(in: table).contains(where: { $0.name == column }) == false else { return }
        try database.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func fetchRows(_ sql: String, _ values: [String?] = []) throws -> [Row] {
        do {
            return try databasePool.read { database in
                try Row.fetchAll(database, sql: sql, arguments: StatementArguments(values))
            }
        } catch {
            throw databaseError(error)
        }
    }

    func databaseError(_ error: Error) -> any Error {
        if let databaseError = error as? DatabaseError {
            let primaryResultCode = databaseError.extendedResultCode.primaryResultCode
            if primaryResultCode == .SQLITE_BUSY || primaryResultCode == .SQLITE_LOCKED {
                do {
                    try onTransientContention?()
                } catch {
                    return error
                }
                return SQLiteMailStoreError.transientContention
            }
        }
        return PlainpostError.validationFailed("Local database operation failed: \(error.localizedDescription)")
    }

    private static func mailboxSearchPattern(_ query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw PlainpostError.validationFailed("Invalid JSON payload.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private func labelsJSON(_ labels: [String]) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys])
    else {
        return "[]"
    }
    return String(decoding: data, as: UTF8.self)
}

private func searchableSenderValue(email: EmailAddress, displayName: String?) -> String {
    [email.rawValue, displayName?.trimmingCharacters(in: .whitespacesAndNewlines)]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " ")
}

private func sanitizedSearchSnippet(_ value: String) -> String {
    String(value.unicodeScalars.filter { scalar in
        scalar.value != 0x1E
            && scalar.value != 0x1F
            && !CharacterSet.controlCharacters.contains(scalar)
    })
}

private func parseLabelsJSON(_ json: String) -> [String] {
    guard
        let data = json.data(using: .utf8),
        let labels = try? JSONSerialization.jsonObject(with: data) as? [String]
    else {
        return []
    }
    return labels
}
