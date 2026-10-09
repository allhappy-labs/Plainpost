// Design-snapshot fixtures for the Settings "Sync Node" page, the Plainpost
// Account page, and a Node-backed mail account page. These build real (but
// inert) `SyncNodeEnrollmentCoordinator` collaborators from only this
// module's public API, so every reachable `SyncNodeEnrollmentViewModel`
// state can be rendered without a live Sync Node, Central server, or the
// crypto-vectors-v1.json test fixture file. Part of the PlainpostDesignSnapshot
// target only; no product code depends on this file.
import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNodeTransport
import SwiftUI
@_spi(DesignPreview) import PlainpostUI

enum SyncNodeDesignFixtureError: Error { case unexpectedNil }

func designRequire<T>(_ value: T?) throws -> T {
    guard let value else { throw SyncNodeDesignFixtureError.unexpectedNil }
    return value
}

private func designTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// A real (but throwaway) P256 public key in SEC1 uncompressed form, valid
/// enough to pass shape validation without any secret material that matters.
private func designP256PublicKey() -> Data {
    P256.Signing.PrivateKey().publicKey.x963Representation
}

/// Builds just enough self-consistent account/trust/profile material to
/// exercise `SyncNodeEnrollmentViewModel` and `SyncNodeEnrollmentCoordinator`
/// for design snapshots, without any production network traffic or the
/// crypto-vectors test fixture file.
@MainActor
struct SyncNodeDesignFixture {
    let accountID: PlainpostAccountID
    let deviceID: AccountDeviceID
    let identity: AccountDeviceIdentity
    let genesisCommit: AccountTrustStateCommit
    let profile: SyncNodeBootstrapProfile
    let presentation: SyncNodeEnrollmentPresentation
    let claim: AccountNodeEnrollmentPublicClaimV1
    let credentials: AccountSessionCredentials
    /// `SyncNodeBootstrapProfile.capability` is internal to
    /// PlainpostAccountRuntime; kept here so this (different-module) fixture
    /// can rebuild a profile with the same capability but no Central audience.
    let profileCapabilityBytes = Data(repeating: 8, count: 32)

