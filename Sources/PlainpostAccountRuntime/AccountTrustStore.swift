import CryptoKit
import Foundation
import PlainpostAccountProtocol

public struct AccountTrustKeyMaterial: Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let epoch: AccountTrustEpoch
    public let keyGeneration: PositiveUInt64
    public let trustRevision: PositiveUInt64
    public let mailboxMatchingKey: Data
    public let metadataKey: Data

    public init(
        accountID: PlainpostAccountID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        trustRevision: PositiveUInt64,
        mailboxMatchingKey: Data,
        metadataKey: Data
    ) throws {
        guard mailboxMatchingKey.count == 32, metadataKey.count == 32 else { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID
        self.epoch = epoch
        self.keyGeneration = keyGeneration
        self.trustRevision = trustRevision
        self.mailboxMatchingKey = mailboxMatchingKey
        self.metadataKey = metadataKey
    }

    public var combined: Data { mailboxMatchingKey + metadataKey }
    public var commitment: Data { Data(SHA256.hash(data: combined)) }
}

public struct AccountRecordHighWater: Codable, Hashable, Sendable {
    public let epoch: AccountTrustEpoch
    public let keyGeneration: PositiveUInt64
    public let recordRevision: PositiveUInt64
    public let envelopeDigest: Data

    public init(epoch: AccountTrustEpoch, keyGeneration: PositiveUInt64, recordRevision: PositiveUInt64, envelopeDigest: Data) throws {
        guard envelopeDigest.count == 32 else { throw AccountRuntimeError.corruptSecret }
        self.epoch = epoch
        self.keyGeneration = keyGeneration
        self.recordRevision = recordRevision
        self.envelopeDigest = envelopeDigest
    }
}

struct AccountTrustMaterialCoordinate: Codable, Hashable, Sendable {
    let epoch: AccountTrustEpoch
    let keyGeneration: PositiveUInt64

    init(epoch: AccountTrustEpoch, keyGeneration: PositiveUInt64) {
        self.epoch = epoch
        self.keyGeneration = keyGeneration
    }

    init(_ material: AccountTrustKeyMaterial) {
        epoch = material.epoch
        keyGeneration = material.keyGeneration
    }
}

struct AccountTrustStoreState: Sendable {
    let headValue: Data
    let snapshotDigest: Data
    let checkpoint: AccountTrustCheckpointV1
    let currentCommit: AccountTrustStateCommit
    let verifiedEntries: [AccountTrustHistoryEntryV1]
    let materialReferences: [StoredMaterialReference]
    let retiredMaterialReferences: [StoredMaterialReference]
    let materials: [AccountTrustMaterialCoordinate: AccountTrustKeyMaterial]
    var cleanupRequired: Bool

    var verifiedCommits: [AccountTrustStateCommit] { verifiedEntries.map(\.commit) }
}

/// Trust material is immutable and commit-scoped. A single CAS-protected head
/// selects one complete snapshot, so a crash before the head update leaves the
/// prior winner usable and a losing fork can only leave unreachable records.
public final class AccountTrustStore: @unchecked Sendable {
    private let secretStore: any AccountSecretStoring
    private let service: String
    private let accessGroup: String?
    private let operationFence: any AccountOperationFencing
    private let maxRetainedGenerations: Int
    private let maxVerifiedEntries: Int
    private let lock = NSLock()

    public init(
        secretStore: any AccountSecretStoring = KeychainAccountSecretStore(),
        service: String = "com.marynavdovenko.Plainpost.AccountTrust",
        accessGroup: String? = nil,
        operationFence: any AccountOperationFencing = FileAccountOperationFence.production()
    ) {
        self.secretStore = secretStore
        self.service = service
        self.accessGroup = accessGroup
        self.operationFence = operationFence
        maxRetainedGenerations = 32
        maxVerifiedEntries = 32 * 11
    }

    init(
        secretStore: any AccountSecretStoring,
        service: String,
        maximumRetainedGenerations: Int,
        accessGroup: String? = nil,
        operationFence: any AccountOperationFencing = FileAccountOperationFence.production()
    ) {
        precondition((1...32).contains(maximumRetainedGenerations))
        self.secretStore = secretStore
        self.service = service
        self.accessGroup = accessGroup
        self.operationFence = operationFence
        maxRetainedGenerations = maximumRetainedGenerations
        maxVerifiedEntries = maximumRetainedGenerations * 11
    }

    func loadState(for accountID: PlainpostAccountID) throws -> AccountTrustStoreState? {
        try withAccountFence(for: accountID) { try loadStateUnfenced(for: accountID) }
    }

    func withAccountFence<T>(for accountID: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        try operationFence.withLock(accountID: accountID, operation)
    }

    private func loadStateUnfenced(for accountID: PlainpostAccountID) throws -> AccountTrustStoreState? {
        lock.lock(); defer { lock.unlock() }
        return try loadStateLocked(for: accountID)
    }

    public func loadKeyMaterial(for accountID: PlainpostAccountID) throws -> AccountTrustKeyMaterial? {
        guard let state = try loadState(for: accountID) else { return nil }
        let coordinate = AccountTrustMaterialCoordinate(
            epoch: state.currentCommit.state.epoch,
            keyGeneration: state.currentCommit.state.keyGeneration
        )
        return state.materials[coordinate]
    }

    public func loadCheckpoint(for accountID: PlainpostAccountID) throws -> AccountTrustCheckpointV1? {
        try loadState(for: accountID)?.checkpoint
    }

