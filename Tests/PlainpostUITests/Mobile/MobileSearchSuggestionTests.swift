import XCTest
import PlainpostCore
@testable import PlainpostUI

final class MobileSearchSuggestionTests: XCTestCase {
    private func item(_ title: String, insertion: String, range: MailSearchTextRange? = nil) -> MailSearchSuggestionItem {
        MailSearchSuggestionItem(id: title, title: title, detail: "", insertion: insertion, replacementRange: range)
    }

    func testRowsOfferAskMailPeopleAttachmentsAndRecents() {
        let swiss = item("Swiss Post", insertion: "from:noreply@post.example ")
        let recent = item("parcel", insertion: "parcel")
        let rows = MobileSearchSuggestion.rows(
            query: "parcel",
            sections: [MailSearchSuggestionSection(kind: .people, items: [swiss]),
                       MailSearchSuggestionSection(kind: .recent, items: [recent])],
            canAskMail: true
        )
        XCTAssertEqual(rows, [.askMail(query: "parcel"), .person(swiss), .hasAttachment, .recent(recent)])
    }

    func testNoAskMailWithoutAProviderOrAQuery() {
        XCTAssertFalse(MobileSearchSuggestion.rows(query: "parcel", sections: [], canAskMail: false).contains(.askMail(query: "parcel")))
        XCTAssertEqual(MobileSearchSuggestion.rows(query: "  ", sections: [], canAskMail: true), [.hasAttachment])
    }

    func testHasAttachmentIsOfferedOnce() {
        XCTAssertFalse(MobileSearchSuggestion.rows(query: "invoice has:attachment", sections: [], canAskMail: false).contains(.hasAttachment))
        XCTAssertEqual(MobileSearchSuggestion.addingHasAttachment(to: "invoice"), "invoice has:attachment ")
        XCTAssertEqual(MobileSearchSuggestion.addingHasAttachment(to: ""), "has:attachment ")
    }

    func testApplyingReplacesTheSuggestedRange() {
        let person = item("Swiss Post", insertion: "from:noreply@post.example ", range: MailSearchTextRange(location: 0, length: 7))
        XCTAssertEqual(MobileSearchSuggestion.applying(person, to: "from:sw"), "from:noreply@post.example ")
        XCTAssertEqual(MobileSearchSuggestion.applying(item("parcel", insertion: "parcel"), to: "par"), "parcel")
    }

    func testHighlightRangesPointAtTheMatches() throws {
        let snippet = try MailSearchSnippet(text: "Your parcel is out", highlights: [MailSearchTextRange(location: 5, length: 6)])
        let ranges = MobileSearchHighlight.ranges(in: snippet)
        XCTAssertEqual(ranges.map { String(snippet.text[$0]) }, ["parcel"])
    }
}
