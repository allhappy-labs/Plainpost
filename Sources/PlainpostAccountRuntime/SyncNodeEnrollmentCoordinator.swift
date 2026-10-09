import CryptoKit
import Foundation
import OSLog
import PlainpostAccountProtocol
import PlainpostNodeTransport

private let syncNodeEnrollmentLogger = Logger(subsystem: "com.marynavdovenko.Plainpost", category: "sync-node-enrollment")

/// The proposed Node supplies signatures, never a private key, to the Apple
/// approver. These short-lived proofs are retained only while an approval is
/// in progress.
public struct SyncNodeEnrollmentNodeProof: Sendable {
    public let claimProofSignature: Data

    public init(claimProofSignature: Data) throws {
        guard claimProofSignature.count == 64 else { throw AccountRuntimeError.untrustedResponse }
        self.claimProofSignature = claimProofSignature
    }
}

public struct SyncNodeEnrollmentAppleAuthorization: Sendable {
    public let identityToken: String
    public let nonce: Data

    public init(identityToken: String, nonce: Data) throws {
        guard !identityToken.isEmpty, nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else { throw AccountRuntimeError.untrustedResponse }
        self.identityToken = identityToken; self.nonce = nonce
    }
}

/// Central rejected a commit before any state change (`audienceMismatch`), or
/// returned 2xx with a body that cannot be decoded (`undecodableSuccess`),
/// which may have committed and must be replayed.
public enum SyncNodeEnrollmentCommitError: Error, Equatable, Sendable { case audienceMismatch, undecodableSuccess }

/// Non-secret classifier for a verifier failure that callers present distinctly.
public enum SyncNodeEnrollmentVerificationError: Error, Equatable, Sendable { case audienceMismatch }

/// Non-secret reason a possibly committed admission could not be installed.
/// Every case retains the exact replay material and the claim.
public enum SyncNodeEnrollmentPostCommitFailure: String, Equatable, Sendable {
    case audienceMismatch = "audience_mismatch"
    case responseVerification = "response_verification"
    case missingV2 = "missing_v2"
    case activationPreflight = "activation_preflight"
    case activationRejected = "activation_rejected"
    /// The activator failed with something other than a Node rejection or an
    /// uncertain Node response (for example a cancellation or nothing pending).
    case activationFailed = "activation_failed"
    case trustAcceptance = "trust_acceptance"
    /// The current session could not be read, or it now belongs to another
    /// account or device, so the retained request was not sent.
    case sessionUnavailable = "session_unavailable"
}

/// Returns the current, refreshed session credentials. Access tokens are
/// short-lived, so every authenticated enrollment request reads them again
/// instead of reusing the credentials captured when the flow was built.
public typealias SyncNodeEnrollmentCredentialsProvider = @Sendable () async throws -> AccountSessionCredentials

/// Result of `SyncNodeEnrollmentCoordinator.stopAndStartOver()`.
public enum SyncNodeEnrollmentStartOverOutcome: Equatable, Sendable {
    /// Central answered 204 to the claim cancel, which proves the request was
    /// never committed. The retained request is gone and a new attempt can start.
    case startedOver
    /// Not offered in the current state (or already in progress). Nothing changed.
    case unavailable
    /// Central did not confirm the cancel. The request may have committed, so
    /// it stays retained and Retry remains the way forward.
    case admissionRetained
}

public struct SyncNodeEnrollmentAdmissionRequest: Sendable {
    public let evidence: AccountNodeEnrollmentAdmissionEvidenceV1
    public let claimProofSignature, matchingConfirmationSignature, admissionApprovalSignature, idempotencyKey: Data
    public let trustCommit: AccountTrustStateCommit
    /// The audience pinned from the Server Setup profile. `nil` encodes the
    /// legacy seven-key request that Central accepts without a gate.
    public let expectedCentralAudience: String?

    public init(evidence: AccountNodeEnrollmentAdmissionEvidenceV1, claimProofSignature: Data, matchingConfirmationSignature: Data, admissionApprovalSignature: Data, idempotencyKey: Data, trustCommit: AccountTrustStateCommit, expectedCentralAudience: String? = nil) throws {
        guard claimProofSignature.count == 64, matchingConfirmationSignature.count == 64, admissionApprovalSignature.count == 64, (16 ... 128).contains(idempotencyKey.count), !idempotencyKey.allSatisfy({ $0 == 0 }), trustCommit.state.accountID == evidence.accountID, trustCommit.state.epoch == evidence.trustEpoch, expectedCentralAudience.map(AccountCentralAudience.isValid) ?? true else { throw AccountRuntimeError.untrustedResponse }
        self.evidence = evidence; self.claimProofSignature = claimProofSignature; self.matchingConfirmationSignature = matchingConfirmationSignature; self.admissionApprovalSignature = admissionApprovalSignature; self.idempotencyKey = idempotencyKey; self.trustCommit = trustCommit; self.expectedCentralAudience = expectedCentralAudience
    }
}

public struct SyncNodeEnrollmentAdmissionResponse: Sendable {
    public let result: AccountNodeEnrollmentResultV1
    public let refreshCredential: AccountNodeRefreshCredentialV1
    public let offlineLease: AccountNodeOfflineLeaseV1
    public let v2: AccountNodeEnrollmentAdmissionResponseV2?

    public init(result: AccountNodeEnrollmentResultV1, refreshCredential: AccountNodeRefreshCredentialV1, offlineLease: AccountNodeOfflineLeaseV1) throws {
        guard result.binding == refreshCredential.binding, result.binding == offlineLease.binding else { throw AccountRuntimeError.untrustedResponse }
        self.result = result; self.refreshCredential = refreshCredential; self.offlineLease = offlineLease; v2 = nil
    }
    public init(v2: AccountNodeEnrollmentAdmissionResponseV2) throws {
        let binding = v2.result.binding.base
        result = try AccountNodeEnrollmentResultV1(binding: binding, committedAt: v2.result.committedAt)
        refreshCredential = try AccountNodeRefreshCredentialV1(binding: binding, credentialID: v2.refreshCredential.credentialID, issuedAt: v2.refreshCredential.issuedAt, expiresAt: v2.refreshCredential.expiresAt, credential: v2.refreshCredential.credential)
        offlineLease = try AccountNodeOfflineLeaseV1(binding: binding, leaseID: v2.offlineLease.leaseID, issuedAt: v2.offlineLease.issuedAt, expiresAt: v2.offlineLease.expiresAt, serverKeyID: v2.offlineLease.serverKeyID, signature: v2.offlineLease.signature)
        self.v2 = v2
    }
}

/// Verifies all material exposed by Central before a node credential is made
/// available to presentation code.
public protocol SyncNodeEnrollmentResponseVerifying: Sendable {
    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws
    /// Checked before any Node presentation so a lease the manifest could not
    /// verify is never committed.
    func canVerifyNodeEnrollmentLease(at now: Date) -> Bool
}

