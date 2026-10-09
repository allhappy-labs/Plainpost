import Foundation
import GRDB
import PlainpostCore

package struct SQLiteMailSearchRetainedMetadata: Sendable {
    package let to: String
    package let cc: String
    package let bcc: String
    package let filenames: String
    package let attachments: [IncomingMessageAttachmentMetadata]
    package let identifiers: String

    package init(
        to: String,
        cc: String,
        bcc: String,
        filenames: String,
        attachments: [IncomingMessageAttachmentMetadata],
        identifiers: String
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.filenames = filenames
        self.attachments = attachments
        self.identifiers = identifiers
    }

    fileprivate static let empty = SQLiteMailSearchRetainedMetadata(
        to: "",
        cc: "",
        bcc: "",
        filenames: "",
        attachments: [],
        identifiers: ""
    )
}

package enum SQLiteMailSearchProjectionWriter {
    package static func upsert(
        messageID: MessageID,
        metadata: IncomingMessageSearchMetadata?,
        retainedMetadata: SQLiteMailSearchRetainedMetadata? = nil,
        database: Database
    ) throws {
        try upsert(
            messageID: messageID,
            metadata: metadata,
            retainedMetadata: retainedMetadata,
            persistsAttachmentMetadata: true,
            database: database
        )
    }

    package static func upsertV22Migration(
        messageID: MessageID,
        retainedMetadata: SQLiteMailSearchRetainedMetadata?,
        database: Database
    ) throws {
        try upsert(
            messageID: messageID,
            metadata: nil,
            retainedMetadata: retainedMetadata,
            persistsAttachmentMetadata: false,
            database: database
        )
    }

    private static func upsert(
        messageID: MessageID,
        metadata: IncomingMessageSearchMetadata?,
        retainedMetadata: SQLiteMailSearchRetainedMetadata?,
        persistsAttachmentMetadata: Bool,
        database: Database
    ) throws {
        guard let message = try Row.fetchOne(
            database,
            sql: """
                WITH resolved_message AS (
                    SELECT
                        m.*,
                        COALESCE(
                            NULLIF(m.account_id, ''),
                            (SELECT MIN(mm.account_id) FROM mailbox_messages mm WHERE mm.message_id = m.id),
                            (SELECT t.account_id FROM threads t WHERE t.id = m.thread_id LIMIT 1)
                        ) AS resolved_account_id
                    FROM messages m
                    WHERE m.id = ?
                )
                SELECT
                    m.id, m.account_id, m.thread_id, m.from_email, m.from_display_name,
                    m.subject, m.preview, m.body_text, m.labels_json, m.is_seen,
                    m.is_deleted, m.sent_at, m.to_emails, m.cc_emails,
                    m.resolved_account_id,
                    COALESCE(
                        m.sent_at,
                        (
                            SELECT MAX(mm.internal_date)
                            FROM mailbox_messages mm
                            WHERE mm.message_id = m.id
                              AND mm.account_id = m.resolved_account_id
                        ),
                        0
                    ) AS resolved_sort_date
                FROM resolved_message m
                """,
            arguments: [messageID.rawValue]
        ) else {
            throw SQLiteMailSearchSchemaError.missingCanonicalMessage(messageID.rawValue)
        }

        guard let accountID: String = message["resolved_account_id"], !accountID.isEmpty else {
            throw SQLiteMailSearchSchemaError.missingCanonicalAccount(messageID.rawValue)
        }

        let labelsJSON: String = message["labels_json"]
        let labels = try JSONDecoder().decode([String].self, from: Data(labelsJSON.utf8))
        let normalizedLabels = uniqueSorted(labels)
        let normalizedLabelTokens = Set(normalizedLabels.map(normalizedToken))

        let memberships = try Row.fetchAll(
            database,
            sql: """
                SELECT
                    mm.mailbox_path,
                    mm.flags,
                    mb.id AS mailbox_id,
                    COALESCE(NULLIF(mb.name, ''), mm.mailbox_path) AS mailbox_name,
                    COALESCE(NULLIF(mb.path, ''), mm.mailbox_path) AS canonical_path,
                    mb.special_use
                FROM mailbox_messages mm
                LEFT JOIN mailboxes mb
                  ON mb.account_id = mm.account_id
                 AND mb.path = mm.mailbox_path COLLATE NOCASE
                WHERE mm.message_id = ? AND mm.account_id = ?
                ORDER BY COALESCE(mb.id, ''), mm.mailbox_path, mm.uid
                """,
            arguments: [messageID.rawValue, accountID]
        )

        var mailboxIDs: [String] = []
        var mailboxNames: [String] = []
        var isInbox = false
        var isSent = false
        var isTrash = false
        var isFlagged = normalizedLabelTokens.contains("flagged")
        var isDelegated = normalizedLabelTokens.contains("delegated")
        for membership in memberships {
            let mailboxID: String? = membership["mailbox_id"]
            let mailboxName: String = membership["mailbox_name"]
            let canonicalPath: String = membership["canonical_path"]
            let specialUse: String? = membership["special_use"]
            if let mailboxID, !mailboxID.isEmpty { mailboxIDs.append(mailboxID) }
            if !mailboxName.isEmpty { mailboxNames.append(mailboxName) }

            let roles = mailboxRoleTokens(
                specialUse: specialUse,
                name: mailboxName,
                path: canonicalPath
            )
            isInbox = isInbox || roles.contains("inbox")
            isSent = isSent || roles.contains("sent")
            isTrash = isTrash || roles.contains("trash")

            let flags: String = membership["flags"]
            let flagTokens = Set(flags.components(separatedBy: flagSeparators).map(normalizedToken))
            isFlagged = isFlagged || flagTokens.contains("flagged")
            isDelegated = isDelegated || flagTokens.contains("delegated")
        }

        let retained = try currentProjectionMetadata(
            messageID: messageID.rawValue,
            persistsAttachmentMetadata: persistsAttachmentMetadata,
            database: database
        ) ?? retainedMetadata ?? .empty
        let canonicalTo: String = message["to_emails"]
        let canonicalCC: String = message["cc_emails"]
        let toValue = metadata.map { joinedAddresses($0.to) } ?? nonempty(canonicalTo) ?? retained.to
        let ccValue = metadata.map { joinedAddresses($0.cc) } ?? nonempty(canonicalCC) ?? retained.cc
        let bccValue = metadata.map { joinedAddresses($0.bcc) } ?? retained.bcc
        let attachments = normalizedAttachments(metadata?.attachments ?? retained.attachments)
        let filenames = metadata.map {
            uniqueSorted($0.attachments.map(\.filename)).joined(separator: " ")
        } ?? retained.filenames
        let identifiers = metadata.map { uniqueSorted($0.messageIdentifiers).joined(separator: " ") } ?? retained.identifiers
        let hasAttachments = !attachments.isEmpty
            || !filenames.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDocuments = attachments.isEmpty
            ? filenameTokens(filenames).contains {
                MailSearchDocumentClassifier.isDocument(filename: $0, mimeType: nil)
            }
            : attachments.contains {
                MailSearchDocumentClassifier.isDocument(
                    filename: $0.filename,
                    mimeType: $0.mimeType
                )
            }
        let attachmentMetadataJSON = try encodedAttachmentMetadata(attachments)

        let senderEmail: String = message["from_email"]
        let senderDisplayName: String? = message["from_display_name"]
        let sender = [senderDisplayName, senderEmail]
            .compactMap { nonempty($0) }
            .joined(separator: " ")

        let attachmentColumn = persistsAttachmentMetadata ? ", attachment_metadata_json" : ""
        let attachmentUpdate = persistsAttachmentMetadata
            ? ", attachment_metadata_json = excluded.attachment_metadata_json"
            : ""
        let attachmentDifference = persistsAttachmentMetadata
            ? "\n                   OR mail_search_documents.attachment_metadata_json IS NOT excluded.attachment_metadata_json"
            : ""
        var arguments: [(any DatabaseValueConvertible)?] = [
            messageID.rawValue,
            message["thread_id"] as String?,
            accountID,
            message["sent_at"] as Double?,
            message["resolved_sort_date"] as Double,
            sender,
            senderEmail,
            senderDisplayName,
            toValue,
            ccValue,
            bccValue,
            message["subject"] as String,
            message["preview"] as String,
            message["body_text"] as String,
            filenames,
        ]
        if persistsAttachmentMetadata { arguments.append(attachmentMetadataJSON) }
        let trailingArguments: [(any DatabaseValueConvertible)?] = [
            identifiers,
            normalizedLabels.joined(separator: " "),
            uniqueSorted(mailboxIDs).joined(separator: " "),
            uniqueSorted(mailboxNames).joined(separator: " "),
            message["is_seen"] as Int,
            isFlagged,
            isDelegated,
            message["is_deleted"] as Int,
            isTrash,
            isInbox,
            isSent,
            hasAttachments,
            hasDocuments,
        ]
        arguments.append(contentsOf: trailingArguments)
        let valuePlaceholders = Array(repeating: "?", count: arguments.count)
            .joined(separator: ", ")

        try database.execute(
            sql: """
                INSERT INTO mail_search_documents (
                    message_id, thread_id, account_id, sent_at, sort_date,
                    sender, sender_email, sender_display_name, to_value, cc_value, bcc_value,
                    subject, preview, body_text, filenames\(attachmentColumn), identifiers, labels,
                    mailbox_ids, mailbox_names, is_seen, is_flagged, is_delegated, is_deleted,
                    is_trash, is_inbox, is_sent, has_attachments, has_documents
                ) VALUES (
                    \(valuePlaceholders)
                )
                ON CONFLICT(message_id) DO UPDATE SET
                    thread_id = excluded.thread_id,
                    account_id = excluded.account_id,
                    sent_at = excluded.sent_at,
                    sort_date = excluded.sort_date,
                    sender = excluded.sender,
                    sender_email = excluded.sender_email,
                    sender_display_name = excluded.sender_display_name,
                    to_value = excluded.to_value,
                    cc_value = excluded.cc_value,
                    bcc_value = excluded.bcc_value,
                    subject = excluded.subject,
                    preview = excluded.preview,
                    body_text = excluded.body_text,
                    filenames = excluded.filenames\(attachmentUpdate),
                    identifiers = excluded.identifiers,
                    labels = excluded.labels,
                    mailbox_ids = excluded.mailbox_ids,
                    mailbox_names = excluded.mailbox_names,
                    is_seen = excluded.is_seen,
                    is_flagged = excluded.is_flagged,
                    is_delegated = excluded.is_delegated,
                    is_deleted = excluded.is_deleted,
                    is_trash = excluded.is_trash,
                    is_inbox = excluded.is_inbox,
                    is_sent = excluded.is_sent,
                    has_attachments = excluded.has_attachments,
                    has_documents = excluded.has_documents
                WHERE mail_search_documents.thread_id IS NOT excluded.thread_id
                   OR mail_search_documents.account_id IS NOT excluded.account_id
                   OR mail_search_documents.sent_at IS NOT excluded.sent_at
                   OR mail_search_documents.sort_date IS NOT excluded.sort_date
                   OR mail_search_documents.sender IS NOT excluded.sender
                   OR mail_search_documents.sender_email IS NOT excluded.sender_email
                   OR mail_search_documents.sender_display_name IS NOT excluded.sender_display_name
                   OR mail_search_documents.to_value IS NOT excluded.to_value
                   OR mail_search_documents.cc_value IS NOT excluded.cc_value
                   OR mail_search_documents.bcc_value IS NOT excluded.bcc_value
                   OR mail_search_documents.subject IS NOT excluded.subject
                   OR mail_search_documents.preview IS NOT excluded.preview
                   OR mail_search_documents.body_text IS NOT excluded.body_text
                   OR mail_search_documents.filenames IS NOT excluded.filenames\(attachmentDifference)
                   OR mail_search_documents.identifiers IS NOT excluded.identifiers
                   OR mail_search_documents.labels IS NOT excluded.labels
                   OR mail_search_documents.mailbox_ids IS NOT excluded.mailbox_ids
                   OR mail_search_documents.mailbox_names IS NOT excluded.mailbox_names
                   OR mail_search_documents.is_seen IS NOT excluded.is_seen
                   OR mail_search_documents.is_flagged IS NOT excluded.is_flagged
                   OR mail_search_documents.is_delegated IS NOT excluded.is_delegated
                   OR mail_search_documents.is_deleted IS NOT excluded.is_deleted
                   OR mail_search_documents.is_trash IS NOT excluded.is_trash
                   OR mail_search_documents.is_inbox IS NOT excluded.is_inbox
                   OR mail_search_documents.is_sent IS NOT excluded.is_sent
                   OR mail_search_documents.has_attachments IS NOT excluded.has_attachments
                   OR mail_search_documents.has_documents IS NOT excluded.has_documents
                """,
            arguments: StatementArguments(arguments)
        )
    }

    package static func refresh(
        messageID: MessageID,
        retainedMetadata: SQLiteMailSearchRetainedMetadata? = nil,
        database: Database
    ) throws {
        try upsert(
            messageID: messageID,
            metadata: nil,
            retainedMetadata: retainedMetadata,
            database: database
        )
    }

    package static func remove(messageID: MessageID, database: Database) throws {
        try database.execute(
            sql: "DELETE FROM mail_search_documents WHERE message_id = ?",
            arguments: [messageID.rawValue]
        )
    }

    private static let flagSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ",()[]")
    )

    private static func joinedAddresses(_ addresses: [EmailAddress]) -> String {
        uniqueSorted(addresses.map(\.rawValue)).joined(separator: " ")
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(nonempty))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
    }

    static func mailboxRoleTokens(specialUse: String?, name: String, path: String) -> Set<String> {
        let special = normalizedMailboxRoleValue(specialUse ?? "")
        let fallbacks = [normalizedMailboxRoleValue(name), normalizedMailboxRoleValue(path)]
        var roles: Set<String> = []
        if special == "inbox" || fallbacks.contains("inbox") { roles.insert("inbox") }
        if special == "sent" || fallbacks.contains(where: ["sent", "sentitems", "sentmessages"].contains) {
            roles.insert("sent")
        }
        // Trash is decided by the shared resolver, as Delete and the folder list decide it.
        if special == "trash" || TrashMailbox.isTrash(path: path, specialUse: specialUse) {
            roles.insert("trash")
        }
        return roles
    }

    private static func normalizedMailboxRoleValue(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func filenameTokens(_ filenames: String) -> [String] {
        filenames.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    private static func normalizedAttachments(
        _ attachments: [IncomingMessageAttachmentMetadata]
    ) -> [IncomingMessageAttachmentMetadata] {
        Array(Set(attachments)).sorted { lhs, rhs in
            let filenameOrder = lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
            if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
            return (lhs.mimeType ?? "") < (rhs.mimeType ?? "")
        }
    }

    private static func encodedAttachmentMetadata(
        _ attachments: [IncomingMessageAttachmentMetadata]
    ) throws -> String {
        String(decoding: try MailSearchJSON.encoder().encode(attachments), as: UTF8.self)
    }

    private static func decodedAttachmentMetadata(
        _ json: String
    ) throws -> [IncomingMessageAttachmentMetadata] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try MailSearchJSON.decoder().decode(
            [IncomingMessageAttachmentMetadata].self,
            from: data
        )
    }

    private static func currentProjectionMetadata(
        messageID: String,
        persistsAttachmentMetadata: Bool,
        database: Database
    ) throws -> SQLiteMailSearchRetainedMetadata? {
        let attachmentSelection = persistsAttachmentMetadata
            ? ", attachment_metadata_json"
            : ""
        if let row = try Row.fetchOne(
            database,
            sql: """
                SELECT to_value, cc_value, bcc_value, filenames, identifiers\(attachmentSelection)
                FROM mail_search_documents WHERE message_id = ?
                """,
            arguments: [messageID]
        ) {
            return SQLiteMailSearchRetainedMetadata(
                to: row["to_value"],
                cc: row["cc_value"],
                bcc: row["bcc_value"],
                filenames: row["filenames"],
                attachments: persistsAttachmentMetadata
                    ? try decodedAttachmentMetadata(row["attachment_metadata_json"])
                    : [],
                identifiers: row["identifiers"]
            )
        }
        return nil
    }
}
