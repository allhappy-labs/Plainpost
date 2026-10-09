import Foundation
import Observation
import PlainpostAccountProtocol
import PlainpostAccountRuntime

public enum NotificationPolicyPresentationAuthority: String, Sendable, Equatable {
    case none
    case mac
    case syncNode
    case mixed
}

public struct NotificationPolicyProviderMailbox: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID
    public let label: String

    public init(logicalMailboxID: LogicalMailboxID, label: String) {
        self.logicalMailboxID = logicalMailboxID
        self.label = label
    }
}

public struct NotificationPolicyMailboxPresentationRow: Sendable, Equatable, Identifiable {
    public let logicalMailboxID: LogicalMailboxID
    public let label: String
    public let authority: NotificationProducerKind
    public fileprivate(set) var loadState: NotificationPolicyPresentationLoadState
    public var id: LogicalMailboxID { logicalMailboxID }

    fileprivate init(logicalMailboxID: LogicalMailboxID, label: String, authority: NotificationProducerKind, loadState: NotificationPolicyPresentationLoadState) {
        self.logicalMailboxID = logicalMailboxID
        self.label = label
        self.authority = authority
        self.loadState = loadState
    }
}

public struct NotificationPolicyPresentationSnapshot: Sendable, Equatable {
    public let authority: NotificationPolicyPresentationAuthority
    public private(set) var rows: [NotificationPolicyMailboxPresentationRow]
    public let message: String?

    fileprivate init(authority: NotificationPolicyPresentationAuthority, rows: [NotificationPolicyMailboxPresentationRow], message: String? = nil) {
        self.authority = authority
        self.rows = rows
        self.message = message
    }
}

private struct NotificationAssignmentIdentity: Hashable, Sendable {
    let logicalMailboxID: LogicalMailboxID
    let producerDeviceID: AccountDeviceID
    let kind: NotificationProducerKind
    let generation: UInt64
    let trustEpoch: UInt64
    let trustRevision: UInt64
    let trustHead: Data
    let producerSigningPublicKey: Data?

    init(_ assignment: NotificationProducerAssignment, mailbox: LogicalMailboxID) {
        logicalMailboxID = mailbox
        producerDeviceID = assignment.producerDeviceID
        kind = assignment.kind
        generation = assignment.generation
        trustEpoch = assignment.trustEpoch
        trustRevision = assignment.trustRevision
        trustHead = assignment.trustHead
        producerSigningPublicKey = assignment.producerSigningPublicKey
    }
}

private struct NotificationSettledMailboxState: Sendable {
    let assignment: NotificationAssignmentIdentity
    let loadState: NotificationPolicyPresentationLoadState
}

/// Main-actor presentation coordinator shared by the iOS account model and
/// mailbox view. It owns assignment-derived row identity and every policy
/// load transition, so a failed read cannot be mistaken for an in-flight row.
@MainActor
@Observable
public final class NotificationPolicyPresentationCoordinator {
    public private(set) var snapshot = NotificationPolicyPresentationSnapshot(authority: .none, rows: [])

    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var operationGenerations: [LogicalMailboxID: UInt64] = [:]
    @ObservationIgnored private var assignmentsByMailbox: [LogicalMailboxID: NotificationProducerAssignment] = [:]
    @ObservationIgnored private var lastSettledSnapshot = NotificationPolicyPresentationSnapshot(authority: .none, rows: [])
    @ObservationIgnored private var lastSettledAssignmentsByMailbox: [LogicalMailboxID: NotificationProducerAssignment] = [:]

    public init() {}

    public func current() -> NotificationPolicyPresentationSnapshot { snapshot }

    public func setLoaded(_ logicalMailboxID: LogicalMailboxID, state: NotificationPolicyPresentationState) {
        _ = nextOperationGeneration(for: logicalMailboxID)
        replaceRow(logicalMailboxID, loadState: .loaded(state), message: nil)
    }

