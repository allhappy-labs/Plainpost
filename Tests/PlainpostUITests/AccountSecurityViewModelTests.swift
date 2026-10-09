import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import XCTest
@testable import PlainpostUI

@MainActor
final class AccountSecurityViewModelTests: XCTestCase {
    func testRefreshPublishesLoadingThenLoadedEmptySnapshot() async {
        let gate = AccountSecuritySnapshotGate()
        let model = makeModel(loadSnapshot: { try await gate.load() })

        model.refresh()
        XCTAssertEqual(model.loadState, .loading)

        await gate.succeed(.init(devices: [], events: []))
        let didLoad = await eventually { model.loadState == .loaded }
        XCTAssertTrue(didLoad)
        XCTAssertEqual(model.devices, [])
        XCTAssertEqual(model.events, [])
    }

    func testFailedRefreshPublishesRetryableLoadFailureWithoutOperationError() async {
        let loader = FailOnceAccountSecurityLoader()
        let model = makeModel(loadSnapshot: { try await loader.load() })

        model.refresh()
        let didFail = await eventually {
            model.loadState == .failed(message: "Account security couldn’t be loaded.")
        }
        XCTAssertTrue(didFail)
        XCTAssertNil(model.operationErrorMessage)

        model.refresh()
        let didLoad = await eventually { model.loadState == .loaded }
        let attemptCount = await loader.attemptCount()
        XCTAssertTrue(didLoad)
        XCTAssertEqual(attemptCount, 2)
    }

    func testCancelInvalidatesNonCooperativeSnapshotCompletion() async throws {
        let gate = AccountSecuritySnapshotGate()
        let model = makeModel(loadSnapshot: { try await gate.load() })
        let device = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos,
            isCurrentDevice: true
        )

        model.refresh()
        model.cancel()
        await gate.succeed(.init(devices: [device], events: []))
        for _ in 0 ..< 20 { await Task.yield() }

