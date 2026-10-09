import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostNodeTransport
import PlainpostNodeMailMode
import PlainpostNotificationRuntime
import PlainpostUI
import SwiftUI

struct MobileManagedDataPurger: Sendable {
    private let clearNotificationState: @Sendable () throws -> Void

    init(
        clearNotificationState: @escaping @Sendable () throws -> Void
    ) {
        self.clearNotificationState = clearNotificationState
    }

    static func production() -> Self {
        Self(
            clearNotificationState: {
                #if canImport(Security)
                let accessGroup = Bundle.main.object(forInfoDictionaryKey: "PLAINPOST_NOTIFICATION_KEYCHAIN_GROUP") as? String
                try NotificationSharedKeychainStore(accessGroup: accessGroup).purgeAll()
                #endif
                UserDefaults.standard.removeObject(forKey: "Plainpost.lastWakeToken")
                Self.clearMailAccountSelections(in: .standard)
            }
        )
    }

    /// Removes every persisted mail account selection: the per-Plainpost-account
    /// keys and the old device-global key.
    static func clearMailAccountSelections(in defaults: UserDefaults) {
        let legacy = MobileAccountModel.legacySelectedMailAccountDefaultsKey
        for key in defaults.dictionaryRepresentation().keys where key == legacy || key.hasPrefix(MobileAccountModel.selectedMailAccountDefaultsKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func purge(accountID: PlainpostAccountID) throws -> Data {
        try clearNotificationState()
        return Data(SHA256.hash(data: Data("Plainpost.MobileManagedAccountPurge.v1\0\(accountID.rawValue)".utf8)))
    }
}

enum NotificationProducerAuthority: String, Equatable {
    case mac
    case syncNode
    case mixed
}

/// A Direct account on this iPhone and the mailbox every trusted device derives for its
/// Inbox. `usesMac` says Central has a Mac sending its new mail as pushes.
struct DirectMacAlertAccount: Identifiable, Equatable {
    let accountID: AccountID
    let email: String
    let logicalMailboxID: LogicalMailboxID
    var usesMac: Bool
    var id: AccountID { accountID }
}

struct NotificationDirectMailboxRow: Identifiable, Equatable {
    let logicalMailboxID: LogicalMailboxID
    let label: String
    var id: LogicalMailboxID { logicalMailboxID }
}

private struct MobileUnavailableNotificationPolicyRemote: NotificationPolicyRemote {
    func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.unavailable
    }

    func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        throw NotificationPolicyRemoteError.unavailable
    }
}

enum NotificationProducerSelectionState: Equatable {
    case idle
    case selecting
    case authenticating(authority: NotificationProducerAuthority)
    case selected(authority: NotificationProducerAuthority, generation: UInt64)
    case conflict
    case unavailable
}

private extension NotificationProducerKind {
    var authority: NotificationProducerAuthority {
        switch self {
        case .mac: .mac
        case .syncNode: .syncNode
        }
    }
}

/// The authenticated Node session a mail authority is built from. Holding the
/// client (not an authority) lets the model read the account catalog and bind
/// one scoped authority per selected provider account.
struct MobileNodeMailSession: Sendable {
    let client: NodeSyncClient
    let accountID: AccountID
}

/// A tapped notification: the opaque message token plus the logical mailbox
/// named by the envelope's outer header. The mailbox is an unauthenticated
/// hint that may only select an account the Node lists for this session;
/// ownership of the message is always proven by a scoped snapshot.
struct MobileNotificationOpenRequest: Equatable, Sendable {
    let token: String
    let logicalMailboxID: LogicalMailboxID?

    init(token: String, logicalMailboxID: LogicalMailboxID?) {
        self.token = token
        self.logicalMailboxID = logicalMailboxID
    }

    init?(userInfo: [AnyHashable: Any]) {
        // A push names `plainpost.deepLinkToken`; a local new-mail alert, `plainpost.openToken`.
        guard let token = userInfo["plainpost.deepLinkToken"] as? String
            ?? userInfo["plainpost.openToken"] as? String else { return nil }
        self.token = token
        let encoded = userInfo["plainpost.envelope"] as? String
            ?? userInfo["envelope"] as? String
            ?? (userInfo["plainpost"] as? [AnyHashable: Any])?["envelope"] as? String
        if let encoded,
           let wire = try? AccountWireCodec.decodeBase64URL(encoded, exactBytes: nil),
           wire.count <= 4096,
           let mailbox = try? RichNotificationEnvelope.mailboxID(in: wire) {
            logicalMailboxID = LogicalMailboxID(rawValue: mailbox)
        } else {
            logicalMailboxID = nil
        }
    }
}

enum MobileAccountPresentation: Equatable {
    case signInRequired
    case pendingApproval(matchingCode: String?)
    case active
    case offlineLease(expiresAt: Date)
    case suspended
    case cleanupRequired
    case deleted
    case recoveryRequired

    var allowsMailbox: Bool {
        switch self {
        case .active, .offlineLease: true
        case .signInRequired, .pendingApproval, .suspended, .cleanupRequired, .deleted, .recoveryRequired: false
        }
    }

    var allowsMailboxMutations: Bool {
        if case .active = self { return true }
        return false
    }

