import Foundation

/// What the broker's single request lane has been doing, for the
/// reachability supervisor: a probe that waits behind a long mirror request
/// (a re-snapshot) must not mark a busy but healthy Node down.
public struct NodeLaneActivitySnapshot: Equatable, Sendable {
    /// Time since the Node last answered any lane request (nil: never).
    public let sinceLastResponse: Duration?
    /// How long the request now holding the lane has held it (nil: free).
    public let laneHeldFor: Duration?

    public init(sinceLastResponse: Duration?, laneHeldFor: Duration?) {
        self.sinceLastResponse = sinceLastResponse
        self.laneHeldFor = laneHeldFor
    }
}

/// Lock-protected record of the broker lane: when it was last acquired and
/// when the Node last answered. It holds only instants, no request data.
public final class NodeLaneActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastResponse: ContinuousClock.Instant?
    private var heldSince: ContinuousClock.Instant?

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    func acquired() { lock.withLock { heldSince = now() } }
    func released() { lock.withLock { heldSince = nil } }

    /// Only a successful answer shows the Node is reachable: a relay or
    /// proxy can answer 4xx (429, 404) or 5xx on its own.
    func recordResponse(statusCode: Int) {
        guard (200..<300).contains(statusCode) else { return }
        lock.withLock { lastResponse = now() }
    }

    public func snapshot() -> NodeLaneActivitySnapshot {
        lock.withLock {
            let current = now()
            return NodeLaneActivitySnapshot(
                sinceLastResponse: lastResponse.map { $0.duration(to: current) },
                laneHeldFor: heldSince.map { $0.duration(to: current) }
            )
        }
    }
}
