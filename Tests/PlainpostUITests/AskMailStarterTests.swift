import XCTest
@testable import PlainpostCore
@testable import PlainpostUI

final class AskMailStarterTests: XCTestCase {
    func testStartersReflectMailbox() {
        XCTAssertEqual(AskMailStarterBuilder.starters(unread: 52, peopleUnread: 3).map(\.id), ["unread", "people", "week"])
        XCTAssertEqual(AskMailStarterBuilder.starters(unread: 0, peopleUnread: 0).map(\.id), ["week"])
        XCTAssertEqual(AskMailStarterBuilder.starters(unread: 52, peopleUnread: 3).first?.count, "52")
    }

    func testScopedRuntimeWithoutSelectedAccountShowsOnlyWeekAndCountsNothing() {
        var counted: [AccountID?] = []
        let starters = AskMailStarterBuilder.starters(requiresAccountScope: true, accountID: nil) { _, accountID in
            counted.append(accountID)
            return 7
        }
        XCTAssertEqual(starters.map(\.id), ["week"])
        XCTAssertEqual(counted.count, 0)
    }

    func testScopedRuntimeCountsSelectedAccountOnly() {
        var counted: [AccountID?] = []
        let starters = AskMailStarterBuilder.starters(requiresAccountScope: true, accountID: AccountID("acc")) { filter, accountID in
            counted.append(accountID)
            return filter.categories == [.personal] ? 2 : 9
        }
        XCTAssertEqual(starters.map(\.count), ["9", "2", ""])
        XCTAssertEqual(counted, [AccountID("acc"), AccountID("acc")])
    }
}
