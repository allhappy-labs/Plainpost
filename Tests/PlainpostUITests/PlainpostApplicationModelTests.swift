import Foundation
import XCTest
@testable import PlainpostAccounts
@testable import PlainpostCore
@testable import PlainpostDB
import PlainpostOperations
import PlainpostTestSupport
import PlainpostRuntimeTestSupport
import PlainpostServiceIPC
@testable import PlainpostUI

final class PlainpostApplicationModelTests: XCTestCase {
    @MainActor
    func testStartRestoresPackagedServiceBeforeVaultReadiness() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let sequence = ManagedPurgeSequenceProbe()
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            prepareService: { await sequence.record("restore-service") },
            vaultReadiness: {
                await sequence.record("vault-readiness")
                return .locked
            },
            initializeImmediately: false
        )

        model.start()
        await waitForLaunchState(model, expected: .locked)

        let events = await sequence.snapshot()
        XCTAssertEqual(events, ["restore-service", "vault-readiness"])
    }

    @MainActor func testVaultReadinessAvailabilityHasOneDistinctLaunchStatePerFailure() async {
        let cases: [(PlainpostVaultStatus.Availability, PlainpostVaultLaunchState)] = [
            (.locked, .locked), (.unlocked, .ready), (.keyMissing, .keyMissing),
            (.keyAmbiguous, .keyAmbiguous), (.ciphertextInvalid, .ciphertextInvalid),
            (.unsupportedVersion(7), .unsupportedVersion(7)),
        ]

        for (availability, expectedDescription) in cases {
            let client = RecordingPlainpostServiceClient(statusResults: [
                .success(
                    PlainpostVaultStatus(
                        availability: availability,
                        matchingKeyItemCount: availability == .keyMissing ? 0 : 1))
            ])
            let gate = PlainpostVaultReadinessGate(serviceClient: client)
            let state = await gate.evaluate()

            XCTAssertEqual(state, expectedDescription, "availability \(availability)")
        }
    }

    @MainActor func testVaultReadinessErrorsHaveDistinctLaunchStates() async {
        let cases: [(PlainpostServiceClientError, PlainpostVaultLaunchState)] = [
            (.vaultLocked, .locked), (.authorizationCancelled, .locked),
            (.authorizationFailed, .authorizationFailed), (.vaultKeyMissing, .keyMissing),
            (.vaultKeyAmbiguous, .keyAmbiguous), (.ciphertextInvalid, .ciphertextInvalid),
            (.unsupportedVaultVersion(9), .unsupportedVersion(9)),
            (.clientUnauthorized, .serviceUnavailable), (.serviceUnavailable, .serviceUnavailable),
            (.timedOut, .serviceUnavailable), (.invalidRequest, .serviceUnavailable),
            (.operationFailed, .serviceUnavailable),
        ]

        for (error, expectedDescription) in cases {
            let client = RecordingPlainpostServiceClient(statusResults: [.failure(error)])
            let gate = PlainpostVaultReadinessGate(serviceClient: client)
            let state = await gate.evaluate()

            XCTAssertEqual(state, expectedDescription, "error \(error)")
        }
    }

    @MainActor func testCancelledUnlockStaysLockedWithoutRetry() async {
        let client = RecordingPlainpostServiceClient(unlockResults: [
            .failure(.authorizationCancelled)
        ])
        let gate = PlainpostVaultReadinessGate(serviceClient: client)
        let state = await gate.unlock(reason: PlainpostApplicationModel.unlockReason)

        XCTAssertEqual(state, .locked)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.unlockCallCount, 1)
        XCTAssertEqual(snapshot.statusCallCount, 0)
        XCTAssertEqual(snapshot.semanticOperationCallCount, 0)
    }

    @MainActor func testStartOverGateOpensTheVaultWithoutReadingStatus() async {
        let client = RecordingPlainpostServiceClient()
        let gate = PlainpostVaultReadinessGate(serviceClient: client)

        let state = await gate.startOver(reason: PlainpostApplicationModel.unlockReason)

        XCTAssertEqual(state, .ready)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.startOverReasons, [PlainpostApplicationModel.unlockReason])
        XCTAssertEqual(snapshot.statusCallCount, 0)
        XCTAssertEqual(snapshot.unlockCallCount, 0)
    }

    @MainActor func testRefusedStartOverRereadsTheVaultAndCancelledPromptStaysLocked() async {
        let refused = RecordingPlainpostServiceClient(
            statusResults: [.success(PlainpostVaultStatus(availability: .keyMissing, matchingKeyItemCount: 0))],
            startOverResults: [.failure(.operationFailed)]
        )
        let refusedState = await PlainpostVaultReadinessGate(serviceClient: refused)
            .startOver(reason: PlainpostApplicationModel.unlockReason)
        XCTAssertEqual(refusedState, .keyMissing)
        let refusedSnapshot = await refused.snapshot()
        XCTAssertEqual(refusedSnapshot.statusCallCount, 1)

        // The fresh key exists once the archive ran; a cancelled prompt leaves an ordinary locked vault.
        let cancelled = RecordingPlainpostServiceClient(startOverResults: [.failure(.authorizationCancelled)])
        let cancelledState = await PlainpostVaultReadinessGate(serviceClient: cancelled)
            .startOver(reason: PlainpostApplicationModel.unlockReason)
        XCTAssertEqual(cancelledState, .locked)
    }

    @MainActor func testStartOverFromAMissingKeyStartsTheRuntime() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .keyMissing)
        let startOver = StartOverProbe(results: [.ready])
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime }, monitor: { _ in },
            vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            startOverVault: { reason in await startOver.startOver(reason: reason) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .keyMissing)
        model.startOverWithSavedSignIns()
        await waitForLaunchState(model, expected: .ready)

        XCTAssertTrue(model.runtime === fixture.runtime)
        XCTAssertNil(model.vaultStartOverError)
        XCTAssertTrue(model.startedOverWithSavedSignIns)
        let reasons = await startOver.reasons
        XCTAssertEqual(reasons, [PlainpostApplicationModel.unlockReason])
        let unlockCalls = await readiness.unlockCallCount()
        XCTAssertEqual(unlockCalls, 0)
    }

    @MainActor func testStartOverIsOnlyOfferedForAMissingKey() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let states: [PlainpostVaultLaunchState] = [
            .locked, .keyAmbiguous, .ciphertextInvalid, .unsupportedVersion(3),
            .authorizationFailed, .serviceUnavailable,
        ]
        for initial in states {
            let readiness = ReadinessProbe(initial: initial)
            let startOver = StartOverProbe(results: [.ready])
            let model = PlainpostApplicationModel(
                makeRuntime: { fixture.runtime }, monitor: { _ in },
                vaultReadiness: { await readiness.evaluate() },
                startOverVault: { reason in await startOver.startOver(reason: reason) },
                initializeImmediately: false)

            model.start()
            await waitForLaunchState(model, expected: initial)
            model.startOverWithSavedSignIns()
            for _ in 0..<20 { await Task.yield() }

            let reasons = await startOver.reasons
            XCTAssertEqual(reasons, [], "\(initial)")
            XCTAssertNil(model.runtime, "\(initial)")
        }
    }

    @MainActor func testFailedStartOverStaysOnTheMissingKeyWithAMessageAndCanBeTriedAgain() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .keyMissing)
        let startOver = StartOverProbe(results: [.keyMissing, .ready])
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime }, monitor: { _ in },
            vaultReadiness: { await readiness.evaluate() },
            startOverVault: { reason in await startOver.startOver(reason: reason) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .keyMissing)
        model.startOverWithSavedSignIns()
        await waitForModel(model) { model.vaultStartOverError != nil }

        XCTAssertEqual(model.vaultLaunchState, .keyMissing)
        XCTAssertEqual(model.vaultStartOverError, PlainpostApplicationModel.vaultStartOverFailureMessage)
        XCTAssertNil(model.runtime)
        XCTAssertFalse(model.startedOverWithSavedSignIns)

        model.startOverWithSavedSignIns()
        await waitForLaunchState(model, expected: .ready)
        XCTAssertNil(model.vaultStartOverError)
        XCTAssertTrue(model.runtime === fixture.runtime)
    }

    private func runtimeConfiguration(databaseURL: URL, keychainService: String)
        -> PlainpostAppRuntimeConfiguration
    {
        RuntimeKeychainIsolation(
            testCase: self,
            databaseURL: databaseURL,
            keychainService: keychainService
        ).configuration
    }

    @MainActor func testDefaultGUIServiceOwnerUnlocksThroughServiceAndBuildsRuntime() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gui-vault-owner-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let serviceClient = RuntimeServiceClientFake(availability: .locked)
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: databaseURL,
            keychainService: "GUIVaultOwner.\(UUID().uuidString)",
            serviceClient: serviceClient
        )
        let owner = DefaultGUIServiceOwner(configuration: configuration)

        let lockedState = await owner.evaluate()
        XCTAssertEqual(lockedState, .locked)
        let unlockedState = await owner.unlock(reason: PlainpostApplicationModel.unlockReason)
        XCTAssertEqual(unlockedState, .ready)
        let runtime = try owner.makeRuntime()
        XCTAssertEqual(runtime.configuration.databaseURL, databaseURL)
        await runtime.shutdown()
    }

    @MainActor
    func testUnlockRequiredDoesNotCreateRuntimeBeforeSuccessfulUnlock() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        let readiness = ReadinessProbe(initial: .locked)
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            }, monitor: { runtime in await probe.run(runtimeID: ObjectIdentifier(runtime)) },
            vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .locked)

        XCTAssertNil(model.runtime)
        XCTAssertEqual(runtimeCreationCount, 0)
        let initialSnapshot = await probe.snapshot()
        XCTAssertEqual(initialSnapshot.starts, 0)

        await readiness.setUnlockResult(.ready)
        model.unlockVault()
        _ = await waitForProbe(probe) { $0.starts == 1 }

        XCTAssertTrue(model.runtime === fixture.runtime)
        XCTAssertEqual(runtimeCreationCount, 1)
    }

    @MainActor
    func testAccountOfflineStartsLocalRuntimeWithoutMailMonitorAndActiveEnablesIt() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { runtime in await probe.run(runtimeID: ObjectIdentifier(runtime)) },
            vaultReadiness: { .ready },
            initializeImmediately: false
        )

        model.start(readOnly: true)
        await waitForLaunchState(model, expected: .ready)
        XCTAssertNotNil(model.runtime)
        XCTAssertTrue(model.accountReadOnly)
        let offlineProbe = await probe.snapshot()
        XCTAssertEqual(offlineProbe.starts, 0)

        model.start(readOnly: false)
        _ = await waitForProbe(probe) { $0.starts == 1 }
        XCTAssertFalse(model.accountReadOnly)
        await model.shutdown()
    }

    @MainActor
    func testAccountAccessSelectsFactoryBeforeConstructionAndSeriallyReplacesOfflineRuntime() async throws {
        let offlineFixture = try RuntimeFixture(testCase: self)
        let activeFixture = try RuntimeFixture(testCase: self)
        var offlineConstructions = 0
        var activeConstructions = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                activeConstructions += 1
                return activeFixture.runtime
            },
            makeReadOnlyRuntime: {
                offlineConstructions += 1
                return offlineFixture.runtime
            },
            monitor: { _ in },
            vaultReadiness: { .ready },
            initializeImmediately: false
        )

        model.start(readOnly: true)
        for _ in 0 ..< 300 where model.runtime !== offlineFixture.runtime {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.runtime === offlineFixture.runtime)
        XCTAssertEqual(offlineConstructions, 1)
        XCTAssertEqual(activeConstructions, 0)

        model.start(readOnly: false)
        for _ in 0 ..< 300 where model.runtime !== activeFixture.runtime {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.runtime === activeFixture.runtime)
        XCTAssertEqual(offlineConstructions, 1)
        XCTAssertEqual(activeConstructions, 1)
        await model.shutdown()
    }

    @MainActor
    func testGlobalAccountPurgeStopsRuntimeBeforeManagedDataDeletion() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let sequence = ManagedPurgeSequenceProbe()
        let expectedDigest = Data(repeating: 0xA7, count: 32)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            shutdownRuntime: { runtime in
                await sequence.record("shutdown")
                await runtime.shutdown()
            },
            purgeManagedData: {
                await sequence.record("purge")
                return expectedDigest
            },
            vaultReadiness: { .ready },
            initializeImmediately: false
        )
        model.start()
        for _ in 0 ..< 300 where model.runtime == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.runtime)

        let digest = try await model.purgePlainpostManagedData()

        XCTAssertEqual(digest, expectedDigest)
        XCTAssertNil(model.runtime)
        let events = await sequence.snapshot()
        XCTAssertEqual(events, ["shutdown", "purge"])
    }

    @MainActor
    func testCancelledUnlockLeavesApplicationLockedWithoutStartingRuntime() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .locked)
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            }, monitor: { _ in }, vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .locked)
        await readiness.setUnlockResult(.locked)
        model.unlockVault()
        await waitForLaunchState(model, expected: .locked)

        XCTAssertNil(model.runtime)
        XCTAssertEqual(runtimeCreationCount, 0)
    }

