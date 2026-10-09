import XCTest
@testable import PlainpostUI

final class MailInspectorSlotTests: XCTestCase {
    func testOpeningOnePaneReplacesTheOtherInTheOneSlot() {
        let opened = MailInspectorSlot.toggled(.conversationAI, isPresented: false, current: .askMail)
        XCTAssertTrue(opened.isPresented)
        XCTAssertEqual(opened.slot, .conversationAI)

        let replaced = MailInspectorSlot.toggled(.askMail, isPresented: true, current: .conversationAI)
        XCTAssertTrue(replaced.isPresented, "Ask Mail replaces the AI pane; it doesn't close the inspector")
        XCTAssertEqual(replaced.slot, .askMail)
    }

    func testPressingTheShownPanesButtonClosesTheInspector() {
        let closed = MailInspectorSlot.toggled(.conversationAI, isPresented: true, current: .conversationAI)
        XCTAssertFalse(closed.isPresented)
        XCTAssertEqual(closed.slot, .conversationAI)
    }
}
