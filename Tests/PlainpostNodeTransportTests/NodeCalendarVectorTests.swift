import Foundation
import XCTest
@testable import PlainpostNodeTransport

final class NodeCalendarVectorTests: XCTestCase {
    func testReceiptKeepsCalendarAndDeliverySeparate() throws {
        let raw = Data(#"{"operationID":"op-1","owner":"email","calendar":"confirmed","delivery":"pending","code":"","eventID":"e1","revision":"r2"}"#.utf8)
        let receipt = try NodeCalendarCodec.decodeReceipt(raw)
        XCTAssertEqual(receipt.calendar, .confirmed)
        XCTAssertEqual(receipt.delivery, .pending)
    }
    func testReceiptRejectsDuplicateUnknownAndInvalidState() throws {
        let raw = #"{"operationID":"op-1","owner":"email","calendar":"confirmed","delivery":"pending","code":"","eventID":"e1","revision":"r2"}"#
        for invalid in [raw.replacingOccurrences(of: "{", with: "{\"code\":\"x\","), raw.replacingOccurrences(of: "{", with: "{\"secret\":true,"), raw.replacingOccurrences(of: "confirmed", with: "done")] {
            XCTAssertThrowsError(try NodeCalendarCodec.decodeReceipt(Data(invalid.utf8)))
        }
    }
}

private struct CalendarLegacyReceiptRequest: Codable { let operationID: String }
private struct CalendarLegacyInvitationRequest: Codable { let id: String }
private struct CalendarLegacyInvitation: Codable { let id, eventID, messageID, uid, organizer, attendeeAddress, recurrenceID, method, revision: String; let state: NodeCalendarInvitationState; let sequence: UInt64; let stamp: String }
private struct CalendarLegacyInvitationResult: Codable { let invitation: CalendarLegacyInvitation }
extension NodeCalendarVectorTests {
    func testEverySharedFixtureAndClosedNegative() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-calendar-v1/fixtures/protocol-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let families = try XCTUnwrap(root["families"] as? [String: String])
        let failures = try XCTUnwrap(root["failures"] as? [String: String])
        XCTAssertEqual(families.count, 22)
        for (name, raw) in families {
            let data = Data(raw.utf8)
            func check<T: Codable>(_ type: T.Type, _ kind: String) throws {
                let value: T = try kind.isEmpty ? NodeCalendarCodec.decode(data) : NodeCalendarCodec.decodeFamily(data, kind: kind)
                let encoded = try kind.isEmpty ? NodeCalendarCodec.encode(value) : NodeCalendarCodec.encodeFamily(value, kind: kind)
                XCTAssertEqual(String(decoding: encoded, as: UTF8.self), raw, name)
                for suffix in ["UnknownField", "DuplicateField", "MissingNullable", "MissingUnknown"] {
                    guard let failure = failures[name + suffix] else {
                        XCTAssertTrue(suffix.hasPrefix("Missing"), name + suffix)
                        continue
                    }
                    let invalid = Data(failure.utf8)
                    XCTAssertThrowsError(try kind.isEmpty ? NodeCalendarCodec.decode(invalid) as T : NodeCalendarCodec.decodeFamily(invalid, kind: kind) as T, name + suffix)
                }
            }
            switch name {
            case "receipt": try check(NodeCalendarReceipt.self, "")
            case "capabilities": try check(NodeCalendarCapabilities.self, "capabilities")
            case "connectionsRequest": try check(NodeCalendarConnectionsRequest.self, "connections-request")
            case "connectionsResult": try check(NodeCalendarConnectionsResult.self, "connections-result")
            case "connectionRequest": try check(NodeCalendarConnectionRequest.self, "connection-command")
            case "caldavConnectionRequest": try check(NodeCalendarConnectionRequest.self, "connection-command")
            case "disconnectRequest": try check(NodeCalendarDisconnectCommand.self, "disconnect-command")
            case "connectionResult": try check(NodeCalendarConnectionResult.self, "connection-result")
            case "eventRequest": try check(NodeCalendarEventRequest.self, "event-request")
            case "eventResult": try check(NodeCalendarEventResult.self, "event-result")
            case "windowRequest": try check(NodeCalendarWindowRequest.self, "window-request")
            case "windowResult": try check(NodeCalendarWindowSnapshot.self, "window-result")
            case "commandRequest": try check(NodeCalendarCommandRequest.self, "command-request")
            case "commandResult": try check(NodeCalendarCommandResult.self, "command-result")
            case "operationReadRequest": try check(NodeCalendarOperationReadRequest.self, "operation-read-request")
            case "operationReadResult": try check(NodeCalendarOperationReadResult.self, "operation-read-result")
            case "invitationReadRequest": try check(NodeCalendarInvitationReadRequest.self, "invitation-read-request")
            case "invitationReadResult": try check(NodeCalendarInvitationReadResult.self, "invitation-read-result")
            case "receiptRequest": try check(CalendarLegacyReceiptRequest.self, "receipt-request")
            case "receiptResult": try check(NodeCalendarCommandResult.self, "receipt-result")
            case "invitationRequest": try check(CalendarLegacyInvitationRequest.self, "invitation-request")
            case "invitationResult": try check(CalendarLegacyInvitationResult.self, "invitation-result")
            default: XCTFail("unhandled fixture: " + name)
            }
        }
    }
}

