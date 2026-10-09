import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperations
@testable import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostTestSupport

/// A runtime claims a job, waits for its execution gate, then fences on the
/// lease before running. These tests pin each outcome of that fence:
/// - lease lost during the wait: skip;
/// - lease kept alive by the heartbeat: run;
/// - cancellation requested during the wait: cancel;
/// - fence could not be checked: hand the job back for retry.
final class LocalOperationRuntimeLeaseFenceTests: XCTestCase {
    func testCancelledQueuedAdmissionReturnsBeforeHolderAndPreservesPublicLeasePolicy() async throws {
        try await assertCancelledQueuedAdmission(releaseLease: false)
    }

    func testCancelledQueuedAdmissionRefundsOwnedLeaseForReleasingCaller() async throws {
        try await assertCancelledQueuedAdmission(releaseLease: true)
    }

    func testRemovingCancelledExclusiveWaiterAdmitsOtherAccountBeforeSyncHolderFinishes() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        for job in fixture.jobs.dropFirst() { try fixture.store.requestJobCancellation(id: job.id) }
        try fixture.store.cacheAccounts([PlainpostFixtures.personalAccount] + ["holding-account", "other-account"].map {
            Account(id: AccountID($0), displayName: $0, email: EmailAddress("\($0)@example.com"),
                    imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        })
        func enqueueSync(_ account: String, priority: Int) throws -> PlainpostDurableJob {
            let input = PlainpostInboxSyncInput(accountID: AccountID(account), trigger: .manual)
            return try fixture.store.enqueueJob(PlainpostJobRequest(
                kind: .inboxSync, payloadJSON: String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                priority: priority, maxAttempts: 1, idempotencyKey: account
            ))
        }
        let holder = try enqueueSync("holding-account", priority: 200)
        let successor = try enqueueSync("other-account", priority: 50)
        let holderEntered = expectation(description: "First account holds a sync permit")
        let successorEntered = expectation(description: "Other account runs before holder finishes")
        let finishHolder = DispatchSemaphore(value: 0)
        defer { finishHolder.signal() }
        let log = ExecutionLog()
        let runtime = LocalOperationRuntime(
            store: fixture.store, credentials: InMemoryCredentialVault(),
            beforeJobExecution: { job in
                log.record(job.id)
                if job.id == holder.id {
                    holderEntered.fulfill()
                    _ = finishHolder.wait(timeout: .now() + 10)
                } else if job.id == successor.id {
                    successorEntered.fulfill()
                }
                throw Sentinel()
            }
        )
        let first = Task { try await runtime.processNextJobContinuingAfterFailure() }
        await fulfillment(of: [holderEntered], timeout: 3)
        let cancelled = expectation(description: "Cancelled exclusive admission returned before sync holder")
        let second = Task {
            let result: Result<PlainpostDurableJob, Error>
            do {
                result = .success(try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[0].id))
            } catch { result = .failure(error) }
            cancelled.fulfill()
            return result
        }
        try await fixture.waitUntilClaimed(0)
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        // Admission must forget the cancelled exclusive waiter even while a
        // different account still owns a permit. Keep its refunded row from
        // being claimed again by the later drainer.
        try fixture.store.requestJobCancellation(id: fixture.jobs[0].id)
        let later = Task { try await runtime.processNextJobContinuingAfterFailure() }
        await fulfillment(of: [successorEntered], timeout: 2)
        finishHolder.signal()
        _ = try await first.value
        _ = try await later.value
        switch await second.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Expected cancelled exclusive admission to return.")
        }
        XCTAssertEqual(log.executedIDs, [holder.id, successor.id])
        XCTAssertEqual(try fixture.store.job(id: fixture.jobs[0].id).attempt, 0)
    }

    func testCancellationAfterGrantBeforeExecutionReturnsPermitAndRefundsUnusedAttempt() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        runtime.beforeLeaseFence = { job in
            if job.id == fixture.jobs[1].id {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let first = Task { try await runtime.processNextJob() }
        await fixture.provider.waitUntilHeld()
        let second = Task {
            try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[1].id)
        }
        try await fixture.waitUntilClaimed(1)
        let later = Task { try await runtime.processNextJob() }
        try await fixture.waitUntilClaimed(2)
        await fixture.provider.release()
        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("Cancellation at the granted lease fence must prevent provider admission.")
        } catch { XCTAssertTrue(error is CancellationError) }
        _ = try await later.value
        let cancelled = try fixture.store.job(id: fixture.jobs[1].id)
        XCTAssertEqual(cancelled.state, .queued)
        XCTAssertEqual(cancelled.attempt, 0)
        XCTAssertNil(cancelled.leaseToken)
        let calls = await fixture.provider.calls
        XCTAssertEqual(calls, [fixture.jobs[0].id, fixture.jobs[2].id])
    }

    func testCancelledQueuedAdmissionCannotReleaseAReplacementLease() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let first = Task { try await runtime.processNextJob() }
        await fixture.provider.waitUntilHeld()
        let finished = expectation(description: "Lost-lease cancellation leaves the queue promptly")
        let second = Task {
            let result: Result<PlainpostDurableJob, Error>
            do {
                result = .success(try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[1].id))
            } catch { result = .failure(error) }
            finished.fulfill()
            return result
        }
        try await fixture.waitUntilClaimed(1)
        let old = try fixture.store.job(id: fixture.jobs[1].id)
        XCTAssertTrue(try fixture.store.releaseJobLeaseForRetry(id: old.id, leaseToken: XCTUnwrap(old.leaseToken)))
        let replacement = try XCTUnwrap(fixture.store.claimNextJob())
        XCTAssertEqual(replacement.id, old.id)
        XCTAssertNotEqual(replacement.leaseToken, old.leaseToken)
        let later = Task { try await runtime.processNextJob() }
        try await fixture.waitUntilClaimed(2)
        second.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let preserved = try fixture.store.job(id: replacement.id)
        XCTAssertEqual(preserved.state, .running)
        XCTAssertEqual(preserved.leaseToken, replacement.leaseToken)
        XCTAssertEqual(preserved.attempt, 1)
        XCTAssertEqual(preserved.leaseExpiresAt, replacement.leaseExpiresAt)

        // Settle the independent owner so even the old broken waiter can join.
        try fixture.store.completeJob(id: replacement.id, leaseToken: XCTUnwrap(replacement.leaseToken), resultArtifactID: nil)
        await fixture.provider.release()
        _ = try await first.value
        _ = try await later.value
        switch await second.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("The cancelled old owner must return cancellation.")
        }
        let calls = await fixture.provider.calls
        XCTAssertEqual(calls, [fixture.jobs[0].id, fixture.jobs[2].id])
    }

    func testCancellationAfterDeliveryAdmissionNeverRefundsEvenForReleasingCaller() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let running = Task {
            try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[0].id)
        }
        await fixture.provider.waitUntilHeld()
        let admitted = try fixture.store.job(id: fixture.jobs[0].id)
        running.cancel()
        await fixture.provider.release(failure: .cancelled)
        do {
            _ = try await running.value
            XCTFail("Expected provider cancellation to propagate.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let stopped = try fixture.store.job(id: admitted.id)
        XCTAssertEqual(stopped.state, .running, "An admitted delivery must retain conservative lease recovery.")
        XCTAssertEqual(stopped.leaseToken, admitted.leaseToken)
        XCTAssertEqual(stopped.attempt, 1)
        XCTAssertFalse(stopped.cancellationRequested)
        _ = try fixture.store.recoverBackgroundAgentJobs(
            allowedKinds: [.approvedDelivery], now: XCTUnwrap(admitted.leaseExpiresAt).addingTimeInterval(1)
        )
        XCTAssertEqual(try fixture.store.job(id: admitted.id).state, .deliveryUncertain)
        let later = try await runtime.processNextJob()
        XCTAssertEqual(later?.id, fixture.jobs[1].id)
        XCTAssertEqual(later?.state, .completed)
    }

    func testCancellationAfterDeliveryAdmissionPreservesAmbiguousFailure() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let running = Task { try await runtime.processNextJob() }
        await fixture.provider.waitUntilHeld()
        running.cancel()
        await fixture.provider.release(failure: .ambiguous)
        do {
            _ = try await running.value
            XCTFail("Expected ambiguous delivery failure to propagate.")
        } catch { XCTAssertEqual(error as? PostSMTPPersistenceError, .localPersistenceFailed) }
        let stopped = try fixture.store.job(id: fixture.jobs[0].id)
        XCTAssertEqual(stopped.state, .deliveryUncertain)
        XCTAssertEqual(stopped.attempt, 1)
        XCTAssertNil(stopped.leaseToken)
        let later = try await runtime.processNextJob()
        XCTAssertEqual(later?.id, fixture.jobs[1].id)
    }

    func testCancellationAfterSMTPDataPreservesSuccessfulDelivery() async throws {
        try await assertCancellationAfterSMTPData(disconnectAfterData: false)
    }

    func testCancellationAfterSMTPDataPreservesUncertainDelivery() async throws {
        try await assertCancellationAfterSMTPData(disconnectAfterData: true)
    }

    func testCancellationDuringCredentialsBeforeSMTPAdmissionStillRefundsUnusedLease() async throws {
        let fixture = try AdmissionFixture(nodeBacked: false)
        defer { fixture.remove() }
        let runtime = LocalOperationRuntime(store: fixture.store, credentials: CancelledAdmissionCredentials())
        do {
            _ = try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[0].id)
            XCTFail("Expected cancellation from credential loading before SMTP admission.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let stopped = try fixture.store.job(id: fixture.jobs[0].id)
        XCTAssertEqual(stopped.state, .queued)
        XCTAssertEqual(stopped.attempt, 0)
        XCTAssertNil(stopped.leaseToken)
        XCTAssertFalse(stopped.cancellationRequested)
    }

    private func assertCancellationAfterSMTPData(disconnectAfterData: Bool) async throws {
        let dataReceived = expectation(description: "SMTP has received DATA before caller cancellation")
        let finishData = DispatchSemaphore(value: 0)
        let smtp = LocalSMTPServer(
            username: "me@example.com", password: "synthetic-password", disconnectAfterData: disconnectAfterData,
            onDataReceived: {
                dataReceived.fulfill()
                _ = finishData.wait(timeout: .now() + 10)
            }
        )
        try await smtp.start()
        defer { finishData.signal(); smtp.stop() }
        let fixture = try AdmissionFixture(nodeBacked: false)
        defer { fixture.remove() }
        let account = Account(
            id: PlainpostFixtures.personalAccount.id, displayName: "SMTP admission", email: EmailAddress("me@example.com"),
            imapHost: "127.0.0.1", smtpHost: "127.0.0.1", smtpPort: smtp.port
        )
        try fixture.store.cacheAccounts([account])
        let vault = InMemoryCredentialVault()
        try await vault.store(
            Data("synthetic-password".utf8), for: CredentialRecordKey(rawValue: "account:\(account.id.rawValue):smtp-password")
        )
        let runtime = LocalOperationRuntime(store: fixture.store, credentials: vault)
        let running = Task {
            try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[0].id)
        }
        await fulfillment(of: [dataReceived], timeout: 5)
        running.cancel()
        finishData.signal()
        do {
            let completed = try await running.value
            XCTAssertFalse(disconnectAfterData)
            XCTAssertEqual(completed.state, .completed)
        } catch {
            XCTAssertTrue(disconnectAfterData)
            XCTAssertTrue(SMTPDeliveryAmbiguity.isAmbiguous(error))
        }
        let stopped = try fixture.store.job(id: fixture.jobs[0].id)
        XCTAssertEqual(stopped.state, disconnectAfterData ? .deliveryUncertain : .completed)
        XCTAssertEqual(stopped.attempt, 1)
        XCTAssertNil(stopped.leaseToken)
        XCTAssertFalse(stopped.cancellationRequested)
        let input = try JSONDecoder().decode(PlainpostApprovalDecisionInput.self, from: Data(stopped.payloadJSON.utf8))
        XCTAssertEqual(try fixture.store.sendRequest(id: input.requestID).status, disconnectAfterData ? .deliveryUncertain : .sent)
        let accepted = await smtp.acceptedMessages()
        XCTAssertEqual(accepted.count, 1)
    }

    private func assertCancelledQueuedAdmission(releaseLease: Bool) async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let first = Task { try await runtime.processNextJob() }
        await fixture.provider.waitUntilHeld()
        let finished = expectation(description: "Cancelled admission returned while holder still owns gate")
        let second = Task {
            let result: Result<PlainpostDurableJob?, Error>
            do {
                let job = if releaseLease {
                    try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: fixture.jobs[1].id)
                } else {
                    try await runtime.processNextJob()
                }
                result = .success(job)
            } catch {
                result = .failure(error)
            }
            finished.fulfill()
            return result
        }
        try await fixture.waitUntilClaimed(1)
        let claimed = try fixture.store.job(id: fixture.jobs[1].id)
        let later = Task { try await runtime.processNextJob() }
        try await fixture.waitUntilClaimed(2)
        second.cancel()

        await fulfillment(of: [finished], timeout: 2)
        let stopped = try fixture.store.job(id: fixture.jobs[1].id)
        XCTAssertEqual(stopped.state, releaseLease ? .queued : .running)
        XCTAssertEqual(stopped.attempt, releaseLease ? 0 : 1)
        XCTAssertEqual(stopped.leaseToken, releaseLease ? nil : claimed.leaseToken)
        XCTAssertFalse(stopped.cancellationRequested, "Task cancellation is not a durable cancellation request.")
        let callsBeforeRelease = await fixture.provider.calls
        XCTAssertEqual(callsBeforeRelease, [fixture.jobs[0].id])

        await fixture.provider.release()
        _ = try await first.value
        _ = try await later.value
        switch await second.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Cancelled pre-admission caller must throw CancellationError.")
        }
        let calls = await fixture.provider.calls
        XCTAssertEqual(calls, [fixture.jobs[0].id, fixture.jobs[2].id], "Cancelled waiter must never reach the provider; the later waiter must run.")
        XCTAssertEqual(try fixture.store.job(id: fixture.jobs[2].id).state, .completed)
        if releaseLease {
            let retried = try await runtime.processNextJob()
            XCTAssertEqual(retried?.id, fixture.jobs[1].id)
            XCTAssertEqual(retried?.state, .completed)
            XCTAssertEqual(retried?.attempt, 1, "An unused admission attempt must be refunded.")
        }
    }

    func testLegacyThreadAIKeyUsesConversationGroupingWithinSelectedAccount() throws {
        let selected = MessageSummary(
            id: MessageID("selected-legacy-message"),
            threadID: ThreadID("thr_uid_legacy"),
            from: EmailAddress("sender@example.com"),
            subject: "Re: Project update",
            preview: "Selected account",
            smartCategory: .personal
        )
        let input = PlainpostAIOperationInput(
            operation: .summarizeThread,
            recordID: "thr_uid_legacy",
            conversationReferenceKind: .thread,
            accountID: AccountID("selected-account"),
            providerID: "deterministic"
        )

        XCTAssertEqual(
            try LocalOperationRuntime.resolveConversationKey(for: input, messages: [selected]),
            "legacy_subject_project update"
        )
        XCTAssertThrowsError(try LocalOperationRuntime.resolveConversationKey(for: input, messages: []))
    }

    private struct Sentinel: Error {}

    private final class ExecutionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []

        func record(_ id: String) {
            lock.withLock { ids.append(id) }
        }

        var executedIDs: [String] {
            lock.withLock { ids }
        }
    }

    private final class FenceFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int

        init(times: Int) { remaining = times }

        func fire() throws {
            let shouldThrow = lock.withLock {
                defer { remaining -= 1 }
                return remaining > 0
            }
            if shouldThrow { throw SQLiteMailStoreError.transientContention }
        }
    }

    /// One exclusive "blocker" job that holds the gate until released, plus
    /// an approved delivery for the same request that queues behind it.
    private struct Fixture {
        let directory: URL
        let store: SQLiteMailStore
        let request: SendRequest
        let blocker: PlainpostDurableJob
        let delivery: PlainpostDurableJob
        let log = ExecutionLog()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)

        init(withBlocker: Bool = true, deliveryAvailableAt: Date? = nil) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("plainpost-lease-fence-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try SQLiteMailStore(path: directory.appendingPathComponent("Plainpost.sqlite").path)
            try store.migrate()
            let draft = try store.createDraft(PlainpostFixtures.replyDraft, actor: PlainpostFixtures.codexActor)
            request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
            let payload = String(
                decoding: try JSONEncoder().encode(
                    PlainpostApprovalDecisionInput(requestID: request.id, actorID: "local-user")
                ),
                as: UTF8.self
            )
            // Any exclusive job can hold the gate; the hook stops every job
            // before it touches the request.
            blocker = try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .denySend,
                    payloadJSON: payload,
                    priority: 100,
                    maxAttempts: 1,
                    idempotencyKey: "deny-send:\(request.id.rawValue)",
                    availableAt: withBlocker ? nil : Date().addingTimeInterval(3_600)
                )
            )
            delivery = try store.enqueueJob(
                PlainpostJobRequest(
                    kind: .approvedDelivery,
                    payloadJSON: payload,
                    priority: 99,
                    maxAttempts: 1,
                    idempotencyKey: "approved-delivery:\(request.id.rawValue)",
                    availableAt: deliveryAvailableAt
                )
            )
        }

        func runtime(leaseTiming: LocalOperationRuntime.LeaseTiming = .production) -> LocalOperationRuntime {
            let (log, blockerID, started, release) = (self.log, blocker.id, blockerStarted, releaseBlocker)
            let runtime = LocalOperationRuntime(
                store: store,
                credentials: InMemoryCredentialVault(),
                beforeJobExecution: { job in
                    log.record(job.id)
                    if job.id == blockerID {
                        started.signal()
                        _ = release.wait(timeout: .now() + 30)
                    }
                    // No job needs to reach a mail server for these tests.
                    throw Sentinel()
                }
            )
            runtime.leaseTiming = leaseTiming
            return runtime
        }

        func waitForDeliveryState(_ state: PlainpostOperationState) async throws {
            let deadline = Date().addingTimeInterval(10)
            while try store.job(id: delivery.id).state != state, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testJobRecoveredWhileWaitingForTheExecutionGateIsNotExecuted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        // The first job holds the exclusive gate.
        let first = Task { try await runtime.processNextJobContinuingAfterFailure() }
        XCTAssertEqual(fixture.blockerStarted.wait(timeout: .now() + 10), .success)

        // The delivery is claimed and waits for the gate behind it.
        let second = Task { try await runtime.processNextJobContinuingAfterFailure() }
        try await fixture.waitForDeliveryState(.running)
        let claimed = try fixture.store.job(id: fixture.delivery.id)
        XCTAssertEqual(claimed.state, .running)

        // Another drainer's recovery pass sees the delivery lease as expired.
        _ = try fixture.store.recoverBackgroundAgentJobs(
            allowedKinds: [.approvedDelivery],
            now: try XCTUnwrap(claimed.leaseExpiresAt).addingTimeInterval(1)
        )
        XCTAssertEqual(try fixture.store.job(id: fixture.delivery.id).state, .deliveryUncertain)

        fixture.releaseBlocker.signal()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(fixture.log.executedIDs, [fixture.blocker.id], "The recovered delivery must not run.")
        XCTAssertEqual(try fixture.store.job(id: fixture.delivery.id).state, .deliveryUncertain)
        XCTAssertEqual(try fixture.store.sendRequest(id: fixture.request.id).status, fixture.request.status)
    }

    func testHeartbeatKeepsTheLeaseAliveWhileWaitingForTheExecutionGate() async throws {
        // The delivery is claimed with a clock 60 s in the past, so its
        // 10-second lease has expired by wall-clock time as soon as it is
        // claimed. Only a heartbeat running during the gate wait can keep it.
        let fixture = try Fixture(deliveryAvailableAt: Date(timeIntervalSince1970: 1_000_000_000))
        defer { fixture.remove() }
        let runtime = fixture.runtime(
            leaseTiming: .init(duration: 10, heartbeatInterval: .milliseconds(20))
        )

        let first = Task { try await runtime.processNextJobContinuingAfterFailure() }
        XCTAssertEqual(fixture.blockerStarted.wait(timeout: .now() + 10), .success)
        let second = Task {
            try await runtime.processNextJobContinuingAfterFailure(now: Date().addingTimeInterval(-60))
        }
        try await fixture.waitForDeliveryState(.running)
        // Not asserting the claimed expiry: the 20 ms heartbeat may already
        // have renewed it by the time this task reads the row.

        // Wait until the heartbeat renews the lease past the current time.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              (try fixture.store.job(id: fixture.delivery.id).leaseExpiresAt ?? .distantPast) <= Date() {
            try await Task.sleep(for: .milliseconds(10))
        }

        // A concurrent recovery pass now leaves the delivery alone.
        _ = try fixture.store.recoverBackgroundAgentJobs(allowedKinds: [.approvedDelivery], now: Date())
        XCTAssertEqual(try fixture.store.job(id: fixture.delivery.id).state, .running)

        fixture.releaseBlocker.signal()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(
            fixture.log.executedIDs,
            [fixture.blocker.id, fixture.delivery.id],
            "A heartbeat during the gate wait must keep the delivery runnable."
        )
    }

    func testCancellationRequestedWhileWaitingForTheExecutionGateWinsOverExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        let first = Task { try await runtime.processNextJobContinuingAfterFailure() }
        XCTAssertEqual(fixture.blockerStarted.wait(timeout: .now() + 10), .success)
        let second = Task { try await runtime.processNextJobContinuingAfterFailure() }
        try await fixture.waitForDeliveryState(.running)

        // The user cancels the approved send while it waits behind the gate.
        try fixture.store.requestJobCancellation(id: fixture.delivery.id)
        XCTAssertTrue(try fixture.store.job(id: fixture.delivery.id).cancellationRequested)

        fixture.releaseBlocker.signal()
        _ = try await first.value
        let returned = try await second.value

        XCTAssertEqual(fixture.log.executedIDs, [fixture.blocker.id], "A cancelled send must not run.")
        XCTAssertEqual(returned?.state, .cancelled)
        let cancelled = try fixture.store.job(id: fixture.delivery.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.leaseToken)
        XCTAssertNotEqual(try fixture.store.sendRequest(id: fixture.request.id).status, .sent)
    }

    func testTransientFenceErrorHandsTheJobBackForRetryWithoutExecuting() async throws {
        let fixture = try Fixture(withBlocker: false)
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let failure = FenceFailure(times: 1)
        runtime.beforeLeaseFence = { _ in try failure.fire() }

        do {
            _ = try await runtime.processNextJob()
            XCTFail("Expected the transient fence error to propagate.")
        } catch {
            XCTAssertEqual(error as? SQLiteMailStoreError, .transientContention)
        }

        XCTAssertEqual(fixture.log.executedIDs, [], "Nothing may run when the fence cannot be checked.")
        let released = try fixture.store.job(id: fixture.delivery.id)
        XCTAssertEqual(released.state, .queued)
        XCTAssertNil(released.leaseToken)
        XCTAssertEqual(released.attempt, 0, "The unused attempt is refunded, so a one-shot delivery stays claimable.")

        // The next pass claims the same delivery and runs it.
        _ = try await runtime.processNextJobContinuingAfterFailure()
        XCTAssertEqual(fixture.log.executedIDs, [fixture.delivery.id])
    }
}

