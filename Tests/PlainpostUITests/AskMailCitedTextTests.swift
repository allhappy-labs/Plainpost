import XCTest
@testable import PlainpostUI

final class AskMailCitedTextTests: XCTestCase {
    func testSplitsCitationsAndKeepsBold() {
        let segments = AskMailCitedText.segments("**46 of 52** are automated [1], people [2].")
        XCTAssertEqual(segments.count, 5)
        guard case .text(let first) = segments[0], case .citation(1) = segments[1], case .citation(2) = segments[3] else {
            return XCTFail("Unexpected segments \(segments)")
        }
        XCTAssertEqual(String(first.characters), "46 of 52 are automated ")
        XCTAssertTrue(first.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testTextWithoutCitations() {
        XCTAssertEqual(AskMailCitedText.segments("Plain").count, 1)
    }

    func testFlowItemsSplitsWordsAndLineBreaks() {
        let items = AskMailCitedText.flowItems("Due Friday [1], ok.\n\nNext")
        let described = items.map { item -> String in
            switch item {
            case .word(let word): return "w:" + String(word.characters)
            case .citation(let number): return "c:\(number)"
            case .paragraphBreak: return "p"
            case .lineBreak: return "n"
            }
        }
        XCTAssertEqual(described, ["w:Due ", "w:Friday ", "c:1", "w:, ", "w:ok.", "p", "w:Next"])
        XCTAssertEqual(AskMailCitedText.flowItems("a\nb").count, 3)
        XCTAssertEqual(AskMailCitedText.plainText("**Due** Friday [1]."), "Due Friday [1].")
        XCTAssertEqual(AskMailCitedText.spokenText("**Due** Friday [1]."), "Due Friday source 1.")
    }
}
