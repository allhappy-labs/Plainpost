import XCTest
@testable import PlainpostUI

final class AskMailReturnKeyTests: XCTestCase {
    func testReturnTypedAtEndSubmitsTheQuestion() {
        XCTAssertEqual(AskMailReturnKey.submittedQuestion(old: "Group my unread", new: "Group my unread\n"),
                       "Group my unread")
    }

    func testReturnTypedMidTextSubmitsTheTextWithoutTheNewline() {
        XCTAssertEqual(AskMailReturnKey.submittedQuestion(old: "Group unread", new: "Group\n unread"),
                       "Group unread")
    }

    func testReturnDeliveredWithAnAutocorrectedWordSubmits() {
        XCTAssertEqual(AskMailReturnKey.submittedQuestion(old: "clean som", new: "clean some\n"),
                       "clean some")
    }

    func testOrdinaryTypingAndPastesDoNotSubmit() {
        XCTAssertNil(AskMailReturnKey.submittedQuestion(old: "Group", new: "Group "))
        XCTAssertNil(AskMailReturnKey.submittedQuestion(old: "", new: "line one\nline two"))
        XCTAssertNil(AskMailReturnKey.submittedQuestion(old: "Hi", new: "Hi\n\n"))
    }

    func testReturnInAnEmptyFieldDoesNotSubmit() {
        XCTAssertNil(AskMailReturnKey.submittedQuestion(old: "", new: "\n"))
        XCTAssertNil(AskMailReturnKey.submittedQuestion(old: "  ", new: "  \n"))
    }
}
