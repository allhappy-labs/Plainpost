import Foundation
import XCTest
import PlainpostAccountProtocol
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostNodeMailMode
@testable import PlainpostNodeTransport

/// A step-driven `Clock<Duration>`: sleepers resume only when the test
/// advances time past their deadline.
final class ReachabilityTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action = lock.withLock { () -> Action in
                    if cancelled.remove(id) != nil { return .cancel }
                    if deadline <= current { return .resume }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return nil
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes every sleeper now due. Returns how many.
    @discardableResult
    func advance(by duration: Duration) -> Int {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers[key] = nil }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
        return due.count
    }
}

final class ReachabilityEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var events: [String] { lock.withLock { stored } }
    func append(_ event: String) { lock.withLock { stored.append(event) } }
    func clear() { lock.withLock { stored.removeAll() } }
}

/// Records the supervisor's router calls, then forwards them to the real router.
final class RecordingReachabilityRouter: NodeReachabilityIntentRouting, @unchecked Sendable {
    private let router: MailIntentRouter
    private let log: ReachabilityEventLog
    private let lock = NSLock()
    private var settleGate: FakeNodeMailServer.Gate?

    init(router: MailIntentRouter, log: ReachabilityEventLog) {
        self.router = router
        self.log = log
    }

    /// Holds the next settle pass until the gate is released.
    func holdNextSettle() -> FakeNodeMailServer.Gate {
        let gate = FakeNodeMailServer.Gate()
        lock.withLock { settleGate = gate }
        return gate
    }

    func rerouteUnstartedDirectIntents(accountID: AccountID) async throws -> Int {
        log.append("reroute")
        return try await router.rerouteUnstartedDirectIntents(accountID: accountID)
    }

    func settleAdmittedIntents(accountID: AccountID) async {
        log.append("settle")
        if let gate = lock.withLock({ () -> FakeNodeMailServer.Gate? in defer { settleGate = nil }; return settleGate }) {
            await gate.arrive()
        }
        await router.settleAdmittedIntents(accountID: accountID)
    }

    func dispatchPending(accountID: AccountID) async {
        log.append("dispatchPending")
        await router.dispatchPending(accountID: accountID)
    }
}

final class RecordingMirrorWaker: NodeMailMirrorWaking, @unchecked Sendable {
    private let log: ReachabilityEventLog
    init(log: ReachabilityEventLog) { self.log = log }
    func wake() async { log.append("mirrorPass") }
}

final class ReachabilityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class ReachabilityBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class ReachabilityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

final class NodeReachabilitySupervisorHarness: @unchecked Sendable {
    static let nodeID = "40000000-0000-4000-8000-000000000917"

    let store: SQLiteMailStore
    let url: URL
    let accountIDs: [AccountID]
    var accountID: AccountID { accountIDs[0] }
    let node: FakeNodeMailServer
    let clock: ReachabilityTestClock
    let log: ReachabilityEventLog
    let direct: RecordingDirectMailDispatcher
    let router: MailIntentRouter
    let routing: RecordingReachabilityRouter
    let vaultOpen = ReachabilityFlag(true)
    /// The accounts that may fall back; nil lets every account.
    var mayFallBack: Set<AccountID>?
    /// While false the session factory throws, as a broker that cannot
    /// resolve or admit a session does.
    let sessionAvailable = ReachabilityFlag(true)
    /// Thrown by the session factory when set (for example the broker's
    /// sticky `notAdmitted`).
    let sessionError = ReachabilityBox<(any Error)?>(nil)
    /// Time the session factory takes, on the test clock.
    let probeDelay = ReachabilityBox<Duration?>(nil)
    /// What the broker lane reports.
    let laneActivity = ReachabilityBox<NodeLaneActivitySnapshot?>(nil)
    let ticks = ReachabilityCounter()
    /// Set while a test holds a probe on the wire: the harness then also
    /// treats "waiting for the probe's timeout" as settled.
    let probeMayHang = ReachabilityFlag(false)
    let invalidations = ReachabilityCounter()
    let accountSignals = ReachabilityCounter()
    var supervisor: NodeReachabilitySupervisor!
    private var observer: NSObjectProtocol?

    private init(store: SQLiteMailStore, url: URL, accountIDs: [AccountID], node: FakeNodeMailServer, clock: ReachabilityTestClock,
                 log: ReachabilityEventLog, direct: RecordingDirectMailDispatcher, router: MailIntentRouter,
                 routing: RecordingReachabilityRouter) {
        self.store = store
        self.url = url
        self.accountIDs = accountIDs
        self.node = node
        self.clock = clock
        self.log = log
        self.direct = direct
        self.router = router
        self.routing = routing
    }

