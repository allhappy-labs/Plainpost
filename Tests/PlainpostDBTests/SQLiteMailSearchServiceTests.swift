import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class SQLiteMailSearchServiceTests: XCTestCase {
    private let parser: MailSearchQueryParser = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MailSearchQueryParser(calendar: calendar)
    }()
    private let now = Date(timeIntervalSince1970: 1_768_608_000)
    private let snippetMarkers = SQLiteMailSearchSnippetMarkers(nonce: "compiler-tests")

    func testCompilerUsesPrefixesForBareTermsAndPhrasesForQuotedTerms() throws {
        let compiler = SQLiteMailSearchQueryCompiler()
        let prefix = try compiler.compile(
            parser.parse("project", now: now),
            request: .init(query: "project", mode: .messages),
            snippetMarkers: snippetMarkers
        )
        let phrase = try compiler.compile(
            parser.parse(#""project alpha""#, now: now),
            request: .init(query: #""project alpha""#, mode: .messages),
            snippetMarkers: snippetMarkers
        )

        XCTAssertEqual(prefix.ftsQuery, #""project"*"#)
        XCTAssertEqual(phrase.ftsQuery, #""project alpha""#)
        XCTAssertFalse(phrase.ftsQuery?.contains("*") ?? true)
        XCTAssertEqual(
            SQLiteMailSearchQueryCompiler.bm25Weights,
            [8.0, 4.0, 4.0, 4.0, 10.0, 6.0, 3.0, 1.0, 8.0, 1.0]
        )
        XCTAssertFalse(prefix.sql.localizedCaseInsensitiveContains("offset"))
    }

    func testSelectedAccountFindsPostSenderByNameAndAddress() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "post-mail", accountID: "selected", sender: "Post CH Ltd notifications@post.ch",
                  senderEmail: "notifications@post.ch", senderDisplayName: "Post CH Ltd",
                  subject: "Your parcel", body: "Delivery update"),
            .init(id: "other-post", accountID: "other", sender: "Post CH Ltd notifications@post.ch",
                  senderEmail: "notifications@post.ch", senderDisplayName: "Post CH Ltd",
                  subject: "Other account")
        ])
        let search = SQLiteMailSearchService(
            store: fixture.store, selectedAccountID: AccountID("selected")
        )

        let response = try await search.search(.init(query: "Post", mode: .conversations))

        XCTAssertEqual(response.hits.count, 1)
        guard case .conversation(let hit) = response.hits.first else {
            return XCTFail("Expected a conversation result")
        }
        XCTAssertEqual(hit.accountID, AccountID("selected"))
    }

    func testSingleTextCompilerMaterializesFTSScoreOnceBeforeRanking() throws {
        let compiler = SQLiteMailSearchQueryCompiler()
        let compiled = try compiler.compile(
            parser.parse("project", now: now),
            request: .init(query: "project", mode: .messages),
            snippetMarkers: snippetMarkers
        )

        XCTAssertTrue(compiled.sql.contains("fts_scores AS MATERIALIZED"))
        XCTAssertTrue(compiled.sql.contains("LEFT JOIN fts_scores AS fts_score"))
        XCTAssertTrue(compiled.sql.contains("fts_score.rowid IS NOT NULL"))
        XCTAssertFalse(compiled.sql.contains("SELECT -bm25"))
    }

    func testMessageCompilerPreservesTask4RawMessageIDOrderingAndKeyset() throws {
        let compiler = SQLiteMailSearchQueryCompiler()
        let parsed = try parser.parse("project", now: now)
        let request = MailSearchRequest(query: "project", mode: .messages, limit: 1)
        let compiled = try compiler.compile(
            parsed,
            request: request,
            cursor: .init(
                exactTier: 1,
                lexicalScore: 0.5,
                sortDate: 100,
                stableID: "raw-message-id"
            ),
            snippetMarkers: snippetMarkers
        )

        XCTAssertEqual(
            compiled.cursorSortDescriptors,
            [
                "exact_tier DESC",
                "lexical_score DESC",
                "recency_score DESC",
                "sort_date DESC",
                "message_id ASC",
            ]
        )
        XCTAssertTrue(compiled.sql.contains("sort_date DESC, message_id ASC"))
        XCTAssertTrue(compiled.sql.contains("sort_date = ? AND message_id > ?"))
        XCTAssertFalse(compiled.sql.contains("stable_id"))
    }

    func testCompilerMapsEveryTextFieldOnlyThroughApprovedFTSColumns() throws {
        let compiler = SQLiteMailSearchQueryCompiler()
        let fields: [(String, String)] = [
            ("from:alice", "sender"),
            ("to:alice", "to_value"),
            ("cc:alice", "cc_value"),
            ("bcc:alice", "bcc_value"),
            ("participants:alice", "{sender to_value cc_value bcc_value}"),
            ("subject:alice", "subject"),
            ("filename:alice", "filenames"),
            ("mailbox:alice", "mailbox_names"),
        ]

        for (query, column) in fields {
            let compiled = try compiler.compile(
                parser.parse(query, now: now),
                request: .init(query: query, mode: .messages),
                snippetMarkers: snippetMarkers
            )
            XCTAssertEqual(compiled.ftsQuery, #"\#(column) : "alice"*"#, query)
            XCTAssertFalse(compiled.sql.contains(query), query)
            XCTAssertNoThrow(try SearchFixture.explain(compiled), query)
        }
    }

    func testCompilerBindsInjectionLikeTextInsteadOfInterpolatingIt() throws {
        let query = #"subject:" OR 1=1 --""#
        let compiled = try SQLiteMailSearchQueryCompiler().compile(
            parser.parse(query, now: now),
            request: .init(query: query, mode: .messages),
            snippetMarkers: snippetMarkers
        )

        XCTAssertFalse(compiled.sql.contains("OR 1=1"))
        XCTAssertEqual(compiled.ftsQuery, #"subject : " OR 1=1 --""#)
    }

    func testInjectionLikePhraseExecutesAsText() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-match", subject: "OR 1=1 --"),
            .init(id: "m-other", subject: "Unrelated"),
        ])

        let response = try await fixture.search(#"subject:" OR 1=1 --""#)

        XCTAssertEqual(response.messageIDs, ["m-match"])
    }

    func testStructuredOnlySearchDoesNotReferenceFTS() throws {
        let query = "is:unread after:2026-07-01"
        let compiled = try SQLiteMailSearchQueryCompiler().compile(
            parser.parse(query, now: now),
            request: .init(query: query, mode: .messages),
            snippetMarkers: snippetMarkers
        )

        XCTAssertFalse(compiled.sql.localizedCaseInsensitiveContains("mail_search_fts"))
        XCTAssertNil(compiled.ftsQuery)
        XCTAssertTrue(compiled.sql.contains("d.is_seen = 0"))
        XCTAssertTrue(compiled.sql.contains("d.sort_date >= ?"))
        XCTAssertFalse(compiled.sql.localizedCaseInsensitiveContains("offset"))
        XCTAssertNoThrow(try SearchFixture.explain(compiled))
    }

    func testCompilerPreservesBooleanAndFieldSemantics() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-project", subject: "Project", isSeen: false),
            .init(id: "m-flagged", subject: "Other", isSeen: true, isFlagged: true),
            .init(id: "m-read", subject: "Project", isSeen: true),
            .init(id: "m-trash", subject: "Other", isSeen: true, isFlagged: true, isTrash: true),
        ])

        let union = try await fixture.search("(subject:project OR is:flagged) NOT in:trash")
        XCTAssertEqual(Set(union.messageIDs), ["m-project", "m-flagged", "m-read"])

        let negated = try await fixture.search("is:unread NOT subject:other")
        XCTAssertEqual(negated.messageIDs, ["m-project"])
    }

    func testServiceAppliesEveryStructuredAndTextField() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(
                id: "m-fields",
                accountID: "a1",
                mailboxIDs: "mb-inbox",
                mailboxNames: "Project Alpha",
                sender: "Alex Rivera alex@example.com",
                senderEmail: "alex@example.com",
                senderDisplayName: "Alex Rivera",
                to: "bob@example.com",
                cc: "finance@example.com",
                bcc: "legal@example.com",
                subject: "Quarterly forecast",
                preview: "Review the attached figures",
                body: "The project alpha forecast is ready",
                filenames: "forecast.pdf",
                sortDate: 1_783_046_400,
                isSeen: false,
                isFlagged: true,
                isDelegated: true,
                isInbox: true,
                isSent: true,
                hasAttachments: true,
                hasDocuments: true
            ),
            .init(id: "m-other", accountID: "a2", mailboxIDs: "mb-other", subject: "Other", isSeen: true),
        ])

        for query in [
            "from:alex", "to:bob", "cc:finance", "bcc:legal", "participants:rivera",
            "subject:quarter", "filename:fore", "mailbox:project", "has:attachment",
            "has:document", "is:unread", "is:flagged", "is:delegated", "in:inbox",
            "in:sent", "after:2026-07-01 before:2026-08-01",
        ] {
            let response = try await fixture.search(query)
            XCTAssertEqual(response.messageIDs, ["m-fields"], query)
        }

        let read = try await fixture.search(
            "is:read",
            scope: .init(accountIDs: [AccountID("a2")])
        )
        XCTAssertEqual(read.messageIDs, ["m-other"])

        let fields = try await fixture.search("subject:quarter")
        let hit = try XCTUnwrap(fields.messageHits.first)
        let expectedRecipients: Set<EmailAddress> = [
            EmailAddress("bob@example.com"),
            EmailAddress("finance@example.com"),
            EmailAddress("legal@example.com"),
        ]
        XCTAssertEqual(hit.sender, EmailAddress("alex@example.com"))
        XCTAssertEqual(hit.senderDisplayName, "Alex Rivera")
        XCTAssertEqual(Set(hit.recipients), expectedRecipients)
        XCTAssertEqual(hit.mailboxIDs, [MailboxID("mb-inbox")])
        XCTAssertTrue(hit.isUnread)
        XCTAssertTrue(hit.isFlagged)
        XCTAssertTrue(hit.isDelegated)
        XCTAssertTrue(hit.hasAttachments)
        XCTAssertTrue(hit.hasDocuments)
    }

    func testQuotedPhraseRequiresAdjacentTerms() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-phrase", subject: "Project Alpha"),
            .init(id: "m-separated", subject: "Project Beta Alpha"),
        ])

        let response = try await fixture.search(#""project alpha""#)

        XCTAssertEqual(response.messageIDs, ["m-phrase"])
    }

    func testScopeAndTrashRulesAreExact() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-a1", accountID: "a1", mailboxIDs: "mb-one", subject: "Project"),
            .init(id: "m-a2", accountID: "a2", mailboxIDs: "mb-two", subject: "Project"),
            .init(id: "m-trash", accountID: "a1", mailboxIDs: "mb-trash", subject: "Project", isTrash: true),
            .init(id: "m-trash-other", accountID: "a1", mailboxIDs: "mb-trash", subject: "Unrelated", isTrash: true),
        ])

        let all = try await fixture.search("project")
        let account = try await fixture.search(
            "project",
            scope: .init(accountIDs: [AccountID("a1")])
        )
        let mailbox = try await fixture.search(
            "project",
            scope: .init(mailboxIDs: [MailboxID("mb-two")])
        )
        let trash = try await fixture.search("project in:trash")
        let union = try await fixture.search("project OR in:trash")

        XCTAssertEqual(Set(all.messageIDs), ["m-a1", "m-a2"])
        XCTAssertEqual(account.messageIDs, ["m-a1"])
        XCTAssertEqual(mailbox.messageIDs, ["m-a2"])
        XCTAssertEqual(trash.messageIDs, ["m-trash"])
        XCTAssertEqual(Set(union.messageIDs), ["m-a1", "m-a2", "m-trash", "m-trash-other"])
    }

    func testSelectedDirectAccountSearchCannotReadNodeAccountRowsSuggestionsOrCursor() async throws {
        let fixture = try SearchFixture()
        let node = Account(
            id: AccountID("a-node"), displayName: "Node",
            email: EmailAddress("node@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        let direct = Account(
            id: AccountID("b-direct"), displayName: "Direct",
            email: EmailAddress("direct@example.com"),
            imapHost: "imap.example.com", smtpHost: "smtp.example.com"
        )
        for (account, mailboxID) in [(node, "mb-node"), (direct, "mb-direct")] {
            let source = try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
            try fixture.store.cacheAccountSetup(
                account: account,
                inbox: Mailbox(id: MailboxID(mailboxID), accountID: account.id,
                               name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                source: source
            )
            if account.id == node.id {
                let nodeSource = source.nodeBacked(
                    nodeID: "A5BE1F45-6473-4D29-BC58-18B63F13B1EA",
                    logicalMailboxID: String(repeating: "A", count: 43),
                    providerIdentity: "node@example.com"
                )
                _ = try fixture.store.replaceMailSource(nodeSource, expectedGeneration: 1)
            }
        }
        XCTAssertEqual(try fixture.store.mailSource(accountID: node.id).kind, .nodeBacked)
        XCTAssertEqual(try fixture.store.mailSource(accountID: direct.id).kind, .direct)
        try fixture.insert([
            .init(id: "m-node", threadID: "shared-thread", accountID: node.id.rawValue,
                  mailboxIDs: "mb-node", mailboxNames: "INBOX", senderEmail: "alice@node.example",
                  senderDisplayName: "Alice Node", subject: "Shared project", sortDate: 300),
            .init(id: "m-direct-1", threadID: "shared-thread", accountID: direct.id.rawValue,
                  mailboxIDs: "mb-direct", mailboxNames: "INBOX", senderEmail: "bob@direct.example",
                  senderDisplayName: "Bob Direct", subject: "Shared project", sortDate: 200),
            .init(id: "m-direct-2", threadID: "shared-thread", accountID: direct.id.rawValue,
                  mailboxIDs: "mb-direct", mailboxNames: "INBOX", senderEmail: "bob@direct.example",
                  senderDisplayName: "Bob Direct", subject: "Shared project", sortDate: 100),
        ])
        let selected = SQLiteMailSearchService(
            store: fixture.store, selectedAccountID: direct.id,
            now: { Date(timeIntervalSince1970: 1_768_608_000) },
            cursorAuthenticationKey: Data(repeating: 0x11, count: 32)
        )

        let first = try await selected.search(.init(query: "shared", mode: .messages, limit: 1))
        XCTAssertEqual(first.scope.accountIDs, [direct.id])
        XCTAssertEqual(first.messageIDs, ["m-direct-1"])
        let publicSelected = SQLiteMailSearchService(store: fixture.store, selectedAccountID: direct.id)
        let publicResponse = try await publicSelected.search(.init(query: "shared", mode: .messages))
        XCTAssertEqual(publicResponse.messageIDs, ["m-direct-1", "m-direct-2"])
        let second = try await selected.search(.init(query: "shared", mode: .messages,
                                                      limit: 1, cursor: first.nextCursor))
        XCTAssertEqual(second.messageIDs, ["m-direct-2"])
        XCTAssertNil(second.nextCursor)
        let conversations = try await selected.search(.init(query: "shared", mode: .conversations))
        XCTAssertEqual(conversations.hits.count, 1)
        XCTAssertTrue(conversations.hits.allSatisfy { hit in
            if case .conversation(let value) = hit { return value.accountID == direct.id }
            return false
        })

        let allAccounts = SQLiteMailSearchService(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 1_768_608_000) },
            cursorAuthenticationKey: Data(repeating: 0x11, count: 32)
        )
        let allFirst = try await allAccounts.search(.init(query: "shared", mode: .messages, limit: 1))
        await assertSearchError(.staleCursor) {
            _ = try await selected.search(.init(query: "shared", mode: .messages,
                                                limit: 1, cursor: allFirst.nextCursor))
        }
        await assertSearchError(.invalidQuery(reason: "Account search scope does not match the selected account.", range: nil)) {
            _ = try await selected.search(.init(query: "shared", scope: .init(accountIDs: [node.id]), mode: .messages))
        }
        await assertSearchError(.invalidQuery(reason: "Account search scope does not match the selected account.", range: nil)) {
            _ = try await selected.search(.init(query: "shared", scope: .init(accountIDs: [node.id, direct.id]), mode: .messages))
        }
        let emptyQuery = try await selected.search(.init(query: "", mode: .messages))
        XCTAssertEqual(emptyQuery.messageIDs, ["m-direct-1", "m-direct-2"])
        let wrongMailbox = try await selected.search(.init(
            query: "shared", scope: .init(mailboxIDs: [MailboxID("mb-node")]), mode: .messages
        ))
        XCTAssertTrue(wrongMailbox.hits.isEmpty)

        let suggestions = try await selected.suggestions(.init(
            query: "", recentQueries: ["A-only private Node search"]
        ))
        let suggestionIDs = suggestions.flatMap(\.items).map(\.id)
        XCTAssertTrue(suggestionIDs.contains("person:bob@direct.example"))
        XCTAssertFalse(suggestionIDs.contains("person:alice@node.example"))
        XCTAssertFalse(suggestions.flatMap(\.items).contains {
            $0.title == "A-only private Node search" || $0.insertion == "A-only private Node search"
        })
        let mailboxSuggestions = try await selected.suggestions(.init(query: "mailbox:", recentQueries: []))
        let mailboxIDs = mailboxSuggestions.flatMap(\.items).map(\.id)
        XCTAssertTrue(mailboxIDs.contains("mailbox:mb-direct"))
        XCTAssertFalse(mailboxIDs.contains("mailbox:mb-node"))
        await assertSearchError(.invalidQuery(reason: "Account search scope does not match the selected account.", range: nil)) {
            _ = try await selected.suggestions(.init(query: "", scope: .init(accountIDs: [node.id]), recentQueries: []))
        }

        try await fixture.store.databasePool.write { database in
            try database.execute(sql: "UPDATE mail_search_state SET state = 'unavailable' WHERE account_id = ?",
                                 arguments: [node.id.rawValue])
        }
        let selectedState = await selected.indexState()
        let allAccountsState = await fixture.service.indexState()
        let afterNodeFailure = try await selected.search(.init(query: "shared", mode: .messages))
        XCTAssertEqual(selectedState, .ready)
        XCTAssertEqual(allAccountsState, .unavailable)
        XCTAssertEqual(afterNodeFailure.messageIDs, ["m-direct-1", "m-direct-2"])
    }

    func testWhitespaceQueryWithStructuralScopeMatchesAllScopedNonTrashMail() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-a1", accountID: "a1", mailboxIDs: "mb-one", subject: "First"),
            .init(id: "m-a2", accountID: "a2", mailboxIDs: "mb-two", subject: "Second"),
            .init(id: "m-trash", accountID: "a1", mailboxIDs: "mb-one", subject: "Trash", isTrash: true),
        ])

        let response = try await fixture.search(
            " \n ",
            scope: .init(accountIDs: [AccountID("a1")])
        )

        XCTAssertEqual(response.parsedQuery.expression, .matchAll)
        XCTAssertEqual(response.messageIDs, ["m-a1"])
    }

    func testRankingUsesExactTierFieldWeightsRecencyAndStableID() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-exact", subject: "Project", sortDate: 100),
            .init(id: "m-subject", subject: "Project planning", sortDate: 200),
            .init(id: "m-body", subject: "Unrelated", body: "Project planning project", sortDate: 300),
            .init(id: "m-newer", subject: "Project note", sortDate: 500),
            .init(id: "m-older-a", subject: "Project note", sortDate: 400),
            .init(id: "m-older-b", subject: "Project note", sortDate: 400),
        ])

        let response = try await fixture.search("project", limit: 20)
        XCTAssertEqual(response.messageIDs.first, "m-exact")
        XCTAssertLessThan(response.messageIDs.firstIndex(of: "m-subject")!, response.messageIDs.firstIndex(of: "m-body")!)
        XCTAssertLessThan(response.messageIDs.firstIndex(of: "m-newer")!, response.messageIDs.firstIndex(of: "m-older-a")!)
        XCTAssertLessThan(response.messageIDs.firstIndex(of: "m-older-a")!, response.messageIDs.firstIndex(of: "m-older-b")!)
    }

    func testMessageCursorReturnsStableNonOverlappingPagesAndLimitPlusOneSentinel() async throws {
        let fixture = try SearchFixture()
        try fixture.insert((0 ..< 5).map {
            .init(id: "m-\($0)", subject: "Project \($0)", sortDate: Double(100 - $0))
        })

        let first = try await fixture.search("project", limit: 2)
        let second = try await fixture.search("project", limit: 2, cursor: first.nextCursor)
        let third = try await fixture.search("project", limit: 2, cursor: second.nextCursor)

        XCTAssertEqual(first.hits.count, 2)
        XCTAssertEqual(second.hits.count, 2)
        XCTAssertEqual(third.hits.count, 1)
        XCTAssertNotNil(first.nextCursor)
        XCTAssertNotNil(second.nextCursor)
        XCTAssertNil(third.nextCursor)
        XCTAssertTrue(Set(first.messageIDs).isDisjoint(with: second.messageIDs))
        XCTAssertEqual(Set(first.messageIDs + second.messageIDs + third.messageIDs).count, 5)
    }

    func testMaximumValidScopePagesWithFingerprintOnlyCursor() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-newer", subject: "Project", sortDate: 2),
            .init(id: "m-older", subject: "Project", sortDate: 1),
        ])
        let scope = MailSearchSelectionScope(
            accountIDs: [AccountID("a1")] +
                (1 ..< MailSearchScopeContract.maximumAccountCount).map {
                    AccountID("account-\($0)")
                },
            mailboxIDs: [MailboxID("mb-inbox")] +
                (1 ..< MailSearchScopeContract.maximumMailboxCount).map {
                    MailboxID("mailbox-\($0)")
                }
        )

        let first = try await fixture.search("project", scope: scope, limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        let payload = try cursor.canonicalJSONObject()
        let second = try await fixture.search(
            "project",
            scope: scope,
            limit: 1,
            cursor: cursor
        )

        XCTAssertEqual(first.messageIDs, ["m-newer"])
        XCTAssertEqual(second.messageIDs, ["m-older"])
        XCTAssertNil(payload["accounts"])
        XCTAssertNil(payload["mailboxes"])
        XCTAssertEqual((payload["scopeFingerprint"] as? String)?.count, 64)
        XCTAssertLessThan(cursor.rawValue.utf8.count, 2_048)
    }

    func testServiceRejectsOversizedScopeBeforeCompilation() async throws {
        let fixture = try SearchFixture()
        let scope = MailSearchSelectionScope(
            accountIDs: (0 ... MailSearchScopeContract.maximumAccountCount).map {
                AccountID("account-\($0)")
            }
        )

        await assertSearchError(
            .requestTooLarge(maximum: MailSearchScopeContract.maximumAccountCount)
        ) {
            _ = try await fixture.search("project", scope: scope)
        }
    }

    func testExpiredAuthenticatedCursorIsInvalid() async throws {
        let initialNow = Date(timeIntervalSince1970: 1_768_608_000)
        let clock = SearchTestClock(initialNow)
        let fixture = try SearchFixture(now: clock.now)
        try fixture.insert([
            .init(id: "m-newer", subject: "Project", sortDate: 2),
            .init(id: "m-older", subject: "Project", sortDate: 1),
        ])
        let first = try await fixture.search("project", limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        clock.advance(by: 25 * 60 * 60)

        await assertSearchError(.invalidCursor) {
            _ = try await fixture.search("project", limit: 1, cursor: cursor)
        }
    }

    func testCursorUsesStableIDAtACompleteRankingTie() async throws {
        let fixture = try SearchFixture()
        try fixture.insert(["m-a", "m-b", "m-c"].map {
            .init(id: $0, subject: "Project note", sortDate: 100)
        })

        let first = try await fixture.search("project", limit: 1)
        let second = try await fixture.search("project", limit: 1, cursor: first.nextCursor)
        let third = try await fixture.search("project", limit: 1, cursor: second.nextCursor)

        XCTAssertEqual(first.messageIDs, ["m-a"])
        XCTAssertEqual(second.messageIDs, ["m-b"])
        XCTAssertEqual(third.messageIDs, ["m-c"])
        XCTAssertNil(third.nextCursor)
    }

    func testMessageCursorKeepsRawTask4BoundaryWhilePublicIDIsCanonical() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-a", accountID: "account:a", subject: "Project", sortDate: 100),
            .init(id: "m-b", accountID: "account:a", subject: "Project", sortDate: 100),
        ])

        let page = try await fixture.search("project", limit: 1)
        let hit = try XCTUnwrap(page.messageHits.first)
        let payload = try XCTUnwrap(page.nextCursor).canonicalJSONObject()
        let canonicalID = MailSearchStableIdentity.message(
            accountID: hit.accountID,
            messageID: hit.messageID
        )

        XCTAssertEqual(hit.stableID, canonicalID)
        XCTAssertEqual(page.hits.first?.id, canonicalID)
        XCTAssertNotEqual(canonicalID, hit.messageID.rawValue)
        XCTAssertEqual(payload["stableID"] as? String, hit.messageID.rawValue)
        XCTAssertEqual(payload["conversationID"] as? String, hit.messageID.rawValue)
    }

    func testMailboxCursorRevisionIgnoresUnrelatedAccountChanges() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-a1-1", accountID: "a1", mailboxIDs: "mb-one", subject: "Project", sortDate: 2),
            .init(id: "m-a1-2", accountID: "a1", mailboxIDs: "mb-one", subject: "Project", sortDate: 1),
            .init(id: "m-a2-1", accountID: "a2", mailboxIDs: "mb-two", subject: "Project"),
        ])
        let scope = MailSearchSelectionScope(mailboxIDs: [MailboxID("mb-one")])
        let first = try await fixture.search("project", scope: scope, limit: 1)

        try fixture.insert([
            .init(id: "m-a2-2", accountID: "a2", mailboxIDs: "mb-two", subject: "Project")
        ])
        let second = try await fixture.search("project", scope: scope, limit: 1, cursor: first.nextCursor)

        XCTAssertEqual(first.messageIDs, ["m-a1-1"])
        XCTAssertEqual(second.messageIDs, ["m-a1-2"])
    }

    func testRelativeDateCursorReusesTheAuthenticatedResolutionAnchorAcrossPages() async throws {
        let initialNow = Date(timeIntervalSince1970: 1_768_608_000)
        let clock = SearchTestClock(initialNow)
        let fixture = try SearchFixture(now: clock.now)
        let originalBoundary = initialNow.addingTimeInterval(-7 * 24 * 60 * 60)
        try fixture.insert([
            .init(id: "m-newer", sortDate: initialNow.addingTimeInterval(-6 * 24 * 60 * 60).timeIntervalSince1970),
            .init(id: "m-boundary", sortDate: originalBoundary.timeIntervalSince1970),
            .init(id: "m-outside", sortDate: originalBoundary.addingTimeInterval(-1).timeIntervalSince1970),
        ])

        let first = try await fixture.search("since:7d", limit: 1)
        clock.advance(by: 24 * 60 * 60)
        let second = try await fixture.search("since:7d", limit: 1, cursor: first.nextCursor)

        XCTAssertEqual(first.messageIDs, ["m-newer"])
        XCTAssertEqual(second.messageIDs, ["m-boundary"])
        XCTAssertNil(second.nextCursor)
    }

    func testCursorFingerprintUsesNormalizedQueryAndPageSize() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-1", filenames: "report-one.pdf", sortDate: 2),
            .init(id: "m-2", filenames: "report-two.pdf", sortDate: 1),
        ])

        let first = try await fixture.search("attachment:report", limit: 1)
        let equivalent = try await fixture.search("  filename : report  ", limit: 1, cursor: first.nextCursor)

        XCTAssertEqual(first.messageIDs, ["m-1"])
        XCTAssertEqual(equivalent.messageIDs, ["m-2"])

        let restarted = try await fixture.search("attachment:report", limit: 1)
        await assertSearchError(.staleCursor) {
            _ = try await fixture.search("filename:report", limit: 2, cursor: restarted.nextCursor)
        }
    }

    func testServiceHonorsTheHundredRowPageBound() async throws {
        let fixture = try SearchFixture()
        try fixture.insert((0 ... 100).map {
            .init(id: "m-\($0)", subject: "Project", sortDate: Double($0))
        })

        let response = try await fixture.search("project", limit: 500)

        XCTAssertEqual(response.hits.count, 100)
        XCTAssertNotNil(response.nextCursor)
    }

    func testCursorRejectsQueryModeScopeRevisionAndTampering() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(id: "m-1", subject: "Project one", sortDate: 2),
            .init(id: "m-2", subject: "Project two", sortDate: 1),
        ])
        let first = try await fixture.search("project", limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)

        await assertSearchError(.staleCursor) {
            _ = try await fixture.search("other", limit: 1, cursor: cursor)
        }
        await assertSearchError(.staleCursor) {
            _ = try await fixture.service.search(.init(query: "project", mode: .conversations, limit: 1, cursor: cursor))
        }
        await assertSearchError(.staleCursor) {
            _ = try await fixture.search(
                "project",
                scope: .init(accountIDs: [AccountID("different")]),
                limit: 1,
                cursor: cursor
            )
        }

        try fixture.insert([.init(id: "m-3", subject: "Project three", sortDate: 3)])
        await assertSearchError(.staleCursor) {
            _ = try await fixture.search("project", limit: 1, cursor: cursor)
        }

        let last = cursor.rawValue.last == "A" ? "B" : "A"
        let tampered = MailSearchCursor(rawValue: String(cursor.rawValue.dropLast()) + last)
        await assertSearchError(.invalidCursor) {
            _ = try await fixture.search("project", limit: 1, cursor: tampered)
        }
        await assertSearchError(.invalidCursor) {
            _ = try await fixture.search(
                "project",
                limit: 1,
                cursor: MailSearchCursor(rawValue: String(repeating: "A", count: 4_097))
            )
        }
    }

    func testCursorRejectsCanonicalPayloadFieldMutationAndDifferentServiceKey() async throws {
        let key = Data(repeating: 0x11, count: 32)
        let fixture = try SearchFixture(cursorAuthenticationKey: key)
        try fixture.insert([
            .init(id: "m-1", subject: "Project one", sortDate: 2),
            .init(id: "m-2", subject: "Project two", sortDate: 1),
        ])
        let first = try await fixture.search("project", limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        let mutations: [String: Any] = [
            "version": 3,
            "mode": "conversations",
            "scopeFingerprint": String(repeating: "0", count: 64),
            "limit": 2,
            "exactTier": 1,
            "lexicalBits": "0000000000000000",
            "sortDate": 123.0,
            "stableID": "forged-message-id",
            "activityDate": -123.0,
            "conversationID": "forged-conversation-id",
            "resolutionAnchorBits": "0000000000000000",
            "expiresAtBits": "0000000000000000",
            "fingerprint": String(repeating: "0", count: 64),
            "revision": String(repeating: "0", count: 64),
            "authTag": String(repeating: "0", count: 64),
        ]

        for (field, value) in mutations {
            let tampered = try cursor.mutatingCanonicalJSON(field: field, value: value)
            await assertSearchError(.invalidCursor) {
                _ = try await fixture.search("project", limit: 1, cursor: tampered)
            }
        }

        let restartedService = SQLiteMailSearchService(
            store: fixture.store,
            now: { Date(timeIntervalSince1970: 1_768_608_000) },
            cursorAuthenticationKey: Data(repeating: 0x22, count: 32)
        )
        await assertSearchError(.invalidCursor) {
            _ = try await restartedService.search(.init(
                query: "project",
                mode: .messages,
                limit: 1,
                cursor: cursor
            ))
        }
    }

    func testCursorDoesNotContainPrivateQueryOrResultText() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(
                id: "m-1",
                accountID: "private-account-scope-id",
                mailboxIDs: "private-mailbox-scope-id",
                sender: "Private Person private@example.com",
                subject: "Private project"
            ),
            .init(
                id: "m-2",
                accountID: "private-account-scope-id",
                mailboxIDs: "private-mailbox-scope-id",
                subject: "Private project two",
                sortDate: -1
            ),
        ])

        let response = try await fixture.search(
            "private",
            scope: .init(
                accountIDs: [AccountID("private-account-scope-id")],
                mailboxIDs: [MailboxID("private-mailbox-scope-id")]
            ),
            limit: 1
        )
        let cursor = try XCTUnwrap(response.nextCursor)
        let decoded = try XCTUnwrap(Data(base64URLEncoded: cursor.rawValue))
        let payload = String(decoding: decoded, as: UTF8.self)

        XCTAssertTrue(payload.contains(#""version":2"#))
        XCTAssertTrue(payload.contains(#""scopeFingerprint":"#))
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("private"))
        XCTAssertFalse(payload.contains("example.com"))
        XCTAssertFalse(payload.contains("Private project"))
        XCTAssertFalse(payload.contains("private-account-scope-id"))
        XCTAssertFalse(payload.contains("private-mailbox-scope-id"))
    }

    func testSnippetsAreBoundedMarkerFreeAndUseValidUTF16Ranges() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([
            .init(
                id: "m-unicode",
                subject: "Status",
                body: String(repeating: "longword ", count: 100) + "😀 café project finish"
            ),
            .init(
                id: "m-markers",
                subject: "Project \u{001E}unsafe\u{001F}",
                body: "Project"
            ),
        ])

        let response = try await fixture.search("project", limit: 10)
        XCTAssertEqual(response.hits.count, 2)
        for hit in response.messageHits {
            XCTAssertLessThanOrEqual((hit.snippet.text as NSString).length, 320)
            XCTAssertFalse(hit.snippet.text.contains("\u{001E}"))
            XCTAssertFalse(hit.snippet.text.contains("\u{001F}"))
            XCTAssertNoThrow(try MailSearchSnippet(text: hit.snippet.text, highlights: hit.snippet.highlights))
        }
        let markerHit = try XCTUnwrap(response.messageHits.first { $0.messageID.rawValue == "m-markers" })
        XCTAssertTrue(markerHit.snippet.highlights.isEmpty)
        XCTAssertTrue(markerHit.snippet.text.contains("unsafe"))
        let unicodeHit = try XCTUnwrap(response.messageHits.first { $0.messageID.rawValue == "m-unicode" })
        XCTAssertFalse(unicodeHit.snippet.highlights.isEmpty)
    }

    func testLiteralActiveMarkersAndMalformedSentinelsCannotForgeHighlights() async throws {
        let nonce = "review-nonce"
        let fixture = try SearchFixture(snippetMarkerNonce: { nonce })
        let legacyStart = "\u{001E}plainpost-search-start["
        let legacyEnd = "]plainpost-search-end\u{001F}"
        let currentStart = "\u{001E}plainpost-search-\(nonce)-start["
        let currentEnd = "]plainpost-search-\(nonce)-end\u{001F}"
        try fixture.insert([
            .init(
                id: "m-complete",
                subject: "Project \(legacyStart)forged complete\(legacyEnd)"
            ),
            .init(
                id: "m-bare",
                subject: "Project \u{001E}bare separators\u{001F}"
            ),
            .init(
                id: "m-active-balanced",
                subject: "Project \(currentStart)forged active\(currentEnd)"
            ),
            .init(
                id: "m-start-only",
                subject: "Project \(currentStart)start only"
            ),
            .init(
                id: "m-end-only",
                subject: "Project end only\(currentEnd)"
            ),
            .init(
                id: "m-nested",
                subject: "Project \(currentStart)outer \(currentStart)nested\(currentEnd)\(currentEnd)"
            ),
            .init(
                id: "m-duplicate",
                subject: "Project \(currentStart)duplicate \(currentStart)"
            ),
            .init(
                id: "m-duplicate-pairs",
                subject: "Project \(currentStart)one\(currentEnd) \(currentStart)two\(currentEnd)"
            ),
            .init(
                id: "m-normal",
                subject: "Project normal"
            ),
        ])

        let response = try await fixture.search("project", limit: 10)

        let adversarialIDs: Set<String> = [
            "m-complete", "m-bare", "m-active-balanced", "m-start-only", "m-end-only",
            "m-nested", "m-duplicate", "m-duplicate-pairs",
        ]
        XCTAssertEqual(Set(response.messageIDs), adversarialIDs.union(["m-normal"]))
        for hit in response.messageHits where adversarialIDs.contains(hit.messageID.rawValue) {
            XCTAssertTrue(hit.snippet.highlights.isEmpty, hit.messageID.rawValue)
            XCTAssertFalse(hit.snippet.text.contains("\u{001E}"), hit.messageID.rawValue)
            XCTAssertFalse(hit.snippet.text.contains("\u{001F}"), hit.messageID.rawValue)
            XCTAssertNoThrow(
                try MailSearchSnippet(text: hit.snippet.text, highlights: hit.snippet.highlights),
                hit.messageID.rawValue
            )
        }
        let complete = try XCTUnwrap(
            response.messageHits.first { $0.messageID.rawValue == "m-complete" }
        )
        XCTAssertTrue(complete.snippet.text.contains("forged complete"))
        let activeBalanced = try XCTUnwrap(
            response.messageHits.first { $0.messageID.rawValue == "m-active-balanced" }
        )
        XCTAssertTrue(activeBalanced.snippet.text.contains("forged active"))
        let normal = try XCTUnwrap(
            response.messageHits.first { $0.messageID.rawValue == "m-normal" }
        )
        XCTAssertFalse(normal.snippet.highlights.isEmpty)
    }

    func testRecencyScoreIsDeterministicAndBounded() {
        XCTAssertEqual(SQLiteMailSearchQueryCompiler.recencyScore(for: -.infinity), 0)
        XCTAssertEqual(SQLiteMailSearchQueryCompiler.recencyScore(for: 0), 0)
        XCTAssertEqual(SQLiteMailSearchQueryCompiler.recencyScore(for: 4_102_444_800), 1)
        XCTAssertEqual(SQLiteMailSearchQueryCompiler.recencyScore(for: .infinity), 1)
        XCTAssertTrue((0 ... 1).contains(SQLiteMailSearchQueryCompiler.recencyScore(for: 1_000_000_000)))
    }

    func testIndexStateErrorsAreTypedAndDoNotExposeStateRows() async throws {
        let fixture = try SearchFixture()
        try fixture.insert([.init(id: "m-1", subject: "Project")])

        try fixture.setIndexState("rebuilding")
        await assertSearchError(.rebuilding) {
            _ = try await fixture.search("project")
        }

        try fixture.setIndexState("unavailable")
        await assertSearchError(.unavailable) {
            _ = try await fixture.search("project")
        }
    }

    func testCancellationInterruptsRunningProjectionScan() async throws {
        let fixture = try SearchFixture()
        try fixture.insertLargeStructuredOnlyCorpus(count: 300_000)
        let probe = SQLiteCancellationProbe()
        try fixture.installCancellationProbe(probe)
        let task = Task {
            try await fixture.search("is:read", limit: 100)
        }

        await probe.waitUntilSQLiteStarted()
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? MailSearchError, .cancelled)
        }
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
        XCTAssertEqual(try fixture.searchDocumentCount(), 300_000)
    }

    private func assertSearchError(
        _ expected: MailSearchError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MailSearchError, expected)
        }
    }
}

