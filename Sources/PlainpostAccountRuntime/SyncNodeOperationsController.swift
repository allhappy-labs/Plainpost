import Foundation
import PlainpostNodeTransport

/// The small authenticated operation surface used by native settings. The
/// server derives the account from the enrolled session and never accepts a
/// destination, credential, or provider identifier from this controller.
public protocol SyncNodeOperationsClient: Sendable {
    func status() async throws -> SyncNodeStatus
    func backup() async throws -> SyncNodeStatus
    func erase() async throws -> SyncNodeStatus
}

/// Restore is deliberately a local process boundary. No Node API client is
/// passed to this coordinator, so an offline restore cannot accidentally be
/// exposed as a network operation.
public protocol SyncNodeOfflineRestoreCoordinating: Sendable {
    var isOffline: Bool { get }
    func restoreOffline(backupPath: String, expectedDigest: String) throws
}

public struct SyncNodeOperationStatus: Equatable, Sendable {
    public let state: String
	/// The closed operation result state when this status came from an
	/// operation response. Diagnostics/status responses have no operation state.
    public let operationState: NodeSyncOperationState?
    public let operationBackup: NodeSyncBackupState?
    public let operationUpgradeStatus: NodeSyncUpgradeStatus?
    public let backup: String
    public let updateStatus: String
    public let completedAt: String?
    public var upgradeReady: Bool {
        Self.isUpgradeReady(backup: backup, updateStatus: updateStatus)
    }
    public static func isUpgradeReady(backup: String, updateStatus: String) -> Bool {
        NodeSyncBackupState(rawValue: backup) == .verified && NodeSyncUpgradeStatus(rawValue: updateStatus) == .ready
    }
    public var backupSucceeded: Bool {
        operationState == .verified && operationBackup == .verified && operationUpgradeStatus == .ready
    }
    public var eraseSucceeded: Bool {
        operationState == .erased && operationBackup == .unchanged && operationUpgradeStatus == .blocked
    }

	init(node: SyncNodeStatus, completedAt: String? = nil) {
		state = node.state; operationState = NodeSyncOperationState(rawValue: node.state); operationBackup = NodeSyncBackupState(rawValue: node.backup); operationUpgradeStatus = NodeSyncUpgradeStatus(rawValue: node.updateStatus); backup = node.backup; updateStatus = node.updateStatus; self.completedAt = completedAt ?? node.completedAt
	}

	init(operation result: NodeSyncOperationResult) {
		state = result.state.rawValue; operationState = result.state; operationBackup = result.backup; operationUpgradeStatus = result.upgradeStatus; backup = result.backup.rawValue; updateStatus = result.upgradeStatus.rawValue; completedAt = result.completedAt
	}
}

public final class SyncNodeOperationsController: Sendable {
    public static let eraseConfirmation = "ERASE SYNC NODE"

    public enum Error: Swift.Error, Equatable, Sendable {
        case confirmationMismatch
        case authenticationFailed
        case restoreDigestMismatch
        case restoreUnavailable
        case operationUnavailable
        case failed
        case uncertain
    }

    private let client: any SyncNodeOperationsClient
    private let authenticator: any LocalApprovalAuthenticating
    private let restoreCoordinator: (any SyncNodeOfflineRestoreCoordinating)?

    public init(
        client: any SyncNodeOperationsClient,
        authenticator: any LocalApprovalAuthenticating = LocalApprovalAuthenticatorFactory.defaultAuthenticator(),
        restoreCoordinator: (any SyncNodeOfflineRestoreCoordinating)? = nil
    ) {
        self.client = client
        self.authenticator = authenticator
        self.restoreCoordinator = restoreCoordinator
    }

