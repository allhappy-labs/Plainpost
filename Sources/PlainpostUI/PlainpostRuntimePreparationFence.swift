import Foundation

/// Main-actor state for runtime preparation tasks. Swift task cancellation is
/// cooperative, so a cancelled task can still return from an awaited
/// operation; callers must check this fence before publishing its result.
@MainActor
public final class PlainpostRuntimePreparationFence {
    private var generation: UInt64 = 0

    public init() {}

    public func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}
