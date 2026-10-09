import Foundation

/// Timing of the service's Sync Node reachability supervisor.
public struct NodeReachabilityPolicy: Equatable, Sendable {
    /// Sustained failure before Node-backed accounts fall back to direct
    /// sync (spec range 30–60 s).
    public let unhealthyWindow: Duration
    /// Sustained health, after fallback, before the accounts return to the
    /// Node. A flapping Node needs longer (`requiredHealthyWindow`).
    public let healthyWindow: Duration
    /// Time between health probes.
    public let probeInterval: Duration
    /// A probe with no answer after this long counts as unhealthy.
    public let probeTimeout: Duration
    /// A fallback entered within this long after the last reconnect counts
    /// as a flap: each one doubles the healthy window needed to return.
    public let flapMemory: Duration
    /// The longest healthy window a flapping Node is held to.
    public let maximumHealthyWindow: Duration
    /// Minimum time between settle passes over admitted/uncertain intents
    /// while the Node stays reachable.
    public let settleInterval: Duration

    public init(
        unhealthyWindow: Duration,
        healthyWindow: Duration,
        probeInterval: Duration,
        probeTimeout: Duration,
        flapMemory: Duration,
        maximumHealthyWindow: Duration,
        settleInterval: Duration
    ) {
        self.unhealthyWindow = unhealthyWindow
        self.healthyWindow = healthyWindow
        self.probeInterval = probeInterval
        self.probeTimeout = probeTimeout
        self.flapMemory = flapMemory
        self.maximumHealthyWindow = max(maximumHealthyWindow, healthyWindow)
        self.settleInterval = settleInterval
    }

    public static let production = NodeReachabilityPolicy(
        unhealthyWindow: .seconds(45),
        healthyWindow: .seconds(30),
        probeInterval: .seconds(10),
        probeTimeout: .seconds(10),
        flapMemory: .seconds(600),
        maximumHealthyWindow: .seconds(600),
        settleInterval: .seconds(60)
    )
}

/// Decides, from a series of health observations, when Node-backed accounts
/// fall back to direct sync and when they return to the Node.
///
/// - In `.node`, only an unbroken run of unhealthy observations spanning
///   `unhealthyWindow` switches to `.fallback`; one healthy observation
///   restarts the run.
/// - In `.fallback`, only an unbroken run of healthy observations spanning
///   `requiredHealthyWindow` switches back to `.node`. The run starts at the
///   first healthy observation after the fallback began, so the accounts
///   stay in fallback at least that long (the dwell time).
/// - Flap damping: a fallback that begins within `flapMemory` of the last
///   reconnect doubles `requiredHealthyWindow` (capped at
///   `maximumHealthyWindow`); a fallback after a longer stable period starts
///   from `healthyWindow` again. Each return to `.node` can cost a full
///   re-snapshot of the account, so a flapping Node must not cause a storm.
public struct NodeReachabilityHysteresis: Equatable, Sendable {
    public let policy: NodeReachabilityPolicy
    public private(set) var mode: NodeBackedMode
    /// Start of the current run of observations that argue for leaving `mode`.
    private var runStart: ContinuousClock.Instant?
    private var lastReconnect: ContinuousClock.Instant?
    private var flaps = 0

    public init(policy: NodeReachabilityPolicy, mode: NodeBackedMode) {
        self.policy = policy
        self.mode = mode
    }

    /// The sustained healthy window needed to leave the current fallback.
    public var requiredHealthyWindow: Duration {
        var window = policy.healthyWindow
        for _ in 0..<min(flaps, 32) {
            window = window * 2
            if window >= policy.maximumHealthyWindow { return policy.maximumHealthyWindow }
        }
        return min(window, policy.maximumHealthyWindow)
    }

    /// Returns the new mode when a sustained window completes; nil otherwise.
    public mutating func observe(healthy: Bool, at instant: ContinuousClock.Instant) -> NodeBackedMode? {
        switch mode {
        case .node:
            guard !healthy else {
                runStart = nil
                return nil
            }
            let start = runStart ?? instant
            runStart = start
            guard start.duration(to: instant) >= policy.unhealthyWindow else { return nil }
            if let lastReconnect, lastReconnect.duration(to: instant) < policy.flapMemory {
                flaps += 1
            } else {
                flaps = 0
            }
            mode = .fallback
            runStart = nil
            return .fallback
        case .fallback:
            guard healthy else {
                runStart = nil
                return nil
            }
            let start = runStart ?? instant
            runStart = start
            guard start.duration(to: instant) >= requiredHealthyWindow else { return nil }
            mode = .node
            runStart = nil
            lastReconnect = instant
            return .node
        }
    }
}