#if DEBUG
    @MainActor
    func testAcceptanceBootstrapFailureKeepsRuntimeLockedWithoutStartingIt() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .locked)
        let bootstrap = AcceptanceBootstrapProbe(result: .locked)
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            }, monitor: { _ in }, vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            acceptanceReadinessBootstrap: { state in await bootstrap.resolve(state) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .locked)

        XCTAssertNil(model.runtime)
        XCTAssertEqual(runtimeCreationCount, 0)
        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 1)
    }

    @MainActor
    func testAcceptanceBootstrapUnavailableKeepsRuntimeUnavailableWithoutStartingIt() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .locked)
        let bootstrap = AcceptanceBootstrapProbe(result: .serviceUnavailable)
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            }, monitor: { _ in }, vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            acceptanceReadinessBootstrap: { state in await bootstrap.resolve(state) },
            initializeImmediately: false)

        model.start()
        await waitForLaunchState(model, expected: .serviceUnavailable)

        XCTAssertNil(model.runtime)
        XCTAssertEqual(runtimeCreationCount, 0)
        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 1)
    }

    @MainActor
    func testAcceptanceBootstrapStartsRuntimeExactlyOnceAfterReturningReady() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = ReadinessProbe(initial: .locked)
        let bootstrap = AcceptanceBootstrapProbe(result: .ready)
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            }, monitor: { _ in }, vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) },
            acceptanceReadinessBootstrap: { state in await bootstrap.resolve(state) },
            initializeImmediately: false)

        model.start()
        model.start()
        for _ in 0..<200 where runtimeCreationCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(model.runtime === fixture.runtime)
        XCTAssertEqual(runtimeCreationCount, 1)
        let bootstrapCalls = await bootstrap.callCount()
        XCTAssertEqual(bootstrapCalls, 1)
    }
