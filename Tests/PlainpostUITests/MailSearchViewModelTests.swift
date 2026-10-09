import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostUI

@MainActor
final class MailSearchViewModelTests: XCTestCase {
    func testDefaultsToConversationsAndRetainsRowsDuringReplacementSearch() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)

        XCTAssertEqual(model.mode, .conversations)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.completeSearch(0, with: .fixtureConversation(id: "t1"))
        await waitUntil { model.rows.map(\.id) == ["thread:t1"] }

        model.query = "budget"
        model.submit()
        await probe.waitForSearchRequests(2)

        XCTAssertEqual(model.rows.map(\.id), ["thread:t1"])
        XCTAssertTrue(model.isReplacingResults)
        XCTAssertEqual(model.state, .searching(retainingResults: true))
    }

    func testReturnDoesNotOpenRetainedResultsFromPreviousRequest() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.completeSearch(0, with: .fixtureConversation(id: "old"))
        await waitUntil { model.rows.map(\.id) == ["thread:old"] }

        model.query = "budget"
        model.submit()
        await probe.waitForSearchRequests(2)

        XCTAssertEqual(model.rows.map(\.id), ["thread:old"])
        XCTAssertNil(model.hitToOpenOnReturn())

        await probe.completeSearch(1, with: .fixtureConversation(id: "current"))
        await waitUntil { model.rows.map(\.id) == ["thread:current"] }
        XCTAssertEqual(model.hitToOpenOnReturn()?.id, "thread:current")
    }

    func testTypingDebouncesForExactly250Milliseconds() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)

        model.query = "project"

        await sleeper.waitForRequests(1)
        let durations = await sleeper.requestedDurations()
        let requestsBeforeResume = await probe.requestCount()
        XCTAssertEqual(durations, [.milliseconds(250)])
        XCTAssertEqual(requestsBeforeResume, 0)
        await sleeper.resume(0)
        await probe.waitForSearchRequests(1)
        let request = await probe.request(at: 0)
        XCTAssertEqual(request.query, "project")
    }

    func testSubmitCancelsDebounceRecordsHistoryAndSearchesImmediately() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let session = MailSearchSession()
        let model = MailSearchViewModel(
            accounts: [.fixture],
            service: probe,
            session: session,
            sleep: sleeper.sleep
        )
        model.query = " project "
        await sleeper.waitForRequests(1)

        model.submit()

        await probe.waitForSearchRequests(1)
        await waitUntil { await session.recentQueries() == ["project"] }
        let firstRequest = await probe.request(at: 0)
        let debounceWasCancelled = await sleeper.wasCancelled(0)
        XCTAssertEqual(firstRequest.query, "project")
        XCTAssertTrue(debounceWasCancelled)
        await sleeper.resume(0)
        await Task.yield()
        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSubmittingPostWithVisibleContactSuggestionSearchesPost() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let contact = MailSearchSuggestionItem(
            id: "post-contact", title: "Post CH Ltd", detail: "notifications@post.ch",
            insertion: "participants:notifications@post.ch", replacementRange: nil
        )
        await probe.enqueueSuggestion(.success([.init(kind: .people, items: [contact])]))
        let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)
        model.query = "Post"
        await sleeper.waitForRequests(1)
        await sleeper.resume(0)
        await probe.waitForSearchRequests(1)
        await waitUntil { model.suggestions.first?.items == [contact] }

        model.submit()

        await probe.waitForSearchRequests(2)
        let request = await probe.request(at: 1)
        XCTAssertEqual(request.query, "Post")
        XCTAssertEqual(model.query, "Post")
    }

    func testScopedWhitespaceSubmitSearchesMatchAllWithoutRecordingHistory() async {
        let probe = MailSearchServiceProbe()
        let session = MailSearchSession()
        let model = MailSearchViewModel(
            accounts: [.fixture],
            service: probe,
            session: session
        )
        model.scope = MailSearchSelectionScope(accountIDs: [AccountID("account")])
        model.query = " \n "

        model.submit()

        await probe.waitForSearchRequests(1)
        let request = await probe.request(at: 0)
        let recentQueries = await session.recentQueries()
        XCTAssertEqual(request.query, "")
        XCTAssertEqual(request.scope.accountIDs, [AccountID("account")])
        XCTAssertEqual(recentQueries, [])
    }

    func testTypingDoesNotRecordSessionHistory() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let session = MailSearchSession()
        let model = MailSearchViewModel(
            accounts: [.fixture],
            service: probe,
            session: session,
            sleep: sleeper.sleep
        )
        model.query = "project"
        await sleeper.waitForRequests(1)
        await sleeper.resume(0)
        await probe.waitForSearchRequests(1)

        let recentQueries = await session.recentQueries()
        XCTAssertEqual(recentQueries, [])
    }

    func testPresentationLoadsEmptyQueryRecentsWithoutSearchingOrWritingHistory() async {
        let probe = MailSearchServiceProbe()
        let session = MailSearchSession()
        await session.submit("project")
        let recent = MailSearchSuggestionItem(
            id: "recent:project",
            title: "project",
            detail: "Recent search",
            insertion: "project",
            replacementRange: .init(location: 0, length: 0)
        )
        await probe.enqueueSuggestion(.success([
            .init(kind: .recent, items: [recent]),
        ]))
        let model = MailSearchViewModel(
            accounts: [.fixture],
            service: probe,
            session: session
        )

        model.prepareInitialSearchSuggestions()

        await probe.waitForSuggestionRequests(1)
        await waitUntil { model.suggestions.first?.items == [recent] }
        let request = await probe.suggestionRequest(at: 0)
        let searchRequestCount = await probe.requestCount()
        let recentQueries = await session.recentQueries()
        XCTAssertEqual(request.query, "")
        XCTAssertEqual(request.recentQueries, ["project"])
        XCTAssertEqual(searchRequestCount, 0)
        XCTAssertEqual(recentQueries, ["project"])
        XCTAssertEqual(model.state, .initial)
    }

    func testClearingSubmittedQueryReloadsSessionRecentsWithoutAnotherSearch() async {
        let probe = MailSearchServiceProbe()
        let session = MailSearchSession()
        let recent = MailSearchSuggestionItem(
            id: "recent:project",
            title: "project",
            detail: "Recent search",
            insertion: "project",
            replacementRange: .init(location: 0, length: 0)
        )
        await probe.enqueueSuggestion(.success([
            .init(kind: .recent, items: [recent]),
        ]))
        let model = MailSearchViewModel(
            accounts: [.fixture],
            service: probe,
            session: session
        )
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await waitUntil { await session.recentQueries() == ["project"] }

        model.query = ""

        await probe.waitForSuggestionRequests(1)
        await waitUntil { model.suggestions.first?.items == [recent] }
        let request = await probe.suggestionRequest(at: 0)
        let searchRequestCount = await probe.requestCount()
        let recentQueries = await session.recentQueries()
        XCTAssertEqual(request.recentQueries, ["project"])
        XCTAssertEqual(searchRequestCount, 1)
        XCTAssertEqual(recentQueries, ["project"])
        XCTAssertEqual(model.state, .initial)
    }

    func testBareOneCharacterOnlySuggestsButStructuredOneCharacterSearches() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)
        model.query = "a"
        await sleeper.waitForRequests(1)
        await sleeper.resume(0)
        await probe.waitForSuggestionRequests(1)
        await Task.yield()

        let bareRequestCount = await probe.requestCount()
        XCTAssertEqual(bareRequestCount, 0)
        XCTAssertEqual(model.state, .suggesting)

        model.query = "from:a"
        await sleeper.waitForRequests(2)
        await sleeper.resume(1)
        await probe.waitForSearchRequests(1)

        let structuredRequest = await probe.request(at: 0)
        XCTAssertEqual(structuredRequest.query, "from:a")
    }

    func testChangingQueryCancelsInFlightServiceCallAndIgnoresLateCompletion() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "first"
        model.submit()
        await probe.waitForSearchRequests(1)

        model.query = "second"
        model.submit()
        await probe.waitForSearchRequests(2)
        await probe.waitForCancelledSearches(1)
        await probe.completeSearch(1, with: .fixtureMessage(id: "new"))
        await waitUntil { model.rows.map(\.id) == ["message:new"] }
        await probe.completeSearch(0, with: .fixtureMessage(id: "old"))
        await Task.yield()

        XCTAssertEqual(model.rows.map(\.id), ["message:new"])
    }

    func testModeAndScopeArePreservedAcrossRequests() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.mode = .messages
        model.scope = MailSearchSelectionScope(
            accountIDs: [AccountID("account")],
            mailboxIDs: [MailboxID("inbox")]
        )
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)

        let request = await probe.request(at: 0)
        XCTAssertEqual(request.mode, .messages)
        XCTAssertEqual(request.scope, model.scope)
    }

    func testTypedFailuresMapToTypedViewStatesWithoutSensitiveDetails() async {
        let cases: [(MailSearchError, MailSearchViewState)] = [
            (.invalidQuery(reason: "private@example.com /Users/me/mail.sqlite", range: nil), .invalid("Check the search query and try again.")),
            (.unsupportedField(name: "private", range: .init(location: 0, length: 7)), .invalid("That search field is not supported.")),
            (.unsupportedValue(field: "has", range: .init(location: 0, length: 3)), .invalid("That search value is not supported.")),
            (.requestTooLarge(maximum: 2_048), .invalid("This search is too long. Remove some terms.")),
            (.rebuilding, .rebuilding),
            (.unavailable, .unavailable),
        ]

        for (index, value) in cases.enumerated() {
            let probe = MailSearchServiceProbe()
            let model = MailSearchViewModel(accounts: [.fixture], service: probe)
            model.query = "query-\(index)"
            model.submit()
            await probe.waitForSearchRequests(1)
            await probe.failSearch(0, with: value.0)
            await waitUntil { model.state == value.1 }
            XCTAssertFalse(String(describing: model.state).contains("private@example.com"))
            XCTAssertFalse(String(describing: model.state).contains("/Users/"))
        }
    }

    func testKnownInvalidQueryReasonExplainsAccountScopeMismatch() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "Post"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.failSearch(0, with: MailSearchError.invalidQuery(
            reason: "Account search scope does not match the selected account.", range: nil
        ))

        await waitUntil {
            if case .invalid = model.state { return true }
            return false
        }
        XCTAssertEqual(
            model.state,
            .invalid("Search scope does not match this account. Clear Scope and try again.")
        )
    }

    func testStaleCursorRestartDrainsDuplicateOnlyContinuationAndRetainsPreviouslyVisibleRows() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.completeSearch(
            0,
            with: .fixture(
                hits: [.fixtureMessage(id: "m1"), .fixtureMessage(id: "m2")],
                nextCursor: "next"
            )
        )
        await waitUntil { model.rows.count == 2 }

        model.loadNextPageIfNeeded(after: "message:m2")
        await probe.waitForSearchRequests(2)
        await probe.completeSearch(
            1,
            with: .fixture(
                hits: [.fixtureMessage(id: "m2"), .fixtureMessage(id: "m3")],
                nextCursor: "stale"
            )
        )
        await waitUntil { model.rows.count == 3 }

        model.loadNextPageIfNeeded(after: "message:m3")
        await probe.waitForSearchRequests(3)
        await probe.failSearch(2, with: MailSearchError.staleCursor)
        await probe.waitForSearchRequests(4)
        let restartRequest = await probe.request(at: 3)
        XCTAssertNil(restartRequest.cursor)
        await probe.completeSearch(
            3,
            with: .fixture(
                hits: [.fixtureMessage(id: "m3"), .fixtureMessage(id: "m1")],
                nextCursor: "fresh-1"
            )
        )
        await waitUntil { model.state == .results(hasMore: true) }

        let firstPageCount = await probe.firstPageCount()
        XCTAssertEqual(firstPageCount, 2)
        XCTAssertEqual(
            model.rows.map(\.id),
            ["message:m3", "message:m1", "message:m2"]
        )
        XCTAssertEqual(model.state, .results(hasMore: true))

        model.loadNextPageIfNeeded(after: "message:m2")
        await probe.waitForSearchRequests(5)
        let freshCursorRequest = await probe.request(at: 4)
        XCTAssertEqual(freshCursorRequest.cursor?.rawValue, "fresh-1")
        await probe.completeSearch(
            4,
            with: .fixture(
                hits: [.fixtureMessage(id: "m3"), .fixtureMessage(id: "m1")],
                nextCursor: "fresh-2"
            )
        )
        let didDrainDuplicatePage = await waitUntilBounded {
            await probe.requestCount() == 6
        }
        XCTAssertTrue(didDrainDuplicatePage)
        guard didDrainDuplicatePage else { return }
        let drainedCursorRequest = await probe.request(at: 5)
        XCTAssertEqual(drainedCursorRequest.cursor?.rawValue, "fresh-2")
        await probe.completeSearch(5, with: .fixture(hits: [.fixtureMessage(id: "m4")]))
        await waitUntil { model.state == .results(hasMore: false) }
        XCTAssertEqual(
            model.rows.map(\.id),
            ["message:m3", "message:m1", "message:m2", "message:m4"]
        )
    }

    func testDuplicateOnlyPageWithRepeatedCursorStopsUnavailableWithoutLooping() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.completeSearch(
            0,
            with: .fixture(hits: [.fixtureMessage(id: "m1")], nextCursor: "repeated")
        )
        await waitUntil { model.state == .results(hasMore: true) }

        model.loadNextPageIfNeeded(after: "message:m1")
        await probe.waitForSearchRequests(2)
        await probe.completeSearch(
            1,
            with: .fixture(hits: [.fixtureMessage(id: "m1")], nextCursor: "repeated")
        )
        let didStopUnavailable = await waitUntilBounded { model.state == .unavailable }

        XCTAssertTrue(didStopUnavailable)
        XCTAssertEqual(model.state, .unavailable)
        let requestCount = await probe.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(model.rows.map(\.id), ["message:m1"])
    }

    func testNextPageStaleCursorRestartsAtMostOncePerGeneration() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.completeSearch(
            0,
            with: .fixture(hits: [.fixtureMessage(id: "m1")], nextCursor: "next")
        )
        await waitUntil { model.rows.count == 1 }
        model.loadNextPageIfNeeded(after: "message:m1")
        await probe.waitForSearchRequests(2)
        await probe.failSearch(1, with: MailSearchError.staleCursor)
        await probe.waitForSearchRequests(3)
        await probe.completeSearch(
            2,
            with: .fixture(hits: [.fixtureMessage(id: "m1")], nextCursor: "fresh")
        )
        await waitUntil { model.state == .results(hasMore: true) }
        model.loadNextPageIfNeeded(after: "message:m1")
        await probe.waitForSearchRequests(4)
        await probe.failSearch(3, with: MailSearchError.staleCursor)
        await waitUntil { model.state == .unavailable }

        let firstPageCount = await probe.firstPageCount()
        XCTAssertEqual(firstPageCount, 2)
        XCTAssertEqual(model.rows.map(\.id), ["message:m1"])
    }

    func testMessageToOpenUsesBestConversationMessageOrMessageHit() throws {
        let model = MailSearchViewModel(accounts: [.fixture], service: MailSearchServiceProbe())
        let conversation = MailSearchHit.fixtureConversation(id: "thread", bestMessageID: "best")
        let message = MailSearchHit.fixtureMessage(id: "direct")

        XCTAssertEqual(model.messageToOpen(for: conversation), MessageID("best"))
        XCTAssertEqual(model.messageToOpen(for: message), MessageID("direct"))
    }

    func testRetryRepeatsFailedRequest() async {
        let probe = MailSearchServiceProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe)
        model.query = "project"
        model.submit()
        await probe.waitForSearchRequests(1)
        await probe.failSearch(0, with: MailSearchError.unavailable)
        await waitUntil { model.state == .unavailable }

        model.retry()
        await probe.waitForSearchRequests(2)

        let first = await probe.request(at: 0)
        let second = await probe.request(at: 1)
        XCTAssertEqual(first, second)
    }

    func testCaretSelectionRequestsRawQuotedValueWithoutRerunningSearch() async {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)
        let query = #"  project from:"Alex Ri" next"#
        let valueRange = (query as NSString).range(of: "Alex Ri")

        model.query = query
        await sleeper.waitForRequests(1)
        model.updateTextSelection(.init(location: valueRange.location + 3, length: 0))
        await sleeper.waitForRequests(2)
        await sleeper.resume(1)
        await probe.waitForSuggestionRequests(1)

        let suggestion = await probe.suggestionRequest(at: 0)
        XCTAssertEqual(suggestion.query, query)
        XCTAssertEqual(
            suggestion.activeRange,
            .init(location: valueRange.location, length: valueRange.length)
        )

        await sleeper.resume(0)
        await probe.waitForSearchRequests(1)
        await Task.yield()
        let searchRequestCount = await probe.requestCount()
        let searchRequest = await probe.request(at: 0)
        XCTAssertEqual(searchRequestCount, 1)
        XCTAssertEqual(searchRequest.query, query.trimmingCharacters(in: .whitespaces))
    }

    func testTextSelectionContextsFlowThroughModelUsingRawUTF16Ranges() async {
        let cases: [(String, MailSearchTextRange, MailSearchTextRange)] = [
            {
                let query = "project from:al next"
                let value = (query as NSString).range(of: "al")
                return (
                    query,
                    .init(location: value.location + 1, length: 0),
                    .init(location: value.location, length: value.length)
                )
            }(),
            {
                let query = #"  from:"Alex Ri" project"#
                let value = (query as NSString).range(of: "Alex Ri")
                return (
                    query,
                    .init(location: value.location + 2, length: 0),
                    .init(location: value.location, length: value.length)
                )
            }(),
            {
                let query = "  leading project"
                let value = (query as NSString).range(of: "leading")
                return (
                    query,
                    .init(location: value.location + 2, length: 0),
                    .init(location: value.location, length: value.length)
                )
            }(),
            {
                let query = "project selected next"
                let value = (query as NSString).range(of: "selected")
                return (
                    query,
                    .init(location: value.location, length: value.length),
                    .init(location: value.location, length: value.length)
                )
            }(),
            ("from:", .init(location: 5, length: 0), .init(location: 5, length: 0)),
            {
                let query = "project 😀 e\u{301} next"
                let value = (query as NSString).range(of: "😀")
                return (
                    query,
                    .init(location: value.location + 1, length: 0),
                    .init(location: value.location, length: value.length)
                )
            }(),
            {
                let query = "project 😀 e\u{301} next"
                let value = (query as NSString).range(of: "e\u{301}")
                return (
                    query,
                    .init(location: value.location + 1, length: 0),
                    .init(location: value.location, length: value.length)
                )
            }(),
        ]

        for (query, selection, expectedRange) in cases {
            let probe = MailSearchServiceProbe()
            let sleeper = SearchSleepProbe()
            let model = MailSearchViewModel(
                accounts: [.fixture],
                service: probe,
                sleep: sleeper.sleep
            )
            model.query = query
            await sleeper.waitForRequests(1)
            model.updateTextSelection(selection)
            let selectionChanged = selection != .init(location: query.utf16.count, length: 0)
            if selectionChanged {
                await sleeper.waitForRequests(2)
                await sleeper.resume(1)
            } else {
                await sleeper.resume(0)
            }
            await probe.waitForSuggestionRequests(1)

            let request = await probe.suggestionRequest(at: 0)
            XCTAssertEqual(request.query, query, query)
            XCTAssertEqual(request.activeRange, expectedRange, query)
        }
    }

    func testStaleSuggestionCannotApplyAfterQueryChangesDuringDebounce() async throws {
        let probe = MailSearchServiceProbe()
        let sleeper = SearchSleepProbe()
        let item = MailSearchSuggestionItem(
            id: "person:alex",
            title: "Alex",
            detail: "alex@example.com",
            insertion: "alex@example.com",
            replacementRange: .init(location: 0, length: 2)
        )
        await probe.enqueueSuggestion(.success([
            .init(kind: .people, items: [item]),
        ]))
        let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)
        model.query = "al"
        await sleeper.waitForRequests(1)
        await sleeper.resume(0)
        await probe.waitForSuggestionRequests(1)
        await waitUntil { model.suggestions.first?.items == [item] }

        model.query = "bo"

        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.validatedSuggestionForApplication(item))
        XCTAssertEqual(model.query, "bo")
    }

    func testRetryRecoversSuggestionOnlyRebuildingAndUnavailableRequests() async {
        for error in [MailSearchError.rebuilding, .unavailable] {
            let probe = MailSearchServiceProbe()
            let sleeper = SearchSleepProbe()
            let item = MailSearchSuggestionItem(
                id: "field:after",
                title: "after",
                detail: "Date boundary",
                insertion: "after:",
                replacementRange: .init(location: 0, length: 1)
            )
            await probe.enqueueSuggestion(.failure(error))
            await probe.enqueueSuggestion(.success([
                .init(kind: .fields, items: [item]),
            ]))
            let model = MailSearchViewModel(accounts: [.fixture], service: probe, sleep: sleeper.sleep)
            model.query = "a"
            await sleeper.waitForRequests(1)
            await sleeper.resume(0)
            await probe.waitForSuggestionRequests(1)
            let expectedFailureState: MailSearchViewState = error == .rebuilding
                ? .rebuilding
                : .unavailable
            await waitUntil { model.state == expectedFailureState }

            model.retry()
            await probe.waitForSuggestionRequests(2)
            await waitUntil { model.suggestions.first?.items == [item] }

            let firstRequest = await probe.suggestionRequest(at: 0)
            let secondRequest = await probe.suggestionRequest(at: 1)
            XCTAssertEqual(model.state, .suggesting)
            XCTAssertEqual(firstRequest, secondRequest)
        }
    }

    func testMailboxMetadataIsBoundedAndRemovedScopeIDsAreReconciled() {
        let inbox = MailSearchMailbox(
            id: MailboxID("inbox"),
            accountID: AccountID("account"),
            displayName: "Inbox"
        )
        let archive = MailSearchMailbox(
            id: MailboxID("archive"),
            accountID: AccountID("account"),
            displayName: "Archive"
        )
        let oversized = (0 ... MailSearchMailbox.maximumMetadataCount).map { index in
            MailSearchMailbox(
                id: MailboxID("mailbox-\(index)"),
                accountID: AccountID("account"),
                displayName: "Mailbox \(index)"
            )
        }
        let bounded = MailSearchViewModel(
            accounts: [.fixture],
            mailboxes: oversized,
            service: MailSearchServiceProbe()
        )
        XCTAssertEqual(bounded.mailboxes.count, MailSearchMailbox.maximumMetadataCount)

        let model = MailSearchViewModel(
            accounts: [.fixture],
            mailboxes: [inbox, archive],
            service: MailSearchServiceProbe()
        )
        model.scope = .init(mailboxIDs: [inbox.id, archive.id])

        model.updateMailboxes([inbox])

        XCTAssertEqual(model.mailboxes, [inbox])
        XCTAssertEqual(model.scope.mailboxIDs, [inbox.id])
        XCTAssertEqual(
            model.accessibilityAnnouncement,
            "Search scope changed because a selected mailbox is no longer available."
        )
    }

    func testSuggestionPreviewRetainsCurrentSuggestionsWhenFieldReportsItsCaret() throws {
        let model = MailSearchViewModel.designSuggestions()
        let item = try XCTUnwrap(model.suggestions.first?.items.first)

        model.updateTextSelection(.init(location: 0, length: model.query.utf16.count))

        XCTAssertFalse(model.suggestions.isEmpty)
        XCTAssertEqual(model.validatedSuggestionForApplication(item), item)
    }

    func testSearchIndexControllerLoadsRealStateAndRefreshesAfterRebuild() async {
        let probe = MailSearchIndexStateProbe(states: [.preparing, .ready])
        let controller = MailSearchIndexRebuildController(
            indexState: { await probe.nextState() },
            rebuild: { try await probe.rebuild() }
        )

        XCTAssertEqual(
            MailSearchIndexRebuildPresentation.confirmationMessage,
            "Plainpost will rebuild its local search index. Your mail is retained and never deleted. Search is unavailable until rebuilding finishes."
        )

        XCTAssertEqual(controller.state, .loading)
        await controller.refresh()
        XCTAssertEqual(controller.state, .preparing)

        await controller.rebuild()

        let rebuildRequestCount = await probe.rebuildCount()
        let stateRequestCount = await probe.stateCount()
        XCTAssertEqual(rebuildRequestCount, 1)
        XCTAssertEqual(stateRequestCount, 2)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.accessibilityAnnouncement, "Search index rebuild completed.")
    }

    func testSearchIndexControllerPresentsUnavailableAndRebuildFailureTruthfully() async {
        let unavailable = MailSearchIndexRebuildController(
            indexState: { .unavailable },
            rebuild: {}
        )
        await unavailable.refresh()
        XCTAssertEqual(unavailable.state, .unavailable)

        let failed = MailSearchIndexRebuildController(
            indexState: { .ready },
            rebuild: { throw MailSearchError.unavailable }
        )
        await failed.refresh()
        await failed.rebuild()
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.accessibilityAnnouncement, "Search index rebuild failed. Try again.")
    }

    func testSelectedDirectSearchDoesNotOfferOrRunStoreWideRebuild() async {
        let probe = MailSearchIndexStateProbe(states: [.ready])
        let controller = MailSearchIndexRebuildController(
            indexState: { await probe.nextState() },
            rebuild: { try await probe.rebuild() },
            allowsRebuild: false
        )

        await controller.refresh()
        XCTAssertFalse(controller.allowsRebuild)
        await controller.rebuild()
        let rebuildCount = await probe.rebuildCount()
        XCTAssertEqual(rebuildCount, 0)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.accessibilityAnnouncement)
    }

    func testSearchIndexControllerPostsOneTerminalAnnouncementWithoutViewObservers() async {
        var successAnnouncements: [String] = []
        let success = MailSearchIndexRebuildController(
            indexState: { .ready },
            rebuild: {},
            announce: { successAnnouncements.append($0) }
        )

        await success.refresh()
        await success.rebuild()

        XCTAssertEqual(
            successAnnouncements.filter { $0 == "Search index rebuild completed." },
            ["Search index rebuild completed."]
        )

        var failureAnnouncements: [String] = []
        let failure = MailSearchIndexRebuildController(
            indexState: { .ready },
            rebuild: { throw MailSearchError.unavailable },
            announce: { failureAnnouncements.append($0) }
        )

        await failure.refresh()
        await failure.rebuild()

        XCTAssertEqual(
            failureAnnouncements.filter { $0 == "Search index rebuild failed. Try again." },
            ["Search index rebuild failed. Try again."]
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        while !(await condition()) { await Task.yield() }
    }

    private func waitUntilBounded(
        maximumYields: Int = 10_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< maximumYields {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}

private actor SearchSleepProbe {
    private(set) var durations: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<Int> = []

    func sleep(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[index] = continuation
            }
        } onCancel: {
            Task { await self.cancel(index) }
        }
    }

    func waitForRequests(_ count: Int) async {
        while durations.count < count { await Task.yield() }
    }

    func requestedDurations() -> [Duration] { durations }

    func resume(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume(returning: ())
    }

    func wasCancelled(_ index: Int) -> Bool { cancelled.contains(index) }

    private func cancel(_ index: Int) {
        cancelled.insert(index)
        continuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}

private actor MailSearchServiceProbe: MailSearchService {
    private(set) var searchRequests: [MailSearchRequest] = []
    private(set) var suggestionRequests: [MailSearchSuggestionRequest] = []
    private var searchContinuations: [Int: CheckedContinuation<MailSearchResponse, Error>] = [:]
    private(set) var cancelledSearches: Set<Int> = []
    private var rebuildRequests = 0
    private var queuedSuggestions: [Result<[MailSearchSuggestionSection], MailSearchError>] = []

    func requestCount() -> Int { searchRequests.count }
    func firstPageCount() -> Int { searchRequests.filter { $0.cursor == nil }.count }
    func request(at index: Int) -> MailSearchRequest { searchRequests[index] }
    func suggestionRequest(at index: Int) -> MailSearchSuggestionRequest { suggestionRequests[index] }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResponse {
        let index = searchRequests.count
        searchRequests.append(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                searchContinuations[index] = continuation
            }
        } onCancel: {
            Task { await self.cancelSearch(index) }
        }
    }

    func suggestions(
        _ request: MailSearchSuggestionRequest
    ) async throws -> [MailSearchSuggestionSection] {
        suggestionRequests.append(request)
        guard !queuedSuggestions.isEmpty else { return [] }
        return try queuedSuggestions.removeFirst().get()
    }

    func enqueueSuggestion(
        _ result: Result<[MailSearchSuggestionSection], MailSearchError>
    ) {
        queuedSuggestions.append(result)
    }

    func indexState() async -> MailSearchIndexState { .ready }
    func rebuildIndex() async throws { rebuildRequests += 1 }
    func performMaintenanceIfDue(now _: Date) async throws {}

    func rebuildRequestCount() -> Int { rebuildRequests }

    func waitForSearchRequests(_ count: Int) async {
        while searchRequests.count < count { await Task.yield() }
    }

    func waitForSuggestionRequests(_ count: Int) async {
        while suggestionRequests.count < count { await Task.yield() }
    }

    func waitForCancelledSearches(_ count: Int) async {
        while cancelledSearches.count < count { await Task.yield() }
    }

    func completeSearch(_ index: Int, with response: MailSearchResponse) {
        searchContinuations.removeValue(forKey: index)?.resume(returning: response)
    }

    func failSearch(_ index: Int, with error: any Error) {
        searchContinuations.removeValue(forKey: index)?.resume(throwing: error)
    }

    private func cancelSearch(_ index: Int) {
        cancelledSearches.insert(index)
    }
}

