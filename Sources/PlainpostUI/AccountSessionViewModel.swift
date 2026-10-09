import Foundation
import Combine
import AuthenticationServices
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNodeTransport
import PlainpostServiceIPC
import SwiftUI

public struct SyncNodeEnrollmentOwner: Equatable, Sendable {
    public let accountID: PlainpostAccountID
    public let deviceID: AccountDeviceID

    public init(accountID: PlainpostAccountID, deviceID: AccountDeviceID) {
        self.accountID = accountID
        self.deviceID = deviceID
    }
}

/// The only presentation boundary allowed to decide whether mailbox data may
/// be constructed. Views consume this closed state and never inspect account
/// credentials or Keychain records directly.
@MainActor
public final class AccountSessionViewModel: ObservableObject {
    private enum AppleSignInPhase: Equatable {
        case awaitingAuthorization
        case bootstrapping
    }

    private struct AppleSignInAttempt {
        let id: UUID
        let rawNonce: Data
        var phase: AppleSignInPhase
    }

    public struct AppleSignInRequest: Equatable, Sendable {
        public let id: UUID
        public let nonce: String
    }

    public enum Presentation: Equatable, Sendable {
        case signInRequired
        case pendingApproval(matchingCode: String?)
        case active
        case offlineLease(expiresAt: Date)
        case suspended
        case cleanupRequired
        case deleted
        case recoveryRequired

        public var allowsMailbox: Bool {
            switch self {
            case .active, .offlineLease: true
            case .signInRequired, .pendingApproval, .suspended, .cleanupRequired, .deleted, .recoveryRequired: false
            }
        }

        public var allowsMailboxMutations: Bool {
            if case .active = self { return true }
            return false
        }

        public var matchingCodeDisplay: String? {
            guard case .pendingApproval(let matchingCode) = self,
                  let matchingCode,
                  matchingCode.utf8.count == 6,
                  matchingCode.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return nil
            }
            return "\(matchingCode.prefix(3)) \(matchingCode.suffix(3))"
        }

