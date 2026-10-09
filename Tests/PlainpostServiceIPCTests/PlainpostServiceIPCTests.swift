import Darwin
import Foundation
import XCTest
import PlainpostCore
import PlainpostOperations
import PlainpostDB
import PlainpostSecrets
@testable import PlainpostServiceRuntime
@testable import PlainpostServiceIPC

final class PlainpostServiceIPCTests: XCTestCase {
    func testOwnedDeadlinePreservesConnectionFanoutAndDefaultDurations() async throws {
        for (deadline, seconds) in [(PlainpostServiceClient.Deadline.control, 5.0), (.interactive, 120.0), (.semantic, 300.0)] {
            let firstAdmitted = expectation(description: "deadline owner admitted")
            let peerAdmitted = expectation(description: "peer admitted")
            let service = ClientServiceProbe(lockAdmission: peerAdmitted, holdsLockReply: true)
            let connection = ClientConnectionProbe(service: service)
            let scheduler = ManualTimeoutScheduler()
            let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
            let first = Task {
                await client.invoke(deadline) { _, complete in
                    let _: @Sendable (Result<Void, PlainpostServiceClientError>) -> Void = complete
                    firstAdmitted.fulfill()
                }
            }
            await fulfillment(of: [firstAdmitted], timeout: 2)
            let peer = Task { try await client.lock() }
            await fulfillment(of: [peerAdmitted], timeout: 2)
            XCTAssertEqual(scheduler.scheduledDelays, [seconds, 5])
            XCTAssertTrue(scheduler.fireNext())
            let firstResult = await first.value
            XCTAssertThrowsError(try firstResult.get()) { XCTAssertEqual($0 as? PlainpostServiceClientError, .timedOut) }
            await XCTAssertThrowsErrorAsync(try await peer.value, equalTo: .serviceUnavailable)
            XCTAssertEqual(connection.invalidationCount, 1)
        }
    }

    func testAlreadyAdmittedDeadlineAfterReplyDoesNotFailLiveRPC() async throws {
        let admitted = expectation(description: "read admitted")
        let peerAdmitted = expectation(description: "peer admitted")
        let service = ClientServiceProbe(holdsStatusReply: true, statusAdmission: admitted, lockAdmission: peerAdmitted, holdsLockReply: true)
        let connection = ClientConnectionProbe(service: service)
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
        let read = Task { try await client.status() }
        await fulfillment(of: [admitted], timeout: 2)
        let staleTimerAction = try XCTUnwrap(scheduler.admitNextAction())
        let peer = Task { try await client.lock() }
        await fulfillment(of: [peerAdmitted], timeout: 2)
        service.releaseStatusReply(status: ipcUnlockedStatus(), error: nil)
        read.cancel() // A reply that already claimed completion remains the winner.
        _ = try await read.value
        staleTimerAction()
        XCTAssertEqual(connection.invalidationCount, 0)
        service.releaseLockReply(error: nil)
        let outcome = await ipcWaitOutcome { try await peer.value }
        XCTAssertEqual(outcome, .success)
    }

    func testClaimedCompletionBeforeUnregisterRejectsAlreadyAdmittedDeadline() async throws {
        for cancelWins in [false, true] {
            let admitted = expectation(description: "read admitted")
            let peerAdmitted = expectation(description: "peer admitted")
            let finishing = CheckoutBarrier()
            let scheduler = ManualTimeoutScheduler(firstCancellationBarrier: finishing)
            let service = ClientServiceProbe(holdsStatusReply: true, statusAdmission: admitted, lockAdmission: peerAdmitted, holdsLockReply: true)
            let connection = ClientConnectionProbe(service: service)
            let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
            let read = Task { await ipcWaitOutcome { _ = try await client.status() } }
            await fulfillment(of: [admitted], timeout: 2)
            let staleTimerAction = try XCTUnwrap(scheduler.admitNextAction())
            let peer = Task { try await client.lock() }
            await fulfillment(of: [peerAdmitted], timeout: 2)
            DispatchQueue.global().async {
                if cancelWins { read.cancel() }
                else { service.releaseStatusReply(status: ipcUnlockedStatus(), error: nil) }
            }
            // Completion already won, but timer.cancel is held before unregister.
            // A pending-membership check alone cannot protect this peer.
            let completionClaimed = finishing.waitUntilPaused()
            XCTAssertTrue(completionClaimed)
            if completionClaimed {
                staleTimerAction()
                XCTAssertEqual(connection.invalidationCount, 0)
            }
            finishing.release()
            // Baseline cancellation has no handler; supply its reply to join it on RED.
            if !completionClaimed { service.releaseStatusReply(status: ipcUnlockedStatus(), error: nil) }
            let outcome = await read.value
            XCTAssertEqual(outcome, cancelWins ? .cancelled : .success)
            service.releaseLockReply(error: nil)
            let peerOutcome = await ipcWaitOutcome { try await peer.value }
            XCTAssertEqual(peerOutcome, .success)
        }
    }

    func testCancelledReadDoesNotCancelOtherRPC() async throws {
        let admitted = expectation(description: "read admitted")
        let peerAdmitted = expectation(description: "peer admitted")
        let finished = expectation(description: "cancelled local wait settled")
        let service = ClientServiceProbe(holdsStatusReply: true, statusAdmission: admitted, lockAdmission: peerAdmitted, holdsLockReply: true)
        let connection = ClientConnectionProbe(service: service)
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
        let read = Task {
            let outcome = await ipcWaitOutcome { _ = try await client.status() }
            finished.fulfill()
            return outcome
        }
        await fulfillment(of: [admitted], timeout: 2)
        let staleTimerAction = try XCTUnwrap(scheduler.admitNextAction())
        let peer = Task { try await client.lock() }
        await fulfillment(of: [peerAdmitted], timeout: 2)
        read.cancel()
        await fulfillment(of: [finished], timeout: 1)
        // Release only after the cancellation assertion: this also joins the old implementation on RED.
        service.releaseStatusReply(status: ipcUnlockedStatus(), error: nil)
        let outcome = await read.value
        XCTAssertEqual(outcome, .cancelled)
        staleTimerAction()
        XCTAssertEqual(connection.invalidationCount, 0)
        service.releaseLockReply(error: nil)
        let peerOutcome = await ipcWaitOutcome { try await peer.value }
        XCTAssertEqual(peerOutcome, .success)
    }

    func testLateReplyAfterWaitCancellationCompletesOnce() async throws {
        let admitted = expectation(description: "read admitted")
        let finished = expectation(description: "local cancellation won")
        finished.assertForOverFulfill = true
        let service = ClientServiceProbe(holdsStatusReply: true, statusAdmission: admitted)
        let connection = ClientConnectionProbe(service: service)
        let client = PlainpostServiceClient(connectionFactory: { connection })
        let read = Task {
            let result = await ipcWaitOutcome { _ = try await client.status() }
            finished.fulfill()
            return result
        }
        await fulfillment(of: [admitted], timeout: 2)
        read.cancel()
        await fulfillment(of: [finished], timeout: 1)
        service.releaseStatusReply(status: ipcUnlockedStatus(), error: nil)
        service.releaseStatusReply(status: nil, error: .init(schemaVersion: 1, code: .operationFailed, detail: 0))
        connection.emitProxyError()
        connection.emit(.invalidation)
        let result = await read.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(service.statusCallCount, 1)
    }

    func testAllFourPreCancelledReadsDoNotRegisterScheduleOrSend() async throws {
        let operations: [@Sendable (PlainpostServiceClient) async throws -> Void] = [
            { _ = try await $0.status() }, { _ = try await $0.nodeSessionIdentityReadiness() },
            { _ = try await $0.nodeMailModeStatus() }, { _ = try await $0.serviceIdentity() },
        ]
        for operation in operations {
            let service = ClientServiceProbe()
            let connection = ClientConnectionProbe(service: service)
            let scheduler = ManualTimeoutScheduler()
            let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
            let start = IPCWaitGate()
            let read = Task { await start.wait(); return await ipcWaitOutcome { try await operation(client) } }
            read.cancel()
            await start.release()
            let result = await read.value
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(scheduler.scheduledDelays, [])
            XCTAssertEqual(service.statusCallCount, 0)
            XCTAssertEqual(connection.invalidationCount, 0)
            try await client.lock()
            XCTAssertEqual(scheduler.scheduledDelays, [5])
        }
    }

