import Foundation

public enum AccountLifecycleAction: String, Codable, Hashable, Sendable {
    case addDevice = "add_device"
    case revokeDevice = "revoke_device"
    case suspendDevice = "suspend_device"
    case deleteAccount = "delete_account"
    case recoverAccount = "recover_account"
    case enrollSyncNode = "enroll_sync_node"
    case replaceSyncNode = "replace_sync_node"
}

public struct AccountStepUpRequestV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let actorDeviceID: AccountDeviceID
    public let targetDeviceID: AccountDeviceID?
    public let action: AccountLifecycleAction
    public let currentCommitDigest: Data
    public let requestNonce: Data
    public let appleNonce: Data
    public let identityToken: String

    public init(accountID: PlainpostAccountID, actorDeviceID: AccountDeviceID, targetDeviceID: AccountDeviceID?, action: AccountLifecycleAction, currentCommitDigest: Data, requestNonce: Data, appleNonce: Data, identityToken: String) throws {
        guard currentCommitDigest.count == 32, requestNonce.count == 32, appleNonce.count == 32,
              !requestNonce.allSatisfy({ $0 == 0 }), !appleNonce.allSatisfy({ $0 == 0 }),
              !identityToken.isEmpty, identityToken.utf8.count <= 16_384,
              (action.requiresTarget == (targetDeviceID != nil)),
              action != .recoverAccount
        else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID; self.actorDeviceID = actorDeviceID; self.targetDeviceID = targetDeviceID
        self.action = action; self.currentCommitDigest = currentCommitDigest; self.requestNonce = requestNonce
        self.appleNonce = appleNonce; self.identityToken = identityToken
    }
}

public struct AccountStepUpAuthorizationV1: Hashable, Sendable {
    public let authorizationID: AccountAuthorizationID
    public let accountID: PlainpostAccountID
    public let actorDeviceID: AccountDeviceID
    public let targetDeviceID: AccountDeviceID?
    public let action: AccountLifecycleAction
    public let currentCommitDigest: Data
    public let requestDigest: Data
    public let issuedAt: String
    public let expiresAt: String
    public let serverKeyID: String
    public let serverSignature: Data

    public init(authorizationID: AccountAuthorizationID, accountID: PlainpostAccountID, actorDeviceID: AccountDeviceID, targetDeviceID: AccountDeviceID?, action: AccountLifecycleAction, currentCommitDigest: Data, requestDigest: Data, issuedAt: String, expiresAt: String, serverKeyID: String, serverSignature: Data) throws {
        guard currentCommitDigest.count == 32, requestDigest.count == 32, serverSignature.count == 64,
              AccountWireCodec.isKeyID(serverKeyID), let issued = AccountWireCodec.parseTimestamp(issuedAt),
              let expiry = AccountWireCodec.parseTimestamp(expiresAt), issued < expiry,
              expiry.timeIntervalSince(issued) <= 300,
              (action.requiresTarget == (targetDeviceID != nil)),
              action != .recoverAccount
        else { throw AccountProtocolError.malformedWire }
        try AccountWireCodec.validateLowSSignature(serverSignature)
        self.authorizationID = authorizationID; self.accountID = accountID; self.actorDeviceID = actorDeviceID
        self.targetDeviceID = targetDeviceID; self.action = action; self.currentCommitDigest = currentCommitDigest
        self.requestDigest = requestDigest; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.serverKeyID = serverKeyID; self.serverSignature = serverSignature
    }
}

private extension AccountLifecycleAction {
    var requiresTarget: Bool { self == .addDevice || self == .revokeDevice || self == .suspendDevice || self == .enrollSyncNode || self == .replaceSyncNode }
}

public struct AccountLifecycleSubmissionV1: Hashable, Sendable {
    public let authorization: AccountStepUpAuthorizationV1
    public let entry: AccountTrustHistoryEntryV1
    public init(authorization: AccountStepUpAuthorizationV1, entry: AccountTrustHistoryEntryV1) throws {
        let transition = entry.commit.state.transition.kind
        let hasAdmissionEvidence: Bool
        if case .admission = entry.evidence { hasAdmissionEvidence = true } else { hasAdmissionEvidence = false }
        guard ((transition == .admission && hasAdmissionEvidence && authorization.action == .addDevice) ||
               (transition == .revocation && entry.evidence == nil && authorization.action == .revokeDevice) ||
               (transition == .suspension && entry.evidence == nil && authorization.action == .suspendDevice)),
              authorization.accountID == entry.commit.state.accountID,
              authorization.currentCommitDigest == entry.commit.state.previousCommitDigest,
              authorization.targetDeviceID == entry.commit.state.transition.targetDeviceIDs.first,
              entry.commit.state.transition.targetDeviceIDs.count == 1
        else { throw AccountProtocolError.invalidTransition }
        self.authorization = authorization; self.entry = entry
    }
}

