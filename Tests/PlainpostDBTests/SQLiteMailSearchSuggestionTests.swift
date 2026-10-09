import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class SQLiteMailSearchSuggestionTests: XCTestCase {
    func testSuggestionsUseRecentPeopleFieldsFiltersPrecedenceAndGlobalBound() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection((0 ..< 12).map { index in
            .init(
                id: "person-\(index)",
                senderEmail: "alex\(index)@example.com",
                senderDisplayName: "Alex \(index)",
                subject: "Mail",
                sortDate: Double(index)
            )
        })
        let recent = (0 ..< 10).map { "recent \($0)" }

        let sections = try await fixture.service.suggestions(.init(
            query: "a",
            recentQueries: recent,
            activeRange: .init(location: 0, length: 1)
        ))

        XCTAssertEqual(sections.map(\.kind), [.recent, .people, .fields, .filters])
        XCTAssertEqual(sections.first?.items.map(\.title), recent)
        XCTAssertLessThanOrEqual(sections.flatMap(\.items).count, 30)
        XCTAssertLessThanOrEqual(sections.first { $0.kind == .people }?.items.count ?? 0, 10)
    }

    func testOneCharacterSuggestionDoesNotSearchBodiesAndUsesScopedPeopleLimit() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", accountID: "a1", senderEmail: "alice@example.com", senderDisplayName: "Alice"),
            .init(id: "adam", accountID: "a1", senderEmail: "adam@example.com", senderDisplayName: "Adam"),
            .init(id: "mallory", accountID: "a2", senderEmail: "mallory@example.com", senderDisplayName: "Mallory"),
            .init(id: "body-only", accountID: "a1", senderEmail: "nobody@example.com", body: "alice"),
        ])
        let recorder = Task5SQLRecorder()
        try await fixture.store.databasePool.read { database in
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                recorder.append(statement.sql)
            }
        }

        let sections = try await fixture.service.suggestions(.init(
            query: "a",
            scope: .init(accountIDs: [AccountID("a1")]),
            recentQueries: [],
            activeRange: .init(location: 0, length: 1)
        ))
        let people = sections.first { $0.kind == .people }?.items ?? []

        XCTAssertEqual(Set(people.map(\.title)), ["Adam", "Alice"])
        let peopleSQL = try XCTUnwrap(recorder.statements.first { $0.contains("mail_search_documents") })
        XCTAssertFalse(peopleSQL.contains("body_text"))
        XCTAssertTrue(peopleSQL.localizedCaseInsensitiveContains("limit 10"))
        XCTAssertLessThanOrEqual(sections.flatMap(\.items).count, 30)
    }

    func testPeopleSuggestionsAreSkippedForNonPersonFieldPosition() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(
                id: "emile",
                senderEmail: "emile@example.com",
                senderDisplayName: "e\u{301}mile"
            )
        ])

        let sections = try await fixture.service.suggestions(.init(
            query: "subject:a",
            recentQueries: [],
            activeRange: .init(location: 8, length: 1)
        ))

        XCTAssertFalse(sections.contains { $0.kind == .people })
    }

    func testPeopleSuggestionsAreSkippedInsideQuotedNonPersonFieldValues() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", senderEmail: "alice@example.com", senderDisplayName: "Alice")
        ])
        let requests: [(String, MailSearchTextRange)] = [
            ("subject:\"al\"", .init(location: 9, length: 2)),
            ("subject:\"al", .init(location: 9, length: 2)),
            ("filename:\"al\"", .init(location: 10, length: 2)),
            ("attachment:\"al\\\"😀\"", .init(location: 12, length: 2)),
        ]

        for (query, activeRange) in requests {
            let sections = try await fixture.service.suggestions(.init(
                query: query,
                recentQueries: [],
                activeRange: activeRange
            ))
            XCTAssertFalse(sections.contains { $0.kind == .people }, query)
        }
    }

    func testPeopleSuggestionsRemainAvailableInsideQuotedPersonFieldValues() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", senderEmail: "alice@example.com", senderDisplayName: "Alice")
        ])
        let requests: [(String, MailSearchTextRange)] = [
            ("from:\"al\"", .init(location: 6, length: 2)),
            ("from:\"al", .init(location: 6, length: 2)),
            ("participant:\"al\\\"😀\"", .init(location: 13, length: 2)),
        ]

        for (query, activeRange) in requests {
            let sections = try await fixture.service.suggestions(.init(
                query: query,
                recentQueries: [],
                activeRange: activeRange
            ))
            XCTAssertNotNil(
                sections.first { $0.kind == .people }?.items.first { $0.title == "Alice" },
                query
            )
        }
    }

    func testPersonInsertionUsesTheActiveUTF16ReplacementRange() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", senderEmail: "alice@example.com", senderDisplayName: "Alice")
        ])
        let range = MailSearchTextRange(location: 5, length: 3)

        let sections = try await fixture.service.suggestions(.init(
            query: "from:ali",
            recentQueries: [],
            activeRange: range
        ))
        let alice = try XCTUnwrap(
            sections.first { $0.kind == .people }?.items.first { $0.title == "Alice" }
        )

        XCTAssertEqual(alice.insertion, "alice@example.com")
        XCTAssertEqual(alice.replacementRange, range)
    }

    func testPersonSuggestionsInsideGroupedAndWhitespaceEmptyFieldsStayFieldLocal() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", senderEmail: "alice@example.com", senderDisplayName: "Alice")
        ])
        let queries = ["from:(al OR bob)", "from:   "]

        for query in queries {
            let selectionLocation: Int
            if let range = query.range(of: "al") {
                selectionLocation = query.utf16.distance(
                    from: query.startIndex,
                    to: range.upperBound
                )
            } else {
                selectionLocation = query.utf16.count
            }
            let context = try XCTUnwrap(
                MailSearchQueryParser.suggestionContext(
                    in: query,
                    selection: .init(location: selectionLocation, length: 0)
                ),
                query
            )
            let sections = try await fixture.service.suggestions(.init(
                query: query,
                recentQueries: [],
                activeRange: context.replacementRange
            ))
            let alice = try XCTUnwrap(
                sections.first { $0.kind == .people }?.items.first { $0.title == "Alice" },
                query
            )

            XCTAssertEqual(alice.insertion, "alice@example.com", query)
            XCTAssertFalse(sections.contains { $0.kind == .fields }, query)
        }
    }

    func testUnicodeSuggestionWithoutExplicitRangeUsesValidUTF16Replacement() async throws {
        let fixture = try Task5SearchFixture()

        let sections = try await fixture.service.suggestions(.init(
            query: "😀",
            recentQueries: ["emoji recent"]
        ))
        let recent = try XCTUnwrap(sections.first?.items.first)

        XCTAssertEqual(recent.replacementRange, .init(location: 0, length: 2))
    }

    func testSuggestionRangeNormalizesInsertionPointInsideEmojiSurrogatePair() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "alice", senderEmail: "alice@example.com", senderDisplayName: "😀 Alice")
        ])
        let query = "from:😀"

        let sections = try await fixture.service.suggestions(.init(
            query: query,
            recentQueries: [],
            activeRange: .init(location: 6, length: 0)
        ))
        let alice = try XCTUnwrap(
            sections.first { $0.kind == .people }?.items.first { $0.title == "😀 Alice" }
        )

        let replacementRange = try XCTUnwrap(alice.replacementRange)
        XCTAssertEqual(replacementRange, .init(location: 5, length: 2))
        assertComposedSequenceRange(replacementRange, in: query)
    }

    func testSuggestionRangeNormalizesPartialDecomposedGrapheme() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(
                id: "emile",
                senderEmail: "emile@example.com",
                senderDisplayName: "e\u{301}mile"
            )
        ])
        let query = "from:e\u{301}"

        let sections = try await fixture.service.suggestions(.init(
            query: query,
            recentQueries: [],
            activeRange: .init(location: 5, length: 1)
        ))
        let emile = try XCTUnwrap(
            sections.first { $0.kind == .people }?.items.first { $0.title == "e\u{301}mile" }
        )

        let replacementRange = try XCTUnwrap(emile.replacementRange)
        XCTAssertEqual(replacementRange, .init(location: 5, length: 2))
        assertComposedSequenceRange(replacementRange, in: query)
    }

    func testRegistryAndMailboxSuggestionsRespectActiveRangeAndMailboxLimit() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertMailboxes((0 ..< 10).map { "Project \($0)" })

        let fieldSections = try await fixture.service.suggestions(.init(
            query: "sub",
            recentQueries: [],
            activeRange: .init(location: 0, length: 3)
        ))
        let subject = try XCTUnwrap(
            fieldSections.first { $0.kind == .fields }?.items.first { $0.title == "subject" }
        )
        XCTAssertEqual(subject.insertion, "subject:")
        XCTAssertEqual(subject.replacementRange, .init(location: 0, length: 3))

        let mailboxSections = try await fixture.service.suggestions(.init(
            query: "mailbox:Pro",
            recentQueries: [],
            activeRange: .init(location: 8, length: 3)
        ))
        let mailboxes = mailboxSections.first { $0.kind == .filters }?.items.filter {
            $0.id.hasPrefix("mailbox:")
        } ?? []
        XCTAssertEqual(mailboxes.count, 8)
        XCTAssertTrue(mailboxes.allSatisfy { $0.insertion.hasPrefix("\"") && $0.insertion.hasSuffix("\"") })
        XCTAssertTrue(mailboxes.allSatisfy { $0.replacementRange == .init(location: 8, length: 3) })
    }

    func testSuggestionsDoNotPersistQueryOrRecentHistory() async throws {
        let fixture = try Task5SearchFixture()
        let secret = "private-search-value"

        _ = try await fixture.service.suggestions(.init(
            query: secret,
            recentQueries: ["private recent value"]
        ))

        let searchHistoryObjects = try await fixture.store.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE lower(name) LIKE '%search%history%'"
            )
        }
        let persistedText = try await fixture.store.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT COALESCE(CAST(last_optimized_at AS TEXT), '') FROM mail_search_maintenance"
            ).joined(separator: "\n")
        }
        XCTAssertTrue(searchHistoryObjects.isEmpty)
        XCTAssertFalse(persistedText.contains(secret))
        XCTAssertFalse(persistedText.contains("private recent value"))
    }

    private func assertComposedSequenceRange(
        _ range: MailSearchTextRange,
        in query: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = query as NSString
        XCTAssertGreaterThanOrEqual(range.location, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(range.length, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(range.location, source.length, file: file, line: line)
        guard range.location >= 0,
              range.length >= 0,
              range.location <= source.length,
              range.length <= source.length - range.location else {
            return
        }
        let nsRange = NSRange(location: range.location, length: range.length)
        XCTAssertEqual(
            source.rangeOfComposedCharacterSequences(for: nsRange),
            nsRange,
            file: file,
            line: line
        )
    }
}

private extension Task5SearchFixture {
    func insertMailboxes(_ names: [String]) throws {
        try store.databasePool.write { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO accounts(
                    id, display_name, email, username, sent_mailbox,
                    imap_host, imap_port, smtp_host, smtp_port
                ) VALUES ('a1', 'Account', 'owner@example.com', 'owner', 'Sent',
                          'imap.example.com', 993, 'smtp.example.com', 587)
                """)
            for (index, name) in names.enumerated() {
                try database.execute(
                    sql: "INSERT INTO mailboxes(id, account_id, name, path, special_use) VALUES (?, 'a1', ?, ?, NULL)",
                    arguments: ["mailbox-\(index)", name, name]
                )
            }
        }
    }
}
