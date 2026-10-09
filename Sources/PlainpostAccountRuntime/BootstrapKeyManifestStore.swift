import CryptoKit
import Foundation
import OSLog
import PlainpostAccountProtocol

private let accountTrustPageLogger = Logger(
    subsystem: "com.marynavdovenko.Plainpost",
    category: "account-security"
)

/// Stores only independently root-authenticated public online keys. The
/// response transport has no authority: every cached member is checked again
/// after decoding and before it can select a verification key.
public final class BootstrapKeyManifestStore: @unchecked Sendable {
    private let offlineRootKeyID: String
    private let offlineRootPublicKey: Data
    private let secretStore: any AccountSecretStoring
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var manifest: AccountBootstrapManifest
    private var overlap: [AccountBootstrapManifest]
    private let cacheKey: AccountSecretKey

    // Production defaults come only from public, app-bundled artifacts. Tests
    // using the legacy synthetic root must inject it explicitly.
    public static let bundledRootDescriptor: Data = { try! Data(contentsOf: Bundle.module.url(forResource: "production-root-descriptor", withExtension: "json")!) }()
    private static let bundledRoot: (keyID: String, publicKey: Data) = {
        guard
            let object = try? JSONSerialization.jsonObject(with: bundledRootDescriptor) as? [String: Any],
            Set(object.keys) == Set(["applicationTag", "keyType", "publicKey", "publicKeySHA256", "rootKeyID", "version"]),
            object["applicationTag"] as? String == "com.marynavdovenko.Plainpost.account.offline-root.prod-2026-09",
            object["keyType"] as? String == "P-256 Secure Enclave signing key",
            object["version"] as? Int == 1,
            let keyID = object["rootKeyID"] as? String,
            AccountWireCodec.isKeyID(keyID),
            let encodedKey = object["publicKey"] as? String,
            let publicKey = try? AccountWireCodec.decodeBase64URL(encodedKey, exactBytes: 65),
            let expectedDigest = object["publicKeySHA256"] as? String,
            expectedDigest == SHA256.hash(data: publicKey).map({ String(format: "%02x", $0) }).joined()
        else { fatalError("Invalid bundled production root descriptor") }
        return (keyID, publicKey)
    }()
    public static let bundledOfflineRootKeyID = bundledRoot.keyID
    public static let bundledOfflineRootPublicKey = bundledRoot.publicKey
    public static let bundledManifest: Data = { try! Data(contentsOf: Bundle.module.url(forResource: "central-bootstrap-manifest-v1", withExtension: "json")!) }()