#endif

    @MainActor func testTerminalVaultFailuresDoNotOfferUnlockOrCreateRuntime() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let terminalStates: [PlainpostVaultLaunchState] = [
            .keyMissing, .keyAmbiguous, .ciphertextInvalid, .unsupportedVersion(3),
            .authorizationFailed, .serviceUnavailable,
        ]

        for terminalState in terminalStates {
            let readiness = ReadinessProbe(initial: terminalState)
            var runtimeCreationCount = 0
            let model = PlainpostApplicationModel(
                makeRuntime: {
                    runtimeCreationCount += 1
                    return fixture.runtime
                }, monitor: { _ in }, vaultReadiness: { await readiness.evaluate() },
                unlockVault: { reason in await readiness.unlock(reason: reason) },
                initializeImmediately: false)

            model.start()
            await waitForLaunchState(model, expected: terminalState)
            model.unlockVault()

            XCTAssertNil(model.runtime)
            XCTAssertEqual(runtimeCreationCount, 0)
            let unlockCallCount = await readiness.unlockCallCount()
            XCTAssertEqual(unlockCallCount, 0)
        }
    }

    @MainActor
    func testTerminalServiceFailureAfterRuntimeCreationAwaitsShutdownAndReleasesRuntime()
        async throws
    {
        let cases: [(PlainpostServiceClientError, PlainpostVaultLaunchState)] = [
            (.vaultLocked, .locked),
            (.vaultKeyMissing, .keyMissing),
            (.vaultKeyAmbiguous, .keyAmbiguous),
            (.ciphertextInvalid, .ciphertextInvalid),
            (.unsupportedVaultVersion(11), .unsupportedVersion(11)),
            (.authorizationFailed, .authorizationFailed),
            (.serviceUnavailable, .serviceUnavailable),
        ]

        for (error, expectedState) in cases {
            let fixture = try RuntimeFixture(testCase: self)
            let readiness = MutableReadinessProbe(result: expectedState)
            let model = PlainpostApplicationModel(
                makeRuntime: { fixture.runtime },
                monitor: { _ in throw error },
                vaultReadiness: { await readiness.evaluate() }
            )

            await waitForLaunchState(model, expected: expectedState)

            XCTAssertNil(model.runtime, "error \(error)")
            let readinessSnapshot = await readiness.snapshot()
            XCTAssertEqual(
                readinessSnapshot.statusCalls,
                error == .serviceUnavailable ? 1 : 0,
                "error \(error)"
            )
        }
    }

    @MainActor
    func testTransientServiceFailureQuietlyReconnectsBeforeShowingUnavailable() async throws {
        let firstFixture = try RuntimeFixture(testCase: self)
        let replacementFixture = try RuntimeFixture(testCase: self)
        let failureGate = RuntimeFailureGate()
        let readiness = MutableReadinessProbe(result: .ready)
        let replacementMonitor = MonitorProbe()
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return runtimeCreationCount == 1
                    ? firstFixture.runtime
                    : replacementFixture.runtime
            },
            monitor: { runtime in
                if runtime === firstFixture.runtime {
                    await failureGate.wait()
                    throw PlainpostServiceClientError.serviceUnavailable
                }
                await replacementMonitor.run(
                    runtimeID: ObjectIdentifier(runtime)
                )
            },
            vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) }
        )

        await failureGate.trigger()
        await waitForModel(model) {
            model.vaultLaunchState == .ready
                && model.runtime === replacementFixture.runtime
        }

        XCTAssertEqual(runtimeCreationCount, 2)
        XCTAssertTrue(model.runtime === replacementFixture.runtime)
        let readinessSnapshot = await readiness.snapshot()
        XCTAssertEqual(readinessSnapshot.statusCalls, 1)
        XCTAssertEqual(readinessSnapshot.unlockCalls, 0)
        let monitorSnapshot = await waitForProbe(replacementMonitor) {
            $0.starts == 1 && $0.active == 1
        }
        XCTAssertEqual(monitorSnapshot.maximumActive, 1)

        await model.shutdown()
    }

    @MainActor
    func testServiceAdapterTerminalFailureReleasesProductionRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "svc-terminal-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = RuntimeServiceClientFake()
        let configuration = PlainpostAppRuntimeConfiguration(
            databaseURL: directory.appendingPathComponent("Plainpost.sqlite"),
            keychainService: "unused-service-only-\(UUID().uuidString)",
            serviceClient: client
        )
        let model = PlainpostApplicationModel(configuration: configuration)
        for _ in 0..<200 where model.runtime == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let runtime = try XCTUnwrap(model.runtime)
        await client.failNextOperation(.markRead, with: .vaultKeyMissing)

        _ = await runtime.makeInboxMailActionViewModel().perform(
            .markRead,
            messageID: "message-1"
        )
        await waitForLaunchState(model, expected: .keyMissing)

        XCTAssertNil(model.runtime)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.foregroundOperationKinds, [.markRead])
        XCTAssertEqual(snapshot.unlockReasons, [])
    }

    @MainActor
    func testRetryWithRunningRuntimeUsesQuietStatusAndNeverUnlocks() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let readiness = MutableReadinessProbe(result: .locked)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) }
        )

        model.retry()
        await waitForLaunchState(model, expected: .locked)

        XCTAssertNil(model.runtime)
        let snapshot = await readiness.snapshot()
        XCTAssertEqual(snapshot.statusCalls, 1)
        XCTAssertEqual(snapshot.unlockCalls, 0)
    }

    @MainActor
    func testRetryWaitsForTerminalTeardownBeforeInstallingReplacementRuntime() async throws {
        let firstFixture = try RuntimeFixture(testCase: self)

        let failureGate = RuntimeFailureGate()
        let shutdownBarrier = RuntimeShutdownBarrier()
        let readiness = MutableReadinessProbe(result: .ready)
        let monitorProbe = MonitorProbe()
        var replacementFixture: RuntimeFixture?
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                if runtimeCreationCount == 1 {
                    return firstFixture.runtime
                }
                let fixture = try RuntimeFixture(testCase: self)
                replacementFixture = fixture
                return fixture.runtime
            },
            monitor: { runtime in
                if runtime === firstFixture.runtime {
                    await failureGate.wait()
                    throw PlainpostServiceClientError.vaultKeyMissing
                }
                await monitorProbe.run(runtimeID: ObjectIdentifier(runtime))
            },
            shutdownRuntime: { runtime in
                if runtime === firstFixture.runtime {
                    await shutdownBarrier.suspend()
                }
                await runtime.shutdown()
                if runtime === firstFixture.runtime {
                    await shutdownBarrier.complete()
                }
            },
            vaultReadiness: { await readiness.evaluate() },
            unlockVault: { reason in await readiness.unlock(reason: reason) }
        )

        await failureGate.trigger()
        await shutdownBarrier.waitUntilEntered()
        XCTAssertNil(model.runtime)
        XCTAssertEqual(model.vaultLaunchState, .checking)

        model.retry()
        for _ in 0..<200 {
            await Task.yield()
        }

        let suspendedSnapshot = await readiness.snapshot()
        XCTAssertEqual(runtimeCreationCount, 1)
        XCTAssertNil(replacementFixture)
        XCTAssertNil(model.runtime)
        XCTAssertEqual(model.vaultLaunchState, .checking)
        XCTAssertEqual(suspendedSnapshot.statusCalls, 0)
        XCTAssertEqual(suspendedSnapshot.unlockCalls, 0)

        await shutdownBarrier.release()
        await shutdownBarrier.waitUntilCompleted()
        await waitForModel(model) {
            model.vaultLaunchState == .ready
                && replacementFixture != nil
                && model.runtime === replacementFixture?.runtime
        }

        let replacement = try XCTUnwrap(replacementFixture)
        XCTAssertEqual(runtimeCreationCount, 2)
        XCTAssertTrue(model.runtime === replacement.runtime)
        XCTAssertEqual(model.vaultLaunchState, .ready)

        let finalReadinessSnapshot = await readiness.snapshot()
        XCTAssertEqual(finalReadinessSnapshot.statusCalls, 1)
        XCTAssertEqual(finalReadinessSnapshot.unlockCalls, 0)
        let runningMonitor = await waitForProbe(monitorProbe) { $0.active == 1 }
        XCTAssertEqual(runningMonitor.starts, 1)
        XCTAssertEqual(runningMonitor.maximumActive, 1)
        XCTAssertEqual(runningMonitor.runtimeIDs, [ObjectIdentifier(replacement.runtime)])

        await model.shutdown()
        let stoppedMonitor = await waitForProbe(monitorProbe) {
            $0.cancellations == 1 && $0.active == 0
        }
        XCTAssertEqual(stoppedMonitor.maximumActive, 1)
    }

    @MainActor
    func testMailKeychainUnlockUsesTheKeychainInteractionWithoutSeparateLocalAuthentication()
        async throws
    {
        let serviceClient = RuntimeServiceClientFake(availability: .locked)
        let gate = PlainpostVaultReadinessGate(serviceClient: serviceClient)

        let state = await gate.unlock(reason: PlainpostApplicationModel.unlockReason)

        XCTAssertEqual(state, .ready)
        let snapshot = await serviceClient.snapshot()
        XCTAssertEqual(
            snapshot.unlockReasons,
            ["Unlock Plainpost to access your saved mail credentials."]
        )
    }

    @MainActor
    func testDeferredProductionInitializationStartsOnlyWhenRequested() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            },
            monitor: { runtime in
                await probe.run(runtimeID: ObjectIdentifier(runtime))
            },
            initializeImmediately: false
        )

        XCTAssertNil(model.runtime)
        XCTAssertEqual(runtimeCreationCount, 0)

        model.start()
        model.start()
        let snapshot = await waitForProbe(probe) { $0.starts == 1 }

        XCTAssertTrue(model.runtime === fixture.runtime)
        XCTAssertEqual(runtimeCreationCount, 1)
        XCTAssertEqual(snapshot.starts, 1)
    }

    @MainActor
    func testProductionModelStartsWithoutAWindowTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let keychainService = "PlainpostApplicationHeadlessTests.\(UUID().uuidString)"
        let configuration = runtimeConfiguration(
            databaseURL: directory.appendingPathComponent("Plainpost.sqlite"),
            keychainService: keychainService
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var model: PlainpostApplicationModel? = PlainpostApplicationModel(configuration: configuration)
        for _ in 0..<200 where model?.runtime == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        let runtime = try XCTUnwrap(model?.runtime)

        model?.start()
        XCTAssertTrue(model?.runtime === runtime)
        await runtime.shutdown()
        model = nil
    }

    @MainActor
    func testShutdownStopsTheRuntimeBeforeReturning() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in }
        )
        let runtime = try XCTUnwrap(model.runtime)

        await model.shutdown()

        XCTAssertNil(model.runtime)
    }

    @MainActor
    func testInitializationCreatesOneRuntimeAndStartsOneMonitor() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        var runtimeCreationCount = 0
        var model: PlainpostApplicationModel? = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            },
            monitor: { runtime in
                await probe.run(runtimeID: ObjectIdentifier(runtime))
            }
        )

        let snapshot = await waitForProbe(probe) { $0.starts == 1 }
        XCTAssertEqual(runtimeCreationCount, 1)
        XCTAssertTrue(model?.runtime === fixture.runtime)
        XCTAssertEqual(snapshot.active, 1)
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.runtimeIDs, [ObjectIdentifier(fixture.runtime)])

        model = nil
        let cancelled = await waitForProbe(probe) { $0.cancellations == 1 }
        XCTAssertEqual(cancelled.active, 0)
    }

    @MainActor
    func testRetryRecoversFromFailureAndStartsOnlyOneMonitor() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        let factoryState = RuntimeFactoryState()
        let model = PlainpostApplicationModel(
            makeRuntime: {
                factoryState.creationCount += 1
                if factoryState.shouldFail {
                    throw RuntimeFixture.Failure.unavailable
                }
                return fixture.runtime
            },
            monitor: { runtime in
                await probe.run(runtimeID: ObjectIdentifier(runtime))
            }
        )

        XCTAssertNil(model.runtime)
        XCTAssertTrue(model.runtimeError?.contains("initialization failed") == true)

        model.retry()
        XCTAssertNil(model.runtime)
        XCTAssertTrue(model.runtimeError?.contains("still failed") == true)

        factoryState.shouldFail = false
        model.retry()
        let snapshot = await waitForProbe(probe) { $0.starts == 1 }

        XCTAssertEqual(factoryState.creationCount, 3)
        XCTAssertTrue(model.runtime === fixture.runtime)
        XCTAssertNil(model.runtimeError)
        XCTAssertEqual(snapshot.active, 1)
        XCTAssertEqual(snapshot.maximumActive, 1)
    }

    @MainActor
    func testRetryDoesNotReplaceHealthyRuntimeOrDuplicateMonitor() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let probe = MonitorProbe()
        var runtimeCreationCount = 0
        let model = PlainpostApplicationModel(
            makeRuntime: {
                runtimeCreationCount += 1
                return fixture.runtime
            },
            monitor: { runtime in
                await probe.run(runtimeID: ObjectIdentifier(runtime))
            }
        )

        _ = await waitForProbe(probe) { $0.starts == 1 }
        model.retry()
        for _ in 0..<10 {
            await Task.yield()
        }
        let snapshot = await probe.snapshot()

        XCTAssertEqual(runtimeCreationCount, 1)
        XCTAssertEqual(snapshot.starts, 1)
        XCTAssertEqual(snapshot.active, 1)
        XCTAssertEqual(snapshot.maximumActive, 1)
    }

    @MainActor
    func testLocalAPILockContentionStartsUsablePassiveRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-bind-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("Plainpost.sqlite")
        let keychainService = "PlainpostApplicationModelBindTests.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = runtimeConfiguration(
            databaseURL: databaseURL,
            keychainService: keychainService
        )
        let blocker = try PlainpostAppRuntime(
            configuration: configuration,
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let model = PlainpostApplicationModel(
            makeRuntime: {
                try PlainpostAppRuntime(
                    configuration: configuration,
                    notificationScheduler: NoopLocalNotificationScheduler()
                )
            },
            monitor: { _ in }
        )

        XCTAssertNotNil(model.runtime)
        XCTAssertNil(model.runtimeError)
        XCTAssertEqual(blocker.localAPIOwnershipState, .owner)
        XCTAssertEqual(model.runtime?.localAPIOwnershipState, .passive)
        await model.shutdown()
        await blocker.shutdown()
    }

    @MainActor
    func testMailMonitoringRunsWithoutCreatingAWindowScene() async throws {
        let imapPassword = "application-monitor-imap-secret"
        let smtpPassword = "application-monitor-smtp-secret"
        let imap = LocalIMAPServer(
            username: "me@example.com",
            password: imapPassword,
            message: PlainpostFixtures.aliceMessage
        )
        let smtp = LocalSMTPServer(
            username: "me@example.com",
            password: smtpPassword
        )
        try await imap.start()
        try await smtp.start()
        defer {
            imap.stop()
            smtp.stop()
        }

        let fixture = try RuntimeFixture(testCase: self)
        let accountSetup = fixture.runtime.makeAccountSetupViewModel()
        accountSetup.displayName = "Personal"
        accountSetup.email = "me@example.com"
        accountSetup.imapHost = "127.0.0.1"
        accountSetup.imapPort = "\(imap.port)"
        accountSetup.smtpHost = "127.0.0.1"
        accountSetup.smtpPort = "\(smtp.port)"
        accountSetup.username = "me@example.com"
        accountSetup.imapPassword = imapPassword
        accountSetup.smtpPassword = smtpPassword
        try await accountSetup.submit()
        // iOS selects the newly admitted account before beginning foreground
        // monitoring. The pre-selection worker intentionally has no claim scope.
        await fixture.runtime.shutdown()
        let selectedRuntime = try PlainpostAppRuntime(
            configuration: PlainpostAppRuntimeConfiguration(
                databaseURL: fixture.databaseURL,
                selectedAccountID: AccountID("acc_me_example_com"),
                runtimeDependencies: try XCTUnwrap(
                    fixture.runtime.configuration.runtimeDependencies
                )
            ),
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        defer { Task { await selectedRuntime.shutdown() } }
        let loginCountAfterSetup = imap.loginAttempts.count
        let baselineStateFetches = imap.messageStateFetchCount
        let observationStore = try SQLiteMailStore(path: fixture.databaseURL.path)
        try observationStore.migrate()

        var model: PlainpostApplicationModel? = PlainpostApplicationModel(
            makeRuntime: { selectedRuntime },
            monitor: { runtime in
                try await runtime.monitorMail(interval: .milliseconds(10))
            }
        )

        var completedMonitorJob: PlainpostDurableJob?
        for _ in 0..<200 {
            let jobs = try observationStore.jobs(limit: 100)
            completedMonitorJob = jobs.first(where: { job in
                guard job.kind == .inboxSync, job.state == .completed,
                      let input = try? JSONDecoder().decode(
                          PlainpostInboxSyncInput.self,
                          from: Data(job.payloadJSON.utf8)
                      ) else {
                    return false
                }
                return input.trigger == .realTimeSignal && input.scope == .incremental
            })
            if completedMonitorJob != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNotNil(model?.runtime)
        XCTAssertGreaterThan(imap.loginAttempts.count, loginCountAfterSetup)
        let observedMonitorJob = try XCTUnwrap(
            completedMonitorJob,
            "Timed out waiting for a foreground monitor job to complete."
        )
        XCTAssertEqual(observedMonitorJob.state, .completed)
        let monitorInputs = try observationStore.jobs(limit: 100).compactMap { job -> PlainpostInboxSyncInput? in
            try? JSONDecoder().decode(PlainpostInboxSyncInput.self, from: Data(job.payloadJSON.utf8))
        }.filter { $0.trigger == .realTimeSignal }
        XCTAssertFalse(monitorInputs.isEmpty)
        XCTAssertTrue(monitorInputs.allSatisfy { $0.scope == .incremental })
        XCTAssertEqual(imap.messageStateFetchCount, baselineStateFetches)
        model = nil
    }

    func testAccountInboxSyncReasonMapsManualAndBackgroundToExpectedInputs() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-sync-reason-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()
        let client = RecordingInboxSyncOperationClient()
        let syncer = LocalOperationAccountInboxSyncer(
            client: client,
            notificationScheduler: NoopLocalNotificationScheduler()
        )
        let account = Account(
            id: AccountID("acc_reason_mapping"),
            displayName: "Reason Mapping",
            email: EmailAddress("reason@example.com"),
            imapHost: "imap.example.com",
            smtpHost: "smtp.example.com"
        )

        _ = try await syncer.syncInbox(for: account, reason: .manual)
        _ = try await syncer.syncInbox(for: account, reason: .background)
        let inputs = await client.inputs()

        XCTAssertEqual(
            inputs,
            [
                PlainpostInboxSyncInput(
                    accountID: account.id,
                    trigger: .manual,
                    scope: .recent
                ),
                PlainpostInboxSyncInput(
                    accountID: account.id,
                    trigger: .realTimeSignal,
                    scope: .incremental
                ),
            ]
        )
    }

    @MainActor
    private func waitForProbe(
        _ probe: MonitorProbe,
        condition: (MonitorProbe.Snapshot) -> Bool
    ) async -> MonitorProbe.Snapshot {
        for _ in 0..<200 {
            let snapshot = await probe.snapshot()
            if condition(snapshot) {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the application monitor state.")
        return await probe.snapshot()
    }

    @MainActor
    func testLockedVaultResumesWhenUnlockedElsewhereWithoutPrompting() async throws {
        // A hidden login launch after a reboot meets a locked vault; an
        // unlock from the CLI or another client must resume the runtime.
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: false)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await vault.state() },
            unlockVault: { _ in await vault.recordPrompt() },
            initializeImmediately: false
        )
        model.lockedVaultPollInterval = .milliseconds(10)

        model.start()
        await waitForModel(model) { model.vaultLaunchState == .locked }
        XCTAssertNil(model.runtime)

        await vault.unlockElsewhere()
        await waitForModel(model) { model.vaultLaunchState == .ready && model.runtime != nil }
        let prompts = await vault.prompts
        XCTAssertEqual(prompts, 0, "watching a locked vault never prompts")
        await model.shutdown()
    }

    @MainActor
    func testLockVaultStopsTheRuntimeAndUnlockResumesIt() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: true)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await vault.state() },
            unlockVault: { _ in await vault.recordPrompt() },
            lockVault: { await vault.lock() },
            initializeImmediately: false
        )
        model.lockedVaultPollInterval = .seconds(3_600)

        await model.lockVault()
        let untouched = await vault.locks
        XCTAssertEqual(untouched, 0, "Lock Vault before a start does nothing")

        model.start()
        await waitForModel(model) { model.runtime != nil }

        await model.lockVault()
        XCTAssertNil(model.runtime)
        XCTAssertEqual(model.vaultLaunchState, .locked)
        let locks = await vault.locks
        XCTAssertEqual(locks, 1)

        model.unlockVault()
        await waitForModel(model) { model.vaultLaunchState == .ready && model.runtime != nil }
        let prompts = await vault.prompts
        XCTAssertEqual(prompts, 1)
        await model.shutdown()
    }

    @MainActor
    func testLockVaultWatchPicksUpACLIUnlock() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: true)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await vault.state() },
            lockVault: { await vault.lock() },
            initializeImmediately: false
        )
        model.lockedVaultPollInterval = .milliseconds(10)
        model.start()
        await waitForModel(model) { model.runtime != nil }

        await model.lockVault()
        XCTAssertNil(model.runtime)
        await vault.unlockElsewhere()
        await waitForModel(model) { model.runtime != nil }
        await model.shutdown()
    }

    @MainActor
    func testVaultLockedUnderTheRuntimeIsWatchedAndResumesAfterACLIUnlock() async throws {
        // A CLI lock makes the running runtime fail with vaultLocked; that
        // locked state must be watched like any other.
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: true)
        let monitorRuns = MonitorRunCounter()
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in
                if await monitorRuns.next() == 1 {
                    await vault.lockElsewhere()
                    throw PlainpostServiceClientError.vaultLocked
                }
                try await Task.sleep(for: .seconds(3_600))
            },
            vaultReadiness: { await vault.state() },
            initializeImmediately: false
        )
        model.lockedVaultPollInterval = .milliseconds(10)

        model.start()
        await waitForModel(model) { model.vaultLaunchState == .locked && model.runtime == nil }

        await vault.unlockElsewhere()
        await waitForModel(model) { model.vaultLaunchState == .ready && model.runtime != nil }
        await model.shutdown()
    }

    @MainActor
    func testFailedLockVaultIsReportedAndLeavesTheVaultUsable() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: true)
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await vault.state() },
            initializeImmediately: false
        )
        model.explicitLockAction = { throw PlainpostServiceClientError.serviceUnavailable }
        model.lockedVaultPollInterval = .seconds(3_600)
        model.start()
        await waitForModel(model) { model.runtime != nil }

        await model.lockVault()

        XCTAssertEqual(model.lockVaultError, PlainpostApplicationModel.lockVaultFailureMessage)
        XCTAssertNotEqual(model.vaultLaunchState, .locked)
        await waitForModel(model) { model.vaultLaunchState == .ready && model.runtime != nil }

        model.explicitLockAction = { await vault.lock() }
        await model.lockVault()
        XCTAssertNil(model.lockVaultError)
        XCTAssertEqual(model.vaultLaunchState, .locked)
        await model.shutdown()
    }

    @MainActor
    func testUnavailableServiceRecoversOnItsOwnAfterASlowStart() async throws {
        // A hidden launch while the service is busy migrating: readiness
        // fails, and later passes succeed without anyone opening a window.
        let fixture = try RuntimeFixture(testCase: self)
        let answers = ReadinessSequence([.serviceUnavailable, .serviceUnavailable, .ready])
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in },
            vaultReadiness: { await answers.next() },
            initializeImmediately: false
        )
        model.serviceUnavailableBackoff = [.milliseconds(10)]
        model.start()
        await waitForModel(model) { model.vaultLaunchState == .ready && model.runtime != nil }
        let asked = await answers.asked
        XCTAssertEqual(asked, 3)
        await model.shutdown()
    }

    @MainActor
    func testLockReachedThroughARuntimeFailureClearsAnEarlierLockError() async throws {
        let fixture = try RuntimeFixture(testCase: self)
        let vault = ToggleVault(unlocked: true)
        let monitorRuns = MonitorRunCounter()
        let failNow = FlagBox()
        let model = PlainpostApplicationModel(
            makeRuntime: { fixture.runtime },
            monitor: { _ in
                _ = await monitorRuns.next()
                while await !failNow.value { try await Task.sleep(for: .milliseconds(5)) }
                await vault.lockElsewhere()
                throw PlainpostServiceClientError.vaultLocked
            },
            vaultReadiness: { await vault.state() },
            initializeImmediately: false
        )
        model.lockedVaultPollInterval = .seconds(3_600)
        model.explicitLockAction = { throw PlainpostServiceClientError.serviceUnavailable }
        model.start()
        await waitForModel(model) { model.runtime != nil }
        await model.lockVault()
        XCTAssertNotNil(model.lockVaultError)
        await waitForModel(model) { model.runtime != nil }

        await failNow.set()
        await waitForModel(model) { model.vaultLaunchState == .locked }
        XCTAssertNil(model.lockVaultError, "a locked state never shows a stale lock failure")
        await model.shutdown()
    }

    @MainActor private func waitForLaunchState(
        _ model: PlainpostApplicationModel, expected: PlainpostVaultLaunchState
    ) async {
        for _ in 0..<200 {
            if model.vaultLaunchState == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for launch state \(expected).")
    }

    @MainActor private func waitForModel(
        _ model: PlainpostApplicationModel,
        condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the application model state.")
    }
}