    /// Removes every bounded device-only trust record owned by one account.
    /// Callers must have already fenced account activity and retained an
    /// external cleanup journal: partial deletion is intentionally fail-closed
    /// and an exact retry completes from the still-present bounded indexes.
    public func purgeAccountAuthority(for accountID: PlainpostAccountID) throws {
        try withAccountFence(for: accountID) {
            lock.lock(); defer { lock.unlock() }

            let gcRecord = try secretStore.load(gcIndexKey(for: accountID))
            let gcIndex = try decodeGCIndex(gcRecord, accountID: accountID)
            let recordIndexRecord = try secretStore.load(recordIndexKey(for: accountID))
            let recordIndex = try decodeRecordHighWaterIndex(recordIndexRecord)

            if let head = try secretStore.load(headKey(for: accountID)) {
                guard head.attributes == .deviceOnly,
                      let pointer = try? Self.decode(StoredTrustHead.self, from: head.value),
                      pointer.version == 3,
                      pointer.checkpoint.accountID == accountID,
                      gcIndex.snapshots.contains(snapshotKey(for: accountID, digest: pointer.snapshotDigest).account)
                else { throw AccountRuntimeError.corruptSecret }
            }

            let indexedAccounts = gcIndex.snapshots + gcIndex.material + gcIndex.nonces
            for account in indexedAccounts {
                try secretStore.delete(secretKey(account: account))
            }
            for recordID in recordIndex.recordIDs {
                let id: AccountRecordID
                do { id = try AccountRecordID(recordID) }
                catch { throw AccountRuntimeError.corruptSecret }
                try secretStore.delete(recordKey(for: accountID, recordID: id))
            }
            try secretStore.delete(headKey(for: accountID))
            try secretStore.delete(gcIndexKey(for: accountID))
            try secretStore.delete(recordIndexKey(for: accountID))
        }
    }

    func installGenesis(_ commit: AccountTrustStateCommit, material: Data) throws {
        guard commit.state.transition.kind == .genesis, material.count == 64 else { throw AccountRuntimeError.corruptSecret }
        let opened = try AccountTrustKeyMaterial(accountID: commit.state.accountID, epoch: commit.state.epoch, keyGeneration: commit.state.keyGeneration, trustRevision: commit.state.revision, mailboxMatchingKey: Data(material.prefix(32)), metadataKey: Data(material.suffix(32)))
        guard opened.commitment == commit.state.keyCommitment else { throw AccountRuntimeError.corruptSecret }
        let entry = try AccountTrustHistoryEntryV1(commit: commit, evidence: nil)
        try withAccountFence(for: commit.state.accountID) {
            if let current = try loadStateUnfenced(for: commit.state.accountID) {
                guard current.checkpoint.commitDigest == AccountTranscript.trustCommitDigest(commit), current.materials[AccountTrustMaterialCoordinate(opened)]?.combined == material else { throw AccountProtocolError.equivocation }
                return
            }
            _ = try installVerifiedCommitUnfenced(commit, openedMaterial: opened, verifiedEntries: [entry], expected: nil)
        }
    }

    func installPreparedActivation(_ prepared: AccountPreparedTrustActivation, deviceID: AccountDeviceID) throws {
        guard let final = prepared.entries.last,
              final.commit.state.accountID == prepared.material.accountID,
              final.commit.state.epoch == prepared.material.epoch,
              final.commit.state.keyGeneration == prepared.material.keyGeneration,
              final.commit.state.revision == prepared.material.trustRevision,
              final.commit.state.keyCommitment == prepared.material.commitment,
              final.commit.state.members.contains(where: { $0.deviceID == deviceID }),
              prepared.entries.allSatisfy({ $0.commit.state.accountID == final.commit.state.accountID })
        else { throw AccountRuntimeError.corruptSecret }
        try withAccountFence(for: final.commit.state.accountID) {
            if let current = try loadStateUnfenced(for: final.commit.state.accountID) {
                guard current.checkpoint.commitDigest == AccountTranscript.trustCommitDigest(final.commit),
                      current.materials[AccountTrustMaterialCoordinate(prepared.material)] == prepared.material,
                      current.verifiedEntries == prepared.entries
                else { throw AccountProtocolError.equivocation }
                return
            }
            _ = try installVerifiedCommitUnfenced(final.commit, openedMaterial: prepared.material, verifiedEntries: prepared.entries, expected: nil)
        }
    }

    /// Installs an already verified, centrally accepted epoch reset. Unlike
    /// bootstrap activation, recovery replaces an authenticated prior head;
    /// exact replay is idempotent and any other current head is equivocation.
    func installPreparedRecoveryActivation(_ prepared: AccountPreparedTrustActivation, deviceID: AccountDeviceID) throws {
        guard prepared.entries.count == 1,
              let final = prepared.entries.first,
              final.commit.state.transition.kind == .recovery,
              final.commit.state.accountID == prepared.material.accountID,
              final.commit.state.epoch == prepared.material.epoch,
              final.commit.state.keyGeneration == prepared.material.keyGeneration,
              final.commit.state.revision == prepared.material.trustRevision,
              final.commit.state.keyCommitment == prepared.material.commitment,
              final.commit.state.members.contains(where: { $0.deviceID == deviceID })
        else { throw AccountRuntimeError.corruptSecret }
        try withAccountFence(for: final.commit.state.accountID) {
            guard let current = try loadStateUnfenced(for: final.commit.state.accountID) else { throw AccountRuntimeError.corruptSecret }
            let finalDigest = AccountTranscript.trustCommitDigest(final.commit)
            if current.checkpoint.commitDigest == finalDigest {
                guard current.materials[AccountTrustMaterialCoordinate(prepared.material)] == prepared.material,
                      current.verifiedEntries == prepared.entries
                else { throw AccountProtocolError.equivocation }
                return
            }
            guard final.commit.state.previousCommitDigest == current.checkpoint.commitDigest else { throw AccountProtocolError.equivocation }
            _ = try installVerifiedCommitUnfenced(final.commit, openedMaterial: prepared.material, verifiedEntries: prepared.entries, expected: current)
        }
    }

    func installVerifiedCommit(
        _ commit: AccountTrustStateCommit,
        openedMaterial: AccountTrustKeyMaterial?,
        verifiedEntries: [AccountTrustHistoryEntryV1],
        expected: AccountTrustStoreState?
    ) throws -> AccountTrustStoreState {
        try withAccountFence(for: commit.state.accountID) {
            try installVerifiedCommitUnfenced(commit, openedMaterial: openedMaterial, verifiedEntries: verifiedEntries, expected: expected)
        }
    }

