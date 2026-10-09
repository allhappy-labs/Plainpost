import Foundation
import SQLite3
import Testing
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostTestSupport

private func makeStore() throws -> (SQLiteMailStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("smart-inbox-mode-\(UUID().uuidString).sqlite")
    let store = try SQLiteMailStore(path: url.path)
    try store.migrate()
    return (store, url)
}

private func message(_ id: String, sentAt: Date?) -> MessageSummary {
    MessageSummary(
        id: MessageID(id), threadID: nil, from: EmailAddress("a@example.com"),
        subject: id, preview: id, smartCategory: .unknown, sentAt: sentAt
    )
}

/// Drives `durable_jobs` into a state the public API won't produce on demand
/// (a runtime-owned `running` lease, or a `mail-sync` pause), mirroring the
/// raw-SQL seeding pattern used by `SmartInboxBatchRuntimeTests`.
private func executeModeStoreSQL(_ sql: String, at databaseURL: URL, arguments: [String] = []) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "SmartInboxModeStoreTests", code: 1)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "SmartInboxModeStoreTests", code: 2)
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in arguments.enumerated() {
        sqlite3_bind_text(statement, Int32(index + 1), value, -1, nil)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "SmartInboxModeStoreTests", code: 3)
    }
}

private func enqueuedRecategorizeInboxJobID(_ store: SQLiteMailStore) throws -> String {
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox, recordID: "", providerID: "deterministic"
    ).resolvingSmartInboxClassifierIdentity()
    let result = try store.enqueueSmartInboxJob(
        input: input,
        classificationInputs: try store.smartInboxClassificationInputs(scope: .allAccounts),
        catalogSnapshot: try store.smartInboxLabelCatalogSnapshot()
    )
    guard case .job(let job) = result else {
        Issue.record("Expected a queued job, got \(result)")
        return ""
    }
    return job.id
}

@Test func missingPolicyRowReadsAsAllMail() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try store.smartInboxMode() == .allMail)
    #expect(try store.smartInboxEnabled())
}

@Test func modeRoundTripsThroughThePolicyRow() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    try store.setSmartInboxMode(.newMailOnly(since: since))
    #expect(try store.smartInboxMode() == .newMailOnly(since: since))
    try store.setSmartInboxMode(.off)
    #expect(try store.smartInboxMode() == .off)
    #expect(try store.smartInboxEnabled() == false)
    try store.setSmartInboxEnabled(true)
    #expect(try store.smartInboxMode() == .allMail)
}

@Test func newMailOnlyExcludesOnlyMailWithAKnownEarlierDate() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    try store.cacheOwnedTestMessage(message("old", sentAt: cutoff.addingTimeInterval(-60)))
    try store.cacheOwnedTestMessage(message("edge", sentAt: cutoff))
    try store.cacheOwnedTestMessage(message("new", sentAt: cutoff.addingTimeInterval(60)))
    try store.cacheOwnedTestMessage(message("undated", sentAt: nil))

    try store.setSmartInboxMode(.newMailOnly(since: cutoff))
    let ids = try store.smartInboxClassificationInputs(scope: .allAccounts).map(\.message.id.rawValue)
    #expect(Set(ids) == ["edge", "new", "undated"])

    try store.setSmartInboxMode(.allMail)
    let all = try store.smartInboxClassificationInputs(scope: .allAccounts).map(\.message.id.rawValue)
    #expect(Set(all) == ["old", "edge", "new", "undated"])
}

@Test func switchingToNewMailOnlyCancelsRunningAndQueuedSortingJobs() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try store.cacheOwnedTestMessage(message("m", sentAt: Date(timeIntervalSince1970: 1)))
    let input = PlainpostAIOperationInput(
        operation: .recategorizeInbox, recordID: "", providerID: "deterministic"
    ).resolvingSmartInboxClassifierIdentity()
    let enqueueResult = try store.enqueueSmartInboxJob(
        input: input,
        classificationInputs: try store.smartInboxClassificationInputs(scope: .allAccounts),
        catalogSnapshot: try store.smartInboxLabelCatalogSnapshot()
    )
    guard case .job(let queuedJob) = enqueueResult else {
        Issue.record("Expected a queued job, got \(enqueueResult)")
        return
    }

    try store.setSmartInboxMode(.newMailOnly(since: Date()))

    let job = try store.job(id: queuedJob.id)
    #expect(job.cancellationRequested || job.state == .cancelled)
}

