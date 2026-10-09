import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport

public enum NotificationEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production

    /// The APNs environment the app's provisioning profile grants. A development-signed
    /// build gets sandbox tokens even in the Release configuration, so the build
    /// configuration can't decide it; an App Store build has no embedded profile.
    public static func provisioned(embeddedProfile: Data?) -> NotificationEnvironment {
        guard let embeddedProfile,
              let start = embeddedProfile.range(of: Data("<?xml".utf8)),
              let end = embeddedProfile.range(of: Data("</plist>".utf8), in: start.lowerBound..<embeddedProfile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: embeddedProfile[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              entitlements["aps-environment"] as? String == "development"
        else { return .production }
        return .sandbox
    }

    /// `provisioned(embeddedProfile:)` for the running app.
    public static var currentApp: NotificationEnvironment {
        provisioned(embeddedProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) })
    }
}

public enum NotificationPermissionState: Equatable, Sendable {
    case authorized
    case denied
}

public enum NotificationRegistrationFailure: String, Codable, Equatable, Sendable, Error {
    case permissionDenied
    case appAttestUnsupported
    case invalidDeviceToken
    case noActiveProducer
    case tokenInvalid
    case reapprovalRequired
    case relayUnavailable
    case invalidResponse
    case pairingUnavailable
    case revocationPending
    case unavailable
}

public enum NotificationRegistrationStatus: Equatable, Sendable {
    case unconfigured
    case registering
    case registered
    case unavailable(NotificationRegistrationFailure)
    case degraded(NotificationRegistrationFailure)
    case revoked
}

public enum NotificationRecoveryAction: String, Equatable, Sendable {
    case openSettings
    case selectProducer
    case reapprove
    case refreshToken
    case retry
}

extension NotificationRegistrationStatus {
    public var recoveryAction: NotificationRecoveryAction? {
        switch self {
        case .degraded(.permissionDenied): return .openSettings
        case .unavailable(.noActiveProducer), .degraded(.noActiveProducer): return .selectProducer
        case .unavailable(.reapprovalRequired), .degraded(.reapprovalRequired): return .reapprove
        case .unavailable(.tokenInvalid), .degraded(.tokenInvalid): return .refreshToken
        case .unavailable(.appAttestUnsupported), .unconfigured, .registering, .registered, .revoked: return nil
        case .unavailable, .degraded: return .retry
        }
    }
}

/// Mail pairing and notification registration are deliberately independent.
/// A notification failure must not make a paired mailbox unavailable.
public enum NotificationMailPairingState: String, Codable, Equatable, Sendable {
    case unpaired
    case paired
}

public struct NotificationTrustSnapshot: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let epoch: UInt64
    public let revision: UInt64
    public let trustHead: Data
    public let nodeID: AccountDeviceID?
    public let nodeSigningPublicKey: Data?

    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, epoch: UInt64, revision: UInt64, trustHead: Data, nodeID: AccountDeviceID? = nil, nodeSigningPublicKey: Data? = nil) throws {
        guard epoch > 0, revision > 0, trustHead.count == 32 else { throw AccountRuntimeError.corruptSecret }
        guard (nodeID == nil) == (nodeSigningPublicKey == nil) else { throw AccountRuntimeError.corruptSecret }
        if let nodeSigningPublicKey, (try? P256.Signing.PublicKey(x963Representation: nodeSigningPublicKey)) == nil { throw AccountRuntimeError.corruptSecret }
        self.accountID = accountID
        self.deviceID = deviceID
        self.epoch = epoch
        self.revision = revision
        self.trustHead = trustHead
        self.nodeID = nodeID
        self.nodeSigningPublicKey = nodeSigningPublicKey
    }
}

/// Initial registration carries an App Attest attestation object. It has a
/// distinct type and wire kind so an assertion can never be accepted on the
/// attestation path by accident.
public struct NotificationAttestationRegistrationRequest: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let apnsDeviceToken: Data
    public let topic: String
    public let environment: NotificationEnvironment
    /// The App Attest key identifier is part of the signed registration
    /// envelope.  It lets the relay bind the proof to the key whose
    /// attestation/assertion it verifies.
    public let appAttestKeyID: String
    public let challenge: Data
    /// Canonical, opaque client data. The exact bytes are hashed for App Attest
    /// and sent unchanged to the relay, so the proof cannot be rebound.
    public let clientData: Data
    public let attestationObject: Data

    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, apnsDeviceToken: Data, topic: String, environment: NotificationEnvironment, appAttestKeyID: String, challenge: Data, clientData: Data, attestationObject: Data) throws {
        guard !apnsDeviceToken.isEmpty, apnsDeviceToken.count <= 128,
              !topic.isEmpty, topic.utf8.count <= 255,
              !topic.contains(where: { $0.isWhitespace }),
              !appAttestKeyID.isEmpty, appAttestKeyID.utf8.count <= 255,
              challenge.count == 32,
              !appAttestKeyID.contains(where: { $0.isWhitespace }),
              !clientData.isEmpty, clientData.count <= 4096,
              !attestationObject.isEmpty, attestationObject.count <= 32768
        else { throw AccountRuntimeError.untrustedResponse }
        self.accountID = accountID; self.deviceID = deviceID; self.apnsDeviceToken = apnsDeviceToken
        self.topic = topic; self.environment = environment; self.appAttestKeyID = appAttestKeyID; self.challenge = challenge
        self.clientData = clientData; self.attestationObject = attestationObject
    }
}

/// Subsequent registration changes carry an App Attest assertion. Keeping it
/// separate from the initial request prevents a proof-mode mix-up during
/// retries or server route changes.
public struct NotificationAssertionRegistrationRequest: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let apnsDeviceToken: Data
    public let topic: String
    public let environment: NotificationEnvironment
    public let appAttestKeyID: String
    public let challenge: Data
    public let clientData: Data
    public let assertion: Data

    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, apnsDeviceToken: Data, topic: String, environment: NotificationEnvironment, appAttestKeyID: String, challenge: Data, clientData: Data, assertion: Data) throws {
        guard !apnsDeviceToken.isEmpty, apnsDeviceToken.count <= 128,
              !topic.isEmpty, topic.utf8.count <= 255,
              !topic.contains(where: { $0.isWhitespace }),
              !appAttestKeyID.isEmpty, appAttestKeyID.utf8.count <= 255,
              challenge.count == 32,
              !appAttestKeyID.contains(where: { $0.isWhitespace }),
              !clientData.isEmpty, clientData.count <= 4096,
              !assertion.isEmpty, assertion.count <= 16384
        else { throw AccountRuntimeError.untrustedResponse }
        self.accountID = accountID; self.deviceID = deviceID; self.apnsDeviceToken = apnsDeviceToken
        self.topic = topic; self.environment = environment; self.appAttestKeyID = appAttestKeyID; self.challenge = challenge
        self.clientData = clientData; self.assertion = assertion
    }
}

public struct NotificationRegistrationResponse: Equatable, Sendable {
    public let routingHandle: Data
    public init(routingHandle: Data) throws {
        guard routingHandle.count == 32 else { throw AccountRuntimeError.untrustedResponse }
        self.routingHandle = routingHandle
    }
}

