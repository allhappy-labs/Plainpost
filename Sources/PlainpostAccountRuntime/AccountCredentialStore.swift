import CryptoKit
import Foundation
import PlainpostAccountProtocol
#if canImport(Security)
import Security
#endif

public enum AccountRuntimeError: Error, Equatable, Sendable { case secretUnavailable, corruptSecret, cryptographicFailure, untrustedResponse, transportFailure, cancelled }

public enum PlainpostAccountSharedKeychain {
    public static let accessGroup = "9XN7WN8JN2.com.marynavdovenko.Plainpost.AccountShared"
}

/// The iOS app's own Keychain access group: its application identifier, which
/// is always an entitled group. Secret-bearing Sync Node setup material uses it
/// so the Notification Service extension, which shares the app's first
/// `keychain-access-groups` entry (`…com.marynavdovenko.Plainpost.notifications`),
/// can never read it.
public enum PlainpostIOSAppKeychain {
    public static let accessGroup = "9XN7WN8JN2.com.marynavdovenko.Plainpost.iOS"
    /// The group shared with the Notification Service extension, which is
    /// also the iOS app's default group for items written without one. It is
    /// named only to move earlier Sync Node records out of it.
    public static let notificationsAccessGroup = "9XN7WN8JN2.com.marynavdovenko.Plainpost.notifications"
}

public struct AccountSecretKey: Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }
}
public enum AccountSecretAccessibility: Sendable, Equatable { case afterFirstUnlockThisDeviceOnly }
public struct AccountSecretAttributes: Sendable, Equatable { public let accessibility: AccountSecretAccessibility; public let synchronizable: Bool; public static let deviceOnly = AccountSecretAttributes(accessibility: .afterFirstUnlockThisDeviceOnly, synchronizable: false); public init(accessibility: AccountSecretAccessibility, synchronizable: Bool) { self.accessibility = accessibility; self.synchronizable = synchronizable } }
public struct AccountSecretRecord: Sendable, Equatable { public let value: Data; public let attributes: AccountSecretAttributes; public init(value: Data, attributes: AccountSecretAttributes) { self.value = value; self.attributes = attributes } }

public protocol AccountSecretStoring: Sendable {
    func load(_ key: AccountSecretKey) throws -> AccountSecretRecord?
    func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws
    /// Atomically changes a record only when its complete previous value still
    /// matches. This is the cross-instance primitive for versioned account
    /// records; callers must not emulate it with load followed by replace.
    func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool
    func delete(_ key: AccountSecretKey) throws
}

public final class InMemoryAccountSecretStore: AccountSecretStoring, @unchecked Sendable {
    private let lock = NSLock(); public private(set) var records: [AccountSecretKey: AccountSecretRecord] = [:]
    public init() {}
    public func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? { lock.lock(); defer { lock.unlock() }; return records[key] }
    public func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws { lock.lock(); defer { lock.unlock() }; records[key] = AccountSecretRecord(value: value, attributes: attributes) }
    public func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard records[key]?.value == expected else { return false }
        records[key] = AccountSecretRecord(value: replacement, attributes: attributes)
        return true
    }
    public func delete(_ key: AccountSecretKey) throws { lock.lock(); defer { lock.unlock() }; records.removeValue(forKey: key) }
}

#if canImport(Security)
public final class KeychainAccountSecretStore: AccountSecretStoring, @unchecked Sendable {
    public init() {}
    public func load(_ key: AccountSecretKey) throws -> AccountSecretRecord? {
        var query = baseQuery(for: key)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { throw AccountRuntimeError.secretUnavailable }
        guard item[kSecAttrAccessible as String] as? String == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String), item[kSecAttrSynchronizable as String] as? Bool != true else { throw AccountRuntimeError.corruptSecret }
        return AccountSecretRecord(value: data, attributes: .deviceOnly)
    }
    public func replace(_ value: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws {
        guard attributes == .deviceOnly else { throw AccountRuntimeError.secretUnavailable }
        let query = baseQuery(for: key)
        let replacement: [String: Any] = [kSecValueData as String: value, kSecAttrGeneric as String: Self.recordDigest(value), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AccountRuntimeError.secretUnavailable }
        var add = query; add[kSecValueData as String] = value; add[kSecAttrGeneric as String] = Self.recordDigest(value); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AccountRuntimeError.secretUnavailable }
    }
    public func compareAndSwap(expected: Data?, replacement: Data, key: AccountSecretKey, attributes: AccountSecretAttributes) throws -> Bool {
        guard attributes == .deviceOnly else { throw AccountRuntimeError.secretUnavailable }
        let base = baseQuery(for: key)
        if let expected {
            var query = base
            query[kSecAttrGeneric as String] = Self.recordDigest(expected)
            let replacementAttributes: [String: Any] = [kSecValueData as String: replacement, kSecAttrGeneric as String: Self.recordDigest(replacement), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, replacementAttributes as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound { return false }
            throw AccountRuntimeError.secretUnavailable
        }
        var add = base
        add[kSecValueData as String] = replacement
        add[kSecAttrGeneric as String] = Self.recordDigest(replacement)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem { return false }
        throw AccountRuntimeError.secretUnavailable
    }
    public func delete(_ key: AccountSecretKey) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountRuntimeError.secretUnavailable }
    }
    private func baseQuery(for key: AccountSecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup = key.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func recordDigest(_ value: Data) -> Data { Data(SHA256.hash(data: value)) }
}
#endif

struct AccountOpaqueSigningIdentity: @unchecked Sendable {
    let publicKey: Data
    let persistentReference: Data
    let sign: @Sendable (Data) throws -> Data
    init(publicKey: Data, persistentReference: Data, sign: @escaping @Sendable (Data) throws -> Data) throws {
        guard !persistentReference.isEmpty else { throw AccountRuntimeError.corruptSecret }
        do { _ = try P256.Signing.PublicKey(x963Representation: publicKey) } catch { throw AccountRuntimeError.corruptSecret }
        self.publicKey = publicKey
        self.persistentReference = persistentReference
        self.sign = sign
    }
}

struct AccountOpaqueAgreementIdentity: @unchecked Sendable {
    let publicKey: Data
    let persistentReference: Data
    let sharedSecret: @Sendable (Data) throws -> AccountSharedSecret
    init(publicKey: Data, persistentReference: Data, sharedSecret: @escaping @Sendable (Data) throws -> AccountSharedSecret) throws {
        guard !persistentReference.isEmpty else { throw AccountRuntimeError.corruptSecret }
        do { _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey) } catch { throw AccountRuntimeError.corruptSecret }
        self.publicKey = publicKey; self.persistentReference = persistentReference; self.sharedSecret = sharedSecret
    }
}

/// CryptoKit intentionally does not expose a public initializer for
/// `SharedSecret`.  Security.framework therefore returns the ECDH bytes for
/// Secure Enclave keys, and this small internal value preserves the same KDF
/// seam used by CryptoKit's `SharedSecret` without exporting private material.
struct AccountSharedSecret: @unchecked Sendable {
    private let bytes: Data

    init(_ bytes: Data) { self.bytes = bytes }
    init(_ shared: SharedSecret) {
        self.bytes = shared.withUnsafeBytes { Data($0) }
    }

    func hkdfDerivedSymmetricKey<H: HashFunction>(
        using hashFunction: H.Type,
        salt: Data,
        sharedInfo: Data,
        outputByteCount: Int
    ) -> SymmetricKey {
        HKDF<H>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: salt,
            info: sharedInfo,
            outputByteCount: outputByteCount
        )
    }
}

public struct AccountDeviceIdentity: @unchecked Sendable, Equatable {
    public let publicBundle: AccountPublicKeyBundle
    private let signingPrivateKey: Data?
    private let opaqueSigning: AccountOpaqueSigningIdentity?
    private let agreementPrivateKey: Data?
    private let opaqueAgreement: AccountOpaqueAgreementIdentity?
    init(signingPrivateKey: Data, agreementPrivateKey: Data) throws {
        guard signingPrivateKey.count == 32, agreementPrivateKey.count == 32 else { throw AccountRuntimeError.corruptSecret }
        do {
            let signing = try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
            self.signingPrivateKey = signingPrivateKey; self.opaqueSigning = nil; self.agreementPrivateKey = agreementPrivateKey; self.opaqueAgreement = nil
            self.publicBundle = try AccountPublicKeyBundle(signingKey: signing.publicKey.x963Representation, agreementKey: agreement.publicKey.x963Representation)
        } catch { throw AccountRuntimeError.corruptSecret }
    }
    init(opaqueSigning: AccountOpaqueSigningIdentity, opaqueAgreement: AccountOpaqueAgreementIdentity) throws {
        do {
            signingPrivateKey = nil; self.opaqueSigning = opaqueSigning; agreementPrivateKey = nil; self.opaqueAgreement = opaqueAgreement
            publicBundle = try AccountPublicKeyBundle(signingKey: opaqueSigning.publicKey, agreementKey: opaqueAgreement.publicKey)
        } catch { throw AccountRuntimeError.corruptSecret }
    }
    public static func generate() throws -> AccountDeviceIdentity { try AccountDeviceIdentity(signingPrivateKey: P256.Signing.PrivateKey().rawRepresentation, agreementPrivateKey: P256.KeyAgreement.PrivateKey().rawRepresentation) }
    public func signature(for transcript: Data) throws -> Data {
        do {
            let raw: Data
            if let opaqueSigning { raw = try opaqueSigning.sign(transcript) }
            else if let signingPrivateKey { raw = try P256.Signing.PrivateKey(rawRepresentation: signingPrivateKey).signature(for: transcript).rawRepresentation }
            else { throw AccountRuntimeError.corruptSecret }
            let normalized = Self.normalizedLowS(raw)
            try AccountWireCodec.validateLowSSignature(normalized)
            return normalized
        } catch { throw AccountRuntimeError.cryptographicFailure }
    }
    func sharedSecret(with peerPublicKey: Data) throws -> AccountSharedSecret {
        do {
            if let opaqueAgreement { return try opaqueAgreement.sharedSecret(peerPublicKey) }
            guard let agreementPrivateKey else { throw AccountRuntimeError.corruptSecret }
            return AccountSharedSecret(try P256.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey).sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)))
        }
        catch { throw AccountRuntimeError.cryptographicFailure }
    }
    func privateKeyMaterialForStorage() -> (signing: Data?, opaqueSigningReference: Data?, agreement: Data?, opaqueAgreementReference: Data?) { (signingPrivateKey, opaqueSigning?.persistentReference, agreementPrivateKey, opaqueAgreement?.persistentReference) }
    public static func == (lhs: AccountDeviceIdentity, rhs: AccountDeviceIdentity) -> Bool { lhs.publicBundle == rhs.publicBundle }
    static let p256Order = Data(hexIdentity: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
    private static let p256HalfOrder = Data(hexIdentity: "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")!
    static func normalizedLowS(_ signature: Data) -> Data {
        guard signature.count == 64 else { return signature }
        let r = Data(signature.prefix(32)), s = Data(signature.suffix(32))
        guard p256HalfOrder.lexicographicallyPrecedes(s), s != p256HalfOrder else { return signature }
        var result = Array(p256Order); let source = Array(s); var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) { let difference = Int(result[index]) - Int(source[index]) - borrow; if difference < 0 { result[index] = UInt8(difference + 256); borrow = 1 } else { result[index] = UInt8(difference); borrow = 0 } }
        return r + Data(result)
    }
}

