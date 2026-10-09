import Foundation
import GRDB
import XCTest
import PlainpostCore
@testable import PlainpostDB

final class SQLiteMailConversationSearchTests: XCTestCase {
    func testConversationModeSelectsBestMatchAndAggregatesOnlyWinningThreads() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(
                id: "alpha-exact",
                threadID: "thread-alpha",
                senderEmail: "alex@example.com",
                senderDisplayName: "Alex",
                to: "team@example.com",
                subject: "Project",
                sortDate: 100
            ),
            .init(
                id: "alpha-body",
                threadID: "thread-alpha",
                senderEmail: "team@example.com",
                senderDisplayName: nil,
                to: "alex@example.com",
                body: "Project details",
                sortDate: 200,
                hasDocuments: true
            ),
            .init(
                id: "alpha-latest",
                threadID: "thread-alpha",
                senderEmail: "owner@example.com",
                senderDisplayName: nil,
                to: "alex@example.com team@example.com",
                subject: "Unrelated update",
                sortDate: 300,
                isSeen: false,
                hasAttachments: true
            ),
            .init(id: "beta", threadID: "thread-beta", subject: "Project beta", sortDate: 250),
            .init(id: "loser", threadID: "thread-loser", subject: "Project loser", sortDate: 50),
        ])

        let response = try await fixture.searchConversations("project", limit: 2)
        let first = try XCTUnwrap(response.conversationHits.first)

        XCTAssertEqual(first.threadID, ThreadID("thread-alpha"))
        XCTAssertEqual(first.bestMatchingMessageID, MessageID("alpha-exact"))
        XCTAssertEqual(first.matchingMessageCount, 2)
        XCTAssertEqual(first.totalMessageCount, 3)
        XCTAssertEqual(first.unreadMessageCount, 1)
        XCTAssertEqual(first.latestActivity, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(Set(first.participants), [
            "Alex", "alex@example.com", "owner@example.com", "team@example.com",
        ])
        XCTAssertTrue(first.hasAttachments)
        XCTAssertTrue(first.hasDocuments)
        XCTAssertEqual(response.hits.count, 2)
        XCTAssertNotNil(response.nextCursor)
    }

    func testConversationHitCarriesTheBestMatchingMessagesSender() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(
                id: "parcel-notice",
                threadID: "thread-parcel",
                senderEmail: "notifications@post.example.test",
                senderDisplayName: "Post CH Ltd",
                to: "aaron@example.com",
                subject: "Parcel update",
                sortDate: 100
            ),
            .init(
                id: "parcel-reply",
                threadID: "thread-parcel",
                senderEmail: "aaron@example.com",
                senderDisplayName: "Aaron",
                to: "notifications@post.example.test",
                subject: "Re: something else",
                sortDate: 200
            ),
            .init(
                id: "nameless",
                threadID: "thread-nameless",
                senderEmail: "zed@example.com",
                senderDisplayName: nil,
                to: "aaron@example.com",
                subject: "Parcel receipt",
                sortDate: 50
            ),
        ])

        let hits = try await fixture.searchConversations("parcel", limit: 10).conversationHits
        let parcel = try XCTUnwrap(hits.first { $0.threadID == ThreadID("thread-parcel") })
        XCTAssertEqual(parcel.bestMatchingMessageID, MessageID("parcel-notice"))
        XCTAssertEqual(parcel.bestMatchSender, EmailAddress("notifications@post.example.test"))
        XCTAssertEqual(parcel.bestMatchSenderDisplayName, "Post CH Ltd")
        XCTAssertNotEqual(parcel.participants.first, "Post CH Ltd", "participants sort alphabetically, so they can't name the sender")

        let nameless = try XCTUnwrap(hits.first { $0.threadID == ThreadID("thread-nameless") })
        XCTAssertEqual(nameless.bestMatchSender, EmailAddress("zed@example.com"))
        XCTAssertNil(nameless.bestMatchSenderDisplayName)
    }

    func testConversationIdentitySeparatesAccountsAndThreadlessMessages() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "shared-a1", threadID: "shared", accountID: "a1", subject: "Project"),
            .init(id: "shared-a2", threadID: "shared", accountID: "a2", subject: "Project"),
            .init(id: "threadless-one", threadID: nil, accountID: "a1", subject: "Project"),
            .init(id: "threadless-two", threadID: nil, accountID: "a1", subject: "Project"),
        ])

        let response = try await fixture.searchConversations("project", limit: 10)
        let hits = response.conversationHits

        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(Set(hits.map { "\($0.accountID.rawValue)|\($0.threadID.rawValue)" }).count, 4)
        XCTAssertEqual(Set(hits.map(\.bestMatchingMessageID.rawValue)), [
            "shared-a1", "shared-a2", "threadless-one", "threadless-two",
        ])
        XCTAssertTrue(hits.allSatisfy { $0.latestActivity == nil })
    }

    func testConversationIdentityEncodingNamespacesIdenticalRawIDsByAccount() throws {
        let queue = try DatabaseQueue()
        let conversationIdentity = SQLiteMailSearchQueryCompiler.conversationIdentitySQL(alias: "d")
        let stableMessageIdentity = SQLiteMailSearchQueryCompiler.stableMessageIdentitySQL(alias: "d")
        let rows = try queue.read { database in
            try Row.fetchAll(database, sql: """
                WITH d(account_id, thread_id, message_id) AS (
                    VALUES
                        ('account-a', 'shared-thread', 'shared-message'),
                        ('account-b', 'shared-thread', 'shared-message'),
                        ('account-a', NULL, 'shared-message'),
                        ('account-b', NULL, 'shared-message')
                )
                SELECT
                    account_id,
                    thread_id,
                    \(conversationIdentity) AS conversation_id,
                    \(stableMessageIdentity) AS stable_id
                FROM d
                ORDER BY account_id, thread_id IS NULL
                """)
        }

        let conversationIDs = rows.map { $0["conversation_id"] as String }
        let stableIDs = rows.map { $0["stable_id"] as String }
        XCTAssertEqual(Set(conversationIDs).count, 4)
        XCTAssertEqual(Set(stableIDs).count, 2)
        XCTAssertTrue(conversationIDs.allSatisfy { $0.contains("|") })
        XCTAssertTrue(stableIDs.allSatisfy { $0.contains("|") })
    }

    func testAccountNamespacedConversationTuplePagesWithoutGapsAndKeepsCursorChecks() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "best-a", threadID: "shared-thread", accountID: "account-a", subject: "Project", sortDate: 100),
            .init(id: "latest-a", threadID: "shared-thread", accountID: "account-a", subject: "Other", sortDate: 200),
            .init(id: "best-b", threadID: "shared-thread", accountID: "account-b", subject: "Project", sortDate: 100),
            .init(id: "latest-b", threadID: "shared-thread", accountID: "account-b", subject: "Other", sortDate: 200),
            .init(id: "threadless-a", threadID: nil, accountID: "account-a", subject: "Project", sortDate: 100),
            .init(id: "threadless-b", threadID: nil, accountID: "account-b", subject: "Project", sortDate: 100),
        ])
        let scope = MailSearchSelectionScope(accountIDs: [AccountID("account-a"), AccountID("account-b")])

        var pages: [MailSearchResponse] = []
        var cursor: MailSearchCursor?
        repeat {
            let page = try await fixture.searchConversations(
                "project",
                scope: scope,
                limit: 1,
                cursor: cursor
            )
            pages.append(page)
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(pages.flatMap(\.hits).count, 4)
        XCTAssertEqual(Set(pages.flatMap(\.conversationIDs)).count, 4)
        let cursorPayloads = try pages.dropLast().compactMap(\.nextCursor).map {
            try Task5CursorMutation.object($0)
        }
        XCTAssertTrue(cursorPayloads.allSatisfy {
            let value = $0["conversationID"] as? String
            return value?.hasPrefix("thread|") == true || value?.hasPrefix("message|") == true
        })
        XCTAssertTrue(cursorPayloads.allSatisfy { payload in
            guard let stableID = payload["stableID"] as? String else { return false }
            return !["best-a", "best-b", "threadless-a", "threadless-b"].contains(stableID)
        })
        for (page, payload) in zip(pages.dropLast(), cursorPayloads) {
            let hit = try XCTUnwrap(page.conversationHits.last)
            XCTAssertEqual(
                payload["stableID"] as? String,
                MailSearchStableIdentity.message(
                    accountID: hit.accountID,
                    messageID: hit.bestMatchingMessageID
                )
            )
            XCTAssertEqual(payload["conversationID"] as? String, hit.stableID)
            XCTAssertEqual(payload["conversationID"] as? String, page.hits.last?.id)
        }

        let firstCursor = try XCTUnwrap(pages.first?.nextCursor)
        await assertSearchError(.staleCursor) {
            _ = try await fixture.searchConversations(
                "project",
                scope: .init(accountIDs: [AccountID("account-a")]),
                limit: 1,
                cursor: firstCursor
            )
        }
        await assertSearchError(.staleCursor) {
            _ = try await fixture.service.search(.init(
                query: "project",
                scope: scope,
                mode: .messages,
                limit: 1,
                cursor: firstCursor
            ))
        }

        try fixture.execute(
            "UPDATE mail_search_state SET revision = revision + 1 WHERE account_id = 'account-a'"
        )
        await assertSearchError(.staleCursor) {
            _ = try await fixture.searchConversations(
                "project",
                scope: scope,
                limit: 1,
                cursor: firstCursor
            )
        }
    }

    func testPublicIdentitySeparatesDelimiterAndLegacySyntheticCollisions() async throws {
        let fixture = try Task5SearchFixture()
        let legacySyntheticThreadID = "plainpost-threadless:1:a:1:m"
        try fixture.insertProjection([
            .init(
                id: "c",
                threadID: "c",
                accountID: "a:b",
                subject: "Project",
                sortDate: 100
            ),
            .init(
                id: "b:c",
                threadID: "b:c",
                accountID: "a",
                subject: "Project",
                sortDate: 200
            ),
            .init(
                id: "m",
                threadID: nil,
                accountID: "a",
                subject: "Project",
                sortDate: 300
            ),
            .init(
                id: "real-message",
                threadID: legacySyntheticThreadID,
                accountID: "a",
                subject: "Project",
                sortDate: 400
            ),
        ])

        let conversations = try await fixture.searchConversations("project", limit: 10)
        let conversationsByMessage = Dictionary(uniqueKeysWithValues: conversations.conversationHits.map {
            ($0.bestMatchingMessageID.rawValue, $0)
        })
        let delimiterOne = try XCTUnwrap(conversationsByMessage["c"])
        let delimiterTwo = try XCTUnwrap(conversationsByMessage["b:c"])
        let threadless = try XCTUnwrap(conversationsByMessage["m"])
        let realThread = try XCTUnwrap(conversationsByMessage["real-message"])
        let threadlessIdentity = MailSearchStableIdentity.message(
            accountID: AccountID("a"),
            messageID: MessageID("m")
        )

        XCTAssertEqual(
            delimiterOne.stableID,
            MailSearchStableIdentity.thread(
                accountID: AccountID("a:b"),
                threadID: ThreadID("c")
            )
        )
        XCTAssertEqual(
            delimiterTwo.stableID,
            MailSearchStableIdentity.thread(
                accountID: AccountID("a"),
                threadID: ThreadID("b:c")
            )
        )
        XCTAssertNotEqual(delimiterOne.stableID, delimiterTwo.stableID)
        XCTAssertEqual(threadless.stableID, threadlessIdentity)
        XCTAssertEqual(threadless.threadID, ThreadID(threadlessIdentity))
        XCTAssertEqual(realThread.threadID, ThreadID(legacySyntheticThreadID))
        XCTAssertTrue(realThread.stableID.hasPrefix("thread|"))
        XCTAssertNotEqual(realThread.stableID, threadless.stableID)

        let conversationPage = try await fixture.searchConversations("project", limit: 1)
        let conversationHit = try XCTUnwrap(conversationPage.conversationHits.last)
        let conversationCursor = try XCTUnwrap(conversationPage.nextCursor)
        let conversationPayload = try Task5CursorMutation.object(conversationCursor)
        XCTAssertEqual(conversationPage.hits.last?.id, conversationPayload["conversationID"] as? String)
        XCTAssertEqual(
            conversationPayload["stableID"] as? String,
            MailSearchStableIdentity.message(
                accountID: conversationHit.accountID,
                messageID: conversationHit.bestMatchingMessageID
            )
        )
        XCTAssertNotEqual(
            conversationPayload["stableID"] as? String,
            conversationPayload["conversationID"] as? String
        )

        let messages = try await fixture.service.search(.init(
            query: "project",
            mode: .messages,
            limit: 10
        ))
        let messageHits = messages.hits.compactMap { hit -> MailMessageSearchHit? in
            guard case .message(let message) = hit else { return nil }
            return message
        }
        let messagesByID = Dictionary(uniqueKeysWithValues: messageHits.map {
            ($0.messageID.rawValue, $0)
        })
        XCTAssertNotEqual(messagesByID["c"]?.stableID, messagesByID["b:c"]?.stableID)
        XCTAssertEqual(messagesByID["m"]?.threadID, ThreadID(threadlessIdentity))

        let messagePage = try await fixture.service.search(.init(
            query: "project",
            mode: .messages,
            limit: 1
        ))
        let messageCursor = try XCTUnwrap(messagePage.nextCursor)
        let messagePayload = try Task5CursorMutation.object(messageCursor)
        let pageMessage = try XCTUnwrap(messagePage.hits.last.flatMap { hit -> MailMessageSearchHit? in
            guard case .message(let message) = hit else { return nil }
            return message
        })
        XCTAssertEqual(messagePayload["stableID"] as? String, pageMessage.messageID.rawValue)
        XCTAssertEqual(messagePayload["conversationID"] as? String, pageMessage.messageID.rawValue)
        XCTAssertNotEqual(messagePage.hits.last?.id, messagePayload["stableID"] as? String)
    }

    func testConversationRankingUsesActivityThenCanonicalIdentityAcrossSingleItemPages() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "z-new-best", threadID: "newer-thread", subject: "Project note", sortDate: 100),
            .init(id: "z-new-latest", threadID: "newer-thread", subject: "Other", sortDate: 400),
            .init(id: "a-old-best", threadID: "older-thread", subject: "Project note", sortDate: 100),
            .init(id: "a-old-latest", threadID: "older-thread", subject: "Other", sortDate: 300),
            .init(id: "z-tie-best", threadID: "a-tie-thread", subject: "Project note", sortDate: 100),
            .init(id: "z-tie-latest", threadID: "a-tie-thread", subject: "Other", sortDate: 200),
            .init(id: "a-tie-best", threadID: "z-tie-thread", subject: "Project note", sortDate: 100),
            .init(id: "a-tie-latest", threadID: "z-tie-thread", subject: "Other", sortDate: 200),
        ])

        var pages: [MailSearchResponse] = []
        var cursor: MailSearchCursor?
        repeat {
            let page = try await fixture.searchConversations("project", limit: 1, cursor: cursor)
            pages.append(page)
            cursor = page.nextCursor
        } while cursor != nil

        let hits = pages.flatMap(\.conversationHits)
        XCTAssertEqual(
            hits.map(\.bestMatchingMessageID.rawValue),
            ["z-new-best", "a-old-best", "z-tie-best", "a-tie-best"]
        )
        XCTAssertEqual(hits.compactMap { $0.latestActivity?.timeIntervalSince1970 }, [400, 300, 200, 200])
        XCTAssertEqual(Set(hits.map(\.stableID)).count, 4)
        XCTAssertEqual(hits[2].threadID, ThreadID("a-tie-thread"))
        XCTAssertEqual(hits[3].threadID, ThreadID("z-tie-thread"))
        XCTAssertLessThan(hits[2].stableID, hits[3].stableID)

        let payloads = try pages.dropLast().compactMap(\.nextCursor).map(Task5CursorMutation.object)
        for (page, payload) in zip(pages.dropLast(), payloads) {
            let hit = try XCTUnwrap(page.conversationHits.last)
            XCTAssertEqual(
                payload["stableID"] as? String,
                MailSearchStableIdentity.message(
                    accountID: hit.accountID,
                    messageID: hit.bestMatchingMessageID
                )
            )
            XCTAssertEqual(payload["conversationID"] as? String, hit.stableID)
            XCTAssertNotEqual(payload["stableID"] as? String, hit.stableID)
        }
    }

    func testConversationCursorUsesTheCompleteConversationTupleWithoutOverlap() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection((0 ..< 5).flatMap { index in
            [
                .init(
                    id: "best-\(index)",
                    threadID: "thread-\(index)",
                    subject: "Project \(index)",
                    sortDate: 100
                ),
                .init(
                    id: "latest-\(index)",
                    threadID: "thread-\(index)",
                    subject: "Other",
                    sortDate: Double(200 - index)
                ),
            ]
        })

        let first = try await fixture.searchConversations("project", limit: 2)
        let second = try await fixture.searchConversations("project", limit: 2, cursor: first.nextCursor)
        let third = try await fixture.searchConversations("project", limit: 2, cursor: second.nextCursor)

        XCTAssertEqual(first.hits.count, 2)
        XCTAssertEqual(second.hits.count, 2)
        XCTAssertEqual(third.hits.count, 1)
        XCTAssertTrue(Set(first.conversationIDs).isDisjoint(with: second.conversationIDs))
        XCTAssertEqual(Set(first.conversationIDs + second.conversationIDs + third.conversationIDs).count, 5)
        XCTAssertNil(third.nextCursor)

        await assertSearchError(.staleCursor) {
            _ = try await fixture.service.search(.init(
                query: "project",
                mode: .messages,
                limit: 2,
                cursor: first.nextCursor
            ))
        }
    }

    func testConversationCursorAuthenticatesActivityAndConversationIdentity() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertProjection([
            .init(id: "best-a", threadID: "thread-a", subject: "Project", sortDate: 100),
            .init(id: "latest-a", threadID: "thread-a", subject: "Other", sortDate: 200),
            .init(id: "best-b", threadID: "thread-b", subject: "Project", sortDate: 90),
        ])
        let first = try await fixture.searchConversations("project", limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)

        for (field, value) in [("activityDate", 0 as Any), ("conversationID", "forged" as Any)] {
            let tampered = try Task5CursorMutation.mutate(cursor, field: field, value: value)
            await assertSearchError(.invalidCursor) {
                _ = try await fixture.searchConversations("project", limit: 1, cursor: tampered)
            }
        }
    }

    func testConversationCompilerUsesOneRankedCandidateCTEAndNoOffsetOrFTSForStructuredOnlyQuery() throws {
        let parsed = try MailSearchQueryParser().parse("is:unread", now: Date(timeIntervalSince1970: 0))
        let compiled = try SQLiteMailSearchQueryCompiler().compile(
            parsed,
            request: .init(query: "is:unread", mode: .conversations, limit: 2),
            snippetMarkers: .init(nonce: "conversation-test")
        )

        XCTAssertTrue(compiled.sql.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(compiled.sql.contains("COUNT(*) OVER"))
        XCTAssertTrue(compiled.sql.contains("PARTITION BY account_id, conversation_id"))
        XCTAssertTrue(compiled.sql.contains("sort_date DESC, message_stable_id ASC"))
        XCTAssertEqual(
            compiled.cursorSortDescriptors,
            [
                "exact_tier DESC",
                "lexical_score DESC",
                "recency_score DESC",
                "sort_date DESC",
                "conversation_activity DESC",
                "conversation_id ASC",
            ]
        )
        XCTAssertEqual(compiled.sql.components(separatedBy: "ranked_candidates AS").count - 1, 1)
        XCTAssertFalse(compiled.sql.localizedCaseInsensitiveContains(" OFFSET "))
        XCTAssertFalse(compiled.sql.contains("mail_search_fts"))

        let paged = try SQLiteMailSearchQueryCompiler().compile(
            parsed,
            request: .init(query: "is:unread", mode: .conversations, limit: 2),
            cursor: .init(
                exactTier: 0,
                lexicalScore: 0,
                sortDate: 100,
                stableID: "message|61|7A",
                activityDate: 200,
                conversationID: "thread|61|74"
            ),
            snippetMarkers: .init(nonce: "conversation-test")
        )
        XCTAssertTrue(paged.sql.contains("sort_date = ? AND conversation_activity < ?"))
        XCTAssertTrue(
            paged.sql.contains(
                "sort_date = ? AND conversation_activity = ? AND conversation_id > ?"
            )
        )
        XCTAssertFalse(paged.sql.contains("stable_id > ?"))
    }

    func testIndexStateCollapsesPersistedAccountStatesBySeverity() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.setStates(["a1": "ready", "a2": "preparing"])
        var state = await fixture.service.indexState()
        XCTAssertEqual(state, .preparing)

        try fixture.setStates(["a1": "ready", "a2": "rebuilding"])
        state = await fixture.service.indexState()
        XCTAssertEqual(state, .rebuilding)

        try fixture.setStates(["a1": "rebuilding", "a2": "unavailable"])
        state = await fixture.service.indexState()
        XCTAssertEqual(state, .unavailable)
    }

    func testRebuildPublishesNoPartialReadyStateAndRepairsProjection() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertCanonicalMessage(id: "canonical", subject: "Restored project")
        try fixture.refreshProjection(messageID: "canonical")
        let before = try fixture.revision(accountID: "a1")
        try fixture.execute("UPDATE messages SET subject = 'Rebuilt project' WHERE id = 'canonical'")
        let pause = Task5SQLitePauseProbe()
        fixture.pauseRebuildAfterProjection(using: pause)

        let task = Task {
            defer { pause.rebuildFinished() }
            try await fixture.service.rebuildIndex()
        }
        guard await pause.waitUntilPausedOrFinished() else {
            do {
                try await task.value
                XCTFail("Rebuild finished before reaching the projection pause")
            } catch {
                XCTFail("Rebuild failed before projection pause: \(error); SQL: \(pause.statements)")
            }
            return
        }

        let rebuildingState = await fixture.service.indexState()
        XCTAssertEqual(rebuildingState, .rebuilding)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Restored project")

        pause.resume()
        try await task.value

        let readyState = await fixture.service.indexState()
        XCTAssertEqual(readyState, .ready)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Rebuilt project")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }

    func testRebuildFailureRollsBackProjectionAndNeverPublishesReady() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertCanonicalMessage(id: "canonical", subject: "Original")
        try fixture.refreshProjection(messageID: "canonical")
        let before = try fixture.revision(accountID: "a1")
        try fixture.execute("UPDATE messages SET subject = 'Partial', labels_json = 'not-json' WHERE id = 'canonical'")

        await assertSearchError(.unavailable) {
            try await fixture.service.rebuildIndex()
        }

        let failedState = await fixture.service.indexState()
        XCTAssertEqual(failedState, .unavailable)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Original")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before)

        try fixture.execute(
            "UPDATE messages SET subject = 'Ordinary write', labels_json = '[]' WHERE id = 'canonical'"
        )
        try fixture.refreshProjection(messageID: "canonical")

        let stateAfterOrdinaryWrite = await fixture.service.indexState()
        XCTAssertEqual(stateAfterOrdinaryWrite, .unavailable)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Ordinary write")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }

    func testCancelledRebuildLeavesNoPartialReadyState() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertCanonicalMessage(id: "canonical", subject: "Original")
        try fixture.refreshProjection(messageID: "canonical")
        try fixture.execute("UPDATE messages SET subject = 'Cancelled partial' WHERE id = 'canonical'")
        let pause = Task5SQLitePauseProbe()
        fixture.pauseRebuildAfterProjection(using: pause)

        let task = Task {
            defer { pause.rebuildFinished() }
            try await fixture.service.rebuildIndex()
        }
        guard await pause.waitUntilPausedOrFinished() else {
            _ = try? await task.value
            return XCTFail("Rebuild finished before reaching the projection pause")
        }
        task.cancel()
        pause.resume()

        await assertSearchError(.cancelled) {
            try await task.value
        }
        let cancelledState = await fixture.service.indexState()
        XCTAssertEqual(cancelledState, .unavailable)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Original")
    }

    func testCancellationAtReadyPublicationBoundaryRollsBackAndPublishesUnavailable() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertCanonicalMessage(id: "canonical", subject: "Original")
        try fixture.refreshProjection(messageID: "canonical")
        let before = try fixture.revision(accountID: "a1")
        try fixture.execute("UPDATE messages SET subject = 'Cancelled before ready' WHERE id = 'canonical'")
        let boundary = Task5BlockingProbe()
        let service = fixture.makeService(
            rebuildWillPublishReady: boundary.pause,
            rebuildDidCommitReady: {}
        )

        let task = Task { try await service.rebuildIndex() }
        await boundary.waitUntilPaused()

        let rebuildingState = await service.indexState()
        XCTAssertEqual(rebuildingState, .rebuilding)
        task.cancel()
        boundary.resume()

        await assertSearchError(.cancelled) {
            try await task.value
        }
        let unavailableState = await service.indexState()
        XCTAssertEqual(unavailableState, .unavailable)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Original")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before)
    }

    func testCancellationAfterReadyCommitDoesNotReinterpretCommittedSuccess() async throws {
        let fixture = try Task5SearchFixture()
        try fixture.insertCanonicalMessage(id: "canonical", subject: "Original")
        try fixture.refreshProjection(messageID: "canonical")
        let before = try fixture.revision(accountID: "a1")
        try fixture.execute("UPDATE messages SET subject = 'Committed ready' WHERE id = 'canonical'")
        let boundary = Task5BlockingProbe()
        let service = fixture.makeService(
            rebuildWillPublishReady: {},
            rebuildDidCommitReady: boundary.pause
        )

        let task = Task { try await service.rebuildIndex() }
        await boundary.waitUntilPaused()

        let committedState = await service.indexState()
        XCTAssertEqual(committedState, .ready)
        XCTAssertEqual(try fixture.projectionSubject(messageID: "canonical"), "Committed ready")
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
        task.cancel()
        boundary.resume()

        try await task.value
        let finalState = await service.indexState()
        XCTAssertEqual(finalState, .ready)
        XCTAssertEqual(try fixture.revision(accountID: "a1"), before + 1)
    }

    func testMaintenancePersistsTwentyFourHourOptimizeGuard() async throws {
        let fixture = try Task5SearchFixture()
        let initial = Date(timeIntervalSince1970: 2_000_000_000)

        try await fixture.service.performMaintenanceIfDue(now: initial)
        XCTAssertEqual(try fixture.lastOptimizationTime(), initial.timeIntervalSince1970)

        let restarted = fixture.makeService()
        try await restarted.performMaintenanceIfDue(now: initial.addingTimeInterval(23 * 60 * 60))
        XCTAssertEqual(try fixture.lastOptimizationTime(), initial.timeIntervalSince1970)

        let due = initial.addingTimeInterval(24 * 60 * 60)
        try await restarted.performMaintenanceIfDue(now: due)
        XCTAssertEqual(try fixture.lastOptimizationTime(), due.timeIntervalSince1970)
    }

    func testMaintenanceRepairsMissingGuardAndDoesNotPublishTimestampAfterFailure() async throws {
        let fixture = try Task5SearchFixture()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.execute("""
            DELETE FROM mail_search_maintenance;
            CREATE TRIGGER reject_search_maintenance
            BEFORE INSERT ON mail_search_maintenance BEGIN
                SELECT RAISE(ABORT, 'reject maintenance timestamp');
            END;
            """)

        await assertSearchError(.unavailable) {
            try await fixture.service.performMaintenanceIfDue(now: now)
        }
        XCTAssertNil(try fixture.lastOptimizationTime())

        try fixture.execute("DROP TRIGGER reject_search_maintenance")
        try await fixture.service.performMaintenanceIfDue(now: now)
        XCTAssertEqual(try fixture.lastOptimizationTime(), now.timeIntervalSince1970)
    }

    func testMaintenanceTreatsMalformedPersistedGuardsAsDueAndReplacesThemAfterOptimize() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let malformedSetups: [(String, (Task5SearchFixture) throws -> Void)] = [
            ("missing", { try $0.execute("DELETE FROM mail_search_maintenance") }),
            ("null", { try $0.execute("UPDATE mail_search_maintenance SET last_optimized_at = NULL") }),
            ("text", { try $0.execute("UPDATE mail_search_maintenance SET last_optimized_at = 'malformed'") }),
            ("nan", { try $0.setMaintenanceGuard(Double.nan) }),
            ("infinity", { try $0.setMaintenanceGuard(Double.infinity) }),
            ("negative", { try $0.setMaintenanceGuard(-1) }),
            ("future", { try $0.setMaintenanceGuard(now.timeIntervalSince1970 + 1) }),
        ]

        for (name, setup) in malformedSetups {
            let fixture = try Task5SearchFixture()
            try setup(fixture)
            let recorder = Task5SQLRecorder()
            fixture.recordSQL(using: recorder)

            try await fixture.service.performMaintenanceIfDue(now: now)

            XCTAssertEqual(
                recorder.statements.filter { $0 == "PRAGMA optimize" }.count,
                1,
                name
            )
            XCTAssertEqual(try fixture.maintenanceGuardStorageClass(), "real", name)
            XCTAssertEqual(try fixture.lastOptimizationTime(), now.timeIntervalSince1970, name)
        }
    }

    func testMaintenanceAcceptsOnlySaneRecentNumericGuard() async throws {
        let fixture = try Task5SearchFixture()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.execute(
            "UPDATE mail_search_maintenance SET last_optimized_at = 1999999999"
        )
        let recorder = Task5SQLRecorder()
        fixture.recordSQL(using: recorder)

        try await fixture.service.performMaintenanceIfDue(now: now)

        XCTAssertEqual(try fixture.maintenanceGuardStorageClass(), "real")
        XCTAssertEqual(try fixture.lastOptimizationTime(), 1_999_999_999)
        XCTAssertFalse(recorder.statements.contains { $0 == "PRAGMA optimize" })
    }

    func testMaintenanceOptimizeFailurePreservesMalformedGuard() throws {
        enum ExpectedFailure: Error { case optimize }

        let fixture = try Task5SearchFixture()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.execute(
            "UPDATE mail_search_maintenance SET last_optimized_at = 'malformed'"
        )
        let before = try fixture.rawMaintenanceGuard()

        XCTAssertThrowsError(try fixture.store.databasePool.write { database in
            try SQLiteMailSearchSchema.performMaintenanceIfDue(
                database,
                now: now,
                optimize: { _ in throw ExpectedFailure.optimize }
            )
        }) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }

        XCTAssertEqual(try fixture.rawMaintenanceGuard(), before)
    }

    func testMaintenanceOptimizerFailureIsObservableAndPrivacySafe() async throws {
        enum SensitiveOptimizerFailure: Error { case privateDatabaseDetails }

        let fixture = try Task5SearchFixture()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fixture.execute(
            "UPDATE mail_search_maintenance SET last_optimized_at = 'malformed'"
        )
        let before = try fixture.rawMaintenanceGuard()
        let service = fixture.makeService(
            maintenanceOptimize: { _ in throw SensitiveOptimizerFailure.privateDatabaseDetails }
        )

        await assertSearchError(.unavailable) {
            try await service.performMaintenanceIfDue(now: now)
        }
        XCTAssertEqual(try fixture.rawMaintenanceGuard(), before)
    }

    func testSearchPreparationRunsRequestedOptimizeMaskWithoutCacheOrMmapChanges() throws {
        let queue = try DatabaseQueue()
        let recorder = Task5SQLRecorder()
        try queue.writeWithoutTransaction { database in
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                recorder.append(statement.sql)
            }
            try SQLiteMailSearchSchema.prepareDatabase(database)
        }

        XCTAssertTrue(recorder.statements.contains { $0 == "PRAGMA optimize=0x10002" })
        XCTAssertFalse(recorder.statements.contains { $0.localizedCaseInsensitiveContains("cache_size") })
        XCTAssertFalse(recorder.statements.contains { $0.localizedCaseInsensitiveContains("mmap_size") })
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