public extension SyncNodeEnrollmentResponseVerifying {
    func canVerifyNodeEnrollmentLease(at now: Date) -> Bool { true }
}

/// The private Node is contacted only after Central's V2 admission has been
/// verified. Implementations retain the exact V3 request only for an
/// ambiguous Node response and erase it on every terminal outcome.
public protocol SyncNodeEnrollmentActivating: Sendable {
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws
    func retryUncertainActivation() async throws
    func cancelPendingActivation() async
}

/// Owns the existing local trust material needed to prepare and durably accept
/// the successor submitted with a Sync Node admission. This stays distinct
/// from generic Apple admission and recovery coordinators.
public protocol SyncNodeEnrollmentTrustCoordinating: Sendable {
    func currentTrustCommit() async throws -> AccountTrustStateCommit?
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws
}

extension AccountTrustCoordinator: SyncNodeEnrollmentTrustCoordinating {}

/// The existing authenticated session-key manifest is the sole key ring used
/// to verify a Node admission lease.
public struct ManifestBackedSyncNodeEnrollmentResponseVerifier: SyncNodeEnrollmentResponseVerifying {
    private let manifest: SessionKeyManifestVerifier
    public init(manifest: SessionKeyManifestVerifier) { self.manifest = manifest }

    public func canVerifyNodeEnrollmentLease(at now: Date) -> Bool { manifest.canVerifyNodeEnrollmentLease(at: now) }

    public func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {
        let boundAudience = response.v2?.result.binding.base.centralAudience ?? response.result.binding.centralAudience
        guard boundAudience == centralAudience, AccountCentralAudience.isValid(centralAudience) else {
            throw SyncNodeEnrollmentVerificationError.audienceMismatch
        }
        if let v2 = response.v2 { try verifyV2(v2, request: request, centralAudience: centralAudience, now: now); return }
        let binding = response.result.binding
        guard binding == response.refreshCredential.binding, binding == response.offlineLease.binding,
              binding.accountID == request.evidence.accountID,
              binding.trustEpoch == request.trustCommit.state.epoch,
              binding.claimID == request.evidence.claimID,
              binding.nodeDeviceID == request.evidence.nodeDeviceID,
              binding.action == request.evidence.action,
              binding.replacedNodeID == request.evidence.replacedNodeID,
              binding.isForCentralAudience(centralAudience),
              binding.admissionEvidenceDigest == Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence))),
              let committedAt = AccountWireCodec.parseTimestamp(response.result.committedAt), committedAt <= now,
              let refreshIssued = AccountWireCodec.parseTimestamp(response.refreshCredential.issuedAt), let refreshExpires = AccountWireCodec.parseTimestamp(response.refreshCredential.expiresAt), refreshIssued <= now, now < refreshExpires,
              let leaseIssued = AccountWireCodec.parseTimestamp(response.offlineLease.issuedAt), let leaseExpires = AccountWireCodec.parseTimestamp(response.offlineLease.expiresAt), leaseIssued <= now, now < leaseExpires,
              committedAt <= refreshIssued, refreshIssued == leaseIssued,
              manifest.verifiesNodeEnrollmentLease(response.offlineLease, at: now)
        else { throw AccountRuntimeError.untrustedResponse }

        if binding.action == .replace {
            guard let replacedNodeID = binding.replacedNodeID,
                  binding.replacementRevocationDigest == replacementRevocationDigest(accountID: binding.accountID, replacedNodeID: replacedNodeID, committedAt: response.result.committedAt)
            else { throw AccountRuntimeError.untrustedResponse }
        } else if binding.replacementRevocationDigest != nil {
            throw AccountRuntimeError.untrustedResponse
        }

        let sessionDigest = AccountTranscript.nodeEnrollmentSessionDigest(refreshCredential: response.refreshCredential.credential, offlineLeaseID: response.offlineLease.leaseID)
        let issuanceDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuance(request.evidence, centralAudience: centralAudience, sessionDigest: sessionDigest)))
        guard binding.issuanceDigest == issuanceDigest else { throw AccountRuntimeError.untrustedResponse }
    }

    private func verifyV2(_ response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {
        let binding = response.result.binding
        guard binding == response.refreshCredential.binding, binding == response.offlineLease.binding,
              binding.base.accountID == request.evidence.accountID, binding.base.trustEpoch == request.trustCommit.state.epoch,
              binding.base.claimID == request.evidence.claimID, binding.base.nodeDeviceID == request.evidence.nodeDeviceID,
              binding.base.action == request.evidence.action, binding.base.replacedNodeID == request.evidence.replacedNodeID,
              binding.base.isForCentralAudience(centralAudience), binding.base.admissionEvidenceDigest == Data(SHA256.hash(data: try AccountWireCodec.encodeNodeEnrollmentAdmissionEvidence(request.evidence))),
              response.cleanupCapability.accountID == binding.base.accountID, response.cleanupCapability.claimID == binding.base.claimID, response.cleanupCapability.nodeDeviceID == binding.base.nodeDeviceID,
              binding.cleanupCapabilityDigest == Data(SHA256.hash(data: try AccountWireCodec.encodeSyncNodeCleanupCapability(response.cleanupCapability))),
              let committedAt = AccountWireCodec.parseTimestamp(response.result.committedAt), committedAt <= now,
              let refreshIssued = AccountWireCodec.parseTimestamp(response.refreshCredential.issuedAt), let refreshExpires = AccountWireCodec.parseTimestamp(response.refreshCredential.expiresAt), refreshIssued <= now, now < refreshExpires,
              let leaseIssued = AccountWireCodec.parseTimestamp(response.offlineLease.issuedAt), let leaseExpires = AccountWireCodec.parseTimestamp(response.offlineLease.expiresAt), leaseIssued <= now, now < leaseExpires,
              committedAt <= refreshIssued, refreshIssued == leaseIssued,
              response.cleanupCapability.issuedAt == response.result.committedAt,
              manifest.verifiesNodeEnrollmentLeaseV2(response.offlineLease, at: now)
        else { throw AccountRuntimeError.untrustedResponse }
        if binding.base.action == .replace {
            guard let replacedNodeID = binding.base.replacedNodeID,
                  binding.base.replacementRevocationDigest == replacementRevocationDigest(accountID: binding.base.accountID, replacedNodeID: replacedNodeID, committedAt: response.result.committedAt)
            else { throw AccountRuntimeError.untrustedResponse }
        } else if binding.base.replacementRevocationDigest != nil {
            throw AccountRuntimeError.untrustedResponse
        }
        let sessionDigest = AccountTranscript.nodeEnrollmentSessionDigestV2(refreshCredential: response.refreshCredential.credential, offlineLeaseID: response.offlineLease.leaseID, cleanupCapabilityDigest: binding.cleanupCapabilityDigest)
        guard binding.base.issuanceDigest == Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentSessionIssuanceV2(request.evidence, centralAudience: centralAudience, sessionDigest: sessionDigest))) else { throw AccountRuntimeError.untrustedResponse }
    }

    private func replacementRevocationDigest(accountID: PlainpostAccountID, replacedNodeID: AccountDeviceID, committedAt: String) -> Data {
        Data(SHA256.hash(data: Data("Plainpost.SyncNodeReplacementRevocation.v1\u{0000}\(accountID.rawValue)\u{0000}\(replacedNodeID.rawValue)\u{0000}\(committedAt)".utf8)))
    }
}

