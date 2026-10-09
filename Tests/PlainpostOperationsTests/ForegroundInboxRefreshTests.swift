import Foundation
import XCTest
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostTestSupport
import PlainpostAccounts
import PlainpostSecrets
@testable import PlainpostOperationRuntime

final class ForegroundInboxRefreshTests: XCTestCase {
    func testLeaseLostDriverCannotClaimReplacementRuntimesTerminalEffectsOnRefundedAttempt() async throws {
        let fixture = try Fixture()
        addTeardownBlock { fixture.remove() }
        let vault = InMemoryCredentialVault()
        try await vault.store(Data("fixture-password".utf8), for: MailCredentialKeys.imapPassword(fixture.account.id))
        let skippedProvider = EmptyForegroundIMAPClient(account: fixture.account)
        let finishingProvider = EmptyForegroundIMAPClient(account: fixture.account)
        func runtime(_ provider: EmptyForegroundIMAPClient) -> LocalOperationRuntime {
            LocalOperationRuntime(
                store: fixture.store, credentials: vault, allowedJobKinds: [.inboxSync],
                mailboxFlagClientFactory: { _ in provider }, inboxSyncClientFactory: { _, _ in provider }
            )
        }
        let firstRuntime = runtime(skippedProvider)
        let secondRuntime = runtime(finishingProvider)
        let reachedFence = expectation(description: "Original driver has claimed before its lease fence")
        let releaseFence = DispatchSemaphore(value: 0)
        firstRuntime.beforeLeaseFence = { _ in
            reachedFence.fulfill()
            _ = releaseFence.wait(timeout: .now() + 10)
        }
        let request = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        let first = Task { await LocalOperationClient(runtime: firstRuntime).driveForegroundInboxRefreshJob(request) }
        addTeardownBlock {
            releaseFence.signal()
            first.cancel()
            _ = await first.value
        }
        await fulfillment(of: [reachedFence], timeout: 3)
        let old = try fixture.store.job(id: request.jobID)
        XCTAssertEqual(old.attempt, 1)
        XCTAssertTrue(try fixture.store.releaseJobLeaseForRetry(id: old.id, leaseToken: XCTUnwrap(old.leaseToken)))
        XCTAssertEqual(try fixture.store.job(id: old.id).attempt, 0)
        // An independent runtime has an independent execution gate, just as
        // another process does. It genuinely runs Core/SQLite to completion.
        let second = await LocalOperationClient(runtime: secondRuntime).driveForegroundInboxRefreshJob(request)
        _ = try second.result.get()
        XCTAssertTrue(second.ownsTerminalEffects)
        XCTAssertEqual(try fixture.store.job(id: old.id).state, .completed)
        XCTAssertEqual(try fixture.store.job(id: old.id).attempt, 1, "The refunded attempt number is reused")
        releaseFence.signal()
        let observer = await first.value
        _ = try observer.result.get()
        XCTAssertFalse(observer.ownsTerminalEffects, "A lease-fence skip cannot claim another runtime's completion")
        XCTAssertEqual(skippedProvider.loginCount, 0)
        XCTAssertEqual(finishingProvider.loginCount, 1)
    }

