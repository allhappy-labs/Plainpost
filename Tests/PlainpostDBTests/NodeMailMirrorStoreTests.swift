import Foundation
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB

final class NodeMailMirrorStoreTests: XCTestCase {
    private static let nodeID = "30000000-0000-4000-8000-000000000801"
    private static let otherNodeID = "30000000-0000-4000-8000-000000000802"
    private static let logicalMailboxID = String(repeating: "A", count: 43)
    private static let otherLogicalMailboxID = String(repeating: "Q", count: 43)
    private static let v3Migration = "node-mode-v3-mirror"

    // MARK: - Schema and availability

    func testMirrorMigrationIsRegisteredAfterTheJournalWithImmediateForeignKeys() throws {
        let (store, url, _) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        XCTAssertEqual(try nodeModeIdentifiers(store),
                       ["node-mode-v1-account-sources", "node-mode-v2-mail-intent-journal", Self.v3Migration,
                        "node-mode-v4-mail-intent-folder-actions"])
        XCTAssertTrue(store.nodeMirrorAvailable)
        XCTAssertEqual(Set(try mirrorTables(store)), Set(Self.mirrorTableNames))

        // Deferred checks would fail the whole migration on an unrelated orphan row.
        try removeMirrorMigration(store)
        try store.databasePool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(sql: """
                INSERT INTO account_authentication (account_id, method, state, updated_at)
                VALUES ('acc-orphan', 'password', 'ready', 0)
                """)
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertTrue(relaunched.nodeMirrorAvailable)
    }

    func testMirrorAPIsProbeOnlyTheV3MigrationAndPickUpAnotherProcessesMigration() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        try removeMirrorMigration(store)

        // v1 and v2 are applied, v3 is truly absent.
        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertTrue(unmigrated.nodeModeSchemaAvailable)
        XCTAssertTrue(unmigrated.mailIntentJournalAvailable)
        XCTAssertFalse(unmigrated.nodeMirrorAvailable)
        // Reads truthfully report nothing, because no mirror row can exist.
        XCTAssertNil(try unmigrated.nodeMirrorCursor(nodeID: Self.nodeID))
        XCTAssertNil(try unmigrated.nodeMirrorAccountBootstrap(accountID: account.id))
        XCTAssertNil(try unmigrated.messageID(forNodeMessageID: "n1", accountID: account.id))
        XCTAssertNil(try unmigrated.nodeMessageID(for: MessageID("m1")))
        XCTAssertEqual(try unmigrated.mirroredNodeMessageIDs(accountID: account.id, after: "", limit: 10), [])
        XCTAssertEqual(try unmigrated.pendingMirrorHydration(accountID: account.id, limit: 10), [])
        // Writes refuse.
        let cursor = NodeMirrorCursor(nodeID: Self.nodeID, deltaCursor: "c1", revision: "1", complete: false)
        assertSchemaUnavailable(try unmigrated.saveNodeMirrorCursor(cursor, expected: nil))
        assertSchemaUnavailable(try unmigrated.saveNodeMirrorAccountBootstrap(bootstrap(scope)))
        assertSchemaUnavailable(try unmigrated.resetNodeMirror(nodeID: Self.nodeID))
        assertSchemaUnavailable(try unmigrated.rebindNodeMirrorAccount(scope))
        assertSchemaUnavailable(try commit(unmigrated, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1))
        assertSchemaUnavailable(try unmigrated.syncMirroredMemberships(scope: scope, nodeMessageID: "n1", memberships: [membership(scope, uid: 1)]))
        assertSchemaUnavailable(try unmigrated.removeMirroredMessage(nodeMessageID: "n1", scope: scope))
        assertSchemaUnavailable(try unmigrated.completeMirrorHydration(messageID: MessageID("m1"), scope: scope, textBody: nil, htmlBody: nil, attachments: []))
        assertSchemaUnavailable(try unmigrated.failMirrorHydration(messageID: MessageID("m1"), scope: scope))