    var matchingCodeDisplay: String? {
        guard case .pendingApproval(let code) = self,
              let code,
              code.utf8.count == 6,
              code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

@MainActor
final class MobileAccountModel: ObservableObject {
    typealias Prepare = @Sendable (Date) async -> AccountSessionState
    typealias Bootstrap = @Sendable (String, Data) async throws -> AccountSessionState
    typealias AdmissionFactory = @MainActor @Sendable (AccountActivation) throws -> AccountPendingAdmissionFlow
    typealias ActiveAdmissionFactory = @MainActor @Sendable () throws -> AccountActiveAdmissionFlow
    typealias ActiveCleanupRegistration = @Sendable () async -> Void
    typealias SecurityFactory = @MainActor @Sendable (MobileAccountModel) -> MobileAccountSecurityModel
    typealias SyncNodeEnrollmentFactory = @MainActor @Sendable () async throws -> SyncNodeEnrollmentViewModel
    typealias SyncNodeEnrollmentOwnerReader = @MainActor @Sendable () throws -> SyncNodeEnrollmentOwner?
    typealias MailAuthorityFactory = @MainActor @Sendable (PlainpostRuntimeAccountAccess) async throws -> any PlainpostMailAuthority
    /// Production Node mail: the model loads the account catalog from this
    /// session and builds a scoped authority for the selected account.
    typealias NodeMailSessionFactory = @MainActor @Sendable (PlainpostRuntimeAccountAccess) async throws -> MobileNodeMailSession
    typealias NotificationRegistrationFactory = @MainActor @Sendable () async throws -> NotificationRegistrationModel
    typealias NotificationProducerSelectorFactory = @MainActor @Sendable () throws -> AuthenticatedNotificationProducerSelector
    typealias NotificationProducerTargetsFactory = @MainActor @Sendable () async throws -> [NotificationProducerTarget]
    typealias NotificationProducerMailboxesFactory = @MainActor @Sendable () async throws -> [Data]
    typealias NotificationProducerAssignmentsFactory = @MainActor @Sendable () async throws -> [NotificationProducerAssignment]
    typealias DirectInboxMailboxIDFactory = @MainActor @Sendable (_ imapHost: String, _ email: String) async throws -> LogicalMailboxID

    @Published private(set) var presentation: MobileAccountPresentation = .signInRequired {
        didSet { refreshPresentableSyncNodeEnrollmentModel() }
    }
    @Published private(set) var isAppleSignInInFlight = false
    @Published private(set) var appleSignInErrorMessage: String?
    /// In memory only (never stored or logged), for the few minutes recovery may use it.
    private var recentAppleSignIn: RecentAppleSignIn?

    /// The Apple sign-in just completed, while Central still accepts it for recovery.
    func appleSignInForRecovery(now: Date = Date()) -> RecentAppleSignIn? {
        guard let recentAppleSignIn, recentAppleSignIn.isUsable(at: now) else { return nil }
        return recentAppleSignIn
    }
    @Published private(set) var pendingApprovalPrompt: AccountActiveAdmissionController.PendingPrompt?
    @Published private(set) var pendingDeviceApproval: PendingDeviceApprovalPresentation = .hidden
    private var pendingDeviceApprovalTracker = PendingDeviceApprovalTracker() {
        didSet {
            pendingApprovalPrompt = pendingDeviceApprovalTracker.currentPrompt
            pendingDeviceApproval = pendingDeviceApprovalTracker.presentation
        }
    }
    @Published private(set) var deviceApprovalPrompt: AccountActiveAdmissionController.ConfirmationPrompt?
    #if DEBUG
    private var debugShowsPendingDeviceApproval = false
    private var debugShowsDeviceApprovalCode = false
    #endif
    private let prepareSession: Prepare
    private let discardSuspendedSession: Prepare?
    private let bootstrap: Bootstrap?
    private let admissionFactory: AdmissionFactory?
    private let activeAdmissionFactory: ActiveAdmissionFactory?
    private let activeCleanupRegistration: ActiveCleanupRegistration?
    private let securityFactory: SecurityFactory?
    private let syncNodeEnrollmentFactory: SyncNodeEnrollmentFactory?
    private let syncNodeEnrollmentOwnerReader: SyncNodeEnrollmentOwnerReader?
    let syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel?
    private let mailAuthorityFactory: MailAuthorityFactory?
    private let nodeMailSessionFactory: NodeMailSessionFactory?
    private let mailSelectionDefaults: UserDefaults
    private let notificationRegistrationFactory: NotificationRegistrationFactory?
    private let notificationProducerSelectorFactory: NotificationProducerSelectorFactory?
    private let notificationProducerTargetsFactory: NotificationProducerTargetsFactory?
    private let notificationProducerMailboxesFactory: NotificationProducerMailboxesFactory?
    private let notificationProducerAssignmentsFactory: NotificationProducerAssignmentsFactory?
    private let directInboxMailboxIDFactory: DirectInboxMailboxIDFactory?
    private let notificationAPNs: APNsTokenProvider?
    let requiresMailAuthority: Bool
    private var task: Task<Void, Never>?
    private var isShutDownForServerChange = false
    private var expiryTask: Task<Void, Never>?
    private var cleanupRegistrationTask: Task<Void, Never>?
    private var appleAttempt: (id: UUID, nonce: Data)?
    private var deviceApprovalAppleAttempt: (id: UUID, nonce: Data)?
    private var generation: UInt64 = 0
    private var admissionController: AccountPendingAdmissionFlow?
    private var admissionObservation: AnyCancellable?
    private var activeAdmissionController: AccountActiveAdmissionFlow?
    private var activeAdmissionObservation: AnyCancellable?
    @Published private(set) var syncNodeEnrollmentModel: SyncNodeEnrollmentViewModel? {
        didSet { refreshPresentableSyncNodeEnrollmentModel() }
    }
    /// The enrollment model views may render: its owner's session read as the
    /// active one when the presentation or the model last changed. Views never
    /// call the owner reader, which is a Keychain read in production.
    @Published private(set) var presentableSyncNodeEnrollmentModel: SyncNodeEnrollmentViewModel?
    /// The Sync Node page's view of the enrollment build, as on the Mac: loading while the
    /// factory runs, failed when it throws.
    @Published private(set) var syncNodeEnrollmentLoadPresentation: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation = .idle
    @Published private(set) var mailAuthority: (any PlainpostMailAuthority)?
    /// The account session or its first Node authority attempt is still
    /// running, so a missing authority is not yet a failure.
    @Published private(set) var isPreparingMailAuthority = false
    private var mailAuthorityAttempt: UInt64 = 0
    /// Every provider account the Node serves, in Node order.
    @Published private(set) var mailAccounts: [NodeMailAccount] = []
    @Published private(set) var selectedMailAccountID: LogicalMailboxID?
    private var nodeMailSession: (session: MobileNodeMailSession, access: PlainpostRuntimeAccountAccess)?
    private var mailAccountsMultiAccount = false
    private var mailAuthorityBinding: MobileMailAuthorityBinding?
    /// Latest-wins fence for authority preparation, account refresh and
    /// selection; a slower operation never replaces a newer selection.
    private var mailAccountToken: UInt64 = 0
    /// Advances on every explicit selection and session reset (not on a catalog
    /// refresh), so a notification owner scan yields to a manual switch.
    private var mailSelectionRevision: UInt64 = 0
    /// Sender for the unscoped onboarding authority used while the Node lists
    /// no provider account (legacy `/v1/status` identity).
    private var unscopedMailSender: String?
    /// The authority bound by the user's own account switch. Any later
    /// binding is a new authority object, so it never matches.
    private var userSelectedMailAuthority = MobileMailAuthorityReference(nil)
    /// The mail root's composer is open with unsaved changes.
    private var mailComposerHasUnsavedChanges = false
    /// A notification tap waiting for the unsaved composer to be saved or closed.
    private var deferredNotificationTap: MobileNotificationOpenRequest?
    /// A notification tap waits for the open composer.
    @Published private(set) var hasDeferredNotificationOpen = false
    @Published private(set) var syncNodeProviderController: SyncNodeProviderController?
    @Published private(set) var notificationStatus: NotificationRegistrationStatus = .unconfigured
    @Published private(set) var notificationPreviewPolicy: NotificationPreviewPolicy = .rich
    @Published private(set) var notificationPolicySelected = false
    @Published private(set) var notificationProducerSelectionState: NotificationProducerSelectionState = .idle
    @Published private(set) var notificationProducerAuthority: NotificationProducerAuthority?
    @Published private(set) var notificationProducerTargets: [NotificationProducerTarget] = []
    @Published private(set) var notificationProducerMailboxIDs: [Data] = []
    @Published private(set) var directNotificationMailboxRows: [NotificationDirectMailboxRow] = []
    /// This iPhone's Direct accounts that a Mac can send instant alerts for.
    @Published private(set) var directMacAlertAccounts: [DirectMacAlertAccount] = []
    private var lastMacAssignmentMailboxIDs: Set<Data> = []
    /// The mail root has per-mailbox notification policy rows to show; the
    /// notification menu then offers them.
    @Published var hasMailboxNotificationPolicyRows = false
    /// The per-mailbox notification policy sheet is open.
    @Published var isMailboxNotificationPolicyPresented = false
    private var requestedNotificationPreviewPolicy: NotificationPreviewPolicy?
    private var syncNodeEnrollmentTask: Task<Void, Never>?
    private var syncNodeEnrollmentGeneration: UInt64 = 0
    /// The Server Setup profile generation current when the published model
    /// was built. A newer generation that arrived while the model retained a
    /// replay is applied once the model converges.
    private var syncNodeEnrollmentProfileGeneration: UInt64?
    private var mailAuthorityTask: Task<Void, Never>?
    private var notificationRegistrationTask: Task<Void, Never>?
    private var notificationActionTask: Task<Void, Never>?
    private var notificationProducerTask: Task<Void, Never>?
    private var notificationRegistration: NotificationRegistrationModel?
    private var notificationProducerTarget: NotificationProducerTarget?
    private var notificationProducerMailboxID: Data?
    private var notificationProducerAppleAttempt: (id: UUID, nonce: Data)?
    private var approvalCapability: AccountDeviceApprovalCapability?
    private let approvalCoordinator: AccountDeviceApprovalCoordinator
    private(set) lazy var securityModel: MobileAccountSecurityModel? = securityFactory?(self)
    #if DEBUG
    /// UI acceptance only: the debug Node refuses sessions until a mail retry.
    fileprivate var debugMailSessionGate: DebugMailSessionGate?
    #endif

    init(
        prepareSession: @escaping Prepare,
        discardSuspendedSession: Prepare? = nil,
        bootstrap: Bootstrap? = nil,
        admissionFactory: AdmissionFactory? = nil,
        activeAdmissionFactory: ActiveAdmissionFactory? = nil,
        activeCleanupRegistration: ActiveCleanupRegistration? = nil,
        securityFactory: SecurityFactory? = nil,
        syncNodeEnrollmentFactory: SyncNodeEnrollmentFactory? = nil,
        syncNodeBootstrapImportModel: SyncNodeBootstrapImportViewModel? = nil,
        syncNodeEnrollmentOwnerReader: SyncNodeEnrollmentOwnerReader? = nil,
        mailAuthorityFactory: MailAuthorityFactory? = nil,
        nodeMailSessionFactory: NodeMailSessionFactory? = nil,
        mailSelectionDefaults: UserDefaults = .standard,
        notificationRegistrationFactory: NotificationRegistrationFactory? = nil,
        notificationProducerSelectorFactory: NotificationProducerSelectorFactory? = nil,
        notificationProducerTargetsFactory: NotificationProducerTargetsFactory? = nil,
        notificationProducerMailboxesFactory: NotificationProducerMailboxesFactory? = nil,
        notificationProducerAssignmentsFactory: NotificationProducerAssignmentsFactory? = nil,
        directInboxMailboxIDFactory: DirectInboxMailboxIDFactory? = nil,
        notificationAPNs: APNsTokenProvider? = nil,
        requiresMailAuthority: Bool = false,
        localApprovalAuthenticator: any LocalApprovalAuthenticating = LocalApprovalAuthenticatorFactory.defaultAuthenticator()
    ) {
        self.prepareSession = prepareSession
        self.discardSuspendedSession = discardSuspendedSession
        self.bootstrap = bootstrap
        self.admissionFactory = admissionFactory
        self.activeAdmissionFactory = activeAdmissionFactory
        self.activeCleanupRegistration = activeCleanupRegistration
        self.securityFactory = securityFactory
        self.syncNodeEnrollmentFactory = syncNodeEnrollmentFactory
        self.syncNodeBootstrapImportModel = syncNodeBootstrapImportModel
        self.syncNodeEnrollmentOwnerReader = syncNodeEnrollmentOwnerReader
        self.mailAuthorityFactory = mailAuthorityFactory
        self.nodeMailSessionFactory = nodeMailSessionFactory
        self.mailSelectionDefaults = mailSelectionDefaults
        self.notificationRegistrationFactory = notificationRegistrationFactory
        self.notificationProducerSelectorFactory = notificationProducerSelectorFactory
        self.notificationProducerTargetsFactory = notificationProducerTargetsFactory
        self.notificationProducerMailboxesFactory = notificationProducerMailboxesFactory
        self.notificationProducerAssignmentsFactory = notificationProducerAssignmentsFactory
        self.directInboxMailboxIDFactory = directInboxMailboxIDFactory
        self.notificationAPNs = notificationAPNs
        self.requiresMailAuthority = requiresMailAuthority
        mailAuthority = nil
        syncNodeProviderController = nil
        approvalCoordinator = AccountDeviceApprovalCoordinator(authenticator: localApprovalAuthenticator)
    }

    convenience init(controller: AccountSessionController) {
        self.init { await controller.prepare(now: $0) }
    }

    static func production(
        server: CentralServerConfiguration,
        credentials: AccountCredentialStore,
        nodeBroker: NodeSessionBroker?
    ) throws -> MobileAccountModel {
        #if targetEnvironment(simulator)
        let manifest = try BootstrapKeyManifestStore(secretStore: InMemoryAccountSecretStore())
        #else
        let manifest = try BootstrapKeyManifestStore()
        #endif
        let client = try AccountAPIClient(credentialStore: credentials, manifestStore: manifest, baseURL: server.origin)
        let notificationSession = NotificationAccountSession(api: client, store: credentials)
        let notificationAPNs = APNsTokenProvider()
        let purger = MobileManagedDataPurger.production()
        let authenticator = LocalApprovalAuthenticatorFactory.defaultAuthenticator()
        let bootstrapImportModel = SyncNodeBootstrapImportViewModel(store: MobileAccountModel.makeSyncNodeBootstrapProfileStore())
        #if targetEnvironment(simulator)
        let sessionManifestSecrets: any AccountSecretStoring = InMemoryAccountSecretStore()
        #else
        let sessionManifestSecrets: any AccountSecretStoring = KeychainAccountSecretStore()
        #endif
        let controller = try AccountSessionRuntimeAssembly.bundledController(
            credentials: credentials,
            bootstrapManifest: manifest,
            baseURL: server.origin
        )
        let model = MobileAccountModel(
            prepareSession: { now in
                if let deletion = (try? credentials.loadLocalDeletion()) ?? nil {
                    do {
                        let cleanup: AccountLifecycleController
                        if deletion.phase == .localPurged {
                            cleanup = try AccountLifecycleController(remote: client, credentialStore: credentials, device: try AccountDeviceIdentity.generate(), platform: .ios, recoveryCoordinatorFactory: { _, _, _, _ in throw AccountRuntimeError.secretUnavailable }, manifestStore: manifest, authenticate: { _ in false }, purgeManagedData: { accountID in try purger.purge(accountID: accountID) })
                        } else {
                            cleanup = try credentials.makeLifecycleController(client: client, manifestStore: manifest, platform: .ios, authenticate: { _ in false }, purgeManagedData: { accountID in try purger.purge(accountID: accountID) })
                        }
                        try await cleanup.resumeLocalDeletion()
                    } catch { return .cleanupRequired }
                }
                return await controller.prepare(now: now)
            },
            discardSuspendedSession: { now in await controller.discardSuspendedSession(now: now) },
            bootstrap: { token, nonce in
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
                return AccountPendingAdmissionFlow(controller: try AccountAdmissionController(rendezvous: CentralAccountAdmissionRendezvous(client: client, credentials: sessionCredentials, identity: identity), pending: activation, publicBundle: identity.publicBundle, poll: { await controller.prepare(now: Date()) }))
            },
            activeAdmissionFactory: { AccountActiveAdmissionFlow(controller: try credentials.makeActiveAdmissionController(client: client, platform: .ios)) },
            activeCleanupRegistration: {
                guard let lifecycle = try? credentials.makeLifecycleController(
                    client: client,
                    manifestStore: manifest,
                    platform: .ios,
                    authenticate: { _ in false }
                ) else { return }
                _ = try? await lifecycle.registerCurrentCleanupTarget()
            },
            securityFactory: { model in
                MobileAccountSecurityModel(
                    controllerFactory: {
                        try credentials.makeLifecycleController(
                            client: client,
                            manifestStore: manifest,
                            platform: .ios,
                            authenticate: { action in
                                try await authenticator.authenticate(reason: "Confirm \(action.rawValue.replacingOccurrences(of: "_", with: " ")) in Plainpost.")
                                return true
                            },
                            purgeManagedData: { [weak model] accountID in
                                await MainActor.run { model?.enterCleanupRequired() }
                                return try purger.purge(accountID: accountID)
                            }
                        )
                    },
                    stateChanged: { [weak model] in model?.prepare() }
                )
            },
            syncNodeEnrollmentFactory: {
                // The session manifest is signed by the session root, not the
                // account bootstrap root. SessionKeyManifestStore persists the
                // authenticated high-water and rejects a bundled downgrade.
                let sessionManifest = try SessionKeyManifestStore(
                    bundledDocument: SessionKeyManifestStore.bundledManifest,
                    offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
                    offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey,
                    secretStore: sessionManifestSecrets
                ).verifier()
                return try await SyncNodeEnrollmentAssembly.makeModel(client: client, credentials: credentials, sessionController: controller, platform: .ios, sessionManifest: sessionManifest, authenticator: authenticator, bootstrapImportModel: bootstrapImportModel, endpointStore: try MobileAccountModel.makeSyncNodeEndpointStore())
            },
            syncNodeBootstrapImportModel: bootstrapImportModel,
            syncNodeEnrollmentOwnerReader: {
                try SyncNodeEnrollmentAssembly.activeSessionOwner(credentials: credentials)
            },
            nodeMailSessionFactory: { access in
                guard let nodeBroker else { throw AccountRuntimeError.secretUnavailable }
                guard let session = try credentials.loadSession(),
                      session.state == .active,
                      let sessionCredentials = session.credentials
                else { throw AccountRuntimeError.untrustedResponse }
                let admitted = try await nodeBroker.currentAdmission()
                guard (access == .cachedReadOnly) == (admitted != .readWrite) else {
                    throw AccountRuntimeError.untrustedResponse
                }
                let brokered = try await nodeBroker.nodeClient()
                // The model reads the account catalog through this client
                // and binds one scoped authority per selected account.
                return MobileNodeMailSession(
                    client: brokered.client,
                    accountID: AccountID(sessionCredentials.accountID.rawValue)
                )
            },
            notificationRegistrationFactory: {
                guard let session = try credentials.loadSession(), session.state == .active,
                      let sessionCredentials = session.credentials else { throw AccountRuntimeError.secretUnavailable }
                let identity = try credentials.loadOrCreateDeviceIdentity()
                let trustCoordinator = try credentials.makeTrustCoordinator(
                    accountID: sessionCredentials.accountID, deviceID: sessionCredentials.deviceID,
                    platform: .ios, identity: identity
                )
                guard let commit = try await trustCoordinator.currentTrustCommit() else { throw AccountRuntimeError.untrustedResponse }
                #if canImport(DeviceCheck)
                let appAttest: any AppAttestProviding = DeviceCheckAppAttestProvider()
                #else
                let appAttest: any AppAttestProviding = UnsupportedAppAttestProvider()
                #endif
                // The profile's aps-environment, not the build configuration: a Release
                // build signed for development still gets sandbox tokens.
                let notificationEnvironment = NotificationEnvironment.currentApp
                let registrationRemote = AccountNotificationRegistrationRemote(client: client, credentials: sessionCredentials, device: identity, currentSession: {
                    let current = try await notificationSession.current()
                    return (current.credentials, current.device)
                })
                let selector = AuthenticatedNotificationProducerSelector(api: client, credentialStore: credentials)
                let directPolicyRemote = AuthenticatedDirectNotificationPolicyClient(api: client, credentialStore: credentials)
                let nodePolicyRemote: (any NotificationPolicyRemote)?
                if commit.state.members.contains(where: { $0.platform == .syncNode }) {
                    let endpointStore = try MobileAccountModel.makeSyncNodeEndpointStore()
                    let discovered: NodeSessionTransport?
                    do {
                        discovered = try await SyncNodeSessionLocator.discover(
                            remote: client,
                            trust: trustCoordinator,
                            credentials: sessionCredentials,
                            device: identity,
                            store: endpointStore
                        )
                    } catch {
                        discovered = nil
                    }
                    nodePolicyRemote = discovered.map { NodeSyncClient(sender: $0) }
                } else {
                    nodePolicyRemote = nil
                }
                let assignmentRemote = NotificationAssignmentPolicyRemote(
                    assignments: { try await selector.currentProducerAssignments() },
                    direct: directPolicyRemote,
                    syncNode: nodePolicyRemote ?? MobileUnavailableNotificationPolicyRemote()
                )
                let policyRemoteFactory: @Sendable (LogicalMailboxID?) async throws -> any NotificationPolicyRemote = { _ in assignmentRemote }
                return try NotificationRegistrationModel(
                    trust: {
                        guard let current = try await trustCoordinator.currentTrustCommit() else {
                            throw AccountRuntimeError.untrustedResponse
                        }
                        let node = current.state.members.first(where: { $0.platform == .syncNode })
                        return try NotificationTrustSnapshot(
                            accountID: sessionCredentials.accountID, deviceID: sessionCredentials.deviceID,
                            epoch: current.state.epoch.value, revision: current.state.revision.value,
                            trustHead: AccountTranscript.trustCommitDigest(current),
                            nodeID: node?.deviceID,
                            nodeSigningPublicKey: node?.publicBundle.signingKey
                        )
                    },
                    identitySignature: { try identity.signature(for: $0) },
                    permission: UserNotificationPermissionProvider(), apns: notificationAPNs,
                    attest: appAttest,
                    remote: registrationRemote,
                    transfer: nil,
                    recipientUploader: registrationRemote,
                recipientCoordinates: {
                    try await selector.currentProducerAssignments().map {
                        (logicalMailboxID: $0.logicalMailboxID, assignmentGeneration: $0.generation)
                    }
                },
                recipientContexts: {
                    let assignments = try await selector.currentProducerAssignments()
                    let contexts = try assignments.map { assignment in
                        guard let signingKey = assignment.producerSigningPublicKey else {
                            throw NotificationRegistrationFailure.noActiveProducer
                        }
                        return try NotificationRecipientProducerContext(
                            logicalMailboxID: assignment.logicalMailboxID,
                            assignmentGeneration: assignment.generation,
                            producerDeviceID: assignment.producerDeviceID,
                            producerSigningPublicKey: signingKey
                        )
                    }
                    return contexts
                },
                store: NotificationKeychainStore(accessGroup: Bundle.main.object(forInfoDictionaryKey: "PLAINPOST_NOTIFICATION_KEYCHAIN_GROUP") as? String),
                    topic: Bundle.main.bundleIdentifier ?? "com.marynavdovenko.Plainpost.iOS",
                    environment: notificationEnvironment, mailPairingState: .paired,
                    policyRemoteFactory: policyRemoteFactory,
                    policyDefaultPersistence: { mode in
                        try await assignmentRemote.persistDefaultPolicy(mode: mode)
                    }
                )
            },
            notificationProducerSelectorFactory: {
                AuthenticatedNotificationProducerSelector(api: client, credentialStore: credentials)
            },
            notificationProducerTargetsFactory: {
                try await AuthenticatedNotificationProducerSelector(api: client, credentialStore: credentials).trustedProducerTargets()
            },
            notificationProducerMailboxesFactory: {
                try await AuthenticatedNotificationProducerSelector(api: client, credentialStore: credentials).currentProducerAssignments()
                    .filter { $0.kind == .mac }
                    .map(\.logicalMailboxID)
            },
            notificationProducerAssignmentsFactory: {
                try await AuthenticatedNotificationProducerSelector(api: client, credentialStore: credentials).currentProducerAssignments()
            },
            directInboxMailboxIDFactory: { imapHost, email in
                guard let session = try credentials.loadSession(), session.state == .active,
                      let sessionCredentials = session.credentials else { throw AccountRuntimeError.secretUnavailable }
                let trust = try credentials.makeTrustCoordinator(
                    accountID: sessionCredentials.accountID, deviceID: sessionCredentials.deviceID,
                    platform: .ios, identity: try credentials.loadOrCreateDeviceIdentity()
                )
                return try await trust.directInboxMailboxID(imapHost: imapHost, email: email)
            },
            notificationAPNs: notificationAPNs,
            requiresMailAuthority: true,
            localApprovalAuthenticator: authenticator
        )
        return model
    }

    #if DEBUG
    static func debugAuthorized() -> MobileAccountModel {
        let model = MobileAccountModel(prepareSession: { _ in .active })
        model.presentation = .active
        return model
    }

    static func debugSignedOut() -> MobileAccountModel {
        MobileAccountModel(prepareSession: { _ in .signInRequired })
    }

    /// In-app two-account Node (`ada@example.test` primary, `grace@example.test`)
    /// for the multi-account UI acceptance fixture. Selection starts fresh.
    static func debugTwoAccountNode() -> MobileAccountModel {
        let suite = "plainpost.debug.multi-account-acceptance"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let environment = ProcessInfo.processInfo.environment
        // A Sync Node notification producer for the primary account, so the
        // per-mailbox notification policy rows appear (layout acceptance).
        var policyAssignments: NotificationProducerAssignmentsFactory?
        if environment["PLAINPOST_DEBUG_NOTIFICATION_POLICY_ROWS"] == "1" {
            policyAssignments = { @MainActor @Sendable in [NotificationProducerAssignment(
                logicalMailboxID: Data(repeating: 1, count: 32),
                producerDeviceID: try AccountDeviceID("90000000-0000-4000-8000-0000000000aa"),
                kind: .syncNode, generation: 1, trustEpoch: 1, trustRevision: 1, trustHead: Data(repeating: 7, count: 32)
            )] }
        }
        // Trusted devices on the Plainpost Account page, for its UI acceptance.
        var securityFactory: SecurityFactory?
        if environment["PLAINPOST_DEBUG_ACCOUNT_SECURITY"] == "1" {
            securityFactory = { _ in debugAccountSecurity() }
        }
        let model: MobileAccountModel
        if environment["PLAINPOST_DEBUG_NODE_UNAVAILABLE_UNTIL_RETRY"] == "1" {
            model = debugNodeUnavailableUntilRetry(defaults: defaults)
        } else {
            model = testing(
                nodeSender: DebugTwoAccountNodeSender.fromEnvironment(),
                defaults: defaults,
                notificationProducerAssignmentsFactory: policyAssignments,
                securityFactory: securityFactory
            )
        }
        // Top-of-screen account prompts, for layout acceptance only.
        model.debugShowsPendingDeviceApproval = environment["PLAINPOST_DEBUG_PENDING_DEVICE_APPROVAL"] == "1"
        model.debugShowsDeviceApprovalCode = environment["PLAINPOST_DEBUG_DEVICE_APPROVAL_CODE"] == "1"
        model.applyDebugAccountPrompts()
        return model
    }

    /// An active Plainpost account whose Sync Node refuses every session until
    /// the mail screen's Retry or Sync Node setup asks again: account mode with
    /// no mail authority. The security model lets the setup sheet open.
    private static func debugNodeUnavailableUntilRetry(defaults: UserDefaults) -> MobileAccountModel {
        let gate = DebugMailSessionGate()
        let client = NodeSyncClient(sender: DebugTwoAccountNodeSender.fromEnvironment())
        let model = MobileAccountModel(
            prepareSession: { _ in .active },
            securityFactory: { _ in
                MobileAccountSecurityModel(controllerFactory: { throw AccountRuntimeError.secretUnavailable }, stateChanged: {})
            },
            nodeMailSessionFactory: { _ in
                guard gate.isOpen else { throw AccountRuntimeError.secretUnavailable }
                return MobileNodeMailSession(client: client, accountID: testingNodeAccountID)
            },
            mailSelectionDefaults: defaults,
            requiresMailAuthority: true
        )
        model.debugMailSessionGate = gate
        model.presentation = .active
        return model
    }

    private func applyDebugAccountPrompts() {
        if debugShowsPendingDeviceApproval {
            pendingDeviceApprovalTracker.receive(.idle([
                AccountActiveAdmissionController.PendingPrompt(selection: 1, platform: .ios, requestID: "debug-pending-device")
            ]))
        }
        if debugShowsDeviceApprovalCode {
            deviceApprovalPrompt = AccountActiveAdmissionController.ConfirmationPrompt(
                matchingCode: "123456", expiresAt: Date().addingTimeInterval(3600)
            )
        }
    }

    static let testingNodeAccountID = AccountID("00112233-4455-6677-8899-aabbccddeeff")

    /// Test factory: Node mail served by `nodeSender`, selection persisted in
    /// `defaults`. Presentation starts active so account reads need no prepare.
    /// This iPhone and another Mac as trusted devices, for the Plainpost Account page's UI
    /// acceptance. Protected changes never complete: there's no Apple identity token here.
    private static func debugAccountSecurity() -> MobileAccountSecurityModel {
        MobileAccountSecurityModel(
            loadSnapshot: {
                ([
                    AccountLifecycleDeviceSummary(
                        id: try AccountDeviceID("90000000-0000-4000-8000-000000000001"),
                        platform: .ios, isCurrentDevice: true, localLabel: "Ada's iPhone", status: "active"
                    ),
                    AccountLifecycleDeviceSummary(
                        id: try AccountDeviceID("90000000-0000-4000-8000-000000000002"),
                        platform: .macos, isCurrentDevice: false, status: "active"
                    ),
                ], [])
            },
            performAction: { _, _, _ in nil },
            saveLabel: { _, _ in },
            stateChanged: {},
            nonceGenerator: { Data(repeating: 0xA5, count: 32) }
        )
    }

    static func testing(
        nodeSender: any NodeSessionRequestSending,
        defaults: UserDefaults,
        accountID: AccountID = testingNodeAccountID,
        prepareSession: @escaping Prepare = { _ in .active },
        notificationProducerAssignmentsFactory: NotificationProducerAssignmentsFactory? = nil,
        securityFactory: SecurityFactory? = nil
    ) -> MobileAccountModel {
        let client = NodeSyncClient(sender: nodeSender)
        let model = MobileAccountModel(
            prepareSession: prepareSession,
            securityFactory: securityFactory,
            nodeMailSessionFactory: { _ in
                MobileNodeMailSession(client: client, accountID: accountID)
            },
            mailSelectionDefaults: defaults,
            notificationProducerAssignmentsFactory: notificationProducerAssignmentsFactory,
            requiresMailAuthority: true
        )
        model.presentation = .active
        return model
    }
    #endif

    deinit { task?.cancel(); expiryTask?.cancel(); syncNodeEnrollmentTask?.cancel(); mailAuthorityTask?.cancel(); notificationRegistrationTask?.cancel(); notificationActionTask?.cancel(); notificationProducerTask?.cancel() }

    /// Notification registration is explicit and opt-in. It is intentionally
    /// independent from `prepare()` so an unavailable relay never blocks sign
    /// in, trust recovery, or mailbox readiness.
    func prepareNotificationRegistration() {
        guard notificationRegistration == nil, notificationRegistrationTask == nil,
              presentation.allowsMailbox,
              let factory = notificationRegistrationFactory else { return }
        let expectedGeneration = generation
        notificationRegistrationTask = Task { @MainActor [weak self] in
            defer { self?.notificationRegistrationTask = nil }
            do {
                let registration = try await factory()
                guard let self, self.generation == expectedGeneration else { return }
                registration.statusObserver = { [weak self] status in self?.notificationStatus = status }
                notificationRegistration = registration
                notificationStatus = registration.status
                // A first picker selection may race this async factory. The
                // user's pending choice is authoritative; a newly-created
                // model's default Rich value must not overwrite it.
                notificationPreviewPolicy = requestedNotificationPreviewPolicy ?? registration.previewPolicy
                notificationPolicySelected = true
                if let requestedNotificationPreviewPolicy {
                    registration.setPreviewPolicy(requestedNotificationPreviewPolicy)
                }
                if registration.needsLaunchReconciliation {
                    notificationActionTask?.cancel()
                    notificationActionTask = Task { @MainActor [weak self, weak registration] in
                        guard let self, let registration else { return }
                        await registration.reconcileOnLaunch()
                        guard self.generation == expectedGeneration else { return }
                        self.notificationStatus = registration.status
                        self.notificationActionTask = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.notificationStatus = .degraded(.unavailable)
            }
        }
    }

    /// Settings' Turn On: saves `policy` (often the shown default, which a picker never
    /// "changes" to) and registers with it in one task, so nothing cancels the policy write.
    /// Off only saves the detail.
    func enableNotifications(policy: NotificationPreviewPolicy) {
        guard presentation.allowsMailbox else { return }
        notificationPreviewPolicy = policy
        notificationPolicySelected = true
        requestedNotificationPreviewPolicy = policy
        prepareNotificationRegistration()
        notificationActionTask?.cancel()
        notificationActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let setup = notificationRegistrationTask { await setup.value }
            guard !Task.isCancelled else { return }
            guard let registration = notificationRegistration else {
                notificationStatus = .degraded(.unavailable)
                notificationActionTask = nil
                return
            }
            // From revoked, setting a detail other than Off already re-registers.
            let reregistersItself = registration.status == .revoked
            registration.setPreviewPolicy(policy)
            notificationPreviewPolicy = registration.previewPolicy
            requestedNotificationPreviewPolicy = nil
            // A failed local save leaves the registration's own policy; never register with
            // a detail that didn't persist.
            if registration.previewPolicy == policy, policy != .off, !reregistersItself {
                await registration.retry()
            }
            guard !Task.isCancelled else { return }
            notificationStatus = registration.status
            notificationActionTask = nil
        }
    }

    func retryNotifications() {
        guard presentation.allowsMailbox, notificationPolicySelected else { return }
        prepareNotificationRegistration()
        notificationActionTask?.cancel()
        notificationActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let setup = notificationRegistrationTask { await setup.value }
            guard let registration = notificationRegistration else {
                notificationStatus = .degraded(.unavailable)
                notificationActionTask = nil
                return
            }
            await registration.retry()
            notificationStatus = registration.status
            notificationActionTask = nil
        }
    }

    func setNotificationPreviewPolicy(_ policy: NotificationPreviewPolicy) {
        notificationPreviewPolicy = policy
        notificationPolicySelected = true
        requestedNotificationPreviewPolicy = policy
        prepareNotificationRegistration()
        notificationActionTask?.cancel()
        notificationActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let setup = notificationRegistrationTask { await setup.value }
            self.notificationRegistration?.setPreviewPolicy(policy)
            // The registration model is the source of truth because local
            // persistence can fail. Reflect its unchanged policy and degraded
            // status instead of claiming a privacy choice that did not reach
            // durable storage.
            if let registration = self.notificationRegistration {
                self.notificationPreviewPolicy = registration.previewPolicy
                self.notificationStatus = registration.status
            }
            self.requestedNotificationPreviewPolicy = nil
            // A newer action replaced (and cancelled) this one; it isn't ours to clear.
            if !Task.isCancelled { self.notificationActionTask = nil }
        }
    }

    func selectNotificationProducer(logicalMailboxID: Data? = nil) {
        notificationProducerTask?.cancel()
        notificationProducerMailboxID = logicalMailboxID
        notificationProducerTarget = nil
        notificationProducerAppleAttempt = nil
        notificationProducerSelectionState = .selecting
        guard let targetsFactory = notificationProducerTargetsFactory else {
            notificationProducerSelectionState = .unavailable
            return
        }
        notificationProducerTask = Task { @MainActor [weak self] in
            defer { self?.notificationProducerTask = nil }
            do {
                let targets = try await targetsFactory()
                guard let self, !targets.isEmpty, !Task.isCancelled else { return }
                self.notificationProducerTargets = targets.map { target in
                    NotificationProducerTarget(
                        deviceID: target.deviceID, kind: target.kind,
                        expectedGeneration: target.expectedGeneration
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.notificationProducerSelectionState = .unavailable
            }
        }
    }

    func loadNotificationProducerMailboxes() async {
        directNotificationMailboxRows = []
        guard let factory = notificationProducerMailboxesFactory else { return }
        do {
            let mailboxIDs = try await factory()
            notificationProducerMailboxIDs = mailboxIDs
            directNotificationMailboxRows = mailboxIDs.enumerated().compactMap { index, raw in
                guard let logicalMailboxID = LogicalMailboxID(rawValue: raw), raw.contains(where: { $0 != 0 }) else { return nil }
                return NotificationDirectMailboxRow(logicalMailboxID: logicalMailboxID, label: "Mailbox \(index + 1)")
            }
        } catch is CancellationError {
            return
        } catch {
            notificationProducerMailboxIDs = []
            directNotificationMailboxRows = []
        }
    }

    /// Rehydrates UI authority from the authenticated current assignment set.
    /// This is used on launch/reload as well as after CAS success, so an old
    /// session's producer selection cannot dictate which rows are displayed.
    @discardableResult
    func refreshNotificationProducerAssignments() async -> [NotificationProducerAssignment] {
        notificationProducerAuthority = nil
        clearNotificationProducerMailboxes()
        guard let factory = notificationProducerAssignmentsFactory else { return [] }
        do {
            let assignments = try await factory()
            try Task.checkCancellation()
            let hasMac = assignments.contains { $0.kind == .mac }
            let hasSyncNode = assignments.contains { $0.kind == .syncNode }
            notificationProducerAuthority = switch (hasMac, hasSyncNode) {
            case (true, false): .mac
            case (false, true): .syncNode
            case (true, true): .mixed
            default: nil
            }
            let macAssignments = assignments.filter { $0.kind == .mac }
            notificationProducerMailboxIDs = macAssignments.map(\.logicalMailboxID)
            directNotificationMailboxRows = macAssignments.enumerated().compactMap { index, assignment in
                guard let mailbox = LogicalMailboxID(rawValue: assignment.logicalMailboxID), assignment.logicalMailboxID.contains(where: { $0 != 0 }) else { return nil }
                return NotificationDirectMailboxRow(logicalMailboxID: mailbox, label: directMailboxLabel(mailbox) ?? "Mailbox \(index + 1)")
            }
            lastMacAssignmentMailboxIDs = Set(macAssignments.map(\.logicalMailboxID))
            updateDirectMacAlertAccounts()
            return assignments
        } catch is CancellationError {
            return []
        } catch {
            notificationProducerAuthority = nil
            clearNotificationProducerMailboxes()
            return []
        }
    }

    func clearNotificationProducerMailboxes() {
        notificationProducerMailboxIDs = []
        directNotificationMailboxRows = []
    }

    func dismissNotificationProducerSelection() {
        guard notificationProducerSelectionState != .idle else { return }
        notificationProducerTask?.cancel()
        notificationProducerAppleAttempt = nil
        notificationProducerSelectionState = .idle
    }

    func beginNotificationProducerEnrollment(authority: NotificationProducerAuthority) {
        guard let target = notificationProducerTargets.first(where: { $0.kind.authority == authority }),
              let logicalMailboxID = notificationProducerMailboxID else {
            notificationProducerSelectionState = .unavailable
            return
        }
        beginNotificationProducerEnrollment(target: target, logicalMailboxID: logicalMailboxID)
    }

    func beginNotificationProducerEnrollment(target: NotificationProducerTarget, logicalMailboxID: Data) {
        guard notificationProducerSelectionState == .selecting,
              logicalMailboxID.count == 32, logicalMailboxID.contains(where: { $0 != 0 }) else {
            notificationProducerSelectionState = .unavailable
            return
        }
        notificationProducerMailboxID = logicalMailboxID
        let currentTarget = Self.targetUsingAuthoritativeAssignment(target, assignment: nil)
        notificationProducerTarget = currentTarget
        notificationProducerSelectionState = .authenticating(authority: currentTarget.kind.authority)
        guard let assignmentsFactory = notificationProducerAssignmentsFactory else { return }
        notificationProducerTask?.cancel()
        notificationProducerTask = Task { @MainActor [weak self] in
            defer { self?.notificationProducerTask = nil }
            do {
                let assignments = try await assignmentsFactory()
                guard let self, !Task.isCancelled,
                      self.notificationProducerMailboxID == logicalMailboxID else { return }
                let assignment = assignments.first(where: { $0.logicalMailboxID == logicalMailboxID })
                // The assignment returned by Central is authoritative for the
                // CAS predecessor. It may still name producer A while the user
                // is proposing successor B; filtering it by the proposal would
                // turn A -> B (and clear -> B) into a fake generation race.
                self.notificationProducerTarget = Self.targetUsingAuthoritativeAssignment(target, assignment: assignment)
            } catch is CancellationError {
                return
            } catch {
                self?.notificationProducerSelectionState = .unavailable
            }
        }
    }

    static func targetUsingAuthoritativeAssignment(
        _ proposed: NotificationProducerTarget,
        assignment: NotificationProducerAssignment?
    ) -> NotificationProducerTarget {
        NotificationProducerTarget(
            deviceID: proposed.deviceID,
            kind: proposed.kind,
            expectedGeneration: assignment?.generation ?? 0
        )
    }

    func configureNotificationProducerAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> UUID? {
        guard case .authenticating = notificationProducerSelectionState else { return nil }
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let id = UUID()
        notificationProducerAppleAttempt = (id, nonce)
        request.nonce = AccountWireCodec.encodeBase64URL(nonce)
        return id
    }

    func completeNotificationProducerAppleAuthorization(_ result: Result<ASAuthorization, Error>, attemptID: UUID?) {
        guard let attemptID, let attempt = notificationProducerAppleAttempt,
              attempt.id == attemptID, let target = notificationProducerTarget,
              let logicalMailboxID = notificationProducerMailboxID else { return }
        notificationProducerAppleAttempt = nil
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty else {
            notificationProducerAuthority = nil
            notificationProducerSelectionState = .unavailable
            return
        }
        guard let selectorFactory = notificationProducerSelectorFactory else {
            notificationProducerSelectionState = .unavailable
            return
        }
        notificationProducerSelectionState = .authenticating(authority: target.kind.authority)
        notificationProducerTask?.cancel()
        notificationProducerTask = Task { @MainActor [weak self] in
            defer { self?.notificationProducerTask = nil }
            do {
                let selector = try selectorFactory()
                let result = await selector.selectProducer(target: target, logicalMailboxID: logicalMailboxID, expectedGeneration: target.expectedGeneration, identityToken: identityToken, appleNonce: attempt.nonce)
                guard let self, !Task.isCancelled else { return }
                switch result {
                case .selected(let generation):
                    self.notificationProducerAuthority = target.kind.authority
                    if target.kind.authority == .mac {
                        self.lastMacAssignmentMailboxIDs.insert(logicalMailboxID)
                        self.updateDirectMacAlertAccounts()
                    }
                    self.notificationProducerSelectionState = .selected(authority: target.kind.authority, generation: generation)
                    // A new assignment generation invalidates every prior
                    // recipient record for this mailbox. If notifications
                    // are already registered, immediately upload the
                    // successor-generation records; otherwise the next
                    // explicit registration performs the same reconciliation.
                    if let registration = self.notificationRegistration {
                        self.notificationActionTask?.cancel()
                        self.notificationActionTask = Task { @MainActor [weak self, weak registration] in
                            guard let self, let registration else { return }
                            await registration.retry()
                            guard !Task.isCancelled else { return }
                            self.notificationStatus = registration.status
                            self.notificationActionTask = nil
                        }
                    }
                case .conflict:
                    self.notificationProducerAuthority = nil
                    self.notificationProducerSelectionState = .conflict
                case .unavailable:
                    self.notificationProducerAuthority = nil
                    self.notificationProducerSelectionState = .unavailable
                }
            } catch is CancellationError {
                return
            } catch {
                self?.notificationProducerSelectionState = .unavailable
            }
        }
    }

    func finishNotificationProducerEnrollment() {
        notificationProducerSelectionState = .idle
        notificationProducerTarget = nil
        notificationProducerMailboxID = nil
        notificationProducerAppleAttempt = nil
    }

    /// The mail root names this iPhone's Direct accounts; each gets the mailbox ID a Mac with
    /// the same account derives, so the Mac can be chosen to send its new mail as pushes.
    func setDirectMailAccounts(_ accounts: [(id: AccountID, email: String, imapHost: String)]) async {
        guard let factory = directInboxMailboxIDFactory, presentation.allowsMailbox else {
            directMacAlertAccounts = []
            return
        }
        var derived: [DirectMacAlertAccount] = []
        for account in accounts {
            guard let mailbox = try? await factory(account.imapHost, account.email) else { continue }
            derived.append(DirectMacAlertAccount(
                accountID: account.id, email: account.email, logicalMailboxID: mailbox, usesMac: false
            ))
        }
        directMacAlertAccounts = derived
        updateDirectMacAlertAccounts()
        directNotificationMailboxRows = directNotificationMailboxRows.map { row in
            NotificationDirectMailboxRow(
                logicalMailboxID: row.logicalMailboxID,
                label: directMailboxLabel(row.logicalMailboxID) ?? row.label
            )
        }
    }

    /// Starts choosing a Mac to send `accountID`'s new mail as pushes (Apple sign-in, then
    /// Central's assignment).
    func useMacForInstantAlerts(accountID: AccountID) {
        guard let account = directMacAlertAccounts.first(where: { $0.accountID == accountID }) else { return }
        selectNotificationProducer(logicalMailboxID: account.logicalMailboxID.rawValue)
    }

    /// The mailbox a producer picker opened without one ("Fix" after Turn On) assigns: the
    /// first Direct account no Mac sends for yet.
    var firstDirectMailboxWithoutMac: Data? {
        directMacAlertAccounts.first(where: { !$0.usesMac })?.logicalMailboxID.rawValue
    }

    var pendingNotificationProducerMailboxID: Data? { notificationProducerMailboxID }

    private func updateDirectMacAlertAccounts() {
        directMacAlertAccounts = directMacAlertAccounts.map { account in
            var account = account
            account.usesMac = lastMacAssignmentMailboxIDs.contains(account.logicalMailboxID.rawValue)
            return account
        }
    }

    private func directMailboxLabel(_ mailbox: LogicalMailboxID) -> String? {
        directMacAlertAccounts.first(where: { $0.logicalMailboxID == mailbox })?.email
    }

    func reapproveNotifications() {
        if pendingApprovalPrompt != nil || deviceApprovalPrompt != nil {
            beginApproval()
            return
        }
        guard presentation.allowsMailbox else {
            notificationStatus = .degraded(.unavailable)
            return
        }
        prepareNotificationRegistration()
        notificationActionTask?.cancel()
        notificationActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let setup = notificationRegistrationTask { await setup.value }
            guard let registration = notificationRegistration else {
                notificationStatus = .degraded(.unavailable)
                notificationActionTask = nil
                return
            }
            await registration.retry()
            notificationStatus = registration.status
            notificationActionTask = nil
        }
    }

    func refreshNotificationToken() {
        notificationAPNs?.resetCachedToken()
        retryNotifications()
    }


    func notificationPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> NodeSyncNotificationPolicy {
        guard let registration = notificationRegistration else { throw AccountRuntimeError.transportFailure }
        return try await registration.notificationPolicy(for: logicalMailboxID)
    }

    func notificationPolicyPresentation(for logicalMailboxID: LogicalMailboxID) async throws -> NotificationPolicyPresentationState {
        guard let registration = notificationRegistration else { throw AccountRuntimeError.transportFailure }
        return try await registration.notificationPolicyPresentation(for: logicalMailboxID)
    }

    func setNotificationPreviewPolicy(_ policy: NotificationPreviewPolicy, for logicalMailboxID: LogicalMailboxID) async throws {
        guard let registration = notificationRegistration else { throw AccountRuntimeError.transportFailure }
        try await registration.setPreviewPolicy(policy, for: logicalMailboxID)
    }

    func clearNotificationPreviewPolicy(for logicalMailboxID: LogicalMailboxID) async throws {
        guard let registration = notificationRegistration else { throw AccountRuntimeError.transportFailure }
        try await registration.clearPreviewPolicy(for: logicalMailboxID)
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard notificationAPNs?.didRegister(deviceToken: deviceToken) == true else { return }
        prepareNotificationRegistration()
        guard notificationRegistration != nil,
              notificationStatus == .registered || notificationStatus.recoveryAction == .refreshToken else { return }
        // APNs can rotate a token while the account remains active. A changed
        // token invalidates the Central route, so re-register through the same
        // bounded authenticated flow. Duplicate callbacks are ignored by the
        // token provider and cannot create an endless retry loop.
        retryNotifications()
    }
    func didFailToRegisterForRemoteNotifications(error: Error) { notificationAPNs?.didFail(error: error) }

    /// Notification links are opaque by design. The active mail runtime is
    /// refreshed first; consumers can resolve the token locally and fall back
    /// to Unified Inbox through this stable app-level event.
    ///
    /// Opening rebuilds the mail session and may switch to the message's
    /// owner; both discard an open composer. While the composer has unsaved
    /// changes, the latest tap waits and opens once it is saved or closed.
    func handleNotificationTap(_ request: MobileNotificationOpenRequest) {
        let token = request.token
        guard !token.isEmpty, token.utf8.count <= 256,
              !token.contains(where: { $0 == "\0" || $0.isNewline }) else { return }
        guard !mailComposerHasUnsavedChanges else {
            deferredNotificationTap = request
            hasDeferredNotificationOpen = true
            return
        }
        prepare()
        NotificationCenter.default.post(name: .plainpostOpenNotification, object: request)
    }

    /// Reported by the mail root. When the composer no longer has unsaved
    /// changes, a waiting notification tap opens.
    func setMailComposerHasUnsavedChanges(_ unsaved: Bool) {
        mailComposerHasUnsavedChanges = unsaved
        guard !unsaved, let request = deferredNotificationTap else { return }
        deferredNotificationTap = nil
        hasDeferredNotificationOpen = false
        handleNotificationTap(request)
    }

    /// Whether `authority` was bound by the user's own account switch, rather
    /// than by a session refresh, catalog change or notification owner.
    func isUserSelectedMailAuthority(_ authority: (any PlainpostMailAuthority)?) -> Bool {
        authority != nil && userSelectedMailAuthority.refers(to: authority)
    }

    /// Server Setup profiles are bearer capabilities: keep them in the app's
    /// own Keychain group, out of the notifications group that the
    /// Notification Service extension shares.
    static func makeSyncNodeBootstrapProfileStore() -> SyncNodeBootstrapProfileStore {
        SyncNodeBootstrapProfileStore(accessGroup: PlainpostIOSAppKeychain.accessGroup)
    }

    /// The Node refresh credential and cached endpoint live in the app's own
    /// Keychain group too. Records an earlier build left in the notifications
    /// group move there on first use.
    nonisolated static func makeSyncNodeEndpointStore() throws -> SyncNodeEndpointStore {
        try SyncNodeEndpointStore(accessGroup: PlainpostIOSAppKeychain.accessGroup, legacyAccessGroup: PlainpostIOSAppKeychain.notificationsAccessGroup)
    }

    /// A retained connection kept in memory but not renderable for the
    /// current session.
    var syncNodeEnrollmentAwaitsOwner: Bool {
        syncNodeEnrollmentModel != nil && presentableSyncNodeEnrollmentModel == nil
    }

    /// The Sync Node page is opening. Reads the owner again, so a one-off
    /// Keychain error does not hide the owner's own connection, and applies
    /// a Server Setup imported while an earlier model retained a replay.
    func prepareSyncNodeEnrollment() {
        dropSyncNodeEnrollmentOfAnotherOwner()
        refreshPresentableSyncNodeEnrollmentModel()
        if applyNewerSyncNodeProfile() { return }
        guard syncNodeEnrollmentModel == nil, syncNodeEnrollmentTask == nil, let syncNodeEnrollmentFactory else { return }
        syncNodeEnrollmentGeneration &+= 1
        let expectedGeneration = syncNodeEnrollmentGeneration
        syncNodeEnrollmentLoadPresentation = .loading
        syncNodeEnrollmentTask = Task { [weak self] in
            let model: SyncNodeEnrollmentViewModel
            do {
                model = try await syncNodeEnrollmentFactory()
            } catch {
                guard let self, !Task.isCancelled, self.syncNodeEnrollmentGeneration == expectedGeneration else { return }
                self.syncNodeEnrollmentTask = nil
                // Only the deliberate "no Node and no Server Setup" error means No Sync
                // Node; any other failure leaves it unknown whether the account has one.
                self.syncNodeEnrollmentLoadPresentation = .init(loadError: error)
                return
            }
            guard let self, !Task.isCancelled, self.syncNodeEnrollmentGeneration == expectedGeneration else {
                model.invalidateForReplacement()
                return
            }
            self.syncNodeEnrollmentTask = nil
            // The session can change while the factory runs. A model built
            // for a positively different owner is never published; a nil or
            // unreadable owner proves nothing and keeps it.
            if self.syncNodeEnrollmentBelongsToAnotherOwner(model) {
                model.invalidateForReplacement()
                self.syncNodeEnrollmentLoadPresentation = .idle
                return
            }
            self.syncNodeEnrollmentLoadPresentation = .ready
            self.syncNodeEnrollmentProfileGeneration = self.syncNodeBootstrapImportModel?.profileGeneration
            model.setInstallationConvergedHandler { [weak self, weak model] in
                guard let self, let model, self.syncNodeEnrollmentModel === model else { return }
                self.applyNewerSyncNodeProfile()
            }
            self.syncNodeEnrollmentModel = model
        }
    }

    /// Retries a failed Sync Node page load.
    func retrySyncNodeEnrollment() {
        guard case .failed = syncNodeEnrollmentLoadPresentation else { return }
        syncNodeEnrollmentLoadPresentation = .idle
        prepareSyncNodeEnrollment()
    }

    /// A new Server Setup replaces the enrollment model, except while the
    /// current model holds the only exact replay of a possibly committed
    /// admission. That model must converge first; the import is applied when
    /// it does, or when the Sync Node page next opens.
    func handleSyncNodeBootstrapFileImporter(_ result: Result<[URL], Error>) {
        guard let syncNodeBootstrapImportModel else { return }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        syncNodeBootstrapImportModel.handleFileImporter(result)
        if syncNodeEnrollmentModel == nil {
            // Restart a build in flight so it cannot publish the older profile.
            guard syncNodeBootstrapImportModel.profileGeneration != priorGeneration else { return }
            replaceSyncNodeEnrollmentModel()
            return
        }
        applyNewerSyncNodeProfile()
    }

    /// Changes the Server Setup's HTTPS address, keeping the pinned Node identity. A saved
    /// change is a new profile generation and is applied like an imported Server Setup.
    @discardableResult
    func updateSyncNodeServerOrigin(_ originText: String) -> SyncNodeBootstrapImportViewModel.ServerOriginUpdate {
        guard let syncNodeBootstrapImportModel else { return .unavailable }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        let result = syncNodeBootstrapImportModel.replaceServerOrigin(originText)
        guard case .saved = result else { return result }
        if syncNodeEnrollmentModel == nil {
            guard syncNodeBootstrapImportModel.profileGeneration != priorGeneration else { return result }
            replaceSyncNodeEnrollmentModel()
        } else {
            applyNewerSyncNodeProfile()
        }
        return result
    }

    /// Imports a Server Setup picked from the server address editor.
    func importSyncNodeBootstrapProfile(from url: URL) -> Bool {
        guard let syncNodeBootstrapImportModel else { return false }
        let priorGeneration = syncNodeBootstrapImportModel.profileGeneration
        handleSyncNodeBootstrapFileImporter(.success([url]))
        return syncNodeBootstrapImportModel.profileGeneration != priorGeneration
    }

    /// Rebuilds the published model for a Server Setup newer than the one it
    /// was built with, once the model no longer retains a replay. Returns
    /// whether a rebuild started.
    @discardableResult
    private func applyNewerSyncNodeProfile() -> Bool {
        guard let current = syncNodeEnrollmentModel,
              let syncNodeBootstrapImportModel,
              syncNodeBootstrapImportModel.profileGeneration != syncNodeEnrollmentProfileGeneration
        else { return false }
        // The current model holds the only exact replay of a possibly
        // committed admission; the newer profile waits for it to converge.
        guard !current.retainsInstallationReplay else { return false }
        let newest: SyncNodeBootstrapProfile?
        do { newest = try syncNodeBootstrapImportModel.loadProfile() } catch { return false }
        guard newest != nil else {
            // The model's own retirement after it connected leaves nothing
            // newer to apply.
            syncNodeEnrollmentProfileGeneration = syncNodeBootstrapImportModel.profileGeneration
            return false
        }
        replaceSyncNodeEnrollmentModel()
        return true
    }

    /// Callers first check that the current model retains no replay.
    private func replaceSyncNodeEnrollmentModel() {
        if let current = syncNodeEnrollmentModel {
            current.setInstallationConvergedHandler(nil)
            current.invalidateForReplacement()
        }
        syncNodeEnrollmentGeneration &+= 1
        syncNodeEnrollmentTask?.cancel()
        syncNodeEnrollmentTask = nil
        syncNodeEnrollmentModel = nil
        syncNodeEnrollmentProfileGeneration = nil
        prepareSyncNodeEnrollment()
    }

    /// Reads the owner once per presentation or model change, never from a
    /// view body. A retained connection renders only while its owner's
    /// session is the active one; a Keychain read error hides it.
    private func refreshPresentableSyncNodeEnrollmentModel() {
        var presentable: SyncNodeEnrollmentViewModel?
        if let model = syncNodeEnrollmentModel, presentation.allowsMailbox {
            if let syncNodeEnrollmentOwnerReader {
                if let owner = model.enrollmentOwner, (try? syncNodeEnrollmentOwnerReader()) == owner { presentable = model }
            } else if model.enrollmentOwner == nil {
                presentable = model
            }
        }
        if presentableSyncNodeEnrollmentModel !== presentable { presentableSyncNodeEnrollmentModel = presentable }
    }

    /// A connection started by another account or device can never finish
    /// here, so the current account gets a fresh one. An unreadable or
    /// signed-out session proves nothing and keeps the model.
    private func dropSyncNodeEnrollmentOfAnotherOwner() {
        guard let model = syncNodeEnrollmentModel, syncNodeEnrollmentBelongsToAnotherOwner(model) else { return }
        model.setInstallationConvergedHandler(nil)
        model.invalidateForReplacement()
        syncNodeEnrollmentModel = nil
        syncNodeEnrollmentProfileGeneration = nil
    }

    /// True only when the active session positively reads as a different
    /// owner. A signed-out or unreadable session proves nothing.
    private func syncNodeEnrollmentBelongsToAnotherOwner(_ model: SyncNodeEnrollmentViewModel) -> Bool {
        guard let syncNodeEnrollmentOwnerReader,
              let owner = model.enrollmentOwner,
              let current = try? syncNodeEnrollmentOwnerReader() else { return false }
        return current != owner
    }

    func prepare(now: Date = Date()) {
        guard !isShutDownForServerChange else { return }
        generation &+= 1
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = nil
        notificationProducerTask?.cancel()
        notificationProducerTask = nil
        notificationProducerAppleAttempt = nil
        notificationProducerTarget = nil
        notificationProducerMailboxID = nil
        notificationProducerTargets = []
        notificationProducerMailboxIDs = []
        notificationProducerSelectionState = .idle
        notificationProducerAuthority = nil
        resetAdmissionFlows()
        resetMailAuthority()
        // The session is read first; its authority attempt follows in apply.
        isPreparingMailAuthority = true
        let expectedGeneration = generation
        task?.cancel()
        let prepareSession = prepareSession
        task = Task { [weak self] in
            let state = await prepareSession(now)
            guard !Task.isCancelled, let self, generation == expectedGeneration else { return }
            apply(state, now: now)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        notificationProducerTask?.cancel()
        notificationProducerTask = nil
        resetMailAuthority()
        expiryTask?.cancel()
        expiryTask = nil
        appleAttempt = nil
        isAppleSignInInFlight = false
        appleSignInErrorMessage = nil
        notificationProducerAppleAttempt = nil
        notificationProducerTarget = nil
        notificationProducerMailboxID = nil
        notificationProducerTargets = []
        notificationProducerMailboxIDs = []
        notificationProducerSelectionState = .idle
        notificationProducerAuthority = nil
        resetAdmissionFlows()
    }

    func shutdownForServerChange() async {
        isShutDownForServerChange = true
        let running = [
            task,
            expiryTask,
            cleanupRegistrationTask,
            syncNodeEnrollmentTask,
            mailAuthorityTask,
            notificationRegistrationTask,
            notificationActionTask,
            notificationProducerTask,
        ].compactMap { $0 }
        cancel()
        cleanupRegistrationTask?.cancel()
        cleanupRegistrationTask = nil
        notificationRegistrationTask?.cancel()
        notificationRegistrationTask = nil
        notificationActionTask?.cancel()
        notificationActionTask = nil
        for task in running { await task.value }
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> UUID? {
        guard !isShutDownForServerChange,
              appleAttempt != nil || !isAppleSignInInFlight else { return nil }
        appleSignInErrorMessage = nil
        generation &+= 1
        task?.cancel()
        appleAttempt = nil
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let id = UUID()
        appleAttempt = (id, nonce)
        isAppleSignInInFlight = true
        request.nonce = AccountWireCodec.encodeBase64URL(nonce)
        return id
    }

    func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>, attemptID: UUID?) {
        guard let attemptID, let attempt = appleAttempt, attempt.id == attemptID else { return }
        switch result {
        case .failure(let error):
            appleAttempt = nil
            isAppleSignInInFlight = false
            presentation = .signInRequired
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                appleSignInErrorMessage = nil
            } else {
                appleSignInErrorMessage = "Apple sign-in could not finish. Try again."
            }
            return
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken else {
                appleAttempt = nil
                isAppleSignInInFlight = false
                presentation = .signInRequired
                appleSignInErrorMessage = "Apple did not provide a sign-in token. Try again."
                return
            }
            submitAppleIdentityToken(tokenData, attemptID: attempt.id)
        }
    }

    func submitAppleIdentityToken(_ tokenData: Data, attemptID: UUID?) {
        guard let attemptID, let attempt = appleAttempt, attempt.id == attemptID else { return }
        appleAttempt = nil
        guard let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let bootstrap else {
            isAppleSignInInFlight = false
            presentation = .signInRequired
            appleSignInErrorMessage = "Apple did not provide a sign-in token. Try again."
            return
        }
        generation &+= 1
        let expectedGeneration = generation
        task?.cancel()
        task = Task { [weak self] in
            do {
                let state = try await bootstrap(token, attempt.nonce)
                guard !Task.isCancelled, let self, generation == expectedGeneration else { return }
                isAppleSignInInFlight = false
                // A recovery that follows reuses this sign-in instead of asking Apple again.
                recentAppleSignIn = RecentAppleSignIn(identityToken: token, rawNonce: attempt.nonce, obtainedAt: Date())
                apply(state, now: Date())
            } catch {
                guard !Task.isCancelled, let self, generation == expectedGeneration else { return }
                isAppleSignInInFlight = false
                presentation = .signInRequired
                appleSignInErrorMessage = AppleSignInFailureMessages.message(
                    for: error, deviceName: "iPhone",
                    fallback: "Plainpost could not connect your account. Try signing in with Apple again."
                )
            }
        }
    }

    func waitForAppleSignInToSettle() async { await task?.value }

    static func presentation(for state: AccountSessionState, now: Date) -> MobileAccountPresentation {
        switch state {
        case .provisional(let activation): activation.mode == .pending ? .pendingApproval(matchingCode: nil) : .recoveryRequired
        case .active: .active
        case .offlineLease(let expiry): expiry > now ? .offlineLease(expiresAt: expiry) : .recoveryRequired
        case .signInRequired: .signInRequired
        case .suspended: .suspended
        case .cleanupRequired: .cleanupRequired
        case .deleted: .deleted
        case .expired: .recoveryRequired
        }
    }

    private func setPresentation(_ next: MobileAccountPresentation, now: Date) {
        expiryTask?.cancel()
        expiryTask = nil
        presentation = next
        guard case .offlineLease(let expiresAt) = next, now < expiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSince(now))
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled,
                  let self,
                  self.presentation == .offlineLease(expiresAt: expiresAt) else { return }
            self.resetMailAuthority()
            self.presentation = .recoveryRequired
        }
    }