    func testRequestAfterCapturedSearchNeedsNewRevisionAndLargerWholeWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        let job = try XCTUnwrap(fixture.store.claimNextJob())
        let lease = try XCTUnwrap(job.leaseToken)
        let captured = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        XCTAssertEqual(captured.recentMessageLimit, 1)
        try fixture.store.saveSyncPreferences(.init(
            accountID: fixture.account.id, downloadCompleteHistory: true, recentMessageLimit: 100
        ))
        let later = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        XCTAssertEqual(later.jobID, first.jobID, "A larger recent limit must not queue behind all history")
        XCTAssertGreaterThan(later.revision, captured.revision)
        try fixture.publish(job: job, demand: captured)
        XCTAssertNotNil(try fixture.store.foregroundInboxRefreshReceipt(first))
        XCTAssertNil(try fixture.store.foregroundInboxRefreshReceipt(later), "A pre-request SEARCH cannot acknowledge a later request")
        let pending = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        XCTAssertEqual(pending.revision, later.revision)
        XCTAssertEqual(pending.recentMessageLimit, 100)
        let reconciliation = try fixture.store.inboxSyncReconciliationGeneration(id: job.id, leaseToken: lease)
        XCTAssertTrue(try fixture.store.completeInboxSyncPass(
            id: job.id, leaseToken: lease, observedReconciliationGeneration: reconciliation, resultArtifactID: nil
        ), "Terminal transition must not overtake an unfulfilled foreground admission")
        XCTAssertEqual(try fixture.store.job(id: job.id).state, .running)
        try fixture.publish(job: job, demand: pending)
        XCTAssertNotNil(try fixture.store.foregroundInboxRefreshReceipt(later))
        XCTAssertFalse(try fixture.store.completeInboxSyncPass(
            id: job.id, leaseToken: lease, observedReconciliationGeneration: reconciliation, resultArtifactID: nil
        ))
    }

    func testCommittedReceiptSurvivesProgressTerminalLeaseClearingAndStoreReopen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        let job = try XCTUnwrap(fixture.store.claimNextJob())
        let lease = try XCTUnwrap(job.leaseToken)
        let captured = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        try fixture.publish(job: job, demand: captured)
        try fixture.store.updateJobProgress(id: job.id, leaseToken: lease, progress: .init(current: 10, total: 8000, phase: "backfill"))
        let receipt = try XCTUnwrap(fixture.store.foregroundInboxRefreshReceipt(request))
        let reconciliation = try fixture.store.inboxSyncReconciliationGeneration(id: job.id, leaseToken: lease)
        XCTAssertFalse(try fixture.store.completeInboxSyncPass(
            id: job.id, leaseToken: lease, observedReconciliationGeneration: reconciliation, resultArtifactID: nil
        ))
        XCTAssertNil(try fixture.store.job(id: job.id).leaseToken)
        let reopened = try SQLiteMailStore(path: fixture.url.path)
        try reopened.migrate()
        XCTAssertEqual(try reopened.foregroundInboxRefreshReceipt(request), receipt)
        let next = try reopened.requestForegroundInboxRefresh(fixture.input)
        XCTAssertNotEqual(next.jobID, request.jobID)
        XCTAssertNil(try reopened.foregroundInboxRefreshReceipt(next))
    }

    func testCheckpointRejectsMissingCommitWrongLeaseAndChangedNamespaceOrSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        let job = try XCTUnwrap(fixture.store.claimNextJob())
        let lease = try XCTUnwrap(job.leaseToken)
        let demand = try XCTUnwrap(fixture.store.captureForegroundInboxRefresh(jobID: job.id, leaseToken: lease))
        XCTAssertThrowsError(try fixture.store.publishForegroundInboxRefresh(
            jobID: job.id, leaseToken: lease, demand: demand, mailboxPath: "INBOX",
            uidValidity: 41, targetUIDs: [1], newlyDiscoveredCount: 1
        ))
        XCTAssertThrowsError(try fixture.store.publishForegroundInboxRefresh(
            jobID: job.id, leaseToken: "replaced-lease", demand: demand, mailboxPath: "INBOX",
            uidValidity: 41, targetUIDs: [], newlyDiscoveredCount: 0
        ))
        try fixture.publish(job: job, demand: demand)
        _ = try fixture.store.recordMailboxGeneration(accountID: fixture.account.id, mailboxPath: "INBOX", uidValidity: 42)
        XCTAssertNil(try fixture.store.foregroundInboxRefreshReceipt(request))
        XCTAssertThrowsError(try fixture.publish(job: job, demand: demand))
        // Source replacement deliberately refuses unresolved operations. Settle
        // this fixture's old owner before testing the independent source fence.
        try fixture.store.completeJob(id: job.id, leaseToken: lease, resultArtifactID: nil)
        _ = try fixture.store.replaceMailSource(AccountMailSource(
            accountID: fixture.account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 2
        ), expectedGeneration: 1)
        XCTAssertThrowsError(try fixture.store.foregroundInboxRefreshReceipt(request))
    }

    func testDisabledInboxRejectsAdmissionAndChangedSelectionUsesSerializedFollower() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        _ = try fixture.store.claimNextJob()
        let sent = Mailbox(id: MailboxID("foreground-sent"), accountID: fixture.account.id,
                           name: "Sent", path: "Sent", specialUse: "\\Sent")
        try fixture.store.cacheMailboxes([sent])
        try fixture.store.saveMailboxSyncPreference(.init(accountID: fixture.account.id, mailboxPath: "Sent", mode: .recent))
        let follower = try fixture.store.requestForegroundInboxRefresh(fixture.input)
        XCTAssertNotEqual(follower.jobID, initial.jobID)
        XCTAssertNil(try fixture.store.claimNextJob(), "One account must not acquire a parallel provider owner")
        try fixture.store.saveMailboxSyncPreference(.init(accountID: fixture.account.id, mailboxPath: "INBOX", mode: .off))
        XCTAssertThrowsError(try fixture.store.requestForegroundInboxRefresh(fixture.input))
    }

    private struct Fixture {
        let url: URL
        let store: SQLiteMailStore
        let account = PlainpostFixtures.personalAccount
        var input: PlainpostInboxSyncInput {
            .init(accountID: account.id, trigger: .manual, expectedDirectSourceGeneration: 1)
        }

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-receipt-\(UUID().uuidString).sqlite")
            store = try SQLiteMailStore(path: url.path)
            try store.migrate()
            let inbox = Mailbox(id: MailboxID("foreground-inbox"), accountID: account.id,
                                name: "INBOX", path: "INBOX", specialUse: "\\Inbox")
            try store.cacheAccountSetup(account: account, inbox: inbox, source: AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            ))
            try store.saveSyncPreferences(.init(accountID: account.id, downloadCompleteHistory: true, recentMessageLimit: 1))
            _ = try store.recordMailboxGeneration(accountID: account.id, mailboxPath: "INBOX", uidValidity: 41)
        }

        func publish(job: PlainpostDurableJob, demand: IMAPForegroundRefreshDemand) throws {
            try store.publishForegroundInboxRefresh(
                jobID: job.id, leaseToken: XCTUnwrap(job.leaseToken), demand: demand,
                mailboxPath: "INBOX", uidValidity: 41, targetUIDs: [], newlyDiscoveredCount: 0
            )
        }
        func remove() { try? FileManager.default.removeItem(at: url) }
    }
}

private final class EmptyForegroundIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let account: Account
    private let lock = NSLock()
    private var logins = 0
    var loginCount: Int { lock.withLock { logins } }
    init(account: Account) { self.account = account }
    func login(username: String, password: String) async throws { lock.withLock { logins += 1 } }
    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(id: MailboxID("foreground-inbox"), accountID: account.id, name: "INBOX", path: "INBOX", specialUse: "\\Inbox")]
    }
    func selectMailbox(_ path: String) async throws -> String { "* OK [UIDVALIDITY 41] UIDs valid" }
    func allMessageUIDs() async throws -> [Int] { [] }
    func fetchHeader(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func fetchBody(uid: Int) async throws -> String { throw IMAPClientError.connectionFailed }
    func markRead(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func markUnread(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func archive(uid: Int, archiveMailbox: String) async throws { throw IMAPClientError.connectionFailed }
    func delete(uid: Int) async throws { throw IMAPClientError.connectionFailed }
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult { throw IMAPClientError.connectionFailed }
}