@MainActor
private final class RuntimeFactoryState {
    var shouldFail = true
    var creationCount = 0
}

@MainActor
private final class RuntimeFixture {
    enum Failure: Error {
        case unavailable
    }

    let directoryURL: URL
    let databaseURL: URL
    let keychainService: String
    let runtime: PlainpostAppRuntime

    init(testCase: XCTestCase) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eam-\(UUID().uuidString.prefix(8))", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("Plainpost.sqlite")
        keychainService = "PlainpostApplicationModelTests.\(UUID().uuidString)"
        runtime = try PlainpostAppRuntime(
            configuration: RuntimeKeychainIsolation(
                testCase: testCase,
                databaseURL: databaseURL,
                keychainService: keychainService
            ).configuration,
            notificationScheduler: NoopLocalNotificationScheduler()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private actor MonitorProbe {
    struct Snapshot: Sendable {
        let starts: Int
        let cancellations: Int
        let active: Int
        let maximumActive: Int
        let runtimeIDs: [ObjectIdentifier]
    }

    private var starts = 0
    private var cancellations = 0
    private var active = 0
    private var maximumActive = 0
    private var runtimeIDs: [ObjectIdentifier] = []

    func run(runtimeID: ObjectIdentifier) async {
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        runtimeIDs.append(runtimeID)

        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellations += 1
        } catch {
            XCTFail("Unexpected monitor error: \(error)")
        }
        active -= 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            starts: starts,
            cancellations: cancellations,
            active: active,
            maximumActive: maximumActive,
            runtimeIDs: runtimeIDs
        )
    }
}