    /// `modes[i]` is the persisted source of account `i`: nil for Direct.
    static let otherNodeID = "40000000-0000-4000-8000-000000000999"

    /// `boundTo[i]`, when set, binds account `i` to that Node instead of the
    /// session's.
    static func make(
        testName: String,
        modes: [NodeBackedMode?] = [.node],
        boundTo: [String?] = [],
        vaultOpen: Bool = true,
        mayFallBack: Set<Int>? = nil,
        start: Bool = true
    ) async throws -> NodeReachabilitySupervisorHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-reachability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("plainpost.sqlite")
        let store = try SQLiteMailStore(path: url.path)
        try store.migrate()
        let accounts = modes.indices.map { index in
            Account(id: AccountID("acc-\(index)"), displayName: "Account \(index)", email: EmailAddress("user\(index)@example.test"),
                    imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        }
        try store.cacheAccounts(accounts)
        let node = FakeNodeMailServer()
        node.setSigningNodeID(nodeID)
        let log = ReachabilityEventLog()
        let direct = RecordingDirectMailDispatcher()
        let router = MailIntentRouter(store: store, direct: direct, sleep: { _ in })
        let harness = NodeReachabilitySupervisorHarness(
            store: store, url: url, accountIDs: accounts.map(\.id), node: node, clock: ReachabilityTestClock(), log: log,
            direct: direct, router: router, routing: RecordingReachabilityRouter(router: router, log: log)
        )
        harness.vaultOpen.value = vaultOpen
        harness.mayFallBack = mayFallBack.map { Set($0.map { accounts[$0].id }) }
        for (index, mode) in modes.enumerated() {
            if let mode {
                try harness.persist(account: index, mode: mode, nodeID: index < boundTo.count ? boundTo[index] ?? nodeID : nodeID)
            }
        }
        harness.observeAccountSignals()
        harness.supervisor = harness.makeSupervisor()
        await router.attach(sessions: harness.supervisor)
        if start { await harness.start() }
        return harness
    }

    func makeSupervisor(policy: NodeReachabilityPolicy = .production) -> NodeReachabilitySupervisor {
        let node = self.node
        let vaultOpen = self.vaultOpen
        let invalidations = self.invalidations
        let sessionAvailable = self.sessionAvailable
        let sessionError = self.sessionError
        let probeDelay = self.probeDelay
        let laneActivity = self.laneActivity
        let ticks = self.ticks
        let clock = self.clock
        let mayFallBack = self.mayFallBack
        return NodeReachabilitySupervisor(
            store: store,
            sessionFactory: {
                if let delay = probeDelay.value {
                    try await clock.sleep(until: clock.now.advanced(by: delay), tolerance: nil)
                }
                if let error = sessionError.value { throw error }
                guard sessionAvailable.value else { throw NodeSessionBrokerError.unavailable }
                return (Self.nodeID, NodeSyncClient(sender: node))
            },
            routing: routing,
            mirror: RecordingMirrorWaker(log: log),
            invalidateSession: { invalidations.increment() },
            mayDispatch: { vaultOpen.value },
            laneActivity: { laneActivity.value },
            afterTick: { ticks.increment() },
            mayFallBack: { accountID in mayFallBack?.contains(accountID) ?? true },
            policy: policy,
            clock: clock
        )
    }

    /// Replaces the supervisor with a fresh one over the same store, as a
    /// service restart does.
    func restart() async {
        await supervisor.stop()
        supervisor = makeSupervisor()
        await router.attach(sessions: supervisor)
        await start()
    }

    /// Stops the current supervisor and runs `replacement` in its place.
    func replaceSupervisor(with replacement: NodeReachabilitySupervisor) async {
        await supervisor.stop()
        supervisor = replacement
        await router.attach(sessions: replacement)
        await start()
    }

    func start() async {
        let before = await supervisor.completedCycles
        await supervisor.start()
        await waitUntilParked(after: before)
    }

    func cleanUp() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func observeAccountSignals() {
        let store = self.store
        let log = self.log
        let counter = self.accountSignals
        let accountIDs = self.accountIDs
        observer = NotificationCenter.default.addObserver(
            forName: MailStoreChangeSignal.notificationName, object: nil, queue: nil
        ) { notification in
            guard MailStoreChangeSignal.scope(from: notification) == .accounts else { return }
            counter.increment()
            for accountID in accountIDs {
                if let mode = try? store.mailSource(accountID: accountID).mode {
                    log.append("mode:\(mode.rawValue)")
                    return
                }
            }
        }
    }