    private func apply(_ accountState: AccountSessionState, now: Date) {
        if case .active = accountState {
            // Keep the registration model while an active session is merely
            // refreshed. Non-active transitions discard the in-memory model so
            // a later account cannot inherit another account's status.
        } else {
            notificationActionTask?.cancel()
            notificationRegistrationTask?.cancel()
            notificationRegistrationTask = nil
            notificationRegistration = nil
            notificationStatus = .unconfigured
            notificationPolicySelected = false
            notificationProducerSelectionState = .idle
            notificationProducerAuthority = nil
            notificationProducerTargets = []
            notificationProducerMailboxIDs = []
            notificationProducerTarget = nil
            notificationProducerMailboxID = nil
            notificationProducerAppleAttempt = nil
        }
        admissionObservation = nil; admissionController?.cancel(); admissionController = nil
        activeAdmissionObservation = nil; activeAdmissionController?.cancel(); activeAdmissionController = nil
        approvalCoordinator.cancel(); approvalCapability = nil; pendingDeviceApprovalTracker.resetFlow(); deviceApprovalPrompt = nil
        resetMailAuthority()
        setPresentation(Self.presentation(for: accountState, now: now), now: now)
        prepareMailAuthority(for: accountState)
        if case .active = accountState {
            // Notification registration is account-owned and does not depend
            // on a Sync Node-backed mail authority being available.
            prepareNotificationRegistration()
            scheduleCleanupRegistration()
            #if DEBUG
            applyDebugAccountPrompts()
            #endif
        }
        if case .active = accountState, let activeAdmissionFactory {
            do {
                let controller = try activeAdmissionFactory(); activeAdmissionController = controller
                activeAdmissionObservation = controller.states.sink { [weak self] state in
                    guard let self else { return }
                    pendingDeviceApprovalTracker.receive(state)
                    switch state {
                    case .idle, .awaitingResponse, .failed: deviceApprovalPrompt = nil; approvalCapability = nil
                    case .awaitingConfirmation(let prompt): deviceApprovalPrompt = prompt; approvalCapability = controller.currentApprovalCapability()
                    }
                }
                controller.refresh()
            } catch { setPresentation(.recoveryRequired, now: now) }
            return
        }
        guard case .provisional(let activation) = accountState, let admissionFactory else { return }
        do {
            let controller = try admissionFactory(activation)
            admissionController = controller
            admissionObservation = controller.states.sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .waiting: self.presentation = .pendingApproval(matchingCode: nil)
                case .matchingCode(let code): self.presentation = .pendingApproval(matchingCode: code)
                case .admitted:
                    self.presentation = .active
                    self.scheduleCleanupRegistration()
                    // Admission changes the authenticated session and trust
                    // generation. Reload both before publishing Node mail so
                    // the authority cannot be built from provisional state.
                    self.prepare(now: Date())
                case .expired, .failed: self.presentation = .recoveryRequired
                }
            }
            controller.start(now: now)
        } catch { presentation = .recoveryRequired }
    }

    private func prepareMailAuthority(for accountState: AccountSessionState) {
        resetMailAuthority()
        let access: PlainpostRuntimeAccountAccess
        switch accountState {
        case .active: access = .readWrite
        case .offlineLease: access = .cachedReadOnly
        default: return
        }
        let expectedGeneration = generation
        mailAuthorityAttempt &+= 1
        let attempt = mailAuthorityAttempt
        if let nodeMailSessionFactory {
            mailAccountToken &+= 1
            let token = mailAccountToken
            isPreparingMailAuthority = true
            mailAuthorityTask = Task { @MainActor [weak self] in
                defer { self?.finishMailAuthorityAttempt(attempt) }
                do {
                    let session = try await nodeMailSessionFactory(access)
                    let catalog = try await Self.loadMailCatalog(session.client)
                    try Task.checkCancellation()
                    guard let self, self.isCurrentMailOperation(token: token, generation: expectedGeneration) else { return }
                    self.publishCatalog(catalog, session: session, access: access, requested: nil)
                    // Restore persisted notification state as soon as the
                    // authenticated authority exists; APNs callbacks may have
                    // arrived before this asynchronous assembly completed.
                    self.prepareNotificationRegistration()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.isCurrentMailOperation(token: token, generation: expectedGeneration) else { return }
                    self.mailAuthority = nil
                    self.mailAuthorityBinding = nil
                    self.syncNodeProviderController = nil
                }
            }
            return
        }
        guard let mailAuthorityFactory else { return }
        isPreparingMailAuthority = true
        mailAuthorityTask = Task { @MainActor [weak self] in
            defer { self?.finishMailAuthorityAttempt(attempt) }
            do {
                let authority = try await mailAuthorityFactory(access)
                try Task.checkCancellation()
                guard let self, self.generation == expectedGeneration else { return }
                self.mailAuthority = authority
                self.syncNodeProviderController = (authority as? PlainpostNodeMailAuthority)?.providerController
                self.prepareNotificationRegistration()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.mailAuthority = nil
                self.syncNodeProviderController = nil
            }
        }
    }

    private func finishMailAuthorityAttempt(_ attempt: UInt64) {
        guard attempt == mailAuthorityAttempt else { return }
        isPreparingMailAuthority = false
    }

    private func resetMailAuthority() {
        mailAuthorityTask?.cancel()
        mailAuthorityTask = nil
        mailAuthorityAttempt &+= 1
        isPreparingMailAuthority = false
        mailAccountToken &+= 1
        mailSelectionRevision &+= 1
        mailAuthority = nil
        mailAuthorityBinding = nil
        syncNodeProviderController = nil
        nodeMailSession = nil
        mailAccounts = []
        selectedMailAccountID = nil
        unscopedMailSender = nil
    }

    private func enterCleanupRequired() {
        generation &+= 1
        task?.cancel()
        resetMailAuthority()
        resetAdmissionFlows()
        setPresentation(.cleanupRequired, now: Date())
    }

    private func scheduleCleanupRegistration() {
        guard let activeCleanupRegistration else { return }
        cleanupRegistrationTask?.cancel()
        cleanupRegistrationTask = Task { await activeCleanupRegistration() }
    }

    func beginApproval() {
        guard let activeAdmissionController, let prompt = pendingDeviceApprovalTracker.beginReview() else { return }
        activeAdmissionController.begin(prompt)
    }
    func dismissPendingDeviceApproval() {
        if pendingDeviceApprovalTracker.dismiss() { activeAdmissionController?.refresh() }
    }
    func confirmApproval() { guard let approvalCapability else { return }; approvalCoordinator.present(approvalCapability); approvalCoordinator.approve() }
    func configureDeviceApprovalAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> UUID? {
        guard deviceApprovalPrompt != nil, deviceApprovalAppleAttempt == nil else { return nil }
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let id = UUID()
        deviceApprovalAppleAttempt = (id, nonce)
        request.nonce = AccountWireCodec.encodeBase64URL(nonce)
        return id
    }
    func completeDeviceApprovalAppleAuthorization(_ result: Result<ASAuthorization, Error>, attemptID: UUID?) {
        guard let attemptID, let attempt = deviceApprovalAppleAttempt, attempt.id == attemptID else { return }
        deviceApprovalAppleAttempt = nil
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let activeAdmissionController else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capability = try await activeAdmissionController.authorizeCurrentApproval(identityToken: token, appleNonce: attempt.nonce)
                guard self.activeAdmissionController != nil, self.deviceApprovalPrompt != nil else { await capability.cancel(); return }
                self.approvalCapability = capability
                self.approvalCoordinator.present(capability)
                self.approvalCoordinator.approve()
            } catch { }
        }
    }
    func waitForDeviceApprovalToSettle() async { await approvalCoordinator.waitUntilIdle() }
    /// Another device recovered or suspended this Plainpost Account, so this device's
    /// session can't come back. It signs in again like a new device: then a trusted device
    /// approves it, or it recovers the account.
    var canSignInAgainAfterSuspension: Bool { discardSuspendedSession != nil }

    func signInAgainAfterSuspension() {
        guard case .suspended = presentation, let discardSuspendedSession else { return }
        Task { [weak self] in
            let state = await discardSuspendedSession(Date())
            self?.apply(state, now: Date())
        }
    }

    func cancelPendingApproval() {
        admissionObservation = nil
        admissionController?.cancel()
        admissionController = nil
        setPresentation(.recoveryRequired, now: Date())
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
        approvalCoordinator.cancel()
        approvalCapability = nil
        deviceApprovalAppleAttempt = nil
        pendingDeviceApprovalTracker.resetFlow()
        deviceApprovalPrompt = nil
    }
}

