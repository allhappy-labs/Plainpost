import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class SQLiteMailSearchTests: XCTestCase {
    func testSQLiteStoreKeepsCanonicalSearchImplementationAlongsideLegacyCompatibilityAPI() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/PlainpostDB/SQLiteMailStore.swift"),
            encoding: .utf8
        )
        let canonicalServiceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/PlainpostDB/SQLiteMailSearchService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(storeSource.contains("func searchMessages("))
        XCTAssertTrue(canonicalServiceSource.contains(
            "public func search(_ request: MailSearchRequest) async throws -> MailSearchResponse"
        ))
    }

    func testStoreRegistersV32AndV33ExactlyOnceAndRemovesLegacySearchTables() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }

        try fixture.store.migrate()

        XCTAssertEqual(
            try fixture.scalarSQL(
                "SELECT count(*) FROM grdb_migrations WHERE identifier = 'v32-unified-local-mail-search'"
            ),
            1
        )
        XCTAssertEqual(
            try fixture.scalarSQL(
                "SELECT count(*) FROM grdb_migrations WHERE identifier = 'v33-search-attachment-mime-metadata'"
            ),
            1
        )
        XCTAssertTrue(try fixture.tableExists("mail_search_documents"))
        XCTAssertEqual(
            try fixture.scalarSQL(
                "SELECT count(*) FROM pragma_table_info('mail_search_documents') WHERE name = 'attachment_metadata_json'"
            ),
            1
        )
        XCTAssertFalse(try fixture.tableExists("message_search_metadata"))
        XCTAssertFalse(try fixture.tableExists("message_fts"))
    }

    func testCacheAndIncomingCommitKeepProjectionAndFTSAtomic() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }

        try fixture.store.cacheMessageReliably(fixture.message(subject: "Cached project"))
        XCTAssertEqual(try fixture.text("subject"), "Cached project")
        XCTAssertEqual(try fixture.ftsMatch("cached"), [fixture.messageID.rawValue])

        _ = try fixture.commit(
            fixture.message(subject: "Incoming budget"),
            attachments: ["forecast.pdf"]
        )
        XCTAssertEqual(try fixture.text("subject"), "Incoming budget")
        XCTAssertEqual(try fixture.text("filenames"), "forecast.pdf")
        XCTAssertEqual(try fixture.scalar("has_documents"), 1)
        XCTAssertEqual(try fixture.ftsMatch("budget"), [fixture.messageID.rawValue])
        try fixture.assertProjectionParity()
    }

    func testMailboxReplacementRefreshesDisplacedAndNewOwnersAndInvalidatesBothScopedCursors() async throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        let secondAccount = Account(
            id: AccountID("account-2"),
            displayName: "Second",
            email: EmailAddress("second@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )
        try fixture.store.cacheAccounts([secondAccount])
        let sharedMailboxID = MailboxID("shared-owner")
        try fixture.store.cacheMailboxes([
            Mailbox(
                id: sharedMailboxID,
                accountID: fixture.account.id,
                name: "Team Inbox",
                path: "Legacy",
                specialUse: "\\Inbox"
            ),
        ])
        let oldIDs = [MessageID("old-owner-1"), MessageID("old-owner-2")]
        let newIDs = [MessageID("new-owner-1"), MessageID("new-owner-2")]
        for (offset, messageID) in oldIDs.enumerated() {
            _ = try fixture.store.commitIncomingMessage(
                fixture.message(id: messageID, subject: "Owner project old \(offset)"),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: fixture.account.id,
                mailboxPath: "Legacy",
                uidValidity: 1,
                uid: 10 + offset,
                notificationEligible: false
            )
        }
        for (offset, messageID) in newIDs.enumerated() {
            _ = try fixture.store.commitIncomingMessage(
                fixture.message(id: messageID, subject: "Owner project new \(offset)"),
                metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
                accountID: secondAccount.id,
                mailboxPath: "Destination",
                uidValidity: 1,
                uid: 20 + offset,
                notificationEligible: false
            )
        }
        let service = SQLiteMailSearchService(store: fixture.store)
        let oldScope = MailSearchSelectionScope(accountIDs: [fixture.account.id])
        let newScope = MailSearchSelectionScope(accountIDs: [secondAccount.id])
        let oldPage = try await service.search(
            .init(query: "owner", scope: oldScope, mode: .messages, limit: 1)
        )
        let newPage = try await service.search(
            .init(query: "owner", scope: newScope, mode: .messages, limit: 1)
        )
        let oldCursor = try XCTUnwrap(oldPage.nextCursor)
        let newCursor = try XCTUnwrap(newPage.nextCursor)
        let oldRevision = try fixture.searchRevision(accountID: fixture.account.id)
        let newRevision = try fixture.searchRevision(accountID: secondAccount.id)

        try fixture.store.cacheMailboxes([
            Mailbox(
                id: sharedMailboxID,
                accountID: secondAccount.id,
                name: "Team Sent",
                path: "Destination",
                specialUse: "\\Sent"
            ),
        ])

        XCTAssertEqual(try fixture.text("mailbox_ids", messageID: oldIDs[0]), "")
        XCTAssertEqual(try fixture.text("mailbox_names", messageID: oldIDs[0]), "Legacy")
        XCTAssertEqual(try fixture.scalar("is_inbox", messageID: oldIDs[0]), 0)
        XCTAssertEqual(try fixture.scalar("is_sent", messageID: oldIDs[0]), 0)
        XCTAssertEqual(try fixture.text("mailbox_ids", messageID: newIDs[0]), sharedMailboxID.rawValue)
        XCTAssertEqual(try fixture.text("mailbox_names", messageID: newIDs[0]), "Team Sent")
        XCTAssertEqual(try fixture.scalar("is_inbox", messageID: newIDs[0]), 0)
        XCTAssertEqual(try fixture.scalar("is_sent", messageID: newIDs[0]), 1)
        XCTAssertGreaterThan(try fixture.searchRevision(accountID: fixture.account.id), oldRevision)
        XCTAssertGreaterThan(try fixture.searchRevision(accountID: secondAccount.id), newRevision)
        do {
            _ = try await service.search(
                .init(query: "owner", scope: oldScope, mode: .messages, limit: 1, cursor: oldCursor)
            )
            XCTFail("Expected the displaced mailbox owner's cursor to be stale.")
        } catch {
            XCTAssertEqual(error as? MailSearchError, .staleCursor)
        }
        do {
            _ = try await service.search(
                .init(query: "owner", scope: newScope, mode: .messages, limit: 1, cursor: newCursor)
            )
            XCTFail("Expected the replacement mailbox owner's cursor to be stale.")
        } catch {
            XCTAssertEqual(error as? MailSearchError, .staleCursor)
        }
    }

    func testCachedUIDReplacementRefreshesDisplacedAndNewMessageOwners() async throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        let replacementID = MessageID("uid-replacement-owner")
        try fixture.store.cacheMessageReliably(
            fixture.message(id: replacementID, subject: "Project UID replacement")
        )
        let service = SQLiteMailSearchService(store: fixture.store)
        let page = try await service.search(.init(query: "project", mode: .messages, limit: 1))
        let cursor = try XCTUnwrap(page.nextCursor)
        let revision = try fixture.searchRevision(accountID: fixture.account.id)

        try fixture.store.recordCachedUID(
            accountID: fixture.account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: replacementID
        )

        XCTAssertEqual(try fixture.text("mailbox_ids"), "")
        XCTAssertEqual(try fixture.text("mailbox_names"), "")
        XCTAssertEqual(try fixture.scalar("is_inbox"), 0)
        XCTAssertEqual(try fixture.text("mailbox_ids", messageID: replacementID), "inbox")
        XCTAssertEqual(try fixture.text("mailbox_names", messageID: replacementID), "Inbox")
        XCTAssertEqual(try fixture.scalar("is_inbox", messageID: replacementID), 1)
        XCTAssertGreaterThan(try fixture.searchRevision(accountID: fixture.account.id), revision)
        do {
            _ = try await service.search(
                .init(query: "project", mode: .messages, limit: 1, cursor: cursor)
            )
            XCTFail("Expected the displaced UID owner's cursor to be stale.")
        } catch {
            XCTAssertEqual(error as? MailSearchError, .staleCursor)
        }
    }

    func testSentMailboxUpsertRefreshesMessagesAtDisplacedAndReplacementPaths() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        let sentMailboxID = MailboxID("mbx_\(fixture.account.id.rawValue)_sent")
        try fixture.store.cacheMailboxes([
            Mailbox(
                id: sentMailboxID,
                accountID: fixture.account.id,
                name: "Legacy Sent",
                path: "LegacySent",
                specialUse: "\\Sent"
            ),
        ])
        let displacedID = MessageID("sent-mailbox-displaced")
        let replacementID = MessageID("sent-mailbox-replacement")
        _ = try fixture.store.commitIncomingMessage(
            fixture.message(id: displacedID, subject: "Displaced Sent owner"),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: fixture.account.id,
            mailboxPath: "LegacySent",
            uidValidity: 1,
            uid: 31,
            notificationEligible: false
        )
        _ = try fixture.store.commitIncomingMessage(
            fixture.message(id: replacementID, subject: "Replacement Sent owner"),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: fixture.account.id,
            mailboxPath: "Sent",
            uidValidity: 1,
            uid: 32,
            notificationEligible: false
        )

        _ = try fixture.store.recordDirectSentMessage(
            draft: fixture.sentDraft(id: "direct-mailbox-replacement"),
            actor: fixture.actor
        )

        XCTAssertEqual(try fixture.text("mailbox_ids", messageID: displacedID), "")
        XCTAssertEqual(try fixture.text("mailbox_names", messageID: displacedID), "LegacySent")
        XCTAssertEqual(try fixture.scalar("is_sent", messageID: displacedID), 0)
        XCTAssertEqual(try fixture.text("mailbox_ids", messageID: replacementID), sentMailboxID.rawValue)
        XCTAssertEqual(try fixture.text("mailbox_names", messageID: replacementID), "Sent")
        XCTAssertEqual(try fixture.scalar("is_sent", messageID: replacementID), 1)
    }

    func testPostMigrationProjectionWriterNeverReadsLegacyMetadataTable() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        let messageID = MessageID("message-after-cutover")
        try fixture.store.databasePool.write { database in
            try database.execute(
                sql: "CREATE TABLE message_search_metadata (message_id TEXT PRIMARY KEY)"
            )
        }

        try fixture.store.cacheMessageReliably(
            fixture.message(id: messageID, subject: "Post-cutover write")
        )

        XCTAssertEqual(try fixture.text("subject", messageID: messageID), "Post-cutover write")
    }

    func testReadFlagAndLabelMutationsRefreshProjectionInsideWrite() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }

        _ = try fixture.store.markSeen(fixture.messageID, seen: true, actor: fixture.actor)
        XCTAssertEqual(try fixture.scalar("is_seen"), 1)

        try fixture.store.reconcileMailboxState(
            accountID: fixture.account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            states: [IMAPRemoteMessageState(uid: 1, flags: ["\\Seen", "\\Flagged"])]
        )
        XCTAssertEqual(try fixture.scalar("is_flagged"), 1)

        _ = try fixture.store.addLabel("Delegated", to: fixture.messageID, actor: fixture.actor)
        XCTAssertEqual(try fixture.scalar("is_delegated"), 1)
        XCTAssertEqual(try fixture.ftsMatch("delegated"), [fixture.messageID.rawValue])
        try fixture.assertProjectionParity()
    }

    func testMailboxMoveRefreshesCanonicalMembershipAndProjection() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }

        _ = try fixture.store.moveMessage(fixture.messageID, toMailboxPath: "Archive", actor: fixture.actor)

        XCTAssertEqual(try fixture.membershipPath(), "Archive")
        XCTAssertEqual(try fixture.text("mailbox_names"), "Archive")
        XCTAssertEqual(try fixture.scalar("is_inbox"), 0)
        XCTAssertEqual(try fixture.ftsMatch("archive"), [fixture.messageID.rawValue])
        try fixture.assertProjectionParity()
    }

    func testMailboxMovePreservesUnrelatedMembershipsAndProjectsCanonicalRoles() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        try fixture.store.cacheMailboxes([fixture.sentMailbox])
        try fixture.insertMembership(mailboxPath: "Archive", uid: 2)

        _ = try fixture.store.moveMessage(
            fixture.messageID,
            toMailboxPath: "Sent",
            actor: fixture.actor
        )

        XCTAssertEqual(try fixture.membershipPaths(), ["Archive", "Sent"])
        XCTAssertEqual(try fixture.text("mailbox_ids"), "archive sent")
        XCTAssertEqual(try fixture.text("mailbox_names"), "Archive Sent")
        XCTAssertEqual(try fixture.scalar("is_inbox"), 0)
        XCTAssertEqual(try fixture.scalar("is_sent"), 1)
    }

    func testMailboxMoveRemovesOnlySourceWhenDestinationMembershipAlreadyExists() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        try fixture.insertMembership(mailboxPath: "Archive", uid: 1)

        _ = try fixture.store.moveMessage(
            fixture.messageID,
            toMailboxPath: "Archive",
            actor: fixture.actor
        )

        XCTAssertEqual(try fixture.membershipPaths(), ["Archive"])
        XCTAssertEqual(try fixture.membershipCount(), 1)
        XCTAssertEqual(try fixture.text("mailbox_ids"), "archive")
        XCTAssertEqual(try fixture.text("mailbox_names"), "Archive")
        XCTAssertEqual(try fixture.scalar("is_inbox"), 0)
    }

    func testMailboxMoveCreatesLocalFallbackWhenCanonicalSourceHasNoMembership() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        try fixture.store.cacheMessageReliably(fixture.message())

        _ = try fixture.store.moveMessage(
            fixture.messageID,
            toMailboxPath: "Archive",
            actor: fixture.actor
        )

        let membership = try fixture.onlyMembership()
        XCTAssertEqual(membership["account_id"] as String?, fixture.account.id.rawValue)
        XCTAssertEqual(membership["mailbox_path"] as String?, "Archive")
        XCTAssertEqual(membership["uid_validity"] as Int?, 0)
        XCTAssertLessThan(try XCTUnwrap(membership["uid"] as Int?), 0)
        XCTAssertEqual(try fixture.text("mailbox_ids"), "archive")
        XCTAssertEqual(try fixture.text("mailbox_names"), "Archive")
    }

    func testAttachmentAndThreadChangesRefreshProjection() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        let replacementThread = MailThread(
            id: ThreadID("thread-replacement"),
            accountID: fixture.account.id,
            subjectNormalized: "replacement",
            participantEmails: [EmailAddress("new@example.com")]
        )
        try fixture.store.cacheThread(replacementThread)

        _ = try fixture.commit(
            fixture.message(subject: "Attachment update", threadID: replacementThread.id),
            attachments: ["photo.png", "brief.docx"]
        )

        XCTAssertEqual(try fixture.text("thread_id"), replacementThread.id.rawValue)
        XCTAssertEqual(try fixture.text("filenames"), "brief.docx photo.png")
        XCTAssertEqual(try fixture.scalar("has_attachments"), 1)
        XCTAssertEqual(try fixture.scalar("has_documents"), 1)
        try fixture.assertProjectionParity()
    }

    func testMailboxReconciliationRefreshesEveryAffectedMessageBeforeCommit() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        let secondID = MessageID("message-2")
        _ = try fixture.store.commitIncomingMessage(
            fixture.message(id: secondID, subject: "Second"),
            metadata: .init(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: fixture.account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 2,
            notificationEligible: false
        )

        try fixture.store.reconcileMailboxState(
            accountID: fixture.account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            states: [IMAPRemoteMessageState(uid: 1, flags: ["\\Seen"])]
        )

        XCTAssertEqual(try fixture.scalar("is_seen"), 1)
        XCTAssertEqual(try fixture.scalar("is_deleted", messageID: secondID), 1)
        try fixture.assertProjectionParity()
    }

    func testDeleteRefreshesProjectionAndExcludesHit() async throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }

        _ = try fixture.store.markDeleted(fixture.messageID, deleted: true, actor: fixture.actor)

        XCTAssertEqual(try fixture.scalar("is_deleted"), 1)
        let response = try await SQLiteMailSearchService(store: fixture.store).search(
            MailSearchRequest(query: "project", mode: .messages)
        )
        XCTAssertTrue(response.hits.isEmpty)
        try fixture.assertProjectionParity()
    }

    func testCacheMessageProjectionFailureThrowsAndRollsBackCanonicalMutation() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        try fixture.store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_search_fts")
        }

        XCTAssertThrowsError(
            try fixture.store.cacheMessage(fixture.message(subject: "Must roll back"))
        )

        XCTAssertEqual(try fixture.canonicalSubject(), "Project launch")
    }

    func testCacheMailboxesProjectionFailureThrowsAndRollsBackCanonicalMailbox() throws {
        let fixture = try CutoverStoreFixture.make(committed: true)
        defer { fixture.removeArtifacts() }
        try fixture.store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_search_fts")
        }

        XCTAssertThrowsError(
            try fixture.store.cacheMailboxes([
                Mailbox(
                    id: MailboxID("inbox"),
                    accountID: fixture.account.id,
                    name: "Renamed Inbox",
                    path: "INBOX",
                    specialUse: "\\Inbox"
                ),
            ])
        )

        XCTAssertEqual(try fixture.mailboxName(id: MailboxID("inbox")), "Inbox")
    }

    func testLocalSentCopyPersistsAtomicallyAndIsMailboxScopedSearchableAfterReopen() async throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        let draft = fixture.sentDraft(id: "sent-persisted")
        let requestID = SendRequestID("sent-persisted")

        let sent = try fixture.store.recordSentMessage(
            draft: draft,
            requestID: requestID,
            actor: fixture.actor
        )
        let reopened = try SQLiteMailStore(path: fixture.databaseURL.path)
        try reopened.migrate()
        let membership = try fixture.membershipRow(in: reopened, messageID: sent.id)

        XCTAssertEqual(membership?["account_id"] as String?, fixture.account.id.rawValue)
        XCTAssertEqual(membership?["mailbox_path"] as String?, fixture.account.sentMailbox)
        XCTAssertEqual(membership?["uid_validity"] as Int?, 0)
        XCTAssertLessThan(try XCTUnwrap(membership?["uid"] as Int?), 0)
        XCTAssertEqual(membership?["flags"] as String?, "\\Seen")
        let canonicalAccountID = try await reopened.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT account_id FROM messages WHERE id = ?",
                arguments: [sent.id.rawValue]
            )
        }
        XCTAssertEqual(canonicalAccountID, fixture.account.id.rawValue)
        XCTAssertTrue(reopened.auditEntries.contains {
            $0.action == "message.sent_copy" && $0.targetID == sent.id.rawValue
        })

        let attachmentProjection = try fixture.attachmentProjectionRow(in: reopened, messageID: sent.id)
        XCTAssertEqual(attachmentProjection?["filenames"] as String?, "misleading.pdf report")
        XCTAssertEqual(
            attachmentProjection?["attachment_metadata_json"] as String?,
            #"[{"filename":"misleading.pdf","mimeType":"image/png"},{"filename":"report","mimeType":"application/pdf"}]"#
        )
        XCTAssertEqual(attachmentProjection?["has_attachments"] as Int?, 1)
        XCTAssertEqual(attachmentProjection?["has_documents"] as Int?, 1)

        let service = SQLiteMailSearchService(store: reopened)
        let scope = MailSearchSelectionScope(
            accountIDs: [fixture.account.id],
            mailboxIDs: [MailboxID("mbx_\(fixture.account.id.rawValue)_sent")]
        )
        for query in ["in:sent", "filename:report", "filename:misleading", "has:attachment", "has:document"] {
            let response = try await service.search(
                MailSearchRequest(query: query, scope: scope, mode: .messages)
            )
            XCTAssertEqual(response.hits.map(\.id), [
                MailSearchStableIdentity.message(accountID: fixture.account.id, messageID: sent.id),
            ], query)
        }
    }

    func testLocalSentCopyProjectionFailureRollsBackEveryCanonicalWriteAndThrows() throws {
        let fixture = try CutoverStoreFixture.make()
        defer { fixture.removeArtifacts() }
        let draft = fixture.sentDraft(id: "sent-rollback")
        let requestID = SendRequestID("sent-rollback")
        let expectedMessageID = MessageID("msg_sent_\(requestID.rawValue)")
        try fixture.store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_search_fts")
        }

        XCTAssertThrowsError(
            try fixture.store.recordSentMessage(
                draft: draft,
                requestID: requestID,
                actor: fixture.actor
            )
        )

        let counts = try fixture.store.databasePool.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM messages WHERE id = ?",
                    arguments: [expectedMessageID.rawValue]
                ) ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM mailboxes WHERE special_use = '\\Sent'"
                ) ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM mailbox_messages WHERE message_id = ?",
                    arguments: [expectedMessageID.rawValue]
                ) ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT count(*) FROM audit_entries WHERE target_id = ?",
                    arguments: [expectedMessageID.rawValue]
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
    }
}

