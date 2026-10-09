import Foundation
import PlainpostNodeTransport

public struct SyncNodeCachedConnection: Sendable {
    public let endpoint: NodeEndpointURL
    public let transport: NodeSessionTransport

    public init(endpoint: NodeEndpointURL, transport: NodeSessionTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }
}

public protocol SyncNodeConnectionChecking: Sendable {
    func check(endpoint: NodeEndpointURL, sender: any NodeSessionRequestSending) async throws
}

public extension SyncNodeConnectionChecking {
    func check(_ connection: SyncNodeCachedConnection) async throws {
        try await check(endpoint: connection.endpoint, sender: connection.transport)
    }
}

/// Separates same-process publication from Runtime readiness. A successful
/// check requires strict readiness followed by one authenticated signed read.
public struct SyncNodeConnectionChecker: SyncNodeConnectionChecking {
    private let client: NodeTLSClient
    private let maximumReadinessAttempts: Int
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        client: NodeTLSClient = NodeTLSClient(),
        maximumReadinessAttempts: Int = 20,
        delay: Duration = .milliseconds(250)
    ) {
        self.init(
            client: client,
            maximumReadinessAttempts: maximumReadinessAttempts,
            delay: delay,
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        client: NodeTLSClient,
        maximumReadinessAttempts: Int,
        delay: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.client = client
        self.maximumReadinessAttempts = maximumReadinessAttempts
        self.delay = delay
        self.sleep = sleep
    }

    public func check(endpoint: NodeEndpointURL, sender: any NodeSessionRequestSending) async throws {
        guard maximumReadinessAttempts > 0 else { throw NodeSessionError.transportFailure }
        var lastError: Error = NodeSessionError.transportFailure
        var ready = false
        for attempt in 0 ..< maximumReadinessAttempts {
            do {
                let response = try await client.send(
                    NodeHTTPRequest(endpoint: endpoint, method: "GET", path: "/readyz", body: Data()),
                    maximumResponseBytes: SyncNodeEnrollmentPresentationClient.maximumResponseBytes
                )
                guard response.statusCode == 200 else { throw NodeSessionError.transportFailure }
                ready = true
                break
            } catch {
                lastError = error
                if attempt + 1 < maximumReadinessAttempts {
                    try await sleep(delay)
                }
            }
        }
        guard ready else { throw lastError }
        _ = try await NodeSyncClient(sender: sender).status()
    }
}