    init() throws {
        accountID = try PlainpostAccountID("90000000-0000-4000-8000-0000000000aa")
        deviceID = try AccountDeviceID("90000000-0000-4000-8000-0000000000bb")
        identity = try AccountDeviceIdentity.generate()

        let member = try AccountDeviceTrustRecord(
            accountID: accountID,
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            revision: try PositiveUInt64(1),
            deviceID: deviceID,
            platform: .macos,
            publicBundle: identity.publicBundle,
            signerDeviceID: deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let transition = try AccountTrustTransition(kind: .genesis, targetDeviceIDs: [deviceID], priorRecordDigests: [])
        let state = try AccountTrustState(
            accountID: accountID,
            epoch: AccountTrustEpoch(rawValue: try PositiveUInt64(1)),
            revision: try PositiveUInt64(1),
            previousCommitDigest: nil,
            transition: transition,
            keyGeneration: try PositiveUInt64(1),
            keyCommitment: Data(repeating: 2, count: 32),
            members: [member],
            signerDeviceID: deviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let stateDigest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let package = try AccountGroupKeyPackage(
            accountID: accountID,
            epoch: state.epoch,
            stateRevision: state.revision,
            keyGeneration: state.keyGeneration,
            stateDigest: stateDigest,
            keyCommitment: state.keyCommitment,
            recipientDeviceID: deviceID,
            senderDeviceID: deviceID,
            senderEphemeralPublicKey: designP256PublicKey(),
            nonce: Data(repeating: 3, count: 12),
            encryptedKeyMaterial: Data(repeating: 4, count: 80),
            signature: Data(repeating: 1, count: 64)
        )
        genesisCommit = try AccountTrustStateCommit(state: state, keyPackages: [package])

        credentials = try AccountSessionCredentials(
            accountID: accountID,
            deviceID: deviceID,
            accessToken: "design-preview-token",
            accessExpiresAt: Date().addingTimeInterval(600),
            refreshCredential: Data(repeating: 6, count: 32),
            offlineLease: "design-preview-lease"
        )

        let nodeDeviceID = try AccountDeviceID("90000000-0000-4000-8000-0000000000cc")
        let signingPublicKey = designP256PublicKey()
        profile = try SyncNodeBootstrapProfile(
            canonicalOrigin: NodeEndpointURL("https://node.tail1234.ts.net:18443"),
            nodeDeviceID: nodeDeviceID,
            signingKeyDigest: Data(SHA256.hash(data: signingPublicKey)),
            capabilityID: Data(repeating: 7, count: 16),
            capability: Data(repeating: 8, count: 32),
            centralAudience: "central.design-preview"
        )
        let createdAt = designTimestamp(Date().addingTimeInterval(-30))
        let expiresAt = designTimestamp(Date().addingTimeInterval(240))
        claim = try AccountNodeEnrollmentPublicClaimV1(
            claimID: NodeEnrollmentClaimID("90000000-0000-4000-8000-0000000000dd"),
            nodeDeviceID: nodeDeviceID,
            signingPublicKey: signingPublicKey,
            agreementPublicKey: designP256PublicKey(),
            noiseStaticPublicKey: Data(repeating: 9, count: 32),
            endpointDigest: Data(repeating: 4, count: 32),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        presentation = try SyncNodeEnrollmentPresentation(
            setupCode: NodeSessionWire.encodeBase64URL(Data(repeating: 1, count: 32)),
            expiresAt: try designRequire(AccountWireCodec.parseTimestamp(expiresAt)),
            claimProofSignature: Data(repeating: 10, count: 64),
            claimFingerprint: "123456"
        )
    }

    /// A coordinator wired with no-op/throwing collaborators: enough to show
    /// static states (`.enterCode`, a chosen `connectionPresentation`), never
    /// enough to drive a real network attempt.
    func inertCoordinator(activeNodeID: AccountDeviceID?) -> SyncNodeEnrollmentCoordinator {
        SyncNodeEnrollmentCoordinator(
            remote: DesignInertRemote(),
            localAuthenticator: DesignInertLocal(),
            responseVerifier: DesignInertVerifier(),
            trust: DesignInertTrust(),
            activation: DesignInertActivator(),
            credentials: credentials,
            credentialsProvider: { [credentials] in credentials },
            device: identity,
            activeNodeID: activeNodeID
        )
    }

    /// A coordinator that can actually run `begin(profile:appleAuthorization:)`
    /// through local auth, step-up and a lost first commit response, landing on
    /// `.commitResponseUncertain` without any real network or Node material.
    func lossyCoordinator() -> SyncNodeEnrollmentCoordinator {
        SyncNodeEnrollmentCoordinator(
            remote: DesignLossyRemote(fixture: self),
            presenter: DesignPresenter(presentation: presentation),
            bootstrapVerifier: DesignBootstrapVerifier(origin: profile.canonicalOrigin),
            localAuthenticator: DesignInertLocal(),
            responseVerifier: DesignInertVerifier(),
            trust: DesignGenesisTrust(commit: genesisCommit),
            activation: DesignInertActivator(),
            credentials: credentials,
            credentialsProvider: { [credentials] in credentials },
            device: identity,
            activeNodeID: nil
        )
    }

    /// A coordinator whose commit *succeeds* (a shape-valid, non-cryptographic
    /// V2 admission response — `responseVerifier` is a no-op, so its field
    /// values never need to be real), but whose Node activation reports
    /// `.uncertain`, landing on `.activationResponseUncertain`.
    func activationUncertainCoordinator() -> SyncNodeEnrollmentCoordinator {
        SyncNodeEnrollmentCoordinator(
            remote: DesignActivationUncertainRemote(fixture: self),
            presenter: DesignPresenter(presentation: presentation),
            bootstrapVerifier: DesignBootstrapVerifier(origin: profile.canonicalOrigin),
            localAuthenticator: DesignInertLocal(),
            responseVerifier: DesignInertVerifier(),
            trust: DesignGenesisTrust(commit: genesisCommit),
            activation: DesignUncertainActivator(),
            credentials: credentials,
            credentialsProvider: { [credentials] in credentials },
            device: identity,
            activeNodeID: nil
        )
    }

    /// Drives `appleAuthorization` through to `.matchingStringConfirmation`
    /// without approving it (any coordinator built by this fixture reaches
    /// the same point before committing).
    private func driveToPending(_ coordinator: SyncNodeEnrollmentCoordinator) async throws -> SyncNodeEnrollmentViewModel {
        let model = SyncNodeEnrollmentViewModel(
            coordinator: coordinator,
            profile: profile,
            nonceGenerator: { Data(repeating: 4, count: 32) }
        )
        let attempt = try model.beginConnectAppleAuthorization()
        model.submitAppleIdentityToken(Data("design-preview-apple-token".utf8), for: attempt.id)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if case .matchingStringConfirmation = model.state, model.connectionPresentation == .ready { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        return model
    }

    /// Drives `lossyCoordinator()` through Apple authorization and approval so
    /// its first commit attempt is lost in transit, landing the model on
    /// `.commitResponseUncertain` (the "commit may have saved your approval"
    /// recovery state).
    func commitUncertainModel() async throws -> SyncNodeEnrollmentViewModel {
        let model = try await driveToPending(lossyCoordinator())
        await model.approvePinnedTarget()
        let settleDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < settleDeadline, model.state != .commitResponseUncertain {
            try await Task.sleep(for: .milliseconds(2))
        }
        return model
    }

    /// Stops right at `.matchingStringConfirmation`: "Approve this server for
    /// your Plainpost account." with Cancel / Approve Connect.
    func matchingStringConfirmationModel() async throws -> SyncNodeEnrollmentViewModel {
        try await driveToPending(lossyCoordinator())
    }

    /// Drives `activationUncertainCoordinator()` through a *successful* commit
    /// whose Node activation is uncertain, landing on
    /// `.activationResponseUncertain` ("The server response was interrupted.
    /// Retry to finish connecting.").
    func activationUncertainModel() async throws -> SyncNodeEnrollmentViewModel {
        let model = try await driveToPending(activationUncertainCoordinator())
        await model.approvePinnedTarget()
        let settleDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < settleDeadline, model.state != .activationResponseUncertain {
            try await Task.sleep(for: .milliseconds(2))
        }
        return model
    }
}

private struct DesignInertRemote: SyncNodeEnrollmentRemote {
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { throw AccountRuntimeError.untrustedResponse }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {}
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 { throw AccountRuntimeError.untrustedResponse }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse { throw AccountRuntimeError.untrustedResponse }
}

private struct DesignInertLocal: SyncNodeEnrollmentLocalAuthenticating { func authenticateSyncNodeEnrollment() async throws {} }
private struct DesignInertVerifier: SyncNodeEnrollmentResponseVerifying { func verify(response: SyncNodeEnrollmentAdmissionResponse, request: SyncNodeEnrollmentAdmissionRequest, centralAudience: String, now: Date) throws {} }
private struct DesignInertActivator: SyncNodeEnrollmentActivating {
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {}
    func retryUncertainActivation() async throws {}
    func cancelPendingActivation() async {}
}
private struct DesignInertTrust: SyncNodeEnrollmentTrustCoordinating {
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { nil }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit { throw AccountRuntimeError.untrustedResponse }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {}
}

/// Always reports `.uncertain`, for the activation-response-uncertain state.
private struct DesignUncertainActivator: SyncNodeEnrollmentActivating {
    func activate(response: AccountNodeEnrollmentAdmissionResponseV2, request: SyncNodeEnrollmentAdmissionRequest, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data, expectedOrigin: NodeEndpointURL) async throws {
        throw NodeActivationError.uncertain
    }
    func retryUncertainActivation() async throws {}
    func cancelPendingActivation() async {}
}

private struct DesignPresenter: SyncNodeEnrollmentPresenting {
    let presentation: SyncNodeEnrollmentPresentation
    func fetchPresentation(for profile: SyncNodeBootstrapProfile) async throws -> SyncNodeEnrollmentPresentation { presentation }
}

private struct DesignBootstrapVerifier: SyncNodeBootstrapClaimVerifying {
    let origin: NodeEndpointURL
    func verify(profile: SyncNodeBootstrapProfile, presentation: SyncNodeEnrollmentPresentation, claim: AccountNodeEnrollmentPublicClaimV1, setupCode: Data) throws -> NodeEndpointURL { origin }
}

/// Accepts a prior genesis commit as-is and builds a self-consistent
/// successor for one Sync Node admission; never checked against a real
/// server, so acceptance always "succeeds" locally.
private final class DesignGenesisTrust: SyncNodeEnrollmentTrustCoordinating, @unchecked Sendable {
    private let commit: AccountTrustStateCommit
    init(commit: AccountTrustStateCommit) { self.commit = commit }
    func currentTrustCommit() async throws -> AccountTrustStateCommit? { commit }
    func makeSyncNodeEnrollmentCommit(evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws -> AccountTrustStateCommit {
        let prior = commit
        let revision = try PositiveUInt64(prior.state.revision.value + 1)
        let bundle = try AccountPublicKeyBundle(signingKey: evidence.signingPublicKey, agreementKey: evidence.agreementPublicKey)
        let member = try AccountDeviceTrustRecord(
            accountID: prior.state.accountID, epoch: prior.state.epoch, revision: revision,
            deviceID: evidence.nodeDeviceID, platform: .syncNode, publicBundle: bundle,
            signerDeviceID: prior.state.signerDeviceID, signature: Data(repeating: 1, count: 64)
        )
        let transition = try AccountTrustTransition(
            kind: .admission, targetDeviceIDs: [evidence.nodeDeviceID], priorRecordDigests: [],
            handshakeDigest: Data(repeating: 3, count: 32), pendingDeviceDigest: Data(repeating: 4, count: 32)
        )
        let state = try AccountTrustState(
            accountID: prior.state.accountID, epoch: prior.state.epoch, revision: revision,
            previousCommitDigest: AccountTranscript.trustCommitDigest(prior), transition: transition,
            keyGeneration: prior.state.keyGeneration, keyCommitment: prior.state.keyCommitment,
            members: prior.state.members + [member], signerDeviceID: prior.state.signerDeviceID,
            signature: Data(repeating: 1, count: 64)
        )
        let digest = Data(SHA256.hash(data: AccountTranscript.signedTrustState(state)))
        let packages = try state.members.map { member in
            try AccountGroupKeyPackage(
                accountID: state.accountID, epoch: state.epoch, stateRevision: state.revision,
                keyGeneration: state.keyGeneration, stateDigest: digest, keyCommitment: state.keyCommitment,
                recipientDeviceID: member.deviceID, senderDeviceID: state.signerDeviceID,
                senderEphemeralPublicKey: designP256PublicKey(), nonce: Data(repeating: 3, count: 12),
                encryptedKeyMaterial: Data(repeating: 4, count: 80), signature: Data(repeating: 1, count: 64)
            )
        }
        return try AccountTrustStateCommit(state: state, keyPackages: packages)
    }
    func acceptSyncNodeEnrollmentCommit(_ commit: AccountTrustStateCommit, evidence: AccountNodeEnrollmentAdmissionEvidenceV1) async throws {}
}

/// Drops the first commit response (transport failure) so the coordinator
/// lands on `.commitResponseUncertain`. Never reached a second time in a
/// snapshot, since each scenario only exercises that first, lost attempt.
private final class DesignLossyRemote: SyncNodeEnrollmentRemote, @unchecked Sendable {
    private let fixture: SyncNodeDesignFixture
    init(fixture: SyncNodeDesignFixture) { self.fixture = fixture }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { fixture.claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {}
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try designStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, credentials: credentials, device: device, trustCommit: trustCommit, now: now)
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        throw AccountRuntimeError.transportFailure
    }
}

/// Commits *successfully*, with a shape-valid (non-cryptographic) V2
/// admission response, for the activation-response-uncertain state.
private final class DesignActivationUncertainRemote: SyncNodeEnrollmentRemote, @unchecked Sendable {
    private let fixture: SyncNodeDesignFixture
    init(fixture: SyncNodeDesignFixture) { self.fixture = fixture }
    func lookupSyncNodeClaim(setupCode: String) async throws -> AccountNodeEnrollmentPublicClaimV1 { fixture.claim }
    func cancelSyncNodeClaim(claimID: NodeEnrollmentClaimID, setupCode: String) async throws {}
    func issueSyncNodeStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, authorization: SyncNodeEnrollmentAppleAuthorization, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) async throws -> AccountStepUpAuthorizationV1 {
        try designStepUp(action: action, claim: claim, replacedNodeID: replacedNodeID, credentials: credentials, device: device, trustCommit: trustCommit, now: now)
    }
    func commitSyncNodeAdmission(_ request: SyncNodeEnrollmentAdmissionRequest, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, now: Date) async throws -> SyncNodeEnrollmentAdmissionResponse {
        try designV2Response(fixture: fixture, request: request, credentials: credentials, device: device, now: now)
    }
}

/// Shared by both remotes that answer a Node step-up request.
private func designStepUp(action: AccountNodeEnrollmentAction, claim: AccountNodeEnrollmentPublicClaimV1, replacedNodeID: AccountDeviceID?, credentials: AccountSessionCredentials, device: AccountDeviceIdentity, trustCommit: AccountTrustStateCommit, now: Date) throws -> AccountStepUpAuthorizationV1 {
    try AccountStepUpAuthorizationV1(
        authorizationID: AccountAuthorizationID("90000000-0000-4000-8000-0000000000ee"),
        accountID: credentials.accountID, actorDeviceID: credentials.deviceID,
        targetDeviceID: action == .enroll ? claim.nodeDeviceID : replacedNodeID,
        action: action == .enroll ? .enrollSyncNode : .replaceSyncNode,
        currentCommitDigest: AccountTranscript.trustCommitDigest(trustCommit),
        requestDigest: Data(repeating: 6, count: 32),
        issuedAt: designTimestamp(now.addingTimeInterval(-1)),
        expiresAt: designTimestamp(now.addingTimeInterval(240)),
        serverKeyID: "design-preview-key",
        serverSignature: try device.signature(for: Data("design-preview-step-up".utf8))
    )
}

/// A shape-valid (every byte-length and cross-reference check the
/// initializers themselves enforce), but not cryptographically real, V2
/// admission response. `SyncNodeEnrollmentResponseVerifying` is a no-op in
/// every design-preview coordinator, so this is accepted without the
/// signature checks a real server's answer would need.
private func designV2Response(
    fixture: SyncNodeDesignFixture,
    request: SyncNodeEnrollmentAdmissionRequest,
    credentials: AccountSessionCredentials,
    device: AccountDeviceIdentity,
    now: Date
) throws -> SyncNodeEnrollmentAdmissionResponse {
    let base = try AccountNodeOperationBindingV1(
        accountID: request.evidence.accountID,
        trustEpoch: request.evidence.trustEpoch,
        claimID: request.evidence.claimID,
        nodeDeviceID: request.evidence.nodeDeviceID,
        centralAudience: try designRequire(request.expectedCentralAudience),
        action: request.evidence.action,
        replacedNodeID: request.evidence.replacedNodeID,
        replacementRevocationDigest: nil,
        admissionEvidenceDigest: Data(repeating: 0x21, count: 32),
        issuanceDigest: Data(repeating: 0x22, count: 32)
    )
    let cleanupCapability = try AccountSyncNodeCleanupCapabilityV1(
        accountID: request.evidence.accountID,
        claimID: request.evidence.claimID,
        nodeDeviceID: request.evidence.nodeDeviceID,
        targetHandle: Data(repeating: 0x23, count: 32),
        cleanupCredential: Data(repeating: 0x24, count: 32),
        deletionGeneration: try PositiveUInt64(1),
        issuedAt: designTimestamp(now)
    )
    let cleanupDigest = Data(SHA256.hash(data: try AccountWireCodec.encodeSyncNodeCleanupCapability(cleanupCapability)))
    let binding = try AccountNodeOperationBindingV2(base: base, cleanupCapabilityDigest: cleanupDigest)
    let result = try AccountNodeEnrollmentResultV2(binding: binding, committedAt: designTimestamp(now))
    let refreshCredential = try AccountNodeRefreshCredentialV2(
        binding: binding, credentialID: "90000000-0000-4000-8000-0000000000f0",
        issuedAt: designTimestamp(now), expiresAt: designTimestamp(now.addingTimeInterval(86_400)),
        credential: Data(repeating: 0x25, count: 32)
    )
    let offlineLease = try AccountNodeOfflineLeaseV2(
        binding: binding, leaseID: "90000000-0000-4000-8000-0000000000f1",
        issuedAt: designTimestamp(now), expiresAt: designTimestamp(now.addingTimeInterval(86_400)),
        serverKeyID: "design-preview-key",
        signature: try device.signature(for: Data("design-preview-lease-v2".utf8))
    )
    let v2 = try AccountNodeEnrollmentAdmissionResponseV2(
        result: result, refreshCredential: refreshCredential, offlineLease: offlineLease, cleanupCapability: cleanupCapability
    )
    return try SyncNodeEnrollmentAdmissionResponse(v2: v2)
}

/// A `SyncNodeBootstrapProfileStoring` that never persists anything, for the
/// "not connected" and "ready to connect" snapshots.
struct DesignProfileStore: SyncNodeBootstrapProfileStoring {
    let profile: SyncNodeBootstrapProfile?
    func load() throws -> SyncNodeBootstrapProfile? { profile }
    func importProfile(_ profile: SyncNodeBootstrapProfile) throws {}
    func retire(expectedCapabilityID: Data) throws {}
}

extension SyncNodeDesignFixture {
    /// A v1 Server Setup file (no Central audience), for the outdated-profile
    /// failure message.
    func outdatedProfile() throws -> SyncNodeBootstrapProfile {
        try SyncNodeBootstrapProfile(
            canonicalOrigin: profile.canonicalOrigin,
            nodeDeviceID: profile.nodeDeviceID,
            signingKeyDigest: profile.signingKeyDigest,
            capabilityID: profile.capabilityID,
            capability: profileCapabilityBytes,
            centralAudience: nil
        )
    }
}

/// Awaits (via `Task.yield()`, same as the test suite's `activate(session:)`
/// helpers) a session's internal `prepare()` Task. A plain `RunLoop` spin
/// does not do this: this process never calls `NSApplication.run()`, so the
/// main dispatch queue a MainActor Task hops onto is never drained outside
/// an actual `await`.
@MainActor
private func designActivate(_ session: AccountSessionViewModel) async {
    session.prepare(now: Date(timeIntervalSince1970: 1_900_000_000))
    for _ in 0 ..< 2_000 where session.presentation != .active { await Task.yield() }
    // Production relies on the Sync Node page's own `.task` to call this
    // once mounted; this headless renderer never truly hosts the view (no
    // `NSApplication.run()`), so no SwiftUI `.task` body ever executes. Drive
    // the same calls directly and await them for real.
    session.refreshSyncNodeEnrollmentOwner()
    session.prepareSyncNodeEnrollment()
    for _ in 0 ..< 2_000 where session.syncNodeEnrollmentLoadPresentation == .loading { await Task.yield() }
}

/// The Sync Node page before any Server Setup file has been imported.
@MainActor
func syncNodeSessionNotConnected() async throws -> AccountSessionViewModel {
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { throw SyncNodeEnrollmentAssembly.LoadError.noSyncNode },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: nil))
    )
    await designActivate(session)
    return session
}