public struct AccountSessionCredentials: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshCredential: Data
    public let offlineLease: String
    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, accessToken: String, accessExpiresAt: Date, refreshCredential: Data, offlineLease: String) throws {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 4096, accessExpiresAt.timeIntervalSince1970 > 0, refreshCredential.count == 32, !offlineLease.isEmpty, offlineLease.utf8.count <= 8192 else { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID; self.deviceID = deviceID; self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt; self.refreshCredential = refreshCredential; self.offlineLease = offlineLease
    }
}

public struct AccountSession: Codable, Hashable, Sendable {
    public let state: AccountSessionState
    public let credentials: AccountSessionCredentials?
    public static func provisional(accountID: PlainpostAccountID, deviceID: AccountDeviceID, mode: AccountBootstrapMode) -> AccountSession { AccountSession(state: .provisional(AccountActivation(accountID: accountID, deviceID: deviceID, mode: mode))) }
    enum CodingKeys: String, CodingKey { case version, state, accountID, deviceID, mode, credentials }
    public init(state: AccountSessionState) { self.state = state; credentials = nil }
    public init(credentials: AccountSessionCredentials) { state = .active; self.credentials = credentials }
    public init(provisional activation: AccountActivation, credentials: AccountSessionCredentials) throws {
        guard activation.mode == .pending, activation.accountID == credentials.accountID, activation.deviceID == credentials.deviceID else { throw AccountRuntimeError.corruptSecret }
        state = .provisional(activation); self.credentials = credentials
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let version = try box.decode(Int.self, forKey: .version)
        if [1, 3].contains(version), try box.decode(String.self, forKey: .state) == "provisional" {
            state = .provisional(AccountActivation(accountID: try box.decode(PlainpostAccountID.self, forKey: .accountID), deviceID: try box.decode(AccountDeviceID.self, forKey: .deviceID), mode: try box.decode(AccountBootstrapMode.self, forKey: .mode)))
            credentials = version == 3 ? try box.decode(AccountSessionCredentials.self, forKey: .credentials) : nil
        } else if version == 2, try box.decode(String.self, forKey: .state) == "active" {
            state = .active; credentials = try box.decode(AccountSessionCredentials.self, forKey: .credentials)
        } else { throw AccountRuntimeError.corruptSecret }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch state {
        case .provisional(let activation): try box.encode(credentials == nil ? 1 : 3, forKey: .version); try box.encode("provisional", forKey: .state); try box.encode(activation.accountID, forKey: .accountID); try box.encode(activation.deviceID, forKey: .deviceID); try box.encode(activation.mode, forKey: .mode); try box.encodeIfPresent(credentials, forKey: .credentials)
        case .active: guard let credentials else { throw AccountRuntimeError.corruptSecret }; try box.encode(2, forKey: .version); try box.encode("active", forKey: .state); try box.encode(credentials, forKey: .credentials)
        default: throw AccountRuntimeError.corruptSecret
        }
    }
}

public struct AccountCleanupCapability: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let kind: AccountCleanupTargetKind
    public let targetHandle: Data
    public let credential: Data
    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, kind: AccountCleanupTargetKind, targetHandle: Data, credential: Data) throws {
        guard targetHandle.count == 32, credential.count == 32,
              !targetHandle.allSatisfy({ $0 == 0 }), !credential.allSatisfy({ $0 == 0 }),
              kind == .macos || kind == .ios || kind == .syncNode
        else { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID; self.deviceID = deviceID; self.kind = kind
        self.targetHandle = targetHandle; self.credential = credential
    }
}

public enum AccountLocalDeletionPhase: String, Codable, Hashable, Sendable { case prepared, centralAccepted, localPurged }

public struct AccountLocalDeletionCheckpoint: Codable, Hashable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let kind: AccountCleanupTargetKind
    public let targetHandle: Data
    public let deletionGeneration: PositiveUInt64
    public let phase: AccountLocalDeletionPhase
    public let resultDigest: Data?
    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, kind: AccountCleanupTargetKind, targetHandle: Data, deletionGeneration: PositiveUInt64, phase: AccountLocalDeletionPhase, resultDigest: Data?) throws {
        guard targetHandle.count == 32, !targetHandle.allSatisfy({ $0 == 0 }),
              (phase == .localPurged) == (resultDigest?.count == 32),
              kind == .macos || kind == .ios || kind == .syncNode
        else { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID; self.deviceID = deviceID; self.kind = kind; self.targetHandle = targetHandle
        self.deletionGeneration = deletionGeneration; self.phase = phase; self.resultDigest = resultDigest
    }
}

/// Opaque, device-only recovery submission state. It exists so an ambiguous
/// network result or process death retries the byte-identical signed recovery
/// candidate instead of generating a second epoch keyset.
public struct AccountRecoverySubmissionCheckpoint: Sendable {
    let authorizationID: AccountAuthorizationID
    let candidate: AccountTrustHistoryEntryV1
    let prepared: AccountPreparedTrustActivation
}

public struct AccountDeletionSubmissionCheckpoint: Sendable {
    let checkpoint: AccountLocalDeletionCheckpoint
    let authorization: AccountStepUpAuthorizationV1
    let headCommitDigest: Data
}

public struct AccountCompletedDeletionReceipt: Codable, Hashable, Sendable {
    public let targetHandle: Data
    public let targetKind: AccountCleanupTargetKind
    public let deletionGeneration: PositiveUInt64
    public let resultDigest: Data
    public let receiptDigest: Data

    public init(targetHandle: Data, targetKind: AccountCleanupTargetKind, deletionGeneration: PositiveUInt64, resultDigest: Data) throws {
        guard targetHandle.count == 32, !targetHandle.allSatisfy({ $0 == 0 }), resultDigest.count == 32, !resultDigest.allSatisfy({ $0 == 0 }),
              targetKind == .macos || targetKind == .ios || targetKind == .syncNode
        else { throw AccountRuntimeError.corruptSecret }
        self.targetHandle = targetHandle; self.targetKind = targetKind; self.deletionGeneration = deletionGeneration; self.resultDigest = resultDigest
        receiptDigest = Data(SHA256.hash(data: AccountTranscript.parts([Data("Plainpost.CompletedAccountDeletionReceipt.v1".utf8), targetHandle, Data(targetKind.rawValue.utf8), AccountTranscript.u64(deletionGeneration.value), resultDigest])))
    }
}

public protocol AccountCredentialStoring: Sendable {
    func withAccountStateFence<T>(_ operation: () throws -> T) throws -> T
    func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity
    func loadSession() throws -> AccountSession?
    func saveSession(_ session: AccountSession) throws
    func replaceSession(ifCurrent expected: AccountSessionCredentials, with replacement: AccountSessionCredentials) throws -> Bool
    func clearSession(ifCurrent expected: AccountSessionCredentials) throws -> Bool
    func clearSession() throws
    /// Commits the only Task 4 activation state and its optional genesis key
    /// material in one device-only record. Genesis carries exactly 64 bytes;
    /// pending admission carries no material.
    func commitProvisionalActivation(_ activation: AccountActivation, genesisMaterial: Data?) throws
    func commitPendingActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials) throws
    func commitActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data?) throws
    func commitRecoveryTrustActivation(credentials: AccountSessionCredentials, prepared: AccountPreparedTrustActivation) throws
    func beginRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1, prepared: AccountPreparedTrustActivation) throws
    func loadRecoverySubmission() throws -> AccountRecoverySubmissionCheckpoint?
    func clearRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1) throws
    func loadOrCreateCleanupCapability(accountID: PlainpostAccountID, deviceID: AccountDeviceID, kind: AccountCleanupTargetKind) throws -> AccountCleanupCapability
    func purgeAccountAuthority(accountID: PlainpostAccountID) throws
    func clearCleanupCapability(accountID: PlainpostAccountID) throws
    func beginLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint, capability: AccountCleanupCapability, authorization: AccountStepUpAuthorizationV1, headCommitDigest: Data) throws
    func loadLocalDeletion() throws -> AccountLocalDeletionCheckpoint?
    func loadLocalDeletionSubmission() throws -> AccountDeletionSubmissionCheckpoint?
    func loadCompletedDeletionReceipt() throws -> AccountCompletedDeletionReceipt?
    func loadDeviceLabel(accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws -> String?
    func saveDeviceLabel(_ label: String, accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws
    func cancelLocalDeletion(accountID: PlainpostAccountID) throws
    func advanceLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint) throws
    func completeLocalDeletion(accountID: PlainpostAccountID) throws
}

public extension AccountCredentialStoring {
    func withAccountStateFence<T>(_: () throws -> T) throws -> T {
        throw AccountRuntimeError.secretUnavailable
    }
    func commitPendingActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials) throws { try saveSession(AccountSession(provisional: activation, credentials: credentials)) }
    func commitActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data?) throws {
        guard activation.mode == .genesis else { throw AccountRuntimeError.corruptSecret }
        try saveSession(AccountSession(credentials: credentials))
    }
    func commitRecoveryTrustActivation(credentials: AccountSessionCredentials, prepared: AccountPreparedTrustActivation) throws {
        throw AccountRuntimeError.secretUnavailable
    }
    func beginRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1, prepared: AccountPreparedTrustActivation) throws { throw AccountRuntimeError.secretUnavailable }
    func loadRecoverySubmission() throws -> AccountRecoverySubmissionCheckpoint? { throw AccountRuntimeError.secretUnavailable }
    func clearRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1) throws { throw AccountRuntimeError.secretUnavailable }
    func loadOrCreateCleanupCapability(accountID: PlainpostAccountID, deviceID: AccountDeviceID, kind: AccountCleanupTargetKind) throws -> AccountCleanupCapability { throw AccountRuntimeError.secretUnavailable }
    func purgeAccountAuthority(accountID: PlainpostAccountID) throws { throw AccountRuntimeError.secretUnavailable }
    func clearCleanupCapability(accountID: PlainpostAccountID) throws { throw AccountRuntimeError.secretUnavailable }
    func beginLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint, capability: AccountCleanupCapability, authorization: AccountStepUpAuthorizationV1, headCommitDigest: Data) throws { throw AccountRuntimeError.secretUnavailable }
    func loadLocalDeletion() throws -> AccountLocalDeletionCheckpoint? { throw AccountRuntimeError.secretUnavailable }
    func loadLocalDeletionSubmission() throws -> AccountDeletionSubmissionCheckpoint? { throw AccountRuntimeError.secretUnavailable }
    func loadCompletedDeletionReceipt() throws -> AccountCompletedDeletionReceipt? { nil }
    func loadDeviceLabel(accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws -> String? { nil }
    func saveDeviceLabel(_ label: String, accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws { throw AccountRuntimeError.secretUnavailable }
    func cancelLocalDeletion(accountID: PlainpostAccountID) throws { throw AccountRuntimeError.secretUnavailable }
    func advanceLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint) throws { throw AccountRuntimeError.secretUnavailable }
    func completeLocalDeletion(accountID: PlainpostAccountID) throws { throw AccountRuntimeError.secretUnavailable }
    func replaceSession(ifCurrent expected: AccountSessionCredentials, with replacement: AccountSessionCredentials) throws -> Bool {
        guard try loadSession()?.credentials == expected else { return false }
        try saveSession(AccountSession(credentials: replacement)); return true
    }
    func clearSession(ifCurrent expected: AccountSessionCredentials) throws -> Bool {
        guard try loadSession()?.credentials == expected else { return false }
        try clearSession(); return true
    }
}

