import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport
import PlainpostServiceIPC
import os

private let reachabilityLogger = Logger(subsystem: "com.marynavdovenko.Plainpost", category: "node-reachability")

/// Opens (or reuses) the service's Node session. Production: `broker.client()`.
public typealias NodeMailSessionFactory = @Sendable () async throws -> (nodeID: String, client: NodeSyncClient)

/// The router passes the supervisor drives. `MailIntentRouter` is the
/// production conformer; tests wrap it to record the order of calls.
protocol NodeReachabilityIntentRouting: Sendable {
    func rerouteUnstartedDirectIntents(accountID: AccountID) async throws -> Int
    func settleAdmittedIntents(accountID: AccountID) async
    func dispatchPending(accountID: AccountID) async
}

extension MailIntentRouter: NodeReachabilityIntentRouting {}

/// The loop that owns the mirror. The supervisor only wakes it; it never
/// owns or runs a `NodeMailMirror`.
protocol NodeMailMirrorWaking: Sendable {
    func wake() async
}

extension NodeMailMirrorLoop: NodeMailMirrorWaking {}

/// Service-lifetime owner of Node reachability for Node-backed accounts.
///
/// Every `probeInterval` it probes the Node (`status()` over the broker's
/// session, bounded by `probeTimeout`; probes never overlap) and feeds the
/// result to `NodeReachabilityHysteresis`. The accounts' persisted mode
/// follows the hysteresis:
///
/// - **Enter fallback** (sustained unhealthy): every Node-backed account in
///   `node` mode moves to `fallback` (`replaceMailSource` posts `.accounts`,
///   so the service starts IDLE and scheduled direct sync, and the mirror
///   pauses). Then `dispatchPending` sends queued intents directly; admitted,
///   uncertain and in-flight Node intents stay guarded.
/// - **Reconnect** (sustained healthy, after the dwell time): in order, each
///   fallback account of the reachable Node moves back to `node` (direct sync
///   stops), unstarted intents are listed for rerouting, admitted/uncertain
///   intents are settled and pending ones dispatched through the Node, then
///   the loop-owned mirror is woken (it re-seeds accounts that were out of
///   node mode). Fallback changes already reached the provider; nothing is
///   replayed to the Node.
///
/// The transitions are reconciled on every tick, so a write that failed (a
/// busy store, a generation race) is retried, and a restart resumes the
/// persisted mode. Intents are dispatched only while `mayDispatch()` (the
/// service runtime is open: the vault is unlocked); while pending rows exist
/// they are re-drained every tick, so rows skipped because another caller held
/// them are never stranded. An `unauthorized` answer invalidates the session
/// once and reports `.reconnectRequired`.
public actor NodeReachabilitySupervisor: NodeMailSessionProviding {
    public enum Status: Equatable, Sendable { case noNode, connected, connectedDirectly, updateRequired, reconnectRequired }

    enum ProbeOutcome: Equatable, Sendable {
        /// `compatibilityConfirmed`: this probe read the Node's mail-mode
        /// capabilities (the only thing that records compatibility).
        case healthy(nodeID: String, compatibilityConfirmed: Bool)
        case unhealthy
        /// No answer within `probeTimeout`.
        case timedOut
        case unauthorized
        case updateRequired
    }

    private enum RunState { case idle, running, stopped }

    private let store: SQLiteMailStore
    private let sessionFactory: NodeMailSessionFactory
    private let router: any NodeReachabilityIntentRouting
    private let mirrorLoop: any NodeMailMirrorWaking
    private let invalidateSession: @Sendable () async -> Void
    private let mayDispatch: @Sendable () async -> Bool
    private let laneActivity: @Sendable () -> NodeLaneActivitySnapshot?
    private let sessionAdmissionCheck: @Sendable () -> NodeSessionAdmission?
    private let afterTick: @Sendable () async -> Void
    private let policy: NodeReachabilityPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let elapsed: @Sendable () -> Duration
    private let anchor = ContinuousClock.now

    private var runState = RunState.idle
    private var loop: Task<Void, Never>?
    /// One hysteresis per Node the accounts are bound to: accounts bound to
    /// a Node other than the session's are unhealthy on their own, and never
    /// move the others.
    private var hysteresis: [String: NodeReachabilityHysteresis] = [:]
    /// The Node the last probe reached, while it was healthy.
    private var reachableNodeID: String?
    /// Whether the account may sync directly while its Node is away: on the iPhone, only
    /// once its provider sign-in is on the phone. The Mac always may.
    private let mayFallBack: @Sendable (AccountID) async -> Bool
    /// The Node the session last answered for (healthy or not since).
    private var sessionNodeID: String?
    private var compatibleNodeID: String?
    private var unauthorized = false
    private var needsUpdate = false
    private var nodeBackedAccountCount = 0
    private var lastSettle: Duration?
    private var probeInFlight: Task<ProbeOutcome, Never>?
    private var probeTimer: Task<Void, Never>?
    private var published: Status = .noNode
    private var subscribers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private(set) var completedCycles = 0
    private(set) var isCycling = false
    /// Tests: the cycle is waiting for a probe answer or its timeout.
    private(set) var isAwaitingProbe = false

    /// Construction order (breaks the router ↔ supervisor cycle): the
    /// composition builds the router without a session provider, builds the
    /// supervisor with it, calls `router.attach(sessions: supervisor)`, then
    /// `start()`.
    public init(
        store: SQLiteMailStore,
        sessionFactory: @escaping NodeMailSessionFactory,
        router: MailIntentRouter,
        mirrorLoop: NodeMailMirrorLoop,
        invalidateSession: @escaping @Sendable () async -> Void,
        mayDispatch: @escaping @Sendable () async -> Bool,
        laneActivity: @escaping @Sendable () -> NodeLaneActivitySnapshot? = { nil },
        afterTick: @escaping @Sendable () async -> Void = {},
        sessionAdmission: @escaping @Sendable () -> NodeSessionAdmission? = { nil },
        mayFallBack: @escaping @Sendable (AccountID) async -> Bool = { _ in true },
        policy: NodeReachabilityPolicy = .production,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            store: store, sessionFactory: sessionFactory, routing: router, mirror: mirrorLoop,
            invalidateSession: invalidateSession, mayDispatch: mayDispatch, laneActivity: laneActivity,
            afterTick: afterTick, sessionAdmission: sessionAdmission, mayFallBack: mayFallBack,
            policy: policy, clock: clock
        )
    }

    init(
        store: SQLiteMailStore,
        sessionFactory: @escaping NodeMailSessionFactory,
        routing: any NodeReachabilityIntentRouting,
        mirror: any NodeMailMirrorWaking,
        invalidateSession: @escaping @Sendable () async -> Void,
        mayDispatch: @escaping @Sendable () async -> Bool,
        laneActivity: @escaping @Sendable () -> NodeLaneActivitySnapshot? = { nil },
        afterTick: @escaping @Sendable () async -> Void = {},
        sessionAdmission: @escaping @Sendable () -> NodeSessionAdmission? = { nil },
        mayFallBack: @escaping @Sendable (AccountID) async -> Bool = { _ in true },
        policy: NodeReachabilityPolicy = .production,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionAdmissionCheck = sessionAdmission
        self.mayFallBack = mayFallBack
        self.laneActivity = laneActivity
        self.afterTick = afterTick
        self.store = store
        self.sessionFactory = sessionFactory
        self.router = routing
        self.mirrorLoop = mirror
        self.invalidateSession = invalidateSession
        self.mayDispatch = mayDispatch
        self.policy = policy
        let bound = Self.bind(clock)
        self.sleep = bound.sleep
        self.elapsed = bound.elapsed
    }

    private static func bind<C: Clock>(_ clock: C) -> (
        sleep: @Sendable (Duration) async throws -> Void, elapsed: @Sendable () -> Duration
    ) where C.Duration == Duration {
        let start = clock.now
        return ({ try await clock.sleep(until: clock.now.advanced(by: $0), tolerance: nil) }, { start.duration(to: clock.now) })
    }

    // MARK: - Lifecycle

    public func start() async {
        guard runState == .idle else { return }
        runState = .running
        loop = Task { [weak self] in await self?.run() }
    }

    /// Cancels the probe loop, any probe in flight and any pending mirror
    /// wake. Transitions already written stay persisted.
    public func stop() async {
        guard runState == .running else {
            runState = .stopped
            return
        }
        runState = .stopped
        let running = loop
        loop = nil
        running?.cancel()
        probeInFlight?.cancel()
        probeTimer?.cancel()
        await running?.value
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    public var status: Status { published }

    public func statusUpdates() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.yield(published)
        guard runState != .stopped else {
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// The XPC status: a closed state and two counts.
    public func mailModeStatus() -> PlainpostNodeMailModeStatus {
        PlainpostNodeMailModeStatus(
            state: Self.wireState(published),
            nodeBackedAccountCount: nodeBackedAccountCount,
            waitingIntentCount: waitingIntentCount()
        )
    }

    static func wireState(_ status: Status) -> PlainpostNodeMailModeStatus.State {
        switch status {
        case .noNode: .noNode
        case .connected: .connected
        case .connectedDirectly: .connectedDirectly
        case .updateRequired: .updateRequired
        case .reconnectRequired: .reconnectRequired
        }
    }

    // MARK: - NodeMailSessionProviding

    /// A client for `nodeID` only while the accounts follow the Node and its
    /// last probe was healthy; nil makes the router keep the intent pending.
    /// The broker's local session check: read without the Node, so the
    /// router can refuse a change made while read-only even when the Node
    /// is unreachable.
    public func sessionAdmission(nodeID: String) async -> NodeSessionAdmission? {
        sessionAdmissionCheck()
    }

    public func reachableClient(nodeID: String) async -> NodeSyncClient? {
        guard runState == .running,
              hysteresis[nodeID.lowercased()]?.mode == .node,
              let reachable = reachableNodeID,
              reachable == nodeID.lowercased(),
              let session = try? await sessionFactory(),
              session.nodeID.lowercased() == reachable
        else { return nil }
        return session.client
    }

    // MARK: - Loop

    /// Each probe is scheduled `probeInterval` after the previous one
    /// started, so a slow probe or drain does not stretch the windows.
    private func run() async {
        while runState == .running, !Task.isCancelled {
            let started = elapsed()
            isCycling = true
            await cycle()
            completedCycles += 1
            isCycling = false
            guard runState == .running, !Task.isCancelled else { return }
            let remaining = policy.probeInterval - (elapsed() - started)
            if remaining > .zero {
                do { try await sleep(remaining) } catch { return }
            } else {
                await Task.yield()
            }
        }
    }

    private func now() -> ContinuousClock.Instant { anchor.advanced(by: elapsed()) }

    func cycle() async {
        let sources: [AccountMailSource]
        do {
            sources = try store.mailSources()
        } catch {
            // A read error is not "no Node-backed account": try again next tick.
            reachabilityLogger.error("Reachability tick skipped: the account mail sources could not be read.")
            return
        }
        let nodeBacked = sources.filter { $0.kind == .nodeBacked && $0.nodeID != nil }
        nodeBackedAccountCount = nodeBacked.count
        guard !nodeBacked.isEmpty else {
            // No Node-backed account: no Node traffic, nothing to supervise.
            hysteresis = [:]
            reachableNodeID = nil
            unauthorized = false
            needsUpdate = false
            publish(.noNode)
            await afterTick()
            return
        }
        let groups = Dictionary(grouping: nodeBacked) { $0.nodeID ?? "" }
        hysteresis = hysteresis.filter { groups[$0.key] != nil }
        for (nodeID, accounts) in groups where hysteresis[nodeID] == nil {
            // Restart (or a newly bound Node): resume the persisted mode.
            let mode: NodeBackedMode = accounts.contains { $0.mode == .fallback } ? .fallback : .node
            hysteresis[nodeID] = NodeReachabilityHysteresis(policy: policy, mode: mode)
        }

        let outcome = await probe()
        guard runState == .running, !Task.isCancelled else { return }
        var healthyNodeID: String?
        var inconclusive = false
        switch outcome {
        case .healthy(let nodeID, _):
            unauthorized = false
            needsUpdate = false
            sessionNodeID = nodeID
            healthyNodeID = nodeID
        case .unhealthy, .timedOut:
            let activity = laneActivity()
            if let since = activity?.sinceLastResponse, since < policy.probeInterval, let sessionNodeID {
                // The lane answered other requests within the interval: the
                // Node is busy (a re-snapshot), not down.
                healthyNodeID = sessionNodeID
            } else if outcome == .timedOut, let held = activity?.laneHeldFor, held < policy.probeTimeout {
                // The probe waited for the lane most of its window: it never
                // had its full timeout on the wire. No observation this tick.
                inconclusive = true
            }
        case .updateRequired:
            unauthorized = false
            needsUpdate = true
        case .unauthorized:
            needsUpdate = false
            if !unauthorized {
                unauthorized = true
                compatibleNodeID = nil
                await invalidateSession()
            }
        }
        reachableNodeID = healthyNodeID.flatMap { groups[$0] == nil ? nil : $0 }
        if !inconclusive {
            let instant = now()
            for nodeID in groups.keys {
                _ = hysteresis[nodeID]?.observe(healthy: nodeID == reachableNodeID, at: instant)
            }
        }
        await reconcile(groups: groups)
        guard runState == .running, !Task.isCancelled else { return }
        await afterTick()
        publishCurrent()
    }

    private func publishCurrent() {
        if unauthorized { return publish(.reconnectRequired) }
        if needsUpdate { return publish(.updateRequired) }
        publish(hysteresis.values.contains { $0.mode == .fallback } ? .connectedDirectly : .connected)
    }

    private func publish(_ status: Status) {
        guard status != published else { return }
        published = status
        for continuation in subscribers.values { continuation.yield(status) }
    }

    // MARK: - Probe

    /// One probe at a time: while an earlier probe is still running (it
    /// timed out but has not returned) this tick counts as unhealthy.
    private func probe() async -> ProbeOutcome {
        guard probeInFlight == nil else { return .timedOut }
        let factory = sessionFactory
        let checkCompatibility = compatibleNodeID
        let task = Task { await Self.performProbe(factory, compatibleNodeID: checkCompatibility) }
        probeInFlight = task
        Task { [weak self] in
            _ = await task.value
            await self?.probeFinished(task)
        }
        let sleep = self.sleep
        let timeout = policy.probeTimeout
        let race = ProbeRace()
        let timer = Task {
            try? await sleep(timeout)
            race.finish(.timedOut)
        }
        probeTimer = timer
        Task {
            race.finish(await task.value)
        }
        isAwaitingProbe = true
        let outcome = await race.value()
        isAwaitingProbe = false
        timer.cancel()
        probeTimer = nil
        if case .healthy(let nodeID, true) = outcome { compatibleNodeID = nodeID }
        return outcome
    }

    private func probeFinished(_ task: Task<ProbeOutcome, Never>) {
        if probeInFlight == task { probeInFlight = nil }
    }

    static func performProbe(_ factory: NodeMailSessionFactory, compatibleNodeID: String?) async -> ProbeOutcome {
        do {
            let session = try await factory()
            let nodeID = session.nodeID.lowercased()
            _ = try await session.client.status()
            if compatibleNodeID != nodeID {
                // Only the Node's own capabilities answer confirms mail mode;
                // a transport failure, a refusal or an undecodable answer
                // confirms nothing (and is not healthy).
                switch await NodeMailModeCompatibility.probe(session.client) {
                case .compatible: return .healthy(nodeID: nodeID, compatibilityConfirmed: true)
                case .updateRequired: return .updateRequired
                case .unavailable: return .unhealthy
                }
            }
            return .healthy(nodeID: nodeID, compatibilityConfirmed: false)
        } catch NodeSyncClientError.problem(.unauthorized) {
            return .unauthorized
        } catch NodeSessionBrokerError.notAdmitted {
            // A sticky Central refusal (expired token without a lease, a
            // suspended or deleted account): the user must reconnect.
            return .unauthorized
        } catch let error as NodeSessionError where error == .authenticationRejected {
            return .unauthorized
        } catch {
            return .unhealthy
        }
    }

    // MARK: - Transitions

    private func reconcile(groups: [String: [AccountMailSource]]) async {
        let canDispatch = await mayDispatch()
        var returnedAny = false
        for (nodeID, sources) in groups.sorted(by: { $0.key < $1.key }) {
            guard let mode = hysteresis[nodeID]?.mode else { continue }
            switch mode {
            case .fallback:
                var entered: [AccountID] = []
                // Only an account this device can sign in to directly falls back; the rest
                // stay with their Node, their changes waiting for it.
                for source in sources where source.mode == .node {
                    guard await mayFallBack(source.accountID) else { continue }
                    if flip(source, to: .fallback) { entered.append(source.accountID) }
                }
                if !entered.isEmpty {
                    reachabilityLogger.notice("Sync Node unreachable: \(entered.count, privacy: .public) account(s) connected directly.")
                }
                if canDispatch {
                    for accountID in entered { await router.dispatchPending(accountID: accountID) }
                }
                // Accounts that were already in fallback: re-drain queued rows.
                await redrain(sources.filter { $0.mode == .fallback }.map(\.accountID), settle: false, canDispatch: canDispatch)
            case .node:
                guard nodeID == reachableNodeID else { continue }
                var returned: [AccountID] = []
                for source in sources where source.mode == .fallback {
                    if flip(source, to: .node) { returned.append(source.accountID) }
                }
                for accountID in returned {
                    do {
                        _ = try await router.rerouteUnstartedDirectIntents(accountID: accountID)
                    } catch {
                        reachabilityLogger.error("Reconnect: the unstarted intents could not be read; the next drain retries.")
                    }
                }
                if canDispatch {
                    for accountID in returned {
                        await router.settleAdmittedIntents(accountID: accountID)
                        await router.dispatchPending(accountID: accountID)
                    }
                    if !returned.isEmpty { lastSettle = elapsed() }
                }
                if !returned.isEmpty {
                    returnedAny = true
                    reachabilityLogger.notice("Sync Node reachable again: \(returned.count, privacy: .public) account(s) follow the Node.")
                }
                await redrain(sources.filter { $0.mode == .node }.map(\.accountID), settle: true, canDispatch: canDispatch)
            }
        }
        if returnedAny {
            guard runState == .running, !Task.isCancelled else { return }
            await mirrorLoop.wake()
        }
    }

    /// Compare-and-swap one account's mode. A stale generation or a store
    /// error leaves it for the next tick.
    private func flip(_ source: AccountMailSource, to mode: NodeBackedMode) -> Bool {
        do {
            try store.replaceMailSource(source.withMode(mode), expectedGeneration: source.generation)
            return true
        } catch {
            reachabilityLogger.error("A mail mode change was not written; the next tick retries it.")
            return false
        }
    }

    /// Periodic drain while rows wait: pending rows are dispatched every
    /// tick; admitted/uncertain Node rows are settled at most every
    /// `settleInterval`. A read error skips the account until the next tick.
    private func redrain(_ accounts: [AccountID], settle: Bool, canDispatch: Bool) async {
        guard canDispatch, !accounts.isEmpty else { return }
        let settleDue = settle && (lastSettle.map { elapsed() - $0 >= policy.settleInterval } ?? true)
        var settled = false
        for accountID in accounts {
            guard runState == .running, !Task.isCancelled else { return }
            if settleDue,
               let waiting = try? store.mailIntents(accountID: accountID, states: [.admitted, .uncertain]),
               waiting.contains(where: { $0.route == .node }) {
                await router.settleAdmittedIntents(accountID: accountID)
                settled = true
            }
            if let pending = try? store.mailIntents(accountID: accountID, states: [.pending]),
               pending.contains(where: { $0.route == nil && $0.kind != .credentialPush }) {
                await router.dispatchPending(accountID: accountID)
            }
        }
        if settled { lastSettle = elapsed() }
    }

    private func waitingIntentCount() -> Int {
        guard let sources = try? store.mailSources() else { return 0 }
        var count = 0
        for source in sources where source.kind == .nodeBacked {
            let rows = (try? store.mailIntents(
                accountID: source.accountID, states: [.pending, .dispatching, .admitted, .uncertain]
            )) ?? []
            count += rows.filter { $0.kind != .credentialPush }.count
        }
        return count
    }
}

/// The first of a probe answer or its timeout wins; the other is ignored.
private final class ProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: NodeReachabilitySupervisor.ProbeOutcome?
    private var waiter: CheckedContinuation<NodeReachabilitySupervisor.ProbeOutcome, Never>?

    func finish(_ value: NodeReachabilitySupervisor.ProbeOutcome) {
        let continuation = lock.withLock { () -> CheckedContinuation<NodeReachabilitySupervisor.ProbeOutcome, Never>? in
            guard outcome == nil else { return nil }
            outcome = value
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: value)
    }

    func value() async -> NodeReachabilitySupervisor.ProbeOutcome {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> NodeReachabilitySupervisor.ProbeOutcome? in
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
