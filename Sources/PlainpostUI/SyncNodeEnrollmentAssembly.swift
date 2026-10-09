import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNodeTransport
import PlainpostServiceIPC

/// The Mac's post-activation Node connection: `PlainpostService` owns the
/// Node session, so the app checks it through the service broker and tells
/// the broker to drop its session whenever enrollment or replacement commits
/// a new trusted Node.
public struct SyncNodeBrokeredConnection: Sendable {
    public let sender: ServiceBrokeredNodeSender
    public let invalidate: @Sendable () async throws -> Void

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        sender = ServiceBrokeredNodeSender(serviceClient: serviceClient)
        invalidate = { try await serviceClient.invalidateNodeSession() }
    }

    init(sender: ServiceBrokeredNodeSender, invalidate: @escaping @Sendable () async throws -> Void) {
        self.sender = sender
        self.invalidate = invalidate
    }
}

/// Remembers the trusted Node the broker was last told about, so a commit by
/// enrollment or replacement invalidates the broker exactly once.
actor SyncNodeBrokerTrustFence {
    private var current: String?

    init(epoch: AccountTrustEpoch?, nodeID: AccountDeviceID?) {
        current = Self.key(epoch: epoch, nodeID: nodeID)
    }

    /// Returns true when the trusted Node changed since the last call.
    func advance(epoch: AccountTrustEpoch, nodeID: AccountDeviceID) -> Bool {
        let next = Self.key(epoch: epoch, nodeID: nodeID)
        defer { current = next }
        return next != current
    }

    private static func key(epoch: AccountTrustEpoch?, nodeID: AccountDeviceID?) -> String? {
        guard let epoch, let nodeID else { return nil }
        return "\(epoch.wireValue)/\(nodeID.rawValue)"
    }
}

/// Builds the one Sync Node enrollment presentation owner for an Apple
/// client. The Central audience comes only from the imported Server Setup
/// profile; no platform derives it from the Central origin.
@MainActor
public enum SyncNodeEnrollmentAssembly {
    /// Why `makeModel` built no connection model.
    public enum LoadError: Error, Equatable, Sendable {
        /// The account's trust state lists no Sync Node and no Server Setup is imported:
        /// there is nothing to connect to or enroll yet. Every other failure (no active
        /// session, an unreadable trust state, the network) throws its own error.
        case noSyncNode
    }

    /// The owner of the active session, or nil when no session is active.
    /// Pair it with `makeModel` so a retained enrollment is rendered and
    /// published only for the account and device that started it.
    public static func activeSessionOwner(credentials: AccountCredentialStore) throws -> SyncNodeEnrollmentOwner? {
        guard let session = try credentials.loadSession(),
              session.state == .active,
              let current = session.credentials else { return nil }
        return SyncNodeEnrollmentOwner(accountID: current.accountID, deviceID: current.deviceID)
    }