    func testReadCancellationAfterRegistrationBeforeSendDoesNotOrphanWaiter() async throws {
        let service = ClientServiceProbe()
        let connection = ClientConnectionProbe(service: service)
        let scheduler = ManualTimeoutScheduler()
        let barrier = CheckoutBarrier()
        let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler, checkoutBarrier: barrier.pause)
        let read = Task { await ipcWaitOutcome { _ = try await client.status() } }
        XCTAssertTrue(barrier.waitUntilPaused())
        read.cancel()
        barrier.release()
        let result = await read.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(service.statusCallCount, 0)
        XCTAssertEqual(scheduler.scheduledDelays, [])
        XCTAssertEqual(connection.invalidationCount, 0)
    }

    func testPreCancelledReadDoesNotWaitForReconnectConfiguration() async throws {
        let firstConnection = ClientConnectionProbe(service: ClientServiceProbe())
        let activation = CheckoutBarrier()
        let replacementService = ClientServiceProbe()
        let replacement = ClientConnectionProbe(service: replacementService, activationBarrier: activation)
        let factory = ClientConnectionFactoryProbe([firstConnection, replacement])
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(connectionFactory: factory.make, timeouts: .init(), timeoutScheduler: scheduler)
        firstConnection.emit(.invalidation)
        let configuringRPC = Task { try await client.lock() }
        XCTAssertTrue(activation.waitUntilPaused())
        let start = IPCWaitGate()
        let finished = expectation(description: "pre-cancelled read settles while reconnect is held")
        let read = Task {
            await start.wait()
            let result = await ipcWaitOutcome { _ = try await client.status() }
            finished.fulfill()
            return result
        }
        read.cancel()
        await start.release()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(scheduler.scheduledDelays, [])
        XCTAssertEqual(replacementService.statusCallCount, 0)
        activation.release()
        let result = await read.value
        XCTAssertEqual(result, .cancelled)
        try await configuringRPC.value
        XCTAssertEqual(scheduler.scheduledDelays, [5])
        XCTAssertEqual(replacement.invalidationCount, 0)
    }

    func testCancelledWaitPreservesAdmittedDurableWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-ipc-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Plainpost.sqlite")
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let actor = Actor(id: "ipc-test-user", kind: .user, displayName: "Test", permissions: .guiUser)
        let account = Account(id: AccountID("ipc-account"), displayName: "Test", email: EmailAddress("me@example.com"), imapHost: "127.0.0.1", smtpHost: "127.0.0.1")
        try store.cacheAccounts([account])
        let draft = Draft(id: DraftID("ipc-draft"), accountID: account.id, from: account.email, to: [EmailAddress("recipient@example.com")], cc: [], bcc: [], subject: "Synthetic", bodyPlain: "Fixture", createdBy: actor.id, aiGenerated: false, sourceThreadID: nil)
        _ = try store.createDraft(draft, actor: actor)
        let request = try store.requestSend(draftID: draft.id, actor: actor, reason: nil)
        let decision = PlainpostApprovalDecisionInput(requestID: request.id, actorID: actor.id)
        let admitted = expectation(description: "service export persisted and claimed write")
        let owner = IPCDurableWriteOwner(store: store, admitted: admitted)
        let coordinator = PlainpostServiceLifecycleCoordinator(vaultSession: VaultSession(provider: IPCVaultKeyProvider()), prepareForegroundUnlock: {}, beginVaultLockdown: {}, confirmVaultLocked: {}, reopenRuntimeConstruction: {})
        try await coordinator.unlock(prompt: "Synthetic fixture", capability: .app)
        let listener = PlainpostServiceListener(lifecycleCoordinator: coordinator, performForegroundOperation: { try await owner.run($0) })
        let connection = ClientConnectionProbe(service: listener.exportedService(for: .app))
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(connectionFactory: { connection }, timeouts: .init(), timeoutScheduler: scheduler)
        let write = Task { try await client.perform(.denySend(decision)) }
        await fulfillment(of: [admitted], timeout: 2)
        write.cancel()
        // Independent SQLite reader proves persisted identity/lease survived local Task cancellation.
        let reader = try SQLiteMailStore(path: databaseURL.path, readOnly: true)
        let running = try XCTUnwrap(reader.job(idempotencyKey: "deny-send:\(request.id.rawValue)"))
        XCTAssertEqual(running.state, .running)
        XCTAssertFalse(running.cancellationRequested)
        XCTAssertNotNil(running.leaseToken)
        let status = try await client.status()
        XCTAssertEqual(status.availability, .unlocked)
        XCTAssertEqual(scheduler.scheduledDelays, [300, 5])
        XCTAssertEqual(connection.invalidationCount, 0)
        await owner.release()
        guard case .denySend = try await write.value else { return XCTFail("Wrong write reply") }
        let completed = try reader.job(id: running.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertFalse(completed.cancellationRequested)
        XCTAssertEqual(completed.idempotencyKey, running.idempotencyKey)
        XCTAssertEqual(try reader.jobs().count, 1)
        let ownership = await owner.observation
        XCTAssertEqual(ownership.calls, 1)
        XCTAssertFalse(ownership.cancelledBefore)
        XCTAssertFalse(ownership.cancelledAfter)
    }

    func testAllowedIdentityMatrixIsExact() {
        let validator = PlainpostClientValidator(verifier: .rejecting)
        XCTAssertEqual(
            validator.capability(for: .init(
                teamIdentifier: "9XN7WN8JN2",
                bundleIdentifier: "com.marynavdovenko.Plainpost"
            )),
            .app
        )
        XCTAssertEqual(
            validator.capability(for: .init(
                teamIdentifier: "9XN7WN8JN2",
                bundleIdentifier: "com.marynavdovenko.Plainpost.CLI"
            )),
            .cli
        )
        XCTAssertEqual(
            validator.capability(for: .init(
                teamIdentifier: "9XN7WN8JN2",
                bundleIdentifier: "com.marynavdovenko.Plainpost.BrowserHost"
            )),
            .browserHost
        )
        XCTAssertEqual(
            validator.capability(for: .init(
                teamIdentifier: "9XN7WN8JN2",
                bundleIdentifier: "com.marynavdovenko.Plainpost.BackgroundAgent"
            )),
            .agent
        )
        XCTAssertNil(
            validator.capability(for: .init(
                teamIdentifier: "FG6INVALID",
                bundleIdentifier: "com.marynavdovenko.Plainpost"
            ))
        )
        XCTAssertNil(
            validator.capability(for: .init(
                teamIdentifier: "9XN7WN8JN2",
                bundleIdentifier: "com.marynavdovenko.Plainpost.Service"
            ))
        )
    }

    func testMalformedAuditTokensNeverReachGuestCodeLookup() {
        let recorder = AuditVerifierRecorder()
        let validator = PlainpostClientValidator(verifier: recorder.verifier)
        let size = MemoryLayout<audit_token_t>.size

        for malformedSize in [0, size - 1, size + 1] {
            XCTAssertNil(
                validator.capability(
                    forAuditTokenData: Data(repeating: 0xA5, count: malformedSize)
                )
            )
        }

        XCTAssertEqual(recorder.guestCodeLookupCount, 0)
    }

    func testAuditTokenValidationUsesEveryExactDesignatedRequirement() {
        let token = Data(repeating: 0x5A, count: MemoryLayout<audit_token_t>.size)
        let expectedRequirements = [
            "anchor apple generic and certificate leaf[subject.OU] = \"9XN7WN8JN2\" and identifier \"com.marynavdovenko.Plainpost\"",
            "anchor apple generic and certificate leaf[subject.OU] = \"9XN7WN8JN2\" and identifier \"com.marynavdovenko.Plainpost.CLI\"",
            "anchor apple generic and certificate leaf[subject.OU] = \"9XN7WN8JN2\" and identifier \"com.marynavdovenko.Plainpost.BrowserHost\"",
            "anchor apple generic and certificate leaf[subject.OU] = \"9XN7WN8JN2\" and identifier \"com.marynavdovenko.Plainpost.BackgroundAgent\"",
        ]

        for (index, capability) in PlainpostClientCapability.allCases.enumerated() {
            let recorder = AuditVerifierRecorder(matchingRequirements: [expectedRequirements[index]])
            XCTAssertEqual(
                PlainpostClientValidator(verifier: recorder.verifier)
                    .capability(forAuditTokenData: token),
                capability
            )
            XCTAssertEqual(recorder.auditTokens, [token])
            XCTAssertEqual(recorder.requirements, expectedRequirements)
        }
    }

    func testRequirementCreationFailureRejectsAuditToken() {
        let recorder = AuditVerifierRecorder(failedRequirementIndex: 2)
        let validator = PlainpostClientValidator(verifier: recorder.verifier)

        XCTAssertNil(
            validator.capability(
                forAuditTokenData: Data(
                    repeating: 0,
                    count: MemoryLayout<audit_token_t>.size
                )
            )
        )
    }

    func testFailedDesignatedRequirementCheckRejectsAuditToken() {
        let recorder = AuditVerifierRecorder()
        let validator = PlainpostClientValidator(verifier: recorder.verifier)

        XCTAssertNil(
            validator.capability(
                forAuditTokenData: Data(
                    repeating: 0,
                    count: MemoryLayout<audit_token_t>.size
                )
            )
        )
    }

    func testMultipleDesignatedRequirementMatchesRejectAuditToken() {
        let recorder = AuditVerifierRecorder(matchingRequirements: [
            PlainpostClientValidator.requirement(for: "com.marynavdovenko.Plainpost"),
            PlainpostClientValidator.requirement(for: "com.marynavdovenko.Plainpost.CLI"),
        ])
        let validator = PlainpostClientValidator(verifier: recorder.verifier)

        XCTAssertNil(
            validator.capability(
                forAuditTokenData: Data(
                    repeating: 0,
                    count: MemoryLayout<audit_token_t>.size
                )
            )
        )
    }

    func testUnavailableAuditTokenKVCFailsClosed() {
        XCTAssertNil(
            PlainpostXPCConnectionAuditTokenBridge.auditTokenData(
                for: NSObject()
            )
        )
    }

    func testMalformedAndExceptionalAuditTokenKVCValuesFailClosed() {
        XCTAssertNil(
            PlainpostXPCConnectionAuditTokenBridge.auditTokenData(
                for: NonValueAuditTokenObject()
            )
        )
        XCTAssertNil(
            PlainpostXPCConnectionAuditTokenBridge.auditTokenData(
                for: WrongTypeAuditTokenObject()
            )
        )
        XCTAssertNil(
            PlainpostXPCConnectionAuditTokenBridge.auditTokenData(
                for: ThrowingAuditTokenObject()
            )
        )
    }

    func testStatusDTORejectsInvalidSchemaAvailabilityCountAndDetail() throws {
        XCTAssertNil(
            PlainpostVaultStatusDTO(
                schemaVersion: 2,
                availability: .locked,
                matchingKeyItemCount: 0,
                detail: 0
            )
        )
        XCTAssertNil(
            PlainpostVaultStatusDTO(
                schemaVersion: 1,
                availability: PlainpostVaultAvailability(rawValue: 99)!,
                matchingKeyItemCount: 0,
                detail: 0
            )
        )
        XCTAssertNil(
            PlainpostVaultStatusDTO(
                schemaVersion: 1,
                availability: .locked,
                matchingKeyItemCount: -1,
                detail: 0
            )
        )
        XCTAssertNil(
            PlainpostVaultStatusDTO(
                schemaVersion: 1,
                availability: .locked,
                matchingKeyItemCount: 0,
                detail: 7
            )
        )
        XCTAssertNil(
            PlainpostVaultStatusDTO(
                schemaVersion: 1,
                availability: .unsupportedVersion,
                matchingKeyItemCount: 1,
                detail: 0
            )
        )

        let invalidArchive = try archive { coder in
            coder.encode(1, forKey: "schemaVersion")
            coder.encode(99, forKey: "availability")
            coder.encode(0, forKey: "matchingKeyItemCount")
            coder.encode(0, forKey: "detail")
        }
        XCTAssertNil(try decodeStatus(invalidArchive))
    }

    func testErrorDTORejectsInvalidSchemaCodeAndInconsistentDetail() throws {
        XCTAssertNil(
            PlainpostXPCErrorDTO(
                schemaVersion: 2,
                code: .vaultLocked,
                detail: 0
            )
        )
        XCTAssertNil(
            PlainpostXPCErrorDTO(
                schemaVersion: 1,
                code: PlainpostXPCErrorCode(rawValue: 99)!,
                detail: 0
            )
        )
        XCTAssertNil(
            PlainpostXPCErrorDTO(
                schemaVersion: 1,
                code: .vaultLocked,
                detail: 7
            )
        )
        XCTAssertNil(
            PlainpostXPCErrorDTO(
                schemaVersion: 1,
                code: .unsupportedVaultVersion,
                detail: 0
            )
        )
        XCTAssertNil(PlainpostXPCErrorDTO(schemaVersion: 1, code: .operationFailed, detail: -1))
        XCTAssertNotNil(
            PlainpostXPCErrorDTO(schemaVersion: 1, code: .operationFailed, detail: 1),
            "an operation failure may name a mail-action refusal"
        )

        let invalidArchive = try archive { coder in
            coder.encode(1, forKey: "schemaVersion")
            coder.encode(99, forKey: "code")
            coder.encode(0, forKey: "detail")
        }
        XCTAssertNil(try decodeError(invalidArchive))
    }

    func testBrowserAndDraftDTOsRejectMalformedAndOversizedPayloads() {
        XCTAssertNil(
            PlainpostSmartInboxBatchRequestDTO(
                schemaVersion: 1,
                accountID: "account-1",
                category: "seen",
                action: "archive_read",
                archiveMailbox: String(repeating: "x", count: 1_025)
            )
        )
        XCTAssertNil(
            PlainpostSmartInboxBatchResultDTO(
                schemaVersion: 1,
                accountID: "account-1",
                category: "seen",
                action: "archive_read",
                affectedMessageIDs: Array(
                    repeating: "message-1",
                    count:
                        PlainpostSmartInboxBatchContract
                            .maximumAffectedMessageCount + 1
                ),
                archiveMailbox: "Archive"
            )
        )
        XCTAssertNil(
            PlainpostBrowserApprovedReplyRequestDTO(
                schemaVersion: 2,
                jobID: "job-1"
            )
        )
        for invalidJobID in [
            "",
            " job-1",
            "job-\u{0000}",
            String(repeating: "x", count: 1_025),
        ] {
            XCTAssertNil(
                PlainpostBrowserApprovedReplyRequestDTO(
                    schemaVersion: 1,
                    jobID: invalidJobID
                )
            )
        }
        XCTAssertNil(
            PlainpostDraftSyncRequestDTO(
                schemaVersion: 1,
                draftID: "draft-1",
                mailbox: String(repeating: "x", count: 1_025)
            )
        )
        XCTAssertNil(
            PlainpostDraftSyncResultDTO(
                schemaVersion: 1,
                draftID: "draft-1",
                mailbox: "Drafts",
                serverDraftUID: -1
            )
        )
        XCTAssertNil(
            PlainpostBackgroundJobResultDTO(
                schemaVersion: 1,
                recoveredJobCount: -1,
                processedJobCount: 0
            )
        )
    }

    func testStatusValueMapsEveryAvailabilityWithoutCollapsingFailureStates() throws {
        let cases: [(PlainpostVaultAvailability, Int, PlainpostVaultStatus.Availability)] = [
            (.locked, 0, .locked),
            (.unlocked, 1, .unlocked),
            (.keyMissing, 0, .keyMissing),
            (.keyAmbiguous, 2, .keyAmbiguous),
            (.ciphertextInvalid, 1, .ciphertextInvalid),
            (.unsupportedVersion, 1, .unsupportedVersion(7)),
        ]

        for (availability, count, expected) in cases {
            let dto = try XCTUnwrap(
                PlainpostVaultStatusDTO(
                    schemaVersion: 1,
                    availability: availability,
                    matchingKeyItemCount: count,
                    detail: availability == .unsupportedVersion ? 7 : 0
                )
            )
            XCTAssertEqual(
                try PlainpostVaultStatus(dto: dto),
                PlainpostVaultStatus(
                    availability: expected,
                    matchingKeyItemCount: count
                )
            )
        }
    }

    func testXPCErrorMappingPreservesEveryClosedServiceFailure() throws {
        let cases: [(PlainpostXPCErrorCode, Int, PlainpostServiceClientError)] = [
            (.vaultLocked, 0, .vaultLocked),
            (.authorizationCancelled, 0, .authorizationCancelled),
            (.authorizationFailed, 0, .authorizationFailed),
            (.vaultKeyMissing, 0, .vaultKeyMissing),
            (.vaultKeyAmbiguous, 0, .vaultKeyAmbiguous),
            (.ciphertextInvalid, 0, .ciphertextInvalid),
            (.unsupportedVaultVersion, 7, .unsupportedVaultVersion(7)),
            (.clientUnauthorized, 0, .clientUnauthorized),
            (.invalidRequest, 0, .invalidRequest),
            (.operationFailed, 0, .operationFailed),
        ]

        for (code, detail, expected) in cases {
            let dto = try XCTUnwrap(
                PlainpostXPCErrorDTO(
                    schemaVersion: 1,
                    code: code,
                    detail: detail
                )
            )
            XCTAssertEqual(PlainpostServiceClientError(dto: dto), expected)
        }
    }

    func testClientUsesExactServiceAndPublishedDeadlines() {
        XCTAssertEqual(PlainpostServiceClient.machServiceName, "com.marynavdovenko.Plainpost.Service")
        let timeouts = PlainpostServiceClientTimeouts()
        XCTAssertEqual(timeouts.control, 5)
        XCTAssertEqual(timeouts.interactive, 120)
        XCTAssertEqual(timeouts.semantic, 300)
    }

    func testAccountPasswordPayloadsAreRequestOnlyAndDescriptionsAreRedacted() throws {
        let imapPassword = "imap-top-secret"
        let smtpPassword = "smtp-top-secret"
        let payload = PlainpostAccountSetupPayload(
            displayName: "Example", email: "me@example.com", imapHost: "imap.example.com",
            imapPort: 993, smtpHost: "smtp.example.com", smtpPort: 587, username: "me@example.com",
            sentMailbox: "Sent", imapPassword: imapPassword, smtpPassword: smtpPassword)
        let operation = PlainpostForegroundOperation.accountAdd(payload)
        let request = try operation.requestDTO()
        let replacement = PlainpostAccountCredentialReplacementPayload(
            accountID: "account-1",
            imapPassword: imapPassword,
            smtpPassword: smtpPassword
        )
        let result = try PlainpostForegroundOperationResult.accountAdd(
            PlainpostAccountSetupSemanticResult(
                accountID: "account-1", email: "me@example.com", isIMAPVerified: true,
                isSMTPVerified: true, syncedMessageCount: 1)
        ).responseDTO()

        for description in [
            String(describing: payload), String(reflecting: payload),
            String(describing: operation), String(reflecting: operation),
            String(describing: request), String(reflecting: request),
            String(describing: result), String(reflecting: result),
            String(decoding: result.archivedPayload, as: UTF8.self),
            Mirror(reflecting: payload).children
                .map { String(describing: $0.value) }
                .joined(separator: "|"),
            Mirror(reflecting: replacement).children
                .map { String(describing: $0.value) }
                .joined(separator: "|"),
        ] {
            XCTAssertFalse(description.contains(imapPassword))
            XCTAssertFalse(description.contains(smtpPassword))
        }
    }

    func testAccountDeletionEnvelopeRoundTripsValidatesStableIDAndCorrelatesResult() throws {
        let payload = PlainpostAccountDeletionPayload(accountID: "account-1")
        let operation = PlainpostForegroundOperation.deleteAccount(payload)

        try operation.validate()
        let decoded = try PlainpostForegroundOperation(
            requestDTO: operation.requestDTO()
        )
        guard case .deleteAccount(let decodedPayload) = decoded else {
            return XCTFail("Expected account deletion request.")
        }
        XCTAssertEqual(decodedPayload.accountID, "account-1")

        let result = PlainpostForegroundOperationResult.deleteAccount
        let decodedResult = try PlainpostForegroundOperationResult(
            responseDTO: result.responseDTO()
        )
        guard case .deleteAccount = decodedResult else {
            return XCTFail("Expected account deletion result.")
        }
        XCTAssertTrue(decodedResult.isSemanticallyCorrelated(with: operation))
        XCTAssertFalse(
            decodedResult.isSemanticallyCorrelated(
                with: .accountTest(
                    PlainpostAccountSetupPayload(
                        displayName: "Example",
                        email: "me@example.com",
                        imapHost: "imap.example.com",
                        imapPort: 993,
                        smtpHost: "smtp.example.com",
                        smtpPort: 587,
                        username: "me@example.com",
                        sentMailbox: "Sent",
                        imapPassword: "imap-secret",
                        smtpPassword: "smtp-secret"
                    )
                )
            )
        )

        for unstableID in [
            "",
            " ",
            "account-1\n",
            "account-\u{0007}",
            String(repeating: "a", count: 1_025),
        ] {
            XCTAssertThrowsError(
                try PlainpostForegroundOperation.deleteAccount(
                    PlainpostAccountDeletionPayload(accountID: unstableID)
                ).validate(),
                "ID: \(unstableID.debugDescription)"
            ) {
                XCTAssertEqual(
                    $0 as? PlainpostForegroundOperationError,
                    .invalidEnvelope
                )
            }
        }

        for description in [
            String(describing: payload),
            String(reflecting: payload),
            String(describing: operation),
            String(reflecting: result),
        ] {
            XCTAssertFalse(description.localizedCaseInsensitiveContains("password"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("credential"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("secret"))
        }
    }

    func testAccountDeletionIsAppOnlyAtClientBoundary() async throws {
        let response = try PlainpostForegroundOperationResult.deleteAccount.responseDTO()
        let service = ClientServiceProbe(foregroundReply: (response, nil))
        let factory: @Sendable () -> PlainpostServiceClientConnection = {
            ClientConnectionProbe(service: service)
        }
        let operation = PlainpostForegroundOperation.deleteAccount(
            PlainpostAccountDeletionPayload(accountID: "account-1")
        )

        let app = PlainpostServiceClient(
            connectionFactory: factory,
            capability: .app
        )
        guard case .deleteAccount = try await app.perform(operation) else {
            return XCTFail("Expected app account deletion result.")
        }

        for capability in [
            PlainpostClientCapability.cli,
            .agent,
            .browserHost,
        ] {
            let client = PlainpostServiceClient(
                connectionFactory: factory,
                capability: capability
            )
            await XCTAssertThrowsErrorAsync(
                try await client.perform(operation),
                equalTo: .clientUnauthorized
            )
        }
    }

    func testNodeSessionIsAppOnlyAtClientBoundaryAndDecodesReplies() async throws {
        let service = ClientServiceProbe()
        service.nodeSessionReply = (try PlainpostNodeSessionResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)).dto(), nil)
        service.nodeSessionReadinessReply = ("ready", nil)
        let factory: @Sendable () -> PlainpostServiceClientConnection = { ClientConnectionProbe(service: service) }
        let request = try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data())

        let app = PlainpostServiceClient(connectionFactory: factory, capability: .app)
        let response = try await app.performNodeSessionRequest(request)
        XCTAssertEqual(response.body, Data("{}".utf8))
        try await app.invalidateNodeSession()
        let readiness = try await app.nodeSessionIdentityReadiness()
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(service.nodeSessionRequests.map(\.path), ["/v1/status"])
        XCTAssertEqual(service.nodeSessionInvalidations, 1)

        service.nodeSessionReadinessReply = ("future_value", nil)
        await XCTAssertThrowsErrorAsync(try await app.nodeSessionIdentityReadiness(), equalTo: .operationFailed)
        service.nodeSessionReply = (nil, PlainpostXPCErrorDTO(schemaVersion: 1, code: .nodeSessionFailed, detail: PlainpostNodeSessionFailure.pathNotAllowed.rawValue))
        await XCTAssertThrowsErrorAsync(try await app.performNodeSessionRequest(request), equalTo: .nodeSession(.pathNotAllowed))

        for capability in [PlainpostClientCapability.cli, .agent, .browserHost] {
            let client = PlainpostServiceClient(connectionFactory: factory, capability: capability)
            await XCTAssertThrowsErrorAsync(try await client.performNodeSessionRequest(request), equalTo: .clientUnauthorized)
            await XCTAssertThrowsErrorAsync(try await client.invalidateNodeSession(), equalTo: .clientUnauthorized)
            await XCTAssertThrowsErrorAsync(try await client.nodeSessionIdentityReadiness(), equalTo: .clientUnauthorized)
        }
        XCTAssertEqual(service.nodeSessionRequests.count, 2, "other clients never reach the service")
        XCTAssertEqual(service.nodeSessionInvalidations, 1)
    }

    func testNodeMailModeStatusIsAppOnlyAtClientBoundaryAndDecodesReplies() async throws {
        let service = ClientServiceProbe()
        service.nodeMailModeStatusReply = (
            try PlainpostNodeMailModeStatus(state: .connectedDirectly, nodeBackedAccountCount: 1, waitingIntentCount: 4).dto(), nil
        )
        let factory: @Sendable () -> PlainpostServiceClientConnection = { ClientConnectionProbe(service: service) }
        let app = PlainpostServiceClient(connectionFactory: factory, capability: .app)
        let status = try await app.nodeMailModeStatus()
        XCTAssertEqual(status, PlainpostNodeMailModeStatus(state: .connectedDirectly, nodeBackedAccountCount: 1, waitingIntentCount: 4))

        service.nodeMailModeStatusReply = (nil, PlainpostXPCErrorDTO(schemaVersion: 1, code: .clientUnauthorized, detail: 0))
        await XCTAssertThrowsErrorAsync(try await app.nodeMailModeStatus(), equalTo: .clientUnauthorized)
        for capability in [PlainpostClientCapability.cli, .agent, .browserHost] {
            let client = PlainpostServiceClient(connectionFactory: factory, capability: capability)
            await XCTAssertThrowsErrorAsync(try await client.nodeMailModeStatus(), equalTo: .clientUnauthorized)
        }
    }

    func testServiceIdentityIsAppOnlyAtClientBoundaryAndDecodesReplies() async throws {
        let service = ClientServiceProbe()
        service.serviceIdentityReply = ("/Applications/Plainpost.app/Contents/Library/Helpers/PlainpostService.app", "7|1:2:3", nil)
        let factory: @Sendable () -> PlainpostServiceClientConnection = { ClientConnectionProbe(service: service) }
        let app = PlainpostServiceClient(connectionFactory: factory, capability: .app)
        let identity = try await app.serviceIdentity()
        XCTAssertEqual(identity, PlainpostServiceBuildIdentity(
            bundlePath: "/Applications/Plainpost.app/Contents/Library/Helpers/PlainpostService.app",
            buildStamp: "7|1:2:3"
        ))

        service.serviceIdentityReply = (nil, nil, nil)
        let unbundled = try await app.serviceIdentity()
        XCTAssertNil(unbundled, "an unbundled service has no identity")
        service.serviceIdentityReply = ("", "stamp", nil)
        let empty = try await app.serviceIdentity()
        XCTAssertNil(empty)
        service.serviceIdentityReply = (String(repeating: "a", count: 4097), "stamp", nil)
        let oversized = try await app.serviceIdentity()
        XCTAssertNil(oversized)

        service.serviceIdentityReply = (nil, nil, PlainpostXPCErrorDTO(schemaVersion: 1, code: .clientUnauthorized, detail: 0))
        await XCTAssertThrowsErrorAsync(try await app.serviceIdentity(), equalTo: .clientUnauthorized)
        for capability in [PlainpostClientCapability.cli, .agent, .browserHost] {
            let client = PlainpostServiceClient(connectionFactory: factory, capability: capability)
            await XCTAssertThrowsErrorAsync(try await client.serviceIdentity(), equalTo: .clientUnauthorized)
        }
    }

    func testStartOverAfterVaultKeyLossIsAppOnlyAndCarriesTheReasonAndError() async throws {
        let service = ClientServiceProbe()
        let factory: @Sendable () -> PlainpostServiceClientConnection = { ClientConnectionProbe(service: service) }
        let app = PlainpostServiceClient(connectionFactory: factory, capability: .app)

        try await app.startOverAfterVaultKeyLoss(reason: "Unlock Plainpost")
        XCTAssertEqual(service.startOverReasons, ["Unlock Plainpost"])

        service.startOverReply = PlainpostXPCErrorDTO(schemaVersion: 1, code: .invalidRequest, detail: 0)
        await XCTAssertThrowsErrorAsync(try await app.startOverAfterVaultKeyLoss(reason: "Unlock Plainpost"), equalTo: .invalidRequest)
        for capability in [PlainpostClientCapability.cli, .agent, .browserHost] {
            let client = PlainpostServiceClient(connectionFactory: factory, capability: capability)
            await XCTAssertThrowsErrorAsync(
                try await client.startOverAfterVaultKeyLoss(reason: "Unlock Plainpost"),
                equalTo: .clientUnauthorized
            )
        }
        XCTAssertEqual(service.startOverReasons.count, 2)
    }

    func testSemanticEnvelopeRejectsKindPayloadMismatchWithoutEchoingPayload() throws {
        let secret = "never-echo-this-password"
        let payload = PlainpostAccountCredentialReplacementPayload(
            accountID: "account-1", imapPassword: secret, smtpPassword: secret)
        let replacement = try PlainpostForegroundOperation.replaceAccountCredentials(payload)
            .requestDTO()
        let mismatched = try XCTUnwrap(
            PlainpostForegroundOperationRequestDTO(
                schemaVersion: replacement.schemaVersion, kind: .markRead,
                archivedPayload: replacement.archivedPayload))

        XCTAssertThrowsError(try PlainpostForegroundOperation(requestDTO: mismatched)) {
            XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
            XCTAssertFalse(String(describing: $0).contains(secret))
        }
    }

    func testArchivePayloadBoundsAndRoundTripsNonDefaultMailbox() throws {
        let operation = PlainpostForegroundOperation.archive(
            PlainpostMailActionPayload(
                messageID: "message-1",
                archiveMailbox: "Processed/2026"
            )
        )

        try operation.validate()
        let decoded = try PlainpostForegroundOperation(
            requestDTO: operation.requestDTO()
        )
        guard case .archive(let payload) = decoded else {
            return XCTFail("Expected archive operation.")
        }
        XCTAssertEqual(payload.messageID, "message-1")
        XCTAssertEqual(payload.archiveMailbox, "Processed/2026")

        XCTAssertThrowsError(
            try PlainpostForegroundOperation.archive(
                PlainpostMailActionPayload(
                    messageID: "message-1",
                    archiveMailbox: String(repeating: "x", count: 1_025)
                )
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? PlainpostForegroundOperationError,
                .invalidEnvelope
            )
        }
    }

    func testClientRejectsArchiveReplyForDifferentMailbox() async throws {
        let response = try PlainpostForegroundOperationResult.archive(
            PlainpostMailActionSemanticResult(
                messageID: "message-1",
                mailboxPath: "Archive",
                isDeleted: false
            )
        ).responseDTO()
        let service = ClientServiceProbe(
            foregroundReply: (response, nil)
        )
        let client = PlainpostServiceClient(
            connectionFactory: {
                ClientConnectionProbe(service: service)
            },
            capability: .cli
        )

        await XCTAssertThrowsErrorAsync(
            try await client.perform(
                .archive(
                    PlainpostMailActionPayload(
                        messageID: "message-1",
                        archiveMailbox: "Processed/2026"
                    )
                )
            ),
            equalTo: .serviceUnavailable
        )
    }

    func testSemanticEnvelopeEnforcesOperationSpecificAIStableIDs() throws {
        func input(
            _ operation: PlainpostAIOperationKind,
            recordID: String
        ) -> PlainpostAIOperationInput {
            PlainpostAIOperationInput(
                operation: operation,
                recordID: recordID,
                providerID: "deterministic",
                targetLanguageIdentifier: operation == .translateMessage ? "de" : nil,
                targetLanguageName: operation == .translateMessage ? "German" : nil,
                question: operation == .answerThreadQuestion
                    || operation == .answerMailboxQuestion ? "What changed?" : nil
            )
        }

        let missingRequiredIDKinds: [PlainpostAIOperationKind] = [
            .summarizeThread,
            .summarizeMessage,
            .translateMessage,
            .answerThreadQuestion,
            .answerMailboxQuestion,
            .draftReply,
            .rewriteDraft,
            .classifyMessage,
        ]
        for kind in missingRequiredIDKinds {
            let operation: PlainpostForegroundOperation =
                kind == .translateMessage
                    ? .translateMessage(input(kind, recordID: ""))
                    : .ai(input(kind, recordID: ""))
            let request = try operation.requestDTO()

            XCTAssertThrowsError(try PlainpostForegroundOperation(requestDTO: request), "kind \(kind)") {
                XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
            }
        }

        for invalidMessageID in [
            " ",
            "message-with-newline\n",
            String(repeating: "m", count: 1_025),
        ] {
            let invalidTranslation = PlainpostForegroundOperation.translateMessage(
                input(.translateMessage, recordID: invalidMessageID)
            )
            XCTAssertThrowsError(
                try PlainpostForegroundOperation(
                    requestDTO: invalidTranslation.requestDTO()
                )
            ) {
                XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
            }
        }

        let recategorizeWithExtraneousID = PlainpostForegroundOperation.ai(
            input(.recategorizeInbox, recordID: "message-should-not-be-targeted")
        )
        XCTAssertThrowsError(
            try PlainpostForegroundOperation(
                requestDTO: recategorizeWithExtraneousID.requestDTO()
            )
        ) {
            XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
        }

        let oversizedOptionalRebuildID = PlainpostForegroundOperation.ai(
            input(.rebuildIndex, recordID: String(repeating: "a", count: 1_025))
        )
        XCTAssertThrowsError(
            try PlainpostForegroundOperation(
                requestDTO: oversizedOptionalRebuildID.requestDTO()
            )
        ) {
            XCTAssertEqual($0 as? PlainpostForegroundOperationError, .invalidEnvelope)
        }

        for operation in [
            PlainpostForegroundOperation.translateMessage(
                input(.translateMessage, recordID: "message-1")
            ),
            .ai(input(.answerMailboxQuestion, recordID: "mailbox")),
            .ai(input(.recategorizeInbox, recordID: "")),
            .ai(input(.rebuildIndex, recordID: "")),
            .ai(input(.rebuildIndex, recordID: "account-1")),
        ] {
            let decoded = try PlainpostForegroundOperation(
                requestDTO: operation.requestDTO()
            )
            XCTAssertEqual(decoded.kind, operation.kind)
        }
    }

    func testStatusReturnsWrappedValue() async throws {
        let dto = try XCTUnwrap(
            PlainpostVaultStatusDTO(
                schemaVersion: 1,
                availability: .unlocked,
                matchingKeyItemCount: 1,
                detail: 0
            )
        )
        let service = ClientServiceProbe(statusReply: (dto, nil))
        let client = PlainpostServiceClient(
            connectionFactory: { ClientConnectionProbe(service: service) }
        )

        let status = try await client.status()
        XCTAssertEqual(
            status,
            PlainpostVaultStatus(
                availability: .unlocked,
                matchingKeyItemCount: 1
            )
        )
    }

    func testDedicatedClientsEnforceCapabilitiesAndDecodeTypedResults()
        async throws
    {
        let backgroundDTO = try XCTUnwrap(
            PlainpostBackgroundJobResultDTO(
                schemaVersion: 1,
                recoveredJobCount: 2,
                processedJobCount: 3
            )
        )
        let browserDTO = try XCTUnwrap(
            PlainpostBrowserApprovedReplyResultDTO(
                schemaVersion: 1,
                requestID: "request-1",
                jobID: "job-1",
                state: "sent"
            )
        )
        let smartInboxBatchDTO = try XCTUnwrap(
            PlainpostSmartInboxBatchResultDTO(
                schemaVersion: 1,
                accountID: "account-1",
                category: "seen",
                action: "archive_read",
                affectedMessageIDs: ["message-1"],
                archiveMailbox: "Archive"
            )
        )
        let draftDTO = try XCTUnwrap(
            PlainpostDraftSyncResultDTO(
                schemaVersion: 1,
                draftID: "draft-1",
                mailbox: "Drafts",
                serverDraftUID: 42
            )
        )
        let service = ClientServiceProbe(
            backgroundReply: (backgroundDTO, nil),
            smartInboxBatchReply: (smartInboxBatchDTO, nil),
            browserReply: (browserDTO, nil),
            draftReply: (draftDTO, nil)
        )
        let factory: @Sendable () -> PlainpostServiceClientConnection = {
            ClientConnectionProbe(service: service)
        }
        let agent = PlainpostServiceClient(
            connectionFactory: factory,
            capability: .agent
        )
        let browser = PlainpostServiceClient(
            connectionFactory: factory,
            capability: .browserHost
        )
        let cli = PlainpostServiceClient(
            connectionFactory: factory,
            capability: .cli
        )

        let backgroundResult = try await agent.processBackgroundJobs()
        XCTAssertEqual(
            backgroundResult,
            PlainpostBackgroundJobResult(
                recoveredJobCount: 2,
                processedJobCount: 3
            )
        )
        let browserResult = try await browser.sendBrowserApprovedReply(
            jobID: "job-1"
        )
        XCTAssertEqual(
            browserResult,
            PlainpostBrowserApprovedReplyResult(
                requestID: "request-1",
                jobID: "job-1",
                state: "sent"
            )
        )
        let draftResult = try await cli.syncDraftToServer(
            draftID: "draft-1",
            mailbox: "Drafts"
        )
        XCTAssertEqual(
            draftResult,
            PlainpostDraftSyncResult(
                draftID: "draft-1",
                mailbox: "Drafts",
                serverDraftUID: 42
            )
        )
        let smartInboxBatchRequest = PlainpostSmartInboxBatchRequest(
            accountID: "account-1",
            category: "seen",
            action: "archive_read",
            archiveMailbox: "Archive"
        )
        let smartInboxBatchResult =
            try await cli.performSmartInboxBatch(
                smartInboxBatchRequest
            )
        XCTAssertEqual(
            smartInboxBatchResult,
            PlainpostSmartInboxBatchResult(
                accountID: "account-1",
                category: "seen",
                action: "archive_read",
                affectedMessageIDs: ["message-1"],
                archiveMailbox: "Archive"
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await cli.processBackgroundJobs(),
            equalTo: .clientUnauthorized
        )
        await XCTAssertThrowsErrorAsync(
            try await agent.sendBrowserApprovedReply(jobID: "job-1"),
            equalTo: .clientUnauthorized
        )
        await XCTAssertThrowsErrorAsync(
            try await browser.syncDraftToServer(
                draftID: "draft-1",
                mailbox: "Drafts"
            ),
            equalTo: .clientUnauthorized
        )
        await XCTAssertThrowsErrorAsync(
            try await agent.performSmartInboxBatch(
                smartInboxBatchRequest
            ),
            equalTo: .clientUnauthorized
        )
        XCTAssertEqual(
            service.smartInboxBatchRequests.map(\.accountID),
            ["account-1"]
        )
        XCTAssertEqual(service.browserJobIDs, ["job-1"])
        XCTAssertEqual(
            service.draftRequests.map { [$0.draftID, $0.mailbox] },
            [["draft-1", "Drafts"]]
        )
    }

    func testDraftSyncRejectsMailboxDriftInServiceReply() async throws {
        let driftedReply = try XCTUnwrap(
            PlainpostDraftSyncResultDTO(
                schemaVersion: 1,
                draftID: "draft-1",
                mailbox: "Unexpected",
                serverDraftUID: 42
            )
        )
        let service = ClientServiceProbe(
            draftReply: (driftedReply, nil)
        )
        let client = PlainpostServiceClient(
            connectionFactory: {
                ClientConnectionProbe(service: service)
            },
            capability: .cli
        )

        await XCTAssertThrowsErrorAsync(
            try await client.syncDraftToServer(
                draftID: "draft-1",
                mailbox: "Drafts"
            ),
            equalTo: .serviceUnavailable
        )
    }

    func testLockMapsEveryTypedReplyAndNilSuccess() async throws {
        let cases: [
            (
                code: PlainpostXPCErrorCode,
                detail: Int,
                expected: PlainpostServiceClientError
            )
        ] = [
            (.vaultLocked, 0, .vaultLocked),
            (.authorizationCancelled, 0, .authorizationCancelled),
            (.authorizationFailed, 0, .authorizationFailed),
            (.vaultKeyMissing, 0, .vaultKeyMissing),
            (.vaultKeyAmbiguous, 0, .vaultKeyAmbiguous),
            (.ciphertextInvalid, 0, .ciphertextInvalid),
            (
                .unsupportedVaultVersion,
                7,
                .unsupportedVaultVersion(7)
            ),
            (.clientUnauthorized, 0, .clientUnauthorized),
            (.invalidRequest, 0, .invalidRequest),
            (.operationFailed, 0, .operationFailed),
        ]

        for item in cases {
            let error = try XCTUnwrap(
                PlainpostXPCErrorDTO(
                    schemaVersion: 1,
                    code: item.code,
                    detail: item.detail
                )
            )
            let client = PlainpostServiceClient(
                connectionFactory: {
                    ClientConnectionProbe(
                        service: ClientServiceProbe(lockReply: error)
                    )
                }
            )

            await XCTAssertThrowsErrorAsync(
                try await client.lock(),
                equalTo: item.expected
            )
        }

        let success = PlainpostServiceClient(
            connectionFactory: {
                ClientConnectionProbe(service: ClientServiceProbe())
            }
        )
        try await success.lock()
    }

    func testLockInterruptionAndInvalidationMapToServiceUnavailable() async {
        for event in [ClientConnectionProbe.Event.interruption, .invalidation] {
            let service = ClientServiceProbe(holdsLockReply: true)
            let connection = ClientConnectionProbe(service: service)
            let client = PlainpostServiceClient(
                connectionFactory: { connection }
            )
            let task = Task {
                try await client.lock()
            }
            let replyWasStored = await service.waitUntilLockReplyStored()
            XCTAssertTrue(replyWasStored)
            connection.emit(event)

            await XCTAssertThrowsErrorAsync(
                try await task.value,
                equalTo: .serviceUnavailable
            )
        }
    }

    func testLockTimeoutIsTypedAndInvalidatesConnection() async {
        let service = ClientServiceProbe(holdsLockReply: true)
        let connection = ClientConnectionProbe(service: service)
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(
            connectionFactory: { connection },
            timeouts: PlainpostServiceClientTimeouts(
                control: 0.001,
                interactive: 0.001,
                semantic: 0.001
            ),
            timeoutScheduler: scheduler
        )
        let task = Task {
            try await client.lock()
        }
        let replyWasStored = await service.waitUntilLockReplyStored()
        XCTAssertTrue(replyWasStored)
        while !scheduler.fireNext() {
            await Task.yield()
        }

        await XCTAssertThrowsErrorAsync(
            try await task.value,
            equalTo: .timedOut
        )
        XCTAssertEqual(connection.invalidationCount, 1)
        service.releaseLockReply(error: nil)
    }

    func testLockContinuationResumesExactlyOnceAcrossReplyAndProxyError() async {
        let error = PlainpostXPCErrorDTO(
            schemaVersion: 1,
            code: .clientUnauthorized,
            detail: 0
        )!
        let service = ClientServiceProbe(holdsLockReply: true)
        let connection = ClientConnectionProbe(service: service)
        let client = PlainpostServiceClient(
            connectionFactory: { connection }
        )
        let task = Task {
            try await client.lock()
        }
        let replyWasStored = await service.waitUntilLockReplyStored()
        XCTAssertTrue(replyWasStored)
        service.releaseLockReply(error: error)
        connection.emitProxyError()
        service.releaseLockReply(error: nil)

        await XCTAssertThrowsErrorAsync(
            try await task.value,
            equalTo: .clientUnauthorized
        )
        XCTAssertEqual(service.lockCallCount, 1)
    }

    func testMalformedStatusRepliesFailClosed() async {
        let validStatus = PlainpostVaultStatusDTO(
            schemaVersion: 1,
            availability: .locked,
            matchingKeyItemCount: 0,
            detail: 0
        )!
        let error = PlainpostXPCErrorDTO(
            schemaVersion: 1,
            code: .operationFailed,
            detail: 0
        )!
        let replies: [(PlainpostVaultStatusDTO?, PlainpostXPCErrorDTO?)] = [
            (nil, nil),
            (validStatus, error),
        ]

        for reply in replies {
            let client = PlainpostServiceClient(
                connectionFactory: {
                    ClientConnectionProbe(
                        service: ClientServiceProbe(statusReply: reply)
                    )
                }
            )
            await XCTAssertThrowsErrorAsync(
                try await client.status(),
                equalTo: .serviceUnavailable
            )
        }
    }

    func testMissingProxyMapsToServiceUnavailable() async {
        let client = PlainpostServiceClient(
            connectionFactory: { ClientConnectionProbe(service: nil) }
        )

        await XCTAssertThrowsErrorAsync(
            try await client.status(),
            equalTo: .serviceUnavailable
        )
    }

    func testInterruptionAndInvalidationMapToServiceUnavailable() async {
        for event in [ClientConnectionProbe.Event.interruption, .invalidation] {
            let service = ClientServiceProbe(holdsStatusReply: true)
            let connection = ClientConnectionProbe(service: service)
            let client = PlainpostServiceClient(connectionFactory: { connection })
            let task = Task {
                try await client.status()
            }
            let replyWasStored = await service.waitUntilStatusReplyStored()
            XCTAssertTrue(replyWasStored)
            connection.emit(event)

            await XCTAssertThrowsErrorAsync(
                try await task.value,
                equalTo: .serviceUnavailable
            )
        }
    }

    func testIdleInvalidationReconnectsOnlyWhenAnRPCNeedsTransport()
        async throws
    {
        let initialConnection = ClientConnectionProbe(service: nil)
        let status = PlainpostVaultStatusDTO(
            schemaVersion: 1,
            availability: .locked,
            matchingKeyItemCount: 0,
            detail: 0
        )!
        let replacementConnection = ClientConnectionProbe(
            service: ClientServiceProbe(statusReply: (status, nil))
        )
        let factory = ClientConnectionFactoryProbe([
            initialConnection,
            replacementConnection,
        ])
        let client = PlainpostServiceClient(connectionFactory: factory.make)

        initialConnection.emit(.invalidation)

        XCTAssertEqual(
            factory.makeCount,
            1,
            "An idle invalidation must not start a reconnect loop."
        )
        _ = try await client.status()
        XCTAssertEqual(factory.makeCount, 2)
    }

    func testInvalidationDuringCheckoutRejectsStaleTransportBeforeSend() async {
        let staleService = ClientServiceProbe(holdsStatusReply: true)
        let staleConnection = ClientConnectionProbe(service: staleService)
        let replacementConnection = ClientConnectionProbe(
            service: ClientServiceProbe()
        )
        let factory = ClientConnectionFactoryProbe([
            staleConnection,
            replacementConnection,
        ])
        let scheduler = ManualTimeoutScheduler()
        let checkoutBarrier = CheckoutBarrier()
        let client = PlainpostServiceClient(
            connectionFactory: factory.make,
            timeouts: PlainpostServiceClientTimeouts(
                control: 5,
                interactive: 120,
                semantic: 300
            ),
            timeoutScheduler: scheduler,
            checkoutBarrier: checkoutBarrier.pause
        )

        let task = Task {
            try await client.status()
        }
        XCTAssertTrue(checkoutBarrier.waitUntilPaused())
        staleConnection.emit(.invalidation)
        checkoutBarrier.release()
        let timeoutWasScheduled = await scheduler.waitUntilScheduled()
        if timeoutWasScheduled {
            _ = scheduler.fireNext()
        }

        await XCTAssertThrowsErrorAsync(
            try await task.value,
            equalTo: .serviceUnavailable
        )
        XCTAssertFalse(timeoutWasScheduled)
        XCTAssertEqual(staleService.statusCallCount, 0)
    }

    func testTimeoutIsTypedAndInvalidatesConnection() async {
        let service = ClientServiceProbe(holdsStatusReply: true)
        let connection = ClientConnectionProbe(service: service)
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(
            connectionFactory: { connection },
            timeouts: PlainpostServiceClientTimeouts(
                control: 0.001,
                interactive: 0.001,
                semantic: 0.001
            ),
            timeoutScheduler: scheduler
        )
        let task = Task {
            try await client.status()
        }
        let replyWasStored = await service.waitUntilStatusReplyStored()
        XCTAssertTrue(replyWasStored)
        while !scheduler.fireNext() {
            await Task.yield()
        }

        await XCTAssertThrowsErrorAsync(
            try await task.value,
            equalTo: .timedOut
        )
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testSemanticTransportDeadlineSchedules300Seconds() async throws {
        let scheduler = ManualTimeoutScheduler()
        let client = PlainpostServiceClient(
            connectionFactory: {
                ClientConnectionProbe(service: ClientServiceProbe())
            },
            timeouts: PlainpostServiceClientTimeouts(
                control: 5,
                interactive: 120,
                semantic: 300
            ),
            timeoutScheduler: scheduler
        )

        let result =
            await client.invoke(.semantic) { _, complete in
                complete(.success(()))
            }

        _ = try result.get()
        XCTAssertEqual(scheduler.scheduledDelays, [300])
    }

    func testStatusContinuationResumesExactlyOnceAcrossReplyAndProxyError() async throws {
        let status = PlainpostVaultStatusDTO(
            schemaVersion: 1,
            availability: .unlocked,
            matchingKeyItemCount: 1,
            detail: 0
        )!
        let service = ClientServiceProbe(holdsStatusReply: true)
        let connection = ClientConnectionProbe(service: service)
        let client = PlainpostServiceClient(connectionFactory: { connection })
        let task = Task {
            try await client.status()
        }
        let replyWasStored = await service.waitUntilStatusReplyStored()
        XCTAssertTrue(replyWasStored)
        service.releaseStatusReply(status: status, error: nil)
        connection.emitProxyError()
        service.releaseStatusReply(status: nil, error: nil)

        let statusValue = try await task.value
        XCTAssertEqual(
            statusValue,
            PlainpostVaultStatus(
                availability: .unlocked,
                matchingKeyItemCount: 1
            )
        )
    }
}
private func archive(_ body: (NSKeyedArchiver) -> Void) throws -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    body(coder)
    coder.finishEncoding()
    return coder.encodedData
}