/// A Server Setup file has been imported but the Sync Node is not yet
/// enrolled: the pinned target and Continue with Apple are shown.
@MainActor
func syncNodeSessionReadyToConnect() async throws -> AccountSessionViewModel {
    let fixture = try SyncNodeDesignFixture()
    let model = SyncNodeEnrollmentViewModel(coordinator: fixture.inertCoordinator(activeNodeID: nil), profile: fixture.profile)
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { model },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: fixture.profile))
    )
    await designActivate(session)
    return session
}

/// An already-enrolled Sync Node at a chosen `connectionPresentation`
/// ("connected" with status, or "connectionFailed"). `profile` is nil (no
/// pending Server Setup import) unless `withReplaceableProfile` is set.
@MainActor
func syncNodeSessionEnrolled(
    presentation: SyncNodeEnrollmentViewModel.ConnectionPresentation,
    withReplaceableProfile: Bool = false
) async throws -> AccountSessionViewModel {
    let fixture = try SyncNodeDesignFixture()
    let model = SyncNodeEnrollmentViewModel(
        coordinator: fixture.inertCoordinator(activeNodeID: fixture.profile.nodeDeviceID),
        profile: withReplaceableProfile ? fixture.profile : nil,
        initialConnectionPresentation: presentation
    )
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { model },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: fixture.profile))
    )
    await designActivate(session)
    return session
}