/// Producer authority needed by the notification extension for one mailbox.
/// The signing key is public, but must still come from the authenticated
/// assignment/trust response rather than from a local device guess.
public struct NotificationRecipientProducerContext: Sendable, Equatable {
    public let logicalMailboxID: Data
    public let assignmentGeneration: UInt64
    public let producerDeviceID: AccountDeviceID
    public let producerSigningPublicKey: Data

    public init(logicalMailboxID: Data, assignmentGeneration: UInt64, producerDeviceID: AccountDeviceID, producerSigningPublicKey: Data) throws {
        guard logicalMailboxID.count == 32, logicalMailboxID.contains(where: { $0 != 0 }),
              assignmentGeneration > 0,
              (try? P256.Signing.PublicKey(x963Representation: producerSigningPublicKey)) != nil else {
            throw AccountRuntimeError.untrustedResponse
        }
        self.logicalMailboxID = logicalMailboxID
        self.assignmentGeneration = assignmentGeneration
        self.producerDeviceID = producerDeviceID
        self.producerSigningPublicKey = producerSigningPublicKey
    }
}

/// This is transferred over the already authenticated pairing channel. It
/// contains no APNs token, App Attest object, or private key.
public struct NotificationRecipientRegistration: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID
    public let epoch: UInt64
    public let revision: UInt64
    public let logicalMailboxID: Data
    public let assignmentGeneration: UInt64
    public let trustHead: Data
    public let routingHandle: Data
    public let agreementPublicKey: Data
    public let deviceSignature: Data

    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID, epoch: UInt64, revision: UInt64, trustHead: Data, routingHandle: Data, agreementPublicKey: Data, deviceSignature: Data, logicalMailboxID: Data = Data(repeating: 0, count: 32), assignmentGeneration: UInt64 = 0) throws {
        guard trustHead.count == 32, routingHandle.count == 32,
              agreementPublicKey.count == 65, agreementPublicKey.first == 4,
              deviceSignature.count == 64 else { throw AccountRuntimeError.untrustedResponse }
        self.accountID = accountID; self.deviceID = deviceID; self.epoch = epoch; self.revision = revision
        self.logicalMailboxID = logicalMailboxID
        self.assignmentGeneration = assignmentGeneration
        self.trustHead = trustHead; self.routingHandle = routingHandle
        self.agreementPublicKey = agreementPublicKey; self.deviceSignature = deviceSignature
    }

    /// Exact 285-byte PPR2 recipient record uploaded to Central. The legacy
    /// transfer initializer remains useful for paired-node test fixtures, but
    /// production Central upload rejects its zero mailbox/generation.
    public var signedRecord: Data {
        var wire = Data("PPR2".utf8)
        wire.append(Self.identifierBytes(accountID.rawValue))
        wire.append(Self.identifierBytes(deviceID.rawValue))
        wire.append(logicalMailboxID)
        Self.appendUInt64(assignmentGeneration, to: &wire)
        Self.appendUInt64(epoch, to: &wire)
        Self.appendUInt64(revision, to: &wire)
        wire.append(trustHead); wire.append(routingHandle); wire.append(agreementPublicKey); wire.append(deviceSignature)
        return wire
    }

    /// Must remain byte-for-byte compatible with the Node recipient verifier.
    public var signingTranscript: Data {
        if logicalMailboxID.count == 32, assignmentGeneration > 0 {
            return Self.signingTranscript(
                accountID: accountID, deviceID: deviceID, logicalMailboxID: logicalMailboxID,
                assignmentGeneration: assignmentGeneration, epoch: epoch, revision: revision,
                trustHead: trustHead, routingHandle: routingHandle, agreementPublicKey: agreementPublicKey
            )
        }
        return Self.signingTranscript(accountID: accountID, deviceID: deviceID, epoch: epoch, revision: revision, trustHead: trustHead, routingHandle: routingHandle, agreementPublicKey: agreementPublicKey)
    }

    /// Builds the exact length-prefixed transcript consumed by the paired
    /// Node. UUID identifiers use their 16-byte wire representation; the
    /// textual fallback exists only for pre-UUID test fixtures.
    public static func signingTranscript(accountID: PlainpostAccountID, deviceID: AccountDeviceID, logicalMailboxID: Data, assignmentGeneration: UInt64, epoch: UInt64, revision: UInt64, trustHead: Data, routingHandle: Data, agreementPublicKey: Data) -> Data {
        transcript([
            Data("Plainpost.NotificationRecipientRegistration.v1".utf8),
            identifierBytes(accountID.rawValue), identifierBytes(deviceID.rawValue), logicalMailboxID,
            Self.u64(assignmentGeneration),
            Self.u64(epoch), Self.u64(revision), trustHead, routingHandle, agreementPublicKey
        ])
    }

    /// Compatibility transcript for paired-node fixtures that predate mailbox
    /// assignment binding. It is never used by Central's PPR2 upload path.
    public static func signingTranscript(accountID: PlainpostAccountID, deviceID: AccountDeviceID, epoch: UInt64, revision: UInt64, trustHead: Data, routingHandle: Data, agreementPublicKey: Data) -> Data {
        transcript([
            Data("Plainpost.NotificationRecipientRegistration.v1".utf8),
            identifierBytes(accountID.rawValue), identifierBytes(deviceID.rawValue),
            Self.u64(epoch), Self.u64(revision), trustHead, routingHandle, agreementPublicKey
        ])
    }

    private static func identifierBytes(_ value: String) -> Data {
        guard let uuid = UUID(uuidString: value) else { return Data(value.utf8) }
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    private static func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func appendUInt64(_ value: UInt64, to data: inout Data) { data.append(u64(value)) }
    private static func transcript(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { result, part in
            var length = UInt32(part.count).bigEndian
            result.append(Data(bytes: &length, count: 4)); result.append(part)
        }
    }
}

public protocol NotificationPermissionProviding: Sendable {
    func requestAuthorization() async throws -> Bool
}

public protocol APNSTokenProviding: Sendable {
    func token() async throws -> Data
}

public protocol AppAttestProviding: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// Used by simulator and platforms without DeviceCheck. Pairing and mail stay
/// available; only the optional notification registration action is disabled.
public struct UnsupportedAppAttestProvider: AppAttestProviding, Sendable {
    public init() {}
    public let isSupported = false
    public func generateKey() async throws -> String { throw NotificationRegistrationFailure.appAttestUnsupported }
    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw NotificationRegistrationFailure.appAttestUnsupported }
    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { throw NotificationRegistrationFailure.appAttestUnsupported }
}

public protocol NotificationRegistrationRemote: Sendable {
    func issueChallenge() async throws -> Data
    func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse
    func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse
    func revoke(routingHandle: Data) async throws
}

public protocol NotificationRecipientTransfer: Sendable {
    func transfer(_ registration: NotificationRecipientRegistration) async throws
}

/// Uploads the recipient's trust-signed PPR2 record to Central for the
/// currently selected mailbox assignment. This is separate from the optional
/// paired-node transfer so Direct Mode remains account-level and Mac-only.
public protocol NotificationRecipientRegistrationUploading: Sendable {
    func upload(_ registration: NotificationRecipientRegistration) async throws
}

public protocol NotificationRecipientRevoking: Sendable {
    func revoke() async throws
}

