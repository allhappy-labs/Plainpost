import Foundation
import GRDB
import PlainpostAccountProtocol
import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
import PlainpostNodeTransport
import XCTest

final class NodeMailMirrorTests: XCTestCase {
    // MARK: - Plan tests

    func testDirectRowAndMirroredRowResolveToOneMessageWithoutRenotifying() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let direct = try harness.commitDirect(rfcMessageID: "<m1@example.test>", mailboxPath: "INBOX", uidValidity: 7, uid: 42, notify: true)
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).count, 1)
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "node-msg-1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 42, ["seen"])])

        let result = try await harness.mirror.runPass()

        XCTAssertTrue(result.bootstrapped)
        XCTAssertEqual(harness.store.messages.filter { $0.id == direct }.count, 1)
        XCTAssertEqual(harness.store.messages.count, 1)
        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "node-msg-1", accountID: harness.accountID), direct)
        XCTAssertTrue(try XCTUnwrap(harness.store.messages.first { $0.id == direct }).isSeen)
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).count, 1)
    }

    func testStaleDeltaCursorTriggersFullRemirrorWithoutDuplicates() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<a@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        harness.server.failNextDeltaWithStaleCursor()
        harness.server.addMessage(nodeID: "n2", rfcMessageID: "<b@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(Set(harness.store.messages.map(\.rfcMessageID)), ["<a@example.test>", "<b@example.test>"])
        XCTAssertEqual(harness.store.messages.count, 2)
        // The re-mirror resolved n1 to its existing row, so only n2, new mail
        // that arrived while the cursor was stale, notified.
        let n2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "n2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).map(\.messageID), [n2])
    }

    // MARK: - Folders

    func testMirroredFoldersBecomeTheAccountsFoldersOnce() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.store.cacheMailboxes([Mailbox(id: MailboxID("direct-inbox"), accountID: harness.accountID,
                                                  name: "INBOX", path: "INBOX", specialUse: "\\Inbox")])
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<n1@example.test>",
                                  memberships: [("INBOX", 7, 1, []), ("[Gmail]/Sent Mail", 8, 1, [])])
        harness.server.addMessage(nodeID: "n2", rfcMessageID: "<n2@example.test>", memberships: [("Receipts/2026", 9, 1, [])])
        _ = try await harness.mirror.runPass()
        let folders = try harness.store.mailboxes(limit: 20, accountID: harness.accountID)
        XCTAssertEqual(folders.filter { $0.path == "INBOX" }.map(\.id), [MailboxID("direct-inbox")], "an existing folder stays as it is")
        let sent = try XCTUnwrap(folders.first { $0.path == "[Gmail]/Sent Mail" })
        XCTAssertEqual(sent.name, "Sent Mail")
        XCTAssertEqual(sent.specialUse, "\\Sent")
        let receipts = try XCTUnwrap(folders.first { $0.path == "Receipts/2026" })
        XCTAssertEqual(receipts.name, "2026")
        XCTAssertNil(receipts.specialUse)
        // A second pass adds nothing.
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.mailboxes(limit: 20, accountID: harness.accountID).count, folders.count)
    }

    // MARK: - Recent-mail window

    /// `count` messages, one minute apart; `m0` is the newest.
    private func addHistory(_ harness: NodeMailMirrorHarness, count: Int, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        for index in 0..<count {
            harness.server.addMessage(nodeID: "m\(index)", rfcMessageID: "<m\(index)@example.test>",
                                      memberships: [("INBOX", 7, UInt32(count - index), [])],
                                      receivedAt: start.addingTimeInterval(Double(-60 * index)))
        }
    }

    func testAWindowMirrorsOnlyTheNewestMessages() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 40, window: 100)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        addHistory(harness, count: 450)
        var passes = 0
        repeat {
            _ = try await harness.mirror.runPass()
            passes += 1
        } while try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete != true && passes < 20
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        XCTAssertEqual(harness.store.messages.count, 100)
        XCTAssertEqual(Set(harness.store.messages.compactMap(\.rfcMessageID)),
                       Set((0..<100).map { "<m\($0)@example.test>" }), "the newest hundred")
    }

    func testAChangeToAnOldMessageOutsideTheWindowAddsNothing() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, window: 10)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        addHistory(harness, count: 30)
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(harness.store.messages.count, 10)
        harness.server.setMemberships(nodeID: "m25", [("INBOX", 7, 5, ["flagged"])])
        _ = try await harness.mirror.runPass()
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m25", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.count, 10)
    }

    func testNewMailAndChangesInsideTheWindowStillArrive() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, window: 10)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        addHistory(harness, count: 30)
        _ = try await harness.mirror.runPass()
        harness.server.addMessage(nodeID: "new", rfcMessageID: "<new@example.test>", memberships: [("INBOX", 7, 100, [])],
                                  receivedAt: Date(timeIntervalSince1970: 1_800_000_600))
        harness.server.setMemberships(nodeID: "m3", [("INBOX", 7, 27, ["seen"])])
        _ = try await harness.mirror.runPass()
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "new", accountID: harness.accountID))
        let m3 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m3", accountID: harness.accountID))
        XCTAssertTrue(try XCTUnwrap(harness.store.messages.first { $0.id == m3 }).isSeen)
        XCTAssertEqual(harness.store.messages.count, 11)
    }

    func testNoWindowMirrorsTheWholeHistory() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        addHistory(harness, count: 120)
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(harness.store.messages.count, 120)
    }

    // MARK: - Bootstrap

    func testChangesDuringBootstrapAreReplayed() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        // A message arrives right after the last snapshot page, so no
        // snapshot page contains it: only the replay from the cursor captured
        // before the snapshot can deliver it.
        let added = Counter()
        harness.server.onAfterSnapshot { _, next in
            guard next.isEmpty, added.value == 0 else { return }
            added.increment()
            harness.server.addMessage(nodeID: "a0", rfcMessageID: "<a0@example.test>", memberships: [("INBOX", 7, 3, [])])
        }

        let result = try await harness.mirror.runPass()

        XCTAssertTrue(result.bootstrapped)
        XCTAssertFalse(harness.server.snapshotServed.contains("a0"))
        XCTAssertEqual(Set(harness.store.messages.compactMap(\.rfcMessageID)),
                       ["<m1@example.test>", "<m2@example.test>", "<a0@example.test>"])
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        XCTAssertEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID)?.complete, true)
    }

    func testAccountSeededAfterTheCursorCompletedIsSnapshottedWithoutRecapturingTheDeltaCursor() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "a1", rfcMessageID: "<a1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        harness.server.addMessage(nodeID: "a2", rfcMessageID: "<a2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        let cursor = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        XCTAssertTrue(cursor.complete)

        let second = try harness.addAccount("acc-second")
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 3, 1, [])],
                                  logical: FakeNodeMailServer.accountB, publish: false)
        // A change lands after the last pass: the Node tail moves past the stored cursor.
        harness.server.addMessage(nodeID: "a3", rfcMessageID: "<a3@example.test>", memberships: [("INBOX", 7, 3, [])])
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        try await harness.mirror.seedCursor(accountID: second, logicalMailboxID: harness.key(FakeNodeMailServer.accountB))

        let seeded = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        XCTAssertEqual(seeded.deltaCursor, cursor.deltaCursor, "seeding keeps the existing replay start")
        XCTAssertFalse(seeded.complete)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)

        let result = try await harness.mirror.runPass()
        XCTAssertTrue(result.bootstrapped)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "b1", accountID: second))
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "a3", accountID: harness.accountID),
                        "the change after the stored cursor is replayed, not skipped by a recapture")
        XCTAssertTrue(try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID)).complete)
    }

    func testCoordinateConflictSplitsTheBatchAndSkipsOnlyTheConflictingMessage() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 7, UInt32(index + 1), [])])
        }
        harness.server.setConflicting(["m2"])
        // A snapshot message without coordinates right now is skipped, not guessed.
        harness.server.addMessage(nodeID: "m4", rfcMessageID: "<m4@example.test>", memberships: [("INBOX", 7, 4, [])])
        harness.server.hideCoordinates(nodeID: "m4")

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.coordinateConflicts, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(Set(harness.store.messages.compactMap(\.rfcMessageID)), ["<m1@example.test>", "<m3@example.test>"])
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true,
                       "one message never stalls bootstrap")
    }

    // MARK: - Account scope

    func testCoordinatesAndChangesOfAForeignLogicalMailboxAreIgnored() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  foreignMemberships: [(FakeNodeMailServer.foreignAccount, "INBOX", 9, 99)])
        _ = try await harness.mirror.runPass()
        harness.server.addMessage(nodeID: "f1", rfcMessageID: "<f1@example.test>", memberships: [("INBOX", 9, 1, [])],
                                  logical: FakeNodeMailServer.foreignAccount)
        harness.server.clearRequests()
        _ = try await harness.mirror.runPass()

        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(try harness.memberships(messageID), ["INBOX|7|1"])
        XCTAssertEqual(harness.store.messages.count, 1)
        XCTAssertFalse(harness.server.requests.contains { $0.hasPrefix("GET /v1/mail/messages/") })
    }

    func testTwoAccountsOnOneNodeStaySeparated() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let second = try harness.addAccount("acc-second")
        try harness.flipToNode()
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        // The same Gmail message in both accounts: the Node namespaces the
        // second account's raw ID (Task 4), and both carry one RFC Message-ID.
        harness.server.addMessage(nodeID: "18f2a", rfcMessageID: "<same@example.test>", memberships: [("INBOX", 1, 5, [])])
        harness.server.addMessage(nodeID: "gm2.ns.18f2a", rfcMessageID: "<same@example.test>", memberships: [("INBOX", 1, 5, ["seen"])],
                                  logical: FakeNodeMailServer.accountB)

        _ = try await harness.mirror.runPass()

        let first = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "18f2a", accountID: harness.accountID))
        let other = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "gm2.ns.18f2a", accountID: second))
        XCTAssertNotEqual(first, other)
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "18f2a", accountID: second))
        XCTAssertEqual(try harness.accountOf(first), harness.accountID.rawValue)
        XCTAssertEqual(try harness.accountOf(other), second.rawValue)
        XCTAssertEqual(harness.store.messages.first { $0.id == first }?.isSeen, false)
        XCTAssertEqual(harness.store.messages.first { $0.id == other }?.isSeen, true)
    }

    func testMirrorNeverWritesIntoADirectAccount() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        // Only the second account is Node-backed; the Node also serves the
        // first account's logical mailbox.
        let second = try harness.addAccount("acc-second")
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "a1", rfcMessageID: "<a1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 3, 1, [])],
                                  logical: FakeNodeMailServer.accountB)

        _ = try await harness.mirror.runPass()

        XCTAssertNil(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID))
        XCTAssertEqual(try harness.messageIDs(accountID: harness.accountID), [])
        XCTAssertEqual(try harness.messageIDs(accountID: second).count, 1)
    }

    func testMirrorOfAnotherNodeTouchesNoAccountBoundElsewhere() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let current = try harness.store.mailSource(accountID: harness.accountID)
        _ = try harness.store.replaceMailSource(current.nodeBacked(
            nodeID: "50000000-0000-4000-8000-000000000999",
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(FakeNodeMailServer.accountA),
            providerIdentity: "p@example.test"), expectedGeneration: current.generation)
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.committed, 0)
        XCTAssertEqual(harness.store.messages.count, 0)
        XCTAssertNil(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID))
        XCTAssertEqual(harness.server.requests, [])
    }

    func testFlipToDirectMidPageStopsThePassWithoutWritingOrAdvancingTheCursor() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        let cursor = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        let gate = harness.server.hold("/v1/mail/mirror/coordinates")
        let pass = Task { try await harness.mirror.runPass() }
        try await waitUntil { gate.hasArrived }
        try harness.flipToDirect()
        gate.release()

        do {
            _ = try await pass.value
            XCTFail("the pass must stop")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.count, 1)
        XCTAssertEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID), cursor)
    }

    // MARK: - Identity

    func testMissingRFCMessageIDUsesTheCoordinateDerivedIDThatMatchesDirectSync() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let direct = try harness.commitDirect(rfcMessageID: nil, mailboxPath: "INBOX", uidValidity: 7, uid: 5, notify: false)
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: nil, memberships: [("INBOX", 7, 5, [])])
        harness.server.addMessage(nodeID: "n2", rfcMessageID: nil, memberships: [("Archive", 7, 9, []), ("INBOX", 7, 6, [])])

        _ = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID), direct)
        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "n2", accountID: harness.accountID),
                       MessageID(IMAPSyncService.localMessageID(accountID: harness.accountID, mailboxPath: "Archive", uidValidity: 7, uid: 9)))
        XCTAssertEqual(harness.store.messages.count, 2)
    }

    func testIdentityMismatchIsCountedAndNeverOverwrites() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let direct = try harness.commitDirect(rfcMessageID: "<local@example.test>", mailboxPath: "INBOX", uidValidity: 7, uid: 42, notify: false)
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<other@Example.TEST>", memberships: [("INBOX", 7, 42, ["seen"])])

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.identityMismatches, 1)
        XCTAssertEqual(harness.store.messages.map(\.id), [direct])
        XCTAssertEqual(harness.store.messages.first?.rfcMessageID, "<local@example.test>")
        XCTAssertEqual(harness.store.messages.first?.isSeen, false)
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID))
    }

    func testMessageIDDomainCaseDoesNotCountAsAMismatch() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let direct = try harness.commitDirect(rfcMessageID: "<Local@example.test>", mailboxPath: "INBOX", uidValidity: 7, uid: 42, notify: false)
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: "<Local@EXAMPLE.test>", memberships: [("INBOX", 7, 42, [])])

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.identityMismatches, 0)
        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID), direct)
    }

    func testUIDValidityChangeReKeysMembershipsOnlyAfterTheNewBaseline() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))

        // The epoch resets: the retired coordinates vanish and a removal is
        // published, but the new baseline has not recorded anything yet.
        harness.server.epochReset()
        harness.server.setMemberships(nodeID: "m1", [], publish: false)
        harness.server.removeMembership(nodeID: "m1", path: "INBOX")
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.memberships(messageID), ["INBOX|7|1"], "omission during a reset never removes")
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.reconcileState, .awaitingBaseline)

        harness.server.setMemberships(nodeID: "m1", [("INBOX", 8, 10, [])], publish: false)
        harness.server.baselineComplete()
        _ = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.memberships(messageID), ["INBOX|8|10"])
        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID), messageID)
        XCTAssertEqual(harness.store.messages.count, 1)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.reconcileState, NodeMirrorReconcileState.none)
    }

    func testUnicodeMailboxPathsMatchDirectRowsByteForByte() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        // IMAP LIST sends modified UTF-7 unless UTF8=ACCEPT is enabled, and
        // neither side decodes it; a raw UTF-8 name is kept as sent too.
        let encoded = try harness.commitDirect(rfcMessageID: nil, mailboxPath: "Entw&APw-rfe", uidValidity: 4, uid: 1, notify: false)
        let utf8 = try harness.commitDirect(rfcMessageID: nil, mailboxPath: "Entwürfe", uidValidity: 5, uid: 1, notify: false)
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "n1", rfcMessageID: nil, memberships: [("Entw&APw-rfe", 4, 1, [])])
        harness.server.addMessage(nodeID: "n2", rfcMessageID: nil, memberships: [("Entwürfe", 5, 1, [])])

        _ = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "n1", accountID: harness.accountID), encoded)
        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "n2", accountID: harness.accountID), utf8)
        XCTAssertEqual(harness.store.messages.count, 2)
        XCTAssertEqual(NodeMailMirrorMapping.mailboxPathKey("Entw&APw-rfe"), "Entw&APw-rfe")
        // Canonically equivalent spellings stay distinct bytes, as in the stable-key lookup.
        let decomposed = "Entwu\u{0308}rfe"
        XCTAssertEqual(Array(NodeMailMirrorMapping.mailboxPathKey(decomposed).utf8), Array(decomposed.utf8))
    }

    // MARK: - Deltas

    func testNotificationsOnlyForFreshInboxDeltasAfterBootstrap() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).count, 0, "bootstrap establishes the watermark")

        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.addMessage(nodeID: "m3", rfcMessageID: "<m3@example.test>", memberships: [("Archive", 7, 3, [])])
        harness.server.addMessage(nodeID: "m4", rfcMessageID: "<m4@example.test>", memberships: [("INBOX", 7, 4, [])],
                                  receivedAt: Date().addingTimeInterval(-3_600))
        harness.server.setMemberships(nodeID: "m1", [("INBOX", 7, 1, ["seen"])])
        _ = try await harness.mirror.runPass()

        let m2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).map(\.messageID), [m2])
    }

    func testRemovalsTombstonesAndOmissions() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("Archive", 7, 9, []), ("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.addMessage(nodeID: "m3", rfcMessageID: "<m3@example.test>", memberships: [("INBOX", 7, 3, [])])
        _ = try await harness.mirror.runPass()
        let m1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        let m2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        let m3 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m3", accountID: harness.accountID))

        // Omission alone never removes: m3 is served but its coordinates are
        // omitted when an upsert arrives.
        harness.server.hideCoordinates(nodeID: "m3")
        harness.server.touch(nodeID: "m3")
        var result = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.memberships(m3), ["INBOX|7|3"])
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m3", accountID: harness.accountID))
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.skipped, 1)
        harness.server.hideCoordinates(nodeID: "m3", false)

        // m1 leaves INBOX but stays archived; m2 loses its last membership.
        harness.server.removeMembership(nodeID: "m1", path: "INBOX")
        harness.server.removeMembership(nodeID: "m2", path: "INBOX")
        result = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.memberships(m1), ["Archive|7|9"])
        XCTAssertEqual(try harness.memberships(m2), [])
        XCTAssertEqual(harness.store.messages.first { $0.id == m2 }?.isDeleted, true)
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(result.removed, 1)

        harness.server.tombstone(nodeID: "m3")
        result = try await harness.mirror.runPass()
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(try harness.memberships(m3), [])
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.reconcileState, NodeMirrorReconcileState.none)
    }

    func testCancellationMidPageLeavesTheCursorUnchanged() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        let cursor = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.addMessage(nodeID: "m3", rfcMessageID: "<m3@example.test>", memberships: [("INBOX", 7, 3, [])])

        let gate = harness.server.hold("/v1/mail/mirror/coordinates")
        let pass = Task { try await harness.mirror.runPass() }
        try await waitUntil { gate.hasArrived }
        pass.cancel()
        gate.release()
        do {
            _ = try await pass.value
            XCTFail("the cancelled pass must not complete")
        } catch {}

        XCTAssertEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID), cursor)
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        // The next pass replays the same page.
        _ = try await harness.mirror.runPass()
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m3", accountID: harness.accountID))
    }

    func testCancellationDuringBootstrapKeepsTheSnapshotCursor() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let gate = harness.server.hold("/v1/mail/mirror/coordinates")
        let pass = Task { try await harness.mirror.runPass() }
        try await waitUntil { gate.hasArrived }
        pass.cancel()
        gate.release()
        _ = try? await pass.value
        let row = try XCTUnwrap(harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID))
        XCTAssertEqual(row.snapshotCursor, "")
        XCTAssertFalse(row.complete)
    }

    // MARK: - Hydration

    func testOversizedBodyIsHydratedLater() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "big", rfcMessageID: "<big@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  text: "A very long body", html: "<p>A very long body</p>", omitBodiesInPages: true)
        _ = try await harness.mirror.runPass()
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "big", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.first { $0.id == messageID }?.body, "")
        XCTAssertEqual(try harness.store.pendingMirrorHydration(accountID: harness.accountID, limit: 5).count, 1)

        let hydrated = try await harness.mirror.hydrate(limit: 50)

        XCTAssertEqual(hydrated, 1)
        let stored = try XCTUnwrap(harness.store.messages.first { $0.id == messageID })
        XCTAssertEqual(stored.body, "A very long body")
        XCTAssertEqual(stored.bodyHTML, "<p>A very long body</p>")
        XCTAssertEqual(try harness.store.pendingMirrorHydration(accountID: harness.accountID, limit: 5), [])
    }

    func testHydrationFailureIsRetriedOnALaterPass() async throws {
        let clock = LockedDate(Date())
        let harness = try await NodeMailMirrorHarness.make(testName: #function, clock: clock)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "big", rfcMessageID: "<big@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  omitBodiesInPages: true)
        _ = try await harness.mirror.runPass()
        harness.server.fail("/v1/mail/messages/", with: .invalidRequest)
        let failed = try await harness.mirror.hydrate(limit: 50)
        XCTAssertEqual(failed, 0)
        clock.value = clock.value.addingTimeInterval(60)
        XCTAssertEqual(try harness.store.pendingMirrorHydration(accountID: harness.accountID, limit: 5, now: clock.value).map(\.state), [.failed])
        let retried = try await harness.mirror.hydrate(limit: 50)
        XCTAssertEqual(retried, 1)
    }

    func testAttachmentPayloadBoundsAreEnforced() async throws {
        XCTAssertEqual(NodeMailMirror.Limits().attachmentBytes, 50 * 1_024 * 1_024)
        XCTAssertEqual(NodeMailMirror.Limits().aggregateAttachmentBytes, 100 * 1_024 * 1_024)
        var limits = NodeMailMirror.Limits()
        limits.attachmentBytes = 5
        limits.aggregateAttachmentBytes = 8
        let harness = try await NodeMailMirrorHarness.make(testName: #function, limits: limits)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        let attachments = [("a1", "1234"), ("a2", "123456"), ("a3", "abcd"), ("a4", "z")].map { id, bytes in
            FakeNodeMailServer.Attachment(
                metadata: NodeSyncAttachment(contentDigest: nil, contentID: nil, disposition: "attachment",
                                             filename: id + ".txt", id: id, mime: "text/plain", size: String(bytes.utf8.count)),
                bytes: Data(bytes.utf8)
            )
        }
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  attachments: attachments)
        _ = try await harness.mirror.runPass()

        let hydrated = try await harness.mirror.hydrate(limit: 50)
        XCTAssertEqual(hydrated, 1)

        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        let stored = try harness.store.incomingMessageAttachments(messageID: messageID)
        XCTAssertEqual(stored.map(\.filename), ["a1.txt", "a3.txt"])
        XCTAssertEqual(stored.map(\.data), [Data("1234".utf8), Data("abcd".utf8)])
        XCTAssertFalse(harness.server.requests.contains { $0.hasSuffix("/a2") || $0.hasSuffix("/a4") },
                       "out-of-bounds attachments are never downloaded")
    }

    // MARK: - Schema

    func testUnavailableMirrorSchemaStopsThePassBeforeAnyNodeRequest() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        try await harness.store.databasePool.write { database in
            for table in ["node_mirror_attachment_links", "node_mirror_membership_links", "node_mirror_message_links",
                          "node_mirror_account_bootstrap", "node_mirror_cursors"] {
                try database.execute(sql: "DROP TABLE \(table)")
            }
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'node-mode-v3-mirror'")
        }
        let reopened = try SQLiteMailStore(path: harness.url.path)
        let mirror = NodeMailMirror(store: reopened, client: NodeSyncClient(sender: harness.server), nodeID: NodeMailMirrorHarness.nodeID)
        do {
            _ = try await mirror.runPass()
            XCTFail("expected schemaUnavailable")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .schemaUnavailable)
        }
        XCTAssertEqual(harness.server.requests, [])
    }

    // MARK: - Loop

    func testLoopKeepsMirroringInTheServiceWithoutAnyAppProcess() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        // Service-only composition: the store, the broker and the loop.
        let broker = harness.broker()
        let loop = NodeMailMirrorLoop(store: harness.store, broker: broker) { nodeID, client in
            NodeMailMirror(store: harness.store, client: client, nodeID: nodeID)
        }
        await loop.start()
        try await waitUntil { (try? harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID)) != nil }
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        await loop.wake()
        try await waitUntil { (try? harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID)) != nil }
        await loop.stop()
    }

    func testLoopOwnsOneMirrorPerNodeAndAWakeDuringAPassQueuesOneFollowUp() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let created = Counter()
        let loop = harness.loop(sessions: harness.broker(), created: created)
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }
        let owned = try await XCTUnwrapAsync(await loop.ownedMirror(nodeID: NodeMailMirrorHarness.nodeID))
        let cyclesBefore = await loop.cycles

        let gate = harness.server.hold("/v1/mail/deltas")
        await loop.wake()
        try await waitUntil { gate.hasArrived }
        await loop.wake()
        await loop.wake()
        await loop.wake()
        gate.release()
        try await waitUntil { await loop.cycles == cyclesBefore + 2 }
        try await Task.sleep(for: .milliseconds(200))
        let cyclesAfter = await loop.cycles
        XCTAssertEqual(cyclesAfter, cyclesBefore + 2, "three wakes during a pass queue exactly one follow-up")
        XCTAssertEqual(created.value, 1)
        let stillOwned = try await XCTUnwrapAsync(await loop.ownedMirror(nodeID: NodeMailMirrorHarness.nodeID))
        XCTAssertTrue(owned === stillOwned)

        // The handover seeds through the same mirror, before the flip.
        let second = try harness.addAccount("acc-second")
        try await loop.seedCursor(nodeID: NodeMailMirrorHarness.nodeID.uppercased(), accountID: second,
                                  logicalMailboxID: harness.key(FakeNodeMailServer.accountB))
        XCTAssertEqual(created.value, 1)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)
        await loop.stop()
    }

    func testLoopOwnWritesDoNotWakeIt() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let loop = harness.loop(sessions: harness.broker())
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }
        let cycles = await loop.cycles
        MailStoreChangeSignal.post(scope: .mailbox)
        MailStoreChangeSignal.post(scope: .operations)
        try await Task.sleep(for: .milliseconds(300))
        let after = await loop.cycles
        XCTAssertEqual(after, cycles)
        await loop.stop()
    }

    func testLoopStopsMirroringWhenTheAccountFlipsToDirect() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let loop = harness.loop(sessions: harness.broker())
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }

        try harness.flipToDirect()     // posts .accounts
        try await waitUntil { await loop.lastOutcome == .idle }
        let owned = await loop.ownedMirror(nodeID: NodeMailMirrorHarness.nodeID)
        XCTAssertNil(owned)
        harness.server.clearRequests()
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        await loop.wake()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.server.requests, [], "no Node request without a Node-backed account")
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        await loop.stop()
    }

    func testLoopStopsMirroringWhenTheNodeBindingChanges() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let currentNode = LockedString(NodeMailMirrorHarness.nodeID)
        let broker = NodeSessionBroker(resolveSender: { [server = harness.server] in (currentNode.value, server) },
                                       check: { NodeSessionCheck(admission: .readWrite, binding: currentNode.value) },
                                       identityReadiness: { .ready })
        let loop = harness.loop(sessions: broker)
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }

        // The broker now reaches a replacement Node the accounts are not bound to.
        currentNode.value = "50000000-0000-4000-8000-000000000999"
        harness.server.clearRequests()
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        let before = await loop.cycles
        await loop.wake()
        try await waitUntil { await loop.cycles > before }
        try await Task.sleep(for: .milliseconds(200))
        let owned = await loop.ownedMirror(nodeID: NodeMailMirrorHarness.nodeID)
        XCTAssertNil(owned)
        let replacement = await loop.ownedMirror(nodeID: currentNode.value)
        XCTAssertNil(replacement, "no mirror for a Node no account is bound to")
        XCTAssertFalse(harness.server.requests.contains { $0.contains("/v1/mail/") })
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        await loop.stop()
    }

    func testLoopBacksOffWithJitterWhenTheBrokerRefusesAdmission() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        let broker = NodeSessionBroker(resolveSender: { [server = harness.server] in (NodeMailMirrorHarness.nodeID, server) },
                                       check: { throw NodeSessionBrokerError.notAdmitted },
                                       identityReadiness: { .ready })
        let backoff = NodeMailMirrorBackoff(base: .milliseconds(20), maximum: .milliseconds(80), random: { 0.5 })
        let loop = harness.loop(sessions: broker, backoff: backoff)
        await loop.start()
        try await Task.sleep(for: .milliseconds(400))
        await loop.stop()

        let cycles = await loop.cycles
        let delays = await loop.requestedDelays
        XCTAssertGreaterThanOrEqual(cycles, 2)
        XCTAssertLessThan(cycles, 15, "a refused admission must not spin")
        XCTAssertEqual(Array(delays.prefix(4)), [.milliseconds(10), .milliseconds(20), .milliseconds(40), .milliseconds(40)])
        XCTAssertEqual(harness.server.requests, [], "no Node request without admission")
        XCTAssertNil(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
    }

    func testLoopRetriesAfterTransientNodeErrorsAndRecovers() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.fail("/v1/mail/deltas", with: .unavailable, times: 6)
        let backoff = NodeMailMirrorBackoff(base: .milliseconds(5), maximum: .milliseconds(20), random: { 1 })
        let loop = harness.loop(sessions: harness.broker(), backoff: backoff)
        await loop.start()
        try await waitUntil { (try? harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID)) != nil }
        let delays = await loop.requestedDelays
        XCTAssertEqual(Array(delays.prefix(3)), [.milliseconds(5), .milliseconds(10), .milliseconds(20)])
        await loop.stop()
    }

    func testBoundedPassReportsMoreWorkAndTheLoopFinishesIt() async throws {
        var limits = NodeMailMirror.Limits()
        limits.maximumPagesPerPass = 1
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1, limits: limits)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 7, UInt32(index + 1), [])])
        }
        let first = try await harness.mirror.runPass()
        XCTAssertTrue(first.hasMore)
        XCTAssertFalse(first.complete)

        let loop = harness.loop(sessions: harness.broker(), makeLimits: limits, pageSize: 1)
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }
        XCTAssertEqual(harness.store.messages.count, 3)
        XCTAssertEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID)?.complete, true)
        await loop.stop()
    }

    func testLoopDoesNotSpinOnAConflictingMessageOrAnUnlistedAccount() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        let second = try harness.addAccount("acc-second")
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        harness.server.setListedAccounts([FakeNodeMailServer.accountA])
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("Archive", 7, 9, []), ("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        // A removal asks for an audit, and one linked message keeps
        // conflicting: it must be retried slowly, not on every pass.
        harness.server.setConflicting(["m2"])
        harness.server.removeMembership(nodeID: "m1", path: "INBOX")
        let loop = harness.loop(sessions: harness.broker())
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .caughtUp }
        let cycles = await loop.cycles
        try await Task.sleep(for: .milliseconds(300))
        let after = await loop.cycles
        XCTAssertEqual(after, cycles, "work only a later change can unblock waits for the tick")
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)
        // The audit is done; the conflicting ID waits for its slow retry.
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.reconcileState, NodeMirrorReconcileState.none)
        let m1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(try harness.memberships(m1), ["Archive|7|9"], "the audit still applied what it could")
        await loop.stop()
    }

    func testLeaseOnlyAdmissionStillMirrorsReadOnly() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  omitBodiesInPages: true)
        let broker = NodeSessionBroker(resolveSender: { [server = harness.server] in (NodeMailMirrorHarness.nodeID, server) },
                                       check: { NodeSessionCheck(admission: .readOnly(expiresAt: Date().addingTimeInterval(3_600)), binding: "b") },
                                       identityReadiness: { .ready })
        let session = try await broker.client()
        let mirror = NodeMailMirror(store: harness.store, client: session.client, nodeID: session.nodeID)
        _ = try await mirror.runPass()
        let hydrated = try await mirror.hydrate(limit: 5)
        XCTAssertEqual(hydrated, 1)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
    }

    func testBackoffIsExponentialCappedAndJittered() {
        let low = NodeMailMirrorBackoff(base: .seconds(2), maximum: .seconds(300), random: { 0.5 })
        let high = NodeMailMirrorBackoff(base: .seconds(2), maximum: .seconds(300), random: { 1 })
        XCTAssertEqual(high.delay(afterFailures: 1), .seconds(2))
        XCTAssertEqual(high.delay(afterFailures: 4), .seconds(16))
        XCTAssertEqual(high.delay(afterFailures: 40), .seconds(300))
        XCTAssertEqual(low.delay(afterFailures: 4), .seconds(8))
        XCTAssertEqual(NodeMailMirrorBackoff(random: { 7 }).delay(afterFailures: 1), .seconds(2))
    }

    // MARK: - Fix round 1

    func testSnapshotOfExactlyOnePageEndsOnTheEmptyCursorWithoutRefetching() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 2)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])

        let result = try await harness.mirror.runPass()

        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 1)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 1, "a complete bootstrap is never refetched")
    }

    func testSnapshotOfAnExactMultipleOfThePageSizeCompletes() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 2)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for (index, id) in ["m1", "m2", "m3", "m4"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 7, UInt32(index + 1), [])])
        }
        let result = try await harness.mirror.runPass()
        XCTAssertFalse(result.hasMore)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 2)
        XCTAssertEqual(harness.store.messages.count, 4)
    }

    func testByteTrimmedSnapshotPagesDoNotEndTheBootstrapEarly() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 3)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for (index, id) in ["m1", "m2", "m3"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 7, UInt32(index + 1), [])],
                                      text: String(repeating: "x", count: 10))
        }
        harness.server.setSnapshotByteBudget(15)

        _ = try await harness.mirror.runPass()

        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 3)
        XCTAssertEqual(harness.store.messages.count, 3)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
    }

    func testFallbackAccountIsNeverWrittenAndItsHydrationPauses() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  omitBodiesInPages: true)
        _ = try await harness.mirror.runPass()
        try harness.setMode(.fallback)
        harness.server.clearRequests()
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])

        let result = try await harness.mirror.runPass()
        let hydrated = try await harness.mirror.hydrate(limit: 5)

        XCTAssertEqual(result.committed, 0)
        XCTAssertEqual(hydrated, 0)
        XCTAssertEqual(harness.server.requests, [], "no Node request for an account in fallback")
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.pendingMirrorHydration(accountID: harness.accountID, limit: 5).count, 1)

        let loop = harness.loop(sessions: harness.broker())
        await loop.start()
        try await waitUntil { await loop.lastOutcome == .idle }
        await loop.stop()
    }

    func testFlipToFallbackMidPageStopsTheWrites() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        let cursor = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        // Direct sync archives m1 during fallback; the Node still lists it in INBOX.
        harness.server.touch(nodeID: "m1")
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        let gate = harness.server.hold("/v1/mail/mirror/coordinates")
        let pass = Task { try await harness.mirror.runPass() }
        try await waitUntil { gate.hasArrived }
        try harness.setMode(.fallback)
        let m1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        try await harness.store.databasePool.write { database in
            try database.execute(sql: "UPDATE mailbox_messages SET mailbox_path = 'Archive' WHERE message_id = ?", arguments: [m1.rawValue])
        }
        gate.release()

        do {
            _ = try await pass.value
            XCTFail("the pass must stop")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .mirrorScopeChanged)
        }
        XCTAssertEqual(try harness.memberships(m1), ["Archive|7|1"], "the mirror never puts back what direct sync archived")
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID), cursor)
    }

    func testSeedWhileDirectThenFlipBootstrapsOnTheFirstPass() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])

        try await harness.mirror.seedCursor(accountID: harness.accountID, logicalMailboxID: harness.key(FakeNodeMailServer.accountA))
        let seeded = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, false)
        XCTAssertEqual(harness.store.messages.count, 0, "seeding writes no mail")
        try harness.flipToNode()
        // m2 is published after the snapshot's last page: only the replay from
        // the seeded cursor delivers it.
        let added = Counter()
        harness.server.onAfterSnapshot { _, next in
            guard next.isEmpty, added.value == 0 else { return }
            added.increment()
            harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        }

        let result = try await harness.mirror.runPass()

        XCTAssertTrue(result.bootstrapped)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertFalse(harness.server.snapshotServed.contains("m2"))
        XCTAssertNotEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID)?.deltaCursor, seeded.deltaCursor,
                          "the replay advanced from the seeded cursor")
    }

    func testRemovalBeforeAStaleCursorStillLandsAfterTheReset() async throws {
        var limits = NodeMailMirror.Limits()
        limits.maximumPagesPerPass = 2
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1, limits: limits)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        for (index, id) in ["a1", "a2", "a3"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 7, UInt32(index + 1), [])])
        }
        harness.server.addMessage(nodeID: "z1", rfcMessageID: "<z1@example.test>", memberships: [("Archive", 7, 9, []), ("INBOX", 7, 4, [])])
        for _ in 0..<4 { _ = try await harness.mirror.runPass() }
        let z1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "z1", accountID: harness.accountID))
        XCTAssertEqual(try harness.memberships(z1), ["Archive|7|9", "INBOX|7|4"])

        // Delta page 1 carries the removal; page 2 is stale.
        harness.server.removeMembership(nodeID: "z1", path: "INBOX")
        harness.server.touch(nodeID: "a1")
        harness.server.failDeltaWithStaleCursor(onContinuedRequest: 2)
        _ = try await harness.mirror.runPass()

        // The re-snapshot has not reached z1 yet, but the audit survived the reset.
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, false)
        XCTAssertEqual(try harness.memberships(z1), ["Archive|7|9"])
    }

    func testMessageRemovedInTheUndeliveredWindowIsSweptAfterTheReBootstrap() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        let m2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        // m2 loses its last membership, but the cursor goes stale before the change is delivered.
        harness.server.removeMembership(nodeID: "m2", path: "INBOX")
        harness.server.failNextDeltaWithStaleCursor()

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.removed, 1)
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.first { $0.id == m2 }?.isDeleted, true)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.sweepPending, false)
    }

    func testSweepKeepsALinkTheFreshSnapshotListedButCouldNotCommit() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        // m2 still exists, but its coordinates are omitted during the re-snapshot.
        harness.server.hideCoordinates(nodeID: "m2")
        harness.server.failNextDeltaWithStaleCursor()

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.removed, 0)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.sweepPending, false)
    }

    func testMirroredMessageThreadIsStored() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        let message = try XCTUnwrap(harness.store.messages.first)
        let threadID = try XCTUnwrap(message.threadID)
        let stored = try await harness.store.databasePool.read { database in
            try String.fetchOne(database, sql: "SELECT account_id FROM threads WHERE id = ?", arguments: [threadID.rawValue])
        }
        XCTAssertEqual(stored, harness.accountID.rawValue)
    }

    func testOneAccountsRepeatedStaleSnapshotDoesNotStopTheOthersOrTheDeltas() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1)
        defer { harness.cleanUp() }
        let second = try harness.addAccount("acc-b")
        try harness.flipToNode()
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "a1", rfcMessageID: "<a1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "a2", rfcMessageID: "<a2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 3, 1, [])], logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "b2", rfcMessageID: "<b2@example.test>", memberships: [("INBOX", 3, 2, [])], logical: FakeNodeMailServer.accountB)
        harness.server.failSnapshotsWithStaleCursor(logical: FakeNodeMailServer.accountB, times: 2)
        // After B's second stale answer, a B message arrives that no snapshot
        // page serves: only the deltas of this same pass can deliver it.
        harness.server.onStaleSnapshot { logical, remaining in
            guard logical == FakeNodeMailServer.accountB, remaining == 0 else { return }
            harness.server.addMessage(nodeID: "b0", rfcMessageID: "<b0@example.test>", memberships: [("INBOX", 3, 5, [])],
                                      logical: FakeNodeMailServer.accountB)
        }

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "b0", accountID: second), "deltas still ran")
        XCTAssertFalse(harness.server.snapshotServed.contains("b0"))
        XCTAssertTrue(harness.server.requests.contains { $0.hasPrefix("GET /v1/mail/messages/") }, "b0 came through a delta upsert")
        XCTAssertFalse(result.complete)
    }

    func testAnAuditIDThatKeepsConflictingIsRetriedSlowlyNotEveryPass() async throws {
        let clock = LockedDate(Date())
        let harness = try await NodeMailMirrorHarness.make(testName: #function, clock: clock)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("Archive", 7, 9, []), ("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        harness.server.setConflicting(["m2"])
        harness.server.removeMembership(nodeID: "m1", path: "INBOX")

        _ = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.reconcileState, NodeMirrorReconcileState.none)
        let m1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(try harness.memberships(m1), ["Archive|7|9"])
        harness.server.clearRequests()
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(harness.server.count("POST /v1/mail/mirror/coordinates"), 0, "no retry before its time")

        // The conflict clears and m2 was removed meanwhile; the retry lands after an hour.
        harness.server.setConflicting([])
        harness.server.setMemberships(nodeID: "m2", [], publish: false)
        clock.value = clock.value.addingTimeInterval(3_601)
        _ = try await harness.mirror.runPass()
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
    }

    func testAConflictingUpsertIsSkippedWithoutWedgingTheDeltas() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        _ = try await harness.mirror.runPass()
        let cursor = try XCTUnwrap(harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID))
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.fail("/v1/mail/messages/", with: .conflict)

        let result = try await harness.mirror.runPass()

        XCTAssertEqual(result.skipped, 1)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertNotEqual(try harness.store.nodeMirrorCursor(nodeID: NodeMailMirrorHarness.nodeID)?.deltaCursor, cursor.deltaCursor)
    }

    func testFailedHydrationWaitsForItsBackoffAndAttachmentCountIsCapped() async throws {
        let clock = LockedDate(Date())
        var limits = NodeMailMirror.Limits()
        limits.attachmentCount = 2
        let harness = try await NodeMailMirrorHarness.make(testName: #function, limits: limits, clock: clock)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        let attachments = ["a1", "a2", "a3"].map { id in
            FakeNodeMailServer.Attachment(
                metadata: NodeSyncAttachment(contentDigest: nil, contentID: nil, disposition: "attachment",
                                             filename: id + ".txt", id: id, mime: "text/plain", size: "1"),
                bytes: Data("x".utf8)
            )
        }
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])], attachments: attachments)
        _ = try await harness.mirror.runPass()
        harness.server.fail("/v1/mail/messages/", with: .invalidRequest)
        let failed = try await harness.mirror.hydrate(limit: 5)
        XCTAssertEqual(failed, 0)
        harness.server.clearRequests()
        let early = try await harness.mirror.hydrate(limit: 5)
        XCTAssertEqual(early, 0)
        XCTAssertEqual(harness.server.requests, [], "a failed message is not refetched before its backoff")

        clock.value = clock.value.addingTimeInterval(61)
        let retried = try await harness.mirror.hydrate(limit: 5)
        XCTAssertEqual(retried, 1)
        let messageID = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.incomingMessageAttachments(messageID: messageID).map(\.filename), ["a1.txt", "a2.txt"])
        XCTAssertFalse(harness.server.requests.contains { $0.hasSuffix("/a3") })
    }

    // MARK: - Fix round 2

    func testContinuedSnapshotAfterTheAccountHeadMovedRestartsAndCompletes() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        harness.server.onSnapshot = { call in
            if call == 2 { harness.server.setMemberships(nodeID: "m1", [("INBOX", 7, 1, ["seen"])], publish: false) }
        }

        _ = try await harness.mirror.runPass()

        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 4, "page, stale, restart, last page")
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        let m1 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.first { $0.id == m1 }?.isSeen, true)
    }

    func testALoneOversizedMessageIsServedWithoutBodiesAndHydratedLater() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.setSnapshotByteBudget(10)
        harness.server.addMessage(nodeID: "big", rfcMessageID: "<big@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  text: String(repeating: "y", count: 40))
        _ = try await harness.mirror.runPass()
        let big = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "big", accountID: harness.accountID))
        XCTAssertEqual(harness.store.messages.first { $0.id == big }?.body, "")
        let hydrated = try await harness.mirror.hydrate(limit: 5)
        XCTAssertEqual(hydrated, 1)
        XCTAssertEqual(harness.store.messages.first { $0.id == big }?.body, String(repeating: "y", count: 40))
    }

    func testSnapshotConflictSkipsTheAccountRetriesSlowlyAndKeepsTheOthersAndTheDeltas() async throws {
        let clock = LockedDate(Date())
        let harness = try await NodeMailMirrorHarness.make(testName: #function, clock: clock)
        defer { harness.cleanUp() }
        let second = try harness.addAccount("acc-b")
        try harness.flipToNode()
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "a1", rfcMessageID: "<a1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 3, 1, [])],
                                  logical: FakeNodeMailServer.accountB)
        harness.server.makeUnfittable(nodeID: "b1")
        // A change only this pass's deltas deliver.
        harness.server.onAfterSnapshot { logical, next in
            guard logical == FakeNodeMailServer.accountA, next.isEmpty else { return }
            harness.server.addMessage(nodeID: "a2", rfcMessageID: "<a2@example.test>", memberships: [("INBOX", 7, 2, [])])
        }

        let result = try await harness.mirror.runPass()

        XCTAssertGreaterThanOrEqual(result.skipped, 1)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.complete, true)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "a2", accountID: harness.accountID), "deltas still ran")
        harness.server.onAfterSnapshot(nil)

        harness.server.clearRequests()
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(harness.server.count("POST /v1/mail/snapshot"), 0, "the refused account waits for its retry")

        harness.server.makeUnfittable(nodeID: "b1", false)
        clock.value = clock.value.addingTimeInterval(3_601)
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, true)
        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "b1", accountID: second))
    }

    func testReconnectOneAccountAtATimeStillMirrorsWhatChangedDuringFallback() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        let second = try harness.addAccount("acc-b")
        try harness.flipToNode()
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "a1", rfcMessageID: "<a1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "b1", rfcMessageID: "<b1@example.test>", memberships: [("INBOX", 3, 1, [])],
                                  logical: FakeNodeMailServer.accountB)
        harness.server.addMessage(nodeID: "b2", rfcMessageID: "<b2@example.test>", memberships: [("INBOX", 3, 2, [])],
                                  logical: FakeNodeMailServer.accountB)
        _ = try await harness.mirror.runPass()
        let b2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "b2", accountID: second))

        try harness.setMode(.fallback)
        try harness.setMode(.fallback, accountID: second)
        // During fallback B gains b3 and loses b2 on the provider. Direct sync
        // sees both: it commits b3 locally (and notifies it once) and marks
        // b2 deleted, as `reconcileMailboxState` does.
        harness.server.addMessage(nodeID: "b3", rfcMessageID: "<b3@example.test>", memberships: [("INBOX", 3, 3, [])],
                                  logical: FakeNodeMailServer.accountB)
        harness.server.removeMembership(nodeID: "b2", path: "INBOX")
        let directB3 = try harness.commitDirect(rfcMessageID: "<b3@example.test>", mailboxPath: "INBOX", uidValidity: 3, uid: 3,
                                                notify: true, accountID: second)
        try await harness.store.databasePool.write { database in
            try database.execute(sql: "DELETE FROM mailbox_messages WHERE message_id = ?", arguments: [b2.rawValue])
            try database.execute(sql: "UPDATE messages SET is_deleted = 1 WHERE id = ?", arguments: [b2.rawValue])
        }
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: second).map(\.messageID), [directB3])
        let messageCount = harness.store.messages.count

        // A reconnects first; a pass moves the shared cursor past B's changes.
        try harness.setMode(.node)
        _ = try await harness.mirror.runPass()
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "b3", accountID: second))
        try harness.setMode(.node, accountID: second)
        _ = try await harness.mirror.runPass()

        XCTAssertEqual(try harness.store.messageID(forNodeMessageID: "b3", accountID: second), directB3, "linked to the direct row")
        XCTAssertEqual(harness.store.messages.count, messageCount, "not duplicated")
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: second).map(\.messageID), [directB3], "not re-notified")
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "b2", accountID: second))
        XCTAssertEqual(harness.store.messages.first { $0.id == b2 }?.isDeleted, true)
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.needsReseed, false)

        harness.server.tombstone(nodeID: "b3")
        _ = try await harness.mirror.runPass()
        XCTAssertNil(try harness.store.messageID(forNodeMessageID: "b3", accountID: second))
    }

    func testSweepKeepsALinkADeltaUpsertNamedEvenWhenItsCommitWasSkipped() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])])
        _ = try await harness.mirror.runPass()
        // m1 is briefly unaddressable, so the fresh snapshot after a stale
        // cursor does not list it; it comes back right after, but its delta
        // upsert cannot be committed (its coordinates conflict).
        harness.server.setMemberships(nodeID: "m1", [], publish: false)
        harness.server.failNextDeltaWithStaleCursor()
        let restored = Counter()
        harness.server.onAfterSnapshot { _, next in
            guard next.isEmpty, restored.value == 0 else { return }
            restored.increment()
            harness.server.setMemberships(nodeID: "m1", [("INBOX", 7, 1, [])])
            harness.server.setConflicting(["m1"])
        }

        _ = try await harness.mirror.runPass()

        XCTAssertNotNil(try harness.store.messageID(forNodeMessageID: "m1", accountID: harness.accountID),
                        "a message a delta upsert named still exists on the Node")
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: harness.accountID)?.sweepPending, false)
    }

    func testAFailedHydrationLinkStaysFailedOnAFlagChange() async throws {
        let clock = LockedDate(Date())
        let harness = try await NodeMailMirrorHarness.make(testName: #function, clock: clock)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])],
                                  omitBodiesInPages: true)
        _ = try await harness.mirror.runPass()
        harness.server.fail("/v1/mail/messages/", with: .invalidRequest)
        _ = try await harness.mirror.hydrate(limit: 5)
        // A flag change re-commits the message from a page that omits its body.
        harness.server.setMemberships(nodeID: "m1", [("INBOX", 7, 1, ["seen"])])
        harness.server.failNextDeltaWithStaleCursor()
        _ = try await harness.mirror.runPass()
        harness.server.clearRequests()
        let early = try await harness.mirror.hydrate(limit: 5)
        XCTAssertEqual(early, 0)
        XCTAssertEqual(harness.server.requests, [], "no re-download before the backoff")
    }

    // MARK: - Fix round 3

    func testFreshInboxMailDuringAReSnapshotAfterReconnectNotifies() async throws {
        var limits = NodeMailMirror.Limits()
        limits.maximumPagesPerPass = 1
        let harness = try await NodeMailMirrorHarness.make(testName: #function, pageSize: 1, limits: limits)
        defer { harness.cleanUp() }
        let second = try harness.addAccount("acc-b")
        try harness.flipToNode()
        try harness.flipToNode(accountID: second, logical: FakeNodeMailServer.accountB)
        let old = Date().addingTimeInterval(-7_200)
        for (index, id) in ["b1", "b2", "b3"].enumerated() {
            harness.server.addMessage(nodeID: id, rfcMessageID: "<\(id)@example.test>", memberships: [("INBOX", 3, UInt32(index + 1), [])],
                                      logical: FakeNodeMailServer.accountB, receivedAt: old)
        }
        for _ in 0..<4 { _ = try await harness.mirror.runPass() }
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, true)

        // B goes to fallback, a pass runs for A, and B comes back: a
        // multi-pass re-snapshot starts.
        try harness.setMode(.fallback, accountID: second)
        _ = try await harness.mirror.runPass()
        try harness.setMode(.node, accountID: second)
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false, "still re-snapshotting")

        // Fresh INBOX mail arrives mid-re-snapshot and comes through a delta.
        harness.server.addMessage(nodeID: "b9", rfcMessageID: "<b9@example.test>", memberships: [("INBOX", 3, 9, [])],
                                  logical: FakeNodeMailServer.accountB)
        _ = try await harness.mirror.runPass()

        let b9 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "b9", accountID: second))
        XCTAssertEqual(try harness.store.nodeMirrorAccountBootstrap(accountID: second)?.complete, false)
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: second).map(\.messageID), [b9])
    }

    func testAMessageAlreadyPresentReListedByAReSnapshotDoesNotNotify() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        // Received just now, so only the store's guards keep them quiet: m1 is
        // re-listed under its known key, m0 under a new key (a new UIDVALIDITY),
        // which leaves only the canonical-insert check.
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        harness.server.addMessage(nodeID: "m0", rfcMessageID: "<m0@example.test>", memberships: [("INBOX", 7, 3, [])])
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).count, 0)
        harness.server.setMemberships(nodeID: "m0", [("INBOX", 8, 3, [])], publish: false)
        // A fresh message that the re-snapshot page (not a delta) carries.
        harness.server.addMessage(nodeID: "m2", rfcMessageID: "<m2@example.test>", memberships: [("INBOX", 7, 2, [])], publish: false)

        try await harness.mirror.seedCursor(accountID: harness.accountID, logicalMailboxID: harness.key(FakeNodeMailServer.accountA))
        _ = try await harness.mirror.runPass()

        XCTAssertTrue(harness.server.snapshotServed.filter { $0 == "m1" }.count >= 2, "m1 was re-listed")
        XCTAssertTrue(harness.server.snapshotServed.filter { $0 == "m0" }.count >= 2, "m0 was re-listed")
        let m0 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m0", accountID: harness.accountID))
        XCTAssertEqual(try harness.memberships(m0), ["INBOX|8|3"])
        XCTAssertTrue(harness.server.snapshotServed.contains("m2"))
        let m2 = try XCTUnwrap(harness.store.messageID(forNodeMessageID: "m2", accountID: harness.accountID))
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).map(\.messageID), [m2],
                       "the re-listed m1 stays quiet; fresh m2 from the re-snapshot page notifies")
    }

    func testFirstBootstrapNeverNotifiesEvenFreshMail() async throws {
        let harness = try await NodeMailMirrorHarness.make(testName: #function)
        defer { harness.cleanUp() }
        try harness.flipToNode()
        harness.server.addMessage(nodeID: "m1", rfcMessageID: "<m1@example.test>", memberships: [("INBOX", 7, 1, [])])
        _ = try await harness.mirror.runPass()
        XCTAssertEqual(try harness.store.macNewMailEvents(accountID: harness.accountID).count, 0)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for condition")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A temporary store with one account, the fake Node and a mirror over it.
struct NodeMailMirrorHarness {
    static let nodeID = "40000000-0000-4000-8000-000000000901"

    let store: SQLiteMailStore
    let url: URL
    let accountID: AccountID
    let server: FakeNodeMailServer
    let mirror: NodeMailMirror

    static func make(
        testName: String, pageSize: Int = 50, limits: NodeMailMirror.Limits = NodeMailMirror.Limits(),
        clock: LockedDate = LockedDate(Date()), window: Int? = nil
    ) async throws -> NodeMailMirrorHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plainpost.sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("acc-gmail"), displayName: "Gmail", email: EmailAddress("user0@example.test"),
                              imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        try store.cacheAccounts([account])
        let server = FakeNodeMailServer()
        let mirror = NodeMailMirror(store: store, client: NodeSyncClient(sender: server), nodeID: nodeID, pageSize: pageSize,
                                    now: { clock.value }, limits: limits, jitter: { 1 }, window: { _ in window })
        return NodeMailMirrorHarness(store: store, url: url, accountID: account.id, server: server, mirror: mirror)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func key(_ logical: LogicalMailboxID) throws -> String {
        try NodeSyncCodec.encodeLogicalMailboxID(logical)
    }

    func setMode(_ mode: NodeBackedMode, accountID: AccountID? = nil) throws {
        let current = try store.mailSource(accountID: accountID ?? self.accountID)
        _ = try store.replaceMailSource(current.withMode(mode), expectedGeneration: current.generation)
    }

    func broker() -> NodeSessionBroker {
        NodeSessionBroker(resolveSender: { [server] in (Self.nodeID, server) })
    }

    func loop(
        sessions: any NodeMailMirrorSessionProviding, created: Counter = Counter(),
        backoff: NodeMailMirrorBackoff = NodeMailMirrorBackoff(),
        makeLimits: NodeMailMirror.Limits = NodeMailMirror.Limits(), pageSize: Int = 50
    ) -> NodeMailMirrorLoop {
        let store = store
        return NodeMailMirrorLoop(
            store: store, sessions: sessions,
            makeMirror: { nodeID, client in
                created.increment()
                return NodeMailMirror(store: store, client: client, nodeID: nodeID, pageSize: pageSize, limits: makeLimits)
            },
            tick: .seconds(3_600), backoff: backoff,
            sleep: { try await Task.sleep(for: $0) },
            notificationCenter: .default, observeDistributedNotifications: false
        )
    }

    @discardableResult
    func addAccount(_ id: String) throws -> AccountID {
        let account = Account(id: AccountID(id), displayName: id, email: EmailAddress("\(id)@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts(store.accounts + [account])
        return account.id
    }

    func flipToNode(accountID: AccountID? = nil, logical: LogicalMailboxID = FakeNodeMailServer.accountA) throws {
        let accountID = accountID ?? self.accountID
        let current = try store.mailSource(accountID: accountID)
        _ = try store.replaceMailSource(
            current.nodeBacked(nodeID: Self.nodeID, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(logical),
                               providerIdentity: "\(accountID.rawValue)@example.test"),
            expectedGeneration: current.generation
        )
    }

    func flipToDirect(accountID: AccountID? = nil) throws {
        let current = try store.mailSource(accountID: accountID ?? self.accountID)
        _ = try store.replaceMailSource(current.revertedToDirect(), expectedGeneration: current.generation)
    }

    /// A direct IMAP sync commit, keyed exactly as `IMAPSyncService` keys it.
    func commitDirect(
        rfcMessageID: String?, mailboxPath: String, uidValidity: Int, uid: Int, notify: Bool, accountID: AccountID? = nil
    ) throws -> MessageID {
        let accountID = accountID ?? self.accountID
        let id = MessageID(rfcMessageID.map { IMAPSyncService.canonicalMessageID(accountID: accountID, rfcMessageID: $0) }
            ?? IMAPSyncService.localMessageID(accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid))
        let message = MessageSummary(id: id, threadID: nil, from: EmailAddress("sender@example.test"), subject: "Hello",
                                     preview: "Direct body", smartCategory: .personal, labels: [], isSeen: false,
                                     mailboxPath: mailboxPath, isDeleted: false, body: "Direct body", rfcMessageID: rfcMessageID)
        _ = try store.commitIncomingMessage(
            message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: mailboxPath, uidValidity: uidValidity, uid: uid,
            notificationDisposition: notify ? .candidate(providerArrivalAt: Date()) : .ineligible
        )
        return id
    }

    func memberships(_ messageID: MessageID) throws -> [String] {
        try store.databasePool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT mailbox_path, uid_validity, uid FROM mailbox_messages WHERE message_id = ? ORDER BY mailbox_path, uid_validity, uid
                """, arguments: [messageID.rawValue]).map {
                "\($0["mailbox_path"] as String)|\($0["uid_validity"] as Int)|\($0["uid"] as Int)"
            }
        }
    }

    func messageIDs(accountID: AccountID) throws -> [String] {
        try store.databasePool.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM messages WHERE account_id = ? ORDER BY id", arguments: [accountID.rawValue])
        }
    }

    func accountOf(_ messageID: MessageID) throws -> String? {
        try store.databasePool.read { database in
            try String.fetchOne(database, sql: "SELECT account_id FROM messages WHERE id = ?", arguments: [messageID.rawValue])
        }
    }
}
