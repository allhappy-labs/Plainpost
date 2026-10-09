import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostTestSupport

final class IMAPSyncCacheTests: XCTestCase {
    func testCompleteImportCachesArrivalBeforeHeldOldInboxHistoryCompletes() async throws {
        try await assertFreshArrivalDuringHistory(mailbox: "INBOX")
    }

    func testCompleteImportCachesInboxArrivalWhileArchiveHistoryIsHeld() async throws {
        try await assertFreshArrivalDuringHistory(mailbox: "Archive")
    }

    private func assertFreshArrivalDuringHistory(mailbox: String) async throws {
        let (store, url, credentials) = try freshnessStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let held = expectation(description: "Second old history fetch reached")
        let gate = HistoryFreshnessFetchGate(held: held)
        let client = HistoryFreshnessIMAPClient(
            uids: mailbox == "INBOX" ? ["INBOX": [1, 2, 3, 4, 5]]
                : ["INBOX": [5], "Archive": [1, 2, 3]],
            arrivalTrigger: "\(mailbox):1", arrivalUIDs: [6],
            heldHeader: "\(mailbox):2", gate: gate
        )
        let task = Task {
            try await IMAPSyncService(client: client, cache: store).syncInbox(
                credentials: credentials,
                options: .init(
                    mailboxPaths: mailbox == "INBOX" ? ["INBOX"] : ["Archive", "INBOX"],
                    recentMessageLimit: 2, downloadCompleteHistory: true, batchSize: 1
                )
            )
        }
        await fulfillment(of: [held], timeout: 5)
        let fetchedWhileHeld = await client.fetchedHeaders
        XCTAssertEqual(fetchedWhileHeld.first, "INBOX:5@7", "Newest inbox mail must precede old history")
        XCTAssertTrue(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ).contains(6), "Arrival after SEARCH must be committed while old history is held")
        XCTAssertFalse(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: mailbox, uidValidity: 7
        ).contains(2))
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.source, .historicalBackfill)
        XCTAssertTrue(try store.macNewMailEvents(accountID: credentials.accountID).isEmpty)
        let finalUIDs = try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        )
        XCTAssertEqual(finalUIDs, mailbox == "INBOX" ? Set(1...6) : Set([5, 6]))
        let fetched = await client.fetchedHeaders
        XCTAssertEqual(fetched.count, Set(fetched).count, "Probe commits must not be fetched again as history")
        if mailbox == "Archive" {
            XCTAssertEqual(try store.cachedUIDs(
                accountID: credentials.accountID, mailboxPath: "Archive", uidValidity: 7
            ), Set([1, 2, 3]))
        }
    }

    func testCompleteImportFreshProbeIsFiniteAndHistoryKeepsAdvancing() async throws {
        let (store, url, credentials) = try freshnessStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HistoryFreshnessIMAPClient(
            uids: ["INBOX": Array(1...6)], arrivalsPerProbe: 2, maximumArrivalProbes: 4
        )
        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: credentials,
            options: .init(recentMessageLimit: 1, downloadCompleteHistory: true, batchSize: 1)
        )
        let fetched = await client.fetchedHeaders
        let probes = await client.freshProbeCount
        let allUIDs = await client.inboxUIDs
        XCTAssertGreaterThanOrEqual(probes, 4)
        XCTAssertEqual(fetched.first, "INBOX:6@7")
        XCTAssertLessThanOrEqual(try XCTUnwrap(fetched.firstIndex(of: "INBOX:3@7")), 6)
        XCTAssertEqual(fetched.count, Set(fetched).count)
        XCTAssertEqual(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ), Set(allUIDs), "Discovered but initially deferred arrivals must eventually be committed")
    }

    func testCompleteImportFinishesCapturedWorkWithoutChasingContinuingArrivalsForever() async throws {
        let (store, url, credentials) = try freshnessStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // More arrivals remain available on every subsequent search. The
        // test's finite cap bounds a broken implementation rather than hanging.
        let client = HistoryFreshnessIMAPClient(
            uids: ["INBOX": Array(1...6)], arrivalsPerProbe: 2, maximumArrivalProbes: 25
        )
        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: credentials,
            options: .init(recentMessageLimit: 1, downloadCompleteHistory: true, batchSize: 1)
        )
        let probes = await client.freshProbeCount
        let discovered = await client.inboxUIDs
        XCTAssertLessThanOrEqual(probes, 7, "Six original messages plus one final discovery must form a finite pass")
        XCTAssertGreaterThan(probes, 0)
        XCTAssertEqual(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ), Set(discovered), "All actually discovered pending UIDs must complete before the pass returns")
    }

    func testCompleteImportRetryRetainsOldHolesAfterNewestMailWasCommitted() async throws {
        let (store, url, credentials) = try freshnessStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let failing = HistoryFreshnessIMAPClient(uids: ["INBOX": Array(1...5)], failedBody: "INBOX:1")
        do {
            _ = try await IMAPSyncService(client: failing, cache: store).syncInbox(
                credentials: credentials,
                options: .init(recentMessageLimit: 2, downloadCompleteHistory: true, batchSize: 1)
            )
            XCTFail("Expected controlled history body failure")
        } catch {}
        XCTAssertEqual(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ), Set([4, 5]))
        let retry = HistoryFreshnessIMAPClient(uids: ["INBOX": Array(1...5)])
        _ = try await IMAPSyncService(client: retry, cache: store).syncInbox(
            credentials: credentials,
            options: .init(recentMessageLimit: 2, downloadCompleteHistory: true, batchSize: 1)
        )
        XCTAssertEqual(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ), Set(1...5))
        let fetched = await retry.fetchedHeaders
        XCTAssertEqual(Set(fetched), Set(["INBOX:1@7", "INBOX:2@7", "INBOX:3@7"]))
    }

    func testCompleteImportRejectsUidValidityRolloverOnFreshProbeAndArchiveRestore() async throws {
        for rolloverMailbox in ["INBOX", "Archive"] {
            let (store, url, credentials) = try freshnessStore()
            defer { try? FileManager.default.removeItem(at: url) }
            let client = HistoryFreshnessIMAPClient(
                uids: ["INBOX": [5], "Archive": [1, 2, 3]],
                arrivalTrigger: "Archive:1", arrivalUIDs: [6], rolloverOnReselect: rolloverMailbox
            )
            do {
                _ = try await IMAPSyncService(client: client, cache: store).syncInbox(
                    credentials: credentials,
                    options: .init(mailboxPaths: ["Archive", "INBOX"], downloadCompleteHistory: true, batchSize: 1)
                )
                XCTFail("Must reject changed UID namespace before fetching captured UIDs")
            } catch {
                XCTAssertTrue(error is IMAPClientError)
            }
            let fetched = await client.fetchedHeaders
            XCTAssertFalse(fetched.contains { $0.hasSuffix("@8") })
        }
    }

    func testCompleteImportNeverProbesAnUnselectedInbox() async throws {
        let (store, url, credentials) = try freshnessStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HistoryFreshnessIMAPClient(uids: ["INBOX": [5], "Archive": [1, 2]])
        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: credentials,
            options: .init(mailboxPaths: ["Archive"], downloadCompleteHistory: true, batchSize: 1)
        )
        let selections = await client.selections
        XCTAssertFalse(selections.contains("INBOX"))
        XCTAssertEqual(try store.cachedUIDs(
            accountID: credentials.accountID, mailboxPath: "INBOX", uidValidity: 7
        ), [])
    }

    private func freshnessStore() throws -> (SQLiteMailStore, URL, IMAPAccountCredentials) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-history-freshness-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        return (store, url, IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id, email: PlainpostFixtures.personalAccount.email,
            username: "synthetic@example.test", password: "synthetic-fixture"
        ))
    }

    func testAttachmentDecodeFailurePreservesPriorCanonicalRowsAndRetriesUID() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-attachment-retry-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id,
            email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com",
            password: "secret"
        )
        let header = """
            From: alice@example.com\r
            Subject: Preserve attachment\r
            Message-ID: <preserve-attachment@example.test>\r
            Date: Thu, 9 Jul 2026 12:00:00 +0000\r
            """
        let validBody = """
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="original.bin"\r
            Content-Transfer-Encoding: base64\r
            \r
            b3JpZ2luYWw=\r
            """
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(
                uids: [1],
                uidValidity: 7,
                header: header,
                body: validBody
            ),
            cache: store
        ).syncInbox(credentials: credentials)

        let messageID = MessageID(IMAPSyncService.canonicalMessageID(
            accountID: credentials.accountID,
            rfcMessageID: "<preserve-attachment@example.test>"
        ))
        let originalAttachments = try store.incomingMessageAttachments(messageID: messageID)
        XCTAssertEqual(originalAttachments.map(\.data), [Data("original".utf8)])

        let unsupportedBody = """
            Content-Type: application/octet-stream\r
            Content-Disposition: attachment; filename="replacement.bin"\r
            Content-Transfer-Encoding: x-custom-compression\r
            \r
            replacement\r
            """
        do {
            _ = try await IMAPSyncService(
                client: DiscoveredUIDIMAPClient(
                    uids: [1, 2],
                    uidValidity: 7,
                    header: header,
                    body: unsupportedBody
                ),
                cache: store
            ).syncInbox(credentials: credentials)
            XCTFail("Expected attachment decoding failure to abort the refresh.")
        } catch {
            XCTAssertEqual(error as? MIMEAttachmentDecodingError, .malformedMessage)
        }

        XCTAssertEqual(
            try store.incomingMessageAttachments(messageID: messageID),
            originalAttachments
        )
        XCTAssertEqual(
            try store.cachedUIDs(
                accountID: credentials.accountID,
                mailboxPath: "INBOX",
                uidValidity: 7
            ),
            Set([1])
        )
    }

    func testUIDValidityResetIsSilentAndDoesNotMixGenerations() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-uidvalidity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id,
            email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com",
            password: "secret"
        )
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 1),
            cache: store
        ).syncInbox(credentials: credentials)

        let result = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 2),
            cache: store
        ).syncInbox(
            credentials: credentials,
            options: IMAPSyncOptions(incrementalOnly: true)
        )

        XCTAssertEqual(result.source, .incremental)
        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(result.newlyDiscoveredMessageCount, 0)
        XCTAssertEqual(store.threads.count, 1)
    }

    func testIncrementalInboxSyncPersistsMacNotificationEventWithoutRemoteProducerSelection() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mac-notification-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id,
            email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com",
            password: "secret"
        )
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7),
            cache: store
        ).syncInbox(credentials: credentials)

        let arrival = Date().addingTimeInterval(-1)
        let result = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(
                uids: [1, 2], uidValidity: 7, internalDate: arrival
            ),
            cache: store
        ).syncInbox(
            credentials: credentials,
            options: IMAPSyncOptions(incrementalOnly: true)
        )

        XCTAssertEqual(result.source, .incremental)
        XCTAssertEqual(result.newlyDiscoveredMessageCount, 1)
        let event = try XCTUnwrap(
            store.macNewMailEvents(accountID: credentials.accountID).first
        )
        XCTAssertEqual(event.state, .awaitingRules)
        XCTAssertEqual(event.providerArrivalAt.timeIntervalSince1970,
                       arrival.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    /// The iPhone's background refresh can run hours apart, so it widens the window in which
    /// an Inbox arrival still notifies; the Mac keeps 15 minutes.
    func testNewMailNotificationWindowDecidesWhetherAnOlderArrivalNotifies() async throws {
        XCTAssertEqual(SQLiteMailStore.newMailNotificationWindow, 15 * 60)
        let twoHoursAgo = Date().addingTimeInterval(-2 * 60 * 60)
        let silent = try await incrementalArrivalEvents(arrival: twoHoursAgo)
        XCTAssertTrue(silent.isEmpty)

        SQLiteMailStore.newMailNotificationWindow = 24 * 60 * 60
        defer { SQLiteMailStore.newMailNotificationWindow = 15 * 60 }
        let events = try await incrementalArrivalEvents(arrival: twoHoursAgo)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.expiresAt.timeIntervalSince1970,
                       twoHoursAgo.timeIntervalSince1970 + 24 * 60 * 60,
                       accuracy: 0.001)
    }

    private func incrementalArrivalEvents(arrival: Date) async throws -> [MacNewMailEventRecord] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-notification-window-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id,
            email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com",
            password: "secret"
        )
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7),
            cache: store
        ).syncInbox(credentials: credentials)
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1, 2], uidValidity: 7, internalDate: arrival),
            cache: store
        ).syncInbox(credentials: credentials, options: IMAPSyncOptions(incrementalOnly: true))
        return try store.macNewMailEvents(accountID: credentials.accountID)
    }

    func testSyncInboxCachesMailboxAndFetchedMessage() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let store = InMemoryMailStore()
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        let service = IMAPSyncService(client: client, cache: store)
        let progress = SyncProgressRecorder()

        let result = try await service.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            ),
            progress: { event in
                await progress.record(event)
            }
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(store.mailboxes.map(\.path), ["INBOX"])
        XCTAssertEqual(store.messages.map(\.from), [EmailAddress("alice@example.com")])
        XCTAssertEqual(store.messages.map(\.subject), ["Availability"])
        XCTAssertEqual(store.messages.map(\.preview), ["Can you meet next Tuesday?"])
        XCTAssertEqual(store.messages.map(\.smartCategory), [.personal])
        XCTAssertEqual(
            store.messages.first?.sentAt,
            Calendar(identifier: .gregorian).date(from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 7,
                day: 8
            ))
        )
        let events = await progress.events
        XCTAssertEqual(events.first, .connecting)
        XCTAssertTrue(events.contains(.discoveringMailboxes))
        XCTAssertTrue(events.contains(.discoveringMessages))
        XCTAssertEqual(
            events.last,
            .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 1, total: 1)
        )
    }

    func testMultiMailboxProgressNeverPairsCumulativeCurrentWithMailboxTotal() async throws {
        let client = MultiMailboxProgressIMAPClient(
            uidsByMailbox: ["INBOX": [1, 2], "Archive": [10]]
        )
        let store = InMemoryMailStore()
        let recorder = SyncProgressRecorder()

        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: EmailAddress("me@example.com"),
                username: "me@example.com",
                password: "secret"
            ),
            options: IMAPSyncOptions(mailboxPaths: ["INBOX", "Archive"])
        ) { event in
            await recorder.record(event)
        }

        let events = await recorder.events
        let mailboxEvents = events.compactMap { event -> IMAPSyncProgress? in
            if case .syncingMailbox = event { return event }
            return nil
        }
        XCTAssertEqual(mailboxEvents, [
            .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 0, total: 2),
            .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 1, total: 2),
            .syncingMailbox(path: "INBOX", phase: "recent-import", completed: 2, total: 2),
            .syncingMailbox(path: "Archive", phase: "recent-import", completed: 0, total: 1),
            .syncingMailbox(path: "Archive", phase: "recent-import", completed: 1, total: 1),
        ])
        XCTAssertFalse(events.contains { event in
            if case .downloading = event { return true }
            return false
        })
    }

    func testSyncInboxUsesDiscoveredUIDsInsteadOfAssumingUIDOne() async throws {
        let store = InMemoryMailStore()
        let client = DiscoveredUIDIMAPClient(uids: [42])
        let service = IMAPSyncService(client: client, cache: store)

        let result = try await service.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(client.fetchedHeaderUIDs, [42])
        XCTAssertEqual(client.fetchedBodyUIDs, [42])
        XCTAssertEqual(store.messages.map(\.id.rawValue), ["msg_acc_personal_inbox_0_42"])
        XCTAssertEqual(store.messages.compactMap(\.threadID?.rawValue).count, 1)
        XCTAssertEqual(store.messages.map(\.subject), ["Discovered UID 42"])
    }

    func testRecentSyncDefaultsToNewestOneHundredMessages() async throws {
        let store = InMemoryMailStore()
        let client = DiscoveredUIDIMAPClient(uids: Array(1...150))
        let service = IMAPSyncService(client: client, cache: store)

        let result = try await service.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 100)
        XCTAssertEqual(client.fetchedHeaderUIDs, Array(51...150))
        XCTAssertEqual(client.fetchedBodyUIDs, Array(51...150))
    }

    func testCompleteHistorySyncDownloadsEveryDiscoveredUID() async throws {
        let store = InMemoryMailStore()
        let client = DiscoveredUIDIMAPClient(uids: Array(1...125))
        let service = IMAPSyncService(client: client, cache: store)

        let result = try await service.syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            ),
            options: IMAPSyncOptions(downloadCompleteHistory: true, batchSize: 20)
        )

        XCTAssertEqual(result.syncedMessageCount, 125)
        let expected = Array((26...125).reversed()) + Array(1...25)
        XCTAssertEqual(client.fetchedHeaderUIDs, expected)
        XCTAssertEqual(client.fetchedBodyUIDs, expected)
    }

    func testSyncDeletesTaggedVerificationMessageWithoutCachingOrCounting() async throws {
        let email = EmailAddress("me@example.com")
        let message = AccountVerificationMessage(
            accountEmail: email,
            identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let client = VerificationMessageIMAPClient(data: message.smtpData)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-verification-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: email,
                username: "custom-login",
                password: "secret"
            ),
            options: IMAPSyncOptions(notificationEligible: true)
        )

        XCTAssertEqual(result.syncedMessageCount, 0)
        XCTAssertEqual(result.newlyDiscoveredMessageCount, 0)
        XCTAssertEqual(client.deletedUIDs, [42])
        XCTAssertTrue(store.messages.isEmpty)
        let searchResponse = try await SQLiteMailSearchService(store: store).search(
            .init(query: "\"Plainpost account verification\"", mode: .messages)
        )
        XCTAssertTrue(searchResponse.hits.isEmpty)
    }

    func testSyncDeletesTaggedVerificationMessageStoredWithSMTPLineEnding() async throws {
        // SMTP DATA ends the body's last line with CRLF, so the server stores
        // the verification body with one trailing line ending.
        let email = EmailAddress("me@example.com")
        let message = AccountVerificationMessage(accountEmail: email)
        let client = VerificationMessageIMAPClient(data: message.smtpData + "\r\n")
        let store = InMemoryMailStore()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: email,
                username: "custom-login",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 0)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(client.deletedUIDs, [42])
    }

    func testSyncStillSuppressesTaggedVerificationMessageWhenRemoteDeleteFails() async throws {
        let email = EmailAddress("me@example.com")
        let message = AccountVerificationMessage(accountEmail: email)
        let client = VerificationMessageIMAPClient(data: message.smtpData, deleteFails: true)
        let store = InMemoryMailStore()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: email,
                username: "custom-login",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 0)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(client.deleteAttempts, [42])
    }

    func testSyncKeepsTaggedVerificationMessageWithLeadingBodyWhitespace() async throws {
        let email = EmailAddress("me@example.com")
        let message = AccountVerificationMessage(accountEmail: email)
        let data = message.smtpData.replacingOccurrences(
            of: AccountVerificationMessage.body,
            with: "  \(AccountVerificationMessage.body)"
        )
        let client = VerificationMessageIMAPClient(data: data)
        let store = InMemoryMailStore()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: email,
                username: "custom-login",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertTrue(client.deleteAttempts.isEmpty)
    }

    func testSyncKeepsTaggedVerificationMessageWithTrailingBodyWhitespaceAndNewlines() async throws {
        let email = EmailAddress("me@example.com")
        let message = AccountVerificationMessage(accountEmail: email)
        let data = message.smtpData.replacingOccurrences(
            of: AccountVerificationMessage.body,
            with: "\(AccountVerificationMessage.body)  \r\n\r\n"
        )
        let client = VerificationMessageIMAPClient(data: data)
        let store = InMemoryMailStore()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: email,
                username: "custom-login",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertTrue(client.deleteAttempts.isEmpty)
    }

    func testSyncKeepsSameSubjectAndBodyWithoutPrivateMarker() async throws {
        let data = """
        From: <me@example.com>\r
        To: <me@example.com>\r
        Subject: Plainpost account verification\r
        Message-ID: <ordinary@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Testing local SMTP credentials.
        """
        let client = VerificationMessageIMAPClient(data: data)
        let store = InMemoryMailStore()

        let result = try await IMAPSyncService(client: client, cache: store).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: AccountID("acc_me_example_com"),
                email: EmailAddress("me@example.com"),
                username: "custom-login",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(store.messages.map(\.subject), [AccountVerificationMessage.subject])
        XCTAssertTrue(client.deleteAttempts.isEmpty)
    }

    func testMessageParserStripsIMAPFetchFramingAndKeepsConcisePreview() {
        let parsed = IMAPMessageParser.parse(
            header: "* 7 FETCH (BODY[HEADER] {93}\r\nFrom: Example Sender <sender@example.com>\r\nSubject: A useful update\r\nDate: Thu, 9 Jul 2026\r\n\r\n)",
            body: "* 7 FETCH (BODY[] {122}\r\nFrom: Example Sender <sender@example.com>\r\nSubject: A useful update\r\n\r\nThis is the message body.\r\n)"
        )

        XCTAssertEqual(parsed.from, EmailAddress("sender@example.com"))
        XCTAssertEqual(parsed.fromDisplayName, "Example Sender")
        XCTAssertEqual(parsed.subject, "A useful update")
        XCTAssertEqual(parsed.preview, "This is the message body.")
        XCTAssertEqual(
            parsed.sentAt,
            Calendar(identifier: .gregorian).date(from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 7,
                day: 9
            ))
        )
    }

    func testMessageParserDecodesSenderDisplayName() {
        let parsed = IMAPMessageParser.parse(
            header: "From: =?UTF-8?B?SsO8cmdlbiBNw7xsbGVy?= <jurgen@example.com>\r\nSubject: Hello\r\n",
            body: "Body"
        )

        XCTAssertEqual(parsed.from, EmailAddress("jurgen@example.com"))
        XCTAssertEqual(parsed.fromDisplayName, "Jürgen Müller")
    }

    func testMessageParserPreservesReplyRecipientsAndRFCAncestry() {
        let parsed = IMAPMessageParser.parse(
            header: "From: Alice <alice@example.com>\r\nReply-To: Project <project@example.com>\r\nTo: me@example.com\r\nCc: team@example.com\r\nMessage-ID: <reply@example.com>\r\nIn-Reply-To: <root@example.com>\r\nReferences: <older@example.com> <root@example.com>\r\nSubject: Re: Project\r\n",
            body: "Body"
        )

        XCTAssertEqual(parsed.replyTo, EmailAddress("project@example.com"))
        XCTAssertEqual(parsed.to, [EmailAddress("me@example.com")])
        XCTAssertEqual(parsed.cc, [EmailAddress("team@example.com")])
        XCTAssertEqual(parsed.messageID, "<reply@example.com>")
        XCTAssertEqual(parsed.inReplyTo, "<root@example.com>")
        XCTAssertEqual(parsed.references, ["<older@example.com>", "<root@example.com>"])
    }

    func testThreadIdentityUsesReplyAncestryAndNormalizesReplySubject() {
        let root = IMAPMessageParser.parse(
            header: "From: alice@example.com\r\nMessage-ID: <root@example.com>\r\nSubject: Project update\r\n",
            body: "Root"
        )
        let reply = IMAPMessageParser.parse(
            header: "From: me@example.com\r\nMessage-ID: <reply@example.com>\r\nIn-Reply-To: <root@example.com>\r\nReferences: <root@example.com>\r\nSubject: Re: Project update\r\n",
            body: "Reply"
        )

        let rootID = MailThreading.threadID(
            accountID: AccountID("acc_test"),
            messageID: root.messageID,
            inReplyTo: root.inReplyTo,
            references: root.references,
            subject: root.subject,
            sender: root.from
        )
        let replyID = MailThreading.threadID(
            accountID: AccountID("acc_test"),
            messageID: reply.messageID,
            inReplyTo: reply.inReplyTo,
            references: reply.references,
            subject: reply.subject,
            sender: reply.from
        )

        XCTAssertEqual(rootID, replyID)
        XCTAssertEqual(MailThreading.normalizedSubject("Re: Fwd: Project update"), "project update")
    }

    func testMessageParserPreservesRFC5322DateWithTimezone() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Dated message\r\nDate: Thu, 9 Jul 2026 10:24:00 +0200\r\n",
            body: "Dated message body"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 8, minute: 24))

        XCTAssertEqual(parsed.sentAt, expected)
    }

    func testMessageParserLeavesMissingAndMalformedDatesUnavailable() {
        let missingDate = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: No date\r\n",
            body: "Body"
        )
        let malformedDate = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Bad date\r\nDate: not-a-date\r\n",
            body: "Body"
        )

        XCTAssertNil(missingDate.sentAt)
        XCTAssertNil(malformedDate.sentAt)
    }

    func testMessageParserDecodesEncodedSubjectAndMultipartQuotedPrintableBody() {
        let encodedSubject = "=?UTF-8?B?0J/RgNC40LLQtdGC?="
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: \(encodedSubject)\r\n",
            body: """
            From: sender@example.com
            Subject: \(encodedSubject)
            Content-Type: multipart/signed; boundary="Signed-F0A"

            --Signed-F0A
            Content-Type: multipart/alternative; boundary="Alternative-b1_Case"

            --Alternative-b1_Case
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            <p>Fallback =D1=82=D0=B5=D0=BA=D1=81=D1=82</p>
            --Alternative-b1_Case
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hello =D0=BC=D0=B8=D1=80
            --Alternative-b1_Case--
            --Signed-F0A
            Content-Type: application/pkcs7-signature
            Content-Transfer-Encoding: base64

            c2lnbmF0dXJl
            --Signed-F0A--
            """
        )

        XCTAssertEqual(parsed.subject, "Привет")
        XCTAssertEqual(parsed.preview, "Hello мир")
        XCTAssertTrue(parsed.bodyHTML?.contains("<p>Fallback текст</p>") == true)
        XCTAssertFalse(parsed.preview.contains("Content-Type"))
        XCTAssertFalse(parsed.preview.contains("=D0"))
    }

    func testMessageParserKeepsFullBodySeparateFromConcisePreview() {
        let bodyText = String(repeating: "Complete body content. ", count: 40)
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Long message\r\n",
            body: "From: sender@example.com\nSubject: Long message\nContent-Type: text/plain; charset=utf-8\n\n\(bodyText)"
        )

        XCTAssertEqual(parsed.preview.count, 500)
        XCTAssertEqual(parsed.body, bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertGreaterThan(parsed.body.count, parsed.preview.count)
        XCTAssertNil(parsed.bodyHTML)
    }

    func testSyncParserCanonicalizesInboundAddressesAndMessageIDsWithFrozenBounds() throws {
        let header = [
            "From: José <JOSE@Example.Invalid>",
            "Reply-To: Zöe <ZOE@Example.Invalid>",
            "To: One <ONE@Example.Invalid>, Two <TWO@Example.Invalid>",
            "Message-ID: <Root@Example.Invalid>",
            "In-Reply-To: <One@Example.Invalid> <One@Example.Invalid> <two@Example.Invalid>",
            "References: <One@Example.Invalid> <One@Example.Invalid> <two@Example.Invalid>",
            "Subject: canonical",
            "",
        ].joined(separator: "\r\n")
        let parsed = try IMAPMessageParser.parseForSync(
            header: header,
            bodyData: Data("Content-Type: text/plain; charset=utf-8\r\n\r\nbody".utf8)
        )

        XCTAssertEqual(parsed.from, EmailAddress("JOSE@example.invalid"))
        XCTAssertEqual(parsed.fromDisplayName, "José")
        XCTAssertEqual(parsed.replyTo, EmailAddress("ZOE@example.invalid"))
        XCTAssertEqual(parsed.to, [EmailAddress("ONE@example.invalid"), EmailAddress("TWO@example.invalid")])
        XCTAssertEqual(parsed.messageID, "<Root@Example.Invalid>")
        XCTAssertEqual(parsed.inReplyTo, "<One@Example.Invalid>")
        XCTAssertEqual(parsed.references, ["<One@Example.Invalid>", "<two@Example.Invalid>"])

        let tooManyReferences = (0 ... 256)
            .map { "<id\($0)@example.invalid>" }
            .joined(separator: " ")
        XCTAssertThrowsError(
            try IMAPMessageParser.parseForSync(
                header: "References: \(tooManyReferences)\r\n",
                bodyData: Data("Content-Type: text/plain\r\n\r\nbody".utf8)
            )
        )
    }

    func testSyncInboxUsesCanonicalHeaderProjectionForPersistedMessage() async throws {
        let cache = AtomicMetadataCaptureCache()
        let client = DiscoveredUIDIMAPClient(
            uids: [42],
            header: [
                "From: José <JOSE@Example.Invalid>",
                "Reply-To: Zöe <ZOE@Example.Invalid>",
                "To: One <ONE@Example.Invalid>",
                "Cc: Two <TWO@Example.Invalid>",
                "Bcc: Three <THREE@Example.Invalid>",
                "Message-ID: <Root@Example.Invalid>",
                "In-Reply-To: <One@Example.Invalid> <One@Example.Invalid>",
                "References: <One@Example.Invalid> <One@Example.Invalid> <two@Example.Invalid>",
                "Subject: canonical",
                "",
            ].joined(separator: "\r\n"),
            body: "Content-Type: text/plain; charset=utf-8\r\n\r\nbody"
        )

        _ = try await IMAPSyncService(client: client, cache: cache).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        let message = try XCTUnwrap(cache.committedMessages.first)
        XCTAssertEqual(message.from, EmailAddress("JOSE@example.invalid"))
        XCTAssertEqual(message.fromDisplayName, "José")
        XCTAssertEqual(message.replyTo, EmailAddress("ZOE@example.invalid"))
        XCTAssertEqual(message.to, [EmailAddress("ONE@example.invalid")])
        XCTAssertEqual(message.cc, [EmailAddress("TWO@example.invalid")])
        XCTAssertEqual(message.rfcMessageID, "<Root@Example.Invalid>")
        XCTAssertEqual(message.inReplyTo, "<One@Example.Invalid>")
        XCTAssertEqual(message.references, ["<One@Example.Invalid>", "<two@Example.Invalid>"])
        XCTAssertEqual(cache.committedMetadata.first?.bcc, [EmailAddress("THREE@example.invalid")])
    }

    func testMIMEParserMatchesOnlyCompleteBoundaryLinesAndSkipsAttachments() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Boundary test\r\n",
            body: """
            Content-Type: multipart/mixed; boundary="Mix;Case"

            MIME preamble that must not be shown.
            --Mix;Case 	
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="raw.txt"
            Content-Transfer-Encoding: base64

            QVRUQUNITUVOVA==
            --Mix;Case
            Content-Type: text/plain; charset=utf-8

            Keep --Mix;Case-not-a-boundary inside the body.
            --Mix;Case--
            MIME epilogue that must not be shown.
            """
        )

        XCTAssertEqual(parsed.body, "Keep --Mix;Case-not-a-boundary inside the body.")
        XCTAssertFalse(parsed.body.contains("ATTACHMENT"))
        XCTAssertFalse(parsed.body.contains("preamble"))
        XCTAssertFalse(parsed.body.contains("epilogue"))
        XCTAssertEqual(
            parsed.attachments,
            [IncomingMessageAttachmentMetadata(
                filename: "raw.txt",
                mimeType: "application/octet-stream"
            )]
        )
    }

    func testMIMEParserPairsEachAttachmentFilenameWithCanonicalContentType() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Attachments\r\n",
            body: """
            Content-Type: multipart/mixed; boundary="AttachmentBoundary"

            --AttachmentBoundary
            Content-Type: text/plain; charset=utf-8

            Body
            --AttachmentBoundary
            Content-Type: Application/PDF; name="quarterly"
            Content-Disposition: attachment; filename="quarterly"

            pdf
            --AttachmentBoundary
            Content-Type: image/png
            Content-Disposition: attachment; filename="misleading.pdf"

            png
            --AttachmentBoundary--
            """
        )

        XCTAssertEqual(parsed.attachments, [
            IncomingMessageAttachmentMetadata(filename: "quarterly", mimeType: "application/pdf"),
            IncomingMessageAttachmentMetadata(filename: "misleading.pdf", mimeType: "image/png"),
        ])
    }

    func testMIMEParserKeepsMissingAttachmentContentTypeAbsentForFilenameFallback() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Legacy attachments\r\n",
            body: """
            Content-Type: multipart/mixed; boundary="LegacyBoundary"

            --LegacyBoundary
            Content-Type: text/plain; charset=utf-8

            Body
            --LegacyBoundary
            Content-Disposition: attachment; filename="legacy.pdf"

            pdf
            --LegacyBoundary
            Content-Disposition: attachment; filename="image.bin"

            image
            --LegacyBoundary--
            """
        )

        XCTAssertEqual(parsed.attachments, [
            IncomingMessageAttachmentMetadata(filename: "legacy.pdf", mimeType: nil),
            IncomingMessageAttachmentMetadata(filename: "image.bin", mimeType: nil),
        ])
        XCTAssertTrue(MailSearchDocumentClassifier.isDocument(
            filename: parsed.attachments[0].filename,
            mimeType: parsed.attachments[0].mimeType
        ))
        XCTAssertFalse(MailSearchDocumentClassifier.isDocument(
            filename: parsed.attachments[1].filename,
            mimeType: parsed.attachments[1].mimeType
        ))
    }

    func testSyncHandsAttachmentFilenameAndMIMEPairsToAtomicCache() async throws {
        let cache = AtomicMetadataCaptureCache()
        let client = DiscoveredUIDIMAPClient(
            uids: [42],
            body: """
            Content-Type: multipart/mixed; boundary="SyncBoundary"

            --SyncBoundary
            Content-Type: text/plain

            Body
            --SyncBoundary
            Content-Type: application/pdf
            Content-Disposition: attachment; filename="extensionless"

            pdf
            --SyncBoundary
            Content-Type: image/png
            Content-Disposition: attachment; filename="misleading.pdf"

            png
            --SyncBoundary--
            """
        )

        _ = try await IMAPSyncService(client: client, cache: cache).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        XCTAssertEqual(cache.committedMetadata.map(\.attachments), [[
            .init(filename: "extensionless", mimeType: "application/pdf"),
            .init(filename: "misleading.pdf", mimeType: "image/png"),
        ]])
    }

    func testSyncAtomicallyHandsDecodedAttachmentPayloadsToCapableCache() async throws {
        let cache = AtomicMetadataCaptureCache()
        let client = DiscoveredUIDIMAPClient(
            uids: [42],
            body: """
            Content-Type: multipart/mixed; boundary="PayloadBoundary"

            --PayloadBoundary
            Content-Type: text/plain

            Body
            --PayloadBoundary
            Content-Type: Application/PDF
            Content-Disposition: attachment; filename*=UTF-8''quarterly%2Freport.pdf
            Content-Transfer-Encoding: base64

            cGF5bG9hZA==
            --PayloadBoundary--
            """
        )

        _ = try await IMAPSyncService(client: client, cache: cache).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        XCTAssertEqual(cache.committedAttachments.count, 1)
        let attachment = try XCTUnwrap(cache.committedAttachments.first)
        XCTAssertEqual(attachment.partPath, "2")
        XCTAssertEqual(attachment.filename, "quarterly_report.pdf")
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.data, Data("payload".utf8))
        XCTAssertEqual(cache.committedMetadata.first?.attachments, [
            .init(filename: attachment.filename, mimeType: attachment.mimeType)
        ])
    }

    func testSyncDefersMalformedAttachmentHydrationUntilAttachmentCapableCache() async throws {
        let cache = MetadataOnlyCaptureCache()
        let client = DiscoveredUIDIMAPClient(
            uids: [42],
            body: """
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="deferred.bin"
            Content-Transfer-Encoding: x-custom-compression

            opaque bytes
            """
        )

        let result = try await IMAPSyncService(client: client, cache: cache).syncInbox(
            credentials: IMAPAccountCredentials(
                accountID: PlainpostFixtures.personalAccount.id,
                email: PlainpostFixtures.personalAccount.email,
                username: "me@example.com",
                password: "secret"
            )
        )

        XCTAssertEqual(result.syncedMessageCount, 1)
        XCTAssertEqual(cache.committedMetadata.first?.attachments, [
            .init(filename: "deferred.bin", mimeType: "application/octet-stream")
        ])
    }

    func testMIMEParserHandlesNestedAlternativeInsideSignedMessage() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Signed alternative\r\n",
            body: """
            Content-Type: multipart/signed; boundary="SignedBoundary"

            --SignedBoundary
            Content-Type: multipart/alternative; boundary="AltBoundary"

            --AltBoundary
            Content-Type: text/html; charset=utf-8

            <p>HTML fallback</p>
            --AltBoundary
            Content-Type: text/plain; charset=utf-8

            Preferred plain body
            --AltBoundary--
            --SignedBoundary
            Content-Type: application/pkcs7-signature

            signature bytes
            --SignedBoundary--
            """
        )

        XCTAssertEqual(parsed.body, "Preferred plain body")
        XCTAssertFalse(parsed.body.contains("signature"))
    }

    func testMIMEParserDecodesInlineRFC822AndIgnoresAttachedMessage() {
        let parsed = IMAPMessageParser.parse(
            header: "From: sender@example.com\r\nSubject: Forwarded\r\n",
            body: """
            Content-Type: multipart/mixed; boundary="ForwardBoundary"

            --ForwardBoundary
            Content-Type: message/rfc822
            Content-Disposition: attachment

            Subject: Attached message

            This must not be selected.
            --ForwardBoundary
            Content-Type: message/rfc822

            From: nested@example.com
            Subject: Inline message
            Content-Type: text/plain; charset=utf-8

            Inline forwarded body
            --ForwardBoundary--
            """
        )

        XCTAssertEqual(parsed.body, "Inline forwarded body")
    }

    func testMIMEParserDecodesWindowsCharsetAndFlowedText() {
        let message = Data(
            "Content-Type: text/plain; charset=windows-1252; format=flowed; delsp=no\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nPrice: =80 and a flowed \r\nline.\r\n-- \r\nSignature".utf8
        )

        XCTAssertEqual(
            MIMEMessageDecoder.displayText(from: message),
            "Price: € and a flowed line.\n--\nSignature"
        )
    }

    func testMIMEHeaderDecoderJoinsAdjacentEncodedWords() {
        XCTAssertEqual(
            MIMEMessageDecoder.decodeHeader("=?UTF-8?Q?Hello?= =?UTF-8?Q?_World?="),
            "Hello World"
        )
    }
}