private func decodeStatus(_ data: Data) throws -> PlainpostVaultStatusDTO? {
    let coder = try NSKeyedUnarchiver(forReadingFrom: data)
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return PlainpostVaultStatusDTO(coder: coder)
}

private func decodeError(_ data: Data) throws -> PlainpostXPCErrorDTO? {
    let coder = try NSKeyedUnarchiver(forReadingFrom: data)
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return PlainpostXPCErrorDTO(coder: coder)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    equalTo expected: PlainpostServiceClientError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? PlainpostServiceClientError,
            expected,
            file: file,
            line: line
        )
    }
}

private final class AuditVerifierRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let matchingRequirements: Set<String>
    private let failedRequirementIndex: Int?
    private(set) var auditTokens: [Data] = []
    private(set) var requirements: [String] = []

    init(
        matchingRequirements: Set<String> = [],
        failedRequirementIndex: Int? = nil
    ) {
        self.matchingRequirements = matchingRequirements
        self.failedRequirementIndex = failedRequirementIndex
    }

    var guestCodeLookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return auditTokens.count
    }

    var verifier: PlainpostAuditCodeVerifier {
        PlainpostAuditCodeVerifier(
            copyGuestCode: { [self] token in
                lock.lock()
                auditTokens.append(token)
                lock.unlock()
                return NSObject()
            },
            createRequirement: { [self] requirement in
                lock.lock()
                let index = requirements.count
                requirements.append(requirement)
                lock.unlock()
                guard index != failedRequirementIndex else { return nil }
                return RequirementProbe(text: requirement)
            },
            check: { [matchingRequirements] _, requirement in
                guard let requirement = requirement as? RequirementProbe else {
                    return false
                }
                return matchingRequirements.contains(requirement.text)
            }
        )
    }
}

