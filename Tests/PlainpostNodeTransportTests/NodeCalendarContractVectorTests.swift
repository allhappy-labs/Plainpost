import CryptoKit
import Foundation
import XCTest
@testable import PlainpostNodeTransport

private struct CalendarContractExpansion: Decodable {
    let token: String
    let unit: String?
    let unitHex: String?
    let count: Int
    let separator: String?
}

private struct CalendarContractCase: Decodable {
    let name: String
    let family: String
    let expect: String
    let reason: String
    let wire: String
    let expand: [CalendarContractExpansion]?
    let canonical: Bool?
}

private struct CalendarContractRoute: Decodable {
    let method: String
    let path: String
    let request: String
    let result: String
    let bodyLimit: Int
}

private struct CalendarContractFixture: Decodable {
    let families: [String: String]
    let routes: [CalendarContractRoute]
    let cases: [CalendarContractCase]
}

private struct CalendarLegacyContractReceiptRequest: Codable { let operationID: String }
private struct CalendarLegacyContractInvitationRequest: Codable { let id: String }
private struct CalendarLegacyContractInvitation: Codable { let id, eventID, messageID, uid, organizer, attendeeAddress, recurrenceID, method, revision: String; let state: NodeCalendarInvitationState; let sequence: UInt64; let stamp: String }
private struct CalendarLegacyContractInvitationResult: Codable { let invitation: CalendarLegacyContractInvitation }

private let calendarProtocolRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-calendar-v1")

private func calendarContractFixture() throws -> CalendarContractFixture {
    try JSONDecoder().decode(CalendarContractFixture.self, from: Data(contentsOf: calendarProtocolRoot.appendingPathComponent("fixtures/protocol-v1.json")))
}

