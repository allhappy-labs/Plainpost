import CryptoKit
import Foundation
import XCTest
@testable import PlainpostAccountProtocol
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport

final class NodeCalendarSignedTransportTests: XCTestCase {
    func testWindowOverOneMiBTraversesRealSignedTLSAndRetainedReplay() async throws {
        for ambiguous in [false, true] {
            let fixture = try CalendarSignedFixture()
            let (request, response) = try windowFixture()
            XCTAssertGreaterThan(response.count, 1_048_576)
            let network = CalendarWireProbe(body: response, failFirst: ambiguous)
            let sender = try fixture.sender(network)
            let result = try await NodeCalendarClient(sender: sender).window(request)
            XCTAssertEqual(result.events.count, 3)
            let calls = await network.calls
            XCTAssertEqual(calls.count, ambiguous ? 2 : 1)
            XCTAssertTrue(calls.allSatisfy { $0.limit == 8 * 1_048_576 })
            for call in calls {
                XCTAssertEqual(call.request.url?.path, "/v1/calendar/window")
                let header = try XCTUnwrap(call.request.value(forHTTPHeaderField: "Plainpost-Signed-Request"))
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String])
                XCTAssertEqual(fields["sequence"], "1")
                XCTAssertEqual(fields["bodySHA256"], NodeSessionWire.encodeBase64URL(Data(SHA256.hash(data: call.request.httpBody!))))
                let signed = try SignedRequestV1(accountID: fixture.reference.accountID.rawValue, clientID: fixture.clientID.rawValue, nodeID: fixture.reference.nodeID.rawValue, trustEpoch: 1, audience: fields["audience"]!, sequence: 1, method: "POST", path: fields["path"]!, bodySHA256: NodeSessionWire.decodeBase64URL(fields["bodySHA256"]!), issuedAt: fields["issuedAt"]!, signature: NodeSessionWire.decodeBase64URL(fields["signature"]!))
                let key = try P256.Signing.PublicKey(x963Representation: fixture.identity.publicBundle.signingKey)
                XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signed.signature), for: try NodeSessionTranscript.request(signed)))
            }
            if ambiguous { XCTAssertEqual(calls[0].request.httpBody, calls[1].request.httpBody) }
            XCTAssertNil(try fixture.store.loadPending(for: fixture.reference))
            XCTAssertEqual(try fixture.store.load(for: fixture.reference).nextSequence, 2)
        }
    }

    func testPreflightConsumedResultRemainsDeliveryUncertain() async throws {
        let fixture = try CalendarSignedFixture()
        let body = Data(#"{"status":409,"type":"urn:plainpost:node-sequence-consumed"}"#.utf8)
        let network = CalendarWireProbe(body: body, failFirst: true, status: 409)
        let sender = try fixture.sender(network)
        do { _ = try await sender.send(method: "POST", path: "/v1/calendar/commands", body: Data("original".utf8)); XCTFail("expected dispatch ambiguity") }
        catch let error as NodeSessionError { XCTAssertEqual(error, .transportFailureAfterDispatch) }
        do { _ = try await NodeCalendarClient(sender: sender).capabilities(); XCTFail("expected uncertain application result") }
        catch let error as NodeCalendarError { XCTAssertEqual(error, .deliveryUncertain) }
        let calls = await network.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.request.url?.path == "/v1/calendar/commands" })
    }

    func testLargeAllowanceIsRestrictedToCalendarWindowAndRequestCapRemains() async throws {
        for (method, path, body, limit) in [
            ("POST", "/v1/calendar/commands", Data(), 8 * 1_048_576),
            ("GET", "/v1/calendar/window", Data(), 8 * 1_048_576),
            ("POST", "/v1/calendar/window?extra=1", Data(), 8 * 1_048_576),
            ("POST", "/v1/calendar/window", Data(), 8 * 1_048_576 + 1),
            ("POST", "/v1/calendar/window", Data(repeating: 0, count: NodeSessionLimits.maximumRequestBodyBytes + 1), 8 * 1_048_576),
        ] {
            let fixture = try CalendarSignedFixture()
            let network = CalendarWireProbe(body: Data(), failFirst: false)
            let sender = try fixture.sender(network)
            do { _ = try await sender.send(method: method, path: path, body: body, maximumResponseBytes: limit); XCTFail("invalid route allowance accepted") } catch {}
            let calls = await network.calls
            XCTAssertTrue(calls.isEmpty)
            XCTAssertNil(try fixture.store.loadPending(for: fixture.reference))
        }
    }

    private func windowFixture() throws -> (NodeCalendarWindowRequest, Data) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Protocol/node-calendar-v1/fixtures/protocol-v1.json"))) as? [String: Any])
        let families = try XCTUnwrap(object["families"] as? [String: String])
        let request: NodeCalendarWindowRequest = try NodeCalendarCodec.decodeFamily(Data(families["windowRequest"]!.utf8), kind: "window-request")
        var response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(families["windowResult"]!.utf8)) as? [String: Any])
        response["nextCursor"] = ""
        let event = try XCTUnwrap((response["events"] as? [[String: Any]])?.first)
        response["events"] = (0..<3).map { index in
            var copy = event; copy["id"] = "event-\(index)"; copy["notes"] = String(repeating: "x", count: 600_000); return copy
        }
        return (request, try JSONSerialization.data(withJSONObject: response))
    }
}

private struct CalendarSignedFixture {
    let store: SyncNodeEndpointStore
    let reference: SyncNodeEndpointReference
    let identity: AccountDeviceIdentity
    let clientID: AccountDeviceID
    init() throws {
        store = try SyncNodeEndpointStore(secretStore: InMemoryAccountSecretStore(), service: "test.calendar-signed")
        clientID = try AccountDeviceID("33333333-3333-4333-8333-333333333333")
        identity = try AccountDeviceIdentity(signingPrivateKey: Data(repeating: 0, count: 31) + Data([7]), agreementPrivateKey: Data(repeating: 0, count: 31) + Data([8]))
        reference = try SyncNodeEndpointReference(accountID: PlainpostAccountID("11111111-1111-4111-8111-111111111111"), nodeID: AccountDeviceID("22222222-2222-4222-8222-222222222222"), trustEpoch: AccountTrustEpoch(wire: "1"), endpointCiphertext: Data(repeating: 1, count: 48))
        try store.save(reference: reference, session: SyncNodeStoredSession(resultWire: Data([1]), refreshWire: Data([2]), leaseWire: Data([3]), trustCommitWire: Data([4]), admissionEvidenceWire: Data([5]), cleanupCapabilityWire: Data([6]), nextSequence: 1))
    }
    func sender(_ network: CalendarWireProbe) throws -> NodeSessionTransport {
        try NodeSessionTransport(reference: reference, clientID: clientID, endpoint: NodeEndpointURL("https://node.tail1234.ts.net:8443"), store: store, identity: identity, client: NodeTLSClient(transport: network))
    }
}
private actor CalendarWireProbe: NodeHTTPTransport {
    struct Call: Sendable { let request: URLRequest; let limit: Int }
    private(set) var calls: [Call] = []
    let body: Data
    let failFirst: Bool
    let status: Int
    init(body: Data, failFirst: Bool, status: Int = 200) { self.body = body; self.failFirst = failFirst; self.status = status }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls.append(Call(request: request, limit: maximumResponseBytes))
        if failFirst && calls.count == 1 { throw NodeSessionError.transportFailure }
        guard body.count <= maximumResponseBytes else { throw NodeSessionError.invalidValue }
        return NodeHTTPResponse(statusCode: status, url: request.url!, headers: [:], body: body)
    }
}
