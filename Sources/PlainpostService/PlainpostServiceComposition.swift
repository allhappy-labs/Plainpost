import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostAccounts
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostDB
import PlainpostNodeMailMode
import PlainpostNotificationRuntime
import PlainpostNodeTransport
import PlainpostSecrets
import PlainpostServiceIPC
import PlainpostServiceRuntime

private func assignmentsHaveStableIdentity(
    _ lhs: [NotificationProducerAssignment],
    _ rhs: [NotificationProducerAssignment]
) -> Bool {
    func sort(_ values: [NotificationProducerAssignment]) -> [NotificationProducerAssignment] {
        values.sorted { left, right in
            if left.logicalMailboxID != right.logicalMailboxID {
                return left.logicalMailboxID.lexicographicallyPrecedes(right.logicalMailboxID)
            }
            if left.producerDeviceID != right.producerDeviceID { return left.producerDeviceID.rawValue < right.producerDeviceID.rawValue }
            if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
            if left.generation != right.generation { return left.generation < right.generation }
            if left.trustEpoch != right.trustEpoch { return left.trustEpoch < right.trustEpoch }
            if left.trustRevision != right.trustRevision { return left.trustRevision < right.trustRevision }
            if left.trustHead != right.trustHead { return left.trustHead.lexicographicallyPrecedes(right.trustHead) }
            return (left.producerSigningPublicKey ?? Data()).lexicographicallyPrecedes(right.producerSigningPublicKey ?? Data())
        }
    }
    return sort(lhs) == sort(rhs)
}

struct PlainpostServiceComposition {
    let listener: PlainpostServiceListener
    let lifecycle: PlainpostServiceLifecycleCoordinator
    let operations: PlainpostServiceOperations
    let store: SQLiteMailStore
    /// The service-lifetime Node mirror; `main` starts and stops it.
    var nodeMailMirror: NodeMailMirrorLoop? = nil
    /// The single mail-intent dispatcher. Its session provider is the
    /// reachability supervisor, attached in `startNodeMailMode()`.
    var mailIntentRouter: MailIntentRouter? = nil
    /// The service-lifetime reachability supervisor: fallback and reconnect
    /// happen whether or not the app is open.
    var nodeReachability: NodeReachabilitySupervisor? = nil

    /// Starts Node mail mode for the service's lifetime: the router gets the
    /// supervisor as its session provider before anything dispatches, then
    /// the mirror loop and the supervisor start.
    static func startNodeMailMode(
        router: MailIntentRouter?,
        mirror: NodeMailMirrorLoop?,
        reachability: NodeReachabilitySupervisor?
    ) async {
        if let router, let reachability {
            await router.attach(sessions: reachability)
        }
        await mirror?.start()
        await reachability?.start()
    }

    /// Stops the supervisor (probes, pending mirror wakes), then the mirror.
    static func stopNodeMailMode(mirror: NodeMailMirrorLoop?, reachability: NodeReachabilitySupervisor?) async {
        await reachability?.stop()
        await mirror?.stop()
    }

    /// Narrow dependency-injected seam used by production composition and
    /// authenticated integration tests. The default factory supplies the
    /// authenticated clients below; tests can supply fakes without bypassing
    /// the service operation hook.
    struct DirectNotificationAssembly {
        let notificationDrain: (any NotificationDraining)?
        let install: (@Sendable () async -> Void)?

        init(
            notificationDrain: (any NotificationDraining)?,
            install: (@Sendable () async -> Void)?
        ) {
            self.notificationDrain = notificationDrain
            self.install = install
        }
    }

    /// The Mac's notification producer follows the Plainpost Account session: signing in,
    /// recovering or switching accounts after the service started rebuilds it, instead of
    /// leaving the service without a producer until it restarts.
    final class DirectNotificationAssemblyCache: @unchecked Sendable {
        private let lock = NSLock()
        private let sessionIdentity: @Sendable () -> String?
        private let make: @Sendable () -> DirectNotificationAssembly
        private let now: @Sendable () -> Date
        private var built: (identity: String?, assembly: DirectNotificationAssembly, at: Date)?

        init(
            sessionIdentity: @escaping @Sendable () -> String?,
            make: @escaping @Sendable () -> DirectNotificationAssembly,
            now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.sessionIdentity = sessionIdentity
            self.make = make
            self.now = now
        }

        func current() -> DirectNotificationAssembly {
            let identity = sessionIdentity()
            return lock.withLock {
                if let built, built.identity == identity {
                    // An active session whose producer couldn't be built (Central briefly
                    // unreachable, say) tries again at most once a minute.
                    let retry = identity != nil && built.assembly.notificationDrain == nil
                        && now().timeIntervalSince(built.at) >= 60
                    if !retry { return built.assembly }
                }
                let assembly = make()
                built = (identity, assembly, now())
                return assembly
            }
        }
    }

