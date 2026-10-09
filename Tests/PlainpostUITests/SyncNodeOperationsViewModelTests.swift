import XCTest
import PlainpostAccountRuntime
@testable import PlainpostUI

final class SyncNodeOperationsViewModelTests: XCTestCase {
    @MainActor
    func testSettingsOperationsExposeOnlySafeStateAndRequireExactEraseConfirmation() {
        let model = SyncNodeSettingsViewModel(
            snapshot: SyncNodeSettingsSnapshot(
                version: "node", reachability: "Reachable", syncLag: "0 seconds",
                storage: "managed", provider: "Google", mailboxAssignments: [],
                backup: "verified", endpoint: "session-scoped", updateStatus: "ready"
            )
        )
        XCTAssertTrue(model.upgradeReady)
        XCTAssertFalse(model.secretFreeDescription.contains("/var/lib"))
        XCTAssertFalse(model.secretFreeDescription.contains("credential"))
        XCTAssertEqual(model.eraseConfirmation, SyncNodeOperationsController.eraseConfirmation)
    }
}
