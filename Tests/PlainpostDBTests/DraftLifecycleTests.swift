import SQLite3
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
import PlainpostTestSupport

final class DraftLifecycleTests: XCTestCase {
    func testCreateUpdateLookupDeleteDraftAuditsLifecycle() throws {
        let store = InMemoryMailStore()
        let actor = PlainpostFixtures.codexActor
        let created = try store.createDraft(PlainpostFixtures.replyDraft, actor: actor)
        let originalHash = created.contentHash

        let updated = try store.updateDraft(
            id: created.id,
            patch: DraftPatch(subject: "Re: Updated availability", bodyPlain: "Wednesday works better."),
            actor: actor
        )

        XCTAssertNotEqual(updated.contentHash, originalHash)
        XCTAssertEqual(updated.subject, "Re: Updated availability")
        XCTAssertEqual(updated.bodyPlain, "Wednesday works better.")
        XCTAssertEqual(try store.draft(id: created.id), updated)

        try store.deleteDraft(id: created.id, actor: actor)

        XCTAssertThrowsError(try store.draft(id: created.id)) { error in
            XCTAssertEqual(error as? PlainpostError, .notFound("Draft not found."))
        }
        XCTAssertEqual(store.auditEntries.map(\.action), ["draft.create", "draft.update", "draft.delete"])
    }

    func testSQLiteJobRequestPersistsFutureAvailabilityAndCannotBeClaimedEarly() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let availableAt = now.addingTimeInterval(10)

        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                maxAttempts: 1,
                idempotencyKey: "device-send:availability-test",
                availableAt: availableAt
            )
        )

        XCTAssertEqual(job.availableAt, availableAt)
        XCTAssertNil(try store.claimNextJob(now: now.addingTimeInterval(9), leaseDuration: 60))
        XCTAssertEqual(
            try store.claimNextJob(now: availableAt, leaseDuration: 60)?.id,
            job.id
        )
    }

    func testSQLiteQueuedJobCancellationIsAtomicAndOnlySucceedsBeforeAvailability() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let availableAt = now.addingTimeInterval(10)
        let job = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                maxAttempts: 1,
                idempotencyKey: "device-send:undo-test",
                availableAt: availableAt
            )
        )

        XCTAssertTrue(
            try store.cancelQueuedJobBeforeAvailability(
                id: job.id,
                now: now.addingTimeInterval(9)
            )
        )
        XCTAssertEqual(try store.job(id: job.id).state, .cancelled)

        let dueJob = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .searchRebuild,
                payloadJSON: plainpostTestSearchRebuildPayloadJSON,
                maxAttempts: 1,
                idempotencyKey: "device-send:undo-too-late-test",
                availableAt: availableAt
            )
        )
        XCTAssertFalse(
            try store.cancelQueuedJobBeforeAvailability(
                id: dueJob.id,
                now: availableAt
            )
        )
        XCTAssertEqual(try store.job(id: dueJob.id).state, .queued)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-draft-lifecycle-\(UUID().uuidString.lowercased()).sqlite")
    }

}