private struct StoredAccountDeviceLabels: Codable, Equatable {
    let accountID: PlainpostAccountID
    var labels: [String: String]
}

public final class AccountCredentialStore: AccountCredentialStoring, @unchecked Sendable {
    private let secretStore: any AccountSecretStoring; private let service: String; private let accessGroup: String?; private let lock = NSRecursiveLock()
    private let secureEnclaveIdentityProvider: (@Sendable () throws -> AccountOpaqueSigningIdentity?)?
    private let secureEnclaveIdentityResolver: (@Sendable (Data) throws -> AccountOpaqueSigningIdentity)?
    private let secureEnclaveAgreementProvider: (@Sendable () throws -> AccountOpaqueAgreementIdentity?)?
    private let secureEnclaveAgreementResolver: (@Sendable (Data) throws -> AccountOpaqueAgreementIdentity)?
    private let trustStore: AccountTrustStore
    var testAfterActivationStep: ((String) throws -> Void)?
    private func key(_ account: String) -> AccountSecretKey {
        AccountSecretKey(service: service, account: account, accessGroup: accessGroup)
    }
    private var signingKey: AccountSecretKey { key("identity.signing.v1") }
    private var agreementKey: AccountSecretKey { key("identity.agreement.v1") }
    private var sessionKey: AccountSecretKey { key("session.v1") }
    private var sessionCredentialsKey: AccountSecretKey { key("session.credentials.v1") }
    private var provisionalActivationKey: AccountSecretKey { key("bootstrap.provisional-activation.v1") }
    private var activationJournalKey: AccountSecretKey { key("activation.journal.v1") }
    private var activationMarkerKey: AccountSecretKey { key("activation.committed.v1") }
    private var activationIntegrityKey: AccountSecretKey { key("activation.integrity-key.v1") }
    private var cleanupCapabilityKey: AccountSecretKey { key("cleanup.capability.v1") }
    private var cleanupJournalKey: AccountSecretKey { key("cleanup.journal.v1") }
    private var completedDeletionReceiptKey: AccountSecretKey { key("cleanup.completed-receipt.v1") }
    private var deviceLabelsKey: AccountSecretKey { key("device-labels.v1") }
    private var recoverySubmissionKey: AccountSecretKey { key("recovery.submission.v1") }
    public convenience init(secretStore: any AccountSecretStoring = KeychainAccountSecretStore(), service: String = "com.marynavdovenko.Plainpost.Account", accessGroup: String? = nil) {
        self.init(secretStore: secretStore, service: service, accessGroup: accessGroup, secureEnclaveIdentityProvider: nil, secureEnclaveIdentityResolver: nil, secureEnclaveAgreementProvider: nil, secureEnclaveAgreementResolver: nil, trustStore: nil)
    }
    init(secretStore: any AccountSecretStoring, service: String, accessGroup: String? = nil, secureEnclaveIdentityProvider: (@Sendable () throws -> AccountOpaqueSigningIdentity?)?, secureEnclaveIdentityResolver: (@Sendable (Data) throws -> AccountOpaqueSigningIdentity)?, secureEnclaveAgreementProvider: (@Sendable () throws -> AccountOpaqueAgreementIdentity?)?, secureEnclaveAgreementResolver: (@Sendable (Data) throws -> AccountOpaqueAgreementIdentity)?, trustStore: AccountTrustStore? = nil) {
        self.secretStore = secretStore; self.service = service
        self.accessGroup = accessGroup
        self.trustStore = trustStore ?? AccountTrustStore(secretStore: secretStore, accessGroup: accessGroup)
        #if canImport(Security)
        let isProductionKeychain = secretStore is KeychainAccountSecretStore
        self.secureEnclaveIdentityProvider = secureEnclaveIdentityProvider ?? (isProductionKeychain ? { @Sendable in try Self.createSecureEnclaveSigningIdentity(accessGroup: accessGroup) } : nil)
        self.secureEnclaveIdentityResolver = secureEnclaveIdentityResolver ?? (isProductionKeychain ? { @Sendable reference in try Self.resolveSecureEnclaveSigningIdentity(reference) } : nil)
        self.secureEnclaveAgreementProvider = secureEnclaveAgreementProvider ?? (isProductionKeychain ? { @Sendable in try Self.createSecureEnclaveAgreementIdentity(accessGroup: accessGroup) } : nil)
        self.secureEnclaveAgreementResolver = secureEnclaveAgreementResolver ?? (isProductionKeychain ? { @Sendable reference in try Self.resolveSecureEnclaveAgreementIdentity(reference) } : nil)
        #else
        self.secureEnclaveIdentityProvider = secureEnclaveIdentityProvider
        self.secureEnclaveIdentityResolver = secureEnclaveIdentityResolver
        self.secureEnclaveAgreementProvider = secureEnclaveAgreementProvider
        self.secureEnclaveAgreementResolver = secureEnclaveAgreementResolver
        #endif
    }
    public func withAccountStateFence<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
    /// Loads an already persisted device identity without creating new key
    /// material.  Service startup uses this to fail closed when the app has
    /// not completed account activation yet.
    public func loadExistingDeviceIdentity() throws -> AccountDeviceIdentity? {
        lock.lock(); defer { lock.unlock() }
        let signing = try secretStore.load(signingKey)
        let agreement = try secretStore.load(agreementKey)
        switch (signing, agreement) {
        case (nil, nil): return nil
        case let (.some(left), .some(right)):
            guard left.attributes == .deviceOnly, right.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            if let reference = Self.opaqueReference(from: left.value) {
                guard let resolver = secureEnclaveIdentityResolver,
                      let agreementReference = Self.opaqueAgreementReference(from: right.value),
                      let agreementResolver = secureEnclaveAgreementResolver else { throw AccountRuntimeError.corruptSecret }
                return try AccountDeviceIdentity(opaqueSigning: resolver(reference), opaqueAgreement: agreementResolver(agreementReference))
            }
            return try AccountDeviceIdentity(signingPrivateKey: left.value, agreementPrivateKey: right.value)
        default: throw AccountRuntimeError.corruptSecret
        }
    }
    public func loadOrCreateDeviceIdentity() throws -> AccountDeviceIdentity {
        lock.lock(); defer { lock.unlock() }
        let signing = try secretStore.load(signingKey); let agreement = try secretStore.load(agreementKey)
        switch (signing, agreement) {
        case let (.some(left), .some(right)):
            guard left.attributes == .deviceOnly, right.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            if let reference = Self.opaqueReference(from: left.value) {
                guard let resolver = secureEnclaveIdentityResolver else { throw AccountRuntimeError.corruptSecret }
                guard let agreementReference = Self.opaqueAgreementReference(from: right.value), let agreementResolver = secureEnclaveAgreementResolver else { throw AccountRuntimeError.corruptSecret }
                return try AccountDeviceIdentity(opaqueSigning: resolver(reference), opaqueAgreement: agreementResolver(agreementReference))
            }
            return try AccountDeviceIdentity(signingPrivateKey: left.value, agreementPrivateKey: right.value)
        case (nil, nil):
            let identity: AccountDeviceIdentity
            if let opaque = try secureEnclaveIdentityProvider?() {
                do {
                    guard let agreement = try secureEnclaveAgreementProvider?() else { throw AccountRuntimeError.cryptographicFailure }
                    identity = try AccountDeviceIdentity(opaqueSigning: opaque, opaqueAgreement: agreement)
                } catch {
                    #if canImport(Security)
                    SecItemDelete([kSecValuePersistentRef as String: opaque.persistentReference] as CFDictionary)
                    #endif
                    throw AccountRuntimeError.cryptographicFailure
                }
            } else {
                identity = try AccountDeviceIdentity.generate()
            }
            let material = identity.privateKeyMaterialForStorage()
            let signingMaterial: Data
            if let reference = material.opaqueSigningReference { signingMaterial = Self.opaqueReferencePrefix + reference }
            else if let raw = material.signing { signingMaterial = raw }
            else { throw AccountRuntimeError.corruptSecret }
            let agreementMaterial: Data
            if let reference = material.opaqueAgreementReference { agreementMaterial = Self.opaqueAgreementPrefix + reference }
            else if let raw = material.agreement { agreementMaterial = raw }
            else { throw AccountRuntimeError.corruptSecret }
            do { try secretStore.replace(signingMaterial, key: signingKey, attributes: .deviceOnly); try secretStore.replace(agreementMaterial, key: agreementKey, attributes: .deviceOnly) } catch { try? secretStore.delete(signingKey); try? secretStore.delete(agreementKey); throw error }
            return identity
        default: throw AccountRuntimeError.corruptSecret
        }
    }

