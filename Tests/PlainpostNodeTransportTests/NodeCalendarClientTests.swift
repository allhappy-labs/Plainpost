import Foundation
import XCTest
@testable import PlainpostNodeTransport

final class NodeCalendarClientTests: XCTestCase {
    func testCapabilitiesUsesSignedSenderAndReconcilesFirst() async throws {
        let sender = CalendarTestSender()
        let client = NodeCalendarClient(sender: sender)
        let result = try await client.capabilities()
        XCTAssertEqual(result.version, 1)
        XCTAssertEqual(result.google, NodeCalendarGoogleAvailability(clientID: "desktop-client.apps.googleusercontent.com"))
        let calls = await sender.calls
        XCTAssertEqual(calls, ["reconcile", "GET /v1/calendar/capabilities"])
    }
    func testStatusIsMappedBeforeDecoding() async throws {
        for (status, expected) in [(404, NodeCalendarError.unsupported), (501, .unsupported), (401, .unauthorized), (403, .unauthorized), (409, .conflict), (503, .unavailable)] {
            let sender = CalendarTestSender(status: status)
            do { _ = try await NodeCalendarClient(sender: sender).capabilities(); XCTFail("accepted status") }
            catch let error as NodeCalendarError { XCTAssertEqual(error, expected) }
        }
    }
    /// A response that must name its destination calendar is a distinct,
    /// bounded refinement of a conflict; the command omits an unset target.
    func testTargetCalendarRequiredProblemAndOptionalTarget() throws {
        let url = URL(string: "https://node.example.test/v1/calendar/commands")!
        let coded = NodeHTTPResponse(statusCode: 409, url: url, headers: [:], body: Data(#"{"category":"conflict","code":"target_calendar_required","kind":"node-calendar.problem.v1"}"#.utf8))
        XCTAssertThrowsError(try NodeCalendarCodec.validateStatus(coded)) { XCTAssertEqual($0 as? NodeCalendarError, .targetCalendarRequired) }
        let pending = NodeHTTPResponse(statusCode: 409, url: url, headers: [:], body: Data(#"{"category":"conflict","code":"calendar_index_pending","kind":"node-calendar.problem.v1"}"#.utf8))
        XCTAssertThrowsError(try NodeCalendarCodec.validateStatus(pending)) { XCTAssertEqual($0 as? NodeCalendarError, .calendarIndexPending) }
        let plain = NodeHTTPResponse(statusCode: 409, url: url, headers: [:], body: Data(#"{"category":"conflict","kind":"node-calendar.problem.v1"}"#.utf8))
        XCTAssertThrowsError(try NodeCalendarCodec.validateStatus(plain)) { XCTAssertEqual($0 as? NodeCalendarError, .conflict) }
        var command = NodeCalendarCommand(operationID: "op", connectionID: "conn", generation: 1, eventID: "identity", invitationID: "inv", revision: "r", scope: .occurrence, response: .accepted)
        let untargeted = try NodeCalendarCodec.encodeFamily(NodeCalendarCommandRequest(command: command), kind: "command-request")
        XCTAssertFalse(String(decoding: untargeted, as: UTF8.self).contains("targetCalendarID"))
        command.targetCalendarID = "home"
        let targeted = try NodeCalendarCodec.encodeFamily(NodeCalendarCommandRequest(command: command), kind: "command-request")
        XCTAssertTrue(String(decoding: targeted, as: UTF8.self).contains(#""targetCalendarID":"home""#))
        let decoded: NodeCalendarCommandRequest = try NodeCalendarCodec.decodeFamily(targeted, kind: "command-request")
        XCTAssertEqual(decoded.command.targetCalendarID, "home")
    }
    func testAmbiguousSendReplaysRetainedRequestWithoutSecondSend() async throws {
        let sender = CalendarTestSender(ambiguous: true)
        let result = try await NodeCalendarClient(sender: sender).capabilities()
        XCTAssertTrue(result.enabled)
        let calls = await sender.calls
        XCTAssertEqual(calls, ["reconcile", "GET /v1/calendar/capabilities", "reconcile"])
    }
}
actor CalendarTestSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    var calls: [String] = []
    let status: Int
    var ambiguous: Bool
    var pending = false
    init(status: Int = 200, ambiguous: Bool = false) { self.status = status; self.ambiguous = ambiguous }
    func response() -> NodeHTTPResponse {
        NodeHTTPResponse(statusCode: status, url: URL(string: "https://node.example")!, headers: [:], body: Data((status == 200 ? #"{"enabled":true,"google":{"clientID":"desktop-client.apps.googleusercontent.com","configured":true},"kind":"node-calendar.capabilities.v1","providers":["google","caldav"],"version":1}"# : "bad JSON").utf8))
    }
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        calls.append("reconcile")
        guard pending else { return nil }
        pending = false
        return response()
    }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        calls.append(method + " " + path)
        if ambiguous { ambiguous = false; pending = true; throw NodeSessionError.transportFailureAfterDispatch }
        return response()
    }
}

extension NodeCalendarClientTests {
    func testAllTransportMethodsUseFrozenRoutesAndLimits() async throws {
        let fixture = try calendarFixtures()
        let sender = CalendarQueueSender(responses: [fixture["connectionsResult"]!, fixture["connectionResult"]!, fixture["connectionResult"]!, fixture["eventResult"]!, fixture["invitationReadResult"]!, fixture["commandResult"]!, fixture["operationReadResult"]!])
        let client = NodeCalendarClient(sender: sender)
        _ = try await client.connections()
        let configure: NodeCalendarConnectionRequest = try NodeCalendarCodec.decodeFamily(fixture["connectionRequest"]!, kind: "connection-command")
        _ = try await client.configure(configure.command)
        let disconnect: NodeCalendarDisconnectCommand = try NodeCalendarCodec.decodeFamily(fixture["disconnectRequest"]!, kind: "disconnect-command")
        _ = try await client.disconnect(disconnect)
        _ = try await client.event(id: "event-001")
        _ = try await client.invitations(messageIDs: ["message-001"])
        let command: NodeCalendarCommandRequest = try NodeCalendarCodec.decodeFamily(fixture["commandRequest"]!, kind: "command-request")
        _ = try await client.submit(command.command)
        do { _ = try await client.receipts(operationIDs: ["operation-001", "operation-002"]); XCTFail("unknown operation accepted as read") }
        catch let error as NodeCalendarError { XCTAssertEqual(error, .unknownOperation) }
        let paths = await sender.paths
        XCTAssertEqual(paths, ["connections/read", "connections/configure", "connections/disconnect", "event", "invitations", "commands", "operations/read"].map { "/v1/calendar/" + $0 })
        let bodies = await sender.bodies
        for (index, name) in ["connectionsRequest", "connectionRequest", "disconnectRequest", "eventRequest", "invitationReadRequest", "commandRequest", "operationReadRequest"].enumerated() { XCTAssertEqual(bodies[index], fixture[name], name) }
    }
    func testWindowCollectsPagesAndRejectsCursorCycles() async throws {
        let fixture = try calendarFixtures()
        var page: NodeCalendarWindowSnapshot = try NodeCalendarCodec.decodeFamily(fixture["windowResult"]!, kind: "window-result")
        let first = page
        page.events[0].id = "event-002"; page.nextCursor = ""
        let sender = CalendarQueueSender(responses: [try NodeCalendarCodec.encodeFamily(first, kind: "window-result", limit: NodeCalendarCodec.windowResponseLimit), try NodeCalendarCodec.encodeFamily(page, kind: "window-result", limit: NodeCalendarCodec.windowResponseLimit)])
        let result = try await NodeCalendarClient(sender: sender).window(NodeCalendarWindowRequest(window: first.window, cursor: ""))
        XCTAssertEqual(result.events.map(\.id), ["event-001", "event-002"])
        let limits = await sender.limits
        XCTAssertEqual(limits, [8_388_608, 8_388_608])
        let cycle = CalendarQueueSender(responses: [fixture["windowResult"]!, fixture["windowResult"]!])
        do { _ = try await NodeCalendarClient(sender: cycle).window(NodeCalendarWindowRequest(window: first.window, cursor: "")); XCTFail("cycle accepted") }
        catch let error as NodeCalendarError { XCTAssertEqual(error, .invalidResponse) }
    }
    func testRetainedReplayFailureRemainsDeliveryUncertain() async throws {
        let sender = CalendarUncertainSender()
        do { _ = try await NodeCalendarClient(sender: sender).capabilities(); XCTFail("lost ambiguity") }
        catch let error as NodeCalendarError { XCTAssertEqual(error, .deliveryUncertain) }
        let sends = await sender.sends
        XCTAssertEqual(sends, 1)
    }
    func testTimeValuesPreserveOffsetAndLegacyWallRepresentations() throws {
        for value in ["2026-10-25T02:30:00", "2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00"] {
            let raw = Data("{\"kind\":\"date_time\",\"timezone\":\"Europe/Zurich\",\"value\":\"\(value)\"}".utf8)
            let decoded: NodeCalendarTime = try NodeCalendarCodec.decode(raw)
            XCTAssertEqual(decoded.value, value)
            XCTAssertEqual(decoded.timezone, "Europe/Zurich")
        }
    }
}
private func calendarFixtures() throws -> [String: Data] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Protocol/node-calendar-v1/fixtures/protocol-v1.json")
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try XCTUnwrap(root["families"] as? [String: String]).mapValues { Data($0.utf8) }
}
private actor CalendarQueueSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    var responses: [Data]
    var paths: [String] = []
    var bodies: [Data] = []
    var limits: [Int] = []
    init(responses: [Data]) { self.responses = responses }
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard method == "POST", !responses.isEmpty else { throw NodeCalendarError.invalidResponse }
        paths.append(path); bodies.append(body); limits.append(maximumResponseBytes)
        return NodeHTTPResponse(statusCode: 200, url: URL(string: "https://node.example")!, headers: [:], body: responses.removeFirst())
    }
}
private actor CalendarUncertainSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    var sends = 0
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        if sends > 0 { throw NodeSessionError.transportFailure }
        return nil
    }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        sends += 1; throw NodeSessionError.transportFailureAfterDispatch
    }
}


extension NodeCalendarClientTests {
    func testCalendarWeekFactoryRetainsPrivateSignedSender() async throws {
        let sender = CalendarTestSender()
        let sync = NodeSyncClient(sender: sender)
        // This capability-only sender deliberately returns an invalid status
        // body; both clients must nevertheless reach this same signed sender.
        do { _ = try await sync.status(); XCTFail("capabilities decoded as status") } catch { }
        let calendar = sync.calendarClient()
        _ = try await calendar.capabilities()
        let calls = await sender.calls
        XCTAssertEqual(calls, ["reconcile", "GET /v1/status", "reconcile", "GET /v1/calendar/capabilities"])
    }
}

extension NodeCalendarClientTests {
    /// Only a first page asks to refresh. Later pages may carry different refresh
    /// metadata; a changed event snapshot restarts from the first page as a read.
    func testWindowRefreshIsExplicitAndChangedSnapshotRestartsFromFirstPage() async throws {
        let fixture = try calendarFixtures()
        let seed = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixture["windowResult"]!) as? [String: Any])
        func page(_ eventID: String, cursor: String, coverage: String = "complete", failures: [String: String] = [:]) throws -> Data {
            var doc = seed
            var events = try XCTUnwrap(doc["events"] as? [[String: Any]])
            events[0]["id"] = eventID
            doc["events"] = events; doc["nextCursor"] = cursor; doc["coverage"] = coverage; doc["failures"] = failures
            return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let changed = Data(#"{"category":"conflict","code":"snapshot_changed","kind":"node-calendar.problem.v1"}"#.utf8)
        let sender = CalendarScriptedSender(responses: [
            (200, try page("event-001", cursor: "cursor-a")), (409, changed),
            (200, try page("event-001", cursor: "cursor-b")), (200, try page("event-002", cursor: "", coverage: "cached", failures: ["4a7f52f8-0b83-4ce5-b4cc-9646a22e84ba": "unavailable"])),
        ])
        let window = try XCTUnwrap((try NodeCalendarCodec.decodeFamily(fixture["windowResult"]!, kind: "window-result") as NodeCalendarWindowSnapshot).window)
        let result = try await NodeCalendarClient(sender: sender).window(.init(window: window, cursor: "", refresh: true))
        XCTAssertEqual(result.events.map(\.id), ["event-001", "event-002"])
        XCTAssertEqual(result.coverage, "complete")
        let bodies = await sender.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(bodies.count, 4)
        XCTAssertTrue(bodies[0].contains(#""refresh":true"#))
        XCTAssertTrue(bodies[1].contains(#""cursor":"cursor-a""#) && !bodies[1].contains("refresh"))
        XCTAssertTrue(bodies[2].contains(#""cursor":"""#) && !bodies[2].contains("refresh"))
        XCTAssertTrue(bodies[3].contains(#""cursor":"cursor-b""#))
        let read = try NodeCalendarCodec.encodeFamily(NodeCalendarWindowRequest(window: window, cursor: ""), kind: "window-request")
        XCTAssertFalse(String(decoding: read, as: UTF8.self).contains("refresh"))
        let decoded: NodeCalendarWindowRequest = try NodeCalendarCodec.decodeFamily(try NodeCalendarCodec.encodeFamily(NodeCalendarWindowRequest(window: window, cursor: "", refresh: true), kind: "window-request"), kind: "window-request")
        XCTAssertTrue(decoded.refresh)
    }
}
private actor CalendarScriptedSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    var responses: [(Int, Data)]
    var bodies: [Data] = []
    init(responses: [(Int, Data)]) { self.responses = responses }
    func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        guard !responses.isEmpty else { throw NodeCalendarError.invalidResponse }
        bodies.append(body)
        let (status, data) = responses.removeFirst()
        return NodeHTTPResponse(statusCode: status, url: URL(string: "https://node.example")!, headers: [:], body: data)
    }
}

extension NodeCalendarClientTests {
    /// Zone names are exact IANA identifiers regardless of how the host's
    /// time zone database treats case.
    func testCalendarTimeZoneNamesAreCanonicalCase() {
        func zone(_ name: String) -> NodeCalendarJSON { .object([NodeCalendarJSONKey("timezone"): .string(NodeCalendarJSONKey(name))]) }
        for name in ["Europe/Zurich", "America/Port-au-Prince", "Etc/GMT+5", "EST", "UTC"] {
            XCTAssertTrue(NodeCalendarSchema.validCalendarTimeZone(zone(name)), name)
        }
        for name in ["europe/zurich", "EUROPE/ZURICH", "Europe/zurich", "utc", "Local", ""] {
            XCTAssertFalse(NodeCalendarSchema.validCalendarTimeZone(zone(name)), name)
        }
    }
}
