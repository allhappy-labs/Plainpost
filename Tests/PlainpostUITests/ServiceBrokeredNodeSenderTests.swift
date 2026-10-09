import Foundation
import XCTest
@testable import PlainpostAccountRuntime
@testable import PlainpostNodeTransport
@testable import PlainpostServiceIPC
@testable import PlainpostUI

@MainActor
final class ServiceBrokeredNodeSenderTests: XCTestCase {
    func testSendRelaysTheRequestAndTheNodeResponseThroughTheService() async throws {
        let service = BrokerServiceStub()
        await service.respond(to: "/v1/status", status: 200, body: Data("node-status".utf8))
        let sender = ServiceBrokeredNodeSender(serviceClient: service)
        let response = try await sender.send(method: "GET", path: "/v1/status", body: Data(), maximumResponseBytes: 1_024)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("node-status".utf8))
        XCTAssertNil(response.url.host, "the Node endpoint never reaches the app")
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.path), ["/v1/status"])
        let reconciled = try await sender.reconcilePendingRequest()
        XCTAssertNil(reconciled, "the service settles retained requests; the app never receives another caller's replay")
    }

    func testResponseLargerThanTheCallerAllowanceIsRejected() async throws {
        let service = BrokerServiceStub()
        await service.respond(to: "/v1/status", status: 200, body: Data(repeating: 1, count: 2_048))
        let sender = ServiceBrokeredNodeSender(serviceClient: service)
        do {
            _ = try await sender.send(method: "GET", path: "/v1/status", body: Data(), maximumResponseBytes: 1_024)
            XCTFail("oversized response accepted")
        } catch let error as NodeSessionError { XCTAssertEqual(error, .invalidValue) }
    }

    func testServiceFailuresKeepTheNodeSessionDispatchDistinctions() async throws {
        let cases: [(PlainpostServiceClientError, String, Error)] = [
            (.nodeSession(.authenticationRejected), "GET", NodeSessionError.authenticationRejected),
            (.nodeSession(.transportFailureAfterDispatch), "POST", NodeSessionError.transportFailureAfterDispatch),
            (.nodeSession(.transportCancellationAfterDispatch), "POST", NodeSessionError.transportCancellationAfterDispatch),
            (.nodeSession(.applicationResultUncertain), "POST", NodeSessionError.applicationResultUncertain),
            (.nodeSession(.transportFailure), "POST", NodeSessionError.transportFailure),
            (.nodeSession(.invalidValue), "POST", NodeSessionError.invalidValue),
            (.nodeSession(.noEnrolledNode), "GET", PlainpostServiceClientError.nodeSession(.noEnrolledNode)),
            (.nodeSession(.pathNotAllowed), "POST", PlainpostServiceClientError.nodeSession(.pathNotAllowed)),
            // An XPC timeout may follow dispatch: only a body-free read may
            // treat it as not sent.
            (.timedOut, "POST", NodeSessionError.transportFailureAfterDispatch),
            (.serviceUnavailable, "PUT", NodeSessionError.transportFailureAfterDispatch),
            (.timedOut, "GET", NodeSessionError.transportFailure),
        ]
        for (failure, method, expected) in cases {
            let service = BrokerServiceStub()
            await service.fail(with: failure)
            let sender = ServiceBrokeredNodeSender(serviceClient: service)
            do {
                _ = try await sender.send(method: method, path: "/v1/calendar/commands", body: Data(), maximumResponseBytes: 1_024)
                XCTFail("\(failure) succeeded")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: expected), "\(failure) \(method)")
            }
        }
    }

    func testConnectionVerificationRetriesUntilTheNodeIsReady() async throws {
        let service = BrokerServiceStub()
        await service.fail(with: .nodeSession(.transportFailure), times: 2)
        await service.respond(to: "/v1/status", status: 200, body: try NodeSyncCodec.encodeStatusResult(NodeSyncStatusResult(revision: "7", state: "ready")))
        let sender = ServiceBrokeredNodeSender(serviceClient: service)
        try await sender.verifyConnection(maximumAttempts: 3, delay: .zero)
        let paths = await service.requests.map(\.path)
        XCTAssertEqual(paths, ["/v1/status", "/v1/status", "/v1/status"])

        let unenrolled = BrokerServiceStub()
        await unenrolled.fail(with: .nodeSession(.noEnrolledNode))
        do {
            try await ServiceBrokeredNodeSender(serviceClient: unenrolled).verifyConnection(maximumAttempts: 5, delay: .zero)
            XCTFail("verified without a Node")
        } catch let error as PlainpostServiceClientError { XCTAssertEqual(error, .nodeSession(.noEnrolledNode)) }
        let unenrolledAttempts = await unenrolled.requests.count
        XCTAssertEqual(unenrolledAttempts, 1, "a missing session is not a readiness delay")
    }

    func testCalendarWeekLoadsThroughTheBrokeredSender() async throws {
        let service = BrokerServiceStub()
        await service.serveCalendar()
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: ServiceBrokeredNodeSender(serviceClient: service)), accountID: "account-a")
        let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        let model = CalendarWeekViewModel(service: authority, clock: { now })
        await model.load(refresh: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.events.map(\.id), ["brokered-event"])
        XCTAssertEqual(model.events.map(\.title), ["Brokered review"])
        model.stop()
        let paths = await service.requests.map(\.path)
        XCTAssertTrue(paths.starts(with: ["/v1/calendar/capabilities", "/v1/calendar/connections/read", "/v1/calendar/window"]), "\(paths)")
    }

    // After activation, every Mac app Node session request goes through the
    // service broker; only enrollment and activation keep their own calls.
    func testMacAppNodeSessionTrafficUsesOnlyTheBroker() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let session = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/AccountSessionViewModel.swift"), encoding: .utf8)
        XCTAssertFalse(session.contains("SyncNodeSessionLocator"), "the Mac calendar authority must not discover its own Node session")
        XCTAssertFalse(session.contains("NodeSessionTransport"))
        XCTAssertTrue(session.contains("ServiceBrokeredNodeSender(serviceClient:"))
        XCTAssertTrue(session.contains("brokeredConnection:"), "the Mac enrollment model verifies its connection through the broker")
        XCTAssertTrue(session.contains("SyncNodeEndpointStore(accessGroup: PlainpostAccountSharedKeychain.accessGroup)"))

        let app = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostApp/PlainpostApp.swift"), encoding: .utf8)
        XCTAssertFalse(app.contains("AccountCredentialStore()"), "the app passes the shared group explicitly")
        XCTAssertEqual(app.components(separatedBy: "AccountCredentialStore(accessGroup: PlainpostAccountSharedKeychain.accessGroup)").count - 1, 2)

        let assembly = try String(contentsOf: root.appendingPathComponent("Sources/PlainpostUI/SyncNodeEnrollmentAssembly.swift"), encoding: .utf8)
        XCTAssertTrue(assembly.contains("if let brokeredConnection"), "the brokered path replaces the in-app cached connection")
    }
}