private final class RequirementProbe: NSObject, @unchecked Sendable {
    let text: String

    init(text: String) {
        self.text = text
    }
}

private enum ClientProbeError: Error {
    case failed
}

private final class NonValueAuditTokenObject: NSObject {
    @objc dynamic var auditToken: Any {
        "not-an-NSValue"
    }
}

private final class WrongTypeAuditTokenObject: NSObject {
    @objc dynamic var auditToken: NSValue {
        NSValue(point: .zero)
    }
}

private final class ThrowingAuditTokenObject: NSObject {
    @objc dynamic var auditToken: NSValue {
        NSException(
            name: .invalidArgumentException,
            reason: "test-only KVC exception"
        ).raise()
        return NSValue(point: .zero)
    }
}

private final class CheckoutBarrier: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pause() {
        paused.signal()
        resume.wait()
    }

    func waitUntilPaused() -> Bool {
        paused.wait(timeout: .now() + 1) == .success
    }

    func release() {
        resume.signal()
    }
}

private final class ClientConnectionFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ClientConnectionProbe]
    private var _makeCount = 0

    init(_ connections: [ClientConnectionProbe]) {
        self.connections = connections
    }

    func make() -> PlainpostServiceClientConnection {
        lock.lock()
        defer {
            lock.unlock()
        }
        _makeCount += 1
        return connections.removeFirst()
    }

    var makeCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _makeCount
    }
}

