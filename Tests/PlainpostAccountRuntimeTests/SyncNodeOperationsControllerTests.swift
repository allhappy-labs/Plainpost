import Foundation
import XCTest
@testable import PlainpostAccountRuntime

final class SyncNodeOperationsControllerTests: XCTestCase {
    func testBackupRequiresLocalAuthenticationBeforeCallingAuthenticatedNodeAPI() async throws {
        let authenticator = RecordingLocalAuthenticator()
        let client = RecordingSyncNodeOperationsClient()
        let controller = SyncNodeOperationsController(client: client, authenticator: authenticator)

        _ = try await controller.backup()

        let reasons = await authenticator.reasons()
        let calls = await client.calls()
        XCTAssertEqual(reasons, ["Back up this Sync Node"])
        XCTAssertEqual(calls, [.backup])
    }

    func testEraseRequiresAuthenticationAndTheExactTypedConfirmation() async throws {
        let authenticator = RecordingLocalAuthenticator()
        let client = RecordingSyncNodeOperationsClient()
        let controller = SyncNodeOperationsController(client: client, authenticator: authenticator)

        do {
            _ = try await controller.erase(confirmation: "erase sync node")
            XCTFail("expected exact confirmation rejection")
        } catch let error as SyncNodeOperationsController.Error {
            XCTAssertEqual(error, .confirmationMismatch)
        }
        let rejectedReasons = await authenticator.reasons()
        let rejectedCalls = await client.calls()
        XCTAssertEqual(rejectedReasons, [])
        XCTAssertEqual(rejectedCalls, [])

        _ = try await controller.erase(confirmation: SyncNodeOperationsController.eraseConfirmation)
        let acceptedReasons = await authenticator.reasons()
        let acceptedCalls = await client.calls()
        XCTAssertEqual(acceptedReasons, ["Erase this Sync Node"])
        XCTAssertEqual(acceptedCalls, [.erase])
    }

    func testUpgradeIsReadyOnlyAfterVerifiedBackup() async throws {
        let client = RecordingSyncNodeOperationsClient()
        let controller = SyncNodeOperationsController(client: client, authenticator: RecordingLocalAuthenticator())

        await client.setStatus(makeStatus(backup: "pending", updateStatus: "blocked"))
        let pending = try await controller.status()
        XCTAssertFalse(pending.upgradeReady)
        await client.setStatus(makeStatus(backup: "verified", updateStatus: "ready"))
        let verified = try await controller.status()
        XCTAssertTrue(verified.upgradeReady)
    }

    func testRecoveryRequiredIsNotASuccessfulTerminalOperation() async throws {
        let client = RecordingSyncNodeOperationsClient()
        let controller = SyncNodeOperationsController(client: client, authenticator: RecordingLocalAuthenticator())

        await client.setStatus(makeStatus(state: "recovery_required", backup: "uncertain", updateStatus: "blocked"))
        let status = try await controller.status()

        XCTAssertFalse(status.backupSucceeded)
        XCTAssertFalse(status.eraseSucceeded)
        XCTAssertEqual(status.operationState, .recoveryRequired)
    }

    func testOfflineRestoreUsesLocalCoordinatorAndRejectsNetworkClient() throws {
        let coordinator = RecordingOfflineRestoreCoordinator()
        let client = RecordingSyncNodeOperationsClient()
        let controller = SyncNodeOperationsController(client: client, authenticator: RecordingLocalAuthenticator(), restoreCoordinator: coordinator)

        XCTAssertThrowsError(try controller.restoreOffline(backupPath: "/private/backup/container", digest: "sha256:abc", confirmation: "sha256:wrong"))
    }

    func testOfflineRestoreCLIRequiresExactDigestAndUsesOfflineCoordinator() throws {
        let coordinator = RecordingOfflineRestoreCoordinator()
        let input = LockedInput(["sha256:abc"])
        let cli = SyncNodeOfflineRestoreCLI(
            coordinator: coordinator,
            readLine: { input.next() },
            write: { _ in }
        )

        try cli.run(backupPath: "/private/backup/container", digest: "sha256:abc")

        XCTAssertEqual(coordinator.restoreArguments(), ["/private/backup/container|sha256:abc"])
    }

    func testPostSendAndMalformedOperationResponsesAreUncertain() async throws {
        for failure in [OperationFailure.postSend, OperationFailure.malformed] {
            let controller = SyncNodeOperationsController(client: FailingOperationsClient(error: failure), authenticator: RecordingLocalAuthenticator())
            do {
                _ = try await controller.backup()
                XCTFail("expected uncertain operation")
            } catch let error as SyncNodeOperationsController.Error {
                XCTAssertEqual(error, .uncertain)
            }
        }
    }

    func testCancellationOfOperationIsUncertain() async throws {
        let controller = SyncNodeOperationsController(client: FailingOperationsClient(error: CancellationError()), authenticator: RecordingLocalAuthenticator())
        do {
            _ = try await controller.erase(confirmation: SyncNodeOperationsController.eraseConfirmation)
            XCTFail("expected uncertain operation")
        } catch let error as SyncNodeOperationsController.Error {
            XCTAssertEqual(error, .uncertain)
        }
    }

    private func makeStatus(backup: String, updateStatus: String) -> SyncNodeStatus {
        makeStatus(state: "ready", backup: backup, updateStatus: updateStatus)
    }

    private func makeStatus(state: String, backup: String, updateStatus: String) -> SyncNodeStatus {
        SyncNodeStatus(state: state, version: "node", reachability: "reachable", syncLag: "0s", storage: "managed", providerIdentity: nil, assignments: [], backup: backup, endpoint: "session", updateStatus: updateStatus)
    }
}

private final class LockedInput: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()

    init(_ values: [String]) { self.values = values }

    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

private actor RecordingLocalAuthenticator: LocalApprovalAuthenticating {
    private var values: [String] = []
    func authenticate(reason: String) async throws { values.append(reason) }
    func reasons() -> [String] { values }
}

private actor RecordingSyncNodeOperationsClient: SyncNodeOperationsClient {
    enum Call: Equatable { case backup, erase, status }
    private var recorded: [Call] = []
    private var current = SyncNodeStatus(version: "node", reachability: "reachable", syncLag: "0s", storage: "managed", providerIdentity: nil, assignments: [], backup: "verified", endpoint: "session", updateStatus: "ready")
    func status() async throws -> SyncNodeStatus { recorded.append(.status); return current }
    func backup() async throws -> SyncNodeStatus { recorded.append(.backup); return current }
    func erase() async throws -> SyncNodeStatus { recorded.append(.erase); return current }
    func calls() -> [Call] { recorded }
    func setStatus(_ value: SyncNodeStatus) { current = value }
}

private enum OperationFailure: Swift.Error {
    case postSend
    case malformed
}

private struct FailingOperationsClient: SyncNodeOperationsClient, @unchecked Sendable {
    let error: Swift.Error
    func status() async throws -> SyncNodeStatus { throw error }
    func backup() async throws -> SyncNodeStatus { throw error }
    func erase() async throws -> SyncNodeStatus { throw error }
}

private final class RecordingOfflineRestoreCoordinator: SyncNodeOfflineRestoreCoordinating, @unchecked Sendable {
    let isOffline = true
    private var calls: [String] = []
    private let lock = NSLock()

    func restoreOffline(backupPath: String, expectedDigest: String) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append("\(backupPath)|\(expectedDigest)")
    }

    func restoreArguments() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