        // Another process adds the tables: the unmigrated instance picks them up.
        let migrating = try SQLiteMailStore(path: url.path)
        try migrating.migrate()
        XCTAssertTrue(unmigrated.nodeMirrorAvailable)
        try unmigrated.saveNodeMirrorCursor(cursor, expected: nil)
        XCTAssertEqual(try migrating.nodeMirrorCursor(nodeID: Self.nodeID), cursor)
    }

    func testUnreadableMirrorProbeFailsClosedAndNeverDowngradesAnAvailableInstance() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let cursor = NodeMirrorCursor(nodeID: Self.nodeID, deltaCursor: "c1", revision: "1", complete: true)
        try store.saveNodeMirrorCursor(cursor, expected: nil)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, complete: true))
        try store.databasePool.write { database in
            try database.execute(sql: """
                ALTER TABLE grdb_migrations RENAME TO grdb_migrations_saved;
                CREATE VIEW grdb_migrations AS SELECT identifier FROM missing_ledger;
                """)
        }

        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(unmigrated.nodeMirrorAvailable)
        // A read error is never an authoritative "no cursor" or "nothing pending".
        XCTAssertThrowsError(try unmigrated.nodeMirrorCursor(nodeID: Self.nodeID)) { self.assertNotSchemaUnavailable($0) }
        XCTAssertThrowsError(try unmigrated.nodeMirrorAccountBootstrap(accountID: account.id)) { self.assertNotSchemaUnavailable($0) }
        XCTAssertThrowsError(try unmigrated.pendingMirrorHydration(accountID: account.id, limit: 1)) { self.assertNotSchemaUnavailable($0) }
        XCTAssertThrowsError(try unmigrated.mirroredNodeMessageIDs(accountID: account.id, after: "", limit: 1)) { self.assertNotSchemaUnavailable($0) }
        XCTAssertThrowsError(try unmigrated.saveNodeMirrorCursor(cursor, expected: cursor)) { self.assertNotSchemaUnavailable($0) }

        // The instance that already saw the tables keeps using them.
        XCTAssertTrue(store.nodeMirrorAvailable)
        XCTAssertEqual(try store.nodeMirrorCursor(nodeID: Self.nodeID), cursor)
    }

    func testFailedReRunKeepsAnAvailableMirror() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let failNext = LockedFlag()
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: {
            if failNext.value { throw NodeMailModeStoreError.schemaUnavailable }
        })
        try store.migrate()
        try store.saveNodeMirrorCursor(NodeMirrorCursor(nodeID: Self.nodeID, deltaCursor: "c", revision: "1", complete: false), expected: nil)
        failNext.value = true
        XCTAssertNoThrow(try store.migrate())
        XCTAssertTrue(store.nodeMirrorAvailable)
        XCTAssertFalse(store.auditEntries.contains { $0.action == "node_mode.schema_unavailable" })
        XCTAssertNotNil(try store.nodeMirrorCursor(nodeID: Self.nodeID))
    }

    func testMirrorMigrationFailingAfterItsDDLRollsBackIsAuditedAndRetriesOnNextLaunch() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        struct SecretBearingError: Error, CustomStringConvertible {
            var description: String { "token=do-not-log" }
        }
        // The body failpoint runs in every Node-mode body: pass v1 and v2, fail v3.
        let calls = LockedCounter()
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationBodyFailpoint: {
            if calls.increment() == 3 { throw SecretBearingError() }
        })
        XCTAssertNoThrow(try store.migrate())
        XCTAssertEqual(calls.value, 3)
        let audits = store.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }
        XCTAssertEqual(audits.map(\.targetID), [Self.v3Migration])
        XCTAssertFalse(String(describing: audits).contains("do-not-log"))
        XCTAssertFalse(try String(contentsOf: store.auditLogURL, encoding: .utf8).contains("do-not-log"))
        XCTAssertTrue(store.nodeModeSchemaAvailable)
        XCTAssertTrue(store.mailIntentJournalAvailable)
        XCTAssertFalse(store.nodeMirrorAvailable)
        XCTAssertEqual(try mirrorTables(store), [])
        XCTAssertEqual(try nodeModeIdentifiers(store), ["node-mode-v1-account-sources", "node-mode-v2-mail-intent-journal"])

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertTrue(relaunched.nodeMirrorAvailable)
        XCTAssertEqual(relaunched.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }.count, 1)
        XCTAssertEqual(Set(try mirrorTables(relaunched)), Set(Self.mirrorTableNames))
    }

    func testMirrorUpgradeFailureOverExistingV1AndV2IsAuditedWithTheV3Target() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        _ = try makeNodeBacked(store, account: account)
        try removeMirrorMigration(store)

        // Only the v3 body runs on this upgrade, and it fails after its DDL.
        let upgrading = try SQLiteMailStore(path: url.path, nodeModeMigrationBodyFailpoint: {
            throw NodeMailModeStoreError.schemaUnavailable
        })
        XCTAssertNoThrow(try upgrading.migrate())
        XCTAssertFalse(upgrading.nodeMirrorAvailable)
        XCTAssertEqual(upgrading.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }.map(\.targetID),
                       [Self.v3Migration])
        XCTAssertEqual(try mirrorTables(upgrading), [])
        XCTAssertFalse(upgrading.runsDirectSync(accountID: account.id))
        XCTAssertTrue(upgrading.mailIntentJournalAvailable)
    }

    // MARK: - Cursor and bootstrap rows

    func testNodeCursorIsACompareAndSwapAndResetDropsItAndReopensOnlyThatNodesAccounts() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account, other])
        let scope = try makeNodeBacked(store, account: account)
        let otherScope = try makeNodeBacked(store, account: other, nodeID: Self.otherNodeID, logical: Self.otherLogicalMailboxID)

        let first = NodeMirrorCursor(nodeID: Self.nodeID, deltaCursor: "c1", revision: "1", complete: false)
        try store.saveNodeMirrorCursor(first, expected: nil)
        XCTAssertThrowsError(try store.saveNodeMirrorCursor(first, expected: nil)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        let second = NodeMirrorCursor(nodeID: Self.nodeID, deltaCursor: "c2", revision: "2", complete: true)
        XCTAssertThrowsError(try store.saveNodeMirrorCursor(second, expected: second)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        try store.saveNodeMirrorCursor(second, expected: first)
        XCTAssertEqual(try store.nodeMirrorCursor(nodeID: Self.nodeID), second)
        // Node IDs are lower-case canonical.
        XCTAssertThrowsError(try store.saveNodeMirrorCursor(NodeMirrorCursor(nodeID: Self.nodeID.uppercased(), deltaCursor: "c",
                                                                          revision: "1", complete: false), expected: nil))

        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s9", complete: true, state: .audit))
        try store.saveNodeMirrorAccountBootstrap(bootstrap(otherScope, cursor: "s3", complete: true))
        try store.resetNodeMirror(nodeID: Self.nodeID)

        XCTAssertNil(try store.nodeMirrorCursor(nodeID: Self.nodeID))
        // A reset never downgrades a pending audit; it opens a new generation
        // with a sweep and remembers the account completed a bootstrap before.
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id),
                       bootstrap(scope, state: .audit, generation: 1, sweep: true, everComplete: true))
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: other.id), bootstrap(otherScope, cursor: "s3", complete: true))
    }

    func testBootstrapRowsMayPrecedeTheFlipButNeverTakeAnotherBinding() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        // Handover seeds while the account is still Direct: a bootstrap row writes no mail.
        let target = NodeMirrorScope(accountID: account.id, nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(target))
        let missing = NodeMirrorScope(accountID: AccountID("acc-missing"), nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID)
        XCTAssertThrowsError(try store.saveNodeMirrorAccountBootstrap(bootstrap(missing))) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.seedNodeMirrorAccount(missing)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        let scope = try makeNodeBacked(store, account: account)
        let wrongNode = NodeMirrorScope(accountID: account.id, nodeID: Self.otherNodeID, logicalMailboxID: Self.logicalMailboxID)
        XCTAssertThrowsError(try store.saveNodeMirrorAccountBootstrap(bootstrap(wrongNode))) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.seedNodeMirrorAccount(wrongNode)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s1"))
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id), bootstrap(scope, cursor: "s1"))
    }

    func testSeedStartsFreshOrReBootstrapsTheSameBindingAndRebindsAnother() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let target = NodeMirrorScope(accountID: account.id, nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID)
        try store.seedNodeMirrorAccount(target)
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id), bootstrap(target))
        let scope = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s9", complete: true, state: .audit))

        // A refused snapshot's retry time survives a re-seed, so a flapping
        // account is still retried only slowly.
        let retry = Date(timeIntervalSince1970: 1_900_000_000)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s9", complete: true, state: .audit).retryingSnapshot(at: retry))

        // Re-seeding the same binding keeps links, a pending audit, the retry
        // time and the fact that it completed before.
        try store.seedNodeMirrorAccount(scope)
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id),
                       bootstrap(scope, state: .audit, generation: 1, sweep: true, everComplete: true).retryingSnapshot(at: retry))
        XCTAssertNotNil(try store.messageID(forNodeMessageID: "n1", accountID: account.id))
        // A new binding starts over.
        try store.rebindNodeMirrorAccount(scope)
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id)?.everComplete, false)
        XCTAssertThrowsError(try store.seedNodeMirrorAccount(NodeMirrorScope(accountID: account.id, nodeID: "ABCDEF00-0000-4000-8000-000000000801",
                                                                             logicalMailboxID: Self.logicalMailboxID))) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .invalidMirrorPayload)
        }
    }

    func testFallbackModePausesEveryMailWriteButNotBookkeeping() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, hydration: .pending)
        let source = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(source.withMode(.fallback), expectedGeneration: source.generation)

        XCTAssertThrowsError(try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 2)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.removeMirroredMessage(nodeMessageID: "n1", scope: scope)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.syncMirroredMemberships(scope: scope, nodeMessageID: "n1", memberships: [membership(scope, uid: 1)])) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        let messageID = try XCTUnwrap(store.messageID(forNodeMessageID: "n1", accountID: account.id))
        XCTAssertThrowsError(try store.completeMirrorHydration(messageID: messageID, scope: scope, textBody: "x", htmlBody: nil, attachments: [])) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertNil(NodeMirrorScope(source: try store.mailSource(accountID: account.id)))
        // Bookkeeping for the same binding still works.
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s1"))
        XCTAssertEqual(store.messages.count, 1)
    }

    func testSweepRemovesOnlyLinksTheFreshSnapshotDidNotList() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        for (index, id) in ["kept", "listed", "gone"].enumerated() {
            _ = try commit(store, scope: scope, nodeMessageID: id, rfc: "<\(id)@example.test>", uid: index + 1)
        }
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, complete: true))
        try store.resetNodeMirror(nodeID: Self.nodeID)
        // The fresh snapshot commits "kept" and lists "listed" without committing it.
        _ = try commit(store, scope: scope, nodeMessageID: "kept", rfc: "<kept@example.test>", uid: 1)
        try store.markNodeMirrorLinksListed(accountID: account.id, nodeMessageIDs: ["listed"])
        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 0, "not before the snapshot completes")
        let row = try XCTUnwrap(store.nodeMirrorAccountBootstrap(accountID: account.id))
        try store.saveNodeMirrorAccountBootstrap(row.updating(complete: true, reconcileState: .awaitingBaseline))
        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 0, "not while an epoch baseline is pending")
        try store.saveNodeMirrorAccountBootstrap(row.updating(complete: true))

        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 1)
        XCTAssertNil(try store.messageID(forNodeMessageID: "gone", accountID: account.id))
        XCTAssertNotNil(try store.messageID(forNodeMessageID: "kept", accountID: account.id))
        XCTAssertNotNil(try store.messageID(forNodeMessageID: "listed", accountID: account.id))
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id)?.sweepPending, false)
        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 0)
    }

    func testSweepKeepsDirectAddedMembershipsWhileASuccessorLinkRemains() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        // n2, the successor with the same RFC Message-ID, is already linked (Sent).
        _ = try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<a@example.test>",
                       memberships: [membership(scope, path: "Sent", uid: 4)])
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, complete: true))
        try directArchive(store, account: account, messageID: result.messageID)
        // The re-snapshot lists n2 (its commit was skipped) but no longer n1.
        try reopenAndComplete(store, scope: scope, listed: ["n2"])

        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 1)

        XCTAssertNil(try store.messageID(forNodeMessageID: "n1", accountID: account.id))
        XCTAssertEqual(try memberships(store, messageID: result.messageID), ["Archive|7|9|", "Sent|7|4|"])
        XCTAssertEqual(store.messages.first { $0.id == result.messageID }?.isDeleted, false)
    }

    func testSweepOfTheLastLinkRemovesAStaleDirectArchiveMembership() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, complete: true))
        // Direct sync archived it during fallback; the server then deleted it
        // before direct sync polled again.
        try directArchive(store, account: account, messageID: result.messageID)
        try reopenAndComplete(store, scope: scope, listed: [])

        XCTAssertEqual(try store.sweepUnlistedMirroredMessages(scope: scope), 1)

        XCTAssertNil(try store.messageID(forNodeMessageID: "n1", accountID: account.id))
        XCTAssertEqual(try memberships(store, messageID: result.messageID), [])
        XCTAssertEqual(store.messages.first { $0.id == result.messageID }?.isDeleted, true)
    }

    /// Direct sync's archive during fallback: the INBOX row goes and an
    /// Archive row no link owns arrives.
    private func directArchive(_ store: SQLiteMailStore, account: Account, messageID: MessageID) throws {
        try store.databasePool.write { database in
            try database.execute(sql: "DELETE FROM mailbox_messages WHERE message_id = ? AND mailbox_path = 'INBOX'",
                                 arguments: [messageID.rawValue])
            try database.execute(sql: """
                INSERT INTO mailbox_messages (account_id, mailbox_path, uid_validity, uid, message_id)
                VALUES (?, 'Archive', 7, 9, ?)
                """, arguments: [account.id.rawValue, messageID.rawValue])
        }
    }

    private func reopenAndComplete(_ store: SQLiteMailStore, scope: NodeMirrorScope, listed: [String]) throws {
        try store.resetNodeMirror(nodeID: Self.nodeID)
        try store.markNodeMirrorLinksListed(accountID: scope.accountID, nodeMessageIDs: listed)
        let row = try XCTUnwrap(store.nodeMirrorAccountBootstrap(accountID: scope.accountID))
        try store.saveNodeMirrorAccountBootstrap(row.updating(complete: true))
    }

    func testAuditRetriesAreDueOnlyAfterTheirTimeAndClearOnResolution() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        _ = try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.scheduleMirrorAuditRetry(accountID: account.id, nodeMessageIDs: ["n1", "n2"], at: now.addingTimeInterval(3_600))
        XCTAssertEqual(try store.dueMirrorAuditRetries(accountID: account.id, now: now, limit: 10), [])
        XCTAssertEqual(try store.dueMirrorAuditRetries(accountID: account.id, now: now.addingTimeInterval(3_600), limit: 10), ["n1", "n2"])
        try store.syncMirroredMemberships(scope: scope, nodeMessageID: "n1", memberships: [membership(scope, uid: 1)])
        _ = try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 2)
        XCTAssertEqual(try store.dueMirrorAuditRetries(accountID: account.id, now: now.addingTimeInterval(7_200), limit: 10), [])
    }

    func testFailedHydrationBacksOffBeforeItIsRetried() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, hydration: .pending)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.failMirrorHydration(messageID: result.messageID, scope: scope, now: now, jitter: 1)
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5, now: now.addingTimeInterval(59)), [])
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5, now: now.addingTimeInterval(60)).map(\.state), [.failed])
        try store.failMirrorHydration(messageID: result.messageID, scope: scope, now: now, jitter: 1)
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5, now: now.addingTimeInterval(119)), [])
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5, now: now.addingTimeInterval(120)).count, 1)
    }

    func testCommitWritesItsThreadOnlyInsideTheGuardedTransaction() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = NodeMirrorScope(accountID: account.id, nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID)
        let thread = MailThread(id: ThreadID("thr_mirror"), accountID: account.id, subjectNormalized: "hi", participantEmails: [])
        XCTAssertThrowsError(try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, thread: thread))
        XCTAssertEqual(try threadCount(store), 0)
        let backed = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: backed, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, thread: thread)
        XCTAssertEqual(try threadCount(store), 1)
    }

    // MARK: - Commit, scope and memberships

    func testCommitNeverWritesIntoADirectAccountOrAnotherBinding() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = NodeMirrorScope(accountID: account.id, nodeID: Self.nodeID, logicalMailboxID: Self.logicalMailboxID)
        XCTAssertThrowsError(try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertEqual(store.messages.count, 0)

        let backed = try makeNodeBacked(store, account: account)
        for foreign in [
            NodeMirrorScope(accountID: account.id, nodeID: Self.otherNodeID, logicalMailboxID: Self.logicalMailboxID),
            NodeMirrorScope(accountID: account.id, nodeID: Self.nodeID, logicalMailboxID: Self.otherLogicalMailboxID),
        ] {
            XCTAssertThrowsError(try commit(store, scope: foreign, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)) {
                XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
            }
        }
        XCTAssertEqual(store.messages.count, 0)

        // A flip back to Direct stops every mirror write.
        _ = try commit(store, scope: backed, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        let source = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(source.revertedToDirect(), expectedGeneration: source.generation)
        XCTAssertThrowsError(try commit(store, scope: backed, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 2)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.removeMirroredMessage(nodeMessageID: "n1", scope: backed)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertThrowsError(try store.syncMirroredMemberships(scope: backed, nodeMessageID: "n1", memberships: [membership(backed, uid: 1)])) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertEqual(store.messages.count, 1)
    }

    func testCommitLinksEveryMembershipAndRemovesOnlyThisNodeMessagesUnlistedMemberships() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let inbox = membership(scope, path: "INBOX", uid: 5, flags: ["seen"])
        let archive = membership(scope, path: "Archive", uid: 9, flags: ["flagged", "seen"])
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", memberships: [archive, inbox])
        XCTAssertTrue(result.insertedCanonicalMessage)
        XCTAssertEqual(try store.messageID(forNodeMessageID: "n1", accountID: account.id), result.messageID)
        XCTAssertEqual(try store.nodeMessageID(for: result.messageID), "n1")
        XCTAssertEqual(try memberships(store, messageID: result.messageID),
                       ["Archive|7|9|\\flagged \\seen", "INBOX|7|5|\\seen"])
        let stored = try XCTUnwrap(store.messages.first { $0.id == result.messageID })
        XCTAssertTrue(stored.isSeen)

        // The message leaves INBOX on the Node.
        let again = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", memberships: [archive])
        XCTAssertFalse(again.insertedCanonicalMessage)
        XCTAssertEqual(try memberships(store, messageID: result.messageID), ["Archive|7|9|\\flagged \\seen"])

        // Another Node message with the same RFC Message-ID shares the local
        // message; neither removes the other's memberships.
        _ = try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<a@example.test>", memberships: [membership(scope, path: "Sent", uid: 3)])
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", memberships: [archive])
        XCTAssertEqual(try memberships(store, messageID: result.messageID), ["Archive|7|9|\\flagged \\seen", "Sent|7|3|"])
    }

    func testCommitRefusesAKeyBoundToAnotherLocalMessageAndWritesNothing() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let first = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        XCTAssertThrowsError(try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 1)) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .messageIdentityMismatch)
        }
        XCTAssertEqual(store.messages.map(\.id), [first.messageID])
        XCTAssertNil(try store.messageID(forNodeMessageID: "n2", accountID: account.id))
    }

    func testCommitCanPreserveABodyTheNodePageOmitted() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, body: "Full body")
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, body: "",
                                preserveBodies: true, hydration: .pending)
        XCTAssertEqual(store.messages.first { $0.id == result.messageID }?.body, "Full body")
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5).map(\.nodeMessageID), [])
        // A link that was already hydrated stays hydrated on a later upsert.
        XCTAssertEqual(try hydrationState(store, nodeMessageID: "n1"), "complete")
    }

    func testSyncMembershipsAndRemoveMarkTheMessageDeletedLikeDirectSync() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        XCTAssertFalse(try store.syncMirroredMemberships(scope: scope, nodeMessageID: "unknown", memberships: [membership(scope, uid: 4)]))
        XCTAssertTrue(try store.syncMirroredMemberships(scope: scope, nodeMessageID: "n1",
                                                        memberships: [membership(scope, path: "Archive", uid: 2, flags: ["seen"])]))
        XCTAssertEqual(try memberships(store, messageID: result.messageID), ["Archive|7|2|\\seen"])
        XCTAssertEqual(store.messages.first { $0.id == result.messageID }?.isSeen, true)

        XCTAssertTrue(try store.removeMirroredMessage(nodeMessageID: "n1", scope: scope))
        XCTAssertFalse(try store.removeMirroredMessage(nodeMessageID: "n1", scope: scope))
        XCTAssertEqual(try memberships(store, messageID: result.messageID), [])
        XCTAssertEqual(store.messages.first { $0.id == result.messageID }?.isDeleted, true)
        XCTAssertNil(try store.messageID(forNodeMessageID: "n1", accountID: account.id))
    }

    func testMirroredNodeMessageIDsPageInOrder() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        for (index, id) in ["n3", "n1", "n2"].enumerated() {
            _ = try commit(store, scope: scope, nodeMessageID: id, rfc: "<\(id)@example.test>", uid: index + 1)
        }
        XCTAssertEqual(try store.mirroredNodeMessageIDs(accountID: account.id, after: "", limit: 2), ["n1", "n2"])
        XCTAssertEqual(try store.mirroredNodeMessageIDs(accountID: account.id, after: "n2", limit: 2), ["n3"])
    }

    func testRebindDropsTheOldBindingsLinksAndReopensItsBootstrap() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let result = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1)
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope, cursor: "s1", complete: true))
        try store.rebindNodeMirrorAccount(scope)
        XCTAssertNil(try store.messageID(forNodeMessageID: "n1", accountID: account.id))
        XCTAssertEqual(try store.nodeMirrorAccountBootstrap(accountID: account.id), bootstrap(scope))
        // Local mail stays.
        XCTAssertNotNil(store.messages.first { $0.id == result.messageID })
    }

    // MARK: - Hydration

    func testHydrationQueueCompletesBodiesAndAttachmentsWithinBounds() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        let pending = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, body: "",
                                 hydration: .pending, attachmentIDs: ["att-1"])
        _ = try commit(store, scope: scope, nodeMessageID: "n2", rfc: "<b@example.test>", uid: 2)
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5),
                       [NodeMirrorHydrationItem(messageID: pending.messageID, nodeMessageID: "n1", state: .pending)])

        let payload = IncomingMessageAttachmentPayload(partPath: "1", filename: "a.txt", mimeType: "text/plain", data: Data("hello".utf8))
        XCTAssertThrowsError(try store.completeMirrorHydration(messageID: pending.messageID, scope: scope, textBody: "x", htmlBody: nil,
                                                               attachments: [payload, payload])) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .invalidMirrorPayload)
        }
        try store.failMirrorHydration(messageID: pending.messageID, scope: scope)
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5, now: Date().addingTimeInterval(3_600)).map(\.state), [.failed])

        try store.completeMirrorHydration(messageID: pending.messageID, scope: scope, textBody: "Hydrated body",
                                          htmlBody: "<p>Hydrated</p>", attachments: [payload])
        XCTAssertEqual(try store.pendingMirrorHydration(accountID: account.id, limit: 5), [])
        let stored = try XCTUnwrap(store.messages.first { $0.id == pending.messageID })
        XCTAssertEqual(stored.body, "Hydrated body")
        XCTAssertEqual(stored.bodyHTML, "<p>Hydrated</p>")
        XCTAssertEqual(try store.incomingMessageAttachments(messageID: pending.messageID).map(\.data), [Data("hello".utf8)])

        // Hydration is account-scoped too.
        let foreign = NodeMirrorScope(accountID: account.id, nodeID: Self.otherNodeID, logicalMailboxID: Self.logicalMailboxID)
        XCTAssertThrowsError(try store.completeMirrorHydration(messageID: pending.messageID, scope: foreign, textBody: nil,
                                                               htmlBody: nil, attachments: [])) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
    }

    func testAccountDeletionCascadesMirrorRows() throws {
        let (store, url, account) = try makeMirrorStore()
        defer { removeStoreArtifacts(at: url) }
        let scope = try makeNodeBacked(store, account: account)
        _ = try commit(store, scope: scope, nodeMessageID: "n1", rfc: "<a@example.test>", uid: 1, hydration: .pending, attachmentIDs: ["att"])
        try store.saveNodeMirrorAccountBootstrap(bootstrap(scope))
        try store.deleteAccountData(accountID: account.id)
        let counts = try store.databasePool.read { database in
            try ["node_mirror_account_bootstrap", "node_mirror_message_links", "node_mirror_membership_links"].map {
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0])
    }

    // MARK: - Helpers

    private static let mirrorTableNames = [
        "node_mirror_cursors", "node_mirror_account_bootstrap", "node_mirror_message_links",
        "node_mirror_message_links_message", "node_mirror_membership_links", "node_mirror_membership_links_message",
        "node_mirror_attachment_links",
    ]

    private func makeMirrorStore() throws -> (SQLiteMailStore, URL, Account) {
        let url = makeStoreURL()
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc-mirror"), displayName: "Mirror", email: EmailAddress("m@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        return (store, url, account)
    }

    @discardableResult
    private func makeNodeBacked(
        _ store: SQLiteMailStore, account: Account, nodeID: String = NodeMailMirrorStoreTests.nodeID,
        logical: String = NodeMailMirrorStoreTests.logicalMailboxID
    ) throws -> NodeMirrorScope {
        let current = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(current.nodeBacked(nodeID: nodeID, logicalMailboxID: logical, providerIdentity: account.email.rawValue),
                                        expectedGeneration: current.generation)
        return NodeMirrorScope(accountID: account.id, nodeID: nodeID, logicalMailboxID: logical)
    }

    private func bootstrap(
        _ scope: NodeMirrorScope, cursor: String = "", complete: Bool = false, state: NodeMirrorReconcileState = .none,
        generation: Int64 = 0, sweep: Bool = false, everComplete: Bool = false
    ) -> NodeMirrorAccountBootstrap {
        NodeMirrorAccountBootstrap(accountID: scope.accountID, nodeID: scope.nodeID, logicalMailboxID: scope.logicalMailboxID,
                                   snapshotCursor: cursor, complete: complete, reconcileState: state,
                                   snapshotGeneration: generation, sweepPending: sweep, everComplete: everComplete)
    }

    private func threadCount(_ store: SQLiteMailStore) throws -> Int {
        try store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM threads") ?? -1 }
    }

    private func membership(_ scope: NodeMirrorScope, path: String = "INBOX", uidValidity: Int = 7, uid: Int, flags: [String] = []) -> MirroredMembership {
        MirroredMembership(key: StableMessageKey(accountID: scope.accountID, mailboxPath: path, uidValidity: uidValidity, uid: uid), flags: flags)
    }

    @discardableResult
    private func commit(
        _ store: SQLiteMailStore, scope: NodeMirrorScope, nodeMessageID: String, rfc: String, uid: Int = 1,
        memberships: [MirroredMembership]? = nil, body: String = "Hi", preserveBodies: Bool = false,
        hydration: NodeMirrorHydrationState = .complete, attachmentIDs: [String] = [], thread: MailThread? = nil
    ) throws -> IncomingMessageCommitResult {
        let message = MessageSummary(
            id: MessageID(IMAPSyncService.canonicalMessageID(accountID: scope.accountID, rfcMessageID: rfc)),
            threadID: nil, from: EmailAddress("a@example.test"), subject: "Hi", preview: body.isEmpty ? "" : "Hi",
            smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false, body: body, rfcMessageID: rfc)
        return try store.commitMirroredMessage(
            message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: [rfc]),
            scope: scope, nodeMessageID: nodeMessageID, memberships: memberships ?? [membership(scope, uid: uid)],
            notification: .establishWatermark, preserveExistingBodies: preserveBodies, hydration: hydration,
            nodeAttachmentIDs: attachmentIDs, thread: thread
        )
    }

    private func memberships(_ store: SQLiteMailStore, messageID: MessageID) throws -> [String] {
        try store.databasePool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT mailbox_path, uid_validity, uid, COALESCE(flags, '') AS flags FROM mailbox_messages
                WHERE message_id = ? ORDER BY mailbox_path, uid
                """, arguments: [messageID.rawValue]).map { row in
                "\(row["mailbox_path"] as String)|\(row["uid_validity"] as Int)|\(row["uid"] as Int)|\(row["flags"] as String)"
            }
        }
    }

    private func hydrationState(_ store: SQLiteMailStore, nodeMessageID: String) throws -> String? {
        try store.databasePool.read { database in
            try String.fetchOne(database, sql: "SELECT hydration_state FROM node_mirror_message_links WHERE node_message_id = ?",
                                arguments: [nodeMessageID])
        }
    }

    private func assertSchemaUnavailable<T>(_ expression: @autoclosure () throws -> T, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .schemaUnavailable, line: line)
        }
    }

    private func assertNotSchemaUnavailable(_ error: Error, line: UInt = #line) {
        XCTAssertNotEqual(error as? NodeMailModeStoreError, .schemaUnavailable, line: line)
    }

    /// Simulates a database written before `node-mode-v3-mirror` existed.
    private func removeMirrorMigration(_ store: SQLiteMailStore) throws {
        try store.databasePool.write { database in
            for table in ["node_mirror_attachment_links", "node_mirror_membership_links", "node_mirror_message_links",
                          "node_mirror_account_bootstrap", "node_mirror_cursors"] {
                try database.execute(sql: "DROP TABLE \(table)")
            }
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [Self.v3Migration])
        }
    }

    private func mirrorTables(_ store: SQLiteMailStore) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'node_mirror_%' ORDER BY name")
        }
    }

    private func nodeModeIdentifiers(_ store: SQLiteMailStore) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations WHERE identifier LIKE 'node-mode-%' ORDER BY rowid")
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.withLock { stored } }
        func increment() -> Int { lock.withLock { stored += 1; return stored } }
    }

    private func makeStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mirror-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("plainpost.sqlite")
    }

    private func removeStoreArtifacts(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
