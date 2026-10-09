import CryptoKit
import Foundation
import PlainpostAccountProtocol

public struct SessionKeyManifestVerifier: Sendable {
    private let keys: [String: SessionPublicKey]
    public let manifestVersion: UInt64
    public let documentDigest: Data
    public let notBefore: Date
    public let expiresAt: Date

    public init(document: Data, offlineRootKeyID: String, offlineRootPublicKey: Data, now: Date = Date(), requireCurrent: Bool = true) throws {
        guard let current = try? AccountSessionManifestCodec.decodeResponse(document).current,
              current.rootKeyID == offlineRootKeyID,
              let notBefore = AccountWireCodec.parseTimestamp(current.notBefore),
              let expiresAt = AccountWireCodec.parseTimestamp(current.expiresAt),
              let rootKey = try? P256.Signing.PublicKey(x963Representation: offlineRootPublicKey),
              let rootSignature = try? P256.Signing.ECDSASignature(rawRepresentation: current.rootSignature)
        else { throw AccountRuntimeError.untrustedResponse }
        guard !requireCurrent || (now >= notBefore && now < expiresAt) else { throw AccountRuntimeError.untrustedResponse }

        let keyEvaluationTime = requireCurrent ? now : min(max(now, notBefore), expiresAt.addingTimeInterval(-1))
        var parsed: [SessionPublicKey] = []
        var active: [AccountSessionKeyPurpose: Int] = [:]
        for key in current.keys {
            guard let keyNotBefore = AccountWireCodec.parseTimestamp(key.notBefore),
                  let keyExpiresAt = AccountWireCodec.parseTimestamp(key.expiresAt)
            else { throw AccountRuntimeError.untrustedResponse }
            if key.status == .active, keyEvaluationTime >= keyNotBefore, keyEvaluationTime < keyExpiresAt { active[key.purpose, default: 0] += 1 }
            parsed.append(SessionPublicKey(keyID: key.keyID, purpose: key.purpose.rawValue, publicKey: key.publicKey, notBefore: keyNotBefore, expiresAt: keyExpiresAt, status: key.status.rawValue))
        }
        guard active[.access] == 1, active[.offlineLease] == 1,
              rootKey.isValidSignature(rootSignature, for: AccountSessionManifestCodec.transcript(current))
        else { throw AccountRuntimeError.untrustedResponse }
        self.keys = Dictionary(uniqueKeysWithValues: parsed.map { ($0.keyID, $0) })
        manifestVersion = current.manifestVersion.value; documentDigest = Data(SHA256.hash(data: document)); self.notBefore = notBefore; self.expiresAt = expiresAt
    }

    public func isCurrent(at date: Date) -> Bool { date >= notBefore && date < expiresAt }

    /// Central's offline-lease lifetime for Node enrollment.
    public static let nodeEnrollmentLeaseLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// True when a lease issued at `now` for the full lifetime can be verified:
    /// the manifest is current and one active offline_lease key covers
    /// `now ... now + 30 days`.
    public func canVerifyNodeEnrollmentLease(at now: Date) -> Bool {
        guard isCurrent(at: now) else { return false }
        let through = now.addingTimeInterval(Self.nodeEnrollmentLeaseLifetime)
        return keys.values.contains { $0.purpose == "offline_lease" && $0.status == "active" && $0.notBefore <= now && through <= $0.expiresAt }
    }

    public func offlineLeaseVerifier(accountID: PlainpostAccountID, deviceID: AccountDeviceID) -> AccountSessionController.OfflineLeaseVerifier {
        let keys = keys
        return { token, now in Self.verifyLease(token, now: now, accountID: accountID, deviceID: deviceID, keys: keys) }
    }