        XCTAssertEqual(model.loadState, .idle)
        XCTAssertEqual(model.devices, [])
        XCTAssertEqual(model.events, [])
    }

    func testActionFailurePreservesLoadedSnapshotAndUsesOperationError() async throws {
        let device = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos,
            isCurrentDevice: true
        )
        let snapshot = AccountSecurityViewModel.Snapshot(devices: [device], events: [])
        let model = makeModel(
            performAction: { _, _, _ in throw AccountRuntimeError.untrustedResponse },
            initialSnapshot: snapshot,
            initialLoadState: .loaded
        )
        let request = try model.begin(.deleteAccount)

        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)

        let didPublishError = await eventually {
            model.operationErrorMessage == "The security change was not completed."
        }
        XCTAssertTrue(didPublishError)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.devices, [device])
    }

    func testRecoveryFailurePublishesPrivacySafeFailureStage() async throws {
        let model = makeModel(
            performAction: { _, _, _ in throw AccountRecoveryFailure.authorizationVerification }
        )
        let request = try model.begin(.recoverAccount)

        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)

        let didPublishError = await eventually {
            model.operationErrorMessage == "Recovery authorization could not be verified."
        }
        XCTAssertTrue(didPublishError)
        XCTAssertFalse(model.recoveryDidComplete)
    }

    /// Recovery reuses the Apple sign-in the person just completed to sign in, so it never
    /// shows a second Apple sheet; the same token and nonce reach the recovery request.
    func testRecoveryWithTheRecentAppleSignInSkipsASecondAppleSheet() async throws {
        let nonce = Data(repeating: 0x42, count: 32)
        var received: (String, Data)?
        let model = makeModel(performAction: { action, token, appleNonce in
            XCTAssertEqual(action, .recoverAccount)
            received = (token, appleNonce)
            return nil
        })
        let signIn = RecentAppleSignIn(identityToken: "first.sign.in", rawNonce: nonce, obtainedAt: Date())

        model.recover(with: signIn)

        let didComplete = await eventually { model.recoveryDidComplete }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(received?.0, "first.sign.in")
        XCTAssertEqual(received?.1, nonce)
    }

    func testARecentAppleSignInIsOfferedOnlyWhileCentralStillAcceptsIt() {
        let obtainedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let signIn = RecentAppleSignIn(identityToken: "t", rawNonce: Data(repeating: 1, count: 32), obtainedAt: obtainedAt)
        XCTAssertTrue(signIn.isUsable(at: obtainedAt.addingTimeInterval(8 * 60)))
        XCTAssertFalse(signIn.isUsable(at: obtainedAt.addingTimeInterval(9 * 60)))
        XCTAssertFalse(signIn.isUsable(at: obtainedAt.addingTimeInterval(-1)))
    }

    func testSuccessfulRecoveryPublishesCompletionForSheetDismissal() async throws {
        var stateChangeCount = 0
        let model = makeModel(
            performAction: { action, _, _ in
                XCTAssertEqual(action, .recoverAccount)
                return nil
            },
            stateChanged: { stateChangeCount += 1 }
        )
        let request = try model.begin(.recoverAccount)

        model.submitAppleIdentityToken(Data("identity.token".utf8), for: request.id)

        let didComplete = await eventually { model.recoveryDidComplete }
        XCTAssertTrue(didComplete)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.operationErrorMessage)
        XCTAssertEqual(stateChangeCount, 1)
    }

    func testRenameFailurePreservesLoadedSnapshotAndUsesOperationError() async throws {
        let device = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            platform: .macos,
            isCurrentDevice: true
        )
        let snapshot = AccountSecurityViewModel.Snapshot(devices: [device], events: [])
        let model = makeModel(
            saveLabel: { _, _ in throw AccountRuntimeError.untrustedResponse },
            initialSnapshot: snapshot,
            initialLoadState: .loaded
        )

        model.renameDevice(device.id, label: "Office Mac")

        let didPublishError = await eventually {
            model.operationErrorMessage == "The local device label was not saved."
        }
        XCTAssertTrue(didPublishError)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.devices, [device])
    }

    // The shared Apple sheet's handle: a stale or cancelled attempt id completes nothing,
    // and its Cancel ends only its own attempt.
    func testAStaleAuthorizationNeitherCompletesNorCancelsTheCurrentOne() throws {
        let model = makeModel(initialLoadState: .loaded)
        let first = try XCTUnwrap(model.authorization(for: .deleteAccount, deviceID: nil))
        let second = try XCTUnwrap(model.authorization(for: .deleteAccount, deviceID: nil))
        XCTAssertTrue(model.hasPendingAppleAuthorization)

        first.complete(.failure(AccountRuntimeError.cancelled), nil)
        first.cancel()
        XCTAssertTrue(model.hasPendingAppleAuthorization, "the stale sheet left the current attempt alone")
        XCTAssertNil(model.operationErrorMessage)

        second.cancel()
        XCTAssertFalse(model.hasPendingAppleAuthorization)
        second.complete(.failure(AccountRuntimeError.cancelled), nil)
        XCTAssertNil(model.operationErrorMessage, "a cancelled attempt's result is ignored")
    }

    func testCancellingAFinishedAuthorizationLeavesARenameRunning() async throws {
        let device = AccountLifecycleDeviceSummary(
            id: try AccountDeviceID("11111111-2222-4333-8444-555555555555"),
            platform: .ios, isCurrentDevice: false, status: "active"
        )
        let loads = AccountSecurityLoadCounter()
        let model = makeModel(
            loadSnapshot: { await loads.load(.init(devices: [device], events: [])) },
            initialSnapshot: .init(devices: [device], events: []),
            initialLoadState: .loaded
        )
        let authorization = try XCTUnwrap(model.authorization(for: .revoke, deviceID: device.id))
        authorization.complete(.failure(AccountRuntimeError.cancelled), nil)
        XCTAssertFalse(model.hasPendingAppleAuthorization)

        model.renameDevice(device.id, label: "Phone")
        authorization.cancel()
        let refreshed = await eventually { await loads.count() == 1 && model.loadState == .loaded }
        XCTAssertTrue(refreshed, "the rename saved and refreshed the list")
    }

    private func makeModel(
        loadSnapshot: @escaping AccountSecurityViewModel.SnapshotLoader = {
            .init(devices: [], events: [])
        },
        performAction: @escaping AccountSecurityViewModel.ActionPerformer = { _, _, _ in nil },
        saveLabel: @escaping AccountSecurityViewModel.LabelSaver = { _, _ in },
        stateChanged: @escaping @MainActor @Sendable () -> Void = {},
        initialSnapshot: AccountSecurityViewModel.Snapshot = .init(devices: [], events: []),
        initialLoadState: AccountSecurityViewModel.LoadState = .idle
    ) -> AccountSecurityViewModel {
        AccountSecurityViewModel(
            loadSnapshot: loadSnapshot,
            performAction: performAction,
            saveLabel: saveLabel,
            stateChanged: stateChanged,
            nonceGenerator: { Data(repeating: 0xA5, count: 32) },
            initialSnapshot: initialSnapshot,
            initialLoadState: initialLoadState
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor AccountSecuritySnapshotGate {
    private var continuation: CheckedContinuation<AccountSecurityViewModel.Snapshot, any Error>?
    private var bufferedSnapshot: AccountSecurityViewModel.Snapshot?

    func load() async throws -> AccountSecurityViewModel.Snapshot {
        if let bufferedSnapshot {
            self.bufferedSnapshot = nil
            return bufferedSnapshot
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed(_ snapshot: AccountSecurityViewModel.Snapshot) {
        guard let continuation else {
            bufferedSnapshot = snapshot
            return
        }
        self.continuation = nil
        continuation.resume(returning: snapshot)
    }
}

private actor FailOnceAccountSecurityLoader {
    private(set) var attempts = 0

    func load() throws -> AccountSecurityViewModel.Snapshot {
        attempts += 1
        if attempts == 1 { throw AccountRuntimeError.untrustedResponse }
        return .init(devices: [], events: [])
    }

    func attemptCount() -> Int { attempts }
}

private actor AccountSecurityLoadCounter {
    private var loads = 0
    func load(_ snapshot: AccountSecurityViewModel.Snapshot) -> AccountSecurityViewModel.Snapshot {
        loads += 1
        return snapshot
    }
    func count() -> Int { loads }
}