public enum AccountCleanupTargetKind: String, Codable, Hashable, Sendable {
    case macos, ios, syncNode = "sync_node", managedBackup = "managed_backup", operatorStorage = "operator_storage"
}
public enum AccountCleanupStatus: String, Codable, Hashable, Sendable {
    case erasurePending = "erasure_pending", erased, operatorActionRequired = "operator_action_required"
}
public struct AccountCleanupTargetStatusV1: Hashable, Sendable {
    public let handle: Data; public let kind: AccountCleanupTargetKind; public let status: AccountCleanupStatus
    public init(handle: Data, kind: AccountCleanupTargetKind, status: AccountCleanupStatus) throws {
        guard handle.count == 32, !handle.allSatisfy({ $0 == 0 }) else { throw AccountProtocolError.malformedWire }
        self.handle = handle; self.kind = kind; self.status = status
    }
}

public struct AccountCleanupRegistrationV1: Hashable, Sendable {
    public let targetHandle: Data
    public let targetKind: AccountCleanupTargetKind
    public let cleanupCredentialDigest: Data
    public init(targetHandle: Data, targetKind: AccountCleanupTargetKind, cleanupCredentialDigest: Data) throws {
        guard targetHandle.count == 32, cleanupCredentialDigest.count == 32,
              !targetHandle.allSatisfy({ $0 == 0 }), !cleanupCredentialDigest.allSatisfy({ $0 == 0 }),
              targetKind == .macos || targetKind == .ios || targetKind == .syncNode
        else { throw AccountProtocolError.malformedWire }
        self.targetHandle = targetHandle
        self.targetKind = targetKind
        self.cleanupCredentialDigest = cleanupCredentialDigest
    }
}

public struct AccountCleanupRegistrationReceiptV1: Hashable, Sendable {
    public let targetHandle: Data
    public let nextDeletionGeneration: PositiveUInt64
    public init(targetHandle: Data, nextDeletionGeneration: PositiveUInt64) throws {
        guard targetHandle.count == 32, !targetHandle.allSatisfy({ $0 == 0 }) else { throw AccountProtocolError.malformedWire }
        self.targetHandle = targetHandle
        self.nextDeletionGeneration = nextDeletionGeneration
    }
}

public struct AccountDeletionRequestV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let headCommitDigest: Data; public let authorization: AccountStepUpAuthorizationV1
    public init(accountID: PlainpostAccountID, headCommitDigest: Data, authorization: AccountStepUpAuthorizationV1) throws {
        guard headCommitDigest.count == 32, authorization.accountID == accountID, authorization.action == .deleteAccount,
              authorization.targetDeviceID == nil, authorization.currentCommitDigest == headCommitDigest
        else { throw AccountProtocolError.malformedWire }
        self.accountID = accountID; self.headCommitDigest = headCommitDigest; self.authorization = authorization
    }
}

public struct AccountDeletionResultV1: Hashable, Sendable {
    public let accountID: PlainpostAccountID; public let deletionGeneration: PositiveUInt64
    public let centralBackupExpiresAt: String; public let targets: [AccountCleanupTargetStatusV1]; public let deletedAt: String
    public init(accountID: PlainpostAccountID, deletionGeneration: PositiveUInt64, centralBackupExpiresAt: String, targets: [AccountCleanupTargetStatusV1], deletedAt: String) throws {
        guard targets.count <= 16, Set(targets.map(\.handle)).count == targets.count,
              let deleted = AccountWireCodec.parseTimestamp(deletedAt), let expiry = AccountWireCodec.parseTimestamp(centralBackupExpiresAt), deleted < expiry
        else { throw AccountProtocolError.malformedWire }
        let ordered = targets.sorted { $0.handle.lexicographicallyPrecedes($1.handle) }
        guard targets == ordered else { throw AccountProtocolError.nonCanonicalValue }
        self.accountID = accountID; self.deletionGeneration = deletionGeneration; self.centralBackupExpiresAt = centralBackupExpiresAt; self.targets = targets; self.deletedAt = deletedAt
    }
}

