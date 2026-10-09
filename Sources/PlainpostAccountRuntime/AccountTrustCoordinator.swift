import CryptoKit
import Foundation
import PlainpostAccountProtocol

public typealias AccountTrustAdmissionEvidence = AccountTrustAdmissionEvidenceV1
public typealias AccountTrustRecoveryEvidence = AccountTrustRecoveryEvidenceV1

public struct AccountPreparedTrustActivation: Sendable {
    let entries: [AccountTrustHistoryEntryV1]
    let material: AccountTrustKeyMaterial
}

struct AccountTrustAuthorizationContext: Sendable {
    let admissions: [AccountTrustAdmissionEvidenceV1]
    let recoveries: [AccountTrustRecoveryEvidenceV1]

    init(
        admissions: [AccountTrustAdmissionEvidenceV1] = [],
        recoveries: [AccountTrustRecoveryEvidenceV1] = []
    ) {
        self.admissions = admissions
        self.recoveries = recoveries
    }

    static let empty = AccountTrustAuthorizationContext()
}

/// Device-local coordinator for the signed account trust chain. The central
/// service can relay inputs, but every state/package/record decision is made
/// only after exact transcript and device-signature verification here.
public actor AccountTrustCoordinator {
    private struct Approval: Sendable {
        let pending: PendingAccountDevice
        let offer: TrustHandshakeOfferV1
    }

    private struct Coordinate: Hashable, Sendable {
        let epoch: UInt64
        let revision: UInt64
        init(_ state: AccountTrustState) { epoch = state.epoch.value; revision = state.revision.value }
        init(epoch: UInt64, revision: UInt64) { self.epoch = epoch; self.revision = revision }
    }

    private let accountID: PlainpostAccountID
    private let deviceID: AccountDeviceID
    private let platform: AccountPlatform
    private let deviceIdentity: AccountDeviceIdentity
    private let trustStore: AccountTrustStore
    private let offlineRootKeyID: String
    private let offlineRootPublicKey: Data
    private let now: @Sendable () -> Date
    private let random: @Sendable (Int) throws -> Data
    private var approval: Approval?
    private var current: AccountTrustStateCommit?
    private var knownCommits: [Coordinate: AccountTrustStateCommit] = [:]
    private var storeState: AccountTrustStoreState?
    private var materials: [AccountTrustMaterialCoordinate: AccountTrustKeyMaterial] = [:]
    private var verifiedEntries: [AccountTrustHistoryEntryV1] = []
    private var authorityStates: [Coordinate: AccountTrustState] = [:]

    public init(
        accountID: PlainpostAccountID,
        deviceID: AccountDeviceID,
        platform: AccountPlatform,
        deviceIdentity: AccountDeviceIdentity,
        trustStore: AccountTrustStore,
        initialCommit: AccountTrustStateCommit? = nil,
        offlineRootKeyID: String = BootstrapKeyManifestStore.bundledOfflineRootKeyID,
        offlineRootPublicKey: Data = BootstrapKeyManifestStore.bundledOfflineRootPublicKey,
        now: @escaping @Sendable () -> Date = Date.init,
        random: @escaping @Sendable (Int) throws -> Data = AccountAPIClient.secureRandom
    ) throws {
        self.accountID = accountID
        self.deviceID = deviceID
        self.platform = platform
        self.deviceIdentity = deviceIdentity
        self.trustStore = trustStore
        guard AccountWireCodec.isKeyID(offlineRootKeyID),
              (try? P256.Signing.PublicKey(x963Representation: offlineRootPublicKey)) != nil
        else { throw AccountRuntimeError.untrustedResponse }
        self.offlineRootKeyID = offlineRootKeyID
        self.offlineRootPublicKey = offlineRootPublicKey
        self.now = now
        self.random = random
        storeState = try trustStore.loadState(for: accountID)
        if let restored = storeState {
            current = restored.currentCommit
            knownCommits[Coordinate(restored.currentCommit.state)] = restored.currentCommit
            materials = restored.materials
            verifiedEntries = restored.verifiedEntries
            authorityStates = Dictionary(uniqueKeysWithValues: restored.verifiedCommits.map { (Coordinate($0.state), $0.state) })
            if let initialCommit {
                guard AccountTranscript.trustCommitDigest(initialCommit) == restored.checkpoint.commitDigest else { throw AccountProtocolError.equivocation }
            }
        } else if let initialCommit {
            guard initialCommit.state.accountID == accountID else { throw AccountProtocolError.invalidTransition }
            try Self.verifyCommit(
                initialCommit,
                predecessor: nil,
                authorizationContext: .empty,
                offlineRootKeyID: offlineRootKeyID,
                offlineRootPublicKey: offlineRootPublicKey
            )
            current = initialCommit
            knownCommits[Coordinate(initialCommit.state)] = initialCommit
            verifiedEntries = [try AccountTrustHistoryEntryV1(commit: initialCommit, evidence: nil)]
            authorityStates[Coordinate(initialCommit.state)] = initialCommit.state
        }
    }

    public func beginApproval(of pending: PendingAccountDevice) throws -> TrustHandshakeOfferV1 {
        try trustStore.withAccountFence(for: accountID) { try beginApprovalUnfenced(of: pending) }
    }

    private func beginApprovalUnfenced(of pending: PendingAccountDevice) throws -> TrustHandshakeOfferV1 {
        try reconcilePersistedState()
        guard pending.accountID == accountID,
              pending.deviceID != deviceID,
              pending.platform != .syncNode,
              pending.publicBundle != deviceIdentity.publicBundle,
              let created = AccountWireCodec.parseTimestamp(pending.createdAt),
              let expiry = AccountWireCodec.parseTimestamp(pending.expiresAt),
              created < expiry,
              expiry.timeIntervalSince(created) <= 300,
              now() >= created,
              now() < expiry
        else { throw AccountProtocolError.invalidTrustHandshake }
        let nonce = try random(32)
        guard nonce.count == 32 else { throw AccountRuntimeError.cryptographicFailure }
        // Pending-device timestamps are issued by Central. Anchoring the offer
        // to that authenticated creation time avoids rejecting a valid offer
        // when the approving device clock is a few milliseconds ahead of the
        // Central clock; the strict pending lifetime and expiry checks remain
        // unchanged.
        let createdMilliseconds = try Self.milliseconds(created)
        let pendingExpiryMilliseconds = try Self.milliseconds(expiry)
        let (latestAllowedExpiry, overflow) = createdMilliseconds.value.addingReportingOverflow(300_000)
        guard !overflow else { throw AccountProtocolError.invalidTimestamp }
        let cappedExpiry = min(pendingExpiryMilliseconds.value, latestAllowedExpiry)
        let expiresMilliseconds = try PositiveUInt64(cappedExpiry)
        let offer = try TrustHandshakeOfferV1(
            accountID: accountID,
            existingDeviceID: deviceID,
            pendingDeviceID: pending.deviceID,
            existingPublicBundle: deviceIdentity.publicBundle,
            pendingPublicBundle: pending.publicBundle,
            existingNonce: nonce,
            createdAtUnixMilliseconds: createdMilliseconds,
            expiresAtUnixMilliseconds: expiresMilliseconds
        )
        approval = Approval(pending: pending, offer: offer)
        return offer
    }

    public func authenticationString(for response: TrustHandshakeResponseV1) throws -> String {
        try trustStore.withAccountFence(for: accountID) { try authenticationStringUnfenced(for: response) }
    }

    private func authenticationStringUnfenced(for response: TrustHandshakeResponseV1) throws -> String {
        guard let approval else { throw AccountProtocolError.invalidTrustHandshake }
        do {
            _ = try validate(response, against: approval)
            return try AccountTrustAuthentication.authenticationString(for: response)
        } catch {
            self.approval = nil
            throw error
        }
    }

    /// Consumes the pending approval once. A cancelled/mismatched confirmation
    /// clears its nonces just like a successful confirmation.
    public func approve(_ response: TrustHandshakeResponseV1, authenticationConfirmed: Bool) throws -> AccountTrustStateV1 {
        try trustStore.withAccountFence(for: accountID) {
            let candidate = try makeAdmissionCandidateUnfenced(response, authenticationConfirmed: authenticationConfirmed)
            try acceptHistoryEntriesUnfenced([candidate])
            return candidate.commit.state
        }
    }

    /// Consumes the one-time approval and constructs the exact signed successor
    /// without publishing it locally. The caller must first obtain central
    /// acceptance, verify the returned history entry byte-for-byte, and only
    /// then install that returned entry with `acceptHistory`.
    public func makeAdmissionCandidate(_ response: TrustHandshakeResponseV1, authenticationConfirmed: Bool) throws -> AccountTrustHistoryEntryV1 {
        try trustStore.withAccountFence(for: accountID) {
            try makeAdmissionCandidateUnfenced(response, authenticationConfirmed: authenticationConfirmed)
        }
    }

    private func makeAdmissionCandidateUnfenced(_ response: TrustHandshakeResponseV1, authenticationConfirmed: Bool) throws -> AccountTrustHistoryEntryV1 {
        try reconcilePersistedState()
        guard let activeApproval = approval else { throw AccountProtocolError.invalidTrustHandshake }
        approval = nil
        let live = try validate(response, against: activeApproval)
        guard authenticationConfirmed else { throw AccountProtocolError.invalidTrustHandshake }
        guard let predecessor = current, let material = material(for: predecessor.state) else { throw AccountProtocolError.invalidTransition }
        guard knownCommits[Coordinate(predecessor.state)] == predecessor else { throw AccountProtocolError.invalidTransition }
        guard predecessor.state.accountID == accountID,
              predecessor.state.members.contains(where: { $0.deviceID == deviceID && $0.publicBundle == deviceIdentity.publicBundle }),
              material.accountID == accountID,
              material.epoch == predecessor.state.epoch,
              material.keyGeneration == predecessor.state.keyGeneration,
              material.commitment == predecessor.state.keyCommitment
        else { throw AccountProtocolError.invalidTransition }

        let nextRevision = try Self.increment(predecessor.state.revision)
        let pendingDigest = Self.digest(AccountTranscript.pendingDeviceAuthorization(live.pending))
        let handshakeDigest = AccountTrustAuthentication.handshakeDigest(response)
        let transition = try AccountTrustTransition(
            kind: .admission,
            targetDeviceIDs: [live.pending.deviceID],
            priorRecordDigests: [],
            handshakeDigest: handshakeDigest,
            pendingDeviceDigest: pendingDigest
        )
        let unsignedRecord = try AccountDeviceTrustRecord(
            accountID: accountID,
            epoch: predecessor.state.epoch,
            revision: nextRevision,
            deviceID: live.pending.deviceID,
            platform: live.pending.platform,
            publicBundle: live.pending.publicBundle,
            signerDeviceID: deviceID,
            signature: Self.placeholderSignature
        )
        let admitted = try Self.signRecord(unsignedRecord, with: deviceIdentity)
        let members = (predecessor.state.members + [admitted]).sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
        let unsignedState = try AccountTrustState(
            accountID: accountID,
            epoch: predecessor.state.epoch,
            revision: nextRevision,
            previousCommitDigest: AccountTranscript.trustCommitDigest(predecessor),
            transition: transition,
            keyGeneration: predecessor.state.keyGeneration,
            keyCommitment: predecessor.state.keyCommitment,
            members: members,
            signerDeviceID: deviceID,
            signature: Self.placeholderSignature
        )
        let state = try Self.signState(unsignedState, with: deviceIdentity)
        let commit = try makeCommit(state: state, material: material)
        return try AccountTrustHistoryEntryV1(
            commit: commit,
            evidence: .admission(AccountTrustAdmissionEvidence(pendingDevice: live.pending, response: response))
        )
    }

    /// Returns the only transferable trust unit: a signed state plus its full,
    /// sorted package set. Standalone state/package acceptance is not exposed.
    public func currentTrustCommit() throws -> TrustStateCommitV1? {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            return current
        }
    }

    /// Builds the only local trust successor valid for a Sync Node admission.
    /// Sync Nodes intentionally bypass generic Apple-device rendezvous, but the
    /// resulting trust commit is still signed, package-complete, and bound to
    /// the canonical node-admission evidence before Central can accept it.
    public func makeSyncNodeEnrollmentCommit(
        evidence: AccountNodeEnrollmentAdmissionEvidenceV1
    ) throws -> AccountTrustStateCommit {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            guard let predecessor = current,
                  let material = material(for: predecessor.state)
            else { throw AccountProtocolError.invalidTransition }
            return try makeSyncNodeEnrollmentCommitUnfenced(
                evidence: evidence,
                predecessor: predecessor,
                material: material
            )
        }
    }

    /// Installs the exact locally prepared Sync Node successor only after
    /// Central has returned a verified admission result. Generic trust-history
    /// decoding cannot substitute for this path because Sync Node evidence is
    /// deliberately not a generic Apple admission or recovery evidence kind.
    public func acceptSyncNodeEnrollmentCommit(
        _ commit: AccountTrustStateCommit,
        evidence: AccountNodeEnrollmentAdmissionEvidenceV1
    ) throws {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            // Completion-journal recovery can resume after the exact
            // successor was installed but before its journal was deleted.
            // Re-accepting that identical signed commit is therefore safe.
            if current == commit { return }
            guard let predecessor = current,
                  let material = material(for: predecessor.state)
            else { throw AccountProtocolError.invalidTransition }
            try validateSyncNodeEnrollmentCommit(
                commit,
                evidence: evidence,
                predecessor: predecessor,
                material: material
            )
            try installAccepted(commit, evidence: .syncNodeEnrollment(evidence))
        }
    }

    private func makeSyncNodeEnrollmentCommitUnfenced(
        evidence: AccountNodeEnrollmentAdmissionEvidenceV1,
        predecessor: AccountTrustStateCommit,
        material: AccountTrustKeyMaterial
    ) throws -> AccountTrustStateCommit {
        try validateSyncNodeEnrollmentEvidence(evidence, predecessor: predecessor, material: material)
        let revision = try Self.increment(predecessor.state.revision)
        let publicBundle = try AccountPublicKeyBundle(
            signingKey: evidence.signingPublicKey,
            agreementKey: evidence.agreementPublicKey
        )
        let resigned = try predecessor.state.members.compactMap { member -> AccountDeviceTrustRecord? in
            if evidence.action == .replace, member.deviceID == evidence.replacedNodeID { return nil }
            let unsigned = try AccountDeviceTrustRecord(
                accountID: accountID,
                epoch: predecessor.state.epoch,
                revision: revision,
                deviceID: member.deviceID,
                platform: member.platform,
                publicBundle: member.publicBundle,
                signerDeviceID: deviceID,
                signature: Self.placeholderSignature
            )
            return try Self.signRecord(unsigned, with: deviceIdentity)
        }
        let nodeUnsigned = try AccountDeviceTrustRecord(
            accountID: accountID,
            epoch: predecessor.state.epoch,
            revision: revision,
            deviceID: evidence.nodeDeviceID,
            platform: .syncNode,
            publicBundle: publicBundle,
            signerDeviceID: deviceID,
            signature: Self.placeholderSignature
        )
        let members = try (resigned + [Self.signRecord(nodeUnsigned, with: deviceIdentity)])
            .sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
        let transition: AccountTrustTransition
        switch evidence.action {
        case .enroll:
            let evidenceDigest = Self.digest(try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(evidence))
            transition = try AccountTrustTransition(
                kind: .admission,
                targetDeviceIDs: [evidence.nodeDeviceID],
                priorRecordDigests: [],
                handshakeDigest: evidence.matchingTranscriptDigest,
                pendingDeviceDigest: evidenceDigest
            )
        case .replace:
            guard let replacedNodeID = evidence.replacedNodeID,
                  let removed = predecessor.state.members.first(where: { $0.deviceID == replacedNodeID })
            else { throw AccountProtocolError.invalidTransition }
            transition = try AccountTrustTransition(
                kind: .revocation,
                targetDeviceIDs: [replacedNodeID],
                priorRecordDigests: [try AccountPriorRecordDigest(
                    deviceID: replacedNodeID,
                    recordDigest: Self.digest(AccountTranscript.signedTrustRecord(removed))
                )]
            )
        }
        let unsignedState = try AccountTrustState(
            accountID: accountID,
            epoch: predecessor.state.epoch,
            revision: revision,
            previousCommitDigest: AccountTranscript.trustCommitDigest(predecessor),
            transition: transition,
            keyGeneration: predecessor.state.keyGeneration,
            keyCommitment: predecessor.state.keyCommitment,
            members: members,
            signerDeviceID: deviceID,
            signature: Self.placeholderSignature
        )
        return try makeCommit(state: Self.signState(unsignedState, with: deviceIdentity), material: material)
    }

    private func validateSyncNodeEnrollmentEvidence(
        _ evidence: AccountNodeEnrollmentAdmissionEvidenceV1,
        predecessor: AccountTrustStateCommit,
        material: AccountTrustKeyMaterial
    ) throws {
        let previousDigest = AccountTranscript.trustCommitDigest(predecessor)
        guard platform != .syncNode,
              predecessor.state.accountID == accountID,
              predecessor.state.epoch == evidence.trustEpoch,
              predecessor.state.members.contains(where: { $0.deviceID == deviceID && $0.publicBundle == deviceIdentity.publicBundle }),
              material.accountID == accountID,
              material.epoch == predecessor.state.epoch,
              material.keyGeneration == predecessor.state.keyGeneration,
              material.commitment == predecessor.state.keyCommitment,
              evidence.accountID == accountID,
              evidence.approverDeviceID == deviceID,
              evidence.stepUp.accountID == accountID,
              evidence.stepUp.actorDeviceID == deviceID,
              evidence.stepUp.currentCommitDigest == previousDigest,
              evidence.nodeDeviceID != deviceID
        else { throw AccountProtocolError.invalidTransition }
        switch evidence.action {
        case .enroll:
            guard evidence.replacedNodeID == nil,
                  evidence.stepUp.action == .enrollSyncNode,
                  evidence.stepUp.targetDeviceID == evidence.nodeDeviceID,
                  !predecessor.state.members.contains(where: { $0.platform == .syncNode || $0.deviceID == evidence.nodeDeviceID })
            else { throw AccountProtocolError.invalidTransition }
        case .replace:
            guard let replacedNodeID = evidence.replacedNodeID,
                  replacedNodeID != evidence.nodeDeviceID,
                  evidence.stepUp.action == .replaceSyncNode,
                  evidence.stepUp.targetDeviceID == replacedNodeID,
                  predecessor.state.members.first(where: { $0.deviceID == replacedNodeID })?.platform == .syncNode,
                  !predecessor.state.members.contains(where: { $0.deviceID == evidence.nodeDeviceID })
            else { throw AccountProtocolError.invalidTransition }
        }
    }

    private func validateSyncNodeEnrollmentCommit(
        _ commit: AccountTrustStateCommit,
        evidence: AccountNodeEnrollmentAdmissionEvidenceV1,
        predecessor: AccountTrustStateCommit,
        material: AccountTrustKeyMaterial
    ) throws {
        try validateSyncNodeEnrollmentEvidence(evidence, predecessor: predecessor, material: material)
        let state = commit.state
        let expectedRevision = try Self.increment(predecessor.state.revision)
        guard state.accountID == accountID,
              state.epoch == predecessor.state.epoch,
              state.revision == expectedRevision,
              state.previousCommitDigest == AccountTranscript.trustCommitDigest(predecessor),
              state.keyGeneration == predecessor.state.keyGeneration,
              state.keyCommitment == predecessor.state.keyCommitment,
              state.signerDeviceID == deviceID,
              commit.keyPackages.count == state.members.count,
              commit.keyPackages.map(\.recipientDeviceID) == state.members.map(\.deviceID)
        else { throw AccountProtocolError.invalidTransition }
        switch evidence.action {
        case .enroll:
            guard state.transition.kind == .admission,
                  state.transition.targetDeviceIDs == [evidence.nodeDeviceID],
                  state.members.count == predecessor.state.members.count + 1
            else { throw AccountProtocolError.invalidTransition }
        case .replace:
            guard let replacedNodeID = evidence.replacedNodeID,
                  state.transition.kind == .revocation,
                  state.transition.targetDeviceIDs == [replacedNodeID],
                  !state.members.contains(where: { $0.deviceID == replacedNodeID }),
                  state.members.count == predecessor.state.members.count
            else { throw AccountProtocolError.invalidTransition }
        }
        let node = state.members.first { $0.deviceID == evidence.nodeDeviceID }
        guard node?.platform == .syncNode,
              node?.publicBundle.signingKey == evidence.signingPublicKey,
              node?.publicBundle.agreementKey == evidence.agreementPublicKey,
              state.members.allSatisfy({ $0.epoch == state.epoch && $0.revision == state.revision && $0.signerDeviceID == deviceID }),
              state.members.allSatisfy({ (try? Self.verifySignature(publicKey: deviceIdentity.publicBundle.signingKey, transcript: AccountTranscript.trustRecord($0), signature: $0.signature)) != nil }),
              (try? Self.verifySignature(publicKey: deviceIdentity.publicBundle.signingKey, transcript: AccountTranscript.trustState(state), signature: state.signature)) != nil
        else { throw AccountProtocolError.invalidTransition }
        let stateDigest = Self.digest(AccountTranscript.signedTrustState(state))
        guard commit.keyPackages.allSatisfy({
            $0.accountID == accountID &&
                $0.epoch == state.epoch &&
                $0.stateRevision == state.revision &&
                $0.keyGeneration == state.keyGeneration &&
                $0.keyCommitment == state.keyCommitment &&
                $0.stateDigest == stateDigest &&
                $0.senderDeviceID == deviceID &&
                (try? Self.verifySignature(publicKey: deviceIdentity.publicBundle.signingKey, transcript: AccountTranscript.groupKeyPackage($0, encryptedDigest: Self.digest($0.nonce + $0.encryptedKeyMaterial)), signature: $0.signature)) != nil
        }) else { throw AccountProtocolError.invalidTransition }
        guard let opened = try openMaterialIfRecipient(from: commit),
              opened.accountID == material.accountID,
              opened.epoch == material.epoch,
              opened.keyGeneration == material.keyGeneration,
              opened.mailboxMatchingKey == material.mailboxMatchingKey,
              opened.metadataKey == material.metadataKey
        else { throw AccountProtocolError.invalidTransition }
    }

    public func currentTrustHistoryEntry() throws -> AccountTrustHistoryEntryV1? {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            return verifiedEntries.last
        }
    }

    func preparedTrustActivation() throws -> AccountPreparedTrustActivation {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            guard let current,
                  let material = material(for: current.state),
                  verifiedEntries.last?.commit == current,
                  current.state.members.contains(where: { $0.deviceID == deviceID && $0.publicBundle == deviceIdentity.publicBundle })
            else { throw AccountRuntimeError.untrustedResponse }
            return AccountPreparedTrustActivation(entries: verifiedEntries, material: material)
        }
    }

    /// Verifies the exact recovery entry returned by central and decrypts its
    /// replacement package without publishing either one. The credential
    /// store journals this prepared value before atomically advancing local
    /// trust and the replacement session.
    func prepareRecoveryActivation(_ accepted: AccountTrustHistoryEntryV1) throws -> AccountPreparedTrustActivation {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            guard let predecessor = current,
                  accepted.commit.state.transition.kind == .recovery,
                  accepted.commit.state.previousCommitDigest == AccountTranscript.trustCommitDigest(predecessor),
                  case .recovery(let evidence)? = accepted.evidence
            else { throw AccountRuntimeError.untrustedResponse }
            try Self.verifyCommit(
                accepted.commit,
                predecessor: predecessor,
                authorizationContext: AccountTrustAuthorizationContext(recoveries: [evidence]),
                offlineRootKeyID: offlineRootKeyID,
                offlineRootPublicKey: offlineRootPublicKey
            )
            guard let material = try openMaterialIfRecipient(from: accepted.commit) else { throw AccountRuntimeError.untrustedResponse }
            return AccountPreparedTrustActivation(entries: [accepted], material: material)
        }
    }

    /// Preflights the complete supplied page, including all admission/recovery
    /// evidence, before the first persistent write. Persistence then advances
    /// one verified commit at a time; a crash can retain only a valid prefix,
    /// which is safely resumable from the atomic local head.
    func acceptHistory(
        _ commits: [TrustStateCommitV1],
        authorizationContext: AccountTrustAuthorizationContext = .empty
    ) throws {
        try trustStore.withAccountFence(for: accountID) {
            try acceptHistoryUnfenced(commits, authorizationContext: authorizationContext)
        }
    }

    private func acceptHistoryUnfenced(
        _ commits: [TrustStateCommitV1],
        authorizationContext: AccountTrustAuthorizationContext
    ) throws {
        try reconcilePersistedState()
        guard !commits.isEmpty, commits.count <= 32 else { throw AccountProtocolError.malformedWire }
        var predecessor = current
        var pending: [(TrustStateCommitV1, AccountTrustTransitionEvidenceV1?)] = []
        for commit in commits {
            guard commit.state.accountID == accountID else { throw AccountProtocolError.invalidTransition }
            let incomingCoordinate = Coordinate(commit.state)
            if let predecessor {
                let predecessorCoordinate = Coordinate(predecessor.state)
                if incomingCoordinate == predecessorCoordinate {
                    guard AccountTranscript.trustCommitDigest(commit) == AccountTranscript.trustCommitDigest(predecessor) else { throw AccountProtocolError.equivocation }
                    continue
                }
                guard incomingCoordinate.epoch > predecessorCoordinate.epoch ||
                    (incomingCoordinate.epoch == predecessorCoordinate.epoch && incomingCoordinate.revision > predecessorCoordinate.revision)
                else { throw AccountProtocolError.rollback }
            }
            try Self.verifyCommit(
                commit,
                predecessor: predecessor,
                authorizationContext: authorizationContext,
                offlineRootKeyID: offlineRootKeyID,
                offlineRootPublicKey: offlineRootPublicKey
            )
            _ = try openMaterialIfRecipient(from: commit)
            predecessor = commit
            pending.append((commit, Self.transitionEvidence(for: commit, context: authorizationContext)))
        }
        for (commit, evidence) in pending {
            try installAccepted(commit, evidence: evidence)
        }
    }

    public func acceptHistory(_ entries: [AccountTrustHistoryEntryV1]) throws {
        try trustStore.withAccountFence(for: accountID) { try acceptHistoryEntriesUnfenced(entries) }
    }

    /// Reconciles Central's complete recovery history with an already trusted
    /// local prefix. Recovery may be retried after the local trust head was
    /// persisted, so replay begins after the exact local head rather than at
    /// genesis. A missing or divergent local head still fails closed.
    func acceptRecoveryHistory(_ entries: [AccountTrustHistoryEntryV1]) throws {
        try trustStore.withAccountFence(for: accountID) {
            try reconcilePersistedState()
            guard !entries.isEmpty, entries.count <= 352 else {
                throw AccountProtocolError.malformedWire
            }

            let firstUntrustedIndex: Int
            if let current {
                let currentCoordinate = Coordinate(current.state)
                guard let localHeadIndex = entries.firstIndex(where: {
                    Coordinate($0.commit.state) == currentCoordinate
                }) else {
                    throw AccountProtocolError.rollback
                }
                guard AccountTranscript.trustCommitDigest(entries[localHeadIndex].commit)
                    == AccountTranscript.trustCommitDigest(current)
                else { throw AccountProtocolError.equivocation }
                firstUntrustedIndex = localHeadIndex + 1
            } else {
                firstUntrustedIndex = entries.startIndex
            }

            for start in stride(from: firstUntrustedIndex, to: entries.endIndex, by: 32) {
                let end = min(start + 32, entries.endIndex)
                try acceptHistoryEntriesUnfenced(Array(entries[start..<end]))
            }
        }
    }

    private func acceptHistoryEntriesUnfenced(_ entries: [AccountTrustHistoryEntryV1]) throws {
        try reconcilePersistedState()
        guard !entries.isEmpty, entries.count <= 32 else { throw AccountProtocolError.malformedWire }
        var predecessor = current
        var pending: [AccountTrustHistoryEntryV1] = []
        for entry in entries {
            let commit = entry.commit
            guard commit.state.accountID == accountID else { throw AccountProtocolError.invalidTransition }
            let incomingCoordinate = Coordinate(commit.state)
            if let predecessor {
                let predecessorCoordinate = Coordinate(predecessor.state)
                if incomingCoordinate == predecessorCoordinate {
                    guard AccountTranscript.trustCommitDigest(commit) == AccountTranscript.trustCommitDigest(predecessor) else { throw AccountProtocolError.equivocation }
                    continue
                }
                guard incomingCoordinate.epoch > predecessorCoordinate.epoch ||
                    (incomingCoordinate.epoch == predecessorCoordinate.epoch && incomingCoordinate.revision > predecessorCoordinate.revision)
                else { throw AccountProtocolError.rollback }
            }
            if case .syncNodeEnrollment(let evidence) = entry.evidence {
                guard let predecessor,
                      let material = material(for: predecessor.state)
                else { throw AccountProtocolError.invalidTransition }
                try validateSyncNodeEnrollmentCommit(
                    commit,
                    evidence: evidence,
                    predecessor: predecessor,
                    material: material
                )
            } else {
                let exactContext: AccountTrustAuthorizationContext
                switch entry.evidence {
                case .admission(let evidence): exactContext = AccountTrustAuthorizationContext(admissions: [evidence])
                case .recovery(let evidence): exactContext = AccountTrustAuthorizationContext(recoveries: [evidence])
                case .syncNodeEnrollment: throw AccountProtocolError.invalidTransition
                case nil: exactContext = .empty
                }
                try Self.verifyCommit(
                    commit,
                    predecessor: predecessor,
                    authorizationContext: exactContext,
                    offlineRootKeyID: offlineRootKeyID,
                    offlineRootPublicKey: offlineRootPublicKey
                )
            }
            _ = try openMaterialIfRecipient(from: commit)
            predecessor = commit
            pending.append(entry)
        }
        for entry in pending { try installAccepted(entry.commit, evidence: entry.evidence) }
    }

    public func accept(_ commit: TrustStateCommitV1) throws {
        try trustStore.withAccountFence(for: accountID) {
            try acceptHistoryUnfenced([commit], authorizationContext: .empty)
        }
    }

    public func logicalMailboxID(provider: String, accountIdentity: String) throws -> LogicalMailboxID {
        try trustStore.withAccountFence(for: accountID) {
            try logicalMailboxIDUnfenced(provider: provider, accountIdentity: accountIdentity)
        }
    }

    /// The logical mailbox every trusted device derives for a Direct account's Inbox, so a
    /// Mac producer and an iPhone that each sign in to the same IMAP account name the same
    /// mailbox without a Sync Node. It changes when the matching key rotates (a device
    /// revoked or suspended), after which both sides derive the new value.
    public func directInboxMailboxID(imapHost: String, email: String) throws -> LogicalMailboxID {
        try logicalMailboxID(provider: "direct-imap-inbox:" + imapHost, accountIdentity: email)
    }

    private func logicalMailboxIDUnfenced(provider: String, accountIdentity: String) throws -> LogicalMailboxID {
        try reconcilePersistedState()
        guard let current, let material = material(for: current.state) else { throw AccountProtocolError.invalidTransition }
        let normalizedProvider = try Self.normalize(provider, maximumBytes: 255)
        let normalizedIdentity = try Self.normalize(accountIdentity, maximumBytes: 1_024)
        let preimage = AccountTranscript.parts([
            Data("Plainpost.LogicalMailboxID.v1".utf8),
            Data(normalizedProvider.utf8),
            Data(normalizedIdentity.utf8),
        ])
        let digest = Data(HMAC<SHA256>.authenticationCode(for: preimage, using: SymmetricKey(data: material.mailboxMatchingKey)))
        guard let value = LogicalMailboxID(rawValue: digest) else { throw AccountRuntimeError.cryptographicFailure }
        return value
    }

    public func sealAccountRecord(id: AccountRecordID, plaintext: Data) throws -> EncryptedAccountRecordV1 {
        try trustStore.withAccountFence(for: accountID) { try sealAccountRecordUnfenced(id: id, plaintext: plaintext, commitHighWater: true) }
    }

    /// Produces an authenticated record for a remote compare-and-swap without
    /// advancing this device's received-record high water.  Callers must open
    /// the record that actually won remotely before treating it as committed.
    /// This prevents a failed upload from permanently excluding the winner.
    public func prepareAccountRecordForRemoteCAS(id: AccountRecordID, plaintext: Data) throws -> EncryptedAccountRecordV1 {
        try trustStore.withAccountFence(for: accountID) { try sealAccountRecordUnfenced(id: id, plaintext: plaintext, commitHighWater: false) }
    }

    private func sealAccountRecordUnfenced(id: AccountRecordID, plaintext: Data, commitHighWater: Bool) throws -> EncryptedAccountRecordV1 {
        try reconcilePersistedState()
        guard plaintext.count >= 1, plaintext.count <= 65_508,
              let current, let material = material(for: current.state)
        else { throw AccountProtocolError.invalidRecord }
        try validateLocalMaterial(material, for: current.state)
        let previous = try trustStore.loadRecordHighWater(accountID: accountID, recordID: id)
        let revision: PositiveUInt64
        if let previous {
            let generationOrdering = Self.compareRecordCoordinate(
                previous.epoch,
                previous.keyGeneration,
                try PositiveUInt64(1),
                material.epoch,
                material.keyGeneration,
                try PositiveUInt64(1)
            )
            guard generationOrdering <= 0 else { throw AccountProtocolError.rollback }
            revision = previous.epoch == material.epoch && previous.keyGeneration == material.keyGeneration
                ? try Self.increment(previous.recordRevision)
                : try PositiveUInt64(1)
        } else { revision = try PositiveUInt64(1) }
        guard let localMember = current.state.members.first(where: { $0.deviceID == deviceID }) else {
            throw AccountProtocolError.invalidRecord
        }
        let nonce = try trustStore.nextMetadataNonce(
            accountID: accountID,
            epoch: material.epoch,
            keyGeneration: material.keyGeneration,
            namespace: Self.metadataNonceNamespace(
                metadataKey: material.metadataKey,
                keyGeneration: material.keyGeneration,
                member: localMember
            )
        )
        let aad = AccountTrustTranscript.encryptedRecordAAD(accountID: accountID, recordID: id, epoch: material.epoch, keyGeneration: material.keyGeneration, trustRevision: current.state.revision, recordRevision: revision)
        let sealed: AES.GCM.SealedBox
        do { sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: material.metadataKey), nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad) }
        catch { throw AccountRuntimeError.cryptographicFailure }
        let envelope = nonce + sealed.ciphertext + sealed.tag
        let unsigned = try EncryptedAccountRecordV1(accountID: accountID, recordID: id, epoch: material.epoch, keyGeneration: material.keyGeneration, trustRevision: current.state.revision, recordRevision: revision, envelope: envelope, signerDeviceID: deviceID, signature: Self.placeholderSignature)
        let signature = try deviceIdentity.signature(for: AccountTrustTranscript.encryptedRecordSignature(unsigned, envelopeDigest: Self.digest(envelope)))
        let record = try EncryptedAccountRecordV1(accountID: unsigned.accountID, recordID: unsigned.recordID, epoch: unsigned.epoch, keyGeneration: unsigned.keyGeneration, trustRevision: unsigned.trustRevision, recordRevision: unsigned.recordRevision, envelope: unsigned.envelope, signerDeviceID: unsigned.signerDeviceID, signature: signature)
        if commitHighWater {
            try trustStore.saveRecordHighWater(try AccountRecordHighWater(epoch: record.epoch, keyGeneration: record.keyGeneration, recordRevision: record.recordRevision, envelopeDigest: Self.digest(record.envelope)), accountID: accountID, recordID: id)
        }
        return record
    }

    public func openAccountRecord(_ record: EncryptedAccountRecordV1) throws -> Data {
        try trustStore.withAccountFence(for: accountID) { try openAccountRecordUnfenced(record) }
    }

    private func openAccountRecordUnfenced(_ record: EncryptedAccountRecordV1) throws -> Data {
        try reconcilePersistedState()
        let materialCoordinate = AccountTrustMaterialCoordinate(epoch: record.epoch, keyGeneration: record.keyGeneration)
        guard record.accountID == accountID, let material = materials[materialCoordinate] else { throw AccountProtocolError.rollback }
        guard let state = authorityStates[Coordinate(epoch: record.epoch.value, revision: record.trustRevision.value)],
              state.keyGeneration == record.keyGeneration,
              state.keyCommitment == material.commitment,
              let signer = state.members.first(where: { $0.deviceID == record.signerDeviceID })
        else { throw AccountProtocolError.invalidRecord }
        try Self.verifySignature(publicKey: signer.publicBundle.signingKey, transcript: AccountTrustTranscript.encryptedRecordSignature(record, envelopeDigest: Self.digest(record.envelope)), signature: record.signature)
        let digest = Self.digest(record.envelope)
        if let highWater = try trustStore.loadRecordHighWater(accountID: accountID, recordID: record.recordID) {
            let ordering = Self.compareRecordCoordinate(record.epoch, record.keyGeneration, record.recordRevision, highWater.epoch, highWater.keyGeneration, highWater.recordRevision)
            if ordering < 0 { throw AccountProtocolError.rollback }
            if ordering == 0 && highWater.envelopeDigest != digest { throw AccountProtocolError.equivocation }
        }
        let nonce = Data(record.envelope.prefix(12))
        let ciphertext = Data(record.envelope.dropFirst(12).dropLast(16))
        let tag = Data(record.envelope.suffix(16))
        let aad = AccountTrustTranscript.encryptedRecordAAD(accountID: record.accountID, recordID: record.recordID, epoch: record.epoch, keyGeneration: record.keyGeneration, trustRevision: record.trustRevision, recordRevision: record.recordRevision)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: material.metadataKey), authenticating: aad)
        } catch { throw AccountRuntimeError.cryptographicFailure }
        try trustStore.saveRecordHighWater(try AccountRecordHighWater(epoch: record.epoch, keyGeneration: record.keyGeneration, recordRevision: record.recordRevision, envelopeDigest: digest), accountID: accountID, recordID: record.recordID)
        return plaintext
    }

    public func resealAccountRecordForCurrentGeneration(_ record: EncryptedAccountRecordV1) throws -> EncryptedAccountRecordV1 {
        try trustStore.withAccountFence(for: accountID) { try resealAccountRecordUnfenced(record) }
    }

    private func resealAccountRecordUnfenced(_ record: EncryptedAccountRecordV1) throws -> EncryptedAccountRecordV1 {
        try reconcilePersistedState()
        guard let current, let currentMaterial = material(for: current.state),
              record.accountID == accountID,
              record.epoch == currentMaterial.epoch,
              record.keyGeneration < currentMaterial.keyGeneration
        else { throw AccountProtocolError.invalidTransition }
        let plaintext = try openAccountRecordUnfenced(record)
        return try sealAccountRecordUnfenced(id: record.recordID, plaintext: plaintext, commitHighWater: true)
    }

    /// Retires a prior-generation key only after Task 7 freezes and signs the
    /// complete current-generation record inventory at the exact trust head.
    public func retireAccountKeyGeneration(
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        afterMigrating records: [EncryptedAccountRecordV1],
        inventoryProof: AccountRecordInventoryProofV1,
        manifestStore: BootstrapKeyManifestStore
    ) throws {
        try trustStore.withAccountFence(for: accountID) {
            try retireAccountKeyGenerationUnfenced(
                epoch: epoch,
                keyGeneration: keyGeneration,
                afterMigrating: records,
                inventoryProof: inventoryProof,
                manifestStore: manifestStore
            )
        }
    }

    private func retireAccountKeyGenerationUnfenced(
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        afterMigrating records: [EncryptedAccountRecordV1],
        inventoryProof: AccountRecordInventoryProofV1,
        manifestStore: BootstrapKeyManifestStore
    ) throws {
        try reconcilePersistedState()
        guard let current,
              let state = storeState,
              let currentMaterial = material(for: current.state),
              epoch == currentMaterial.epoch,
              keyGeneration < currentMaterial.keyGeneration,
              Set(records.map(\.recordID)).count == records.count,
              records.allSatisfy({
                  $0.accountID == accountID &&
                  $0.epoch == currentMaterial.epoch &&
                  $0.keyGeneration == currentMaterial.keyGeneration
              })
        else { throw AccountProtocolError.invalidTransition }
        try manifestStore.verifyRecordInventoryProof(
            inventoryProof,
            expectedAccountID: accountID,
            expectedTrustCommitDigest: AccountTranscript.trustCommitDigest(current),
            expectedEpoch: current.state.epoch,
            expectedKeyGeneration: current.state.keyGeneration
        )
        let exactEntries = try records.sorted { $0.recordID.rawValue < $1.recordID.rawValue }.map(Self.inventoryEntry)
        guard exactEntries == inventoryProof.entries else { throw AccountProtocolError.invalidTransition }
        if state.materialReferences.contains(where: { $0.epoch == epoch && $0.keyGeneration == keyGeneration }) == false { return }
        for record in records { _ = try openAccountRecordUnfenced(record) }
        let updated = try trustStore.retireMaterial(epoch: epoch, keyGeneration: keyGeneration, expected: state)
        restore(updated)
    }

    public func revoke(_ targetDeviceID: AccountDeviceID, suspended: Bool = false) throws -> TrustStateCommitV1 {
        try trustStore.withAccountFence(for: accountID) {
            let candidate = try makeRemovalCandidateUnfenced(targetDeviceID, suspended: suspended)
            try acceptHistoryEntriesUnfenced([candidate])
            return candidate.commit
        }
    }

    /// Constructs a signed removal candidate without changing local trust.
    /// The caller must submit it centrally, compare the returned history entry
    /// byte-for-byte, and only then install that accepted entry.
    public func makeRemovalCandidate(_ targetDeviceID: AccountDeviceID, suspended: Bool = false) throws -> AccountTrustHistoryEntryV1 {
        try trustStore.withAccountFence(for: accountID) {
            try makeRemovalCandidateUnfenced(targetDeviceID, suspended: suspended)
        }
    }

    private func makeRemovalCandidateUnfenced(_ targetDeviceID: AccountDeviceID, suspended: Bool) throws -> AccountTrustHistoryEntryV1 {
        try reconcilePersistedState()
        guard let predecessor = current, let material = material(for: predecessor.state), targetDeviceID != deviceID,
              predecessor.state.members.count > 1,
              let removed = predecessor.state.members.first(where: { $0.deviceID == targetDeviceID })
        else { throw AccountProtocolError.invalidTransition }
        try validateLocalMaterial(material, for: predecessor.state)
        let transition = try AccountTrustTransition(kind: suspended ? .suspension : .revocation, targetDeviceIDs: [targetDeviceID], priorRecordDigests: [try AccountPriorRecordDigest(deviceID: targetDeviceID, recordDigest: Self.digest(AccountTranscript.signedTrustRecord(removed)))])
        let newMaterial = try freshMaterial(epoch: predecessor.state.epoch, keyGeneration: try Self.increment(predecessor.state.keyGeneration), trustRevision: try Self.increment(predecessor.state.revision))
        let unsignedState = try AccountTrustState(accountID: accountID, epoch: predecessor.state.epoch, revision: newMaterial.trustRevision, previousCommitDigest: AccountTranscript.trustCommitDigest(predecessor), transition: transition, keyGeneration: newMaterial.keyGeneration, keyCommitment: newMaterial.commitment, members: predecessor.state.members.filter { $0.deviceID != targetDeviceID }, signerDeviceID: deviceID, signature: Self.placeholderSignature)
        let state = try Self.signState(unsignedState, with: deviceIdentity)
        let commit = try makeCommit(state: state, material: newMaterial)
        return try AccountTrustHistoryEntryV1(commit: commit, evidence: nil)
    }

    /// Recovery creates an entirely new epoch and fresh account keys. The
    /// manifest verifier is required here, rather than trusted to a caller, so
    /// the replacement self-signature is bound to a live purpose-scoped server
    /// authorization before any local state changes.
    public func recover(
        with authorization: AccountRecoveryAuthorization,
        expectedExchangeRequestDigest: Data,
        manifestStore: BootstrapKeyManifestStore
    ) throws -> TrustStateCommitV1 {
        try trustStore.withAccountFence(for: accountID) {
            let candidate = try makeRecoveryCandidateUnfenced(
                with: authorization,
                expectedExchangeRequestDigest: expectedExchangeRequestDigest,
                manifestStore: manifestStore
            )
            try acceptHistoryEntriesUnfenced([candidate])
            return candidate.commit
        }
    }

    /// Constructs the fresh-epoch recovery entry without publishing it. The
    /// exact entry returned by the recovery endpoint is the only value that
    /// may subsequently be installed.
    public func makeRecoveryCandidate(
        with authorization: AccountRecoveryAuthorization,
        expectedExchangeRequestDigest: Data,
        manifestStore: BootstrapKeyManifestStore
    ) throws -> AccountTrustHistoryEntryV1 {
        try trustStore.withAccountFence(for: accountID) {
            try makeRecoveryCandidateUnfenced(
                with: authorization,
                expectedExchangeRequestDigest: expectedExchangeRequestDigest,
                manifestStore: manifestStore
            )
        }
    }

    private func makeRecoveryCandidateUnfenced(
        with authorization: AccountRecoveryAuthorization,
        expectedExchangeRequestDigest: Data,
        manifestStore: BootstrapKeyManifestStore
    ) throws -> AccountTrustHistoryEntryV1 {
        try reconcilePersistedState()
        guard expectedExchangeRequestDigest.count == 32 else { throw AccountProtocolError.invalidTransition }
        guard let predecessor = current,
              authorization.accountID == accountID,
              authorization.deviceID == deviceID,
              authorization.platform == platform,
              authorization.publicBundle == deviceIdentity.publicBundle,
              authorization.priorCommitDigest == AccountTranscript.trustCommitDigest(predecessor)
        else { throw AccountProtocolError.invalidTransition }
        let nextEpoch = try Self.increment(predecessor.state.epoch)
        guard authorization.epoch == nextEpoch else { throw AccountProtocolError.invalidTransition }
        let authorizingManifest = try manifestStore.verifyRecoveryAuthorization(
            authorization,
            expectedAccountID: accountID,
            expectedEpoch: nextEpoch,
            expectedDeviceID: deviceID,
            expectedPlatform: platform,
            expectedPublicBundle: deviceIdentity.publicBundle,
            expectedPriorCommitDigest: AccountTranscript.trustCommitDigest(predecessor),
            expectedExchangeRequestDigest: expectedExchangeRequestDigest
        )
        let epoch = authorization.epoch
        let revision = try PositiveUInt64(1)
        let keyGeneration = try PositiveUInt64(1)
        let targets = predecessor.state.members.map(\.deviceID).sorted { $0.rawValue < $1.rawValue }
        let priors = try predecessor.state.members.map { try AccountPriorRecordDigest(deviceID: $0.deviceID, recordDigest: Self.digest(AccountTranscript.signedTrustRecord($0))) }.sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
        let transition = try AccountTrustTransition(kind: .recovery, targetDeviceIDs: targets, priorRecordDigests: priors, recoveryAuthorizationDigest: AccountTranscript.recoveryAuthorizationDigest(authorization))
        let material = try freshMaterial(epoch: epoch, keyGeneration: keyGeneration, trustRevision: revision)
        let unsignedRecord = try AccountDeviceTrustRecord(accountID: accountID, epoch: epoch, revision: revision, deviceID: deviceID, platform: platform, publicBundle: deviceIdentity.publicBundle, signerDeviceID: deviceID, signature: Self.placeholderSignature)
        let replacement = try Self.signRecord(unsignedRecord, with: deviceIdentity)
        let unsignedState = try AccountTrustState(accountID: accountID, epoch: epoch, revision: revision, previousCommitDigest: AccountTranscript.trustCommitDigest(predecessor), transition: transition, keyGeneration: keyGeneration, keyCommitment: material.commitment, members: [replacement], signerDeviceID: deviceID, signature: Self.placeholderSignature)
        let state = try Self.signState(unsignedState, with: deviceIdentity)
        let commit = try makeCommit(state: state, material: material)
        return try AccountTrustHistoryEntryV1(
            commit: commit,
            evidence: .recovery(AccountTrustRecoveryEvidence(
                authorization: authorization,
                historicalManifest: authorizingManifest
            ))
        )
    }

    private func acceptVerified(
        _ commit: AccountTrustStateCommit,
        authorizationContext: AccountTrustAuthorizationContext
    ) throws {
        try acceptHistoryUnfenced([commit], authorizationContext: authorizationContext)
    }

    private func installAccepted(
        _ commit: AccountTrustStateCommit,
        evidence: AccountTrustTransitionEvidenceV1?
    ) throws {
        let opened = try openMaterialIfRecipient(from: commit)
        let entry = try AccountTrustHistoryEntryV1(commit: commit, evidence: evidence)
        let nextVerified: [AccountTrustHistoryEntryV1]
        if commit.state.transition.kind == .recovery {
            nextVerified = [entry]
        } else {
            let currentCoordinate = AccountTrustMaterialCoordinate(
                epoch: commit.state.epoch,
                keyGeneration: commit.state.keyGeneration
            )
            let retainedCoordinates = Set(materials.keys).union([currentCoordinate])
            nextVerified = (verifiedEntries + [entry]).filter {
                retainedCoordinates.contains(AccountTrustMaterialCoordinate(
                    epoch: $0.commit.state.epoch,
                    keyGeneration: $0.commit.state.keyGeneration
                ))
            }
        }
        let installed = try trustStore.installVerifiedCommit(
            commit,
            openedMaterial: opened,
            verifiedEntries: nextVerified,
            expected: storeState
        )
        restore(installed)
    }

    private func restore(_ state: AccountTrustStoreState) {
        storeState = state
        current = state.currentCommit
        materials = state.materials
        verifiedEntries = state.verifiedEntries
        knownCommits = [Coordinate(state.currentCommit.state): state.currentCommit]
        authorityStates = Dictionary(uniqueKeysWithValues: state.verifiedCommits.map { (Coordinate($0.state), $0.state) })
    }

    private func reconcilePersistedState() throws {
        guard let persisted = try trustStore.loadState(for: accountID) else {
            if storeState != nil { throw AccountRuntimeError.corruptSecret }
            return
        }
        if storeState?.headValue != persisted.headValue { restore(persisted) }
    }

    private func material(for state: AccountTrustState) -> AccountTrustKeyMaterial? {
        materials[AccountTrustMaterialCoordinate(epoch: state.epoch, keyGeneration: state.keyGeneration)]
    }

    private func validate(_ response: TrustHandshakeResponseV1, against approval: Approval) throws -> Approval {
        guard approval.offer == response.offer,
              now() < Self.date(milliseconds: approval.offer.expiresAtUnixMilliseconds),
              response.pendingNonce != response.offer.existingNonce
        else { throw AccountProtocolError.invalidTrustHandshake }
        return approval
    }

    private func makeCommit(state: AccountTrustState, material: AccountTrustKeyMaterial) throws -> AccountTrustStateCommit {
        try validateLocalMaterial(material, for: state)
        let stateDigest = Self.digest(AccountTranscript.signedTrustState(state))
        let packages = try state.members.map { member in try makePackage(state: state, stateDigest: stateDigest, recipient: member, material: material) }.sorted { $0.recipientDeviceID.rawValue < $1.recipientDeviceID.rawValue }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }

    private func makePackage(state: AccountTrustState, stateDigest: Data, recipient: AccountDeviceTrustRecord, material: AccountTrustKeyMaterial) throws -> AccountGroupKeyPackage {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared: SharedSecret
        do { shared = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: recipient.publicBundle.agreementKey)) }
        catch { throw AccountRuntimeError.cryptographicFailure }
        let info = AccountTrustTranscript.groupKeyPackageKDF(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: stateDigest, recipientDeviceID: recipient.deviceID, senderDeviceID: deviceID)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: stateDigest, sharedInfo: info, outputByteCount: 32)
        let nonce = try random(12)
        guard nonce.count == 12 else { throw AccountRuntimeError.cryptographicFailure }
        let aad = AccountTrustTranscript.groupKeyPackageAAD(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: recipient.deviceID, senderDeviceID: deviceID, senderEphemeralPublicKey: ephemeral.publicKey.x963Representation)
        let sealed: AES.GCM.SealedBox
        do { sealed = try AES.GCM.seal(material.combined, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad) }
        catch { throw AccountRuntimeError.cryptographicFailure }
        let encrypted = sealed.ciphertext + sealed.tag
        let unsigned = try AccountGroupKeyPackage(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: stateDigest, keyCommitment: state.keyCommitment, recipientDeviceID: recipient.deviceID, senderDeviceID: deviceID, senderEphemeralPublicKey: ephemeral.publicKey.x963Representation, nonce: nonce, encryptedKeyMaterial: encrypted, signature: Self.placeholderSignature)
        let signature = try deviceIdentity.signature(for: AccountTranscript.groupKeyPackage(unsigned, encryptedDigest: Self.digest(nonce + encrypted)))
        return try AccountGroupKeyPackage(accountID: unsigned.accountID, epoch: unsigned.epoch, stateRevision: unsigned.stateRevision, keyGeneration: unsigned.keyGeneration, stateDigest: unsigned.stateDigest, keyCommitment: unsigned.keyCommitment, recipientDeviceID: unsigned.recipientDeviceID, senderDeviceID: unsigned.senderDeviceID, senderEphemeralPublicKey: unsigned.senderEphemeralPublicKey, nonce: unsigned.nonce, encryptedKeyMaterial: unsigned.encryptedKeyMaterial, signature: signature)
    }

    private func openMaterialIfRecipient(from commit: AccountTrustStateCommit) throws -> AccountTrustKeyMaterial? {
        let state = commit.state
        guard let package = commit.keyPackages.first(where: { $0.recipientDeviceID == deviceID }) else {
            guard !state.members.contains(where: { $0.deviceID == deviceID }) else { throw AccountProtocolError.invalidTransition }
            return nil
        }
        let shared = try deviceIdentity.sharedSecret(with: package.senderEphemeralPublicKey)
        let info = AccountTrustTranscript.groupKeyPackageKDF(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: package.stateDigest, recipientDeviceID: deviceID, senderDeviceID: package.senderDeviceID)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: package.stateDigest, sharedInfo: info, outputByteCount: 32)
        let ciphertext = Data(package.encryptedKeyMaterial.dropLast(16))
        let tag = Data(package.encryptedKeyMaterial.suffix(16))
        let aad = AccountTrustTranscript.groupKeyPackageAAD(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: package.stateDigest, keyCommitment: package.keyCommitment, recipientDeviceID: deviceID, senderDeviceID: package.senderDeviceID, senderEphemeralPublicKey: package.senderEphemeralPublicKey)
        let material: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: package.nonce), ciphertext: ciphertext, tag: tag)
            material = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch { throw AccountRuntimeError.cryptographicFailure }
        guard material.count == 64, Self.digest(material) == state.keyCommitment else { throw AccountRuntimeError.cryptographicFailure }
        return try AccountTrustKeyMaterial(accountID: state.accountID, epoch: state.epoch, keyGeneration: state.keyGeneration, trustRevision: state.revision, mailboxMatchingKey: Data(material.prefix(32)), metadataKey: Data(material.suffix(32)))
    }

    private func freshMaterial(epoch: AccountTrustEpoch, keyGeneration: PositiveUInt64, trustRevision: PositiveUInt64) throws -> AccountTrustKeyMaterial {
        let data = try random(64)
        guard data.count == 64 else { throw AccountRuntimeError.cryptographicFailure }
        return try AccountTrustKeyMaterial(accountID: accountID, epoch: epoch, keyGeneration: keyGeneration, trustRevision: trustRevision, mailboxMatchingKey: Data(data.prefix(32)), metadataKey: Data(data.suffix(32)))
    }

    private func validateLocalMaterial(_ material: AccountTrustKeyMaterial, for state: AccountTrustState) throws {
        try Self.validateStoredMaterial(material, for: state)
    }

    private static func validateStoredMaterial(_ material: AccountTrustKeyMaterial, for state: AccountTrustState) throws {
        guard material.accountID == state.accountID,
              material.epoch == state.epoch,
              material.keyGeneration == state.keyGeneration,
              material.commitment == state.keyCommitment
        else { throw AccountProtocolError.invalidTransition }
    }

    private static func inventoryEntry(_ record: EncryptedAccountRecordV1) throws -> AccountRecordInventoryEntryV1 {
        try AccountRecordInventoryEntryV1(
            recordID: record.recordID,
            epoch: record.epoch,
            keyGeneration: record.keyGeneration,
            trustRevision: record.trustRevision,
            recordRevision: record.recordRevision,
            envelopeDigest: digest(record.envelope),
            signatureDigest: digest(record.signature)
        )
    }

    private static let placeholderSignature = Data(repeating: 1, count: 64)

    private static func signRecord(_ record: AccountDeviceTrustRecord, with identity: AccountDeviceIdentity) throws -> AccountDeviceTrustRecord {
        let signature = try identity.signature(for: AccountTranscript.trustRecord(record))
        return try AccountDeviceTrustRecord(accountID: record.accountID, epoch: record.epoch, revision: record.revision, deviceID: record.deviceID, platform: record.platform, publicBundle: record.publicBundle, signerDeviceID: record.signerDeviceID, signature: signature)
    }

    private static func signState(_ state: AccountTrustState, with identity: AccountDeviceIdentity) throws -> AccountTrustState {
        let signature = try identity.signature(for: AccountTranscript.trustState(state))
        return try AccountTrustState(accountID: state.accountID, epoch: state.epoch, revision: state.revision, previousCommitDigest: state.previousCommitDigest, transition: state.transition, keyGeneration: state.keyGeneration, keyCommitment: state.keyCommitment, members: state.members, signerDeviceID: state.signerDeviceID, signature: signature)
    }

    private static func verifyCommit(
        _ commit: AccountTrustStateCommit,
        predecessor: AccountTrustStateCommit?,
        authorizationContext: AccountTrustAuthorizationContext,
        offlineRootKeyID: String,
        offlineRootPublicKey: Data
    ) throws {
        let state = commit.state
        let packages = commit.keyPackages
        try validateActiveMemberPlatforms(state.members)
        let stateDigest = digest(AccountTranscript.signedTrustState(state))
        guard packages.count == state.members.count,
              packages.map(\.recipientDeviceID) == state.members.map(\.deviceID),
              packages.allSatisfy({ $0.stateDigest == stateDigest && $0.keyCommitment == state.keyCommitment && $0.senderDeviceID == state.signerDeviceID })
        else { throw AccountProtocolError.invalidTransition }
        switch state.transition.kind {
        case .genesis:
            guard predecessor == nil,
                  state.epoch.value == 1, state.revision.value == 1, state.keyGeneration.value == 1,
                  state.members.count == 1, let member = state.members.first,
                  member.deviceID == state.signerDeviceID, member.signerDeviceID == member.deviceID
            else { throw AccountProtocolError.invalidTransition }
            try verifySignature(publicKey: member.publicBundle.signingKey, transcript: AccountTranscript.trustRecord(member), signature: member.signature)
            try verifySignature(publicKey: member.publicBundle.signingKey, transcript: AccountTranscript.trustState(state), signature: state.signature)
        case .admission:
            guard let predecessor else { throw AccountProtocolError.invalidTransition }
            let expectedRevision = try increment(predecessor.state.revision)
            guard
                  state.accountID == predecessor.state.accountID,
                  state.epoch == predecessor.state.epoch,
                  state.revision == expectedRevision,
                  state.previousCommitDigest == AccountTranscript.trustCommitDigest(predecessor),
                  state.keyGeneration == predecessor.state.keyGeneration,
                  state.keyCommitment == predecessor.state.keyCommitment,
                  let signer = predecessor.state.members.first(where: { $0.deviceID == state.signerDeviceID }),
                  state.members.contains(where: { $0.deviceID == signer.deviceID })
            else { throw AccountProtocolError.invalidTransition }
            let target = state.transition.targetDeviceIDs[0]
            guard let admitted = state.members.first(where: { $0.deviceID == target }),
                  !predecessor.state.members.contains(where: { $0.deviceID == target }),
                  admitted.revision == state.revision,
                  admitted.signerDeviceID == state.signerDeviceID
            else { throw AccountProtocolError.invalidTransition }
            try verifySignature(publicKey: signer.publicBundle.signingKey, transcript: AccountTranscript.trustRecord(admitted), signature: admitted.signature)
            try verifyUnchangedSurvivors(state.members.filter { $0.deviceID != target }, predecessor: predecessor.state.members)
            try verifySignature(publicKey: signer.publicBundle.signingKey, transcript: AccountTranscript.trustState(state), signature: state.signature)
            try verifyAdmissionAuthorization(
                state: state,
                signer: signer,
                admitted: admitted,
                context: authorizationContext
            )
        case .revocation, .suspension:
            guard let predecessor else { throw AccountProtocolError.invalidTransition }
            let expectedRevision = try increment(predecessor.state.revision)
            let expectedGeneration = try increment(predecessor.state.keyGeneration)
            guard
                  state.accountID == predecessor.state.accountID,
                  state.epoch == predecessor.state.epoch,
                  state.revision == expectedRevision,
                  state.previousCommitDigest == AccountTranscript.trustCommitDigest(predecessor),
                  state.keyGeneration == expectedGeneration,
                  state.keyCommitment != predecessor.state.keyCommitment,
                  let signer = predecessor.state.members.first(where: { $0.deviceID == state.signerDeviceID }),
                  state.members.contains(where: { $0.deviceID == signer.deviceID })
            else { throw AccountProtocolError.invalidTransition }
            let target = state.transition.targetDeviceIDs[0]
            guard let removed = predecessor.state.members.first(where: { $0.deviceID == target }),
                  !state.members.contains(where: { $0.deviceID == target }),
                  state.transition.priorRecordDigests == [try AccountPriorRecordDigest(deviceID: target, recordDigest: digest(AccountTranscript.signedTrustRecord(removed)))]
            else { throw AccountProtocolError.invalidTransition }
            try verifyUnchangedSurvivors(state.members, predecessor: predecessor.state.members.filter { $0.deviceID != target })
            try verifySignature(publicKey: signer.publicBundle.signingKey, transcript: AccountTranscript.trustState(state), signature: state.signature)
        case .recovery:
            guard let predecessor else { throw AccountProtocolError.invalidTransition }
            let expectedEpoch = try increment(predecessor.state.epoch)
            let expectedPriorRecords = try predecessor.state.members.map {
                try AccountPriorRecordDigest(deviceID: $0.deviceID, recordDigest: digest(AccountTranscript.signedTrustRecord($0)))
            }
            guard state.accountID == predecessor.state.accountID,
                  state.epoch == expectedEpoch,
                  state.revision.value == 1, state.keyGeneration.value == 1,
                  state.previousCommitDigest == AccountTranscript.trustCommitDigest(predecessor),
                  state.keyCommitment != predecessor.state.keyCommitment,
                  state.members.count == 1, let replacement = state.members.first,
                  replacement.deviceID == state.signerDeviceID,
                  replacement.signerDeviceID == replacement.deviceID,
                  !predecessor.state.members.contains(where: { $0.deviceID == replacement.deviceID }),
                  state.transition.targetDeviceIDs == predecessor.state.members.map(\.deviceID),
                  state.transition.priorRecordDigests == expectedPriorRecords
            else { throw AccountProtocolError.invalidTransition }
            try verifySignature(publicKey: replacement.publicBundle.signingKey, transcript: AccountTranscript.trustRecord(replacement), signature: replacement.signature)
            try verifySignature(publicKey: replacement.publicBundle.signingKey, transcript: AccountTranscript.trustState(state), signature: state.signature)
            try verifyRecoveryAuthorization(
                state: state,
                replacement: replacement,
                context: authorizationContext,
                offlineRootKeyID: offlineRootKeyID,
                offlineRootPublicKey: offlineRootPublicKey
            )
        }
        guard let packageSigner = state.members.first(where: { $0.deviceID == state.signerDeviceID }) else { throw AccountProtocolError.invalidTransition }
        for package in packages {
            try verifySignature(publicKey: packageSigner.publicBundle.signingKey, transcript: AccountTranscript.groupKeyPackage(package, encryptedDigest: digest(package.nonce + package.encryptedKeyMaterial)), signature: package.signature)
        }
    }

    private static func verifyAdmissionAuthorization(
        state: AccountTrustState,
        signer: AccountDeviceTrustRecord,
        admitted: AccountDeviceTrustRecord,
        context: AccountTrustAuthorizationContext
    ) throws {
        guard let pendingDigest = state.transition.pendingDeviceDigest,
              let handshakeDigest = state.transition.handshakeDigest
        else { throw AccountProtocolError.invalidTransition }
        let matches = context.admissions.filter {
            digest(AccountTranscript.pendingDeviceAuthorization($0.pendingDevice)) == pendingDigest &&
                AccountTrustAuthentication.handshakeDigest($0.response) == handshakeDigest
        }
        guard matches.count == 1 else { throw AccountProtocolError.invalidTransition }
        let evidence = matches[0]
        let pending = evidence.pendingDevice
        let offer = evidence.response.offer
        guard pending.accountID == state.accountID,
              pending.deviceID == admitted.deviceID,
              pending.platform == admitted.platform,
              pending.platform != .syncNode,
              pending.publicBundle == admitted.publicBundle,
              offer.accountID == state.accountID,
              offer.existingDeviceID == signer.deviceID,
              offer.pendingDeviceID == admitted.deviceID,
              offer.existingPublicBundle == signer.publicBundle,
              offer.pendingPublicBundle == admitted.publicBundle,
              let pendingCreated = AccountWireCodec.parseTimestamp(pending.createdAt),
              let pendingExpiry = AccountWireCodec.parseTimestamp(pending.expiresAt),
              date(milliseconds: offer.createdAtUnixMilliseconds) >= pendingCreated,
              date(milliseconds: offer.expiresAtUnixMilliseconds) <= pendingExpiry
        else { throw AccountProtocolError.invalidTransition }
    }

    private static func transitionEvidence(
        for commit: AccountTrustStateCommit,
        context: AccountTrustAuthorizationContext
    ) -> AccountTrustTransitionEvidenceV1? {
        switch commit.state.transition.kind {
        case .admission:
            guard let pendingDigest = commit.state.transition.pendingDeviceDigest,
                  let handshakeDigest = commit.state.transition.handshakeDigest,
                  let evidence = context.admissions.first(where: {
                      digest(AccountTranscript.pendingDeviceAuthorization($0.pendingDevice)) == pendingDigest &&
                      AccountTrustAuthentication.handshakeDigest($0.response) == handshakeDigest
                  })
            else { return nil }
            return .admission(evidence)
        case .recovery:
            guard let authorizationDigest = commit.state.transition.recoveryAuthorizationDigest,
                  let evidence = context.recoveries.first(where: {
                      AccountTranscript.recoveryAuthorizationDigest($0.authorization) == authorizationDigest
                  })
            else { return nil }
            return .recovery(evidence)
        case .genesis, .revocation, .suspension:
            return nil
        }
    }

    private static func verifyRecoveryAuthorization(
        state: AccountTrustState,
        replacement: AccountDeviceTrustRecord,
        context: AccountTrustAuthorizationContext,
        offlineRootKeyID: String,
        offlineRootPublicKey: Data
    ) throws {
        guard let expectedDigest = state.transition.recoveryAuthorizationDigest else { throw AccountProtocolError.invalidTransition }
        let matches = context.recoveries.filter {
            AccountTranscript.recoveryAuthorizationDigest($0.authorization) == expectedDigest
        }
        guard matches.count == 1 else { throw AccountProtocolError.invalidTransition }
        let evidence = matches[0]
        let authorization = evidence.authorization
        guard authorization.exchangeRequestDigest.count == 32,
              authorization.accountID == state.accountID,
              authorization.epoch == state.epoch,
              authorization.deviceID == replacement.deviceID,
              authorization.platform == replacement.platform,
              authorization.platform != .syncNode,
              authorization.publicBundle == replacement.publicBundle,
              authorization.priorCommitDigest == state.previousCommitDigest
        else { throw AccountProtocolError.invalidTransition }
        try BootstrapKeyManifestStore.verifyHistoricalRecoveryAuthorization(
            authorization,
            historicalManifest: evidence.historicalManifest,
            offlineRootKeyID: offlineRootKeyID,
            offlineRootPublicKey: offlineRootPublicKey,
            expectedAccountID: state.accountID,
            expectedEpoch: state.epoch,
            expectedDeviceID: replacement.deviceID,
            expectedPlatform: replacement.platform,
            expectedPublicBundle: replacement.publicBundle,
            expectedPriorCommitDigest: authorization.priorCommitDigest,
            expectedExchangeRequestDigest: authorization.exchangeRequestDigest
        )
    }

    private static func verifyUnchangedSurvivors(_ actual: [AccountDeviceTrustRecord], predecessor: [AccountDeviceTrustRecord]) throws {
        guard actual.count == predecessor.count else { throw AccountProtocolError.invalidTransition }
        for item in actual {
            guard let prior = predecessor.first(where: { $0.deviceID == item.deviceID }), AccountTranscript.signedTrustRecord(item) == AccountTranscript.signedTrustRecord(prior) else { throw AccountProtocolError.invalidTransition }
        }
    }

    private static func validateActiveMemberPlatforms(_ members: [AccountDeviceTrustRecord]) throws {
        guard members.filter({ $0.platform == .macos }).count <= 5,
              members.filter({ $0.platform == .ios }).count <= 5,
              members.filter({ $0.platform == .syncNode }).count <= 1
        else { throw AccountProtocolError.invalidTransition }
    }

    private static func verifySignature(publicKey: Data, transcript: Data, signature: Data) throws {
        try AccountWireCodec.validateLowSSignature(signature)
        do {
            let key = try P256.Signing.PublicKey(x963Representation: publicKey)
            let value = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(value, for: transcript) else { throw AccountProtocolError.invalidSignature }
        } catch let error as AccountProtocolError { throw error }
        catch { throw AccountProtocolError.invalidSignature }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func metadataNonceNamespace(
        metadataKey: Data,
        keyGeneration: PositiveUInt64,
        member: AccountDeviceTrustRecord
    ) -> Data {
        var generation = keyGeneration.value.bigEndian
        let transcript = AccountTranscript.parts([
            Data("Plainpost.MetadataNonceNamespace.v1".utf8),
            Data(member.accountID.rawValue.utf8),
            Data(member.deviceID.rawValue.utf8),
            Data(SHA256.hash(data: member.publicBundle.signingKey)),
            Data(SHA256.hash(data: member.publicBundle.agreementKey)),
            Data(bytes: &generation, count: MemoryLayout<UInt64>.size),
        ])
        return Data(HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: SymmetricKey(data: metadataKey)
        ).prefix(8))
    }

    private static func increment(_ value: PositiveUInt64) throws -> PositiveUInt64 {
        let (next, overflow) = value.value.addingReportingOverflow(1)
        guard !overflow else { throw AccountProtocolError.nonCanonicalValue }
        return try PositiveUInt64(next)
    }

    private static func increment(_ value: AccountTrustEpoch) throws -> AccountTrustEpoch {
        let (next, overflow) = value.value.addingReportingOverflow(1)
        guard !overflow else { throw AccountProtocolError.nonCanonicalValue }
        return AccountTrustEpoch(rawValue: try PositiveUInt64(next))
    }

    private static func milliseconds(_ value: Date) throws -> PositiveUInt64 {
        let milliseconds = value.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 1, milliseconds <= Double(UInt64.max) else { throw AccountProtocolError.invalidTimestamp }
        return try PositiveUInt64(UInt64(milliseconds.rounded(.towardZero)))
    }

    private static func date(milliseconds: PositiveUInt64) -> Date { Date(timeIntervalSince1970: TimeInterval(milliseconds.value) / 1_000) }

    private static func normalize(_ value: String, maximumBytes: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= maximumBytes, normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw AccountProtocolError.malformedWire }
        return normalized
    }

    private static func compareRecordCoordinate(_ leftEpoch: AccountTrustEpoch, _ leftGeneration: PositiveUInt64, _ leftRevision: PositiveUInt64, _ rightEpoch: AccountTrustEpoch, _ rightGeneration: PositiveUInt64, _ rightRevision: PositiveUInt64) -> Int {
        let left = (leftEpoch.value, leftGeneration.value, leftRevision.value)
        let right = (rightEpoch.value, rightGeneration.value, rightRevision.value)
        if left == right { return 0 }
        return left.0 != right.0 ? (left.0 < right.0 ? -1 : 1) : left.1 != right.1 ? (left.1 < right.1 ? -1 : 1) : (left.2 < right.2 ? -1 : 1)
    }
}

extension AccountTrustCoordinator: AccountTrustHistoryApplying {}
