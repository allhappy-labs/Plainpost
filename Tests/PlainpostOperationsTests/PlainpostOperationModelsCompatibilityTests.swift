import Foundation
import XCTest
@testable import PlainpostOperations

final class PlainpostOperationModelsCompatibilityTests: XCTestCase {
    func testLegacyDurableJobJSONDefaultsMissingPauseRequestToFalse() throws {
        let fixture = LegacyDurableJobJSONFixture(
            id: "legacy-job",
            kind: .aiOperation,
            payloadJSON: #"{"operation":"recategorize-inbox"}"#,
            state: .running,
            priority: 42,
            availableAt: Date(timeIntervalSinceReferenceDate: 100),
            attempt: 2,
            maxAttempts: 5,
            leaseToken: "legacy-lease",
            leaseExpiresAt: Date(timeIntervalSinceReferenceDate: 200),
            cancellationRequested: false,
            idempotencyKey: "legacy-idempotency",
            pauseReason: nil,
            progress: .init(current: 3, total: 9, phase: "classifying", label: "Smart Inbox"),
            resultArtifactID: nil,
            errorCode: nil,
            errorMessage: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )

        let job = try JSONDecoder().decode(
            PlainpostDurableJob.self,
            from: JSONEncoder().encode(fixture)
        )

        XCTAssertEqual(job.id, fixture.id)
        XCTAssertEqual(job.state, fixture.state)
        XCTAssertEqual(job.leaseToken, fixture.leaseToken)
        XCTAssertEqual(job.progress, fixture.progress)
        XCTAssertFalse(job.pauseRequested)
    }

    func testCurrentDurableJobJSONRoundTripPreservesPauseRequest() throws {
        let job = PlainpostDurableJob(
            id: "current-job",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .running,
            pauseRequested: true,
            idempotencyKey: "current-idempotency"
        )

        let decoded = try JSONDecoder().decode(
            PlainpostDurableJob.self,
            from: JSONEncoder().encode(job)
        )

        XCTAssertEqual(decoded, job)
        XCTAssertTrue(decoded.pauseRequested)
    }

    func testLegacyRepositoryConformerUsesUnsupportedPauseCapabilityDefaults() {
        let repository: any DurableJobRepository = LegacyDurableJobRepository()
        let operations: [() throws -> Void] = [
            { try repository.requestJobPause(id: "legacy-job") },
            {
                try repository.acknowledgeJobPause(
                    id: "legacy-job",
                    leaseToken: "legacy-lease",
                    progress: .init(current: 1, total: 1, phase: "paused")
                )
            },
            {
                try repository.resumeUserPausedJob(
                    id: "legacy-job",
                    now: Date(timeIntervalSinceReferenceDate: 100)
                )
            },
        ]

        for operation in operations {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual(
                    $0 as? DurableJobRepositoryPauseCapabilityError,
                    .unsupported
                )
            }
        }
    }

    func testLegacyRepositoryConformerUsesDiagnosticsPageDefault() {
        let repository: any DurableJobRepository = LegacyDurableJobRepository()
        XCTAssertThrowsError(
            try repository.diagnosticsJobPage(now: Date(), anchor: nil, offset: 0, limit: 20)
        )
    }

    func testLegacyDiagnosticsPagePreservesOriginalSessionTime() throws {
        let now = Date(timeIntervalSince1970: 1_752_101_000)
        let newest = PlainpostDurableJob(
            id: "legacy-newest",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .completed,
            idempotencyKey: "legacy-newest",
            createdAt: now,
            updatedAt: now
        )
        let oldest = PlainpostDurableJob(
            id: "legacy-oldest",
            kind: .aiOperation,
            payloadJSON: plainpostTestAIOperationPayloadJSON,
            state: .completed,
            idempotencyKey: "legacy-oldest",
            createdAt: now.addingTimeInterval(-3_590),
            updatedAt: now.addingTimeInterval(-3_590)
        )
        let repository: any DurableJobRepository = LegacyDurableJobRepository(
            diagnosticJobs: [newest, oldest]
        )

        let first = try repository.diagnosticsJobPage(now: now, anchor: nil, offset: 0, limit: 1)
        let second = try repository.diagnosticsJobPage(
            now: now.addingTimeInterval(20),
            anchor: try XCTUnwrap(first.anchor),
            offset: 1,
            limit: 1
        )

        XCTAssertEqual(second.terminalJobs.map(\.id), ["legacy-oldest"])
        XCTAssertEqual(second.totalTerminalCount, 2)
    }
}

