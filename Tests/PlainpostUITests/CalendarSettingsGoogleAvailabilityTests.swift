import Darwin
import XCTest
import PlainpostAccountRuntime
import PlainpostNodeTransport
@_spi(DesignPreview) @testable import PlainpostUI

@MainActor
final class CalendarSettingsGoogleAvailabilityTests: XCTestCase {
    func testCalendarSettingsShowNoMailboxIDsOrProviderPrefill() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlainpostUITests/CalendarSettingsGoogleAvailabilityTests.swift",
            with: "Sources/PlainpostUI/CalendarSettingsView.swift"))
        XCTAssertFalse(source.contains("purelymail"))
        XCTAssertFalse(source.contains("Sending mailbox: \\("))
        XCTAssertFalse(source.contains("Connected sending mailbox ID"))
    }

    func testCalendarSettingsOffersGoogleOnlyForNodeConfiguredClient() async {
        let configured = CalendarSettingsModel(service: GoogleCapabilityService(google: .init(clientID: "desktop-client.apps.googleusercontent.com")))
        await configured.load()
        XCTAssertEqual(configured.googleSetup, .configured(clientID: "desktop-client.apps.googleusercontent.com"))
        XCTAssertTrue(configured.canConnectGoogle)
        XCTAssertNil(configured.googleSetup.settingsMessage)

        let unconfigured = CalendarSettingsModel(service: GoogleCapabilityService(google: .unconfigured))
        await unconfigured.load()
        XCTAssertEqual(unconfigured.googleSetup, .notConfigured)
        XCTAssertFalse(unconfigured.canConnectGoogle)
        XCTAssertEqual(unconfigured.googleSetup.settingsMessage, "Your Sync Node has no Google Calendar client configured.")
        // CalDAV setup is unaffected by Google availability.
        unconfigured.endpoint = "https://dav.example.test"; unconfigured.username = "me"; unconfigured.password = "pw"
        unconfigured.sendingMailboxID = "mail"; unconfigured.attendeeAddress = "me@example.test"
        XCTAssertTrue(unconfigured.canConnectCalDAV)

        let disabled = CalendarSettingsModel(service: GoogleCapabilityService(google: .init(clientID: "desktop-client"), enabled: false))
        await disabled.load()
        XCTAssertFalse(disabled.canConnectGoogle)

        let offline = CalendarSettingsModel(service: GoogleCapabilityService(google: .init(clientID: "desktop-client"), failure: .unavailable))
        await offline.load()
        XCTAssertEqual(offline.googleSetup, .unknown)
        XCTAssertFalse(offline.canConnectGoogle)
    }

    func testCalendarSettingsConnectGoogleSendsNodeClientAndLoopbackRedirect() async throws {
        let service = GoogleCapabilityService(google: .init(clientID: "desktop-client.apps.googleusercontent.com"))
        let opened = OpenedAuthorizationURLs()
        let model = CalendarSettingsModel(service: service) { url in opened.urls.append(url); return true }
        await model.load()
        let connecting = Task { await model.connectGoogle() }
        var authorizationURL: URL?
        for _ in 0..<300 where authorizationURL == nil {
            authorizationURL = opened.urls.first
            if authorizationURL == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let url = try XCTUnwrap(authorizationURL)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "desktop-client.apps.googleusercontent.com")
        let redirect = try XCTUnwrap(items["redirect_uri"])
        let port = UInt16(try XCTUnwrap(URLComponents(string: redirect)?.port))
        XCTAssertEqual(redirect, "http://127.0.0.1:\(port)/oauth/calendar/google")
        let state = try XCTUnwrap(items["state"])
        _ = try await Task.detached { try RawLoopbackGet.send(port: port, target: "/oauth/calendar/google?state=\(state)&code=node-exchanged-code") }.value
        await connecting.value
        let captured = await service.lastCommand
        let command = try XCTUnwrap(captured)
        XCTAssertEqual(command.kind, .google)
        let google = try XCTUnwrap(command.configuration.google)
        XCTAssertEqual(google.clientID, "desktop-client.apps.googleusercontent.com")
        XCTAssertEqual(google.redirectURI, redirect)
        XCTAssertEqual(google.authorizationCode, "node-exchanged-code")
        XCTAssertGreaterThanOrEqual(google.codeVerifier.count, 43)
    }

    func testCalendarSettingsStopCancelsPendingGoogleAuthorization() async throws {
        let service = GoogleCapabilityService(google: .init(clientID: "desktop-client"))
        let opened = OpenedAuthorizationURLs()
        let model = CalendarSettingsModel(service: service) { url in opened.urls.append(url); return true }
        await model.load()
        let connecting = Task { await model.connectGoogle() }
        for _ in 0..<300 where opened.urls.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let url = try XCTUnwrap(opened.urls.first)
        let redirect = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value)
        let port = UInt16(try XCTUnwrap(URLComponents(string: redirect)?.port))
        model.stop()
        await connecting.value
        XCTAssertFalse(model.isBusy)
        let captured = await service.lastCommand
        XCTAssertNil(captured)
        var closed = false
        for _ in 0..<200 where !closed {
            closed = !RawLoopbackGet.canConnect(port: port)
            if !closed { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(closed, "settings close left the loopback port open")
    }
}

@MainActor private final class OpenedAuthorizationURLs {
    var urls: [URL] = []
}

private actor GoogleCapabilityService: CalendarServing {
    let google: NodeCalendarGoogleAvailability
    let enabled: Bool
    let failure: NodeCalendarError?
    var lastCommand: NodeCalendarConnectionCommand?
    init(google: NodeCalendarGoogleAvailability, enabled: Bool = true, failure: NodeCalendarError? = nil) { self.google = google; self.enabled = enabled; self.failure = failure }
    func capabilities() async throws -> NodeCalendarCapabilities {
        if let failure { throw failure }
        return .init(version: 1, providers: [.google, .caldav], enabled: enabled, google: google)
    }
    func connections() async throws -> [NodeCalendarConnection] { [] }
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot { .init(events: [], window: request.window, coverage: "complete", refreshedAt: request.window.start, failures: [:], nextCursor: "") }
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult { lastCommand = command; throw NodeCalendarError.unavailable }
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult { throw NodeCalendarError.unavailable }
    func event(id: String) async throws -> NodeCalendarEvent { throw NodeCalendarError.unavailable }
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] { [] }
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt { throw NodeCalendarError.unavailable }
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] { [] }
}

/// A real loopback HTTP request, as the user's browser would send it.
private enum RawLoopbackGet {
    static func canConnect(port: UInt16) -> Bool {
        let fd = open(port: port)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func send(port: UInt16, target: String) throws -> String {
        let fd = open(port: port)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        let request = Array("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, request.count) }
        shutdown(fd, SHUT_WR)
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        return String(decoding: response, as: UTF8.self)
    }

    private static func open(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result != 0 { close(fd); return -1 }
        return fd
    }
}