/// A service client that answers Node session requests from canned responses.
private actor BrokerServiceStub: PlainpostServiceClientProtocol {
    private(set) var requests: [PlainpostNodeSessionRequest] = []
    private var responses: [String: (Int, Data)] = [:]
    private var failure: PlainpostServiceClientError?
    private var failuresRemaining = Int.max
    private var servesCalendar = false

    func respond(to path: String, status: Int, body: Data) { responses[path] = (status, body) }
    func fail(with error: PlainpostServiceClientError, times: Int = .max) { failure = error; failuresRemaining = times }
    func serveCalendar() { servesCalendar = true }

    nonisolated func status() async throws -> PlainpostVaultStatus { PlainpostVaultStatus(availability: .unlocked, matchingKeyItemCount: 1) }
    nonisolated func unlock(reason: String) async throws {}
    nonisolated func lock() async throws {}

    func performNodeSessionRequest(_ request: PlainpostNodeSessionRequest) async throws -> PlainpostNodeSessionResponse {
        requests.append(request)
        if let failure, failuresRemaining > 0 {
            failuresRemaining -= 1
            throw failure
        }
        if servesCalendar { return try calendarResponse(request) }
        guard let (status, body) = responses[request.path] else { throw PlainpostServiceClientError.nodeSession(.unavailable) }
        return try PlainpostNodeSessionResponse(statusCode: status, headers: [:], body: body)
    }

    private func calendarResponse(_ request: PlainpostNodeSessionRequest) throws -> PlainpostNodeSessionResponse {
        let data: Data
        switch request.path {
        case "/v1/calendar/capabilities":
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarCapabilities(version: 1, providers: [.caldav], enabled: true), kind: "capabilities")
        case "/v1/calendar/connections/read":
            let connection = NodeCalendarConnection(
                id: "conn-a", generation: 1, kind: .caldav, sendingMailbox: "mailbox-a", attendeeAddress: "me@example.test", delivery: .email, enabled: true,
                calendars: [.init(id: "work", name: "Work", color: "#4A78DF", timezone: "UTC", writable: true, scheduling: false)])
            data = try NodeCalendarCodec.encodeFamily(NodeCalendarConnectionsResult(connections: [connection]), kind: "connections-result")
        case "/v1/calendar/window":
            let window: NodeCalendarWindowRequest = try NodeCalendarCodec.decodeFamily(request.body, kind: "window-request")
            let formatter = ISO8601DateFormatter()
            let start = try XCTUnwrap(formatter.date(from: window.window.start)).addingTimeInterval(36 * 3_600)
            let event = Self.event(start: formatter.string(from: start), end: formatter.string(from: start.addingTimeInterval(3_600)))
            data = try NodeCalendarCodec.encodeFamily(
                NodeCalendarWindowSnapshot(events: [event], window: window.window, coverage: "complete", refreshedAt: "2026-09-16T12:00:00Z", failures: [:], nextCursor: ""),
                kind: "window-result", limit: NodeCalendarCodec.windowResponseLimit)
        default:
            return try PlainpostNodeSessionResponse(statusCode: 404, headers: [:], body: Data())
        }
        return try PlainpostNodeSessionResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    private static func event(start: String, end: String) -> NodeCalendarEvent {
        NodeCalendarEvent(id: "brokered-event", connectionID: "conn-a", calendarID: "work", recurrenceID: "", organizer: "", revision: "1", sequence: 0, stamp: "", title: "Brokered review", location: "", notes: "", start: .init(kind: .dateTime, value: start, timezone: "UTC"), end: .init(kind: .dateTime, value: end, timezone: "UTC"), recurring: false, cancelled: false, attendeeAddress: "", response: .accepted, canEditOccurrence: false, canEditSeries: false, canRespond: false, disabledReason: "", threadID: "", messageID: "", providerLink: "")
    }
}
