import Foundation
import PlainpostCore

public struct AccountVerificationCleanup: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public let maximumAttempts: Int
    public let retryDelay: Duration
    private let sleep: Sleep

    public init(
        maximumAttempts: Int = 6,
        retryDelay: Duration = .milliseconds(500),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    public func delete(
        message: AccountVerificationMessage,
        newerThan baselineUID: Int?,
        using client: IMAPClientProtocol
    ) async {
        for attempt in 0..<maximumAttempts {
            do {
                for uid in try await client.messageUIDs(after: baselineUID) {
                    let header = try await client.fetchHeader(uid: uid)
                    guard message.matchesDeliveryHeader(header) else { continue }
                    try await client.delete(uid: uid)
                    return
                }
            } catch {
                // Cleanup is deliberately silent and non-blocking.
            }
            guard attempt + 1 < maximumAttempts else { return }
            do {
                try await sleep(retryDelay)
            } catch {
                return
            }
        }
    }
}
