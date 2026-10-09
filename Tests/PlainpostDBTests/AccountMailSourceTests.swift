import Foundation
import CryptoKit
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class AccountMailSourceTests: XCTestCase {
    func testNodeSendReservationRetainsExactCanonicalBytesAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-node-send-recovery-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let owner = account("node-recovery")
        let direct = try AccountMailSource(accountID: owner.id, kind: .direct, mode: nil,
                                           nodeID: nil, logicalMailboxID: nil,
                                           providerIdentity: nil, generation: 1)
        try store.cacheAccountSetup(account: owner, inbox: inbox(for: owner), source: direct)
        let nodeID = "a5be1f45-6473-4d29-bc58-18b63f13b1ea"
        let mailbox = String(repeating: "A", count: 43)
        try store.replaceMailSource(direct.nodeBacked(
            nodeID: nodeID, logicalMailboxID: mailbox,
            providerIdentity: owner.email.rawValue), expectedGeneration: 1)
        let operation = Data("exact-signed-send-operation".utf8)
        let digest = Data(SHA256.hash(data: operation))
        try store.reserveNodeSend(accountID: owner.id, expectedGeneration: 2,
                                  nodeID: nodeID, logicalMailboxID: mailbox,
                                  idempotencyKey: "recovered-send",
                                  canonicalOperationSHA256: digest,
                                  canonicalOperation: operation)

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.unresolvedNodeSends(accountID: owner.id), [operation])
        XCTAssertThrowsError(try reopened.replaceMailSource(
            try reopened.mailSource(accountID: owner.id).revertedToDirect(), expectedGeneration: 2
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .nodeSendUnresolved)
        }
    }
    func testInFlightDirectJobBlocksOnlyItsAccountsSourceTransition() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-direct-job-source-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = account("running-direct-a")
        let second = account("running-direct-b")
        for value in [first, second] {
            let direct = try AccountMailSource(
                accountID: value.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
            try store.cacheAccountSetup(account: value, inbox: inbox(for: value), source: direct)
        }
        let jobID = UUID().uuidString
        try store.databasePool.write { database in
            try database.execute(
                sql: """
                    INSERT INTO durable_jobs (
                        id, kind, payload_json, state, available_at, idempotency_key,
                        created_at, updated_at, owner_account_id, ownership_kind
                    ) VALUES (?, 'mailbox-flag', '{}', 'running', 0, ?, 0, 0, ?, 'account')
                    """,
                arguments: [jobID, jobID, first.id.rawValue]
            )
        }
        let firstNode = try store.mailSource(accountID: first.id).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: first.email.rawValue
        )
        let secondNode = try store.mailSource(accountID: second.id).nodeBacked(
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "Q", count: 43),
            providerIdentity: second.email.rawValue
        )
        XCTAssertThrowsError(try store.replaceMailSource(firstNode, expectedGeneration: 1)) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .operationUnresolved)
        }
        XCTAssertEqual(try store.mailSource(accountID: first.id).generation, 1)
        XCTAssertNoThrow(try store.replaceMailSource(secondNode, expectedGeneration: 1))
        try store.databasePool.write { database in
            try database.execute(sql: "UPDATE durable_jobs SET state = 'completed' WHERE id = ?", arguments: [jobID])
        }
        XCTAssertNoThrow(try store.replaceMailSource(firstNode, expectedGeneration: 1))
    }

    func testDirectIntentMigrationKeepsLegacyCacheReadableWhenOptionalNodeSchemaFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-optional-node-migration-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.databasePool.write { database in
            // Recreate an old cache whose independent Node migration fails at
            // its messages index. The direct intent migration must still run.
            try database.execute(sql: "DROP TABLE node_send_intents")
            try database.execute(sql: "DROP TABLE direct_send_intents")
            try database.execute(sql: "DROP TABLE account_mail_sources")
            try database.execute(sql: "DROP INDEX messages_account_rfc_message_id")
            try database.execute(sql: "CREATE INDEX messages_account_rfc_message_id ON accounts(id)")
            try database.execute(sql: """
                DELETE FROM grdb_migrations WHERE identifier IN (
                    'node-mode-v1-account-sources', 'v61-direct-send-intent',
                    'v62-direct-send-source-generation', 'v63-node-send-intent'
                )
                """)
        }

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.nodeModeSchemaStatus(), .absent)
        XCTAssertNoThrow(try reopened.databasePool.read { database in
            try database.execute(sql: "SELECT source_generation FROM direct_send_intents LIMIT 1")
        })
    }

    func testNodeSendReservationFencesOnlyItsAccountAndGenerationUntilTerminalResult() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-node-send-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = account("node-send-a")
        let second = account("node-send-b")
        for (value, mailbox) in [(first, "A"), (second, "Q")] {
            let direct = try AccountMailSource(accountID: value.id, kind: .direct, mode: nil,
                                               nodeID: nil, logicalMailboxID: nil,
                                               providerIdentity: nil, generation: 1)
            try store.cacheAccountSetup(account: value, inbox: inbox(for: value), source: direct)
            try store.replaceMailSource(direct.nodeBacked(
                nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
                logicalMailboxID: String(repeating: mailbox, count: 43),
                providerIdentity: value.email.rawValue), expectedGeneration: 1)
        }

        try store.reserveNodeSend(accountID: first.id, expectedGeneration: 2,
                                  nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
                                  logicalMailboxID: String(repeating: "A", count: 43),
                                  idempotencyKey: "send-a",
                                  canonicalOperationSHA256: Data(repeating: 7, count: 32))
        XCTAssertThrowsError(try store.replaceMailSource(
            try store.mailSource(accountID: first.id).revertedToDirect(), expectedGeneration: 2
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .nodeSendUnresolved)
        }
        XCTAssertNoThrow(try store.replaceMailSource(
            try store.mailSource(accountID: second.id).revertedToDirect(), expectedGeneration: 2
        ))
        XCTAssertThrowsError(try store.reserveNodeSend(accountID: first.id,
            expectedGeneration: 1,
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            idempotencyKey: "stale",
            canonicalOperationSHA256: Data(repeating: 7, count: 32))) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try store.reserveNodeSend(accountID: first.id,
            expectedGeneration: 2,
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "Q", count: 43),
            idempotencyKey: "foreign-mailbox",
            canonicalOperationSHA256: Data(repeating: 7, count: 32))) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try store.reserveNodeSend(
            accountID: first.id, expectedGeneration: 2,
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            idempotencyKey: "send-a",
            canonicalOperationSHA256: Data(repeating: 8, count: 32)
        )) { error in
            XCTAssertEqual(error as? NodeSendIntentError, .operationMismatch)
        }
        try store.settleNodeSend(accountID: first.id, expectedGeneration: 2,
                                 idempotencyKey: "send-a",
                                 canonicalOperationSHA256: Data(repeating: 7, count: 32),
                                 state: .deliveryUncertain)
        XCTAssertThrowsError(try store.replaceMailSource(
            try store.mailSource(accountID: first.id).revertedToDirect(), expectedGeneration: 2
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .nodeSendUnresolved)
        }
        try store.settleNodeSend(accountID: first.id, expectedGeneration: 2,
                                 idempotencyKey: "send-a",
                                 canonicalOperationSHA256: Data(repeating: 7, count: 32),
                                 state: .conflicted)
        XCTAssertTrue(try store.unresolvedNodeSends(accountID: first.id).isEmpty,
                      "An authenticated terminal conflict must not replay forever")
        XCTAssertThrowsError(try store.reserveNodeSend(
            accountID: first.id, expectedGeneration: 2,
            nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea",
            logicalMailboxID: String(repeating: "A", count: 43),
            idempotencyKey: "send-a",
            canonicalOperationSHA256: Data(repeating: 7, count: 32)
        )) { error in
            XCTAssertEqual(error as? NodeSendIntentError, .terminalReservation)
        }
        XCTAssertThrowsError(try store.settleNodeSend(
            accountID: first.id, expectedGeneration: 2,
            idempotencyKey: "send-a",
            canonicalOperationSHA256: Data(repeating: 7, count: 32),
            state: .applied
        )) { error in
            XCTAssertEqual(error as? NodeSendIntentError, .missingReservation)
        }
        XCTAssertNoThrow(try store.replaceMailSource(
            try store.mailSource(accountID: first.id).revertedToDirect(), expectedGeneration: 2
        ))
    }

    func testAIDraftCommitRejectsStaleDirectGenerationWithoutPersistingDraft() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-source-fence-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let owner = account("ai-source")
        let direct = try AccountMailSource(
            accountID: owner.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: owner, inbox: inbox(for: owner), source: direct)
        let actor = Actor(id: "local-operation-agent", kind: .system,
                          displayName: "Local Operation Agent", permissions: .guiUser)
        let draft = Draft(id: DraftID("drf_ai_fenced"), accountID: owner.id, from: owner.email,
                          to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                          subject: "Re: source", bodyPlain: "Generated", createdBy: actor.id,
                          aiGenerated: true, sourceThreadID: nil)

        try store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: owner.email.rawValue
        ), expectedGeneration: 1)

        XCTAssertThrowsError(try store.createAIDraft(
            draft, actor: actor, expectedDirectSourceGeneration: 1
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try store.draft(id: draft.id))
    }

    func testAITranslationCommitRejectsStaleDirectGenerationWithoutPersistingCache() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-ai-translation-source-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let owner = account("translation-source")
        let direct = try AccountMailSource(accountID: owner.id, kind: .direct, mode: nil,
                                           nodeID: nil, logicalMailboxID: nil,
                                           providerIdentity: nil, generation: 1)
        try store.cacheAccountSetup(account: owner, inbox: inbox(for: owner), source: direct)
        let message = MessageSummary(id: MessageID("translation-source-message"), threadID: nil,
                                     from: EmailAddress("sender@example.com"), subject: "Source",
                                     preview: "Source", body: "Source", smartCategory: .personal)
        try store.cacheMessageReliably(message)
        try store.recordCachedUID(accountID: owner.id, mailboxPath: "INBOX", uidValidity: 1,
                                  uid: 1, messageID: message.id)
        let fingerprint = MailTranslationFingerprint.message(message)
        let translation = CachedMessageTranslation(
            messageID: message.id, targetLanguageID: "de", sourceFingerprint: fingerprint,
            providerID: "foundation", modelID: "model", contractVersion: "message-translation-v1",
            bodyKind: .plainText, translatedBody: "Übersetzt", createdAt: Date(), updatedAt: Date()
        )
        try store.replaceMailSource(direct.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: owner.email.rawValue
        ), expectedGeneration: 1)
        XCTAssertThrowsError(try store.compareAndSaveCachedTranslation(
            translation, expectedSourceFingerprint: fingerprint,
            expectedDirectSourceGeneration: 1
        )) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertNil(try store.cachedTranslation(messageID: message.id, targetLanguageID: "de"))
    }

    func testOAuthDirectAccountPublishesSourceAndAuthenticationTogether() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-oauth-source-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let value = account("oauth")
        let direct = try AccountMailSource(
            accountID: value.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1)
        try store.cacheOAuthAccountSetup(
            account: value, inbox: inbox(for: value), source: direct, authentication: .googleOAuth)
        try store.requireDirectMailSource(accountID: value.id)
        XCTAssertEqual(try store.accountAuthentication(accountID: value.id).method, .googleOAuth)
        XCTAssertThrowsError(try store.cacheOAuthAccountSetup(
            account: value, inbox: inbox(for: value), source: direct, authentication: .googleOAuth))
        XCTAssertEqual(try store.accountAuthentication(accountID: value.id).method, .googleOAuth)
    }

    func testConfirmedSentMembershipUsesOwningAccountAndConfiguredPathAfterRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-sent-projection-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteMailStore(path: url.path)
        try writer.migrate()
        let actor = Actor(id: "user", kind: .user, displayName: "User", permissions: .guiUser)
        let first = account("first")
        let second = Account(
            id: AccountID("second"), displayName: "Second", email: EmailAddress("second@example.com"),
            sentMailbox: "Sent Items", imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        try writer.cacheAccounts([first, second])
        let firstSent = try writer.recordDirectSentMessage(draft: sentDraft("first", account: first, actor: actor), actor: actor)
        let secondSent = try writer.recordDirectSentMessage(draft: sentDraft("second", account: second, actor: actor), actor: actor)
        try writer.recordCachedUID(accountID: second.id, mailboxPath: "Sent Items",
                                   uidValidity: 9, uid: 42, messageID: secondSent.id)

        let reader = try SQLiteMailStore(path: url.path)
        try reader.migrate()
        XCTAssertEqual(try reader.sentMailboxListMessages(accountID: first.id, limit: 20, query: "").map(\.id), [firstSent.id])
        XCTAssertEqual(try reader.sentMailboxListMessages(accountID: second.id, limit: 20, query: "").map(\.id), [secondSent.id])
        XCTAssertEqual(try reader.sentMailboxListMessages(accountID: second.id, limit: 20, query: "first").map(\.id), [])
        XCTAssertEqual(Set(try reader.sentMailboxListMessages(limit: 20, query: "").map(\.id)),
                       Set([firstSent.id, secondSent.id]))
        XCTAssertEqual(try reader.sentMailboxListMessageCount(query: ""), 2)

        try writer.databasePool.write { database in
            try database.execute(sql: """
                INSERT INTO direct_send_intents (
                    draft_id, content_hash, account_id, source_generation, state, created_at, updated_at
                ) VALUES ('first', 'hash', 'first', NULL, 'uncertain', 1, 1)
                """)
        }
        XCTAssertTrue(try reader.sentMailboxListMessages(accountID: first.id, limit: 20, query: "").isEmpty)
        XCTAssertEqual(try reader.sentMailboxListMessageCount(query: ""), 1)
        try writer.databasePool.write { database in
            try database.execute(sql: "UPDATE direct_send_intents SET state = 'sent' WHERE draft_id = 'first'")
        }
        XCTAssertEqual(try reader.sentMailboxListMessages(accountID: first.id, limit: 20, query: "").map(\.id), [firstSent.id])
    }

    func testExplicitDirectSourcePersistsAndFencesProviderAccessAfterNodeHandover() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-source-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()

        let legacy = account("legacy")
        try store.cacheAccountSetup(account: legacy, inbox: inbox(for: legacy))
        XCTAssertEqual(try store.mailSource(accountID: legacy.id), .direct(legacy.id))
        XCTAssertThrowsError(try store.requireDirectMailSource(accountID: legacy.id))

        let direct = account("direct")
        let explicit = try AccountMailSource(
            accountID: direct.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        try store.cacheAccountSetup(account: direct, inbox: inbox(for: direct), source: explicit)
        try store.requireDirectMailSource(accountID: direct.id)

        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.mailSource(accountID: direct.id), explicit)
        try reopened.requireDirectMailSource(accountID: direct.id)

        let node = explicit.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "direct@example.com"
        )
        XCTAssertEqual(try reopened.replaceMailSource(node, expectedGeneration: 1), node)
        XCTAssertThrowsError(try reopened.replaceMailSource(node, expectedGeneration: 1)) { error in
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try reopened.requireDirectMailSource(accountID: direct.id))
        XCTAssertEqual(try reopened.mailSource(accountID: legacy.id), .direct(legacy.id))
    }

    func testSourceOwnershipIsAccountKeyedEvenWithMatchingMessageUIDs() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mail-source-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()

        for name in ["first", "second"] {
            let value = account(name)
            let source = try AccountMailSource(
                accountID: value.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
            try store.cacheAccountSetup(account: value, inbox: inbox(for: value), source: source)
            let message = MessageSummary(
                id: MessageID("\(name)-message"), threadID: nil,
                from: EmailAddress("sender@example.com"), subject: "Shared UID",
                preview: name, smartCategory: .personal
            )
            try store.cacheMessageReliably(message)
            try store.recordCachedUID(accountID: value.id, mailboxPath: "INBOX",
                                      uidValidity: 7, uid: 42, messageID: message.id)
            XCTAssertEqual(try store.mailSource(accountID: value.id), source)
            try store.requireDirectMailSource(accountID: value.id)
        }

        let memberships = try store.databasePool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT account_id, message_id FROM mailbox_messages
                WHERE mailbox_path = 'INBOX' AND uid_validity = 7 AND uid = 42
                ORDER BY account_id
                """)
        }
        XCTAssertEqual(memberships.count, 2)
        XCTAssertEqual(memberships.map { $0["account_id"] as String }, ["first", "second"])
        XCTAssertEqual(memberships.map { $0["message_id"] as String }, ["first-message", "second-message"])

        let first = try store.mailSource(accountID: AccountID("first"))
        let node = first.nodeBacked(
            nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
            logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "first@example.com"
        )
        try store.replaceMailSource(node, expectedGeneration: 1)
        XCTAssertThrowsError(try store.requireDirectMailSource(accountID: AccountID("first")))
        try store.requireDirectMailSource(accountID: AccountID("second"))
    }

    private func account(_ id: String) -> Account {
        Account(id: AccountID(id), displayName: id,
                email: EmailAddress("\(id)@example.com"),
                imapHost: "imap.example.com", smtpHost: "smtp.example.com")
    }

    private func inbox(for account: Account) -> Mailbox {
        Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
    }

    private func sentDraft(_ id: String, account: Account, actor: Actor) -> Draft {
        Draft(id: DraftID(id), accountID: account.id, from: account.email,
              to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
              subject: "Sent \(id)", bodyPlain: "Body \(id)", createdBy: actor.id,
              aiGenerated: false, sourceThreadID: nil)
    }
}
