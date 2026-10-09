import Foundation
import XCTest
import PlainpostAccountRuntime
import PlainpostNodeMailMode
@testable import PlainpostSecrets
@testable import PlainpostService
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

final class NodeSessionServiceCompositionTests: XCTestCase {
    private let shared = PlainpostAccountSharedKeychain.accessGroup

    // A Mac that has not signed in, or whose app has not activated an
    // account yet, still runs the service: Node session calls fail typed and
    // closed, and the mail XPC surface stays available.
    func testServiceStartsCleanlyWithoutAnAccountSession() async throws {
        let accountSecrets = InMemoryAccountSecretStore()
        let broker = NodeSessionBroker.production(
            credentials: AccountCredentialStore(secretStore: accountSecrets, service: #function, accessGroup: shared),
            configurationStore: KeychainCentralServerConfigurationStore(secretStore: InMemoryAccountSecretStore(), accessGroup: shared),
            endpointStore: try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore(), accessGroup: shared)
        )
        let handlers = PlainpostServiceComposition.nodeSessionHandlers(broker: broker)
        let listener = PlainpostServiceListener(
            lifecycleCoordinator: PlainpostServiceLifecycleCoordinator(
                vaultSession: VaultSession(provider: UnlockedVaultKeyProvider()),
                prepareForegroundUnlock: {},
                beginVaultLockdown: {},
                confirmVaultLocked: {},
                reopenRuntimeConstruction: {}
            ),
            nodeSession: handlers
        )
        let app = listener.exportedService(for: .app)

        let request = try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()).dto()
        let performed: (PlainpostNodeSessionResponseDTO?, PlainpostXPCErrorDTO?) = await withCheckedContinuation { continuation in
            app.performNodeSessionRequest(request) { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertNil(performed.0)
        XCTAssertEqual(performed.1.map(PlainpostServiceClientError.init(dto:)), .nodeSession(.noActiveSession))

        let readiness: (String?, PlainpostXPCErrorDTO?) = await withCheckedContinuation { continuation in
            app.nodeSessionIdentityReadiness { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertEqual(readiness.0, PlainpostNodeSessionIdentityReadiness.noSession.rawValue)
        XCTAssertNil(readiness.1)

        let status: (PlainpostVaultStatusDTO?, PlainpostXPCErrorDTO?) = await withCheckedContinuation { continuation in
            app.status { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertNotNil(status.0, "mail XPC stays available without a Node session")
        XCTAssertNil(status.1)
        XCTAssertTrue(accountSecrets.records.isEmpty, "the service never writes account Keychain items")
    }

    func testBrokerFailuresCrossXPCAsTypedNodeSessionFailures() async throws {
        let broker = NodeSessionBroker(resolveSender: { throw NodeSessionBrokerError.noEnrolledNode })
        let handlers = PlainpostServiceComposition.nodeSessionHandlers(broker: broker)
        do {
            _ = try await handlers.perform(try PlainpostNodeSessionRequest(method: "GET", path: "/v1/status", body: Data()))
            XCTFail("proxied without a Node")
        } catch let error as PlainpostServiceClientError { XCTAssertEqual(error, .nodeSession(.noEnrolledNode)) }
        do {
            _ = try await handlers.perform(try PlainpostNodeSessionRequest(method: "POST", path: "/v1/mutations", body: Data()))
            XCTFail("the app reached the mutation route")
        } catch let error as PlainpostServiceClientError { XCTAssertEqual(error, .nodeSession(.pathNotAllowed)) }
    }
}

private struct UnlockedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { Data(repeating: 0x44, count: 32) }
    func countMatchingItems() async throws -> Int { 1 }
}
