import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

final class PlainpostServiceRuntimeTests: XCTestCase {
    func testVaultFailuresRemainDistinctAcrossXPC() {
        let cases: [(CredentialVaultError, PlainpostServiceClientError)] = [
            (.locked, .vaultLocked),
            (.authorizationCancelled, .authorizationCancelled),
            (.authorizationFailed, .authorizationFailed),
            (.keyMissing, .vaultKeyMissing),
            (.keyAmbiguous, .vaultKeyAmbiguous),
            (.ciphertextInvalid, .ciphertextInvalid),
            (.unsupportedVersion(7), .unsupportedVaultVersion(7)),
        ]

        for (source, expected) in cases {
            XCTAssertEqual(
                PlainpostServiceClientError(
                    dto: PlainpostServiceErrorMapper.dto(from: source)
                ),
                expected
            )
        }
    }

    func testSemanticRequestFailuresRemainDistinctAcrossXPC() {
        let cases: [(PlainpostServiceClientError, PlainpostServiceClientError)] = [
            (.invalidRequest, .invalidRequest),
            (.operationFailed, .operationFailed),
        ]

        for (source, expected) in cases {
            XCTAssertEqual(
                PlainpostServiceClientError(
                    dto: PlainpostServiceErrorMapper.dto(from: source)
                ),
                expected
            )
        }
    }

    func testAccountDeletionFailureStatesRemainTypedAcrossXPC() {
        let accountID = AccountID("account-1")
        let cases: [(Error, PlainpostServiceClientError)] = [
            (
                AccountDeletionCleanupPendingError(
                    accountID: accountID,
                    operationError: PlainpostServiceClientError.operationFailed
                ),
                .accountDeletionCleanupPending
            ),
            (
                AccountDeletionCompensationError(
                    operationError: PlainpostServiceClientError.operationFailed,
                    compensationError: CredentialVaultError.locked
                ),
                .accountDeletionCompensationFailed
            ),
        ]

        for (source, expected) in cases {
            XCTAssertEqual(
                PlainpostServiceClientError(
                    dto: PlainpostServiceErrorMapper.dto(from: source)
                ),
                expected
            )
        }
    }

