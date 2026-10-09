import Foundation
import XCTest
@testable import PlainpostCore

final class MailSearchContractTests: XCTestCase {
    func testNonemptyQueryAllowsCanonicalDefaultEmptyScope() throws {
        let request = MailSearchRequest(query: "project")

        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(request.scope, MailSearchSelectionScope())
        XCTAssertEqual(try MailSearchQueryParser().parse(request).canonicalQuery, "project")
    }

    func testStructuralScopeMakesWhitespaceQueryAValidatedMatchAllRequest() throws {
        let request = MailSearchRequest(
            query: "  \n",
            scope: .init(mailboxIDs: [MailboxID("inbox")])
        )

        XCTAssertNoThrow(try request.validate())
        let parsed = try MailSearchQueryParser().parse(request)
        XCTAssertEqual(parsed.expression, .matchAll)
        XCTAssertEqual(parsed.canonicalQuery, "*")
        XCTAssertTrue(parsed.tokens.isEmpty)
    }

    func testEmptyQueryAndEmptyScopeRemainInvalid() {
        let request = MailSearchRequest(query: " \t ")

        XCTAssertThrowsError(try request.validate()) {
            XCTAssertEqual(
                $0 as? MailSearchError,
                .invalidQuery(reason: "Query is empty unless an account or mailbox scope is selected.", range: nil)
            )
        }
    }

    func testCanonicalScopeContractAcceptsItsExactBounds() throws {
        let scope = MailSearchSelectionScope(
            accountIDs: (0 ..< MailSearchScopeContract.maximumAccountCount).map {
                AccountID("account-\($0)")
            },
            mailboxIDs: (0 ..< MailSearchScopeContract.maximumMailboxCount).map {
                MailboxID("mailbox-\($0)")
            }
        )

        XCTAssertNoThrow(try MailSearchScopeContract.validate(scope))
        XCTAssertEqual(MailSearchScopeContract.maximumIdentifierUTF8Length, 256)
    }

    func testCanonicalScopeContractRejectsExcessCountsAndLongUTF8Identifiers() {
        let tooManyAccounts = MailSearchSelectionScope(
            accountIDs: (0 ... MailSearchScopeContract.maximumAccountCount).map {
                AccountID("account-\($0)")
            }
        )
        let tooManyMailboxes = MailSearchSelectionScope(
            mailboxIDs: (0 ... MailSearchScopeContract.maximumMailboxCount).map {
                MailboxID("mailbox-\($0)")
            }
        )
        let longIdentifier = MailSearchSelectionScope(
            accountIDs: [AccountID(String(repeating: "x", count: 257))]
        )

        XCTAssertThrowsError(try MailSearchScopeContract.validate(tooManyAccounts)) {
            XCTAssertEqual(
                $0 as? MailSearchError,
                .requestTooLarge(maximum: MailSearchScopeContract.maximumAccountCount)
            )
        }
        XCTAssertThrowsError(try MailSearchScopeContract.validate(tooManyMailboxes)) {
            XCTAssertEqual(
                $0 as? MailSearchError,
                .requestTooLarge(maximum: MailSearchScopeContract.maximumMailboxCount)
            )
        }
        XCTAssertThrowsError(try MailSearchScopeContract.validate(longIdentifier)) {
            XCTAssertEqual(
                $0 as? MailSearchError,
                .requestTooLarge(maximum: MailSearchScopeContract.maximumIdentifierUTF8Length)
            )
        }
    }

    func testRequestDefaultsToConversationsAndClampsLimit() {
        let request = MailSearchRequest(query: "project", limit: 500)

        XCTAssertEqual(request.mode, .conversations)
        XCTAssertEqual(request.limit, 100)
        XCTAssertEqual(MailSearchRequest(query: "project", limit: 0).limit, 1)
        XCTAssertEqual(MailSearchRequest(query: "project").limit, 50)
    }

