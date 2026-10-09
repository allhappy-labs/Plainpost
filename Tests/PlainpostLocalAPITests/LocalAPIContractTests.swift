import XCTest
@testable import PlainpostLocalAPI

final class LocalAPIContractTests: XCTestCase {
    func testUnreadListRequestUsesStableVersionedJSON() throws {
        let request = LocalAPIRequest(
            requestID: "req-1",
            method: .mailUnreadList,
            parameters: LocalAPIUnreadListParameters(limit: 10)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["apiVersion"] as? Int, 1)
        XCTAssertEqual(object["requestID"] as? String, "req-1")
        XCTAssertEqual(object["method"] as? String, "mail.unreadList")
        XCTAssertEqual((object["parameters"] as? [String: Any])?["limit"] as? Int, 10)
    }

    func testNativePayloadLimitIsOneMiB() {
        XCTAssertEqual(LocalAPIProtocol.maximumFrameSize, 1_048_576)
        XCTAssertEqual(LocalAPIProtocol.maximumMessageBodyBytes, 262_144)
    }
}
