import Foundation
import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class SyncNodeConnectionCheckerTests: XCTestCase {
    func testRetriesStrictReadinessThenPerformsOneSignedStatusRead() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:18443")
        let events = ConnectionCheckEvents()
        let readiness = ScriptedReadinessTransport(endpoint: endpoint.url, statuses: [503, 200], events: events)
        let sender = StatusSender(events: events)
        let checker = SyncNodeConnectionChecker(
            client: NodeTLSClient(transport: readiness),
            maximumReadinessAttempts: 3,
            delay: .zero,
            sleep: { _ in }
        )

        try await checker.check(endpoint: endpoint, sender: sender)

        XCTAssertEqual(events.values(), ["ready", "ready", "status"])
        let statusCount = await sender.count()
        XCTAssertEqual(statusCount, 1)
    }

    func testReadinessTimeoutNeverConsumesSignedSessionSequence() async throws {
        let endpoint = try NodeEndpointURL("https://node.tail1234.ts.net:18443")
        let events = ConnectionCheckEvents()
        let readiness = ScriptedReadinessTransport(endpoint: endpoint.url, statuses: [503, 503], events: events)
        let sender = StatusSender(events: events)
        let checker = SyncNodeConnectionChecker(
            client: NodeTLSClient(transport: readiness),
            maximumReadinessAttempts: 2,
            delay: .zero,
            sleep: { _ in }
        )

        do {
            try await checker.check(endpoint: endpoint, sender: sender)
            XCTFail("expected readiness timeout")
        } catch {}

        XCTAssertEqual(events.values(), ["ready", "ready"])
        let statusCount = await sender.count()
        XCTAssertEqual(statusCount, 0)
    }
}

private final class ConnectionCheckEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ event: String) { lock.withLock { events.append(event) } }
    func values() -> [String] { lock.withLock { events } }
}

private actor ScriptedReadinessTransport: NodeHTTPTransport {
    private let endpoint: URL
    private var statuses: [Int]
    private let events: ConnectionCheckEvents
    init(endpoint: URL, statuses: [Int], events: ConnectionCheckEvents) {
        self.endpoint = endpoint
        self.statuses = statuses
        self.events = events
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard request.url?.path == "/readyz", request.httpMethod == "GET", maximumResponseBytes == 1024 else {
            throw NodeSessionError.invalidValue
        }
        events.record("ready")
        return NodeHTTPResponse(statusCode: statuses.removeFirst(), url: endpoint, headers: [:], body: Data())
    }
}

private actor StatusSender: NodeSessionRequestSending {
    private var calls = 0
    private let events: ConnectionCheckEvents
    init(events: ConnectionCheckEvents) { self.events = events }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard method == "GET", path == "/v1/status", body.isEmpty else { throw NodeSyncClientError.invalidResponse }
        calls += 1
        events.record("status")
        let status = try NodeSyncStatusResult(
            revision: "1",
            state: "ready",
            version: "node-sync-v1",
            reachability: "reachable",
            syncLag: "0",
            storage: "managed",
            assignments: [],
            backup: "not_reported",
            endpoint: "session-scoped",
            updateStatus: "current"
        )
        return NodeHTTPResponse(
            statusCode: 200,
            url: URL(string: "https://node.tail1234.ts.net:18443/v1/status")!,
            headers: [:],
            body: try NodeSyncCodec.encodeStatusResult(status)
        )
    }
    func count() -> Int { calls }
}