public struct AccountCleanupCheckV1: Hashable, Sendable {
    public let targetHandle: Data; public let deletionGeneration: PositiveUInt64; public let cleanupCredential: Data
    public init(targetHandle: Data, deletionGeneration: PositiveUInt64, cleanupCredential: Data) throws {
        guard targetHandle.count == 32, cleanupCredential.count == 32, !targetHandle.allSatisfy({ $0 == 0 }), !cleanupCredential.allSatisfy({ $0 == 0 }) else { throw AccountProtocolError.malformedWire }
        self.targetHandle = targetHandle; self.deletionGeneration = deletionGeneration; self.cleanupCredential = cleanupCredential
    }
}
public struct AccountCleanupAcknowledgementV1: Hashable, Sendable {
    public let targetHandle: Data; public let deletionGeneration: PositiveUInt64; public let resultDigest: Data
    public init(targetHandle: Data, deletionGeneration: PositiveUInt64, resultDigest: Data) throws {
        guard targetHandle.count == 32, resultDigest.count == 32, !targetHandle.allSatisfy({ $0 == 0 }), !resultDigest.allSatisfy({ $0 == 0 }) else { throw AccountProtocolError.malformedWire }
        self.targetHandle = targetHandle; self.deletionGeneration = deletionGeneration; self.resultDigest = resultDigest
    }
}
public struct AccountCleanupDirectiveV1: Hashable, Sendable {
    public let targetHandle: Data; public let deletionGeneration: PositiveUInt64; public let targetKind: AccountCleanupTargetKind; public let status: AccountCleanupStatus; public let centralBackupExpiresAt: String
    public init(targetHandle: Data, deletionGeneration: PositiveUInt64, targetKind: AccountCleanupTargetKind, status: AccountCleanupStatus, centralBackupExpiresAt: String) throws {
        guard targetHandle.count == 32, !targetHandle.allSatisfy({ $0 == 0 }), AccountWireCodec.parseTimestamp(centralBackupExpiresAt) != nil else { throw AccountProtocolError.malformedWire }
        self.targetHandle = targetHandle; self.deletionGeneration = deletionGeneration; self.targetKind = targetKind; self.status = status; self.centralBackupExpiresAt = centralBackupExpiresAt
    }
}

public enum AccountSecurityEventCategory: String, Codable, Hashable, Sendable {
    case deviceAdded = "device_added", deviceRevoked = "device_revoked", deviceSuspended = "device_suspended", accountRecovered = "account_recovered", accountDeleted = "account_deleted", cleanupAcknowledged = "cleanup_acknowledged"
}
public struct AccountSecurityEventV1: Hashable, Sendable {
    public let handle: Data; public let category: AccountSecurityEventCategory; public let actorHandle: Data; public let targetHandle: Data?; public let platform: AccountPlatform?; public let status: String; public let occurredAt: String
    public init(handle: Data, category: AccountSecurityEventCategory, actorHandle: Data, targetHandle: Data?, platform: AccountPlatform?, status: String, occurredAt: String) throws {
        let allowedStatuses: Set<String> = ["pending", "active", "suspended", "revoked", "deleted", "erasure_pending", "erased", "operator_action_required"]
        guard handle.count == 32, actorHandle.count == 32, targetHandle?.count ?? 32 == 32, !handle.allSatisfy({ $0 == 0 }), !actorHandle.allSatisfy({ $0 == 0 }), allowedStatuses.contains(status), AccountWireCodec.parseTimestamp(occurredAt) != nil else { throw AccountProtocolError.malformedWire }
        self.handle = handle; self.category = category; self.actorHandle = actorHandle; self.targetHandle = targetHandle; self.platform = platform; self.status = status; self.occurredAt = occurredAt
    }
}
public struct AccountSecurityEventPageV1: Hashable, Sendable {
    public let events: [AccountSecurityEventV1]; public let nextCursor: String?
    public init(events: [AccountSecurityEventV1], nextCursor: String?) throws {
        let cursorIsValid = nextCursor.map { (try? AccountWireCodec.decodeBase64URL($0, exactBytes: 8)) != nil } ?? true
        guard events.count <= 32, cursorIsValid else { throw AccountProtocolError.malformedWire }
        self.events = events; self.nextCursor = nextCursor
    }
}

