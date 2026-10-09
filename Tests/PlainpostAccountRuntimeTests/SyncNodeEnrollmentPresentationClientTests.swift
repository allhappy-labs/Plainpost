import Foundation
import XCTest
@testable import PlainpostNodeTransport

final class SyncNodeEnrollmentPresentationClientTests: XCTestCase {
    private let endpoint = try! NodeEndpointURL("https://node.tail1234.ts.net:18443")
    private let capabilityID = Data((1 ... 16).map(UInt8.init))
    private let capability = Data(repeating: 0xa5, count: 32)
    private let canonicalResponse = #"{"claimFingerprint":"123456","claimProofSignature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expiresAt":"2099-01-02T03:04:05Z","kind":"sync-node.enrollment-presentation.v1","setupCode":"AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"# + "\n"

    func testClientBuildsFixedProtectedRequestAndDecodesGoWire() async throws {
        let transport = PresentationRecordingTransport(response: NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data(canonicalResponse.utf8)))
        let cleared = LockedDataSnapshots()
        let client = SyncNodeEnrollmentPresentationClient(client: NodeTLSClient(transport: transport), clock: { Date(timeIntervalSince1970: 4_000_000_000) }, sensitiveBufferCleared: cleared.record)
        let request = try SyncNodeEnrollmentPresentationRequest(endpoint: endpoint, capabilityID: capabilityID, capability: capability)
        let presentation = try await client.fetch(request)
        XCTAssertEqual(presentation.setupCode, "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(presentation.claimProofSignature, Data(repeating: 0, count: 64))
        XCTAssertEqual(presentation.claimFingerprint, "123456")

        let capturedValue = await transport.captured()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.maximumResponseBytes, 1024)
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.url?.absoluteString, "https://node.tail1234.ts.net:18443/v1/bootstrap/enrollment-presentation")
        XCTAssertEqual(captured.request.httpBody, Data())
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Authorization"), "Plainpost-Bootstrap-v1 AQIDBAUGBwgJCgsMDQ4PEA.paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaU")
        XCTAssertTrue(cleared.values().allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == 0 } })
    }

    func testRequestAndPresentationRequireExactCanonicalNonzeroValues() throws {
        XCTAssertNoThrow(try SyncNodeEnrollmentPresentationRequest(endpoint: endpoint, capabilityID: capabilityID, capability: capability))
        for (name, id, secret) in [
            ("short ID", Data(repeating: 1, count: 15), capability),
            ("zero ID", Data(repeating: 0, count: 16), capability),
            ("short capability", capabilityID, Data(repeating: 1, count: 31)),
            ("zero capability", capabilityID, Data(repeating: 0, count: 32)),
        ] {
            XCTAssertThrowsError(try SyncNodeEnrollmentPresentationRequest(endpoint: endpoint, capabilityID: id, capability: secret), name)
        }
        XCTAssertThrowsError(try SyncNodeEnrollmentPresentation(setupCode: "bad", expiresAt: Date(timeIntervalSince1970: 4_000_000_001), claimProofSignature: Data(repeating: 1, count: 64), claimFingerprint: "123456"))
        XCTAssertThrowsError(try SyncNodeEnrollmentPresentation(setupCode: "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", expiresAt: Date(timeIntervalSince1970: 4_000_000_001), claimProofSignature: Data(repeating: 1, count: 63), claimFingerprint: "123456"))
        XCTAssertThrowsError(try SyncNodeEnrollmentPresentation(setupCode: "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", expiresAt: Date(timeIntervalSince1970: 4_000_000_001), claimProofSignature: Data(repeating: 1, count: 64), claimFingerprint: "12345x"))
    }

    func testClientRejectsOpenNoncanonicalExpiredOversizedRedirectedAndSubstitutedResponses() async throws {
        let base = String(canonicalResponse.dropLast())
        let invalidResponses: [(String, NodeHTTPResponse)] = [
            ("unknown", response(base.replacingOccurrences(of: #"{"claimFingerprint"#, with: #"{"additional":true,"claimFingerprint"#))),
            ("duplicate", response(base.replacingOccurrences(of: #"{"claimFingerprint":"123456"#, with: #"{"claimFingerprint":"123456","claimFingerprint":"123456"#))),
            ("trailing space", response(base + " ")),
            ("two newlines", response(base + "\n\n")),
            ("expired", response(base.replacingOccurrences(of: "2099-01-02T03:04:05Z", with: "2020-01-02T03:04:05Z"))),
            ("wrong content type", NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: Data(canonicalResponse.utf8))),
            ("missing no-store", NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: ["Content-Type": "application/json"], body: Data(canonicalResponse.utf8))),
            ("oversized", NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data(repeating: 0x78, count: 1025))),
            ("redirect", NodeHTTPResponse(statusCode: 302, url: endpoint.url, headers: [:], body: Data())),
            ("changed host", NodeHTTPResponse(statusCode: 200, url: URL(string: "https://other.tail1234.ts.net:18443/v1/bootstrap/enrollment-presentation")!, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data(canonicalResponse.utf8))),
            ("changed port", NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.tail1234.ts.net:18444/v1/bootstrap/enrollment-presentation")!, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data(canonicalResponse.utf8))),
        ]
        for (name, response) in invalidResponses {
            let client = SyncNodeEnrollmentPresentationClient(client: NodeTLSClient(transport: PresentationRecordingTransport(response: response)), clock: { Date(timeIntervalSince1970: 4_000_000_000) })
            await XCTAssertThrowsErrorAsync(try await client.fetch(try SyncNodeEnrollmentPresentationRequest(endpoint: self.endpoint, capabilityID: self.capabilityID, capability: self.capability)), name)
        }
    }

    func testClientPreservesTaskCancellation() async throws {
        let client = SyncNodeEnrollmentPresentationClient(client: NodeTLSClient(transport: PresentationCancellationTransport()), clock: Date.init)
        do {
            _ = try await client.fetch(try SyncNodeEnrollmentPresentationRequest(endpoint: endpoint, capabilityID: capabilityID, capability: capability))
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation normalized to \(error)")
        }
    }

    private func response(_ wire: String) -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: 200, url: endpoint.url, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data(wire.utf8))
    }
}

private actor PresentationRecordingTransport: NodeHTTPTransport {
    struct Capture { let request: URLRequest; let maximumResponseBytes: Int }
    private let response: NodeHTTPResponse
    private var capture: Capture?
    init(response: NodeHTTPResponse) { self.response = response }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        capture = Capture(request: request, maximumResponseBytes: maximumResponseBytes)
        return response
    }
    func captured() -> Capture? { capture }
}

private struct PresentationCancellationTransport: NodeHTTPTransport {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse { throw CancellationError() }
}

private final class LockedDataSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Data] = []
    func record(_ value: Data) { lock.lock(); snapshots.append(value); lock.unlock() }
    func values() -> [Data] { lock.lock(); defer { lock.unlock() }; return snapshots }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error \(message)", file: file, line: line)
    } catch {
    }
}