    /// Verifies the separately canonicalized lease returned by a Sync Node
    /// admission. This uses the existing signed offline-lease key ring and
    /// deliberately introduces no Node-specific trust root.
    public func verifiesNodeEnrollmentLease(_ lease: AccountNodeOfflineLeaseV1, at now: Date) -> Bool {
        guard isCurrent(at: now),
              let key = keys[lease.serverKeyID], key.purpose == "offline_lease", key.status == "active",
              let issuedAt = AccountWireCodec.parseTimestamp(lease.issuedAt),
              let expiresAt = AccountWireCodec.parseTimestamp(lease.expiresAt),
              issuedAt <= now, now < expiresAt,
              key.notBefore <= issuedAt, expiresAt <= key.expiresAt,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: lease.signature)
        else { return false }
        return publicKey.isValidSignature(signature, for: AccountTranscript.nodeOfflineLease(lease))
    }

    public func verifiesNodeEnrollmentLeaseV2(_ lease: AccountNodeOfflineLeaseV2, at now: Date) -> Bool {
        guard isCurrent(at: now), let key = keys[lease.serverKeyID], key.purpose == "offline_lease", key.status == "active",
              let issuedAt = AccountWireCodec.parseTimestamp(lease.issuedAt), let expiresAt = AccountWireCodec.parseTimestamp(lease.expiresAt), issuedAt <= now, now < expiresAt, key.notBefore <= issuedAt, expiresAt <= key.expiresAt,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: lease.signature)
        else { return false }
        return publicKey.isValidSignature(signature, for: AccountTranscript.nodeOfflineLeaseV2(lease))
    }

    private static func verifyLease(_ token: String, now: Date, accountID: PlainpostAccountID, deviceID: AccountDeviceID, keys: [String: SessionPublicKey]) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let header = Data(base64URL: String(parts[0])), let headerObject = try? JSONSerialization.jsonObject(with: header) as? [String: Any], Set(headerObject.keys) == ["alg", "typ"], headerObject["alg"] as? String == "ES256", headerObject["typ"] as? String == "plainpost-session",
              let payload = Data(base64URL: String(parts[1])), payload.count <= 4_096,
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], Set(claims.keys) == ["typ", "kid", "aid", "did", "iat", "exp"],
              claims["typ"] as? String == "offline_lease", let keyID = claims["kid"] as? String, let key = keys[keyID], key.purpose == "offline_lease", key.status != "revoked",
              claims["aid"] as? String == accountID.rawValue, claims["did"] as? String == deviceID.rawValue,
              let iatNumber = claims["iat"] as? NSNumber, let expNumber = claims["exp"] as? NSNumber,
              let signatureData = Data(base64URL: String(parts[2]), exact: 64), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData), let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey),
              publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
        else { return nil }
        let issuedAt = Date(timeIntervalSince1970: iatNumber.doubleValue / 1_000_000_000)
        let expiresAt = Date(timeIntervalSince1970: expNumber.doubleValue / 1_000_000_000)
        guard issuedAt <= now, issuedAt >= key.notBefore, expiresAt <= key.expiresAt, issuedAt < expiresAt, expiresAt.timeIntervalSince(issuedAt) <= 30 * 24 * 60 * 60, now < expiresAt else { return nil }
        return expiresAt
    }

}

