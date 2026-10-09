import CryptoKit
import Foundation
import GRDB
import PlainpostCore
import PlainpostOperations

enum LocalAccountDeletion {
    enum ParentDisposition: Equatable, Sendable {
        case retain
        case delete
    }

    struct Plan: Equatable, Sendable {
        let accountID: AccountID
        let directDeletion: DirectDeletion
        let messageSurgeries: [MessageSurgery]
        let smartInboxSurgeries: [SmartInboxSurgery]
        let ruleRunSurgeries: [RuleRunSurgery]
    }

    struct DirectDeletion: Equatable, Sendable {
        let mailboxIDs: [String]
        let threadIDs: [String]
        let draftIDs: [String]
        let sendRequestIDs: [String]
        let jobIDs: [String]
        let scheduleIDs: [String]
        let ruleIDs: [String]
        let labelIDs: [String]
        let artifactIDs: [String]
        let auditEntryIDs: [String]
    }

    struct MessageSurgery: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case deleteCanonical
            case preserveCanonical(
                accountID: AccountID,
                canonicalMailboxPath: String,
                detachFromThreadID: String?
            )
        }

        let messageID: String
        let targetMemberships: [MailboxMembership]
        let retainedMemberships: [RetainedMailboxMembership]
        let action: Action
    }

    struct MailboxMembership: Equatable, Sendable {
        let mailboxPath: String
        let uidValidity: Int
        let uid: Int
    }

    struct RetainedMailboxMembership: Equatable, Sendable {
        let accountID: AccountID
        let mailboxPath: String
        let uidValidity: Int
        let uid: Int
    }

    struct SmartInboxSurgery: Equatable, Sendable {
        struct ArtifactPreimage: Equatable, Sendable {
            let id: String
            let kind: String
            let recordID: String
            let payloadJSON: String
            let createdAt: Double
            let ownerAccountID: String?
            let ownershipKind: String
        }

        enum ResultArtifactDisposition: Equatable, Sendable {
            case none
            case rebuild(
                artifact: ArtifactPreimage,
                payload: PlainpostLocalAIArtifactPayload
            )
            case clearAndDelete(artifactID: String)
        }

        struct Progress: Equatable, Sendable {
            let total: Int
            let current: Int
            let categorized: Int
            let unchanged: Int
            let failed: Int
        }

        let jobID: String
        let parentDisposition: ParentDisposition
        let targetWorkOrdinals: [Int]
        let retainedWorkOrdinals: [Int]
        let workFingerprint: String
        let progress: Progress
        let retainedLabels: [MailLabelDefinition]
        let sourceCatalogFingerprint: String?
        let retainedCatalogFingerprint: String
        let resultArtifactDisposition: ResultArtifactDisposition
    }

    private struct SmartInboxWorkFingerprintEntry: Codable {
        let ordinal: Int
        let messageID: String
        let sourceFingerprint: String
        let state: String
        let category: String?
        let priority: String?
        let requiresAction: Bool?
        let confidence: Double?
        let errorMessage: String?
        let retryResetAttempt: Int
        let updatedAt: Double
        let labelMatchesJSON: String
        let catalogFingerprint: String
        let classifierDiscriminator: String
        let providerID: String
        let modelID: String?
        let writesEnrichedProjection: Bool
        let wasUpdated: Bool?
        let ownerAccountID: String?
        let ownershipKind: String
    }

    struct RuleRunSurgery: Equatable, Sendable {
        let runID: String
        let parentDisposition: ParentDisposition
        let targetItemOrdinals: [Int]
        let retainedItemOrdinals: [Int]
        let itemFingerprint: String
        let totalItems: Int
        let enqueuedItems: Int
    }

    private struct RuleRunItemFingerprintEntry: Codable {
        let ordinal: Int
        let messageID: String
        let accountID: String
        let actionsJSON: String
        let jobIDsJSON: String
        let state: String
        let errorMessage: String?
        let ownerAccountID: String?
        let ownershipKind: String
    }

    static func makePlan(
        accountID: AccountID,
        requiresLiveAccount: Bool,
        database: Database
    ) throws -> Plan {
        let accountExists = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ?)",
            arguments: [accountID.rawValue]
        ) == true
        guard !requiresLiveAccount || accountExists else {
            throw PlainpostError.notFound("Account not found.")
        }

        let descriptorTables = [
            "drafts", "send_requests", "durable_jobs", "operation_schedules",
            "durable_operation_artifacts", "smart_inbox_work_items",
            "mail_rule_run_items", "audit_entries",
        ]
        for table in descriptorTables {
            if try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE ownership_kind = 'ambiguous')"
            ) == true {
                throw PlainpostError.validationFailed(
                    "Account deletion is blocked by ambiguous local ownership in \(table)."
                )
            }
            if try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM \(table)
                        WHERE NOT (
                            (ownership_kind = 'account' AND owner_account_id IS NOT NULL)
                            OR
                            (ownership_kind IN ('global', 'shared', 'ambiguous')
                             AND owner_account_id IS NULL)
                        )
                    )
                    """
            ) == true {
                throw PlainpostError.validationFailed(
                    "Account deletion is blocked by an invalid ownership descriptor in \(table)."
                )
            }
        }

        let mailboxIDs = try String.fetchAll(
            database,
            sql: "SELECT id FROM mailboxes WHERE account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        )
        let threadIDs = try String.fetchAll(
            database,
            sql: "SELECT id FROM threads WHERE account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        )
        let draftIDs = try ownedDraftIDs(accountID: accountID, database: database)
        let sendRequestIDs = try ownedSendRequestIDs(
            accountID: accountID,
            draftIDs: Set(draftIDs),
            database: database
        )
        let jobIDs = try ownedJobIDs(accountID: accountID, database: database)
        let scheduleIDs = try ownedScheduleIDs(accountID: accountID, database: database)
        let ruleIDs = try String.fetchAll(
            database,
            sql: "SELECT id FROM mail_rules WHERE scope_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        )
        let labelIDs = try String.fetchAll(
            database,
            sql: "SELECT id FROM mail_labels WHERE scope_account_id = ? ORDER BY id",
            arguments: [accountID.rawValue]
        )
        let artifactIDs = try ownedIDs(
            table: "durable_operation_artifacts",
            accountID: accountID,
            database: database
        )
        let auditEntryIDs = try ownedIDs(
            table: "audit_entries",
            accountID: accountID,
            database: database
        )
        if try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM mailbox_messages memberships
                    LEFT JOIN messages ON messages.id = memberships.message_id
                    WHERE memberships.account_id = ? AND messages.id IS NULL
                )
                """,
            arguments: [accountID.rawValue]
        ) == true {
            throw PlainpostError.validationFailed(
                "A target mailbox membership references a missing canonical message."
            )
        }
        let candidateRows = try Row.fetchAll(
            database,
            sql: """
                SELECT DISTINCT messages.id, messages.account_id, messages.thread_id,
                    messages.mailbox_path
                FROM messages
                WHERE messages.account_id = ?
                   OR messages.thread_id IN (
                       SELECT id FROM threads WHERE account_id = ?
                   )
                   OR EXISTS (
                       SELECT 1 FROM mailbox_messages memberships
                       WHERE memberships.message_id = messages.id
                         AND memberships.account_id = ?
                   )
                ORDER BY messages.id
                """,
            arguments: [accountID.rawValue, accountID.rawValue, accountID.rawValue]
        )
        let targetThreadIDs = Set(threadIDs)
        let messageSurgeries = try candidateRows.map { row -> MessageSurgery in
            let messageID: String = row["id"]
            let canonicalAccountID: String? = row["account_id"]
            let threadID: String? = row["thread_id"]
            let currentCanonicalMailboxPath: String = row["mailbox_path"]
            let memberships = try Row.fetchAll(
                database,
                sql: """
                    SELECT account_id, mailbox_path, uid_validity, uid
                    FROM mailbox_messages
                    WHERE message_id = ?
                    ORDER BY account_id, mailbox_path COLLATE BINARY, uid_validity, uid
                    """,
                arguments: [messageID]
            )
            let targetMemberships = memberships.compactMap { membership -> MailboxMembership? in
                let owner: String = membership["account_id"]
                guard owner == accountID.rawValue else { return nil }
                return MailboxMembership(
                    mailboxPath: membership["mailbox_path"],
                    uidValidity: membership["uid_validity"],
                    uid: membership["uid"]
                )
            }
            let retainedMemberships = memberships.compactMap { membership -> RetainedMailboxMembership? in
                let owner: String = membership["account_id"]
                guard owner != accountID.rawValue else { return nil }
                return RetainedMailboxMembership(
                    accountID: AccountID(owner),
                    mailboxPath: membership["mailbox_path"],
                    uidValidity: membership["uid_validity"],
                    uid: membership["uid"]
                )
            }
            let retainedOwners = Set(retainedMemberships.map(\.accountID.rawValue))
            let action: MessageSurgery.Action
            if let retainedAccountID = retainedOwners.sorted().first {
                guard let retainedMembership = retainedMemberships.first(where: {
                    $0.accountID.rawValue == retainedAccountID
                }) else {
                    throw PlainpostError.validationFailed(
                        "A retained canonical message has inconsistent mailbox ownership."
                    )
                }
                action = .preserveCanonical(
                    accountID: AccountID(retainedAccountID),
                    canonicalMailboxPath: retainedMembership.mailboxPath,
                    detachFromThreadID: try retainedThreadDetachment(
                        threadID: threadID,
                        retainedAccountID: retainedAccountID,
                        targetThreadIDs: targetThreadIDs,
                        database: database
                    )
                )
            } else if canonicalAccountID != accountID.rawValue,
                      let canonicalAccountID,
                      !canonicalAccountID.isEmpty {
                action = .preserveCanonical(
                    accountID: AccountID(canonicalAccountID),
                    canonicalMailboxPath: try retainedCanonicalMailboxPath(
                        preferredPath: currentCanonicalMailboxPath,
                        accountID: canonicalAccountID,
                        database: database
                    ),
                    detachFromThreadID: try retainedThreadDetachment(
                        threadID: threadID,
                        retainedAccountID: canonicalAccountID,
                        targetThreadIDs: targetThreadIDs,
                        database: database
                    )
                )
            } else {
                action = .deleteCanonical
            }
            return MessageSurgery(
                messageID: messageID,
                targetMemberships: targetMemberships,
                retainedMemberships: retainedMemberships,
                action: action
            )
        }
        let smartInboxSurgeries = try makeSmartInboxSurgeries(
            accountID: accountID,
            database: database
        )
        let plannedDeletedJobIDs = Set(jobIDs).union(
            smartInboxSurgeries.compactMap {
                $0.parentDisposition == .delete ? $0.jobID : nil
            }
        )
        let plannedDeletedArtifactIDs = Set(artifactIDs).union(
            smartInboxSurgeries.compactMap { surgery in
                if case .clearAndDelete(let artifactID) = surgery.resultArtifactDisposition {
                    return artifactID
                }
                return nil
            }
        )
        let clearedArtifactReferences = Dictionary(
            uniqueKeysWithValues: smartInboxSurgeries.compactMap { surgery -> (String, String)? in
                if case .clearAndDelete(let artifactID) = surgery.resultArtifactDisposition {
                    return (surgery.jobID, artifactID)
                }
                return nil
            }
        )
        try validateArtifactReferences(
            deletedJobIDs: plannedDeletedJobIDs,
            deletedArtifactIDs: plannedDeletedArtifactIDs,
            clearedArtifactReferences: clearedArtifactReferences,
            database: database
        )
        let ruleRunSurgeries = try makeRuleRunSurgeries(
            accountID: accountID,
            deletedJobIDs: plannedDeletedJobIDs,
            database: database
        )
        return Plan(
            accountID: accountID,
            directDeletion: DirectDeletion(
                mailboxIDs: mailboxIDs,
                threadIDs: threadIDs,
                draftIDs: draftIDs,
                sendRequestIDs: sendRequestIDs,
                jobIDs: jobIDs,
                scheduleIDs: scheduleIDs,
                ruleIDs: ruleIDs,
                labelIDs: labelIDs,
                artifactIDs: artifactIDs,
                auditEntryIDs: auditEntryIDs
            ),
            messageSurgeries: messageSurgeries,
            smartInboxSurgeries: smartInboxSurgeries,
            ruleRunSurgeries: ruleRunSurgeries
        )
    }

    private static func retainedThreadDetachment(
        threadID: String?,
        retainedAccountID: String,
        targetThreadIDs: Set<String>,
        database: Database
    ) throws -> String? {
        guard let threadID else { return nil }
        if targetThreadIDs.contains(threadID) { return threadID }
        guard let threadOwner = try String.fetchOne(
            database,
            sql: "SELECT account_id FROM threads WHERE id = ?",
            arguments: [threadID]
        ) else {
            throw PlainpostError.validationFailed(
                "A retained canonical message references a missing thread."
            )
        }
        guard threadOwner == retainedAccountID else {
            throw PlainpostError.validationFailed(
                "A retained canonical message thread conflicts with its retained owner."
            )
        }
        return nil
    }

    private static func retainedCanonicalMailboxPath(
        preferredPath: String,
        accountID: String,
        database: Database
    ) throws -> String {
        guard let mailboxPath = try String.fetchOne(
            database,
            sql: """
                SELECT path FROM mailboxes
                WHERE account_id = ?
                ORDER BY CASE WHEN path = ? COLLATE BINARY THEN 0 ELSE 1 END,
                    path COLLATE BINARY, id
                LIMIT 1
                """,
            arguments: [accountID, preferredPath]
        ) else {
            throw PlainpostError.validationFailed(
                "A retained canonical message has no valid retained mailbox."
            )
        }
        return mailboxPath
    }

    static func executeMessageSurgery(
        plan: Plan,
        database: Database
    ) throws {
        try validatePlan(
            plan,
            mismatchMessage: "Account deletion plan no longer matches persisted message ownership.",
            database: database
        )
        try applyMessageSurgery(plan: plan, database: database)
    }

    static func executeSmartInboxSurgery(
        plan: Plan,
        database: Database
    ) throws {
        try validatePlan(
            plan,
            mismatchMessage: "Account deletion plan no longer matches persisted Smart Inbox ownership.",
            database: database
        )
        try applySmartInboxSurgery(plan: plan, database: database)
    }

    static func executeRuleRunSurgery(
        plan: Plan,
        database: Database
    ) throws {
        try validatePlan(
            plan,
            mismatchMessage: "Account deletion plan no longer matches persisted rule-run ownership.",
            database: database
        )
        try applyRuleRunSurgery(plan: plan, database: database)
    }

    static func executePlannedSurgeries(
        plan: Plan,
        database: Database
    ) throws {
        try validatePlan(
            plan,
            mismatchMessage: "Account deletion plan no longer matches persisted deletion state.",
            database: database
        )
        try applyMessageSurgery(plan: plan, database: database)
        try applySmartInboxSurgery(plan: plan, database: database)
        try applyRuleRunSurgery(plan: plan, database: database)
    }

    private static func validatePlan(
        _ plan: Plan,
        mismatchMessage: String,
        database: Database
    ) throws {
        let current = try makePlan(
            accountID: plan.accountID,
            requiresLiveAccount: false,
            database: database
        )
        guard current == plan else {
            throw PlainpostError.validationFailed(mismatchMessage)
        }
    }

    private static func applyMessageSurgery(
        plan: Plan,
        database: Database
    ) throws {
        for surgery in plan.messageSurgeries {
            for membership in surgery.targetMemberships {
                try database.execute(
                    sql: """
                        DELETE FROM mailbox_messages
                        WHERE account_id = ? AND mailbox_path = ? COLLATE BINARY
                          AND uid_validity = ? AND uid = ? AND message_id = ?
                        """,
                    arguments: [
                        plan.accountID.rawValue,
                        membership.mailboxPath,
                        membership.uidValidity,
                        membership.uid,
                        surgery.messageID,
                    ]
                )
            }
        }

        for surgery in plan.messageSurgeries {
            switch surgery.action {
            case .deleteCanonical:
                try removeSearchProjection(messageID: surgery.messageID, database: database)
                try database.execute(
                    sql: "DELETE FROM mail_embedding_chunks WHERE message_id = ?",
                    arguments: [surgery.messageID]
                )
                try database.execute(
                    sql: "DELETE FROM mailbox_messages WHERE message_id = ?",
                    arguments: [surgery.messageID]
                )
                try database.execute(
                    sql: "DELETE FROM messages WHERE id = ?",
                    arguments: [surgery.messageID]
                )

            case .preserveCanonical(
                let retainedAccountID,
                let canonicalMailboxPath,
                let detachFromThreadID
            ):
                try database.execute(
                    sql: """
                        UPDATE messages
                        SET account_id = ?,
                            thread_id = CASE WHEN thread_id = ? THEN NULL ELSE thread_id END,
                            mailbox_path = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        retainedAccountID.rawValue,
                        detachFromThreadID,
                        canonicalMailboxPath,
                        surgery.messageID,
                    ]
                )
                try refreshSearchProjection(
                    messageID: surgery.messageID,
                    mailboxPath: canonicalMailboxPath,
                    database: database
                )
            }
        }

        for threadID in plan.directDeletion.threadIDs {
            try database.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [threadID])
        }
        for mailboxID in plan.directDeletion.mailboxIDs {
            try database.execute(sql: "DELETE FROM mailboxes WHERE id = ?", arguments: [mailboxID])
        }
        if try database.tableExists("mail_search_state") {
            try database.execute(
                sql: "DELETE FROM mail_search_state WHERE account_id = ?",
                arguments: [plan.accountID.rawValue]
            )
        }
    }

    private static func applySmartInboxSurgery(
        plan: Plan,
        database: Database
    ) throws {
        for surgery in plan.smartInboxSurgeries {
            for ordinal in surgery.targetWorkOrdinals {
                try database.execute(
                    sql: """
                        DELETE FROM smart_inbox_work_items
                        WHERE job_id = ? AND ordinal = ? AND owner_account_id = ?
                        """,
                    arguments: [surgery.jobID, ordinal, plan.accountID.rawValue]
                )
            }

            switch surgery.parentDisposition {
            case .retain:
                try database.execute(
                    sql: """
                        UPDATE durable_jobs
                        SET progress_current = ?, progress_total = ?
                        WHERE id = ?
                        """,
                    arguments: [surgery.progress.current, surgery.progress.total, surgery.jobID]
                )
                let labelsJSON = String(
                    decoding: try JSONEncoder().encode(surgery.retainedLabels),
                    as: UTF8.self
                )
                try database.execute(
                    sql: """
                        UPDATE smart_inbox_label_catalog_snapshots
                        SET catalog_fingerprint = ?, labels_json = ?
                        WHERE job_id = ?
                        """,
                    arguments: [
                        surgery.retainedCatalogFingerprint,
                        labelsJSON,
                        surgery.jobID,
                    ]
                )
                try applyResultArtifactDisposition(
                    surgery.resultArtifactDisposition,
                    jobID: surgery.jobID,
                    database: database
                )

            case .delete:
                try applyResultArtifactDisposition(
                    surgery.resultArtifactDisposition,
                    jobID: surgery.jobID,
                    database: database
                )
                try deleteSmartInboxJobRelations(jobID: surgery.jobID, database: database)
                try database.execute(
                    sql: "DELETE FROM durable_jobs WHERE id = ?",
                    arguments: [surgery.jobID]
                )
            }
        }
    }

    private static func applyRuleRunSurgery(
        plan: Plan,
        database: Database
    ) throws {
        for surgery in plan.ruleRunSurgeries {
            for ordinal in surgery.targetItemOrdinals {
                try database.execute(
                    sql: """
                        DELETE FROM mail_rule_run_items
                        WHERE run_id = ? AND ordinal = ? AND owner_account_id = ?
                        """,
                    arguments: [surgery.runID, ordinal, plan.accountID.rawValue]
                )
            }

            switch surgery.parentDisposition {
            case .retain:
                try database.execute(
                    sql: """
                        UPDATE mail_rule_runs
                        SET total_items = ?, enqueued_items = ?
                        WHERE id = ?
                        """,
                    arguments: [surgery.totalItems, surgery.enqueuedItems, surgery.runID]
                )
            case .delete:
                try database.execute(
                    sql: "DELETE FROM mail_rule_runs WHERE id = ?",
                    arguments: [surgery.runID]
                )
            }
        }
    }

    private static func applyResultArtifactDisposition(
        _ disposition: SmartInboxSurgery.ResultArtifactDisposition,
        jobID: String,
        database: Database
    ) throws {
        switch disposition {
        case .none:
            return
        case .clearAndDelete(let artifactID):
            try database.execute(
                sql: "UPDATE durable_jobs SET result_artifact_id = NULL WHERE id = ? AND result_artifact_id = ?",
                arguments: [jobID, artifactID]
            )
            try database.execute(
                sql: "DELETE FROM durable_operation_artifacts WHERE id = ?",
                arguments: [artifactID]
            )
        case .rebuild(let artifact, let payload):
            let payloadJSON = String(
                decoding: try JSONEncoder().encode(payload),
                as: UTF8.self
            )
            try database.execute(
                sql: """
                    UPDATE durable_operation_artifacts
                    SET payload_json = ?
                    WHERE id = ? AND kind = ? AND record_id = ?
                      AND payload_json = ? AND created_at = ?
                      AND owner_account_id IS ? AND ownership_kind = ?
                    """,
                arguments: [
                    payloadJSON,
                    artifact.id,
                    artifact.kind,
                    artifact.recordID,
                    artifact.payloadJSON,
                    artifact.createdAt,
                    artifact.ownerAccountID,
                    artifact.ownershipKind,
                ]
            )
            guard database.changesCount == 1 else {
                throw PlainpostError.validationFailed(
                    "A shared Smart Inbox result artifact changed after planning."
                )
            }
        }
    }

    private static func deleteSmartInboxJobRelations(
        jobID: String,
        database: Database
    ) throws {
        try database.execute(
            sql: "DELETE FROM durable_job_terminal_events WHERE job_id = ?",
            arguments: [jobID]
        )
        for table in [
            "smart_inbox_incremental_follow_up_demands",
            "smart_inbox_promoted_successors",
        ] {
            try database.execute(
                sql: "DELETE FROM \(table) WHERE predecessor_job_id = ? OR successor_job_id = ?",
                arguments: [jobID, jobID]
            )
        }
    }

    private static func removeSearchProjection(
        messageID: String,
        database: Database
    ) throws {
        if try database.tableExists("mail_search_documents") {
            try SQLiteMailSearchProjectionWriter.remove(
                messageID: MessageID(messageID),
                database: database
            )
        }
        if try database.tableExists("message_fts") {
            try database.execute(
                sql: "DELETE FROM message_fts WHERE message_id = ?",
                arguments: [messageID]
            )
        }
        if try database.tableExists("message_search_metadata") {
            try database.execute(
                sql: "DELETE FROM message_search_metadata WHERE message_id = ?",
                arguments: [messageID]
            )
        }
    }

    private static func refreshSearchProjection(
        messageID: String,
        mailboxPath: String?,
        database: Database
    ) throws {
        if try database.tableExists("mail_search_documents") {
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: MessageID(messageID),
                database: database
            )
        }
        if let mailboxPath, try database.tableExists("message_search_metadata") {
            try database.execute(
                sql: "UPDATE message_search_metadata SET mailbox_path = ? WHERE message_id = ?",
                arguments: [mailboxPath, messageID]
            )
        }
        if try database.tableExists("message_fts"),
           try database.tableExists("message_search_metadata") {
            try database.execute(
                sql: "DELETE FROM message_fts WHERE message_id = ?",
                arguments: [messageID]
            )
            try database.execute(
                sql: """
                    INSERT INTO message_fts (
                        message_id, from_value, to_value, cc_value, bcc_value, subject,
                        body_text, attachment_filenames, message_identifiers, mailbox_path, labels
                    )
                    SELECT message_id, from_value, to_value, cc_value, bcc_value, subject,
                        body_text, attachment_filenames, message_identifiers, mailbox_path, labels
                    FROM message_search_metadata WHERE message_id = ?
                    """,
                arguments: [messageID]
            )
        }
    }

    private static func ownedIDs(
        table: String,
        accountID: AccountID,
        database: Database
    ) throws -> [String] {
        try String.fetchAll(
            database,
            sql: """
                SELECT id FROM \(table)
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        )
    }

    private static func ownedJobIDs(
        accountID: AccountID,
        database: Database
    ) throws -> [String] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, kind, payload_json FROM durable_jobs
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        ).map { row in
            let id: String = row["id"]
            try SQLiteMailStore.validateAccountDeletionJobPayload(
                kindRaw: row["kind"],
                payloadJSON: row["payload_json"],
                accountID: accountID,
                database: database
            )
            return id
        }
    }

    private static func ownedDraftIDs(
        accountID: AccountID,
        database: Database
    ) throws -> [String] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, payload_json FROM drafts
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        ).map { row in
            let id: String = row["id"]
            let payload: String = row["payload_json"]
            do {
                guard try JSONDecoder().decode(Draft.self, from: Data(payload.utf8)).accountID == accountID else {
                    throw PlainpostError.validationFailed("A draft owner does not match its payload.")
                }
            } catch let error as PlainpostError {
                throw error
            } catch {
                throw PlainpostError.validationFailed("An account-owned draft could not be decoded.")
            }
            return id
        }
    }

    private static func ownedSendRequestIDs(
        accountID: AccountID,
        draftIDs: Set<String>,
        database: Database
    ) throws -> [String] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, payload_json FROM send_requests
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        ).map { row in
            let id: String = row["id"]
            let payload: String = row["payload_json"]
            do {
                let request = try JSONDecoder().decode(SendRequest.self, from: Data(payload.utf8))
                guard draftIDs.contains(request.draftID.rawValue) else {
                    throw PlainpostError.validationFailed(
                        "An account-owned send request references a differently owned draft."
                    )
                }
            } catch let error as PlainpostError {
                throw error
            } catch {
                throw PlainpostError.validationFailed(
                    "An account-owned send request could not be decoded."
                )
            }
            return id
        }
    }

    private static func ownedScheduleIDs(
        accountID: AccountID,
        database: Database
    ) throws -> [String] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, kind, payload_json FROM operation_schedules
                WHERE ownership_kind = 'account' AND owner_account_id = ?
                ORDER BY id
                """,
            arguments: [accountID.rawValue]
        ).map { row in
            let id: String = row["id"]
            let kindRaw: String = row["kind"]
            let payload: String = row["payload_json"]
            guard let kind = PlainpostOperationKind(rawValue: kindRaw) else {
                throw PlainpostError.validationFailed(
                    "An account-owned schedule has an unknown kind."
                )
            }
            do {
                switch kind {
                case .inboxSync, .historicalSync:
                    guard try JSONDecoder().decode(
                        PlainpostInboxSyncInput.self,
                        from: Data(payload.utf8)
                    ).accountID == accountID else {
                        throw PlainpostError.validationFailed(
                            "A schedule owner does not match its payload."
                        )
                    }
                default:
                    throw PlainpostError.validationFailed(
                        "An account-owned schedule has an unsupported ownership kind."
                    )
                }
            } catch let error as PlainpostError {
                throw error
            } catch {
                throw PlainpostError.validationFailed(
                    "An account-owned durable-operation input could not be decoded."
                )
            }
            return id
        }
    }

    private static func validateArtifactReferences(
        deletedJobIDs: Set<String>,
        deletedArtifactIDs: Set<String>,
        clearedArtifactReferences: [String: String],
        database: Database
    ) throws {
        if try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM durable_jobs
                    WHERE result_artifact_id IS NOT NULL
                    GROUP BY result_artifact_id
                    HAVING COUNT(*) > 1
                )
                """
        ) == true {
            throw PlainpostError.validationFailed(
                "A durable result artifact is linked by multiple jobs."
            )
        }
        let references = try Row.fetchAll(
            database,
            sql: """
                SELECT jobs.id AS job_id, jobs.result_artifact_id,
                       jobs.owner_account_id AS job_owner,
                       jobs.ownership_kind AS job_ownership_kind,
                       artifacts.id AS artifact_exists,
                       artifacts.owner_account_id AS artifact_owner,
                       artifacts.ownership_kind AS artifact_ownership_kind
                FROM durable_jobs jobs
                LEFT JOIN durable_operation_artifacts artifacts
                  ON artifacts.id = jobs.result_artifact_id
                WHERE jobs.result_artifact_id IS NOT NULL
                ORDER BY jobs.id
                """
        )
        for reference in references {
            let jobID: String = reference["job_id"]
            let artifactID: String = reference["result_artifact_id"]
            let artifactExists: String? = reference["artifact_exists"]
            guard artifactExists != nil else {
                throw PlainpostError.validationFailed(
                    "A durable job references a missing result artifact."
                )
            }
            let jobOwner: String? = reference["job_owner"]
            let jobOwnershipKind: String = reference["job_ownership_kind"]
            let artifactOwner: String? = reference["artifact_owner"]
            let artifactOwnershipKind: String = reference["artifact_ownership_kind"]
            if !deletedJobIDs.contains(jobID),
               deletedArtifactIDs.contains(artifactID),
               clearedArtifactReferences[jobID] != artifactID {
                throw PlainpostError.validationFailed(
                    "A retained durable job references an account-owned artifact planned for deletion."
                )
            }
            if deletedJobIDs.contains(jobID), !deletedArtifactIDs.contains(artifactID) {
                throw PlainpostError.validationFailed(
                    "An account-owned durable job references a retained result artifact."
                )
            }
            guard jobOwner == artifactOwner,
                  jobOwnershipKind == artifactOwnershipKind else {
                throw PlainpostError.validationFailed(
                    "A durable job result artifact conflicts with its persisted ownership."
                )
            }
        }
    }

    private static func makeSmartInboxSurgeries(
        accountID: AccountID,
        database: Database
    ) throws -> [SmartInboxSurgery] {
        let jobIDs = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT job_id FROM smart_inbox_work_items
                WHERE owner_account_id = ?
                ORDER BY job_id
                """,
            arguments: [accountID.rawValue]
        )
        return try jobIDs.compactMap { jobID in
            guard let job = try Row.fetchOne(
                database,
                sql: """
                    SELECT owner_account_id, ownership_kind, result_artifact_id
                    FROM durable_jobs WHERE id = ?
                    """,
                arguments: [jobID]
            ) else {
                throw PlainpostError.validationFailed(
                    "A Smart Inbox work item references a missing durable job."
                )
            }
            let jobOwner: String? = job["owner_account_id"]
            let jobKind: String = job["ownership_kind"]
            let resultArtifactID: String? = job["result_artifact_id"]
            let work = try Row.fetchAll(
                database,
                sql: """
                    SELECT ordinal, message_id, source_fingerprint, state, category,
                        priority, requires_action, confidence, error_message,
                        retry_reset_attempt, updated_at, label_matches_json,
                        catalog_fingerprint, classifier_discriminator, provider_id,
                        model_id, writes_enriched_projection, was_updated,
                        owner_account_id, ownership_kind
                    FROM smart_inbox_work_items
                    WHERE job_id = ?
                    ORDER BY ordinal
                    """,
                arguments: [jobID]
            )
            let workFingerprint = try smartInboxWorkFingerprint(work)
            let validatedStates: [Int: (state: PlainpostSmartInboxWorkState, wasUpdated: Bool?)] = try Dictionary(
                uniqueKeysWithValues: work.map { row -> (Int, (PlainpostSmartInboxWorkState, Bool?)) in
                    let ordinal: Int = row["ordinal"]
                    let rawState: String = row["state"]
                    let wasUpdated: Bool? = row["was_updated"]
                    guard let state = PlainpostSmartInboxWorkState(rawValue: rawState),
                          (state == .applied) == (wasUpdated != nil) else {
                        throw PlainpostError.validationFailed(
                            "A shared Smart Inbox work item has invalid persisted state."
                        )
                    }
                    return (ordinal, (state, wasUpdated))
                }
            )
            let target = work.filter { ($0["owner_account_id"] as String?) == accountID.rawValue }
            let retained = work.filter { ($0["owner_account_id"] as String?) != accountID.rawValue }
            if jobKind == "account", jobOwner == accountID.rawValue {
                guard retained.isEmpty else {
                    throw PlainpostError.validationFailed(
                        "An account-owned Smart Inbox job contains retained work."
                    )
                }
                return SmartInboxSurgery(
                    jobID: jobID,
                    parentDisposition: .delete,
                    targetWorkOrdinals: target.map { $0["ordinal"] },
                    retainedWorkOrdinals: [],
                    workFingerprint: workFingerprint,
                    progress: .init(total: 0, current: 0, categorized: 0, unchanged: 0, failed: 0),
                    retainedLabels: [],
                    sourceCatalogFingerprint: nil,
                    retainedCatalogFingerprint: "",
                    resultArtifactDisposition: resultArtifactID.map {
                        .clearAndDelete(artifactID: $0)
                    } ?? .none
                )
            }
            guard jobKind == "shared", jobOwner == nil else {
                throw PlainpostError.validationFailed(
                    "Smart Inbox work ownership conflicts with its durable job."
                )
            }
            guard !retained.isEmpty else {
                return SmartInboxSurgery(
                    jobID: jobID,
                    parentDisposition: .delete,
                    targetWorkOrdinals: target.map { $0["ordinal"] },
                    retainedWorkOrdinals: [],
                    workFingerprint: workFingerprint,
                    progress: .init(total: 0, current: 0, categorized: 0, unchanged: 0, failed: 0),
                    retainedLabels: [],
                    sourceCatalogFingerprint: nil,
                    retainedCatalogFingerprint: "",
                    resultArtifactDisposition: resultArtifactID.map {
                        .clearAndDelete(artifactID: $0)
                    } ?? .none
                )
            }

            guard let catalog = try Row.fetchOne(
                database,
                sql: "SELECT catalog_fingerprint, labels_json FROM smart_inbox_label_catalog_snapshots WHERE job_id = ?",
                arguments: [jobID]
            ) else {
                throw PlainpostError.validationFailed(
                    "A shared Smart Inbox job is missing its label catalog."
                )
            }
            let sourceCatalogFingerprint: String = catalog["catalog_fingerprint"]
            let labelsJSON: String = catalog["labels_json"]
            let labels: [MailLabelDefinition]
            do {
                labels = try JSONDecoder().decode(
                    [MailLabelDefinition].self,
                    from: Data(labelsJSON.utf8)
                )
            } catch {
                throw PlainpostError.validationFailed(
                    "A shared Smart Inbox label catalog could not be decoded."
                )
            }
            let states = try retained.map { row -> (state: PlainpostSmartInboxWorkState, wasUpdated: Bool?) in
                let ordinal: Int = row["ordinal"]
                guard let state = validatedStates[ordinal] else {
                    throw PlainpostError.validationFailed(
                        "A shared Smart Inbox work item could not be planned deterministically."
                    )
                }
                return state
            }
            let retainedLabels = labels
                .filter { $0.scope.accountID != accountID }
                .sorted { $0.id < $1.id }
            let progress = SmartInboxSurgery.Progress(
                total: retained.count,
                current: states.filter { $0.state != .pending }.count,
                categorized: states.filter { $0.state == .applied && $0.wasUpdated == true }.count,
                unchanged: states.filter { $0.state == .applied && $0.wasUpdated == false }.count,
                failed: states.filter { $0.state == .failed }.count
            )
            let terminalStates: Set<PlainpostSmartInboxWorkState> = [.applied, .failed, .skipped]
            let resultDisposition: SmartInboxSurgery.ResultArtifactDisposition = try resultArtifactID.map {
                let artifactID = $0
                if states.allSatisfy({ terminalStates.contains($0.state) }) {
                    let artifact = try validateSmartInboxAggregateArtifact(
                        artifactID: artifactID,
                        database: database
                    )
                    return .rebuild(
                        artifact: artifact.preimage,
                        payload: rebuiltSmartInboxArtifactPayload(
                            artifact.payload,
                            progress: progress
                        )
                    )
                }
                return .clearAndDelete(artifactID: artifactID)
            } ?? .none
            return SmartInboxSurgery(
                jobID: jobID,
                parentDisposition: .retain,
                targetWorkOrdinals: target.map { $0["ordinal"] },
                retainedWorkOrdinals: retained.map { $0["ordinal"] },
                workFingerprint: workFingerprint,
                progress: progress,
                retainedLabels: retainedLabels,
                sourceCatalogFingerprint: sourceCatalogFingerprint,
                retainedCatalogFingerprint: try SQLiteMailStore.smartInboxCatalogFingerprint(
                    retainedLabels
                ),
                resultArtifactDisposition: resultDisposition
            )
        }
    }

    private static func smartInboxWorkFingerprint(_ rows: [Row]) throws -> String {
        let entries = rows.map { row in
            SmartInboxWorkFingerprintEntry(
                ordinal: row["ordinal"],
                messageID: row["message_id"],
                sourceFingerprint: row["source_fingerprint"],
                state: row["state"],
                category: row["category"],
                priority: row["priority"],
                requiresAction: row["requires_action"],
                confidence: row["confidence"],
                errorMessage: row["error_message"],
                retryResetAttempt: row["retry_reset_attempt"],
                updatedAt: row["updated_at"],
                labelMatchesJSON: row["label_matches_json"],
                catalogFingerprint: row["catalog_fingerprint"],
                classifierDiscriminator: row["classifier_discriminator"],
                providerID: row["provider_id"],
                modelID: row["model_id"],
                writesEnrichedProjection: row["writes_enriched_projection"],
                wasUpdated: row["was_updated"],
                ownerAccountID: row["owner_account_id"],
                ownershipKind: row["ownership_kind"]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(entries))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func rebuiltSmartInboxArtifactPayload(
        _ payload: PlainpostLocalAIArtifactPayload,
        progress: SmartInboxSurgery.Progress
    ) -> PlainpostLocalAIArtifactPayload {
        PlainpostLocalAIArtifactPayload(
            text: payload.text,
            items: payload.items,
            modelID: payload.modelID,
            localOnly: payload.localOnly,
            resultRecordID: payload.resultRecordID,
            category: payload.category,
            confidence: payload.confidence,
            indexedMessageCount: payload.indexedMessageCount,
            categorizedMessageCount: progress.categorized,
            unchangedMessageCount: progress.unchanged,
            failedMessageCount: progress.failed,
            sources: payload.sources,
            insufficientEvidence: payload.insufficientEvidence,
            retrievalMode: payload.retrievalMode,
            translatedBodyKind: payload.translatedBodyKind,
            translatedBody: payload.translatedBody,
            sourceFingerprint: payload.sourceFingerprint
        )
    }

    private static func validateSmartInboxAggregateArtifact(
        artifactID: String,
        database: Database
    ) throws -> (
        preimage: SmartInboxSurgery.ArtifactPreimage,
        payload: PlainpostLocalAIArtifactPayload
    ) {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, kind, record_id, payload_json, created_at,
                    owner_account_id, ownership_kind
                FROM durable_operation_artifacts WHERE id = ?
                """,
            arguments: [artifactID]
        ) else {
            throw PlainpostError.validationFailed(
                "A shared Smart Inbox job references a missing result artifact."
            )
        }
        let id: String = row["id"]
        let kind: String = row["kind"]
        let recordID: String = row["record_id"]
        let payload: String = row["payload_json"]
        let createdAt: Double = row["created_at"]
        let ownerAccountID: String? = row["owner_account_id"]
        let ownershipKind: String = row["ownership_kind"]
        guard kind == PlainpostAIOperationKind.recategorizeInbox.rawValue,
              let decoded = try? JSONDecoder().decode(
                  PlainpostLocalAIArtifactPayload.self,
                  from: Data(payload.utf8)
              ) else {
            throw PlainpostError.validationFailed(
                "A shared Smart Inbox result artifact could not be rebuilt safely."
            )
        }
        return (
            SmartInboxSurgery.ArtifactPreimage(
                id: id,
                kind: kind,
                recordID: recordID,
                payloadJSON: payload,
                createdAt: createdAt,
                ownerAccountID: ownerAccountID,
                ownershipKind: ownershipKind
            ),
            decoded
        )
    }

    private static func makeRuleRunSurgeries(
        accountID: AccountID,
        deletedJobIDs: Set<String>,
        database: Database
    ) throws -> [RuleRunSurgery] {
        let runIDs = try String.fetchAll(
            database,
            sql: """
                SELECT DISTINCT run_id FROM mail_rule_run_items
                WHERE owner_account_id = ?
                ORDER BY run_id
                """,
            arguments: [accountID.rawValue]
        )
        return try runIDs.compactMap { runID in
            guard let run = try Row.fetchOne(
                database,
                sql: """
                    SELECT rules.scope_account_id
                    FROM mail_rule_runs runs
                    JOIN mail_rules rules ON rules.id = runs.rule_id
                    WHERE runs.id = ?
                    """,
                arguments: [runID]
            ) else {
                throw PlainpostError.validationFailed(
                    "A mail rule run item references a missing rule run."
                )
            }
            let scopeAccountID: String? = run["scope_account_id"]
            let items = try Row.fetchAll(
                database,
                sql: """
                    SELECT ordinal, message_id, account_id, actions_json, job_ids_json,
                           state, error_message, owner_account_id, ownership_kind
                    FROM mail_rule_run_items
                    WHERE run_id = ?
                    ORDER BY ordinal
                    """,
                arguments: [runID]
            )
            let itemFingerprint = try ruleRunItemFingerprint(items)
            let target = items.filter { ($0["owner_account_id"] as String?) == accountID.rawValue }
            let retained = items.filter { ($0["owner_account_id"] as String?) != accountID.rawValue }
            if scopeAccountID == accountID.rawValue {
                guard retained.isEmpty else {
                    throw PlainpostError.validationFailed(
                        "An account-scoped mail rule run contains retained items."
                    )
                }
                return RuleRunSurgery(
                    runID: runID,
                    parentDisposition: .delete,
                    targetItemOrdinals: target.map { $0["ordinal"] },
                    retainedItemOrdinals: [],
                    itemFingerprint: itemFingerprint,
                    totalItems: 0,
                    enqueuedItems: 0
                )
            }
            guard scopeAccountID == nil else {
                throw PlainpostError.validationFailed(
                    "A mail rule run item conflicts with its scoped rule."
                )
            }
            guard !retained.isEmpty else {
                return RuleRunSurgery(
                    runID: runID,
                    parentDisposition: .delete,
                    targetItemOrdinals: target.map { $0["ordinal"] },
                    retainedItemOrdinals: [],
                    itemFingerprint: itemFingerprint,
                    totalItems: 0,
                    enqueuedItems: 0
                )
            }
            for item in retained {
                let jobsJSON: String = item["job_ids_json"]
                let referencedJobs: [String]
                do {
                    referencedJobs = try JSONDecoder().decode(
                        [String].self,
                        from: Data(jobsJSON.utf8)
                    )
                } catch {
                    throw PlainpostError.validationFailed(
                        "A retained mail rule run item has malformed job references."
                    )
                }
                guard deletedJobIDs.isDisjoint(with: referencedJobs) else {
                    throw PlainpostError.validationFailed(
                        "A retained mail rule run item references a job planned for deletion."
                    )
                }
                if !referencedJobs.isEmpty {
                    let encodedReferences = String(
                        decoding: try JSONEncoder().encode(referencedJobs),
                        as: UTF8.self
                    )
                    let found = try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM durable_jobs WHERE id IN (SELECT value FROM json_each(?))",
                        arguments: [encodedReferences]
                    ) ?? 0
                    guard found == Set(referencedJobs).count else {
                        throw PlainpostError.validationFailed(
                            "A retained mail rule run item references a missing job."
                        )
                    }
                }
            }
            return RuleRunSurgery(
                runID: runID,
                parentDisposition: .retain,
                targetItemOrdinals: target.map { $0["ordinal"] },
                retainedItemOrdinals: retained.map { $0["ordinal"] },
                itemFingerprint: itemFingerprint,
                totalItems: retained.count,
                enqueuedItems: retained.filter {
                    let state: String = $0["state"]
                    return state == "queued" || state == "enqueued" || state == "completed"
                }.count
            )
        }
    }

    private static func ruleRunItemFingerprint(_ rows: [Row]) throws -> String {
        let entries = rows.map { row in
            RuleRunItemFingerprintEntry(
                ordinal: row["ordinal"],
                messageID: row["message_id"],
                accountID: row["account_id"],
                actionsJSON: row["actions_json"],
                jobIDsJSON: row["job_ids_json"],
                state: row["state"],
                errorMessage: row["error_message"],
                ownerAccountID: row["owner_account_id"],
                ownershipKind: row["ownership_kind"]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(entries))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
