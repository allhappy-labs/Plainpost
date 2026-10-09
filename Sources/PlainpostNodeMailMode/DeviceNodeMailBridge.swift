import Foundation
import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport
import PlainpostOperations

/// The iPhone's Sync Node mail: a mirror loop, an intent router and a reachability supervisor
/// over the device's Node session. Each start adds the Node's accounts to the device's
/// catalog, so every Node account is mirrored into the device's database.
///
/// While the Node is away, an account whose provider sign-in is on the phone falls back: the
/// phone syncs it itself and the journal sends its changes to the provider (`direct`). Any
/// other account stays with its Node, its changes waiting in the journal.
public actor DeviceNodeMailBridge: DeviceNodeMailBridging {
    private let store: SQLiteMailStore
    private let broker: NodeSessionBroker
    private let makeLoop: @Sendable () -> NodeMailMirrorLoop
    private let router: MailIntentRouter
    private let routerSessions: ProbedNodeMailSessions
    private let mayFallBack: @Sendable (AccountID) async -> Bool
    private let reachability: NodeReachabilityPolicy
    private var attached = false
    /// The running loop and supervisor. Neither can start again once stopped, so each start
    /// makes new ones.
    private var loop: NodeMailMirrorLoop?
    private var supervisor: NodeReachabilitySupervisor?
    private var lastReachable = true
    /// Node accounts the Node's last catalog no longer listed.
    private var unlisted: Set<AccountID> = []

    /// - Parameters:
    ///   - window: how many of an account's newest messages to mirror; `nil` mirrors its
    ///     whole history.
    ///   - direct: the phone's own route to a fallback account's provider; without one, no
    ///     account falls back.
    ///   - mayFallBack: whether the account's provider sign-in is on the phone.
    public init(
        store: SQLiteMailStore,
        broker: NodeSessionBroker,
        window: @escaping @Sendable (AccountID) -> Int?,
        direct: (any DirectMailDispatching)? = nil,
        mayFallBack: @escaping @Sendable (AccountID) async -> Bool = { _ in false },
        reachability: NodeReachabilityPolicy = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.broker = broker
        makeLoop = {
            NodeMailMirrorLoop(store: store, broker: broker) { nodeID, client in
                NodeMailMirror(store: store, client: client, nodeID: nodeID, now: now, window: window)
            }
        }
        let canDispatchDirectly = direct != nil
        router = MailIntentRouter(
            store: store, direct: direct ?? NoDirectMailOnThisDevice(), now: now, processStartedAt: now(),
            directDispatchAllowed: { canDispatchDirectly }
        )
        routerSessions = ProbedNodeMailSessions(broker: broker)
        let neverFallsBack: @Sendable (AccountID) async -> Bool = { _ in false }
        self.mayFallBack = canDispatchDirectly ? mayFallBack : neverFallsBack
        self.reachability = reachability
    }

    /// The window Direct accounts sync: each account's recent-message limit, or its whole
    /// history once complete history is on.
    public init(
        store: SQLiteMailStore,
        broker: NodeSessionBroker,
        direct: (any DirectMailDispatching)? = nil,
        mayFallBack: @escaping @Sendable (AccountID) async -> Bool = { _ in false }
    ) {
        self.init(store: store, broker: broker, window: { [store] accountID in
            guard let preferences = try? store.syncPreferences(accountID: accountID) else {
                return MailSyncPreferences(accountID: accountID).recentMessageLimit
            }
            return preferences.downloadCompleteHistory ? nil : preferences.recentMessageLimit
        }, direct: direct, mayFallBack: mayFallBack)
    }

    private func attachRouter() async {
        guard !attached else { return }
        attached = true
        await router.attach(sessions: routerSessions)
    }

    public func start() async {
        await attachRouter()
        await addCatalogAccounts()
        if loop == nil {
            let loop = makeLoop()
            self.loop = loop
            await loop.start()
            // The supervisor only moves accounts between their Node and fallback. A change
            // for an account with its Node goes whenever a status check finds the Node
            // answering, not only once the supervisor's windows agree.
            let supervisor = makeSupervisor(mirror: loop)
            self.supervisor = supervisor
            await supervisor.start()
        }
        await dispatchPending()
    }

    public func stop() async {
        guard let loop else { return }
        self.loop = nil
        if let supervisor {
            self.supervisor = nil
            await supervisor.stop()
        }
        lastReachable = await loop.lastOutcome != .failed
        await loop.stop()
    }

    private func makeSupervisor(mirror: NodeMailMirrorLoop) -> NodeReachabilitySupervisor {
        let broker = broker
        return NodeReachabilitySupervisor(
            store: store,
            sessionFactory: { try await broker.client() },
            routing: router,
            mirror: mirror,
            invalidateSession: { await broker.invalidate() },
            mayDispatch: { true },
            laneActivity: { [activity = broker.activity] in activity.snapshot() },
            sessionAdmission: { broker.currentAdmissionHint() },
            mayFallBack: mayFallBack,
            policy: reachability
        )
    }

    public func wake() async {
        await attachRouter()
        await addCatalogAccounts()
        await loop?.wake()
        await dispatchPending()
    }

    public func perform(_ kind: MailIntentKind, messageID: MessageID, folder: String? = nil) async throws -> DeviceNodeMailOutcome {
        await attachRouter()
        let outcome = Self.outcome(try await router.performIntent(kind, messageID: messageID, archiveMailbox: folder).outcome)
        // The Node applied it: mirror the change now rather than at the next tick.
        if outcome == .confirmed { await loop?.wake() }
        return outcome
    }

    public func saveDraft(_ draft: Draft) async throws -> DeviceNodeMailOutcome {
        await attachRouter()
        return Self.outcome(try await router.saveDraft(draft))
    }

    public func send(_ draft: Draft) async throws -> DeviceNodeMailOutcome {
        await attachRouter()
        return Self.outcome(try await router.send(draft))
    }

    /// Reopens the account's mirror snapshot; with complete history on, the window no
    /// longer applies, so the older mail arrives on the next passes.
    public func downloadCompleteHistory(for accountID: AccountID) async throws {
        guard let source = try store.mailSources().first(where: { $0.accountID == accountID }),
              let scope = NodeMirrorScope(source: source) else {
            throw NodeMailModeStoreError.mirrorScopeChanged
        }
        try store.seedNodeMirrorAccount(scope)
        await loop?.wake()
    }

    public func accountStates() async -> [AccountID: DeviceNodeAccountState] {
        let reachable = if let loop { await loop.lastOutcome != .failed } else { lastReachable }
        let state: DeviceNodeAccountState = reachable ? .ready : .unreachable
        var states = Dictionary(uniqueKeysWithValues: nodeAccounts().map { ($0, state) })
        let current = Set(((try? store.mailSources()) ?? []).filter { $0.kind == .nodeBacked }.map(\.accountID))
        for accountID in unlisted where current.contains(accountID) { states[accountID] = .noLongerOnSyncNode }
        return states
    }

    /// Adds the Node's accounts to the device's catalog now, before any mail runtime runs:
    /// a device whose only accounts are on its Sync Node has nothing else to open.
    public func addSyncNodeAccounts() async {
        await addCatalogAccounts()
    }

    /// Adds each account the Node serves to the device's catalog, once: the Plainpost
    /// Account path's accounts, which the device knew only through the Node, become
    /// accounts like any other. A Node that can't be reached adds nothing now.
    private func addCatalogAccounts() async {
        guard let session = try? await broker.client(),
              let catalog = try? await NodeMailAccountCatalog.load(session.client) else { return }
        for mailAccount in catalog.accounts {
            guard let logical = try? NodeSyncCodec.encodeLogicalMailboxID(mailAccount.logicalMailboxID) else { continue }
            let email = EmailAddress(mailAccount.providerIdentity)
            let gmail = mailAccount.providerKind == "gmail"
            let account = Account(
                id: AccountID.stableAccountID(email: email),
                displayName: mailAccount.providerIdentity, email: email,
                imapHost: gmail ? MailProviderProfile.gmail.imapHost : "",
                smtpHost: gmail ? MailProviderProfile.gmail.smtpHost : ""
            )
            let source = AccountMailSource.direct(account.id).nodeBacked(
                nodeID: session.nodeID, logicalMailboxID: logical, providerIdentity: mailAccount.providerIdentity
            )
            // An address already used by another account keeps that account as it is.
            _ = try? store.createNodeBackedAccount(account, source: source)
        }
        // An account of this Node the catalog no longer lists says so; it stays until the
        // user removes it, so nothing waiting on it (a draft, a change) goes silently.
        let listed = Set(catalog.accounts.compactMap { try? NodeSyncCodec.encodeLogicalMailboxID($0.logicalMailboxID) })
        unlisted = Set(((try? store.mailSources()) ?? []).filter {
            $0.kind == .nodeBacked && $0.nodeID?.lowercased() == session.nodeID.lowercased()
                && !listed.contains($0.logicalMailboxID ?? "")
        }.map(\.accountID))
        // The account's folders come from its mirrored mail's folders. Rows an earlier
        // build made from the catalog's mailbox handles (which are not folder paths) go.
        try? store.removeLegacyNodeHandleMailboxes()
    }

    private func nodeAccounts() -> [AccountID] {
        ((try? store.mailSources()) ?? []).filter { $0.kind == .nodeBacked && $0.mode == .node }.map(\.accountID)
    }

    /// Every Node account's waiting changes: to the Node, or for an account in fallback, to
    /// its provider.
    private func dispatchPending() async {
        for source in (try? store.mailSources()) ?? [] where source.kind == .nodeBacked {
            await router.dispatchPending(accountID: source.accountID)
        }
    }

    static func outcome(_ outcome: MailIntentDispatchOutcome) -> DeviceNodeMailOutcome {
        switch outcome {
        case .confirmed: .confirmed
        case .waitingForNode: .waitingForNode
        case .uncertain: .uncertain
        case let .failed(message): .failed(message)
        }
    }
}

/// A bridge built without the phone's direct route: the router never calls this while
/// direct dispatch is not allowed.
private struct NoDirectMailOnThisDevice: DirectMailDispatching {
    private static let refusal = DirectMailDispatchRefusal(message: "This account syncs through your Sync Node.")
    func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws { throw Self.refusal }
    func saveDraft(_ draft: Draft) async throws { throw Self.refusal }
    func send(_ draft: Draft, approvedContentHash: String) async throws { throw Self.refusal }
}

/// The broker's client for the Node, offered only after the Node answers a
/// status check, so a change made while the Node is away waits in the
/// journal instead of leaving with no answer.
struct ProbedNodeMailSessions: NodeMailSessionProviding {
    let broker: NodeSessionBroker

    func reachableClient(nodeID: String) async -> NodeSyncClient? {
        guard let session = try? await broker.client(), session.nodeID.lowercased() == nodeID.lowercased(),
              (try? await session.client.status()) != nil
        else { return nil }
        return session.client
    }

    func sessionAdmission(nodeID: String) async -> NodeSessionAdmission? {
        broker.currentAdmissionHint()
    }
}
