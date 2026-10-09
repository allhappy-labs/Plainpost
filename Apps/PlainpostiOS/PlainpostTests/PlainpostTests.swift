import Combine
import CryptoKit
import AuthenticationServices
import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostAccounts
import PlainpostSecrets
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNotificationRuntime
import PlainpostUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import PlainpostNodeTransport
import PlainpostNodeMailMode
import SQLite3
@testable import Plainpost

private final class MobileRecordingNotificationPermission: NotificationPermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    func requestAuthorization() async throws -> Bool { record(); return true }
    private func record() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
private final class MobileRegistrationBox: @unchecked Sendable {
    var registration: NotificationRegistrationModel?
}

private struct MobileFailingAPNSToken: APNSTokenProviding {
    func token() async throws -> Data { throw CancellationError() }
}

private struct MobileFailingNotificationRemote: NotificationRegistrationRemote {
    func issueChallenge() async throws -> Data { throw AccountRuntimeError.untrustedResponse }
    func registerAttestation(_ request: NotificationAttestationRegistrationRequest) async throws -> NotificationRegistrationResponse { throw AccountRuntimeError.untrustedResponse }
    func registerAssertion(_ request: NotificationAssertionRegistrationRequest) async throws -> NotificationRegistrationResponse { throw AccountRuntimeError.untrustedResponse }
    func revoke(routingHandle: Data) async throws { throw AccountRuntimeError.untrustedResponse }
}

private struct MobileSetupNoopSyncer: AccountInboxSyncOrchestrating {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult {
        IMAPSyncResult(syncedMessageCount: 0)
    }
}

private final class MobileSetupVerificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func record(_ value: String) { lock.withLock { message = value } }
    func read() -> String? { lock.withLock { message } }
}

private final class MobileSetupSMTPClient: SMTPClientProtocol, @unchecked Sendable {
    private let recorder: MobileSetupVerificationRecorder
    init(recorder: MobileSetupVerificationRecorder) { self.recorder = recorder }
    func send(username: String, password: String, from: EmailAddress, to recipients: [EmailAddress], data: String) async throws {
        recorder.record(data)
    }
}

private final class MobileSetupIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    private let recorder: MobileSetupVerificationRecorder
    init(recorder: MobileSetupVerificationRecorder) { self.recorder = recorder }
    func login(username: String, password: String) async throws {}
    func listMailboxes() async throws -> [Mailbox] {
        [Mailbox(id: MailboxID("setup-inbox"), accountID: AccountID("acc_me_example_com"), name: "INBOX", path: "INBOX", specialUse: "\\Inbox")]
    }
    func selectMailbox(_ path: String) async throws -> String { "* 1 EXISTS\n* OK [UIDVALIDITY 1] UIDs valid" }
    func allMessageUIDs() async throws -> [Int] { [7] }
    func messageUIDs(after uid: Int?) async throws -> [Int] { recorder.read() == nil ? [] : [8] }
    func fetchHeader(uid: Int) async throws -> String {
        guard let message = recorder.read() else { throw PlainpostError.validationFailed("Verification mail missing") }
        return message.components(separatedBy: "\r\n\r\n")[0]
    }
    func fetchBody(uid: Int) async throws -> String {
        guard let message = recorder.read() else { throw PlainpostError.validationFailed("Verification mail missing") }
        return message
    }
    func markRead(uid: Int) async throws {}
    func markUnread(uid: Int) async throws {}
    func archive(uid: Int, archiveMailbox: String) async throws {}
    func delete(uid: Int) async throws {}
    func appendMessage(to mailbox: String, flags: [String], data: String) async throws -> IMAPAppendResult {
        IMAPAppendResult(mailbox: mailbox, uid: nil)
    }
}

@MainActor
private final class MobileAccountFlowRecorder {
    private(set) var starts = 0
    private(set) var refreshes = 0
    private(set) var begins = 0
    private(set) var cancels = 0
    func start() { starts += 1 }
    func refresh() { refreshes += 1 }
    func begin() { begins += 1 }
    func cancel() { cancels += 1 }
}
private struct MobileAllowingAccountAuthenticator: LocalApprovalAuthenticating {
    func authenticate(reason: String) async throws {}
}

private actor MobileAccountApprovalRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor MobileSecurityActionGate {
    private var started = false
    private var release: CheckedContinuation<Void, Never>?

    func run(_ action: MobileAccountSecurityModel.Action) async throws {
        guard action == .deleteAccount else { throw CancellationError() }
        started = true
        await withCheckedContinuation { release = $0 }
    }

    /// Bounded, so a regression that never starts the action fails instead of hanging.
    func waitUntilStarted(timeout: Duration = .seconds(3)) async {
        await mobileWaitOrFail("security action never started", timeout: timeout) { started }
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

private final class MobilePurgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class MobileBootstrapProfileMemoryStore: SyncNodeBootstrapProfileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: SyncNodeBootstrapProfile?
    private var loadFails = false
    init(profile: SyncNodeBootstrapProfile? = nil) { self.profile = profile }
    /// Models a Keychain read error for `load()`.
    var failsLoad: Bool {
        get { lock.withLock { loadFails } }
        set { lock.withLock { loadFails = newValue } }
    }
    func load() throws -> SyncNodeBootstrapProfile? {
        try lock.withLock {
            if loadFails { throw AccountRuntimeError.secretUnavailable }
            return profile
        }
    }
    func importProfile(_ profile: SyncNodeBootstrapProfile) throws { lock.withLock { self.profile = profile } }
    func retire(expectedCapabilityID: Data) throws { lock.withLock { if profile?.capabilityID == expectedCapabilityID { profile = nil } } }
}

private func writeMobileServerSetup() throws -> URL {
    let document = #"{"capability":"paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU","capabilityID":"AQIDBAUGBwgJCgsMDQ4PEA","canonicalOrigin":"https://node.tail1234.ts.net:18443","centralAudience":"plainpost-central-private-beta","kind":"sync-node.bootstrap-profile.v2","nodeDeviceID":"11111111-1111-4111-8111-111111111111","signingKeyDigest":"ERERERERERERERERERERERERERERERERERERERERERE"}"# + "\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-sync-node-\(UUID().uuidString).plainpostserver")
    try Data(document.utf8).write(to: url, options: .withoutOverwriting)
    return url
}

/// Inert coordinator dependencies: the owner-gate tests never run a flow.
private struct MobileInertEnrollmentRemote: SyncNodeEnrollmentRemote {
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { throw AccountRuntimeError.secretUnavailable }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws { throw AccountRuntimeError.secretUnavailable }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.secretUnavailable }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { throw AccountRuntimeError.secretUnavailable }
}

private struct MobileInertEnrollmentDependencies: SyncNodeEnrollmentLocalAuthenticating, SyncNodeEnrollmentResponseVerifying, SyncNodeEnrollmentTrustCoordinating, SyncNodeEnrollmentActivating {
    func authenticateSyncNodeEnrollment() async throws { throw AccountRuntimeError.secretUnavailable }
    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws { throw AccountRuntimeError.untrustedResponse }
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { nil }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit { throw AccountRuntimeError.secretUnavailable }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws { throw AccountRuntimeError.secretUnavailable }
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws { throw AccountRuntimeError.secretUnavailable }
    func retryUncertainActivation() async throws { throw AccountRuntimeError.secretUnavailable }
    func cancelPendingActivation() async {}
}

@MainActor
private func makeMobileEnrollmentModel(owner: SyncNodeEnrollmentOwner, activeNodeID: AccountDeviceID? = nil, connection: SyncNodeEnrollmentViewModel.ConnectionPresentation = .ready) throws -> SyncNodeEnrollmentViewModel {
    let credentials = try AccountSessionCredentials(accountID: owner.accountID, deviceID: owner.deviceID, accessToken: "token", accessExpiresAt: Date().addingTimeInterval(60), refreshCredential: Data(repeating: 6, count: 32), offlineLease: "lease")
    let inert = MobileInertEnrollmentDependencies()
    let coordinator = SyncNodeEnrollmentCoordinator(
        remote: MobileInertEnrollmentRemote(),
        localAuthenticator: inert,
        responseVerifier: inert,
        trust: inert,
        activation: inert,
        credentials: credentials,
        credentialsProvider: { [credentials] in credentials },
        device: try AccountDeviceIdentity.generate(),
        activeNodeID: activeNodeID
    )
    return SyncNodeEnrollmentViewModel(coordinator: coordinator, owner: owner, initialConnectionPresentation: connection)
}

/// A Node that answers once `isAvailable` is set, counting session attempts
/// and account-session prepares.
@MainActor
private final class MobileRetryNodeGate {
    var isAvailable = false
    var sessionAttempts = 0
    var holdsFirstSession = false
    private(set) var prepares = 0
    private var held: CheckedContinuation<Void, Never>?
    var isHoldingFirstSession: Bool { held != nil }
    func waitForRelease() async {
        guard holdsFirstSession else { return }
        await withCheckedContinuation { held = $0 }
    }
    func release() {
        held?.resume()
        held = nil
    }
    func recordPrepare() -> AccountSessionState {
        prepares += 1
        return .active
    }
}

@MainActor
private final class MobileEnrollmentOwnerReader {
    enum Outcome { case owner(SyncNodeEnrollmentOwner), none, failure }
    var outcome: Outcome
    private(set) var reads = 0
    init(_ owner: SyncNodeEnrollmentOwner) { outcome = .owner(owner) }
    func read() throws -> SyncNodeEnrollmentOwner? {
        reads += 1
        switch outcome {
        case .owner(let owner): return owner
        case .none: return nil
        case .failure: throw AccountRuntimeError.secretUnavailable
        }
    }
}

@MainActor
private final class MobileEnrollmentModelQueue {
    private(set) var models: [SyncNodeEnrollmentViewModel]
    private(set) var calls = 0
    init(_ models: [SyncNodeEnrollmentViewModel]) { self.models = models }
    /// An unexpected extra factory call fails like the production factory.
    func next() throws -> SyncNodeEnrollmentViewModel {
        calls += 1
        guard !models.isEmpty else { throw AccountRuntimeError.secretUnavailable }
        return models.removeFirst()
    }
}

/// The first build suspends until released, so a newer build can publish
/// before the stale result arrives.
@MainActor
private final class MobileSuspendedEnrollmentFactory {
    private let models: [SyncNodeEnrollmentViewModel]
    private var release: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(_ models: [SyncNodeEnrollmentViewModel]) { self.models = models }
    func make() async throws -> SyncNodeEnrollmentViewModel {
        let index = calls
        calls += 1
        guard index < models.count else { throw AccountRuntimeError.secretUnavailable }
        if index == 0 { await withCheckedContinuation { release = $0 } }
        return models[index]
    }
    var isFirstBuildSuspended: Bool { release != nil }
    func releaseFirstBuild() {
        release?.resume()
        release = nil
    }
}

/// A provisioned Sync Node connection whose commit response is always lost,
/// so the model retains the exact admission replay. Mirrors the PlainpostUI
/// test fixture with public API only.
private struct MobileRetainedEnrollmentFixture {
    let trustCommit: AccountTrustStateCommit
    let identity: AccountDeviceIdentity
    let claim: AccountNodeEnrollmentPublicClaimV1
    let profile: SyncNodeBootstrapProfile
    let presentation: SyncNodeEnrollmentPresentation

    var owner: SyncNodeEnrollmentOwner {
        SyncNodeEnrollmentOwner(accountID: trustCommit.state.accountID, deviceID: trustCommit.state.members[0].deviceID)
    }

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Protocol/account-v1/fixtures/crypto-vectors-v1.json"))) as? [String: Any])
        let genesis = try XCTUnwrap(((vectors["bootstrapFinalize"] as? [String: Any])?["genesis"] as? [String: Any])?["message"] as? [String: Any])
        let decoded = try AccountWireCodec.decodeTrustCommit(JSONSerialization.data(withJSONObject: try XCTUnwrap(genesis["genesisCommit"])))
        identity = try AccountDeviceIdentity.generate()
        let deviceID = decoded.state.members[0].deviceID
        let member = try AccountDeviceTrustRecord(accountID: decoded.state.accountID, epoch: decoded.state.epoch, revision: decoded.state.revision, deviceID: deviceID, platform: decoded.state.members[0].platform, publicBundle: identity.publicBundle, signerDeviceID: deviceID, signature: Data(repeating: 1, count: 64))
        let state = try AccountTrustState(accountID: decoded.state.accountID, epoch: decoded.state.epoch, revision: decoded.state.revision, previousCommitDigest: decoded.state.previousCommitDigest, transition: decoded.state.transition, keyGeneration: decoded.state.keyGeneration, keyCommitment: decoded.state.keyCommitment, members: [member], signerDeviceID: deviceID, signature: Data(repeating: 1, count: 64))
        let template = try XCTUnwrap(decoded.keyPackages.first)
        let package = try AccountGroupKeyPackage(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: Data(SHA256.hash(data: AccountTranscript.signedTrustState(state))), keyCommitment: state.keyCommitment, recipientDeviceID: deviceID, senderDeviceID: deviceID, senderEphemeralPublicKey: template.senderEphemeralPublicKey, nonce: template.nonce, encryptedKeyMaterial: template.encryptedKeyMaterial, signature: Data(repeating: 1, count: 64))
        trustCommit = try AccountTrustStateCommit(state: state, keyPackages: [package])
        let signing = P256.Signing.PrivateKey().publicKey.x963Representation
        claim = try AccountNodeEnrollmentPublicClaimV1(
            claimID: NodeEnrollmentClaimID("90000000-0000-4000-8000-000000000001"),
            nodeDeviceID: AccountDeviceID("90000000-0000-4000-8000-000000000002"),
            signingPublicKey: signing,
            agreementPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation,
            noiseStaticPublicKey: Data(repeating: 9, count: 32),
            endpointDigest: Data(repeating: 4, count: 32),
            createdAt: mobileEnrollmentTimestamp(Date().addingTimeInterval(-30)),
            expiresAt: mobileEnrollmentTimestamp(Date().addingTimeInterval(240))
        )
        profile = try SyncNodeBootstrapProfile(
            canonicalOrigin: NodeEndpointURL("https://node.tail1234.ts.net:18443"),
            nodeDeviceID: claim.nodeDeviceID,
            signingKeyDigest: Data(SHA256.hash(data: claim.signingPublicKey)),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "plainpost-central-private-beta"
        )
        presentation = try SyncNodeEnrollmentPresentation(
            setupCode: NodeSessionWire.encodeBase64URL(Data(repeating: 1, count: 32)),
            expiresAt: try XCTUnwrap(AccountWireCodec.parseTimestamp(claim.expiresAt)),
            claimProofSignature: Data(repeating: 10, count: 64),
            claimFingerprint: "123456"
        )
    }

    /// Drives a model owned by `owner` to `.commitResponseUncertain`. Generic
    /// over the remote so a loss-only remote and a loss-then-install remote
    /// can share this setup.
    @MainActor
    func uncertainCommitModel<Remote: SyncNodeEnrollmentRemote>(remote: Remote, retireProfile: @escaping @MainActor (Data) throws -> Void = { _ in }) async throws -> SyncNodeEnrollmentViewModel {
        let credentials = try AccountSessionCredentials(accountID: owner.accountID, deviceID: owner.deviceID, accessToken: "token", accessExpiresAt: Date().addingTimeInterval(600), refreshCredential: Data(repeating: 6, count: 32), offlineLease: "lease")
        let dependencies = MobileRetainedEnrollmentDependencies(commit: trustCommit, origin: profile.canonicalOrigin, presentation: presentation)
        let coordinator = SyncNodeEnrollmentCoordinator(
            remote: remote,
            presenter: dependencies,
            bootstrapVerifier: dependencies,
            localAuthenticator: dependencies,
            responseVerifier: dependencies,
            trust: dependencies,
            activation: dependencies,
            credentials: credentials,
            credentialsProvider: { [credentials] in credentials },
            device: identity,
            activeNodeID: nil
        )
        let model = SyncNodeEnrollmentViewModel(coordinator: coordinator, profile: profile, owner: owner, nonceGenerator: { Data(repeating: 4, count: 32) }, retireProfile: retireProfile)
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("apple-token".utf8), for: attempt.id)
        for _ in 0 ..< 400 {
            if case .matchingStringConfirmation = model.state, model.connectionPresentation == .ready { break }
            await Task.yield()
        }
        await model.approvePinnedTarget()
        XCTAssertEqual(model.state, .commitResponseUncertain)
        XCTAssertTrue(model.retainsInstallationReplay)
        return model
    }
}

private func mobileEnrollmentTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// Every admission commit loses its response, so Central may have committed.
/// A claim cancel answers 204 (`cancelSucceeds`) or refuses.
private actor MobileCommitLossRemote: SyncNodeEnrollmentRemote {
    private let claim: AccountNodeEnrollmentPublicClaimV1
    private let identity: AccountDeviceIdentity
    private let cancelSucceeds: Bool
    private(set) var commits = 0
    private(set) var cancels = 0

    init(fixture: MobileRetainedEnrollmentFixture, cancelSucceeds: Bool) {
        claim = fixture.claim
        identity = fixture.identity
        self.cancelSucceeds = cancelSucceeds
    }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        cancels += 1
        guard cancelSucceeds else { throw AccountRuntimeError.untrustedResponse }
    }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try AccountStepUpAuthorizationV1(
            authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-000000000003"),
            accountID: credentials.accountID,
            actorDeviceID: credentials.deviceID,
            targetDeviceID: claim.nodeDeviceID,
            action: .enrollSyncNode,
            currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit),
            requestDigest: Data(repeating: 6, count: 32),
            issuedAt: mobileEnrollmentTimestamp(now.addingTimeInterval(-1)),
            expiresAt: mobileEnrollmentTimestamp(now.addingTimeInterval(240)),
            serverKeyID: "test-key",
            serverSignature: try identity.signature(for: Data("step-up".utf8))
        )
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        commits += 1
        throw AccountRuntimeError.transportFailure
    }
}

/// The first admission commit loses its response, exactly like
/// `MobileCommitLossRemote`, so the model reaches `.commitResponseUncertain`.
/// Every later commit (a Retry) succeeds and installs, so this drives an
/// install-success convergence instead of a Stop and Start Over one.
private actor MobileCommitInstallRemote: SyncNodeEnrollmentRemote {
    private let claim: AccountNodeEnrollmentPublicClaimV1
    private let identity: AccountDeviceIdentity
    private(set) var commits = 0

    init(fixture: MobileRetainedEnrollmentFixture) {
        claim = fixture.claim
        identity = fixture.identity
    }

    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {
        throw AccountRuntimeError.untrustedResponse
    }
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try AccountStepUpAuthorizationV1(
            authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-000000000003"),
            accountID: credentials.accountID,
            actorDeviceID: credentials.deviceID,
            targetDeviceID: claim.nodeDeviceID,
            action: .enrollSyncNode,
            currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit),
            requestDigest: Data(repeating: 6, count: 32),
            issuedAt: mobileEnrollmentTimestamp(now.addingTimeInterval(-1)),
            expiresAt: mobileEnrollmentTimestamp(now.addingTimeInterval(240)),
            serverKeyID: "test-key",
            serverSignature: try identity.signature(for: Data("step-up".utf8))
        )
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        commits += 1
        guard commits > 1 else { throw AccountRuntimeError.transportFailure }
        let issuedAt = mobileEnrollmentTimestamp(now)
        let expiresAt = mobileEnrollmentTimestamp(now.addingTimeInterval(3600))
        let cleanupCapability = try AccountSyncNodeCleanupCapabilityV1(
            accountID: request.evidence.accountID,
            claimID: request.evidence.claimID,
            nodeDeviceID: request.evidence.nodeDeviceID,
            targetHandle: Data(repeating: 5, count: 32),
            cleanupCredential: Data(repeating: 6, count: 32),
            deletionGeneration: try PositiveUInt64(1),
            issuedAt: issuedAt
        )
        let cleanupDigest = Data(SHA256.hash(data: try AccountWireCodec.encodeSyncNodeCleanupCapability(cleanupCapability)))
        let base = try AccountNodeOperationBindingV1(
            accountID: request.evidence.accountID,
            trustEpoch: request.evidence.trustEpoch,
            claimID: request.evidence.claimID,
            nodeDeviceID: request.evidence.nodeDeviceID,
            centralAudience: request.expectedCentralAudience ?? "plainpost-central-private-beta",
            action: request.evidence.action,
            replacedNodeID: request.evidence.replacedNodeID,
            replacementRevocationDigest: nil,
            admissionEvidenceDigest: Data(repeating: 1, count: 32),
            issuanceDigest: Data(repeating: 2, count: 32)
        )
        let binding = try AccountNodeOperationBindingV2(base: base, cleanupCapabilityDigest: cleanupDigest)
        let result = try AccountNodeEnrollmentResultV2(binding: binding, committedAt: issuedAt)
        let refreshCredential = try AccountNodeRefreshCredentialV2(binding: binding, credentialID: "90000000-0000-4000-8000-000000000005", issuedAt: issuedAt, expiresAt: expiresAt, credential: Data(repeating: 7, count: 32))
        let offlineLease = try AccountNodeOfflineLeaseV2(binding: binding, leaseID: "90000000-0000-4000-8000-000000000006", issuedAt: issuedAt, expiresAt: expiresAt, serverKeyID: "test-key", signature: try identity.signature(for: Data("offline-lease".utf8)))
        let v2 = try AccountNodeEnrollmentAdmissionResponseV2(result: result, refreshCredential: refreshCredential, offlineLease: offlineLease, cleanupCapability: cleanupCapability)
        return try SyncNodeEnrollmentAdmissionResponse(v2: v2)
    }
}