    public static func makeModel(
        client: AccountAPIClient,
        credentials: AccountCredentialStore,
        sessionController: AccountSessionController,
        platform: AccountPlatform,
        sessionManifest: SessionKeyManifestVerifier,
        authenticator: any LocalApprovalAuthenticating,
        bootstrapImportModel: SyncNodeBootstrapImportViewModel,
        endpointStore: SyncNodeEndpointStore,
        brokeredConnection: SyncNodeBrokeredConnection? = nil
    ) async throws -> SyncNodeEnrollmentViewModel {
        guard let session = try credentials.loadSession(), session.state == .active, let sessionCredentials = session.credentials else { throw AccountRuntimeError.corruptSecret }
        let enrollmentOwner = SyncNodeEnrollmentOwner(accountID: sessionCredentials.accountID, deviceID: sessionCredentials.deviceID)
        // Access tokens expire after 15 minutes, while a retained
        // admission can wait longer for Retry. Every commit, replay and
        // endpoint publication reads the current session; the
        // coordinator and activator refuse one for another owner.
        let currentSessionCredentials: SyncNodeEnrollmentCredentialsProvider = {
            _ = await sessionController.prepare(now: Date())
            guard let session = try credentials.loadSession(), session.state == .active, let current = session.credentials else {
                throw AccountRuntimeError.secretUnavailable
            }
            return current
        }
        let identity = try credentials.loadOrCreateDeviceIdentity()
        let trust = try credentials.makeTrustCoordinator(accountID: sessionCredentials.accountID, deviceID: sessionCredentials.deviceID, platform: platform, identity: identity)
        let nodeClient = NodeTLSClient()
        let connectionChecker = SyncNodeConnectionChecker(client: nodeClient)
        let profileBeforeResume = try bootstrapImportModel.loadProfile()
        let activation = try PrivateSyncNodeEnrollmentActivator(remote: client, trust: trust, store: endpointStore, client: nodeClient, credentials: sessionCredentials, credentialsProvider: currentSessionCredentials, device: identity)
        let resumedActivation = await activation.hasPendingActivation
        let resumeMatchesProfile: Bool
        if let profileBeforeResume {
            resumeMatchesProfile = await activation.pendingActivationMatches(profile: profileBeforeResume)
        } else {
            resumeMatchesProfile = false
        }
        try await activation.resumePendingActivation()
        if resumedActivation, resumeMatchesProfile, let profileBeforeResume {
            try bootstrapImportModel.retireProfile(expectedCapabilityID: profileBeforeResume.capabilityID)
        }

        guard let commit = try await trust.currentTrustCommit(), commit.state.accountID == sessionCredentials.accountID else {
            throw AccountRuntimeError.untrustedResponse
        }
        let activeNodeID = commit.state.members.first(where: { $0.platform == .syncNode })?.deviceID
        let currentProfile = try bootstrapImportModel.loadProfile()
        let coordinator = SyncNodeEnrollmentCoordinator(
            remote: client,
            presenter: NodeTransportSyncNodeEnrollmentPresenter(),
            bootstrapVerifier: SyncNodeBootstrapClaimVerifier(),
            localAuthenticator: LocalApprovalSyncNodeEnrollmentAuthenticator(authenticator: authenticator),
            responseVerifier: ManifestBackedSyncNodeEnrollmentResponseVerifier(manifest: sessionManifest),
            trust: trust,
            activation: activation,
            credentials: sessionCredentials,
            credentialsProvider: currentSessionCredentials,
            device: identity,
            activeNodeID: activeNodeID
        )
        if let brokeredConnection {
            // Enrollment and activation stay in the app (Amendment 6
            // exception); every later Node session request, including this
            // check, goes through the service broker.
            let fence = SyncNodeBrokerTrustFence(epoch: activeNodeID == nil ? nil : commit.state.epoch, nodeID: activeNodeID)
            let verifyConnection: @Sendable () async throws -> Void = {
                guard let latest = try await trust.currentTrustCommit(),
                      latest.state.accountID == sessionCredentials.accountID,
                      let member = latest.state.members.first(where: { $0.platform == .syncNode })
                else { throw AccountRuntimeError.untrustedResponse }
                if await fence.advance(epoch: latest.state.epoch, nodeID: member.deviceID) {
                    try await brokeredConnection.invalidate()
                }
                try await brokeredConnection.sender.verifyConnection()
            }
            guard activeNodeID != nil else {
                guard let currentProfile else { throw LoadError.noSyncNode }
                return SyncNodeEnrollmentViewModel(
                    coordinator: coordinator,
                    profile: currentProfile,
                    owner: enrollmentOwner,
                    retireProfile: { capabilityID in try bootstrapImportModel.retireProfile(expectedCapabilityID: capabilityID) },
                    verifyConnection: verifyConnection
                )
            }
            let initialPresentation: SyncNodeEnrollmentViewModel.ConnectionPresentation
            do {
                try await verifyConnection()
                initialPresentation = .connected
            } catch PlainpostServiceClientError.nodeSession(.noEnrolledNode), PlainpostServiceClientError.nodeSession(.noActiveSession) {
                initialPresentation = .recoveryRequired
            } catch {
                initialPresentation = .connectionFailed
            }
            return SyncNodeEnrollmentViewModel(
                coordinator: coordinator,
                profile: currentProfile,
                owner: enrollmentOwner,
                initialConnectionPresentation: initialPresentation,
                retireProfile: { capabilityID in try bootstrapImportModel.retireProfile(expectedCapabilityID: capabilityID) },
                verifyConnection: verifyConnection
            )
        }

        let verifyConnection: @Sendable () async throws -> Void = {
            guard let latest = try await trust.currentTrustCommit(),
                  latest.state.accountID == sessionCredentials.accountID,
                  let member = latest.state.members.first(where: { $0.platform == .syncNode })
            else { throw AccountRuntimeError.untrustedResponse }
            let connection = try SyncNodeSessionLocator.restoreCachedConnection(
                credentials: sessionCredentials,
                nodeID: member.deviceID,
                trustEpoch: latest.state.epoch,
                device: identity,
                store: endpointStore,
                client: nodeClient
            )
            try await connectionChecker.check(connection)
        }

        if let activeNodeID {
            let initialPresentation: SyncNodeEnrollmentViewModel.ConnectionPresentation
            do {
                _ = try SyncNodeSessionLocator.restoreCachedConnection(credentials: sessionCredentials, nodeID: activeNodeID, trustEpoch: commit.state.epoch, device: identity, store: endpointStore, client: nodeClient)
                do {
                    try await verifyConnection()
                    initialPresentation = .connected
                } catch {
                    initialPresentation = .connectionFailed
                }
            } catch {
                initialPresentation = .recoveryRequired
            }
            return SyncNodeEnrollmentViewModel(
                coordinator: coordinator,
                profile: currentProfile,
                owner: enrollmentOwner,
                initialConnectionPresentation: initialPresentation,
                retireProfile: { capabilityID in try bootstrapImportModel.retireProfile(expectedCapabilityID: capabilityID) },
                verifyConnection: verifyConnection
            )
        }

        guard let currentProfile else { throw LoadError.noSyncNode }
        return SyncNodeEnrollmentViewModel(
            coordinator: coordinator,
            profile: currentProfile,
            owner: enrollmentOwner,
            retireProfile: { capabilityID in try bootstrapImportModel.retireProfile(expectedCapabilityID: capabilityID) },
            verifyConnection: verifyConnection
        )
    }
}
