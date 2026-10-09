import CryptoKit
import Foundation
import OSLog
import PlainpostAccountProtocol

public struct AccountSecuritySnapshotFailure: Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case trustHistory = "trust_history"
        case securityEvents = "security_events"
        case devices
    }

    public let stage: Stage

    public init(stage: Stage) {
        self.stage = stage
    }
}

private let accountSecurityLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "account-security"
)

public protocol AccountLifecycleRemote: Sendable {
    func issueStepUp(action: AccountLifecycleAction, targetDeviceID: AccountDeviceID?, currentCommitDigest: Data, identityToken: String, appleNonce: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountStepUpAuthorizationV1
    func submitLifecycle(authorization: AccountStepUpAuthorizationV1, candidate: AccountTrustHistoryEntryV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountTrustHistoryEntryV1
    func securityEvents(cursor: String?, limit: Int, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountSecurityEventPageV1
    func deleteAccount(authorization: AccountStepUpAuthorizationV1, currentCommitDigest: Data, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountDeletionResultV1
    func registerCleanup(_ registration: AccountCleanupRegistrationV1, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> AccountCleanupRegistrationReceiptV1
    func checkCleanup(_ check: AccountCleanupCheckV1) async throws -> AccountCleanupDirectiveV1
    func acknowledgeCleanup(_ acknowledgement: AccountCleanupAcknowledgementV1, cleanupCredential: Data) async throws
    func prepareRecovery(identityToken: String, appleNonce: Data, device: AccountDeviceIdentity) async throws -> (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data)
    func commitRecovery(candidate: AccountTrustHistoryEntryV1, authorizationID: AccountAuthorizationID, device: AccountDeviceIdentity) async throws -> AccountRecoveryActivationV1
    func synchronizeTrustHistory(credentials: AccountSessionCredentials, device: AccountDeviceIdentity, applying: any AccountTrustHistoryApplying, now: Date) async throws -> TrustStateCommitV1?
}

extension AccountAPIClient: AccountLifecycleRemote {}

/// Privacy-safe recovery stages suitable for diagnostics and user-facing errors.
/// The cases intentionally contain no server payload, identity, or account data.
public enum AccountRecoveryFailure: String, Error, Equatable, Sendable {
    case requestPreparation
    case serverPreparation
    case responseDecoding
    case responseBinding
    case authorizationVerification
    case priorHistory
    case candidatePreparation
    case localApproval
    case checkpointPersistence
    case serverCommit
    case localActivation
}

public struct AccountLifecycleDeviceSummary: Equatable, Sendable, Identifiable {
    public let id: AccountDeviceID
    public let platform: AccountPlatform
    public let isCurrentDevice: Bool
    public let localLabel: String?
    public let status: String
    public let lastSecurityEventAt: String?
    public init(id: AccountDeviceID, platform: AccountPlatform, isCurrentDevice: Bool, localLabel: String? = nil, status: String = "active", lastSecurityEventAt: String? = nil) {
        self.id = id
        self.platform = platform
        self.isCurrentDevice = isCurrentDevice
        self.localLabel = localLabel
        self.status = status
        self.lastSecurityEventAt = lastSecurityEventAt
    }
}

public struct AccountLifecycleSecuritySnapshot: Equatable, Sendable {
    public let devices: [AccountLifecycleDeviceSummary]
    public let events: [AccountSecurityEventV1]

    public init(
        devices: [AccountLifecycleDeviceSummary],
        events: [AccountSecurityEventV1]
    ) {
        self.devices = devices
        self.events = events
    }
}

/// Owns lifecycle sequencing above the trust, remote, and credential stores.
/// Candidate construction is always local and non-publishing; only an exact
/// centrally accepted entry may advance local trust.
public actor AccountLifecycleController {
    public typealias LocalAuthentication = @Sendable (AccountLifecycleAction) async throws -> Bool
    public typealias RecoveryCoordinatorFactory = @Sendable (PlainpostAccountID, AccountDeviceID, AccountPlatform, AccountDeviceIdentity) throws -> AccountTrustCoordinator
    public typealias ManagedDataPurge = @Sendable (PlainpostAccountID) async throws -> Data

    private let remote: any AccountLifecycleRemote
    private let credentialStore: any AccountCredentialStoring
    private let device: AccountDeviceIdentity
    private let platform: AccountPlatform
    private let credentials: AccountSessionCredentials?
    private let coordinator: AccountTrustCoordinator?
    private let recoveryCoordinatorFactory: RecoveryCoordinatorFactory
    private let manifestStore: BootstrapKeyManifestStore
    private let authenticate: LocalAuthentication
    private let clock: @Sendable () -> Date
    private let purgeManagedData: ManagedDataPurge?
    private var generation: UInt64 = 0

    public init(
        remote: any AccountLifecycleRemote,
        credentialStore: any AccountCredentialStoring,
        device: AccountDeviceIdentity,
        platform: AccountPlatform,
        credentials: AccountSessionCredentials? = nil,
        coordinator: AccountTrustCoordinator? = nil,
        recoveryCoordinatorFactory: @escaping RecoveryCoordinatorFactory,
        manifestStore: BootstrapKeyManifestStore,
        authenticate: @escaping LocalAuthentication,
        clock: @escaping @Sendable () -> Date = Date.init,
        purgeManagedData: ManagedDataPurge? = nil
    ) throws {
        guard platform != .syncNode,
              ((credentials == nil && coordinator == nil) || (credentials != nil && coordinator != nil))
        else { throw AccountRuntimeError.corruptSecret }
        self.remote = remote
        self.credentialStore = credentialStore
        self.device = device
        self.platform = platform
        self.credentials = credentials
        self.coordinator = coordinator
        self.recoveryCoordinatorFactory = recoveryCoordinatorFactory
        self.manifestStore = manifestStore
        self.authenticate = authenticate
        self.clock = clock
        self.purgeManagedData = purgeManagedData
    }

    public func revokeDevice(_ targetDeviceID: AccountDeviceID, identityToken: String, appleNonce: Data) async throws -> AccountTrustHistoryEntryV1 {
        try await removeDevice(targetDeviceID, action: .revokeDevice, identityToken: identityToken, appleNonce: appleNonce)
    }

    public func suspendDevice(_ targetDeviceID: AccountDeviceID, identityToken: String, appleNonce: Data) async throws -> AccountTrustHistoryEntryV1 {
        try await removeDevice(targetDeviceID, action: .suspendDevice, identityToken: identityToken, appleNonce: appleNonce)
    }

    private func removeDevice(_ targetDeviceID: AccountDeviceID, action: AccountLifecycleAction, identityToken: String, appleNonce: Data) async throws -> AccountTrustHistoryEntryV1 {
        guard let credentials, let coordinator, appleNonce.count == 32, !identityToken.isEmpty else { throw AccountRuntimeError.untrustedResponse }
        let operation = nextGeneration()
        guard let predecessor = try await coordinator.currentTrustCommit() else { throw AccountRuntimeError.untrustedResponse }
        let head = AccountTranscript.trustCommitDigest(predecessor)
        let authorization = try await remote.issueStepUp(action: action, targetDeviceID: targetDeviceID, currentCommitDigest: head, identityToken: identityToken, appleNonce: appleNonce, credentials: credentials, device: device, now: clock())
        try requireCurrent(operation)
        guard try await authenticate(action) else { throw AccountRuntimeError.untrustedResponse }
        try requireCurrent(operation)
        let candidate = try await coordinator.makeRemovalCandidate(targetDeviceID, suspended: action == .suspendDevice)
        guard candidate.commit.state.previousCommitDigest == head else { throw AccountRuntimeError.untrustedResponse }
        let accepted: AccountTrustHistoryEntryV1
        do {
            accepted = try await remote.submitLifecycle(authorization: authorization, candidate: candidate, credentials: credentials, device: device, now: clock())
        } catch {
            let submissionError = error
            try requireCurrent(operation)
            let synchronized = try await remote.synchronizeTrustHistory(credentials: credentials, device: device, applying: coordinator, now: clock())
            try requireCurrent(operation)
            guard synchronized == candidate.commit else { throw submissionError }
            return candidate
        }
        try requireCurrent(operation)
        guard accepted == candidate else { throw AccountRuntimeError.untrustedResponse }
        try await coordinator.acceptHistory([accepted])
        return accepted
    }

    public func recover(identityToken: String, appleNonce: Data) async throws -> AccountSession {
        guard credentials == nil, coordinator == nil, appleNonce.count == 32, !identityToken.isEmpty else {
            throw AccountRecoveryFailure.requestPreparation
        }
        let operation = nextGeneration()
        if let interrupted = try credentialStore.loadRecoverySubmission() {
            guard try await authenticate(.recoverAccount) else {
                try credentialStore.clearRecoverySubmission(authorizationID: interrupted.authorizationID, candidate: interrupted.candidate)
                throw AccountRecoveryFailure.localApproval
            }
            try requireCurrent(operation)
            let activation: AccountRecoveryActivationV1
            do {
                activation = try await remote.commitRecovery(candidate: interrupted.candidate, authorizationID: interrupted.authorizationID, device: device)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AccountRecoveryFailure.serverCommit
            }
            try requireCurrent(operation)
            do {
                return try finishAcceptedRecovery(activation, checkpoint: interrupted, operation: operation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AccountRecoveryFailure.localActivation
            }
        }
        let result: (preparation: AccountRecoveryPreparationV1, exchangeRequestDigest: Data)
        do {
            result = try await remote.prepareRecovery(identityToken: identityToken, appleNonce: appleNonce, device: device)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AccountRecoveryFailure {
            throw failure
        } catch let failure as AppleSignInIssuedForAnotherApp {
            throw failure
        } catch {
            throw AccountRecoveryFailure.serverPreparation
        }
        try requireCurrent(operation)
        let preparation = result.preparation
        let recoveryCoordinator: AccountTrustCoordinator
        do {
            recoveryCoordinator = try recoveryCoordinatorFactory(preparation.authorization.accountID, preparation.authorization.deviceID, preparation.authorization.platform, device)
            try await recoveryCoordinator.acceptRecoveryHistory(preparation.priorHistory)
            try requireCurrent(operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountRecoveryFailure.priorHistory
        }
        let candidate: AccountTrustHistoryEntryV1
        let prepared: AccountPreparedTrustActivation
        do {
            candidate = try await recoveryCoordinator.makeRecoveryCandidate(with: preparation.authorization, expectedExchangeRequestDigest: result.exchangeRequestDigest, manifestStore: manifestStore)
            try requireCurrent(operation)
            prepared = try await recoveryCoordinator.prepareRecoveryActivation(candidate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountRecoveryFailure.candidatePreparation
        }
        guard try await authenticate(.recoverAccount) else { throw AccountRecoveryFailure.localApproval }
        try requireCurrent(operation)
        do {
            try credentialStore.beginRecoverySubmission(authorizationID: preparation.authorization.authorizationID, candidate: candidate, prepared: prepared)
        } catch {
            throw AccountRecoveryFailure.checkpointPersistence
        }
        try requireCurrent(operation)
        let activation: AccountRecoveryActivationV1
        do {
            activation = try await remote.commitRecovery(candidate: candidate, authorizationID: preparation.authorization.authorizationID, device: device)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountRecoveryFailure.serverCommit
        }
        try requireCurrent(operation)
        do {
            return try finishAcceptedRecovery(
                activation,
                checkpoint: AccountRecoverySubmissionCheckpoint(authorizationID: preparation.authorization.authorizationID, candidate: candidate, prepared: prepared),
                operation: operation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountRecoveryFailure.localActivation
        }
    }

    private func finishAcceptedRecovery(_ activation: AccountRecoveryActivationV1, checkpoint: AccountRecoverySubmissionCheckpoint, operation: UInt64) throws -> AccountSession {
        guard activation.acceptedEntry == checkpoint.candidate,
              let accessExpiry = AccountWireCodec.parseTimestamp(activation.accessExpiresAt),
              AccountWireCodec.parseTimestamp(activation.offlineLeaseExpiresAt) != nil
        else { throw AccountRuntimeError.untrustedResponse }
        let replacement = try AccountSessionCredentials(
            accountID: checkpoint.candidate.commit.state.accountID,
            deviceID: checkpoint.candidate.commit.state.signerDeviceID,
            accessToken: activation.accessToken,
            accessExpiresAt: accessExpiry,
            refreshCredential: activation.refreshCredential,
            offlineLease: activation.offlineLease
        )
        try requireCurrent(operation)
        try credentialStore.commitRecoveryTrustActivation(credentials: replacement, prepared: checkpoint.prepared)
        return AccountSession(credentials: replacement)
    }

    public func securityHistory(cursor: String? = nil, limit: Int = 32) async throws -> AccountSecurityEventPageV1 {
        guard let credentials else { throw AccountRuntimeError.untrustedResponse }
        return try await remote.securityEvents(cursor: cursor, limit: limit, credentials: credentials, device: device, now: clock())
    }

    public func securitySnapshot(limit: Int = 32) async throws -> AccountLifecycleSecuritySnapshot {
        guard let credentials, let coordinator else { throw AccountRuntimeError.untrustedResponse }
        do {
            _ = try await remote.synchronizeTrustHistory(
                credentials: credentials,
                device: device,
                applying: coordinator,
                now: clock()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accountSecurityLogger.error("snapshot_failed stage=trust_history error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw AccountSecuritySnapshotFailure(stage: .trustHistory)
        }
        let page: AccountSecurityEventPageV1
        do {
            page = try await remote.securityEvents(
                cursor: nil,
                limit: limit,
                credentials: credentials,
                device: device,
                now: clock()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accountSecurityLogger.error("snapshot_failed stage=security_events error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw AccountSecuritySnapshotFailure(stage: .securityEvents)
        }
        do {
            return AccountLifecycleSecuritySnapshot(
                devices: try await devices(recentEvents: page.events),
                events: page.events
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            accountSecurityLogger.error("snapshot_failed stage=devices error_type=\(String(reflecting: type(of: error)), privacy: .public)")
            throw AccountSecuritySnapshotFailure(stage: .devices)
        }
    }

    public func devices(recentEvents: [AccountSecurityEventV1] = []) async throws -> [AccountLifecycleDeviceSummary] {
        guard let coordinator, let head = try await coordinator.currentTrustCommit() else {
            throw AccountRuntimeError.untrustedResponse
        }
        guard let credentials else { throw AccountRuntimeError.untrustedResponse }
        return head.state.members.map {
            let handle = AccountTranscript.securityDeviceHandle(accountID: credentials.accountID, deviceID: $0.deviceID)
            let lastEvent = recentEvents
                .filter { $0.actorHandle == handle || $0.targetHandle == handle }
                .map(\.occurredAt)
                .max()
            return AccountLifecycleDeviceSummary(id: $0.deviceID, platform: $0.platform, isCurrentDevice: $0.deviceID == credentials.deviceID, localLabel: try? credentialStore.loadDeviceLabel(accountID: credentials.accountID, deviceID: $0.deviceID), lastSecurityEventAt: lastEvent)
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func setLocalDeviceLabel(_ label: String, for deviceID: AccountDeviceID) async throws {
        guard let credentials, let coordinator, let head = try await coordinator.currentTrustCommit(),
              head.state.members.contains(where: { $0.deviceID == deviceID }) else { throw AccountRuntimeError.untrustedResponse }
        try credentialStore.saveDeviceLabel(label, accountID: credentials.accountID, deviceID: deviceID)
    }

    /// Registers the current native client while ordinary account authority is
    /// still live. Account deletion later requires one cleanup capability per
    /// active client so an offline client can erase itself after bearer/session
    /// authority has been revoked.
    public func registerCurrentCleanupTarget() async throws -> AccountCleanupRegistrationReceiptV1 {
        let operation = nextGeneration()
        let (_, receipt) = try await registerCleanupTarget()
        try requireCurrent(operation)
        return receipt
    }

    public func deleteAccount(identityToken: String, appleNonce: Data) async throws -> AccountDeletionResultV1 {
        guard let credentials, let coordinator, let purgeManagedData,
              appleNonce.count == 32, !identityToken.isEmpty
        else { throw AccountRuntimeError.untrustedResponse }
        let operation = nextGeneration()
        guard let predecessor = try await coordinator.currentTrustCommit() else { throw AccountRuntimeError.untrustedResponse }
        let head = AccountTranscript.trustCommitDigest(predecessor)
        let (capability, receipt) = try await registerCleanupTarget()
        let kind = capability.kind
        try requireCurrent(operation)
        let authorization = try await remote.issueStepUp(action: .deleteAccount, targetDeviceID: nil, currentCommitDigest: head, identityToken: identityToken, appleNonce: appleNonce, credentials: credentials, device: device, now: clock())
        try requireCurrent(operation)
        guard try await authenticate(.deleteAccount) else { throw AccountRuntimeError.untrustedResponse }
        try requireCurrent(operation)
        let prepared = try AccountLocalDeletionCheckpoint(accountID: credentials.accountID, deviceID: credentials.deviceID, kind: kind, targetHandle: capability.targetHandle, deletionGeneration: receipt.nextDeletionGeneration, phase: .prepared, resultDigest: nil)
        try credentialStore.beginLocalDeletion(prepared, capability: capability, authorization: authorization, headCommitDigest: head)
        let result: AccountDeletionResultV1
        do {
            result = try await remote.deleteAccount(authorization: authorization, currentCommitDigest: head, credentials: credentials, device: device, now: clock())
        } catch AccountRuntimeError.untrustedResponse {
            try credentialStore.cancelLocalDeletion(accountID: credentials.accountID)
            throw AccountRuntimeError.untrustedResponse
        }
        try requireCurrent(operation)
        guard result.accountID == credentials.accountID,
              result.deletionGeneration == receipt.nextDeletionGeneration,
              result.targets.contains(where: { $0.handle == capability.targetHandle && $0.kind == kind && $0.status == .erasurePending })
        else { throw AccountRuntimeError.untrustedResponse }
        try credentialStore.advanceLocalDeletion(try AccountLocalDeletionCheckpoint(accountID: prepared.accountID, deviceID: prepared.deviceID, kind: prepared.kind, targetHandle: prepared.targetHandle, deletionGeneration: prepared.deletionGeneration, phase: .centralAccepted, resultDigest: nil))
        try await finishLocalDeletion(operation: operation, capability: capability, purgeManagedData: purgeManagedData)
        return result
    }

    private func registerCleanupTarget() async throws -> (AccountCleanupCapability, AccountCleanupRegistrationReceiptV1) {
        guard let credentials, let coordinator, try await coordinator.currentTrustCommit() != nil else {
            throw AccountRuntimeError.untrustedResponse
        }
        let kind: AccountCleanupTargetKind = platform == .macos ? .macos : .ios
        let capability = try credentialStore.loadOrCreateCleanupCapability(accountID: credentials.accountID, deviceID: credentials.deviceID, kind: kind)
        let registration = try AccountCleanupRegistrationV1(
            targetHandle: capability.targetHandle,
            targetKind: capability.kind,
            cleanupCredentialDigest: Data(SHA256.hash(data: capability.credential))
        )
        let receipt = try await remote.registerCleanup(registration, credentials: credentials, device: device, now: clock())
        guard receipt.targetHandle == capability.targetHandle else { throw AccountRuntimeError.untrustedResponse }
        return (capability, receipt)
    }

    public func resumeLocalDeletion() async throws {
        guard let submission = try credentialStore.loadLocalDeletionSubmission(), let purgeManagedData else { return }
        let operation = nextGeneration()
        let checkpoint = submission.checkpoint
        let capability = try credentialStore.loadOrCreateCleanupCapability(accountID: checkpoint.accountID, deviceID: checkpoint.deviceID, kind: checkpoint.kind)
        do {
            try await finishLocalDeletion(operation: operation, capability: capability, purgeManagedData: purgeManagedData)
        } catch AccountRuntimeError.untrustedResponse where checkpoint.phase == .prepared {
            guard let credentials, credentials.accountID == checkpoint.accountID, credentials.deviceID == checkpoint.deviceID else {
                throw AccountRuntimeError.untrustedResponse
            }
            do {
                _ = try await remote.deleteAccount(authorization: submission.authorization, currentCommitDigest: submission.headCommitDigest, credentials: credentials, device: device, now: clock())
            } catch AccountRuntimeError.untrustedResponse {
                // A completed deletion invalidates ordinary bearer auth. The
                // cleanup credential remains authoritative, so re-check once
                // after the exact retry before staying fail-closed.
            }
            try requireCurrent(operation)
            try await finishLocalDeletion(operation: operation, capability: capability, purgeManagedData: purgeManagedData)
        }
    }

    private func finishLocalDeletion(operation: UInt64, capability: AccountCleanupCapability, purgeManagedData: ManagedDataPurge) async throws {
        guard var checkpoint = try credentialStore.loadLocalDeletion(), checkpoint.accountID == capability.accountID,
              checkpoint.deviceID == capability.deviceID, checkpoint.targetHandle == capability.targetHandle
        else { throw AccountRuntimeError.corruptSecret }
        let directive = try await remote.checkCleanup(try AccountCleanupCheckV1(targetHandle: capability.targetHandle, deletionGeneration: checkpoint.deletionGeneration, cleanupCredential: capability.credential))
        try requireCurrent(operation)
        guard directive.targetHandle == checkpoint.targetHandle,
              directive.deletionGeneration == checkpoint.deletionGeneration,
              directive.targetKind == checkpoint.kind,
              directive.status == .erasurePending || directive.status == .erased
        else { throw AccountRuntimeError.untrustedResponse }
        if checkpoint.phase == .prepared {
            checkpoint = try AccountLocalDeletionCheckpoint(accountID: checkpoint.accountID, deviceID: checkpoint.deviceID, kind: checkpoint.kind, targetHandle: checkpoint.targetHandle, deletionGeneration: checkpoint.deletionGeneration, phase: .centralAccepted, resultDigest: nil)
            try credentialStore.advanceLocalDeletion(checkpoint)
        }
        if checkpoint.phase != .localPurged {
            let purgeDigest = try await purgeManagedData(checkpoint.accountID)
            try requireCurrent(operation)
            guard purgeDigest.count == 32, !purgeDigest.allSatisfy({ $0 == 0 }) else { throw AccountRuntimeError.untrustedResponse }
            try credentialStore.purgeAccountAuthority(accountID: checkpoint.accountID)
            let resultDigest = Data(SHA256.hash(data: AccountTranscript.parts([Data("Plainpost.AccountLocalDeletionResult.v1".utf8), checkpoint.targetHandle, AccountTranscript.u64(checkpoint.deletionGeneration.value), purgeDigest])))
            checkpoint = try AccountLocalDeletionCheckpoint(accountID: checkpoint.accountID, deviceID: checkpoint.deviceID, kind: checkpoint.kind, targetHandle: checkpoint.targetHandle, deletionGeneration: checkpoint.deletionGeneration, phase: .localPurged, resultDigest: resultDigest)
            try credentialStore.advanceLocalDeletion(checkpoint)
        }
        guard let resultDigest = checkpoint.resultDigest else { throw AccountRuntimeError.corruptSecret }
        try await remote.acknowledgeCleanup(try AccountCleanupAcknowledgementV1(targetHandle: checkpoint.targetHandle, deletionGeneration: checkpoint.deletionGeneration, resultDigest: resultDigest), cleanupCredential: capability.credential)
        try requireCurrent(operation)
        try credentialStore.completeLocalDeletion(accountID: checkpoint.accountID)
    }

    public func cancel() { _ = nextGeneration() }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func requireCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

}