/// A v1 ("outdated") Server Setup file: an enrollment failure message that
/// only Replace Server Setup can fix.
@MainActor
func syncNodeSessionOutdatedProfile() async throws -> AccountSessionViewModel {
    let fixture = try SyncNodeDesignFixture()
    let legacy = try fixture.outdatedProfile()
    let model = SyncNodeEnrollmentViewModel(coordinator: fixture.inertCoordinator(activeNodeID: nil), profile: legacy)
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { model },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: legacy))
    )
    await designActivate(session)
    return session
}

/// The generic "Sync Node connection couldn't be completed" failure message
/// (a pre-commit rejection with no committed admission to protect).
@MainActor
func syncNodeSessionGenericFailure() async throws -> AccountSessionViewModel {
    let fixture = try SyncNodeDesignFixture()
    let model = SyncNodeEnrollmentViewModel(
        coordinator: fixture.inertCoordinator(activeNodeID: nil),
        profile: fixture.profile,
        initialConnectionPresentation: .failed
    )
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { model },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: fixture.profile))
    )
    await designActivate(session)
    return session
}

/// Wraps an already-built enrollment model (for the models this fixture
/// drove asynchronously before `main()`'s scenario list) into a session.
@MainActor
func syncNodeSessionFromModel(_ model: SyncNodeEnrollmentViewModel) async throws -> AccountSessionViewModel {
    let fixture = try SyncNodeDesignFixture()
    let session = AccountSessionViewModel(
        prepareSession: { _ in .active },
        syncNodeEnrollmentFactory: { model },
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel(store: DesignProfileStore(profile: fixture.profile))
    )
    await designActivate(session)
    return session
}