    func testSelectionScopeDeduplicatesAndSortsIdentifiers() {
        let scope = MailSearchSelectionScope(
            accountIDs: [AccountID("z"), AccountID("a"), AccountID("z")],
            mailboxIDs: [MailboxID("inbox"), MailboxID("archive"), MailboxID("inbox")]
        )

        XCTAssertEqual(scope.accountIDs, [AccountID("a"), AccountID("z")])
        XCTAssertEqual(scope.mailboxIDs, [MailboxID("archive"), MailboxID("inbox")])
    }

    func testRequestCodableOutputIsStableAndRoundTrips() throws {
        let request = MailSearchRequest(
            query: "project",
            scope: .init(
                accountIDs: [AccountID("account-a")],
                mailboxIDs: [MailboxID("mailbox-a")]
            ),
            mode: .messages,
            cursor: .init(rawValue: "v1-token")
        )

        let data = try MailSearchJSON.encoder().encode(request)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"cursor":"v1-token","limit":50,"mode":"messages","query":"project","scope":{"accountIDs":["account-a"],"mailboxIDs":["mailbox-a"]}}"#
        )
        XCTAssertEqual(try MailSearchJSON.decoder().decode(MailSearchRequest.self, from: data), request)
    }

    func testRequestDecodingReappliesLimitAndScopeInvariants() throws {
        let data = Data(
            #"{"cursor":null,"limit":500,"mode":"messages","query":"project","scope":{"accountIDs":["z","a","z"],"mailboxIDs":["inbox","archive","inbox"]}}"#.utf8
        )

        let request = try MailSearchJSON.decoder().decode(MailSearchRequest.self, from: data)

        XCTAssertEqual(request.limit, 100)
        XCTAssertEqual(request.scope.accountIDs, [AccountID("a"), AccountID("z")])
        XCTAssertEqual(
            request.scope.mailboxIDs,
            [MailboxID("archive"), MailboxID("inbox")]
        )
    }

    func testSnippetDecodingRejectsInvalidComposedCharacterRange() {
        let data = Data(
            #"{"highlights":[{"length":2,"location":0}],"text":"👩‍💻"}"#.utf8
        )

        XCTAssertThrowsError(
            try MailSearchJSON.decoder().decode(MailSearchSnippet.self, from: data)
        ) {
            XCTAssertEqual($0 as? MailSearchModelError, .invalidHighlightRange)
        }
    }

    func testSnippetDecodingRejectsOverflowingHighlightRangeSafely() {
        let data = Data(
            #"{"highlights":[{"length":1,"location":9223372036854775807}],"text":"x"}"#.utf8
        )

        XCTAssertThrowsError(
            try MailSearchJSON.decoder().decode(MailSearchSnippet.self, from: data)
        ) {
            XCTAssertEqual($0 as? MailSearchModelError, .invalidHighlightRange)
        }
    }

    func testSuggestionRequestDecodingNormalizesAndBoundsRecentQueries() throws {
        let data = Data(
            #"{"activeRange":null,"query":"from:al","recentQueries":[" Project ","project","query 2","query 3","query 4","query 5","query 6","query 7","query 8","query 9","query 10","query 11"],"scope":{"accountIDs":[],"mailboxIDs":[]}}"#.utf8
        )

        let request = try MailSearchJSON.decoder().decode(
            MailSearchSuggestionRequest.self,
            from: data
        )

        XCTAssertEqual(request.recentQueries.count, 10)
        XCTAssertEqual(request.recentQueries.first, "Project")
        XCTAssertEqual(request.recentQueries.last, "query 10")
    }

    func testSuggestionRequestNormalizesComposedRangesAndRejectsInvalidBounds() throws {
        let emoji = MailSearchSuggestionRequest(
            query: "from:😀",
            recentQueries: [],
            activeRange: .init(location: 6, length: 0)
        )
        XCTAssertEqual(emoji.activeRange, .init(location: 5, length: 2))

        let decomposed = MailSearchSuggestionRequest(
            query: "from:e\u{301}",
            recentQueries: [],
            activeRange: .init(location: 5, length: 1)
        )
        XCTAssertEqual(decomposed.activeRange, .init(location: 5, length: 2))

        let overflow = MailSearchSuggestionRequest(
            query: "alice",
            recentQueries: [],
            activeRange: .init(location: Int.max, length: Int.max)
        )
        XCTAssertNil(overflow.activeRange)

        let encoded = try MailSearchJSON.encoder().encode(emoji)
        XCTAssertEqual(
            try MailSearchJSON.decoder().decode(MailSearchSuggestionRequest.self, from: encoded),
            emoji
        )
    }

    func testConversationHitDecodesWithoutTheBestMatchSender() throws {
        let hit = MailConversationSearchHit(
            stableID: "account-1|thread-1",
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-1"),
            bestMatchingMessageID: MessageID("message-1"),
            subject: "Parcel update",
            participants: ["Post CH Ltd", "reader@example.test"],
            latestActivity: nil,
            snippet: try MailSearchSnippet(text: "Your parcel", highlights: []),
            matchingMessageCount: 1,
            totalMessageCount: 1,
            unreadMessageCount: 0,
            hasAttachments: false,
            hasDocuments: false,
            bestMatchSender: EmailAddress("notifications@post.example.test"),
            bestMatchSenderDisplayName: "Post CH Ltd"
        )
        let encoded = try MailSearchJSON.encoder().encode(hit)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["bestMatchSender"] as? String, "notifications@post.example.test")
        XCTAssertEqual(object["bestMatchSenderDisplayName"] as? String, "Post CH Ltd")
        object.removeValue(forKey: "bestMatchSender")
        object.removeValue(forKey: "bestMatchSenderDisplayName")

        let legacy = try MailSearchJSON.decoder().decode(
            MailConversationSearchHit.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.bestMatchSender)
        XCTAssertNil(legacy.bestMatchSenderDisplayName)
        XCTAssertEqual(legacy.bestMatchingMessageID, hit.bestMatchingMessageID)
        XCTAssertEqual(legacy.participants, hit.participants)
    }

    func testEveryResultModelHasACompletePublicInitializerAndRoundTrips() throws {
        let snippet = try MailSearchSnippet(
            text: "Project café",
            highlights: [.init(location: 0, length: 7), .init(location: 8, length: 4)]
        )
        let conversation = MailConversationSearchHit(
            stableID: MailSearchStableIdentity.thread(
                accountID: AccountID("account-1"),
                threadID: ThreadID("thread-1")
            ),
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-1"),
            bestMatchingMessageID: MessageID("message-1"),
            subject: "Project",
            participants: ["Alex Rivera"],
            latestActivity: Date(timeIntervalSince1970: 1_751_324_400),
            snippet: snippet,
            matchingMessageCount: 1,
            totalMessageCount: 2,
            unreadMessageCount: 1,
            hasAttachments: true,
            hasDocuments: false,
            bestMatchSender: EmailAddress("alex@example.com"),
            bestMatchSenderDisplayName: "Alex Rivera"
        )
        let message = MailMessageSearchHit(
            stableID: MailSearchStableIdentity.message(
                accountID: AccountID("account-1"),
                messageID: MessageID("message-2")
            ),
            messageID: MessageID("message-2"),
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-1"),
            sender: EmailAddress("alex@example.com"),
            senderDisplayName: "Alex Rivera",
            recipients: [EmailAddress("max@example.com")],
            subject: "Project",
            sentAt: Date(timeIntervalSince1970: 1_751_324_400),
            snippet: snippet,
            isUnread: true,
            isFlagged: false,
            isDelegated: false,
            mailboxIDs: [MailboxID("inbox")],
            hasAttachments: true,
            hasDocuments: false
        )
        let parsedQuery = MailSearchParsedQuery(
            expression: .all([
                .field(.subject, .term("project", prefix: true)),
                .not(.state(.read)),
            ]),
            tokens: [
                .init(
                    kind: .filter,
                    text: "subject:project",
                    sourceRange: .init(location: 0, length: 15)
                ),
            ],
            canonicalQuery: "subject:project NOT is:read"
        )
        let response = MailSearchResponse(
            parsedQuery: parsedQuery,
            mode: .conversations,
            scope: .init(accountIDs: [AccountID("account-1")]),
            hits: [.conversation(conversation), .message(message)],
            nextCursor: .init(rawValue: "v1-next"),
            indexRevision: "revision-1"
        )

        let data = try MailSearchJSON.encoder().encode(response)

        XCTAssertEqual(try MailSearchJSON.decoder().decode(MailSearchResponse.self, from: data), response)
        XCTAssertEqual(
            response.hits.map(\.id),
            [
                "thread|6163636F756E742D31|7468726561642D31",
                "message|6163636F756E742D31|6D6573736167652D32",
            ]
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("body"))
    }

    func testSuggestionModelsBoundRecentQueriesAndRoundTrip() throws {
        let request = MailSearchSuggestionRequest(
            query: "from:al",
            recentQueries: (0 ..< 12).map { "query \($0)" },
            activeRange: .init(location: 5, length: 2)
        )
        let sections = [
            MailSearchSuggestionSection(
                kind: .people,
                items: [
                    .init(
                        id: "alex@example.com",
                        title: "Alex Rivera",
                        detail: "alex@example.com",
                        insertion: "from:alex@example.com",
                        replacementRange: .init(location: 0, length: 7)
                    ),
                ]
            ),
        ]

        XCTAssertEqual(request.recentQueries, (0 ..< 10).map { "query \($0)" })
        let data = try MailSearchJSON.encoder().encode(sections)
        XCTAssertEqual(
            try MailSearchJSON.decoder().decode([MailSearchSuggestionSection].self, from: data),
            sections
        )
    }

    func testFieldRegistryContainsEveryApprovedCanonicalField() {
        XCTAssertEqual(
            Set(MailSearchFieldRegistry.all.map(\.name)),
            [
                "from", "to", "cc", "bcc", "participants", "subject", "filename",
                "has", "with", "is", "in", "mailbox", "since", "after", "before", "on", "date",
            ]
        )
        XCTAssertEqual(MailSearchFieldRegistry.all.count, 17)
        XCTAssertTrue(MailSearchFieldRegistry.cliGuide.contains("date:2026-07-01..2026-07-18"))
        XCTAssertTrue(MailSearchFieldRegistry.cliGuide.contains("Precedence"))
        XCTAssertTrue(MailSearchFieldRegistry.cliGuide.contains("Conversations"))
        XCTAssertTrue(MailSearchFieldRegistry.mcpGuide.contains("next_cursor"))
        XCTAssertTrue(MailSearchFieldRegistry.mcpGuide.contains("Field selection"))
    }

    func testSnippetRejectsInvalidRanges() {
        XCTAssertThrowsError(
            try MailSearchSnippet(
                text: "café",
                highlights: [.init(location: 3, length: 99)]
            )
        ) {
            XCTAssertEqual($0 as? MailSearchModelError, .invalidHighlightRange)
        }
    }

    func testSnippetRejectsPartialComposedCharacterAndOverlappingRanges() {
        XCTAssertThrowsError(
            try MailSearchSnippet(
                text: "👩‍💻 mail",
                highlights: [.init(location: 0, length: 2)]
            )
        ) {
            XCTAssertEqual($0 as? MailSearchModelError, .invalidHighlightRange)
        }
        XCTAssertThrowsError(
            try MailSearchSnippet(
                text: "project",
                highlights: [.init(location: 0, length: 4), .init(location: 3, length: 2)]
            )
        ) {
            XCTAssertEqual($0 as? MailSearchModelError, .invalidHighlightRange)
        }
    }

    func testSearchErrorsExposeStableCodes() {
        let range = MailSearchTextRange(location: 0, length: 3)
        let errors: [(MailSearchError, String)] = [
            (.invalidQuery(reason: "bad query", range: nil), "INVALID_QUERY"),
            (.unsupportedField(name: "foo", range: range), "UNSUPPORTED_FIELD"),
            (.unsupportedValue(field: "is", range: range), "UNSUPPORTED_VALUE"),
            (.requestTooLarge(maximum: 100), "REQUEST_TOO_LARGE"),
            (.invalidCursor, "INVALID_CURSOR"),
            (.staleCursor, "STALE_CURSOR"),
            (.rebuilding, "SEARCH_REBUILDING"),
            (.unavailable, "SEARCH_UNAVAILABLE"),
            (.cancelled, "CANCELLED"),
        ]

        XCTAssertEqual(errors.map { $0.0.code }, errors.map(\.1))
    }

    func testQueryExpressionVariantsUseCanonicalTaggedJSON() throws {
        let rangeDate = Date(timeIntervalSince1970: 0.125)
        let fixtures: [(MailSearchQueryExpression, String)] = [
            (
                .term("project", prefix: true),
                #"{"prefix":true,"type":"term","value":"project"}"#
            ),
            (
                .phrase("project alpha"),
                #"{"type":"phrase","value":"project alpha"}"#
            ),
            (
                .field(.subject, .term("budget", prefix: true)),
                #"{"expression":{"prefix":true,"type":"term","value":"budget"},"field":"subject","type":"field"}"#
            ),
            (
                .content(.attachment),
                #"{"type":"content","value":"attachment"}"#
            ),
            (
                .state(.unread),
                #"{"type":"state","value":"unread"}"#
            ),
            (
                .location(.sent),
                #"{"type":"location","value":"sent"}"#
            ),
            (
                .date(.init(lowerBound: rangeDate, upperBound: nil)),
                #"{"interval":{"lowerBound":"1970-01-01T00:00:00.125Z"},"type":"date"}"#
            ),
            (
                .all([.term("one", prefix: true)]),
                #"{"expressions":[{"prefix":true,"type":"term","value":"one"}],"type":"all"}"#
            ),
            (
                .any([.phrase("exact phrase")]),
                #"{"expressions":[{"type":"phrase","value":"exact phrase"}],"type":"any"}"#
            ),
            (
                .not(.state(.read)),
                #"{"expression":{"type":"state","value":"read"},"type":"not"}"#
            ),
        ]

        for (value, goldenJSON) in fixtures {
            assertGoldenRoundTrip(value, goldenJSON: goldenJSON)
        }
    }

    func testHitVariantsUseCanonicalTaggedJSONAndAccountScopedIdentity() throws {
        let snippet = try MailSearchSnippet(text: "Project", highlights: [])
        let conversation = MailSearchHit.conversation(.init(
            stableID: "thread|6163636F756E742D61|7468726561642D31",
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-a"),
            bestMatchingMessageID: MessageID("message-1"),
            subject: "Project",
            participants: ["Alex"],
            latestActivity: nil,
            snippet: snippet,
            matchingMessageCount: 1,
            totalMessageCount: 2,
            unreadMessageCount: 1,
            hasAttachments: false,
            hasDocuments: false
        ))
        let message = MailSearchHit.message(.init(
            stableID: "message|6163636F756E742D61|6D6573736167652D31",
            messageID: MessageID("message-1"),
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-a"),
            sender: EmailAddress("alex@example.com"),
            senderDisplayName: nil,
            recipients: [EmailAddress("max@example.com")],
            subject: "Project",
            sentAt: nil,
            snippet: snippet,
            isUnread: true,
            isFlagged: false,
            isDelegated: false,
            mailboxIDs: [MailboxID("inbox")],
            hasAttachments: false,
            hasDocuments: false
        ))

        assertGoldenRoundTrip(
            conversation,
            goldenJSON: #"{"type":"conversation","value":{"accountID":"account-a","bestMatchingMessageID":"message-1","hasAttachments":false,"hasDocuments":false,"matchingMessageCount":1,"participants":["Alex"],"snippet":{"highlights":[],"text":"Project"},"stableID":"thread|6163636F756E742D61|7468726561642D31","subject":"Project","threadID":"thread-1","totalMessageCount":2,"unreadMessageCount":1}}"#
        )
        assertGoldenRoundTrip(
            message,
            goldenJSON: #"{"type":"message","value":{"accountID":"account-a","hasAttachments":false,"hasDocuments":false,"isDelegated":false,"isFlagged":false,"isUnread":true,"mailboxIDs":["inbox"],"messageID":"message-1","recipients":["max@example.com"],"sender":"alex@example.com","snippet":{"highlights":[],"text":"Project"},"stableID":"message|6163636F756E742D61|6D6573736167652D31","subject":"Project","threadID":"thread-1"}}"#
        )

        let otherAccountConversation = MailSearchHit.conversation(.init(
            stableID: MailSearchStableIdentity.thread(
                accountID: AccountID("account-b"),
                threadID: ThreadID("thread-1")
            ),
            threadID: ThreadID("thread-1"),
            accountID: AccountID("account-b"),
            bestMatchingMessageID: MessageID("message-1"),
            subject: "Project",
            participants: [],
            latestActivity: nil,
            snippet: snippet,
            matchingMessageCount: 1,
            totalMessageCount: 1,
            unreadMessageCount: 0,
            hasAttachments: false,
            hasDocuments: false
        ))
        XCTAssertEqual(conversation.id, "thread|6163636F756E742D61|7468726561642D31")
        XCTAssertEqual(message.id, "message|6163636F756E742D61|6D6573736167652D31")
        XCTAssertNotEqual(conversation.id, otherAccountConversation.id)
    }

    func testStableIdentityUsesCanonicalHexAndCannotCollideAtDelimiters() {
        let firstThread = MailSearchStableIdentity.thread(
            accountID: AccountID("a:b"),
            threadID: ThreadID("c")
        )
        let secondThread = MailSearchStableIdentity.thread(
            accountID: AccountID("a"),
            threadID: ThreadID("b:c")
        )
        let firstMessage = MailSearchStableIdentity.message(
            accountID: AccountID("a:b"),
            messageID: MessageID("c")
        )
        let secondMessage = MailSearchStableIdentity.message(
            accountID: AccountID("a"),
            messageID: MessageID("b:c")
        )

        XCTAssertEqual(firstThread, "thread|613A62|63")
        XCTAssertEqual(secondThread, "thread|61|623A63")
        XCTAssertEqual(firstMessage, "message|613A62|63")
        XCTAssertEqual(secondMessage, "message|61|623A63")
        XCTAssertNotEqual(firstThread, secondThread)
        XCTAssertNotEqual(firstMessage, secondMessage)
    }

    func testErrorVariantsUseCanonicalCodeDiscriminatedJSON() {
        let range = MailSearchTextRange(location: 1, length: 3)
        let fixtures: [(MailSearchError, String)] = [
            (
                .invalidQuery(reason: "bad query", range: range),
                #"{"code":"INVALID_QUERY","range":{"length":3,"location":1},"reason":"bad query"}"#
            ),
            (
                .unsupportedField(name: "foo", range: range),
                #"{"code":"UNSUPPORTED_FIELD","name":"foo","range":{"length":3,"location":1}}"#
            ),
            (
                .unsupportedValue(field: "is", range: range),
                #"{"code":"UNSUPPORTED_VALUE","field":"is","range":{"length":3,"location":1}}"#
            ),
            (
                .requestTooLarge(maximum: 100),
                #"{"code":"REQUEST_TOO_LARGE","maximum":100}"#
            ),
            (.invalidCursor, #"{"code":"INVALID_CURSOR"}"#),
            (.staleCursor, #"{"code":"STALE_CURSOR"}"#),
            (.rebuilding, #"{"code":"SEARCH_REBUILDING"}"#),
            (.unavailable, #"{"code":"SEARCH_UNAVAILABLE"}"#),
            (.cancelled, #"{"code":"CANCELLED"}"#),
        ]

        for (value, goldenJSON) in fixtures {
            assertGoldenRoundTrip(value, goldenJSON: goldenJSON)
        }
    }

    func testUnsupportedValueErrorNeverRetainsRejectedTextAndRejectsOldWireShape() throws {
        let hostileValue = #"secret\"recipient@example.com"#
        let error = MailSearchError.unsupportedValue(
            field: "is",
            range: .init(location: 3, length: hostileValue.utf16.count)
        )
        let data = try MailSearchJSON.encoder().encode(error)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"code":"UNSUPPORTED_VALUE","field":"is","range":{"length":29,"location":3}}"#
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(hostileValue))
        XCTAssertFalse(String(describing: error).contains(hostileValue))
        XCTAssertFalse(error.localizedDescription.contains(hostileValue))

        let oldShape = Data(
            #"{"code":"UNSUPPORTED_VALUE","field":"is","range":{"length":28,"location":3},"value":"secret"}"#.utf8
        )
        XCTAssertThrowsError(try MailSearchJSON.decoder().decode(MailSearchError.self, from: oldShape))
    }

    func testCanonicalJSONPreservesFractionalSecondTimestamps() throws {
        let interval = MailSearchDateInterval(
            lowerBound: Date(timeIntervalSince1970: 0.125),
            upperBound: Date(timeIntervalSince1970: 1.875)
        )

        let data = try MailSearchJSON.encoder().encode(interval)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"lowerBound":"1970-01-01T00:00:00.125Z","upperBound":"1970-01-01T00:00:01.875Z"}"#
        )
        XCTAssertEqual(
            try MailSearchJSON.decoder().decode(MailSearchDateInterval.self, from: data),
            interval
        )
    }

    func testCanonicalJSONRoundsAndReencodesMillisecondBoundariesStably() throws {
        let interval = MailSearchDateInterval(
            lowerBound: Date(timeIntervalSince1970: 100.334_499),
            upperBound: Date(timeIntervalSince1970: 100.334_501)
        )

        let data = try MailSearchJSON.encoder().encode(interval)

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"lowerBound":"1970-01-01T00:01:40.334Z","upperBound":"1970-01-01T00:01:40.335Z"}"#
        )
        let decoded = try MailSearchJSON.decoder().decode(
            MailSearchDateInterval.self,
            from: data
        )
        XCTAssertEqual(try MailSearchJSON.encoder().encode(decoded), data)
    }

    func testSessionRetainsTenUniqueQueriesInMemory() async {
        let session = MailSearchSession()
        for index in 0 ..< 12 {
            await session.submit("query \(index)")
        }
        await session.submit("query 11")

        let recent = await session.recentQueries()

        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first, "query 11")
        XCTAssertEqual(recent.last, "query 2")
    }

    func testSessionTrimsQueriesDeduplicatesCaseInsensitivelyAndClears() async {
        let session = MailSearchSession(capacity: 2)
        await session.submit("  Project  ")
        await session.submit("project")
        await session.submit("\n")

        let deduplicatedQueries = await session.recentQueries()
        XCTAssertEqual(deduplicatedQueries, ["project"])

        await session.clear()
        let clearedQueries = await session.recentQueries()
        XCTAssertEqual(clearedQueries, [])
    }

    func testSessionNeverRetainsMoreThanTenQueries() async {
        let session = MailSearchSession(capacity: 100)
        for index in 0 ..< 12 {
            await session.submit("query \(index)")
        }

        let recent = await session.recentQueries()

        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first, "query 11")
        XCTAssertEqual(recent.last, "query 2")
    }

    private func assertGoldenRoundTrip<Value: Codable & Equatable>(
        _ value: Value,
        goldenJSON: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let encoded = try MailSearchJSON.encoder().encode(value)
            XCTAssertEqual(
                String(decoding: encoded, as: UTF8.self),
                goldenJSON,
                file: file,
                line: line
            )
            let decoded = try MailSearchJSON.decoder().decode(
                Value.self,
                from: Data(goldenJSON.utf8)
            )
            XCTAssertEqual(decoded, value, file: file, line: line)
        } catch {
            XCTFail("Golden JSON round trip failed: \(error)", file: file, line: line)
        }
    }
}
