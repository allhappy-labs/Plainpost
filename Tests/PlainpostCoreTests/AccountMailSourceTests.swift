import Foundation
import XCTest
@testable import PlainpostCore

final class AccountMailSourceTests: XCTestCase {
    private let accountID = AccountID("acc-source")
    private let nodeID = "30000000-0000-4000-8000-000000000801"
    private let logicalMailboxID = String(repeating: "A", count: 43)

    func testDirectSourceRunsDirectSyncAtGenerationZero() {
        let direct = AccountMailSource.direct(accountID)
        XCTAssertEqual(direct.kind, .direct)
        XCTAssertNil(direct.mode)
        XCTAssertNil(direct.nodeID)
        XCTAssertNil(direct.logicalMailboxID)
        XCTAssertNil(direct.providerIdentity)
        XCTAssertEqual(direct.generation, 0)
        XCTAssertTrue(direct.runsDirectSync)
        XCTAssertNoThrow(try direct.validate())
    }

    func testTransitionsAdvanceGenerationAndOnlyFallbackRunsDirectSync() throws {
        let backed = AccountMailSource.direct(accountID).nodeBacked(
            nodeID: nodeID, logicalMailboxID: logicalMailboxID, providerIdentity: "a@example.test")
        XCTAssertEqual(backed.kind, .nodeBacked)
        XCTAssertEqual(backed.mode, .node)
        XCTAssertEqual(backed.nodeID, nodeID)
        XCTAssertEqual(backed.logicalMailboxID, logicalMailboxID)
        XCTAssertEqual(backed.providerIdentity, "a@example.test")
        XCTAssertEqual(backed.generation, 1)
        XCTAssertFalse(backed.runsDirectSync)
        XCTAssertNoThrow(try backed.validate())

        let fallback = backed.withMode(.fallback)
        XCTAssertEqual(fallback.mode, .fallback)
        XCTAssertEqual(fallback.generation, 2)
        XCTAssertEqual(fallback.nodeID, nodeID)
        XCTAssertTrue(fallback.runsDirectSync)

        let reverted = fallback.revertedToDirect()
        XCTAssertEqual(reverted.kind, .direct)
        XCTAssertNil(reverted.mode)
        XCTAssertNil(reverted.nodeID)
        XCTAssertNil(reverted.logicalMailboxID)
        XCTAssertNil(reverted.providerIdentity)
        XCTAssertEqual(reverted.generation, 3)
        XCTAssertTrue(reverted.runsDirectSync)
    }

    func testValidationRejectsMalformedNodeBackedSources() {
        let direct = AccountMailSource.direct(accountID)
        let invalid: [AccountMailSource] = [
            direct.nodeBacked(nodeID: "not-a-uuid", logicalMailboxID: logicalMailboxID, providerIdentity: "a@example.test"),
            direct.nodeBacked(nodeID: nodeID, logicalMailboxID: String(repeating: "A", count: 42), providerIdentity: "a@example.test"),
            direct.nodeBacked(nodeID: nodeID, logicalMailboxID: String(repeating: "+", count: 43), providerIdentity: "a@example.test"),
            direct.nodeBacked(nodeID: nodeID, logicalMailboxID: logicalMailboxID, providerIdentity: ""),
            // 43 base64url characters whose last one has non-zero spare bits.
            direct.nodeBacked(nodeID: nodeID, logicalMailboxID: String(repeating: "A", count: 42) + "B", providerIdentity: "a@example.test"),
        ]
        for source in invalid {
            XCTAssertThrowsError(try source.validate()) {
                XCTAssertEqual($0 as? AccountMailSourceError, .invalidSource)
            }
        }
        XCTAssertThrowsError(try AccountMailSource(
            accountID: accountID, kind: .direct, mode: .fallback, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1))
        XCTAssertThrowsError(try AccountMailSource(
            accountID: accountID, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: -1))
    }

    func testNodeIDIsCanonicalizedToLowercase() throws {
        let upper = "3A000000-0000-4000-8000-00000000080F"
        let backed = AccountMailSource.direct(accountID).nodeBacked(
            nodeID: upper, logicalMailboxID: String(repeating: "A", count: 42) + "Q", providerIdentity: "a@example.test")
        XCTAssertEqual(backed.nodeID, upper.lowercased())
        XCTAssertNoThrow(try backed.validate())
        let decoded = try AccountMailSource(
            accountID: accountID, kind: .nodeBacked, mode: .fallback, nodeID: upper,
            logicalMailboxID: logicalMailboxID, providerIdentity: "a@example.test", generation: 3)
        XCTAssertEqual(decoded.nodeID, upper.lowercased())
    }

    func testCodableRoundTripUsesWireValuesAndRejectsInvalidPayloads() throws {
        let backed = AccountMailSource.direct(accountID).nodeBacked(
            nodeID: nodeID, logicalMailboxID: logicalMailboxID, providerIdentity: "a@example.test")
        let data = try JSONEncoder().encode(backed)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"node_backed\""))
        XCTAssertEqual(try JSONDecoder().decode(AccountMailSource.self, from: data), backed)

        let invalid = Data("""
            {"accountID":"acc","kind":"node_backed","generation":1}
            """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountMailSource.self, from: invalid))
    }

    func testStableMessageKeyIdentityIsAllFourComponents() {
        let key = StableMessageKey(accountID: accountID, mailboxPath: "INBOX", uidValidity: 7, uid: 42)
        XCTAssertEqual(key, StableMessageKey(accountID: accountID, mailboxPath: "INBOX", uidValidity: 7, uid: 42))
        XCTAssertNotEqual(key, StableMessageKey(accountID: accountID, mailboxPath: "INBOX", uidValidity: 8, uid: 42))
        XCTAssertNotEqual(key, StableMessageKey(accountID: accountID, mailboxPath: "INBOX", uidValidity: 7, uid: 43))
        XCTAssertNotEqual(key, StableMessageKey(accountID: accountID, mailboxPath: "Archive", uidValidity: 7, uid: 42))
        XCTAssertNotEqual(key, StableMessageKey(accountID: AccountID("other"), mailboxPath: "INBOX", uidValidity: 7, uid: 42))
    }
}