private final class ClientConnectionProbe: PlainpostServiceClientConnection, @unchecked Sendable {
    enum Event {
        case interruption
        case invalidation
    }

    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?
    private let service: PlainpostServiceXPCProtocol?
    private let activationBarrier: CheckoutBarrier?
    private var proxyErrorHandler: (@Sendable (Error) -> Void)?
    private(set) var invalidationCount = 0

    init(service: PlainpostServiceXPCProtocol?, activationBarrier: CheckoutBarrier? = nil) {
        self.service = service
        self.activationBarrier = activationBarrier
    }

    func activate() { activationBarrier?.pause() }

    func invalidate() {
        invalidationCount += 1
    }

    func remoteService(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> PlainpostServiceXPCProtocol? {
        proxyErrorHandler = errorHandler
        return service
    }

    func emit(_ event: Event) {
        switch event {
        case .interruption:
            interruptionHandler?()
        case .invalidation:
            invalidationHandler?()
        }
    }

    func emitProxyError() {
        proxyErrorHandler?(ClientProbeError.failed)
    }
}

private final class ClientServiceProbe: NSObject, PlainpostServiceXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let statusReply: (PlainpostVaultStatusDTO?, PlainpostXPCErrorDTO?)
    private let holdsStatusReply: Bool
    private let statusAdmission: XCTestExpectation?
    private let lockAdmission: XCTestExpectation?
    private let lockReply: PlainpostXPCErrorDTO?
    private let holdsLockReply: Bool
    private let backgroundReply:
        (PlainpostBackgroundJobResultDTO?, PlainpostXPCErrorDTO?)
    private let smartInboxBatchReply:
        (PlainpostSmartInboxBatchResultDTO?, PlainpostXPCErrorDTO?)
    private let browserReply:
        (PlainpostBrowserApprovedReplyResultDTO?, PlainpostXPCErrorDTO?)
    private let draftReply:
        (PlainpostDraftSyncResultDTO?, PlainpostXPCErrorDTO?)
    private let foregroundReply:
        (
            PlainpostForegroundOperationResultDTO?,
            PlainpostXPCErrorDTO?
        )
    private var storedStatusReply: (
        (@Sendable (PlainpostVaultStatusDTO?, PlainpostXPCErrorDTO?) -> Void)?
    )
    private var storedLockReply:
        ((@Sendable (PlainpostXPCErrorDTO?) -> Void)?)
    private(set) var statusCallCount = 0
    private(set) var lockCallCount = 0
    private(set) var smartInboxBatchRequests:
        [PlainpostSmartInboxBatchRequestDTO] = []
    private(set) var browserJobIDs: [String] = []
    private(set) var draftRequests: [PlainpostDraftSyncRequestDTO] = []
    var nodeSessionReply: (PlainpostNodeSessionResponseDTO?, PlainpostXPCErrorDTO?) = (nil, nil)
    var nodeSessionReadinessReply: (String?, PlainpostXPCErrorDTO?) = (nil, nil)
    var nodeMailModeStatusReply: (PlainpostNodeMailModeStatusDTO?, PlainpostXPCErrorDTO?) = (nil, nil)
    var serviceIdentityReply: (String?, String?, PlainpostXPCErrorDTO?) = (nil, nil, nil)
    var startOverReply: PlainpostXPCErrorDTO?
    private(set) var startOverReasons: [String] = []
    private(set) var nodeSessionRequests: [PlainpostNodeSessionRequestDTO] = []
    private(set) var nodeSessionInvalidations = 0

