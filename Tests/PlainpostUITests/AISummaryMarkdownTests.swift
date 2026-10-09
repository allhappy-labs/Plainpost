import Foundation
import XCTest
@testable import PlainpostUI

final class AISummaryMarkdownTests: XCTestCase {
    func testSummaryMarkdownRendersEmphasisInsteadOfShowingSourceMarkers() throws {
        let rendered = AISummaryMarkdown.attributedString(
            from: "- **Thank You Message**: The sender confirms the order."
        )

        XCTAssertEqual(
            String(rendered.characters),
            "- Thank You Message: The sender confirms the order."
        )

        let emphasizedText = rendered.runs.compactMap { run -> String? in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else {
                return nil
            }
            return String(rendered.characters[run.range])
        }
        XCTAssertEqual(emphasizedText, ["Thank You Message"])
    }

    /// The exact shape the iPhone conversation screen's summary panel reuses this renderer
    /// for: several bulleted lines, each with its own bold lead-in.
    func testSummaryMarkdownRendersMultipleBulletsWithLineBreaksAndBoldLeadIns() {
        let rendered = AISummaryMarkdown.attributedString(
            from: "- **Decision**: Ship the redesign.\n- **Information**: QA signs off Friday."
        )

        XCTAssertEqual(
            String(rendered.characters),
            "- Decision: Ship the redesign.\n- Information: QA signs off Friday."
        )

        let emphasizedText = rendered.runs.compactMap { run -> String? in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else {
                return nil
            }
            return String(rendered.characters[run.range])
        }
        XCTAssertEqual(emphasizedText, ["Decision", "Information"])
    }
}