/// Narrow boundary for account-v1 Sync Node routes. It deliberately has no
/// legacy device trust, Noise, TLS-pin, or private-Node-key surface.
public protocol SyncNodeEnrollmentRemote: Sendable {
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse
}

public protocol SyncNodeEnrollmentLocalAuthenticating: Sendable { func authenticateSyncNodeEnrollment() async throws }

public struct LocalApprovalSyncNodeEnrollmentAuthenticator: SyncNodeEnrollmentLocalAuthenticating {
    private let authenticator: any LocalApprovalAuthenticating
    public init(authenticator: any LocalApprovalAuthenticating) { self.authenticator = authenticator }
    public func authenticateSyncNodeEnrollment() async throws { try await authenticator.authenticate(reason: "Approve this Sync Node for your Plainpost account") }
}

/// Best-effort volatile storage for a setup verifier. Strings necessarily cross
/// the platform HTTP boundary briefly, but neither coordinator state nor a
/// pending claim retains one.
private final class SensitiveSetupCode: @unchecked Sendable {
    private var bytes: [UInt8]
    init(_ value: String) { bytes = Array(value.utf8) }
    func string() -> String? { bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
    func wipe() { bytes.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; bytes.removeAll(keepingCapacity: false) }
    var isPresent: Bool { !bytes.isEmpty }
}

@MainActor
public final class SyncNodeEnrollmentCoordinator: ObservableObject {
    public enum State: Equatable, Sendable { case enterCode, fetching, localAuthentication, centralStepUp, matchingStringConfirmation(String), signing, committing, commitResponseUncertain, activationResponseUncertain, commitVerificationFailed(SyncNodeEnrollmentPostCommitFailure), profileOutdated, serverAudienceMismatch, installed(AccountNodeEnrollmentResultV1), failed }

    /// Sticky states hold the only exact replay of a request Central may have
    /// committed. No cancel, disappearance, ownership change, or reset may
    /// discard them.
    public var retainsCommittedAdmission: Bool {
        switch state {
        case .committing, .commitResponseUncertain, .activationResponseUncertain, .commitVerificationFailed: return true
        default: return false
        }
    }

    @Published public private(set) var state: State = .enterCode
    @Published public private(set) var activeNodeID: AccountDeviceID?
    /// When the Node can present a fresh claim again. A Node keeps presenting
    /// its pending claim until that claim expires, and Central never looks up a
    /// cancelled claim, so after a proven cancel Connect is certain to fail
    /// until this time. Only a cancel Central confirmed moves it.
    @Published public private(set) var reconnectAvailableAt: Date?
    public private(set) var lastResponse: SyncNodeEnrollmentAdmissionResponse?
    public var retainsSetupVerifierMaterial: Bool { setupCode?.isPresent == true }
    /// Replay material exists only after Central may have committed a request
    /// whose response was lost. It is deliberately in-memory-only.
    public var hasPendingCommitReplay: Bool { replayMaterial?.isPresent == true }
    public var hasPendingActivationReplay: Bool { state == .activationResponseUncertain }

    private let remote: any SyncNodeEnrollmentRemote
    private let presenter: (any SyncNodeEnrollmentPresenting)?
    private let bootstrapVerifier: (any SyncNodeBootstrapClaimVerifying)?
    private let localAuthenticator: any SyncNodeEnrollmentLocalAuthenticating
    private let responseVerifier: any SyncNodeEnrollmentResponseVerifying
    private let trust: any SyncNodeEnrollmentTrustCoordinating
    private let activation: any SyncNodeEnrollmentActivating
    /// Fixes the owning account and device. Authenticated requests use
    /// `currentCredentials()` for the access token.
    private let credentials: AccountSessionCredentials
    private let credentialsProvider: SyncNodeEnrollmentCredentialsProvider
    private let device: AccountDeviceIdentity
    private let random: @Sendable (Int) throws -> Data
    private let responseValidationClock: @Sendable () -> Date
    private var replacementSelection: AccountDeviceID?
    private var replacementConfirmed = false
    private var pending: Pending?
    private var activationClaim: AccountNodeEnrollmentPublicClaimV1?
    private var activationExpectedOrigin: NodeEndpointURL?
    private var replayMaterial: ReplayMaterial?
    private var verifiedResponse: SyncNodeEnrollmentAdmissionResponse?
    private var claimCancellation: NodeEnrollmentClaimID?
    /// The expiry of `claimCancellation`, the Node's pending claim.
    private var claimExpiresAt: Date?
    private var setupCode: SensitiveSetupCode?
    private var cancelledClaims = Set<NodeEnrollmentClaimID>()
    private var cancellationRequested = false
    /// Central returned 2xx for this request at least once, so it committed.
    private var commitObserved = false
    /// An earlier attempt ended without a definite answer, so Central may have
    /// committed even if a later attempt is rejected before replay lookup.
    private var commitOutcomeUncertain = false
    /// The Node accepted V3 in this attempt; a verification retry skips it.
    private var activationCompleted = false
    /// A Stop and Start Over claim cancel is awaiting Central's answer.
    private var startOverInFlight = false
    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?

    private struct Pending {
        let claim: AccountNodeEnrollmentPublicClaimV1
        let action: AccountNodeEnrollmentAction
        let replacedNodeID: AccountDeviceID?
        let proof: SyncNodeEnrollmentNodeProof
        let stepUp: AccountStepUpAuthorizationV1
        let priorCommit: AccountTrustStateCommit
        let expectedOrigin: NodeEndpointURL
        let expiresAt: Date
        let centralAudience: String
    }

    private struct ClaimCancellation: Sendable {
        let claimID: NodeEnrollmentClaimID
        let setupCode: String
        let expiresAt: Date?
    }

    /// Keeps the byte-identical canonical admission that crossed the remote
    /// commit boundary. This is bounded to one active claim and is cleared on
    /// success or an explicit cancellation; it is never persisted.
    private final class ReplayMaterial {
        let evidence: AccountNodeEnrollmentAdmissionEvidenceV1
        let trustCommit: AccountTrustStateCommit
        let successor: AccountTrustStateCommit
        let expectedCentralAudience: String?
        private var claimProofSignature: [UInt8]
        private var matchingConfirmationSignature: [UInt8]
        private var admissionApprovalSignature: [UInt8]
        private var idempotencyKey: [UInt8]

