import Foundation
import XCTest
import PlainpostAccountProtocol
import PlainpostCore
import PlainpostDB
import PlainpostNodeMailMode
import PlainpostNodeTransport
@testable import PlainpostSecrets
@testable import PlainpostService
@testable import PlainpostServiceIPC

/// The service's reachability composition: the supervisor probes through the
/// one broker, dispatches only while the service runtime is open, and its
/// status is what the app reads over XPC.
final class NodeReachabilityServiceCompositionTests: XCTestCase {
    func testTheRuntimeGateFollowsTheVaultLifecycle() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let closed = await fixture.operations.runtimeIsOpen
        XCTAssertFalse(closed, "nothing dispatches before the runtime opens")
        await fixture.operations.reopenRuntimeConstruction()
        let open = await fixture.operations.runtimeIsOpen
        XCTAssertTrue(open)
        await fixture.operations.beginVaultLockdown()
        let locked = await fixture.operations.runtimeIsOpen
        XCTAssertFalse(locked, "a vault lockdown closes the gate")
    }

    func testTheSupervisorProbesThroughTheBrokerAndReportsItsStatusOverXPC() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let sender = StatusRecordingSender()
        let broker = NodeSessionBroker(resolveSender: { (Fixture.nodeID, sender) })
        let router = PlainpostServiceComposition.makeMailIntentRouter(store: fixture.store, direct: ServiceDirectMailDispatcher())
        let mirror = PlainpostServiceComposition.makeNodeMailMirror(store: fixture.store, broker: broker)
        let supervisor = PlainpostServiceComposition.makeNodeReachabilitySupervisor(
            store: fixture.store, broker: broker, router: router, mirrorLoop: mirror, operations: fixture.operations
        )
        let handlers = PlainpostServiceComposition.nodeSessionHandlers(broker: broker, reachability: supervisor)
        await PlainpostServiceComposition.startNodeMailMode(router: router, mirror: nil, reachability: supervisor)
        let deadline = ContinuousClock.now + .seconds(10)
        while !sender.paths.contains("GET /v1/status"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sender.paths.contains("GET /v1/status"), "the probe went through the broker's session")
        let status = try XCTUnwrap(handlers.mailModeStatus)
        let reported = await status()
        XCTAssertEqual(reported.nodeBackedAccountCount, 1)
        XCTAssertEqual(reported.state, .connected, "one failed probe is not a fallback")
        await PlainpostServiceComposition.stopNodeMailMode(mirror: nil, reachability: supervisor)
        let count = sender.paths.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sender.paths.count, count, "no probe after stop")
        XCTAssertEqual(try fixture.store.mailSource(accountID: fixture.accountID).mode, .node)
    }

    private struct Fixture {
        static let nodeID = "40000000-0000-4000-8000-000000000918"
        let directory: URL
        let store: SQLiteMailStore
        let operations: PlainpostServiceOperations
        let accountID: AccountID

        static func make() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("plainpost-service-reachability-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try SQLiteMailStore(path: directory.appendingPathComponent("plainpost.sqlite").path)
            try store.migrate()
            let account = Account(id: AccountID("acc-node"), displayName: "Node", email: EmailAddress("n@example.test"),
                                  imapHost: "imap.example.test", smtpHost: "smtp.example.test")
            try store.cacheAccounts([account])
            let logical = try NodeSyncCodec.encodeLogicalMailboxID(LogicalMailboxID(rawValue: Data(repeating: 0x11, count: 32))!)
            _ = try store.replaceMailSource(AccountMailSource.direct(account.id).nodeBacked(
                nodeID: nodeID, logicalMailboxID: logical, providerIdentity: "n@example.test"), expectedGeneration: 0)
            let assembly = SQLiteCredentialVaultAssembly(store: store, provider: ReachabilityVaultKeyProvider())
            let operations = PlainpostServiceOperations(
                applicationSupportURL: directory, store: store, assembly: assembly,
                backgroundJobWakeScheduler: ReachabilityNoopWakeScheduler(),
                mailMonitorFactory: { _ in ReachabilityNoopMailMonitor() }
            )
            return Fixture(directory: directory, store: store, operations: operations, accountID: account.id)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Answers every request 503 (an unavailable Node).
private final class StatusRecordingSender: NodeSessionRequestSending, NodePendingRequestReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        lock.withLock { stored.append(method + " " + path) }
        return NodeHTTPResponse(statusCode: 503, url: URL(string: "https://node.example.ts.net:443")!, headers: [:], body: Data())
    }
}

private struct ReachabilityVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { Data(repeating: 0x45, count: 32) }
    func countMatchingItems() async throws -> Int { 1 }
}

private actor ReachabilityNoopMailMonitor: ServiceMailMonitoring {
    func start() {}
    func stop() {}
}

private struct ReachabilityNoopWakeScheduler: BackgroundJobWakeScheduling {
    func replaceWake(at date: Date?, action: @escaping @Sendable () async -> Void) async {}
}