/// Sends the recipient's current routing authority over the authenticated
/// Node session. Central registration is not considered ready until this
/// second, authenticated hop has applied the same trust commit.
public struct NodeSyncNotificationRecipientTransfer: NotificationRecipientTransfer, NotificationRecipientRevoking, @unchecked Sendable {
    private let client: NodeSyncClient
    private let trustCommit: Data

    public init(client: NodeSyncClient, trustCommit: Data) throws {
        guard !trustCommit.isEmpty, trustCommit.count <= 256 * 1024 else { throw NotificationRegistrationFailure.pairingUnavailable }
        self.client = client
        self.trustCommit = trustCommit
    }

    public func transfer(_ registration: NotificationRecipientRegistration) async throws {
        let request = try NodeSyncNotificationRecipientRequest(
            accountID: registration.accountID.rawValue,
            deviceID: registration.deviceID.rawValue,
            trustEpoch: String(registration.epoch),
            trustRevision: String(registration.revision),
            trustHead: registration.trustHead,
            routingHandle: registration.routingHandle,
            agreementPublicKey: registration.agreementPublicKey,
            deviceSignature: registration.deviceSignature,
            trustCommit: trustCommit
        )
        do {
            _ = try await client.applyNotificationRecipient(request)
        } catch {
            throw NotificationRegistrationFailure.pairingUnavailable
        }
    }

    public func revoke() async throws {
        do {
            try await client.removeNotificationRecipient()
        } catch {
            throw NotificationRegistrationFailure.pairingUnavailable
        }
    }
}