        init(request: SyncNodeEnrollmentAdmissionRequest, successor: AccountTrustStateCommit) {
            evidence = request.evidence
            trustCommit = request.trustCommit
            self.successor = successor
            expectedCentralAudience = request.expectedCentralAudience
            claimProofSignature = Array(request.claimProofSignature)
            matchingConfirmationSignature = Array(request.matchingConfirmationSignature)
            admissionApprovalSignature = Array(request.admissionApprovalSignature)
            idempotencyKey = Array(request.idempotencyKey)
        }

        var isPresent: Bool { !idempotencyKey.isEmpty }

        func request() throws -> SyncNodeEnrollmentAdmissionRequest {
            guard isPresent else { throw AccountRuntimeError.untrustedResponse }
            return try SyncNodeEnrollmentAdmissionRequest(
                evidence: evidence,
                claimProofSignature: Data(claimProofSignature),
                matchingConfirmationSignature: Data(matchingConfirmationSignature),
                admissionApprovalSignature: Data(admissionApprovalSignature),
                idempotencyKey: Data(idempotencyKey),
                trustCommit: trustCommit,
                expectedCentralAudience: expectedCentralAudience)
        }

        deinit { wipe() }

        func wipe() {
            wipe(&claimProofSignature)
            wipe(&matchingConfirmationSignature)
            wipe(&admissionApprovalSignature)
            wipe(&idempotencyKey)
        }

        private func wipe(_ bytes: inout [UInt8]) {
            bytes.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            bytes.removeAll(keepingCapacity: false)
        }
    }

    public init(remote: any SyncNodeEnrollmentRemote, presenter: (any SyncNodeEnrollmentPresenting)? = nil, bootstrapVerifier: (any SyncNodeBootstrapClaimVerifying)? = nil, localAuthenticator: any SyncNodeEnrollmentLocalAuthenticating, responseVerifier: any SyncNodeEnrollmentResponseVerifying, trust: any SyncNodeEnrollmentTrustCoordinating, activation: any SyncNodeEnrollmentActivating, credentials: AccountSessionCredentials, credentialsProvider: @escaping SyncNodeEnrollmentCredentialsProvider, device: AccountDeviceIdentity, activeNodeID: AccountDeviceID?, random: @escaping @Sendable (Int) throws -> Data = AccountAPIClient.secureRandom, responseValidationClock: @escaping @Sendable () -> Date = Date.init) {
        self.remote = remote; self.presenter = presenter; self.bootstrapVerifier = bootstrapVerifier; self.localAuthenticator = localAuthenticator; self.responseVerifier = responseVerifier; self.trust = trust; self.activation = activation; self.credentials = credentials; self.credentialsProvider = credentialsProvider; self.device = device; self.activeNodeID = activeNodeID; self.random = random; self.responseValidationClock = responseValidationClock
    }

    public func selectReplacement(of nodeID: AccountDeviceID) { guard activeNodeID == nodeID else { return }; replacementSelection = nodeID; replacementConfirmed = false }
    public func confirmReplacement(of nodeID: AccountDeviceID) { guard replacementSelection == nodeID, activeNodeID == nodeID else { return }; replacementConfirmed = true }

    func start(setupCode: String, proof: SyncNodeEnrollmentNodeProof, expectedOrigin: NodeEndpointURL, centralAudience: String, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date = Date()) {
        // A new attempt must never wipe a request Central may have committed.
        guard !retainsCommittedAdmission else { return }
        guard state == .enterCode, validSetupCode(setupCode), AccountCentralAudience.isValid(centralAudience) else { clearEnrollmentMaterial(); clearReplacementConsent(); state = .failed; return }
        let action: AccountNodeEnrollmentAction; let replacedNodeID: AccountDeviceID?
        if let activeNodeID {
            guard replacementSelection == activeNodeID, replacementConfirmed else { clearEnrollmentMaterial(); clearReplacementConsent(); state = .failed; return }
            action = .replace; replacedNodeID = activeNodeID
        } else { action = .enroll; replacedNodeID = nil }
        clearEnrollmentMaterial()
        self.setupCode = SensitiveSetupCode(setupCode)
        cancellationRequested = false
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in await self?.runLegacyBegin(generation: operationGeneration, action: action, replacedNodeID: replacedNodeID, setupCode: setupCode, proof: proof, expectedOrigin: expectedOrigin, centralAudience: centralAudience, appleAuthorization: appleAuthorization, now: now) }
    }

    func begin(setupCode: String, proof: SyncNodeEnrollmentNodeProof, expectedOrigin: NodeEndpointURL, centralAudience: String, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date = Date()) async {
        start(setupCode: setupCode, proof: proof, expectedOrigin: expectedOrigin, centralAudience: centralAudience, appleAuthorization: appleAuthorization, now: now)
        await operation?.value
    }

