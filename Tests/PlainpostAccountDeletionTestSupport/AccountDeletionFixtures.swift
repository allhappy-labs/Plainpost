import XCTest
import SQLite3
import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations
import PlainpostTestSupport

/// Ownership fixtures shared only by storage and service acceptance tests.
public enum AccountDeletionFixtures {
    public struct AccountDeletionFixture: Sendable {
        public let deleted: Account
        public let retained: Account
        public let deletedDraftID: DraftID
        public let retainedDraftID: DraftID
        public let globalRule: MailRule
        public let deletedLabel: MailLabelDefinition
        public let retainedLabel: MailLabelDefinition
        public let retainedJobID: String
    }

    public static func makeAccountDeletionFixture(
        store: SQLiteMailStore,
        databaseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AccountDeletionFixture {
        let deleted = Account(
            id: AccountID("acc-delete-target"),
            displayName: "Delete me",
            email: EmailAddress("delete@example.com"),
            imapHost: "imap.delete.example",
            smtpHost: "smtp.delete.example"
        )
        let retained = Account(
            id: AccountID("acc-retained"),
            displayName: "Keep me",
            email: EmailAddress("retain@example.com"),
            imapHost: "imap.retain.example",
            smtpHost: "smtp.retain.example"
        )
        try store.cacheAccounts([deleted, retained])

        let deletedMailbox = Mailbox(
            id: MailboxID("mbx-delete-inbox"),
            accountID: deleted.id,
            name: "Inbox",
            path: "INBOX",
            specialUse: "\\\\Inbox"
        )
        let retainedMailbox = Mailbox(
            id: MailboxID("mbx-retained-inbox"),
            accountID: retained.id,
            name: "Inbox",
            path: "INBOX",
            specialUse: "\\\\Inbox"
        )
        try store.cacheMailboxes([deletedMailbox, retainedMailbox])

        let deletedThread = MailThread(
            id: ThreadID("thr-delete-target"),
            accountID: deleted.id,
            subjectNormalized: "delete target",
            participantEmails: [deleted.email, EmailAddress("sender@example.com")]
        )
        let retainedThread = MailThread(
            id: ThreadID("thr-retained"),
            accountID: retained.id,
            subjectNormalized: "retained",
            participantEmails: [retained.email, EmailAddress("sender@example.com")]
        )
        try store.cacheThreads([deletedThread, retainedThread])

        let deletedMessage = MessageSummary(
            id: MessageID("msg-delete-target"),
            threadID: deletedThread.id,
            from: EmailAddress("sender@example.com"),
            subject: "Local account fixture",
            preview: "Cached local mail",
            body: "Target cached body",
            smartCategory: .personal,
            sentAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let deletedAttachment = IncomingMessageAttachmentPayload(
            partPath: "2.1",
            filename: "target.pdf",
            mimeType: "application/pdf",
            data: Data("target attachment".utf8)
        )
        _ = try store.commitIncomingMessage(
            deletedMessage,
            metadata: IncomingMessageSearchMetadata(
                to: [deleted.email],
                cc: [],
                bcc: [],
                attachments: [.init(filename: deletedAttachment.filename, mimeType: deletedAttachment.mimeType)],
                messageIdentifiers: ["<target@example.com>"]
            ),
            attachments: [deletedAttachment],
            accountID: deleted.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            notificationEligible: false
        )
        let retainedMessage = MessageSummary(
            id: MessageID("msg-retained"),
            threadID: retainedThread.id,
            from: EmailAddress("sender@example.com"),
            subject: "Retained fixture",
            preview: "Retained cached mail",
            body: "Retained cached body",
            smartCategory: .personal,
            sentAt: Date(timeIntervalSince1970: 2_000_000_001)
        )
        _ = try store.commitIncomingMessage(
            retainedMessage,
            metadata: IncomingMessageSearchMetadata(
                to: [retained.email], cc: [], bcc: [], attachments: [], messageIdentifiers: []
            ),
            accountID: retained.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )
        let translation = CachedMessageTranslation(
            messageID: deletedMessage.id,
            targetLanguageID: "fr",
            sourceFingerprint: MailTranslationFingerprint.message(deletedMessage),
            providerID: "fixture-provider",
            modelID: "fixture-model",
            contractVersion: "fixture-v1",
            bodyKind: .plainText,
            translatedBody: "Corps cible",
            createdAt: Date(timeIntervalSince1970: 2_000_000_010),
            updatedAt: Date(timeIntervalSince1970: 2_000_000_010)
        )
        XCTAssertEqual(
            try store.compareAndSaveCachedTranslation(
                translation,
                expectedSourceFingerprint: translation.sourceFingerprint
            ),
            .saved,
            file: file, line: line
        )
        try store.replaceMailEmbeddingChunks(
            messageID: deletedMessage.id,
            providerID: "fixture-provider",
            modelID: "fixture-model",
            contentFingerprint: "target-embedding",
            chunks: [
                StoredMailEmbeddingChunk(
                    messageID: deletedMessage.id,
                    providerID: "fixture-provider",
                    modelID: "fixture-model",
                    contentFingerprint: "target-embedding",
                    ordinal: 0,
                    text: "Target local embedding",
                    vector: [0.25, -0.5]
                )
            ]
        )

        let deletedDraft = try store.createDraft(
            Draft(
                id: DraftID("drf-delete-target"),
                accountID: deleted.id,
                from: deleted.email,
                to: [EmailAddress("recipient@example.com")],
                cc: [],
                bcc: [],
                subject: "Delete draft",
                bodyPlain: "Local-only draft",
                createdBy: PlainpostFixtures.guiUser.id,
                aiGenerated: false,
                sourceThreadID: deletedThread.id
            ),
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.requestSend(draftID: deletedDraft.id, actor: PlainpostFixtures.guiUser, reason: nil)
        let retainedDraft = try store.createDraft(
            Draft(
                id: DraftID("drf-retained"),
                accountID: retained.id,
                from: retained.email,
                to: [EmailAddress("recipient@example.com")],
                cc: [],
                bcc: [],
                subject: "Retained draft",
                bodyPlain: "Retained local-only draft",
                createdBy: PlainpostFixtures.guiUser.id,
                aiGenerated: false,
                sourceThreadID: retainedThread.id
            ),
            actor: PlainpostFixtures.guiUser
        )
        _ = try store.requestSend(draftID: retainedDraft.id, actor: PlainpostFixtures.guiUser, reason: nil)
        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: deleted.id,
                downloadCompleteHistory: true,
                recentMessageLimit: 250,
                realTimeMonitoringEnabled: true
            )
        )
        try store.saveSyncPreferences(
            MailSyncPreferences(
                accountID: retained.id,
                downloadCompleteHistory: false,
                recentMessageLimit: 75,
                realTimeMonitoringEnabled: false
            )
        )
        try store.saveMailboxSyncPreference(
            MailboxSyncPreference(accountID: deleted.id, mailboxPath: "INBOX", mode: .complete)
        )
        _ = try store.recordMailboxGeneration(accountID: deleted.id, mailboxPath: "INBOX", uidValidity: 1)
        try store.recordMailboxSyncProgress(
            accountID: deleted.id,
            mailboxPath: "INBOX",
            phase: "messages",
            downloaded: 1,
            estimatedTotal: 1,
            complete: true,
            error: nil
        )

        let globalLabel = try MailLabelDefinition.validated(
            id: "label-global",
            title: "Global retained label",
            description: "Retained for all accounts",
            isSmartInboxEnabled: false,
            scope: .allAccounts
        )
        let deletedLabel = try MailLabelDefinition.validated(
            id: "label-delete-target",
            title: "Target local label",
            description: "Owned by the deleted account",
            isSmartInboxEnabled: false,
            scope: .account(deleted.id)
        )
        let retainedLabel = try MailLabelDefinition.validated(
            id: "label-retained",
            title: "Retained local label",
            description: "Owned by the retained account",
            isSmartInboxEnabled: false,
            scope: .account(retained.id)
        )
        try store.saveMailLabel(globalLabel)
        try store.saveMailLabel(deletedLabel)
        try store.saveMailLabel(retainedLabel)
        try store.addUserLabel(labelID: deletedLabel.id, to: deletedMessage.id, actor: PlainpostFixtures.guiUser)

        let globalRule = try MailRule.validated(
            id: "rule-global",
            name: "Global retained rule",
            scope: .allAccounts,
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.markAsRead]
        )
        let deletedRule = try MailRule.validated(
            id: "rule-delete-target",
            name: "Deleted account rule",
            scope: .account(deleted.id),
            conditions: [.init(field: .from, operator: .domainIs, value: "example.com")],
            actions: [.markAsRead]
        )
        try store.saveMailRule(globalRule)
        try store.saveMailRule(deletedRule)

        let deletedInput = PlainpostInboxSyncInput(accountID: deleted.id, trigger: .manual)
        let deletedJob = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(deletedInput), as: UTF8.self),
                idempotencyKey: "sync-delete-target"
            )
        )
        let retainedInput = PlainpostInboxSyncInput(accountID: retained.id, trigger: .manual)
        let retainedJob = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .inboxSync,
                payloadJSON: String(decoding: try JSONEncoder().encode(retainedInput), as: UTF8.self),
                idempotencyKey: "sync-retained"
            )
        )
        let deletedPayloadJSON = String(
            decoding: try JSONEncoder().encode(deletedInput),
            as: UTF8.self
        )
        let retainedPayloadJSON = String(
            decoding: try JSONEncoder().encode(retainedInput),
            as: UTF8.self
        )
        try executeSQL(
            """
            INSERT INTO smart_inbox_classification_cache (
                message_id, source_fingerprint, category, provider_id, model_id, classified_at, updated_at
            ) VALUES (
                'msg-delete-target', 'target-fingerprint', 'personal', 'fixture-provider', 'fixture-model', 1, 1
            );
            INSERT INTO smart_inbox_work_items (
                job_id, ordinal, message_id, source_fingerprint, state, updated_at,
                owner_account_id, ownership_kind
            ) VALUES (
                '\(deletedJob.id)',
                0, 'msg-delete-target', 'target-fingerprint', 'pending', 1,
                'acc-delete-target', 'account'
            );
            INSERT INTO smart_inbox_work_preparations (job_id, prepared_at)
                VALUES ('\(deletedJob.id)', 1);
            UPDATE sync_job_scopes
            SET scope_fingerprint = 'target-scope', mailbox_paths_json = '["INBOX"]',
                recent_message_limit = 250, download_complete_history = 1,
                incremental_only = 0, establishes_readiness = 1, reconciliation_generation = 0
            WHERE job_id = '\(deletedJob.id)';
            INSERT INTO operation_schedules (
                id, kind, payload_json, interval_seconds, next_run_at, enabled,
                owner_account_id, ownership_kind
            ) VALUES
                ('schedule-delete-target', 'inbox-sync', \(sqlLiteral(deletedPayloadJSON)), 300, 10, 1, 'acc-delete-target', 'account'),
                ('schedule-retained', 'inbox-sync', \(sqlLiteral(retainedPayloadJSON)), 300, 10, 1, 'acc-retained', 'account');
            INSERT INTO durable_operation_artifacts (id, kind, record_id, payload_json, created_at, owner_account_id, ownership_kind) VALUES
                ('artifact-delete-target', 'ai-operation', 'msg-delete-target', '{"accountID":"acc-delete-target"}', 1, 'acc-delete-target', 'account'),
                ('artifact-retained', 'ai-operation', 'msg-retained', '{"accountID":"acc-retained"}', 1, 'acc-retained', 'account');
            INSERT INTO audit_entries (id, actor_id, action, target_type, target_id, result, occurred_at, owner_account_id, ownership_kind) VALUES
                ('audit-delete-target', 'local-user', 'fixture.delete', 'account', 'acc-delete-target', '{"accountID":"acc-delete-target"}', 1, 'acc-delete-target', 'account'),
                ('audit-retained', 'local-user', 'fixture.keep', 'account', 'acc-retained', '{"accountID":"acc-retained"}', 1, 'acc-retained', 'account');
            INSERT INTO mail_rule_label_actions (rule_id, label_id, ordinal)
                VALUES ('rule-delete-target', 'label-delete-target', 0);
            INSERT INTO message_label_exclusions (message_id, label_id, created_at)
                VALUES ('msg-delete-target', 'label-delete-target', 1);
            INSERT INTO smart_inbox_label_catalog_snapshots (job_id, catalog_fingerprint, labels_json, created_at)
                VALUES ('\(deletedJob.id)', 'target-catalog', '["label-delete-target"]', 1);
            INSERT INTO durable_job_terminal_events (job_id) VALUES ('\(deletedJob.id)');
            INSERT INTO smart_inbox_incremental_follow_up_demands (
                predecessor_job_id, successor_job_id, payload_json, created_at
            ) VALUES ('\(deletedJob.id)', '\(deletedJob.id)', \(sqlLiteral(deletedPayloadJSON)), 1);
            INSERT INTO smart_inbox_promoted_successors (predecessor_job_id, successor_job_id)
                VALUES ('\(deletedJob.id)', '\(deletedJob.id)');
            INSERT INTO mail_rule_runs (id, rule_id, created_at, total_items, enqueued_items)
                VALUES ('run-delete-target', 'rule-delete-target', 1, 1, 1);
            INSERT INTO mail_rule_run_items (
                run_id, ordinal, message_id, account_id, actions_json, job_ids_json, state,
                owner_account_id, ownership_kind
            ) VALUES (
                'run-delete-target', 0, 'msg-delete-target', 'acc-delete-target', '["mark_as_read"]',
                '["\(deletedJob.id)"]', 'queued', 'acc-delete-target', 'account'
            );
            INSERT INTO mail_rule_message_actions (
                message_id, account_id, action, source_rule_ids_json, created_at
            ) VALUES (
                'msg-delete-target', 'acc-delete-target', 'mark_as_read', '["rule-delete-target"]', 1
            );
            INSERT INTO account_mail_sources (
                account_id, kind, mode, node_id, logical_mailbox_id, provider_identity,
                generation, mode_changed_at
            ) VALUES (
                'acc-delete-target', 'node_backed', 'node', '30000000-0000-4000-8000-000000000801',
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'acc-delete-target', 1, 1
            );
            INSERT INTO mail_intent_journal (
                operation_id, account_id, kind, route, state, message_id, draft_id,
                created_at, updated_at
            ) VALUES (
                '00000000-0000-4000-8000-00000000d31e', 'acc-delete-target', 'archive', 'node',
                'admitted', 'msg-delete-target', NULL, 1, 1
            );
            INSERT INTO smart_inbox_batch_profiles (
                provider_id, model_id, classifier_discriminator, max_message_count,
                max_prompt_characters, memory_ceiling_bytes, benchmarked_at
            ) VALUES ('global-provider', 'global-model', 'global-classifier', 100, 1000, NULL, 1);
            """,
            at: databaseURL
        )

        return AccountDeletionFixture(
            deleted: deleted,
            retained: retained,
            deletedDraftID: deletedDraft.id,
            retainedDraftID: retainedDraft.id,
            globalRule: globalRule,
            deletedLabel: deletedLabel,
            retainedLabel: retainedLabel,
            retainedJobID: retainedJob.id
        )
    }

    public static func assertNoPersistedReferences(_ identifiers: [String], databaseURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw PlainpostError.validationFailed("Could not inspect account-deletion fixture database.")
        }
        defer { sqlite3_close(database) }

        var tableStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            -1,
            &tableStatement,
            nil
        ) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not enumerate account-deletion fixture tables.")
        }
        defer { sqlite3_finalize(tableStatement) }

        var references: [String] = []
        while sqlite3_step(tableStatement) == SQLITE_ROW {
            guard let rawTableName = sqlite3_column_text(tableStatement, 0) else { continue }
            let tableName = String(cString: rawTableName)
            let escapedTableName = tableName.replacingOccurrences(of: "\"", with: "\"\"")
            var columnStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "PRAGMA table_info(\"\(escapedTableName)\")",
                -1,
                &columnStatement,
                nil
            ) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(columnStatement) }

            while sqlite3_step(columnStatement) == SQLITE_ROW {
                guard let rawColumnName = sqlite3_column_text(columnStatement, 1),
                      let rawColumnType = sqlite3_column_text(columnStatement, 2) else { continue }
                let columnName = String(cString: rawColumnName)
                let columnType = String(cString: rawColumnType).uppercased()
                guard columnType.contains("TEXT") || columnType.contains("BLOB") else { continue }
                let escapedColumnName = columnName.replacingOccurrences(of: "\"", with: "\"\"")
                var valueStatement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    database,
                    "SELECT \"\(escapedColumnName)\" FROM \"\(escapedTableName)\" WHERE \"\(escapedColumnName)\" IS NOT NULL",
                    -1,
                    &valueStatement,
                    nil
                ) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(valueStatement) }

                while sqlite3_step(valueStatement) == SQLITE_ROW {
                    let matches: Bool
                    if columnType.contains("BLOB") {
                        let count = Int(sqlite3_column_bytes(valueStatement, 0))
                        if let bytes = sqlite3_column_blob(valueStatement, 0), count > 0 {
                            let data = Data(bytes: bytes, count: count)
                            matches = String(data: data, encoding: .utf8).map { value in
                                identifiers.contains { value.contains($0) }
                            } ?? false
                        } else {
                            matches = false
                        }
                    } else if let rawValue = sqlite3_column_text(valueStatement, 0) {
                        let value = String(cString: rawValue)
                        let references = Set(identifiers)
                        matches = references.contains(value)
                            || identifiers.contains { value == "account:\($0)" }
                            || jsonContainsAnyReference(value, references: references)
                    } else {
                        matches = false
                    }
                    if matches {
                        references.append("\(tableName).\(columnName)")
                    }
                }
            }
        }
        XCTAssertTrue(references.isEmpty, "Persisted account references remain in: \(references)", file: file, line: line)
    }

    public static func assertNoAuditReferences(
        _ identifiers: [String],
        auditLogURL: URL
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let references = Set(identifiers)
        for data in try auditLogContents(at: auditLogURL).values {
            for line in data.split(separator: 0x0A) {
                let record = try decoder.decode(PersistedAuditRecord.self, from: Data(line))
                if references.contains(record.actorID)
                    || references.contains(record.targetID)
                    || references.contains(record.result)
                    || jsonContainsAnyReference(record.result, references: references) {
                    throw PlainpostError.validationFailed("Deleted-account audit record survived local purge.")
                }
            }
        }
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func auditLogContents(at auditLogURL: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for index in 0 ... 4 {
            let url = index == 0
                ? auditLogURL
                : URL(fileURLWithPath: "\(auditLogURL.path).\(index)")
            if FileManager.default.fileExists(atPath: url.path) {
                contents[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return contents
    }

    private static func jsonContainsAnyReference(_ value: String, references: Set<String>) -> Bool {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        return jsonObject(object, containsAny: references)
    }

    private static func jsonObject(_ object: Any, containsAny references: Set<String>) -> Bool {
        switch object {
        case let value as String:
            references.contains(value)
        case let values as [Any]:
            values.contains { jsonObject($0, containsAny: references) }
        case let values as [String: Any]:
            values.values.contains { jsonObject($0, containsAny: references) }
        default:
            false
        }
    }

    private static func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw PlainpostError.validationFailed("Could not open SQLite database.")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
            throw PlainpostError.validationFailed("Could not execute SQLite statement: \(message)")
        }
    }

}
