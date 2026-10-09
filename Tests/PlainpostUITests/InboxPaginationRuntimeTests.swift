import XCTest
@testable import PlainpostCore
import PlainpostDB
@testable import PlainpostTestSupport
@testable import PlainpostUI
import PlainpostRuntimeTestSupport

final class InboxPaginationRuntimeTests: XCTestCase {
    @MainActor
    func testInboxLoadMoreAdvancesRuntimePageByRepositoryPageSize() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-pagination-runtime-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let isolation = RuntimeKeychainIsolation(
            testCase: self, databaseURL: databaseURL,
            keychainService: "InboxPaginationRuntimeTests.\(UUID().uuidString)"
        )
        let account = PlainpostFixtures.personalAccount
        let seed = try SQLiteMailStore(path: databaseURL.path)
        try seed.migrate()
        try seed.cacheAccountSetup(
            account: account,
            inbox: Mailbox(
                id: MailboxID("pagination-inbox"), accountID: account.id,
                name: "Inbox", path: "INBOX", specialUse: "\\Inbox"
            ),
            source: AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let runtime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: databaseURL, selectedAccountID: account.id,
                runtimeDependencies: isolation.runtimeDependencies
            ), notificationScheduler: NoopLocalNotificationScheduler()
        )
        for index in 0..<401 {
            _ = try runtime.store.commitIncomingMessage(
                MessageSummary(
                    id: MessageID("msg_inbox_page_\(index)"),
                    threadID: ThreadID("thr_inbox_page_\(index)"),
                    from: EmailAddress("sender@example.com"),
                    subject: "Inbox page message \(index)",
                    preview: "Preview \(index)",
                    smartCategory: .personal,
                    sentAt: Date(timeIntervalSince1970: TimeInterval(index))
                ),
                metadata: IncomingMessageSearchMetadata(
                    to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []
                ),
                accountID: account.id, mailboxPath: "INBOX", uidValidity: 1,
                uid: index + 1, notificationEligible: false
            )
        }

        let initial = await runtime.makeInboxSelectionViewModelAsync(selectedMessageID: nil)
        let expanded = await runtime.loadMoreInboxSelectionViewModelAsync(selectedMessageID: nil)

        XCTAssertEqual(initial.classicRows.count, 200)
        XCTAssertEqual(expanded.classicRows.count, 400)
        XCTAssertTrue(initial.hasMoreRows)
        XCTAssertTrue(expanded.hasMoreRows)
    }
}
