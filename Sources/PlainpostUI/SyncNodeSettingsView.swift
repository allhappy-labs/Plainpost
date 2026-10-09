import SwiftUI
import PlainpostAccountRuntime

public struct SyncNodeSettingsSnapshot: Equatable, Sendable {
    public let version: String
    public let reachability: String
    public let syncLag: String
    public let storage: String
    public let provider: String
    public let mailboxAssignments: [String]
    public let backup: String
    public let endpoint: String
    public let updateStatus: String

    public init(version: String, reachability: String, syncLag: String, storage: String, provider: String, mailboxAssignments: [String], backup: String, endpoint: String, updateStatus: String) {
        self.version = version
        self.reachability = reachability
        self.syncLag = syncLag
        self.storage = storage
        self.provider = provider
        self.mailboxAssignments = mailboxAssignments
        self.backup = backup
        self.endpoint = endpoint
        self.updateStatus = updateStatus
    }
}

public enum SyncNodeOperationPhase: Equatable, Sendable {
    case idle
    case inFlight
    case succeeded
    case failed
    case uncertain
}

/// Which Sync Node operation the page last started, so a failure can name it.
public enum SyncNodeOperationKind: Equatable, Sendable {
    case backup
    case erase
}

public enum SyncNodeSettingsOperationError: Swift.Error, Equatable, Sendable {
    case operationInFlight
}

@MainActor
public final class SyncNodeSettingsViewModel: ObservableObject {
    @Published public private(set) var snapshot: SyncNodeSettingsSnapshot
    @Published public private(set) var operationPhase: SyncNodeOperationPhase = .idle
    @Published public private(set) var completedAt: String?
    @Published public private(set) var operatorActionRequired = false
    /// The operation `operationPhase` describes; set when it starts.
    @Published public private(set) var lastOperation: SyncNodeOperationKind?
    /// When this session last saw a verified backup finish. Erase and unverified backups
    /// never set it.
    @Published public private(set) var lastVerifiedBackupAt: String?
    /// False until a status has been read; a placeholder snapshot is never shown as health.
    @Published public private(set) var hasStatus: Bool
    private let refreshAction: (@Sendable () async -> SyncNodeSettingsSnapshot)?
    private let connectProviderAction: (() -> Void)?
    private let operationsController: SyncNodeOperationsController?

    public init(
        snapshot: SyncNodeSettingsSnapshot = .empty,
        refresh: (@Sendable () async -> SyncNodeSettingsSnapshot)? = nil,
        connectProvider: (() -> Void)? = nil,
        operationsController: SyncNodeOperationsController? = nil
    ) {
        self.snapshot = snapshot
        hasStatus = snapshot != .empty
        refreshAction = refresh
        connectProviderAction = connectProvider
        self.operationsController = operationsController
    }

    /// Only the deliberately secret-free operational projection is exposed to
    /// diagnostics and accessibility. OAuth tokens, refresh credentials,
    /// client secrets, and one-time codes have no representation here.
    public var secretFreeDescription: String {
        [
            snapshot.version,
            snapshot.reachability,
            snapshot.syncLag,
            snapshot.storage,
            snapshot.provider,
            snapshot.mailboxAssignments.joined(separator: ", "),
            snapshot.backup,
            snapshot.endpoint,
            snapshot.updateStatus,
        ].joined(separator: " · ")
    }

    public func update(_ snapshot: SyncNodeSettingsSnapshot) {
        self.snapshot = snapshot
        hasStatus = true
    }

    public var canConnectProvider: Bool { connectProviderAction != nil }
    public var canOperate: Bool { operationsController != nil }

    public func connectProvider() {
        connectProviderAction?()
    }

    public func refresh() async {
        guard let refreshAction else { return }
        update(await refreshAction())
    }

    public var upgradeReady: Bool {
        SyncNodeOperationStatus.isUpgradeReady(backup: snapshot.backup, updateStatus: snapshot.updateStatus)
    }

    public var eraseConfirmation: String { SyncNodeOperationsController.eraseConfirmation }

    public func backup() async throws {
        guard let operationsController else { return }
        guard operationPhase != .inFlight else { throw SyncNodeSettingsOperationError.operationInFlight }
        operationPhase = .inFlight
        lastOperation = .backup
        do {
            let status = try await operationsController.backup()
            snapshot = snapshot.applying(backup: status.backup, updateStatus: status.updateStatus)
            completedAt = status.completedAt
            let verified = status.backupSucceeded
            if verified, let completedAt = status.completedAt { lastVerifiedBackupAt = completedAt }
            operatorActionRequired = !verified
            // Every non-terminal response remains visibly actionable. In
            // particular recovery_required, operator_action_required, and
            // uncertain must never render as a successful operation.
            operationPhase = verified ? .succeeded : .uncertain
        } catch {
            operationPhase = (error as? SyncNodeOperationsController.Error).map { $0 == .uncertain } == true ? .uncertain : .failed
            throw error
        }
    }

    public func erase(confirmation: String) async throws {
        guard let operationsController else { return }
        guard operationPhase != .inFlight else { throw SyncNodeSettingsOperationError.operationInFlight }
        operationPhase = .inFlight
        lastOperation = .erase
        do {
            let status = try await operationsController.erase(confirmation: confirmation)
            snapshot = snapshot.applying(backup: status.backup, updateStatus: status.updateStatus)
            completedAt = status.completedAt
            let erased = status.eraseSucceeded
            if erased { lastVerifiedBackupAt = nil }
            operatorActionRequired = !erased
            operationPhase = erased ? .succeeded : .uncertain
        } catch {
            operationPhase = (error as? SyncNodeOperationsController.Error).map { $0 == .uncertain } == true ? .uncertain : .failed
            throw error
        }
    }

    @MainActor
    public func runBackup() async {
        guard operationPhase != .inFlight else { return }
        do { try await backup() }
        catch let error as SyncNodeOperationsController.Error where error == .uncertain { operationPhase = .uncertain }
        catch { operationPhase = .failed }
    }

    @MainActor
    public func runErase(confirmation: String) async {
        guard operationPhase != .inFlight else { return }
        do { try await erase(confirmation: confirmation) }
        catch let error as SyncNodeOperationsController.Error where error == .uncertain { operationPhase = .uncertain }
        catch { operationPhase = .failed }
    }

}

extension SyncNodeSettingsSnapshot {
    public static let empty = SyncNodeSettingsSnapshot(
        version: "Unknown", reachability: "Unavailable", syncLag: "Unknown",
        storage: "Unknown", provider: "Unknown", mailboxAssignments: [],
        backup: "Unknown", endpoint: "Unknown", updateStatus: "Unknown"
    )

    fileprivate func applying(backup: String, updateStatus: String) -> SyncNodeSettingsSnapshot {
        SyncNodeSettingsSnapshot(version: version, reachability: reachability, syncLag: syncLag, storage: storage, provider: provider, mailboxAssignments: mailboxAssignments, backup: backup, endpoint: endpoint, updateStatus: updateStatus)
    }
}

/// The Node's status on its own, for hosts without an account session.
public struct SyncNodeSettingsView: View {
    @ObservedObject private var model: SyncNodeSettingsViewModel

    public init(model: SyncNodeSettingsViewModel) { self.model = model }

    public var body: some View {
        Form { SyncNodeStatusOnlyContent(nodeSettings: model) }
            .formStyle(.grouped)
    }
}
