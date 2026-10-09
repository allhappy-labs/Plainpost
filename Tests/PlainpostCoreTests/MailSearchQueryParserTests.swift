import Foundation
import XCTest
@testable import PlainpostCore

final class MailSearchQueryParserTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private var parser: MailSearchQueryParser {
        MailSearchQueryParser(calendar: calendar)
    }

    private var now: Date {
        calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 7,
            day: 18,
            hour: 15,
            minute: 30
        ))!
    }

    func testLexingRetainsNonControlCharactersAcrossScalarRepresentations() throws {
        let cases = ["project", "cafe\u{0301}", "漢字", "👩‍💻", "pro\u{0000}ject"]
        let expected = ["project", "café", "漢字", "👩‍💻", "project"]
        for (query, term) in zip(cases, expected) {
            let parsed = try parser.parse(query, now: now)
            XCTAssertEqual(parsed.expression, .term(term, prefix: true))
            XCTAssertEqual(parsed.tokens.count, 1)
            XCTAssertEqual(parsed.tokens.first?.text, term)
            XCTAssertEqual(parsed.tokens.first?.sourceRange, .init(location: 0, length: query.utf16.count))
        }
        XCTAssertThrowsError(try parser.parse("\u{0000}\u{0007}", now: now)) { error in
            XCTAssertEqual(error as? MailSearchError, .invalidQuery(reason: "Query is empty.", range: nil))
        }
    }

    func testBooleanPrecedenceAndFieldScoping() throws {
        let parsed = try parser.parse(
            #"from:(alice OR bob) subject:"project alpha" -in:trash"#,
            now: now
        )

        XCTAssertEqual(parsed.expression, .all([
            .field(.from, .any([.term("alice", prefix: true), .term("bob", prefix: true)])),
            .field(.subject, .phrase("project alpha")),
            .not(.location(.trash)),
        ]))
    }

    func testExplicitBooleanOperatorsNestedGroupsAndUnaryForms() throws {
        let parsed = try parser.parse(
            "NOT (alpha OR beta) AND (gamma OR (delta AND -epsilon))",
            now: now
        )

        XCTAssertEqual(parsed.expression, .all([
            .not(.any([
                .term("alpha", prefix: true),
                .term("beta", prefix: true),
            ])),
            .any([
                .term("gamma", prefix: true),
                .all([
                    .term("delta", prefix: true),
                    .not(.term("epsilon", prefix: true)),
                ]),
            ]),
        ]))
    }

    func testImplicitAndAndQuotedPhrase() throws {
        let parsed = try parser.parse(#"alpha "project alpha" beta"#, now: now)

        XCTAssertEqual(parsed.expression, .all([
            .term("alpha", prefix: true),
            .phrase("project alpha"),
            .term("beta", prefix: true),
        ]))
    }

    func testApprovedFieldExamplesParse() throws {
        for field in MailSearchFieldRegistry.all {
            for example in field.examples {
                XCTAssertNoThrow(try parser.parse(example, now: now), example)
            }
        }
    }

    func testTextFieldAliasesAndEnumeratedValues() throws {
        let cases: [(String, MailSearchQueryExpression)] = [
            ("participant:jos\u{00E9}", .field(.participants, .term("jos\u{00E9}", prefix: true))),
            ("attachment:report", .field(.filename, .term("report", prefix: true))),
            ("has:attachment", .content(.attachment)),
            ("has:attachments", .content(.attachment)),
            ("has:document", .content(.document)),
            ("has:documents", .content(.document)),
            ("with:attachment", .content(.attachment)),
            ("with:attachments", .content(.attachment)),
            ("with:document", .content(.document)),
            ("with:documents", .content(.document)),
            ("is:unread", .state(.unread)),
            ("is:read", .state(.read)),
            ("is:flagged", .state(.flagged)),
            ("is:delegated", .state(.delegated)),
            ("delegated", .state(.delegated)),
            ("in:inbox", .location(.inbox)),
            ("in:sent", .location(.sent)),
            ("in:trash", .location(.trash)),
        ]

        for (query, expression) in cases {
            XCTAssertEqual(try parser.parse(query, now: now).expression, expression, query)
        }
    }

    func testAttachmentValueAliasesNormalizeToCanonicalExpressions() throws {
        for query in ["has:attachment", "has:attachments", "with:attachment", "with:attachments"] {
            XCTAssertEqual(
                try parser.parse(query, now: now).canonicalQuery,
                "has:attachment",
                query
            )
        }
        for query in ["has:document", "has:documents", "with:document", "with:documents"] {
            XCTAssertEqual(
                try parser.parse(query, now: now).canonicalQuery,
                "has:document",
                query
            )
        }
    }

    func testUnknownFieldReportsItsUTF16Range() {
        XCTAssertThrowsError(try parser.parse("project owner:alex", now: now)) { error in
            XCTAssertEqual(error as? MailSearchError, .unsupportedField(
                name: "owner",
                range: .init(location: 8, length: 5)
            ))
        }

        XCTAssertThrowsError(try parser.parse("\u{1F600} owner:alex", now: now)) { error in
            XCTAssertEqual(error as? MailSearchError, .unsupportedField(
                name: "owner",
                range: .init(location: 3, length: 5)
            ))
        }
    }

    func testInjectionLikeTextRemainsText() throws {
        let parsed = try parser.parse(#"subject:" OR 1=1 --""#, now: now)
        XCTAssertEqual(parsed.expression, .field(.subject, .phrase(" OR 1=1 --")))
    }

    func testQuotedPhrasesSupportOnlyCanonicalQuoteAndBackslashEscapes() throws {
        XCTAssertEqual(
            try parser.parse(#""project \"alpha\" \\ archive""#, now: now).expression,
            .phrase("project \"alpha\" \\ archive")
        )
        XCTAssertEqual(
            try parser.parse(#"subject:"say \"hi\" in C:\\Mail""#, now: now).expression,
            .field(.subject, .phrase("say \"hi\" in C:\\Mail"))
        )
    }

    func testInvalidQuotedEscapesReportExactUTF16RangesWithoutRejectedText() {
        let cases: [(String, MailSearchError)] = [
            (
                #""bad\q""#,
                .invalidQuery(
                    reason: "Quoted phrase contains an unsupported escape.",
                    range: .init(location: 4, length: 2)
                )
            ),
            (
                "\"bad\\",
                .invalidQuery(
                    reason: "Quoted phrase has a dangling escape.",
                    range: .init(location: 4, length: 1)
                )
            ),
        ]

        for (query, expected) in cases {
            XCTAssertThrowsError(try parser.parse(query, now: now), query) { error in
                XCTAssertEqual(error as? MailSearchError, expected)
                XCTAssertFalse(String(describing: error).contains(query))
            }
        }
    }

    func testUnicodeIsPrecomposedWithoutLosingOriginalUTF16Range() throws {
        let parsed = try parser.parse("cafe\u{0301} r\u{00E9}sum\u{00E9}", now: now)

        XCTAssertEqual(parsed.expression, .all([
            .term("caf\u{00E9}", prefix: true),
            .term("r\u{00E9}sum\u{00E9}", prefix: true),
        ]))
        XCTAssertEqual(parsed.tokens.first, .init(
            kind: .text,
            text: "caf\u{00E9}",
            sourceRange: .init(location: 0, length: 5)
        ))
    }

    func testControlCharactersAreRemovedBeforeParsing() throws {
        let parsed = try parser.parse("pro\u{0000}ject subject:\u{0007}alpha", now: now)
        XCTAssertEqual(parsed.expression, .all([
            .term("project", prefix: true),
            .field(.subject, .term("alpha", prefix: true)),
        ]))
    }

    func testDateFormsUseInjectedCalendarAndHalfOpenIntervals() throws {
        let july1 = date(2026, 7, 1)
        let july2 = date(2026, 7, 2)
        let july19 = date(2026, 7, 19)
        let june18At1530 = date(2026, 6, 18, hour: 15, minute: 30)
        let july11At1530 = date(2026, 7, 11, hour: 15, minute: 30)

        let cases: [(String, MailSearchDateInterval)] = [
            ("since:2026-07-01", .init(lowerBound: july1, upperBound: nil)),
            ("since:7d", .init(lowerBound: july11At1530, upperBound: nil)),
            ("since:1w", .init(lowerBound: july11At1530, upperBound: nil)),
            ("since:1m", .init(lowerBound: june18At1530, upperBound: nil)),
            ("since:1y", .init(lowerBound: date(2025, 7, 18, hour: 15, minute: 30), upperBound: nil)),
            ("after:2026-07-01", .init(lowerBound: july2, upperBound: nil)),
            ("after:today", .init(lowerBound: july19, upperBound: nil)),
            ("after:yesterday", .init(lowerBound: date(2026, 7, 18), upperBound: nil)),
            ("before:2026-07-01", .init(lowerBound: nil, upperBound: july1)),
            ("before:today", .init(lowerBound: nil, upperBound: date(2026, 7, 18))),
            ("before:yesterday", .init(lowerBound: nil, upperBound: date(2026, 7, 17))),
            ("on:2026-07-01", .init(lowerBound: july1, upperBound: july2)),
            ("on:today", .init(lowerBound: date(2026, 7, 18), upperBound: july19)),
            ("on:yesterday", .init(lowerBound: date(2026, 7, 17), upperBound: date(2026, 7, 18))),
            ("date:2026-07-01..2026-07-18", .init(lowerBound: july1, upperBound: july19)),
        ]

        for (query, interval) in cases {
            XCTAssertEqual(try parser.parse(query, now: now).expression, .date(interval), query)
        }
    }

    func testImpossibleDatesReversedRangesAndRelativeZeroAreRejected() {
        for query in [
            "on:2023-02-29",
            "date:2026-07-18..2026-07-01",
            "since:0d",
            "after:tomorrow",
            "after:9999-12-31",
        ] {
            XCTAssertThrowsError(try parser.parse(query, now: now), query) { error in
                guard case .unsupportedValue = error as? MailSearchError else {
                    return XCTFail("Expected unsupported value for \(query), got \(error)")
                }
            }
        }
    }

    func testQueryTermClauseAndDepthLimits() throws {
        XCTAssertNoThrow(try parser.parse(String(repeating: "a", count: 2_048), now: now))
        assertError(
            tryParse: { try self.parser.parse(String(repeating: "a", count: 2_049), now: self.now) },
            equals: .requestTooLarge(maximum: 2_048)
        )

        let maximumTerms = (0 ..< 64).map { "term\($0)" }.joined(separator: " ")
        XCTAssertNoThrow(try parser.parse(maximumTerms, now: now))
        assertInvalidQuery(
            (0 ... 64).map { "term\($0)" }.joined(separator: " "),
            reason: "Too many terms; maximum is 64."
        )

        let maximumClauses = Array(repeating: "is:read", count: 32).joined(separator: " ")
        XCTAssertNoThrow(try parser.parse(maximumClauses, now: now))
        assertInvalidQuery(
            Array(repeating: "is:read", count: 33).joined(separator: " "),
            reason: "Too many clauses; maximum is 32."
        )

        XCTAssertNoThrow(try parser.parse(String(repeating: "(", count: 8) + "alpha" + String(repeating: ")", count: 8), now: now))
        assertInvalidQuery(
            String(repeating: "(", count: 9) + "alpha" + String(repeating: ")", count: 9),
            reason: "Nesting is too deep; maximum is 8."
        )
    }

    func testSingleGraphemeCannotBypassTheBoundedLexerPreflight() {
        let combiningMarkStress = "a" + String(repeating: "\u{0301}", count: 9_000)
        assertError(
            tryParse: { try self.parser.parse(combiningMarkStress, now: self.now) },
            equals: .requestTooLarge(maximum: 2_048)
        )
    }

    func testTextOnlyPredicateFailsClosedBeyondCanonicalNodeBudget() {
        var expression = MailSearchQueryExpression.term("project", prefix: true)
        for _ in 0 ... MailSearchQueryParser.maximumExpressionNodeCount {
            expression = .not(expression)
        }

        XCTAssertFalse(expression.isTextOnly)
    }

    func testRawUTF8PreflightAccepts8192BytesAndRejects8193Bytes() throws {
        let exactBoundary = String(repeating: "\u{1F600}", count: 2_048)
        XCTAssertEqual(exactBoundary.utf8.count, 8_192)
        XCTAssertEqual(exactBoundary.count, 2_048)
        XCTAssertNoThrow(try parser.parse(exactBoundary, now: now))

        let overBoundary = String(repeating: "\u{1F600}", count: 2_047)
            + "a\u{0301}\u{0301}"
        XCTAssertEqual(overBoundary.utf8.count, 8_193)
        XCTAssertEqual(overBoundary.count, 2_048)
        assertError(
            tryParse: { try self.parser.parse(overBoundary, now: self.now) },
            equals: .requestTooLarge(maximum: 2_048)
        )
    }

    func testEmptyAndMalformedQueriesReturnSafeTypedErrors() {
        for query in ["", "   ", "\u{0000}\n", "from:", "()", "alpha OR", "AND alpha", "\"open"] {
            XCTAssertThrowsError(try parser.parse(query, now: now), query) { error in
                guard case .invalidQuery(let reason, _) = error as? MailSearchError else {
                    return XCTFail("Expected invalid query for \(query.debugDescription), got \(error)")
                }
                XCTAssertFalse(reason.contains(query))
                XCTAssertLessThan(reason.count, 100)
            }
        }
    }

    func testEmptyStructuredAndUnsupportedEnumeratedValuesReportValueRanges() {
        XCTAssertThrowsError(try parser.parse("from:", now: now)) { error in
            guard case .invalidQuery(_, let range) = error as? MailSearchError else {
                return XCTFail("Expected invalid query, got \(error)")
            }
            XCTAssertEqual(range, .init(location: 5, length: 0))
        }

        XCTAssertThrowsError(try parser.parse("is:urgent", now: now)) { error in
            XCTAssertEqual(error as? MailSearchError, .unsupportedValue(
                field: "is",
                range: .init(location: 3, length: 6)
            ))
        }
    }

    func testCanonicalQueryIsNormalizedDeterministically() throws {
        let parsed = try parser.parse(
            #"FROM:(alice OR bob) subject:"project alpha" -in:trash"#,
            now: now
        )

        XCTAssertEqual(
            parsed.canonicalQuery,
            #"from:(alice OR bob) AND subject:"project alpha" AND NOT in:trash"#
        )
        XCTAssertEqual(
            try parser.parse(parsed.canonicalQuery, now: now).expression,
            parsed.expression
        )
    }

    func testCanonicalQuotedEscapesAreDeterministicAndRoundTrip() throws {
        let cases = [
            #""a \\ path and \"quote\"""#,
            #"subject:"a \\ path and \"quote\"""#,
        ]

        for query in cases {
            let parsed = try parser.parse(query, now: now)
            XCTAssertEqual(parsed.canonicalQuery, query)
            XCTAssertEqual(
                try parser.parse(parsed.canonicalQuery, now: now).expression,
                parsed.expression
            )
        }
    }

    func testCanonicalGuidesAreGeneratedFromTheFieldRegistry() {
        for field in MailSearchFieldRegistry.all {
            XCTAssertTrue(MailSearchFieldRegistry.cliGuide.contains("- \(field.name)"), field.name)
            XCTAssertTrue(MailSearchFieldRegistry.mcpGuide.contains("- \(field.name)"), field.name)
            for example in field.examples {
                XCTAssertTrue(MailSearchFieldRegistry.cliGuide.contains(example), example)
                XCTAssertTrue(MailSearchFieldRegistry.mcpGuide.contains(example), example)
            }
        }
        XCTAssertEqual(MailSearchFieldRegistry.canonicalName(for: "participant"), "participants")
        XCTAssertEqual(MailSearchFieldRegistry.canonicalName(for: "ATTACHMENT"), "filename")
        XCTAssertNil(MailSearchFieldRegistry.canonicalName(for: "owner"))
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func assertInvalidQuery(
        _ query: String,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertError(
            tryParse: { try self.parser.parse(query, now: self.now) },
            equals: .invalidQuery(reason: reason, range: nil),
            file: file,
            line: line
        )
    }

    private func assertError(
        tryParse: () throws -> MailSearchParsedQuery,
        equals expected: MailSearchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try tryParse(), file: file, line: line) { error in
            XCTAssertEqual(error as? MailSearchError, expected, file: file, line: line)
        }
    }
}
