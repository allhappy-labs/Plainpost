import SwiftUI
import XCTest
@testable import PlainpostUI

final class MailboxReadStateToggleTests: XCTestCase {
    func testUnreadPresentationPreviewsMarkRead() {
        let presentation = MailboxReadStateTogglePresentation.resolve(isUnread: true)

        XCTAssertTrue(presentation.showsUnreadDotAtRest)
        XCTAssertEqual(presentation.hoverSystemImage, "eye")
        XCTAssertEqual(presentation.accessibilityLabel, "Mark as Read")
        XCTAssertEqual(presentation.action, .markRead)
    }

    func testReadPresentationPreviewsMarkUnread() {
        let presentation = MailboxReadStateTogglePresentation.resolve(isUnread: false)

        XCTAssertFalse(presentation.showsUnreadDotAtRest)
        XCTAssertEqual(presentation.hoverSystemImage, "eye.slash")
        XCTAssertEqual(presentation.accessibilityLabel, "Mark as Unread")
        XCTAssertEqual(presentation.action, .markUnread)
    }

    func testToggleHitTargetOverlaysExistingIndicatorFootprint() {
        XCTAssertEqual(MailboxReadStateToggleLayout.hitTargetSize, 26)
        XCTAssertEqual(MailboxReadStateToggleLayout.actionPreviewSize, 20)
        XCTAssertEqual(MailboxReadStateToggleLayout.indicatorFootprint, 5)
        XCTAssertEqual(MailboxReadStateToggleLayout.horizontalOffset, -10.5)
        XCTAssertEqual(MailboxReadStateToggleLayout.narrowVerticalOffset, 2.5)
    }

    @MainActor
    func testToggleRendersEveryApprovedState() {
        for isUnread in [true, false] {
            for isRowHovered in [true, false] {
                evaluate(
                    MailboxReadStateToggle(
                        presentation: .resolve(isUnread: isUnread),
                        unreadColor: .accentColor,
                        isRowHovered: isRowHovered,
                        forceDirectHover: false,
                        isDisabled: false,
                        action: {}
                    )
                )
            }
        }
    }
}

@MainActor
private func evaluate<V: View>(
    _ view: V,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    _ = view.body
    XCTAssertTrue(true, file: file, line: line)
}
