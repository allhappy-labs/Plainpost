import XCTest
@testable import PlainpostUI

final class OptimisticMutationCoordinatorTests: XCTestCase {
    @MainActor
    func testTracksPendingMutationsIndependentlyByKey() {
        let coordinator = OptimisticMutationCoordinator<String>()

        let delete = coordinator.begin(for: "msg_delete")
        let archive = coordinator.begin(for: "msg_archive")

        XCTAssertTrue(coordinator.isPending("msg_delete"))
        XCTAssertTrue(coordinator.isPending("msg_archive"))
        XCTAssertEqual(coordinator.resolve(delete, as: .committed), .committed)
        XCTAssertFalse(coordinator.isPending("msg_delete"))
        XCTAssertTrue(coordinator.isPending("msg_archive"))
    }

    @MainActor
    func testOlderTokenCannotResolveANewerMutationForTheSameKey() {
        let coordinator = OptimisticMutationCoordinator<String>()
        let older = coordinator.begin(for: "msg_1")
        let newer = coordinator.begin(for: "msg_1")

        XCTAssertEqual(coordinator.resolve(older, as: .rolledBack), .superseded)
        XCTAssertTrue(coordinator.isPending("msg_1"))
        XCTAssertEqual(coordinator.resolve(newer, as: .committed), .committed)
        XCTAssertFalse(coordinator.isPending("msg_1"))
    }

    @MainActor
    func testIsSupersededOnlyWhileANewerMutationForTheKeyIsPending() {
        let coordinator = OptimisticMutationCoordinator<String>()
        let older = coordinator.begin(for: "msg_1")
        let other = coordinator.begin(for: "msg_2")

        XCTAssertFalse(coordinator.isSuperseded(older))
        let newer = coordinator.begin(for: "msg_1")
        XCTAssertTrue(coordinator.isSuperseded(older))
        XCTAssertFalse(coordinator.isSuperseded(newer))
        XCTAssertFalse(coordinator.isSuperseded(other))

        coordinator.resolve(newer, as: .committed)
        XCTAssertFalse(coordinator.isSuperseded(newer))
    }
}