// MARK: - Sync Node mail accounts

/// What the published authority is bound to. An equal binding keeps the
/// authority (and therefore the running mail runtime) across refreshes.
private struct MobileMailAuthorityBinding: Equatable {
    let client: ObjectIdentifier
    let access: PlainpostRuntimeAccountAccess
    let logicalMailboxID: LogicalMailboxID?
    let providerIdentity: String?
    let needsAttention: Bool
    let multiAccount: Bool
}

private struct MobileMailCatalog: Sendable {
    let accounts: [NodeMailAccount]
    let multiAccount: Bool
    let unscopedSender: String?
}

extension MobileAccountModel {
    /// The old device-global selection key. It may name another Plainpost
    /// account's mailbox, so it is ignored and removed.
    nonisolated static let legacySelectedMailAccountDefaultsKey = "plainpost.ios.selectedMailAccount"
    nonisolated static let selectedMailAccountDefaultsKeyPrefix = "plainpost.ios.selectedMailAccount.v2."

    /// Non-secret key holding the raw base64url logical mailbox of the selected
    /// account, one per Plainpost account. The key carries a digest, not the
    /// account ID.
    nonisolated static func selectedMailAccountDefaultsKey(for accountID: AccountID) -> String {
        let digest = SHA256.hash(data: Data("Plainpost.MobileSelectedMailAccount.v2\0\(accountID.rawValue)".utf8))
        return selectedMailAccountDefaultsKeyPrefix + AccountWireCodec.encodeBase64URL(Data(digest.prefix(16)))
    }