public final class SessionKeyManifestStore: @unchecked Sendable {
    public static let bundledRootDescriptor: Data = {
        try! Data(contentsOf: Bundle.module.url(forResource: "production-session-root-descriptor", withExtension: "json")!)
    }()
    private static let bundledRoot: (keyID: String, publicKey: Data) = {
        guard
            let object = try? JSONSerialization.jsonObject(with: bundledRootDescriptor) as? [String: Any],
            Set(object.keys) == Set(["applicationTag", "keyType", "publicKey", "publicKeySHA256", "rootKeyID", "version"]),
            object["applicationTag"] as? String == "com.marynavdovenko.Plainpost.session.offline-root.prod-2026-09",
            object["keyType"] as? String == "P-256 Secure Enclave signing key",
            object["version"] as? Int == 1,
            let keyID = object["rootKeyID"] as? String,
            AccountWireCodec.isKeyID(keyID),
            let encodedKey = object["publicKey"] as? String,
            let publicKey = try? AccountWireCodec.decodeBase64URL(encodedKey, exactBytes: 65),
            let expectedDigest = object["publicKeySHA256"] as? String,
            expectedDigest == SHA256.hash(data: publicKey).map({ String(format: "%02x", $0) }).joined()
        else { fatalError("Invalid bundled production session root descriptor") }
        return (keyID, publicKey)
    }()
    public static let bundledOfflineRootKeyID = bundledRoot.keyID
    public static let bundledOfflineRootPublicKey = bundledRoot.publicKey
    public static let bundledManifest: Data = {
        try! Data(contentsOf: Bundle.module.url(forResource: "production-session-key-manifest-v1", withExtension: "json")!)
    }()
    private struct Cache: Codable { let version: UInt64; let digest: Data; let document: Data }
    private let lock = NSLock(), rootKeyID: String, rootPublicKey: Data, secrets: any AccountSecretStoring, clock: @Sendable () -> Date
    private let cacheKey: AccountSecretKey
    private var current: SessionKeyManifestVerifier!
    public init(bundledDocument: Data, offlineRootKeyID: String, offlineRootPublicKey: Data, secretStore: any AccountSecretStoring = KeychainAccountSecretStore(), clock: @escaping @Sendable () -> Date = Date.init) throws {
        rootKeyID = offlineRootKeyID; rootPublicKey = offlineRootPublicKey; secrets = secretStore; self.clock = clock
        cacheKey = RootScopedManifestCache.key(prefix: "session-key-manifest.high-water.v2", rootKeyID: offlineRootKeyID, rootPublicKey: offlineRootPublicKey)
        let bundled = try SessionKeyManifestVerifier(document: bundledDocument, offlineRootKeyID: offlineRootKeyID, offlineRootPublicKey: offlineRootPublicKey, now: clock(), requireCurrent: false)
        while true {
            if let cached = try secretStore.load(cacheKey) {
                let restored = try decode(cached)
                if restored.manifestVersion == bundled.manifestVersion && restored.documentDigest != bundled.documentDigest { throw AccountRuntimeError.untrustedResponse }
                let selected = restored.manifestVersion > bundled.manifestVersion ? restored : bundled
                guard selected.isCurrent(at: clock()) else { throw AccountRuntimeError.untrustedResponse }
                if selected.documentDigest == restored.documentDigest { current = restored; break }
                let encoded = try encodeCache(bundledDocument, verifier: bundled)
                if try secretStore.compareAndSwap(expected: cached.value, replacement: encoded, key: cacheKey, attributes: .deviceOnly) { current = bundled; break }
                continue
            }
            guard bundled.isCurrent(at: clock()) else { throw AccountRuntimeError.untrustedResponse }
            let encoded = try encodeCache(bundledDocument, verifier: bundled)
            if try secretStore.compareAndSwap(expected: nil, replacement: encoded, key: cacheKey, attributes: .deviceOnly) { current = bundled; break }
        }
    }
    public func accept(_ document: Data) throws {
        let candidate = try SessionKeyManifestVerifier(document: document, offlineRootKeyID: rootKeyID, offlineRootPublicKey: rootPublicKey, now: clock())
        lock.lock(); defer { lock.unlock() }
        while true {
            guard let stored = try secrets.load(cacheKey) else { throw AccountRuntimeError.corruptSecret }
            let observed = try decode(stored)
            guard candidate.manifestVersion > observed.manifestVersion || (candidate.manifestVersion == observed.manifestVersion && candidate.documentDigest == observed.documentDigest) else { throw AccountRuntimeError.untrustedResponse }
            if candidate.manifestVersion == observed.manifestVersion { current = observed; return }
            let encoded = try encodeCache(document, verifier: candidate)
            if try secrets.compareAndSwap(expected: stored.value, replacement: encoded, key: cacheKey, attributes: .deviceOnly) { current = candidate; return }
        }
    }
    public func verifier() throws -> SessionKeyManifestVerifier {
        lock.lock(); defer { lock.unlock() }
        guard let stored = try secrets.load(cacheKey) else { throw AccountRuntimeError.corruptSecret }
        let observed = try decode(stored)
        guard observed.isCurrent(at: clock()) else { throw AccountRuntimeError.untrustedResponse }
        guard observed.manifestVersion > current.manifestVersion || (observed.manifestVersion == current.manifestVersion && observed.documentDigest == current.documentDigest) else { throw AccountRuntimeError.untrustedResponse }
        current = observed
        return current
    }
    public func fetch(using transport: any AccountHTTPTransport, baseURL: URL = AccountAPIClient.productionBaseURL) async throws {
        guard let url = URL(string: "/.well-known/plainpost/session-keys", relativeTo: baseURL), url.scheme == "https", url.host == baseURL.host else { throw AccountRuntimeError.transportFailure }
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 20; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard response.statusCode == 200, !response.body.isEmpty, response.body.count <= AccountWireCodec.maxBodyBytes, response.headers.first(where: { $0.key.caseInsensitiveCompare("content-type") == .orderedSame })?.value.lowercased().hasPrefix("application/json") == true else { throw AccountRuntimeError.untrustedResponse }
        try accept(response.body)
    }
    private func encodeCache(_ document: Data, verifier: SessionKeyManifestVerifier) throws -> Data { try JSONEncoder().encode(Cache(version: verifier.manifestVersion, digest: verifier.documentDigest, document: document)) }
    private func decode(_ record: AccountSecretRecord) throws -> SessionKeyManifestVerifier {
        guard record.attributes == .deviceOnly, let value = try? JSONDecoder().decode(Cache.self, from: record.value), value.digest == Data(SHA256.hash(data: value.document)) else { throw AccountRuntimeError.corruptSecret }
        let verifier = try SessionKeyManifestVerifier(document: value.document, offlineRootKeyID: rootKeyID, offlineRootPublicKey: rootPublicKey, now: clock(), requireCurrent: false)
        guard verifier.manifestVersion == value.version, verifier.documentDigest == value.digest else { throw AccountRuntimeError.corruptSecret }
        return verifier
    }
}

private struct SessionPublicKey: Sendable { let keyID: String; let purpose: String; let publicKey: Data; let notBefore: Date; let expiresAt: Date; let status: String }

private extension Data {
    init?(base64URL value: String, exact: Int? = nil) {
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), exact == nil || decoded.count == exact else { return nil }
        self = decoded
    }
}
