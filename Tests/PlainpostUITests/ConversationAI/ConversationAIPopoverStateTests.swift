import XCTest
@testable import PlainpostUI

/// Ruling 17: the iPad ✦ popover's open state never outlives the reader it opened over.
final class ConversationAIPopoverStateTests: XCTestCase {
    func testOpensOverTheReaderAndStaysOpenWhileItShowsTheSameMessage() {
        var state = ConversationAIPopoverState()
        XCTAssertFalse(state.isPresented)

        state.open(over: "m2")
        state.readerDidShow("m2")

        XCTAssertTrue(state.isPresented)
    }

    func testClosesWhenTheReaderShowsAnotherMessage() {
        var state = ConversationAIPopoverState()
        state.open(over: "m2")

        state.readerDidShow("dinner-1")

        XCTAssertFalse(state.isPresented)
    }

    /// The reader went away (back to the list, another destination): the open state resets, so
    /// the next ✦ tap is a change that presents the popover instead of `true` → `true`.
    func testClosesWhenTheReaderGoesAwayAndTheNextTapOpensAgain() {
        var state = ConversationAIPopoverState()
        state.open(over: "m2")

        state.readerDidShow(nil)
        XCTAssertFalse(state.isPresented)

        state.readerDidShow("m2")
        XCTAssertFalse(state.isPresented, "coming back doesn't reopen it by itself")
        state.open(over: "m2")
        XCTAssertTrue(state.isPresented)
    }

    func testCloseClosesAndAClosedPopoverStaysClosedWhenTheReaderChanges() {
        var state = ConversationAIPopoverState()
        state.open(over: "m2")
        state.close()
        XCTAssertFalse(state.isPresented)

        state.readerDidShow("m1")
        XCTAssertFalse(state.isPresented)
    }
}