    var selectedMailAccount: NodeMailAccount? {
        mailAccounts.first { $0.logicalMailboxID == selectedMailAccountID }
    }

    /// Google onboarding configures the Node's primary account through the
    /// primary-only provider routes, so it is offered only while the primary
    /// (or the unscoped onboarding authority) is selected.
    var allowsGoogleProviderOnboarding: Bool {
        selectedMailAccount.map(\.isPrimary) ?? true
    }

    /// Notification-policy mailboxes for the selected account from the
    /// authenticated account catalog: one row per account (its logical
    /// mailbox) when it has a Sync Node producer assignment. Nil when no
    /// catalog account is selected.
    func selectedAccountNotificationPolicyMailboxes(syncNodeMailboxIDs: Set<Data>) -> [SyncNodeProviderMailbox]? {
        guard let account = selectedMailAccount else { return nil }
        guard syncNodeMailboxIDs.contains(account.logicalMailboxID.rawValue) else { return [] }
        let inbox = account.mailboxes.first { $0.role == "inbox" } ?? account.mailboxes.first
        return [SyncNodeProviderMailbox(
            displayName: account.providerIdentity,
            mailboxHandle: inbox?.mailboxHandle ?? "INBOX",
            role: inbox?.role ?? "inbox",
            logicalMailboxID: account.logicalMailboxID
        )]
    }