private actor SyncProgressRecorder {
    private(set) var events: [IMAPSyncProgress] = []

    func record(_ event: IMAPSyncProgress) {
        events.append(event)
    }
}

private final class DiscoveredUIDIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    let uids: [Int]
    let uidValidity: Int?
    let header: String?
    let body: String?
    let internalDate: Date?
    private(set) var fetchedHeaderUIDs: [Int] = []
    private(set) var fetchedBodyUIDs: [Int] = []

    init(
        uids: [Int],
        uidValidity: Int? = nil,
        header: String? = nil,
        body: String? = nil,
        internalDate: Date? = nil
    ) {
        self.uids = uids
        self.uidValidity = uidValidity
        self.header = header
        self.body = body
        self.internalDate = internalDate
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        [
            Mailbox(
                id: MailboxID("mbx_test_inbox"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: "INBOX",
                path: "INBOX",
                specialUse: "\\Inbox"
            )
        ]
    }

    func selectMailbox(_ path: String) async throws -> String {
        if let uidValidity {
            return "* \(uids.count) EXISTS\n* OK [UIDVALIDITY \(uidValidity)] UIDs valid"
        }
        return "* \(uids.count) EXISTS"
    }

    func allMessageUIDs() async throws -> [Int] {
        uids
    }

    func fetchHeader(uid: Int) async throws -> String {
        fetchedHeaderUIDs.append(uid)
        return header ?? "From: alice@example.com Subject: Discovered UID \(uid) Date: 2026-07-09"
    }

    func fetchBody(uid: Int) async throws -> String {
        fetchedBodyUIDs.append(uid)
        return body ?? "Body: Message fetched by discovered UID \(uid)"
    }

    func fetchInternalDate(uid: Int) async throws -> Date? { internalDate }

    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private final class AtomicMetadataCaptureCache: MailCache, AtomicIncomingAttachmentCache {
    private(set) var committedMetadata: [IncomingMessageSearchMetadata] = []
    private(set) var committedAttachments: [IncomingMessageAttachmentPayload] = []
    private(set) var committedMessages: [MessageSummary] = []

    func cacheMailboxes(_ mailboxes: [Mailbox]) throws {}

    func cacheMessage(_ message: MessageSummary) throws {
        XCTFail("Atomic sync must not fall back to cacheMessage")
    }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        attachments: [IncomingMessageAttachmentPayload],
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        committedMessages.append(message)
        committedMetadata.append(metadata)
        committedAttachments.append(contentsOf: attachments)
        return IncomingMessageCommitResult(
            messageID: message.id,
            insertedMembership: true,
            insertedCanonicalMessage: true
        )
    }
}