public struct AccountRecoveryRequestV1: Sendable {
    public let identityToken: String; public let appleNonce: Data; public let publicBundle: AccountPublicKeyBundle; public let deviceProof: Data
    public init(identityToken: String, appleNonce: Data, publicBundle: AccountPublicKeyBundle, deviceProof: Data) throws {
        guard !identityToken.isEmpty, identityToken.utf8.count <= 16_384, appleNonce.count == 32, !appleNonce.allSatisfy({ $0 == 0 }), deviceProof.count == 64 else { throw AccountProtocolError.malformedWire }
        self.identityToken = identityToken; self.appleNonce = appleNonce; self.publicBundle = publicBundle; self.deviceProof = deviceProof
    }
}
public struct AccountRecoveryPreparationV1: Hashable, Sendable {
    public let authorization: AccountRecoveryAuthorization; public let historicalManifest: AccountBootstrapManifest; public let priorHistory: [AccountTrustHistoryEntryV1]
    public init(authorization: AccountRecoveryAuthorization, historicalManifest: AccountBootstrapManifest, priorHistory: [AccountTrustHistoryEntryV1]) throws {
        guard !priorHistory.isEmpty, priorHistory.count <= 352 else { throw AccountProtocolError.invalidTransition }
        for index in priorHistory.indices {
            let commit = priorHistory[index].commit
            guard commit.state.accountID == authorization.accountID else { throw AccountProtocolError.invalidTransition }
            if index == priorHistory.startIndex {
                guard commit.state.transition.kind == .genesis, commit.state.previousCommitDigest == nil else { throw AccountProtocolError.invalidTransition }
            } else {
                let previous = priorHistory[priorHistory.index(before: index)].commit
                guard commit.state.previousCommitDigest == AccountTranscript.trustCommitDigest(previous) else { throw AccountProtocolError.invalidTransition }
                if commit.state.epoch == previous.state.epoch {
                    guard previous.state.revision.value < UInt64.max, commit.state.revision.value == previous.state.revision.value + 1 else { throw AccountProtocolError.invalidTransition }
                } else {
                    guard previous.state.epoch.value < UInt64.max, commit.state.epoch.value == previous.state.epoch.value + 1, commit.state.revision.value == 1, commit.state.transition.kind == .recovery else { throw AccountProtocolError.invalidTransition }
                }
            }
        }
        guard let head = priorHistory.last, AccountTranscript.trustCommitDigest(head.commit) == authorization.priorCommitDigest else { throw AccountProtocolError.invalidTransition }
        self.authorization = authorization; self.historicalManifest = historicalManifest; self.priorHistory = priorHistory
    }
}
public struct AccountRecoveryCommitRequestV1: Hashable, Sendable {
    public let authorizationID: AccountAuthorizationID; public let requestNonce: Data; public let entry: AccountTrustHistoryEntryV1; public let deviceProof: Data
    public init(authorizationID: AccountAuthorizationID, requestNonce: Data, entry: AccountTrustHistoryEntryV1, deviceProof: Data) throws {
        guard requestNonce.count == 32, !requestNonce.allSatisfy({ $0 == 0 }), deviceProof.count == 64,
              entry.commit.state.transition.kind == .recovery,
              entry.evidence?.recoveryAuthorizationID == authorizationID
        else { throw AccountProtocolError.malformedWire }
        self.authorizationID = authorizationID; self.requestNonce = requestNonce; self.entry = entry; self.deviceProof = deviceProof
    }
}
public struct AccountRecoveryActivationV1: Hashable, Sendable {
    public let acceptedEntry: AccountTrustHistoryEntryV1; public let accessToken: String; public let accessExpiresAt: String; public let refreshCredential: Data; public let offlineLease: String; public let offlineLeaseExpiresAt: String
    public init(acceptedEntry: AccountTrustHistoryEntryV1, accessToken: String, accessExpiresAt: String, refreshCredential: Data, offlineLease: String, offlineLeaseExpiresAt: String) throws {
        guard acceptedEntry.commit.state.transition.kind == .recovery, !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              refreshCredential.count == 32, !offlineLease.isEmpty, offlineLease.utf8.count <= 32_768,
              let accessExpiry = AccountWireCodec.parseTimestamp(accessExpiresAt), let leaseExpiry = AccountWireCodec.parseTimestamp(offlineLeaseExpiresAt), accessExpiry < leaseExpiry
        else { throw AccountProtocolError.malformedWire }
        self.acceptedEntry = acceptedEntry; self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt; self.refreshCredential = refreshCredential; self.offlineLease = offlineLease; self.offlineLeaseExpiresAt = offlineLeaseExpiresAt
    }
}

private extension AccountTrustTransitionEvidenceV1 {
    var recoveryAuthorizationID: AccountAuthorizationID? {
        if case .recovery(let evidence) = self { return evidence.authorization.authorizationID }
        return nil
    }
}