    // MARK: - Time

    /// Advances the clock one second at a time, letting every probe cycle
    /// that falls due finish before time moves on.
    func advance(by duration: Duration) async {
        var remaining = duration
        while remaining > .zero {
            let step = min(Duration.seconds(1), remaining)
            remaining -= step
            let before = await supervisor.completedCycles
            if clock.advance(by: step) > 0 {
                if probeMayHang.value {
                    // A woken probe (not the loop) may still be finishing:
                    // let it run before time moves on.
                    try? await Task.sleep(for: .milliseconds(20))
                }
                await waitUntilParked(after: before)
            }
        }
    }

    func waitUntilParked(after before: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let cycles = await supervisor.completedCycles
            let cycling = await supervisor.isCycling
            if cycles > before, !cycling, clock.sleeperCount > 0 { return }
            if probeMayHang.value, cycling, await supervisor.isAwaitingProbe, clock.sleeperCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("the supervisor never finished its probe cycle", file: file, line: line)
    }

    // MARK: - Store

    func persist(account index: Int, mode: NodeBackedMode, nodeID boundNodeID: String = NodeReachabilitySupervisorHarness.nodeID) throws {
        let accountID = accountIDs[index]
        var current = try store.mailSource(accountID: accountID)
        if current.kind != .nodeBacked {
            let logical = index == 0 ? FakeNodeMailServer.accountA : FakeNodeMailServer.accountB
            current = try store.replaceMailSource(
                current.nodeBacked(nodeID: boundNodeID, logicalMailboxID: try NodeSyncCodec.encodeLogicalMailboxID(logical),
                                   providerIdentity: "user\(index)@example.test"),
                expectedGeneration: current.generation)
        }
        if current.mode != mode {
            _ = try store.replaceMailSource(current.withMode(mode), expectedGeneration: current.generation)
        }
    }

    func mode(_ index: Int = 0) throws -> NodeBackedMode? {
        try store.mailSource(accountID: accountIDs[index]).mode
    }

    func intent(_ operationID: String) throws -> MailIntentRecord {
        try XCTUnwrap(try store.mailIntent(operationID: operationID))
    }

    /// A local message on account 0 with no Node link (so a Node dispatch
    /// would refuse it, and only a direct dispatch can apply it).
    func seedLocalMessage() throws -> MessageID {
        let rfcMessageID = "<reachability-\(UUID().uuidString)@example.test>"
        let id = MessageID(IMAPSyncService.canonicalMessageID(accountID: accountID, rfcMessageID: rfcMessageID))
        let message = MessageSummary(id: id, threadID: nil, from: EmailAddress("a@example.test"), subject: "Hi", preview: "Hi",
                                     smartCategory: .personal, labels: [], isSeen: false, mailboxPath: "INBOX", isDeleted: false,
                                     body: "Hi", rfcMessageID: rfcMessageID)
        _ = try store.commitIncomingMessage(
            message, metadata: IncomingMessageSearchMetadata(to: [], cc: [], bcc: [], attachments: [], messageIdentifiers: []),
            accountID: accountID, mailboxPath: "INBOX", uidValidity: 7, uid: 42, notificationDisposition: .ineligible)
        return id
    }

    /// Mirrors one Node message into account 0 through the real mirror.
    func seedMirroredMessage(nodeID messageNodeID: String) async throws -> MessageID {
        node.addMessage(nodeID: messageNodeID, rfcMessageID: "<\(messageNodeID)@example.test>",
                        memberships: [("INBOX", 1, UInt32(abs(messageNodeID.hashValue) % 90_000 + 1), [])],
                        logical: FakeNodeMailServer.accountA)
        let mirror = NodeMailMirror(store: store, client: NodeSyncClient(sender: node), nodeID: Self.nodeID)
        _ = try await mirror.runPass()
        return try XCTUnwrap(try store.messageID(forNodeMessageID: messageNodeID, accountID: accountID))
    }

    func makeDraft() throws -> Draft {
        try store.createDraft(
            Draft(id: DraftID("drf_reach_\(UUID().uuidString.prefix(8).lowercased())"), accountID: accountID,
                  from: EmailAddress("user0@example.test"), to: [EmailAddress("to@example.test")], cc: [], bcc: [],
                  subject: "Reachability", bodyPlain: "Hello", createdBy: "local-user", aiGenerated: false, sourceThreadID: nil),
            actor: Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser))
    }

    func waitUntil(timeout: Duration = .seconds(5), _ predicate: @escaping @Sendable () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !predicate() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for a condition", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