    public init(
        bundledManifest: Data = BootstrapKeyManifestStore.bundledManifest,
        offlineRootKeyID: String = BootstrapKeyManifestStore.bundledOfflineRootKeyID,
        offlineRootPublicKey: Data = BootstrapKeyManifestStore.bundledOfflineRootPublicKey,
        secretStore: any AccountSecretStoring = KeychainAccountSecretStore(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard AccountWireCodec.isKeyID(offlineRootKeyID) else { throw AccountRuntimeError.untrustedResponse }
        do { _ = try P256.Signing.PublicKey(x963Representation: offlineRootPublicKey) } catch { throw AccountRuntimeError.untrustedResponse }
        self.offlineRootKeyID = offlineRootKeyID
        self.offlineRootPublicKey = offlineRootPublicKey
        self.secretStore = secretStore
        self.clock = clock
        cacheKey = RootScopedManifestCache.key(prefix: "manifest.cache.v3", rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey)

        let bundled = try AccountWireCodec.decodeManifest(bundledManifest)
        try Self.verify(bundled, rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock())
        try Self.verifyCurrentPurposes(bundled, now: clock())
        manifest = bundled
        overlap = []

        lock.lock()
        defer { lock.unlock() }
        if let cached = try secretStore.load(cacheKey) {
            guard cached.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            let restored = try Self.decodeCache(cached.value, rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock())
            manifest = restored.current
            overlap = restored.overlap
        } else {
            let prepared = try Self.prepare(current: bundled, overlap: [], rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock())
            try persist(prepared)
        }
    }

    public func currentManifest() -> AccountBootstrapManifest {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    /// Compatibility entry point for a directly root-signed manifest.
    public func accept(_ data: Data) throws {
        let candidate = try AccountWireCodec.decodeManifest(data)
        try acceptPrepared(Self.prepare(current: candidate, overlap: [], rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock()))
    }

    /// Decodes the fixed well-known response. It is intentionally separate
    /// from arbitrary API response handling so only this closed resource can
    /// alter bootstrap authority.
    public func acceptManifestResponse(_ data: Data) throws {
        let response = try AccountWireCodec.decodeManifestResponse(data)
        try acceptPrepared(Self.prepare(current: response.current, overlap: response.overlap, rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock()))
    }

    public func key(id: String, purpose: AccountKeyPurpose, signedAt: String) throws -> Data {
        guard let signedTime = AccountWireCodec.parseTrustTimestamp(signedAt) else { throw AccountRuntimeError.untrustedResponse }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        for candidate in [manifest] + overlap {
            guard let manifestStart = AccountWireCodec.parseTimestamp(candidate.notBefore), let manifestEnd = AccountWireCodec.parseTimestamp(candidate.expiresAt), now >= manifestStart, now < manifestEnd else { continue }
            if let selected = candidate.keys.first(where: { $0.keyID == id && $0.purpose == purpose && $0.status == .active }), let start = AccountWireCodec.parseTimestamp(selected.notBefore), let end = AccountWireCodec.parseTimestamp(selected.expiresAt), now >= start, now < end, signedTime >= start, signedTime < end {
                return selected.publicKey
            }
        }
        throw AccountRuntimeError.untrustedResponse
    }

    public func verifyBootstrapChallenge(_ challenge: AccountBootstrapChallenge) throws {
        let now = clock()
        guard let createdAt = AccountWireCodec.parseTimestamp(challenge.createdAt), let expiresAt = AccountWireCodec.parseTimestamp(challenge.expiresAt), createdAt <= now, now < expiresAt, expiresAt.timeIntervalSince(createdAt) <= 300 else { throw AccountRuntimeError.untrustedResponse }
        let key = try self.key(id: challenge.serverKeyID, purpose: .bootstrapChallenge, signedAt: challenge.createdAt)
        try Self.verify(signature: challenge.serverSignature, publicKey: key, transcript: AccountTranscript.bootstrapChallenge(challenge))
    }

    public func verifyRecordInventoryProof(
        _ proof: AccountRecordInventoryProofV1,
        expectedAccountID: PlainpostAccountID,
        expectedTrustCommitDigest: Data,
        expectedEpoch: AccountTrustEpoch,
        expectedKeyGeneration: PositiveUInt64
    ) throws {
        let now = clock()
        guard proof.accountID == expectedAccountID,
              proof.trustCommitDigest == expectedTrustCommitDigest,
              proof.epoch == expectedEpoch,
              proof.keyGeneration == expectedKeyGeneration,
              let issuedAt = AccountWireCodec.parseTimestamp(proof.issuedAt),
              let expiresAt = AccountWireCodec.parseTimestamp(proof.expiresAt),
              issuedAt <= now,
              now < expiresAt
        else { throw AccountRuntimeError.untrustedResponse }
        let publicKey = try key(id: proof.serverKeyID, purpose: .trustPagination, signedAt: proof.issuedAt)
        try Self.verify(
            signature: proof.serverSignature,
            publicKey: publicKey,
            transcript: AccountTrustTranscript.recordInventoryProof(proof)
        )
    }

    public func verifyStepUpAuthorization(_ authorization: AccountStepUpAuthorizationV1, now: Date? = nil) throws {
        let verificationTime = now ?? clock()
        guard let issuedAt = AccountWireCodec.parseTimestamp(authorization.issuedAt),
              let expiresAt = AccountWireCodec.parseTimestamp(authorization.expiresAt),
              issuedAt <= verificationTime, verificationTime < expiresAt,
              expiresAt.timeIntervalSince(issuedAt) <= 300
        else { throw AccountRuntimeError.untrustedResponse }
        let publicKey = try key(id: authorization.serverKeyID, purpose: .recoveryAuthorization, signedAt: authorization.issuedAt)
        try Self.verify(signature: authorization.serverSignature, publicKey: publicKey, transcript: AccountTranscript.stepUpAuthorization(authorization))
    }

    public func verifyTrustStatePage(_ page: AccountTrustStatePageV1, expectedAccountID: PlainpostAccountID, expectedAfter: AccountTrustAfterV1, expectedCursor: AccountTrustCursorV1? = nil) throws {
        let now = clock()
        guard page.accountID == expectedAccountID,
              page.requestCursor.after == expectedAfter,
              expectedCursor.map({ $0 == page.requestCursor }) ?? true
        else {
            accountTrustPageLogger.error("trust_page_rejected reason=request_context")
            throw AccountRuntimeError.untrustedResponse
        }
        guard let issued = AccountWireCodec.parseTrustTimestamp(page.issuedAt),
              let expires = AccountWireCodec.parseTrustTimestamp(page.expiresAt),
              issued <= now, now < expires, expires.timeIntervalSince(issued) <= 300
        else {
            accountTrustPageLogger.error("trust_page_rejected reason=validity_window")
            throw AccountRuntimeError.untrustedResponse
        }
        let key: Data
        do {
            key = try self.key(id: page.serverKeyID, purpose: .trustPagination, signedAt: page.issuedAt)
        } catch {
            accountTrustPageLogger.error("trust_page_rejected reason=signing_key")
            throw error
        }
        do {
            try Self.verify(signature: page.requestCursor.signature, publicKey: key, transcript: AccountTrustTranscript.trustCursor(page.requestCursor))
        } catch {
            accountTrustPageLogger.error("trust_page_rejected reason=request_cursor_signature")
            throw error
        }
        if let next = page.nextCursor {
            guard next.accountID == page.accountID, next.snapshotHead == page.snapshotHead, next.issuedAt == page.issuedAt, next.expiresAt == page.expiresAt, next.serverKeyID == page.serverKeyID else {
                accountTrustPageLogger.error("trust_page_rejected reason=next_cursor_context")
                throw AccountRuntimeError.untrustedResponse
            }
            do {
                try Self.verify(signature: next.signature, publicKey: key, transcript: AccountTrustTranscript.trustCursor(next))
            } catch {
                accountTrustPageLogger.error("trust_page_rejected reason=next_cursor_signature")
                throw error
            }
        }
        do {
            try Self.verify(signature: page.serverSignature, publicKey: key, transcript: AccountTrustTranscript.trustStatePage(page))
        } catch {
            accountTrustPageLogger.error("trust_page_rejected reason=page_signature")
            throw error
        }
    }

    public func verifyRecoveryAuthorization(
        _ authorization: AccountRecoveryAuthorization,
        expectedAccountID: PlainpostAccountID,
        expectedEpoch: AccountTrustEpoch,
        expectedDeviceID: AccountDeviceID,
        expectedPlatform: AccountPlatform,
        expectedPublicBundle: AccountPublicKeyBundle,
        expectedPriorCommitDigest: Data,
        expectedExchangeRequestDigest: Data
    ) throws -> AccountBootstrapManifest {
        let now = clock()
        guard let issuedAt = AccountWireCodec.parseTimestamp(authorization.issuedAt),
              let expiresAt = AccountWireCodec.parseTimestamp(authorization.expiresAt),
              issuedAt <= now, now < expiresAt
        else { throw AccountRuntimeError.untrustedResponse }
        lock.lock()
        let candidates = [manifest] + overlap
        lock.unlock()
        for candidate in candidates {
            guard let manifestStart = AccountWireCodec.parseTimestamp(candidate.notBefore),
                  let manifestEnd = AccountWireCodec.parseTimestamp(candidate.expiresAt),
                  now >= manifestStart,
                  now < manifestEnd,
                  candidate.keys.contains(where: {
                      $0.keyID == authorization.serverKeyID &&
                      $0.purpose == .recoveryAuthorization &&
                      $0.status == .active
                  })
            else { continue }
            do {
                try verifyHistoricalRecoveryAuthorization(
                    authorization,
                    historicalManifest: candidate,
                    expectedAccountID: expectedAccountID,
                    expectedEpoch: expectedEpoch,
                    expectedDeviceID: expectedDeviceID,
                    expectedPlatform: expectedPlatform,
                    expectedPublicBundle: expectedPublicBundle,
                    expectedPriorCommitDigest: expectedPriorCommitDigest,
                    expectedExchangeRequestDigest: expectedExchangeRequestDigest
                )
                return candidate
            } catch { continue }
        }
        throw AccountRuntimeError.untrustedResponse
    }

    /// Revalidates an already committed recovery as historical authority. The
    /// signed authorization window must be internally valid and its signing key
    /// purpose-valid at `issuedAt`, but it need not still be live now.
    public func verifyHistoricalRecoveryAuthorization(
        _ authorization: AccountRecoveryAuthorization,
        historicalManifest: AccountBootstrapManifest,
        expectedAccountID: PlainpostAccountID,
        expectedEpoch: AccountTrustEpoch,
        expectedDeviceID: AccountDeviceID,
        expectedPlatform: AccountPlatform,
        expectedPublicBundle: AccountPublicKeyBundle,
        expectedPriorCommitDigest: Data,
        expectedExchangeRequestDigest: Data
    ) throws {
        try Self.verifyHistoricalRecoveryAuthorization(
            authorization,
            historicalManifest: historicalManifest,
            offlineRootKeyID: offlineRootKeyID,
            offlineRootPublicKey: offlineRootPublicKey,
            expectedAccountID: expectedAccountID,
            expectedEpoch: expectedEpoch,
            expectedDeviceID: expectedDeviceID,
            expectedPlatform: expectedPlatform,
            expectedPublicBundle: expectedPublicBundle,
            expectedPriorCommitDigest: expectedPriorCommitDigest,
            expectedExchangeRequestDigest: expectedExchangeRequestDigest
        )
    }

    public static func verifyHistoricalRecoveryAuthorization(
        _ authorization: AccountRecoveryAuthorization,
        historicalManifest: AccountBootstrapManifest,
        offlineRootKeyID: String,
        offlineRootPublicKey: Data,
        expectedAccountID: PlainpostAccountID,
        expectedEpoch: AccountTrustEpoch,
        expectedDeviceID: AccountDeviceID,
        expectedPlatform: AccountPlatform,
        expectedPublicBundle: AccountPublicKeyBundle,
        expectedPriorCommitDigest: Data,
        expectedExchangeRequestDigest: Data
    ) throws {
        guard authorization.accountID == expectedAccountID,
              authorization.epoch == expectedEpoch,
              authorization.deviceID == expectedDeviceID,
              authorization.platform == expectedPlatform,
              authorization.platform != .syncNode,
              authorization.publicBundle == expectedPublicBundle,
              authorization.priorCommitDigest == expectedPriorCommitDigest,
              authorization.exchangeRequestDigest == expectedExchangeRequestDigest,
              let issuedAt = AccountWireCodec.parseTimestamp(authorization.issuedAt),
              let expiresAt = AccountWireCodec.parseTimestamp(authorization.expiresAt),
              issuedAt < expiresAt,
              expiresAt.timeIntervalSince(issuedAt) <= 300
        else { throw AccountRuntimeError.untrustedResponse }
        try Self.verify(
            historicalManifest,
            rootKeyID: offlineRootKeyID,
            rootPublicKey: offlineRootPublicKey,
            now: issuedAt
        )
        guard let keyEntry = historicalManifest.keys.first(where: {
            $0.keyID == authorization.serverKeyID &&
            $0.purpose == .recoveryAuthorization &&
            $0.status == .active
        }),
        let keyStart = AccountWireCodec.parseTimestamp(keyEntry.notBefore),
        let keyEnd = AccountWireCodec.parseTimestamp(keyEntry.expiresAt),
        issuedAt >= keyStart, issuedAt < keyEnd
        else { throw AccountRuntimeError.untrustedResponse }
        let key = keyEntry.publicKey
        try Self.verify(signature: authorization.serverSignature, publicKey: key, transcript: AccountTranscript.recoveryAuthorization(authorization))
    }

    private func acceptPrepared(_ prepared: PreparedManifestCache) throws {
        lock.lock(); defer { lock.unlock() }
        try persist(prepared)
        manifest = prepared.current
        overlap = prepared.overlap
    }

    /// Serialized compare-and-swap makes this safe even when separate app
    /// processes construct independent stores against one Keychain item.
    private func persist(_ prepared: PreparedManifestCache) throws {
        for _ in 0..<8 {
            let existing = try secretStore.load(cacheKey)
            if let existing {
                guard existing.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
                let current = try Self.decodeCache(existing.value, rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey, now: clock())
                guard current.highestVersion <= prepared.highestVersion else { throw AccountRuntimeError.untrustedResponse }
                if current.highestVersion == prepared.highestVersion, current.highestDigest != prepared.highestDigest { throw AccountRuntimeError.untrustedResponse }
            }
            let encoded = try JSONEncoder().encode(prepared.record)
            if try secretStore.compareAndSwap(expected: existing?.value, replacement: encoded, key: cacheKey, attributes: .deviceOnly) { return }
        }
        throw AccountRuntimeError.secretUnavailable
    }

    private static func prepare(current: AccountBootstrapManifest, overlap: [AccountBootstrapManifest], rootKeyID: String, rootPublicKey: Data, now: Date) throws -> PreparedManifestCache {
        guard overlap.count <= 4 else { throw AccountRuntimeError.untrustedResponse }
        try verify(current, rootKeyID: rootKeyID, rootPublicKey: rootPublicKey, now: now)
        try verifyCurrentPurposes(current, now: now)
        let currentDigest = digest(current)
        var versions = [current.manifestVersion.value: currentDigest]
        var pairs = Set<ManifestPair>()
        guard pairs.insert(ManifestPair(version: current.manifestVersion.value, digest: currentDigest)).inserted else { throw AccountRuntimeError.untrustedResponse }
        for item in overlap {
            try verify(item, rootKeyID: rootKeyID, rootPublicKey: rootPublicKey, now: now)
            let itemDigest = digest(item)
            guard item.manifestVersion < current.manifestVersion, versions[item.manifestVersion.value] == nil, pairs.insert(ManifestPair(version: item.manifestVersion.value, digest: itemDigest)).inserted else { throw AccountRuntimeError.untrustedResponse }
            versions[item.manifestVersion.value] = itemDigest
        }
        let record = ManifestCacheRecord(version: 1, highestVersion: current.manifestVersion, highestDigest: currentDigest, current: try AccountWireCodec.encodeManifest(current), overlap: try overlap.map(AccountWireCodec.encodeManifest))
        return PreparedManifestCache(current: current, overlap: overlap, highestVersion: current.manifestVersion, highestDigest: currentDigest, record: record)
    }

    private static func decodeCache(_ data: Data, rootKeyID: String, rootPublicKey: Data, now: Date) throws -> PreparedManifestCache {
        guard let cache = try? JSONDecoder().decode(ManifestCacheRecord.self, from: data), cache.version == 1, cache.overlap.count <= 4 else { throw AccountRuntimeError.corruptSecret }
        do {
            let current = try AccountWireCodec.decodeManifest(cache.current)
            let overlap = try cache.overlap.map(AccountWireCodec.decodeManifest)
            let prepared = try prepare(current: current, overlap: overlap, rootKeyID: rootKeyID, rootPublicKey: rootPublicKey, now: now)
            guard prepared.highestVersion == cache.highestVersion, prepared.highestDigest == cache.highestDigest else { throw AccountRuntimeError.corruptSecret }
            return prepared
        } catch let error as AccountRuntimeError { throw error }
        catch { throw AccountRuntimeError.corruptSecret }
    }

    private static func digest(_ manifest: AccountBootstrapManifest) -> Data {
        Data(SHA256.hash(data: AccountTranscript.manifest(rootKeyID: manifest.rootKeyID, version: manifest.manifestVersion, notBefore: manifest.notBefore, expiresAt: manifest.expiresAt, previousDigest: manifest.previousManifestDigest, keys: manifest.keys) + AccountTranscript.part(manifest.rootSignature)))
    }

    private static func verifyCurrentPurposes(_ manifest: AccountBootstrapManifest, now: Date) throws {
        let required = Set([AccountKeyPurpose.bootstrapChallenge, .trustPagination, .recoveryAuthorization])
        let active = Set(manifest.keys.compactMap { key -> AccountKeyPurpose? in
            guard key.status == .active, let start = AccountWireCodec.parseTimestamp(key.notBefore), let end = AccountWireCodec.parseTimestamp(key.expiresAt), now >= start, now < end else { return nil }
            return key.purpose
        })
        guard required.isSubset(of: active) else { throw AccountRuntimeError.untrustedResponse }
    }

    private static func verify(_ manifest: AccountBootstrapManifest, rootKeyID: String, rootPublicKey: Data, now: Date) throws {
        guard manifest.rootKeyID == rootKeyID, let start = AccountWireCodec.parseTimestamp(manifest.notBefore), let end = AccountWireCodec.parseTimestamp(manifest.expiresAt), now >= start, now < end, manifest.keys.allSatisfy({ $0.publicKey != rootPublicKey }), Set(manifest.keys.map(\.publicKey)).count == manifest.keys.count else { throw AccountRuntimeError.untrustedResponse }
        for key in manifest.keys {
            guard let keyStart = AccountWireCodec.parseTimestamp(key.notBefore), let keyEnd = AccountWireCodec.parseTimestamp(key.expiresAt), keyStart >= start, keyEnd <= end, keyStart < keyEnd else { throw AccountRuntimeError.untrustedResponse }
            do { _ = try P256.Signing.PublicKey(x963Representation: key.publicKey) } catch { throw AccountRuntimeError.untrustedResponse }
        }
        try verify(signature: manifest.rootSignature, publicKey: rootPublicKey, transcript: AccountTranscript.manifest(rootKeyID: manifest.rootKeyID, version: manifest.manifestVersion, notBefore: manifest.notBefore, expiresAt: manifest.expiresAt, previousDigest: manifest.previousManifestDigest, keys: manifest.keys))
    }

    private static func verify(signature: Data, publicKey: Data, transcript: Data) throws {
        do {
            try AccountWireCodec.validateLowSSignature(signature)
            let key = try P256.Signing.PublicKey(x963Representation: publicKey)
            let raw = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(raw, for: transcript) else { throw AccountRuntimeError.untrustedResponse }
        } catch { throw AccountRuntimeError.untrustedResponse }
    }
}

private struct ManifestPair: Hashable { let version: UInt64; let digest: Data }
private struct ManifestCacheRecord: Codable { let version: Int; let highestVersion: PositiveUInt64; let highestDigest: Data; let current: Data; let overlap: [Data] }
private struct PreparedManifestCache {
    let current: AccountBootstrapManifest
    let overlap: [AccountBootstrapManifest]
    let highestVersion: PositiveUInt64
    let highestDigest: Data
    let record: ManifestCacheRecord
}
