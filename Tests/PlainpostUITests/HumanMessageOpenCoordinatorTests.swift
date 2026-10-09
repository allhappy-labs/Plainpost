import XCTest
import PlainpostCore
@testable import PlainpostUI

final class HumanMessageOpenCoordinatorTests: XCTestCase {
    @MainActor
    func testSelectingUnreadMessageInvokesHumanOpen() async throws {
        var opened: [MessageID] = []
        let coordinator = HumanMessageOpenCoordinator { messageID in
            opened.append(messageID)
        }

        try await coordinator.openIfPresent("msg-unread")

        XCTAssertEqual(opened, [MessageID("msg-unread")])
    }

    @MainActor
    func testNilSelectionDoesNotInvokeHumanOpen() async throws {
        var opened: [MessageID] = []
        let coordinator = HumanMessageOpenCoordinator { messageID in
            opened.append(messageID)
        }

        try await coordinator.openIfPresent(nil)

        XCTAssertTrue(opened.isEmpty)
    }
}
