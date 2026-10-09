import XCTest

final class Task6UnraidReleaseContractTests: XCTestCase {
    func testGmailGateWithoutExplicitOptInIsIncomplete() {
        let configuration = SyncNodeUnraidReleaseConfiguration(environment: [:])
        XCTAssertEqual(configuration.gateDecision, .incomplete(reason: "gmail-e2e-disabled"))
    }
}