private final class CutoverStoreFixture {
    let store: SQLiteMailStore
    let databaseURL: URL
    let account = Account(
        id: AccountID("account"),
        displayName: "Personal",
        email: EmailAddress("me@example.com"),
        imapHost: "imap.example.com",
        smtpHost: "smtp.example.com"
    )
    let messageID = MessageID("message-1")
    let threadID = ThreadID("thread-1")
    let actor = Actor(
        id: "user",
        kind: .user,
        displayName: "User",
        permissions: .guiUser
    )

    private init(store: SQLiteMailStore, databaseURL: URL) {
        self.store = store
        self.databaseURL = databaseURL
    }

    static func make(committed: Bool = false) throws -> CutoverStoreFixture {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mail-search-cutover-\(UUID().uuidString).sqlite")
        let fixture = CutoverStoreFixture(
            store: try SQLiteMailStore(path: databaseURL.path),
            databaseURL: databaseURL
        )
        try fixture.store.migrate()
        try fixture.store.cacheAccounts([fixture.account])
        try fixture.store.cacheMailboxes([
            Mailbox(
                id: MailboxID("inbox"),
                accountID: fixture.account.id,
                name: "Inbox",
                path: "INBOX",
                specialUse: "\\Inbox"
            ),
            Mailbox(
                id: MailboxID("archive"),
                accountID: fixture.account.id,
                name: "Archive",
                path: "Archive",
                specialUse: nil
            ),
        ])
        try fixture.store.cacheThread(MailThread(
            id: fixture.threadID,
            accountID: fixture.account.id,
            subjectNormalized: "project launch",
            participantEmails: [EmailAddress("alex@example.com")]
        ))
        if committed { _ = try fixture.commit(fixture.message()) }
        return fixture
    }