private actor ReadinessProbe {
    private let initial: PlainpostVaultLaunchState
    private var unlockResult: PlainpostVaultLaunchState
    private var unlockCalls = 0

    init(initial: PlainpostVaultLaunchState) {
        self.initial = initial
        unlockResult = initial
    }

    func evaluate() -> PlainpostVaultLaunchState { initial }

    func setUnlockResult(_ result: PlainpostVaultLaunchState) { unlockResult = result }

    func unlock(reason: String) -> PlainpostVaultLaunchState {
        _ = reason
        unlockCalls += 1
        return unlockResult
    }

    func unlockCallCount() -> Int { unlockCalls }
}

private actor MutableReadinessProbe {
    struct Snapshot: Sendable {
        let statusCalls: Int
        let unlockCalls: Int
    }

    private var result: PlainpostVaultLaunchState
    private var statusCalls = 0
    private var unlockCalls = 0

    init(result: PlainpostVaultLaunchState) {
        self.result = result
    }

    func evaluate() -> PlainpostVaultLaunchState {
        statusCalls += 1
        return result
    }

    func unlock(reason: String) -> PlainpostVaultLaunchState {
        _ = reason
        unlockCalls += 1
        return result
    }

    func snapshot() -> Snapshot {
        Snapshot(statusCalls: statusCalls, unlockCalls: unlockCalls)
    }
}