    func testConcurrentForegroundUnlocksShareOneSessionBuffer() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x28, count: 32)),
            startsSuspended: true
        )
        let session = VaultSession(provider: provider)
        let hooks = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {
                await hooks.record("prepare")
            },
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {
                await hooks.record("reopen")
            }
        )

        async let appUnlock: Void = coordinator.unlock(
            prompt: "Unlock Plainpost",
            capability: .app
        )
        await provider.waitUntilLoadStarts()
        async let cliUnlock: Void = coordinator.unlock(
            prompt: "Unlock Plainpost",
            capability: .cli
        )
        for _ in 0..<20 {
            await Task.yield()
        }
        await provider.releaseLoad()
        try await appUnlock
        try await cliUnlock

        let calls = await provider.calls
        let events = await hooks.events
        let firstByte = try await session.withKey { key in
            key.withUnsafeBytes { $0.first }
        }
        XCTAssertEqual(calls.interactiveLoads, 1)
        XCTAssertEqual(events, ["prepare", "reopen"])
        XCTAssertEqual(firstByte, 0x28)
    }

    func testAuthorizationCancellationRestoresLockedWithoutRetry() async {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .failure(.authorizationCancelled)
        )
        let session = VaultSession(provider: provider)
        let hooks = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {
                await hooks.record("prepare")
            },
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {
                await hooks.record("reopen")
            }
        )

        await XCTAssertCredentialVaultError(
            try await coordinator.unlock(
                prompt: "Unlock Plainpost",
                capability: .app
            ),
            equals: .authorizationCancelled
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        let calls = await provider.calls
        let events = await hooks.events
        let state = await session.state
        XCTAssertEqual(calls.interactiveLoads, 1)
        XCTAssertEqual(events, ["prepare"])
        XCTAssertEqual(state, .locked)
    }

    func testPostUnlockRecoveryFailureRelocksWithoutReopeningRuntime() async {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x31, count: 32))
        )
        let session = VaultSession(provider: provider)
        let events = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: { await events.record("prepare") },
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            recoverAfterUnlock: {
                await events.record("recover")
                throw CredentialVaultError.ciphertextInvalid
            },
            reopenRuntimeConstruction: { await events.record("reopen") }
        )

        await XCTAssertCredentialVaultError(
            try await coordinator.unlock(prompt: "Unlock Plainpost", capability: .app),
            equals: .ciphertextInvalid
        )

        let recordedEvents = await events.events
        let state = await session.state
        XCTAssertEqual(recordedEvents, ["prepare", "recover"])
        XCTAssertEqual(state, .locked)
    }

    func testQuietCapabilitiesCannotTriggerForegroundUnlock() async {
        for capability in [
            PlainpostClientCapability.agent,
            .browserHost,
        ] {
            let provider = LifecycleVaultKeyProvider(
                matchingItemCount: 1,
                loadBehavior: .value(Data(repeating: 0x39, count: 32))
            )
            let hooks = LifecycleHookRecorder()
            let coordinator = PlainpostServiceLifecycleCoordinator(
                vaultSession: VaultSession(provider: provider),
                prepareForegroundUnlock: {
                    await hooks.record("prepare")
                },
                beginVaultLockdown: {},
                confirmVaultLocked: {},
                reopenRuntimeConstruction: {
                    await hooks.record("reopen")
                }
            )

            await XCTAssertCredentialVaultError(
                try await coordinator.unlock(
                    prompt: "Must remain quiet",
                    capability: capability
                ),
                equals: .locked
            )

            let calls = await provider.calls
            let events = await hooks.events
            XCTAssertEqual(calls.interactiveLoads, 0)
            XCTAssertEqual(events, [])
        }
    }

    func testLockQuiescesRuntimeThenClearsKeyThenConfirmsLocked() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x4A, count: 32))
        )
        let session = VaultSession(provider: provider)
        try await session.unlock(prompt: "Initial unlock")
        let events = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {
                await events.record(
                    "begin:\(await session.state)"
                )
            },
            confirmVaultLocked: {
                await events.record(
                    "confirm:\(await session.state)"
                )
            },
            reopenRuntimeConstruction: {}
        )

        await coordinator.lock()

        let recorded = await events.events
        let state = await session.state
        XCTAssertEqual(
            recorded,
            ["begin:unlocked", "confirm:locked"]
        )
        XCTAssertEqual(state, .locked)
        await XCTAssertCredentialVaultError(
            try await session.withKey { _ in true },
            equals: .locked
        )
    }

    func testActiveTransitionsRunFIFO() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x52, count: 32))
        )
        let session = VaultSession(provider: provider)
        try await session.unlock(prompt: "Initial unlock")
        let events = LifecycleHookRecorder()
        let firstLockGate = SingleUseTransitionGate()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {
                await events.record("prepare")
            },
            beginVaultLockdown: {
                await events.record("begin")
                await firstLockGate.enter()
            },
            confirmVaultLocked: {
                await events.record("confirm")
            },
            reopenRuntimeConstruction: {
                await events.record("reopen")
            }
        )

        let firstLock = Task {
            await coordinator.lock()
        }
        await firstLockGate.waitUntilFirstEntry()
        let queuedUnlock = Task {
            try await coordinator.unlock(
                prompt: "Queued unlock",
                capability: .app
            )
        }
        while await coordinator.pendingTransitionWaiterCount < 1 {
            await Task.yield()
        }
        let queuedLock = Task {
            await coordinator.lock()
        }
        while await coordinator.pendingTransitionWaiterCount < 2 {
            await Task.yield()
        }

        await firstLockGate.releaseFirstEntry()
        await firstLock.value
        try await queuedUnlock.value
        await queuedLock.value

        let recorded = await events.events
        let calls = await provider.calls
        let state = await session.state
        XCTAssertEqual(
            recorded,
            [
                "begin",
                "confirm",
                "prepare",
                "reopen",
                "begin",
                "confirm",
            ]
        )
        XCTAssertEqual(calls.interactiveLoads, 2)
        XCTAssertEqual(state, .locked)
    }

    func testTerminalVaultFailureRemainsVisibleInStatus() async {
        let cases: [
            (
                error: CredentialVaultError,
                expected: PlainpostVaultStatus.Availability
            )
        ] = [
            (.ciphertextInvalid, .ciphertextInvalid),
            (.unsupportedVersion(7), .unsupportedVersion(7)),
        ]

        for item in cases {
            let provider = LifecycleVaultKeyProvider(
                matchingItemCount: 1,
                loadBehavior: .value(Data(repeating: 0x5B, count: 32))
            )
            let session = VaultSession(provider: provider)
            let coordinator = PlainpostServiceLifecycleCoordinator(
                vaultSession: session,
                prepareForegroundUnlock: {
                    throw item.error
                },
                beginVaultLockdown: {},
                confirmVaultLocked: {},
                reopenRuntimeConstruction: {}
            )

            await XCTAssertCredentialVaultError(
                try await coordinator.unlock(
                    prompt: "Unlock Plainpost",
                    capability: .app
                ),
                equals: item.error
            )
            do {
                let status = try await coordinator.status()
                XCTAssertEqual(status.availability, item.expected)
                XCTAssertEqual(status.matchingKeyItemCount, 1)
            } catch {
                XCTFail("Expected typed status, received \(error)")
            }
            let state = await session.state
            XCTAssertEqual(state, .locked)
        }
    }

    func testShutdownRejectsQueuedAndNewUnlocksAndCompletesQueuedLocks() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x6C, count: 32))
        )
        let session = VaultSession(provider: provider)
        let hooks = LifecycleHookRecorder()
        let firstLockGate = SingleUseTransitionGate()
        let queuedLockCompletion = AsyncFlag()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {
                await hooks.record("begin")
                await firstLockGate.enter()
            },
            confirmVaultLocked: {
                await hooks.record("confirm")
            },
            reopenRuntimeConstruction: {
                await hooks.record("reopen")
            }
        )
        try await coordinator.unlock(
            prompt: "Initial foreground unlock",
            capability: .app
        )
        let reopenBaseline = await hooks.count(of: "reopen")

        let activeLock = Task {
            await coordinator.lock()
        }
        await firstLockGate.waitUntilFirstEntry()
        let queuedUnlock = Task {
            await captureCredentialVaultError {
                try await coordinator.unlock(
                    prompt: "Queued unlock",
                    capability: .cli
                )
            }
        }
        let queuedLock = Task {
            await coordinator.lock()
            await queuedLockCompletion.set()
        }
        while await coordinator.pendingTransitionWaiterCount < 2 {
            await Task.yield()
        }

        let shutdown = Task {
            await coordinator.shutdown()
        }
        while await !coordinator.isShutdownRequested {
            await Task.yield()
        }
        let newUnlock = Task {
            await captureCredentialVaultError {
                try await coordinator.unlock(
                    prompt: "New unlock",
                    capability: .app
                )
            }
        }
        await firstLockGate.releaseFirstEntry()

        let queuedUnlockError = await queuedUnlock.value
        let newUnlockError = await newUnlock.value
        await activeLock.value
        await shutdown.value
        await queuedLock.value

        let events = await hooks.events
        let didCompleteQueuedLock = await queuedLockCompletion.value
        let state = await session.state
        XCTAssertEqual(queuedUnlockError, .locked)
        XCTAssertEqual(newUnlockError, .locked)
        XCTAssertTrue(didCompleteQueuedLock)
        XCTAssertEqual(events.filter { $0 == "begin" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "confirm" }.count, 2)
        XCTAssertEqual(
            events.filter { $0 == "reopen" }.count,
            reopenBaseline
        )
        XCTAssertEqual(state, .locked)
    }

    func testShutdownRequestDuringActiveUnlockWaitsForReopenThenLocks() async {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x6D, count: 32)),
            startsSuspended: true
        )
        let session = VaultSession(provider: provider)
        let hooks = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {
                await hooks.record("prepare")
            },
            beginVaultLockdown: {
                await hooks.record("begin")
            },
            confirmVaultLocked: {
                await hooks.record("confirm")
            },
            reopenRuntimeConstruction: {
                await hooks.record("reopen")
            }
        )
        let activeUnlock = Task {
            await captureCredentialVaultError {
                try await coordinator.unlock(
                    prompt: "Active unlock",
                    capability: .app
                )
            }
        }
        await provider.waitUntilLoadStarts()
        let shutdown = Task {
            await coordinator.shutdown()
        }
        while await !coordinator.isShutdownRequested {
            await Task.yield()
        }
        let shutdownEnteredDuringActiveUnlock =
            await coordinator.isShutdownInProgress

        let rejectedUnlock = await captureCredentialVaultError {
            try await coordinator.unlock(
                prompt: "Rejected after shutdown request",
                capability: .cli
            )
        }
        await provider.releaseLoad()

        let activeUnlockError = await activeUnlock.value
        await shutdown.value

        let events = await hooks.events
        let state = await session.state
        let calls = await provider.calls
        XCTAssertFalse(shutdownEnteredDuringActiveUnlock)
        XCTAssertEqual(rejectedUnlock, .locked)
        XCTAssertNil(activeUnlockError)
        XCTAssertEqual(
            events,
            ["prepare", "reopen", "begin", "confirm"]
        )
        XCTAssertEqual(state, .locked)
        XCTAssertEqual(calls.interactiveLoads, 1)
    }

    func testShutdownWaitsToEnterShuttingDownUntilSuspendedReopenReturns() async {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x6E, count: 32))
        )
        let session = VaultSession(provider: provider)
        let reopenGate = SuspendedReopenGate()
        let hooks = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {
                await hooks.record("begin:\(await session.state)")
            },
            confirmVaultLocked: {
                await hooks.record("confirm:\(await session.state)")
            },
            reopenRuntimeConstruction: {
                await hooks.record("reopen:entered")
                await reopenGate.enter()
                await hooks.record("reopen:returned")
            }
        )
        let unlock = Task {
            await captureCredentialVaultError {
                try await coordinator.unlock(
                    prompt: "Unlock before shutdown",
                    capability: .app
                )
            }
        }
        await reopenGate.waitUntilEntered()
        let shutdown = Task {
            await coordinator.shutdown()
        }
        while await !coordinator.isShutdownRequested {
            await Task.yield()
        }

        let eventsWhileReopenIsSuspended = await hooks.events
        let stateWhileReopenIsSuspended = await session.state
        let shutdownEnteredWhileReopenWasSuspended =
            await coordinator.isShutdownInProgress
        XCTAssertEqual(
            eventsWhileReopenIsSuspended,
            ["reopen:entered"]
        )
        XCTAssertEqual(stateWhileReopenIsSuspended, .unlocked)
        XCTAssertFalse(shutdownEnteredWhileReopenWasSuspended)

        let rejectedUnlock = await captureCredentialVaultError {
            try await coordinator.unlock(
                prompt: "Rejected after shutdown request",
                capability: .cli
            )
        }

        await reopenGate.release()
        let unlockError = await unlock.value
        await shutdown.value

        let events = await hooks.events
        let finalState = await session.state
        XCTAssertNil(unlockError)
        XCTAssertEqual(rejectedUnlock, .locked)
        XCTAssertEqual(
            events,
            [
                "reopen:entered",
                "reopen:returned",
                "begin:unlocked",
                "confirm:locked",
            ]
        )
        XCTAssertEqual(finalState, .locked)
        await XCTAssertCredentialVaultError(
            try await session.withKey { _ in true },
            equals: .locked
        )
    }

    func testRestartBeginsLockedAndRequiresFreshForegroundUnlock() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x7D, count: 32))
        )
        let firstSession = VaultSession(provider: provider)
        let first = PlainpostServiceLifecycleCoordinator(
            vaultSession: firstSession,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        try await first.unlock(
            prompt: "First service session",
            capability: .app
        )

        await first.shutdown()

        let firstSessionState = await firstSession.state
        XCTAssertEqual(firstSessionState, .locked)
        let secondSession = VaultSession(provider: provider)
        let second = PlainpostServiceLifecycleCoordinator(
            vaultSession: secondSession,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let restartedStatus = try await second.status()
        let loadsBeforeExplicitUnlock = await provider.calls.interactiveLoads
        XCTAssertEqual(
            restartedStatus,
            PlainpostVaultStatus(
                availability: .locked,
                matchingKeyItemCount: 1
            )
        )
        XCTAssertEqual(loadsBeforeExplicitUnlock, 1)

        try await second.unlock(
            prompt: "Second service session",
            capability: .cli
        )

        let loadsAfterExplicitUnlock = await provider.calls.interactiveLoads
        XCTAssertEqual(loadsAfterExplicitUnlock, 2)
        let secondSessionState = await secondSession.state
        XCTAssertEqual(secondSessionState, .unlocked)
    }

    func testListenerRejectsConnectionWhenLiveCapabilityResolutionReturnsNil() {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x11, count: 32))
        )
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: provider),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let resolver = ConnectionCapabilityResolverRecorder(result: nil)
        let serviceListener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator,
            capabilityForConnection: resolver.resolve
        )
        let connection = NSXPCConnection(
            machServiceName: "com.marynavdovenko.Plainpost.Unavailable",
            options: []
        )

        let accepted = serviceListener.listener(
            NSXPCListener.anonymous(),
            shouldAcceptNewConnection: connection
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(resolver.connectionCount, 1)
        XCTAssertTrue(resolver.lastConnection === connection)
        XCTAssertNil(connection.exportedObject)
    }

    func testListenerLockReturnsTypedErrorsByCapabilityWithoutQuietSideEffects() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x22, count: 32))
        )
        let session = VaultSession(provider: provider)
        let hooks = LifecycleHookRecorder()
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: session,
            prepareForegroundUnlock: {},
            beginVaultLockdown: {
                await hooks.record("begin")
            },
            confirmVaultLocked: {
                await hooks.record("confirm")
            },
            reopenRuntimeConstruction: {}
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator
        )
        let app = listener.exportedService(for: .app)
        let cli = listener.exportedService(for: .cli)
        let agent = listener.exportedService(for: .agent)
        let browser = listener.exportedService(for: .browserHost)

        let appUnlockError = await serviceUnlock(
            app,
            reason: "Foreground app unlock"
        )
        XCTAssertNil(appUnlockError)
        let loadsAfterAppUnlock = await provider.calls.interactiveLoads
        XCTAssertEqual(loadsAfterAppUnlock, 1)

        for quietService in [agent, browser] {
            let error = await serviceUnlock(
                quietService,
                reason: "Must stay quiet"
            )
            XCTAssertEqual(error?.code, .vaultLocked)
            let lockError = await serviceLock(quietService)
            XCTAssertEqual(lockError?.code, .clientUnauthorized)
        }

        let stateAfterQuietCalls = await session.state
        let loadsAfterQuietCalls = await provider.calls.interactiveLoads
        let eventsAfterQuietCalls = await hooks.events
        XCTAssertEqual(stateAfterQuietCalls, .unlocked)
        XCTAssertEqual(loadsAfterQuietCalls, 1)
        XCTAssertEqual(eventsAfterQuietCalls, [])

        let cliLockError = await serviceLock(cli)

        let stateAfterCLILock = await session.state
        let eventsAfterCLILock = await hooks.events
        XCTAssertNil(cliLockError)
        XCTAssertEqual(stateAfterCLILock, .locked)
        XCTAssertEqual(eventsAfterCLILock, ["begin", "confirm"])

        let secondAppUnlockError = await serviceUnlock(
            app,
            reason: "Second foreground app unlock"
        )
        let appLockError = await serviceLock(app)

        let finalState = await session.state
        let finalLoads = await provider.calls.interactiveLoads
        let finalEvents = await hooks.events
        XCTAssertNil(secondAppUnlockError)
        XCTAssertNil(appLockError)
        XCTAssertEqual(finalState, .locked)
        XCTAssertEqual(finalLoads, 2)
        XCTAssertEqual(
            finalEvents,
            ["begin", "confirm", "begin", "confirm"]
        )
    }

    func testListenerStatusIsQuietForEveryCapability() async throws {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x33, count: 32))
        )
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: provider),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator
        )

        for capability in PlainpostClientCapability.allCases {
            let result = await serviceStatus(
                listener.exportedService(for: capability)
            )
            XCTAssertNil(result.error)
            let status = try PlainpostVaultStatus(
                dto: XCTUnwrap(result.status)
            )
            XCTAssertEqual(
                status,
                PlainpostVaultStatus(
                    availability: .locked,
                    matchingKeyItemCount: 1
                )
            )
        }

        let calls = await provider.calls
        XCTAssertEqual(calls.interactiveLoads, 0)
        XCTAssertEqual(calls.countMatchingItems, 4)
    }

    func testQuietAgentAndBrowserOperationsStayLockedWithoutAuthorization()
        async throws
    {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x57, count: 32))
        )
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: provider),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let calls = QuietOperationHandlerRecorder()
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator,
            processBackgroundJobs: {
                await calls.recordAgent()
                return PlainpostBackgroundJobResult(
                    recoveredJobCount: 0,
                    processedJobCount: 1
                )
            },
            sendBrowserApprovedReply: { jobID in
                await calls.recordBrowser(jobID)
                return PlainpostBrowserApprovedReplyResult(
                    requestID: "request-1",
                    jobID: jobID,
                    state: "sent"
                )
            }
        )

        let agent = await serviceProcessBackgroundJobs(
            listener.exportedService(for: .agent)
        )
        let browser = await serviceSendBrowserApprovedReply(
            listener.exportedService(for: .browserHost),
            jobID: "job-1"
        )

        XCTAssertNil(agent.result)
        XCTAssertEqual(agent.error?.code, .vaultLocked)
        XCTAssertNil(browser.result)
        XCTAssertEqual(browser.error?.code, .vaultLocked)
        let providerCalls = await provider.calls
        XCTAssertEqual(providerCalls.interactiveLoads, 0)
        let handlerCalls = await calls.calls
        XCTAssertEqual(handlerCalls.agent, 0)
        XCTAssertEqual(handlerCalls.browserJobIDs, [])
    }

    func testSmartInboxBatchIsCLIOnlyBoundedAndQuietUntilExplicitUnlock()
        async throws
    {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .value(Data(repeating: 0x5A, count: 32))
        )
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: provider),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let calls = SmartInboxBatchHandlerRecorder()
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator,
            performSmartInboxBatch: { request in
                await calls.record(request)
                return PlainpostSmartInboxBatchResult(
                    accountID: request.accountID,
                    category: request.category,
                    action: request.action,
                    affectedMessageIDs: ["message-1"],
                    archiveMailbox: request.archiveMailbox
                )
            }
        )
        let request = try PlainpostSmartInboxBatchRequest(
            accountID: "account-1",
            category: "seen",
            action: "archive_read",
            archiveMailbox: "Archive"
        ).dto()

        let locked = await servicePerformSmartInboxBatch(
            listener.exportedService(for: .cli),
            request: request
        )
        let unauthorized = await servicePerformSmartInboxBatch(
            listener.exportedService(for: .app),
            request: request
        )

        XCTAssertNil(locked.result)
        XCTAssertEqual(locked.error?.code, .vaultLocked)
        XCTAssertNil(unauthorized.result)
        XCTAssertEqual(unauthorized.error?.code, .clientUnauthorized)
        let lockedRequests = await calls.requests
        let lockedProviderCalls = await provider.calls
        XCTAssertEqual(lockedRequests, [])
        XCTAssertEqual(lockedProviderCalls.interactiveLoads, 0)

        let cli = listener.exportedService(for: .cli)
        let unlockError = await serviceUnlock(
            cli,
            reason: "Explicit CLI unlock"
        )
        XCTAssertNil(unlockError)
        let malformed = try XCTUnwrap(
            PlainpostSmartInboxBatchRequestDTO(
                schemaVersion: 1,
                accountID: "account-1",
                category: "everything",
                action: "archive_read",
                archiveMailbox: "Archive"
            )
        )
        let malformedResult = await servicePerformSmartInboxBatch(
            cli,
            request: malformed
        )
        let success = await servicePerformSmartInboxBatch(
            cli,
            request: request
        )

        XCTAssertNil(malformedResult.result)
        XCTAssertEqual(malformedResult.error?.code, .invalidRequest)
        XCTAssertNil(success.error)
        XCTAssertEqual(success.result?.affectedMessageIDs, ["message-1"])
        let successfulRequests = await calls.requests
        XCTAssertEqual(
            successfulRequests,
            [
                PlainpostSmartInboxBatchRequest(
                    accountID: "account-1",
                    category: "seen",
                    action: "archive_read",
                    archiveMailbox: "Archive"
                ),
            ]
        )
    }

    func testListenerPreservesAuthorizationFailure() async {
        let provider = LifecycleVaultKeyProvider(
            matchingItemCount: 1,
            loadBehavior: .failure(.authorizationFailed)
        )
        let coordinator = PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: provider),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: coordinator
        )

        let error = await serviceUnlock(
            listener.exportedService(for: .app),
            reason: "Foreground authorization"
        )

        XCTAssertEqual(error?.code, .authorizationFailed)
    }
}
private actor LifecycleVaultKeyProvider: VaultKeyProvider {
    enum LoadBehavior: Sendable {
        case value(Data?)
        case failure(CredentialVaultError)
    }

    struct Calls: Equatable, Sendable {
        var countMatchingItems = 0
        var createIfMissing = 0
        var interactiveLoads = 0
    }

    private let matchingItemCount: Int
    private let loadBehavior: LoadBehavior
    private var suspended: Bool
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var didStartLoad = false
    private(set) var calls = Calls()

    init(
        matchingItemCount: Int,
        loadBehavior: LoadBehavior,
        startsSuspended: Bool = false
    ) {
        self.matchingItemCount = matchingItemCount
        self.loadBehavior = loadBehavior
        suspended = startsSuspended
    }

    func createIfMissing() {
        calls.createIfMissing += 1
    }

    func load(interactive: Bool, prompt: String?) async throws -> Data? {
        if interactive {
            calls.interactiveLoads += 1
        }
        didStartLoad = true
        startContinuation?.resume()
        startContinuation = nil
        if suspended {
            await withCheckedContinuation { loadContinuation = $0 }
        }
        switch loadBehavior {
        case let .value(value):
            return value
        case let .failure(error):
            throw error
        }
    }

    func countMatchingItems() -> Int {
        calls.countMatchingItems += 1
        return matchingItemCount
    }

    func waitUntilLoadStarts() async {
        guard !didStartLoad else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseLoad() {
        suspended = false
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
private actor LifecycleHookRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

private actor SingleUseTransitionGate {
    private var entries = 0
    private var firstEntryReleased = false
    private var firstEntryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entries += 1
        if entries == 1 {
            firstEntryWaiter?.resume()
            firstEntryWaiter = nil
            guard !firstEntryReleased else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilFirstEntry() async {
        guard entries > 0 else {
            await withCheckedContinuation { firstEntryWaiter = $0 }
            return
        }
    }

    func releaseFirstEntry() {
        firstEntryReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SuspendedReopenGate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor AsyncFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private final class ConnectionCapabilityResolverRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: PlainpostClientCapability?
    private var connections: [NSXPCConnection] = []

    init(result: PlainpostClientCapability?) {
        self.result = result
    }

    var connectionCount: Int {
        lock.withLock { connections.count }
    }

    var lastConnection: NSXPCConnection? {
        lock.withLock { connections.last }
    }

    func resolve(
        _ connection: NSXPCConnection
    ) -> PlainpostClientCapability? {
        lock.withLock {
            connections.append(connection)
        }
        return result
    }
}

private actor PairedDeviceHandlerRecorder {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private actor ForegroundOperationHandlerRecorder {
    private(set) var kinds: [PlainpostForegroundOperationKind] = []

    func record(_ kind: PlainpostForegroundOperationKind) { kinds.append(kind) }
}

private actor QuietOperationHandlerRecorder {
    struct Calls: Equatable {
        var agent = 0
        var browserJobIDs: [String] = []
    }

    private(set) var calls = Calls()

    func recordAgent() {
        calls.agent += 1
    }

    func recordBrowser(_ jobID: String) {
        calls.browserJobIDs.append(jobID)
    }
}

private actor SmartInboxBatchHandlerRecorder {
    private(set) var requests: [PlainpostSmartInboxBatchRequest] = []

    func record(_ request: PlainpostSmartInboxBatchRequest) {
        requests.append(request)
    }
}

private func XCTAssertCredentialVaultError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: CredentialVaultError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? CredentialVaultError,
            expected,
            file: file,
            line: line
        )
    }
}

private func captureCredentialVaultError(
    _ operation: @escaping @Sendable () async throws -> Void
) async -> CredentialVaultError? {
    do {
        try await operation()
        return nil
    } catch let error as CredentialVaultError {
        return error
    } catch {
        return nil
    }
}

private func serviceStatus(
    _ service: PlainpostServiceXPCProtocol
) async -> (
    status: PlainpostVaultStatusDTO?,
    error: PlainpostXPCErrorDTO?
) {
    await withCheckedContinuation { continuation in
        service.status { status, error in
            continuation.resume(returning: (status, error))
        }
    }
}

private func serviceUnlock(
    _ service: PlainpostServiceXPCProtocol,
    reason: String
) async -> PlainpostXPCErrorDTO? {
    await withCheckedContinuation { continuation in
        service.unlock(reason: reason) { error in
            continuation.resume(returning: error)
        }
    }
}

private func serviceLock(
    _ service: PlainpostServiceXPCProtocol
) async -> PlainpostXPCErrorDTO? {
    await withCheckedContinuation { continuation in
        service.lock { error in
            continuation.resume(returning: error)
        }
    }
}

private func servicePerform(
    _ service: PlainpostServiceXPCProtocol, request: PlainpostForegroundOperationRequestDTO
) async -> (result: PlainpostForegroundOperationResultDTO?, error: PlainpostXPCErrorDTO?) {
    await withCheckedContinuation { continuation in
        service.performForegroundOperation(request) { result, error in
            continuation.resume(returning: (result, error))
        }
    }
}

private func serviceProcessBackgroundJobs(
    _ service: PlainpostServiceXPCProtocol
) async -> (
    result: PlainpostBackgroundJobResultDTO?,
    error: PlainpostXPCErrorDTO?
) {
    await withCheckedContinuation { continuation in
        service.processBackgroundJobs { result, error in
            continuation.resume(returning: (result, error))
        }
    }
}

private func servicePerformSmartInboxBatch(
    _ service: PlainpostServiceXPCProtocol,
    request: PlainpostSmartInboxBatchRequestDTO
) async -> (
    result: PlainpostSmartInboxBatchResultDTO?,
    error: PlainpostXPCErrorDTO?
) {
    await withCheckedContinuation { continuation in
        service.performSmartInboxBatch(request) { result, error in
            continuation.resume(returning: (result, error))
        }
    }
}

private func serviceSendBrowserApprovedReply(
    _ service: PlainpostServiceXPCProtocol,
    jobID: String
) async -> (
    result: PlainpostBrowserApprovedReplyResultDTO?,
    error: PlainpostXPCErrorDTO?
) {
    let request = PlainpostBrowserApprovedReplyRequestDTO(
        schemaVersion: 1,
        jobID: jobID
    )!
    return await withCheckedContinuation { continuation in
        service.sendBrowserApprovedReply(request) { result, error in
            continuation.resume(returning: (result, error))
        }
    }
}