private struct MobileRetainedEnrollmentDependencies: SyncNodeEnrollmentPresenting, SyncNodeBootstrapClaimVerifying, SyncNodeEnrollmentLocalAuthenticating, SyncNodeEnrollmentResponseVerifying, SyncNodeEnrollmentTrustCoordinating, SyncNodeEnrollmentActivating {
    let commit: AccountTrustStateCommit
    let origin: NodeEndpointURL
    let presentation: SyncNodeEnrollmentPresentation

    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation { presentation }
    func verify(profile: SyncNodeBootstrapProfile, presentation: SyncNodeEnrollmentPresentation, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data) throws -> NodeEndpointURL { origin }
    func authenticateSyncNodeEnrollment() async throws {}
    func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {}
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { commit }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit {
        let prior = commit
        let revision = try PositiveUInt64(prior.state.revision.value + 1)
        let node = try AccountDeviceTrustRecord(accountID: prior.state.accountID, epoch: prior.state.epoch, revision: revision, deviceID: evidence.nodeDeviceID, platform: .syncNode, publicBundle: AccountPublicKeyBundle(signingKey: evidence.signingPublicKey, agreementKey: evidence.agreementPublicKey), signerDeviceID: prior.state.signerDeviceID, signature: Data(repeating: 1, count: 64))
        let transition = try AccountTrustTransition(kind: .admission, targetDeviceIDs: [evidence.nodeDeviceID], priorRecordDigests: [], handshakeDigest: Data(repeating: 3, count: 32), pendingDeviceDigest: Data(repeating: 4, count: 32))
        let state = try AccountTrustState(accountID: prior.state.accountID, epoch: prior.state.epoch, revision: revision, previousCommitDigest: AccountTranscript.trustCommitDigest(prior), transition: transition, keyGeneration: prior.state.keyGeneration, keyCommitment: prior.state.keyCommitment, members: (prior.state.members + [node]).sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }, signerDeviceID: prior.state.signerDeviceID, signature: Data(repeating: 1, count: 64))
        let digest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let template = try XCTUnwrap(prior.keyPackages.first)
        let packages = try state.members.map { member in
            try AccountGroupKeyPackage(accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision, keyGeneration: state.keyGeneration, stateDigest: digest, keyCommitment: state.keyCommitment, recipientDeviceID: member.deviceID, senderDeviceID: state.signerDeviceID, senderEphemeralPublicKey: template.senderEphemeralPublicKey, nonce: template.nonce, encryptedKeyMaterial: template.encryptedKeyMaterial, signature: Data(repeating: 1, count: 64))
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {}
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {}
    func retryUncertainActivation() async throws {}
    func cancelPendingActivation() async {}
}

private final class MobileSessionStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionState
    init(_ value: AccountSessionState) { self.value = value }
    var state: AccountSessionState {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class PlainpostTests: XCTestCase {
    func testGoogleSignInAcceptsDocumentedExtraCallbackParameters() throws {
        let redirect = "com.googleusercontent.apps.fixture:/oauth2redirect"
        let state = String(repeating: "s", count: 43)
        let callback = URL(string: "\(redirect)?state=\(state)&code=4%2Fcode&scope=https%3A%2F%2Fmail.google.com%2F&authuser=0&prompt=consent")!
        XCTAssertEqual(try IOSMailOAuthSession.validate(
            callback: callback, redirectURI: redirect, expectedState: state), "4/code")
        XCTAssertThrowsError(try IOSMailOAuthSession.validate(
            callback: URL(string: "\(redirect)?state=wrong&code=x&scope=y")!,
            redirectURI: redirect, expectedState: state))
    }

    func testSelectedNodeSendJournalReservesExactBytesAndRejectsForeignOperation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("local-mail"), displayName: "Mail",
                              email: EmailAddress("mail@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let direct = try AccountMailSource(accountID: account.id, kind: .direct, mode: nil,
                                           nodeID: nil, logicalMailboxID: nil,
                                           providerIdentity: nil, generation: 1)
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("local-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: direct
        )
        let plainpostID = try PlainpostAccountID("11111111-1111-4111-8111-111111111111")
        let nodeID = "a5be1f45-6473-4d29-bc58-18b63f13b1ea"
        let mailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 7, count: 32)))
        let source = try direct.nodeBacked(nodeID: nodeID,
                                       logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(mailbox),
                                       providerIdentity: account.email.rawValue)
        try store.replaceMailSource(source, expectedGeneration: 1)
        let journal = MobileNodeSendJournal(databaseURL: url, accountID: account.id,
                                             plainpostAccountID: plainpostID, source: source)
        func signedOperation(nodeID: String, idempotencyKey: String = "send-one") throws -> Data {
            let unsigned = try NodeSyncUnsignedOperation(
                accountID: plainpostID.rawValue, authorityEpoch: "1",
                clientID: "22222222-2222-4222-8222-222222222222", idempotencyKey: idempotencyKey,
                issuedAt: "2026-09-27T12:00:00Z", logicalMailboxID: mailbox,
                nodeID: nodeID, operation: .send(draftID: "draft-one", expectedRevision: "1"),
                trustEpoch: "1"
            )
            return try NodeSyncCodec.encodeOperation(NodeSyncOperation(
                unsigned: unsigned, signature: Data(repeating: 1, count: 64)))
        }
        let operation = try signedOperation(nodeID: nodeID)
        try journal.reserveSend(canonicalOperation: operation)
        XCTAssertEqual(try journal.unresolvedSendOperations(accountID: account.id), [operation])
        XCTAssertThrowsError(try journal.reserveSend(canonicalOperation: signedOperation(
            nodeID: "33333333-3333-4333-8333-333333333333")))
        XCTAssertThrowsError(try journal.unresolvedSendOperations(accountID: AccountID("foreign")))
        try journal.settleSend(canonicalOperation: operation, state: .applied)
        XCTAssertTrue(try journal.unresolvedSendOperations(accountID: account.id).isEmpty)
        let conflict = try signedOperation(nodeID: nodeID, idempotencyKey: "send-conflict")
        try journal.reserveSend(canonicalOperation: conflict)
        try journal.settleSend(canonicalOperation: conflict, state: .conflicted)
        XCTAssertTrue(try journal.unresolvedSendOperations(accountID: account.id).isEmpty,
                      "An authenticated terminal conflict must not wedge later account work")
        XCTAssertThrowsError(try journal.reserveSend(canonicalOperation: conflict),
                             "A terminal conflict must not be submitted again with the same key")
        try journal.requireCurrentSource()
        _ = try store.replaceMailSource(source.withMode(.fallback), expectedGeneration: source.generation)
        XCTAssertThrowsError(try journal.requireCurrentSource(),
                             "A previously opened authority must reject a later source CAS")
    }

    func testDirectSyncPendingNoticeDoesNotClaimServerFailure() {
        XCTAssertNil(MobileDirectSyncRetryPolicy.message(isPending: true, elapsed: .seconds(11)))
        XCTAssertEqual(
            MobileDirectSyncRetryPolicy.message(isPending: true, elapsed: .seconds(12)),
            "Mail sync is still in progress."
        )
        XCTAssertNil(MobileDirectSyncRetryPolicy.message(isPending: false, elapsed: .seconds(90)))
    }

    func testProductionSetupTransitionsCleanLaunchToDirectComposerAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults.standard.removeObject(forKey: "plainpost.ios.selected-provider-account") }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        let credentials = InMemoryCredentialVault()
        let recorder = MobileSetupVerificationRecorder()
        let imap = MobileSetupIMAPClient(recorder: recorder)
        let smtp = MobileSetupSMTPClient(recorder: recorder)
        let handler = AccountSetupService(
            store: store,
            credentials: credentials,
            inboxSyncOrchestrator: MobileSetupNoopSyncer(),
            imapClientFactory: { _, _ in imap },
            smtpClientFactory: { _, _ in smtp },
            publishDirectMailSource: true
        )
        let result = try await handler.addAccount(
            AccountSetupRequest(
                displayName: "Personal", email: EmailAddress("me@example.com"),
                imapHost: "imap.example.test", imapPort: 993,
                smtpHost: "smtp.example.test", smtpPort: 587,
                imapPassword: "imap-secret", smtpPassword: "smtp-secret"
            ), progress: { _ in }
        )
        try store.requireDirectMailSource(accountID: result.account.id)

        let launch = MobileLocalMailLaunchModel(databaseURL: url, credentials: credentials)
        try launch.selectAccountID(result.account.id)
        let reopened = MobileLocalMailLaunchModel(databaseURL: url, credentials: credentials)
        XCTAssertEqual(try reopened.selectedAccountID(), result.account.id)
        guard case .allDirect = try reopened.route(for: result.account.id) else {
            return XCTFail("Published account must relaunch as Direct")
        }
        let runtime = try reopened.makeLocalRuntime()
        let composer = runtime.makeComposerViewModel()
        composer.to = "friend@example.test"
        composer.subject = "Ready"
        composer.bodyMarkdown = "Hello"
        try await composer.saveDraft()
        XCTAssertNotNil(composer.lastDraftID)
        await runtime.shutdown()
    }

    func testLocalSetupRouteWaitsForUnsavedComposerBeforeOpeningDirectAccount() async throws {
        let controller = Self.fakeRuntimeController()
        await controller.prepare(readOnly: false, route: .localSetup)
        let setupRuntime = try XCTUnwrap(controller.runtime)
        setupRuntime.composerActivity.update(hasUnsavedOpenComposer: true)
        XCTAssertTrue(controller.hasUnsavedComposer)

        let transition = Task {
            await controller.prepare(readOnly: false, route: .allDirect)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.runtime === setupRuntime, "Unsaved setup composer must remain mounted")
        setupRuntime.composerActivity.update(hasUnsavedOpenComposer: false)
        await transition.value
        XCTAssertFalse(controller.runtime === setupRuntime)
    }
    func testLocalLaunchRoutesCleanInstallToSetupWithoutCentral() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MobileLocalMailLaunchModel(databaseURL: IOSLocalDatabaseProtection.databaseURL(in: directory))
        guard case .localSetup = try model.route(for: nil) else { return XCTFail("Clean install must open local setup") }
        let runtime = try model.makeLocalRuntime()
        XCTAssertNotNil(runtime)
        await runtime.shutdown()
    }

    /// Every Direct account opens in one device-wide runtime.
    func testLocalLaunchOpensEveryDirectAccountInOneRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = ["direct-one", "direct-two"].map {
            Account(id: AccountID($0), displayName: $0, email: EmailAddress("\($0)@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        }
        for account in accounts {
            let inbox = Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox")
            let source = try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
            try store.cacheAccountSetup(account: account, inbox: inbox, source: source)
        }
        let model = MobileLocalMailLaunchModel(databaseURL: url)
        for account in accounts {
            guard case .allDirect = try model.route(for: account.id) else { return XCTFail("Expected the all-Direct route") }
        }
        let runtime = try model.makeLocalRuntime()
        XCTAssertNil(runtime.configuration.selectedAccountID)
        XCTAssertEqual(Set(runtime.makeAccountSetupViewModel().accounts.map(\.id)), Set(accounts.map(\.id)))
        try IOSLocalDatabaseProtection.verify(url: url)
        await runtime.shutdown()
        XCTAssertThrowsError(try model.route(for: AccountID("missing")))
    }

    func testLocalAccountChoicesLabelSourcesAndPersistDirectAndNodeSelection() throws {
        let selectionKey = "plainpost.ios.selected-provider-account"
        let previousSelection = UserDefaults.standard.string(forKey: selectionKey)
        UserDefaults.standard.removeObject(forKey: selectionKey)
        defer {
            if let previousSelection { UserDefaults.standard.set(previousSelection, forKey: selectionKey) }
            else { UserDefaults.standard.removeObject(forKey: selectionKey) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let first = Account(id: AccountID("a-direct"), displayName: "Personal", email: EmailAddress("a@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let second = Account(id: AccountID("b-direct"), displayName: "Work", email: EmailAddress("b@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let node = Account(id: AccountID("c-node"), displayName: "Archive", email: EmailAddress("c@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        for account in [first, second, node] {
            try store.cacheAccountSetup(
                account: account,
                inbox: Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
                source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
            )
        }
        let nodeSource = try AccountMailSource(accountID: node.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
            .nodeBacked(nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea", logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: "c@example.test")
        try store.replaceMailSource(nodeSource, expectedGeneration: 1)

        let model = MobileLocalMailLaunchModel(databaseURL: url)
        let choices = try model.accountChoices()
        XCTAssertEqual(choices.map(\.title), [
            "Personal (a@example.test) · Direct",
            "Work (b@example.test) · Direct",
            "Archive (c@example.test) · Sync Node"
        ])
        XCTAssertEqual(choices.map(\.id), [first.id, second.id, node.id])
        XCTAssertEqual(try model.selectedAccountID(), first.id)
        try model.selectAccountID(second.id)
        XCTAssertEqual(try model.selectedAccountID(), second.id)
        try model.selectAccountID(first.id)
        XCTAssertEqual(try model.selectedAccountID(), first.id)
        try model.selectAccountID(node.id)
        XCTAssertEqual(try model.selectedAccountID(), node.id)
        guard case .nodeUnavailable(node.id) = try model.route(for: node.id) else {
            return XCTFail("Cataloged Node account without matching authority must remain selectable but unavailable")
        }
        try model.selectAccountID(second.id)
        guard case .allDirect = try model.route(for: try model.selectedAccountID()) else {
            return XCTFail("Selecting a Direct account should restore the all-Direct route")
        }
    }

    func testLocalAccountSwitchIsBlockedWhileDraftOrSendIsActive() {
        XCTAssertFalse(MobileLocalAccountSwitchPolicy.isBlocked(
            hasUnsavedComposer: false, isSendPending: false
        ))
        XCTAssertTrue(MobileLocalAccountSwitchPolicy.isBlocked(
            hasUnsavedComposer: true, isSendPending: false
        ))
        XCTAssertTrue(MobileLocalAccountSwitchPolicy.isBlocked(
            hasUnsavedComposer: false, isSendPending: true
        ))
    }

    func testSelectedDirectAttachChangesOnlySelectedSourceAndRejectsStaleProposal() async throws {
        let selectionKey = "plainpost.ios.selected-provider-account"
        let previousSelection = UserDefaults.standard.string(forKey: selectionKey)
        defer {
            if let previousSelection { UserDefaults.standard.set(previousSelection, forKey: selectionKey) }
            else { UserDefaults.standard.removeObject(forKey: selectionKey) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let selected = Account(id: AccountID("attach-a"), displayName: "A", email: EmailAddress("ada@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let other = Account(id: AccountID("attach-b"), displayName: "B", email: EmailAddress("grace@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        for account in [selected, other] {
            try store.cacheAccountSetup(
                account: account,
                inbox: Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
                source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
            )
        }
        let client = NodeSyncClient(sender: MobileTwoAccountNodeSender())
        let catalog = try await NodeMailAccountCatalog.load(client)
        let nodeAccount = try XCTUnwrap(catalog.accounts.first { $0.providerIdentity == selected.email.rawValue })
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: selected.id, mailAccount: nodeAccount,
            multiAccount: true, access: .authorized
        )
        let source = try store.mailSource(accountID: selected.id)
        let proposal = source.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(nodeAccount.logicalMailboxID),
            providerIdentity: nodeAccount.providerIdentity
        )
        let launch = MobileLocalMailLaunchModel(databaseURL: url, nodeAuthority: { accountID in
            accountID == selected.id ? authority : nil
        })
        try launch.selectAccountID(other.id)
        XCTAssertThrowsError(try launch.attachSelectedNode(proposal, expectedGeneration: source.generation, authority: authority))
        XCTAssertEqual(try store.mailSource(accountID: selected.id), source)
        try launch.selectAccountID(selected.id)
        let runtime = try XCTUnwrap(launch.attachSelectedNode(proposal, expectedGeneration: source.generation, authority: authority))
        XCTAssertEqual(runtime.configuration.databaseURL, url)
        XCTAssertEqual(runtime.configuration.selectedAccountID, selected.id)
        XCTAssertEqual(try store.mailSource(accountID: selected.id), proposal)
        XCTAssertEqual(try store.mailSource(accountID: other.id).kind, .direct)
        guard case .allDirect = try launch.route(for: other.id) else { return XCTFail("Other Direct source changed") }
        let otherRuntime = try launch.makeLocalRuntime()
        XCTAssertEqual(Set(otherRuntime.makeAccountSetupViewModel().accounts.map(\.id)), [selected.id, other.id],
                       "the attached account stays in the one runtime, now mirrored from the Node")
        let disconnected = MobileLocalMailLaunchModel(databaseURL: url)
        guard case .nodeUnavailable(selected.id) = try disconnected.route(for: selected.id) else {
            return XCTFail("Node loss must not restore Direct provider I/O")
        }
        XCTAssertThrowsError(try launch.attachSelectedNode(proposal, expectedGeneration: source.generation, authority: authority))
        await otherRuntime.shutdown()
        await runtime.shutdown()
    }

    /// With the device's Node session, Use Sync Node switches the account and the shared
    /// runtime mirrors it: the attach succeeds without a runtime of its own (it used to throw
    /// after the switch had committed).
    func testAttachWithANodeSessionSucceedsIntoTheSharedRuntime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach-shared-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("attach-shared"), displayName: "A", email: EmailAddress("ada@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("attach-shared-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
        )
        let client = NodeSyncClient(sender: MobileTwoAccountNodeSender())
        let catalog = try await NodeMailAccountCatalog.load(client)
        let nodeAccount = try XCTUnwrap(catalog.accounts.first { $0.providerIdentity == account.email.rawValue })
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: account.id, mailAccount: nodeAccount, multiAccount: true, access: .authorized
        )
        let source = try store.mailSource(accountID: account.id)
        let proposal = source.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(nodeAccount.logicalMailboxID),
            providerIdentity: nodeAccount.providerIdentity
        )
        let launch = MobileLocalMailLaunchModel(databaseURL: url, nodeAuthority: { $0 == account.id ? authority : nil })
        launch.nodeBroker = NodeSessionBroker(
            resolveSender: { throw NodeSessionBrokerError.unavailable },
            check: { throw NodeSessionBrokerError.notAdmitted }
        )
        try launch.selectAccountID(account.id)
        let runtime = try launch.attachSelectedNode(proposal, expectedGeneration: source.generation, authority: authority)
        XCTAssertNil(runtime)
        XCTAssertEqual(try store.mailSource(accountID: account.id), proposal)
        guard case .allDirect = try launch.route(for: account.id) else { return XCTFail("the shared runtime serves it") }
    }

    func testExplicitAttachPreservesDirectWhenBrokerIsNotAdmitted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(id: AccountID("attach-denied"), displayName: "Direct",
                              email: EmailAddress("direct@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let source = try AccountMailSource(accountID: account.id, kind: .direct, mode: nil,
                                           nodeID: nil, logicalMailboxID: nil,
                                           providerIdentity: nil, generation: 1)
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("attach-denied-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: source
        )
        let launch = MobileLocalMailLaunchModel(databaseURL: url)
        try launch.selectAccountID(account.id)
        let broker = NodeSessionBroker(
            resolveSender: { throw NodeSessionBrokerError.unavailable },
            check: { throw NodeSessionBrokerError.notAdmitted }
        )
        let secrets = InMemoryAccountSecretStore()
        let manifest = try SessionKeyManifestStore(
            bundledDocument: SessionKeyManifestStore.bundledManifest,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
            secretStore: secrets
        ).verifier()
        do {
            _ = try await launch.attachSelectedDirectAccount(
                broker: broker,
                accountCredentials: AccountCredentialStore(secretStore: secrets),
                endpointStore: try SyncNodeEndpointStore(secretStore: secrets),
                manifest: manifest
            )
            XCTFail("Attach must require broker admission")
        } catch let error as NodeSessionBrokerError {
            XCTAssertEqual(error, .notAdmitted)
        }
        XCTAssertEqual(try store.mailSource(accountID: account.id), source)
        guard case .allDirect = try launch.route(for: account.id) else {
            return XCTFail("Failed verification must leave Direct usable")
        }
    }

    func testMixedSourceCatalogKeepsSelectedDirectRuntimeInEitherInsertionOrder() async throws {
        for nodeFirst in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
            try IOSLocalDatabaseProtection.prepare(url: url)
            let store = try SQLiteMailStore(path: url.path)
            try store.migrate()
            let direct = Account(id: AccountID("direct"), displayName: "Direct", email: EmailAddress("direct@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
            let node = Account(id: AccountID("node"), displayName: "Node", email: EmailAddress("node@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
            for account in (nodeFirst ? [node, direct] : [direct, node]) {
                try store.cacheAccountSetup(
                    account: account,
                    inbox: Mailbox(id: MailboxID("\(account.id.rawValue)-inbox"), accountID: account.id, name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
                    source: try AccountMailSource(accountID: account.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
                )
            }
            let nodeSource = try AccountMailSource(accountID: node.id, kind: .direct, mode: nil, nodeID: nil, logicalMailboxID: nil, providerIdentity: nil, generation: 1)
                .nodeBacked(nodeID: "a5be1f45-6473-4d29-bc58-18b63f13b1ea", logicalMailboxID: String(repeating: "A", count: 43), providerIdentity: "node@example.test")
            try store.replaceMailSource(nodeSource, expectedGeneration: 1)
            let model = MobileLocalMailLaunchModel(databaseURL: url)
            guard case .allDirect = try model.route(for: direct.id) else { return XCTFail("Direct source lost") }
            guard case .nodeUnavailable(node.id) = try model.route(for: node.id) else { return XCTFail("Node must fail closed") }
            let runtime = try model.makeLocalRuntime()
            XCTAssertEqual(Set(runtime.makeAccountSetupViewModel().accounts.map(\.id)), [direct.id, node.id],
                           "the Node account's mirrored mail is in the one runtime")
            await runtime.shutdown()
        }
    }

    func testSelectedNodeRouteOpensProtectedLocalCatalogWithMatchingAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = IOSLocalDatabaseProtection.databaseURL(in: directory)
        try IOSLocalDatabaseProtection.prepare(url: url)
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let account = Account(
            id: AccountID("selected-node"), displayName: "Node",
            email: EmailAddress("ada@example.test"),
            imapHost: "imap.example.test", smtpHost: "smtp.example.test"
        )
        try store.cacheAccountSetup(
            account: account,
            inbox: Mailbox(id: MailboxID("node-inbox"), accountID: account.id,
                           name: "Inbox", path: "INBOX", specialUse: "\\Inbox"),
            source: try AccountMailSource(
                accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
                logicalMailboxID: nil, providerIdentity: nil, generation: 1
            )
        )
        let client = NodeSyncClient(sender: MobileTwoAccountNodeSender())
        let catalog = try await NodeMailAccountCatalog.load(client)
        let mailAccount = try XCTUnwrap(catalog.accounts.first)
        let source = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(source.nodeBacked(
            nodeID: "00112233-4455-6677-8899-aabbccddeeff",
            logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(mailAccount.logicalMailboxID),
            providerIdentity: mailAccount.providerIdentity
        ), expectedGeneration: source.generation)
        let authority = try PlainpostNodeMailAuthorityFactory.make(
            client: client, accountID: account.id, mailAccount: mailAccount,
            multiAccount: true, access: .authorized
        )
        let launch = MobileLocalMailLaunchModel(
            databaseURL: url, nodeAuthority: { selected in
                selected == account.id ? authority : nil
            }
        )
        try launch.selectAccountID(account.id)
        XCTAssertEqual(try launch.selectedAccountID(), account.id)
        guard case .node = try launch.route(for: account.id) else {
            return XCTFail("Selected matching account should use its Node authority")
        }
        let runtime = try launch.makeNodeRuntime(
            for: account.id, authority: authority, readOnly: false
        )
        XCTAssertEqual(runtime.configuration.databaseURL, url)
        XCTAssertEqual(runtime.configuration.selectedAccountID, account.id)
        try IOSLocalDatabaseProtection.verify(url: url)
        await runtime.shutdown()

        let replacementMailboxID = try NodeSyncCodec.encodeLogicalMailboxID(
            MobileTwoAccountNodeSender.graceLogicalMailboxID
        )
        var swappedSource = false
        let swappingLaunch = MobileLocalMailLaunchModel(
            databaseURL: url, nodeAuthority: { selected in
                guard selected == account.id else { return nil }
                if !swappedSource {
                    swappedSource = true
                    let current = try? store.mailSource(accountID: account.id)
                    if let current {
                        let replacement = current.nodeBacked(
                            nodeID: "11112222-3333-4444-5555-666677778888",
                            logicalMailboxID: replacementMailboxID,
                            providerIdentity: "grace@example.test"
                        )
                        _ = try? store.replaceMailSource(
                            replacement, expectedGeneration: current.generation
                        )
                    }
                }
                return authority
            }
        )
        XCTAssertThrowsError(try swappingLaunch.makeNodeRuntime(
            for: account.id, authority: authority, readOnly: false
        ), "A Node source CAS during authority resolution must not open the new source with the old authority")
        XCTAssertTrue(swappedSource)

        let stale = try store.mailSource(accountID: account.id)
        _ = try store.replaceMailSource(stale.withMode(.fallback), expectedGeneration: stale.generation)
        guard case .nodeUnavailable(account.id) = try launch.route(for: account.id) else {
            return XCTFail("iOS fallback requires a checked provider transition before mail can open")
        }
        XCTAssertThrowsError(try launch.makeNodeRuntime(
            for: account.id, authority: authority, readOnly: false
        ))
    }

    func testUnregisteredCentralNodeKeepsLegacyRuntimeUntilCatalogMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localURL = IOSLocalDatabaseProtection.databaseURL(in: directory)
        let accountID = AccountID("unregistered-node")
        let authority = PlainpostNodeMailAuthority(
            client: NodeSyncClient(sender: MobileNoopNodeSender()), accountID: accountID
        )
        let launch = MobileLocalMailLaunchModel(databaseURL: localURL)
        let runtime = try launch.makeNodeRuntime(
            for: accountID, authority: authority, readOnly: false
        )
        XCTAssertEqual(runtime.configuration.databaseURL, PlainpostAppRuntimeConfiguration.defaultDatabaseURL())
        XCTAssertNil(runtime.configuration.selectedAccountID)
        XCTAssertTrue(runtime.mailAuthority as AnyObject === authority)
        await runtime.shutdown()
    }

    /// Every Direct account shares one runtime: preparing the route again keeps it.
    func testAllDirectRouteKeepsOneRuntimeAndNodeLossClosesIt() async throws {
        let controller = Self.fakeRuntimeController()
        await controller.prepare(readOnly: false, route: .allDirect)
        let first = try XCTUnwrap(controller.runtime)
        let firstGeneration = controller.runtimeGeneration
        await controller.prepare(readOnly: false, route: .allDirect)
        XCTAssertTrue(controller.runtime === first)
        XCTAssertEqual(controller.runtimeGeneration, firstGeneration)

        await controller.prepare(readOnly: false, route: .nodeUnavailable(AccountID("node")))
        XCTAssertNil(controller.runtime)
        XCTAssertNotNil(controller.failure)
    }
    func testLocalDatabaseFileProtection() throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let directory = applicationSupport
            .appendingPathComponent("Plainpost-iOS-protection-\(UUID().uuidString)", isDirectory: true)
        let database = IOSLocalDatabaseProtection.databaseURL(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        try IOSLocalDatabaseProtection.prepare(url: database)
        var first: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &first), SQLITE_OK)
        defer { sqlite3_close(first) }
        XCTAssertEqual(sqlite3_exec(first, "PRAGMA journal_mode=WAL; CREATE TABLE mail (id INTEGER); INSERT INTO mail VALUES (1);", nil, nil, nil), SQLITE_OK)

        try IOSLocalDatabaseProtection.prepare(url: database)
        var reopened: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &reopened), SQLITE_OK)
        defer { sqlite3_close(reopened) }
        try IOSLocalDatabaseProtection.verify(url: database)

        for url in [directory, database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Expected \(url.lastPathComponent)")
            let protection = try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }

    func testServerSetupTypeIsExportedForTheFileImporter() throws {
        let declarations = try XCTUnwrap(Bundle(for: MobileAccountModel.self).object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == "com.marynavdovenko.plainpost.server-setup" })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.json"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["plainpostserver"])
        XCTAssertEqual(UTType.plainpostServerSetup.preferredFilenameExtension, "plainpostserver")
    }

    // The profile is a bearer capability. It must live in the app's own
    // application-identifier Keychain group, not in the notifications group
    // that the Notification Service extension shares.
    func testServerSetupProfileStoreUsesTheAppOwnKeychainGroup() throws {
        let bundle = Bundle(for: MobileAccountModel.self)
        let bundleIdentifier = try XCTUnwrap(bundle.bundleIdentifier)
        let store = MobileAccountModel.makeSyncNodeBootstrapProfileStore()
        XCTAssertEqual(store.accessGroup, PlainpostIOSAppKeychain.accessGroup)
        XCTAssertEqual(PlainpostIOSAppKeychain.accessGroup, "9XN7WN8JN2.\(bundleIdentifier)")
        XCTAssertFalse(try XCTUnwrap(store.accessGroup).hasSuffix("com.marynavdovenko.Plainpost.notifications"))
        XCTAssertNotEqual(store.accessGroup, bundle.object(forInfoDictionaryKey: "PLAINPOST_NOTIFICATION_KEYCHAIN_GROUP") as? String)
    }

    func testImportedServerSetupRebuildsSyncNodeEnrollmentModel() async throws {
        let factoryCalls = MobileAccountApprovalRecorder()
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore())
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: {
                await factoryCalls.record()
                // What production throws with no Node and no Server Setup.
                throw SyncNodeEnrollmentAssembly.LoadError.noSyncNode
            },
            syncNodeBootstrapImportModel: importModel
        )

        model.prepareSyncNodeEnrollment()
        try await waitForMobileCount(factoryCalls, equalTo: 1)
        try await waitForMobile { model.syncNodeEnrollmentLoadPresentation == .noSyncNode }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }

        model.handleSyncNodeBootstrapFileImporter(.success([url]))

        try await waitForMobileCount(factoryCalls, equalTo: 2)
        XCTAssertEqual(importModel.presentation, .imported(origin: "https://node.tail1234.ts.net:18443", nodeFingerprint: "11:11:11:11:11:11"))
        XCTAssertTrue(model.syncNodeBootstrapImportModel === importModel)
    }

    func testFailedServerSetupImportDoesNotRebuildEnrollment() async throws {
        let factoryCalls = MobileAccountApprovalRecorder()
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore())
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { await factoryCalls.record(); throw SyncNodeEnrollmentAssembly.LoadError.noSyncNode }, syncNodeBootstrapImportModel: importModel)
        model.prepareSyncNodeEnrollment()
        try await waitForMobileCount(factoryCalls, equalTo: 1)

        model.handleSyncNodeBootstrapFileImporter(.failure(CocoaError(.fileReadNoPermission)))
        try await Task.sleep(for: .milliseconds(100))

        let count = await factoryCalls.count
        XCTAssertEqual(count, 1)
    }

    // A retained Sync Node connection renders only while its owner's session
    // is the active one, matching macOS. The owner is read when the
    // presentation or the model changes, never while a view renders.
    func testRetainedSyncNodeConnectionIsPresentableOnlyForItsOwnersActiveSession() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let owner = fixture.owner
        let enrollment = try await fixture.uncertainCommitModel(remote: MobileCommitLossRemote(fixture: fixture, cancelSucceeds: false))
        let reader = MobileEnrollmentOwnerReader(owner)
        let session = MobileSessionStateBox(.active)
        let model = MobileAccountModel(
            prepareSession: { _ in session.state },
            syncNodeEnrollmentFactory: { enrollment },
            syncNodeEnrollmentOwnerReader: { try reader.read() }
        )
        func renderReads() -> Int {
            let before = reader.reads
            for _ in 0 ..< 20 {
                _ = model.presentableSyncNodeEnrollmentModel
                _ = model.syncNodeEnrollmentAwaitsOwner
            }
            return reader.reads - before
        }

        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.syncNodeEnrollmentModel === enrollment }
        XCTAssertTrue(model.presentableSyncNodeEnrollmentModel === enrollment)
        XCTAssertFalse(model.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(renderReads(), 0)

        // Signed out: the model stays in memory but nothing renders.
        reader.outcome = .none
        session.state = .signInRequired
        model.prepare()
        try await waitForMobile { model.presentation == .signInRequired }
        XCTAssertTrue(model.syncNodeEnrollmentModel === enrollment)
        XCTAssertNil(model.presentableSyncNodeEnrollmentModel)
        XCTAssertTrue(model.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(AccountSessionViewModel.syncNodeEnrollmentOwnerRequiredMessage, "Finish this Sync Node connection when the account that started it is signed in and active.")

        // The owner is signed in but not active.
        reader.outcome = .owner(owner)
        session.state = .suspended
        model.prepare()
        try await waitForMobile { model.presentation == .suspended }
        XCTAssertNil(model.presentableSyncNodeEnrollmentModel)
        XCTAssertTrue(model.syncNodeEnrollmentAwaitsOwner)

        // An active session whose owner can't be read hides it, and opening
        // Account Security keeps it: an unreadable owner proves nothing.
        reader.outcome = .failure
        session.state = .active
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        XCTAssertNil(model.presentableSyncNodeEnrollmentModel)
        model.prepareSyncNodeEnrollment()
        XCTAssertTrue(model.syncNodeEnrollmentModel === enrollment)
        XCTAssertEqual(renderReads(), 0)

        // The owner's session is active again.
        reader.outcome = .owner(owner)
        model.prepare()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === enrollment }
        XCTAssertFalse(model.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(renderReads(), 0)
        XCTAssertEqual(enrollment.state, .commitResponseUncertain)
        XCTAssertTrue(enrollment.retainsInstallationReplay)
    }

    // Another account's connection can never finish on this session, so
    // opening Account Security replaces it with the current owner's.
    func testAnotherOwnersSyncNodeConnectionIsReplacedWhenSecurityOpens() async throws {
        let first = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let second = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("cccccccc-3333-4333-8333-333333333333"), deviceID: try AccountDeviceID("dddddddd-4444-4444-8444-444444444444"))
        let firstModel = try makeMobileEnrollmentModel(owner: first)
        let secondModel = try makeMobileEnrollmentModel(owner: second)
        let built = MobileEnrollmentModelQueue([firstModel, secondModel])
        let reader = MobileEnrollmentOwnerReader(first)
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            syncNodeEnrollmentFactory: { try built.next() },
            syncNodeEnrollmentOwnerReader: { try reader.read() }
        )
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === firstModel }

        reader.outcome = .owner(second)
        model.prepare()
        try await waitForMobile { model.syncNodeEnrollmentAwaitsOwner }
        XCTAssertTrue(model.syncNodeEnrollmentModel === firstModel)

        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === secondModel }
        XCTAssertTrue(built.models.isEmpty)
    }

    // Opening Account Security while a connection belongs to nobody that
    // can be read keeps it: a signed-out session proves nothing.
    func testAccountSecurityOpenKeepsTheModelWhenTheOwnerReadsNil() async throws {
        let owner = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let enrollment = try makeMobileEnrollmentModel(owner: owner)
        let built = MobileEnrollmentModelQueue([enrollment])
        let reader = MobileEnrollmentOwnerReader(owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === enrollment }

        reader.outcome = .none
        model.prepareSyncNodeEnrollment()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(model.syncNodeEnrollmentModel === enrollment)
        XCTAssertTrue(model.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(built.calls, 1)
    }

    // A one-off Keychain error while reading the owner hides the owner's own
    // connection. Opening Account Security reads the owner again, so it shows
    // without waiting for the next session change.
    func testOpeningAccountSecurityRereadsTheOwnerAfterATransientReadError() async throws {
        let owner = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let enrollment = try makeMobileEnrollmentModel(owner: owner)
        let built = MobileEnrollmentModelQueue([enrollment])
        let reader = MobileEnrollmentOwnerReader(owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === enrollment }

        reader.outcome = .failure
        let readsBefore = reader.reads
        model.prepare()
        try await waitForMobile { reader.reads > readsBefore && model.presentableSyncNodeEnrollmentModel == nil }
        reader.outcome = .owner(owner)
        XCTAssertNil(model.presentableSyncNodeEnrollmentModel, "the cached verdict is still the failed read")

        model.prepareSyncNodeEnrollment()

        XCTAssertTrue(model.presentableSyncNodeEnrollmentModel === enrollment)
        XCTAssertFalse(model.syncNodeEnrollmentAwaitsOwner)
        XCTAssertEqual(built.calls, 1)
    }

    // The session can change while the factory builds a model. A model built
    // for a positively different owner is never published; a nil or unreadable
    // owner proves nothing, so the model is published but not presentable.
    func testEnrollmentModelForAnotherOwnerIsNeverPublished() async throws {
        let first = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let second = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("cccccccc-3333-4333-8333-333333333333"), deviceID: try AccountDeviceID("dddddddd-4444-4444-8444-444444444444"))
        let outcomes: [(MobileEnrollmentOwnerReader.Outcome, Bool)] = [(.owner(second), false), (.none, true), (.failure, true), (.owner(first), true)]
        for (outcome, published) in outcomes {
            let enrollment = try makeMobileEnrollmentModel(owner: first)
            let built = MobileEnrollmentModelQueue([enrollment])
            let reader = MobileEnrollmentOwnerReader(first)
            let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeEnrollmentOwnerReader: { try reader.read() })
            model.prepare()
            try await waitForMobile { model.presentation == .active }
            reader.outcome = outcome

            model.prepareSyncNodeEnrollment()
            try await waitForMobile { built.calls == 1 }
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(model.syncNodeEnrollmentModel === enrollment, published, "\(outcome)")
            if !published { XCTAssertNil(model.syncNodeEnrollmentModel) }
        }
    }

    // While the model holds the only exact replay of a possibly committed
    // admission, a new Server Setup never replaces it: the same model stays
    // and the factory is not called.
    func testServerSetupImportDuringRetainedReplayKeepsTheSameModel() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitLossRemote(fixture: fixture, cancelSucceeds: false)
        let retained = try await fixture.uncertainCommitModel(remote: remote)
        let built = MobileEnrollmentModelQueue([retained, try makeMobileEnrollmentModel(owner: fixture.owner)])
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore(profile: fixture.profile))
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }

        model.handleSyncNodeBootstrapFileImporter(.success([url]))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(importModel.presentation, .imported(origin: "https://node.tail1234.ts.net:18443", nodeFingerprint: "11:11:11:11:11:11"))
        XCTAssertTrue(model.syncNodeEnrollmentModel === retained)
        XCTAssertEqual(built.calls, 1)
        XCTAssertEqual(retained.state, .commitResponseUncertain)
        XCTAssertTrue(retained.retainsInstallationReplay)
        XCTAssertTrue(retained.canRetryCommit)
        let cancels = await remote.cancels
        XCTAssertEqual(cancels, 0)
    }

    // A build that started before a newer import can finish after the build
    // for that import. Its result is discarded, never published.
    func testStaleEnrollmentFactoryResultAfterANewerImportIsDiscarded() async throws {
        let owner = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let stale = try makeMobileEnrollmentModel(owner: owner)
        let current = try makeMobileEnrollmentModel(owner: owner)
        let factory = MobileSuspendedEnrollmentFactory([stale, current])
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore())
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try await factory.make() }, syncNodeBootstrapImportModel: importModel)
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { factory.isFirstBuildSuspended }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }

        model.handleSyncNodeBootstrapFileImporter(.success([url]))
        try await waitForMobile { model.syncNodeEnrollmentModel === current }
        factory.releaseFirstBuild()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(model.syncNodeEnrollmentModel === current)
        XCTAssertEqual(factory.calls, 2)
    }

    // A Server Setup imported while a replay was retained is applied once the
    // model converges; a proven Stop and Start Over (claim cancel 204) is one
    // such convergence.
    func testServerSetupImportedDuringRetainedReplayIsAppliedAfterProvenStopAndStartOver() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitLossRemote(fixture: fixture, cancelSucceeds: true)
        let retained = try await fixture.uncertainCommitModel(remote: remote)
        let rebuilt = try makeMobileEnrollmentModel(owner: fixture.owner)
        let built = MobileEnrollmentModelQueue([retained, rebuilt])
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore(profile: fixture.profile))
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }
        model.handleSyncNodeBootstrapFileImporter(.success([url]))
        XCTAssertTrue(model.syncNodeEnrollmentModel === retained)

        await retained.stopAndStartOver()

        XCTAssertEqual(retained.state, .enterCode)
        let cancels = await remote.cancels
        XCTAssertEqual(cancels, 1)
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === rebuilt }
        XCTAssertEqual(built.calls, 2)
    }

    // The convergence rebuild can miss, for example on a Keychain read error.
    // Opening Account Security then applies the newer Server Setup.
    func testServerSetupImportedDuringRetainedReplayIsAppliedWhenSecurityOpensAfterConvergence() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitLossRemote(fixture: fixture, cancelSucceeds: true)
        let retained = try await fixture.uncertainCommitModel(remote: remote)
        let rebuilt = try makeMobileEnrollmentModel(owner: fixture.owner)
        let built = MobileEnrollmentModelQueue([retained, rebuilt])
        let store = MobileBootstrapProfileMemoryStore(profile: fixture.profile)
        let importModel = SyncNodeBootstrapImportViewModel(store: store)
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }
        model.handleSyncNodeBootstrapFileImporter(.success([url]))

        store.failsLoad = true
        await retained.stopAndStartOver()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.syncNodeEnrollmentModel === retained)
        XCTAssertEqual(built.calls, 1)
        store.failsLoad = false

        model.prepareSyncNodeEnrollment()

        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === rebuilt }
        XCTAssertEqual(built.calls, 2)
    }

    // Opening Account Security never applies a newer Server Setup while the
    // replay is still retained, including after a refused claim cancel.
    func testServerSetupImportedDuringRetainedReplayWaitsWhileTheReplayIsRetained() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitLossRemote(fixture: fixture, cancelSucceeds: false)
        let retained = try await fixture.uncertainCommitModel(remote: remote)
        let built = MobileEnrollmentModelQueue([retained, try makeMobileEnrollmentModel(owner: fixture.owner)])
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore(profile: fixture.profile))
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }
        model.handleSyncNodeBootstrapFileImporter(.success([url]))

        model.prepareSyncNodeEnrollment()
        await retained.stopAndStartOver()
        model.prepareSyncNodeEnrollment()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(retained.startOverFailureMessage, SyncNodeEnrollmentViewModel.startOverUnconfirmedMessage)
        XCTAssertTrue(model.syncNodeEnrollmentModel === retained)
        XCTAssertEqual(built.calls, 1)
        XCTAssertEqual(retained.state, .commitResponseUncertain)
        XCTAssertTrue(retained.retainsInstallationReplay)
    }

    // A Server Setup imported while a replay was retained is applied once a
    // Retry installs it directly, not only through Stop and Start Over.
    func testServerSetupImportedDuringRetainedReplayIsAppliedWhenTheInstallSucceeds() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitInstallRemote(fixture: fixture)
        let retained = try await fixture.uncertainCommitModel(remote: remote)
        let rebuilt = try makeMobileEnrollmentModel(owner: fixture.owner)
        let built = MobileEnrollmentModelQueue([retained, rebuilt])
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore(profile: fixture.profile))
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }
        let url = try writeMobileServerSetup()
        defer { try? FileManager.default.removeItem(at: url) }
        model.handleSyncNodeBootstrapFileImporter(.success([url]))
        XCTAssertTrue(model.syncNodeEnrollmentModel === retained)

        await retained.retryCommit()

        // The install replaces `retained` with the rebuilt model for the
        // newly imported profile, which resets `retained`'s own coordinator
        // (`invalidateForReplacement`) back to `.enterCode` as it is retired
        // — the same thing a Replace does to any model it supersedes. The
        // install succeeding is proven by the rebuild itself, not by
        // `retained`'s state afterward.
        let commits = await remote.commits
        XCTAssertEqual(commits, 2)
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === rebuilt }
        XCTAssertTrue(model.syncNodeEnrollmentModel === rebuilt)
        XCTAssertEqual(built.calls, 2)
    }

    // The model's own post-install retirement of its profile must not be
    // mistaken for a newer Server Setup: an install with nothing imported
    // rebuilds nothing.
    func testInstallSucceedingWithNoImportRebuildsNothing() async throws {
        let fixture = try MobileRetainedEnrollmentFixture()
        let remote = MobileCommitInstallRemote(fixture: fixture)
        let importModel = SyncNodeBootstrapImportViewModel(store: MobileBootstrapProfileMemoryStore(profile: fixture.profile))
        let retained = try await fixture.uncertainCommitModel(remote: remote, retireProfile: { capabilityID in try importModel.retireProfile(expectedCapabilityID: capabilityID) })
        let built = MobileEnrollmentModelQueue([retained])
        let reader = MobileEnrollmentOwnerReader(fixture.owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeBootstrapImportModel: importModel, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === retained }

        // No Server Setup is imported; the install now succeeds and retires
        // the model's own profile, which by itself changes the import
        // model's generation exactly like a newer import would.
        await retained.retryCommit()

        guard case .installed = retained.state else { return XCTFail("expected installed, got \(retained.state)") }
        try await waitForMobile { model.syncNodeEnrollmentModel === retained }
        XCTAssertEqual(built.calls, 1)
    }

    // iOS may end Plainpost once it leaves the screen, which loses the
    // in-memory replay just as quitting does, so every retained state says so.
    func testRetainedAdmissionGuidanceAsksToKeepPlainpostOnScreen() async throws {
        XCTAssertEqual(SyncNodeEnrollmentViewModel.keepOpenMessage, "Keep Plainpost on screen while this finishes.")
        XCTAssertEqual(SyncNodeEnrollmentViewModel.activationResumesGuidance, SyncNodeEnrollmentViewModel.keepOpenMessage)
        let guidance = [
            SyncNodeEnrollmentViewModel.keepOpenMessage,
            SyncNodeEnrollmentViewModel.stopAndStartOverGuidance,
            SyncNodeEnrollmentViewModel.quittingLosesApprovalGuidance,
            SyncNodeEnrollmentViewModel.activationResumesGuidance,
        ]
        for copy in guidance {
            XCTAssertFalse(copy.contains("Keep Plainpost open"), copy)
            XCTAssertFalse(copy.contains("Quitting"), copy)
        }
        XCTAssertEqual(SyncNodeEnrollmentViewModel.stopAndStartOverGuidance, "If retrying keeps failing, choose Stop and Start Over.")
        let fixture = try MobileRetainedEnrollmentFixture()
        let retained = try await fixture.uncertainCommitModel(remote: MobileCommitLossRemote(fixture: fixture, cancelSucceeds: true))
        XCTAssertEqual(retained.retainedAdmissionGuidance, "Keep Plainpost on screen while this finishes. If retrying keeps failing, choose Stop and Start Over.")
    }

    // The production wiring must build the store with the app's own Keychain
    // access group, not the notifications group. This must never touch the
    // real Keychain (see "No automated test uses the user's real Keychain",
    // docs/superpowers/specs/2026-07-26-plainpost-clean-break-migration-design.md:574) —
    // `SyncNodeBootstrapProfileStore.init(accessGroup:)` only records the
    // group on an `AccountSecretKey`; it performs no Keychain I/O by itself,
    // so reading `.accessGroup` here is a pure source-contract check.
    func testProductionWiringBuildsTheStoreWithTheAppOwnKeychainGroup() throws {
        let store = MobileAccountModel.makeSyncNodeBootstrapProfileStore()
        XCTAssertEqual(store.accessGroup, PlainpostIOSAppKeychain.accessGroup)
        XCTAssertEqual(SyncNodeBootstrapProfileStore(accessGroup: PlainpostIOSAppKeychain.accessGroup).accessGroup, PlainpostIOSAppKeychain.accessGroup)
    }

    // The Node refresh credential and cached endpoint must stay out of the
    // notifications group the Notification Service extension shares; records
    // an earlier build wrote there move to the app group. Constructing the
    // store records the groups only and performs no Keychain I/O.
    func testSyncNodeEndpointStoreUsesTheAppOwnKeychainGroup() throws {
        let bundle = Bundle(for: MobileAccountModel.self)
        let store = try MobileAccountModel.makeSyncNodeEndpointStore()
        XCTAssertEqual(store.accessGroup, PlainpostIOSAppKeychain.accessGroup)
        XCTAssertEqual(store.legacyAccessGroup, PlainpostIOSAppKeychain.notificationsAccessGroup)
        XCTAssertEqual(PlainpostIOSAppKeychain.notificationsAccessGroup, bundle.object(forInfoDictionaryKey: "PLAINPOST_NOTIFICATION_KEYCHAIN_GROUP") as? String)
        XCTAssertNotEqual(store.accessGroup, store.legacyAccessGroup)
    }

    // MARK: - Account-mode mail with no Sync Node authority

    // The copy names the cause only when the enrollment state proves it: a
    // loaded connection with no Node in the trust commit, or a Node whose
    // connection check failed. A Node that checks out (or needs recovery)
    // proves nothing about why the authority failed, so the line is neutral.
    func testAccountMailUnavailabilityCopyFollowsTheEnrollmentState() async throws {
        let owner = SyncNodeEnrollmentOwner(accountID: try PlainpostAccountID("aaaaaaaa-1111-4111-8111-111111111111"), deviceID: try AccountDeviceID("bbbbbbbb-2222-4222-8222-222222222222"))
        let nodeID = try AccountDeviceID("90000000-0000-4000-8000-000000000002")

        XCTAssertEqual(MobileAccountMailUnavailability(enrollment: nil), .undetermined)
        XCTAssertEqual(MobileAccountMailUnavailability(enrollment: try makeMobileEnrollmentModel(owner: owner)), .noSyncNode)
        XCTAssertEqual(MobileAccountMailUnavailability(enrollment: try makeMobileEnrollmentModel(owner: owner, activeNodeID: nodeID, connection: .connectionFailed)), .syncNodeUnreachable)
        for connection: SyncNodeEnrollmentViewModel.ConnectionPresentation in [.connected, .recoveryRequired, .ready, .checking, .failed] {
            XCTAssertEqual(
                MobileAccountMailUnavailability(enrollment: try makeMobileEnrollmentModel(owner: owner, activeNodeID: nodeID, connection: connection)),
                .undetermined, "\(connection)"
            )
        }
        XCTAssertEqual(MobileAccountMailUnavailability.noSyncNode.message, "Set up a Sync Node to read mail in your Plainpost account.")
        XCTAssertEqual(MobileAccountMailUnavailability.syncNodeUnreachable.message, "Can't reach your Sync Node. Check your connection and try again.")
        XCTAssertEqual(MobileAccountMailUnavailability.undetermined.message, "Mail comes from your Sync Node. Set it up or try again.")

        // The account model reads it from the enrollment it may present.
        let enrolled = try makeMobileEnrollmentModel(owner: owner, activeNodeID: nodeID, connection: .connectionFailed)
        let built = MobileEnrollmentModelQueue([enrolled])
        let reader = MobileEnrollmentOwnerReader(owner)
        let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { try built.next() }, syncNodeEnrollmentOwnerReader: { try reader.read() })
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        XCTAssertEqual(model.mailUnavailability, .undetermined)
        model.prepareSyncNodeEnrollment()
        try await waitForMobile { model.presentableSyncNodeEnrollmentModel === enrolled }
        XCTAssertEqual(model.mailUnavailability, .syncNodeUnreachable)

        XCTAssertEqual(MobileAccountMailUnavailability(enrollment: nil, load: .noSyncNode), .noSyncNode)
        XCTAssertEqual(MobileAccountMailUnavailability(enrollment: nil, load: .failed(message: "x")), .undetermined)
    }

    // Only the factory's deliberate "no Node and no Server Setup" error means No Sync Node;
    // any other load failure leaves it unknown whether the account has one.
    func testSyncNodeLoadTellsNoSyncNodeFromARealFailure() async throws {
        typealias Load = AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation
        let cases: [(any Error, Load, MobileAccountMailUnavailability)] = [
            (SyncNodeEnrollmentAssembly.LoadError.noSyncNode, .noSyncNode, .noSyncNode),
            (AccountRuntimeError.secretUnavailable, .failed(message: Load.failureMessage), .undetermined),
            (AccountRuntimeError.transportFailure, .failed(message: Load.unreachableMessage), .undetermined),
        ]
        for (error, load, unavailability) in cases {
            let model = MobileAccountModel(prepareSession: { _ in .active }, syncNodeEnrollmentFactory: { throw error })
            model.prepare()
            try await waitForMobile { model.presentation == .active }
            model.prepareSyncNodeEnrollment()
            try await waitForMobile { model.syncNodeEnrollmentLoadPresentation == load }
            XCTAssertEqual(model.mailUnavailability, unavailability, "\(error)")
        }
    }

    // The first authority attempt is reported while it runs, and a Retry in
    // that window waits for it instead of discarding its result.
    func testRetryDuringTheFirstAuthorityAttemptKeepsItsResult() async throws {
        let defaults = try Self.freshDefaults(#function)
        let client = NodeSyncClient(sender: MobileTwoAccountNodeSender())
        let node = MobileRetryNodeGate()
        node.isAvailable = true
        node.holdsFirstSession = true
        let model = MobileAccountModel(
            prepareSession: { _ in await node.recordPrepare() },
            nodeMailSessionFactory: { _ in
                node.sessionAttempts += 1
                if node.sessionAttempts == 1 { await node.waitForRelease() }
                guard node.isAvailable else { throw AccountRuntimeError.secretUnavailable }
                return MobileNodeMailSession(client: client, accountID: MobileAccountModel.testingNodeAccountID)
            },
            mailSelectionDefaults: defaults,
            requiresMailAuthority: true
        )
        XCTAssertFalse(model.isPreparingMailAuthority)
        model.prepare()
        try await waitForMobile { node.isHoldingFirstSession }
        XCTAssertTrue(model.isPreparingMailAuthority)

        let retry = Task { await model.retryMailAuthority() }
        try await Task.sleep(for: .milliseconds(50))
        node.release()
        await retry.value

        XCTAssertNotNil(model.mailAuthority)
        XCTAssertFalse(model.isPreparingMailAuthority)
        XCTAssertEqual(node.sessionAttempts, 1, "Retry waits for the first attempt and keeps its authority")
    }

    // Account mode re-prepares the account authority; local mode and a
    // runtime that failed to open re-run the route.
    func testMailUnavailableRecoveryRebuildsTheAccountAuthorityOnlyInAccountMode() {
        let unavailable = MobileMailRoute.nodeUnavailable(AccountID("plainpost-node"))
        XCTAssertEqual(
            MobileMailUnavailableRecovery(route: unavailable, isAccountMode: true, offersSyncNodeSetup: true),
            .accountAuthority(offersSyncNodeSetup: true)
        )
        XCTAssertEqual(
            MobileMailUnavailableRecovery(route: unavailable, isAccountMode: true, offersSyncNodeSetup: false),
            .accountAuthority(offersSyncNodeSetup: false)
        )
        XCTAssertEqual(MobileMailUnavailableRecovery(route: unavailable, isAccountMode: false, offersSyncNodeSetup: true), .route)
        XCTAssertEqual(MobileMailUnavailableRecovery(route: .localSetup, isAccountMode: true, offersSyncNodeSetup: true), .route)
    }

    // Retry rebuilds the authority a failed Node session left nil, without
    // re-running the account session or resetting its presentation.
    func testRetryMailAuthorityRebuildsAFailedAuthorityWithoutResettingTheSession() async throws {
        let defaults = try Self.freshDefaults(#function)
        let client = NodeSyncClient(sender: MobileTwoAccountNodeSender())
        let node = MobileRetryNodeGate()
        let model = MobileAccountModel(
            prepareSession: { _ in await node.recordPrepare() },
            nodeMailSessionFactory: { _ in
                node.sessionAttempts += 1
                guard node.isAvailable else { throw AccountRuntimeError.secretUnavailable }
                return MobileNodeMailSession(client: client, accountID: MobileAccountModel.testingNodeAccountID)
            },
            mailSelectionDefaults: defaults,
            requiresMailAuthority: true
        )
        model.prepare()
        try await waitForMobile { model.presentation == .active }
        await model.settleMailAuthorityPreparation()
        XCTAssertNil(model.mailAuthority)
        XCTAssertEqual(node.sessionAttempts, 1)

        node.isAvailable = true
        await model.retryMailAuthority()

        XCTAssertNotNil(model.mailAuthority)
        XCTAssertEqual(node.sessionAttempts, 2)
        XCTAssertEqual(node.prepares, 1, "Retry must not re-run the account session")
        XCTAssertEqual(model.presentation, .active)
    }

    private func waitForMobile(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not reached")
    }

    private func waitForMobileCount(_ recorder: MobileAccountApprovalRecorder, equalTo expected: Int) async throws {
        for _ in 0 ..< 200 {
            if await recorder.count == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let actual = await recorder.count
        XCTFail("expected \(expected) factory calls, observed \(actual)")
    }

    func testMobileSecurityAppleAttemptIsCanonicalStaleSafeAndTokenLocal() async throws {
        var actions: [MobileAccountSecurityModel.Action] = []
        var stateChanges = 0
        let model = MobileAccountSecurityModel(
            loadSnapshot: { ([], []) },
            performAction: { action, identityToken, nonce in
                XCTAssertEqual(identityToken, "identity.token")
                XCTAssertEqual(nonce, Data(repeating: 0xA7, count: 32))
                actions.append(action)
                return nil
            },
            saveLabel: { _, _ in },
            stateChanged: { stateChanges += 1 },
            nonceGenerator: { Data(repeating: 0xA7, count: 32) }
        )
        let target = try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let provider = ASAuthorizationAppleIDProvider()
        let staleRequest = provider.createRequest()
        let staleID = try XCTUnwrap(model.configure(staleRequest, action: .revoke(target)))
        let currentRequest = provider.createRequest()
        let currentID = try XCTUnwrap(model.configure(currentRequest, action: .revoke(target)))

        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(try XCTUnwrap(currentRequest.nonce)), Data(repeating: 0xA7, count: 32))
        XCTAssertFalse(try XCTUnwrap(currentRequest.nonce).contains("="))
        model.submitAppleIdentityToken(Data("stale.token".utf8), id: staleID)
        XCTAssertTrue(model.hasPendingAppleAuthorization)
        model.submitAppleIdentityToken(Data("identity.token".utf8), id: currentID)
        await model.waitUntilIdle()

        XCTAssertEqual(actions, [.revoke(target)])
        XCTAssertEqual(stateChanges, 1)
        XCTAssertFalse(model.hasPendingAppleAuthorization)
        XCTAssertNil(model.errorMessage)
    }

    /// Recovery right after sign-in reuses that Apple sign-in: no second Apple sheet.
    func testMobileRecoveryReusesTheRecentAppleSignIn() async throws {
        var received: [(MobileAccountSecurityModel.Action, String, Data)] = []
        let model = MobileAccountSecurityModel(
            loadSnapshot: { ([], []) },
            performAction: { action, identityToken, nonce in
                received.append((action, identityToken, nonce))
                return nil
            },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA7, count: 32) }
        )
        let nonce = Data(repeating: 0x42, count: 32)

        model.recover(with: RecentAppleSignIn(identityToken: "first.sign.in", rawNonce: nonce, obtainedAt: Date()))
        await model.waitUntilIdle()

        XCTAssertEqual(received.map(\.0), [.recoverAccount])
        XCTAssertEqual(received.first?.1, "first.sign.in")
        XCTAssertEqual(received.first?.2, nonce)
        XCTAssertNil(model.errorMessage)
    }

    func testMobileSecurityCancellationInvalidatesAttemptAndLateActionCompletion() async throws {
        let gate = MobileSecurityActionGate()
        var stateChanges = 0
        let model = MobileAccountSecurityModel(
            loadSnapshot: { ([], []) },
            performAction: { action, _, _ in try await gate.run(action); return nil },
            saveLabel: { _, _ in },
            stateChanged: { stateChanges += 1 },
            nonceGenerator: { Data(repeating: 0xB8, count: 32) }
        )
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        let attemptID = try XCTUnwrap(model.configure(request, action: .deleteAccount))
        model.submitAppleIdentityToken(Data("identity.token".utf8), id: attemptID)
        await gate.waitUntilStarted()

        model.cancel()
        await gate.finish()
        await model.waitUntilIdle()

        XCTAssertEqual(stateChanges, 0)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.hasPendingAppleAuthorization)
        XCTAssertNil(model.deletionResult)
    }

    func testMobileAppleNonceIsFreshCanonicalAndStaleCompletionCannotClearCurrentAttempt() throws {
        let model = MobileAccountModel(prepareSession: { _ in .signInRequired })
        let provider = ASAuthorizationAppleIDProvider()
        let firstRequest = provider.createRequest()
        let firstID = try XCTUnwrap(model.configureAppleRequest(firstRequest))
        let firstNonce = try XCTUnwrap(firstRequest.nonce)
        let secondRequest = provider.createRequest()
        let secondID = try XCTUnwrap(model.configureAppleRequest(secondRequest))
        let secondNonce = try XCTUnwrap(secondRequest.nonce)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertNotEqual(firstNonce, secondNonce)
        XCTAssertFalse(firstNonce.contains("="))
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(firstNonce).count, 32)
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(secondNonce).count, 32)

        model.completeAppleAuthorization(
            .failure(ASAuthorizationError(.canceled)),
            attemptID: firstID
        )
        XCTAssertTrue(model.isAppleSignInInFlight)
        model.completeAppleAuthorization(
            .failure(ASAuthorizationError(.canceled)),
            attemptID: secondID
        )
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertEqual(model.presentation, .signInRequired)
    }

    func testAppleBootstrapFailureIsVisibleAndNewAttemptClearsIt() async throws {
        let gate = MobileAppleBootstrapGate()
        let model = MobileAccountModel(
            prepareSession: { _ in .signInRequired },
            bootstrap: { _, _ in
                await gate.hold()
                throw PlainpostError.validationFailed("private server detail")
            }
        )
        let provider = ASAuthorizationAppleIDProvider()
        let firstID = try XCTUnwrap(model.configureAppleRequest(provider.createRequest()))

        model.submitAppleIdentityToken(Data("identity-token".utf8), attemptID: firstID)
        await gate.waitUntilStarted()
        XCTAssertTrue(model.isAppleSignInInFlight)
        XCTAssertNil(model.configureAppleRequest(provider.createRequest()), "A pending bootstrap must not be replaced")
        await gate.release()
        await model.waitForAppleSignInToSettle()

        XCTAssertEqual(model.presentation, .signInRequired)
        XCTAssertEqual(model.appleSignInErrorMessage, "Plainpost could not connect your account. Try signing in with Apple again.")
        XCTAssertFalse(try XCTUnwrap(model.appleSignInErrorMessage).contains("private server detail"))

        let retryID = try XCTUnwrap(model.configureAppleRequest(provider.createRequest()))
        XCTAssertNotEqual(firstID, retryID)
        XCTAssertNil(model.appleSignInErrorMessage)
        XCTAssertTrue(model.isAppleSignInInFlight)
    }

    func testMobileShutdownPermanentlyRejectsNewAndLateAppleAttempts() async throws {
        let model = MobileAccountModel(prepareSession: { _ in .signInRequired })
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        let attemptID = try XCTUnwrap(model.configureAppleRequest(request))
        await model.shutdownForServerChange()
        model.completeAppleAuthorization(
            .failure(ASAuthorizationError(.unknown)),
            attemptID: attemptID
        )
        XCTAssertFalse(model.isAppleSignInInFlight)
        XCTAssertNil(model.configureAppleRequest(provider.createRequest()))
    }

    func testNotificationProducerSelectionRequiresAuthenticatedStepUp() {
        let model = MobileAccountModel(prepareSession: { _ in .active })

        XCTAssertEqual(model.notificationProducerSelectionState, .idle)
        model.selectNotificationProducer()
        XCTAssertEqual(model.notificationProducerSelectionState, .unavailable)
        XCTAssertNil(model.notificationProducerAuthority)
        model.finishNotificationProducerEnrollment()
        XCTAssertEqual(model.notificationProducerSelectionState, .idle)
    }

    func testDirectNotificationMailboxRowsUseGenericLabels() async {
        let mailbox = Data(repeating: 0x4A, count: 32)
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            notificationProducerMailboxesFactory: { [mailbox] }
        )

        await model.loadNotificationProducerMailboxes()

        XCTAssertEqual(model.directNotificationMailboxRows.map(\.label), ["Mailbox 1"])
        XCTAssertEqual(model.directNotificationMailboxRows.first?.logicalMailboxID.rawValue, mailbox)
    }

    /// Each Direct account derives the mailbox a Mac with the same account names; Settings
    /// shows which a Mac sends instant alerts for, labelled by email, and "Fix" picks the
    /// first one without.
    func testDirectAccountsDeriveTheirMailboxAndShowWhichAMacAlertsFor() async throws {
        let alice = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x61, count: 32)))
        let bob = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x62, count: 32)))
        let mac = try AccountDeviceID("22222222-3333-4444-5555-777777777777")
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            notificationProducerAssignmentsFactory: {
                [NotificationProducerAssignment(
                    logicalMailboxID: alice.rawValue, producerDeviceID: mac, kind: .mac,
                    generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 0x01, count: 32)
                )]
            },
            directInboxMailboxIDFactory: { host, email in
                XCTAssertEqual(host, "imap.example.com")
                return email == "alice@example.com" ? alice : bob
            }
        )
        model.prepare(now: Date())
        for _ in 0..<200 where !model.presentation.allowsMailbox { try await Task.sleep(for: .milliseconds(10)) }

        await model.setDirectMailAccounts([
            (id: AccountID("acc_alice"), email: "alice@example.com", imapHost: "imap.example.com"),
            (id: AccountID("acc_bob"), email: "bob@example.com", imapHost: "imap.example.com"),
        ])
        _ = await model.refreshNotificationProducerAssignments()

        XCTAssertEqual(model.directMacAlertAccounts.map(\.email), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(model.directMacAlertAccounts.map(\.usesMac), [true, false])
        XCTAssertEqual(model.directNotificationMailboxRows.map(\.label), ["alice@example.com"])
        XCTAssertEqual(model.firstDirectMailboxWithoutMac, bob.rawValue)
    }

    func testNotificationPolicyRowsFollowCurrentAuthorityAndClearStaleRows() throws {
        let directMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x4B, count: 32)))
        let nodeMailbox = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 0x4C, count: 32)))
        let directRows = [NotificationDirectMailboxRow(logicalMailboxID: directMailbox, label: "Mailbox 1")]
        let providerRows = [SyncNodeProviderMailbox(displayName: "Provider Inbox", mailboxHandle: "inbox", role: "inbox", logicalMailboxID: nodeMailbox)]

        let macRows = MobileMailRootView.notificationPolicyRows(authority: .mac, assignedMailboxes: providerRows, directMailboxes: directRows)
        XCTAssertEqual(macRows.map(\.label), ["Mailbox 1"])
        XCTAssertEqual(macRows.first?.id, directMailbox)

        let syncRows = MobileMailRootView.notificationPolicyRows(authority: .syncNode, assignedMailboxes: providerRows, directMailboxes: directRows)
        XCTAssertEqual(syncRows.map(\.label), ["Provider Inbox"])
        XCTAssertEqual(syncRows.first?.id, nodeMailbox)
        let mixedRows = MobileMailRootView.notificationPolicyRows(authority: .mixed, assignedMailboxes: providerRows, directMailboxes: directRows)
        XCTAssertEqual(mixedRows.map(\.label), ["Mailbox 1", "Provider Inbox"])
        XCTAssertEqual(mixedRows.map(\.id), [directMailbox, nodeMailbox])
        XCTAssertTrue(MobileMailRootView.notificationPolicyRows(authority: nil, assignedMailboxes: providerRows, directMailboxes: directRows).isEmpty)
    }

    func testNotificationProducerTargetWaitsForAppleStepUpBeforePublishingAuthority() async throws {
        let target = NotificationProducerTarget(
            deviceID: try AccountDeviceID("22222222-3333-4444-5555-666666666666"), kind: .syncNode
        )
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            notificationProducerTargetsFactory: { [target] }
        )
        let mailbox = Data(repeating: 0x42, count: 32)
        model.selectNotificationProducer()
        await Task.yield()
        model.beginNotificationProducerEnrollment(target: target, logicalMailboxID: mailbox)
        XCTAssertEqual(model.notificationProducerSelectionState, .authenticating(authority: .syncNode))
        XCTAssertNil(model.notificationProducerAuthority)

        let request = ASAuthorizationAppleIDProvider().createRequest()
        let attempt = try XCTUnwrap(model.configureNotificationProducerAppleRequest(request))
        XCTAssertEqual(try AccountWireCodec.decodeBase64URL(request.nonce ?? "").count, 32)
        model.completeNotificationProducerAppleAuthorization(.failure(ASAuthorizationError(.canceled)), attemptID: attempt)
        XCTAssertEqual(model.notificationProducerSelectionState, .unavailable)
        XCTAssertNil(model.notificationProducerAuthority)
    }

    func testNotificationProducerSwitchUsesReturnedCurrentGenerationForSuccessor() throws {
        let successor = NotificationProducerTarget(
            deviceID: try AccountDeviceID("22222222-3333-4444-8555-666666666666"), kind: .syncNode,
            expectedGeneration: 999
        )
        let current = NotificationProducerAssignment(
            logicalMailboxID: Data(repeating: 0x42, count: 32),
            producerDeviceID: try AccountDeviceID("11111111-2222-3333-8444-555555555555"),
            kind: .mac, generation: 7, trustEpoch: 2, trustRevision: 3,
            trustHead: Data(repeating: 0xA1, count: 32)
        )
        let resolved = MobileAccountModel.targetUsingAuthoritativeAssignment(successor, assignment: current)

        XCTAssertEqual(resolved.deviceID, successor.deviceID)
        XCTAssertEqual(resolved.kind, successor.kind)
        XCTAssertEqual(resolved.expectedGeneration, 7)
        XCTAssertNotEqual(resolved.expectedGeneration, successor.expectedGeneration)
    }

    func testNotificationProducerClearThenSuccessorUsesZeroCASGeneration() throws {
        let successor = NotificationProducerTarget(
            deviceID: try AccountDeviceID("22222222-3333-4444-8555-666666666666"), kind: .syncNode,
            expectedGeneration: 123
        )
        let resolved = MobileAccountModel.targetUsingAuthoritativeAssignment(successor, assignment: nil)

        XCTAssertEqual(resolved.deviceID, successor.deviceID)
        XCTAssertEqual(resolved.kind, successor.kind)
        XCTAssertEqual(resolved.expectedGeneration, 0)
    }

    /// Settings ▸ Notifications' Turn On: the shown detail (here the default Full, which the
    /// picker never "changes" to) is saved and registration runs, in one sequence. The
    /// simulator-only App Attest provider ends registration at `.unavailable`, after the
    /// permission prompt, which proves `configure()` ran.
    func testEnableNotificationsWithPolicySavesItAndRegistersInOneSequence() async throws {
        for policy in [NotificationPreviewPolicy.rich, .generic] {
            let permission = MobileRecordingNotificationPermission()
            let created = MobileRegistrationBox()
            let model = MobileAccountModel(
                prepareSession: { _ in .active },
                mailAuthorityFactory: { _ in
                    PlainpostNodeMailAuthority(
                        client: NodeSyncClient(sender: MobileNoopNodeSender()),
                        accountID: AccountID("00112233-4455-6677-8899-aabbccddeeff")
                    )
                },
                notificationRegistrationFactory: {
                    let registration = try NotificationRegistrationModel(
                        trust: { throw AccountRuntimeError.untrustedResponse },
                        identitySignature: { _ in Data(repeating: 0x77, count: 64) },
                        permission: permission,
                        apns: MobileFailingAPNSToken(),
                        attest: UnsupportedAppAttestProvider(),
                        remote: MobileFailingNotificationRemote(),
                        store: InMemoryNotificationRegistrationStore(),
                        topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox,
                        mailPairingState: .unpaired
                    )
                    created.registration = registration
                    return registration
                }
            )
            model.prepare(now: Date())
            for _ in 0..<200 where model.mailAuthority == nil || created.registration == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.notificationStatus, .unconfigured)

            model.enableNotifications(policy: policy)
            for _ in 0..<200 where model.notificationStatus == .unconfigured || model.notificationStatus == .registering {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertEqual(permission.requests, 1, "\(policy): registration ran once")
            XCTAssertEqual(model.notificationStatus, .unavailable(.appAttestUnsupported), "\(policy)")
            XCTAssertEqual(created.registration?.previewPolicy, policy)
            XCTAssertEqual(model.notificationPreviewPolicy, policy)
            XCTAssertTrue(model.notificationPolicySelected)
        }
    }

    /// Off saves the detail but never registers.
    func testEnableNotificationsWithOffDoesNotRegister() async throws {
        let permission = MobileRecordingNotificationPermission()
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            mailAuthorityFactory: { _ in
                PlainpostNodeMailAuthority(
                    client: NodeSyncClient(sender: MobileNoopNodeSender()),
                    accountID: AccountID("00112233-4455-6677-8899-aabbccddeeff")
                )
            },
            notificationRegistrationFactory: {
                try NotificationRegistrationModel(
                    trust: { throw AccountRuntimeError.untrustedResponse },
                    identitySignature: { _ in Data(repeating: 0x77, count: 64) },
                    permission: permission, apns: MobileFailingAPNSToken(),
                    attest: UnsupportedAppAttestProvider(), remote: MobileFailingNotificationRemote(),
                    store: InMemoryNotificationRegistrationStore(),
                    topic: "com.marynavdovenko.Plainpost.iOS", environment: .sandbox,
                    mailPairingState: .unpaired
                )
            }
        )
        model.prepare(now: Date())
        for _ in 0..<200 where model.mailAuthority == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.enableNotifications(policy: .off)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(model.notificationPreviewPolicy, .off)
        XCTAssertEqual(model.notificationStatus, .unconfigured)
    }

    /// An iPhone another device's recovery suspended can sign in again like a new one.
    func testASuspendedIPhoneCanSignInAgain() async throws {
        let model = MobileAccountModel(
            prepareSession: { _ in .suspended },
            discardSuspendedSession: { _ in .signInRequired }
        )
        model.prepare(now: Date())
        for _ in 0..<200 where model.presentation != .suspended { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.presentation, .suspended)
        XCTAssertTrue(model.canSignInAgainAfterSuspension)

        model.signInAgainAfterSuspension()
        for _ in 0..<200 where model.presentation != .signInRequired { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(model.presentation, .signInRequired)
    }

    func testNotificationReapprovalWithoutPendingAdmissionSurfacesRegistrationAttempt() {
        let model = MobileAccountModel(prepareSession: { _ in .active })
        model.prepare(now: Date())

        model.reapproveNotifications()

        XCTAssertEqual(model.notificationStatus, .degraded(.unavailable))
    }

    func testMobileRootOwnsPendingFlowThroughSASAndCancellation() async throws {
        let subject = PassthroughSubject<AccountAdmissionController.State, Never>()
        let lifecycle = MobileAccountFlowRecorder()
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            mode: .pending
        )
        let model = MobileAccountModel(
            prepareSession: { _ in .provisional(activation) },
            admissionFactory: { _ in
                AccountPendingAdmissionFlow(
                    states: subject.eraseToAnyPublisher(),
                    start: { _ in lifecycle.start() },
                    cancel: { lifecycle.cancel() }
                )
            }
        )

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.starts == 0 { await Task.yield() }
        subject.send(.matchingCode("123456"))
        XCTAssertEqual(model.presentation.matchingCodeDisplay, "123 456")
        model.cancelPendingApproval()
        XCTAssertEqual(model.presentation, .recoveryRequired)
        XCTAssertEqual(lifecycle.cancels, 1)
    }

    func testMobileRootOwnsActiveDiscoveryAndSingleUseBiometricApproval() async throws {
        let subject = PassthroughSubject<AccountActiveAdmissionController.State, Never>()
        let lifecycle = MobileAccountFlowRecorder()
        let approvals = MobileAccountApprovalRecorder()
        let context = try AccountDeviceApprovalContext(
            pendingID: "pending-mobile-flow",
            offerDigest: Data(repeating: 0x41, count: 32),
            responseDigest: Data(repeating: 0x42, count: 32),
            generation: 1,
            matchingCode: "654321",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_060)
        )
        let capability = AccountDeviceApprovalCapability(
            context: context,
            approve: { await approvals.record() },
            cancel: {}
        )
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            activeAdmissionFactory: {
                AccountActiveAdmissionFlow(
                    states: subject.eraseToAnyPublisher(),
                    refresh: { lifecycle.refresh() },
                    begin: { _ in lifecycle.begin() },
                    currentApprovalCapability: { capability },
                    cancel: { lifecycle.cancel() }
                )
            },
            localApprovalAuthenticator: MobileAllowingAccountAuthenticator()
        )

        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.refreshes == 0 { await Task.yield() }
        let pending = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .macos, requestID: "request-mobile-flow")
        subject.send(.idle([pending]))
        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 1)
        subject.send(.awaitingResponse)
        subject.send(.awaitingConfirmation(.init(matchingCode: context.matchingCode, expiresAt: context.expiresAt)))
        model.confirmApproval()
        await model.waitForDeviceApprovalToSettle()
        let approvalCount = await approvals.count
        XCTAssertEqual(approvalCount, 1)
    }

    func testMobilePendingDeviceReviewShowsProgressFailureAndPerRequestDismissal() async throws {
        let subject = PassthroughSubject<AccountActiveAdmissionController.State, Never>()
        let lifecycle = MobileAccountFlowRecorder()
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            activeAdmissionFactory: {
                AccountActiveAdmissionFlow(
                    states: subject.eraseToAnyPublisher(),
                    refresh: { lifecycle.refresh() },
                    begin: { _ in lifecycle.begin() },
                    currentApprovalCapability: { nil },
                    cancel: { lifecycle.cancel() }
                )
            },
            localApprovalAuthenticator: MobileAllowingAccountAuthenticator()
        )
        model.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
        for _ in 0 ..< 100 where lifecycle.refreshes == 0 { await Task.yield() }

        let expired = AccountActiveAdmissionController.PendingPrompt(selection: 0, platform: .macos, requestID: "request-mobile-expired")
        let other = AccountActiveAdmissionController.PendingPrompt(selection: 1, platform: .ios, requestID: "request-mobile-other")
        subject.send(.idle([expired, other]))
        XCTAssertEqual(model.pendingDeviceApproval, .review(expired))
        model.beginApproval()
        subject.send(.awaitingResponse)
        model.beginApproval()
        XCTAssertEqual(lifecycle.begins, 1)
        XCTAssertEqual(model.pendingDeviceApproval, .contacting(expired))

        subject.send(.failed(.expired))
        XCTAssertNil(model.pendingApprovalPrompt)
        XCTAssertEqual(model.pendingDeviceApproval, .failed(.expired, retry: nil))
        model.dismissPendingDeviceApproval()
        XCTAssertEqual(lifecycle.refreshes, 2)
        XCTAssertEqual(model.pendingDeviceApproval, .review(other))

        model.dismissPendingDeviceApproval()
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)
        subject.send(.idle([expired, other]))
        XCTAssertEqual(model.pendingDeviceApproval, .hidden)
    }

    func testPostAdmissionMailAuthorityPreparationIsCancelledWithoutLatePublication() async throws {
        let started = XCTestExpectation(description: "authority preparation started")
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            mailAuthorityFactory: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
        )

        model.prepare(now: Date())
        await fulfillment(of: [started], timeout: 1)
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(model.mailAuthority)
    }

    func testNonCooperativeLateMailAuthorityFactoryCannotCrossGenerationFence() async throws {
        let started = XCTestExpectation(description: "authority preparation started")
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            mailAuthorityFactory: { _ in
                started.fulfill()
                try? await Task.sleep(for: .seconds(10))
                return PlainpostNodeMailAuthority(
                    client: NodeSyncClient(sender: MobileNoopNodeSender()),
                    accountID: AccountID("00112233-4455-6677-8899-aabbccddeeff")
                )
            }
        )

        model.prepare(now: Date())
        await fulfillment(of: [started], timeout: 1)
        model.cancel()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(model.mailAuthority)
        XCTAssertNil(model.syncNodeProviderController)
    }

    @MainActor
    func testOfflineLeaseExpiresIntoRecoveryWithoutForegroundOrWake() async throws {
        let expiry = Date().addingTimeInterval(0.05)
        let model = MobileAccountModel(prepareSession: { _ in .offlineLease(expiresAt: expiry) })
        model.prepare(now: Date())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.presentation, .offlineLease(expiresAt: expiry))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.presentation, .recoveryRequired)
    }

    func testMobileAccountRootBlocksMailboxExceptForActiveAndVerifiedOfflineLease() {
        XCTAssertFalse(MobileAccountPresentation.signInRequired.allowsMailbox)
        XCTAssertFalse(MobileAccountPresentation.pendingApproval(matchingCode: nil).allowsMailbox)
        XCTAssertTrue(MobileAccountPresentation.active.allowsMailbox)
        XCTAssertTrue(MobileAccountPresentation.offlineLease(expiresAt: Date(timeIntervalSince1970: 1_900_000_000)).allowsMailbox)
        XCTAssertFalse(MobileAccountPresentation.suspended.allowsMailbox)
        XCTAssertFalse(MobileAccountPresentation.cleanupRequired.allowsMailbox)
        XCTAssertFalse(MobileAccountPresentation.deleted.allowsMailbox)
        XCTAssertFalse(MobileAccountPresentation.recoveryRequired.allowsMailbox)
    }

    func testMobilePendingAccountRootExposesOnlyAValidatedMatchingCode() {
        XCTAssertEqual(MobileAccountPresentation.pendingApproval(matchingCode: "654321").matchingCodeDisplay, "654 321")
        XCTAssertNil(MobileAccountPresentation.pendingApproval(matchingCode: "identity-token").matchingCodeDisplay)
    }

    func testIncompleteGenesisNeverUsesMobilePendingApprovalPresentation() throws {
        let activation = AccountActivation(
            accountID: try PlainpostAccountID("00112233-4455-6677-8899-aabbccddeeff"),
            deviceID: try AccountDeviceID("aaaaaaaa-bbbb-cccc-dddd-00000000000c"),
            mode: .genesis
        )
        XCTAssertEqual(
            MobileAccountModel.presentation(
                for: .provisional(activation),
                now: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            .recoveryRequired
        )
    }

    func testMobileLaunchRequiresConfigurationBeforeConstructingAccount() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.mobile.launch.empty")
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        var factoryCalls = 0
        let launch = MobileAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: store),
            store: store,
            credentials: credentials,
            bundledDocument: nil,
            makeAccountModel: { _ in
                factoryCalls += 1
                return MobileAccountModel(prepareSession: { _ in .signInRequired })
            }
        )

        XCTAssertTrue(launch.showsSetup)
        XCTAssertNil(launch.accountModel)
        XCTAssertEqual(factoryCalls, 0)

        await launch.save(originText: "https://mobile.example")
        XCTAssertEqual(launch.selectedServer, try CentralServerConfiguration(originText: "https://mobile.example"))
        XCTAssertEqual(factoryCalls, 1)
    }

    func testMobileChangeServerTearsDownBeforePristineReplacement() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.mobile.launch.change")
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let first = try CentralServerConfiguration(originText: "https://first.example")
        var factoryCalls = 0
        var shutdownCalls = 0
        let launch = MobileAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: store),
            store: store,
            credentials: credentials,
            bundledDocument: first.canonicalDocument,
            makeAccountModel: { _ in
                factoryCalls += 1
                return MobileAccountModel(prepareSession: { _ in .signInRequired })
            },
            shutdownAccountModel: { model in
                model.cancel()
                shutdownCalls += 1
            }
        )

        await launch.changeServer()
        XCTAssertNil(launch.accountModel)
        XCTAssertEqual(shutdownCalls, 1)
        await launch.save(originText: "https://second.example")
        XCTAssertEqual(launch.selectedServer, try CentralServerConfiguration(originText: "https://second.example"))
        XCTAssertEqual(factoryCalls, 2)
    }

    func testMobileChangeServerImmediatelyRetiresOldModelWhileShutdownDrains() async throws {
        let secrets = InMemoryAccountSecretStore()
        let credentials = AccountCredentialStore(secretStore: secrets, service: "test.mobile.launch.race")
        let store = KeychainCentralServerConfigurationStore(secretStore: secrets)
        let server = try CentralServerConfiguration(originText: "https://first.example")
        let gate = MobileLaunchShutdownGate()
        var factoryCalls = 0
        let launch = MobileAccountLaunchModel(
            resolver: CentralServerConfigurationResolver(store: store),
            store: store,
            credentials: credentials,
            bundledDocument: server.canonicalDocument,
            makeAccountModel: { _ in
                factoryCalls += 1
                return MobileAccountModel(prepareSession: { _ in .signInRequired })
            },
            shutdownAccountModel: { _ in await gate.drain() }
        )

        let change = Task { await launch.changeServer() }
        await gate.waitUntilStarted()
        XCTAssertTrue(launch.isChangingServer)
        XCTAssertNil(launch.accountModel)
        XCTAssertFalse(launch.showsSetup)
        await launch.save(originText: "https://second.example")
        XCTAssertEqual(try store.loadSelection(), server.canonicalSelectionRecord)
        XCTAssertEqual(factoryCalls, 1)
        await gate.finish()
        await change.value
        XCTAssertTrue(launch.showsSetup)
    }

    // MARK: - Sync Node mail accounts

    @MainActor
    func testMobileMailAccountsSelectionRoutesAuthorityToOwningAccountAndFallsBackToPrimary() async throws {
        UserDefaults(suiteName: #function)!.removePersistentDomain(forName: #function)
        let sender = MobileTwoAccountNodeSender()   // pre-approved copy of Task 7's TwoAccountNodeSender (ruling C7)
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: UserDefaults(suiteName: #function)!)
        await model.refreshMailAccounts()
        XCTAssertEqual(model.mailAccounts.map(\.providerIdentity), ["ada@example.test", "grace@example.test"])
        XCTAssertEqual(model.selectedMailAccountID, model.mailAccounts.first { $0.isPrimary }?.logicalMailboxID)

        let grace = try XCTUnwrap(model.mailAccounts.first { $0.providerIdentity == "grace@example.test" })
        await model.selectMailAccount(grace.logicalMailboxID)
        let authority = try XCTUnwrap(model.mailAuthority as? PlainpostNodeMailAuthority)
        XCTAssertEqual(authority.mailAccount?.logicalMailboxID, grace.logicalMailboxID)
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
        let routedLogicalMailboxID = try await sender.lastMutationLogicalMailboxID()
        XCTAssertEqual(routedLogicalMailboxID, grace.logicalMailboxID)

        await sender.removeAccount(grace.logicalMailboxID)
        await model.refreshMailAccounts()
        XCTAssertEqual(model.selectedMailAccountID, model.mailAccounts.first { $0.isPrimary }?.logicalMailboxID)
    }

    @MainActor
    func testMobileMailAccountSelectionPersistsRawBase64URLAndComposerSenderFollowsSelection() async throws {
        let defaults = try Self.freshDefaults(#function)
        let sender = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()
        XCTAssertEqual(model.mailAuthority?.senderAddress, EmailAddress("ada@example.test"))

        await model.selectMailAccount(MobileTwoAccountNodeSender.graceLogicalMailboxID)
        XCTAssertEqual(
            defaults.string(forKey: Self.selectionKey),
            AccountWireCodec.encodeBase64URL(MobileTwoAccountNodeSender.graceLogicalMailboxID.rawValue)
        )
        XCTAssertEqual(model.mailAuthority?.senderAddress, EmailAddress("grace@example.test"))

        // A new model (next launch) restores the persisted account.
        let relaunched = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await relaunched.refreshMailAccounts()
        XCTAssertEqual(relaunched.selectedMailAccountID, MobileTwoAccountNodeSender.graceLogicalMailboxID)
        XCTAssertEqual(relaunched.mailAuthority?.senderAddress, EmailAddress("grace@example.test"))

        // Selecting an account the Node does not list changes nothing.
        let unknown = try XCTUnwrap(LogicalMailboxID(rawValue: Data(repeating: 9, count: 32)))
        let before = try XCTUnwrap(relaunched.mailAuthority)
        await relaunched.selectMailAccount(unknown)
        XCTAssertEqual(relaunched.selectedMailAccountID, MobileTwoAccountNodeSender.graceLogicalMailboxID)
        XCTAssertTrue(relaunched.mailAuthority as AnyObject === before as AnyObject)
    }

    @MainActor
    func testMobileCachedReadOnlyMailAccessKeepsLastSelectionAndCannotMutate() async throws {
        let defaults = try Self.freshDefaults(#function)
        defaults.set(
            AccountWireCodec.encodeBase64URL(MobileTwoAccountNodeSender.graceLogicalMailboxID.rawValue),
            forKey: Self.selectionKey
        )
        let sender = MobileTwoAccountNodeSender()
        let expiry = Date().addingTimeInterval(3600)
        let model = MobileAccountModel.testing(
            nodeSender: sender, defaults: defaults,
            prepareSession: { _ in .offlineLease(expiresAt: expiry) }
        )
        model.prepare(now: Date())
        try await Self.waitUntil { model.mailAuthority != nil }

        XCTAssertEqual(model.selectedMailAccountID, MobileTwoAccountNodeSender.graceLogicalMailboxID)
        let authority = try XCTUnwrap(model.mailAuthority)
        XCTAssertNil(authority as? PlainpostNodeMailAuthority, "cached access must publish the read-only wrapper")
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
            XCTFail("cached read-only access must not mutate")
        } catch PlainpostError.permissionDenied {
        }
        let mutations = await sender.mutationLogicalMailboxIDs()
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertEqual(
            defaults.string(forKey: Self.selectionKey),
            AccountWireCodec.encodeBase64URL(MobileTwoAccountNodeSender.graceLogicalMailboxID.rawValue)
        )
    }

    @MainActor
    func testMobileOlderSyncNodeShowsOneAccountWithoutSwitcherOrUpdatePrompt() async throws {
        let defaults = try Self.freshDefaults(#function)
        let sender = MobileLegacySingleAccountNodeSender(identity: "ada@example.test")
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()

        XCTAssertEqual(model.mailAccounts.map(\.providerIdentity), ["ada@example.test"])
        XCTAssertEqual(model.selectedMailAccountID, MobileLegacySingleAccountNodeSender.logicalMailboxID)
        let authority = try XCTUnwrap(model.mailAuthority as? PlainpostNodeMailAuthority)
        _ = try await authority.snapshots.snapshot(after: nil, limit: 50)
        let paths = await sender.requests().map(\.path)
        XCTAssertTrue(paths.contains("/v1/snapshot"))
        XCTAssertFalse(paths.contains("/v1/mail/snapshot"))
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("message-1")]))
        let routed = try await sender.lastMutationLogicalMailboxID()
        XCTAssertEqual(routed, MobileLegacySingleAccountNodeSender.logicalMailboxID)
        // iOS never prompts to update an older Node; nothing is persisted either.
        XCTAssertNil(defaults.string(forKey: Self.selectionKey))
    }

    @MainActor
    func testMobileMailAccountRefreshDuringInFlightAuthorityPreparationIsFenced() async throws {
        let defaults = try Self.freshDefaults(#function)
        let base = MobileTwoAccountNodeSender()
        let sender = MobileScriptedNodeSender(base: base, gateFirstAccountsRead: true)
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)

        model.prepare(now: Date())
        await sender.waitUntilGateStarted()
        await model.refreshMailAccounts()
        let refreshed = try XCTUnwrap(model.mailAuthority)
        XCTAssertEqual(model.selectedMailAccountID, MobileTwoAccountNodeSender.adaLogicalMailboxID)

        await model.selectMailAccount(MobileTwoAccountNodeSender.graceLogicalMailboxID)
        let selected = try XCTUnwrap(model.mailAuthority as? PlainpostNodeMailAuthority)
        XCTAssertFalse(selected === refreshed as AnyObject)

        await sender.releaseGate()
        // The held catalog read reaches the Node only after the release; wait
        // for it in the request log, then for the stale preparation to finish.
        try await Self.waitUntilAsync {
            await base.requests().filter { $0.path == "/v1/mail/accounts" }.count == 2
        }
        await model.settleMailAuthorityPreparation()
        XCTAssertTrue(model.mailAuthority as AnyObject === selected)
        XCTAssertEqual(model.selectedMailAccountID, MobileTwoAccountNodeSender.graceLogicalMailboxID)

        // The runtime model fences preparation the same way: while the previous
        // runtime's shutdown is held, a newer preparation wins and the stale
        // preparation never builds or publishes a runtime.
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(recorder: recorder)
        await controller.prepare(readOnly: false, mailAuthority: refreshed, requiresMailAuthority: true)
        let shutdownGate = MobileLaunchShutdownGate()
        recorder.nextShutdownGate = shutdownGate
        let stale = Task { await controller.prepare(readOnly: false, mailAuthority: selected, requiresMailAuthority: true) }
        await shutdownGate.waitUntilStarted()
        await controller.prepare(readOnly: false, mailAuthority: refreshed, requiresMailAuthority: true)
        await shutdownGate.finish()
        await stale.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === refreshed as AnyObject)
        XCTAssertEqual(recorder.madeAuthorities, [ObjectIdentifier(refreshed as AnyObject), ObjectIdentifier(refreshed as AnyObject)])
        XCTAssertFalse(recorder.madeAuthorities.contains(ObjectIdentifier(selected)))
    }

    @MainActor
    func testMobileMailAccountNeedingAttentionIsSelectableReadOnly() async throws {
        let defaults = try Self.freshDefaults(#function)
        let sender = MobileTwoAccountNodeSender(graceState: .authenticationRequired)
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()
        let grace = try XCTUnwrap(model.mailAccounts.first { $0.logicalMailboxID == MobileTwoAccountNodeSender.graceLogicalMailboxID })

        await model.selectMailAccount(grace.logicalMailboxID)
        XCTAssertEqual(model.selectedMailAccountID, grace.logicalMailboxID)
        let authority = try XCTUnwrap(model.mailAuthority as? PlainpostNodeMailAuthority)
        _ = try await authority.snapshots.snapshot(after: nil, limit: 50)
        do {
            _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
            XCTFail("an account needing attention must stay read-only")
        } catch PlainpostError.permissionDenied {
        }
        let mutations = await sender.mutationLogicalMailboxIDs()
        XCTAssertTrue(mutations.isEmpty)
    }

    @MainActor
    func testMobileRemovingSelectedPrimaryAccountSelectsPromotedAccount() async throws {
        let defaults = try Self.freshDefaults(#function)
        let ada = MobileTwoAccountNodeSender.adaLogicalMailboxID
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let sender = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()
        await model.selectMailAccount(ada)
        XCTAssertNotNil(defaults.string(forKey: Self.selectionKey))

        await sender.removeAccount(ada)
        await model.refreshMailAccounts()

        XCTAssertEqual(model.mailAccounts.map(\.providerIdentity), ["grace@example.test"])
        XCTAssertEqual(model.mailAccounts.first?.isPrimary, true)
        XCTAssertEqual(model.selectedMailAccountID, grace)
        let authority = try XCTUnwrap(model.mailAuthority as? PlainpostNodeMailAuthority)
        XCTAssertEqual(authority.mailAccount?.logicalMailboxID, grace)
        XCTAssertEqual(authority.senderAddress, EmailAddress("grace@example.test"))
        XCTAssertNil(defaults.string(forKey: Self.selectionKey), "a removed account's selection is dropped")
        _ = try await authority.mutations.perform(.archive(messageIDs: [MessageID("gm2.0123456789abcdef0123456789abcdef01234567")]))
        let routed = try await sender.lastMutationLogicalMailboxID()
        XCTAssertEqual(routed, grace)
    }

    @MainActor
    func testMobileMailAccountSelectionIsPersistedPerPlainpostAccountAndPurged() async throws {
        let defaults = try Self.freshDefaults(#function)
        let ada = MobileTwoAccountNodeSender.adaLogicalMailboxID
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let first = MobileAccountModel.testingNodeAccountID
        let second = AccountID("ffeeddcc-bbaa-9988-7766-554433221100")
        let firstKey = MobileAccountModel.selectedMailAccountDefaultsKey(for: first)
        let secondKey = MobileAccountModel.selectedMailAccountDefaultsKey(for: second)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertNotEqual(firstKey, MobileAccountModel.legacySelectedMailAccountDefaultsKey)
        XCTAssertFalse(firstKey.contains(first.rawValue), "the key must not carry the raw account ID")

        // The old device-global key may belong to another Plainpost account: ignore and drop it.
        defaults.set(AccountWireCodec.encodeBase64URL(grace.rawValue), forKey: MobileAccountModel.legacySelectedMailAccountDefaultsKey)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults, accountID: first)
        await model.refreshMailAccounts()
        XCTAssertEqual(model.selectedMailAccountID, ada)
        XCTAssertNil(defaults.string(forKey: MobileAccountModel.legacySelectedMailAccountDefaultsKey))

        await model.selectMailAccount(grace)
        XCTAssertEqual(defaults.string(forKey: firstKey), AccountWireCodec.encodeBase64URL(grace.rawValue))

        // Another Plainpost account signed in on this device does not inherit it.
        let other = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults, accountID: second)
        await other.refreshMailAccounts()
        XCTAssertEqual(other.selectedMailAccountID, ada)
        await other.selectMailAccount(ada)

        defaults.set("unrelated", forKey: "plainpost.ios.selectedMailAccountTheme")
        defaults.set(AccountWireCodec.encodeBase64URL(grace.rawValue), forKey: MobileAccountModel.legacySelectedMailAccountDefaultsKey)
        MobileManagedDataPurger.clearMailAccountSelections(in: defaults)
        XCTAssertNil(defaults.string(forKey: firstKey))
        XCTAssertNil(defaults.string(forKey: secondKey))
        XCTAssertNil(defaults.string(forKey: MobileAccountModel.legacySelectedMailAccountDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: "plainpost.ios.selectedMailAccountTheme"), "unrelated")
    }

    @MainActor
    func testMobileNotificationPolicyMailboxesAndGoogleOnboardingFollowSelectedCatalogAccount() async throws {
        let defaults = try Self.freshDefaults(#function)
        let ada = MobileTwoAccountNodeSender.adaLogicalMailboxID
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let sender = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()
        let assigned: Set<Data> = [ada.rawValue, grace.rawValue]

        XCTAssertTrue(model.allowsGoogleProviderOnboarding)
        XCTAssertEqual(model.selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: assigned)?.map(\.logicalMailboxID), [ada])

        let statusReads = await sender.requests().filter { $0.path == "/v1/status" }.count
        await model.selectMailAccount(grace)
        // Rows for a non-primary account come from the authenticated catalog,
        // never from the primary-only /v1/status.
        let rows = try XCTUnwrap(model.selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: assigned))
        XCTAssertEqual(rows.map(\.logicalMailboxID), [grace])
        XCTAssertEqual(rows.map(\.displayName), ["grace@example.test"])
        let statusReadsAfter = await sender.requests().filter { $0.path == "/v1/status" }.count
        XCTAssertEqual(statusReadsAfter, statusReads)
        // Google onboarding configures the primary account only.
        XCTAssertFalse(model.allowsGoogleProviderOnboarding)
        // Without a Sync Node producer assignment the account has no row.
        XCTAssertEqual(model.selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: [ada.rawValue])?.isEmpty, true)

        // No catalog account (no Node accounts): the caller keeps the provider path.
        let unscoped = MobileAccountModel(prepareSession: { _ in .active })
        XCTAssertNil(unscoped.selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: assigned))
        XCTAssertTrue(unscoped.allowsGoogleProviderOnboarding)
    }

    // MARK: Notification opens and pending sends across account switches

    @MainActor
    func testMobilePendingUndoSendSurvivesAccountSwitchAndIsDeliveredOnceByItsOwner() async throws {
        let defaults = try Self.freshDefaults(#function)
        let ada = MobileTwoAccountNodeSender.adaLogicalMailboxID
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let gate = MobileUndoSendGate()
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(recorder: recorder, undoSendSleep: { _ in try await gate.wait() })
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        _ = try await adaAuthority.mutations.perform(.saveDraft(Self.draft(from: "ada@example.test")))
        // No strong reference to the runtime is kept here: only the controller owns it.
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        XCTAssertTrue(controller.isSendPending)
        await gate.waitUntilWaiting()

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task { await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true) }
        try await Self.waitUntil { controller.isDeferringForPendingSend }
        // The runtime that scheduled the send, and its Undo, stay until it settles.
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === adaAuthority as AnyObject)
        XCTAssertTrue(controller.isSendPending)
        XCTAssertTrue(recorder.shutdownAuthorities.isEmpty)

        await gate.release()
        await switching.value

        let sends = try await Self.sendOperations(base)
        XCTAssertEqual(sends, [ada], "delivered exactly once, by the account that scheduled it")
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertFalse(controller.isSendPending)
        XCTAssertFalse(controller.isDeferringForPendingSend)
        XCTAssertEqual(recorder.shutdownAuthorities, [ObjectIdentifier(adaAuthority as AnyObject)])
    }

    @MainActor
    func testMobilePendingUndoSendCanStillBeUndoneWhileAccountSwitchWaits() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let gate = MobileUndoSendGate()
        let controller = Self.fakeRuntimeController(undoSendSleep: { _ in try await gate.wait() })
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        _ = try await adaAuthority.mutations.perform(.saveDraft(Self.draft(from: "ada@example.test")))
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        await gate.waitUntilWaiting()

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task { await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true) }
        try await Self.waitUntil { controller.isDeferringForPendingSend }

        XCTAssertEqual(controller.runtime?.undoSend.undoLatestSend(), Self.restoreSnapshot)
        await switching.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertFalse(controller.isSendPending)

        // The undone delivery wakes cancelled and never reaches the Node.
        await gate.release()
        try await Self.waitUntilAsync { await gate.cancelledWakeups == 1 }
        let sends = try await Self.sendOperations(base)
        XCTAssertTrue(sends.isEmpty)
    }

    /// Task 10 ledger: an archive the user starts while a switch waits on a send must commit
    /// with the runtime that shows it, so the host's commit runs after the wait, right before
    /// the swap, not before the wait begins.
    ///
    /// This passes its own `beforeReplacing` closure to `controller.prepare`, so it proves the
    /// controller calls that hook at the right point in the sequence. It doesn't prove that
    /// `MobileMailRootView`'s `.task` actually passes `{ await mobileEnvironment
    /// .commitPendingActions() }` as that argument (`MobileMailRootView.swift:187`), or that no
    /// other call there commits before `prepare` runs. That's a SwiftUI view's own wiring, which
    /// needs a hosted view to exercise and has no simulator-free way to test here (task-3-review
    /// Minor 7, Ruling 8 — the same limit as the deleted source-text check this task's commit
    /// history replaced elsewhere).
    @MainActor
    func testMobileSwitchCommitsMailActionsAfterItsWaitAndBeforeTheSwap() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let gate = MobileUndoSendGate()
        let controller = Self.fakeRuntimeController(undoSendSleep: { _ in try await gate.wait() })
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        await gate.waitUntilWaiting()

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let commits = MobileCommitRecorder()
        let switching = Task {
            await controller.prepare(
                readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true,
                beforeReplacing: { commits.record(controller.runtime?.mailAuthority) }
            )
        }
        try await Self.waitUntil { controller.isDeferringForPendingSend }
        XCTAssertTrue(commits.authorities.isEmpty, "nothing commits while the switch waits; Undo still works")

        XCTAssertEqual(controller.runtime?.undoSend.undoLatestSend(), Self.restoreSnapshot)
        await switching.value
        XCTAssertEqual(commits.authorities, [ObjectIdentifier(adaAuthority as AnyObject)], "once, with the old runtime still current")
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        await gate.release()
    }

    @MainActor
    func testMobileFirstPreparationHasNothingToCommit() async throws {
        let commits = MobileCommitRecorder()
        let controller = Self.fakeRuntimeController()
        await controller.prepare(
            readOnly: false, mailAuthority: nil, requiresMailAuthority: false,
            beforeReplacing: { commits.record(controller.runtime?.mailAuthority) }
        )
        XCTAssertNotNil(controller.runtime)
        XCTAssertTrue(commits.authorities.isEmpty, "no runtime was replaced")
    }

    @MainActor
    func testMobileFailedSendKeepsDeferredSwitchAndItsNoticeUntilDismissed() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let gate = MobileUndoSendGate()
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(
            recorder: recorder, undoSendSleep: { _ in try await gate.wait() }, sender: MobileFailingComposerSender()
        )
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        await gate.waitUntilWaiting()

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task { await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(graceAuthority)) }
        try await Self.waitUntil { controller.switchHold == .finishingSend }

        // The delivery fails during the wait: the runtime, and its failure
        // notice with the draft restore, stay until the user acts on it.
        await gate.release()
        try await Self.waitUntil { controller.switchHold == .sendFailed }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.switchHold, .sendFailed)
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === adaAuthority as AnyObject)
        XCTAssertEqual(controller.runtime?.undoSend.snackbarState, .failed(snapshot: Self.restoreSnapshot))
        XCTAssertTrue(recorder.shutdownAuthorities.isEmpty)

        controller.dismissFailedSend()
        await switching.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertNil(controller.switchHold)
        XCTAssertEqual(recorder.shutdownAuthorities, [ObjectIdentifier(adaAuthority as AnyObject)])
        let sends = try await Self.sendOperations(base)
        XCTAssertTrue(sends.isEmpty)
    }

    @MainActor
    func testMobileEarlierFailedSendHoldsSwitchUntilItsDraftIsReopened() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let controller = Self.fakeRuntimeController(undoSendSleep: { _ in }, sender: MobileFailingComposerSender())
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntil { controller.runtime?.hasFailedSend == true }
        XCTAssertNil(controller.switchHold, "a failure alone holds nothing until a replacement is requested")

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task { await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(graceAuthority)) }
        try await Self.waitUntil { controller.switchHold == .sendFailed }
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === adaAuthority as AnyObject)

        // Reopening the draft (the notice's restore) is the user's other answer.
        XCTAssertEqual(controller.runtime?.undoSend.restoreFailedSend(), Self.restoreSnapshot)
        await switching.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertNil(controller.switchHold)
    }

    /// A failed send's draft is already saved on the Node. Only the user's own
    /// account switch waits for the failure to be acknowledged; a read-only
    /// flip, a lost authority or a refreshed session replaces the runtime.
    @MainActor
    func testMobileFailedSendReleasesHoldForReplacementsThatAreNotAUserSwitch() async throws {
        let defaults = try Self.freshDefaults(#function)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        XCTAssertFalse(model.isUserSelectedMailAuthority(adaAuthority), "the initial binding is not a user switch")
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(recorder: recorder, undoSendSleep: { _ in }, sender: MobileFailingComposerSender())
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)

        func failSend() async throws -> MobileFakeMailRuntime {
            let runtime = try XCTUnwrap(controller.runtime)
            XCTAssertEqual(runtime.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
            try await Self.waitUntil { runtime.hasFailedSend }
            return runtime
        }

        // A read-only flip on the same account.
        var failed = try await failSend()
        let flip = Task { await controller.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(adaAuthority)) }
        try await Self.waitUntil { controller.runtime !== failed && controller.runtime != nil }
        await flip.value
        XCTAssertNil(controller.switchHold)

        // A session refresh: another authority for the same account that no
        // user switch bound.
        let refreshed = try PlainpostNodeMailAuthorityFactory.make(
            client: NodeSyncClient(sender: MobileTwoAccountNodeSender()), accountID: MobileAccountModel.testingNodeAccountID,
            mailAccount: try XCTUnwrap(model.mailAccounts.first), multiAccount: true, access: .authorized
        )
        failed = try await failSend()
        let refresh = Task { await controller.prepare(readOnly: false, mailAuthority: refreshed, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(refreshed)) }
        try await Self.waitUntil { controller.runtime !== failed && controller.runtime != nil }
        await refresh.value
        XCTAssertNil(controller.switchHold)

        // The authority is lost.
        failed = try await failSend()
        let lost = Task { await controller.prepare(readOnly: false, mailAuthority: nil, requiresMailAuthority: true) }
        try await Self.waitUntil { controller.runtime == nil && controller.failure != nil }
        await lost.value
        XCTAssertNil(controller.switchHold)
        XCTAssertEqual(recorder.shutdownAuthorities.count, 3, "every replaced runtime was shut down")
    }

    /// A failed send released by a replacement that is not the user's switch
    /// loses its runtime and its "Couldn't send" notice. The controller keeps
    /// a notice above the new runtime until it is dismissed, whether the send
    /// had already failed or failed while the replacement waited on it.
    @MainActor
    func testMobileFailedSendReleasedByAReplacementLeavesANoticeUntilDismissed() async throws {
        let defaults = try Self.freshDefaults(#function)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let gate = MobileUndoSendGate()
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(
            recorder: recorder, undoSendSleep: { _ in try await gate.wait() }, sender: MobileFailingComposerSender()
        )
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertFalse(controller.showsReleasedFailedSendNotice)

        // Already failed when the read-only flip arrives: released at once.
        await gate.release()
        var failed = try XCTUnwrap(controller.runtime)
        XCTAssertEqual(failed.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntil { failed.hasFailedSend }
        XCTAssertFalse(controller.showsReleasedFailedSendNotice, "a failure alone publishes nothing while its runtime shows it")
        await controller.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true, isUserAccountSwitch: false)
        XCTAssertTrue(controller.runtime != nil && controller.runtime !== failed)
        XCTAssertNil(controller.switchHold)
        XCTAssertTrue(controller.showsReleasedFailedSendNotice)
        XCTAssertEqual(controller.releasedFailedSend?.providerIdentity, "ada@example.test")
        controller.dismissReleasedFailedSendNotice()
        XCTAssertFalse(controller.showsReleasedFailedSendNotice)

        // Still in its undo window when a lost authority arrives: the
        // replacement waits, the delivery fails, and the replacement proceeds.
        let heldGate = MobileUndoSendGate()
        let heldController = Self.fakeRuntimeController(
            recorder: recorder, undoSendSleep: { _ in try await heldGate.wait() }, sender: MobileFailingComposerSender()
        )
        await heldController.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        failed = try XCTUnwrap(heldController.runtime)
        XCTAssertEqual(failed.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        await heldGate.waitUntilWaiting()
        let lost = Task { await heldController.prepare(readOnly: false, mailAuthority: nil, requiresMailAuthority: true) }
        try await Self.waitUntil { heldController.switchHold == .finishingSend }
        XCTAssertFalse(heldController.showsReleasedFailedSendNotice)
        await heldGate.release()
        await lost.value
        XCTAssertNil(heldController.runtime)
        XCTAssertNil(heldController.switchHold)
        XCTAssertTrue(heldController.showsReleasedFailedSendNotice)
        heldController.dismissReleasedFailedSendNotice()
        XCTAssertFalse(heldController.showsReleasedFailedSendNotice)
    }

    /// A failed-send hold keeps the old runtime alive and writable while the
    /// user's switch waits. Once the Node stops listing that runtime's
    /// account, holding it serves an account that no longer exists: release it
    /// like a lost authority, leave the notice, and build the new runtime.
    @MainActor
    func testMobileFailedSendHoldIsReleasedWhenTheNodeStopsListingItsAccount() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let listed = MobileListedAccountsBox([
            MobileTwoAccountNodeSender.adaLogicalMailboxID, grace,
        ])
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(recorder: recorder, undoSendSleep: { _ in }, sender: MobileFailingComposerSender())
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        let failed = try XCTUnwrap(controller.runtime)
        XCTAssertEqual(failed.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntil { failed.hasFailedSend }

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task {
            await controller.prepare(
                readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true,
                isUserAccountSwitch: model.isUserSelectedMailAuthority(graceAuthority),
                isAccountListed: { listed.contains($0) }
            )
        }
        // Bounded: a hold that never releases must fail, not hang the suite.
        defer { switching.cancel() }
        try await Self.waitUntil { controller.switchHold == .sendFailed }
        XCTAssertTrue(controller.runtime === failed, "the held runtime is still ada's")

        // Ada is removed on the Mac and disappears from the Node's catalog.
        listed.remove(MobileTwoAccountNodeSender.adaLogicalMailboxID)
        try await Self.waitUntil { controller.switchHold == nil }
        await switching.value

        XCTAssertNil(controller.switchHold)
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertEqual(recorder.shutdownAuthorities, [ObjectIdentifier(adaAuthority as AnyObject)])
        XCTAssertTrue(controller.showsReleasedFailedSendNotice, "the released failure still needs its notice")
    }

    /// The notice names the account whose send failed, so "It's in Drafts"
    /// points at the right Drafts after a switch, and it is announced once
    /// when it appears rather than on every reappearance.
    @MainActor
    func testMobileReleasedFailedSendNoticeNamesTheAccountAndAnnouncesOnce() async throws {
        let defaults = try Self.freshDefaults(#function)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let announcer = MobileAccessibilityAnnouncementRecorder()
        let controller = Self.fakeRuntimeController(
            undoSendSleep: { _ in }, sender: MobileFailingComposerSender(), announce: { announcer.append($0) })
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        let failed = try XCTUnwrap(controller.runtime)
        XCTAssertEqual(failed.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntil { failed.hasFailedSend }
        XCTAssertTrue(announcer.messages.isEmpty)

        // A read-only flip releases the runtime and its own notice.
        await controller.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true)
        let notice = try XCTUnwrap(controller.releasedFailedSend)
        XCTAssertEqual(notice.providerIdentity, "ada@example.test")
        XCTAssertTrue(notice.statusText.contains("ada@example.test"), notice.statusText)
        XCTAssertTrue(notice.statusText.contains("Drafts"), notice.statusText)
        XCTAssertEqual(announcer.messages, [notice.statusText])

        // The notice survives later replacements, which rebuild the view it
        // sits above. Only the release announces, so it is never repeated.
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertTrue(controller.showsReleasedFailedSendNotice)
        XCTAssertEqual(announcer.messages, [notice.statusText], "the notice is announced when it appears, not on every rebuild")

        controller.dismissReleasedFailedSendNotice()
        XCTAssertNil(controller.releasedFailedSend)
        XCTAssertEqual(announcer.messages.count, 1)
    }

    /// A delivered send, and a failure the user's own switch waited on and
    /// the user acknowledged, leave no released-send notice.
    @MainActor
    func testMobileReleasedFailedSendNoticeIsNotShownForUserSwitchesOrDeliveredSends() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)

        // Delivered, then a read-only flip.
        let delivered = Self.fakeRuntimeController(undoSendSleep: { _ in })
        await delivered.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        _ = try await adaAuthority.mutations.perform(.saveDraft(Self.draft(from: "ada@example.test")))
        let deliveredRuntime = try XCTUnwrap(delivered.runtime)
        XCTAssertEqual(deliveredRuntime.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntilAsync { !deliveredRuntime.isSendPending }
        await delivered.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertTrue(delivered.runtime !== deliveredRuntime)
        XCTAssertFalse(deliveredRuntime.hasFailedSend)
        XCTAssertFalse(delivered.showsReleasedFailedSendNotice)

        // Failed, then the user's switch holds until the failure is dismissed.
        let controller = Self.fakeRuntimeController(undoSendSleep: { _ in }, sender: MobileFailingComposerSender())
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        try await Self.waitUntil { controller.runtime?.hasFailedSend == true }
        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        let switching = Task { await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(graceAuthority)) }
        try await Self.waitUntil { controller.switchHold == .sendFailed }
        XCTAssertFalse(controller.showsReleasedFailedSendNotice)
        controller.dismissFailedSend()
        await switching.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)
        XCTAssertFalse(controller.showsReleasedFailedSendNotice)
    }

    /// A user switch is a transition to another account. Once the user has
    /// switched to grace, rebuilding grace's runtime (a read-only flip on the
    /// same authority, or a refreshed grace authority) is not a user switch
    /// even though the authority is still the one the user selected.
    @MainActor
    func testMobileRebuildingTheSwitchedToAccountsRuntimeIsNotAUserSwitch() async throws {
        let defaults = try Self.freshDefaults(#function)
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let recorder = MobileFakeRuntimeRecorder()
        let controller = Self.fakeRuntimeController(recorder: recorder, undoSendSleep: { _ in }, sender: MobileFailingComposerSender())
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        XCTAssertTrue(model.isUserSelectedMailAuthority(graceAuthority))
        await controller.prepare(readOnly: false, mailAuthority: graceAuthority, requiresMailAuthority: true, isUserAccountSwitch: true)
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === graceAuthority as AnyObject)

        func failSend() async throws -> MobileFakeMailRuntime {
            let runtime = try XCTUnwrap(controller.runtime)
            XCTAssertEqual(runtime.undoSend.schedule(draft: Self.draft(from: "grace@example.test"), restoring: Self.restoreSnapshot), true)
            try await Self.waitUntil { runtime.hasFailedSend }
            return runtime
        }

        // A read-only flip on the switched-to authority, which the model
        // still reports as the user's selection.
        var failed = try await failSend()
        XCTAssertTrue(model.isUserSelectedMailAuthority(graceAuthority))
        let flip = Task { await controller.prepare(readOnly: true, mailAuthority: graceAuthority, requiresMailAuthority: true, isUserAccountSwitch: model.isUserSelectedMailAuthority(graceAuthority)) }
        try await Self.waitUntil { controller.runtime !== failed && controller.runtime != nil }
        await flip.value
        XCTAssertNil(controller.switchHold)

        // A refreshed grace authority, even if flagged as the user's switch.
        let refreshed = try PlainpostNodeMailAuthorityFactory.make(
            client: NodeSyncClient(sender: MobileTwoAccountNodeSender()), accountID: MobileAccountModel.testingNodeAccountID,
            mailAccount: try XCTUnwrap(model.mailAccounts.first { $0.logicalMailboxID == grace }), multiAccount: true, access: .authorized
        )
        failed = try await failSend()
        let refresh = Task { await controller.prepare(readOnly: false, mailAuthority: refreshed, requiresMailAuthority: true, isUserAccountSwitch: true) }
        try await Self.waitUntil { controller.runtime !== failed && controller.runtime != nil }
        await refresh.value
        XCTAssertNil(controller.switchHold)
        XCTAssertEqual(recorder.shutdownAuthorities.count, 3, "ada's runtime and both of grace's failed runtimes were shut down")

        // A user switch back to ada, another account, still holds.
        failed = try await failSend()
        let back = Task { await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true, isUserAccountSwitch: true) }
        try await Self.waitUntil { controller.switchHold == .sendFailed }
        XCTAssertTrue(controller.runtime === failed)
        controller.dismissFailedSend()
        await back.value
        XCTAssertTrue(controller.runtime?.mailAuthority as AnyObject === adaAuthority as AnyObject)
    }

    @MainActor
    func testMobileOnlyTheSwitcherSelectionIsAUserAccountSwitch() async throws {
        let defaults = try Self.freshDefaults(#function)
        let graceMessageID = "gm2.0123456789abcdef0123456789abcdef01234567"
        let ada = MobileTwoAccountNodeSender.adaLogicalMailboxID
        let grace = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let base = MobileTwoAccountNodeSender()
        let sender = MobileScriptedNodeSender(base: base, messages: [grace: [Self.nodeMessage(id: graceMessageID)]])
        let model = MobileAccountModel.testing(nodeSender: sender, defaults: defaults)
        await model.refreshMailAccounts()
        XCTAssertFalse(model.isUserSelectedMailAuthority(model.mailAuthority))

        await model.selectMailAccount(grace)
        let graceAuthority = try XCTUnwrap(model.mailAuthority)
        XCTAssertTrue(model.isUserSelectedMailAuthority(graceAuthority))
        XCTAssertFalse(model.isUserSelectedMailAuthority(nil))

    }

    @MainActor
    func testMobileControllerPublishesTheCurrentRuntimesUnsavedComposer() async throws {
        let defaults = try Self.freshDefaults(#function)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let controller = Self.fakeRuntimeController()
        XCTAssertFalse(controller.hasUnsavedComposer)
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        let ada = try XCTUnwrap(controller.runtime)

        ada.composerActivity.update(hasUnsavedOpenComposer: true)
        XCTAssertTrue(controller.hasUnsavedComposer)
        ada.composerActivity.update(hasUnsavedOpenComposer: false)
        XCTAssertFalse(controller.hasUnsavedComposer)

        // A replacement follows the new runtime, never the old one.
        ada.composerActivity.update(hasUnsavedOpenComposer: true)
        await model.selectMailAccount(MobileTwoAccountNodeSender.graceLogicalMailboxID)
        await controller.prepare(readOnly: false, mailAuthority: model.mailAuthority, requiresMailAuthority: true)
        XCTAssertFalse(controller.hasUnsavedComposer)
        ada.composerActivity.update(hasUnsavedOpenComposer: false)
        ada.composerActivity.update(hasUnsavedOpenComposer: true)
        XCTAssertFalse(controller.hasUnsavedComposer)
        controller.runtime?.composerActivity.update(hasUnsavedOpenComposer: true)
        XCTAssertTrue(controller.hasUnsavedComposer)
        await controller.shutdown()
        XCTAssertFalse(controller.hasUnsavedComposer)
    }

    /// A notification tap rebuilds the mail session and may switch to the
    /// message's owner. Both discard an open composer, so the tap waits until
    /// the composer is saved or closed.
    @MainActor
    func testMobileNotificationTapWaitsUntilTheUnsavedComposerIsSavedOrClosed() async throws {
        let defaults = try Self.freshDefaults(#function)
        let prepares = MobilePrepareCounter()
        let model = MobileAccountModel.testing(
            nodeSender: MobileTwoAccountNodeSender(), defaults: defaults,
            prepareSession: { _ in await prepares.increment(); return .active }
        )
        await model.refreshMailAccounts()
        var opened: [MobileNotificationOpenRequest] = []
        let observer = NotificationCenter.default.addObserver(forName: .plainpostOpenNotification, object: nil, queue: nil) { notification in
            guard let request = notification.object as? MobileNotificationOpenRequest else { return }
            MainActor.assumeIsolated { opened.append(request) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let request = MobileNotificationOpenRequest(token: "token-1", logicalMailboxID: MobileTwoAccountNodeSender.graceLogicalMailboxID)

        model.setMailComposerHasUnsavedChanges(true)
        let authority = model.mailAuthority
        model.handleNotificationTap(request)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(model.hasDeferredNotificationOpen)
        XCTAssertTrue(model.mailAuthority as AnyObject === authority as AnyObject, "the session was not rebuilt under the composer")
        let preparedBefore = await prepares.count
        XCTAssertEqual(preparedBefore, 0)

        // A newer tap replaces the waiting one.
        let newer = MobileNotificationOpenRequest(token: "token-2", logicalMailboxID: nil)
        model.handleNotificationTap(newer)
        model.setMailComposerHasUnsavedChanges(false)
        XCTAssertEqual(opened, [newer])
        XCTAssertFalse(model.hasDeferredNotificationOpen)

        model.setMailComposerHasUnsavedChanges(true)
        model.setMailComposerHasUnsavedChanges(false)
        XCTAssertEqual(opened, [newer], "a waiting tap opens once")
    }

    func testMobileSwitchHoldStatusNamesTheWaitAndOffersDismissOnlyForFailure() {
        XCTAssertEqual(MobileMailRuntimeSwitchHold.finishingSend.statusText, "Finishing send…")
        XCTAssertFalse(MobileMailRuntimeSwitchHold.finishingSend.canDismiss)
        XCTAssertEqual(MobileMailRuntimeSwitchHold.sendFailed.statusText, "Couldn’t send. Open the draft or dismiss to switch.")
        XCTAssertTrue(MobileMailRuntimeSwitchHold.sendFailed.canDismiss)
        XCTAssertEqual(MobileMailRuntimeSwitchHold.statusIdentifier, "mail-account.switch-hold")
        XCTAssertEqual(MobileMailRuntimeSwitchHold.dismissIdentifier, "mail-account.switch-hold.dismiss")
    }

    @MainActor
    func testMobilePendingSendSwitchHoldIsPublishedUntilTheSendSettles() async throws {
        let defaults = try Self.freshDefaults(#function)
        let base = MobileTwoAccountNodeSender()
        let model = MobileAccountModel.testing(nodeSender: base, defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        _ = try await adaAuthority.mutations.perform(.saveDraft(Self.draft(from: "ada@example.test")))
        let gate = MobileUndoSendGate()
        let controller = Self.fakeRuntimeController(undoSendSleep: { _ in try await gate.wait() })
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertNil(controller.switchHold)
        XCTAssertEqual(controller.runtime?.undoSend.schedule(draft: Self.draft(from: "ada@example.test"), restoring: Self.restoreSnapshot), true)
        await gate.waitUntilWaiting()

        // A readOnly flip on the same account waits too, and says so.
        let flipping = Task { await controller.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true) }
        try await Self.waitUntil { controller.switchHold == .finishingSend }
        XCTAssertTrue(controller.isDeferringForPendingSend)
        await gate.release()
        await flipping.value
        XCTAssertNil(controller.switchHold)
        XCTAssertFalse(controller.isDeferringForPendingSend)
    }

    @MainActor
    func testMobileRuntimeGenerationAdvancesWheneverThePublishedRuntimeChanges() async throws {
        let defaults = try Self.freshDefaults(#function)
        let model = MobileAccountModel.testing(nodeSender: MobileTwoAccountNodeSender(), defaults: defaults)
        await model.refreshMailAccounts()
        let adaAuthority = try XCTUnwrap(model.mailAuthority)
        let controller = Self.fakeRuntimeController()
        var generations: [UInt64] = [controller.runtimeGeneration]

        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        generations.append(controller.runtimeGeneration)
        // The same inputs keep the runtime and its view identity.
        await controller.prepare(readOnly: false, mailAuthority: adaAuthority, requiresMailAuthority: true)
        XCTAssertEqual(controller.runtimeGeneration, generations.last)
        // The same authority rebuilt read-only is a new runtime: a new identity.
        await controller.prepare(readOnly: true, mailAuthority: adaAuthority, requiresMailAuthority: true)
        generations.append(controller.runtimeGeneration)
        await model.selectMailAccount(MobileTwoAccountNodeSender.graceLogicalMailboxID)
        await controller.prepare(readOnly: true, mailAuthority: model.mailAuthority, requiresMailAuthority: true)
        generations.append(controller.runtimeGeneration)
        await controller.shutdown()
        generations.append(controller.runtimeGeneration)

        XCTAssertEqual(generations, generations.sorted())
        XCTAssertEqual(Set(generations).count, generations.count, "every published runtime has its own identity")
    }

    @MainActor
    func testMobileRuntimeScopedContentDropsStateObjectsOfThePreviousRuntime() async throws {
        let host = MobileScopedHost()
        let hosting = UIHostingController(rootView: MobileScopedHostView(host: host))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        }
        window.rootViewController = hosting
        window.isHidden = false
        defer { window.isHidden = true }
        func render() async throws {
            let before = host.renderedTags.count
            try await Self.waitUntil {
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                return host.renderedTags.count > before
            }
        }
        try await render()
        XCTAssertEqual(host.renderedTags.last, 1)

        // A new runtime under the same identity keeps the old state objects:
        // the failure the identity exists to prevent.
        host.runtimeTag = 2
        try await render()
        XCTAssertEqual(host.renderedTags.last, 1)

        // A new generation rebuilds them from the new runtime, with no
        // intermediate empty render.
        host.runtimeTag = 3
        host.generation = 2
        try await render()
        XCTAssertEqual(host.renderedTags.last, 3)
    }

    func testMobileAuthorityReferenceNeverMatchesAReleasedAuthorityAtAReusedAddress() {
        let reference: MobileMailAuthorityReference
        let releasedAddress: ObjectIdentifier
        do {
            let authority = MobileAuthorityStandIn()
            reference = MobileMailAuthorityReference(object: authority)
            releasedAddress = ObjectIdentifier(authority)
            XCTAssertTrue(reference.refers(toObject: authority))
            XCTAssertFalse(reference.refers(toObject: MobileAuthorityStandIn()))
            XCTAssertFalse(reference.refers(toObject: nil))
        }
        // Allocate until an object lands on the released address (usually at once).
        var sawReuse = false
        for _ in 0..<1_000 {
            let candidate = MobileAuthorityStandIn()
            XCTAssertFalse(reference.refers(toObject: candidate))
            if ObjectIdentifier(candidate) == releasedAddress {
                sawReuse = true
                break
            }
        }
        if !sawReuse { print("note: allocator did not reuse the released address") }

        let unbound = MobileMailAuthorityReference(object: nil)
        XCTAssertTrue(unbound.refers(toObject: nil))
        XCTAssertFalse(unbound.refers(toObject: MobileAuthorityStandIn()))
    }

    func testMobileNotificationOpenRequestReadsLogicalMailboxFromEnvelope() throws {
        let mailbox = MobileTwoAccountNodeSender.graceLogicalMailboxID
        let producer = P256.Signing.PrivateKey()
        let recipient = P256.KeyAgreement.PrivateKey()
        let digest = Data(repeating: 0x5A, count: 32)
        let wire = try RichNotificationEnvelope.seal(
            recipientRoutingHandle: Data(repeating: 0x11, count: 32),
            recipientAgreementPublicKey: recipient.publicKey.x963Representation,
            recipientDeviceID: try AccountDeviceID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            producerDeviceID: try AccountDeviceID("11111111-2222-4333-8444-555555555555"),
            logicalMailboxID: mailbox.rawValue,
            trustEpoch: 1, trustRevision: 1, producerAssignmentGeneration: 1,
            trustHead: digest, policyVersion: 1, messageDigest: digest,
            replayID: Data(repeating: 0x6B, count: 32), collapseDigest: digest,
            mailboxToken: "mailbox", threadToken: "thread", messageToken: "message",
            sender: "Grace", subject: "Hello", preview: "", badge: 1,
            producerSigningPublicKey: producer.publicKey.x963Representation,
            sign: { try producer.signature(for: $0).rawRepresentation }
        )
        let request = try XCTUnwrap(MobileNotificationOpenRequest(userInfo: [
            "plainpost.deepLinkToken": "token-1",
            "plainpost.envelope": AccountWireCodec.encodeBase64URL(wire),
        ]))
        XCTAssertEqual(request.token, "token-1")
        XCTAssertEqual(request.logicalMailboxID, mailbox)

        let withoutEnvelope = try XCTUnwrap(MobileNotificationOpenRequest(userInfo: ["plainpost.deepLinkToken": "token-2"]))
        XCTAssertNil(withoutEnvelope.logicalMailboxID)
        let malformed = try XCTUnwrap(MobileNotificationOpenRequest(userInfo: ["plainpost.deepLinkToken": "token-3", "plainpost.envelope": "not-an-envelope"]))
        XCTAssertNil(malformed.logicalMailboxID)
        XCTAssertNil(MobileNotificationOpenRequest(userInfo: [:]))
    }

    private static let selectionKey = MobileAccountModel.selectedMailAccountDefaultsKey(for: MobileAccountModel.testingNodeAccountID)

    private static let restoreSnapshot = ComposerRestoreSnapshot(
        to: "recipient@example.test", cc: "", bcc: "", subject: "Pending", bodyMarkdown: "body",
        presentationMode: .newMessage, replyContext: nil, includesQuotedHistory: false
    )

    private static func draft(from: String) -> Draft {
        Draft(
            id: DraftID("pending-send"), accountID: AccountID("plainpost-account"),
            from: EmailAddress(from), to: [EmailAddress("recipient@example.test")],
            cc: [], bcc: [], subject: "Pending", bodyPlain: "body", createdBy: "test",
            aiGenerated: false, sourceThreadID: nil
        )
    }

    private static func fakeRuntimeController(
        recorder: MobileFakeRuntimeRecorder = MobileFakeRuntimeRecorder(),
        undoSendSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        sender: (any DirectComposerSending)? = nil,
        announce: @escaping @MainActor (String) -> Void = { _ in }
    ) -> MobileMailRuntimeController<MobileFakeMailRuntime> {
        MobileMailRuntimeController(
            makeRuntime: { _, authority in
                MobileFakeMailRuntime(mailAuthority: authority, recorder: recorder, undoSendSleep: undoSendSleep, sender: sender)
            },
            pollInterval: .milliseconds(10),
            announce: announce
        )
    }

    /// Logical mailboxes of every signed send operation sent to the Node, in order.
    private static func sendOperations(_ sender: MobileTwoAccountNodeSender) async throws -> [LogicalMailboxID] {
        try await sender.requests().filter { $0.path == "/v1/mutations" }.compactMap {
            let operation = try NodeSyncCodec.decodeOperation(NodeSyncCodec.decodeMutationRequest($0.body).canonicalOperation)
            guard case .send = operation.unsigned.operation else { return nil }
            return operation.unsigned.logicalMailboxID
        }
    }

    /// Logical mailboxes of every scoped snapshot read, in request order.
    private static func snapshotReads(_ sender: MobileTwoAccountNodeSender) async throws -> [LogicalMailboxID] {
        try await sender.requests().filter { $0.path == "/v1/mail/snapshot" }.map {
            try NodeSyncMailModeCodec.decodeAccountSnapshotRequest($0.body).logicalMailboxID
        }
    }

    private static func waitUntilAsync(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("condition not met before timeout")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "plainpost.tests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("condition not met before timeout")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func nodeMessage(id: String) -> NodeSyncMessage {
        NodeSyncMessage(
            attachments: [], bcc: [], cc: [], flags: [],
            from: [NodeSyncAddress(displayName: "Sender", mailbox: "sender@example.com")],
            htmlBody: NodeSyncBody(state: .absent, value: nil), id: id,
            inReplyTo: [], labels: ["inbox"], receivedAt: "2026-09-14T10:00:00Z", references: [],
            replyTo: [], sentAt: "2026-09-14T10:00:00Z", subject: "Subject \(id)",
            textBody: NodeSyncBody(state: .complete, value: "Body"), threadID: "thread-\(id)",
            to: [NodeSyncAddress(displayName: "Recipient", mailbox: "recipient@example.com")]
        )
    }
}

/// Wraps the C7 copy without changing it: serves per-account snapshot
/// messages (after the copy has enforced ownership) and can hold the first
/// account-catalog read or the first scoped snapshot read open to exercise
/// fencing.
private actor MobileScriptedNodeSender: NodeSessionRequestSending, NodeMutationOperationSigning, NodeAuthorityEpochUpdating {
    private let base: MobileTwoAccountNodeSender
    private let messages: [LogicalMailboxID: [NodeSyncMessage]]
    private var gatedPath: String?
    private var gateStarted = false
    private var gateReleased = false
    private var gate: CheckedContinuation<Void, Never>?

    init(
        base: MobileTwoAccountNodeSender,
        messages: [LogicalMailboxID: [NodeSyncMessage]] = [:],
        gateFirstAccountsRead: Bool = false,
        gateFirstSnapshotRead: Bool = false
    ) {
        self.base = base
        self.messages = messages
        gatedPath = gateFirstAccountsRead ? "/v1/mail/accounts" : (gateFirstSnapshotRead ? "/v1/mail/snapshot" : nil)
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        if path == gatedPath {
            gatedPath = nil
            gateStarted = true
            if !gateReleased { await withCheckedContinuation { gate = $0 } }
        }
        let response = try await base.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
        guard path == "/v1/mail/snapshot", response.statusCode == 200 else { return response }
        let request = try NodeSyncMailModeCodec.decodeAccountSnapshotRequest(body)
        let page = try NodeSyncSnapshotPage(messages: messages[request.logicalMailboxID] ?? [], nextCursor: "", revision: "1")
        return NodeHTTPResponse(statusCode: 200, url: response.url, headers: [:], body: try NodeSyncCodec.encodeSnapshotPage(page))
    }

    nonisolated func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        try base.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }

    nonisolated func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        try base.signMutation(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, issuedAt: issuedAt)
    }

    /// Bounded, so a regression that never reaches the gate fails instead of hanging.
    func waitUntilGateStarted(timeout: Duration = .seconds(3)) async {
        await mobileWaitOrFail("gated Node request never arrived", timeout: timeout) { gateStarted }
    }

    func releaseGate() {
        gateReleased = true
        gate?.resume()
        gate = nil
    }
}

/// The Node's current account catalog, as the mail root reads it while a
/// runtime replacement waits.
@MainActor
private final class MobileListedAccountsBox {
    private var listed: Set<LogicalMailboxID>

    init(_ listed: Set<LogicalMailboxID>) { self.listed = listed }

    func contains(_ id: LogicalMailboxID) -> Bool { listed.contains(id) }

    func remove(_ id: LogicalMailboxID) { listed.remove(id) }
}

/// VoiceOver announcements the runtime controller posted.
@MainActor
private final class MobileAccessibilityAnnouncementRecorder {
    private(set) var messages: [String] = []

    func append(_ message: String) { messages.append(message) }
}

/// Records what the runtime model builds and shuts down; can hold the next
/// shutdown open to exercise preparation fencing.
@MainActor
private final class MobileFakeRuntimeRecorder {
    private(set) var madeAuthorities: [ObjectIdentifier?] = []
    private(set) var shutdownAuthorities: [ObjectIdentifier?] = []
    var nextShutdownGate: MobileLaunchShutdownGate?

    func made(_ authority: (any PlainpostMailAuthority)?) {
        madeAuthorities.append(authority.map { ObjectIdentifier($0 as AnyObject) })
    }

    func shutdown(_ authority: (any PlainpostMailAuthority)?) async {
        shutdownAuthorities.append(authority.map { ObjectIdentifier($0 as AnyObject) })
        if let gate = nextShutdownGate {
            nextShutdownGate = nil
            await gate.drain()
        }
    }
}

/// A mail runtime stand-in that owns a real `UndoSendCoordinator` delivering
/// through its authority, exactly as `PlainpostAppRuntime` does, without
/// opening a mail store.
@MainActor
private final class MobileFakeMailRuntime: MobileMailRuntime {
    let mailAuthority: (any PlainpostMailAuthority)?
    let undoSend: UndoSendCoordinator
    private let recorder: MobileFakeRuntimeRecorder

    init(
        mailAuthority: (any PlainpostMailAuthority)?,
        recorder: MobileFakeRuntimeRecorder,
        undoSendSleep: @escaping @Sendable (Duration) async throws -> Void,
        sender: (any DirectComposerSending)? = nil
    ) {
        self.mailAuthority = mailAuthority
        self.recorder = recorder
        undoSend = UndoSendCoordinator(
            sender: sender
                ?? mailAuthority.map { NodeAuthorityDirectComposerSender(mutations: $0.mutations) }
                ?? NodeAuthorityDirectComposerSender(),
            sleep: undoSendSleep
        )
        recorder.made(mailAuthority)
    }

    var isSendPending: Bool { undoSend.isSendPending }
    var sendPendingPublisher: AnyPublisher<Bool, Never> { undoSend.sendPendingPublisher }
    var hasFailedSend: Bool { undoSend.hasFailedSend }
    func dismissFailedSend() { undoSend.dismissFailedSend() }
    let composerActivity = PlainpostComposerActivity()
    var unsavedOpenComposerPublisher: AnyPublisher<Bool, Never> { composerActivity.unsavedOpenComposerPublisher }
    func shutdown() async { await recorder.shutdown(mailAuthority) }
}

/// Records the authority of the runtime that was current each time a switch committed.
@MainActor
private final class MobileCommitRecorder {
    private(set) var authorities: [ObjectIdentifier?] = []
    func record(_ authority: (any PlainpostMailAuthority)?) {
        authorities.append(authority.map { ObjectIdentifier($0 as AnyObject) })
    }
}

/// Stands in for the undo window: holds every sleep until released and counts
/// deliveries that wake up cancelled (undone).
private actor MobileUndoSendGate {
    private var released = false
    private var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelledWakeups = 0

    func wait() async throws {
        if !released {
            waiting += 1
            await withCheckedContinuation { continuations.append($0) }
        }
        if Task.isCancelled {
            cancelledWakeups += 1
            throw CancellationError()
        }
    }

    func waitUntilWaiting(timeout: Duration = .seconds(3)) async {
        await mobileWaitOrFail("undo window never started", timeout: timeout) { waiting > 0 }
    }

    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

/// Waits for `condition` up to `timeout`, then records a test failure.
private func mobileWaitOrFail(
    _ message: String,
    timeout: Duration,
    isolation: isolated (any _Concurrency.Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            XCTFail("timed out: \(message)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A delivery that always fails, as a Node rejecting the send would.
private struct MobileFailingComposerSender: DirectComposerSending {
    func send(draft: Draft) async throws -> DirectComposerSendResult {
        throw PlainpostError.validationFailed("delivery rejected")
    }
}

@MainActor
private final class MobileScopedProbe: ObservableObject {
    let runtimeTag: Int
    init(runtimeTag: Int) { self.runtimeTag = runtimeTag }
}

/// Stands in for the mail root: `runtimeTag` is the runtime a view is built
/// from, `generation` the identity the root gives that runtime's content.
@MainActor
private final class MobileScopedHost: ObservableObject {
    @Published var generation: UInt64 = 1
    @Published var runtimeTag = 1
    var renderedTags: [Int] = []
}

/// Like `PlainpostRootView`, it takes its state objects from the runtime it
/// was built with; SwiftUI keeps the first ones for as long as its identity lasts.
private struct MobileScopedProbeView: View {
    @StateObject private var probe: MobileScopedProbe
    private let host: MobileScopedHost

    init(runtimeTag: Int, host: MobileScopedHost) {
        _probe = StateObject(wrappedValue: MobileScopedProbe(runtimeTag: runtimeTag))
        self.host = host
    }

    var body: some View {
        host.renderedTags.append(probe.runtimeTag)
        return Text("runtime \(probe.runtimeTag) of \(host.runtimeTag)")
    }
}

private struct MobileScopedHostView: View {
    @ObservedObject var host: MobileScopedHost

    var body: some View {
        MobileMailRuntimeScoped(generation: host.generation) {
            MobileScopedProbeView(runtimeTag: host.runtimeTag, host: host)
        }
    }
}

private final class MobileAuthorityStandIn {}

private actor MobileLaunchShutdownGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func drain() async { started = true; await withCheckedContinuation { continuation = $0 } }
    /// Bounded, so a regression that never drains fails instead of hanging.
    func waitUntilStarted(timeout: Duration = .seconds(3)) async {
        await mobileWaitOrFail("runtime shutdown never started", timeout: timeout) { started }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor MobileNoopNodeSender: NodeSessionRequestSending {
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        NodeHTTPResponse(
            statusCode: 503,
            url: URL(string: "https://node.example.ts.net:443")!,
            headers: [:],
            body: Data()
        )
    }
}

private actor MobilePrepareCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor MobileAppleBootstrapGate {
    private var started = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted(timeout: Duration = .seconds(3)) async {
        await mobileWaitOrFail("Apple bootstrap never started", timeout: timeout) { started }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class MobileMailHostTests: XCTestCase {
    /// An iPhone Pro Max is regular width in landscape; the shell must not depend on it.
    func testIPhoneUsesTheMobileShellInEveryOrientation() {
        XCTAssertTrue(MobileMailRootView.usesMobileShell(idiom: .phone))
        XCTAssertFalse(MobileMailRootView.usesMobileShell(idiom: .pad))
    }

    /// Pull to refresh is rebuilt when first-run setup turns into a Direct account, when the
    /// account turns read-only, and when the app returns to the foreground.
    func testPullToRefreshIsRebuiltWhenItsInputsChange() {
        let direct = MobileMailRoute.allDirect
        let setup = MobileMailRootView.mobileSyncActionKey(route: .localSetup, readOnly: false, scenePhase: .active)
        let active = MobileMailRootView.mobileSyncActionKey(route: direct, readOnly: false, scenePhase: .active)
        let readOnly = MobileMailRootView.mobileSyncActionKey(route: direct, readOnly: true, scenePhase: .active)
        let background = MobileMailRootView.mobileSyncActionKey(route: direct, readOnly: false, scenePhase: .background)
        XCTAssertEqual(Set([setup, active, readOnly, background]).count, 4)
        XCTAssertEqual(active, MobileMailRootView.mobileSyncActionKey(route: direct, readOnly: false, scenePhase: .active))
    }

    /// Compose's From names the selected account, so switching between two accounts, with
    /// the count unchanged, changes it.
    func testFromAddressFollowsTheSelectedAccount() {
        let first = Account(id: AccountID("a-direct"), displayName: "Personal", email: EmailAddress("a@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        let second = Account(id: AccountID("b-direct"), displayName: "Work", email: EmailAddress("b@example.test"), imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        XCTAssertEqual(MobileMailRootView.fromAddress(accountCount: 2, selectedAccountID: first.id, accounts: [first, second]), "a@example.test")
        XCTAssertEqual(MobileMailRootView.fromAddress(accountCount: 2, selectedAccountID: second.id, accounts: [first, second]), "b@example.test")
        XCTAssertNil(MobileMailRootView.fromAddress(accountCount: 1, selectedAccountID: first.id, accounts: [first]))
        XCTAssertNil(MobileMailRootView.fromAddress(accountCount: 2, selectedAccountID: nil, accounts: [first, second]))
    }

    /// Retry goes to the host's retry, which restarts a sync still running; pull to refresh
    /// joins it. A host that sets no retry retries through its sync.
    @MainActor
    func testRetryUsesTheHostsRetryAndPullToRefreshItsSync() async {
        let environment = MobileMailEnvironment()
        var calls: [String] = []
        environment.syncAction = { calls.append("sync") }
        await environment.retrySync()
        environment.retryAction = { calls.append("retry") }
        await environment.retrySync()
        await environment.sync()
        XCTAssertEqual(calls, ["sync", "retry", "sync"])
    }

    func testHostActivitiesDescribeTheDirectSync() {
        XCTAssertEqual(
            MobileMailRootView.hostActivities(accountTitle: "me@x.example", isSyncing: false, failure: "Mail sync failed.",
                                              historyMailbox: nil, downloaded: 0, total: nil),
            [MobileHostActivity(kind: .failed, accountTitle: "me@x.example", detail: "Mail sync failed.")]
        )
        XCTAssertEqual(
            MobileMailRootView.hostActivities(accountTitle: "me@x.example", isSyncing: true, failure: nil,
                                              historyMailbox: "INBOX", downloaded: 10, total: 40),
            [MobileHostActivity(kind: .syncing, accountTitle: "me@x.example", detail: "INBOX · 10 of 40", fraction: 0.25)]
        )
        XCTAssertEqual(
            MobileMailRootView.hostActivities(accountTitle: "me@x.example", isSyncing: false, failure: nil,
                                              historyMailbox: nil, downloaded: 0, total: nil),
            []
        )
    }

    /// Ledger Task 7: any line to show gives a different key than `noMobileBannerKey`.
    /// (`noMobileBannerKey` is itself defined as `mobileBannerKey(nil, false, false)`, so
    /// comparing that same call's result to it would be a tautology — task-3-review Minor 7,
    /// Ruling 8 — hence no separate "empty" case here.)
    func testTheBannerIsEmptyOnlyWithNothingToShow() {
        for key in [
            MobileMailRootView.mobileBannerKey(switchHold: .finishingSend, hasReleasedFailedSend: false, hasDeferredNotificationOpen: false),
            MobileMailRootView.mobileBannerKey(switchHold: nil, hasReleasedFailedSend: true, hasDeferredNotificationOpen: false),
            MobileMailRootView.mobileBannerKey(switchHold: nil, hasReleasedFailedSend: false, hasDeferredNotificationOpen: true),
        ] {
            XCTAssertNotEqual(key, MobileMailRootView.noMobileBannerKey)
        }
    }

    /// Ledger Task 7: the stalled-sync line shows on iPhone, under the running sync.
    func testHostActivitiesCarryTheStalledSyncNotice() {
        XCTAssertEqual(
            MobileMailRootView.hostActivities(accountTitle: "me@x.example", isSyncing: true, failure: nil,
                                              historyMailbox: nil, downloaded: 0, total: nil,
                                              notice: "Mail sync is still in progress."),
            [MobileHostActivity(kind: .syncing, accountTitle: "me@x.example", detail: "Mail sync is still in progress.")]
        )
        XCTAssertEqual(
            MobileMailRootView.hostActivities(accountTitle: "me@x.example", isSyncing: false, failure: "Mail sync failed.",
                                              historyMailbox: nil, downloaded: 0, total: nil,
                                              notice: "Mail sync is still in progress."),
            [MobileHostActivity(kind: .failed, accountTitle: "me@x.example", detail: "Mail sync failed.")],
            "a failure replaces the notice"
        )
    }
}