/// Production adapter for the existing authenticated account API. The
/// transport signs requests with the paired account identity; this type only
/// owns the versioned notification request encoding and bounded decoding.
public actor AccountNotificationRegistrationRemote: NotificationRegistrationRemote, NotificationRecipientRegistrationUploading {
    private let client: AccountAPIClient
    private let credentials: AccountSessionCredentials
    private let device: AccountDeviceIdentity
    private let currentSession: (@Sendable () async throws -> (AccountSessionCredentials, AccountDeviceIdentity))?

    public init(client: AccountAPIClient, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, currentSession: (@Sendable () async throws -> (AccountSessionCredentials, AccountDeviceIdentity))? = nil) {
        self.client = client; self.credentials = credentials; self.device = device; self.currentSession = currentSession
    }

    private func session() async throws -> (AccountSessionCredentials, AccountDeviceIdentity) {
        try await currentSession?() ?? (credentials, device)
    }

    public func issueChallenge() async throws -> Data {
        let (credentials, device) = try await session()
        let body = try JSONSerialization.data(withJSONObject: ["kind": "ios.notification-registration-challenge.v1"], options: [.sortedKeys, .withoutEscapingSlashes])
        let response = try await client.sendAccountRequest(method: "POST", path: "/v1/notifications/registrations/challenge", body: body, credentials: credentials, device: device, maximumResponseBytes: 1024)
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              root["kind"] as? String == "ios.notification-registration-challenge.v1",
              let encoded = root["challenge"] as? String,
              let challenge = try? AccountWireCodec.decodeBase64URL(encoded),
              challenge.count == 32 else { throw AccountRuntimeError.untrustedResponse }
        return challenge
    }

    public func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse {
        try await register(
            kind: "ios.notification-registration-attest.v1",
            accountID: request.accountID, deviceID: request.deviceID,
            apnsDeviceToken: request.apnsDeviceToken, topic: request.topic,
            environment: request.environment, appAttestKeyID: request.appAttestKeyID,
            challenge: request.challenge, clientData: request.clientData, proof: request.attestationObject,
            proofField: "attestationObject",
            path: "/v1/notifications/registrations/attest"
        )
    }

    public func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse {
        try await register(
            kind: "ios.notification-registration-assert.v1",
            accountID: request.accountID, deviceID: request.deviceID,
            apnsDeviceToken: request.apnsDeviceToken, topic: request.topic,
            environment: request.environment, appAttestKeyID: request.appAttestKeyID,
            challenge: request.challenge, clientData: request.clientData, proof: request.assertion,
            proofField: "assertion",
            path: "/v1/notifications/registrations/assert"
        )
    }

    private func register(kind: String, accountID: PlainpostAccountID, deviceID: AccountDeviceID, apnsDeviceToken: Data, topic: String, environment: NotificationEnvironment, appAttestKeyID: String, challenge: Data, clientData: Data, proof: Data, proofField: String, path: String) async throws -> NotificationRegistrationResponse {
        guard let clientDataString = String(data: clientData, encoding: .utf8),
              Data(clientDataString.utf8) == clientData else {
            throw AccountRuntimeError.untrustedResponse
        }
        let object: [String: Any] = [
            "kind": kind, "accountID": accountID.rawValue,
            "deviceID": deviceID.rawValue, "apnsDeviceToken": AccountWireCodec.encodeBase64URL(apnsDeviceToken),
            "topic": topic, "environment": environment.rawValue,
            "appAttestKeyID": appAttestKeyID,
            "challenge": AccountWireCodec.encodeBase64URL(challenge),
            // clientData is deliberately canonical UTF-8 JSON produced by
            // the coordinator. The round-trip guard above prevents silently
            // replacing arbitrary bytes with lossy replacement characters.
            "clientData": clientDataString,
            proofField: AccountWireCodec.encodeBase64URL(proof),
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let (credentials, device) = try await session()
        let response = try await client.sendAccountRequest(method: "POST", path: path, body: body, credentials: credentials, device: device, maximumResponseBytes: 1024)
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any], root["kind"] as? String == "ios.notification-registration-response.v1", let encoded = root["routingHandle"] as? String, let handle = try? AccountWireCodec.decodeBase64URL(encoded) else { throw AccountRuntimeError.untrustedResponse }
        return try NotificationRegistrationResponse(routingHandle: handle)
    }

    public func revoke(routingHandle: Data) async throws {
        guard routingHandle.count == 32 else { throw AccountRuntimeError.untrustedResponse }
        let (credentials, device) = try await session()
        let body = try JSONSerialization.data(withJSONObject: ["kind": "ios.notification-registration-revoke.v1", "routingHandle": AccountWireCodec.encodeBase64URL(routingHandle)], options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try await client.sendAccountRequest(method: "POST", path: "/v1/notifications/registrations/revoke", body: body, credentials: credentials, device: device, maximumResponseBytes: 512, expectedStatusCodes: [200, 204])
    }

    public func upload(_ registration: NotificationRecipientRegistration) async throws {
        let (credentials, device) = try await session()
        guard registration.accountID.rawValue == credentials.accountID.rawValue,
              registration.deviceID.rawValue == credentials.deviceID.rawValue,
              registration.logicalMailboxID.count == 32,
              registration.logicalMailboxID.contains(where: { $0 != 0 }),
              registration.assignmentGeneration > 0,
              registration.signedRecord.count == 285 else {
            throw AccountRuntimeError.untrustedResponse
        }
        let body: [String: Any] = [
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(registration.logicalMailboxID),
            "assignmentGeneration": registration.assignmentGeneration,
            "trustEpoch": registration.epoch,
            "trustRevision": registration.revision,
            "trustHead": AccountWireCodec.encodeBase64URL(registration.trustHead),
            "recipientDeviceID": registration.deviceID.rawValue,
            "signedRecord": AccountWireCodec.encodeBase64URL(registration.signedRecord),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try await client.sendAccountRequest(
            method: "PUT", path: "/v1/notifications/producers/recipients", body: encoded,
            credentials: credentials, device: device, maximumRequestBytes: 16 * 1024,
            maximumResponseBytes: 512, expectedStatusCodes: [200, 204]
        )
    }
}

public protocol NotificationRegistrationStoring: Sendable {
    func load(_ key: NotificationRegistrationStoreKey) throws -> Data?
    func save(_ value: Data, for key: NotificationRegistrationStoreKey) throws
    func delete(_ key: NotificationRegistrationStoreKey) throws
}

public enum NotificationRegistrationStoreKey: String, Hashable, Sendable {
    case agreementPrivateKey
    case agreementPublicKey
    case attestKeyID
    case pendingAttestation
    case routingHandle
    case recipientDeviceID
    case nodeDeviceID
    case nodeSigningPublicKey
    case trustEpoch
    case trustRevision
    case trustHead
    case previewPolicy
    case deepLinkMapping
    case registrationState
    case mailboxContexts
}

/// A response-loss-safe initial attestation envelope. It is deliberately kept
/// in the same device-only Keychain group as the key identifier: if Central
/// accepted the proof but the response was lost, retrying these exact bytes is
/// safe and cannot silently mint a second App Attest key. The record is short
/// lived because challenges are one-time and must not be replayed indefinitely.
private struct PendingNotificationAttestation: Codable, Sendable {
    static let lifetime: TimeInterval = 5 * 60
    let accountID: PlainpostAccountID
    let deviceID: AccountDeviceID
    let topic: String
    let environment: NotificationEnvironment
    let epoch: UInt64
    let revision: UInt64
    let keyID: String
    let apnsDeviceToken: Data
    let challenge: Data
    let clientData: Data
    let attestationObject: Data
    let createdAt: Date
    let expiresAt: Date

    init(request: NotificationAttestationRegistrationRequest, trust: NotificationTrustSnapshot, now: Date = Date()) throws {
        self.accountID = request.accountID
        self.deviceID = request.deviceID
        self.topic = request.topic
        self.environment = request.environment
        self.epoch = trust.epoch
        self.revision = trust.revision
        self.keyID = request.appAttestKeyID
        self.apnsDeviceToken = request.apnsDeviceToken
        self.challenge = request.challenge
        self.clientData = request.clientData
        self.attestationObject = request.attestationObject
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
    }

    func request() throws -> NotificationAttestationRegistrationRequest {
        try NotificationAttestationRegistrationRequest(
            accountID: accountID, deviceID: deviceID, apnsDeviceToken: apnsDeviceToken,
            topic: topic, environment: environment, appAttestKeyID: keyID,
            challenge: challenge, clientData: clientData, attestationObject: attestationObject
        )
    }
}

public final class InMemoryNotificationRegistrationStore: NotificationRegistrationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NotificationRegistrationStoreKey: Data] = [:]
    public init() {}
    public func load(_ key: NotificationRegistrationStoreKey) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func save(_ value: Data, for key: NotificationRegistrationStoreKey) throws { lock.lock(); values[key] = value; lock.unlock() }
    public func delete(_ key: NotificationRegistrationStoreKey) throws { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}

/// Main iOS registration coordinator. It is a main-actor model so views can
/// consume status/actions without owning any App Attest, APNs, or Keychain
/// details. The mail pairing state is never changed by this coordinator.
@MainActor
public final class NotificationRegistrationModel {
    public private(set) var status: NotificationRegistrationStatus = .unconfigured
    public private(set) var mailPairingState: NotificationMailPairingState
    public private(set) var previewPolicy: NotificationPreviewPolicy
    public private(set) var needsLaunchReconciliation = false
    /// Main-app assembly may observe this without coupling views to the
    /// registration implementation. The callback carries status only; token,
    /// proof, challenge, and recipient material are never exposed.
    public var statusObserver: (@MainActor @Sendable (NotificationRegistrationStatus) -> Void)?

    private let trust: @Sendable () async throws -> NotificationTrustSnapshot
    private let identitySignature: @Sendable (Data) throws -> Data
    private let permission: any NotificationPermissionProviding
    private let apns: any APNSTokenProviding
    private let attest: any AppAttestProviding
    private let remote: any NotificationRegistrationRemote
    private let transfer: (any NotificationRecipientTransfer)?
    private let recipientUploader: (any NotificationRecipientRegistrationUploading)?
    private let recipientCoordinates: (@Sendable () async throws -> [(logicalMailboxID: Data, assignmentGeneration: UInt64)])?
    private let recipientContexts: (@Sendable () async throws -> [NotificationRecipientProducerContext])?
    private let policyUpdater: AccountNotificationPolicyUpdater?
    private let policyRemoteFactory: (@Sendable (LogicalMailboxID?) async throws -> any NotificationPolicyRemote)?
    private let policyDefaultPersistence: (@Sendable (NodeSyncNotificationPolicyMode) async throws -> Void)?
    private let store: any NotificationRegistrationStoring
    private let topic: String
    private let environment: NotificationEnvironment
    private var routingHandle: Data?
    private var policyUpdateTask: Task<Void, Never>?

    public init(
        trust: @escaping @Sendable () async throws -> NotificationTrustSnapshot,
        identitySignature: @escaping @Sendable (Data) throws -> Data,
        permission: any NotificationPermissionProviding,
        apns: any APNSTokenProviding,
        attest: any AppAttestProviding,
        remote: any NotificationRegistrationRemote,
        transfer: (any NotificationRecipientTransfer)? = nil,
        recipientUploader: (any NotificationRecipientRegistrationUploading)? = nil,
        recipientCoordinates: (@Sendable () async throws -> [(logicalMailboxID: Data, assignmentGeneration: UInt64)])? = nil,
        recipientContexts: (@Sendable () async throws -> [NotificationRecipientProducerContext])? = nil,
        store: any NotificationRegistrationStoring,
        topic: String,
        environment: NotificationEnvironment,
        mailPairingState: NotificationMailPairingState,
        policyUpdater: AccountNotificationPolicyUpdater? = nil,
        policyRemoteFactory: (@Sendable (LogicalMailboxID?) async throws -> any NotificationPolicyRemote)? = nil,
        policyDefaultPersistence: (@Sendable (NodeSyncNotificationPolicyMode) async throws -> Void)? = nil
    ) throws {
        guard !topic.isEmpty, topic.utf8.count <= 255 else { throw AccountRuntimeError.untrustedResponse }
        self.trust = trust; self.identitySignature = identitySignature; self.permission = permission; self.apns = apns; self.attest = attest
        self.remote = remote; self.transfer = transfer; self.recipientUploader = recipientUploader
        self.recipientCoordinates = recipientCoordinates; self.recipientContexts = recipientContexts; self.store = store; self.topic = topic; self.environment = environment
        self.policyUpdater = policyUpdater
        self.policyRemoteFactory = policyRemoteFactory
        self.policyDefaultPersistence = policyDefaultPersistence
        self.mailPairingState = mailPairingState
        if let saved = try store.load(.previewPolicy), let value = String(data: saved, encoding: .utf8), let policy = NotificationPreviewPolicy(rawValue: value) {
            previewPolicy = policy
        } else {
            previewPolicy = .rich
        }
        routingHandle = try store.load(.routingHandle)
        let persistedPrivateKey = try store.load(.agreementPrivateKey)
        let persistedPublicKey = try store.load(.agreementPublicKey)
        let persistedAttestKeyID = try store.load(.attestKeyID)
        let hasPersistedRegistrationMaterial = routingHandle?.count == 32
            && persistedPrivateKey?.count == 32
            && persistedPublicKey?.count == 65
            && persistedAttestKeyID?.isEmpty == false
        if hasPersistedRegistrationMaterial {
            status = .registered
            needsLaunchReconciliation = true
            if let state = try store.load(.registrationState), String(data: state, encoding: .utf8) == "revoked" {
                status = .revoked
                needsLaunchReconciliation = false
            } else {
                // This also upgrades registrations written before the
                // registration-state marker was introduced.
                try? store.save(Data("registered".utf8), for: .registrationState)
            }
        }
    }

    public func setMailPairingState(_ state: NotificationMailPairingState) { mailPairingState = state }

    /// The policy is local-only and may be selected before the system prompt.
    /// It never changes mail pairing or the authenticated registration proof.
    public func setPreviewPolicy(_ policy: NotificationPreviewPolicy) {
        let wasRegistered = status == .registered
        let wasRevoked = status == .revoked
        let retryingFailedOffUpdate: Bool = {
            guard case .degraded(.unavailable) = status else { return false }
            return policy == .off
        }()
        do {
            try store.save(Data(policy.rawValue.utf8), for: .previewPolicy)
        } catch {
            // The local privacy preference is the fail-closed gate for remote
            // policy mutation. Do not claim or publish a policy that could not
            // survive restart, and surface the degraded state to the user.
            setStatus(.degraded(.unavailable))
            return
        }
        previewPolicy = policy
        if policy == .off, wasRegistered {
            policyUpdateTask?.cancel()
            policyUpdateTask = Task { [weak self] in await self?.revoke() }
            return
        }
        if policy != .off, wasRevoked {
            policyUpdateTask?.cancel()
            policyUpdateTask = Task { [weak self] in await self?.retry() }
            return
        }
        guard wasRegistered || retryingFailedOffUpdate else {
            if policy == .off, wasRegistered { setStatus(.degraded(.unavailable)) }
            return
        }
        guard hasPolicyRemote else {
            // A registered Direct Mode producer still needs an acknowledged
            // policy path. Never report a local-only preference change as if
            // the producer received it.
            setStatus(.degraded(.unavailable))
            return
        }
        policyUpdateTask?.cancel()
        policyUpdateTask = Task { [weak self] in
            do {
                try await self?.persistPolicyRemotely(policy: policy)
                if policy == .off { self?.setStatus(.revoked) }
            } catch is CancellationError {
                return
            } catch {
                self?.setStatus(.degraded(Self.failure(for: error)))
            }
        }
    }

    public func configure() async {
        guard previewPolicy != .off else { setStatus(.unconfigured); return }
        setStatus(.registering)
        do {
            try Task.checkCancellation()
            guard try await permission.requestAuthorization() else { setStatus(.degraded(.permissionDenied)); return }
            try Task.checkCancellation()
            guard attest.isSupported else { setStatus(.unavailable(.appAttestUnsupported)); return }
            let trust = try await trust()
            let privateKey = try agreementPrivateKey()
            let publicKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation
            let response: NotificationRegistrationResponse
            let usingPendingAttestation: Bool
            let keyID: String
            let token: Data
            let clientData: Data
            let challenge: Data
            if let pending = try loadPendingAttestation(for: trust) {
                let request = try pending.request()
                usingPendingAttestation = true
                keyID = request.appAttestKeyID
                token = request.apnsDeviceToken
                clientData = request.clientData
                challenge = request.challenge
                response = try await remote.registerAttestation(request)
            } else {
                let currentToken = try await apns.token()
                try Task.checkCancellation()
                guard !currentToken.isEmpty, currentToken.count <= 128 else { throw NotificationRegistrationFailure.invalidDeviceToken }
                token = currentToken
                if let saved = try store.load(.attestKeyID), let existing = String(data: saved, encoding: .utf8), !existing.isEmpty {
                    keyID = existing
                    let currentChallenge = try await remote.issueChallenge()
                    try Task.checkCancellation()
                    challenge = currentChallenge
                    clientData = try Self.clientData(challenge: currentChallenge, trust: trust, agreementPublicKey: publicKey, appAttestKeyID: existing, apnsToken: token, topic: topic, environment: environment)
                    let proof = try await attest.generateAssertion(existing, clientDataHash: Data(SHA256.hash(data: clientData)))
                    try Task.checkCancellation()
                    let request = try NotificationAssertionRegistrationRequest(accountID: trust.accountID, deviceID: trust.deviceID, apnsDeviceToken: token, topic: topic, environment: environment, appAttestKeyID: keyID, challenge: challenge, clientData: clientData, assertion: proof)
                    usingPendingAttestation = false
                    response = try await remote.registerAssertion(request)
                } else {
                    keyID = try await attest.generateKey()
                    guard !keyID.isEmpty else { throw AccountRuntimeError.cryptographicFailure }
                    let currentChallenge = try await remote.issueChallenge()
                    try Task.checkCancellation()
                    challenge = currentChallenge
                    clientData = try Self.clientData(challenge: currentChallenge, trust: trust, agreementPublicKey: publicKey, appAttestKeyID: keyID, apnsToken: token, topic: topic, environment: environment)
                    let proof = try await attest.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
                    try Task.checkCancellation()
                    let request = try NotificationAttestationRegistrationRequest(accountID: trust.accountID, deviceID: trust.deviceID, apnsDeviceToken: token, topic: topic, environment: environment, appAttestKeyID: keyID, challenge: challenge, clientData: clientData, attestationObject: proof)
                    try savePendingAttestation(request, trust: trust)
                    usingPendingAttestation = true
                    response = try await remote.registerAttestation(request)
                }
            }
            try Task.checkCancellation()
            // Mark the App Attest key as registered only after Central accepts
            // the complete request. A crash or relay failure before this point
            // must retry initial attestation, never send an assertion for a
            // key the relay has not seen.
            if usingPendingAttestation {
                try store.save(Data(keyID.utf8), for: .attestKeyID)
                try store.delete(.pendingAttestation)
            }
            let coordinates = try await recipientCoordinates?() ?? []
            let producerContexts = try await recipientContexts?() ?? []
            if recipientUploader != nil && coordinates.isEmpty {
                // A successful APNs registration without an authoritative
                // mailbox assignment is not a usable notification producer.
                // Do not persist a route that the extension cannot bind.
                throw NotificationRegistrationFailure.noActiveProducer
            }
            // Persist the selected global policy on the optional paired Node
            // before transferring its recipient. Direct Mode has no Node hop;
            // Central already owns the attested APNs route.
            try await persistPolicyRemotely(policy: previewPolicy)
            if let recipientUploader {
                // Central requires one trust-signed PPR2 record per selected
                // mailbox assignment. No assignment means registration remains
                // valid but cannot claim producer authority yet.
                for coordinate in coordinates {
                    guard coordinate.logicalMailboxID.count == 32,
                          coordinate.logicalMailboxID.contains(where: { $0 != 0 }),
                          coordinate.assignmentGeneration > 0 else { throw AccountRuntimeError.untrustedResponse }
                    let transcript = NotificationRecipientRegistration.signingTranscript(
                        accountID: trust.accountID, deviceID: trust.deviceID,
                        logicalMailboxID: coordinate.logicalMailboxID,
                        assignmentGeneration: coordinate.assignmentGeneration,
                        epoch: trust.epoch, revision: trust.revision,
                        trustHead: trust.trustHead, routingHandle: response.routingHandle,
                        agreementPublicKey: publicKey
                    )
                    let registration = try NotificationRecipientRegistration(
                        accountID: trust.accountID, deviceID: trust.deviceID,
                        epoch: trust.epoch, revision: trust.revision, trustHead: trust.trustHead,
                        routingHandle: response.routingHandle, agreementPublicKey: publicKey,
                        deviceSignature: try identitySignature(transcript),
                        logicalMailboxID: coordinate.logicalMailboxID,
                        assignmentGeneration: coordinate.assignmentGeneration
                    )
                    try await recipientUploader.upload(registration)
                }
            } else {
                let transcript = NotificationRecipientRegistration.signingTranscript(accountID: trust.accountID, deviceID: trust.deviceID, epoch: trust.epoch, revision: trust.revision, trustHead: trust.trustHead, routingHandle: response.routingHandle, agreementPublicKey: publicKey)
                let registration = try NotificationRecipientRegistration(accountID: trust.accountID, deviceID: trust.deviceID, epoch: trust.epoch, revision: trust.revision, trustHead: trust.trustHead, routingHandle: response.routingHandle, agreementPublicKey: publicKey, deviceSignature: try identitySignature(transcript))
                if let transfer { try await transfer.transfer(registration) }
            }
            if !producerContexts.isEmpty {
                guard producerContexts.count <= 64,
                      Set(producerContexts.map(\.logicalMailboxID)).count == producerContexts.count else {
                    throw AccountRuntimeError.untrustedResponse
                }
                let records = try producerContexts.map { context in
                    try NotificationMailboxContextRecord(
                        logicalMailboxID: context.logicalMailboxID,
                        recipientAgreementPrivateKey: privateKey,
                        recipientDeviceID: trust.deviceID.rawValue,
                        producerDeviceID: context.producerDeviceID.rawValue,
                        producerSigningPublicKey: context.producerSigningPublicKey,
                        assignmentGeneration: context.assignmentGeneration,
                        trustEpoch: trust.epoch,
                        trustRevision: trust.revision,
                        trustHead: trust.trustHead,
                        policy: previewPolicy
                    )
                }
                try store.save(try JSONEncoder().encode(records), for: .mailboxContexts)
            }
            try Task.checkCancellation()
            try store.save(response.routingHandle, for: .routingHandle)
            try store.save(publicKey, for: .agreementPublicKey)
            // NotificationService needs this authority even in Direct Mode;
            // it is not conditional on a paired Sync Node.
            try store.save(Data(trust.deviceID.rawValue.utf8), for: .recipientDeviceID)
            try store.save(Self.u64(trust.epoch), for: .trustEpoch)
            try store.save(Self.u64(trust.revision), for: .trustRevision)
            try store.save(trust.trustHead, for: .trustHead)
            try store.save(Data(previewPolicy.rawValue.utf8), for: .previewPolicy)
            if let nodeID = trust.nodeID, let nodeSigningPublicKey = trust.nodeSigningPublicKey {
                try store.save(Data(nodeID.rawValue.utf8), for: .nodeDeviceID)
                try store.save(nodeSigningPublicKey, for: .nodeSigningPublicKey)
            }
            routingHandle = response.routingHandle
            try store.save(Data("registered".utf8), for: .registrationState)
            needsLaunchReconciliation = false
            setStatus(.registered)
        } catch let failure as NotificationRegistrationFailure {
            setStatus(.degraded(failure))
        } catch is CancellationError {
            return
        } catch {
            setStatus(.degraded(Self.failure(for: error)))
        }
    }

    public func retry() async {
        if case .degraded(.revocationPending) = status {
            await revoke()
            return
        }
        // Off is a durable Node policy, not an instruction to re-register.
        // If its write failed, retry that exact policy transition instead of
        // taking the registration back through configure's off guard.
        if previewPolicy == .off, case .degraded(.unavailable) = status {
            do {
                try await persistPolicyRemotely(policy: .off)
                setStatus(.revoked)
            } catch is CancellationError {
                return
            } catch {
                setStatus(.degraded(.unavailable))
            }
            return
        }
        // A Retry action is also the bounded recovery loop for transient
        // producer/relay failures. Two attempts cover a fresh token or a
        // provider wake without creating a background retry storm.
        let maximumAttempts = Self.shouldAutomaticallyRetry(status) ? 2 : 1
        for attempt in 0..<maximumAttempts {
            await configure()
            guard attempt + 1 < maximumAttempts,
                  Self.shouldAutomaticallyRetry(status) else { return }
            await Task.yield()
        }
    }

    /// Reconciles durable registration state once after app launch. This is
    /// intentionally opt-in to existing registration only: a fresh install
    /// never prompts for notification permission in the background.
    public func reconcileOnLaunch() async {
        guard needsLaunchReconciliation else { return }
        needsLaunchReconciliation = false
        await retry()
    }

    /// Applies a mailbox-scoped override through the authenticated Node API.
    /// The global registration state is deliberately unchanged; callers must
    /// use the version returned by Node as the concurrency fence.
    public func setPreviewPolicy(_ policy: NotificationPreviewPolicy, for logicalMailboxID: LogicalMailboxID) async throws {
        let mode: NodeSyncNotificationPolicyMode = switch policy {
        case .rich: .richPreview
        case .senderAndSubject: .senderSubject
        case .generic: .generic
        case .off: .off
        }
        if let policyRemoteFactory {
            let remote = try await policyRemoteFactory(logicalMailboxID)
            if let assignmentRemote = remote as? any NotificationPolicyAssignmentAccess {
                _ = try await assignmentRemote.updateNotificationPolicyPresentation(
                    for: logicalMailboxID, mode: mode, clear: false, idempotencyKey: UUID().uuidString.lowercased()
                )
                return
            }
            if let directRemote = remote as? any DirectNotificationPolicyAccess {
                let current = try await directRemote.directPolicy(for: logicalMailboxID)
                let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: logicalMailboxID, mode: mode, expectedVersion: current.scopeVersion, idempotencyKey: UUID().uuidString.lowercased())
                _ = try await directRemote.updateDirectNotificationPolicy(request)
                return
            }
        }
        let policyUpdater = try await policyUpdater(for: logicalMailboxID)
        let current = try await policyUpdater.current(logicalMailboxID: logicalMailboxID)
        let request = try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: logicalMailboxID, mode: mode, expectedVersion: current.version,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        _ = try await policyUpdater.update(request)
    }

    /// Removes a mailbox-scoped override through Node, restoring inheritance
    /// from the persisted global policy. No local registration key is erased.
    public func clearPreviewPolicy(for logicalMailboxID: LogicalMailboxID) async throws {
        if let policyRemoteFactory {
            let remote = try await policyRemoteFactory(logicalMailboxID)
            if let assignmentRemote = remote as? any NotificationPolicyAssignmentAccess {
                _ = try await assignmentRemote.updateNotificationPolicyPresentation(
                    for: logicalMailboxID, mode: .richPreview, clear: true, idempotencyKey: UUID().uuidString.lowercased()
                )
                return
            }
            if let directRemote = remote as? any DirectNotificationPolicyAccess {
                let current = try await directRemote.directPolicy(for: logicalMailboxID)
                let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: logicalMailboxID, mode: current.mode, clear: true, expectedVersion: current.scopeVersion, idempotencyKey: UUID().uuidString.lowercased())
                _ = try await directRemote.updateDirectNotificationPolicy(request)
                return
            }
        }
        let policyUpdater = try await policyUpdater(for: logicalMailboxID)
        let current = try await policyUpdater.current(logicalMailboxID: logicalMailboxID)
        _ = try await policyUpdater.clear(
            logicalMailboxID: logicalMailboxID, expectedVersion: current.version,
            idempotencyKey: UUID().uuidString.lowercased()
        )
    }

    public func notificationPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> NodeSyncNotificationPolicy {
        let policyUpdater = try await policyUpdater(for: logicalMailboxID)
        return try await policyUpdater.current(logicalMailboxID: logicalMailboxID)
    }

    public func notificationPolicyPresentation(for logicalMailboxID: LogicalMailboxID) async throws -> NotificationPolicyPresentationState {
        if let policyRemoteFactory {
            let remote = try await policyRemoteFactory(logicalMailboxID)
            if let assignmentRemote = remote as? any NotificationPolicyAssignmentAccess {
                return try await assignmentRemote.notificationPolicyPresentation(for: logicalMailboxID)
            }
        }
        return try NotificationPolicyPresentationState(nodePolicy: try await notificationPolicy(for: logicalMailboxID))
    }

    public func revoke() async {
        let handle = routingHandle ?? (try? store.load(.routingHandle)) ?? nil
        do {
            // Fence Node first. The producer must stop targeting this route
            // before Central/local teardown, and every step is retried by the
            // same bounded Retry action after a failure.
            try store.save(Data(NotificationPreviewPolicy.off.rawValue.utf8), for: .previewPolicy)
            previewPolicy = .off
            try await persistPolicyRemotely(policy: .off)
            if let transfer, let revoker = transfer as? any NotificationRecipientRevoking { try await revoker.revoke() }
            if let handle { try await remote.revoke(routingHandle: handle) }
            try clearLocalKeys(excluding: [.previewPolicy])
            routingHandle = nil
            setStatus(.revoked)
        }
        catch is CancellationError {
            return
        }
        catch {
            // A failed remote revoke needs exactly one opaque coordinate for a
            // bounded retry.  Erase every signing/agreement/attestation value
            // immediately; retaining the route alone cannot decrypt or mint a
            // notification, and allows the next attempt to finish remotely.
            try? clearLocalKeys(excluding: [.routingHandle, .previewPolicy])
            routingHandle = handle
            if let handle { try? store.save(handle, for: .routingHandle) }
            setStatus(.degraded(.revocationPending))
        }
    }

    private func setStatus(_ value: NotificationRegistrationStatus) {
        status = value
        statusObserver?(value)
    }

    private func persistPolicyRemotely(policy: NotificationPreviewPolicy) async throws {
        guard hasPolicyRemote else { return }
        let mode: NodeSyncNotificationPolicyMode = switch policy {
        case .rich: .richPreview
        case .senderAndSubject: .senderSubject
        case .generic: .generic
        case .off: .off
        }
        if let policyDefaultPersistence {
            try await policyDefaultPersistence(mode)
            return
        }
        let policyUpdater = try await policyUpdater(for: nil)
        let current = try await policyUpdater.current()
        guard current.mode != mode || current.version == "0" else { return }
        // A generic updater cannot safely represent Central's absent-default
        // v0 state. Require the dedicated persistence seam for that bootstrap;
        // otherwise fail closed instead of claiming registration on v0.
        guard current.version != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        let request = try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: nil, mode: mode, expectedVersion: current.version,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let result = try await policyUpdater.update(request)
        guard result.mode == mode, result.version != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        let verified = try await policyUpdater.current()
        guard verified.mode == mode, verified.version != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
    }

    private var hasPolicyRemote: Bool { policyUpdater != nil || policyRemoteFactory != nil || policyDefaultPersistence != nil }

    private func policyUpdater(for logicalMailboxID: LogicalMailboxID?) async throws -> AccountNotificationPolicyUpdater {
        if let policyRemoteFactory {
            return AccountNotificationPolicyUpdater(remote: try await policyRemoteFactory(logicalMailboxID))
        }
        if let policyUpdater { return policyUpdater }
        throw AccountRuntimeError.transportFailure
    }

    private func agreementPrivateKey() throws -> Data {
        if let stored = try store.load(.agreementPrivateKey) {
            guard stored.count == 32 else { throw AccountRuntimeError.corruptSecret }
            _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: stored)
            return stored
        }
        let key = P256.KeyAgreement.PrivateKey()
        let raw = key.rawRepresentation
        try store.save(raw, for: .agreementPrivateKey)
        return raw
    }

    private func clearLocalKeys(excluding excluded: Set<NotificationRegistrationStoreKey> = []) throws {
        for key in [NotificationRegistrationStoreKey.agreementPrivateKey, .agreementPublicKey, .attestKeyID, .pendingAttestation, .routingHandle, .recipientDeviceID, .nodeDeviceID, .nodeSigningPublicKey, .trustEpoch, .trustRevision, .trustHead, .previewPolicy, .deepLinkMapping, .registrationState, .mailboxContexts] where !excluded.contains(key) {
            try store.delete(key)
        }
    }

    private func loadPendingAttestation(for trust: NotificationTrustSnapshot) throws -> PendingNotificationAttestation? {
        guard let encoded = try store.load(.pendingAttestation) else { return nil }
        guard let pending = try? JSONDecoder().decode(PendingNotificationAttestation.self, from: encoded) else {
            throw AccountRuntimeError.corruptSecret
        }
        guard pending.expiresAt > Date(), pending.createdAt <= Date(), pending.accountID == trust.accountID,
              pending.deviceID == trust.deviceID, pending.epoch == trust.epoch, pending.revision == trust.revision,
              pending.topic == topic, pending.environment == environment else {
            if pending.expiresAt <= Date() { try store.delete(.pendingAttestation); return nil }
            throw AccountRuntimeError.corruptSecret
        }
        _ = try pending.request()
        return pending
    }

    private func savePendingAttestation(_ request: NotificationAttestationRegistrationRequest, trust: NotificationTrustSnapshot) throws {
        let pending = try PendingNotificationAttestation(request: request, trust: trust)
        let encoded = try JSONEncoder().encode(pending)
        guard encoded.count <= 64 * 1024 else { throw AccountRuntimeError.corruptSecret }
        try store.save(encoded, for: .pendingAttestation)
    }

    private static func clientData(challenge: Data, trust: NotificationTrustSnapshot, agreementPublicKey: Data, appAttestKeyID: String, apnsToken: Data, topic: String, environment: NotificationEnvironment) throws -> Data {
        guard !challenge.isEmpty, challenge.count <= 512 else { throw AccountRuntimeError.untrustedResponse }
        let agreementDigest = Data(SHA256.hash(data: agreementPublicKey))
        let binding = registrationBindingDigest(accountID: trust.accountID.rawValue, deviceID: trust.deviceID.rawValue, epoch: String(trust.epoch), revision: String(trust.revision), keyID: appAttestKeyID, challenge: challenge, agreementDigest: agreementDigest, token: apnsToken, topic: topic, environment: environment.rawValue)
        let value: [String: Any] = ["kind": "ios.notification-registration.v1", "challenge": AccountWireCodec.encodeBase64URL(challenge), "accountID": trust.accountID.rawValue, "deviceID": trust.deviceID.rawValue, "epoch": String(trust.epoch), "revision": String(trust.revision), "appAttestKeyID": appAttestKeyID, "agreementKeyDigest": AccountWireCodec.encodeBase64URL(agreementDigest), "registrationDigest": AccountWireCodec.encodeBase64URL(binding)]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func registrationBindingDigest(accountID: String, deviceID: String, epoch: String, revision: String, keyID: String, challenge: Data, agreementDigest: Data, token: Data, topic: String, environment: String) -> Data {
        var transcript = Data()
        for part in [Data("Plainpost.NotificationRegistrationBinding.v1".utf8), Data(accountID.utf8), Data(deviceID.utf8), Data(epoch.utf8), Data(revision.utf8), Data(keyID.utf8), challenge, agreementDigest, token, Data(topic.utf8), Data(environment.utf8)] {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { transcript.append(contentsOf: $0) }
            transcript.append(part)
        }
        return Data(SHA256.hash(data: transcript))
    }

    private static func u64(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> UInt64(56 - ($0 * 8))) & 0xff) })
    }

    private static func failure(for error: Error) -> NotificationRegistrationFailure {
        if let failure = error as? NotificationRegistrationFailure { return failure }
        if let error = error as? NodeSyncClientError {
            switch error {
            case .conflict, .problem(.unauthorized): return .reapprovalRequired
            case .notFound: return .noActiveProducer
            case .invalidResponse: return .tokenInvalid
            case .problem(.invalidRequest): return .tokenInvalid
            case .transport, .problem(.unavailable): return .relayUnavailable
            case .cancelled, .transportAfterDispatch, .cancelledAfterDispatch, .problem: return .unavailable
            }
        }
        if let error = error as? NotificationPolicyRemoteError {
            switch error {
            case .conflict, .unauthorized: return .reapprovalRequired
            case .unavailable: return .relayUnavailable
            case .invalidResponse: return .tokenInvalid
            }
        }
        if error is AccountRuntimeError { return .relayUnavailable }
        return .unavailable
    }

    private static func shouldAutomaticallyRetry(_ status: NotificationRegistrationStatus) -> Bool {
        let failure: NotificationRegistrationFailure?
        switch status {
        case .unavailable(let value), .degraded(let value): failure = value
        case .unconfigured: return true
        case .registering, .registered, .revoked: return false
        }
        switch failure {
        case .relayUnavailable, .noActiveProducer, .tokenInvalid, .unavailable: return true
        default: return false
        }
    }
}