    /// Waits for any in-flight session and authority preparation to finish.
    func settleMailAuthorityPreparation() async {
        if let task { await task.value }
        if let mailAuthorityTask { await mailAuthorityTask.value }
    }

    /// Re-reads the Node account catalog. The selected account's authority is
    /// kept when it is unchanged; a removed selection falls back to the
    /// primary account. A failed refresh keeps what is published, so a
    /// transient Node error never blanks the open mailbox.
    func refreshMailAccounts() async {
        guard nodeMailSessionFactory != nil, let access = currentMailAccess else { return }
        mailAccountToken &+= 1
        let token = mailAccountToken
        let expectedGeneration = generation
        do {
            let session = try await currentOrNewMailSession(access: access)
            let catalog = try await Self.loadMailCatalog(session.client)
            guard isCurrentMailOperation(token: token, generation: expectedGeneration) else { return }
            publishCatalog(catalog, session: session, access: access, requested: nil)
        } catch {
            return
        }
    }

    /// Why account-mode mail has no authority, as far as the enrollment state
    /// this account may present can tell.
    var mailUnavailability: MobileAccountMailUnavailability {
        MobileAccountMailUnavailability(enrollment: presentableSyncNodeEnrollmentModel, load: syncNodeEnrollmentLoadPresentation)
    }

