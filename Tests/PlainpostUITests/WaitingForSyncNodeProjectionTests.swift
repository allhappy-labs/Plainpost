import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostUI

final class WaitingForSyncNodeProjectionTests: XCTestCase {
    @MainActor
    func testSourceSwitchDuringProjectionRejectsOldResult() async throws {
        try await assertSourceSwitchRejected(trigger: "from messages")
    }

    @MainActor
    func testSourceSwitchDuringWaitingIntentReadRejectsOldResult() async throws {
        try await assertSourceSwitchRejected(trigger: "from mail_intent_journal")
    }

    @MainActor
    func testInvalidationDuringProjectionRejectsOldResult() async throws {
        try await assertSourceSwitchRejected(trigger: "from messages", invalidate: true)
    }

    @MainActor
    func testSourceSwitchDuringSelectedDetailRejectsOldProjection() async throws {
        try await assertSourceSwitchRejected(trigger: "body_text", selectMessage: true)
    }

    @MainActor
    private func assertSourceSwitchRejected(trigger: String, invalidate: Bool = false, selectMessage: Bool = false) async throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("pp-read-\(UUID().uuidString.prefix(8))")
        let databaseURL = directory.appendingPathComponent("plainpost.sqlite")
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(databaseURL: databaseURL, selectedAccountID: AccountID("acc-badge")),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let account = Account(id: AccountID("acc-badge"), displayName: "Badge", email: EmailAddress("badge@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try runtime.store.cacheAccounts([account])
        let id = try commit(runtime.store, account: account.id, uid: 1)
        let source = try runtime.store.mailSource(accountID: account.id)
        let writer = try SQLiteMailStore(path: databaseURL.path)
        let switched = expectation(description: "source changed inside the admitted query")
        let trace = ProjectionSQLTrace(trigger: trigger) {
            if invalidate {
                let released = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    runtime.invalidateInboxSnapshot()
                    released.signal()
                }
                XCTAssertEqual(released.wait(timeout: .now() + 5), .success,
                               "MainActor must remain available during the admitted SQLite read")
                switched.fulfill()
                return
            }
            do {
                _ = try writer.replaceMailSource(source.nodeBacked(
                    nodeID: "00112233-4455-6677-8899-aabbccddeeff",
                    logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: account.email.rawValue
                ), expectedGeneration: source.generation)
            } catch { XCTFail("source fixture failed: \(error)") }
            switched.fulfill()
        }
        try trace.install(on: runtime.store)
        let result = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: selectMessage ? id.rawValue : nil)
        await fulfillment(of: [switched], timeout: 1)
        XCTAssertFalse(result.classicRows.contains { $0.id == id.rawValue })
        XCTAssertEqual(trace.mainThreadReads, 0)
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testOnlyAdmittedOrUncertainNodeIntentsShowTheBadge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-waiting-badge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        let account = Account(id: AccountID("acc-badge"), displayName: "Badge", email: EmailAddress("badge@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        let admitted = try commit(store, account: account.id, uid: 1)
        let pending = try commit(store, account: account.id, uid: 2)
        let untouched = try commit(store, account: account.id, uid: 3)
        let now = Date()
        _ = try store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000171", accountID: account.id,
                                        kind: .archive, messageID: admitted, draftID: nil, now: now)
        _ = try store.beginMailIntentDispatch(operationID: "00000000-0000-4000-8000-000000000171", route: .node, now: now)
        _ = try store.recordMailIntentOutcome(operationID: "00000000-0000-4000-8000-000000000171", state: .admitted, now: now)
        _ = try store.journalMailIntent(operationID: "00000000-0000-4000-8000-000000000172", accountID: account.id,
                                        kind: .markRead, messageID: pending, draftID: nil, now: now)
        let rows = [admitted, pending, untouched].map { row(for: $0) }

        let waiting = PlainpostAppRuntime.waitingForNode(rows: rows, store: store)

        XCTAssertEqual(waiting, [admitted.rawValue], "a pending, unrouted intent keeps spec semantics: no badge")
        XCTAssertNotEqual(PlainpostAppRuntime.waitingRevision(waiting), PlainpostAppRuntime.waitingRevision([]))
        let badged = rows[0].withWaitingForNode(true)
        XCTAssertTrue(badged.isWaitingForNode)
        XCTAssertFalse(rows[1].isWaitingForNode)
        XCTAssertTrue(MessageListRow.accessibilityValue(for: badged, selected: false)
            .contains("Waiting for Sync Node to confirm this change"))
        XCTAssertFalse(MessageListRow.accessibilityValue(for: rows[1], selected: false).contains("Waiting for Sync Node"))
        XCTAssertEqual(WaitingForSyncNodeBadge.title, "Waiting for Sync Node")

        let repository = InboxProjectionRepository(source: SQLiteInboxProjectionSource(store: store, accountID: account.id))
        let page = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        XCTAssertEqual(page.waitingMessageIDs, [admitted.rawValue])
        XCTAssertEqual(page.authority.source, .direct(account.id))
        try await store.databasePool.write { try $0.execute(sql: "DROP TABLE mail_intent_journal") }
        let unreadableJournal = try await repository.mailboxPage(limit: 200, query: "", forceReload: false)
        XCTAssertTrue(unreadableJournal.waitingMessageIDs.isEmpty)
        XCTAssertEqual(unreadableJournal.rows.count, 3, "a journal error omits the badge without dropping readable mail")
    }

    private func commit(_ store: SQLiteMailStore, account: AccountID, uid: Int) throws -> MessageID {
        let rfcMessageID = "<badge-\(uid)@example.test>"
        let id = MessageID(IMAPSyncService.canonicalMessageID(accountID: account, rfcMessageID: rfcMessageID))
        let message = MessageSummary(id: id, threadID: nil, from: EmailAddress("a@example.test"), subject: "Badge \(uid)",
                                     preview: "Badge", smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX",
                                     isDeleted: false, body: "Badge", rfcMessageID: rfcMessageID)
        _ = try store.commitIncomingMessage(
            message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: account, mailboxPath: "INBOX", uidValidity: 1, uid: uid, notificationDisposition: .ineligible)
        return id
    }

    private func row(for id: MessageID) -> MessageRowModel {
        MessageRowModel(id: id.rawValue, sender: "a@example.test", subject: "Badge", preview: "Badge", category: .personal,
                        categoryLabel: "Personal", isUnread: true, isPinned: false, dateLabel: "Today", actions: [])
    }
}