    private func installVerifiedCommitUnfenced(
        _ commit: AccountTrustStateCommit,
        openedMaterial: AccountTrustKeyMaterial?,
        verifiedEntries: [AccountTrustHistoryEntryV1],
        expected: AccountTrustStoreState?
    ) throws -> AccountTrustStoreState {
        lock.lock(); defer { lock.unlock() }
        guard expected?.cleanupRequired != true else { throw AccountRuntimeError.secretUnavailable }
        let checkpoint = try AccountTrustCheckpointV1(
            accountID: commit.state.accountID,
            epoch: commit.state.epoch,
            revision: commit.state.revision,
            commitDigest: AccountTranscript.trustCommitDigest(commit)
        )
        var references = expected?.materialReferences ?? []
        var retiredReferences = expected?.retiredMaterialReferences ?? []
        if commit.state.transition.kind == .recovery {
            retiredReferences.append(contentsOf: references)
            references = []
        }
        if let openedMaterial {
            guard openedMaterial.accountID == commit.state.accountID,
                  openedMaterial.epoch == commit.state.epoch,
                  openedMaterial.keyGeneration == commit.state.keyGeneration,
                  openedMaterial.commitment == commit.state.keyCommitment
            else { throw AccountRuntimeError.corruptSecret }
            let coordinate = AccountTrustMaterialCoordinate(openedMaterial)
            if let existing = references.first(where: { $0.coordinate == coordinate }) {
                guard expected?.materials[coordinate]?.combined == openedMaterial.combined,
                      existing.keyCommitment == openedMaterial.commitment
                else { throw AccountRuntimeError.corruptSecret }
            } else {
                guard references.count + retiredReferences.count < maxRetainedGenerations else {
                    throw AccountProtocolError.invalidTransition
                }
                let reference = StoredMaterialReference(
                    accountID: openedMaterial.accountID,
                    epoch: openedMaterial.epoch,
                    keyGeneration: openedMaterial.keyGeneration,
                    trustRevision: openedMaterial.trustRevision,
                    keyCommitment: openedMaterial.commitment,
                    locator: checkpoint.commitDigest
                )
                try saveMaterial(openedMaterial, reference: reference)
                references.append(reference)
                references.sort(by: StoredMaterialReference.lessThan)
            }
        }
        guard references.count + retiredReferences.count <= maxRetainedGenerations,
              verifiedEntries.count <= maxVerifiedEntries
        else { throw AccountProtocolError.invalidTransition }
        let snapshot = try StoredTrustSnapshot(
            version: 3,
            checkpoint: checkpoint,
            currentCommit: AccountWireCodec.encodeTrustCommit(commit),
            verifiedEntries: try verifiedEntries.map(AccountWireCodec.encodeTrustHistoryEntry),
            materialReferences: references,
            retiredMaterialReferences: retiredReferences
        )
        var committedMaterials = expected?.materials ?? [:]
        if commit.state.transition.kind == .recovery { committedMaterials.removeAll() }
        if let openedMaterial { committedMaterials[AccountTrustMaterialCoordinate(openedMaterial)] = openedMaterial }
        return try installSnapshot(snapshot, materials: committedMaterials, expectedHeadValue: expected?.headValue)
    }

    func retireMaterial(
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        expected: AccountTrustStoreState
    ) throws -> AccountTrustStoreState {
        try withAccountFence(for: expected.checkpoint.accountID) {
            try retireMaterialUnfenced(epoch: epoch, keyGeneration: keyGeneration, expected: expected)
        }
    }

    private func retireMaterialUnfenced(
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        expected: AccountTrustStoreState
    ) throws -> AccountTrustStoreState {
        lock.lock(); defer { lock.unlock() }
        guard expected.cleanupRequired == false else { throw AccountRuntimeError.secretUnavailable }
        let coordinate = AccountTrustMaterialCoordinate(epoch: epoch, keyGeneration: keyGeneration)
        guard let removed = expected.materialReferences.first(where: { $0.coordinate == coordinate }) else { throw AccountProtocolError.invalidTransition }
        let currentCoordinate = AccountTrustMaterialCoordinate(
            epoch: expected.currentCommit.state.epoch,
            keyGeneration: expected.currentCommit.state.keyGeneration
        )
        guard coordinate != currentCoordinate else { throw AccountProtocolError.invalidTransition }
        let references = expected.materialReferences.filter { $0.coordinate != coordinate }
        let retiredReferences = expected.retiredMaterialReferences + [removed]
        let retainedEntries = expected.verifiedEntries.filter {
            AccountTrustMaterialCoordinate(epoch: $0.commit.state.epoch, keyGeneration: $0.commit.state.keyGeneration) != coordinate
        }
        guard references.count + retiredReferences.count <= maxRetainedGenerations,
              retainedEntries.count <= maxVerifiedEntries
        else { throw AccountProtocolError.invalidTransition }
        let snapshot = try StoredTrustSnapshot(
            version: 3,
            checkpoint: expected.checkpoint,
            currentCommit: AccountWireCodec.encodeTrustCommit(expected.currentCommit),
            verifiedEntries: try retainedEntries.map(AccountWireCodec.encodeTrustHistoryEntry),
            materialReferences: references,
            retiredMaterialReferences: retiredReferences
        )
        var committedMaterials = expected.materials
        committedMaterials.removeValue(forKey: coordinate)
        return try installSnapshot(snapshot, materials: committedMaterials, expectedHeadValue: expected.headValue)
    }

    public func loadRecordHighWater(accountID: PlainpostAccountID, recordID: AccountRecordID) throws -> AccountRecordHighWater? {
        try withAccountFence(for: accountID) { try loadRecordHighWaterUnfenced(accountID: accountID, recordID: recordID) }
    }

    private func loadRecordHighWaterUnfenced(accountID: PlainpostAccountID, recordID: AccountRecordID) throws -> AccountRecordHighWater? {
        lock.lock(); defer { lock.unlock() }
        let index = try decodeRecordHighWaterIndex(try secretStore.load(recordIndexKey(for: accountID)))
        guard let record = try secretStore.load(recordKey(for: accountID, recordID: recordID)) else { return nil }
        guard record.attributes == .deviceOnly,
              index.recordIDs.contains(recordID.rawValue),
              let highWater = try? Self.decode(AccountRecordHighWater.self, from: record.value)
        else { throw AccountRuntimeError.corruptSecret }
        return highWater
    }

