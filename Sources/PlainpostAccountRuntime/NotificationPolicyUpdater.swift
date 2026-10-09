import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

/// The only runtime seam UI/account state needs for notification policy.
/// Account identity and the authenticated Node session remain owned by the
/// injected remote; this type never accepts provider or message identifiers.
public protocol NotificationPolicyRemote: Sendable {
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy
    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy
}

public enum NotificationPolicyRemoteError: Error, Equatable, Sendable {
    case unauthorized
    case conflict
    case unavailable
    case invalidResponse
}

/// Central Direct policy state. This is intentionally separate from the
/// positive-version Node DTOs: an absent Rich default is version zero, while
/// mailbox rows retain their own scope high-water mark.
public struct DirectNotificationPolicyState: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID?
    public let mode: NodeSyncNotificationPolicyMode
    public let version: String
    public let scopeVersion: String
    public let override: Bool

    public init(logicalMailboxID: LogicalMailboxID?, mode: NodeSyncNotificationPolicyMode, version: String, scopeVersion: String, override: Bool) throws {
        guard !version.isEmpty, (version == "0" || !version.hasPrefix("0")),
              !scopeVersion.isEmpty, (scopeVersion == "0" || !scopeVersion.hasPrefix("0")),
              let versionValue = UInt64(version), versionValue <= 65_535,
              let scopeValue = UInt64(scopeVersion), scopeValue <= 65_535 else { throw NotificationPolicyRemoteError.invalidResponse }
        if logicalMailboxID == nil {
            guard !override, scopeValue == 0, versionValue > 0 || mode == .richPreview else { throw NotificationPolicyRemoteError.invalidResponse }
        } else if override {
            guard versionValue > 0, scopeValue > 0, versionValue == scopeValue else { throw NotificationPolicyRemoteError.invalidResponse }
        } else {
            // Inherited mailbox state carries the effective default version,
            // which may be positive or the absent Rich v0 sentinel, while
            // scopeVersion is independently zero (absent row) or positive
            // (retained tombstone high-water).
            guard versionValue > 0 || mode == .richPreview else { throw NotificationPolicyRemoteError.invalidResponse }
        }
        self.logicalMailboxID = logicalMailboxID; self.mode = mode; self.version = version; self.scopeVersion = scopeVersion; self.override = override
    }
}

public struct DirectNotificationPolicyUpdateRequest: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID?
    public let mode: NodeSyncNotificationPolicyMode
    public let clear: Bool
    public let expectedVersion: String
    public let idempotencyKey: String

    public init(logicalMailboxID: LogicalMailboxID?, mode: NodeSyncNotificationPolicyMode, clear: Bool = false, expectedVersion: String, idempotencyKey: String) throws {
        guard !expectedVersion.isEmpty, (expectedVersion == "0" || !expectedVersion.hasPrefix("0")),
              let value = UInt64(expectedVersion), value <= 65_535,
              !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
              (clear ? logicalMailboxID != nil : true) else { throw NotificationPolicyRemoteError.invalidResponse }
        self.logicalMailboxID = logicalMailboxID; self.mode = mode; self.clear = clear; self.expectedVersion = expectedVersion; self.idempotencyKey = idempotencyKey
    }
}

public protocol DirectNotificationPolicyAccess: NotificationPolicyRemote {
    func directDefaultPolicy() async throws -> DirectNotificationPolicyState
    func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState
    func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState
}

/// Assignment-aware presentation for mailbox policy. Unlike the Node wire
/// DTO, this preserves Direct's effective version separately from its mailbox
/// scope high-water mark, including inherited and retained-tombstone rows.
public struct NotificationPolicyPresentationState: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID?
    public let mode: NodeSyncNotificationPolicyMode
    public let version: String
    public let scopeVersion: String
    public let override: Bool

    public init(logicalMailboxID: LogicalMailboxID?, mode: NodeSyncNotificationPolicyMode, version: String, scopeVersion: String, override: Bool) throws {
        _ = try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: mode, version: version, scopeVersion: scopeVersion, override: override)
        self.logicalMailboxID = logicalMailboxID
        self.mode = mode
        self.version = version
        self.scopeVersion = scopeVersion
        self.override = override
    }

    public init(directState: DirectNotificationPolicyState) {
        logicalMailboxID = directState.logicalMailboxID
        mode = directState.mode
        version = directState.version
        scopeVersion = directState.scopeVersion
        override = directState.override
    }

    public init(nodePolicy: NodeSyncNotificationPolicy) throws {
        try self.init(logicalMailboxID: nodePolicy.logicalMailboxID, mode: nodePolicy.mode, version: nodePolicy.version, scopeVersion: nodePolicy.scopeVersion, override: nodePolicy.override)
    }
}

public enum NotificationPolicyPresentationLoadError: String, Sendable, Equatable {
    case conflict
    case unavailable
    case invalidResponse

    public init(remoteError: NotificationPolicyRemoteError) {
        switch remoteError {
        case .conflict: self = .conflict
        case .invalidResponse: self = .invalidResponse
        case .unauthorized, .unavailable: self = .unavailable
        }
    }

    public var message: String {
        switch self {
        case .conflict: "Mailbox notification authority changed."
        case .unavailable: "Mailbox notification policy is temporarily unavailable."
        case .invalidResponse: "Mailbox notification policy could not be read."
        }
    }
}

public enum NotificationPolicyPresentationLoadState: Sendable, Equatable {
    case loading
    case loaded(NotificationPolicyPresentationState)
    case error(NotificationPolicyPresentationLoadError)

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    public var loadError: NotificationPolicyPresentationLoadError? {
        if case .error(let value) = self { return value }
        return nil
    }
}

/// The single policy seam used by presentation and registration when the
/// account can have more than one producer authority. Implementations must
/// resolve the current assignment for each operation and choose the wire
/// protocol from that assignment, rather than from a caller's inferred mode.
public protocol NotificationPolicyAssignmentAccess: Sendable {
    func notificationPolicyPresentation(for logicalMailboxID: LogicalMailboxID) async throws -> NotificationPolicyPresentationState
    func updateNotificationPolicyPresentation(for logicalMailboxID: LogicalMailboxID, mode: NodeSyncNotificationPolicyMode, clear: Bool, idempotencyKey: String) async throws -> NotificationPolicyPresentationState
}

extension NodeSyncClient: NotificationPolicyRemote {}

public actor AccountNotificationPolicyUpdater {
    private let remote: any NotificationPolicyRemote

    public init(remote: any NotificationPolicyRemote) {
        self.remote = remote
    }

    public func current(logicalMailboxID: LogicalMailboxID? = nil) async throws -> NodeSyncNotificationPolicy {
        do {
            return try await remote.notificationPolicy(for: logicalMailboxID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSyncClientError {
            switch error {
            case .conflict, .problem(.conflict): throw NotificationPolicyRemoteError.conflict
            default: throw error
            }
        }
    }

    public func update(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        do {
            return try await remote.updateNotificationPolicy(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSyncClientError {
            switch error {
            case .conflict, .problem(.conflict): throw NotificationPolicyRemoteError.conflict
            default: throw error
            }
        }
    }

    public func clear(logicalMailboxID: LogicalMailboxID, expectedVersion: String, idempotencyKey: String) async throws -> NodeSyncNotificationPolicy {
        let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: logicalMailboxID, clear: true, expectedVersion: expectedVersion, idempotencyKey: idempotencyKey)
        return try await update(request)
    }
}
