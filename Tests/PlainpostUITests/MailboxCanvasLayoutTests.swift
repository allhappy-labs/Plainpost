import SwiftUI
import XCTest
@testable import PlainpostUI

final class MailboxCanvasLayoutTests: XCTestCase {
    func testMailboxCanvasFillsEveryWorkspaceSurface() {
        XCTAssertTrue(MailboxCanvasLayout.maximumWidth.isInfinite)
        XCTAssertTrue(MailboxCanvasLayout.maximumHeight.isInfinite)
        XCTAssertEqual(
            MailboxCanvasLayout.listBackgroundVisibility,
            .hidden
        )
        XCTAssertEqual(MailboxCanvasLayout.surfaceRole, .workArea)
    }

    func testMailboxEmptyStateFillsTheEntireCanvas() {
        XCTAssertTrue(MailboxCanvasLayout.emptyStateMaximumWidth.isInfinite)
        XCTAssertTrue(MailboxCanvasLayout.emptyStateMaximumHeight.isInfinite)
    }

    func testReaderWorkspaceContentUsesTheAvailableReaderWidth() {
        XCTAssertTrue(
            MailboxCanvasLayout.readerContentMaximumWidth.isInfinite
        )
        XCTAssertTrue(
            MailboxCanvasLayout.readerColumnMaximumWidth.isInfinite
        )
    }
}
