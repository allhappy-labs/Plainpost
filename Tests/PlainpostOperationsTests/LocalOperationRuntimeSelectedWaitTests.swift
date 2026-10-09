import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
@testable import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostTestSupport

final class LocalOperationRuntimeSelectedWaitTests: XCTestCase {
    func testCancellingForegroundObserverDoesNotCancelAdmittedDurableDelivery() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        // Remove unrelated queued work from this observer-only scenario.
        for job in fixture.jobs.dropFirst() { try fixture.store.requestJobCancellation(id: job.id) }
        let worker = Task { try await runtime.processNextJob() }
        await fixture.provider.waitUntilHeld()
        let admitted = try fixture.store.job(id: fixture.jobs[0].id)
        let observer = Task { try await runtime.runUntilTerminal(jobID: admitted.id) }
        observer.cancel()
        do {
            _ = try await observer.value
            XCTFail("The foreground observer must stop waiting.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let stillRunning = try fixture.store.job(id: admitted.id)
        XCTAssertEqual(stillRunning.state, .running)
        XCTAssertEqual(stillRunning.leaseToken, admitted.leaseToken)
        XCTAssertEqual(stillRunning.attempt, 1)
        XCTAssertFalse(stillRunning.cancellationRequested)
        await fixture.provider.release()
        let completed = try await worker.value
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.attempt, 1)
        let calls = await fixture.provider.calls
        XCTAssertEqual(calls, [admitted.id])
    }

    func testForegroundWaitRejectsUnversionedSelectedSyncInsteadOfWaitingForever() async throws {
        try await assertUnclaimableSelectedSyncFails(inputGeneration: nil, currentGeneration: 1)
    }

    func testForegroundWaitRejectsWrongSelectedSyncGenerationInsteadOfWaitingForever() async throws {
        try await assertUnclaimableSelectedSyncFails(inputGeneration: 2, currentGeneration: 1)
    }

    func testForegroundWaitRejectsChangedSelectedSourceInsteadOfWaitingForever() async throws {
        try await assertUnclaimableSelectedSyncFails(inputGeneration: 1, currentGeneration: 2)
    }

    private func assertUnclaimableSelectedSyncFails(
        inputGeneration: Int64?,
        currentGeneration: Int64
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-selected-wait-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        for generation in 1...currentGeneration {
            _ = try store.replaceMailSource(AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil,
                nodeID: nil, logicalMailboxID: nil,
                providerIdentity: nil, generation: generation
            ), expectedGeneration: generation - 1)
        }
        let input = PlainpostInboxSyncInput(
            accountID: account.id, trigger: .manual,
            expectedDirectSourceGeneration: inputGeneration
        )
        let job = try store.enqueueJob(PlainpostJobRequest(
            kind: .inboxSync,
            payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
            idempotencyKey: "unclaimable-selected-wait"
        ))
        let runtime = LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            allowedJobKinds: [.inboxSync], requireExplicitDirectSource: true,
            selectedDirectAccountID: account.id, expectedDirectSourceGeneration: 1,
            requireSelectedDirectClaimScope: true
        )

        let waiter = Task { try await runtime.runUntilTerminal(jobID: job.id) }
        let timeout = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { waiter.cancel() }
        }
        defer {
            timeout.cancel()
            waiter.cancel()
        }
        do {
            _ = try await waiter.value
            XCTFail("An unclaimable selected Direct job must fail the foreground wait.")
        } catch is CancellationError {
            XCTFail("The selected Direct foreground wait did not return before its deadline.")
        } catch {
            XCTAssertEqual(error as? NodeMailModeStoreError, .generationConflict)
        }
        XCTAssertEqual(try store.job(id: job.id).state, .queued)
    }
}