    /// Drains whatever producer the session currently has; none drains nothing.
    struct SessionFollowingNotificationDrain: NotificationDraining {
        let cache: DirectNotificationAssemblyCache

        func drain() async throws -> NotificationDrainResult {
            guard let current = cache.current().notificationDrain else {
                return NotificationDrainResult(claimedCount: 0, frozenCount: 0, deliveredCount: 0, retryAt: nil)
            }
            return try await current.drain()
        }
    }

    static func makeBoundAccountAPI(
        transport: any AccountHTTPTransport,
        credentials: any AccountCredentialStoring,
        manifest: BootstrapKeyManifestStore,
        configurationStore: any CentralServerConfigurationStoring,
        bundledDocument: Data? = CentralServerConfiguration.bundledDocument
    ) throws -> AccountAPIClient? {
        guard case .configured(let server) = CentralServerConfigurationResolver(
            store: configurationStore
        ).resolve(bundledDocument: bundledDocument, credentials: credentials) else { return nil }
        return try AccountAPIClient(
            transport: transport,
            credentialStore: credentials,
            manifestStore: manifest,
            baseURL: server.origin
        )
    }

    private actor DirectNotificationReconciliationCoordinator {
        private var tail: Task<Bool, Never>?

        func reconcile(_ operation: @escaping @Sendable () async -> Bool) async -> Bool {
            let predecessor = tail
            let current = Task { [predecessor] in
                _ = await predecessor?.value
                return await operation()
            }
            tail = current
            return await current.value
        }
    }

    static func makeDirectNotificationAssembly(
        store: SQLiteMailStore,
        plainpostAccountID: PlainpostAccountID,
        producerDeviceID: AccountDeviceID,
        notificationDrain: NotificationDrain?,
        fetchAssignments: @escaping @Sendable () async throws -> [NotificationProducerAssignment],
        fetchSnapshot: @escaping @Sendable () async throws -> DirectNotificationPolicySnapshot,
        currentIdentity: @escaping @Sendable () throws -> (PlainpostAccountID, AccountDeviceID)?,
        derivedInboxMailboxIDs: @escaping @Sendable () async -> [AccountID: LogicalMailboxID] = { [:] }
    ) -> DirectNotificationAssembly {
        let coordinator = DirectNotificationReconciliationCoordinator()
        return DirectNotificationAssembly(
            notificationDrain: notificationDrain,
            install: {
                _ = await coordinator.reconcile {
                    await DirectNotificationConfigurationInstaller.reconcile(
                        store: store,
                        plainpostAccountID: plainpostAccountID,
                        producerDeviceID: producerDeviceID,
                        fetchAssignments: fetchAssignments,
                        fetchSnapshot: fetchSnapshot,
                        currentIdentity: currentIdentity,
                        derivedInboxMailboxIDs: derivedInboxMailboxIDs
                    )
                }
            }
        )
    }