extension NodeCalendarVectorTests {
    func testNativeInvitationCarriesDetailsAndNullableResolution() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-calendar-v1/fixtures/protocol-v1.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let families = try XCTUnwrap(root["families"] as? [String: String])
        let result: NodeCalendarInvitationReadResult = try NodeCalendarCodec.decodeFamily(Data(try XCTUnwrap(families["invitationReadResult"]).utf8), kind: "invitation-read-result")
        XCTAssertEqual(result.invitations.count, 2)
        let resolved = result.invitations[0], pending = result.invitations[1]
        XCTAssertNotEqual(resolved.eventID, resolved.calendarEventID, "invitation identity is not the stored event ID")
        XCTAssertEqual(resolved.calendarEventID, "event-001")
        XCTAssertEqual(resolved.title, "Planning")
        XCTAssertEqual(resolved.start?.value, "2026-10-25T09:00:00+01:00")
        XCTAssertEqual(resolved.meetingURL, "https://meet.example.test/planning")
        XCTAssertNil(pending.calendarEventID)
        XCTAssertNil(pending.start)
        XCTAssertNil(pending.meetingURL)
    }

    func testOperationReadDistinguishesUnknownOperations() async throws {
        let unknown = #"{"kind":"node-calendar.operation-read-result.v1","receipts":[],"unknownOperationIDs":["never"]}"#
        let response = NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example")!, headers: [:], body: Data(unknown.utf8))
        XCTAssertThrowsError(try NodeCalendarCodec.decodeOperationReadResponse(response, requested: ["never"])) { XCTAssertEqual($0 as? NodeCalendarError, .unknownOperation) }
        XCTAssertThrowsError(try NodeCalendarCodec.decodeOperationReadResponse(response, requested: ["other"])) { XCTAssertEqual($0 as? NodeCalendarError, .invalidResponse, "unknown IDs must be requested IDs") }
        let conflict = NodeHTTPResponse(statusCode: 409, url: URL(string: "https://node.example")!, headers: [:], body: Data())
        XCTAssertThrowsError(try NodeCalendarCodec.decodeOperationReadResponse(conflict, requested: ["never"])) { XCTAssertEqual($0 as? NodeCalendarError, .conflict, "a 409 is never an unknown operation") }
    }
}

extension NodeCalendarVectorTests {
    func testConnectionResultCarriesBoundedSetupCode() throws {
        let wire = Data(#"{"code":"calendar_limit","connection":{"attendeeAddress":"","calendars":[],"delivery":"google","enabled":true,"generation":1,"id":"10000000-0000-4000-8000-000000000001","kind":"google","sendingMailbox":""},"kind":"node-calendar.connection-result.v1","operationID":"op","state":"failed"}"#.utf8)
        let decoded: NodeCalendarConnectionResult = try NodeCalendarCodec.decodeFamily(wire, kind: "connection-result")
        XCTAssertEqual(decoded.code, .calendarLimit)
        let metadata: NodeCalendarConnectionResult = try NodeCalendarCodec.decodeFamily(Data(String(decoding: wire, as: UTF8.self).replacingOccurrences(of: "calendar_limit", with: "calendar_metadata_limit").utf8), kind: "connection-result")
        XCTAssertEqual(metadata.code, .calendarMetadataLimit)
        XCTAssertEqual(try NodeCalendarCodec.encodeFamily(decoded, kind: "connection-result"), wire)
        XCTAssertThrowsError(try NodeCalendarCodec.decodeFamily(Data(String(decoding: wire, as: UTF8.self).replacingOccurrences(of: "calendar_limit", with: "too_many").utf8), kind: "connection-result") as NodeCalendarConnectionResult)
    }
}