    /// Returns the verified trust snapshot currently selected by this
    /// account's CAS-protected trust head. Notification coordination uses
    /// this exact snapshot when validating signed recipient records.
    public func loadCurrentTrustCommit(for accountID: PlainpostAccountID) throws -> AccountTrustStateCommit? {
        lock.lock()
        defer { lock.unlock() }
        return try trustStore.loadState(for: accountID)?.currentCommit
    }
    @MainActor public func makeActiveAdmissionController(client: AccountAPIClient, platform: AccountPlatform) throws -> AccountActiveAdmissionController {
        guard let session = try loadSession(), session.state == .active, let credentials = session.credentials else { throw AccountRuntimeError.corruptSecret }
        let identity = try loadOrCreateDeviceIdentity()
        let coordinator = try AccountTrustCoordinator(accountID: credentials.accountID, deviceID: credentials.deviceID, platform: platform, deviceIdentity: identity, trustStore: trustStore)
        let rendezvous = CentralAccountAdmissionRendezvous(client: client, credentials: credentials, identity: identity)
        return AccountActiveAdmissionController(rendezvous: rendezvous, coordinator: coordinator, client: client, credentials: credentials, identity: identity)
    }
    public func makeTrustCoordinator(accountID: PlainpostAccountID, deviceID: AccountDeviceID, platform: AccountPlatform, identity: AccountDeviceIdentity) throws -> AccountTrustCoordinator {
        try AccountTrustCoordinator(accountID: accountID, deviceID: deviceID, platform: platform, deviceIdentity: identity, trustStore: trustStore)
    }
    public func makeLifecycleController(
        client: AccountAPIClient,
        manifestStore: BootstrapKeyManifestStore,
        platform: AccountPlatform,
        authenticate: @escaping AccountLifecycleController.LocalAuthentication,
        purgeManagedData: AccountLifecycleController.ManagedDataPurge? = nil
    ) throws -> AccountLifecycleController {
        let identity = try loadOrCreateDeviceIdentity()
        let loaded = try loadSession()
        let credentials = loaded?.state == .active ? loaded?.credentials : nil
        let coordinator = try credentials.map {
            try makeTrustCoordinator(accountID: $0.accountID, deviceID: $0.deviceID, platform: platform, identity: identity)
        }
        return try AccountLifecycleController(
            remote: client,
            credentialStore: self,
            device: identity,
            platform: platform,
            credentials: credentials,
            coordinator: coordinator,
            recoveryCoordinatorFactory: { [weak self] accountID, deviceID, platform, identity in
                guard let self else { throw AccountRuntimeError.secretUnavailable }
                return try self.makeTrustCoordinator(accountID: accountID, deviceID: deviceID, platform: platform, identity: identity)
            },
            manifestStore: manifestStore,
            authenticate: authenticate,
            purgeManagedData: purgeManagedData
        )
    }
    /// Builds the recovery path without attaching the installed session.
    /// Recovery is entered precisely when that session is expired or otherwise
    /// unusable, and AccountLifecycleController deliberately rejects recovery
    /// while ordinary session authority is attached.
    public func makeRecoveryLifecycleController(
        client: AccountAPIClient,
        manifestStore: BootstrapKeyManifestStore,
        platform: AccountPlatform,
        authenticate: @escaping AccountLifecycleController.LocalAuthentication,
        purgeManagedData: AccountLifecycleController.ManagedDataPurge? = nil
    ) throws -> AccountLifecycleController {
        let identity = try loadOrCreateDeviceIdentity()
        return try AccountLifecycleController(
            remote: client,
            credentialStore: self,
            device: identity,
            platform: platform,
            credentials: nil,
            coordinator: nil,
            recoveryCoordinatorFactory: { [weak self] accountID, deviceID, platform, identity in
                guard let self else { throw AccountRuntimeError.secretUnavailable }
                return try self.makeTrustCoordinator(
                    accountID: accountID,
                    deviceID: deviceID,
                    platform: platform,
                    identity: identity
                )
            },
            manifestStore: manifestStore,
            authenticate: authenticate,
            purgeManagedData: purgeManagedData
        )
    }
    public func loadSession() throws -> AccountSession? {
        lock.lock(); defer { lock.unlock() }
        if let journal = try secretStore.load(activationJournalKey) {
            guard journal.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            if let recovery = try? JSONDecoder().decode(RecoveryTrustActivationJournal.self, from: journal.value), recovery.version == 1 {
                try trustStore.withAccountFence(for: recovery.accountID) {
                    try finishRecoveryTrustActivationUnfenced(journal.value)
                }
            } else if let pending = try? JSONDecoder().decode(PendingTrustActivationJournal.self, from: journal.value), pending.version == 1 {
                try trustStore.withAccountFence(for: pending.activation.accountID) {
                    try finishPendingTrustActivationUnfenced(journal.value)
                }
            } else {
                try finishGenesisActivation(journal.value)
            }
        }
        if let record = try secretStore.load(sessionCredentialsKey) {
            guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            do {
                if let cleared = try? JSONDecoder().decode(ClearedSessionRecord.self, from: record.value), cleared.version == 1, cleared.state == "cleared" { return nil }
                if let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: record.value) {
                    if let digest = active.activationDigest {
                        guard let marker = try secretStore.load(activationMarkerKey), marker.attributes == .deviceOnly, marker.value == digest else { throw AccountRuntimeError.corruptSecret }
                    }
                    return active.session
                }
                return try JSONDecoder().decode(AccountSession.self, from: record.value)
            } catch { throw AccountRuntimeError.corruptSecret }
        }
        if let record = try secretStore.load(provisionalActivationKey) {
            guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            do { return try JSONDecoder().decode(ProvisionalActivationRecord.self, from: record.value).session } catch { throw AccountRuntimeError.corruptSecret }
        }
        // Read-only migration support for the original Task 4 checkpoint.
        guard let legacy = try secretStore.load(sessionKey), legacy.attributes == .deviceOnly else { return nil }
        do { return try JSONDecoder().decode(AccountSession.self, from: legacy.value) } catch { throw AccountRuntimeError.corruptSecret }
    }
    public func saveSession(_ session: AccountSession) throws {
        if case .provisional(let activation) = session.state {
            if let credentials = session.credentials { try commitPendingActivation(activation, credentials: credentials) }
            else { try commitProvisionalActivation(activation, genesisMaterial: nil) }
            return
        }
        guard case .active = session.state, session.credentials != nil else { throw AccountRuntimeError.corruptSecret }
        lock.lock(); defer { lock.unlock() }
        let encoded: Data
        if let existing = try secretStore.load(sessionCredentialsKey),
           let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: existing.value) {
            encoded = try JSONEncoder().encode(ActiveActivationRecord(session: session, genesisMaterial: active.genesisMaterial))
        } else {
            encoded = try JSONEncoder().encode(session)
        }
        try secretStore.replace(encoded, key: sessionCredentialsKey, attributes: .deviceOnly)
        try? secretStore.delete(provisionalActivationKey)
        try? secretStore.delete(sessionKey)
    }
    public func replaceSession(ifCurrent expected: AccountSessionCredentials, with replacement: AccountSessionCredentials) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stored = try secretStore.load(sessionCredentialsKey), stored.attributes == .deviceOnly else { return false }
        let decoded: AccountSession
        let genesisMaterial: Data?
        if let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: stored.value) { decoded = active.session; genesisMaterial = active.genesisMaterial }
        else { decoded = try JSONDecoder().decode(AccountSession.self, from: stored.value); genesisMaterial = nil }
        guard decoded.credentials == expected else { return false }
        let encoded = try JSONEncoder().encode(ActiveActivationRecord(session: AccountSession(credentials: replacement), genesisMaterial: genesisMaterial))
        return try secretStore.compareAndSwap(expected: stored.value, replacement: encoded, key: sessionCredentialsKey, attributes: .deviceOnly)
    }
    public func clearSession(ifCurrent expected: AccountSessionCredentials) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stored = try secretStore.load(sessionCredentialsKey), stored.attributes == .deviceOnly else { return false }
        let decoded: AccountSession
        if let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: stored.value) { decoded = active.session }
        else if let legacy = try? JSONDecoder().decode(AccountSession.self, from: stored.value) { decoded = legacy }
        else { return false }
        guard decoded.credentials == expected else { return false }
        let tombstone = try JSONEncoder().encode(ClearedSessionRecord())
        return try secretStore.compareAndSwap(expected: stored.value, replacement: tombstone, key: sessionCredentialsKey, attributes: .deviceOnly)
    }
    public func commitProvisionalActivation(_ activation: AccountActivation, genesisMaterial: Data?) throws {
        guard (activation.mode == .genesis && genesisMaterial?.count == 64) || (activation.mode == .pending && genesisMaterial == nil) else { throw AccountRuntimeError.corruptSecret }
        lock.lock(); defer { lock.unlock() }
        let record = ProvisionalActivationRecord(activation: activation, genesisMaterial: genesisMaterial)
        try secretStore.replace(try JSONEncoder().encode(record), key: provisionalActivationKey, attributes: .deviceOnly)
        // Only after the complete new record succeeds can a legacy fragment be
        // removed; no Task 4 write splits state from genesis material.
        try? secretStore.delete(sessionKey)
    }
    public func commitPendingActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials) throws {
        guard activation.mode == .pending, activation.accountID == credentials.accountID, activation.deviceID == credentials.deviceID else { throw AccountRuntimeError.corruptSecret }
        lock.lock(); defer { lock.unlock() }
        let record = ProvisionalActivationRecord(activation: activation, credentials: credentials, genesisMaterial: nil)
        try secretStore.replace(try JSONEncoder().encode(record), key: provisionalActivationKey, attributes: .deviceOnly)
        try? secretStore.delete(sessionCredentialsKey); try? secretStore.delete(sessionKey)
    }
    public func commitActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data?) throws {
        guard activation.mode == .genesis,
              genesisMaterial?.count == 64,
              activation.accountID == credentials.accountID,
              activation.deviceID == credentials.deviceID
        else { throw AccountRuntimeError.corruptSecret }
        lock.lock(); defer { lock.unlock() }
        guard let genesisMaterial,
              let commit = activation.currentTrustCommit,
              commit.state.transition.kind == .genesis,
              commit.state.accountID == activation.accountID
        else { throw AccountRuntimeError.corruptSecret }
        try trustStore.withAccountFence(for: activation.accountID) {
            let authenticationKey = try loadOrCreateActivationIntegrityKey()
            let journal = try GenesisActivationJournal(activation: activation, credentials: credentials, genesisMaterial: genesisMaterial, commit: commit, authenticationKey: authenticationKey)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let wire = try encoder.encode(journal)
            if let interrupted = try secretStore.load(activationJournalKey) {
                guard interrupted.attributes == .deviceOnly, interrupted.value == wire else { throw AccountProtocolError.equivocation }
                try finishGenesisActivationUnfenced(wire)
                return
            }
            if try isExactCommittedGenesisActivation(wire) { return }
            try saveExactActivationRecord(wire, key: activationJournalKey)
            try testAfterActivationStep?("journal")
            try finishGenesisActivationUnfenced(wire)
        }
        try? secretStore.delete(provisionalActivationKey); try? secretStore.delete(sessionKey)
    }
    public func clearSession() throws { lock.lock(); defer { lock.unlock() }; try secretStore.delete(sessionCredentialsKey); try secretStore.delete(provisionalActivationKey); try secretStore.delete(sessionKey); try? secretStore.delete(activationJournalKey); try? secretStore.delete(recoverySubmissionKey); try? secretStore.delete(activationMarkerKey); try? secretStore.delete(activationIntegrityKey) }

    public func loadOrCreateCleanupCapability(accountID: PlainpostAccountID, deviceID: AccountDeviceID, kind: AccountCleanupTargetKind) throws -> AccountCleanupCapability {
        lock.lock(); defer { lock.unlock() }
        guard kind == .macos || kind == .ios || kind == .syncNode else { throw AccountRuntimeError.corruptSecret }
        if let stored = try secretStore.load(cleanupCapabilityKey) {
            guard stored.attributes == .deviceOnly,
                  let value = try? JSONDecoder().decode(AccountCleanupCapability.self, from: stored.value),
                  value.accountID == accountID, value.deviceID == deviceID, value.kind == kind,
                  (try? Self.encodeCleanupCapability(value)) == stored.value
            else { throw AccountRuntimeError.corruptSecret }
            return value
        }
        let value = try AccountCleanupCapability(accountID: accountID, deviceID: deviceID, kind: kind, targetHandle: AccountAPIClient.secureRandom(32), credential: AccountAPIClient.secureRandom(32))
        let wire = try Self.encodeCleanupCapability(value)
        guard try secretStore.compareAndSwap(expected: nil, replacement: wire, key: cleanupCapabilityKey, attributes: .deviceOnly) else {
            guard let winner = try secretStore.load(cleanupCapabilityKey), winner.attributes == .deviceOnly,
                  let decoded = try? JSONDecoder().decode(AccountCleanupCapability.self, from: winner.value),
                  decoded.accountID == accountID, decoded.deviceID == deviceID, decoded.kind == kind,
                  (try? Self.encodeCleanupCapability(decoded)) == winner.value
            else { throw AccountRuntimeError.secretUnavailable }
            return decoded
        }
        return value
    }

    public func purgeAccountAuthority(accountID: PlainpostAccountID) throws {
        lock.lock(); defer { lock.unlock() }
        if let current = try loadStoredSessionUnfenced(), let credentials = current.credentials, credentials.accountID != accountID {
            throw AccountRuntimeError.corruptSecret
        }
        try trustStore.purgeAccountAuthority(for: accountID)
        try deleteOpaqueIdentityIfPresent(signingKey)
        try deleteOpaqueIdentityIfPresent(agreementKey)
        for key in [sessionCredentialsKey, provisionalActivationKey, sessionKey, activationJournalKey, recoverySubmissionKey, activationMarkerKey, activationIntegrityKey, deviceLabelsKey, signingKey, agreementKey] {
            try secretStore.delete(key)
        }
    }

    public func loadDeviceLabel(accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try loadDeviceLabelsUnfenced(accountID: accountID).labels[deviceID.rawValue]
    }

    public func saveDeviceLabel(_ label: String, accountID: PlainpostAccountID, deviceID: AccountDeviceID) throws {
        lock.lock(); defer { lock.unlock() }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validDeviceLabel(normalized) else { throw AccountRuntimeError.untrustedResponse }
        var value = try loadDeviceLabelsUnfenced(accountID: accountID)
        guard value.labels[deviceID.rawValue] != nil || value.labels.count < 11 else { throw AccountRuntimeError.untrustedResponse }
        value.labels[deviceID.rawValue] = normalized
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let replacement = try encoder.encode(value)
        let expected = try secretStore.load(deviceLabelsKey)?.value
        guard try secretStore.compareAndSwap(expected: expected, replacement: replacement, key: deviceLabelsKey, attributes: .deviceOnly) else { throw AccountRuntimeError.secretUnavailable }
    }

    private func loadDeviceLabelsUnfenced(accountID: PlainpostAccountID) throws -> StoredAccountDeviceLabels {
        guard let record = try secretStore.load(deviceLabelsKey) else { return StoredAccountDeviceLabels(accountID: accountID, labels: [:]) }
        let decoder = JSONDecoder(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard record.attributes == .deviceOnly,
              let value = try? decoder.decode(StoredAccountDeviceLabels.self, from: record.value),
              value.accountID == accountID, value.labels.count <= 11,
              value.labels.allSatisfy({ (try? AccountDeviceID($0.key)) != nil && Self.validDeviceLabel($0.value) }),
              (try? encoder.encode(value)) == record.value
        else { throw AccountRuntimeError.corruptSecret }
        return value
    }

    private static func validDeviceLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public func clearCleanupCapability(accountID: PlainpostAccountID) throws {
        lock.lock(); defer { lock.unlock() }
        if let stored = try secretStore.load(cleanupCapabilityKey) {
            guard stored.attributes == .deviceOnly,
                  let value = try? JSONDecoder().decode(AccountCleanupCapability.self, from: stored.value),
                  value.accountID == accountID
            else { throw AccountRuntimeError.corruptSecret }
        }
        try secretStore.delete(cleanupCapabilityKey)
    }

    public func beginLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint, capability: AccountCleanupCapability, authorization: AccountStepUpAuthorizationV1, headCommitDigest: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard checkpoint.phase == .prepared, checkpoint.resultDigest == nil,
              capability.accountID == checkpoint.accountID, capability.deviceID == checkpoint.deviceID,
              capability.kind == checkpoint.kind, capability.targetHandle == checkpoint.targetHandle,
              headCommitDigest.count == 32,
              authorization.accountID == checkpoint.accountID,
              authorization.actorDeviceID == checkpoint.deviceID,
              authorization.action == .deleteAccount,
              authorization.targetDeviceID == nil,
              authorization.currentCommitDigest == headCommitDigest,
              try loadCleanupCapabilityUnfenced() == capability
        else { throw AccountRuntimeError.corruptSecret }
        let journal = try LocalDeletionJournal(checkpoint: checkpoint, authorizationWire: AccountWireCodec.encodeStepUpAuthorization(authorization), headCommitDigest: headCommitDigest, credential: capability.credential)
        let wire = try Self.encodeLocalDeletionJournal(journal)
        if let existing = try secretStore.load(cleanupJournalKey) {
            guard existing.attributes == .deviceOnly, existing.value == wire else { throw AccountProtocolError.equivocation }
            return
        }
        guard try secretStore.compareAndSwap(expected: nil, replacement: wire, key: cleanupJournalKey, attributes: .deviceOnly) else { throw AccountRuntimeError.secretUnavailable }
    }

    public func loadLocalDeletion() throws -> AccountLocalDeletionCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return try loadLocalDeletionUnfenced()
    }

    public func loadLocalDeletionSubmission() throws -> AccountDeletionSubmissionCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        guard let journal = try loadLocalDeletionJournalUnfenced() else { return nil }
        return AccountDeletionSubmissionCheckpoint(checkpoint: journal.checkpoint, authorization: try AccountWireCodec.decodeStepUpAuthorization(journal.authorizationWire), headCommitDigest: journal.headCommitDigest)
    }

    public func loadCompletedDeletionReceipt() throws -> AccountCompletedDeletionReceipt? {
        lock.lock(); defer { lock.unlock() }
        guard let record = try secretStore.load(completedDeletionReceiptKey) else { return nil }
        guard record.attributes == .deviceOnly,
              let receipt = try? JSONDecoder().decode(AccountCompletedDeletionReceipt.self, from: record.value),
              let rebuilt = try? AccountCompletedDeletionReceipt(targetHandle: receipt.targetHandle, targetKind: receipt.targetKind, deletionGeneration: receipt.deletionGeneration, resultDigest: receipt.resultDigest),
              rebuilt == receipt,
              (try? Self.encodeCompletedDeletionReceipt(receipt)) == record.value
        else { throw AccountRuntimeError.corruptSecret }
        return receipt
    }

    public func advanceLocalDeletion(_ checkpoint: AccountLocalDeletionCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard let existingRecord = try secretStore.load(cleanupJournalKey), existingRecord.attributes == .deviceOnly,
              let existing = try? JSONDecoder().decode(LocalDeletionJournal.self, from: existingRecord.value),
              let capability = try loadCleanupCapabilityUnfenced(),
              try existing.verify(credential: capability.credential),
              existing.checkpoint.accountID == checkpoint.accountID,
              existing.checkpoint.deviceID == checkpoint.deviceID,
              existing.checkpoint.kind == checkpoint.kind,
              existing.checkpoint.targetHandle == checkpoint.targetHandle,
              existing.checkpoint.deletionGeneration == checkpoint.deletionGeneration,
              Self.validDeletionAdvance(from: existing.checkpoint.phase, to: checkpoint.phase)
        else { throw AccountRuntimeError.corruptSecret }
        let replacement = try Self.encodeLocalDeletionJournal(LocalDeletionJournal(checkpoint: checkpoint, authorizationWire: existing.authorizationWire, headCommitDigest: existing.headCommitDigest, credential: capability.credential))
        guard try secretStore.compareAndSwap(expected: existingRecord.value, replacement: replacement, key: cleanupJournalKey, attributes: .deviceOnly) else { throw AccountRuntimeError.secretUnavailable }
    }

    public func cancelLocalDeletion(accountID: PlainpostAccountID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let journal = try loadLocalDeletionJournalUnfenced(),
              journal.checkpoint.accountID == accountID,
              journal.checkpoint.phase == .prepared
        else { throw AccountRuntimeError.corruptSecret }
        try secretStore.delete(cleanupJournalKey)
    }

    public func completeLocalDeletion(accountID: PlainpostAccountID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let checkpoint = try loadLocalDeletionUnfenced(), checkpoint.accountID == accountID, checkpoint.phase == .localPurged,
              let resultDigest = checkpoint.resultDigest
        else { throw AccountRuntimeError.corruptSecret }
        let receipt = try AccountCompletedDeletionReceipt(targetHandle: checkpoint.targetHandle, targetKind: checkpoint.kind, deletionGeneration: checkpoint.deletionGeneration, resultDigest: resultDigest)
        let receiptWire = try Self.encodeCompletedDeletionReceipt(receipt)
        if let existing = try secretStore.load(completedDeletionReceiptKey) {
            guard existing.attributes == .deviceOnly, existing.value == receiptWire else { throw AccountProtocolError.equivocation }
        } else if !(try secretStore.compareAndSwap(expected: nil, replacement: receiptWire, key: completedDeletionReceiptKey, attributes: .deviceOnly)) {
            guard let winner = try secretStore.load(completedDeletionReceiptKey), winner.attributes == .deviceOnly, winner.value == receiptWire else { throw AccountProtocolError.equivocation }
        }
        try secretStore.delete(cleanupJournalKey)
        try secretStore.delete(cleanupCapabilityKey)
    }

    private func loadCleanupCapabilityUnfenced() throws -> AccountCleanupCapability? {
        guard let record = try secretStore.load(cleanupCapabilityKey) else { return nil }
        guard record.attributes == .deviceOnly, let value = try? JSONDecoder().decode(AccountCleanupCapability.self, from: record.value), (try? Self.encodeCleanupCapability(value)) == record.value else { throw AccountRuntimeError.corruptSecret }
        return value
    }

    private func loadLocalDeletionUnfenced() throws -> AccountLocalDeletionCheckpoint? {
        try loadLocalDeletionJournalUnfenced()?.checkpoint
    }

    private func loadLocalDeletionJournalUnfenced() throws -> LocalDeletionJournal? {
        guard let record = try secretStore.load(cleanupJournalKey) else { return nil }
        guard record.attributes == .deviceOnly,
              let journal = try? JSONDecoder().decode(LocalDeletionJournal.self, from: record.value),
              let capability = try loadCleanupCapabilityUnfenced(),
              try journal.verify(credential: capability.credential),
              journal.checkpoint.accountID == capability.accountID,
              journal.checkpoint.deviceID == capability.deviceID,
              journal.checkpoint.kind == capability.kind,
              journal.checkpoint.targetHandle == capability.targetHandle,
              journal.headCommitDigest.count == 32,
              let authorization = try? AccountWireCodec.decodeStepUpAuthorization(journal.authorizationWire),
              (try? AccountWireCodec.encodeStepUpAuthorization(authorization)) == journal.authorizationWire,
              authorization.accountID == journal.checkpoint.accountID,
              authorization.actorDeviceID == journal.checkpoint.deviceID,
              authorization.action == .deleteAccount,
              authorization.targetDeviceID == nil,
              authorization.currentCommitDigest == journal.headCommitDigest,
              (try? Self.encodeLocalDeletionJournal(journal)) == record.value
        else { throw AccountRuntimeError.corruptSecret }
        return journal
    }

    private static func validDeletionAdvance(from: AccountLocalDeletionPhase, to: AccountLocalDeletionPhase) -> Bool {
        from == to || (from == .prepared && to == .centralAccepted) || (from == .centralAccepted && to == .localPurged)
    }

    private static func encodeLocalDeletionJournal(_ value: LocalDeletionJournal) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func encodeCompletedDeletionReceipt(_ value: AccountCompletedDeletionReceipt) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func loadStoredSessionUnfenced() throws -> AccountSession? {
        if try secretStore.load(activationJournalKey) != nil { throw AccountRuntimeError.secretUnavailable }
        if let record = try secretStore.load(sessionCredentialsKey) {
            guard record.attributes == .deviceOnly else { throw AccountRuntimeError.corruptSecret }
            if let cleared = try? JSONDecoder().decode(ClearedSessionRecord.self, from: record.value), cleared.version == 1, cleared.state == "cleared" { return nil }
            if let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: record.value) { return active.session }
            guard let session = try? JSONDecoder().decode(AccountSession.self, from: record.value) else { throw AccountRuntimeError.corruptSecret }
            return session
        }
        if let record = try secretStore.load(provisionalActivationKey) {
            guard record.attributes == .deviceOnly, let value = try? JSONDecoder().decode(ProvisionalActivationRecord.self, from: record.value) else { throw AccountRuntimeError.corruptSecret }
            return try value.session
        }
        if let record = try secretStore.load(sessionKey) {
            guard record.attributes == .deviceOnly, let session = try? JSONDecoder().decode(AccountSession.self, from: record.value) else { throw AccountRuntimeError.corruptSecret }
            return session
        }
        return nil
    }

    private static func encodeCleanupCapability(_ value: AccountCleanupCapability) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func deleteOpaqueIdentityIfPresent(_ key: AccountSecretKey) throws {
        #if canImport(Security)
        guard let record = try secretStore.load(key) else { return }
        let reference = Self.opaqueReference(from: record.value) ?? Self.opaqueAgreementReference(from: record.value)
        if let reference {
            let status = SecItemDelete([kSecValuePersistentRef as String: reference] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountRuntimeError.secretUnavailable }
        }
        #else
        _ = key
        #endif
    }

    private func finishGenesisActivation(_ wire: Data) throws {
        let journal = try JSONDecoder().decode(GenesisActivationJournal.self, from: wire)
        guard journal.version == 1, journal.activation.mode == .genesis, journal.activation.accountID == journal.credentials.accountID, journal.activation.deviceID == journal.credentials.deviceID, journal.genesisMaterial.count == 64, journal.activation.currentTrustCommit == journal.commit else { throw AccountRuntimeError.corruptSecret }
        try trustStore.withAccountFence(for: journal.activation.accountID) {
            try verifyActivationJournal(journal)
            try finishGenesisActivationUnfenced(wire)
        }
    }

    func commitPendingTrustActivation(_ activation: AccountActivation, credentials: AccountSessionCredentials, prepared: AccountPreparedTrustActivation) throws {
        guard activation.mode == .pending,
              activation.accountID == credentials.accountID,
              activation.deviceID == credentials.deviceID,
              prepared.material.accountID == activation.accountID,
              prepared.entries.last?.commit.state.members.contains(where: { $0.deviceID == activation.deviceID }) == true
        else { throw AccountRuntimeError.corruptSecret }
        let history = try prepared.entries.map(AccountWireCodec.encodeTrustHistoryEntry)
        lock.lock(); defer { lock.unlock() }
        try trustStore.withAccountFence(for: activation.accountID) {
            let authenticationKey = try loadOrCreateActivationIntegrityKey()
            let journal = try PendingTrustActivationJournal(activation: activation, credentials: credentials, history: history, material: prepared.material.combined, authenticationKey: authenticationKey)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let wire = try encoder.encode(journal)
            if let interrupted = try secretStore.load(activationJournalKey) {
                guard interrupted.attributes == .deviceOnly, interrupted.value == wire else { throw AccountProtocolError.equivocation }
                try finishPendingTrustActivationUnfenced(wire)
                return
            }
            if try isExactCommittedGenesisActivation(wire) { return }
            try saveExactActivationRecord(wire, key: activationJournalKey)
            try testAfterActivationStep?("journal")
            try finishPendingTrustActivationUnfenced(wire)
        }
    }

    public func commitRecoveryTrustActivation(credentials: AccountSessionCredentials, prepared: AccountPreparedTrustActivation) throws {
        guard let final = prepared.entries.last,
              prepared.entries.count == 1,
              final.commit.state.transition.kind == .recovery,
              final.commit.state.accountID == credentials.accountID,
              final.commit.state.members.contains(where: { $0.deviceID == credentials.deviceID }),
              prepared.material.accountID == credentials.accountID,
              prepared.material.epoch == final.commit.state.epoch,
              prepared.material.keyGeneration == final.commit.state.keyGeneration
        else { throw AccountRuntimeError.corruptSecret }
        let history = try prepared.entries.map(AccountWireCodec.encodeTrustHistoryEntry)
        lock.lock(); defer { lock.unlock() }
        try trustStore.withAccountFence(for: credentials.accountID) {
            let authenticationKey = try loadOrCreateActivationIntegrityKey()
            let journal = try RecoveryTrustActivationJournal(accountID: credentials.accountID, deviceID: credentials.deviceID, credentials: credentials, history: history, material: prepared.material.combined, authenticationKey: authenticationKey)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let wire = try encoder.encode(journal)
            if let interrupted = try secretStore.load(activationJournalKey) {
                guard interrupted.attributes == .deviceOnly, interrupted.value == wire else { throw AccountProtocolError.equivocation }
                try finishRecoveryTrustActivationUnfenced(wire)
                return
            }
            try saveExactActivationRecord(wire, key: activationJournalKey)
            try testAfterActivationStep?("journal")
            try finishRecoveryTrustActivationUnfenced(wire)
        }
        try? secretStore.delete(provisionalActivationKey); try? secretStore.delete(sessionKey)
    }

    public func beginRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1, prepared: AccountPreparedTrustActivation) throws {
        guard prepared.entries == [candidate],
              candidate.commit.state.transition.kind == .recovery,
              case .recovery(let evidence)? = candidate.evidence,
              evidence.authorization.authorizationID == authorizationID,
              prepared.material.accountID == candidate.commit.state.accountID,
              prepared.material.epoch == candidate.commit.state.epoch,
              prepared.material.keyGeneration == candidate.commit.state.keyGeneration,
              prepared.material.trustRevision == candidate.commit.state.revision,
              prepared.material.commitment == candidate.commit.state.keyCommitment
        else { throw AccountRuntimeError.corruptSecret }
        lock.lock(); defer { lock.unlock() }
        let key = try loadOrCreateActivationIntegrityKey()
        let journal = try RecoverySubmissionJournal(
            authorizationID: authorizationID,
            candidate: AccountWireCodec.encodeTrustHistoryEntry(candidate),
            material: prepared.material.combined,
            authenticationKey: key
        )
        try saveExactActivationRecord(try Self.encodeRecoverySubmissionJournal(journal), key: recoverySubmissionKey)
    }

    public func loadRecoverySubmission() throws -> AccountRecoverySubmissionCheckpoint? {
        lock.lock(); defer { lock.unlock() }
        return try loadRecoverySubmissionUnfenced()
    }

    public func clearRecoverySubmission(authorizationID: AccountAuthorizationID, candidate: AccountTrustHistoryEntryV1) throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = try loadRecoverySubmissionUnfenced(),
              current.authorizationID == authorizationID,
              current.candidate == candidate
        else { throw AccountProtocolError.equivocation }
        try secretStore.delete(recoverySubmissionKey)
    }

    private func loadRecoverySubmissionUnfenced() throws -> AccountRecoverySubmissionCheckpoint? {
        guard let record = try secretStore.load(recoverySubmissionKey) else { return nil }
        guard record.attributes == .deviceOnly,
              let journal = try? JSONDecoder().decode(RecoverySubmissionJournal.self, from: record.value),
              journal.version == 1,
              journal.material.count == 64,
              (try? Self.encodeRecoverySubmissionJournal(journal)) == record.value
        else { throw AccountRuntimeError.corruptSecret }
        let key = try loadOrCreateActivationIntegrityKey()
        guard try journal.verify(authenticationKey: key) else { throw AccountRuntimeError.corruptSecret }
        let candidate = try AccountWireCodec.decodeTrustHistoryEntry(journal.candidate)
        guard candidate.commit.state.transition.kind == .recovery,
              case .recovery(let evidence)? = candidate.evidence,
              evidence.authorization.authorizationID == journal.authorizationID
        else { throw AccountRuntimeError.corruptSecret }
        let material = try AccountTrustKeyMaterial(
            accountID: candidate.commit.state.accountID,
            epoch: candidate.commit.state.epoch,
            keyGeneration: candidate.commit.state.keyGeneration,
            trustRevision: candidate.commit.state.revision,
            mailboxMatchingKey: Data(journal.material.prefix(32)),
            metadataKey: Data(journal.material.suffix(32))
        )
        guard material.commitment == candidate.commit.state.keyCommitment else { throw AccountRuntimeError.corruptSecret }
        return AccountRecoverySubmissionCheckpoint(
            authorizationID: journal.authorizationID,
            candidate: candidate,
            prepared: AccountPreparedTrustActivation(entries: [candidate], material: material)
        )
    }

    private static func encodeRecoverySubmissionJournal(_ value: RecoverySubmissionJournal) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func finishRecoveryTrustActivationUnfenced(_ wire: Data) throws {
        let journal = try JSONDecoder().decode(RecoveryTrustActivationJournal.self, from: wire)
        try verifyActivationJournal(journal)
        guard journal.version == 1,
              journal.accountID == journal.credentials.accountID,
              journal.deviceID == journal.credentials.deviceID,
              journal.history.count == 1,
              journal.material.count == 64
        else { throw AccountRuntimeError.corruptSecret }
        let entries = try journal.history.map(AccountWireCodec.decodeTrustHistoryEntry)
        guard let final = entries.first,
              final.commit.state.transition.kind == .recovery,
              final.commit.state.accountID == journal.accountID,
              final.commit.state.members.contains(where: { $0.deviceID == journal.deviceID })
        else { throw AccountRuntimeError.corruptSecret }
        let material = try AccountTrustKeyMaterial(
            accountID: journal.accountID,
            epoch: final.commit.state.epoch,
            keyGeneration: final.commit.state.keyGeneration,
            trustRevision: final.commit.state.revision,
            mailboxMatchingKey: Data(journal.material.prefix(32)),
            metadataKey: Data(journal.material.suffix(32))
        )
        try trustStore.installPreparedRecoveryActivation(AccountPreparedTrustActivation(entries: entries, material: material), deviceID: journal.deviceID)
        try testAfterActivationStep?("trust")
        let digest = Data(SHA256.hash(data: wire))
        let active = ActiveActivationRecord(session: AccountSession(credentials: journal.credentials), genesisMaterial: nil, activationDigest: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try secretStore.replace(try encoder.encode(active), key: sessionCredentialsKey, attributes: .deviceOnly)
        try testAfterActivationStep?("session")
        try secretStore.replace(digest, key: activationMarkerKey, attributes: .deviceOnly)
        try testAfterActivationStep?("marker")
        try secretStore.delete(activationJournalKey)
        try secretStore.delete(recoverySubmissionKey)
    }

    private func finishPendingTrustActivationUnfenced(_ wire: Data) throws {
        let journal = try JSONDecoder().decode(PendingTrustActivationJournal.self, from: wire)
        try verifyActivationJournal(journal)
        guard journal.version == 1,
              journal.activation.mode == .pending,
              journal.activation.accountID == journal.credentials.accountID,
              journal.activation.deviceID == journal.credentials.deviceID,
              !journal.history.isEmpty,
              journal.history.count <= 32 * 11,
              journal.material.count == 64
        else { throw AccountRuntimeError.corruptSecret }
        let entries = try journal.history.map(AccountWireCodec.decodeTrustHistoryEntry)
        guard let final = entries.last,
              final.commit.state.accountID == journal.activation.accountID,
              final.commit.state.members.contains(where: { $0.deviceID == journal.activation.deviceID })
        else { throw AccountRuntimeError.corruptSecret }
        let material = try AccountTrustKeyMaterial(
            accountID: journal.activation.accountID,
            epoch: final.commit.state.epoch,
            keyGeneration: final.commit.state.keyGeneration,
            trustRevision: final.commit.state.revision,
            mailboxMatchingKey: Data(journal.material.prefix(32)),
            metadataKey: Data(journal.material.suffix(32))
        )
        try trustStore.installPreparedActivation(AccountPreparedTrustActivation(entries: entries, material: material), deviceID: journal.activation.deviceID)
        try testAfterActivationStep?("trust")
        let digest = Data(SHA256.hash(data: wire))
        let active = ActiveActivationRecord(session: AccountSession(credentials: journal.credentials), genesisMaterial: nil, activationDigest: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try saveExactActivationRecord(encoder.encode(active), key: sessionCredentialsKey)
        try testAfterActivationStep?("session")
        try saveExactActivationRecord(digest, key: activationMarkerKey)
        try testAfterActivationStep?("marker")
        try secretStore.delete(activationJournalKey)
    }

    private func finishGenesisActivationUnfenced(_ wire: Data) throws {
        let journal = try JSONDecoder().decode(GenesisActivationJournal.self, from: wire)
        try verifyActivationJournal(journal)
        guard journal.version == 1, journal.activation.mode == .genesis, journal.activation.accountID == journal.credentials.accountID, journal.activation.deviceID == journal.credentials.deviceID, journal.genesisMaterial.count == 64, journal.activation.currentTrustCommit == journal.commit else { throw AccountRuntimeError.corruptSecret }
        let digest = Data(SHA256.hash(data: wire))
        try trustStore.installGenesis(journal.commit, material: journal.genesisMaterial)
        try testAfterActivationStep?("trust")
        let active = ActiveActivationRecord(session: AccountSession(credentials: journal.credentials), genesisMaterial: journal.genesisMaterial, activationDigest: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try saveExactActivationRecord(encoder.encode(active), key: sessionCredentialsKey)
        try testAfterActivationStep?("session")
        try saveExactActivationRecord(digest, key: activationMarkerKey)
        try testAfterActivationStep?("marker")
        try secretStore.delete(activationJournalKey)
    }

    private func saveExactActivationRecord(_ value: Data, key: AccountSecretKey) throws {
        if let existing = try secretStore.load(key) {
            guard existing.attributes == .deviceOnly, existing.value == value else { throw AccountProtocolError.equivocation }
            return
        }
        guard try secretStore.compareAndSwap(expected: nil, replacement: value, key: key, attributes: .deviceOnly) else {
            guard let winner = try secretStore.load(key), winner.attributes == .deviceOnly, winner.value == value else { throw AccountProtocolError.equivocation }
            return
        }
    }

    private func loadOrCreateActivationIntegrityKey() throws -> Data {
        if let stored = try secretStore.load(activationIntegrityKey) {
            guard stored.attributes == .deviceOnly, stored.value.count == 32 else { throw AccountRuntimeError.corruptSecret }
            return stored.value
        }
        let candidate = try AccountAPIClient.secureRandom(32)
        guard try secretStore.compareAndSwap(expected: nil, replacement: candidate, key: activationIntegrityKey, attributes: .deviceOnly) else {
            guard let winner = try secretStore.load(activationIntegrityKey), winner.attributes == .deviceOnly, winner.value.count == 32 else { throw AccountRuntimeError.corruptSecret }
            return winner.value
        }
        return candidate
    }

    private func verifyActivationJournal(_ journal: GenesisActivationJournal) throws {
        let key = try loadOrCreateActivationIntegrityKey()
        guard HMAC<SHA256>.isValidAuthenticationCode(journal.authenticationTag, authenticating: try journal.authenticationPayload(), using: SymmetricKey(data: key)) else { throw AccountRuntimeError.corruptSecret }
    }

    private func verifyActivationJournal(_ journal: PendingTrustActivationJournal) throws {
        let key = try loadOrCreateActivationIntegrityKey()
        guard HMAC<SHA256>.isValidAuthenticationCode(journal.authenticationTag, authenticating: try journal.authenticationPayload(), using: SymmetricKey(data: key)) else { throw AccountRuntimeError.corruptSecret }
    }

    private func verifyActivationJournal(_ journal: RecoveryTrustActivationJournal) throws {
        let key = try loadOrCreateActivationIntegrityKey()
        guard HMAC<SHA256>.isValidAuthenticationCode(journal.authenticationTag, authenticating: try journal.authenticationPayload(), using: SymmetricKey(data: key)) else { throw AccountRuntimeError.corruptSecret }
    }

    private func isExactCommittedGenesisActivation(_ journalWire: Data) throws -> Bool {
        let storedSession = try secretStore.load(sessionCredentialsKey)
        let storedMarker = try secretStore.load(activationMarkerKey)
        guard storedSession != nil || storedMarker != nil else { return false }
        guard let storedSession, let storedMarker,
              storedSession.attributes == .deviceOnly,
              storedMarker.attributes == .deviceOnly,
              let active = try? JSONDecoder().decode(ActiveActivationRecord.self, from: storedSession.value),
              active.version == 4,
              let activationDigest = active.activationDigest,
              activationDigest == storedMarker.value
        else { throw AccountRuntimeError.corruptSecret }
        guard activationDigest == Data(SHA256.hash(data: journalWire)) else { throw AccountProtocolError.equivocation }
        return true
    }
    private static let opaqueReferencePrefix = Data("plainpost-secure-enclave-reference.v1:".utf8)
    private static let opaqueAgreementPrefix = Data("plainpost-secure-enclave-agreement.v1:".utf8)
    private static func opaqueReference(from stored: Data) -> Data? {
        guard stored.starts(with: opaqueReferencePrefix) else { return nil }
        let reference = Data(stored.dropFirst(opaqueReferencePrefix.count))
        return reference.isEmpty ? nil : reference
    }
    private static func opaqueAgreementReference(from stored: Data) -> Data? {
        guard stored.starts(with: opaqueAgreementPrefix) else { return nil }
        let reference = Data(stored.dropFirst(opaqueAgreementPrefix.count))
        return reference.isEmpty ? nil : reference
    }
}

#if canImport(Security)
private final class SendableSecKey: @unchecked Sendable {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }
}

extension AccountCredentialStore {
    static func createSecureEnclaveAgreementIdentity(accessGroup: String? = nil) throws -> AccountOpaqueAgreementIdentity? {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
            throw AccountRuntimeError.secretUnavailable
        }
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: access,
        ]
        if let accessGroup {
            privateAttributes[kSecAttrAccessGroup as String] = accessGroup
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = (error?.takeRetainedValue() as Error?) as NSError?
            if code?.domain == NSOSStatusErrorDomain,
               [errSecUnimplemented, errSecNotAvailable].contains(OSStatus(code!.code)) {
                return nil
            }
            throw AccountRuntimeError.cryptographicFailure
        }
        let reference = try persistentReference(for: key)
        return try opaqueAgreementIdentity(key: key, reference: reference)
    }

    /// A persistent reference names exactly one Keychain item, whatever its
    /// access group. Adding `kSecAttrAccessGroup` to this lookup makes it fail
    /// with errSecParam (-50) (Task 1 spike), so the query never names a group;
    /// the item's group was fixed when the key was created.
    static func secureEnclaveKeyQuery(persistentReference reference: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecValuePersistentRef as String: reference,
            kSecReturnRef as String: true,
        ]
    }

    static func resolveSecureEnclaveAgreementIdentity(_ reference: Data) throws -> AccountOpaqueAgreementIdentity {
        let query = secureEnclaveKeyQuery(persistentReference: reference)
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let key = result as! SecKey? else {
            throw AccountRuntimeError.corruptSecret
        }
        return try opaqueAgreementIdentity(key: key, reference: reference)
    }

    private static func opaqueAgreementIdentity(key: SecKey, reference: Data) throws -> AccountOpaqueAgreementIdentity {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw AccountRuntimeError.corruptSecret
        }
        let agreementKey = SendableSecKey(key)
        return try AccountOpaqueAgreementIdentity(publicKey: external, persistentReference: reference) { peer in
            let peerKeyAttributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            guard let peerKey = SecKeyCreateWithData(peer as CFData, peerKeyAttributes as CFDictionary, nil) else {
                throw AccountRuntimeError.cryptographicFailure
            }
            var error: Unmanaged<CFError>?
            guard let shared = SecKeyCopyKeyExchangeResult(
                agreementKey.key,
                SecKeyAlgorithm.ecdhKeyExchangeStandard,
                peerKey,
                [:] as CFDictionary,
                &error
            ) as Data? else {
                throw AccountRuntimeError.cryptographicFailure
            }
            return AccountSharedSecret(shared)
        }
    }

    static func createSecureEnclaveSigningIdentity(accessGroup: String? = nil) throws -> AccountOpaqueSigningIdentity? {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else { throw AccountRuntimeError.secretUnavailable }
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: access,
        ]
        if let accessGroup {
            privateAttributes[kSecAttrAccessGroup as String] = accessGroup
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        if let accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = (error?.takeRetainedValue() as Error?) as NSError?
            // A parameter error means our requested key policy is malformed,
            // not that the device lacks a Secure Enclave. Only explicit
            // unavailability/unimplemented responses may select fallback.
            if code?.domain == NSOSStatusErrorDomain, [errSecUnimplemented, errSecNotAvailable].contains(OSStatus(code!.code)) { return nil }
            throw AccountRuntimeError.secretUnavailable
        }
        do {
            let reference = try persistentReference(for: key)
            return try opaqueIdentity(key: key, reference: reference)
        } catch {
            SecItemDelete([kSecValuePersistentRef as String: try? persistentReference(for: key)] as CFDictionary)
            throw error
        }
    }

    static func resolveSecureEnclaveSigningIdentity(_ reference: Data) throws -> AccountOpaqueSigningIdentity {
        var result: CFTypeRef?
        let query = secureEnclaveKeyQuery(persistentReference: reference)
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let key = result as! SecKey? else { throw AccountRuntimeError.corruptSecret }
        return try opaqueIdentity(key: key, reference: reference)
    }

    private static func persistentReference(for key: SecKey) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecValueRef as String: key, kSecReturnPersistentRef as String: true] as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else { throw AccountRuntimeError.secretUnavailable }
        return reference
    }

    private static func opaqueIdentity(key: SecKey, reference: Data) throws -> AccountOpaqueSigningIdentity {
        guard let publicKey = SecKeyCopyPublicKey(key), let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw AccountRuntimeError.corruptSecret }
        let signingKey = SendableSecKey(key)
        return try AccountOpaqueSigningIdentity(publicKey: external, persistentReference: reference) { transcript in
            let digest = Data(SHA256.hash(data: transcript))
            var error: Unmanaged<CFError>?
            guard let der = SecKeyCreateSignature(signingKey.key, .ecdsaSignatureDigestX962SHA256, digest as CFData, &error) as Data? else { throw AccountRuntimeError.cryptographicFailure }
            return try Self.rawP256Signature(fromDER: der)
        }
    }

    static func rawP256Signature(fromDER der: Data) throws -> Data {
        var index = 0
        func byte() throws -> UInt8 { guard index < der.count else { throw AccountRuntimeError.cryptographicFailure }; defer { index += 1 }; return der[index] }
        func length() throws -> Int { let value = try byte(); guard value < 128 else { throw AccountRuntimeError.cryptographicFailure }; return Int(value) }
        func scalar() throws -> Data {
            guard try byte() == 0x02 else { throw AccountRuntimeError.cryptographicFailure }
            let count = try length()
            guard count > 0, count <= 33, index + count <= der.count else { throw AccountRuntimeError.cryptographicFailure }
            let encoded = Data(der[index..<index + count]); index += count
            guard encoded[0] & 0x80 == 0 else { throw AccountRuntimeError.cryptographicFailure }
            let magnitude: Data
            if encoded.count > 1, encoded[0] == 0 {
                guard encoded[1] & 0x80 != 0 else { throw AccountRuntimeError.cryptographicFailure }
                magnitude = Data(encoded.dropFirst())
            } else { magnitude = encoded }
            guard magnitude.count <= 32 else { throw AccountRuntimeError.cryptographicFailure }
            return Data(repeating: 0, count: 32 - magnitude.count) + magnitude
        }
        guard try byte() == 0x30, try length() == der.count - index else { throw AccountRuntimeError.cryptographicFailure }
        let r = try scalar(), s = try scalar()
        guard index == der.count, !r.allSatisfy({ $0 == 0 }), !s.allSatisfy({ $0 == 0 }), r.lexicographicallyPrecedes(AccountDeviceIdentity.p256Order), s.lexicographicallyPrecedes(AccountDeviceIdentity.p256Order) else { throw AccountRuntimeError.cryptographicFailure }
        let normalized = AccountDeviceIdentity.normalizedLowS(r + s)
        do { try AccountWireCodec.validateLowSSignature(normalized) } catch { throw AccountRuntimeError.cryptographicFailure }
        return normalized
    }
}
#endif

