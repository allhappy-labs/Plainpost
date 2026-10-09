@preconcurrency import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostNodeTransport

/// Where the loop gets its Node client. Production uses `NodeSessionBroker`,
/// the single owner of the Mac's Node session; nothing here opens a transport.
public protocol NodeMailMirrorSessionProviding: Sendable {
    func mirrorClient() async throws -> (nodeID: String, client: NodeSyncClient)
}

extension NodeSessionBroker: NodeMailMirrorSessionProviding {
    public func mirrorClient() async throws -> (nodeID: String, client: NodeSyncClient) {
        try await client()
    }
}

/// Jittered exponential retry delay after failed cycles: `base · 2^(n-1)`,
/// capped at `maximum`, then scaled by a random factor in [0.5, 1].
public struct NodeMailMirrorBackoff: Sendable {
    public var base: Duration
    public var maximum: Duration
    public var random: @Sendable () -> Double

    public init(base: Duration = .seconds(2), maximum: Duration = .seconds(300),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1) }) {
        self.base = base
        self.maximum = maximum
        self.random = random
    }

    public func delay(afterFailures failures: Int) -> Duration {
        let exponent = min(max(failures - 1, 0), 30)
        let raw = min(base * Double(1 << exponent), maximum)
        return raw * min(max(random(), 0.5), 1)
    }
}