/// Real durable claims and provider routing, with only the external handoff held.
struct AdmissionFixture {
    let directory: URL
    let store: SQLiteMailStore
    let jobs: [PlainpostDurableJob]
    let provider = AdmissionProvider()

    init(nodeBacked: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("Plainpost.sqlite").path)
        self.store = store
        try store.migrate()
        let account = PlainpostFixtures.personalAccount
        try store.cacheAccounts([account])
        if nodeBacked {
            _ = try store.replaceMailSource(
                AccountMailSource.direct(account.id).nodeBacked(
                    nodeID: "00000000-0000-0000-0000-000000000001",
                    logicalMailboxID: String(repeating: "A", count: 43),
                    providerIdentity: "admission-fixture"
                ), expectedGeneration: 0
            )
        }
        jobs = try (0..<3).map { index in
            let draft = try store.createDraft(Draft(
                id: DraftID("admission-draft-\(index)"), accountID: account.id,
                from: account.email, to: [EmailAddress("recipient@example.com")], cc: [], bcc: [],
                subject: "Admission \(index)", bodyPlain: "Synthetic delivery", createdBy: "codex",
                aiGenerated: false, sourceThreadID: nil
            ), actor: PlainpostFixtures.codexActor)
            let request = try store.requestSend(draftID: draft.id, actor: PlainpostFixtures.codexActor, reason: nil)
            let payload = PlainpostApprovalDecisionInput(requestID: request.id, actorID: PlainpostFixtures.guiUser.id)
            return try store.enqueueJob(PlainpostJobRequest(
                kind: .approvedDelivery,
                payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self),
                priority: 100 - index,
                maxAttempts: 1,
                idempotencyKey: "admission-\(index)"
            ))
        }
    }

    func runtime() -> LocalOperationRuntime {
        LocalOperationRuntime(
            store: store, credentials: InMemoryCredentialVault(),
            nodeModeApprovedSendHandoff: { [provider] work in try await provider.send(work) }
        )
    }

    func waitUntilClaimed(_ index: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try store.job(id: jobs[index].id).state != .running, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(try store.job(id: jobs[index].id).state, .running)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

actor AdmissionProvider {
    enum Failure { case cancelled, ambiguous }
    private(set) var calls: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var failure: Failure?

    func send(_ work: NodeModeApprovedSend) async throws {
        calls.append(work.jobID)
        if calls.count == 1 {
            await withCheckedContinuation { continuation in
                held = continuation
                let waiters = started
                started.removeAll()
                waiters.forEach { $0.resume() }
            }
            switch failure {
            case .cancelled: throw CancellationError()
            case .ambiguous: throw PostSMTPPersistenceError.localPersistenceFailed
            case nil: break
            }
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release(failure: Failure? = nil) {
        self.failure = failure
        held?.resume()
        held = nil
    }
}

private struct CancelledAdmissionCredentials: CredentialVault {
    func load(_ key: CredentialRecordKey) async throws -> Data? { throw CancellationError() }
    func store(_ secret: Data, for key: CredentialRecordKey) async throws { throw CancellationError() }
    func remove(_ key: CredentialRecordKey) async throws { throw CancellationError() }
    func loadOrCreate(
        _ keys: [CredentialRecordKey], create: @escaping @Sendable () throws -> [Data]
    ) async throws -> [Data?] { throw CancellationError() }
}