    init(
        statusReply: (PlainpostVaultStatusDTO?, PlainpostXPCErrorDTO?) = (nil, nil),
        holdsStatusReply: Bool = false,
        statusAdmission: XCTestExpectation? = nil,
        lockAdmission: XCTestExpectation? = nil,
        lockReply: PlainpostXPCErrorDTO? = nil,
        holdsLockReply: Bool = false,
        backgroundReply:
            (PlainpostBackgroundJobResultDTO?, PlainpostXPCErrorDTO?) =
                (nil, nil),
        smartInboxBatchReply:
            (
                PlainpostSmartInboxBatchResultDTO?,
                PlainpostXPCErrorDTO?
            ) = (nil, nil),
        browserReply:
            (
                PlainpostBrowserApprovedReplyResultDTO?,
                PlainpostXPCErrorDTO?
            ) = (nil, nil),
        draftReply:
            (PlainpostDraftSyncResultDTO?, PlainpostXPCErrorDTO?) =
                (nil, nil),
        foregroundReply:
            (
                PlainpostForegroundOperationResultDTO?,
                PlainpostXPCErrorDTO?
            ) = (nil, nil)
    ) {
        self.statusReply = statusReply
        self.holdsStatusReply = holdsStatusReply
        self.statusAdmission = statusAdmission
        self.lockAdmission = lockAdmission
        self.lockReply = lockReply
        self.holdsLockReply = holdsLockReply
        self.backgroundReply = backgroundReply
        self.smartInboxBatchReply = smartInboxBatchReply
        self.browserReply = browserReply
        self.draftReply = draftReply
        self.foregroundReply = foregroundReply
    }