private final class MetadataOnlyCaptureCache: MailCache, AtomicIncomingMessageCache {
    private(set) var committedMetadata: [IncomingMessageSearchMetadata] = []

    func cacheMailboxes(_ mailboxes: [Mailbox]) throws {}

    func cacheMessage(_ message: MessageSummary) throws {
        XCTFail("Atomic sync must not fall back to cacheMessage")
    }

    func commitIncomingMessage(
        _ message: MessageSummary,
        metadata: IncomingMessageSearchMetadata,
        accountID: AccountID,
        mailboxPath: String,
        uidValidity: Int,
        uid: Int,
        notificationEligible: Bool
    ) throws -> IncomingMessageCommitResult {
        committedMetadata.append(metadata)
        return IncomingMessageCommitResult(messageID: message.id, insertedMembership: true)
    }
}

private enum VerificationDeleteFailure: Error {
    case failed
}

private final class VerificationMessageIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    let data: String
    let deleteFails: Bool
    private(set) var deleteAttempts: [Int] = []
    private(set) var deletedUIDs: [Int] = []

    init(data: String, deleteFails: Bool = false) {
        self.data = data
        self.deleteFails = deleteFails
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(
            id: MailboxID("mbx_verification_inbox"),
            accountID: AccountID("acc_me_example_com"),
            name: "INBOX",
            path: "INBOX",
            specialUse: "\\Inbox"
        )]
    }

    func selectMailbox(_ path: String) async throws -> String {
        "* 1 EXISTS\n* OK [UIDVALIDITY 1] UIDs valid"
    }

    func allMessageUIDs() async throws -> [Int] { [42] }

    func fetchHeader(uid: Int) async throws -> String {
        data.components(separatedBy: "\r\n\r\n")[0]
    }

    func fetchBody(uid: Int) async throws -> String { data }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}

    func delete(uid: Int) async throws {
        deleteAttempts.append(uid)
        if deleteFails { throw VerificationDeleteFailure.failed }
        deletedUIDs.append(uid)
    }

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private final class MultiMailboxProgressIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let uidsByMailbox: [String: [Int]]
    private var selectedMailbox = "INBOX"

    init(uidsByMailbox: [String: [Int]]) {
        self.uidsByMailbox = uidsByMailbox
    }

    func login(username: String, password: String) async throws {}

    func listMailboxes() async throws -> [Mailbox] {
        uidsByMailbox.keys.sorted().map { path in
            Mailbox(
                id: MailboxID("mbx_\(path.lowercased())"),
                accountID: PlainpostFixtures.personalAccount.id,
                name: path,
                path: path,
                specialUse: nil
            )
        }
    }

    func selectMailbox(_ path: String) async throws -> String {
        selectedMailbox = path
        return "* \(uidsByMailbox[path, default: []].count) EXISTS\r\n* OK [UIDVALIDITY 1]"
    }

    func allMessageUIDs() async throws -> [Int] {
        uidsByMailbox[selectedMailbox, default: []]
    }

    func fetchHeader(uid: Int) async throws -> String {
        "From: sender\(uid)@example.com\r\nSubject: Message \(uid)\r\n"
    }

    func fetchBody(uid: Int) async throws -> String { "Body \(uid)" }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}

    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

