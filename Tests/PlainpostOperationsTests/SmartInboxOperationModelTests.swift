import XCTest
@testable import PlainpostOperations

final class SmartInboxOperationModelTests: XCTestCase {
    func testSmartInboxWorkItemRoundTripsEnrichedClassificationFields() throws {
        let item = PlainpostSmartInboxWorkItem(
            jobID: "job_triage",
            ordinal: 3,
            messageID: "msg_triage",
            sourceFingerprint: "fingerprint",
            state: .completed,
            category: "personal",
            priority: "high",
            requiresAction: true,
            confidence: 0.87,
            errorMessage: nil
        )

        let decoded = try JSONDecoder().decode(
            PlainpostSmartInboxWorkItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.priority, "high")
        XCTAssertEqual(decoded.requiresAction, true)
        XCTAssertEqual(decoded.confidence, 0.87)
    }
}