private struct ActiveActivationRecord: Codable {
    let version: Int
    let state: String
    let session: AccountSession
    let genesisMaterial: Data?
    let activationDigest: Data?
    init(session: AccountSession, genesisMaterial: Data?, activationDigest: Data? = nil) { version = activationDigest == nil ? 3 : 4; state = "active-with-genesis"; self.session = session; self.genesisMaterial = genesisMaterial; self.activationDigest = activationDigest }
}
private struct GenesisActivationJournal: Codable {
    let version: Int; let activation: AccountActivation; let credentials: AccountSessionCredentials; let genesisMaterial: Data; let commit: AccountTrustStateCommit; let authenticationTag: Data
    init(activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data, commit: AccountTrustStateCommit, authenticationKey: Data) throws {
        version=1; self.activation=activation; self.credentials=credentials; self.genesisMaterial=genesisMaterial; self.commit=commit
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(for: try Self.payload(version: 1, activation: activation, credentials: credentials, genesisMaterial: genesisMaterial, commit: commit), using: SymmetricKey(data: authenticationKey)))
    }
    func authenticationPayload() throws -> Data { try Self.payload(version: version, activation: activation, credentials: credentials, genesisMaterial: genesisMaterial, commit: commit) }
    private static func payload(version: Int, activation: AccountActivation, credentials: AccountSessionCredentials, genesisMaterial: Data, commit: AccountTrustStateCommit) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("Plainpost.LocalGenesisActivationJournal.v1".utf8) + (try encoder.encode(GenesisActivationJournalPayload(version: version, activation: activation, credentials: credentials, genesisMaterial: genesisMaterial, commit: commit)))
    }
}
private struct PendingTrustActivationJournal: Codable {
    let version: Int
    let activation: AccountActivation
    let credentials: AccountSessionCredentials
    let history: [Data]
    let material: Data
    let authenticationTag: Data
    init(activation: AccountActivation, credentials: AccountSessionCredentials, history: [Data], material: Data, authenticationKey: Data) throws {
        version = 1
        self.activation = activation
        self.credentials = credentials
        self.history = history
        self.material = material
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(for: try Self.payload(version: 1, activation: activation, credentials: credentials, history: history, material: material), using: SymmetricKey(data: authenticationKey)))
    }
    func authenticationPayload() throws -> Data { try Self.payload(version: version, activation: activation, credentials: credentials, history: history, material: material) }
    private static func payload(version: Int, activation: AccountActivation, credentials: AccountSessionCredentials, history: [Data], material: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("Plainpost.LocalPendingTrustActivationJournal.v1".utf8) + (try encoder.encode(PendingTrustActivationJournalPayload(version: version, activation: activation, credentials: credentials, history: history, material: material)))
    }
}
private struct RecoveryTrustActivationJournal: Codable {
    let version: Int
    let accountID: PlainpostAccountID
    let deviceID: AccountDeviceID
    let credentials: AccountSessionCredentials
    let history: [Data]
    let material: Data
    let authenticationTag: Data
    init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, credentials: AccountSessionCredentials, history: [Data], material: Data, authenticationKey: Data) throws {
        version = 1
        self.accountID = accountID
        self.deviceID = deviceID
        self.credentials = credentials
        self.history = history
        self.material = material
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(for: try Self.payload(version: 1, accountID: accountID, deviceID: deviceID, credentials: credentials, history: history, material: material), using: SymmetricKey(data: authenticationKey)))
    }
    func authenticationPayload() throws -> Data { try Self.payload(version: version, accountID: accountID, deviceID: deviceID, credentials: credentials, history: history, material: material) }
    private static func payload(version: Int, accountID: PlainpostAccountID, deviceID: AccountDeviceID, credentials: AccountSessionCredentials, history: [Data], material: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("Plainpost.LocalRecoveryTrustActivationJournal.v1".utf8) + (try encoder.encode(RecoveryTrustActivationJournalPayload(version: version, accountID: accountID, deviceID: deviceID, credentials: credentials, history: history, material: material)))
    }
}
private struct GenesisActivationJournalPayload: Codable { let version: Int; let activation: AccountActivation; let credentials: AccountSessionCredentials; let genesisMaterial: Data; let commit: AccountTrustStateCommit }
private struct PendingTrustActivationJournalPayload: Codable { let version: Int; let activation: AccountActivation; let credentials: AccountSessionCredentials; let history: [Data]; let material: Data }
private struct RecoveryTrustActivationJournalPayload: Codable { let version: Int; let accountID: PlainpostAccountID; let deviceID: AccountDeviceID; let credentials: AccountSessionCredentials; let history: [Data]; let material: Data }
private struct RecoverySubmissionJournal: Codable {
    let version: Int
    let authorizationID: AccountAuthorizationID
    let candidate: Data
    let material: Data
    let authenticationTag: Data

