import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostServiceIPC

final class MailActionPermanentCodingTests: XCTestCase {
    func testPermanentIsOptInAndOldPayloadsDecodeAsAPlainDelete() throws {
        let plain = try JSONEncoder().encode(PlainpostMailActionPayload(messageID: "m"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("permanent"))
        let old = try JSONDecoder().decode(PlainpostMailActionPayload.self, from: Data(#"{"messageID":"m"}"#.utf8))
        XCTAssertFalse(old.permanent)

        let permanent = PlainpostMailActionPayload(messageID: "m", permanent: true)
        let decoded = try JSONDecoder().decode(PlainpostMailActionPayload.self, from: JSONEncoder().encode(permanent))
        XCTAssertEqual(decoded, permanent)
    }

    func testDeleteOutcomeRoundTripsAndIsAbsentFromOlderResults() throws {
        let result = PlainpostMailActionSemanticResult(
            messageID: "m", mailboxPath: "Trash", isDeleted: false, deleteOutcome: .alreadyInTrash
        )
        let decoded = try JSONDecoder().decode(PlainpostMailActionSemanticResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        let old = try JSONDecoder().decode(
            PlainpostMailActionSemanticResult.self, from: Data(#"{"messageID":"m","isDeleted":true}"#.utf8)
        )
        XCTAssertNil(old.deleteOutcome)
    }

    func testSourceMailboxIsAdditiveAndValidated() throws {
        let shown = PlainpostMailActionPayload(messageID: "m", sourceMailbox: "[Gmail]/Sent Mail", sourceUID: 3)
        let decoded = try JSONDecoder().decode(PlainpostMailActionPayload.self, from: JSONEncoder().encode(shown))
        XCTAssertEqual(decoded, shown)
        XCTAssertNoThrow(try PlainpostForegroundOperation.delete(shown).validate())
        XCTAssertNoThrow(try PlainpostForegroundOperation.archive(shown).validate())
        XCTAssertThrowsError(
            try PlainpostForegroundOperation.delete(PlainpostMailActionPayload(messageID: "m", sourceUID: 3)).validate(),
            "a UID needs its mailbox"
        )
        XCTAssertThrowsError(try PlainpostForegroundOperation.markRead(shown).validate())
        let plain = try JSONEncoder().encode(PlainpostMailActionPayload(messageID: "m"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("source"))
    }
}