private actor RuntimeFailureGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func trigger() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeShutdownBarrier {
    private var didEnter = false
    private var isReleased = false
    private var didComplete = false
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        didEnter = true
        entryContinuations.forEach { $0.resume() }
        entryContinuations.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entryContinuations.append($0) }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func complete() {
        didComplete = true
        completionContinuations.forEach { $0.resume() }
        completionContinuations.removeAll()
    }

    func waitUntilCompleted() async {
        guard !didComplete else { return }
        await withCheckedContinuation { completionContinuations.append($0) }
    }
}

private actor AcceptanceBootstrapProbe {
    private let result: PlainpostVaultLaunchState
    private var calls = 0

    init(result: PlainpostVaultLaunchState) { self.result = result }

    func resolve(_: PlainpostVaultLaunchState) -> PlainpostVaultLaunchState {
        calls += 1
        return result
    }

    func callCount() -> Int {
        calls
    }
}

private actor RecordingPlainpostServiceClient: PlainpostServiceClientProtocol {
    struct Snapshot: Sendable {
        let statusCallCount: Int
        let unlockCallCount: Int
        let semanticOperationCallCount: Int
        var startOverReasons: [String] = []
    }

    private var statusResults: [Result<PlainpostVaultStatus, PlainpostServiceClientError>]
    private var unlockResults: [Result<Void, PlainpostServiceClientError>]
    private var startOverResults: [Result<Void, PlainpostServiceClientError>]
    private var statusCallCount = 0
    private var unlockCallCount = 0
    private var startOverReasons: [String] = []

    init(
        statusResults: [Result<PlainpostVaultStatus, PlainpostServiceClientError>] = [],
        unlockResults: [Result<Void, PlainpostServiceClientError>] = [],
        startOverResults: [Result<Void, PlainpostServiceClientError>] = []
    ) {
        self.statusResults = statusResults
        self.unlockResults = unlockResults
        self.startOverResults = startOverResults
    }

    func startOverAfterVaultKeyLoss(reason: String) throws {
        startOverReasons.append(reason)
        guard !startOverResults.isEmpty else { return }
        _ = try startOverResults.removeFirst().get()
    }

    func status() throws -> PlainpostVaultStatus {
        statusCallCount += 1
        guard !statusResults.isEmpty else {
            return PlainpostVaultStatus(availability: .unlocked, matchingKeyItemCount: 1)
        }
        return try statusResults.removeFirst().get()
    }

    func unlock(reason: String) throws {
        _ = reason
        unlockCallCount += 1
        guard !unlockResults.isEmpty else { return }
        _ = try unlockResults.removeFirst().get()
    }

    func lock() throws {}

    func snapshot() -> Snapshot {
        Snapshot(
            statusCallCount: statusCallCount, unlockCallCount: unlockCallCount,
            semanticOperationCallCount: 0, startOverReasons: startOverReasons)
    }
}

