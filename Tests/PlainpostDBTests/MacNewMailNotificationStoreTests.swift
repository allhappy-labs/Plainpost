import XCTest
import PlainpostAccountProtocol
@testable import PlainpostCore
@testable import PlainpostDB

final class MacNewMailNotificationStoreTests: XCTestCase {
    func testFreshIncrementalInboxCommitCreatesOneAwaitingRulesEventWithoutProducerConfiguration() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(try store.nextMacNewMailDeliveryWakeDate(now: Date()))
        let providerArrivalAt = Date().addingTimeInterval(-5)
        let message = testMessage(id: "msg-fresh")

        let result = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: accountID,
            mailboxPath: "INBOX",
            uidValidity: 7,
            uid: 42,
            notificationDisposition: .candidate(providerArrivalAt: providerArrivalAt)
        )

        XCTAssertTrue(result.insertedCanonicalMessage)
        XCTAssertTrue(result.insertedMembership)
        let event = try XCTUnwrap(store.macNewMailEvents(accountID: accountID).only)
        XCTAssertEqual(event.accountID, accountID)
        XCTAssertEqual(event.messageID, message.id)
        XCTAssertEqual(event.state, .awaitingRules)
        XCTAssertEqual(event.providerArrivalAt.timeIntervalSince1970,
                       providerArrivalAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(event.readyAt)
        XCTAssertEqual(event.expiresAt.timeIntervalSince1970,
                       providerArrivalAt.addingTimeInterval(15 * 60).timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertTrue(event.id.hasPrefix("mac-mail-event-"))
        XCTAssertFalse(event.id.contains(accountID.rawValue))
        XCTAssertFalse(event.id.contains(message.id.rawValue))
    }

    func testIneligibleBaselineAndNonInboxCommitsDoNotCreateEvents() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date().addingTimeInterval(-5)

        try commit(testMessage(id: "msg-ineligible"), disposition: .ineligible,
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(testMessage(id: "msg-baseline"), disposition: .establishWatermark,
                   mailboxPath: "INBOX", uid: 2, store: store, accountID: accountID)
        try commit(testMessage(id: "msg-archive"),
                   disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "Archive", uid: 3, store: store, accountID: accountID)

        XCTAssertEqual(try store.macNewMailEvents(accountID: accountID), [])
    }

    func testMissingStaleAndFutureProviderArrivalsDoNotCreateEvents() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }

        try commit(testMessage(id: "msg-no-arrival"),
                   disposition: .candidate(providerArrivalAt: nil),
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(testMessage(id: "msg-stale"),
                   disposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-(15 * 60 + 5))),
                   mailboxPath: "INBOX", uid: 2, store: store, accountID: accountID)
        try commit(testMessage(id: "msg-future"),
                   disposition: .candidate(providerArrivalAt: Date().addingTimeInterval(5)),
                   mailboxPath: "INBOX", uid: 3, store: store, accountID: accountID)

        XCTAssertEqual(try store.macNewMailEvents(accountID: accountID), [])
    }

    func testDuplicateAndExistingCanonicalMessageCopiedToInboxDoNotCreateEvents() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date().addingTimeInterval(-5)
        let duplicate = testMessage(id: "msg-duplicate")
        let copied = testMessage(id: "msg-copied")

        try commit(duplicate, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(duplicate, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(copied, disposition: .ineligible,
                   mailboxPath: "Archive", uid: 2, store: store, accountID: accountID)
        try commit(copied, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 3, store: store, accountID: accountID)

        XCTAssertEqual(try store.macNewMailEvents(accountID: accountID).map(\.messageID), [duplicate.id])
    }

    func testRuleResolutionMakesAllowedEventReadyAndSuppressedEventTerminalIdempotently() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date().addingTimeInterval(-5)
        let allowed = testMessage(id: "msg-allowed")
        let suppressed = testMessage(id: "msg-suppressed")
        try commit(allowed, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(suppressed, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 2, store: store, accountID: accountID)
        let resolvedAt = Date()

        try store.resolveMacNewMailEvents(
            accountID: accountID,
            messageIDs: [allowed.id, suppressed.id],
            suppressedIDs: [suppressed.id],
            now: resolvedAt
        )
        try store.resolveMacNewMailEvents(
            accountID: accountID,
            messageIDs: [allowed.id, suppressed.id],
            suppressedIDs: [],
            now: resolvedAt.addingTimeInterval(10)
        )

        let events = Dictionary(
            uniqueKeysWithValues: try store.macNewMailEvents(accountID: accountID)
                .map { ($0.messageID, $0) }
        )
        XCTAssertEqual(events[allowed.id]?.state, .ready)
        XCTAssertEqual(events[suppressed.id]?.state, .suppressed)
        XCTAssertEqual(try XCTUnwrap(events[allowed.id]?.readyAt).timeIntervalSince1970,
                       resolvedAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(events[suppressed.id]?.readyAt)
    }

    func testExpiredAndFailedRuleResolutionFailClosed() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date().addingTimeInterval(-(15 * 60 - 1))
        let expired = testMessage(id: "msg-expired")
        let failed = testMessage(id: "msg-failed")
        try commit(expired, disposition: .candidate(providerArrivalAt: arrival),
                   mailboxPath: "INBOX", uid: 1, store: store, accountID: accountID)
        try commit(failed, disposition: .candidate(providerArrivalAt: Date().addingTimeInterval(-1)),
                   mailboxPath: "INBOX", uid: 2, store: store, accountID: accountID)

        try store.resolveMacNewMailEvents(
            accountID: accountID,
            messageIDs: [expired.id],
            suppressedIDs: [],
            now: arrival.addingTimeInterval(15 * 60 + 1)
        )
        try store.failMacNewMailRuleEvaluation(
            accountID: accountID,
            messageIDs: [failed.id],
            now: Date()
        )

        XCTAssertEqual(
            try store.macNewMailEvents(accountID: accountID).map(\.state),
            [.expired, .suppressed]
        )
    }

    func testAwaitingRuleRecoveryIsBoundedAndExcludesExpiredEvents() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let arrival = Date().addingTimeInterval(-5)
        for index in 0..<3 {
            try commit(testMessage(id: "msg-recovery-\(index)"),
                       disposition: .candidate(providerArrivalAt: arrival),
                       mailboxPath: "INBOX", uid: index + 1,
                       store: store, accountID: accountID)
        }

        let batches = try store.awaitingMacNewMailEventMessageIDs(
            limit: 2,
            now: Date()
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].accountID, accountID)
        XCTAssertEqual(batches[0].messageIDs.count, 2)
    }

    func testDeliveryFormationWaitsTwoSecondsThenCreatesStableIndividualDeliveries() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        let messageIDs = try createReadyEvents(
            count: 3,
            prefix: "individual",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )

        XCTAssertEqual(
            try XCTUnwrap(store.nextMacNewMailDeliveryWakeDate(now: readyAt))
                .timeIntervalSince1970,
            readyAt.addingTimeInterval(2).timeIntervalSince1970,
            accuracy: 0.001
        )

        XCTAssertEqual(
            try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(1.999)),
            0
        )
        XCTAssertEqual(
            try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(2)),
            3
        )
        let first = try store.macNewMailDeliveries(accountID: accountID)
        XCTAssertEqual(first.map(\.kind), [.individual, .individual, .individual])
        XCTAssertEqual(first.map(\.eventCount), [1, 1, 1])
        XCTAssertEqual(Set(first.map(\.messageIDs)), Set(messageIDs.map { [$0] }))
        XCTAssertTrue(first.allSatisfy { $0.id.hasPrefix("mac-mail-delivery-") })

        XCTAssertEqual(
            try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(3)),
            0
        )
        XCTAssertEqual(try store.macNewMailDeliveries(accountID: accountID).map(\.id),
                       first.map(\.id))
    }

    func testSixReadyEventsCreateOneAccountScopedSummaryAndLateEventWaitsForNextWindow() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        let firstWindowIDs = try createReadyEvents(
            count: 6,
            prefix: "summary",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )
        let lateIDs = try createReadyEvents(
            count: 1,
            prefix: "late",
            accountID: accountID,
            store: store,
            readyAt: readyAt.addingTimeInterval(3),
            uidOffset: 100
        )

        XCTAssertEqual(
            try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(2)),
            1
        )
        var deliveries = try store.macNewMailDeliveries(accountID: accountID)
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].kind, .summary)
        XCTAssertEqual(deliveries[0].eventCount, 6)
        XCTAssertEqual(Set(deliveries[0].messageIDs), Set(firstWindowIDs))

        XCTAssertEqual(
            try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(5)),
            1
        )
        deliveries = try store.macNewMailDeliveries(accountID: accountID)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.map(\.kind), [.summary, .individual])
        XCTAssertEqual(deliveries[1].messageIDs, lateIDs)
    }

    func testSummaryLinksAtMostFiveHundredEventsAndSuppressesOverflow() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        _ = try createReadyEvents(
            count: 501,
            prefix: "overflow",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )

        XCTAssertEqual(try store.formMacNewMailDeliveries(
            now: readyAt.addingTimeInterval(2)
        ), 1)
        let delivery = try XCTUnwrap(store.macNewMailDeliveries(accountID: accountID).only)
        XCTAssertEqual(delivery.kind, .summary)
        XCTAssertEqual(delivery.eventCount, 501)
        XCTAssertEqual(delivery.messageIDs.count, 500)
        let eventStates = try store.macNewMailEvents(accountID: accountID).map(\.state)
        XCTAssertEqual(eventStates.filter { $0 == .assigned }.count, 500)
        XCTAssertEqual(eventStates.filter { $0 == .suppressed }.count, 1)
    }

    func testDeliveryFormationKeepsAccountsInSeparateBatches() throws {
        let (store, url, firstAccountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let secondAccountID = AccountID("acc-mac-new-mail-second")
        try store.cacheAccounts([
            Account(
                id: secondAccountID,
                displayName: "Second Mac Notifications",
                email: EmailAddress("mac-notifications-second@example.com"),
                imapHost: "imap.example.com",
                smtpHost: "smtp.example.com"
            )
        ])
        let readyAt = Date()
        _ = try createReadyEvents(
            count: 6, prefix: "first-account", accountID: firstAccountID,
            store: store, readyAt: readyAt
        )
        _ = try createReadyEvents(
            count: 6, prefix: "second-account", accountID: secondAccountID,
            store: store, readyAt: readyAt
        )

        XCTAssertEqual(try store.formMacNewMailDeliveries(
            now: readyAt.addingTimeInterval(2)
        ), 2)
        XCTAssertEqual(try store.macNewMailDeliveries(accountID: firstAccountID).count, 1)
        XCTAssertEqual(try store.macNewMailDeliveries(accountID: secondAccountID).count, 1)
    }

    func testOnlyOneStoreClaimsDeliveryAndSubmissionTransitionsRequireItsLease() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        let messageID = try createReadyEvents(
            count: 1,
            prefix: "claim",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )[0]
        XCTAssertEqual(try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(2)), 1)
        let secondStore = try SQLiteMailStore(path: url.path)
        try secondStore.migrate()

        let claim = try XCTUnwrap(store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(2),
            leaseDuration: 30
        ))
        XCTAssertNil(try secondStore.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(2),
            leaseDuration: 30
        ))
        XCTAssertFalse(try store.beginMacNewMailSubmission(
            id: claim.id,
            leaseToken: "wrong-token",
            now: readyAt.addingTimeInterval(2)
        ))
        XCTAssertEqual(claim.messageIDs, [messageID])
        XCTAssertTrue(try store.beginMacNewMailSubmission(
            id: claim.id,
            leaseToken: claim.leaseToken,
            now: readyAt.addingTimeInterval(2)
        ))
        XCTAssertTrue(try store.completeMacNewMailSubmission(
            id: claim.id,
            leaseToken: claim.leaseToken,
            now: readyAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(try store.completeMacNewMailSubmission(
            id: claim.id,
            leaseToken: claim.leaseToken,
            now: readyAt.addingTimeInterval(2)
        ))
    }

    func testRecoveryRetriesPreIntentLeaseButNeverRetriesAmbiguousSubmittingDelivery() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        _ = try createReadyEvents(
            count: 1,
            prefix: "recovery-state",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )
        XCTAssertEqual(try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(2)), 1)

        let first = try XCTUnwrap(store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(2), leaseDuration: 1
        ))
        try store.recoverMacNewMailNotifications(now: readyAt.addingTimeInterval(4))
        let reclaimed = try XCTUnwrap(store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(4), leaseDuration: 30
        ))
        XCTAssertEqual(reclaimed.id, first.id)
        XCTAssertTrue(try store.beginMacNewMailSubmission(
            id: reclaimed.id,
            leaseToken: reclaimed.leaseToken,
            now: readyAt.addingTimeInterval(4)
        ))
        XCTAssertTrue(try store.failMacNewMailSubmission(
            id: reclaimed.id,
            leaseToken: reclaimed.leaseToken,
            errorCategory: .systemTemporarilyUnavailable,
            retryAt: readyAt.addingTimeInterval(6),
            now: readyAt.addingTimeInterval(4)
        ))
        XCTAssertNil(try store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(5), leaseDuration: 30
        ))
        let retry = try XCTUnwrap(store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(6), leaseDuration: 30
        ))
        XCTAssertEqual(retry.id, first.id)
        XCTAssertTrue(try store.beginMacNewMailSubmission(
            id: retry.id,
            leaseToken: retry.leaseToken,
            now: readyAt.addingTimeInterval(6)
        ))
        try store.recoverMacNewMailNotifications(now: readyAt.addingTimeInterval(7))

        XCTAssertNil(try store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(7), leaseDuration: 30
        ))
        let states = Dictionary(uniqueKeysWithValues:
            try store.macNewMailDeliveries(accountID: accountID).map { ($0.id, $0.state) })
        XCTAssertEqual(states[retry.id], .failed)
    }

    func testPermanentSubmissionFailureIsTerminalAndAccountDeletionCascadesState() throws {
        let (store, url, accountID) = try makeStore(testName: #function)
        defer { try? FileManager.default.removeItem(at: url) }
        let readyAt = Date()
        _ = try createReadyEvents(
            count: 1,
            prefix: "permanent",
            accountID: accountID,
            store: store,
            readyAt: readyAt
        )
        XCTAssertEqual(try store.formMacNewMailDeliveries(now: readyAt.addingTimeInterval(2)), 1)
        let claim = try XCTUnwrap(store.claimMacNewMailDelivery(
            now: readyAt.addingTimeInterval(2), leaseDuration: 30
        ))
        XCTAssertTrue(try store.beginMacNewMailSubmission(
            id: claim.id, leaseToken: claim.leaseToken,
            now: readyAt.addingTimeInterval(2)
        ))
        XCTAssertTrue(try store.failMacNewMailSubmission(
            id: claim.id,
            leaseToken: claim.leaseToken,
            errorCategory: .systemRejected,
            retryAt: nil,
            now: readyAt.addingTimeInterval(2)
        ))
        XCTAssertEqual(try store.macNewMailDeliveries(accountID: accountID).only?.state, .failed)

        try store.deleteAccountData(accountID: accountID)

        XCTAssertEqual(try store.macNewMailEvents(accountID: accountID), [])
        XCTAssertEqual(try store.macNewMailDeliveries(accountID: accountID), [])
    }

    private func makeStore(testName: String) throws -> (SQLiteMailStore, URL, AccountID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-mac-new-mail-\(testName)-\(UUID().uuidString).sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accountID = AccountID("acc-mac-new-mail")
        try store.cacheAccounts([
            Account(
                id: accountID,
                displayName: "Mac Notifications",
                email: EmailAddress("mac-notifications@example.com"),
                imapHost: "imap.example.com",
                smtpHost: "smtp.example.com"
            )
        ])
        return (store, url, accountID)
    }

    private func commit(
        _ message: MessageSummary,
        disposition: IncomingNotificationDisposition,
        mailboxPath: String,
        uid: Int,
        store: SQLiteMailStore,
        accountID: AccountID
    ) throws {
        _ = try store.commitIncomingMessage(
            message,
            metadata: metadata,
            accountID: accountID,
            mailboxPath: mailboxPath,
            uidValidity: 7,
            uid: uid,
            notificationDisposition: disposition
        )
    }

    private func createReadyEvents(
        count: Int,
        prefix: String,
        accountID: AccountID,
        store: SQLiteMailStore,
        readyAt: Date,
        uidOffset: Int = 0
    ) throws -> [MessageID] {
        let messageIDs = (0..<count).map { MessageID("msg-\(prefix)-\($0)") }
        for (index, messageID) in messageIDs.enumerated() {
            try commit(
                testMessage(id: messageID.rawValue),
                disposition: .candidate(
                    providerArrivalAt: Date().addingTimeInterval(-10 + Double(index) / 1_000)
                ),
                mailboxPath: "INBOX",
                uid: uidOffset + index + 1,
                store: store,
                accountID: accountID
            )
        }
        try store.resolveMacNewMailEvents(
            accountID: accountID,
            messageIDs: messageIDs,
            suppressedIDs: [],
            now: readyAt
        )
        return messageIDs
    }

    private func testMessage(id: String) -> MessageSummary {
        MessageSummary(
            id: MessageID(id),
            threadID: nil,
            from: EmailAddress("sender@example.com"),
            subject: "New message",
            preview: "Preview",
            body: "Body",
            smartCategory: .personal
        )
    }

    private var metadata: IncomingMessageSearchMetadata {
        IncomingMessageSearchMetadata(
            to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