    init(authorizationID: AccountAuthorizationID, candidate: Data, material: Data, authenticationKey: Data) throws {
        guard candidate.count <= 640 * 1024, material.count == 64, authenticationKey.count == 32 else { throw AccountRuntimeError.corruptSecret }
        version = 1
        self.authorizationID = authorizationID
        self.candidate = candidate
        self.material = material
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(for: try Self.payload(version: 1, authorizationID: authorizationID, candidate: candidate, material: material), using: SymmetricKey(data: authenticationKey)))
    }

    func verify(authenticationKey: Data) throws -> Bool {
        guard version == 1, authenticationKey.count == 32, authenticationTag.count == 32,
              candidate.count <= 640 * 1024, material.count == 64
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            authenticationTag,
            authenticating: try Self.payload(version: version, authorizationID: authorizationID, candidate: candidate, material: material),
            using: SymmetricKey(data: authenticationKey)
        )
    }

    private static func payload(version: Int, authorizationID: AccountAuthorizationID, candidate: Data, material: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("Plainpost.LocalRecoverySubmissionJournal.v1".utf8) + (try encoder.encode(RecoverySubmissionJournalPayload(version: version, authorizationID: authorizationID, candidate: candidate, material: material)))
    }
}
private struct RecoverySubmissionJournalPayload: Codable { let version: Int; let authorizationID: AccountAuthorizationID; let candidate: Data; let material: Data }
private struct LocalDeletionJournal: Codable {
    let version: Int
    let checkpoint: AccountLocalDeletionCheckpoint
    let authorizationWire: Data
    let headCommitDigest: Data
    let authenticationTag: Data
    init(checkpoint: AccountLocalDeletionCheckpoint, authorizationWire: Data, headCommitDigest: Data, credential: Data) throws {
        guard credential.count == 32, headCommitDigest.count == 32, !authorizationWire.isEmpty, authorizationWire.count <= 16 * 1024 else { throw AccountRuntimeError.corruptSecret }
        version = 2; self.checkpoint = checkpoint; self.authorizationWire = authorizationWire; self.headCommitDigest = headCommitDigest
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(for: try Self.payload(version: 2, checkpoint: checkpoint, authorizationWire: authorizationWire, headCommitDigest: headCommitDigest), using: SymmetricKey(data: credential)))
    }
    func verify(credential: Data) throws -> Bool {
        guard version == 2, credential.count == 32, authenticationTag.count == 32, headCommitDigest.count == 32, !authorizationWire.isEmpty, authorizationWire.count <= 16 * 1024 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(authenticationTag, authenticating: try Self.payload(version: version, checkpoint: checkpoint, authorizationWire: authorizationWire, headCommitDigest: headCommitDigest), using: SymmetricKey(data: credential))
    }
    private static func payload(version: Int, checkpoint: AccountLocalDeletionCheckpoint, authorizationWire: Data, headCommitDigest: Data) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data("Plainpost.LocalAccountDeletionJournal.v2".utf8) + (try encoder.encode(LocalDeletionJournalPayload(version: version, checkpoint: checkpoint, authorizationWire: authorizationWire, headCommitDigest: headCommitDigest)))
    }
}
private struct LocalDeletionJournalPayload: Codable { let version: Int; let checkpoint: AccountLocalDeletionCheckpoint; let authorizationWire: Data; let headCommitDigest: Data }
private struct ClearedSessionRecord: Codable { let version: Int; let state: String; init() { version = 1; state = "cleared" } }

