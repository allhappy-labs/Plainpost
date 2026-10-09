import XCTest
@testable import PlainpostDesignSnapshot
@testable import PlainpostUI

final class MailboxToolbarFixtureScenarioTests: XCTestCase {
    func testToolbarFixtureScenariosCoverEachPickerSelection() {
        XCTAssertEqual(
            MailboxToolbarFixtureScenario.all,
            [.focusedList, .board, .splitBoard]
        )
        XCTAssertEqual(
            MailboxToolbarFixtureScenario.all.map(\.selectedInboxMode),
            [
                .focusedList,
                .simpleList,
                .unreadCards,
            ]
        )
    }

    func testToolbarFixtureUsesTheConfigurationWidth() {
        XCTAssertEqual(
            MailboxToolbarFixtureScenario.focusedList.renderWidth(
                for: CGSize(width: 900, height: 640)
            ),
            900
        )
        XCTAssertEqual(
            MailboxToolbarFixtureScenario.focusedList.renderWidth(
                for: CGSize(width: 1_180, height: 720)
            ),
            1_180
        )
    }

    @MainActor
    func testToolbarFixtureKeepsLeadingFrameAlignment() {
        XCTAssertEqual(
            PlainpostDesignSnapshot.mailboxToolbarFixtureFrameAlignment,
            .leading
        )
    }
}