private actor HistoryFreshnessFetchGate {
    let held: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(held: XCTestExpectation) { self.held = held }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            held.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor HistoryFreshnessIMAPClient: IMAPClientProtocol {
    private var uids: [String: [Int]]
    private var selected = "INBOX"
    private var generations: [String: Int] = [:]
    private var selectionCounts: [String: Int] = [:]
    private let arrivalTrigger: String?
    private let arrivalUIDs: [Int]
    private let heldHeader: String?
    private let gate: HistoryFreshnessFetchGate?
    private let failedBody: String?
    private let rolloverOnReselect: String?
    private let arrivalsPerProbe: Int
    private let maximumArrivalProbes: Int
    private(set) var fetchedHeaders: [String] = []
    private(set) var selections: [String] = []
    private(set) var freshProbeCount = 0
    var inboxUIDs: [Int] { uids["INBOX", default: []] }

    init(
        uids: [String: [Int]], arrivalTrigger: String? = nil, arrivalUIDs: [Int] = [],
        heldHeader: String? = nil, gate: HistoryFreshnessFetchGate? = nil,
        failedBody: String? = nil, rolloverOnReselect: String? = nil,
        arrivalsPerProbe: Int = 0, maximumArrivalProbes: Int = 0
    ) {
        self.uids = uids; self.arrivalTrigger = arrivalTrigger; self.arrivalUIDs = arrivalUIDs
        self.heldHeader = heldHeader; self.gate = gate; self.failedBody = failedBody
        self.rolloverOnReselect = rolloverOnReselect
        self.arrivalsPerProbe = arrivalsPerProbe; self.maximumArrivalProbes = maximumArrivalProbes
    }
    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] {
        uids.keys.sorted().map { Mailbox(
            id: MailboxID("freshness-\($0)"), accountID: PlainpostFixtures.personalAccount.id,
            name: $0, path: $0, specialUse: nil
        ) }
    }
    func selectMailbox(_ path: String) async throws -> String {
        selected = path; selections.append(path); selectionCounts[path, default: 0] += 1
        if path == rolloverOnReselect, selectionCounts[path, default: 0] > 1 { generations[path] = 8 }
        return "* OK [UIDVALIDITY \(generations[path, default: 7])]"
    }
    func allMessageUIDs() async throws -> [Int] { uids[selected, default: []].sorted() }
    func messageUIDs(after uid: Int?) async throws -> [Int] {
        freshProbeCount += 1
        if selected == "INBOX", freshProbeCount <= maximumArrivalProbes {
            let start = (uids["INBOX", default: []].max() ?? 0) + 1
            uids["INBOX", default: []].append(contentsOf: start..<(start + arrivalsPerProbe))
        }
        return uids[selected, default: []].filter { $0 > (uid ?? 0) }.sorted()
    }
    func fetchHeader(uid: Int) async throws -> String {
        let path = selected
        fetchedHeaders.append("\(path):\(uid)@\(generations[path, default: 7])")
        if "\(path):\(uid)" == heldHeader { await gate?.wait() }
        return "From: sender@example.test\r\nSubject: \(path) \(uid)\r\n"
    }
    func fetchBody(uid: Int) async throws -> String {
        let key = "\(selected):\(uid)"
        if key == failedBody { throw IMAPClientError.protocolError("Controlled synthetic body failure") }
        if key == arrivalTrigger { uids["INBOX", default: []].append(contentsOf: arrivalUIDs) }
        return "Synthetic body"
    }
    func fetchInternalDate(uid: Int) async throws -> Date? { Date() }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        .init(mailbox: mailbox, uid: nil)
    }
}