    /// Production entry point. Presentation material is fetched only after an
    /// owned Apple authorization has completed and is pinned before local auth.
    public func start(profile: SyncNodeBootstrapProfile, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date = Date()) {
        // A new attempt must never wipe a request Central may have committed.
        guard !retainsCommittedAdmission else { return }
        guard state == .enterCode, presenter != nil, bootstrapVerifier != nil else {
            clearEnrollmentMaterial(); clearReplacementConsent(); state = .failed; return
        }
        guard let centralAudience = profile.centralAudience else {
            syncNodeEnrollmentLogger.error("sync_node_enrollment_preflight_rejection reason=profile_outdated")
            clearEnrollmentMaterial(); clearReplacementConsent(); state = .profileOutdated; return
        }
        guard responseVerifier.canVerifyNodeEnrollmentLease(at: now) else {
            syncNodeEnrollmentLogger.error("sync_node_enrollment_preflight_rejection reason=lease_key_window")
            clearEnrollmentMaterial(); clearReplacementConsent(); state = .failed; return
        }
        let action: AccountNodeEnrollmentAction
        let replacedNodeID: AccountDeviceID?
        if let activeNodeID {
            guard replacementSelection == activeNodeID, replacementConfirmed else {
                clearEnrollmentMaterial(); clearReplacementConsent(); state = .failed; return
            }
            action = .replace; replacedNodeID = activeNodeID
        } else {
            action = .enroll; replacedNodeID = nil
        }
        clearEnrollmentMaterial()
        cancellationRequested = false
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in
            await self?.runProvisionedBegin(
                generation: operationGeneration,
                action: action,
                replacedNodeID: replacedNodeID,
                profile: profile,
                centralAudience: centralAudience,
                appleAuthorization: appleAuthorization,
                now: now
            )
        }
    }

    public func begin(profile: SyncNodeBootstrapProfile, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date = Date()) async {
        start(profile: profile, appleAuthorization: appleAuthorization, now: now)
        await operation?.value
    }

    public func confirmMatchingString(_ value: String, now: Date = Date()) async {
        guard case .matchingStringConfirmation(let expected) = state, value == expected, pending != nil else { await rejectMatchingString(); return }
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in await self?.runCommit(generation: operationGeneration, now: now) }
        await operation?.value
    }

    public func approvePinnedTarget(now: Date = Date()) async {
        guard case .matchingStringConfirmation = state, pending != nil else { return }
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in await self?.runCommit(generation: operationGeneration, now: now) }
        await operation?.value
    }

    /// Resends the exact signed request and idempotency key after a response
    /// loss. It never creates a new successor commit or approval signature.
    public func retryCommit(now: Date = Date()) async {
        guard state == .commitResponseUncertain, replayMaterial != nil, !startOverInFlight else { return }
        // Claim the retry synchronously so a second tap is a no-op.
        state = .committing
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in await self?.runReplay(generation: operationGeneration, now: now) }
        await operation?.value
    }

    /// Re-posts the exact retained request (same idempotency key) after a
    /// post-commit failure, then verifies again. Central answers from its
    /// committed replay, so this works after the claim has expired.
    public func retryCommitVerification(now: Date = Date()) async {
        guard case .commitVerificationFailed = state, replayMaterial != nil else { return }
        // Claim the retry synchronously so a second tap is a no-op.
        state = .committing
        generation &+= 1
        let operationGeneration = generation
        operation = Task { @MainActor [weak self] in await self?.runReplay(generation: operationGeneration, now: now) }
        await operation?.value
    }

    /// Replays the exact retained V3 body. Central is not contacted again.
    public func retryActivation() async {
        guard state == .activationResponseUncertain, let replayMaterial, let response = verifiedResponse else { return }
        state = .committing
        do { try await activation.retryUncertainActivation() }
        catch {
            switch error as? NodeActivationError {
            case .uncertain: state = .activationResponseUncertain
            case .rejected: failAfterCommit(.activationRejected)
            default: failAfterCommit(.activationFailed)
            }
            return
        }
        activationCompleted = true
        do { try await trust.acceptSyncNodeEnrollmentCommit(replayMaterial.successor, evidence: replayMaterial.evidence) }
        catch { failAfterCommit(.trustAcceptance); return }
        lastResponse = response; activeNodeID = replayMaterial.evidence.nodeDeviceID
        clearEnrollmentMaterial(); clearReplacementConsent(); state = .installed(response.result); operation = nil
    }

    private func failAfterCommit(_ reason: SyncNodeEnrollmentPostCommitFailure) {
        syncNodeEnrollmentLogger.error("sync_node_enrollment_post_commit_failure reason=\(reason.rawValue, privacy: .public)")
        verifiedResponse = nil
        state = .commitVerificationFailed(reason)
        operation = nil
    }

    /// Stop and Start Over is offered only for an uncertain commit for which
    /// Central never answered 2xx. Once any 2xx was seen the request committed
    /// and only Retry may follow.
    public var canStopAndStartOver: Bool {
        state == .commitResponseUncertain && !commitObserved && replayMaterial?.isPresent == true && claimCancellation != nil && setupCode?.isPresent == true
    }

    /// Releases an uncertain request only after Central proves it never
    /// committed. Central answers HTTP 204 only for a claim that was never
    /// consumed: it cancels an unconsumed claim, even after it expired, and it
    /// answers 204 again for a claim that is already cancelled. The cancel
    /// writes under the same serializable claim lock every admission takes,
    /// and a claim can never be both cancelled and consumed, so a 204 still
    /// proves nothing committed. Any other answer (404/409, 5xx, transport
    /// loss, cancellation) leaves the state and the exact replay untouched.
    public func stopAndStartOver() async -> SyncNodeEnrollmentStartOverOutcome {
        guard !startOverInFlight, canStopAndStartOver, let claimID = claimCancellation, let code = setupCode?.string() else { return .unavailable }
        let claimExpiry = claimExpiresAt
        startOverInFlight = true
        do {
            try await remote.cancelSyncNodeClaim(claimID: claimID, setupCode: code)
        } catch {
            startOverInFlight = false
            syncNodeEnrollmentLogger.error("sync_node_enrollment_start_over_unconfirmed")
            return .admissionRetained
        }
        startOverInFlight = false
        // Retries are fenced while the cancel is in flight; stay defensive.
        guard state == .commitResponseUncertain, !commitObserved, claimCancellation == claimID else { return .admissionRetained }
        cancelledClaims.insert(claimID)
        recordCancelledClaim(expiringAt: claimExpiry)
        generation &+= 1; operation?.cancel(); operation = nil
        clearEnrollmentMaterial(); clearReplacementConsent()
        state = .enterCode
        syncNodeEnrollmentLogger.info("sync_node_enrollment_start_over_confirmed")
        return .startedOver
    }

    public func rejectMatchingString() async {
        // Matching rejection is only meaningful before submission; it must
        // never discard a request Central may have committed.
        guard !retainsCommittedAdmission else { return }
        generation &+= 1; operation?.cancel(); operation = nil; clearReplacementConsent(); await invalidatePendingClaim(); state = .enterCode
    }
    public func cancel() async {
        // A cancel after V3 may only cancel presentation.  It cannot undo a
        // Node commit, so keep the coordinator and activator recovery state.
        guard !retainsCommittedAdmission else {
            await activation.cancelPendingActivation()
            clearReplacementConsent()
            return
        }
        generation &+= 1; operation?.cancel(); operation = nil; cancellationRequested = true; await activation.cancelPendingActivation(); clearReplacementConsent(); state = .enterCode; await invalidatePendingClaim()
    }
    public func viewDidDisappear() async {
        guard !retainsCommittedAdmission else {
            clearReplacementConsent()
            return
        }
        await cancel()
    }

    /// Synchronously fences callbacks when the owning presentation is being
    /// replaced. Remote claim cancellation remains best effort, but no stale
    /// fetch or lookup can advance to local authorization after this returns.
    public func invalidatePresentationOwnership() {
        guard !retainsCommittedAdmission else {
            clearReplacementConsent()
            return
        }
        generation &+= 1
        operation?.cancel()
        operation = nil
        cancellationRequested = true
        clearReplacementConsent()
        state = .enterCode
        let cancellation = takePendingClaimForInvalidation()
        let remote = remote
        Task { [weak self] in
            if let cancellation {
                do {
                    try await remote.cancelSyncNodeClaim(
                        claimID: cancellation.claimID,
                        setupCode: cancellation.setupCode
                    )
                    self?.recordCancelledClaim(expiringAt: cancellation.expiresAt)
                } catch {}
            }
        }
    }
    /// A normal pre-submit failure can be restarted, while an uncertain commit
    /// must be explicitly retried or cancelled so its idempotency proof is not
    /// silently discarded.
    public func reset() {
        guard !retainsCommittedAdmission else { return }
        generation &+= 1; operation?.cancel(); operation = nil
        clearEnrollmentMaterial(); replacementSelection = nil; replacementConfirmed = false; lastResponse = nil; state = .enterCode
    }

    private func runLegacyBegin(generation operationGeneration: UInt64, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, setupCode: String, proof: SyncNodeEnrollmentNodeProof, expectedOrigin: NodeEndpointURL, centralAudience: String, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date) async {
        var ownedClaim: AccountNodeEnrollmentPublicClaimV1?
        do {
            state = .fetching
            let claim = try await remote.lookupSyncNodeClaim(setupCode: setupCode)
            ownedClaim = claim
            guard isCurrent(operationGeneration) else {
                await cancelOwnedClaim(claim, setupCode: setupCode)
                return
            }
            claimCancellation = claim.claimID
            let expiry = try claimExpiry(claim)
            claimExpiresAt = expiry
            try await continueBegin(
                generation: operationGeneration,
                action: action,
                replacedNodeID: replacedNodeID,
                claim: claim,
                proof: proof,
                expectedOrigin: expectedOrigin,
                expiresAt: expiry,
                centralAudience: centralAudience,
                appleAuthorization: appleAuthorization,
                now: now
            )
        } catch {
            guard isCurrent(operationGeneration) else {
                if let ownedClaim { await cancelOwnedClaim(ownedClaim, setupCode: setupCode) }
                return
            }
            await invalidatePendingClaim()
            guard isCurrent(operationGeneration) else { return }
            clearReplacementConsent(); state = .failed; operation = nil
        }
    }

    private func runProvisionedBegin(generation operationGeneration: UInt64, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, profile: SyncNodeBootstrapProfile, centralAudience: String, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date) async {
        var ownedClaim: AccountNodeEnrollmentPublicClaimV1?
        var ownedSetupCode: String?
        do {
            guard let presenter, let bootstrapVerifier else { throw AccountRuntimeError.untrustedResponse }
            state = .fetching
            let presentation = try await presenter.fetchPresentation(for: profile)
            try ensureCurrent(operationGeneration)
            let setupCode = presentation.setupCode
            ownedSetupCode = setupCode
            guard validSetupCode(setupCode) else { throw AccountRuntimeError.untrustedResponse }
            self.setupCode = SensitiveSetupCode(setupCode)
            let claim = try await remote.lookupSyncNodeClaim(setupCode: setupCode)
            ownedClaim = claim
            guard isCurrent(operationGeneration) else {
                await cancelOwnedClaim(claim, setupCode: setupCode)
                return
            }
            let setupData = try NodeSessionWire.decodeBase64URL(setupCode)
            let expectedOrigin = try bootstrapVerifier.verify(
                profile: profile,
                presentation: presentation,
                claim: claim,
                setupCode: setupData
            )
            try ensureCurrent(operationGeneration)
            guard now < presentation.expiresAt else { throw AccountRuntimeError.untrustedResponse }
            claimCancellation = claim.claimID
            // The verifier pinned this to the claim's own expiry.
            claimExpiresAt = presentation.expiresAt
            try await continueBegin(
                generation: operationGeneration,
                action: action,
                replacedNodeID: replacedNodeID,
                claim: claim,
                proof: SyncNodeEnrollmentNodeProof(claimProofSignature: presentation.claimProofSignature),
                expectedOrigin: expectedOrigin,
                expiresAt: presentation.expiresAt,
                centralAudience: centralAudience,
                appleAuthorization: appleAuthorization,
                now: now
            )
        } catch {
            guard isCurrent(operationGeneration) else {
                if let ownedClaim, let ownedSetupCode {
                    await cancelOwnedClaim(ownedClaim, setupCode: ownedSetupCode)
                }
                return
            }
            await invalidatePendingClaim()
            guard isCurrent(operationGeneration) else { return }
            clearReplacementConsent(); state = .failed; operation = nil
        }
    }

    private func continueBegin(generation operationGeneration: UInt64, action: AccountNodeEnrollmentAction, replacedNodeID: AccountDeviceID?, claim: AccountNodeEnrollmentPublicClaimV1, proof: SyncNodeEnrollmentNodeProof, expectedOrigin: NodeEndpointURL, expiresAt: Date, centralAudience: String, appleAuthorization: SyncNodeEnrollmentAppleAuthorization, now: Date) async throws {
        state = .localAuthentication
        try await localAuthenticator.authenticateSyncNodeEnrollment()
        try ensureCurrent(operationGeneration)
        state = .centralStepUp
        guard let priorCommit = try await trust.currentTrustCommit(),
              priorCommit.state.accountID == credentials.accountID,
              priorCommit.state.members.contains(where: { $0.deviceID == credentials.deviceID && $0.publicBundle == device.publicBundle })
        else { throw AccountRuntimeError.untrustedResponse }
        try ensureCurrent(operationGeneration)
        let sessionCredentials = try await currentCredentials()
        try ensureCurrent(operationGeneration)
        let stepUp = try await remote.issueSyncNodeStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, authorization: appleAuthorization, credentials: sessionCredentials, device: device, trustCommit: priorCommit, now: now)
        try ensureCurrent(operationGeneration)
        guard valid(stepUp: stepUp, action: action, claim: claim, replacedNodeID: replacedNodeID, trustCommit: priorCommit) else { throw AccountRuntimeError.untrustedResponse }
        pending = Pending(claim: claim, action: action, replacedNodeID: replacedNodeID, proof: proof, stepUp: stepUp, priorCommit: priorCommit, expectedOrigin: expectedOrigin, expiresAt: expiresAt, centralAudience: centralAudience)
        state = .matchingStringConfirmation(matchingString(for: claim))
        operation = nil
    }

    private func runCommit(generation operationGeneration: UInt64, now: Date) async {
        do {
            guard let pending else { throw AccountRuntimeError.untrustedResponse }
            guard now < pending.expiresAt else { throw AccountRuntimeError.untrustedResponse }
            state = .signing
            let matchingDigest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentMatchingConfirmation(pending.claim, accountID: credentials.accountID)))
            let evidence = try AccountNodeEnrollmentAdmissionEvidenceV1(accountID: credentials.accountID, trustEpoch: pending.priorCommit.state.epoch, approverDeviceID: credentials.deviceID, claimID: pending.claim.claimID, nodeDeviceID: pending.claim.nodeDeviceID, action: pending.action, replacedNodeID: pending.replacedNodeID, signingPublicKey: pending.claim.signingPublicKey, agreementPublicKey: pending.claim.agreementPublicKey, noiseStaticPublicKey: pending.claim.noiseStaticPublicKey, endpointDigest: pending.claim.endpointDigest, matchingTranscriptDigest: matchingDigest, stepUp: pending.stepUp)
            let successor = try await trust.makeSyncNodeEnrollmentCommit(evidence: evidence)
            try ensureCurrent(operationGeneration)
            guard valid(successor: successor, evidence: evidence, priorCommit: pending.priorCommit) else { throw AccountRuntimeError.untrustedResponse }
            let idempotencyKey = try random(32)
            guard idempotencyKey.count == 32, !idempotencyKey.allSatisfy({ $0 == 0 }) else { throw AccountRuntimeError.cryptographicFailure }
            let admissionSignature = try device.signature(for: AccountTranscript.nodeEnrollmentApproval(evidence, idempotencyKey: idempotencyKey))
            let matchingConfirmationSignature = try device.signature(for: AccountTranscript.nodeEnrollmentMatchingConfirmation(pending.claim, accountID: credentials.accountID))
            let request = try SyncNodeEnrollmentAdmissionRequest(evidence: evidence, claimProofSignature: pending.proof.claimProofSignature, matchingConfirmationSignature: matchingConfirmationSignature, admissionApprovalSignature: admissionSignature, idempotencyKey: idempotencyKey, trustCommit: successor, expectedCentralAudience: pending.centralAudience)
            try ensureCurrent(operationGeneration)
            replayMaterial = ReplayMaterial(request: request, successor: successor)
            activationClaim = pending.claim
            activationExpectedOrigin = pending.expectedOrigin
            self.pending = nil
            await submitReplay(generation: operationGeneration, now: now)
        } catch {
            guard isCurrent(operationGeneration) else { return }
            await invalidatePendingClaim()
            guard isCurrent(operationGeneration) else { return }
            clearReplacementConsent(); state = .failed; operation = nil
        }
    }

    private func runReplay(generation operationGeneration: UInt64, now: Date) async {
        guard replayMaterial != nil else { state = .failed; operation = nil; return }
        await submitReplay(generation: operationGeneration, now: now)
    }

    private func submitReplay(generation operationGeneration: UInt64, now: Date) async {
        guard let replayMaterial else { state = .failed; operation = nil; return }
        state = .committing
        let request: SyncNodeEnrollmentAdmissionRequest
        do { request = try replayMaterial.request() }
        catch {
            if commitObserved { failAfterCommit(.responseVerification); return }
            if commitOutcomeUncertain { state = .commitResponseUncertain; operation = nil; return }
            await invalidatePendingClaim()
            state = .failed; operation = nil
            return
        }
        let sessionCredentials: AccountSessionCredentials
        do {
            sessionCredentials = try await currentCredentials()
        } catch {
            guard isCurrent(operationGeneration) else { return }
            // Nothing was sent in this attempt. Keep any possibly committed
            // request exactly as it is.
            syncNodeEnrollmentLogger.error("sync_node_enrollment_session_unavailable")
            if commitObserved { failAfterCommit(.sessionUnavailable); return }
            if commitOutcomeUncertain { state = .commitResponseUncertain; operation = nil; return }
            await invalidatePendingClaim()
            guard isCurrent(operationGeneration) else { return }
            clearReplacementConsent(); state = .failed; operation = nil
            return
        }
        guard isCurrent(operationGeneration) else { return }
        let response: SyncNodeEnrollmentAdmissionResponse
        do {
            response = try await remote.commitSyncNodeAdmission(request, credentials: sessionCredentials, device: device, now: now)
        } catch {
            // Record what this send proved before any fence: even a stale
            // attempt's 2xx or uncertain outcome applies to the same request.
            if isUncertainCommitFailure(error) {
                // An undecodable 2xx is still a 2xx: Central committed.
                if (error as? SyncNodeEnrollmentCommitError) == .undecodableSuccess { commitObserved = true }
                commitOutcomeUncertain = true
            }
            guard isCurrent(operationGeneration) else { return }
            if isUncertainCommitFailure(error) {
                state = .commitResponseUncertain; operation = nil
                return
            }
            if commitObserved { failAfterCommit(.responseVerification); return }
            let audienceMismatch = (error as? SyncNodeEnrollmentCommitError) == .audienceMismatch
            if commitOutcomeUncertain {
                // Central's audience and authorization gates run before its
                // replay lookup, so a definite rejection of a retry cannot
                // prove an earlier uncertain attempt did not commit. Keep the
                // claim and the exact replay.
                if audienceMismatch {
                    syncNodeEnrollmentLogger.error("sync_node_enrollment_uncertain_rejection reason=audience_mismatch")
                } else {
                    syncNodeEnrollmentLogger.error("sync_node_enrollment_uncertain_rejection reason=rejected")
                }
                state = .commitResponseUncertain; operation = nil
                return
            }
            await invalidatePendingClaim()
            guard isCurrent(operationGeneration) else { return }
            clearReplacementConsent()
            if audienceMismatch {
                syncNodeEnrollmentLogger.error("sync_node_enrollment_precommit_rejection reason=audience_mismatch")
                state = .serverAudienceMismatch
            } else {
                state = .failed
            }
            operation = nil
            return
        }
        commitObserved = true
        await finishCommittedAdmission(response: response, request: request, replayMaterial: replayMaterial, generation: operationGeneration)
    }

    private func finishCommittedAdmission(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, replayMaterial: ReplayMaterial, generation operationGeneration: UInt64) async {
        var stage = SyncNodeEnrollmentPostCommitFailure.responseVerification
        do {
            try ensureCurrent(operationGeneration)
            guard let centralAudience = request.expectedCentralAudience else { throw AccountRuntimeError.untrustedResponse }
            do {
                // Validate server-issued timestamps at response receipt, not at
                // request start. A commit crossing a UTC-second boundary is still
                // fresh and must not fail nondeterministically.
                try responseVerifier.verify(response: response, request: request, centralAudience: centralAudience, now: responseValidationClock())
            } catch SyncNodeEnrollmentVerificationError.audienceMismatch {
                stage = .audienceMismatch
                throw SyncNodeEnrollmentVerificationError.audienceMismatch
            }
            try ensureCurrent(operationGeneration)
            stage = .missingV2
            guard let v2 = response.v2 else { throw AccountRuntimeError.untrustedResponse }
            if !activationCompleted {
                stage = .activationPreflight
                guard let setupCode = try setupCodeData(), let claim = activationClaim, let expectedOrigin = activationExpectedOrigin else { throw AccountRuntimeError.untrustedResponse }
                do {
                    try await activation.activate(response: v2, request: request, claim: claim, setupCode: setupCode, expectedOrigin: expectedOrigin)
                } catch where (error as? NodeActivationError) == .uncertain {
                    verifiedResponse = response; state = .activationResponseUncertain; operation = nil; return
                } catch where (error as? NodeActivationError) == .rejected {
                    stage = .activationRejected
                    throw error
                } catch {
                    // Not a Node answer (for example a cancellation). The
                    // Node may still have accepted V3; Retry Verification
                    // replays activation from the exact request.
                    stage = .activationFailed
                    throw error
                }
                activationCompleted = true
                try ensureCurrent(operationGeneration)
            }
            stage = .trustAcceptance
            try await trust.acceptSyncNodeEnrollmentCommit(replayMaterial.successor, evidence: request.evidence)
            try ensureCurrent(operationGeneration)
            lastResponse = response; activeNodeID = request.evidence.nodeDeviceID
            clearEnrollmentMaterial(); clearReplacementConsent(); state = .installed(response.result); operation = nil
        } catch {
            guard isCurrent(operationGeneration) else { return }
            failAfterCommit(stage)
        }
    }

    private func invalidatePendingClaim() async {
        guard let cancellation = takePendingClaimForInvalidation() else { return }
        do {
            try await remote.cancelSyncNodeClaim(
                claimID: cancellation.claimID,
                setupCode: cancellation.setupCode
            )
        } catch {
            // Unconfirmed: the claim may still be live, so Connect stays open.
            return
        }
        recordCancelledClaim(expiringAt: cancellation.expiresAt)
    }

    /// Only a cancel Central confirmed may delay Connect, and never shorten
    /// an existing wait.
    private func recordCancelledClaim(expiringAt expiresAt: Date?) {
        guard let expiresAt else { return }
        if let current = reconnectAvailableAt, current >= expiresAt { return }
        reconnectAvailableAt = expiresAt
    }

    private func takePendingClaimForInvalidation() -> ClaimCancellation? {
        let claimID = pending?.claim.claimID ?? claimCancellation
        let expiresAt = pending?.expiresAt ?? claimExpiresAt
        let code = setupCode?.string()
        // Snapshot and erase this attempt's local material before yielding.
        // A new attempt may begin while the best-effort remote cancellation is
        // suspended; the old operation must have no cleanup left that could
        // erase the newer generation.
        pending = nil
        clearReplayMaterial()
        claimCancellation = nil
        claimExpiresAt = nil
        clearSetupCode()
        cancellationRequested = false
        guard let claimID, let code else { return nil }
        guard cancelledClaims.insert(claimID).inserted else { return nil }
        return ClaimCancellation(claimID: claimID, setupCode: code, expiresAt: expiresAt)
    }

    private func clearEnrollmentMaterial() { pending = nil; activationClaim = nil; activationExpectedOrigin = nil; verifiedResponse = nil; clearReplayMaterial(); claimCancellation = nil; claimExpiresAt = nil; cancellationRequested = false; commitObserved = false; commitOutcomeUncertain = false; activationCompleted = false; clearSetupCode() }
    private func clearReplayMaterial() { replayMaterial?.wipe(); replayMaterial = nil }
    private func clearReplacementConsent() { replacementSelection = nil; replacementConfirmed = false }
    private func clearSetupCode() { setupCode?.wipe(); setupCode = nil }
    private func setupCodeData() throws -> Data? {
        guard let code = setupCode?.string() else { return nil }
        return try NodeSessionWire.decodeBase64URL(code)
    }
    private func claimExpiry(_ claim: AccountNodeEnrollmentPublicClaimV1) throws -> Date {
        guard let expiresAt = AccountWireCodec.parseTimestamp(claim.expiresAt) else {
            throw AccountRuntimeError.untrustedResponse
        }
        return expiresAt
    }
    private func cancelOwnedClaim(_ claim: AccountNodeEnrollmentPublicClaimV1, setupCode: String) async {
        // A fresh attempt may legitimately receive the same still-live claim.
        // Never let a late callback cancel material now owned by that attempt.
        if self.setupCode?.string() == setupCode { return }
        guard cancelledClaims.insert(claim.claimID).inserted else { return }
        do { try await remote.cancelSyncNodeClaim(claimID: claim.claimID, setupCode: setupCode) }
        catch { return }
        recordCancelledClaim(expiringAt: AccountWireCodec.parseTimestamp(claim.expiresAt))
    }
    /// The current session for the owning account and device. A session for
    /// any other owner is refused rather than used.
    private func currentCredentials() async throws -> AccountSessionCredentials {
        let current = try await credentialsProvider()
        guard current.accountID == credentials.accountID, current.deviceID == credentials.deviceID else {
            syncNodeEnrollmentLogger.error("sync_node_enrollment_session_owner_changed")
            throw AccountRuntimeError.untrustedResponse
        }
        return current
    }
    private func isCurrent(_ operationGeneration: UInt64) -> Bool { operationGeneration == generation && !Task.isCancelled }
    private func ensureCurrent(_ operationGeneration: UInt64) throws { guard isCurrent(operationGeneration) else { throw CancellationError() } }
    /// Outcomes after which Central may have committed: transport loss or 5xx,
    /// an undecodable 2xx, and a cancellation that can surface after the
    /// request was already sent.
    private func isUncertainCommitFailure(_ error: Error) -> Bool {
        error as? AccountRuntimeError == .transportFailure || (error as? SyncNodeEnrollmentCommitError) == .undecodableSuccess || error is CancellationError
    }
    private func valid(stepUp: AccountStepUpAuthorizationV1, action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, trustCommit: AccountTrustStateCommit) -> Bool { stepUp.accountID == credentials.accountID && stepUp.actorDeviceID == credentials.deviceID && stepUp.currentCommitDigest == AccountTranscript.trustCommitDigest(trustCommit) && stepUp.action == (action == .enroll ? .enrollSyncNode : .replaceSyncNode) && stepUp.targetDeviceID == (action == .enroll ? claim.nodeDeviceID : replacedNodeID) }
    private func valid(successor: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1, priorCommit: AccountTrustStateCommit) -> Bool {
        guard successor.state.accountID == credentials.accountID,
              successor.state.epoch == priorCommit.state.epoch,
              successor.state.revision.value == priorCommit.state.revision.value + 1,
              successor.state.previousCommitDigest == AccountTranscript.trustCommitDigest(priorCommit),
              successor.state.signerDeviceID == credentials.deviceID,
              successor.state.members.first(where: { $0.deviceID == evidence.nodeDeviceID })?.platform == .syncNode,
              successor.state.members.first(where: { $0.deviceID == evidence.nodeDeviceID })?.publicBundle.signingKey == evidence.signingPublicKey,
              successor.state.members.first(where: { $0.deviceID == evidence.nodeDeviceID })?.publicBundle.agreementKey == evidence.agreementPublicKey
        else { return false }
        switch evidence.action {
        case .enroll:
            return evidence.replacedNodeID == nil && successor.state.transition.kind == .admission && successor.state.transition.targetDeviceIDs == [evidence.nodeDeviceID]
        case .replace:
            guard let replacedNodeID = evidence.replacedNodeID else { return false }
            return successor.state.transition.kind == .revocation && successor.state.transition.targetDeviceIDs == [replacedNodeID] && !successor.state.members.contains(where: { $0.deviceID == replacedNodeID })
        }
    }
    private func matchingString(for claim: AccountNodeEnrollmentPublicClaimV1) -> String { let digest = Data(SHA256.hash(data: AccountTranscript.nodeEnrollmentMatchingConfirmation(claim, accountID: credentials.accountID))); let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000; return String(format: "%06u", number) }
    private func validSetupCode(_ value: String) -> Bool { (43 ... 64).contains(value.utf8.count) && value.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 } }
}