    func message(
        id: MessageID? = nil,
        subject: String = "Project launch",
        threadID: ThreadID? = nil
    ) -> MessageSummary {
        MessageSummary(
            id: id ?? messageID,
            threadID: threadID ?? self.threadID,
            from: EmailAddress("alex@example.com"),
            fromDisplayName: "Alex",
            subject: subject,
            preview: "Project body",
            smartCategory: .personal,
            labels: [],
            isSeen: false,
            mailboxPath: "INBOX",
            isDeleted: false,
            body: "Project body",
            sentAt: Date(timeIntervalSince1970: 1_720_000_000),
            to: [account.email]
        )
    }

    func sentDraft(id: String) -> Draft {
        Draft(
            id: DraftID(id),
            accountID: account.id,
            from: account.email,
            to: [EmailAddress("recipient@example.com")],
            cc: [],
            bcc: [],
            subject: "Sent project",
            bodyPlain: "The sent project body.",
            createdBy: actor.id,
            aiGenerated: false,
            sourceThreadID: threadID,
            attachments: [
                DraftAttachment(
                    id: "report",
                    filename: "report",
                    mimeType: "application/pdf",
                    data: Data("report".utf8)
                ),
                DraftAttachment(
                    id: "photo",
                    filename: "misleading.pdf",
                    mimeType: "image/png",
                    data: Data("photo".utf8)
                ),
            ]
        )
    }