        public var offlineLeaseExpiry: Date? {
            guard case .offlineLease(let expiresAt) = self else { return nil }
            return expiresAt
        }
    }

    public typealias Prepare = @Sendable (Date) async -> AccountSessionState
    public typealias NonceGenerator = () throws -> Data
    public typealias BootstrapAppleCredential = @Sendable (_ identityToken: String, _ rawNonce: Data) async throws -> AccountSessionState
    public typealias AdmissionFactory = @MainActor @Sendable (AccountActivation) throws -> AccountPendingAdmissionFlow
    public typealias ActiveAdmissionFactory = @MainActor @Sendable () throws -> AccountActiveAdmissionFlow
    public typealias ActiveCleanupRegistration = @Sendable () async -> Void
    public typealias SecurityFactory = @MainActor @Sendable (AccountSessionViewModel) -> AccountSecurityViewModel
    public typealias SyncNodeEnrollmentFactory = @MainActor @Sendable () async throws -> SyncNodeEnrollmentViewModel
    public typealias SyncNodeEnrollmentOwnerReader = @MainActor @Sendable () throws -> SyncNodeEnrollmentOwner?

    public enum SyncNodeEnrollmentLoadPresentation: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// The account has no Sync Node and no Server Setup is imported: setup is next.
        case noSyncNode
        /// The load failed for another reason, so whether the account has a Node is unknown.
        case failed(message: String)

        /// What a failed enrollment load shows. Only the deliberate "nothing to connect to"
        /// error means No Sync Node; any other failure is a real one, never "not set up".
        public init(loadError error: any Error) {
            if let error = error as? SyncNodeEnrollmentAssembly.LoadError, error == .noSyncNode {
                self = .noSyncNode
            } else if error as? AccountRuntimeError == .transportFailure || error is URLError {
                self = .failed(message: Self.unreachableMessage)
            } else {
                self = .failed(message: Self.failureMessage)
            }
        }

        public static let failureMessage = "Sync Node connection information couldn’t be loaded. Try again."
        public static let unreachableMessage = "Plainpost couldn’t reach its server. Check your connection and try again."
    }

    public typealias CalendarAuthorityFactory = @MainActor @Sendable () async throws -> PlainpostCalendarAuthority
    /// Re-reads the session's sending-mailbox choices (the Node's "drafts" role
    /// assignments) without touching the live calendar authority. Separate from
    /// `CalendarAuthorityFactory` so a stale, empty mailbox list can be refreshed
    /// non-destructively, instead of invalidating and recreating the authority
    /// other calendar surfaces (week view, thread invitations) are still using.
    public typealias CalendarSendingMailboxesFactory = @MainActor @Sendable () async -> [CalendarSendingMailbox]
    @Published public private(set) var calendarAuthority: PlainpostCalendarAuthority?
    private let calendarAuthorityFactory: CalendarAuthorityFactory?
    private let calendarSendingMailboxesFactory: CalendarSendingMailboxesFactory?
    private let calendarAccountIDReader: (@Sendable () -> String?)?
    public var calendarCacheAccountID: String? {
        guard presentation.allowsMailbox, !isShutDownForServerChange else { return nil }
        return calendarAuthority?.accountID ?? calendarAccountIDReader?()
    }
    private var calendarGeneration: UInt64 = 0

    public func prepareCalendarAuthority() async {
        guard presentation == .active, !isShutDownForServerChange else { await invalidateCalendarAuthority(); return }
        if let existing = calendarAuthority, let calendarAccountIDReader, existing.accountID != calendarAccountIDReader() {
            await invalidateCalendarAuthority()
        }
        guard calendarAuthority == nil, let calendarAuthorityFactory else { return }
        calendarGeneration &+= 1; let started = calendarGeneration
        do {
            let candidate = try await calendarAuthorityFactory()
            guard calendarGeneration == started, presentation == .active, !isShutDownForServerChange else { await candidate.invalidate(); return }
            calendarAuthority = candidate
        } catch { /* Calendar availability never blocks mail admission. */ }
    }
    public func invalidateCalendarAuthority() async {
        calendarGeneration &+= 1
        let old = calendarAuthority; calendarAuthority = nil
        await old?.invalidate()
    }
    /// Non-destructive: re-reads the mailbox list from the session without
    /// invalidating or recreating `calendarAuthority`. Falls back to the
    /// current authority's (possibly still-empty) list where no factory is
    /// wired, e.g. design previews and tests.
    public func refreshCalendarSendingMailboxes() async -> [CalendarSendingMailbox] {
        guard let calendarSendingMailboxesFactory else { return calendarAuthority?.sendingMailboxes ?? [] }
        return await calendarSendingMailboxesFactory()
    }

    @Published public private(set) var presentation: Presentation = .signInRequired
    /// Set when the last prepare failed for a reason that may clear by
    /// itself (Central unreachable, login keychain still locked).
    @Published public private(set) var transientFailure: AccountSessionTransientFailure?
    /// Reads the controller's transient failure after each prepare.
    public var transientFailureReader: (@Sendable () async -> AccountSessionTransientFailure?)?
    @Published public private(set) var isAppleSignInInFlight = false
    @Published public private(set) var appleSignInErrorMessage: String?
    @Published public private(set) var pendingApprovalPrompt: AccountActiveAdmissionController.PendingPrompt?
    @Published public private(set) var pendingDeviceApproval: PendingDeviceApprovalPresentation = .hidden
    private var pendingDeviceApprovalTracker = PendingDeviceApprovalTracker() {
        didSet {
            pendingApprovalPrompt = pendingDeviceApprovalTracker.currentPrompt
            pendingDeviceApproval = pendingDeviceApprovalTracker.presentation
        }
    }
    @Published public private(set) var deviceApprovalPrompt: AccountActiveAdmissionController.ConfirmationPrompt?
    public let centralServerOrigin: URL?
    private var approvalCapability: AccountDeviceApprovalCapability?
    private let prepareSession: Prepare
    private let discardSuspendedSession: Prepare?
    private let nonceGenerator: NonceGenerator
    private let bootstrapAppleCredential: BootstrapAppleCredential?
    private let admissionFactory: AdmissionFactory?
    private let activeAdmissionFactory: ActiveAdmissionFactory?
    private let activeCleanupRegistration: ActiveCleanupRegistration?
    private let securityFactory: SecurityFactory?
    private let syncNodeEnrollmentFactory: SyncNodeEnrollmentFactory?
    private let syncNodeEnrollmentOwnerReader: SyncNodeEnrollmentOwnerReader?
    private let automaticallyPrepareSyncNodeOnActive: Bool
    private var prepareTask: Task<Void, Never>?
    /// Identifies the prepare in flight. Every exit of that task clears
    /// `prepareTask` while it is still the current one, so a generation bump
    /// elsewhere (Apple sign-in, cancel) cannot leave a finished task behind
    /// that blocks background refreshes forever.
    private var prepareTaskID: UInt64 = 0
    private var appleSignInTask: Task<Void, Never>?
    private var isShutDownForServerChange = false
    private var expiryTask: Task<Void, Never>?
    private var cleanupRegistrationTask: Task<Void, Never>?
    private var appleAttempt: AppleSignInAttempt?
    private var deviceApprovalAppleAttempt: (id: UUID, rawNonce: Data)?
    private var generation: UInt64 = 0
    private var admissionController: AccountPendingAdmissionFlow?
    private var admissionObservation: AnyCancellable?
    private var activeAdmissionController: AccountActiveAdmissionFlow?
    private var activeAdmissionObservation: AnyCancellable?
    private let deviceApprovalCoordinator: AccountDeviceApprovalCoordinator
    public private(set) lazy var securityModel: AccountSecurityViewModel? = securityFactory?(self)
    @Published public private(set) var syncNodeEnrollmentModel: SyncNodeEnrollmentViewModel?
    /// The enrollment model whose owner last read as the active session.
    /// It is refreshed when the presentation or the model changes, so view
    /// bodies never call the owner reader (a Keychain read in production).
    /// It is held weakly and compared by identity, so a released model can
    /// never lend its verdict to a new one allocated at the same address.
    private weak var ownerVerifiedSyncNodeEnrollmentModel: SyncNodeEnrollmentViewModel?
    @Published public private(set) var syncNodeEnrollmentLoadPresentation: SyncNodeEnrollmentLoadPresentation = .idle
    public let syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel?
    private var syncNodeEnrollmentTask: Task<Void, Never>?
    private var syncNodeEnrollmentAttemptID: UUID?
    private var deferredSyncNodeProfileGeneration: UInt64?

    public init(
        prepareSession: @escaping Prepare,
        discardSuspendedSession: Prepare? = nil,
        centralServerOrigin: URL? = nil,
        nonceGenerator: NonceGenerator? = nil,
        bootstrapAppleCredential: BootstrapAppleCredential? = nil,
        admissionFactory: AdmissionFactory? = nil,
        activeAdmissionFactory: ActiveAdmissionFactory? = nil,
        activeCleanupRegistration: ActiveCleanupRegistration? = nil,
        securityFactory: SecurityFactory? = nil,
        syncNodeEnrollmentFactory: SyncNodeEnrollmentFactory? = nil,
        syncNodeEnrollmentOwnerReader: SyncNodeEnrollmentOwnerReader? = nil,
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel? = nil,
        automaticallyPrepareSyncNodeOnActive: Bool = false,
        localApprovalAuthenticator: (any LocalApprovalAuthenticating)? = nil,
        calendarAuthorityFactory: CalendarAuthorityFactory? = nil,
        calendarSendingMailboxesFactory: CalendarSendingMailboxesFactory? = nil,
        calendarAccountIDReader: (@Sendable () -> String?)? = nil
    ) {
        self.calendarAccountIDReader = calendarAccountIDReader
        self.calendarAuthorityFactory = calendarAuthorityFactory
        self.calendarSendingMailboxesFactory = calendarSendingMailboxesFactory
        self.prepareSession = prepareSession
        self.discardSuspendedSession = discardSuspendedSession
        self.centralServerOrigin = centralServerOrigin
        self.nonceGenerator = nonceGenerator ?? {
            var generator = SystemRandomNumberGenerator()
            return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
        self.bootstrapAppleCredential = bootstrapAppleCredential
        self.admissionFactory = admissionFactory
        self.activeAdmissionFactory = activeAdmissionFactory
        self.activeCleanupRegistration = activeCleanupRegistration
        self.securityFactory = securityFactory
        self.syncNodeEnrollmentFactory = syncNodeEnrollmentFactory
        self.syncNodeEnrollmentOwnerReader = syncNodeEnrollmentOwnerReader
        self.syncNodeBootstrapImportModel = syncNodeBootstrapImportModel
        self.automaticallyPrepareSyncNodeOnActive = automaticallyPrepareSyncNodeOnActive
        self.deviceApprovalCoordinator = AccountDeviceApprovalCoordinator(
            authenticator: localApprovalAuthenticator ?? LocalApprovalAuthenticatorFactory.defaultAuthenticator()
        )
    }

    public convenience init(controller: AccountSessionController) {
        self.init { now in await controller.prepare(now: now) }
    }

    /// The Node's "drafts"-role mailbox assignments, as calendar sending-mailbox
    /// choices. Shared by the authority factory and the non-destructive refresh
    /// so both list the same mailboxes the same way.
    private static func sendingMailboxChoices(_ assignments: NodeSyncMailboxAssignmentsResult?) -> [CalendarSendingMailbox] {
        assignments?.assignments.compactMap { mailbox -> CalendarSendingMailbox? in
            guard mailbox.role == "drafts", let id = mailbox.logicalMailboxID else { return nil }
            return CalendarSendingMailbox(id: id.rawValue.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""), name: mailbox.displayName)
        } ?? []
    }

    public static func production(
        server: CentralServerConfiguration,
        credentials: AccountCredentialStore,
        nodeSessionClient: (any PlainpostServiceClientProtocol)?,
        purgeManagedData: @escaping AccountLifecycleController.ManagedDataPurge = { _ in
            throw AccountRuntimeError.secretUnavailable
        }
    ) throws -> AccountSessionViewModel {
        let manifest = try BootstrapKeyManifestStore()
        let client = try AccountAPIClient(credentialStore: credentials, manifestStore: manifest, baseURL: server.origin)
        let controller = try AccountSessionRuntimeAssembly.bundledController(credentials: credentials, bootstrapManifest: manifest, baseURL: server.origin)
        let authenticator = LocalApprovalAuthenticatorFactory.defaultAuthenticator()
        let bootstrapImportModel = SyncNodeBootstrapImportViewModel(
            store: SyncNodeBootstrapProfileStore()
        )
        // PlainpostService owns the Node session on macOS; the app reaches it
        // only through this connection.
        let nodeSessionClient: any PlainpostServiceClientProtocol = nodeSessionClient ?? PlainpostServiceClient()
        let model = AccountSessionViewModel(
            prepareSession: { now in
                if let deletion = (try? credentials.loadLocalDeletion()) ?? nil {
                    do {
                        let cleanup: AccountLifecycleController
                        if deletion.phase == .localPurged {
                            cleanup = try AccountLifecycleController(remote: client, credentialStore: credentials, device: try AccountDeviceIdentity.generate(), platform: .macos, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.secretUnavailable }, manifestStore: manifest, authenticate: { _ in false }, purgeManagedData: purgeManagedData)
                        } else {
                            cleanup = try credentials.makeLifecycleController(client: client, manifestStore: manifest, platform: .macos, authenticate: { _ in false }, purgeManagedData: purgeManagedData)
                        }
                        try await cleanup.resumeLocalDeletion()
                    } catch { return .cleanupRequired }
                }
                return await controller.prepare(now: now)
            },
            discardSuspendedSession: { now in await controller.discardSuspendedSession(now: now) },
            centralServerOrigin: server.origin,
            bootstrapAppleCredential: { token, nonce in
                let identity = try credentials.loadOrCreateDeviceIdentity()
                _ = try await client.bootstrapAppleCredential(
                    identityToken: token,
                    nonce: nonce,
                    device: identity
                )
                return await controller.prepare(now: Date())
            },
            admissionFactory: { activation in
                guard let session = try credentials.loadSession(), let sessionCredentials = session.credentials else { throw AccountRuntimeError.corruptSecret }
                let identity = try credentials.loadOrCreateDeviceIdentity()
                let rendezvous = CentralAccountAdmissionRendezvous(client: client, credentials: sessionCredentials, identity: identity)
                return AccountPendingAdmissionFlow(controller: try AccountAdmissionController(rendezvous: rendezvous, pending: activation, publicBundle: identity.publicBundle, poll: { await controller.prepare(now: Date()) }))
            },
            activeAdmissionFactory: { AccountActiveAdmissionFlow(controller: try credentials.makeActiveAdmissionController(client: client, platform: .macos)) },
            activeCleanupRegistration: {
                guard let lifecycle = try? credentials.makeLifecycleController(
                    client: client,
                    manifestStore: manifest,
                    platform: .macos,
                    authenticate: { _ in false }
                ) else { return }
                _ = try? await lifecycle.registerCurrentCleanupTarget()
            },
            securityFactory: { model in
                let calendarPurge: AccountLifecycleController.ManagedDataPurge = { [weak model] request in
                    await model?.invalidateCalendarAuthority()
                    return try await purgeManagedData(request)
                }
                return AccountSecurityViewModel(
                    controllerFactory: {
                        try credentials.makeLifecycleController(
                            client: client,
                            manifestStore: manifest,
                            platform: .macos,
                            authenticate: { action in
                                try await authenticator.authenticate(reason: "Confirm \(action.rawValue.replacingOccurrences(of: "_", with: " ")) in Plainpost.")
                                return true
                            },
                            purgeManagedData: calendarPurge
                        )
                    },
                    recoveryControllerFactory: {
                        try credentials.makeRecoveryLifecycleController(
                            client: client,
                            manifestStore: manifest,
                            platform: .macos,
                            authenticate: { action in
                                try await authenticator.authenticate(reason: "Confirm \(action.rawValue.replacingOccurrences(of: "_", with: " ")) in Plainpost.")
                                return true
                            },
                            purgeManagedData: calendarPurge
                        )
                    },
                    stateChanged: { [weak model] in model?.prepare() }
                )
            },
            syncNodeEnrollmentFactory: {
                // Never instantiate a verifier from the bundle directly here:
                // SessionKeyManifestStore persists the authenticated high-water
                // and rejects a bundled downgrade after a key rotation.
                let sessionManifest = try SessionKeyManifestStore(
                    bundledDocument: SessionKeyManifestStore.bundledManifest,
                    offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
                    offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey
                ).verifier()
                // Enrollment and activation write the Node session into the
                // group PlainpostService reads; after that the app checks the
                // connection only through the service broker.
                return try await SyncNodeEnrollmentAssembly.makeModel(
                    client: client, credentials: credentials, sessionController: controller, platform: .macos,
                    sessionManifest: sessionManifest, authenticator: authenticator, bootstrapImportModel: bootstrapImportModel,
                    endpointStore: try SyncNodeEndpointStore(accessGroup: PlainpostAccountSharedKeychain.accessGroup),
                    brokeredConnection: SyncNodeBrokeredConnection(serviceClient: nodeSessionClient)
                )
            },
            syncNodeEnrollmentOwnerReader: {
                try SyncNodeEnrollmentAssembly.activeSessionOwner(credentials: credentials)
            },
            syncNodeBootstrapImportModel: bootstrapImportModel,
            automaticallyPrepareSyncNodeOnActive: true,
            localApprovalAuthenticator: authenticator,
            calendarAuthorityFactory: {
                guard let session = try credentials.loadSession(), session.state == .active, let current = session.credentials else { throw AccountRuntimeError.secretUnavailable }
                // PlainpostService owns the Node session; calendar traffic
                // goes through its broker and never through an app transport.
                let sender = ServiceBrokeredNodeSender(serviceClient: nodeSessionClient)
                let assignments: NodeSyncMailboxAssignmentsResult?
                do {
                    let response = try await sender.send(method: "GET", path: "/v1/mailboxes/assignments", body: Data(), maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
                    assignments = (200...299).contains(response.statusCode) ? try? NodeSyncCodec.decodeMailboxAssignmentsResult(response.body) : nil
                } catch PlainpostServiceClientError.nodeSession(.noActiveSession), PlainpostServiceClientError.nodeSession(.noEnrolledNode), PlainpostServiceClientError.nodeSession(.notAdmitted) {
                    throw AccountRuntimeError.secretUnavailable
                } catch {
                    assignments = nil
                }
                let sync = NodeSyncClient(sender: sender)
                let choices = Self.sendingMailboxChoices(assignments)
                return PlainpostCalendarAuthority(client: sync.calendarClient(), accountID: current.accountID.rawValue, sendingMailboxes: choices)
            },
            // Non-destructive counterpart to `calendarAuthorityFactory`: a bare,
            // best-effort re-read of the same "drafts" mailbox assignments that
            // never throws and never touches the live calendar authority, so
            // Settings can refresh a stale empty mailbox list without
            // invalidating the authority the week view and thread invitations
            // are still using.
            calendarSendingMailboxesFactory: {
                let sender = ServiceBrokeredNodeSender(serviceClient: nodeSessionClient)
                let assignments: NodeSyncMailboxAssignmentsResult?
                do {
                    let response = try await sender.send(method: "GET", path: "/v1/mailboxes/assignments", body: Data(), maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
                    assignments = (200...299).contains(response.statusCode) ? try? NodeSyncCodec.decodeMailboxAssignmentsResult(response.body) : nil
                } catch {
                    assignments = nil
                }
                return Self.sendingMailboxChoices(assignments)
            },
            calendarAccountIDReader: { (try? credentials.loadSession())?.credentials?.accountID.rawValue }
        )
        model.transientFailureReader = { await controller.lastTransientFailure }
        Task { [weak model] in
            await controller.setStateObserver { [weak model] state, failure in
                await model?.receiveBackgroundSessionState(state, transientFailure: failure)
            }
        }
        return model
    }

    #if DEBUG
    public static func debugAuthorized() -> AccountSessionViewModel {
        let model = AccountSessionViewModel(prepareSession: { _ in .active })
        model.presentation = .active
        return model
    }
    #endif

    deinit {
        prepareTask?.cancel()
        appleSignInTask?.cancel()
        expiryTask?.cancel()
        syncNodeEnrollmentTask?.cancel()
    }

    /// Shown in place of a retained Sync Node connection while its owner's
    /// session isn't the active one. It names no server, Node or account, and
    /// it stays accurate when the owner is signed in but not active.
    public static let syncNodeEnrollmentOwnerRequiredMessage = "Finish this Sync Node connection when the account that started it is signed in and active."

    /// The Sync Node model views may render. A retained admission outlives
    /// sign-out in memory, but its server, Node fingerprint and actions belong
    /// to the account that started it, so they render only while that
    /// account's session is active and reads as its owner. A Keychain read
    /// error hides it. The owner match is cached, never read while rendering.
    public var presentableSyncNodeEnrollmentModel: SyncNodeEnrollmentViewModel? {
        guard let model = syncNodeEnrollmentModel,
              presentation.allowsMailbox,
              ownerVerifiedSyncNodeEnrollmentModel === model else { return nil }
        return model
    }

    /// A model is kept in memory but may not render for the current session.
    public var syncNodeEnrollmentAwaitsOwner: Bool {
        syncNodeEnrollmentModel != nil && presentableSyncNodeEnrollmentModel == nil
    }

    public func prepareSyncNodeEnrollment() {
        guard presentation == .active,
              syncNodeEnrollmentModel == nil,
              syncNodeEnrollmentTask == nil,
              let syncNodeEnrollmentFactory else { return }
        let attemptID = UUID()
        let expectedAccountGeneration = generation
        let expectedProfileGeneration = syncNodeBootstrapImportModel?.profileGeneration
        let expectedCapabilityID: Data?
        do { expectedCapabilityID = try syncNodeBootstrapImportModel?.loadProfile()?.capabilityID }
        catch { expectedCapabilityID = nil }
        syncNodeEnrollmentAttemptID = attemptID
        syncNodeEnrollmentLoadPresentation = .loading
        syncNodeEnrollmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await syncNodeEnrollmentFactory()
                guard !Task.isCancelled,
                      generation == expectedAccountGeneration,
                      syncNodeEnrollmentAttemptID == attemptID,
                      syncNodeEnrollmentOwnerFenceAllowsPublication(model),
                      profileFenceAllowsResult(expectedGeneration: expectedProfileGeneration, expectedCapabilityID: expectedCapabilityID)
                else {
                    discardStaleSyncNodeEnrollmentAttempt(attemptID)
                    return
                }
                syncNodeEnrollmentModel = model
                // The fence above just read this model's owner as current.
                refreshSyncNodeEnrollmentOwnerMatch(verifiedModel: model)
                model.setInstallationConvergedHandler { [weak self, weak model] in
                    guard let model else { return }
                    self?.syncNodeEnrollmentDidConverge(model)
                }
                syncNodeEnrollmentLoadPresentation = .ready
                syncNodeEnrollmentTask = nil
                syncNodeEnrollmentAttemptID = nil
            } catch {
                guard !Task.isCancelled,
                      generation == expectedAccountGeneration,
                      syncNodeEnrollmentAttemptID == attemptID else { return }
                syncNodeEnrollmentLoadPresentation = SyncNodeEnrollmentLoadPresentation(loadError: error)
                syncNodeEnrollmentTask = nil
                syncNodeEnrollmentAttemptID = nil
            }
        }
    }

    public func retrySyncNodeEnrollment() {
        guard case .failed = syncNodeEnrollmentLoadPresentation else { return }
        syncNodeEnrollmentLoadPresentation = .idle
        prepareSyncNodeEnrollment()
    }

    private func profileFenceAllowsResult(expectedGeneration: UInt64?, expectedCapabilityID: Data?) -> Bool {
        guard let expectedGeneration, let syncNodeBootstrapImportModel else { return true }
        if syncNodeBootstrapImportModel.profileGeneration == expectedGeneration { return true }
        // The owned durable-success retirement changes the generation and
        // leaves no live profile. A genuinely newer import remains fenced.
        guard expectedCapabilityID != nil,
              syncNodeBootstrapImportModel.profileGeneration == (expectedGeneration &+ 1)
        else { return false }
        do { return try syncNodeBootstrapImportModel.loadProfile() == nil }
        catch { return false }
    }

    private func discardStaleSyncNodeEnrollmentAttempt(_ attemptID: UUID) {
        guard syncNodeEnrollmentAttemptID == attemptID else { return }
        syncNodeEnrollmentTask = nil
        syncNodeEnrollmentAttemptID = nil
        syncNodeEnrollmentLoadPresentation = .idle
    }

    public var showsSyncNodeBootstrapImport: Bool {
        presentation == .signInRequired && syncNodeBootstrapImportModel != nil
    }

    /// Server Setup import for the signed-in Settings page. The sign-in
    /// screen keeps its own `showsSyncNodeBootstrapImport` gate.
    public var syncNodeSettingsImportModel: SyncNodeBootstrapImportViewModel? {
        presentation.allowsMailbox ? syncNodeBootstrapImportModel : nil
    }

    /// Routes a Server Setup file-importer result through the same profile
    /// change handling as an opened `.plainpostserver` document.
    public func handleSyncNodeBootstrapFileImporter(_ result: Result<[URL], Error>) {
        guard let syncNodeBootstrapImportModel else { return }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        syncNodeBootstrapImportModel.handleFileImporter(result)
        _ = applySyncNodeBootstrapProfileChange(from: priorGeneration)
    }

    @discardableResult
    public func importSyncNodeBootstrapProfile(from url: URL) -> Bool {
        guard let syncNodeBootstrapImportModel else { return false }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        syncNodeBootstrapImportModel.importFile(at: url)
        return applySyncNodeBootstrapProfileChange(from: priorGeneration)
    }

    @discardableResult
    public func updateSyncNodeServerOrigin(
        _ originText: String
    ) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate {
        guard let syncNodeBootstrapImportModel else { return .unavailable }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        let result = syncNodeBootstrapImportModel.replaceServerOrigin(originText)
        guard case .saved = result else { return result }
        _ = applySyncNodeBootstrapProfileChange(from: priorGeneration)
        return result
    }

    private func applySyncNodeBootstrapProfileChange(from priorGeneration: UInt64) -> Bool {
        guard let syncNodeBootstrapImportModel,
              syncNodeBootstrapImportModel.profileGeneration != priorGeneration
        else { return false }
        if syncNodeEnrollmentModel?.retainsInstallationReplay == true {
            // The imported profile is durable, while the existing model keeps
            // the only exact request needed to converge an ambiguous install.
            deferredSyncNodeProfileGeneration = syncNodeBootstrapImportModel.profileGeneration
            return true
        }
        resetSyncNodeEnrollment()
        if presentation == .active { prepareSyncNodeEnrollment() }
        return true
    }

    public func prepare(now: Date = Date()) {
        guard !isShutDownForServerChange else { return }
        generation &+= 1
        resetSyncNodeEnrollment()
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = nil
        appleSignInTask?.cancel()
        appleSignInTask = nil
        resetAdmissionFlows()
        let expectedGeneration = generation
        prepareTask?.cancel()
        let prepareSession = prepareSession
        let transientFailureReader = transientFailureReader
        prepareTaskID &+= 1
        let taskID = prepareTaskID
        prepareTask = Task { [weak self] in
            let state = await prepareSession(now)
            let failure = await transientFailureReader?()
            guard let self else { return }
            defer { self.finishPrepareTask(taskID) }
            guard !Task.isCancelled, self.generation == expectedGeneration else { return }
            self.transientFailure = failure
            self.apply(state, now: now)
        }
    }

    private func finishPrepareTask(_ taskID: UInt64) {
        guard prepareTaskID == taskID else { return }
        prepareTask = nil
    }

    /// A retry nobody is looking at (the recovery monitor while no window is
    /// open). Unlike `prepare()` it leaves admission, enrollment and sign-in
    /// flows alone unless the session state actually changes, and it never
    /// overrides a foreground prepare.
    public func refreshInBackground(now: Date = Date()) {
        guard prepareTask == nil, !isShutDownForServerChange else { return }
        let expectedGeneration = generation
        let prepareSession = prepareSession
        let transientFailureReader = transientFailureReader
        prepareTaskID &+= 1
        let taskID = prepareTaskID
        prepareTask = Task { [weak self] in
            let state = await prepareSession(now)
            let failure = await transientFailureReader?()
            guard let self else { return }
            defer { self.finishPrepareTask(taskID) }
            guard !Task.isCancelled, self.generation == expectedGeneration else { return }
            self.transientFailure = failure
            guard Self.presentation(for: state, now: now) != self.presentation else { return }
            self.apply(state, now: now)
        }
    }

    /// Result of a refresh the controller scheduled on its own. A foreground
    /// prepare in flight wins; otherwise a changed presentation applies
    /// (for example active to offline after Central became unreachable).
    public func receiveBackgroundSessionState(
        _ state: AccountSessionState,
        transientFailure: AccountSessionTransientFailure?,
        now: Date = Date()
    ) {
        guard prepareTask == nil, !isShutDownForServerChange else { return }
        self.transientFailure = transientFailure
        guard Self.presentation(for: state, now: now) != presentation else { return }
        apply(state, now: now)
    }

    public func cancel() {
        generation &+= 1
        resetSyncNodeEnrollment()
        prepareTask?.cancel()
        prepareTask = nil
        prepareTaskID &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        resetAdmissionFlows()
        cancelAppleSignIn()
    }

    public func shutdownForServerChange() async {
        isShutDownForServerChange = true
        await invalidateCalendarAuthority()
        let running = [
            prepareTask,
            appleSignInTask,
            expiryTask,
            cleanupRegistrationTask,
            syncNodeEnrollmentTask,
        ].compactMap { $0 }
        cancel()
        cleanupRegistrationTask?.cancel()
        cleanupRegistrationTask = nil
        for task in running { await task.value }
    }

    public func beginAppleSignIn() throws -> AppleSignInRequest {
        guard !isShutDownForServerChange else { throw AccountRuntimeError.cancelled }
        guard appleAttempt?.phase != .bootstrapping else {
            throw AccountRuntimeError.cancelled
        }
        generation &+= 1
        appleSignInTask?.cancel()
        appleSignInTask = nil
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = nil
        let rawNonce: Data
        do {
            rawNonce = try nonceGenerator()
            guard rawNonce.count == 32 else { throw AccountRuntimeError.cryptographicFailure }
        } catch {
            appleSignInErrorMessage = Self.appleSignInFailureMessage
            throw error
        }
        let id = UUID()
        appleAttempt = AppleSignInAttempt(
            id: id,
            rawNonce: rawNonce,
            phase: .awaitingAuthorization
        )
        isAppleSignInInFlight = true
        return AppleSignInRequest(id: id, nonce: AccountWireCodec.encodeBase64URL(rawNonce))
    }

    /// Transitions the owned attempt to bootstrap exactly once. The raw token
    /// is captured only by the in-flight task; it is never presentation state,
    /// a log value, or a persisted value.
    public func submitAppleIdentityToken(_ tokenData: Data, for attemptID: UUID) {
        guard var attempt = appleAttempt,
              attempt.id == attemptID,
              attempt.phase == .awaitingAuthorization else { return }
        guard
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty,
              let bootstrapAppleCredential else {
            finishAppleSignIn(attemptID: attemptID, errorMessage: Self.appleSignInFailureMessage)
            return
        }
        attempt.phase = .bootstrapping
        appleAttempt = attempt
        let expectedGeneration = generation
        appleSignInTask?.cancel()
        appleSignInTask = Task { [weak self] in
            do {
                let state = try await bootstrapAppleCredential(identityToken, attempt.rawNonce)
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.appleAttempt?.id == attemptID,
                      self.appleAttempt?.phase == .bootstrapping else { return }
                // An existing account may need recovery next; it reuses this sign-in
                // rather than asking Apple again (`appleSignInForRecovery`).
                self.recentAppleSignIn = RecentAppleSignIn(
                    identityToken: identityToken, rawNonce: attempt.rawNonce, obtainedAt: Date()
                )
                self.apply(state, now: Date())
                self.appleAttempt = nil
                self.appleSignInTask = nil
                self.appleSignInErrorMessage = nil
                self.isAppleSignInInFlight = false
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.appleAttempt?.id == attemptID,
                      self.appleAttempt?.phase == .bootstrapping else { return }
                self.appleAttempt = nil
                self.appleSignInTask = nil
                self.isAppleSignInInFlight = false
                self.appleSignInErrorMessage = AppleSignInFailureMessages.message(
                    for: error, deviceName: "Mac", fallback: Self.appleSignInFailureMessage
                )
                self.presentation = .signInRequired
            }
        }
    }

    /// Keeps the Apple identity token inside the session model. Native views
    /// forward only the authorization result and immutable attempt identity.
    public func completeAppleAuthorization(
        _ result: Result<ASAuthorization, Error>,
        for attemptID: UUID
    ) {
        guard appleAttempt?.id == attemptID,
              appleAttempt?.phase == .awaitingAuthorization else { return }
        switch result {
        case .failure(let error):
            finishAppleSignIn(
                attemptID: attemptID,
                errorMessage: Self.isAppleAuthorizationCancellation(error)
                    ? nil
                    : Self.appleSignInFailureMessage
            )
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken else {
                finishAppleSignIn(attemptID: attemptID, errorMessage: Self.appleSignInFailureMessage)
                return
            }
            submitAppleIdentityToken(token, for: attemptID)
        }
    }

    public func cancelAppleSignIn() {
        generation &+= 1
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = nil
        appleSignInTask?.cancel()
        appleSignInTask = nil
    }

    /// Held in memory only (never stored or logged) for the few minutes recovery may use it.
    private var recentAppleSignIn: RecentAppleSignIn?

    private static let appleSignInFailureMessage = "Sign in couldn’t be completed. Try again."

    private static func isAppleAuthorizationCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain
            && error.code == ASAuthorizationError.Code.canceled.rawValue
    }

    private func finishAppleSignIn(attemptID: UUID, errorMessage: String?) {
        guard appleAttempt?.id == attemptID else { return }
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = errorMessage
        appleSignInTask?.cancel()
        appleSignInTask = nil
    }

    public static func presentation(for state: AccountSessionState, now: Date) -> Presentation {
        switch state {
        case .provisional(let activation):
            return activation.mode == .pending ? .pendingApproval(matchingCode: nil) : .recoveryRequired
        case .active:
            return .active
        case .offlineLease(let expiresAt):
            return expiresAt > now ? .offlineLease(expiresAt: expiresAt) : .recoveryRequired
        case .signInRequired:
            return .signInRequired
        case .suspended:
            return .suspended
        case .cleanupRequired:
            return .cleanupRequired
        case .deleted:
            return .deleted
        case .expired:
            return .recoveryRequired
        }
    }

    private func apply(_ state: AccountSessionState, now: Date) {
        if let model = syncNodeEnrollmentModel,
           model.retainsInstallationReplay,
           syncNodeEnrollmentReplayBelongsToCurrentOwner(model) {
            // Keep the exact request while the same account/device remains
            // installed, even if this refresh temporarily presents offline.
        } else {
            resetSyncNodeEnrollment(force: true)
        }
        resetAdmissionFlows()
        setPresentation(Self.presentation(for: state, now: now), now: now)
        if case .active = state { scheduleCleanupRegistration() }
        if case .active = state, automaticallyPrepareSyncNodeOnActive { prepareSyncNodeEnrollment() }
        if case .active = state, let activeAdmissionFactory {
            do {
                let controller = try activeAdmissionFactory(); activeAdmissionController = controller
                activeAdmissionObservation = controller.states.sink { [weak self] state in
                    guard let self else { return }
                    self.pendingDeviceApprovalTracker.receive(state)
                    switch state {
                    case .idle, .awaitingResponse, .failed: self.deviceApprovalPrompt = nil; self.approvalCapability = nil
                    case .awaitingConfirmation(let prompt): self.deviceApprovalPrompt = prompt; self.approvalCapability = controller.currentApprovalCapability()
                    }
                }
                controller.refresh()
            } catch { setPresentation(.recoveryRequired, now: now) }
            return
        }
        guard case .provisional(let activation) = state, let admissionFactory else { return }
        do {
            let controller = try admissionFactory(activation)
            admissionController = controller
            admissionObservation = controller.states.sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .waiting: self.setPresentation(.pendingApproval(matchingCode: nil), now: Date())
                case .matchingCode(let code): self.setPresentation(.pendingApproval(matchingCode: code), now: Date())
                case .admitted:
                    self.setPresentation(.active, now: Date())
                    self.scheduleCleanupRegistration()
                case .expired, .failed: self.setPresentation(.recoveryRequired, now: Date())
                }
            }
            controller.start(now: now)
        } catch { setPresentation(.recoveryRequired, now: now) }
    }

    private func setPresentation(_ next: Presentation, now: Date) {
        expiryTask?.cancel()
        expiryTask = nil
        presentation = next
        refreshSyncNodeEnrollmentOwnerMatch()
        if !next.allowsMailboxMutations {
            calendarGeneration &+= 1
            let authority = calendarAuthority; calendarAuthority = nil
            Task { await authority?.invalidate() }
        }
        guard case .offlineLease(let expiresAt) = next, now < expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSince(now))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled,
                  let self,
                  self.presentation == .offlineLease(expiresAt: expiresAt) else { return }
            self.setPresentation(.recoveryRequired, now: Date())
        }
    }

    private func scheduleCleanupRegistration() {
        guard let activeCleanupRegistration else { return }
        cleanupRegistrationTask?.cancel()
        cleanupRegistrationTask = Task { await activeCleanupRegistration() }
    }

    private func resetSyncNodeEnrollment(force: Bool = false) {
        if !force,
           let model = syncNodeEnrollmentModel,
           model.retainsInstallationReplay,
           syncNodeEnrollmentReplayBelongsToCurrentOwner(model) {
            syncNodeEnrollmentLoadPresentation = .ready
            return
        }
        syncNodeEnrollmentTask?.cancel()
        syncNodeEnrollmentTask = nil
        syncNodeEnrollmentAttemptID = nil
        syncNodeEnrollmentModel?.setInstallationConvergedHandler(nil)
        syncNodeEnrollmentModel?.invalidateForReplacement()
        syncNodeEnrollmentModel = nil
        refreshSyncNodeEnrollmentOwnerMatch()
        syncNodeEnrollmentLoadPresentation = .idle
        if force { deferredSyncNodeProfileGeneration = nil }
    }

    private func syncNodeEnrollmentDidConverge(_ model: SyncNodeEnrollmentViewModel) {
        guard syncNodeEnrollmentModel === model,
              syncNodeEnrollmentReplayBelongsToCurrentOwner(model),
              let expectedGeneration = deferredSyncNodeProfileGeneration,
              let syncNodeBootstrapImportModel,
              syncNodeBootstrapImportModel.profileGeneration == expectedGeneration
        else { return }
        do {
            guard let profile = try syncNodeBootstrapImportModel.loadProfile(),
                  profile.capabilityID != model.provisionedCapabilityID
            else {
                deferredSyncNodeProfileGeneration = nil
                return
            }
        } catch {
            return
        }
        deferredSyncNodeProfileGeneration = nil
        resetSyncNodeEnrollment(force: true)
        if presentation == .active { prepareSyncNodeEnrollment() }
    }

    /// Reads the owner again for the current model. Both Sync Node surfaces
    /// call this when they appear, so a one-off Keychain read error does not
    /// hide the owner's own connection until the next session change. Call
    /// it from an appearance task, never from a view body.
    public func refreshSyncNodeEnrollmentOwner() {
        refreshSyncNodeEnrollmentOwnerMatch()
    }

    /// Reads the owner once for the current model and presentation. Called
    /// from `apply` (through `setPresentation`), `setPresentation`, model
    /// publication and reset, and surface appearance, never from a view body.
    private func refreshSyncNodeEnrollmentOwnerMatch(verifiedModel: SyncNodeEnrollmentViewModel? = nil) {
        var verified: SyncNodeEnrollmentViewModel?
        if let model = syncNodeEnrollmentModel, presentation.allowsMailbox,
           model === verifiedModel || syncNodeEnrollmentOwnerFenceAllowsPublication(model) {
            verified = model
        }
        guard ownerVerifiedSyncNodeEnrollmentModel !== verified else { return }
        objectWillChange.send()
        ownerVerifiedSyncNodeEnrollmentModel = verified
    }

    private func syncNodeEnrollmentOwnerFenceAllowsPublication(_ model: SyncNodeEnrollmentViewModel) -> Bool {
        guard let syncNodeEnrollmentOwnerReader else {
            return model.enrollmentOwner == nil
        }
        return syncNodeEnrollmentOwnerMatches(model, reader: syncNodeEnrollmentOwnerReader)
    }

    /// A retained admission is dropped only for a positively different
    /// owner. A session that does not read as active, or a Keychain read
    /// error, proves nothing, so the exact replay stays.
    private func syncNodeEnrollmentReplayBelongsToCurrentOwner(_ model: SyncNodeEnrollmentViewModel) -> Bool {
        guard let syncNodeEnrollmentOwnerReader, let owner = model.enrollmentOwner else { return false }
        do {
            guard let current = try syncNodeEnrollmentOwnerReader() else { return true }
            return current == owner
        } catch {
            return true
        }
    }

    private func syncNodeEnrollmentOwnerMatches(
        _ model: SyncNodeEnrollmentViewModel,
        reader: SyncNodeEnrollmentOwnerReader
    ) -> Bool {
        guard let owner = model.enrollmentOwner else { return false }
        do { return try reader() == owner }
        catch { return false }
    }

    /// Starts (or retries) review of the shown pending device. A review
    /// already in flight is never re-entered.
    public func beginApproval() {
        guard let activeAdmissionController, let prompt = pendingDeviceApprovalTracker.beginReview() else { return }
        activeAdmissionController.begin(prompt)
    }
    /// Hides the shown pending request for this app session. Dismissing a
    /// request that can no longer be approved refreshes the pending list.
    public func dismissPendingDeviceApproval() {
        if pendingDeviceApprovalTracker.dismiss() { activeAdmissionController?.refresh() }
    }
    /// The Apple sign-in just completed, while Central still accepts it for recovery.
    public func appleSignInForRecovery(now: Date = Date()) -> RecentAppleSignIn? {
        guard let recentAppleSignIn, recentAppleSignIn.isUsable(at: now) else { return nil }
        return recentAppleSignIn
    }

    /// Another device recovered or suspended this Plainpost Account, so this device's
    /// session can't come back. It signs in again like a new device: then a trusted device
    /// approves it, or it recovers the account.
    public var canSignInAgainAfterSuspension: Bool { discardSuspendedSession != nil }

    public func signInAgainAfterSuspension() {
        guard case .suspended = presentation, let discardSuspendedSession else { return }
        Task { [weak self] in
            let state = await discardSuspendedSession(Date())
            self?.apply(state, now: Date())
        }
    }

    public func cancelPendingApproval() {
        admissionObservation = nil
        admissionController?.cancel()
        admissionController = nil
        setPresentation(.recoveryRequired, now: Date())
    }
    public func confirmApproval() {
        guard let approvalCapability else { return }
        deviceApprovalCoordinator.present(approvalCapability)
        deviceApprovalCoordinator.approve()
    }

    public func beginDeviceApprovalAppleSignIn() throws -> AppleSignInRequest {
        guard deviceApprovalPrompt != nil, deviceApprovalAppleAttempt == nil else { throw AccountRuntimeError.cancelled }
        let nonce = try nonceGenerator()
        guard nonce.count == 32, !nonce.allSatisfy({ $0 == 0 }) else { throw AccountRuntimeError.cryptographicFailure }
        let id = UUID()
        deviceApprovalAppleAttempt = (id, nonce)
        return AppleSignInRequest(id: id, nonce: AccountWireCodec.encodeBase64URL(nonce))
    }

    public func completeDeviceApprovalAppleAuthorization(_ result: Result<ASAuthorization, Error>, for id: UUID) {
        guard let attempt = deviceApprovalAppleAttempt, attempt.id == id else { return }
        deviceApprovalAppleAttempt = nil
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8), !identityToken.isEmpty,
              let activeAdmissionController else { return }
        appleSignInTask?.cancel()
        appleSignInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capability = try await activeAdmissionController.authorizeCurrentApproval(identityToken: identityToken, appleNonce: attempt.rawNonce)
                guard self.activeAdmissionController != nil, self.deviceApprovalPrompt != nil else { await capability.cancel(); return }
                self.approvalCapability = capability
                self.deviceApprovalCoordinator.present(capability)
                self.deviceApprovalCoordinator.approve()
            } catch { }
        }
    }

    func installApprovalCapability(_ capability: AccountDeviceApprovalCapability) {
        approvalCapability = capability
    }

    func waitForDeviceApprovalToSettle() async {
        await deviceApprovalCoordinator.waitUntilIdle()
    }

    private func resetAdmissionFlows() {
        cleanupRegistrationTask?.cancel()
        cleanupRegistrationTask = nil
        admissionObservation = nil
        admissionController?.cancel()
        admissionController = nil
        activeAdmissionObservation = nil
        activeAdmissionController?.cancel()
        activeAdmissionController = nil
        deviceApprovalCoordinator.cancel()
        approvalCapability = nil
        deviceApprovalAppleAttempt = nil
        pendingDeviceApprovalTracker.resetFlow()
        deviceApprovalPrompt = nil
    }
}