private func expandedWire(_ contractCase: CalendarContractCase) -> Data {
    var data = Data(contractCase.wire.utf8)
    for expansion in contractCase.expand ?? [] {
        let unit: Data
        if let hex = expansion.unitHex {
            unit = Data(stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
        } else {
            unit = Data((expansion.unit ?? "").utf8)
        }
        var joined = Data()
        for index in 0..<expansion.count {
            if index > 0 { joined.append(Data((expansion.separator ?? "").utf8)) }
            let indexed = Data(String(format: "%05d", index).utf8)
            joined.append(unit.replacingOccurrences(of: Data("{i}".utf8), with: indexed))
        }
        data = data.replacingOccurrences(of: Data(expansion.token.utf8), with: joined)
    }
    return data
}

private extension Data {
    func replacingOccurrences(of target: Data, with replacement: Data) -> Data {
        guard !target.isEmpty else { return self }
        var result = Data()
        result.reserveCapacity(count)
        var searchStart = startIndex
        while let found = self[searchStart...].firstRange(of: target) {
            result.append(self[searchStart..<found.lowerBound])
            result.append(replacement)
            searchStart = found.upperBound
        }
        result.append(self[searchStart...])
        return result
    }
}

/// Decodes one shared vector with the native codec and returns its canonical bytes.
func calendarContractCanonical(family: String, data: Data) throws -> Data {
    func decodeKind<T: Codable>(_ type: T.Type, _ kind: String) throws -> Data {
        let value: T = try NodeCalendarCodec.decodeFamily(data, kind: kind)
        return try NodeCalendarCodec.encodeFamily(value, kind: kind, limit: NodeCalendarCodec.windowResponseLimit)
    }
    switch family {
    case "receipt":
        let value = try NodeCalendarCodec.decodeReceipt(data)
        return try NodeCalendarCodec.encodeDefinition(value, definition: "receipt")
    case "capabilities": return try decodeKind(NodeCalendarCapabilities.self, "capabilities")
    case "connectionsRequest": return try decodeKind(NodeCalendarConnectionsRequest.self, "connections-request")
    case "connectionsResult": return try decodeKind(NodeCalendarConnectionsResult.self, "connections-result")
    case "connectionRequest", "caldavConnectionRequest": return try decodeKind(NodeCalendarConnectionRequest.self, "connection-command")
    case "disconnectRequest": return try decodeKind(NodeCalendarDisconnectCommand.self, "disconnect-command")
    case "connectionResult": return try decodeKind(NodeCalendarConnectionResult.self, "connection-result")
    case "eventRequest": return try decodeKind(NodeCalendarEventRequest.self, "event-request")
    case "eventResult": return try decodeKind(NodeCalendarEventResult.self, "event-result")
    case "windowRequest": return try decodeKind(NodeCalendarWindowRequest.self, "window-request")
    case "windowResult": return try decodeKind(NodeCalendarWindowSnapshot.self, "window-result")
    case "commandRequest": return try decodeKind(NodeCalendarCommandRequest.self, "command-request")
    case "commandResult": return try decodeKind(NodeCalendarCommandResult.self, "command-result")
    case "operationReadRequest": return try decodeKind(NodeCalendarOperationReadRequest.self, "operation-read-request")
    case "operationReadResult": return try decodeKind(NodeCalendarOperationReadResult.self, "operation-read-result")
    case "invitationReadRequest": return try decodeKind(NodeCalendarInvitationReadRequest.self, "invitation-read-request")
    case "invitationReadResult": return try decodeKind(NodeCalendarInvitationReadResult.self, "invitation-read-result")
    case "receiptRequest": return try decodeKind(CalendarLegacyContractReceiptRequest.self, "receipt-request")
    case "receiptResult": return try decodeKind(NodeCalendarCommandResult.self, "receipt-result")
    case "invitationRequest": return try decodeKind(CalendarLegacyContractInvitationRequest.self, "invitation-request")
    case "invitationResult": return try decodeKind(CalendarLegacyContractInvitationResult.self, "invitation-result")
    default: throw NodeCalendarError.unsupported
    }
}

final class NodeCalendarContractVectorTests: XCTestCase {
    /// Proves the native codec's accept/reject decision and canonical bytes for
    /// every shared vector. The contract runner compares the emitted digest list
    /// with the Go Node codec's list.
    func testEverySharedContractVector() throws {
        let fixture = try calendarContractFixture()
        XCTAssertGreaterThan(fixture.cases.count, 1000)
        var report = ""
        var failures = 0
        for contractCase in fixture.cases {
            let data = expandedWire(contractCase)
            var line = contractCase.name
            var accepted = false
            do {
                let canonical = try calendarContractCanonical(family: contractCase.family, data: data)
                accepted = true
                let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
                line += "\taccept\t\(digest)\t\(canonical.count)"
                if contractCase.canonical == true && canonical != data {
                    failures += 1
                    XCTFail("\(contractCase.name): canonical bytes differ (\(contractCase.reason))")
                }
            } catch {
                line += "\treject"
            }
            report += line + "\n"
            if (accepted ? "accept" : "reject") != contractCase.expect {
                failures += 1
                XCTFail("\(contractCase.name): got \(accepted ? "accept" : "reject"), want \(contractCase.expect) (\(contractCase.reason))")
            }
            if failures > 40 { XCTFail("too many contract vector failures"); break }
        }
        if let path = ProcessInfo.processInfo.environment["PLAINPOST_CALENDAR_VECTOR_OUTPUT"], !path.isEmpty {
            try Data(report.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// The native transport embeds an exact copy of the authoritative schema.
    func testEmbeddedSchemaMatchesProtocol() throws {
        let authoritative = try String(contentsOf: calendarProtocolRoot.appendingPathComponent("node-calendar.schema.json"), encoding: .utf8)
        XCTAssertEqual(NodeCalendarSchemaSource.json + "\n", authoritative, "Sources/PlainpostNodeTransport/NodeCalendarSchema.swift differs from Protocol/node-calendar-v1/node-calendar.schema.json")
    }

    /// Every native request and result encoding honors the shared route table.
    func testRouteTableMatchesNativeTransportLimits() throws {
        let fixture = try calendarContractFixture()
        XCTAssertEqual(fixture.routes.count, 9)
        for route in fixture.routes where !route.request.isEmpty {
            let limit = route.path.hasPrefix("/v1/calendar/connections/") ? NodeCalendarCodec.connectionBodyLimit : NodeCalendarCodec.commandBodyLimit
            XCTAssertEqual(limit, route.bodyLimit, route.path)
            let seed = try XCTUnwrap(fixture.families[route.request].map { Data($0.utf8) })
            XCTAssertEqual(try calendarContractCanonical(family: route.request, data: seed), seed, route.path)
            let result = try XCTUnwrap(fixture.families[route.result].map { Data($0.utf8) })
            XCTAssertEqual(try calendarContractCanonical(family: route.result, data: result), result, route.path)
        }
    }
}