    /// Retry for account-mode mail with no authority: rebuilds the Node
    /// session and authority without re-running the account session, and
    /// re-reads the enrollment state the unavailable copy depends on.
    func retryMailAuthority() async {
        #if DEBUG
        debugMailSessionGate?.isOpen = true
        #endif
        prepareSyncNodeEnrollment()
        // A Retry while the first attempt runs waits for it: refreshing now
        // would advance the token and drop that attempt's authority.
        await settleMailAuthorityPreparation()
        guard mailAuthority == nil else { return }
        await refreshMailAccounts()
    }

    /// The user's own account switch: selects one listed account, persists it,
    /// and rebinds the scoped authority so every read and mutation is routed
    /// to that account.
    func selectMailAccount(_ id: LogicalMailboxID) async {
        selectMailAccount(id, byUser: true)
    }

    private func selectMailAccount(_ id: LogicalMailboxID, byUser: Bool) {
        guard let nodeMailSession, mailAccounts.contains(where: { $0.logicalMailboxID == id }) else { return }
        mailSelectionDefaults.set(
            AccountWireCodec.encodeBase64URL(id.rawValue),
            forKey: Self.selectedMailAccountDefaultsKey(for: nodeMailSession.session.accountID)
        )
        mailAccountToken &+= 1
        mailSelectionRevision &+= 1
        let previous = MobileMailAuthorityReference(mailAuthority)
        bindSelectedMailAuthority(session: nodeMailSession.session, access: nodeMailSession.access, requested: id)
        // Only a newly bound authority is the user's switch; reselecting the
        // current account changes nothing.
        if byUser, let mailAuthority, !previous.refers(to: mailAuthority) {
            userSelectedMailAuthority = MobileMailAuthorityReference(mailAuthority)
        }
    }