/// Service-lifetime owner of the one `NodeMailMirror` per Node. It runs in
/// the background service, whether or not the app is open: it waits for an
/// `.accounts` store change, `wake()` or a 60 s tick, takes the broker's
/// current client, and runs `runPass()` then `hydrate(limit: 50)`.
///
/// - Without any account in `node` mode (Direct, or Node-backed in fallback,
///   where direct sync owns the mail) it makes no Node request and waits for
///   an `.accounts` change.
/// - A refused admission, an unavailable Node or a read error backs off
///   with jitter; it never spins.
/// - A `wake()` during a pass queues exactly one follow-up pass. Passes for
///   one Node never overlap.
/// - It observes only `.accounts` (and `.all`), never the `.mailbox` changes
///   it posts itself, so its own writes cannot wake it.
public actor NodeMailMirrorLoop {
    public typealias MirrorFactory = @Sendable (String, NodeSyncClient) -> NodeMailMirror
    public static let tick: Duration = .seconds(60)
    public static let hydrationBatch = 50

    enum Outcome: Equatable {
        /// No account in `node` mode: wait for an `.accounts` change.
        case idle
        case caughtUp
        case more
        case failed
        case stopped
    }

    private enum State {
        case inactive
        case running
        case stopped
    }

    private let store: SQLiteMailStore
    private let sessions: any NodeMailMirrorSessionProviding
    private let makeMirror: MirrorFactory
    private let tick: Duration
    private let backoff: NodeMailMirrorBackoff
    private let sleep: @Sendable (Duration) async throws -> Void
    private let notificationCenter: NotificationCenter
    private let observeDistributedNotifications: Bool

    private var state = State.inactive
    private var task: Task<Void, Never>?
    private var mirrors: [String: NodeMailMirror] = [:]
    private var failures = 0
    private var wakePending = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitToken: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var localObserver: NSObjectProtocol?
#if os(macOS)
    private var distributedObserver: NSObjectProtocol?
#endif
    private(set) var cycles = 0
    private(set) var lastOutcome: Outcome?
    private(set) var requestedDelays: [Duration] = []

    public init(store: SQLiteMailStore, broker: NodeSessionBroker, makeMirror: @escaping MirrorFactory) {
        self.init(store: store, sessions: broker, makeMirror: makeMirror)
    }

    init(
        store: SQLiteMailStore,
        sessions: any NodeMailMirrorSessionProviding,
        makeMirror: @escaping MirrorFactory,
        tick: Duration = NodeMailMirrorLoop.tick,
        backoff: NodeMailMirrorBackoff = NodeMailMirrorBackoff(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = .default,
        observeDistributedNotifications: Bool = true
    ) {
        self.store = store
        self.sessions = sessions
        self.makeMirror = makeMirror
        self.tick = tick
        self.backoff = backoff
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        self.observeDistributedNotifications = observeDistributedNotifications
    }

    public func start() async {
        guard state == .inactive else { return }
        state = .running
        installObservers()
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() async {
        guard state == .running else { return }
        state = .stopped
        removeObservers()
        let running = task
        task = nil
        running?.cancel()
        resumeWaiter()
        await running?.value
        mirrors.removeAll()
    }

    /// Asks for a pass now; during a pass, exactly one follow-up pass.
    public func wake() async {
        guard state == .running else { return }
        wakePending = true
        resumeWaiter()
    }

    /// Handover pass-through, before the flip: seeds the account's target
    /// binding on the loop-owned mirror for `nodeID`, which must be the
    /// broker's current Node.
    public func seedCursor(nodeID: String, accountID: AccountID, logicalMailboxID: String) async throws {
        let session = try await sessions.mirrorClient()
        let current = session.nodeID.lowercased()
        guard current == nodeID.lowercased() else { throw NodeMailModeStoreError.mirrorScopeChanged }
        try await mirror(for: current, client: session.client).seedCursor(accountID: accountID, logicalMailboxID: logicalMailboxID)
    }

    /// The loop-owned mirror for `nodeID`, if one exists (tests).
    func ownedMirror(nodeID: String) -> NodeMailMirror? { mirrors[nodeID.lowercased()] }

    // MARK: - Loop

    private func run() async {
        while state == .running, !Task.isCancelled {
            wakePending = false
            let outcome = await cycle()
            cycles += 1
            lastOutcome = outcome
            guard state == .running, !Task.isCancelled else { return }
            switch outcome {
            case .stopped:
                return
            case .idle:
                failures = 0
                await wait(timeout: nil)
            case .caughtUp:
                failures = 0
                await wait(timeout: tick)
            case .more:
                failures = 0
                await Task.yield()
            case .failed:
                failures += 1
                await wait(timeout: backoff.delay(afterFailures: failures))
            }
        }
    }

    func cycle() async -> Outcome {
        let scopes: [NodeMirrorScope]
        do {
            scopes = try store.mailSources().compactMap(NodeMirrorScope.init(source:))
        } catch {
            // A read error is not "no Node-backed account": retry.
            return .failed
        }
        guard !scopes.isEmpty else {
            mirrors.removeAll()
            return .idle
        }
        let session: (nodeID: String, client: NodeSyncClient)
        do {
            session = try await sessions.mirrorClient()
        } catch is CancellationError {
            return .stopped
        } catch {
            return .failed
        }
        let nodeID = session.nodeID.lowercased()
        mirrors = mirrors.filter { $0.key == nodeID }
        guard scopes.contains(where: { $0.nodeID == nodeID }) else {
            // Accounts are bound to another Node than the session's; recheck
            // on the next tick or `.accounts` change.
            mirrors.removeAll()
            return .caughtUp
        }
        let mirror = await mirror(for: nodeID, client: session.client)
        do {
            let result = try await mirror.runPass()
            guard state == .running, !Task.isCancelled else { return .stopped }
            _ = try await mirror.hydrate(limit: Self.hydrationBatch)
            return result.hasMore ? .more : .caughtUp
        } catch is CancellationError {
            return .stopped
        } catch {
            return Task.isCancelled ? .stopped : .failed
        }
    }

    private func mirror(for nodeID: String, client: NodeSyncClient) async -> NodeMailMirror {
        if let existing = mirrors[nodeID] {
            await existing.use(client: client)
            return existing
        }
        let created = makeMirror(nodeID, client)
        mirrors[nodeID] = created
        return created
    }

    private func wait(timeout: Duration?) async {
        guard !wakePending, state == .running, !Task.isCancelled else { return }
        if let timeout { requestedDelays.append(timeout) }
        waitToken &+= 1
        let token = waitToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            if let timeout {
                let sleep = self.sleep
                timer = Task { [weak self] in
                    // A cancelled timer, or one from an earlier wait, must not
                    // end a later wait early.
                    guard (try? await sleep(timeout)) != nil else { return }
                    await self?.timerFired(token: token)
                }
            }
        }
    }

    private func timerFired(token: UInt64) {
        guard token == waitToken else { return }
        resumeWaiter()
    }

    private func resumeWaiter() {
        timer?.cancel()
        timer = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }

    // MARK: - Observers

    private func installObservers() {
        localObserver = notificationCenter.addObserver(
            forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil
        ) { [weak self] notification in
            let scope = MailStoreChangeSignal.scope(from: notification)
            guard scope == .accounts || scope == .all else { return }
            Task { await self?.wake() }
        }
#if os(macOS)
        if observeDistributedNotifications {
            distributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil
            ) { [weak self] notification in
                let scope = MailStoreChangeSignal.scope(from: notification)
                guard scope == .accounts || scope == .all else { return }
                Task { await self?.wake() }
            }
        }
#endif
    }

    private func removeObservers() {
        if let localObserver {
            notificationCenter.removeObserver(localObserver)
            self.localObserver = nil
        }
#if os(macOS)
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
#endif
    }
}