private actor MailSearchIndexStateProbe {
    private var states: [MailSearchIndexState]
    private var rebuilds = 0
    private var stateRequests = 0

    init(states: [MailSearchIndexState]) {
        self.states = states
    }

    func nextState() -> MailSearchIndexState {
        stateRequests += 1
        return states.isEmpty ? .unavailable : states.removeFirst()
    }

    func rebuild() throws { rebuilds += 1 }
    func rebuildCount() -> Int { rebuilds }
    func stateCount() -> Int { stateRequests }
}

private extension MailSearchAccount {
    static let fixture = MailSearchAccount(
        id: AccountID("account"),
        displayName: "Personal",
        email: "me@example.com"
    )
}

private extension MailSearchHit {
    static func fixtureConversation(
        id: String,
        bestMessageID: String = "best"
    ) -> MailSearchHit {
        .conversation(.init(
            stableID: "thread:\(id)",
            threadID: ThreadID(id),
            accountID: AccountID("account"),
            bestMatchingMessageID: MessageID(bestMessageID),
            subject: "Project",
            participants: ["Alex"],
            latestActivity: Date(timeIntervalSince1970: 1_720_000_000),
            snippet: try! MailSearchSnippet(text: "Project", highlights: []),
            matchingMessageCount: 1,
            totalMessageCount: 2,
            unreadMessageCount: 1,
            hasAttachments: false,
            hasDocuments: false
        ))
    }

