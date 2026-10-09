import Darwin
import Foundation
import XCTest
@testable import PlainpostLocalServer
@testable import PlainpostUI

final class LocalAPIServerOwnershipCoordinatorTests: XCTestCase {
    func testActivateReturnsPassiveForExactLockContention() throws {
        let server = ScriptedLocalAPIServer([
            .failure(.init(operation: "acquire lifecycle lock", code: EAGAIN)),
        ])
        let coordinator = LocalAPIServerOwnershipCoordinator(server: server)

        try coordinator.activate()

        XCTAssertEqual(coordinator.state, .passive)
        XCTAssertEqual(server.startCount, 1)
        XCTAssertEqual(server.stopCount, 0)
    }

    func testActivateRethrowsNonContentionError() {
        let server = ScriptedLocalAPIServer([
            .failure(.init(operation: "bind socket", code: EADDRINUSE)),
        ])
        let coordinator = LocalAPIServerOwnershipCoordinator(server: server)

        XCTAssertThrowsError(try coordinator.activate()) { error in
            let serverError = error as? LocalAPIUnixServerError
            XCTAssertEqual(serverError?.operation, "bind socket")
            XCTAssertEqual(serverError?.code, EADDRINUSE)
        }
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(server.stopCount, 0)
    }

    func testMaintainOwnershipRetriesAndBecomesOwner() async throws {
        let server = ScriptedLocalAPIServer([
            .failure(.init(operation: "acquire lifecycle lock", code: EACCES)),
            .success,
        ])
        let coordinator = LocalAPIServerOwnershipCoordinator(
            server: server,
            suspendBeforeRetry: {}
        )
        try coordinator.activate()

        await coordinator.maintainOwnership()

        XCTAssertEqual(coordinator.state, .owner)
        XCTAssertEqual(server.startCount, 2)
        XCTAssertEqual(server.stopCount, 0)
    }

    func testMaintainOwnershipStopsAfterNonContentionRetryError() async throws {
        let server = ScriptedLocalAPIServer([
            .failure(.init(operation: "acquire lifecycle lock", code: EAGAIN)),
            .failure(.init(operation: "bind socket", code: EADDRINUSE)),
        ])
        let coordinator = LocalAPIServerOwnershipCoordinator(
            server: server,
            suspendBeforeRetry: {}
        )
        try coordinator.activate()

        await coordinator.maintainOwnership()

        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(server.startCount, 2)
        XCTAssertEqual(server.stopCount, 0)
    }

    func testStopCancelsPendingRetryWithoutStoppingUnownedServer() async throws {
        let server = ScriptedLocalAPIServer([
            .failure(.init(operation: "acquire lifecycle lock", code: EAGAIN)),
        ])
        let retryStarted = expectation(description: "retry sleep started")
        let coordinator = LocalAPIServerOwnershipCoordinator(
            server: server,
            suspendBeforeRetry: {
                retryStarted.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
        )
        try coordinator.activate()
        let maintenance = Task { await coordinator.maintainOwnership() }
        await fulfillment(of: [retryStarted], timeout: 1)

        maintenance.cancel()
        coordinator.stop()
        await maintenance.value

        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertEqual(server.startCount, 1)
        XCTAssertEqual(server.stopCount, 0)
    }
}

private final class ScriptedLocalAPIServer: LocalAPIServerLifecycle, @unchecked Sendable {
    enum StartResult {
        case success
        case failure(LocalAPIUnixServerError)
    }

    private let lock = NSLock()
    private var results: [StartResult]
    private var starts = 0
    private var stops = 0

    init(_ results: [StartResult]) {
        self.results = results
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start() throws {
        let result = lock.withLock { () -> StartResult in
            starts += 1
            return results.isEmpty ? .success : results.removeFirst()
        }
        if case .failure(let error) = result {
            throw error
        }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }
}
