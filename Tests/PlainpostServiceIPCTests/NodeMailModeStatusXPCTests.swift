import Foundation
import XCTest
@testable import PlainpostSecrets
@testable import PlainpostServiceIPC
@testable import PlainpostServiceRuntime

final class NodeMailModeStatusXPCTests: XCTestCase {
    func testStatusDTORoundTripsThroughSecureCodingForEveryState() throws {
        for state in PlainpostNodeMailModeStatus.State.allCases {
            let status = PlainpostNodeMailModeStatus(state: state, nodeBackedAccountCount: 2, waitingIntentCount: 7)
            let archived = try NSKeyedArchiver.archivedData(withRootObject: status.dto(), requiringSecureCoding: true)
            let dto = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: PlainpostNodeMailModeStatusDTO.self, from: archived))
            XCTAssertEqual(try PlainpostNodeMailModeStatus(dto: dto), status)
        }
        XCTAssertEqual(PlainpostNodeMailModeStatus.State.reconnectRequired.rawValue, "reconnect_required")
        XCTAssertEqual(PlainpostNodeMailModeStatus.State.connectedDirectly.rawValue, "connected_directly")
        XCTAssertEqual(PlainpostNodeMailModeStatus.State.updateRequired.rawValue, "update_required")
        XCTAssertEqual(PlainpostNodeMailModeStatus.State.noNode.rawValue, "no_node")
    }

    func testStatusDTORejectsUnknownStatesAndOutOfBoundCounts() {
        XCTAssertNil(PlainpostNodeMailModeStatusDTO(schemaVersion: 1, state: "fallback", nodeBackedAccountCount: 0, waitingIntentCount: 0))
        XCTAssertNil(PlainpostNodeMailModeStatusDTO(schemaVersion: 2, state: "connected", nodeBackedAccountCount: 0, waitingIntentCount: 0))
        XCTAssertNil(PlainpostNodeMailModeStatusDTO(schemaVersion: 1, state: "connected", nodeBackedAccountCount: -1, waitingIntentCount: 0))
        XCTAssertNil(PlainpostNodeMailModeStatusDTO(schemaVersion: 1, state: "connected", nodeBackedAccountCount: 0, waitingIntentCount: 1_000_001))
        XCTAssertNotNil(PlainpostNodeMailModeStatusDTO(schemaVersion: 1, state: "connected", nodeBackedAccountCount: 0, waitingIntentCount: 1_000_000))
    }

    func testDescriptionContainsNoIdentity() throws {
        let status = PlainpostNodeMailModeStatus(state: .connectedDirectly, nodeBackedAccountCount: 1, waitingIntentCount: 3)
        let dto = try status.dto()
        for text in [String(describing: status), String(reflecting: status), String(describing: dto), String(reflecting: dto)] {
            XCTAssertTrue(text.contains("connected_directly"), text)
            for forbidden in ["@", "node_id", "nodeID", "logical", "provider", "token", "password", "path", "/"] {
                XCTAssertFalse(text.contains(forbidden), "\(forbidden) in \(text)")
            }
        }
        // Only the state and two counts cross the boundary.
        let fields = Mirror(reflecting: status).children.compactMap(\.label).sorted()
        XCTAssertEqual(fields, ["nodeBackedAccountCount", "state", "waitingIntentCount"])
    }

    func testOnlyTheAppMayReadTheStatus() {
        for capability in PlainpostClientCapability.allCases {
            XCTAssertEqual(PlainpostClientValidator.permits(.nodeMailModeStatus, for: capability), capability == .app, "\(capability)")
        }
    }

    func testInterfaceAdmitsTheStatusDTOClass() {
        let interface = PlainpostServiceXPCInterface.make()
        let classes = interface.classes(for: #selector(PlainpostServiceXPCProtocol.nodeMailModeStatus(reply:)), argumentIndex: 0, ofReply: true)
        XCTAssertTrue(classes.contains { ($0 as? AnyClass) == PlainpostNodeMailModeStatusDTO.self })
    }

    func testListenerRejectsNonAppCallersAndForwardsTheApp() async throws {
        let recorder = StatusRecorder(status: PlainpostNodeMailModeStatus(state: .reconnectRequired, nodeBackedAccountCount: 1, waitingIntentCount: 2))
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator(), nodeSession: recorder.handlers)
        for capability in PlainpostClientCapability.allCases where capability != .app {
            let answer = await status(listener.exportedService(for: capability))
            XCTAssertNil(answer.status)
            XCTAssertEqual(answer.error?.code, .clientUnauthorized)
        }
        let calls = await recorder.calls
        XCTAssertEqual(calls, 0, "a rejected caller never reaches the supervisor")

        let answer = await status(listener.exportedService(for: .app))
        XCTAssertNil(answer.error)
        let decoded = try PlainpostNodeMailModeStatus(dto: XCTUnwrap(answer.status))
        XCTAssertEqual(decoded.state, .reconnectRequired)
        XCTAssertEqual(decoded.waitingIntentCount, 2)
        let after = await recorder.calls
        XCTAssertEqual(after, 1)
    }

    func testListenerWithoutASupervisorAnswersNoNode() async throws {
        let listener = PlainpostServiceListener(lifecycleCoordinator: makeCoordinator())
        let answer = await status(listener.exportedService(for: .app))
        XCTAssertEqual(try PlainpostNodeMailModeStatus(dto: XCTUnwrap(answer.status)), .noNode)
    }

    private func makeCoordinator() -> PlainpostServiceLifecycleCoordinator {
        PlainpostServiceLifecycleCoordinator(
            vaultSession: VaultSession(provider: StatusLockedVaultKeyProvider()),
            prepareForegroundUnlock: {},
            beginVaultLockdown: {},
            confirmVaultLocked: {},
            reopenRuntimeConstruction: {}
        )
    }

    private func status(_ service: PlainpostServiceXPCProtocol) async -> (status: PlainpostNodeMailModeStatusDTO?, error: PlainpostXPCErrorDTO?) {
        await withCheckedContinuation { continuation in
            service.nodeMailModeStatus { continuation.resume(returning: ($0, $1)) }
        }
    }
}

private actor StatusRecorder {
    private(set) var calls = 0
    private let status: PlainpostNodeMailModeStatus

    init(status: PlainpostNodeMailModeStatus) { self.status = status }

    private func next() -> PlainpostNodeMailModeStatus {
        calls += 1
        return status
    }

    nonisolated var handlers: PlainpostNodeSessionHandlers {
        PlainpostNodeSessionHandlers(
            perform: { _ in throw PlainpostServiceClientError.nodeSession(.unavailable) },
            invalidate: {},
            identityReadiness: { .ready },
            mailModeStatus: { await self.next() }
        )
    }
}

private struct StatusLockedVaultKeyProvider: VaultKeyProvider {
    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { nil }
    func countMatchingItems() async throws -> Int { 1 }
}
