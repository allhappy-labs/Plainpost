import Foundation
import GRDB
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB

final class MailIntentJournalStoreTests: XCTestCase {
    private static let v2Migration = "node-mode-v2-mail-intent-journal"

    func testDirectDispatchIsRefusedAfterNodeAdmissionAndSurvivesReopen() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = "00000000-0000-4000-8000-000000000002"
        _ = try store.journalMailIntent(operationID: id, accountID: account.id, kind: .send, messageID: nil, draftID: DraftID("d1"), now: Date())
        _ = try store.beginMailIntentDispatch(operationID: id, route: .node, now: Date())
        _ = try store.recordMailIntentOutcome(operationID: id, state: .admitted, now: Date())
        let reopened = try SQLiteMailStore(path: url.path)
        try reopened.migrate()
        XCTAssertThrowsError(try reopened.beginMailIntentDispatch(operationID: id, route: .direct, now: Date()))
        XCTAssertThrowsError(try reopened.recordMailIntentOutcome(operationID: id, state: .pending, now: Date()))
        XCTAssertEqual(try reopened.markNodeIntentsUnconfirmed(accountID: account.id, now: Date()), 1)
        XCTAssertEqual(try reopened.mailIntents(accountID: account.id, states: [.unconfirmedAfterRemoval]).map(\.operationID), [id])
    }

    func testStampsFollowCommitOrderSoASweepNeverSkipsALateCommit() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let later = Date(timeIntervalSince1970: 2_000)
        let earlier = Date(timeIntervalSince1970: 1_000)
        _ = try store.journalMailIntent(operationID: opID(101), accountID: account.id, kind: .markRead,
                                        messageID: MessageID("m1"), draftID: nil, now: later)
        // Committed after the other, with an older clock reading.
        let late = try store.journalMailIntent(operationID: opID(102), accountID: account.id, kind: .markRead,
                                               messageID: MessageID("m2"), draftID: nil, now: earlier)
        XCTAssertEqual(try store.mailIntent(operationID: opID(102))?.updatedAt, later)
        XCTAssertEqual(late.updatedAt, later, "the returned record carries the stored stamp")
        _ = try store.beginMailIntentDispatch(operationID: opID(102), route: .direct, now: earlier)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(try store.mailIntent(operationID: opID(102))?.updatedAt), later)
    }

    // MARK: - Journal and dispatch

    func testJournalStartsPendingWithoutRouteAndValidatesItsShape() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let created = Date(timeIntervalSince1970: 1_000)
        let record = try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .markRead,
                                                 messageID: MessageID("m1"), draftID: nil, now: created)
        XCTAssertEqual(record, MailIntentRecord(operationID: opID(1), accountID: account.id, kind: .markRead, route: nil,
                                                state: .pending, messageID: MessageID("m1"), draftID: nil,
                                                createdAt: created, updatedAt: created))
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: [.pending]), [record])

        // Re-journaling the same intent is idempotent; a different intent under the same ID is a conflict.
        XCTAssertEqual(try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .markRead,
                                                   messageID: MessageID("m1"), draftID: nil, now: Date()), record)
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([other])
        let conflicting: [(AccountID, MailIntentKind, MessageID)] = [
            (account.id, .archive, MessageID("m1")), (account.id, .markRead, MessageID("m2")), (other.id, .markRead, MessageID("m1")),
        ]
        for (accountID, kind, messageID) in conflicting {
            XCTAssertThrowsError(try store.journalMailIntent(operationID: opID(1), accountID: accountID, kind: kind,
                                                             messageID: messageID, draftID: nil, now: Date()), "\(kind)") {
                XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
            }
        }

        let invalid: [(String, MailIntentKind, MessageID?, DraftID?)] = [
            ("0000000A-0000-4000-8000-00000000000B", .markRead, MessageID("m1"), nil),
            ("not-a-uuid", .markRead, MessageID("m1"), nil),
            (opID(3), .markRead, nil, nil),
            (opID(4), .archive, MessageID("m1"), DraftID("d1")),
            (opID(5), .send, nil, nil),
            (opID(6), .saveDraft, MessageID("m1"), DraftID("d1")),
            (opID(7), .credentialPush, MessageID("m1"), nil),
            (opID(8), .credentialPush, nil, DraftID("d1")),
        ]
        for (id, kind, messageID, draftID) in invalid {
            XCTAssertThrowsError(try store.journalMailIntent(operationID: id, accountID: account.id, kind: kind,
                                                             messageID: messageID, draftID: draftID, now: Date()), "\(id) \(kind)") {
                XCTAssertEqual($0 as? NodeMailModeStoreError, .invalidMailIntent)
            }
        }
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: Set(MailIntentState.allCases)).count, 1)
    }

    func testBeginDispatchIsACompareAndSwapFromUnstartedPending() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .archive,
                                        messageID: MessageID("m1"), draftID: nil, now: Date(timeIntervalSince1970: 1))
        let started = try store.beginMailIntentDispatch(operationID: opID(1), route: .direct, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(started.state, .dispatching)
        XCTAssertEqual(started.route, .direct)
        XCTAssertEqual(started.createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(started.updatedAt, Date(timeIntervalSince1970: 5))
        for route in [MailIntentRoute.direct, .node] {
            XCTAssertThrowsError(try store.beginMailIntentDispatch(operationID: opID(1), route: route, now: Date())) {
                XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
            }
        }
        XCTAssertThrowsError(try store.beginMailIntentDispatch(operationID: opID(9), route: .node, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mailIntentNotFound)
        }

        // Credential pushes are Node-only.
        _ = try store.journalMailIntent(operationID: opID(2), accountID: account.id, kind: .credentialPush,
                                        messageID: nil, draftID: nil, now: Date())
        XCTAssertThrowsError(try store.beginMailIntentDispatch(operationID: opID(2), route: .direct, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertEqual(try store.beginMailIntentDispatch(operationID: opID(2), route: .node, now: Date()).route, .node)
    }

    func testConcurrentBeginDispatchFromTwoStoresHasExactlyOneWinner() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = try SQLiteMailStore(path: url.path)
        try other.migrate()
        let ids = (1...24).map(opID)
        for id in ids {
            _ = try store.journalMailIntent(operationID: id, accountID: account.id, kind: .send,
                                            messageID: nil, draftID: DraftID("d-\(id)"), now: Date())
        }
        let winners = LockedWinners()
        DispatchQueue.concurrentPerform(iterations: ids.count * 2) { index in
            let id = ids[index / 2]
            let (contender, route): (SQLiteMailStore, MailIntentRoute) = index.isMultiple(of: 2) ? (store, .node) : (other, .direct)
            do {
                let record = try contender.beginMailIntentDispatch(operationID: id, route: route, now: Date())
                winners.add(id: id, route: record.route)
            } catch let error as NodeMailModeStoreError {
                XCTAssertEqual(error, .generationConflict)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        let won = winners.snapshot
        let rows = try store.mailIntents(accountID: account.id, states: [.dispatching])
        XCTAssertEqual(rows.count, ids.count)
        for id in ids {
            XCTAssertEqual(won[id]?.count, 1, id)
            XCTAssertEqual(rows.first { $0.operationID == id }?.route, won[id]?.first ?? nil, id)
        }
    }

    // MARK: - Transitions

    func testRecordOutcomeFollowsTheExplicitTransitionTable() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let removed = Account(id: AccountID("acc-removed"), displayName: "Removed", email: EmailAddress("r@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([removed])
        let sources: [(MailIntentState, MailIntentRoute?, MailIntentKind)] = [
            (.pending, nil, .send), (.dispatching, .node, .send), (.dispatching, .direct, .send),
            (.admitted, .node, .send), (.uncertain, .node, .send), (.confirmed, .node, .send),
            (.confirmed, .direct, .send), (.failed, .node, .send), (.failed, .direct, .send),
            (.failed, nil, .credentialPush), (.unconfirmedAfterRemoval, .node, .send),
            (.unconfirmed, .node, .send), (.failed, nil, .archive),
        ]
        let allowed: [String: Set<MailIntentState>] = [
            "dispatching/node": [.admitted, .confirmed, .uncertain, .failed],
            "dispatching/direct": [.confirmed, .failed],
            "admitted/node": [.confirmed, .uncertain, .failed],
            "uncertain/node": [.confirmed, .failed, .unconfirmed],
        ]
        var counter = 100
        for (fromState, route, kind) in sources {
            for target in MailIntentState.allCases {
                counter += 1
                let owner = fromState == .unconfirmedAfterRemoval ? removed.id : account.id
                let id = try drive(store: store, accountID: owner, id: opID(counter), to: fromState, route: route, kind: kind)
                let before = try XCTUnwrap(store.mailIntents(accountID: owner, states: [fromState]).first { $0.operationID == id })
                let key = "\(fromState.rawValue)/\(route?.rawValue ?? "nil")"
                let label = "\(key) -> \(target.rawValue)"
                if allowed[key]?.contains(target) == true {
                    let after = try store.recordMailIntentOutcome(operationID: id, state: target, now: Date(timeIntervalSince1970: 9_999))
                    XCTAssertEqual(after.state, target, label)
                    XCTAssertEqual(after.route, route, label)
                    XCTAssertEqual(after.updatedAt, Date(timeIntervalSince1970: 9_999), label)
                } else {
                    XCTAssertThrowsError(try store.recordMailIntentOutcome(operationID: id, state: target, now: Date()), label) {
                        XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict, label)
                    }
                    let unchanged = try store.mailIntents(accountID: owner, states: Set(MailIntentState.allCases))
                        .first { $0.operationID == id }
                    XCTAssertEqual(unchanged, before, label)
                }
            }
        }
        XCTAssertThrowsError(try store.recordMailIntentOutcome(operationID: opID(99), state: .confirmed, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .mailIntentNotFound)
        }
    }

    func testSchemaRejectsIllegalRowShapes() throws {
        let (store, url, _) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let columns = "operation_id, account_id, kind, route, state, message_id, draft_id, created_at, updated_at"
        let rejected = [
            "('0000000A-0000-4000-8000-00000000000B', 'acc-journal', 'archive', NULL, 'pending', 'm1', NULL, 0, 0)",
            "('\(opID(1))0', 'acc-journal', 'archive', NULL, 'pending', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'forward', NULL, 'pending', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', 'direct', 'admitted', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', 'direct', 'uncertain', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', NULL, 'dispatching', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', 'direct', 'unconfirmed', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', NULL, 'confirmed', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'archive', NULL, 'pending', NULL, NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'send', NULL, 'pending', NULL, NULL, 0, 0)",
            "('\(opID(1))', 'acc-journal', 'credential_push', NULL, 'pending', 'm1', NULL, 0, 0)",
            "('\(opID(1))', 'acc-missing', 'archive', NULL, 'pending', 'm1', NULL, 0, 0)",
        ]
        for values in rejected {
            XCTAssertThrowsError(try store.databasePool.write { database in
                try database.execute(sql: "INSERT INTO mail_intent_journal (\(columns)) VALUES \(values)")
            }, values)
        }
        XCTAssertNoThrow(try store.databasePool.write { database in
            try database.execute(sql: """
                INSERT INTO mail_intent_journal (\(columns)) VALUES
                ('\(self.opID(1))', 'acc-journal', 'credential_push', NULL, 'failed', NULL, NULL, 0, 0)
                """)
        })
    }

    func testStoredOperationsReplayKeysAndRefusalsFollowTheirRules() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let bytes = Data("signed-operation".utf8)
        // A Node dispatch stores its exact bytes with the route.
        _ = try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .archive, messageID: MessageID("m1"),
                                        draftID: nil, archiveMailbox: "Processed", now: Date())
        let begun = try store.beginMailIntentDispatch(operationID: opID(1), route: .node, canonicalOperation: bytes, now: Date())
        XCTAssertEqual(begun.archiveMailbox, "Processed")
        XCTAssertEqual(begun.idempotencyKey, opID(1))
        XCTAssertEqual(try store.mailIntentCanonicalOperation(operationID: opID(1)), bytes)
        // Re-signing while dispatching moves the key; the old and new keys both find the intent.
        let rekeyed = try store.storeMailIntentOperation(operationID: opID(1), idempotencyKey: opID(2), canonicalOperation: Data("re-signed".utf8), now: Date())
        XCTAssertEqual(rekeyed.idempotencyKey, opID(2))
        XCTAssertEqual(try store.mailIntent(idempotencyKey: opID(2))?.operationID, opID(1))
        XCTAssertEqual(try store.mailIntent(idempotencyKey: opID(1))?.operationID, opID(1))
        // Admitted or uncertain work that already holds bytes is never re-signed.
        _ = try store.recordMailIntentOutcome(operationID: opID(1), state: .uncertain, now: Date())
        XCTAssertThrowsError(try store.storeMailIntentOperation(operationID: opID(1), idempotencyKey: opID(3), canonicalOperation: bytes, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        // An uncertain send without bytes (its save landed) may gain its first operation.
        _ = try store.journalMailIntent(operationID: opID(4), accountID: account.id, kind: .send, messageID: nil,
                                        draftID: DraftID("d4"), contentHash: "hash-4", now: Date())
        _ = try store.beginMailIntentDispatch(operationID: opID(4), route: .node, now: Date())
        _ = try store.recordMailIntentOutcome(operationID: opID(4), state: .uncertain, now: Date())
        XCTAssertNoThrow(try store.storeMailIntentOperation(operationID: opID(4), idempotencyKey: opID(4), canonicalOperation: bytes, now: Date()))
        XCTAssertTrue(try store.mailIntentSendInFlight(draftID: DraftID("d4")))
        // A draft save never stores its bytes (they carry the body).
        _ = try store.journalMailIntent(operationID: opID(5), accountID: account.id, kind: .saveDraft, messageID: nil,
                                        draftID: DraftID("d5"), now: Date())
        XCTAssertThrowsError(try store.beginMailIntentDispatch(operationID: opID(5), route: .node, canonicalOperation: bytes, now: Date()))
        _ = try store.beginMailIntentDispatch(operationID: opID(5), route: .node, now: Date())
        XCTAssertThrowsError(try store.storeMailIntentOperation(operationID: opID(5), idempotencyKey: opID(5), canonicalOperation: bytes, now: Date()))
        // Only a send carries a content hash; only an archive carries a destination.
        XCTAssertThrowsError(try store.journalMailIntent(operationID: opID(6), accountID: account.id, kind: .archive, messageID: MessageID("m6"),
                                                         draftID: nil, contentHash: "h", now: Date()))
        XCTAssertThrowsError(try store.journalMailIntent(operationID: opID(6), accountID: account.id, kind: .delete, messageID: MessageID("m6"),
                                                         draftID: nil, archiveMailbox: "A", now: Date()))
        // A row-specific refusal: pending, unrouted → failed, unrouted; never a started row.
        _ = try store.journalMailIntent(operationID: opID(7), accountID: account.id, kind: .send, messageID: nil,
                                        draftID: DraftID("d7"), contentHash: "hash-7", now: Date())
        let refused = try store.refuseUnroutedMailIntent(operationID: opID(7), now: Date())
        XCTAssertEqual(refused.state, .failed)
        XCTAssertNil(refused.route)
        XCTAssertFalse(try store.mailIntentSendInFlight(draftID: DraftID("d7")), "a refused send unlocks its draft")
        XCTAssertThrowsError(try store.refuseUnroutedMailIntent(operationID: opID(4), now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
    }

    func testASaveStageJournalsItsKeyAndSendRevisionWithoutBytes() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .send, messageID: nil,
                                        draftID: DraftID("d1"), contentHash: "hash-1", now: Date())
        _ = try store.beginMailIntentDispatch(operationID: opID(1), route: .node, idempotencyKey: opID(2), now: Date())
        let keyed = try store.storeMailIntentSaveKey(operationID: opID(1), idempotencyKey: opID(2), sendRevision: "4", now: Date())
        XCTAssertEqual(keyed.idempotencyKey, opID(2))
        XCTAssertEqual(keyed.sendRevision, "4")
        XCTAssertNil(try store.mailIntentCanonicalOperation(operationID: opID(1)))
        XCTAssertEqual(try store.mailIntent(idempotencyKey: opID(2))?.operationID, opID(1))
        // Redone after a restart: a new key and revision while uncertain.
        _ = try store.recordMailIntentOutcome(operationID: opID(1), state: .uncertain, now: Date())
        XCTAssertEqual(try store.storeMailIntentSaveKey(operationID: opID(1), idempotencyKey: opID(3), sendRevision: "6", now: Date()).sendRevision, "6")
        // Once the send's own operation is stored, the save stage is over.
        _ = try store.storeMailIntentOperation(operationID: opID(1), idempotencyKey: opID(1), canonicalOperation: Data("send".utf8), now: Date())
        XCTAssertThrowsError(try store.storeMailIntentSaveKey(operationID: opID(1), idempotencyKey: opID(4), sendRevision: "8", now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        // Only a send carries a send revision; a direct route carries no key.
        _ = try store.journalMailIntent(operationID: opID(5), accountID: account.id, kind: .saveDraft, messageID: nil,
                                        draftID: DraftID("d5"), now: Date())
        XCTAssertThrowsError(try store.beginMailIntentDispatch(operationID: opID(5), route: .direct, idempotencyKey: opID(5), now: Date()))
        _ = try store.beginMailIntentDispatch(operationID: opID(5), route: .node, idempotencyKey: opID(5), now: Date())
        XCTAssertThrowsError(try store.storeMailIntentSaveKey(operationID: opID(5), idempotencyKey: opID(6), sendRevision: "2", now: Date()))
        XCTAssertNoThrow(try store.storeMailIntentSaveKey(operationID: opID(5), idempotencyKey: opID(6), sendRevision: nil, now: Date()))
        let indexed = try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'mail_intent_journal'")
        }
        XCTAssertTrue(indexed.contains("mail_intent_journal_idempotency_key"))
    }

    func testASaveStageFailsOnlyWhileNoSendBytesAreStored() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .send, messageID: nil,
                                        draftID: DraftID("d1"), contentHash: "hash-1", now: Date())
        let begun = try store.beginMailIntentDispatch(operationID: opID(1), route: .node, idempotencyKey: opID(2), sendRevision: "2", now: Date())
        XCTAssertEqual(begun.sendRevision, "2", "begin journals the key and the send revision in one write")
        _ = try store.recordMailIntentOutcome(operationID: opID(1), state: .uncertain, now: Date())
        _ = try store.storeMailIntentOperation(operationID: opID(1), idempotencyKey: opID(1), canonicalOperation: Data("send".utf8), now: Date())
        XCTAssertThrowsError(try store.failMailIntentSaveStage(operationID: opID(1), now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertEqual(try store.mailIntent(operationID: opID(1))?.state, .uncertain)

        _ = try store.journalMailIntent(operationID: opID(3), accountID: account.id, kind: .send, messageID: nil,
                                        draftID: DraftID("d3"), contentHash: "hash-3", now: Date())
        _ = try store.beginMailIntentDispatch(operationID: opID(3), route: .node, idempotencyKey: opID(4), sendRevision: "2", now: Date())
        XCTAssertEqual(try store.failMailIntentSaveStage(operationID: opID(3), now: Date()).state, .failed)
        // A stored single operation is never a save stage.
        _ = try store.journalMailIntent(operationID: opID(5), accountID: account.id, kind: .archive, messageID: MessageID("m5"),
                                        draftID: nil, now: Date())
        _ = try store.beginMailIntentDispatch(operationID: opID(5), route: .node, now: Date())
        XCTAssertThrowsError(try store.failMailIntentSaveStage(operationID: opID(5), now: Date()))
    }

    // MARK: - Account-level operations

    func testRerouteReturnsOnlyRouteNilPendingMailIntentsAndTouchesNothing() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([other])
        let unstartedA = try drive(store: store, accountID: account.id, id: opID(1), to: .pending, route: nil, kind: .archive,
                                   at: Date(timeIntervalSince1970: 10))
        let unstartedB = try drive(store: store, accountID: account.id, id: opID(2), to: .pending, route: nil, kind: .send,
                                   at: Date(timeIntervalSince1970: 20))
        _ = try drive(store: store, accountID: account.id, id: opID(3), to: .dispatching, route: .direct, kind: .archive)
        _ = try drive(store: store, accountID: account.id, id: opID(4), to: .dispatching, route: .node, kind: .archive)
        _ = try drive(store: store, accountID: account.id, id: opID(5), to: .admitted, route: .node, kind: .send)
        _ = try drive(store: store, accountID: account.id, id: opID(6), to: .confirmed, route: .direct, kind: .markRead)
        _ = try drive(store: store, accountID: account.id, id: opID(7), to: .pending, route: nil, kind: .credentialPush)
        _ = try drive(store: store, accountID: other.id, id: opID(8), to: .pending, route: nil, kind: .archive)
        let before = try store.mailIntents(accountID: account.id, states: Set(MailIntentState.allCases))

        let rerouted = try store.rerouteUnstartedDirectIntents(accountID: account.id, now: Date())

        XCTAssertEqual(rerouted.map(\.operationID), [unstartedA, unstartedB])
        XCTAssertTrue(rerouted.allSatisfy { $0.state == .pending && $0.route == nil })
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: Set(MailIntentState.allCases)), before)
    }

    func testMarkNodeIntentsUnconfirmedConvertsOnlyNodeWorkInFlight() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([other])
        let converted = [
            try drive(store: store, accountID: account.id, id: opID(1), to: .dispatching, route: .node, kind: .send),
            try drive(store: store, accountID: account.id, id: opID(2), to: .admitted, route: .node, kind: .send),
            try drive(store: store, accountID: account.id, id: opID(3), to: .uncertain, route: .node, kind: .archive),
        ]
        let kept = [
            try drive(store: store, accountID: account.id, id: opID(4), to: .dispatching, route: .direct, kind: .send),
            try drive(store: store, accountID: account.id, id: opID(5), to: .pending, route: nil, kind: .send),
            try drive(store: store, accountID: account.id, id: opID(6), to: .confirmed, route: .node, kind: .send),
            try drive(store: store, accountID: account.id, id: opID(7), to: .failed, route: .node, kind: .send),
            try drive(store: store, accountID: other.id, id: opID(8), to: .admitted, route: .node, kind: .send),
        ]
        let before = try allIntents(store, accounts: [account.id, other.id])

        XCTAssertEqual(try store.markNodeIntentsUnconfirmed(accountID: account.id, now: Date(timeIntervalSince1970: 777)), 3)

        let after = try allIntents(store, accounts: [account.id, other.id])
        for id in converted {
            XCTAssertEqual(after[id]?.state, .unconfirmedAfterRemoval, id)
            XCTAssertEqual(after[id]?.route, .node, id)
            XCTAssertEqual(after[id]?.updatedAt, Date(timeIntervalSince1970: 777), id)
        }
        for id in kept { XCTAssertEqual(after[id], before[id], id) }
        XCTAssertEqual(try store.markNodeIntentsUnconfirmed(accountID: account.id, now: Date()), 0)
    }

    func testSupersedePendingCredentialPushesKeepsTheNamedOne() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([other])
        let older = [
            try drive(store: store, accountID: account.id, id: opID(1), to: .pending, route: nil, kind: .credentialPush),
            try drive(store: store, accountID: account.id, id: opID(2), to: .pending, route: nil, kind: .credentialPush),
        ]
        let latest = try drive(store: store, accountID: account.id, id: opID(3), to: .pending, route: nil, kind: .credentialPush)
        let inFlight = try drive(store: store, accountID: account.id, id: opID(4), to: .dispatching, route: .node, kind: .credentialPush)
        let mail = try drive(store: store, accountID: account.id, id: opID(5), to: .pending, route: nil, kind: .send)
        let otherPush = try drive(store: store, accountID: other.id, id: opID(6), to: .pending, route: nil, kind: .credentialPush)
        let before = try allIntents(store, accounts: [account.id, other.id])

        XCTAssertEqual(try store.supersedePendingCredentialPushes(accountID: account.id, keeping: latest,
                                                                  now: Date(timeIntervalSince1970: 55)), 2)

        let after = try allIntents(store, accounts: [account.id, other.id])
        for id in older {
            XCTAssertEqual(after[id]?.state, .failed, id)
            XCTAssertNil(after[id]?.route, id)
            XCTAssertEqual(after[id]?.updatedAt, Date(timeIntervalSince1970: 55), id)
        }
        for id in [latest, inFlight, mail, otherPush] { XCTAssertEqual(after[id], before[id], id) }
        // pending → failed is never available to mail kinds, nor through recordMailIntentOutcome.
        XCTAssertThrowsError(try store.recordMailIntentOutcome(operationID: mail, state: .failed, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertThrowsError(try store.recordMailIntentOutcome(operationID: latest, state: .failed, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: [.pending]).map(\.operationID), [latest, mail])
    }

    func testInterruptedNodeDispatchRecoversAsUncertainAndDirectDispatchStaysGuarded() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let crashed = try drive(store: store, accountID: account.id, id: opID(1), to: .dispatching, route: .node, kind: .send,
                                at: Date(timeIntervalSince1970: 100))
        let crashedDirect = try drive(store: store, accountID: account.id, id: opID(2), to: .dispatching, route: .direct, kind: .send,
                                      at: Date(timeIntervalSince1970: 100))
        let live = try drive(store: store, accountID: account.id, id: opID(3), to: .dispatching, route: .node, kind: .archive,
                             at: Date(timeIntervalSince1970: 300))
        let admitted = try drive(store: store, accountID: account.id, id: opID(4), to: .admitted, route: .node, kind: .send,
                                 at: Date(timeIntervalSince1970: 100))

        // A new service process starts at t=200: only dispatches older than its start are interrupted.
        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertEqual(try relaunched.recoverInterruptedMailIntentDispatches(dispatchedBefore: Date(timeIntervalSince1970: 200),
                                                                            now: Date(timeIntervalSince1970: 400)), 1)

        let after = try allIntents(relaunched, accounts: [account.id])
        XCTAssertEqual(after[crashed]?.state, .uncertain)
        XCTAssertEqual(after[crashed]?.updatedAt, Date(timeIntervalSince1970: 400))
        XCTAssertFalse(MailIntentGuard.mayDispatchDirect(try XCTUnwrap(after[crashed])))
        XCTAssertFalse(MailIntentGuard.mayResend(try XCTUnwrap(after[crashed])))
        XCTAssertTrue(MailIntentGuard.waitsForNode(try XCTUnwrap(after[crashed])))
        XCTAssertEqual(after[crashedDirect]?.state, .dispatching)
        XCTAssertEqual(after[crashedDirect]?.route, .direct)
        XCTAssertFalse(MailIntentGuard.mayResend(try XCTUnwrap(after[crashedDirect])))
        XCTAssertEqual(after[live]?.state, .dispatching)
        XCTAssertEqual(after[admitted]?.state, .admitted)
        XCTAssertThrowsError(try relaunched.beginMailIntentDispatch(operationID: crashed, route: .direct, now: Date()))
    }

    func testWaitingForNodeReturnsOnlyAdmittedAndUncertainMessages() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let other = Account(id: AccountID("acc-other"), displayName: "Other", email: EmailAddress("o@example.test"),
                            imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([other])
        let states: [(MailIntentState, MailIntentRoute?)] = [
            (.pending, nil), (.dispatching, .node), (.dispatching, .direct), (.admitted, .node), (.uncertain, .node),
            (.confirmed, .node), (.failed, .node), (.confirmed, .direct),
        ]
        for (index, (state, route)) in states.enumerated() {
            _ = try drive(store: store, accountID: account.id, id: opID(index + 1), to: state, route: route, kind: .archive,
                          messageID: MessageID("m-\(state.rawValue)-\(route?.rawValue ?? "nil")"))
        }
        let removedID = try drive(store: store, accountID: other.id, id: opID(40), to: .admitted, route: .node, kind: .markRead,
                                  messageID: MessageID("m-removed"))
        XCTAssertEqual(try store.markNodeIntentsUnconfirmed(accountID: other.id, now: Date()), 1)
        _ = removedID
        _ = try drive(store: store, accountID: other.id, id: opID(41), to: .uncertain, route: .node, kind: .markRead,
                      messageID: MessageID("m-other"))

        let everything = states.map { MessageID("m-\($0.0.rawValue)-\($0.1?.rawValue ?? "nil")") }
            + [MessageID("m-removed"), MessageID("m-other"), MessageID("m-unknown")]
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: everything),
                       [MessageID("m-admitted-node"), MessageID("m-uncertain-node"), MessageID("m-other")])
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: [MessageID("m-confirmed-node")]), [])
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: []), [])
        // More IDs than SQLite binds in one statement.
        let many = (0..<2_500).map { MessageID("filler-\($0)") } + [MessageID("m-uncertain-node")]
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: many), [MessageID("m-uncertain-node")])
    }

    func testMailIntentsFiltersByAccountAndStateInCreationOrder() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let late = try drive(store: store, accountID: account.id, id: opID(1), to: .pending, route: nil, kind: .archive,
                             at: Date(timeIntervalSince1970: 30))
        let early = try drive(store: store, accountID: account.id, id: opID(2), to: .pending, route: nil, kind: .archive,
                              at: Date(timeIntervalSince1970: 10))
        let failed = try drive(store: store, accountID: account.id, id: opID(3), to: .failed, route: .direct, kind: .archive,
                               at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: [.pending]).map(\.operationID), [early, late])
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: [.pending, .failed]).map(\.operationID),
                       [early, failed, late])
        XCTAssertEqual(try store.mailIntents(accountID: account.id, states: []), [])
        XCTAssertEqual(try store.mailIntents(accountID: AccountID("acc-nobody"), states: [.pending]), [])
    }

    func testAccountDeletionCascadesJournalRows() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let kept = Account(id: AccountID("acc-kept"), displayName: "Kept", email: EmailAddress("k@example.test"),
                           imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([kept])
        _ = try drive(store: store, accountID: account.id, id: opID(1), to: .admitted, route: .node, kind: .send)
        _ = try drive(store: store, accountID: account.id, id: opID(2), to: .pending, route: nil, kind: .credentialPush)
        let keptID = try drive(store: store, accountID: kept.id, id: opID(3), to: .pending, route: nil, kind: .archive)

        try store.deleteAccountData(accountID: account.id)

        let remaining = try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT operation_id FROM mail_intent_journal")
        }
        XCTAssertEqual(remaining, [keptID])
    }

    // MARK: - Schema availability

    func testJournalProbeChecksTheV2MigrationAndMigrateAddsIt() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: "30000000-0000-4000-8000-000000000801", logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "p"), expectedGeneration: 0)
        try removeJournalMigration(store)

        // v1 is applied, v2 is truly absent.
        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertTrue(unmigrated.nodeModeSchemaAvailable)
        XCTAssertFalse(unmigrated.mailIntentJournalAvailable)
        XCTAssertFalse(unmigrated.runsDirectSync(accountID: account.id))
        XCTAssertThrowsError(try unmigrated.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .archive,
                                                              messageID: MessageID("m1"), draftID: nil, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .schemaUnavailable)
        }
        XCTAssertThrowsError(try unmigrated.beginMailIntentDispatch(operationID: opID(1), route: .node, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .schemaUnavailable)
        }
        XCTAssertThrowsError(try unmigrated.recordMailIntentOutcome(operationID: opID(1), state: .confirmed, now: Date())) {
            XCTAssertEqual($0 as? NodeMailModeStoreError, .schemaUnavailable)
        }
        // With no table there are truly no intents.
        XCTAssertEqual(try unmigrated.mailIntents(accountID: account.id, states: [.pending]), [])
        XCTAssertEqual(try unmigrated.mailIntentsWaitingForNode(messageIDs: [MessageID("m1")]), [])
        XCTAssertEqual(try unmigrated.rerouteUnstartedDirectIntents(accountID: account.id, now: Date()), [])
        XCTAssertEqual(try unmigrated.markNodeIntentsUnconfirmed(accountID: account.id, now: Date()), 0)
        XCTAssertEqual(try unmigrated.supersedePendingCredentialPushes(accountID: account.id, keeping: opID(1), now: Date()), 0)
        XCTAssertEqual(try unmigrated.recoverInterruptedMailIntentDispatches(dispatchedBefore: Date(), now: Date()), 0)

        // Another process adds the table: the unmigrated instance picks it up.
        let migrating = try SQLiteMailStore(path: url.path)
        try migrating.migrate()
        XCTAssertTrue(migrating.mailIntentJournalAvailable)
        XCTAssertTrue(unmigrated.mailIntentJournalAvailable)
        XCTAssertEqual(try unmigrated.journalMailIntent(operationID: opID(1), accountID: account.id, kind: .archive,
                                                        messageID: MessageID("m1"), draftID: nil, now: Date()).state, .pending)
    }

    func testUnreadableJournalProbeFailsClosedAndNeverDowngradesAnAvailableJournal() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        let admitted = try drive(store: store, accountID: account.id, id: opID(1), to: .admitted, route: .node, kind: .archive,
                                 messageID: MessageID("m1"))
        try store.databasePool.write { database in
            try database.execute(sql: """
                ALTER TABLE grdb_migrations RENAME TO grdb_migrations_saved;
                CREATE VIEW grdb_migrations AS SELECT identifier FROM missing_ledger;
                """)
        }

        let unmigrated = try SQLiteMailStore(path: url.path)
        XCTAssertFalse(unmigrated.mailIntentJournalAvailable)
        XCTAssertThrowsError(try unmigrated.mailIntentsWaitingForNode(messageIDs: [MessageID("m1")]))
        XCTAssertThrowsError(try unmigrated.mailIntents(accountID: account.id, states: [.admitted]))
        XCTAssertThrowsError(try unmigrated.rerouteUnstartedDirectIntents(accountID: account.id, now: Date()))
        XCTAssertThrowsError(try unmigrated.markNodeIntentsUnconfirmed(accountID: account.id, now: Date()))
        XCTAssertThrowsError(try unmigrated.supersedePendingCredentialPushes(accountID: account.id, keeping: opID(2), now: Date()))
        XCTAssertThrowsError(try unmigrated.recoverInterruptedMailIntentDispatches(dispatchedBefore: Date(), now: Date()))
        XCTAssertThrowsError(try unmigrated.beginMailIntentDispatch(operationID: admitted, route: .direct, now: Date()))
        XCTAssertThrowsError(try unmigrated.journalMailIntent(operationID: opID(2), accountID: account.id, kind: .archive,
                                                              messageID: MessageID("m2"), draftID: nil, now: Date())) {
            XCTAssertNotEqual($0 as? NodeMailModeStoreError, .schemaUnavailable)
        }

        // The instance that already saw the journal keeps using it.
        XCTAssertTrue(store.mailIntentJournalAvailable)
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: [MessageID("m1")]), [MessageID("m1")])
    }

    func testFailedReRunKeepsAnAvailableJournal() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        let failNext = LockedFlag()
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationFailpoint: {
            if failNext.value { throw NodeMailModeStoreError.schemaUnavailable }
        })
        try store.migrate()
        let account = Account(id: AccountID("acc-journal"), displayName: "Journal", email: EmailAddress("j@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        _ = try drive(store: store, accountID: account.id, id: opID(1), to: .admitted, route: .node, kind: .archive,
                      messageID: MessageID("m1"))
        failNext.value = true
        XCTAssertNoThrow(try store.migrate())
        XCTAssertTrue(store.mailIntentJournalAvailable)
        XCTAssertFalse(store.auditEntries.contains { $0.action == "node_mode.schema_unavailable" })
        XCTAssertEqual(try store.mailIntentsWaitingForNode(messageIDs: [MessageID("m1")]), [MessageID("m1")])
    }

    func testJournalMigrationFailingAfterItsDDLRollsBackAndRetriesOnNextLaunch() throws {
        let url = makeStoreURL()
        defer { removeStoreArtifacts(at: url) }
        // The body failpoint runs in every Node-mode migration body; pass v1, fail v2.
        struct SecretBearingError: Error, CustomStringConvertible {
            var description: String { "token=do-not-log" }
        }
        let calls = LockedCounter()
        let store = try SQLiteMailStore(path: url.path, nodeModeMigrationBodyFailpoint: {
            if calls.increment() == 2 { throw SecretBearingError() }
        })
        XCTAssertNoThrow(try store.migrate())
        XCTAssertEqual(calls.value, 2)
        // v1 applied, v2 rolled back: audited, naming only the missing migration.
        let audits = store.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }
        XCTAssertEqual(audits.map(\.targetID), [Self.v2Migration])
        XCTAssertEqual(audits.map(\.targetType), ["node_mode"])
        XCTAssertFalse(String(describing: audits).contains("do-not-log"))
        XCTAssertFalse(try String(contentsOf: store.auditLogURL, encoding: .utf8).contains("do-not-log"))

        XCTAssertTrue(store.nodeModeSchemaAvailable)
        XCTAssertFalse(store.mailIntentJournalAvailable)
        XCTAssertEqual(try journalLeftovers(store), [])
        XCTAssertEqual(try nodeModeIdentifiers(store), ["node-mode-v1-account-sources"])

        let relaunched = try SQLiteMailStore(path: url.path)
        try relaunched.migrate()
        XCTAssertTrue(relaunched.mailIntentJournalAvailable)
        XCTAssertEqual(relaunched.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }.count, 1)
        XCTAssertEqual(try nodeModeIdentifiers(relaunched), ["node-mode-v1-account-sources", Self.v2Migration, "node-mode-v3-mirror", "node-mode-v4-mail-intent-folder-actions"])
        XCTAssertEqual(try journalLeftovers(relaunched).sorted(),
                       ["mail_intent_journal", "mail_intent_journal_account_state", "mail_intent_journal_message"])
    }

    func testJournalUpgradeFailureOverAnExistingV1SchemaKeepsSourcesIntact() throws {
        let (store, url, account) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: "30000000-0000-4000-8000-000000000801", logicalMailboxID: String(repeating: "A", count: 43),
            providerIdentity: "p"), expectedGeneration: 0)
        try removeJournalMigration(store)

        // Only the v2 body runs on this upgrade, and it fails after its DDL.
        let upgrading = try SQLiteMailStore(path: url.path, nodeModeMigrationBodyFailpoint: {
            throw NodeMailModeStoreError.schemaUnavailable
        })
        XCTAssertNoThrow(try upgrading.migrate())
        XCTAssertFalse(upgrading.mailIntentJournalAvailable)
        XCTAssertEqual(upgrading.auditEntries.filter { $0.action == "node_mode.schema_unavailable" }.map(\.targetID),
                       [Self.v2Migration])
        XCTAssertEqual(try journalLeftovers(upgrading), [])
        XCTAssertTrue(upgrading.nodeModeSchemaAvailable)
        XCTAssertEqual(try upgrading.mailSource(accountID: account.id).generation, 1)
        XCTAssertFalse(upgrading.runsDirectSync(accountID: account.id))
    }

    func testJournalMigrationIsRegisteredAfterAccountSourcesWithImmediateForeignKeys() throws {
        let (store, url, _) = try makeJournalStore(testName: #function)
        defer { removeStoreArtifacts(at: url) }
        XCTAssertEqual(try nodeModeIdentifiers(store), ["node-mode-v1-account-sources", Self.v2Migration, "node-mode-v3-mirror", "node-mode-v4-mail-intent-folder-actions"])
        // Deferred checks would fail the whole migration on an unrelated orphan row.
        try removeJournalMigration(store)
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
        XCTAssertTrue(relaunched.mailIntentJournalAvailable)
    }

    // MARK: - Helpers

    private func makeJournalStore(testName: String) throws -> (SQLiteMailStore, URL, Account) {
        let url = makeStoreURL()
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc-journal"), displayName: "Journal", email: EmailAddress("j@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        return (store, url, account)
    }

    private func opID(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }

    /// Journals an intent and drives it through public APIs to `state`.
    @discardableResult
    private func drive(
        store: SQLiteMailStore, accountID: AccountID, id: String, to state: MailIntentState, route: MailIntentRoute?,
        kind: MailIntentKind, messageID: MessageID? = nil, at time: Date = Date(timeIntervalSince1970: 1)
    ) throws -> String {
        let isDraftKind = kind == .send || kind == .saveDraft
        let messageID = kind == .credentialPush || isDraftKind ? nil : (messageID ?? MessageID("m-\(id)"))
        let draftID = isDraftKind ? DraftID("d-\(id)") : nil
        _ = try store.journalMailIntent(operationID: id, accountID: accountID, kind: kind, messageID: messageID,
                                        draftID: draftID, now: time)
        switch (state, route) {
        case (.pending, nil):
            return id
        case (.failed, nil):
            if kind == .credentialPush {
                XCTAssertEqual(try store.supersedePendingCredentialPushes(accountID: accountID, keeping: opID(999_999), now: time), 1)
            } else {
                _ = try store.refuseUnroutedMailIntent(operationID: id, now: time)
            }
            return id
        case (.unconfirmed, .node?):
            _ = try store.beginMailIntentDispatch(operationID: id, route: .node, now: time)
            _ = try store.recordMailIntentOutcome(operationID: id, state: .uncertain, now: time)
            _ = try store.recordMailIntentOutcome(operationID: id, state: .unconfirmed, now: time)
            return id
        case (.unconfirmedAfterRemoval, .node?):
            _ = try store.beginMailIntentDispatch(operationID: id, route: .node, now: time)
            XCTAssertEqual(try store.markNodeIntentsUnconfirmed(accountID: accountID, now: time), 1)
            return id
        case (_, let route?):
            _ = try store.beginMailIntentDispatch(operationID: id, route: route, now: time)
            if state == .dispatching { return id }
            if state == .uncertain || state == .confirmed || state == .failed {
                _ = try store.recordMailIntentOutcome(operationID: id, state: state, now: time)
            } else if state == .admitted {
                _ = try store.recordMailIntentOutcome(operationID: id, state: .admitted, now: time)
            }
            return id
        default:
            throw NodeMailModeStoreError.invalidMailIntent
        }
    }

    private func allIntents(_ store: SQLiteMailStore, accounts: [AccountID]) throws -> [String: MailIntentRecord] {
        var result: [String: MailIntentRecord] = [:]
        for account in accounts {
            for record in try store.mailIntents(accountID: account, states: Set(MailIntentState.allCases)) {
                result[record.operationID] = record
            }
        }
        return result
    }

    /// Simulates a database written before `node-mode-v2-mail-intent-journal` existed.
    private func removeJournalMigration(_ store: SQLiteMailStore) throws {
        try store.databasePool.write { database in
            try database.execute(sql: "DROP TABLE mail_intent_journal")
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [Self.v2Migration])
        }
    }

    private func journalLeftovers(_ store: SQLiteMailStore) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE name IN ('mail_intent_journal', 'mail_intent_journal_account_state', 'mail_intent_journal_message')
                """)
        }
    }

    private func nodeModeIdentifiers(_ store: SQLiteMailStore) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(database, sql: """
                SELECT identifier FROM grdb_migrations WHERE identifier LIKE 'node-mode-%' ORDER BY rowid
                """)
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

    private final class LockedWinners: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: [MailIntentRoute?]] = [:]
        var snapshot: [String: [MailIntentRoute?]] { lock.withLock { stored } }
        func add(id: String, route: MailIntentRoute?) { lock.withLock { stored[id, default: []].append(route) } }
    }

    private func makeStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-journal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("plainpost.sqlite")
    }

    private func removeStoreArtifacts(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