    public func setError(_ logicalMailboxID: LogicalMailboxID, error: NotificationPolicyPresentationLoadError) {
        _ = nextOperationGeneration(for: logicalMailboxID)
        replaceRow(logicalMailboxID, loadState: .error(error), message: error.message)
    }

    @discardableResult
    public func refresh(
        assignments: () async throws -> [NotificationProducerAssignment],
        providerMailboxes: [NotificationPolicyProviderMailbox],
        policyProvider: (LogicalMailboxID) async throws -> NotificationPolicyPresentationState
    ) async throws -> NotificationPolicyPresentationSnapshot {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var loadStarted = false
        var operationTokens: [LogicalMailboxID: UInt64] = [:]
        operationGenerations.removeAll()
        assignmentsByMailbox.removeAll()

        do {
            let values = try await assignments()
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return snapshot }
            let derivedRows = Self.rows(assignments: values, providerMailboxes: providerMailboxes)
            assignmentsByMailbox = Self.assignmentMap(assignments: values)
            snapshot = NotificationPolicyPresentationSnapshot(
                authority: Self.authority(assignments: values),
                rows: derivedRows.map { row in
                    NotificationPolicyMailboxPresentationRow(logicalMailboxID: row.logicalMailboxID, label: row.label, authority: row.authority, loadState: .loading)
                }
            )
            loadStarted = true
            let priorStates = settledStates(for: derivedRows.map(\.logicalMailboxID))
            derivedRows.forEach { row in
                operationTokens[row.logicalMailboxID] = nextOperationGeneration(for: row.logicalMailboxID)
            }
            let result = try await loadAll(
                policyProvider: policyProvider,
                generation: generation,
                operationTokens: operationTokens,
                priorStates: priorStates
            )
            guard generation == refreshGeneration else { return result }
            lastSettledSnapshot = result
            lastSettledAssignmentsByMailbox = assignmentsByMailbox
            return result
        } catch is CancellationError {
            if generation == refreshGeneration, !loadStarted {
                snapshot = lastSettledSnapshot
            }
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return snapshot }
            snapshot = NotificationPolicyPresentationSnapshot(authority: .none, rows: [], message: NotificationPolicyPresentationLoadError.unavailable.message)
            return snapshot
        }
    }

    @discardableResult
    public func retry(
        _ logicalMailboxID: LogicalMailboxID,
        policyProvider: (LogicalMailboxID) async throws -> NotificationPolicyPresentationState
    ) async throws -> NotificationPolicyPresentationSnapshot {
        guard let row = snapshot.rows.first(where: { $0.logicalMailboxID == logicalMailboxID }),
              let assignment = assignmentsByMailbox[logicalMailboxID] else { return snapshot }
        let generation = refreshGeneration
        let operation = nextOperationGeneration(for: logicalMailboxID)
        let restoreState: NotificationPolicyPresentationLoadState = switch row.loadState {
        case .loading: .error(.unavailable)
        default: row.loadState
        }
        replaceRow(logicalMailboxID, loadState: .loading, message: nil)

        do {
            let state = try await policyProvider(logicalMailboxID)
            try Task.checkCancellation()
            guard isCurrent(logicalMailboxID, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
            replaceRow(logicalMailboxID, loadState: .loaded(state), message: nil)
        } catch is CancellationError {
            if isCurrent(logicalMailboxID, assignment: assignment, generation: generation, operation: operation) {
                replaceRow(logicalMailboxID, loadState: restoreState, message: nil)
            }
            throw CancellationError()
        } catch let error as NotificationPolicyRemoteError {
            try Task.checkCancellation()
            guard isCurrent(logicalMailboxID, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
            replaceRow(logicalMailboxID, loadState: .error(.init(remoteError: error)), message: nil)
        } catch {
            try Task.checkCancellation()
            guard isCurrent(logicalMailboxID, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
            replaceRow(logicalMailboxID, loadState: .error(.unavailable), message: nil)
        }
        return snapshot
    }

    @discardableResult
    public func refreshAfterConflict(
        _ logicalMailboxID: LogicalMailboxID,
        policyProvider: (LogicalMailboxID) async throws -> NotificationPolicyPresentationState
    ) async throws -> NotificationPolicyPresentationSnapshot {
        let result = try await retry(logicalMailboxID, policyProvider: policyProvider)
        guard let row = result.rows.first(where: { $0.logicalMailboxID == logicalMailboxID }), row.loadState.isLoaded else {
            let message = result.rows.first(where: { $0.logicalMailboxID == logicalMailboxID })?.loadState.loadError?.message ?? NotificationPolicyPresentationLoadError.conflict.message
            snapshot = NotificationPolicyPresentationSnapshot(authority: result.authority, rows: result.rows, message: message)
            return snapshot
        }
        snapshot = NotificationPolicyPresentationSnapshot(authority: result.authority, rows: result.rows, message: "Mailbox notification policy changed elsewhere; refreshed.")
        return snapshot
    }

    private func loadAll(
        policyProvider: (LogicalMailboxID) async throws -> NotificationPolicyPresentationState,
        generation: UInt64,
        operationTokens: [LogicalMailboxID: UInt64],
        priorStates: [LogicalMailboxID: NotificationSettledMailboxState]
    ) async throws -> NotificationPolicyPresentationSnapshot {
        let mailboxes = snapshot.rows.map(\.logicalMailboxID)
        for mailbox in mailboxes {
            guard generation == refreshGeneration, let assignment = assignmentsByMailbox[mailbox] else { return snapshot }
            guard let operation = operationGenerations[mailbox] else { continue }
            do {
                let state = try await policyProvider(mailbox)
                try Task.checkCancellation()
                guard isCurrent(mailbox, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
                replaceRow(mailbox, loadState: .loaded(state), message: nil)
            } catch is CancellationError {
                if generation == refreshGeneration {
                    restoreCancelledRefreshRows(operationTokens: operationTokens, priorStates: priorStates)
                }
                throw CancellationError()
            } catch let error as NotificationPolicyRemoteError {
                try Task.checkCancellation()
                guard isCurrent(mailbox, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
                replaceRow(mailbox, loadState: .error(.init(remoteError: error)), message: nil)
            } catch {
                try Task.checkCancellation()
                guard isCurrent(mailbox, assignment: assignment, generation: generation, operation: operation) else { return snapshot }
                replaceRow(mailbox, loadState: .error(.unavailable), message: nil)
            }
        }
        return snapshot
    }

    @discardableResult
    private func nextOperationGeneration(for mailbox: LogicalMailboxID) -> UInt64 {
        let next = (operationGenerations[mailbox] ?? 0) &+ 1
        operationGenerations[mailbox] = next
        return next
    }

    private func isCurrent(_ mailbox: LogicalMailboxID, assignment: NotificationProducerAssignment, generation: UInt64, operation: UInt64) -> Bool {
        generation == refreshGeneration && operationGenerations[mailbox] == operation && assignmentsByMailbox[mailbox] == assignment && snapshot.rows.contains { $0.logicalMailboxID == mailbox }
    }

    private func replaceRow(_ mailbox: LogicalMailboxID, loadState: NotificationPolicyPresentationLoadState, message: String?) {
        guard let index = snapshot.rows.firstIndex(where: { $0.logicalMailboxID == mailbox }) else { return }
        var rows = snapshot.rows
        rows[index].loadState = loadState
        snapshot = NotificationPolicyPresentationSnapshot(authority: snapshot.authority, rows: rows, message: message)
        if !rows.contains(where: { if case .loading = $0.loadState { return true }; return false }) {
            lastSettledSnapshot = snapshot
            lastSettledAssignmentsByMailbox = assignmentsByMailbox
        }
    }

    private func settledStates(for mailboxes: [LogicalMailboxID]) -> [LogicalMailboxID: NotificationSettledMailboxState] {
        var result: [LogicalMailboxID: NotificationSettledMailboxState] = [:]
        for row in lastSettledSnapshot.rows where mailboxes.contains(row.logicalMailboxID) {
            guard let assignment = lastSettledAssignmentsByMailbox[row.logicalMailboxID] else { continue }
            result[row.logicalMailboxID] = NotificationSettledMailboxState(
                assignment: NotificationAssignmentIdentity(assignment, mailbox: row.logicalMailboxID),
                loadState: row.loadState
            )
        }
        return result
    }

    private func restoreCancelledRefreshRows(
        operationTokens: [LogicalMailboxID: UInt64],
        priorStates: [LogicalMailboxID: NotificationSettledMailboxState]
    ) {
        var rows = snapshot.rows
        var changed = false
        for (mailbox, operation) in operationTokens {
            guard operationGenerations[mailbox] == operation,
                  let index = rows.firstIndex(where: { $0.logicalMailboxID == mailbox }),
                  rows[index].loadState == .loading else { continue }
            guard let prior = priorStates[mailbox],
                  let currentAssignment = assignmentsByMailbox[mailbox],
                  NotificationAssignmentIdentity(currentAssignment, mailbox: mailbox) == prior.assignment else {
                rows[index].loadState = .error(.unavailable)
                changed = true
                continue
            }
            rows[index].loadState = prior.loadState
            changed = true
        }
        guard changed else { return }
        snapshot = NotificationPolicyPresentationSnapshot(authority: snapshot.authority, rows: rows, message: nil)
        if !rows.contains(where: { if case .loading = $0.loadState { return true }; return false }) {
            lastSettledSnapshot = snapshot
            lastSettledAssignmentsByMailbox = assignmentsByMailbox
        }
    }

    private static func assignmentMap(assignments: [NotificationProducerAssignment]) -> [LogicalMailboxID: NotificationProducerAssignment] {
        var result: [LogicalMailboxID: NotificationProducerAssignment] = [:]
        for assignment in assignments {
            guard let mailbox = LogicalMailboxID(rawValue: assignment.logicalMailboxID) else { continue }
            result[mailbox] = assignment
        }
        return result
    }

    private static func rows(assignments: [NotificationProducerAssignment], providerMailboxes: [NotificationPolicyProviderMailbox]) -> [(logicalMailboxID: LogicalMailboxID, label: String, authority: NotificationProducerKind)] {
        let macAssignments = assignments.filter { $0.kind == .mac }
        let direct = macAssignments.enumerated().compactMap { index, assignment -> (LogicalMailboxID, String, NotificationProducerKind)? in
            guard let mailbox = LogicalMailboxID(rawValue: assignment.logicalMailboxID), assignment.logicalMailboxID.contains(where: { $0 != 0 }) else { return nil }
            return (mailbox, "Mailbox \(index + 1)", .mac)
        }
        let syncIDs = Set(assignments.filter { $0.kind == .syncNode }.compactMap { LogicalMailboxID(rawValue: $0.logicalMailboxID) })
        let sync = providerMailboxes.compactMap { provider -> (LogicalMailboxID, String, NotificationProducerKind)? in
            guard syncIDs.contains(provider.logicalMailboxID) else { return nil }
            return (provider.logicalMailboxID, provider.label, .syncNode)
        }
        return direct + sync
    }

    private static func authority(assignments: [NotificationProducerAssignment]) -> NotificationPolicyPresentationAuthority {
        let hasMac = assignments.contains { $0.kind == .mac }
        let hasSyncNode = assignments.contains { $0.kind == .syncNode }
        return switch (hasMac, hasSyncNode) {
        case (true, true): .mixed
        case (true, false): .mac
        case (false, true): .syncNode
        default: .none
        }
    }
}
