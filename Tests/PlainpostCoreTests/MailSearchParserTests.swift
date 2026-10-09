import Foundation
import XCTest
@testable import PlainpostCore

final class MailSearchParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testLegacyParserSurfaceIsReplacedByCanonicalQueryParser() throws {
        let parsed = try MailSearchQueryParser(calendar: calendar).parse(
            "from:alex AND has:attachment",
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(parsed.expression, .all([
            .field(.from, .term("alex", prefix: true)),
            .content(.attachment),
        ]))
        XCTAssertEqual(parsed.canonicalQuery, "from:alex AND has:attachment")
    }

    func testCanonicalParserReturnsTypedPrivacySafeErrors() {
        XCTAssertThrowsError(
            try MailSearchQueryParser(calendar: calendar).parse(
                "owner:private-customer-name",
                now: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? MailSearchError,
                .unsupportedField(
                    name: "owner",
                    range: .init(location: 0, length: 5)
                )
            )
            XCTAssertFalse(String(describing: error).contains("private-customer-name"))
        }
    }

    func testRequestDefaultsToConversationModeAndBoundedPageSize() {
        let request = MailSearchRequest(query: "project", limit: 1_000)

        XCTAssertEqual(request.mode, .conversations)
        XCTAssertEqual(request.scope, MailSearchSelectionScope())
        XCTAssertEqual(request.limit, MailSearchRequest.maximumLimit)
        XCTAssertNil(request.cursor)
    }

    func testSuggestionContextUsesRawLexerRangesForCaretSelectionAndEmptyValues() throws {
        let cases: [(String, String, Bool, String?)] = [
            ("project from:al next", "al", false, "from"),
            (#"  from:"Alex Ri" project"#, "Alex Ri", false, "from"),
            (#"subject:"Quarterly Rev"#, "Quarterly Rev", false, "subject"),
            ("project selected next", "selected", true, nil),
            ("😀 from:e\u{301} next", "e\u{301}", false, "from"),
        ]

        for (query, activeText, selectsText, expectedField) in cases {
            let activeRange = (query as NSString).range(of: activeText)
            let selection = MailSearchTextRange(
                location: selectsText ? activeRange.location : activeRange.location + 1,
                length: selectsText ? activeRange.length : 0
            )
            let context = try XCTUnwrap(
                MailSearchQueryParser.suggestionContext(
                    in: query,
                    selection: selection
                ),
                query
            )

            XCTAssertEqual(
                context.replacementRange,
                .init(location: activeRange.location, length: activeRange.length),
                query
            )
            XCTAssertEqual(context.canonicalField, expectedField, query)
        }

        let empty = try XCTUnwrap(
            MailSearchQueryParser.suggestionContext(
                in: "  from:",
                selection: .init(location: 7, length: 0)
            )
        )
        XCTAssertEqual(empty.replacementRange, .init(location: 7, length: 0))
        XCTAssertEqual(empty.canonicalField, "from")

        let quotedQuery = #"from:"Alex Ri" next"#
        let quotedSelection = (quotedQuery as NSString).range(of: #""Alex Ri""#)
        let selectedQuoteContext = try XCTUnwrap(
            MailSearchQueryParser.suggestionContext(
                in: quotedQuery,
                selection: .init(
                    location: quotedSelection.location,
                    length: quotedSelection.length
                )
            )
        )
        XCTAssertEqual(
            selectedQuoteContext.replacementRange,
            .init(location: quotedSelection.location + 1, length: quotedSelection.length - 2)
        )
        XCTAssertEqual(selectedQuoteContext.canonicalField, "from")
    }

    func testSuggestionContextRetainsEnclosingFieldAcrossGroupsAndWhitespaceEmptyValues() throws {
        let groupedQuery = "from:(alice OR bob) subject:budget"
        for selected in ["alice", "bob"] {
            let selectedRange = (groupedQuery as NSString).range(of: selected)
            let context = try XCTUnwrap(
                MailSearchQueryParser.suggestionContext(
                    in: groupedQuery,
                    selection: .init(
                        location: selectedRange.location + selectedRange.length,
                        length: 0
                    )
                ),
                selected
            )

            XCTAssertEqual(
                context.replacementRange,
                .init(location: selectedRange.location, length: selectedRange.length),
                selected
            )
            XCTAssertEqual(context.canonicalField, "from", selected)
        }

        let emptyQuery = "from:   "
        let emptyContext = try XCTUnwrap(
            MailSearchQueryParser.suggestionContext(
                in: emptyQuery,
                selection: .init(location: emptyQuery.utf16.count, length: 0)
            )
        )
        XCTAssertEqual(
            emptyContext.replacementRange,
            .init(location: emptyQuery.utf16.count, length: 0)
        )
        XCTAssertEqual(emptyContext.canonicalField, "from")
    }
}