/// A populated Node status snapshot: version, storage, verified backup, and
/// (by default) a reachable Node. Pass `reachability: "unreachable"` (any
/// value that doesn't lower-case to "reachable") for the "Needs attention"
/// connection row.
@MainActor
func syncNodeStatusViewModel(reachability: String = "reachable") throws -> SyncNodeSettingsViewModel {
    SyncNodeSettingsViewModel(
        snapshot: SyncNodeSettingsSnapshot(
            version: "node-9.4.1", reachability: reachability, syncLag: "2s",
            storage: "1500000000/10000000000 bytes", provider: "gmail-identity",
            mailboxAssignments: ["Inbox"], backup: "verified",
            endpoint: "https://node.example", updateStatus: "Current"
        ),
        // Only to make `canOperate` true, so Status shows its Last Backup row
        // and the page offers Erase Sync Node; never invoked in a snapshot.
        operationsController: SyncNodeOperationsController(client: DesignInertOperationsClient())
    )
}

private struct DesignInertOperationsClient: SyncNodeOperationsClient {
    func status() async throws -> SyncNodeStatus { throw AccountRuntimeError.secretUnavailable }
    func backup() async throws -> SyncNodeStatus { throw AccountRuntimeError.secretUnavailable }
    func erase() async throws -> SyncNodeStatus { throw AccountRuntimeError.secretUnavailable }
}