    func status(
        reply: @escaping @Sendable (
            PlainpostVaultStatusDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        lock.lock()
        statusCallCount += 1
        if holdsStatusReply {
            storedStatusReply = reply
            lock.unlock()
            statusAdmission?.fulfill()
            return
        }
        let statusReply = self.statusReply
        lock.unlock()
        reply(statusReply.0, statusReply.1)
    }

    func unlock(
        reason: String,
        reply: @escaping @Sendable (PlainpostXPCErrorDTO?) -> Void
    ) {
        reply(nil)
    }

    func lock(
        reply: @escaping @Sendable (PlainpostXPCErrorDTO?) -> Void
    ) {
        lock.lock()
        lockCallCount += 1
        if holdsLockReply {
            storedLockReply = reply
            lock.unlock()
            lockAdmission?.fulfill()
            return
        }
        let lockReply = self.lockReply
        lock.unlock()
        reply(lockReply)
    }

    func processBackgroundJobs(
        reply: @escaping @Sendable (
            PlainpostBackgroundJobResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        reply(backgroundReply.0, backgroundReply.1)
    }

    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequestDTO,
        reply: @escaping @Sendable (
            PlainpostSmartInboxBatchResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        lock.withLock {
            smartInboxBatchRequests.append(request)
        }
        reply(smartInboxBatchReply.0, smartInboxBatchReply.1)
    }

    func sendBrowserApprovedReply(
        _ request: PlainpostBrowserApprovedReplyRequestDTO,
        reply: @escaping @Sendable (
            PlainpostBrowserApprovedReplyResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        lock.withLock {
            browserJobIDs.append(request.jobID)
        }
        reply(browserReply.0, browserReply.1)
    }

    func syncDraftToServer(
        _ request: PlainpostDraftSyncRequestDTO,
        reply: @escaping @Sendable (
            PlainpostDraftSyncResultDTO?,
            PlainpostXPCErrorDTO?
        ) -> Void
    ) {
        lock.withLock {
            draftRequests.append(request)
        }
        reply(draftReply.0, draftReply.1)
    }

    func performForegroundOperation(
        _ request: PlainpostForegroundOperationRequestDTO,
        reply:
            @escaping @Sendable (PlainpostForegroundOperationResultDTO?, PlainpostXPCErrorDTO?) ->
            Void
    ) {
        _ = request
        reply(foregroundReply.0, foregroundReply.1)
    }

    func performNodeSessionRequest(
        _ request: PlainpostNodeSessionRequestDTO,
        reply: @escaping @Sendable (PlainpostNodeSessionResponseDTO?, PlainpostXPCErrorDTO?) -> Void
    ) {
        let response = lock.withLock { () -> (PlainpostNodeSessionResponseDTO?, PlainpostXPCErrorDTO?) in
            nodeSessionRequests.append(request)
            return nodeSessionReply
        }
        reply(response.0, response.1)
    }

    func invalidateNodeSession(reply: @escaping @Sendable (PlainpostXPCErrorDTO?) -> Void) {
        lock.withLock { nodeSessionInvalidations += 1 }
        reply(nil)
    }

    func nodeSessionIdentityReadiness(reply: @escaping @Sendable (String?, PlainpostXPCErrorDTO?) -> Void) {
        let response = lock.withLock { nodeSessionReadinessReply }
        reply(response.0, response.1)
    }

    func nodeMailModeStatus(reply: @escaping @Sendable (PlainpostNodeMailModeStatusDTO?, PlainpostXPCErrorDTO?) -> Void) {
        let response = lock.withLock { nodeMailModeStatusReply }
        reply(response.0, response.1)
    }

    func serviceIdentity(reply: @escaping @Sendable (String?, String?, PlainpostXPCErrorDTO?) -> Void) {
        let response = lock.withLock { serviceIdentityReply }
        reply(response.0, response.1, response.2)
    }

    func startOverAfterVaultKeyLoss(reason: String, reply: @escaping @Sendable (PlainpostXPCErrorDTO?) -> Void) {
        let response = lock.withLock {
            startOverReasons.append(reason)
            return startOverReply
        }
        reply(response)
    }

    func releaseStatusReply(status: PlainpostVaultStatusDTO?, error: PlainpostXPCErrorDTO?) {
        lock.lock()
        let reply = storedStatusReply
        lock.unlock()
        reply?(status, error)
    }

    func releaseLockReply(error: PlainpostXPCErrorDTO?) {
        lock.lock()
        let reply = storedLockReply
        lock.unlock()
        reply?(error)
    }

    func waitUntilStatusReplyStored() async -> Bool {
        for _ in 0..<10_000 {
            if hasStoredStatusReply() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func hasStoredStatusReply() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedStatusReply != nil
    }

    func waitUntilLockReplyStored() async -> Bool {
        for _ in 0..<10_000 {
            if hasStoredLockReply() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func hasStoredLockReply() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedLockReply != nil
    }
}

private final class ManualTimeoutScheduler: PlainpostServiceClientTimeoutScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ManualTimeoutTask] = []
    private var delays: [TimeInterval] = []
    private let firstCancellationBarrier: CheckoutBarrier?

    init(firstCancellationBarrier: CheckoutBarrier? = nil) {
        self.firstCancellationBarrier = firstCancellationBarrier
    }

    var scheduledDelays: [TimeInterval] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return delays
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any PlainpostServiceClientTimeoutTask {
        lock.lock()
        let task = ManualTimeoutTask(action: action, cancellationBarrier: delays.isEmpty ? firstCancellationBarrier : nil)
        tasks.append(task)
        delays.append(delay)
        lock.unlock()
        return task
    }

    // Capture a timer action that has already passed its cancellation check.
    // Releasing this action models DispatchWorkItem.cancel racing an admitted callback.
    func admitNextAction() -> (@Sendable () -> Void)? {
        let task = lock.withLock { tasks.isEmpty ? nil : tasks.removeFirst() }
        return task?.admitAction()
    }

    func fireNext() -> Bool {
        lock.lock()
        guard !tasks.isEmpty else {
            lock.unlock()
            return false
        }
        let task = tasks.removeFirst()
        lock.unlock()
        return task.fire()
    }

    func waitUntilScheduled() async -> Bool {
        for _ in 0..<10_000 {
            if hasScheduledTask() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func hasScheduledTask() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return !tasks.isEmpty
    }
}

private final class ManualTimeoutTask: PlainpostServiceClientTimeoutTask, @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var cancelled = false
    private let cancellationBarrier: CheckoutBarrier?

    init(action: @escaping @Sendable () -> Void, cancellationBarrier: CheckoutBarrier? = nil) {
        self.action = action
        self.cancellationBarrier = cancellationBarrier
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        cancellationBarrier?.pause()
    }

    func admitAction() -> (@Sendable () -> Void)? {
        lock.withLock { cancelled ? nil : action }
    }

    func fire() -> Bool {
        lock.lock()
        let shouldFire = !cancelled
        lock.unlock()
        if shouldFire {
            action()
        }
        return shouldFire
    }
}

private enum IPCWaitOutcome: Equatable {
    case success, cancelled, service(PlainpostServiceClientError), unexpected
}

private func ipcWaitOutcome(_ operation: () async throws -> Void) async -> IPCWaitOutcome {
    do { try await operation(); return .success }
    catch is CancellationError { return .cancelled }
    catch let error as PlainpostServiceClientError { return .service(error) }
    catch { return .unexpected }
}

private func ipcUnlockedStatus() -> PlainpostVaultStatusDTO {
    PlainpostVaultStatusDTO(schemaVersion: 1, availability: .unlocked, matchingKeyItemCount: 1, detail: 0)!
}

private actor IPCWaitGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private struct IPCVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func countMatchingItems() async throws -> Int { 1 }
    func load(interactive: Bool, prompt: String?) async throws -> Data? { Data(repeating: 0x17, count: 32) }
}

private actor IPCDurableWriteOwner {
    struct Observation: Sendable { var calls = 0; var cancelledBefore = false; var cancelledAfter = false }
    private(set) var observation = Observation()
    private let store: SQLiteMailStore
    private let admitted: XCTestExpectation
    private let gate = IPCWaitGate()
    init(store: SQLiteMailStore, admitted: XCTestExpectation) { self.store = store; self.admitted = admitted }
    func run(_ operation: PlainpostForegroundOperation) async throws -> PlainpostForegroundOperationResult {
        guard case .denySend(let decision) = operation else { throw PlainpostServiceClientError.invalidRequest }
        observation.calls += 1
        observation.cancelledBefore = Task.isCancelled
        let job = try store.enqueueJob(.init(kind: .denySend, payloadJSON: String(decoding: JSONEncoder().encode(decision), as: UTF8.self), idempotencyKey: "deny-send:\(decision.requestID.rawValue)"))
        guard let claim = try store.claimNextJob(allowedKinds: [.denySend]), let token = claim.leaseToken, claim.id == job.id else { throw PlainpostServiceClientError.operationFailed }
        admitted.fulfill()
        await gate.wait()
        observation.cancelledAfter = Task.isCancelled
        try store.completeJob(id: job.id, leaseToken: token, resultArtifactID: nil)
        return .denySend
    }
    func release() async { await gate.release() }
}