/// Lazily owns a mailbox runtime after account authorization. The factory is
/// intentionally below this gate: constructing a forbidden root cannot open a
/// database, start wake work, or schedule mail side effects.
@MainActor
public final class AccountMailboxRuntimeGate<Runtime> {
    public enum Access: Equatable, Sendable {
        case readWrite
        case readOnly(expiresAt: Date)
    }

    public private(set) var runtime: Runtime?
    public private(set) var access: Access?
    private let makeRuntime: @MainActor (Access) async throws -> Runtime
    private let tearDown: @MainActor (Runtime) async -> Void
    private var expiryTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        makeRuntime: @escaping @MainActor (Access) async throws -> Runtime,
        tearDown: @escaping @MainActor (Runtime) async -> Void
    ) {
        self.makeRuntime = makeRuntime
        self.tearDown = tearDown
    }

    deinit { expiryTask?.cancel() }

    public func transition(to presentation: AccountSessionViewModel.Presentation, now: Date = Date()) async throws {
        let requestedAccess: Access?
        switch presentation {
        case .active:
            requestedAccess = .readWrite
        case .offlineLease(let expiresAt) where now < expiresAt:
            requestedAccess = .readOnly(expiresAt: expiresAt)
        case .signInRequired, .pendingApproval, .offlineLease, .suspended, .cleanupRequired, .deleted, .recoveryRequired:
            requestedAccess = nil
        }
        guard requestedAccess != access else { return }
        generation &+= 1
        let expectedGeneration = generation
        await closeCurrent(incrementGeneration: false)
        guard let requestedAccess else { return }
        let candidate = try await makeRuntime(requestedAccess)
        guard generation == expectedGeneration else {
            await tearDown(candidate)
            return
        }
        runtime = candidate
        access = requestedAccess
        if case .readOnly(let expiresAt) = requestedAccess {
            let delay = max(0, expiresAt.timeIntervalSince(Date()))
            expiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, self?.access == requestedAccess else { return }
                await self?.close()
            }
        }
    }

    public func close() async {
        generation &+= 1
        await closeCurrent(incrementGeneration: false)
    }

    public func requireReadWrite() throws -> Runtime {
        guard access == .readWrite, let runtime else { throw AccountRuntimeError.cancelled }
        return runtime
    }

    private func closeCurrent(incrementGeneration: Bool) async {
        if incrementGeneration { generation &+= 1 }
        expiryTask?.cancel()
        expiryTask = nil
        let existing = runtime
        runtime = nil
        access = nil
        if let existing { await tearDown(existing) }
    }
}

/// A Sign in with Apple result, kept in memory so account recovery can follow sign-in
/// without a second Apple prompt. Central accepts an Apple identity token for ten minutes
/// after Apple issued it; recovery stops offering it a minute earlier. Recovery still binds
/// it to this device's replacement keys and asks for local confirmation.
public struct RecentAppleSignIn: Sendable {
    public let identityToken: String
    public let rawNonce: Data
    public let obtainedAt: Date

    public init(identityToken: String, rawNonce: Data, obtainedAt: Date) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.obtainedAt = obtainedAt
    }

    public func isUsable(at now: Date) -> Bool {
        let age = now.timeIntervalSince(obtainedAt)
        return age >= 0 && age < 9 * 60
    }
}