struct Task5SearchDocument {
    let id: String
    var threadID: String? = nil
    var accountID = "a1"
    var mailboxIDs = "mb-inbox"
    var mailboxNames = "Inbox"
    var senderEmail = "sender@example.com"
    var senderDisplayName: String? = "Sender"
    var to = "recipient@example.com"
    var cc = ""
    var bcc = ""
    var subject = ""
    var preview = ""
    var body = ""
    var sortDate: Double = 0
    var isSeen = true
    var hasAttachments = false
    var hasDocuments = false
}

final class Task5SearchFixture: @unchecked Sendable {
    let directory: URL
    let store: SQLiteMailStore
    let service: SQLiteMailSearchService

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-task5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.migrate()
        service = SQLiteMailSearchService(
            store: store,
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            cursorAuthenticationKey: Data(repeating: 0x55, count: 32),
            snippetMarkerNonce: { "task5" }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeService(
        rebuildWillPublishReady: @escaping @Sendable () -> Void = {},
        rebuildDidCommitReady: @escaping @Sendable () -> Void = {},
        maintenanceOptimize: @escaping @Sendable (Database) throws -> Void = {
            try $0.execute(sql: "PRAGMA optimize")
        }
    ) -> SQLiteMailSearchService {
        SQLiteMailSearchService(
            store: store,
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            cursorAuthenticationKey: Data(repeating: 0x55, count: 32),
            snippetMarkerNonce: { "task5" },
            rebuildWillPublishReady: rebuildWillPublishReady,
            rebuildDidCommitReady: rebuildDidCommitReady,
            maintenanceOptimize: maintenanceOptimize
        )
    }

    func insertProjection(_ documents: [Task5SearchDocument]) throws {
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
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '', '', ?, ?, ?, 0, 0, 0, 0, 1, 0, ?, ?)
                        """,
                    arguments: [
                        document.id, document.threadID, document.accountID,
                        document.sortDate, document.sortDate,
                        [document.senderDisplayName, document.senderEmail].compactMap { $0 }.joined(separator: " "),
                        document.senderEmail, document.senderDisplayName,
                        document.to, document.cc, document.bcc,
                        document.subject, document.preview, document.body,
                        document.mailboxIDs, document.mailboxNames, document.isSeen,
                        document.hasAttachments, document.hasDocuments,
                    ]
                )
            }
        }
    }

    func searchConversations(
        _ query: String,
        scope: MailSearchSelectionScope = .init(),
        limit: Int = 50,
        cursor: MailSearchCursor? = nil
    ) async throws -> MailSearchResponse {
        try await service.search(.init(
            query: query,
            scope: scope,
            mode: .conversations,
            limit: limit,
            cursor: cursor
        ))
    }

    func setStates(_ states: [String: String]) throws {
        try store.databasePool.write { database in
            try database.execute(sql: "DELETE FROM mail_search_state")
            for (accountID, state) in states {
                try database.execute(
                    sql: "INSERT INTO mail_search_state(account_id, revision, state, updated_at) VALUES (?, 1, ?, 0)",
                    arguments: [accountID, state]
                )
            }
        }
    }

    func insertCanonicalMessage(id: String, subject: String) throws {
        try store.databasePool.write { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO accounts(
                    id, display_name, email, username, sent_mailbox,
                    imap_host, imap_port, smtp_host, smtp_port
                ) VALUES ('a1', 'Account', 'owner@example.com', 'owner', 'Sent',
                          'imap.example.com', 993, 'smtp.example.com', 587);
                INSERT INTO messages(
                    id, account_id, thread_id, from_email, from_display_name,
                    subject, preview, body_text, smart_category, labels_json,
                    is_seen, mailbox_path, is_deleted, sent_at, to_emails, cc_emails
                ) VALUES (?, 'a1', 'canonical-thread', 'sender@example.com', 'Sender',
                          ?, ?, '', 'personal', '[]', 1, 'INBOX', 0, 100, '', '');
                """, arguments: [id, subject, subject])
        }
    }

    func refreshProjection(messageID: String) throws {
        try store.databasePool.write { database in
            try SQLiteMailSearchProjectionWriter.refresh(
                messageID: MessageID(messageID),
                database: database
            )
        }
    }

    func execute(_ sql: String) throws {
        try store.databasePool.write { database in
            try database.execute(sql: sql)
        }
    }

    func pauseRebuildAfterProjection(using probe: Task5SQLitePauseProbe) {
        store.databasePool.writeWithoutTransaction { database in
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                probe.observe(statement.sql)
            }
        }
    }

    func recordSQL(using recorder: Task5SQLRecorder) {
        store.databasePool.writeWithoutTransaction { database in
            database.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                recorder.append(statement.sql)
            }
        }
    }

    func setMaintenanceGuard(_ value: Double) throws {
        try store.databasePool.write { database in
            try database.execute(
                sql: "UPDATE mail_search_maintenance SET last_optimized_at = ?",
                arguments: [value]
            )
        }
    }

    func maintenanceGuardStorageClass() throws -> String? {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT typeof(last_optimized_at) FROM mail_search_maintenance WHERE singleton = 1"
            )
        }
    }

    func rawMaintenanceGuard() throws -> String? {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT typeof(last_optimized_at) || ':' || quote(last_optimized_at)
                    FROM mail_search_maintenance WHERE singleton = 1
                    """
            )
        }
    }

    func projectionSubject(messageID: String) throws -> String? {
        try store.databasePool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT subject FROM mail_search_documents WHERE message_id = ?",
                arguments: [messageID]
            )
        }
    }

    func revision(accountID: String) throws -> Int {
        try store.databasePool.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT revision FROM mail_search_state WHERE account_id = ?",
                arguments: [accountID]
            ) ?? -1
        }
    }

    func lastOptimizationTime() throws -> Double? {
        try store.databasePool.read { database in
            try Double.fetchOne(
                database,
                sql: "SELECT last_optimized_at FROM mail_search_maintenance WHERE singleton = 1"
            )
        }
    }
}

private extension MailSearchResponse {
    var conversationHits: [MailConversationSearchHit] {
        hits.compactMap {
            guard case .conversation(let hit) = $0 else { return nil }
            return hit
        }
    }

    var conversationIDs: [String] {
        conversationHits.map { "\($0.accountID.rawValue)|\($0.threadID.rawValue)" }
    }
}

final class Task5SQLitePauseProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isPaused = false
    private var isFinished = false
    private var shouldResume = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var recordedStatements: [String] = []

    var statements: [String] {
        condition.withLock { recordedStatements }
    }

    func waitUntilPausedOrFinished() async -> Bool {
        await withCheckedContinuation { continuation in
            condition.lock()
            if isPaused || isFinished {
                let result = isPaused
                condition.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func observe(_ sql: String) {
        condition.lock()
        recordedStatements.append(sql)
        guard sql.contains("mail_search_fts(mail_search_fts) VALUES('rebuild')") else {
            condition.unlock()
            return
        }
        isPaused = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume(returning: true) }
        while !shouldResume { condition.wait() }
        condition.unlock()
    }

    func rebuildFinished() {
        condition.lock()
        isFinished = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        condition.unlock()
        for waiter in pending { waiter.resume(returning: false) }
    }

    func resume() {
        condition.lock()
        shouldResume = true
        condition.broadcast()
        condition.unlock()
    }
}

final class Task5SQLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var statements: [String] { lock.withLock { storage } }

    func append(_ sql: String) {
        lock.withLock { storage.append(sql) }
    }
}

final class Task5BlockingProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isPaused = false
    private var shouldResume = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() {
        condition.lock()
        isPaused = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
        while !shouldResume { condition.wait() }
        condition.unlock()
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if isPaused {
                condition.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func resume() {
        condition.lock()
        shouldResume = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum Task5CursorMutation {
    static func object(_ cursor: MailSearchCursor) throws -> [String: Any] {
        let data = try XCTUnwrap(decode(cursor.rawValue))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func mutate(
        _ cursor: MailSearchCursor,
        field: String,
        value: Any
    ) throws -> MailSearchCursor {
        var object = try object(cursor)
        XCTAssertNotNil(object[field])
        object[field] = value
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MailSearchCursor(rawValue: encode(mutated))
    }

    private static func decode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