    /// The Mac's producer follows the Plainpost Account session (see
    /// `DirectNotificationAssemblyCache`): its drain and install always use the current one.
    private static func makeProductionDirectNotificationAssembly(
        store: SQLiteMailStore,
        databaseURL: URL
    ) -> DirectNotificationAssembly {
        let sessionCredentials = AccountCredentialStore(
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        let cache = DirectNotificationAssemblyCache(
            sessionIdentity: {
                guard let session = try? sessionCredentials.loadSession(), session.state == .active,
                      let credentials = session.credentials else { return nil }
                return "\(credentials.accountID.rawValue)/\(credentials.deviceID.rawValue)"
            },
            make: { Self.makeSessionDirectNotificationAssembly(store: store, databaseURL: databaseURL) }
        )
        return DirectNotificationAssembly(
            notificationDrain: SessionFollowingNotificationDrain(cache: cache),
            install: { await cache.current().install?() }
        )
    }

    private static func makeSessionDirectNotificationAssembly(
        store: SQLiteMailStore,
        databaseURL: URL
    ) -> DirectNotificationAssembly {
        // The service is the sole Mac notification producer. Its account
        // records are read from the app/service keychain group; no local
        // mailbox path is allowed to become an authority coordinate.
        let accountCredentials = AccountCredentialStore(
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        let configurationStore = KeychainCentralServerConfigurationStore(
            secretStore: KeychainAccountSecretStore(),
            accessGroup: PlainpostAccountSharedKeychain.accessGroup
        )
        guard let session = try? accountCredentials.loadSession(),
              session.state == .active,
              let credentials = session.credentials,
              let identity = try? accountCredentials.loadExistingDeviceIdentity()
        else {
            return DirectNotificationAssembly(notificationDrain: nil, install: nil)
        }

        do {
            // Notification authority is an optional service capability. Mail
            // XPC must still start if construction is temporarily unavailable;
            // the absent drain leaves publication fail-closed.
            let manifest = try BootstrapKeyManifestStore()
            guard let accountAPI = try Self.makeBoundAccountAPI(
                transport: URLSessionAccountHTTPTransport(),
                credentials: accountCredentials,
                manifest: manifest,
                configurationStore: configurationStore
            ) else { return DirectNotificationAssembly(notificationDrain: nil, install: nil) }
            let refreshLockURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("notification-session-refresh.lock")
            let coordination = AuthenticatedNotificationCoordinationClient(
                api: accountAPI,
                credentialStore: accountCredentials,
                refreshLockURL: refreshLockURL
            )
            let producerSelector = AuthenticatedNotificationProducerSelector(
                api: accountAPI,
                credentialStore: accountCredentials,
                refreshLockURL: refreshLockURL
            )
            let directPolicyClient = AuthenticatedDirectNotificationPolicyClient(
                api: accountAPI,
                credentialStore: accountCredentials,
                refreshLockURL: refreshLockURL
            )
            let snapshot = SQLiteNotificationSnapshotProvider(
                store: store,
                plainpostAccountID: credentials.accountID
            )
            let preview = PPN2NotificationPreviewBuilder(
                producerDeviceID: credentials.deviceID,
                producerSigningPublicKey: identity.publicBundle.signingKey,
                sign: { transcript in try identity.signature(for: transcript) },
                snapshot: { source, claim in
                    try snapshot.snapshot(source: source, claim: claim)
                },
                trust: { _, _ in
                    guard let commit = try accountCredentials.loadCurrentTrustCommit(
                        for: credentials.accountID
                    ) else {
                        throw NotificationRuntimeError.unavailable
                    }
                    return try NotificationTrustCoordinates(
                        epoch: commit.state.epoch.value,
                        revision: commit.state.revision.value,
                        head: AccountTranscript.trustCommitDigest(commit)
                    )
                }
            )
            let producer = NotificationProducer(
                coordination: coordination,
                verifier: coordination,
                previewBuilder: preview
            )
            let relay = AuthenticatedNotificationRelayClient(
                api: accountAPI,
                credentialStore: accountCredentials,
                refreshLockURL: refreshLockURL
            )
            let drain = NotificationDrain(store: store, producer: producer, relay: relay)
            let trust = try accountCredentials.makeTrustCoordinator(
                accountID: credentials.accountID, deviceID: credentials.deviceID,
                platform: .macos, identity: identity
            )
            return Self.makeDirectNotificationAssembly(
                store: store,
                plainpostAccountID: credentials.accountID,
                producerDeviceID: credentials.deviceID,
                notificationDrain: drain,
                fetchAssignments: {
                    try await producerSelector.currentProducerAssignments()
                },
                fetchSnapshot: { try await directPolicyClient.snapshot() },
                currentIdentity: {
                    guard let current = try accountCredentials.loadSession(),
                          current.state == .active,
                          let currentCredentials = current.credentials
                    else {
                        return nil
                    }
                    return (currentCredentials.accountID, currentCredentials.deviceID)
                },
                derivedInboxMailboxIDs: {
                    // An account whose ID can't be derived (no trust material yet) stays
                    // unbound until a later reconcile.
                    var derived: [AccountID: LogicalMailboxID] = [:]
                    for account in store.directSyncAccounts {
                        derived[account.id] = try? await trust.directInboxMailboxID(
                            imapHost: account.imapHost, email: account.email.rawValue
                        )
                    }
                    return derived
                }
            )
        } catch {
            return DirectNotificationAssembly(notificationDrain: nil, install: nil)
        }
    }

    /// The service's single mail credential resolver and its single
    /// `GoogleAccessTokenProvider`. The Google Desktop client comes from the
    /// packaged bundle; without it Google OAuth accounts fail with
    /// `oauthNotConfigured` while password accounts are unaffected.
    static func makeMailCredentials(
        store: SQLiteMailStore,
        vault: any CredentialVault,
        bundle: Bundle,
        http: any GoogleOAuthHTTP = URLSessionGoogleOAuthHTTP()
    ) -> (resolver: MailCredentialResolver, googleOAuthTokens: GoogleOAuthTokenClient?) {
        let tokens = GoogleOAuthDesktopClient.resolve(from: bundle).map {
            GoogleOAuthTokenClient(client: $0, http: http)
        }
        let provider = GoogleAccessTokenProvider(store: store, credentials: vault, tokens: tokens)
        return (MailCredentialResolver(store: store, credentials: vault, googleTokens: provider), tokens)
    }

    /// The service-owned Node session broker. It reads the account session,
    /// device identity, trust state and endpoint records from the shared
    /// group the app writes, and never creates an identity.
    static func makeNodeSessionBroker() -> NodeSessionBroker {
        let group = PlainpostAccountSharedKeychain.accessGroup
        let credentials = AccountCredentialStore(accessGroup: group)
        let configurationStore = KeychainCentralServerConfigurationStore(
            secretStore: KeychainAccountSecretStore(),
            accessGroup: group
        )
        guard let endpointStore = try? SyncNodeEndpointStore(accessGroup: group) else {
            return NodeSessionBroker(
                resolveSender: { throw NodeSessionBrokerError.unavailable },
                identityReadiness: { .noSession }
            )
        }
        return NodeSessionBroker.production(
            credentials: credentials,
            configurationStore: configurationStore,
            endpointStore: endpointStore
        )
    }

    /// The Node mirror over the one broker the listener also uses, so every
    /// Node request of the service shares one session lane. It runs for the
    /// service's lifetime, whether or not the app is open.
    static func makeNodeMailMirror(store: SQLiteMailStore, broker: NodeSessionBroker) -> NodeMailMirrorLoop {
        NodeMailMirrorLoop(store: store, broker: broker) { nodeID, client in
            NodeMailMirror(store: store, client: client, nodeID: nodeID)
        }
    }

    /// The reachability supervisor over the service's one broker, router
    /// and mirror loop. It dispatches only while the service runtime is open
    /// (vault unlocked), an `unauthorized` Node answer invalidates the
    /// broker's session, the broker's lane activity keeps a busy Node from
    /// looking down, and each tick reconciles routed approved sends.
    static func makeNodeReachabilitySupervisor(
        store: SQLiteMailStore,
        broker: NodeSessionBroker,
        router: MailIntentRouter,
        mirrorLoop: NodeMailMirrorLoop,
        operations: PlainpostServiceOperations
    ) -> NodeReachabilitySupervisor {
        NodeReachabilitySupervisor(
            store: store,
            sessionFactory: { try await broker.client() },
            router: router,
            mirrorLoop: mirrorLoop,
            invalidateSession: { await broker.invalidate() },
            mayDispatch: { await operations.runtimeIsOpen },
            laneActivity: { [activity = broker.activity] in activity.snapshot() },
            // Approved sends routed through the journal: move their send
            // requests once the intent settles.
            afterTick: { [reconciler = ServiceApprovedSendReconciler(store: store, router: router)] in
                await reconciler.sweep()
            },
            // Read locally, so a change made while the session is read-only
            // is refused even while the Node is unreachable.
            sessionAdmission: { broker.currentAdmissionHint() }
        )
    }

    /// The service's mail-intent router, built without a session provider
    /// (every Node-mode dispatch waits until one is attached). Service start
    /// first moves `dispatching(node)` intents left by an earlier process to
    /// `uncertain`; if that write fails the router retries it before its
    /// first dispatch.
    static func makeMailIntentRouter(
        store: SQLiteMailStore,
        direct: ServiceDirectMailDispatcher,
        processStartedAt: Date = Date()
    ) -> MailIntentRouter {
        let recovered = (try? store.recoverInterruptedMailIntentDispatches(
            dispatchedBefore: processStartedAt, now: Date()
        )) != nil
        return MailIntentRouter(
            store: store, direct: direct,
            processStartedAt: processStartedAt, recoveredInterruptedDispatches: recovered,
            directDispatchAllowed: { await direct.runtimeIsOpen() }
        )
    }

    /// App XPC access to the broker (app-caller rules, typed failures) and
    /// to the supervisor's mail-mode status.
    static func nodeSessionHandlers(
        broker: NodeSessionBroker,
        reachability: NodeReachabilitySupervisor? = nil
    ) -> PlainpostNodeSessionHandlers {
        var mailModeStatus: (@Sendable () async -> PlainpostNodeMailModeStatus)?
        if let reachability {
            mailModeStatus = { await reachability.mailModeStatus() }
        }
        return PlainpostNodeSessionHandlers(
            perform: { request in
                do {
                    return try await broker.proxy(request, caller: .app)
                } catch {
                    throw PlainpostServiceClientError.nodeSession(NodeSessionBroker.failure(for: error))
                }
            },
            invalidate: { await broker.invalidate() },
            identityReadiness: { await broker.identityReadiness() },
            mailModeStatus: mailModeStatus
        )
    }

    static func production(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> PlainpostServiceComposition {
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try SQLiteMailStore(path: databaseURL.path)
        try store.migrate()

        let provider = MacVaultKeyProvider()
        let assembly = SQLiteCredentialVaultAssembly(
            store: store,
            provider: provider
        )
        let directNotificationAssembly = Self.makeProductionDirectNotificationAssembly(
            store: store,
            databaseURL: databaseURL
        )
        let mailCredentials = Self.makeMailCredentials(store: store, vault: assembly.vault, bundle: .main)
        let directMailDispatcher = ServiceDirectMailDispatcher()
        let mailIntentRouter = Self.makeMailIntentRouter(store: store, direct: directMailDispatcher)
        let operations = PlainpostServiceOperations(
            applicationSupportURL: databaseURL.deletingLastPathComponent(),
            store: store,
            assembly: assembly,
            notificationDrain: directNotificationAssembly.notificationDrain,
            installNotificationConfiguration: directNotificationAssembly.install,
            credentialResolver: mailCredentials.resolver,
            googleOAuthTokens: mailCredentials.googleOAuthTokens,
            mailIntentRouter: mailIntentRouter
        )
        directMailDispatcher.bind(operations)
        let lifecycle = PlainpostServiceLifecycleCoordinator(
            vaultSession: assembly.session,
            prepareForegroundUnlock: {
                try await assembly.prepareForegroundUnlock()
            },
            archiveCredentialsAfterKeyLoss: {
                try await assembly.archiveRecordsAfterKeyLoss()
            },
            beginVaultLockdown: {
                await operations.beginVaultLockdown()
            },
            confirmVaultLocked: {
                await operations.confirmVaultLocked()
            },
            recoverAfterUnlock: {
                try await assembly.recoverPendingAccountDeletions()
            },
            reopenRuntimeConstruction: {
                await operations.reopenRuntimeConstruction()
            }
        )
        let nodeSessionBroker = Self.makeNodeSessionBroker()
        let nodeMailMirror = Self.makeNodeMailMirror(store: store, broker: nodeSessionBroker)
        let nodeReachability = Self.makeNodeReachabilitySupervisor(
            store: store,
            broker: nodeSessionBroker,
            router: mailIntentRouter,
            mirrorLoop: nodeMailMirror,
            operations: operations
        )
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: lifecycle,
            performForegroundOperation: { operation in
                try await operations.perform(operation)
            },
            processBackgroundJobs: {
                try await operations.processBackgroundJobs()
            },
            performSmartInboxBatch: { request in
                try await operations.performSmartInboxBatch(request)
            },
            sendBrowserApprovedReply: { jobID in
                try await operations.sendBrowserApprovedReply(jobID: jobID)
            },
            syncDraftToServer: { draftID, mailbox in
                try await operations.syncDraftToServer(
                    draftID: draftID,
                    mailbox: mailbox
                )
            },
            nodeSession: Self.nodeSessionHandlers(broker: nodeSessionBroker, reachability: nodeReachability)
        )
        return PlainpostServiceComposition(
            listener: listener, lifecycle: lifecycle, operations: operations, store: store,
            nodeMailMirror: nodeMailMirror,
            mailIntentRouter: mailIntentRouter,
            nodeReachability: nodeReachability
        )
    }
}

public struct DirectNotificationPolicyReconciliation: Sendable, Equatable {
    public let assignment: NotificationProducerAssignment
    public let policy: DirectNotificationPolicyReconciliationValue

    public init(assignment: NotificationProducerAssignment, policy: DirectNotificationPolicyReconciliationValue) {
        self.assignment = assignment
        self.policy = policy
    }
}

/// Installs only authenticated Mac assignments into the local outbox
/// projection. Central supplies opaque mailbox IDs and policy coordinates;
/// this layer is the only place that joins them to provider-local paths.
struct DirectNotificationConfigurationInstaller {
    @discardableResult
    static func reconcile(
        store: SQLiteMailStore,
        plainpostAccountID: PlainpostAccountID,
        producerDeviceID: AccountDeviceID,
        fetchAssignments: @escaping @Sendable () async throws -> [NotificationProducerAssignment],
        fetchSnapshot: @escaping @Sendable () async throws -> DirectNotificationPolicySnapshot,
        currentIdentity: @escaping @Sendable () throws -> (PlainpostAccountID, AccountDeviceID)?,
        derivedInboxMailboxIDs: @escaping @Sendable () async -> [AccountID: LogicalMailboxID] = { [:] }
    ) async -> Bool {
        do {
            guard let initialIdentity = try currentIdentity(),
                  initialIdentity.0 == plainpostAccountID,
                  initialIdentity.1 == producerDeviceID else { return false }
            guard let assignmentsA = try? await fetchAssignments(),
                  let snapshot = try? await fetchSnapshot(),
                  let assignmentsB = try? await fetchAssignments(),
                  assignmentsHaveStableIdentity(assignmentsA, assignmentsB),
                  let finalIdentity = try currentIdentity(),
                  finalIdentity == initialIdentity else { return false }
            let reconciliations = reconciliations(
                assignments: assignmentsA, snapshot: snapshot,
                producerDeviceID: producerDeviceID
            )
            let candidates = assignmentsA.filter {
                $0.producerDeviceID == producerDeviceID && $0.kind == .mac &&
                $0.logicalMailboxID.count == 32 && $0.logicalMailboxID.contains(where: { $0 != 0 })
            }
            let retainedLogicalMailboxIDs = Set(candidates.compactMap {
                LogicalMailboxID(rawValue: $0.logicalMailboxID)
            })
            guard candidates.count == reconciliations.count else {
                // A decoded authoritative snapshot that cannot be joined to
                // every candidate is unsafe: revoke all prior Mac eligibility
                // before returning the retryable failure.
                _ = try store.revokeNotificationProducerConfigurations(
                    plainpostAccountID: plainpostAccountID,
                    producerDeviceID: producerDeviceID,
                    retainedLogicalMailboxIDs: []
                )
                return false
            }
            // Assignment removal and producer rotation are authoritative
            // too. Revoke absent/nonmatching rows before any sync can publish.
            _ = try store.revokeNotificationProducerConfigurations(
                plainpostAccountID: plainpostAccountID,
                producerDeviceID: producerDeviceID,
                retainedLogicalMailboxIDs: retainedLogicalMailboxIDs
            )
            return try install(
                store: store, plainpostAccountID: plainpostAccountID,
                producerDeviceID: producerDeviceID, reconciliations: reconciliations,
                derivedInboxMailboxIDs: await derivedInboxMailboxIDs()
            )
        } catch {
            return false
        }
    }

    @discardableResult
    static func install(
        store: SQLiteMailStore,
        plainpostAccountID: PlainpostAccountID,
        producerDeviceID: AccountDeviceID,
        reconciliations: [DirectNotificationPolicyReconciliation],
        derivedInboxMailboxIDs: [AccountID: LogicalMailboxID] = [:]
    ) throws -> Bool {
        let selected = reconciliations.filter {
            $0.assignment.producerDeviceID == producerDeviceID &&
            $0.assignment.kind == .mac &&
            $0.assignment.logicalMailboxID.count == 32 &&
            $0.assignment.logicalMailboxID.contains(where: { $0 != 0 }) &&
            $0.policy.logicalMailboxID.rawValue == $0.assignment.logicalMailboxID &&
            $0.policy.effectiveVersion > 0 && $0.policy.effectiveVersion <= Int64(UInt16.max) &&
            $0.policy.scopeVersion >= 0 && $0.policy.scopeVersion <= Int64(UInt16.max)
        }
        guard !selected.isEmpty else { return false }

        // Central assigns by logical mailbox, not by the local IMAP account
        // identifier or path. Reconcile every local path whose durable
        // configuration already contains that logical ID; never infer a
        // Plainpost account UUID from the provider's local AccountID.
        let localAccounts = store.accounts
        var matched = 0
        for account in localAccounts {
            for path in try store.mailboxPaths(accountID: account.id) {
                guard let existing = try store.notificationProducerConfigurationForReconciliation(
                    accountID: account.id, mailboxPath: path
                ), existing.plainpostAccountID == plainpostAccountID,
                   let assignment = selected.first(where: {
                       $0.assignment.logicalMailboxID == existing.logicalMailboxIDBytes
                   }) else { continue }
                let result = try persist(
                    store: store, accountID: account.id, mailboxPath: path,
                    producerDeviceID: producerDeviceID, reconciliation: assignment,
                    existing: existing
                )
                if result { matched += 1 }
            }
        }

        // A Direct account's Inbox is named by the mailbox every trusted device derives
        // for it (`AccountTrustCoordinator.directInboxMailboxID`), so each account Central
        // assigned to this Mac binds without a Sync Node, however many accounts it has.
        for account in localAccounts {
            guard let derived = derivedInboxMailboxIDs[account.id],
                  let assignment = selected.first(where: {
                      $0.assignment.logicalMailboxID == derived.rawValue
                  }) else { continue }
            if let existing = try store.notificationProducerConfigurationForReconciliation(
                accountID: account.id, mailboxPath: "INBOX"
            ), existing.plainpostAccountID == plainpostAccountID,
               existing.logicalMailboxIDBytes == derived.rawValue {
                continue // Reconciled with the bindings above.
            }
            let configuration = try makeConfiguration(
                plainpostAccountID: plainpostAccountID,
                logicalMailboxID: derived,
                producerDeviceID: producerDeviceID,
                assignment: assignment.assignment,
                policy: assignment.policy
            )
            let result = try store.reconcileNotificationProducerConfiguration(
                accountID: account.id, mailboxPath: "INBOX", configuration: configuration
            )
            if result == .applied || result == .idempotent { matched += 1 }
        }

        // Initial pairing has no local logical-mailbox row yet. The Inbox is
        // the only safe bootstrap path; subsequent syncs preserve and expand
        // the path-to-logical-ID bindings above.
        if matched == 0, derivedInboxMailboxIDs.isEmpty, localAccounts.count == 1,
                  let accountID = localAccounts.first?.id,
                  selected.count == 1,
                  let assignment = selected.first {
            guard let logicalMailboxID = LogicalMailboxID(rawValue: assignment.assignment.logicalMailboxID) else {
                return false
            }
            let configuration = try makeConfiguration(
                plainpostAccountID: plainpostAccountID,
                logicalMailboxID: logicalMailboxID,
                producerDeviceID: producerDeviceID,
                assignment: assignment.assignment,
                    policy: assignment.policy
            )
            let result = try store.reconcileNotificationProducerConfiguration(
                accountID: accountID, mailboxPath: "INBOX", configuration: configuration
            )
            matched = result == .applied || result == .idempotent ? 1 : 0
        }
        return matched > 0
    }

    static func reconciliations(
        assignments: [NotificationProducerAssignment],
        snapshot: DirectNotificationPolicySnapshot,
        producerDeviceID: AccountDeviceID
    ) -> [DirectNotificationPolicyReconciliation] {
        let candidates = assignments.filter {
            $0.producerDeviceID == producerDeviceID &&
            $0.kind == .mac &&
            $0.logicalMailboxID.count == 32 &&
            $0.logicalMailboxID.contains(where: { $0 != 0 })
        }
        guard Set(candidates.map(\.logicalMailboxID)).count == candidates.count else {
            return []
        }
        let reconciliations: [DirectNotificationPolicyReconciliation] = candidates.compactMap { assignment in
            guard let mailbox = LogicalMailboxID(rawValue: assignment.logicalMailboxID) else { return nil }
            let states = snapshot.mailboxStates.filter { $0.logicalMailboxID == mailbox }
            guard states.count == 1, let state = states.first,
                  let effectiveVersion = Int64(state.override ? state.version : snapshot.defaultPolicy.version),
                  let scopeVersion = Int64(state.scopeVersion),
                  let policy = try? DirectNotificationPolicyReconciliationValue(
                      logicalMailboxID: mailbox,
                      mode: state.override ? state.mode : snapshot.defaultPolicy.mode,
                      effectiveVersion: effectiveVersion,
                      scopeVersion: scopeVersion,
                      override: state.override
                  ) else { return nil }
            return DirectNotificationPolicyReconciliation(assignment: assignment, policy: policy)
        }
        return reconciliations.count == candidates.count ? reconciliations : []
    }

    private static func persist(
        store: SQLiteMailStore,
        accountID: AccountID,
        mailboxPath: String,
        producerDeviceID: AccountDeviceID,
        reconciliation: DirectNotificationPolicyReconciliation,
        existing: NotificationProducerConfiguration
    ) throws -> Bool {
        let assignment = reconciliation.assignment
        guard let plainpostAccountID = existing.plainpostAccountID,
              let logicalMailboxID = LogicalMailboxID(rawValue: assignment.logicalMailboxID) else {
            throw PlainpostError.validationFailed("Notification producer configuration is not authoritative.")
        }
        let configuration = try makeConfiguration(
            plainpostAccountID: plainpostAccountID,
            logicalMailboxID: logicalMailboxID,
            producerDeviceID: producerDeviceID,
            assignment: assignment,
            policy: reconciliation.policy
        )
        let result = try store.reconcileNotificationProducerConfiguration(
            accountID: accountID, mailboxPath: mailboxPath, configuration: configuration
        )
        return result == .applied || result == .idempotent
    }

    private static func makeConfiguration(
        plainpostAccountID: PlainpostAccountID,
        logicalMailboxID: LogicalMailboxID,
        producerDeviceID: AccountDeviceID,
        assignment: NotificationProducerAssignment,
        policy: DirectNotificationPolicyReconciliationValue
    ) throws -> NotificationProducerConfiguration {
        guard assignment.generation <= UInt64(Int64.max),
              assignment.trustRevision <= UInt64(Int64.max) else {
            throw PlainpostError.validationFailed("Notification producer assignment is out of range.")
        }
        guard policy.logicalMailboxID == logicalMailboxID,
              policy.effectiveVersion > 0,
              policy.scopeVersion >= 0 else {
            throw PlainpostError.validationFailed("Notification policy is not authoritative.")
        }
        let policyMode = policy.mode.rawValue
        let identity = [
            assignment.trustEpoch.description, assignment.trustRevision.description,
            assignment.generation.description, assignment.trustHead.base64EncodedString(),
            assignment.producerSigningPublicKey?.base64EncodedString() ?? "none",
            policy.scopeVersion.description, policy.effectiveVersion.description, policyMode,
            policy.override.description
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let producerIdentity = [
            assignment.trustEpoch.description, assignment.trustRevision.description,
            assignment.trustHead.base64EncodedString(),
            assignment.producerSigningPublicKey?.base64EncodedString() ?? "none"
        ].joined(separator: "|")
        let producerIdentityDigest = SHA256.hash(data: Data(producerIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return NotificationProducerConfiguration(
            plainpostAccountID: plainpostAccountID,
            logicalMailboxID: logicalMailboxID,
            producerDeviceID: producerDeviceID,
            producerKind: "mac",
            policyMode: policyMode,
            policyVersion: policy.effectiveVersion,
            configRevision: Int64(assignment.trustRevision),
            producerGeneration: Int64(assignment.generation),
            configVersion: "direct-\(digest)",
            producerIdentityDigest: producerIdentityDigest,
            policyOverride: policy.override,
            directPolicyScopeVersion: policy.scopeVersion
        )
    }
}

/// Builds a bounded, deterministic message view at the point a publication
/// is prepared.  The outbox stores only the resulting envelope bytes, so a
/// retry never re-reads or re-encrypts this mutable message state.
private struct SQLiteNotificationSnapshotProvider: Sendable {
    let store: SQLiteMailStore
    let plainpostAccountID: PlainpostAccountID

    func snapshot(
        source: NotificationPublicationSource,
        claim: NotificationPublicationClaim
    ) throws -> NotificationMessageSnapshot {
        guard source.plainpostAccountID.rawValue == plainpostAccountID.rawValue,
              source.logicalMailboxIDBytes.count == 32,
              source.logicalMailboxIDBytes.contains(where: { $0 != 0 }),
              let arrival = source.providerArrivalAt,
              Date().timeIntervalSince(arrival) >= 0,
              Date().timeIntervalSince(arrival) <= 15 * 60,
              claim.policyMode != "off" else {
            throw NotificationRuntimeError.staleAssignment
        }
        guard let message = try store.messageSummary(id: source.messageID),
              !message.isDeleted,
              store.accountID(forMessageID: source.messageID) == source.accountID else {
            throw NotificationRuntimeError.staleAssignment
        }
        let identities = NotificationOpaqueIdentities.derive(
            mailboxBytes: source.logicalMailboxIDBytes,
            messageID: source.messageID.rawValue,
            threadID: source.threadID?.rawValue ?? message.threadID?.rawValue ?? source.messageID.rawValue
        )
        let displayName = message.fromDisplayName ?? ""
        let senderValue = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? message.from.rawValue : displayName
        let sender = bounded(senderValue, maximumBytes: 160)
        let subject = bounded(message.subject, maximumBytes: 200)
        let preview = bounded(message.preview.isEmpty ? message.body : message.preview, maximumBytes: 240)
        let unreadCount = min(999, max(0, try store.unreadNotificationCount(accountID: source.accountID, mailboxPath: source.mailboxPath)))
        let safeSubject = subject.isEmpty ? "(no subject)" : subject
        let messageDigest = digest(parts: [Data("message.v2".utf8), Data(source.messageID.rawValue.utf8), Data(safeSubject.utf8), Data(preview.utf8)])
        let replayID = digest(parts: [Data("replay.v2".utf8), Data(plainpostAccountID.rawValue.utf8), source.logicalMailboxIDBytes, Data(source.uidValidity.bigEndianBytes), Data(source.uid.bigEndianBytes)])
        let collapseDigest = digest(parts: [Data("collapse.v2".utf8), Data(identities.mailboxToken.utf8), Data(identities.threadToken.utf8)])
        return NotificationMessageSnapshot(
            mailboxToken: identities.mailboxToken,
            threadToken: identities.threadToken,
            messageToken: identities.messageToken,
            sender: sender,
            subject: safeSubject,
            preview: preview,
            badge: UInt16(unreadCount),
            messageDigest: messageDigest,
            replayID: replayID,
            collapseDigest: collapseDigest
        )
    }

    private func bounded(_ value: String, maximumBytes: Int) -> String {
        let lines = value.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        let withoutQuotedHistory = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        let joined = withoutQuotedHistory.joined(separator: " ")
        let scalarText = joined.unicodeScalars
            .filter { $0.value >= 0x20 || $0 == "\t" }
            .map(String.init).joined()
        let cleaned = scalarText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var bounded = ""
        for scalar in cleaned.unicodeScalars {
            let next = String(scalar)
            guard bounded.utf8.count + next.utf8.count <= maximumBytes else { break }
            bounded.append(contentsOf: next)
        }
        return bounded
    }

    private func digest(parts: [Data]) -> Data {
        var input = Data()
        for part in parts {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(part)
        }
        return Data(SHA256.hash(data: input))
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
