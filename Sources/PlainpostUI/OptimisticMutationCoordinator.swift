import Combine
import Foundation

public enum OptimisticMutationResolution: Equatable, Sendable {
    case committed
    case rolledBack
    case superseded
}

public struct OptimisticMutationToken<Key: Hashable & Sendable>: Equatable, Sendable {
    public let key: Key
    fileprivate let id: UUID
}

@MainActor
public final class OptimisticMutationCoordinator<Key: Hashable & Sendable>: ObservableObject {
    @Published public private(set) var pendingKeys: Set<Key> = []
    private var latestTokenIDs: [Key: UUID] = [:]

    public init() {}

    public func begin(for key: Key) -> OptimisticMutationToken<Key> {
        let token = OptimisticMutationToken(key: key, id: UUID())
        latestTokenIDs[key] = token.id
        pendingKeys.insert(key)
        return token
    }

    public func isPending(_ key: Key) -> Bool {
        pendingKeys.contains(key)
    }

    /// True while a newer mutation for `token`'s key is pending, so `token` can no longer resolve it.
    public func isSuperseded(_ token: OptimisticMutationToken<Key>) -> Bool {
        guard let latest = latestTokenIDs[token.key] else { return false }
        return latest != token.id
    }

    @discardableResult
    public func resolve(
        _ token: OptimisticMutationToken<Key>,
        as resolution: OptimisticMutationResolution
    ) -> OptimisticMutationResolution {
        guard latestTokenIDs[token.key] == token.id else { return .superseded }
        latestTokenIDs[token.key] = nil
        pendingKeys.remove(token.key)
        return resolution
    }
}