final class InlineImagePartTests: XCTestCase {
    /// Helsana's Outlook signature: a multipart/related HTML body whose logo
    /// is a `cid:` part. The part keeps its Content-ID so the view can show it.
    func testSyncedRelatedImageKeepsItsContentIDAndResolvesInTheHTML() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-inline-image-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id, email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com", password: "secret"
        )
        let header = """
            From: Jeremy <jeremy@example.com>\r
            Subject: Signature\r
            Message-ID: <inline-image@example.test>\r
            Date: Mon, 5 Oct 2026 10:26:21 +0000\r
            Content-Type: multipart/related; boundary="rel"; type="text/html"\r
            """
        let body = """
            Content-Type: multipart/related; boundary="rel"; type="text/html"\r
            \r
            --rel\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <p>Kind regards</p><img width="102" src="cid:image001.png@01DD54C4.B9AD52D0">\r
            --rel\r
            Content-Type: image/png; name="image001.png"\r
            Content-Description: image001.png\r
            Content-Disposition: inline; filename="image001.png"\r
            Content-ID: <image001.png@01DD54C4.B9AD52D0>\r
            Content-Transfer-Encoding: base64\r
            \r
            iVBORw0KGgo=\r
            --rel--\r
            """
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7, header: header, body: body),
            cache: store
        ).syncInbox(credentials: credentials)

        let message = try XCTUnwrap(try store.messages(accountID: credentials.accountID).first)
        let parts = try store.inlineImageParts(messageID: message.id)
        XCTAssertEqual(parts.map(\.contentID), ["image001.png@01DD54C4.B9AD52D0"])
        XCTAssertEqual(parts.map(\.mimeType), ["image/png"])
        XCTAssertEqual(
            try store.incomingMessageAttachments(messageID: message.id).map(\.contentID),
            ["image001.png@01DD54C4.B9AD52D0"]
        )
        let html = try XCTUnwrap(message.bodyHTML)
        XCTAssertTrue(html.contains("cid:image001.png@01DD54C4.B9AD52D0"), html)
        let resolved = InlineImageResolver.resolve(html: html, parts: parts)
        XCTAssertFalse(resolved.contains("cid:"))
        XCTAssertTrue(resolved.contains("data:image/png;base64,iVBORw0KGgo="))
    }
}

