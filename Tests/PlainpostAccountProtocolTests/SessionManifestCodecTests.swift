import Foundation
import XCTest
@testable import PlainpostAccountProtocol

final class SessionManifestCodecTests: XCTestCase {
    func testCodecRoundTripsCanonicalFixtureAndMatchesSharedTranscript() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let object = try XCTUnwrap(fixture["manifest"] as? [String: Any])
        let document = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])

        let response = try AccountSessionManifestCodec.decodeResponse(document)

        XCTAssertEqual(try AccountSessionManifestCodec.encodeResponse(response), document)
        XCTAssertEqual(
            AccountSessionManifestCodec.transcript(response.current).map { String(format: "%02x", $0) }.joined(),
            try XCTUnwrap(fixture["manifestTranscriptHex"] as? String)
        )
        XCTAssertEqual(response.current.keys.map(\.purpose), [.access, .offlineLease])
    }

    func testCodecRejectsDuplicateFieldsAndUnsortedKeys() throws {
        XCTAssertThrowsError(try AccountSessionManifestCodec.decodeResponse(Data(#"{"kind":"account.session-key-manifest-response.v1","kind":"account.session-key-manifest-response.v1","current":{}}"#.utf8)))

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Protocol/account-v1/fixtures/session-crypto-vectors-v1.json")
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        var response = try XCTUnwrap(fixture["manifest"] as? [String: Any])
        var current = try XCTUnwrap(response["current"] as? [String: Any])
        current["keys"] = Array(try XCTUnwrap(current["keys"] as? [[String: Any]]).reversed())
        response["current"] = current

        XCTAssertThrowsError(try AccountSessionManifestCodec.decodeResponse(try JSONSerialization.data(withJSONObject: response)))
    }
}