    var sentMailbox: Mailbox {
        Mailbox(
            id: MailboxID("sent"),
            accountID: account.id,
            name: "Sent",
            path: "Sent",
            specialUse: "\\Sent"
        )
    }

    @discardableResult
    func commit(
        _ message: MessageSummary,
        attachments: [String] = []
    ) throws -> IncomingMessageCommitResult {
        try store.commitIncomingMessage(
            message,
            metadata: .init(
                to: message.to,
                cc: message.cc,
                bcc: [],
                attachments: attachments.map {
                    .init(filename: $0, mimeType: nil)
                },
                messageIdentifiers: ["<project@example.com>"]
            ),
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: message.id == messageID ? 1 : 2,
            notificationEligible: false
        )
    }

    func scalar(_ column: String, messageID: MessageID? = nil) throws -> Int {
        try store.databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT \(column) FROM mail_search_documents WHERE message_id = ?",
                arguments: [(messageID ?? self.messageID).rawValue]
            ) ?? -1
        }
    }

    func scalarSQL(_ sql: String) throws -> Int {
        try store.databasePool.read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    func searchRevision(accountID: AccountID) throws -> Int64 {
        try store.databasePool.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT revision FROM mail_search_state WHERE account_id = ?",
                arguments: [accountID.rawValue]
            ) ?? -1
        }
    }

    func text(_ column: String, messageID: MessageID? = nil) throws -> String {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT \(column) FROM mail_search_documents WHERE message_id = ?",
                arguments: [(messageID ?? self.messageID).rawValue]
            ) ?? ""
        }
    }

    func ftsMatch(_ query: String) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT d.message_id
                    FROM mail_search_fts f
                    JOIN mail_search_documents d ON d.rowid = f.rowid
                    WHERE mail_search_fts MATCH ?
                    ORDER BY d.message_id
                    """,
                arguments: [query]
            )
        }
    }

    func mailboxName(id: MailboxID) throws -> String {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT name FROM mailboxes WHERE id = ?",
                arguments: [id.rawValue]
            ) ?? ""
        }
    }

    func membershipPath() throws -> String {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT mailbox_path FROM mailbox_messages WHERE message_id = ?",
                arguments: [messageID.rawValue]
            ) ?? ""
        }
    }

    func membershipPaths() throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT mailbox_path FROM mailbox_messages
                    WHERE message_id = ? ORDER BY mailbox_path COLLATE NOCASE
                    """,
                arguments: [messageID.rawValue]
            )
        }
    }

    func membershipCount() throws -> Int {
        try store.databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT count(*) FROM mailbox_messages WHERE message_id = ?",
                arguments: [messageID.rawValue]
            ) ?? -1
        }
    }

    func onlyMembership() throws -> Row {
        try store.databasePool.read { database in
            try XCTUnwrap(Row.fetchOne(
                database,
                sql: """
                    SELECT account_id, mailbox_path, uid_validity, uid
                    FROM mailbox_messages WHERE message_id = ?
                    """,
                arguments: [messageID.rawValue]
            ))
        }
    }

    // Kept as a plain (non-async) throws helper so `Row.fetchOne` always resolves
    // to DatabasePool's synchronous `read` overload, even when called from an
    // `async` test — Row is not Sendable, so the async overload isn't usable here.
    func membershipRow(in targetStore: SQLiteMailStore, messageID: MessageID) throws -> Row? {
        try targetStore.databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT account_id, mailbox_path, uid_validity, uid, flags
                    FROM mailbox_messages WHERE message_id = ?
                    """,
                arguments: [messageID.rawValue]
            )
        }
    }

    // See `membershipRow(in:messageID:)` for why this stays a non-async helper.
    func attachmentProjectionRow(in targetStore: SQLiteMailStore, messageID: MessageID) throws -> Row? {
        try targetStore.databasePool.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT filenames, attachment_metadata_json, has_attachments, has_documents
                    FROM mail_search_documents WHERE message_id = ?
                    """,
                arguments: [messageID.rawValue]
            )
        }
    }

    func insertMembership(mailboxPath: String, uid: Int) throws {
        try store.databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO mailbox_messages (
                        account_id, mailbox_path, uid_validity, uid, message_id
                    ) VALUES (?, ?, 1, ?, ?)
                    """,
                arguments: [account.id.rawValue, mailboxPath, uid, messageID.rawValue]
            )
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: messageID,
                database: database
            )
        }
    }

    func canonicalSubject() throws -> String {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT subject FROM messages WHERE id = ?",
                arguments: [messageID.rawValue]
            ) ?? ""
        }
    }

    func tableExists(_ name: String) throws -> Bool {
        try store.databasePool.read { try $0.tableExists(name) }
    }

    func assertProjectionParity() throws {
        let counts = try store.databasePool.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_documents") ?? -1,
                try Int.fetchOne(database, sql: "SELECT count(*) FROM mail_search_fts_docsize") ?? -1
            )
        }
        XCTAssertEqual(counts.0, counts.1)
    }

    func removeArtifacts() {
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
    }
}