final class MisreadSenderRepairTests: XCTestCase {
    /// The shape `IMAPClient.fetchHeader` returns: the literal follows the FETCH prefix.
    private let fetchedHeader = "* 1 FETCH (UID 1 BODY[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)] "
        + "From: Furrer Jeremy Shawn <jeremyshawn.furrer@helsana.ch>\r\n"
        + "To: Oleh Vdovenko <me@example.com>\r\n"
        + "Subject: RE: Kundenrueckfrage\r\n"
        + "Date: Mon, 5 Oct 2026 10:26:21 +0000\r\n"
        + "Message-ID: <misread@example.test>\r\n"
        + "\r\n)"

    func testALaterPassRepairsASenderReadFromTheFetchPrefixLine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-misread-sender-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        let credentials = IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id, email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com", password: "secret"
        )
        let client = DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7, header: fetchedHeader, body: "Body")
        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(credentials: credentials)
        // What the earlier parser stored for this header.
        try await store.databasePool.write { database in
            try database.execute(sql: """
                UPDATE messages SET from_email = 'me@example.com',
                    from_display_name = 'Furrer Jeremy Shawn <jeremyshawn.furrer@helsana.ch>' || char(13, 10) || 'To: Oleh Vdovenko',
                    to_emails = ''
                """)
        }

        _ = try await IMAPSyncService(client: client, cache: store).syncInbox(credentials: credentials)

        let message = try XCTUnwrap(try store.messages(accountID: credentials.accountID).first)
        XCTAssertEqual(message.from.rawValue, "jeremyshawn.furrer@helsana.ch")
        XCTAssertEqual(message.fromDisplayName, "Furrer Jeremy Shawn")
        XCTAssertEqual(message.to.map(\.rawValue), ["me@example.com"])
    }
}