@Test func switchingToNewMailOnlyCancelsAPausedMailSyncSortingJob() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try store.cacheOwnedTestMessage(message("m", sentAt: Date(timeIntervalSince1970: 1)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)
    try executeModeStoreSQL(
        "UPDATE durable_jobs SET state = 'paused', pause_reason = 'mail-sync', lease_token = NULL WHERE id = ?",
        at: url, arguments: [jobID]
    )

    try store.setSmartInboxMode(.newMailOnly(since: Date()))

    let job = try store.job(id: jobID)
    #expect(job.cancellationRequested || job.state == .cancelled)
}

@Test func switchingToNewMailOnlyCancelsARunningSortingJob() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try store.cacheOwnedTestMessage(message("m", sentAt: Date(timeIntervalSince1970: 1)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)
    try executeModeStoreSQL(
        "UPDATE durable_jobs SET state = 'running', lease_token = 'test-lease' WHERE id = ?",
        at: url, arguments: [jobID]
    )

    try store.setSmartInboxMode(.newMailOnly(since: Date()))

    let job = try store.job(id: jobID)
    #expect(job.cancellationRequested)
}

@Test func reapplyingTheSameNewMailOnlyModeDoesNotCancelQueuedWork() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    try store.setSmartInboxMode(.newMailOnly(since: since))
    try store.cacheOwnedTestMessage(message("m", sentAt: since.addingTimeInterval(60)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)

    try store.setSmartInboxMode(.newMailOnly(since: since))

    let job = try store.job(id: jobID)
    #expect(job.state == .queued)
    #expect(job.cancellationRequested == false)
}

@Test func movingFromOffToNewMailOnlyCancelsAQueuedJobSeededEarlier() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try store.cacheOwnedTestMessage(message("m", sentAt: Date(timeIntervalSince1970: 1)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)
    try store.setSmartInboxMode(.off)

    try store.setSmartInboxMode(.newMailOnly(since: Date()))

    // Off leaves queued jobs queued, but the job was seeded under whatever mode
    // preceded the pause (here, the .allMail default) and can include pre-cutoff
    // mail, so it must still be cancelled on the way to New mail only.
    let job = try store.job(id: jobID)
    #expect(job.cancellationRequested || job.state == .cancelled)
}

@Test func movingFromOffToNewMailOnlyCancelsAJobOffPausedWhileRunning() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try store.cacheOwnedTestMessage(message("m", sentAt: Date(timeIntervalSince1970: 1)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)
    // Simulate the runtime having already carried out the pause that `setSmartInboxMode(.off)`
    // only requests: the job was running when Off took effect, so it ends up paused with
    // `pause_reason = 'smart-inbox-disabled'` rather than cancelled.
    try executeModeStoreSQL(
        "UPDATE durable_jobs SET state = 'paused', pause_reason = 'smart-inbox-disabled', lease_token = NULL WHERE id = ?",
        at: url, arguments: [jobID]
    )
    try store.setSmartInboxMode(.off)

    try store.setSmartInboxMode(.newMailOnly(since: Date()))

    let job = try store.job(id: jobID)
    #expect(job.cancellationRequested || job.state == .cancelled)
}

@Test func reapplyingAFractionalCutoffDoesNotCancelQueuedWork() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    // A fractional cutoff that doesn't round-trip exactly through `timeIntervalSince1970`
    // must not be treated as "later" than itself; this mirrors Task 3 persisting the mode
    // as JSON and re-deriving a `Date` on the next launch.
    let since = Date(timeIntervalSince1970: 1_700_000_000.123456)
    try store.setSmartInboxMode(.newMailOnly(since: since))
    try store.cacheOwnedTestMessage(message("m", sentAt: since.addingTimeInterval(60)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)

    try store.setSmartInboxMode(.newMailOnly(since: since))

    let job = try store.job(id: jobID)
    #expect(job.state == .queued)
    #expect(job.cancellationRequested == false)
}

@Test func reapplyingTheCurrentDateAsCutoffDoesNotCancelQueuedWork() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let since = Date()
    try store.setSmartInboxMode(.newMailOnly(since: since))
    try store.cacheOwnedTestMessage(message("m", sentAt: since.addingTimeInterval(60)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)

    try store.setSmartInboxMode(.newMailOnly(since: since))

    let job = try store.job(id: jobID)
    #expect(job.state == .queued)
    #expect(job.cancellationRequested == false)
}

@Test func movingTheCutoffEarlierDoesNotCancelQueuedWork() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    try store.setSmartInboxMode(.newMailOnly(since: since))
    try store.cacheOwnedTestMessage(message("m", sentAt: since.addingTimeInterval(60)))
    let jobID = try enqueuedRecategorizeInboxJobID(store)

    try store.setSmartInboxMode(.newMailOnly(since: since.addingTimeInterval(-60)))

    let job = try store.job(id: jobID)
    #expect(job.state == .queued)
    #expect(job.cancellationRequested == false)
}