private struct ProvisionalActivationRecord: Codable {
    let version: Int
    let state: String
    let accountID: PlainpostAccountID
    let deviceID: AccountDeviceID
    let mode: AccountBootstrapMode
    let genesisMaterial: Data?
    let credentials: AccountSessionCredentials?
    init(activation: AccountActivation, credentials: AccountSessionCredentials? = nil, genesisMaterial: Data?) {
        version = credentials == nil ? 1 : 2
        state = "bootstrap-provisional"
        accountID = activation.accountID
        deviceID = activation.deviceID
        mode = activation.mode
        self.genesisMaterial = genesisMaterial
        self.credentials = credentials
    }
    var session: AccountSession {
        get throws {
            guard [1, 2].contains(version), state == "bootstrap-provisional", (mode == .genesis && genesisMaterial?.count == 64 && credentials == nil) || (mode == .pending && genesisMaterial == nil) else { throw AccountRuntimeError.corruptSecret }
            let activation = AccountActivation(accountID: accountID, deviceID: deviceID, mode: mode)
            if let credentials { return try AccountSession(provisional: activation, credentials: credentials) }
            return .provisional(accountID: accountID, deviceID: deviceID, mode: mode)
        }
    }
}

private extension Data {
    init?(hexIdentity: String) { guard hexIdentity.count.isMultiple(of: 2) else { return nil }; self = Data(stride(from: 0, to: hexIdentity.count, by: 2).compactMap { UInt8(hexIdentity.dropFirst($0).prefix(2), radix: 16) }); guard count == hexIdentity.count / 2 else { return nil } }
}