#if canImport(DeviceCheck)
import DeviceCheck

public final class DeviceCheckAppAttestProvider: AppAttestProviding, @unchecked Sendable {
    private let service: DCAppAttestService
    public init(service: DCAppAttestService = .shared) { self.service = service }
    public var isSupported: Bool { service.isSupported }
    public func generateKey() async throws -> String { try await withCheckedThrowingContinuation { continuation in service.generateKey { key, error in if let key { continuation.resume(returning: key) } else { continuation.resume(throwing: error ?? AccountRuntimeError.cryptographicFailure) } } } }
    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { try await withCheckedThrowingContinuation { continuation in service.attestKey(keyID, clientDataHash: clientDataHash) { data, error in if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? AccountRuntimeError.cryptographicFailure) } } } }
    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { try await withCheckedThrowingContinuation { continuation in service.generateAssertion(keyID, clientDataHash: clientDataHash) { data, error in if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? AccountRuntimeError.cryptographicFailure) } } } }
}
#endif

#if canImport(Security)
import Security

/// Device-only Keychain storage for the agreement key, App Attest identifier,
/// and routing handle. Pass the application/extension access group configured
/// by the iOS target when one is available; omitting it uses the app's own
/// Keychain group and remains safe for builds without an extension.
public final class NotificationKeychainStore: NotificationRegistrationStoring, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.marynavdovenko.Plainpost.notifications", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load(_ key: NotificationRegistrationStoreKey) throws -> Data? {
        let query = baseQuery(key)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true], uniquingKeysWith: { $1 }) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountRuntimeError.secretUnavailable }
        return data
    }

    public func save(_ value: Data, for key: NotificationRegistrationStoreKey) throws {
        guard !value.isEmpty else { throw AccountRuntimeError.corruptSecret }
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AccountRuntimeError.secretUnavailable }
        var add = query
        add.merge(attributes) { _, replacement in replacement }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AccountRuntimeError.secretUnavailable }
    }

    public func delete(_ key: NotificationRegistrationStoreKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountRuntimeError.secretUnavailable }
    }

    private func baseQuery(_ key: NotificationRegistrationStoreKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
#endif

#if canImport(UIKit) && canImport(UserNotifications)
import UIKit
import UserNotifications

public struct UserNotificationPermissionProvider: NotificationPermissionProviding, Sendable {
    public init() {}
    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
}

/// The app delegate forwards didRegister/didFail callbacks to this object.
/// Token bytes stay in memory until the coordinator submits them and are
/// never persisted or included in diagnostics.
@MainActor
public final class APNsTokenProvider: NSObject, APNSTokenProviding, @unchecked Sendable {
    private let application: UIApplication
    private var waiting: CheckedContinuation<Data, Error>?
    private var currentToken: Data?

    public init(application: UIApplication = .shared) { self.application = application }

    public func token() async throws -> Data {
        try Task.checkCancellation()
        if let currentToken { return currentToken }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting?.resume(throwing: CancellationError())
                waiting = continuation
                application.registerForRemoteNotifications()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaitingRequest() }
        })
    }

    private func cancelWaitingRequest() {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }

    public func resetCachedToken() {
        currentToken = nil
        cancelWaitingRequest()
    }

    @discardableResult
    public func didRegister(deviceToken: Data) -> Bool {
        guard !deviceToken.isEmpty else { waiting?.resume(throwing: NotificationRegistrationFailure.invalidDeviceToken); waiting = nil; return false }
        let changed = currentToken != deviceToken
        currentToken = deviceToken
        waiting?.resume(returning: deviceToken); waiting = nil
        return changed
    }

    public func didFail(error: Error) {
        waiting?.resume(throwing: error); waiting = nil
    }
}
#endif