final class MissingSentDateRepairTests: XCTestCase {
    private let undatedHeader = """
        From: alice@example.com\r
        Subject: Undated\r
        Message-ID: <undated@example.test>\r
        """

    private func makeStore() throws -> (SQLiteMailStore, URL, IMAPAccountCredentials) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-sent-date-repair-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        return (store, url, IMAPAccountCredentials(
            accountID: PlainpostFixtures.personalAccount.id, email: PlainpostFixtures.personalAccount.email,
            username: "me@example.com", password: "secret"
        ))
    }

    private func sentAt(_ store: SQLiteMailStore, _ credentials: IMAPAccountCredentials) throws -> Date? {
        try XCTUnwrap(try store.messages(accountID: credentials.accountID).first).sentAt
    }

    func testALaterPassDatesMailCachedWithoutASentDate() async throws {
        let (store, url, credentials) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7, header: undatedHeader, body: "Body"),
            cache: store
        ).syncInbox(credentials: credentials)
        XCTAssertNil(try sentAt(store, credentials))

        let datedHeader = undatedHeader + "Date: Mon, 06 Oct 2026 07:12:34 -0700\r\n"
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(uids: [1], uidValidity: 7, header: datedHeader, body: "Body"),
            cache: store
        ).syncInbox(credentials: credentials)
        XCTAssertEqual(try sentAt(store, credentials), Date(timeIntervalSince1970: 1_791_295_954))
    }

    func testMailWithoutADateHeaderTakesTheServerArrivalTime() async throws {
        let (store, url, credentials) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date(timeIntervalSince1970: 1_791_300_000)
        _ = try await IMAPSyncService(
            client: DiscoveredUIDIMAPClient(
                uids: [1], uidValidity: 7, header: undatedHeader, body: "Body", internalDate: arrival
            ),
            cache: store
        ).syncInbox(credentials: credentials)
        XCTAssertEqual(try sentAt(store, credentials), arrival)
    }
}
