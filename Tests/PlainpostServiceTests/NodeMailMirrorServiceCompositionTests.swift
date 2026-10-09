import Foundation
import XCTest
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB
import PlainpostNodeMailMode
import PlainpostNodeTransport
@testable import PlainpostService

/// The service's mirror composition: the loop takes every Node request
/// through the broker it is given, starts and stops with the service.
final class NodeMailMirrorServiceCompositionTests: XCTestCase {
    func testServiceMirrorUsesTheGivenBrokerAndStartsAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-service-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
        try store.migrate()
        let account = Account(id: AccountID("acc-node"), displayName: "Node", email: EmailAddress("n@example.test"),
                              imapHost: "imap.example.test", smtpHost: "smtp.example.test")
        try store.cacheAccounts([account])
        let nodeID = "40000000-0000-4000-8000-000000000901"
        let logical = try NodeSyncCodec.encodeLogicalMailboxID(LogicalMailboxID(rawValue: Data(repeating: 0x11, count: 32))!)
        _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
            nodeID: nodeID, logicalMailboxID: logical, providerIdentity: "n@example.test"), expectedGeneration: 0)

        let sender = RecordingSender()
        let resolved = ResolveCounter()
        let broker = NodeSessionBroker(resolveSender: {
            resolved.increment()
            return (nodeID, sender)
        })
        let loop = PlainpostServiceComposition.makeNodeMailMirror(store: store, broker: broker)

        await loop.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while sender.paths.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await loop.stop()

        XCTAssertGreaterThan(resolved.value, 0, "the mirror resolved its session through the broker")
        XCTAssertEqual(sender.paths.first, "POST /v1/mail/deltas", "the first mirror request went through the broker's sender")
        let count = sender.paths.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sender.paths.count, count, "no request after stop")
    }
}

private final class ResolveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

/// Answers every request 503, so the loop backs off after its first request.
private final class RecordingSender: NodeSessionRequestSending, NodePendingRequestReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        lock.withLock { stored.append(method + " " + path) }
        return NodeHTTPResponse(statusCode: 503, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }
}