    public func saveRecordHighWater(_ highWater: AccountRecordHighWater, accountID: PlainpostAccountID, recordID: AccountRecordID) throws {
        try withAccountFence(for: accountID) {
            try saveRecordHighWaterUnfenced(highWater, accountID: accountID, recordID: recordID)
        }
    }

    private func saveRecordHighWaterUnfenced(_ highWater: AccountRecordHighWater, accountID: PlainpostAccountID, recordID: AccountRecordID) throws {
        lock.lock(); defer { lock.unlock() }
        try reserveRecordHighWaterID(accountID: accountID, recordID: recordID)
        let key = recordKey(for: accountID, recordID: recordID)
        let replacement = try Self.encode(highWater)
        for _ in 0..<8 {
            let existing = try secretStore.load(key)
            if let existing {
                guard existing.attributes == .deviceOnly,
                      let prior = try? Self.decode(AccountRecordHighWater.self, from: existing.value)
                else { throw AccountRuntimeError.corruptSecret }
                let ordering = Self.compareRecordHighWater(prior, highWater)
                if ordering > 0 { throw AccountProtocolError.rollback }
                if ordering == 0 {
                    guard prior.envelopeDigest == highWater.envelopeDigest else { throw AccountProtocolError.equivocation }
                    return
                }
            }
            if try secretStore.compareAndSwap(expected: existing?.value, replacement: replacement, key: key, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private func reserveRecordHighWaterID(accountID: PlainpostAccountID, recordID: AccountRecordID) throws {
        let key = recordIndexKey(for: accountID)
        for _ in 0..<8 {
            let existing = try secretStore.load(key)
            var index = try decodeRecordHighWaterIndex(existing)
            if index.recordIDs.contains(recordID.rawValue) { return }
            guard index.recordIDs.count < AccountRecordInventoryProofV1.maximumEntries else {
                throw AccountRuntimeError.secretUnavailable
            }
            index.recordIDs.append(recordID.rawValue)
            index.recordIDs.sort()
            if try secretStore.compareAndSwap(
                expected: existing?.value,
                replacement: Self.encode(index),
                key: key,
                attributes: .deviceOnly
            ) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private func decodeRecordHighWaterIndex(_ record: AccountSecretRecord?) throws -> StoredRecordHighWaterIndex {
        guard let record else { return StoredRecordHighWaterIndex() }
        guard record.attributes == .deviceOnly,
              let index = try? Self.decode(StoredRecordHighWaterIndex.self, from: record.value),
              index.isValid
        else { throw AccountRuntimeError.corruptSecret }
        return index
    }

    public func nextMetadataNonce(
        accountID: PlainpostAccountID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        namespace: Data
    ) throws -> Data {
        try withAccountFence(for: accountID) {
            try nextMetadataNonceUnfenced(
                accountID: accountID,
                epoch: epoch,
                keyGeneration: keyGeneration,
                namespace: namespace
            )
        }
    }

    private func nextMetadataNonceUnfenced(
        accountID: PlainpostAccountID,
        epoch: AccountTrustEpoch,
        keyGeneration: PositiveUInt64,
        namespace: Data
    ) throws -> Data {
        guard namespace.count == 8 else { throw AccountRuntimeError.cryptographicFailure }
        let key = metadataNonceKey(accountID: accountID, epoch: epoch, keyGeneration: keyGeneration)
        lock.lock(); defer { lock.unlock() }
        try reserveIndexedKey(key, kind: .nonce, accountID: accountID)
        for _ in 0..<8 {
            let existing = try secretStore.load(key)
            let state: MetadataNonceState
            if let existing {
                guard existing.attributes == .deviceOnly,
                      let decoded = try? Self.decode(MetadataNonceState.self, from: existing.value),
                      decoded.version == 2,
                      decoded.namespace == namespace,
                      decoded.namespace.count == 8
                else { throw AccountRuntimeError.corruptSecret }
                state = decoded
            } else {
                state = MetadataNonceState(version: 2, namespace: namespace, nextCounter: 0)
            }
            guard state.nextCounter < UInt32.max else { throw AccountRuntimeError.cryptographicFailure }
            var counter = state.nextCounter.bigEndian
            let nonce = state.namespace + Data(bytes: &counter, count: MemoryLayout<UInt32>.size)
            let next = MetadataNonceState(version: 2, namespace: state.namespace, nextCounter: state.nextCounter + 1)
            if try secretStore.compareAndSwap(
                expected: existing?.value,
                replacement: Self.encode(next),
                key: key,
                attributes: .deviceOnly
            ) { return nonce }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private func installSnapshot(
        _ snapshot: StoredTrustSnapshot,
        materials: [AccountTrustMaterialCoordinate: AccountTrustKeyMaterial],
        expectedHeadValue: Data?
    ) throws -> AccountTrustStoreState {
        let snapshotValue = try Self.encode(snapshot)
        let snapshotDigest = Data(SHA256.hash(data: snapshotValue))
        try saveIndexedImmutable(snapshotValue, key: snapshotKey(for: snapshot.checkpoint.accountID, digest: snapshotDigest), kind: .snapshot, accountID: snapshot.checkpoint.accountID)
        let pointer = StoredTrustHead(version: 3, checkpoint: snapshot.checkpoint, snapshotDigest: snapshotDigest)
        let pointerValue = try Self.encode(pointer)
        if try secretStore.compareAndSwap(expected: expectedHeadValue, replacement: pointerValue, key: headKey(for: snapshot.checkpoint.accountID), attributes: .deviceOnly) {
            let committed = try constructState(
                headValue: pointerValue,
                pointer: pointer,
                snapshotValue: snapshotValue,
                snapshot: snapshot,
                materials: materials
            )
            return reconcileCleanupLocked(committed)
        }
        guard let winner = try loadStateLocked(for: snapshot.checkpoint.accountID) else { throw AccountRuntimeError.secretUnavailable }
        let ordering = Self.compareCheckpoint(winner.checkpoint, snapshot.checkpoint)
        if ordering > 0 { throw AccountProtocolError.rollback }
        if ordering == 0 {
            guard winner.checkpoint.commitDigest == snapshot.checkpoint.commitDigest else { throw AccountProtocolError.equivocation }
            guard winner.snapshotDigest == snapshotDigest else { throw AccountRuntimeError.secretUnavailable }
            return winner
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private func loadStateLocked(for accountID: PlainpostAccountID) throws -> AccountTrustStoreState? {
        guard let state = try loadStateRawLocked(for: accountID) else {
            guard try reconcileGCIndex(
                accountID: accountID,
                reachableSnapshots: [],
                reachableMaterial: [],
                reachableNonces: []
            ) else { throw AccountRuntimeError.secretUnavailable }
            return nil
        }
        return reconcileCleanupLocked(state)
    }

    private func loadStateRawLocked(for accountID: PlainpostAccountID) throws -> AccountTrustStoreState? {
        guard let headRecord = try secretStore.load(headKey(for: accountID)) else { return nil }
        guard headRecord.attributes == .deviceOnly,
              let pointer = try? Self.decode(StoredTrustHead.self, from: headRecord.value),
              pointer.version == 3,
              pointer.checkpoint.accountID == accountID,
              let snapshotRecord = try secretStore.load(snapshotKey(for: accountID, digest: pointer.snapshotDigest)),
              snapshotRecord.attributes == .deviceOnly,
              Data(SHA256.hash(data: snapshotRecord.value)) == pointer.snapshotDigest,
              let snapshot = try? Self.decode(StoredTrustSnapshot.self, from: snapshotRecord.value)
        else { throw AccountRuntimeError.corruptSecret }
        return try decodeState(
            headValue: headRecord.value,
            pointer: pointer,
            snapshotValue: snapshotRecord.value,
            snapshot: snapshot
        )
    }

    private func decodeState(
        headValue: Data,
        pointer: StoredTrustHead,
        snapshotValue: Data,
        snapshot: StoredTrustSnapshot
    ) throws -> AccountTrustStoreState {
        guard snapshot.version == 3,
              snapshot.checkpoint == pointer.checkpoint,
              Data(SHA256.hash(data: snapshotValue)) == pointer.snapshotDigest
        else { throw AccountRuntimeError.corruptSecret }
        let current: AccountTrustStateCommit
        let entries: [AccountTrustHistoryEntryV1]
        do {
            current = try AccountWireCodec.decodeTrustCommit(snapshot.currentCommit)
            entries = try snapshot.verifiedEntries.map(AccountWireCodec.decodeTrustHistoryEntry)
        } catch { throw AccountRuntimeError.corruptSecret }
        guard current.state.accountID == snapshot.checkpoint.accountID,
              current.state.epoch == snapshot.checkpoint.epoch,
              current.state.revision == snapshot.checkpoint.revision,
              AccountTranscript.trustCommitDigest(current) == snapshot.checkpoint.commitDigest,
              entries.last?.commit == current,
              entries.count <= maxVerifiedEntries,
              snapshot.materialReferences.count + snapshot.retiredMaterialReferences.count <= maxRetainedGenerations,
              Set(snapshot.materialReferences.map(\.coordinate)).count == snapshot.materialReferences.count,
              Set(snapshot.retiredMaterialReferences.map(\.coordinate)).count == snapshot.retiredMaterialReferences.count,
              Set(snapshot.materialReferences.map(\.coordinate)).isDisjoint(with: Set(snapshot.retiredMaterialReferences.map(\.coordinate)))
        else { throw AccountRuntimeError.corruptSecret }
        try Self.validateStoredReferences(
            active: snapshot.materialReferences,
            retired: snapshot.retiredMaterialReferences,
            accountID: snapshot.checkpoint.accountID,
            verifiedEntries: entries
        )
        var materials: [AccountTrustMaterialCoordinate: AccountTrustKeyMaterial] = [:]
        for reference in snapshot.materialReferences {
            guard reference.accountID == snapshot.checkpoint.accountID,
                  let matching = try secretStore.load(matchingKey(for: reference)),
                  let metadata = try secretStore.load(metadataKey(for: reference)),
                  matching.attributes == .deviceOnly, metadata.attributes == .deviceOnly,
                  let matchingHalf = try? Self.decode(StoredMaterialHalf.self, from: matching.value),
                  let metadataHalf = try? Self.decode(StoredMaterialHalf.self, from: metadata.value),
                  matchingHalf.reference == reference,
                  metadataHalf.reference == reference
            else { throw AccountRuntimeError.corruptSecret }
            let material = try AccountTrustKeyMaterial(
                accountID: reference.accountID,
                epoch: reference.epoch,
                keyGeneration: reference.keyGeneration,
                trustRevision: reference.trustRevision,
                mailboxMatchingKey: matchingHalf.value,
                metadataKey: metadataHalf.value
            )
            guard material.commitment == reference.keyCommitment else { throw AccountRuntimeError.corruptSecret }
            materials[reference.coordinate] = material
        }
        return try constructState(
            headValue: headValue,
            pointer: pointer,
            snapshotValue: snapshotValue,
            snapshot: snapshot,
            materials: materials
        )
    }

    private func constructState(
        headValue: Data,
        pointer: StoredTrustHead,
        snapshotValue: Data,
        snapshot: StoredTrustSnapshot,
        materials: [AccountTrustMaterialCoordinate: AccountTrustKeyMaterial]
    ) throws -> AccountTrustStoreState {
        let current: AccountTrustStateCommit
        let entries: [AccountTrustHistoryEntryV1]
        do {
            current = try AccountWireCodec.decodeTrustCommit(snapshot.currentCommit)
            entries = try snapshot.verifiedEntries.map(AccountWireCodec.decodeTrustHistoryEntry)
        } catch { throw AccountRuntimeError.corruptSecret }
        try Self.validateStoredReferences(
            active: snapshot.materialReferences,
            retired: snapshot.retiredMaterialReferences,
            accountID: snapshot.checkpoint.accountID,
            verifiedEntries: entries
        )
        guard snapshot.version == 3,
              snapshot.checkpoint == pointer.checkpoint,
              Data(SHA256.hash(data: snapshotValue)) == pointer.snapshotDigest,
              current.state.accountID == snapshot.checkpoint.accountID,
              current.state.epoch == snapshot.checkpoint.epoch,
              current.state.revision == snapshot.checkpoint.revision,
              AccountTranscript.trustCommitDigest(current) == snapshot.checkpoint.commitDigest,
              entries.last?.commit == current,
              entries.count <= maxVerifiedEntries,
              snapshot.materialReferences.count + snapshot.retiredMaterialReferences.count <= maxRetainedGenerations,
              Set(materials.keys) == Set(snapshot.materialReferences.map(\.coordinate)),
              snapshot.materialReferences.allSatisfy({ reference in
                  materials[reference.coordinate]?.commitment == reference.keyCommitment
              })
        else { throw AccountRuntimeError.corruptSecret }
        return AccountTrustStoreState(
            headValue: headValue,
            snapshotDigest: pointer.snapshotDigest,
            checkpoint: snapshot.checkpoint,
            currentCommit: current,
            verifiedEntries: entries,
            materialReferences: snapshot.materialReferences,
            retiredMaterialReferences: snapshot.retiredMaterialReferences,
            materials: materials,
            cleanupRequired: false
        )
    }

    private static func validateStoredReferences(
        active: [StoredMaterialReference],
        retired: [StoredMaterialReference],
        accountID: PlainpostAccountID,
        verifiedEntries: [AccountTrustHistoryEntryV1]
    ) throws {
        guard Set(active.map(\.coordinate)).count == active.count,
              Set(retired.map(\.coordinate)).count == retired.count,
              Set(active.map(\.coordinate)).isDisjoint(with: Set(retired.map(\.coordinate))),
              Set((active + retired).map(\.locator)).count == active.count + retired.count
        else { throw AccountRuntimeError.corruptSecret }
        for reference in active + retired {
            guard reference.accountID == accountID,
                  reference.locator.count == 32,
                  reference.keyCommitment.count == 32
            else { throw AccountRuntimeError.corruptSecret }
        }
        for reference in active {
            guard let authorizingEntry = verifiedEntries.first(where: { entry in
                entry.commit.state.accountID == accountID
                    && entry.commit.state.epoch == reference.epoch
                    && entry.commit.state.keyGeneration == reference.keyGeneration
                    && entry.commit.state.revision == reference.trustRevision
                    && entry.commit.state.keyCommitment == reference.keyCommitment
            }),
            AccountTranscript.trustCommitDigest(authorizingEntry.commit) == reference.locator
            else { throw AccountRuntimeError.corruptSecret }
        }
    }

    /// Retired tombstones are explicit retry state. A cleanup error never
    /// invalidates the already committed head and never revives retired keys.
    private func reconcileCleanupLocked(_ state: AccountTrustStoreState) -> AccountTrustStoreState {
        var remaining: [StoredMaterialReference] = []
        for reference in state.retiredMaterialReferences {
            do {
                try secretStore.delete(matchingKey(for: reference))
                try secretStore.delete(metadataKey(for: reference))
                try secretStore.delete(metadataNonceKey(accountID: reference.accountID, epoch: reference.epoch, keyGeneration: reference.keyGeneration))
            } catch {
                remaining.append(reference)
            }
        }
        var result = state
        var cleanupFailed = !remaining.isEmpty
        if remaining != state.retiredMaterialReferences {
            do {
                let snapshot = try StoredTrustSnapshot(
                    version: 3,
                    checkpoint: state.checkpoint,
                    currentCommit: AccountWireCodec.encodeTrustCommit(state.currentCommit),
                    verifiedEntries: state.verifiedEntries.map(AccountWireCodec.encodeTrustHistoryEntry),
                    materialReferences: state.materialReferences,
                    retiredMaterialReferences: remaining
                )
                let value = try Self.encode(snapshot)
                let digest = Data(SHA256.hash(data: value))
                try saveIndexedImmutable(value, key: snapshotKey(for: state.checkpoint.accountID, digest: digest), kind: .snapshot, accountID: state.checkpoint.accountID)
                let pointer = StoredTrustHead(version: 3, checkpoint: state.checkpoint, snapshotDigest: digest)
                let pointerValue = try Self.encode(pointer)
                if try secretStore.compareAndSwap(expected: state.headValue, replacement: pointerValue, key: headKey(for: state.checkpoint.accountID), attributes: .deviceOnly) {
                    result = try constructState(headValue: pointerValue, pointer: pointer, snapshotValue: value, snapshot: snapshot, materials: state.materials)
                } else if let winner = try loadStateRawLocked(for: state.checkpoint.accountID) {
                    result = winner
                }
            } catch {
                result = state
                cleanupFailed = true
            }
        }
        if garbageCollectLocked(result) == false { cleanupFailed = true }
        result.cleanupRequired = cleanupFailed || !result.retiredMaterialReferences.isEmpty
        return result
    }

    @discardableResult
    private func garbageCollectLocked(_ state: AccountTrustStoreState) -> Bool {
        let reachableSnapshot = snapshotKey(for: state.checkpoint.accountID, digest: state.snapshotDigest)
        let allReferences = state.materialReferences + state.retiredMaterialReferences
        let reachableMaterial = Set(allReferences.flatMap { [matchingKey(for: $0), metadataKey(for: $0)] })
        let reachableNonces = Set(allReferences.map { metadataNonceKey(accountID: $0.accountID, epoch: $0.epoch, keyGeneration: $0.keyGeneration) })
        do {
            return try reconcileGCIndex(
                accountID: state.checkpoint.accountID,
                reachableSnapshots: [reachableSnapshot],
                reachableMaterial: reachableMaterial,
                reachableNonces: reachableNonces
            )
        } catch {
            return false
        }
    }

    private func saveMaterial(_ material: AccountTrustKeyMaterial, reference: StoredMaterialReference) throws {
        let matching = try Self.encode(StoredMaterialHalf(reference: reference, value: material.mailboxMatchingKey))
        let metadata = try Self.encode(StoredMaterialHalf(reference: reference, value: material.metadataKey))
        try saveIndexedImmutable(matching, key: matchingKey(for: reference), kind: .material, accountID: reference.accountID)
        try saveIndexedImmutable(metadata, key: metadataKey(for: reference), kind: .material, accountID: reference.accountID)
    }

    private func saveIndexedImmutable(_ value: Data, key: AccountSecretKey, kind: StoredTrustGCIndex.Kind, accountID: PlainpostAccountID) throws {
        try reserveIndexedKey(key, kind: kind, accountID: accountID)
        try saveImmutable(value, key: key)
    }

    private func reserveIndexedKey(_ key: AccountSecretKey, kind: StoredTrustGCIndex.Kind, accountID: PlainpostAccountID) throws {
        let indexKey = gcIndexKey(for: accountID)
        for _ in 0..<8 {
            let existing = try secretStore.load(indexKey)
            var index = try decodeGCIndex(existing, accountID: accountID)
            if index.contains(key.account, kind: kind) { return }
            try index.insert(
                key.account,
                kind: kind,
                accountID: accountID,
                maximumRetainedGenerations: maxRetainedGenerations
            )
            if try secretStore.compareAndSwap(expected: existing?.value, replacement: Self.encode(index), key: indexKey, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private func reconcileGCIndex(
        accountID: PlainpostAccountID,
        reachableSnapshots: Set<AccountSecretKey>,
        reachableMaterial: Set<AccountSecretKey>,
        reachableNonces: Set<AccountSecretKey>
    ) throws -> Bool {
        let indexKey = gcIndexKey(for: accountID)
        for _ in 0..<8 {
            let existing = try secretStore.load(indexKey)
            guard existing != nil else { return true }
            var index = try decodeGCIndex(existing, accountID: accountID)
            var failed = false
            for (kind, accounts, reachable) in [
                (StoredTrustGCIndex.Kind.snapshot, index.snapshots, reachableSnapshots),
                (.material, index.material, reachableMaterial),
                (.nonce, index.nonces, reachableNonces),
            ] {
                for account in accounts {
                    let key = secretKey(account: account)
                    guard !reachable.contains(key) else { continue }
                    do {
                        try secretStore.delete(key)
                        index.remove(account, kind: kind)
                    } catch { failed = true }
                }
            }
            guard !failed else { return false }
            let replacement = try Self.encode(index)
            if replacement == existing?.value { return true }
            if try secretStore.compareAndSwap(expected: existing?.value, replacement: replacement, key: indexKey, attributes: .deviceOnly) { return true }
        }
        return false
    }

    private func decodeGCIndex(_ record: AccountSecretRecord?, accountID: PlainpostAccountID) throws -> StoredTrustGCIndex {
        guard let record else { return StoredTrustGCIndex() }
        guard record.attributes == .deviceOnly,
              let index = try? Self.decode(StoredTrustGCIndex.self, from: record.value),
              index.isValid(accountID: accountID, maximumRetainedGenerations: maxRetainedGenerations)
        else { throw AccountRuntimeError.corruptSecret }
        return index
    }

    private func saveImmutable(_ value: Data, key: AccountSecretKey) throws {
        if try secretStore.compareAndSwap(expected: nil, replacement: value, key: key, attributes: .deviceOnly) { return }
        guard let existing = try secretStore.load(key), existing.attributes == .deviceOnly, existing.value == value else {
            throw AccountRuntimeError.corruptSecret
        }
    }

    private func secretKey(account: String) -> AccountSecretKey {
        AccountSecretKey(service: service, account: account, accessGroup: accessGroup)
    }

    private func headKey(for accountID: PlainpostAccountID) -> AccountSecretKey {
        secretKey(account: "trust-head.v3.\(accountID.rawValue)")
    }

    private func snapshotKey(for accountID: PlainpostAccountID, digest: Data) -> AccountSecretKey {
        secretKey(account: "trust-snapshot.v3.\(accountID.rawValue).\(AccountWireCodec.encodeBase64URL(digest))")
    }

    private func matchingKey(for reference: StoredMaterialReference) -> AccountSecretKey {
        secretKey(account: "trust-material.v3.\(reference.accountID.rawValue).\(AccountWireCodec.encodeBase64URL(reference.locator)).matching")
    }

    private func metadataKey(for reference: StoredMaterialReference) -> AccountSecretKey {
        secretKey(account: "trust-material.v3.\(reference.accountID.rawValue).\(AccountWireCodec.encodeBase64URL(reference.locator)).metadata")
    }

    private func metadataNonceKey(accountID: PlainpostAccountID, epoch: AccountTrustEpoch, keyGeneration: PositiveUInt64) -> AccountSecretKey {
        secretKey(account: "metadata-nonce.v2.\(accountID.rawValue).\(epoch.wireValue).\(keyGeneration.wireValue)")
    }

    private func gcIndexKey(for accountID: PlainpostAccountID) -> AccountSecretKey {
        secretKey(account: "trust-gc-index.v1.\(accountID.rawValue)")
    }

    private func recordKey(for accountID: PlainpostAccountID, recordID: AccountRecordID) -> AccountSecretKey {
        secretKey(account: "account-record-high-water.v1.\(accountID.rawValue).\(recordID.rawValue)")
    }

    private func recordIndexKey(for accountID: PlainpostAccountID) -> AccountSecretKey {
        secretKey(account: "account-record-high-water-index.v1.\(accountID.rawValue)")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func compareCheckpoint(_ left: AccountTrustCheckpointV1, _ right: AccountTrustCheckpointV1) -> Int {
        if left.epoch != right.epoch { return left.epoch < right.epoch ? -1 : 1 }
        if left.revision != right.revision { return left.revision < right.revision ? -1 : 1 }
        return 0
    }

    private static func compareRecordHighWater(_ left: AccountRecordHighWater, _ right: AccountRecordHighWater) -> Int {
        if left.epoch != right.epoch { return left.epoch < right.epoch ? -1 : 1 }
        if left.keyGeneration != right.keyGeneration { return left.keyGeneration < right.keyGeneration ? -1 : 1 }
        if left.recordRevision != right.recordRevision { return left.recordRevision < right.recordRevision ? -1 : 1 }
        return 0
    }
}

struct MetadataNonceState: Codable, Equatable, Sendable {
    let version: Int
    let namespace: Data
    let nextCounter: UInt32
}

struct StoredRecordHighWaterIndex: Codable, Equatable, Sendable {
    let version: Int
    var recordIDs: [String]

    init() {
        version = 1
        recordIDs = []
    }

    var isValid: Bool {
        version == 1
            && recordIDs.count <= AccountRecordInventoryProofV1.maximumEntries
            && recordIDs == Array(Set(recordIDs)).sorted()
            && recordIDs.allSatisfy { (try? AccountRecordID($0)) != nil }
    }
}

struct StoredTrustGCIndex: Codable, Equatable, Sendable {
    enum Kind {
        case snapshot
        case material
        case nonce
    }

    let version: Int
    var snapshots: [String]
    var material: [String]
    var nonces: [String]

    init() {
        version = 1
        snapshots = []
        material = []
        nonces = []
    }

    func contains(_ account: String, kind: Kind) -> Bool {
        accounts(for: kind).contains(account)
    }

    mutating func insert(
        _ account: String,
        kind: Kind,
        accountID: PlainpostAccountID,
        maximumRetainedGenerations: Int
    ) throws {
        var accounts = accounts(for: kind)
        guard !accounts.contains(account) else { return }
        accounts.append(account)
        accounts.sort()
        setAccounts(accounts, for: kind)
        guard isValid(accountID: accountID, maximumRetainedGenerations: maximumRetainedGenerations) else {
            throw AccountRuntimeError.secretUnavailable
        }
    }

    mutating func remove(_ account: String, kind: Kind) {
        setAccounts(accounts(for: kind).filter { $0 != account }, for: kind)
    }

    func isValid(accountID: PlainpostAccountID, maximumRetainedGenerations: Int) -> Bool {
        guard version == 1,
              maximumRetainedGenerations > 0,
              snapshots.count <= maximumRetainedGenerations * 4,
              material.count <= maximumRetainedGenerations * 2 + 2,
              nonces.count <= maximumRetainedGenerations + 1,
              snapshots.allSatisfy({ Self.isValid($0, kind: .snapshot, accountID: accountID) }),
              material.allSatisfy({ Self.isValid($0, kind: .material, accountID: accountID) }),
              nonces.allSatisfy({ Self.isValid($0, kind: .nonce, accountID: accountID) })
        else { return false }
        return [snapshots, material, nonces].allSatisfy { accounts in
            accounts == Array(Set(accounts)).sorted()
        }
    }

    private static func isValid(_ value: String, kind: Kind, accountID: PlainpostAccountID) -> Bool {
        switch kind {
        case .snapshot:
            let prefix = "trust-snapshot.v3.\(accountID.rawValue)."
            guard value.hasPrefix(prefix) else { return false }
            let digest = String(value.dropFirst(prefix.count))
            return !digest.contains(".")
                && (try? AccountWireCodec.decodeBase64URL(digest, exactBytes: 32)) != nil
        case .material:
            let prefix = "trust-material.v3.\(accountID.rawValue)."
            guard value.hasPrefix(prefix) else { return false }
            let suffix = String(value.dropFirst(prefix.count))
            let terminal: String
            if suffix.hasSuffix(".matching") { terminal = ".matching" }
            else if suffix.hasSuffix(".metadata") { terminal = ".metadata" }
            else { return false }
            let locator = String(suffix.dropLast(terminal.count))
            return !locator.contains(".")
                && (try? AccountWireCodec.decodeBase64URL(locator, exactBytes: 32)) != nil
        case .nonce:
            let prefix = "metadata-nonce.v2.\(accountID.rawValue)."
            guard value.hasPrefix(prefix) else { return false }
            let coordinates = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard coordinates.count == 2 else { return false }
            return (try? PositiveUInt64(wire: String(coordinates[0]))) != nil
                && (try? PositiveUInt64(wire: String(coordinates[1]))) != nil
        }
    }

    private func accounts(for kind: Kind) -> [String] {
        switch kind {
        case .snapshot: snapshots
        case .material: material
        case .nonce: nonces
        }
    }

    private mutating func setAccounts(_ accounts: [String], for kind: Kind) {
        switch kind {
        case .snapshot: snapshots = accounts
        case .material: material = accounts
        case .nonce: nonces = accounts
        }
    }
}

private struct StoredTrustHead: Codable {
    let version: Int
    let checkpoint: AccountTrustCheckpointV1
    let snapshotDigest: Data
}

private struct StoredTrustSnapshot: Codable {
    let version: Int
    let checkpoint: AccountTrustCheckpointV1
    let currentCommit: Data
    let verifiedEntries: [Data]
    let materialReferences: [StoredMaterialReference]
    let retiredMaterialReferences: [StoredMaterialReference]
}

struct StoredMaterialReference: Codable, Hashable, Sendable {
    let accountID: PlainpostAccountID
    let epoch: AccountTrustEpoch
    let keyGeneration: PositiveUInt64
    let trustRevision: PositiveUInt64
    let keyCommitment: Data
    let locator: Data

    var coordinate: AccountTrustMaterialCoordinate {
        AccountTrustMaterialCoordinate(epoch: epoch, keyGeneration: keyGeneration)
    }

    static func lessThan(_ left: Self, _ right: Self) -> Bool {
        if left.epoch != right.epoch { return left.epoch < right.epoch }
        return left.keyGeneration < right.keyGeneration
    }
}

private struct StoredMaterialHalf: Codable {
    let reference: StoredMaterialReference
    let value: Data
}