private extension MailSearchResponse {
    var messageHits: [MailMessageSearchHit] {
        hits.compactMap {
            guard case .message(let hit) = $0 else { return nil }
            return hit
        }
    }

    var messageIDs: [String] {
        messageHits.map(\.messageID.rawValue)
    }
}

private struct SearchDocument {
    let id: String
    var threadID: String? = nil
    var accountID = "a1"
    var mailboxIDs = "mb-inbox"
    var mailboxNames = "Inbox"
    var sender = "Sender sender@example.com"
    var senderEmail = "sender@example.com"
    var senderDisplayName: String? = "Sender"
    var to = "recipient@example.com"
    var cc = ""
    var bcc = ""
    var subject = ""
    var preview = ""
    var body = ""
    var filenames = ""
    var identifiers = ""
    var labels = ""
    var sentAt: Double? = nil
    var sortDate: Double = 0
    var isSeen = true
    var isFlagged = false
    var isDelegated = false
    var isDeleted = false
    var isTrash = false
    var isInbox = false
    var isSent = false
    var hasAttachments = false
    var hasDocuments = false
}

private final class SearchFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMailStore
    let service: SQLiteMailSearchService

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        cursorAuthenticationKey: Data = Data(repeating: 0x11, count: 32),
        snippetMarkerNonce: @escaping @Sendable () -> String = { "fixture-nonce" }
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        service = SQLiteMailSearchService(
            store: store,
            now: now,
            cursorAuthenticationKey: cursorAuthenticationKey,
            snippetMarkerNonce: snippetMarkerNonce
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func insert(_ documents: [SearchDocument]) throws {
        try store.databasePool.write { database in
            for document in documents {
                try database.execute(
                    sql: """
                        INSERT INTO mail_search_documents (
                            message_id, thread_id, account_id, sent_at, sort_date,
                            sender, sender_email, sender_display_name, to_value, cc_value, bcc_value,
                            subject, preview, body_text, filenames, identifiers, labels,
                            mailbox_ids, mailbox_names, is_seen, is_flagged, is_delegated, is_deleted,
                            is_trash, is_inbox, is_sent, has_attachments, has_documents
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        document.id,
                        document.threadID ?? "thread-\(document.id)",
                        document.accountID,
                        document.sentAt ?? document.sortDate,
                        document.sortDate,
                        document.sender,
                        document.senderEmail,
                        document.senderDisplayName,
                        document.to,
                        document.cc,
                        document.bcc,
                        document.subject,
                        document.preview,
                        document.body,
                        document.filenames,
                        document.identifiers,
                        document.labels,
                        document.mailboxIDs,
                        document.mailboxNames,
                        document.isSeen,
                        document.isFlagged,
                        document.isDelegated,
                        document.isDeleted,
                        document.isTrash,
                        document.isInbox,
                        document.isSent,
                        document.hasAttachments,
                        document.hasDocuments,
                    ]
                )
            }
        }
    }

    func search(
        _ query: String,
        scope: MailSearchSelectionScope = .init(),
        limit: Int = 50,
        cursor: MailSearchCursor? = nil
    ) async throws -> MailSearchResponse {
        try await service.search(.init(
            query: query,
            scope: scope,
            mode: .messages,
            limit: limit,
            cursor: cursor
        ))
    }

    func setIndexState(_ state: String) throws {
        try store.databasePool.write { database in
            try database.execute(sql: "UPDATE mail_search_state SET state = ?", arguments: [state])
        }
    }

    func insertLargeStructuredOnlyCorpus(count: Int) throws {
        try store.databasePool.write { database in
            try database.execute(sql: """
                DROP TRIGGER mail_search_documents_after_insert;
                DROP TRIGGER mail_search_documents_after_delete;
                DROP TRIGGER mail_search_documents_after_update;
                INSERT INTO mail_search_documents (
                    message_id, thread_id, account_id, sent_at, sort_date,
                    sender, sender_email, sender_display_name, to_value, cc_value, bcc_value,
                    subject, preview, body_text, filenames, identifiers, labels,
                    mailbox_ids, mailbox_names, is_seen, is_flagged, is_delegated, is_deleted,
                    is_trash, is_inbox, is_sent, has_attachments, has_documents
                )
                WITH RECURSIVE corpus(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM corpus WHERE value < \(count)
                )
                SELECT
                    printf('large-%08d', value), printf('thread-%08d', value), 'a1', value, value,
                    'Sender', 'sender@example.com', 'Sender', '', '', '',
                    'Structured row', '', '', '', '', '', 'mb-inbox', 'Inbox',
                    1, 0, 0, 0, 0, 1, 0, 0, 0
                FROM corpus;
                INSERT INTO mail_search_state(account_id, revision, state, updated_at)
                VALUES ('a1', 1, 'ready', 0)
                ON CONFLICT(account_id) DO UPDATE SET revision = revision + 1, state = 'ready';
                """)
        }
    }

    func installCancellationProbe(_ probe: SQLiteCancellationProbe) throws {
        try store.databasePool.read { database in
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event,
                      statement.sql.contains("scored AS (")
                else { return }
                probe.sqliteStatementDidStart()
            }
        }
    }

    func searchDocumentCount() throws -> Int {
        try store.databasePool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM mail_search_documents") ?? -1
        }
    }

    static func explain(_ compiled: SQLiteMailSearchCompiledQuery) throws {
        let fixture = try SearchFixture()
        try fixture.store.databasePool.read { database in
            _ = try Row.fetchAll(
                database,
                sql: "EXPLAIN QUERY PLAN \(compiled.sql)",
                arguments: compiled.arguments
            )
        }
    }
}

private final class SQLiteCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilSQLiteStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func sqliteStatementDidStart() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

private extension MailSearchCursor {
    func canonicalJSONObject() throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64URLEncoded: rawValue))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(canonical, data, "Cursor fixture must be canonical sorted-key JSON")
        return object
    }

    func mutatingCanonicalJSON(field: String, value: Any) throws -> MailSearchCursor {
        var object = try canonicalJSONObject()
        XCTAssertNotNil(object[field], "Missing cursor field \(field)")
        object[field] = value
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MailSearchCursor(rawValue: mutated.testBase64URLEncodedString())
    }
}

private extension Data {
    func testBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class SearchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
