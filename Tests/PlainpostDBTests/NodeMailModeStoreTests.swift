import Foundation
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostSecrets

final class NodeMailModeStoreTests: XCTestCase {
    private static let nodeID = "30000000-0000-4000-8000-000000000801"
    private static let logicalMailboxID = String(repeating: "A", count: 43)

    func testExistingAccountsStayDirectAndStableKeyResolvesExistingMembership() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc-direct"), displayName: "Direct", email: EmailAddress("direct@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        let message = try commitMessage(store: store, accountID: account.id, rfcMessageID: "<m1@example.test>", uidValidity: 7, uid: 42)

        XCTAssertTrue(store.nodeModeSchemaAvailable)
        XCTAssertEqual(try store.mailSource(accountID: account.id), .direct(account.id))
        XCTAssertEqual(store.directSyncAccounts.map(\.id), [account.id])
        let key = StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 42)
        XCTAssertEqual(try store.resolveStableMessageKey(key), message.id)
        XCTAssertThrowsError(try store.verifyStableMessageKey(key, rfcMessageID: "<other@example.test>")) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .messageIdentityMismatch)
        }
    }

    func testNodeBackedAccountLeavesDirectSyncUntilFallbackAndCASRejectsStaleWriter() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let backed = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "direct@example.test"), expectedGeneration: 0)
        XCTAssertFalse(store.runsDirectSync(accountID: account.id))
        XCTAssertThrowsError(try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: 0)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        _ = try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: backed.generation)
        XCTAssertTrue(store.runsDirectSync(accountID: account.id))
    }

    /// A device syncing a Node account in fallback reads and writes it like a Direct one,
    /// fenced at the fallback generation; in Node mode the same write is refused.
    func testFallbackAccountTakesDirectWritesAtItsOwnGeneration() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let message = try commitMessage(store: store, accountID: account.id, rfcMessageID: "<f1@example.test>", uidValidity: 7, uid: 42)
        let backed = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "direct@example.test"), expectedGeneration: 0)
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        XCTAssertThrowsError(try store.requireDirectSyncSource(accountID: account.id))
        XCTAssertThrowsError(try store.markSelectedDirectSeen(
            message.id, seen: true, actor: actor, accountID: account.id, expectedSourceGeneration: backed.generation
        ))
        let fallback = try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: backed.generation)
        XCTAssertNoThrow(try store.requireDirectSyncSource(accountID: account.id))
        XCTAssertThrowsError(try store.requireDirectMailSource(accountID: account.id))
        XCTAssertTrue(try store.markSelectedDirectSeen(
            message.id, seen: true, actor: actor, accountID: account.id, expectedSourceGeneration: fallback.generation
        ).isSeen)
        XCTAssertThrowsError(try store.markSelectedDirectSeen(
            message.id, seen: false, actor: actor, accountID: account.id, expectedSourceGeneration: backed.generation
        ))
    }

    func testFailedNodeModeMigrationKeepsLocalMailAvailable() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: { throw NodeMailModeStoreError.schemaUnavailable })
        XCTAssertNoThrow(try store.migrate())
        XCTAssertFalse(store.nodeModeSchemaAvailable)
        try store.cacheAccounts([Account(id: AccountID("acc"), displayName: "A", email: EmailAddress("a@example.test"), imapHost: "i.example.test", smtpHost: "s.example.test")])
        XCTAssertEqual(store.directSyncAccounts.count, 1)
        XCTAssertThrowsError(try store.replaceMailSource(.direct(AccountID("acc")), expectedGeneration: 0)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .schemaUnavailable)
        }
    }

    func testFailedNodeModeMigrationRollsBackRecordsRedactedAuditAndRetriesOnNextLaunch() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        struct SecretBearingError: Error, CustomStringConvertible {
            var description: String { "token=do-not-log" }
        }
        let failing = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: { throw SecretBearingError() })
        try failing.migrate()
        XCTAssertFalse(failing.nodeModeSchemaAvailable)
        XCTAssertFalse(try tableExists("account_mail_sources", store: failing))
        let audit = try XCTUnwrap(failing.auditEntries.first { $0.action == "node_mode.schema_unavailable" })
        XCTAssertEqual(audit.targetID, "node-mode-v1-account-sources")
        XCTAssertFalse(String(describing: audit).contains("do-not-log"))
        XCTAssertEqual(try String(contentsOf: failing.auditLogURL, encoding: .utf8).contains("do-not-log"), false)

        // A store instance that did not run migrate() sees the same unavailability.
        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(unmigrated.nodeModeSchemaAvailable)

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertTrue(relaunched.nodeModeSchemaAvailable)
        XCTAssertTrue(try tableExists("account_mail_sources", store: relaunched))
        // Neither the failed nor the unmigrated instance caches a stale negative.
        XCTAssertTrue(unmigrated.nodeModeSchemaAvailable)
        XCTAssertTrue(failing.nodeModeSchemaAvailable)
    }

    func testMigrationFailingAfterItsDDLRollsBackCompletely() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationBodyFailpoint: {
            throw NodeMailModeStoreError.schemaUnavailable
        })
        XCTAssertNoThrow(try store.migrate())

        XCTAssertFalse(store.nodeModeSchemaAvailable)
        let leftovers = try store.databasePool.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE name IN ('account_mail_sources', 'account_mail_sources_logical', 'messages_account_rfc_message_id')
                UNION ALL
                SELECT identifier FROM grdb_migrations WHERE identifier LIKE 'node-mode-%'
                """)
        }
        XCTAssertEqual(leftovers, [])
        XCTAssertTrue(store.auditEntries.contains { $0.action == "node_mode.schema_unavailable" })
    }

    func testFailedReRunOverExistingSchemaKeepsNodeModeAccountsOffDirectSync() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let failNext = LockedFlag()
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: {
            if failNext.value { throw NodeMailModeStoreError.schemaUnavailable }
        })
        try store.migrate()
        let account = Account(id: AccountID("acc-node"), displayName: "Node", email: EmailAddress("n@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        let backed = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)

        // A later migrate() on the long-lived service store hits a transient error.
        failNext.value = true
        XCTAssertNoThrow(try store.migrate())

        XCTAssertTrue(store.nodeModeSchemaAvailable)
        XCTAssertEqual(store.directSyncAccounts, [])
        XCTAssertFalse(store.runsDirectSync(accountID: account.id))
        XCTAssertEqual(try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: 1).mode, .fallback)
        XCTAssertFalse(store.auditEntries.contains { $0.action == "node_mode.schema_unavailable" })
    }

    func testUnreadableSchemaProbeFailsClosed() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let direct = Account(id: AccountID("acc-plain"), displayName: "Plain", email: EmailAddress("p@example.test"),
                             imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account, direct])
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)
        try store.databasePool.write { database in
            try database.execute(sql: """
                ALTER TABLE grdb_migrations RENAME TO grdb_migrations_saved;
                CREATE VIEW grdb_migrations AS SELECT identifier FROM missing_ledger;
                """)
        }

        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(unmigrated.nodeModeSchemaAvailable)
        XCTAssertEqual(unmigrated.directSyncAccounts, [])
        XCTAssertFalse(unmigrated.runsDirectSync(accountID: account.id))
        XCTAssertFalse(unmigrated.runsDirectSync(accountID: direct.id))
        XCTAssertThrowsError(try unmigrated.mailSource(accountID: account.id))
        XCTAssertThrowsError(try unmigrated.replaceMailSource(.direct(direct.id).revertedToDirect(), expectedGeneration: 0))
    }

    func testNodeModeMigrationIgnoresUnrelatedOrphanRows() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let first = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: {
            throw NodeMailModeStoreError.schemaUnavailable
        })
        try first.migrate()
        XCTAssertFalse(first.nodeModeSchemaAvailable)
        try first.databasePool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(sql: """
                INSERT INTO account_authentication (account_id, method, state, updated_at)
                VALUES ('acc-orphan', 'password', 'ready', 0)
                """)
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertTrue(relaunched.nodeModeSchemaAvailable)
    }

    func testMainMigratorToleratesAppliedNodeModeIdentifiers() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let identifiers = try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations WHERE identifier LIKE 'node-mode-%'")
        }
        XCTAssertEqual(identifiers, ["node-mode-v1-account-sources", "node-mode-v2-mail-intent-journal", "node-mode-v3-mirror",
                                     "node-mode-v4-mail-intent-folder-actions"])
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)

        let reopened = try SQLiteMailStore(path: url.path)
        XCTAssertNoThrow(try reopened.migrate())
        XCTAssertTrue(reopened.nodeModeSchemaAvailable)
        XCTAssertEqual(try reopened.mailSource(accountID: account.id).generation, 1)
        XCTAssertFalse(reopened.runsDirectSync(accountID: account.id))
    }

    func testTheJournalTakesFlagsAndMovesAndAMoveAlwaysNamesItsFolder() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let message = try commitMessage(store: store, accountID: account.id, rfcMessageID: "<m1@example.test>", uidValidity: 7, uid: 42).id
        let now = Date()
        func record(_ kind: MailIntentKind, folder: String?) throws -> MailIntentRecord {
            try store.journalMailIntent(
                operationID: UUID().uuidString.lowercased(), accountID: account.id, kind: kind,
                messageID: message, draftID: nil, archiveMailbox: folder, now: now
            )
        }
        XCTAssertEqual(try record(.flag, folder: nil).kind, .flag)
        XCTAssertEqual(try record(.unflag, folder: nil).kind, .unflag)
        XCTAssertEqual(try record(.move, folder: "Receipts").archiveMailbox, "Receipts")
        XCTAssertThrowsError(try record(.move, folder: nil), "a move names its folder")
        XCTAssertThrowsError(try record(.flag, folder: "Receipts"), "a flag names none")
        // The schema holds the same rule for any writer.
        XCTAssertThrowsError(try store.databasePool.write { database in
            try database.execute(sql: """
                INSERT INTO mail_intent_journal (operation_id, account_id, kind, state, message_id, created_at, updated_at)
                VALUES (?, ?, 'move', 'pending', ?, 0, 0)
                """, arguments: [UUID().uuidString.lowercased(), account.id.rawValue, message.rawValue])
        })
    }

    func testSchemaEnforcesSourceShapeAndLogicalMailboxUniqueness() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account, other])
        let rejected = [
            "INSERT INTO account_mail_sources VALUES ('acc-sources', 'direct', 'node', NULL, NULL, NULL, 1, 0)",
            "INSERT INTO account_mail_sources VALUES ('acc-sources', 'node_backed', 'node', 'n', 'short', 'p', 1, 0)",
            "INSERT INTO account_mail_sources VALUES ('acc-sources', 'node_backed', NULL, 'n', '\(Self.logicalMailboxID)', 'p', 1, 0)",
            "INSERT INTO account_mail_sources VALUES ('acc-sources', 'direct', NULL, NULL, NULL, NULL, -1, 0)",
            "INSERT INTO account_mail_sources VALUES ('acc-sources', 'node_backed', 'node', 'ABC', '\(Self.logicalMailboxID)', 'p', 1, 0)",
            "INSERT INTO account_mail_sources VALUES ('acc-missing', 'direct', NULL, NULL, NULL, NULL, 1, 0)",
        ]
        for sql in rejected {
            XCTAssertThrowsError(try store.databasePool.write { try $0.execute(sql: sql) }, sql)
        }
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)
        XCTAssertThrowsError(try store.replaceMailSource(AccountMailSource.direct(other.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0))
        XCTAssertEqual(try store.mailSource(accountID: other.id), .direct(other.id))
        XCTAssertThrowsError(try store.replaceMailSource(AccountMailSource.direct(other.id).nodeBacked(
            nodeID: "nope", logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)) {
            XCTAssertEqual($0 as? AccountMailSourceError, .invalidSource)
        }
        // An uppercase spelling of the same Node is canonicalized, so it collides.
        XCTAssertThrowsError(try store.replaceMailSource(AccountMailSource.direct(other.id).nodeBacked(
            nodeID: Self.nodeID.uppercased(), logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0))
        let indexes = try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('account_mail_sources_logical', 'messages_account_rfc_message_id') ORDER BY name")
        }
        XCTAssertEqual(indexes, ["account_mail_sources_logical", "messages_account_rfc_message_id"])
    }

    func testReplaceMailSourcePostsAccountsChangeAndRevertKeepsGenerationMonotonic() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let posted = expectation(forNotification: MailStoreChangeSignal.notificationName, object: nil) {
            MailStoreChangeSignal.scope(from: $0) == .accounts
        }
        let backed = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(try store.mailSource(accountID: account.id), backed)
        XCTAssertEqual(try store.mailSources(), [backed])

        let reverted = try store.replaceMailSource(backed.revertedToDirect(), expectedGeneration: 1)
        XCTAssertEqual(reverted.kind, .direct)
        XCTAssertEqual(try store.mailSource(accountID: account.id).generation, 2)
        XCTAssertTrue(store.runsDirectSync(accountID: account.id))
        // A writer that still believes the row is absent (generation 0) loses.
        XCTAssertThrowsError(try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        // A caller cannot smuggle an arbitrary generation past the store.
        XCTAssertThrowsError(try store.replaceMailSource(reverted, expectedGeneration: 2)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try store.replaceMailSource(.direct(AccountID("acc-missing")), expectedGeneration: 0))
    }

    // MARK: - Node-backed account creation

    private func nodeAccount(_ id: String = "acc-node", email: String = "node@example.test") -> Account {
        Account(id: AccountID(id), displayName: email, email: EmailAddress(email),
                imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
    }

    private func nodeSource(_ account: Account, logical: String = NodeMailModeStoreTests.logicalMailboxID) throws -> AccountMailSource {
        AccountMailSource.direct(account.id).nodeBacked(nodeID: Self.nodeID, logicalMailboxID: logical, providerIdentity: account.email.rawValue)
    }

    func testCreateNodeBackedAccountWritesTheAccountItsInboxAndItsSource() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = nodeAccount()
        let posted = expectation(forNotification: MailStoreChangeSignal.notificationName, object: nil) {
            MailStoreChangeSignal.scope(from: $0) == .accounts
        }
        XCTAssertEqual(try store.createNodeBackedAccount(account, source: try nodeSource(account)), account.id)
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(store.accounts.map(\.id), [account.id])
        XCTAssertEqual(try store.mailboxes(limit: 10, accountID: account.id).map(\.path), ["INBOX"])
        let source = try store.mailSource(accountID: account.id)
        XCTAssertEqual(source.kind, .nodeBacked)
        XCTAssertEqual(source.mode, .node)
        XCTAssertEqual(source.generation, 1)
        XCTAssertFalse(store.runsDirectSync(accountID: account.id))
    }

    func testCreatingTheSameNodeAccountTwiceKeepsOneAccount() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = nodeAccount()
        _ = try store.createNodeBackedAccount(account, source: try nodeSource(account))
        // A later launch builds the account again from the catalog.
        XCTAssertEqual(try store.createNodeBackedAccount(account, source: try nodeSource(account)), account.id)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(try store.mailSource(accountID: account.id).generation, 1)
    }

    /// The same Node mailbox already attached to a Direct account (the attach flow kept its id).
    func testANodeMailboxAlreadyBoundToAnotherAccountReturnsThatAccount() throws {
        let (store, url, attached) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.replaceMailSource(AccountMailSource.direct(attached.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)
        let catalog = nodeAccount("acc-from-catalog", email: "other@example.test")
        XCTAssertEqual(try store.createNodeBackedAccount(catalog, source: try nodeSource(catalog)), attached.id)
        XCTAssertEqual(store.accounts.map(\.id), [attached.id])
    }

    func testADirectAccountWithTheSameIdOrEmailIsRefusedAndKept() throws {
        let (store, url, direct) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let sameID = nodeAccount(direct.id.rawValue, email: "fresh@example.test")
        XCTAssertThrowsError(try store.createNodeBackedAccount(sameID, source: try nodeSource(sameID))) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .accountExists)
        }
        let sameEmail = nodeAccount("acc-new", email: direct.email.rawValue)
        XCTAssertThrowsError(try store.createNodeBackedAccount(sameEmail, source: try nodeSource(sameEmail))) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .accountExists)
        }
        XCTAssertEqual(try store.mailSource(accountID: direct.id).kind, .direct)
        XCTAssertEqual(store.accounts.map(\.id), [direct.id])
    }

    func testRemovingASyncNodeAccountFromTheDeviceChecksItsSource() async throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = nodeAccount()
        _ = try store.createNodeBackedAccount(account, source: try nodeSource(account))
        do {
            try await store.deleteNodeBackedAccountData(accountID: account.id, expectedSourceGeneration: 7,
                                                         credentials: InMemoryCredentialVault())
            XCTFail("a stale source must not delete")
        } catch NodeMailModeStoreError.generationConflict {}
        XCTAssertEqual(store.accounts.map(\.id), [account.id])
        try await store.deleteNodeBackedAccountData(accountID: account.id, expectedSourceGeneration: 1,
                                                     credentials: InMemoryCredentialVault())
        XCTAssertTrue(store.accounts.isEmpty)
    }

    /// The source can change while the deletion runs (credential removal, journal recovery):
    /// the commit checks it again and keeps an account that was flipped meanwhile.
    func testRemovingASyncNodeAccountRefusesASourceThatChangedBeforeTheCommit() async throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let setup = try SQLiteMailStore(path: url.path)
        try setup.migrate()
        let account = nodeAccount()
        _ = try setup.createNodeBackedAccount(account, source: try nodeSource(account))
        let store = try SQLiteMailStore(path: url.path, accountDeletionFailpoint: { phase in
            guard phase == .afterCredentialRemovalBeforeSQLiteCommit else { return }
            // As a concurrent rebind would: the row moves on under the deletion.
            try setup.databasePool.write { database in
                try database.execute(
                    sql: "UPDATE account_mail_sources SET generation = generation + 1 WHERE account_id = ?",
                    arguments: [account.id.rawValue]
                )
            }
        })
        do {
            try await store.deleteNodeBackedAccountData(accountID: account.id, expectedSourceGeneration: 1,
                                                         credentials: InMemoryCredentialVault())
            XCTFail("a source flipped before the commit must not be deleted")
        } catch {}
        XCTAssertEqual(setup.accounts.map(\.id), [account.id])
    }

    func testOnlyAFreshNodeModeSourceCreatesAnAccount() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = nodeAccount()
        let source = try nodeSource(account)
        for bad in [AccountMailSource.direct(account.id), source.withMode(.fallback),
                    AccountMailSource.direct(AccountID("acc-other")).nodeBacked(
                        nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p")] {
            XCTAssertThrowsError(try store.createNodeBackedAccount(account, source: bad))
        }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testDirectSyncAccountsExcludeOnlyNodeModeAccounts() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account, other])
        let backed = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID, providerIdentity: "p"), expectedGeneration: 0)
        XCTAssertEqual(store.directSyncAccounts.map(\.id), [other.id])
        XCTAssertEqual(try store.mailSources().map(\.accountID), [other.id, account.id])
        _ = try store.replaceMailSource(backed.withMode(.fallback), expectedGeneration: 1)
        XCTAssertEqual(Set(store.directSyncAccounts.map(\.id)), [account.id, other.id])
    }

    func testVerifyStableMessageKeyMatchesOnlyTheStoredIdentity() throws {
        let (store, url, account) = try makeSourceStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let message = try commitMessage(store: store, accountID: account.id, rfcMessageID: "<m1@example.test>", uidValidity: 7, uid: 42)
        let key = StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 42)
        XCTAssertEqual(try store.verifyStableMessageKey(key, rfcMessageID: "<m1@example.test>"), message.id)
        XCTAssertEqual(try store.verifyStableMessageKey(key, rfcMessageID: " <m1@example.test> "), message.id)
        XCTAssertEqual(try store.verifyStableMessageKey(key, rfcMessageID: nil), message.id)
        // The domain compares case-insensitively; the local part does not.
        XCTAssertEqual(try store.verifyStableMessageKey(key, rfcMessageID: "<m1@EXAMPLE.Test>"), message.id)
        XCTAssertThrowsError(try store.verifyStableMessageKey(key, rfcMessageID: "<M1@example.test>")) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .messageIdentityMismatch)
        }
        for miss in [
            StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 8, uid: 42),
            StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 43),
            StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 6, uid: 42),
            StableMessageKey(accountID: account.id, mailboxPath: "INBOX", uidValidity: 7, uid: 41),
            StableMessageKey(accountID: account.id, mailboxPath: "Archive", uidValidity: 7, uid: 42),
            StableMessageKey(accountID: AccountID("acc-other"), mailboxPath: "INBOX", uidValidity: 7, uid: 42),
        ] {
            XCTAssertNil(try store.resolveStableMessageKey(miss))
            XCTAssertNil(try store.verifyStableMessageKey(miss, rfcMessageID: "<m1@example.test>"))
        }
    }

    // MARK: - Helpers

    private func makeSourceStore(testName: String) throws -> (SQLiteMailStore, URL, Account) {
        let url = makeStoreURL()
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc-sources"), displayName: "Sources", email: EmailAddress("direct@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        return (store, url, account)
    }

    private func commitMessage(
        store: SQLiteMailStore, accountID: AccountID, rfcMessageID: String, uidValidity: Int, uid: Int
    ) throws -> MessageSummary {
        let message = MessageSummary(id: MessageID(IMAPSyncService.canonicalMessageID(accountID: accountID, rfcMessageID: rfcMessageID)),
            threadID: nil, from: EmailAddress("a@example.test"), subject: "Hi", preview: "Hi", smartCategory: .personal,
            labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false, body: "Hi", rfcMessageID: rfcMessageID)
        _ = try store.commitIncomingMessage(message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: uidValidity, uid: uid, notificationDisposition: .ineligible)
        return message
    }

    private func tableExists(_ name: String, store: SQLiteMailStore) throws -> Bool {
        try store.databasePool.read { try $0.tableExists(name) }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func makeStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-sources-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("plainpost.sqlite")
    }

    private func removeStoreArtifacts(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
