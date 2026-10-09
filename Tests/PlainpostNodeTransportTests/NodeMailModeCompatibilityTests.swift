import XCTest
import PlainpostAccountProtocol
@testable import PlainpostNodeTransport

final class NodeMailModeCompatibilityTests: XCTestCase {
    func testMissingCapabilitiesRouteMeansUpdateRequired() async throws {
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail/capabilities"))
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 404, url: url, headers: [:], body: Data())])
        let result = await NodeMailModeCompatibility.probe(NodeSyncClient(sender: sender))
        XCTAssertEqual(result, .updateRequired)
        let requests = await sender.requests()
        XCTAssertEqual(requests.map(\.path), ["/v1/mail/capabilities"])
    }

    func testServerErrorIsUnavailableNotUpdateRequired() async throws {
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail/capabilities"))
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 503, url: url, headers: [:], body: Data())])
        let result = await NodeMailModeCompatibility.probe(NodeSyncClient(sender: sender))
        XCTAssertEqual(result, .unavailable)
    }

    func testDecodedCapabilitiesAreCompatible() async throws {
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail/capabilities"))
        let capabilities = NodeSyncMailCapabilities(googleImport: true, imapImport: true, mirrorCoordinates: false, multiAccount: true)
        let body = try NodeSyncMailModeCodec.encodeMailCapabilities(capabilities)
        let sender = RecordingNodeSessionSender(responses: [NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: body)])
        let result = await NodeMailModeCompatibility.probe(NodeSyncClient(sender: sender))
        XCTAssertEqual(result, .compatible(capabilities))
    }

    func testUnauthorizedAndUndecodableCapabilitiesAreUnavailable() async throws {
        let url = try XCTUnwrap(URL(string: "https://node.example.ts.net/v1/mail/capabilities"))
        let future = Data(#"{"googleImport":true,"imapImport":true,"kind":"node-sync.mail-capabilities.v1","mirrorCoordinates":true,"multiAccount":true,"version":"2"}"#.utf8)
        for response in [
            NodeHTTPResponse(statusCode: 401, url: url, headers: [:], body: Data()),
            NodeHTTPResponse(statusCode: 200, url: url, headers: [:], body: future),
        ] {
            let sender = RecordingNodeSessionSender(responses: [response])
            let result = await NodeMailModeCompatibility.probe(NodeSyncClient(sender: sender))
            XCTAssertEqual(result, .unavailable)
        }
    }
}