    private var currentMailAccess: PlainpostRuntimeAccountAccess? {
        if let nodeMailSession { return nodeMailSession.access }
        switch presentation {
        case .active: return .readWrite
        case .offlineLease: return .cachedReadOnly
        default: return nil
        }
    }

    private func currentOrNewMailSession(access: PlainpostRuntimeAccountAccess) async throws -> MobileNodeMailSession {
        if let nodeMailSession, nodeMailSession.access == access { return nodeMailSession.session }
        guard let nodeMailSessionFactory else { throw AccountRuntimeError.untrustedResponse }
        return try await nodeMailSessionFactory(access)
    }

    fileprivate func isCurrentMailOperation(token: UInt64, generation expected: UInt64) -> Bool {
        !Task.isCancelled && !isShutDownForServerChange && token == mailAccountToken && generation == expected
    }

    fileprivate static func loadMailCatalog(_ client: NodeSyncClient) async throws -> MobileMailCatalog {
        let loaded = try await NodeMailAccountCatalog.load(client)
        // With no provider account the unscoped authority keeps provider
        // onboarding available and, as before, trusts the status identity.
        let unscopedSender = loaded.accounts.isEmpty ? try await client.status().providerIdentity : nil
        return MobileMailCatalog(accounts: loaded.accounts, multiAccount: loaded.multiAccount, unscopedSender: unscopedSender)
    }

    fileprivate func publishCatalog(
        _ catalog: MobileMailCatalog,
        session: MobileNodeMailSession,
        access: PlainpostRuntimeAccountAccess,
        requested: LogicalMailboxID?
    ) {
        mailAccounts = catalog.accounts
        mailAccountsMultiAccount = catalog.multiAccount
        unscopedMailSender = catalog.unscopedSender
        nodeMailSession = (session, access)
        bindSelectedMailAuthority(session: session, access: access, requested: requested)
    }

    private func bindSelectedMailAuthority(
        session: MobileNodeMailSession,
        access: PlainpostRuntimeAccountAccess,
        requested: LogicalMailboxID?
    ) {
        let selectionKey = Self.selectedMailAccountDefaultsKey(for: session.accountID)
        mailSelectionDefaults.removeObject(forKey: Self.legacySelectedMailAccountDefaultsKey)
        let persisted = mailSelectionDefaults.string(forKey: selectionKey)
            .flatMap { try? AccountWireCodec.decodeBase64URL($0, exactBytes: 32) }
            .flatMap(LogicalMailboxID.init(rawValue:))
        func listed(_ id: LogicalMailboxID?) -> NodeMailAccount? {
            id.flatMap { id in mailAccounts.first { $0.logicalMailboxID == id } }
        }
        let selected = listed(requested) ?? listed(persisted)
            ?? mailAccounts.first(where: \.isPrimary) ?? mailAccounts.first
        if persisted != nil, listed(persisted) == nil, mailAccountsMultiAccount {
            // The account is gone from a full catalog; logical mailboxes are
            // never reused, so the stale selection is dropped. A legacy
            // single-account projection keeps it for a later upgrade.
            mailSelectionDefaults.removeObject(forKey: selectionKey)
        }
        selectedMailAccountID = selected?.logicalMailboxID
        let binding = MobileMailAuthorityBinding(
            client: ObjectIdentifier(session.client), access: access,
            logicalMailboxID: selected?.logicalMailboxID,
            providerIdentity: selected?.providerIdentity ?? unscopedMailSender,
            needsAttention: selected?.state == .authenticationRequired,
            multiAccount: mailAccountsMultiAccount
        )
        guard binding != mailAuthorityBinding || mailAuthority == nil else { return }
        let factoryAccess: PlainpostNodeMailAuthorityFactory.Access = access == .cachedReadOnly ? .cachedReadOnly : .authorized
        do {
            let authority: any PlainpostMailAuthority
            if let selected {
                authority = try PlainpostNodeMailAuthorityFactory.make(
                    client: session.client, accountID: session.accountID,
                    mailAccount: selected, multiAccount: mailAccountsMultiAccount, access: factoryAccess,
                    requiresSendJournal: false
                )
            } else {
                authority = try PlainpostNodeMailAuthorityFactory.make(
                    client: session.client, accountID: session.accountID,
                    senderAddress: unscopedMailSender, access: factoryAccess
                )
            }
            mailAuthority = authority
            mailAuthorityBinding = binding
            syncNodeProviderController = (authority as? PlainpostNodeMailAuthority)?.providerController
        } catch {
            mailAuthority = nil
            mailAuthorityBinding = nil
            syncNodeProviderController = nil
        }
    }

}

/// Why account-mode mail has no authority. The cause is named only when the
/// enrollment state proves it: a load that found no Sync Node and no Server
/// Setup, a loaded connection whose trust commit lists no Sync Node, or one
/// whose Node failed its connection check. With no loaded connection (a failed
/// load, one not run yet, another owner's) the cases cannot be told apart, so
/// the copy stays neutral.
enum MobileAccountMailUnavailability: Equatable {
    case noSyncNode
    case syncNodeUnreachable
    case undetermined

    @MainActor
    init(
        enrollment: SyncNodeEnrollmentViewModel?,
        load: AccountSessionViewModel.SyncNodeEnrollmentLoadPresentation = .idle
    ) {
        guard let enrollment else {
            self = load == .noSyncNode ? .noSyncNode : .undetermined
            return
        }
        if enrollment.activeNodeID == nil {
            self = .noSyncNode
        } else if enrollment.connectionPresentation == .connectionFailed {
            self = .syncNodeUnreachable
        } else {
            // A Node that checks out, needs recovery or is mid-connection
            // proves nothing about why the authority failed (admission,
            // session or catalog).
            self = .undetermined
        }
    }

    var message: String {
        switch self {
        case .noSyncNode: return "Set up a Sync Node to read mail in your Plainpost account."
        case .syncNodeUnreachable: return "Can't reach your Sync Node. Check your connection and try again."
        case .undetermined: return "Mail comes from your Sync Node. Set it up or try again."
        }
    }
}

#if DEBUG
@MainActor
final class DebugMailSessionGate {
    var isOpen = false
}
#endif