/// The Sync Node Settings page, with the sidebar beside it (Settings always
/// composes both).
@MainActor
func syncNodeSettingsPreview(session: AccountSessionViewModel, nodeSettings: SyncNodeSettingsViewModel? = nil) -> AnyView {
    let accountSetup = AccountSetupViewModel.connectedPreview()
    return AnyView(
        SettingsWorkspace(
            selection: .constant(.section(.syncNode)),
            accountSetup: accountSetup,
            accountSessionModel: session,
            nodeSettings: nodeSettings,
            aiProviderSettings: .preview(),
            aiIndexStatus: InboxViewModel.designPreview().aiIndexStatus,
            auditLog: .preview(),
            mailRules: .preview(),
            mailLabels: .preview(),
            maintenance: .preview(accountSetup: accountSetup)
        )
    )
}

/// A Node-backed mail account's own settings page (`NodeAccountSettingsPage`,
/// reached through the `.nodeAccount` destination and the settings host).
@MainActor
func nodeAccountPreview(state: NodeSyncMailAccountState) -> AnyView {
    guard let mailboxID = LogicalMailboxID(rawValue: Data(repeating: 0x5A, count: 32)) else {
        return AnyView(Text("Could not build a design LogicalMailboxID"))
    }
    let account = NodeMailAccount(
        logicalMailboxID: mailboxID,
        providerIdentity: "oleh@example.com",
        providerKind: "gmail",
        isPrimary: true,
        state: state,
        mailboxes: [
            SyncNodeProviderMailbox(displayName: "Inbox", mailboxHandle: "INBOX", role: "inbox", logicalMailboxID: mailboxID)
        ]
    )
    let accountSetup = AccountSetupViewModel.connectedPreview()
    var host = PlainpostSettingsHost()
    host.nodeMailAccounts = [account]
    return AnyView(
        SettingsWorkspace(
            selection: .constant(.nodeAccount(mailboxID)),
            accountSetup: accountSetup,
            aiProviderSettings: .preview(),
            aiIndexStatus: InboxViewModel.designPreview().aiIndexStatus,
            auditLog: .preview(),
            mailRules: .preview(),
            mailLabels: .preview(),
            maintenance: .preview(accountSetup: accountSetup)
        )
        .plainpostSettingsHost(host)
    )
}
