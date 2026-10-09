import XCTest
@testable import PlainpostUI

final class PlainpostApplicationPresenceTests: XCTestCase {
    func testVisibleMainCapableWindowCountsAsUserFacing() {
        XCTAssertTrue(
            PlainpostApplicationPresence.isUserFacingWindow(
                presence(canBecomeMain: true, isVisible: true)
            )
        )
    }

    func testMiniaturizedMainCapableWindowCountsAsUserFacing() {
        XCTAssertTrue(
            PlainpostApplicationPresence.isUserFacingWindow(
                presence(canBecomeMain: true, isMiniaturized: true)
            )
        )
    }

    func testHiddenMainCapableWindowDoesNotCountAsUserFacing() {
        XCTAssertFalse(
            PlainpostApplicationPresence.isUserFacingWindow(
                presence(canBecomeMain: true)
            )
        )
    }

    func testVisibleInternalWindowDoesNotCountAsUserFacing() {
        XCTAssertFalse(
            PlainpostApplicationPresence.isUserFacingWindow(
                presence(canBecomeMain: false, isVisible: true)
            )
        )
    }

    func testAnyUserFacingWindowKeepsApplicationPresent() {
        XCTAssertTrue(
            PlainpostApplicationPresence.hasUserFacingWindow(
                in: [
                    presence(canBecomeMain: false, isVisible: true),
                    presence(canBecomeMain: true, isVisible: true),
                    presence(canBecomeMain: true)
                ]
            )
        )
    }

    func testEmptyAndHiddenWindowCollectionsDoNotKeepApplicationPresent() {
        XCTAssertFalse(
            PlainpostApplicationPresence.hasUserFacingWindow(
                in: [] as [PlainpostWindowPresence]
            )
        )
        XCTAssertFalse(
            PlainpostApplicationPresence.hasUserFacingWindow(
                in: [
                    presence(canBecomeMain: true),
                    presence(canBecomeMain: false, isVisible: true)
                ]
            )
        )
    }

    private func presence(
        canBecomeMain: Bool,
        isVisible: Bool = false,
        isMiniaturized: Bool = false
    ) -> PlainpostWindowPresence {
        PlainpostWindowPresence(
            canBecomeMain: canBecomeMain,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized
        )
    }
}