    static func fixtureMessage(id: String) -> MailSearchHit {
        .message(.init(
            stableID: "message:\(id)",
            messageID: MessageID(id),
            threadID: ThreadID("thread-\(id)"),
            accountID: AccountID("account"),
            sender: EmailAddress("alex@example.com"),
            senderDisplayName: "Alex",
            recipients: [EmailAddress("me@example.com")],
            subject: "Project",
            sentAt: Date(timeIntervalSince1970: 1_720_000_000),
            snippet: try! MailSearchSnippet(text: "Project", highlights: []),
            isUnread: true,
            isFlagged: false,
            isDelegated: false,
            mailboxIDs: [MailboxID("inbox")],
            hasAttachments: false,
            hasDocuments: false
        ))
    }
}

private extension MailSearchResponse {
    static func fixtureConversation(id: String) -> MailSearchResponse {
        fixture(hits: [.fixtureConversation(id: id)])
    }

    static func fixtureMessage(id: String) -> MailSearchResponse {
        fixture(hits: [.fixtureMessage(id: id)])
    }

    static func fixture(
        hits: [MailSearchHit],
        nextCursor: String? = nil
    ) -> MailSearchResponse {
        MailSearchResponse(
            parsedQuery: .init(
                expression: .term("project", prefix: true),
                tokens: [],
                canonicalQuery: "project"
            ),
            mode: hits.first.map {
                if case .conversation = $0 { return .conversations }
                return .messages
            } ?? .conversations,
            scope: .init(),
            hits: hits,
            nextCursor: nextCursor.map(MailSearchCursor.init(rawValue:)),
            indexRevision: "1"
        )
    }
}
