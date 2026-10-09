import XCTest
@testable import PlainpostUI

/// Ledger Task 6: each kind of failure has its own alert title.
final class MobileMailFailureTests: XCTestCase {
    func testEachKindOfFailureHasItsOwnTitle() {
        let failures: [MobileMailFailure] = [.messageAction("IMAP refused"), .markRead, .attachment("disk full")]
        XCTAssertEqual(Set(failures.map(\.title)).count, failures.count)
    }

    func testTheMessageCarriesTheDetail() {
        XCTAssertEqual(MobileMailFailure.messageAction("IMAP refused").message, "IMAP refused")
        XCTAssertEqual(MobileMailFailure.attachment("disk full").message, "Plainpost couldn't open the attachment: disk full")
    }
}