private actor StartOverProbe {
    private var results: [PlainpostVaultLaunchState]
    private(set) var reasons: [String] = []

    init(results: [PlainpostVaultLaunchState]) { self.results = results }

    func startOver(reason: String) -> PlainpostVaultLaunchState {
        reasons.append(reason)
        return results.isEmpty ? .keyMissing : results.removeFirst()
    }
}

private actor RecordingInboxSyncOperationClient: PlainpostOperationClientProtocol {
    private var recordedInputs: [PlainpostInboxSyncInput] = []

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        recordedInputs.append(input)
        return PlainpostInboxSyncResult(accountID: input.accountID, syncedMessageCount: 0, jobID: "job_reason")
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        _ = input
        throw PlainpostError.notFound("Unused operation.")
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        _ = requestID
        _ = approvedBy
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        _ = requestID
        _ = deniedBy
    }

    func inputs() -> [PlainpostInboxSyncInput] {
        recordedInputs
    }
}

private actor ManagedPurgeSequenceProbe {
    private var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private actor ToggleVault {
    private var unlocked: Bool
    private(set) var prompts = 0
    private(set) var locks = 0

    init(unlocked: Bool) { self.unlocked = unlocked }

    func state() -> PlainpostVaultLaunchState { unlocked ? .ready : .locked }
    func unlockElsewhere() { unlocked = true }
    func lockElsewhere() { unlocked = false }
    func lock() { locks += 1; unlocked = false }
    func recordPrompt() -> PlainpostVaultLaunchState {
        prompts += 1
        unlocked = true
        return .ready
    }
}

private actor MonitorRunCounter {
    private var runs = 0
    func next() -> Int {
        runs += 1
        return runs
    }
}

private actor ReadinessSequence {
    private var answers: [PlainpostVaultLaunchState]
    private(set) var asked = 0
    init(_ answers: [PlainpostVaultLaunchState]) { self.answers = answers }
    func next() -> PlainpostVaultLaunchState {
        asked += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

private actor FlagBox {
    private(set) var value = false
    func set() { value = true }
}