private struct LegacyDurableJobJSONFixture: Encodable {
    let id: String
    let kind: PlainpostOperationKind
    let payloadJSON: String
    let state: PlainpostOperationState
    let priority: Int
    let availableAt: Date
    let attempt: Int
    let maxAttempts: Int
    let leaseToken: String?
    let leaseExpiresAt: Date?
    let cancellationRequested: Bool
    let idempotencyKey: String
    let pauseReason: String?
    let progress: PlainpostOperationProgress?
    let resultArtifactID: String?
    let errorCode: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

private enum LegacyRepositoryStubError: Error {
    case unused
}

private final class LegacyDurableJobRepository: DurableJobRepository, @unchecked Sendable {
    private let diagnosticJobs: [PlainpostDurableJob]?

    init(diagnosticJobs: [PlainpostDurableJob]? = nil) {
        self.diagnosticJobs = diagnosticJobs
    }

    func enqueueJob(_ request: PlainpostJobRequest) throws -> PlainpostDurableJob {
        throw LegacyRepositoryStubError.unused
    }

    func job(id: String) throws -> PlainpostDurableJob {
        throw LegacyRepositoryStubError.unused
    }

    func job(idempotencyKey: String) throws -> PlainpostDurableJob? {
        throw LegacyRepositoryStubError.unused
    }

    func jobs(limit: Int) throws -> [PlainpostDurableJob] {
        throw LegacyRepositoryStubError.unused
    }

    func diagnosticsJobs(now: Date, recentTerminalLimit: Int) throws -> [PlainpostDurableJob] {
        guard let diagnosticJobs else { throw LegacyRepositoryStubError.unused }
        return Array(
            diagnosticJobs
                .filter {
                    $0.state == .queued || $0.state == .running || $0.state == .paused
                        || $0.updatedAt >= now.addingTimeInterval(-3_600)
                }
                .prefix(max(0, recentTerminalLimit))
        )
    }

    func claimNextJob(now: Date, leaseDuration: TimeInterval) throws -> PlainpostDurableJob? {
        throw LegacyRepositoryStubError.unused
    }

    func nextPendingJob(
        higherPriorityThan priority: Int,
        now: Date,
        allowedKinds: Set<PlainpostOperationKind>?
    ) throws -> PlainpostDurableJob? {
        throw LegacyRepositoryStubError.unused
    }

    func pauseJob(
        id: String,
        leaseToken: String,
        reason: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw LegacyRepositoryStubError.unused
    }

    func acknowledgeJobCancellation(id: String, leaseToken: String) throws {
        throw LegacyRepositoryStubError.unused
    }

    func updateJobProgress(
        id: String,
        leaseToken: String,
        progress: PlainpostOperationProgress
    ) throws {
        throw LegacyRepositoryStubError.unused
    }

    func renewJobLease(
        id: String,
        leaseToken: String,
        now: Date,
        leaseDuration: TimeInterval
    ) throws {
        throw LegacyRepositoryStubError.unused
    }

    func completeJob(id: String, leaseToken: String, resultArtifactID: String?) throws {
        throw LegacyRepositoryStubError.unused
    }

    func failJob(
        id: String,
        leaseToken: String,
        code: String,
        message: String,
        retryAt: Date?
    ) throws {
        throw LegacyRepositoryStubError.unused
    }

    func markDeliveryUncertain(id: String, leaseToken: String, message: String) throws {
        throw LegacyRepositoryStubError.unused
    }

    func requestJobCancellation(id: String) throws {
        throw LegacyRepositoryStubError.unused
    }

    func pruneTerminalJobs(before: Date) throws {
        throw LegacyRepositoryStubError.unused
    }
}