    public func status() async throws -> SyncNodeOperationStatus {
        do { return SyncNodeOperationStatus(node: try await client.status()) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NodeSyncClientError where error == .transport { throw Error.uncertain }
        catch { throw Error.operationUnavailable }
    }

    public func backup() async throws -> SyncNodeOperationStatus {
        try await authenticate(reason: "Back up this Sync Node")
        do {
            let status = try await client.backup()
            // Project the legacy DTO into its typed operation vocabulary
            // before applying terminal-state policy.
            let projected = SyncNodeOperationStatus(node: status)
            if projected.operationState == .uncertain || projected.operationState == .recoveryRequired || projected.operationState == .operatorActionRequired { throw Error.uncertain }
            return projected
        }
        catch { throw Self.mapOperationError(error) }
    }

    public func erase(confirmation: String) async throws -> SyncNodeOperationStatus {
        guard confirmation == Self.eraseConfirmation else { throw Error.confirmationMismatch }
        try await authenticate(reason: "Erase this Sync Node")
        do { return SyncNodeOperationStatus(node: try await client.erase()) }
        catch { throw Self.mapOperationError(error) }
    }

    public func restoreOffline(backupPath: String, digest: String, confirmation: String) throws {
        guard digest == confirmation else { throw Error.restoreDigestMismatch }
        guard !backupPath.isEmpty, let restoreCoordinator, restoreCoordinator.isOffline else { throw Error.restoreUnavailable }
        try restoreCoordinator.restoreOffline(backupPath: backupPath, expectedDigest: digest)
    }

    private func authenticate(reason: String) async throws {
        do { try await authenticator.authenticate(reason: reason) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Error.authenticationFailed }
    }

    private static func mapOperationError(_ error: Swift.Error) -> Error {
        if error is CancellationError { return .uncertain }
        guard let clientError = error as? NodeSyncClientError else {
            if let operationError = error as? Error { return operationError }
            return .uncertain
        }
        switch clientError {
        case .problem(.invalidRequest), .problem(.unauthorized):
            return .failed
        case .cancelled, .conflict, .invalidResponse, .notFound, .problem(.conflict), .problem(.staleCursor), .problem(.unavailable), .transport, .transportAfterDispatch, .cancelledAfterDispatch:
            // A response may have arrived after the Node performed the
            // operation, and malformed/5xx responses are equally ambiguous.
            return .uncertain
        }
    }
}

/// Local operator assembly for restore. It has no Node client or network
/// sender, and therefore cannot publish restore as a remote API operation.
public struct SyncNodeOfflineRestoreCLI: Sendable {
    private let coordinator: any SyncNodeOfflineRestoreCoordinating
    private let readLine: @Sendable () -> String?
    private let write: @Sendable (String) -> Void

    public init(
        coordinator: any SyncNodeOfflineRestoreCoordinating,
        readLine: @escaping @Sendable () -> String?,
        write: @escaping @Sendable (String) -> Void
    ) {
        self.coordinator = coordinator; self.readLine = readLine; self.write = write
    }

    public func run(backupPath: String, digest: String) throws {
        guard coordinator.isOffline else { throw SyncNodeOperationsController.Error.restoreUnavailable }
        write("Type the exact backup digest to restore:")
        guard readLine() == digest else { throw SyncNodeOperationsController.Error.restoreDigestMismatch }
        try coordinator.restoreOffline(backupPath: backupPath, expectedDigest: digest)
    }
}

extension SyncNodeOperationsController {
    /// Adapts the transport result to the account-runtime status vocabulary;
    /// operation response metadata is never promoted to a settings secret.
    public convenience init(
        client: NodeSyncClient,
        authenticator: any LocalApprovalAuthenticating = LocalApprovalAuthenticatorFactory.defaultAuthenticator(),
        restoreCoordinator: (any SyncNodeOfflineRestoreCoordinating)? = nil
    ) {
        self.init(client: NodeSyncOperationsTransportAdapter(client: client), authenticator: authenticator, restoreCoordinator: restoreCoordinator)
    }
}

private struct NodeSyncOperationsTransportAdapter: SyncNodeOperationsClient {
    let client: NodeSyncClient

    func status() async throws -> SyncNodeStatus { try await client.status().syncNodeStatus() }

    func backup() async throws -> SyncNodeStatus {
        let result = try await client.backup()
        return Self.operationStatus(result)
    }

    func erase() async throws -> SyncNodeStatus {
        let result = try await client.erase(confirmation: SyncNodeOperationsController.eraseConfirmation)
        return Self.operationStatus(result)
    }

	private static func operationStatus(_ result: NodeSyncOperationResult) -> SyncNodeStatus {
        // SyncNodeStatus predates typed operation results and remains a
        // diagnostics DTO. This is the sole typed-to-string projection.
        SyncNodeStatus(
            revision: "0", state: result.state.rawValue, version: "unknown",
            reachability: "reachable", syncLag: "unknown", storage: "managed",
            providerIdentity: nil, assignments: [], backup: result.backup.rawValue,
            endpoint: "session", updateStatus: result.upgradeStatus.rawValue,
            completedAt: result.completedAt
        )
    }
}
