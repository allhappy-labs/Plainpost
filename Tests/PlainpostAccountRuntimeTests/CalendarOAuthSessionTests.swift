import XCTest
import CryptoKit
import Darwin
import PlainpostNodeTransport
@testable import PlainpostAccountRuntime

@MainActor
final class CalendarOAuthSessionTests: XCTestCase {
    // MARK: Loopback receiver

    func testLoopbackReceiverReturnsCodeForValidCallbackAndNeverReflectsInput() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        XCTAssertGreaterThanOrEqual(port, 1024)
        let waiting = Task { try await receiver.callback() }
        let marker = "reflected%3Cscript%3E"
        let response = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?state=expected-state&code=\(marker)", port: port))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
        XCTAssertTrue(response.contains("You can return to Plainpost"), response)
        XCTAssertFalse(response.contains("reflected"), "response reflected request input")
        XCTAssertFalse(response.contains("expected-state"), "response reflected state")
        let code = try await waiting.value
        XCTAssertEqual(code, "reflected<script>")
        try await LoopbackHTTP.waitUntilClosed(port: port)
    }

    func testLoopbackReceiverRejectsWrongStateAndCloses() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        let waiting = Task { try await receiver.callback() }
        let response = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?state=attacker-state&code=stolen", port: port))
        XCTAssertFalse(response.contains("attacker-state") || response.contains("stolen"), response)
        do { _ = try await waiting.value; XCTFail("wrong state accepted") } catch { XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .invalidCallback) }
        try await LoopbackHTTP.waitUntilClosed(port: port)
    }

    func testLoopbackReceiverRejectsMissingOrDuplicateStateAndOversizedCode() async throws {
        for query in ["code=x", "state=expected-state&state=expected-state&code=x", "state=expected-state", "state=expected-state&code=", "state=expected-state&code=\(String(repeating: "c", count: 4097))"] {
            let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
            let port = try await receiver.start()
            let waiting = Task { try await receiver.callback() }
            _ = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?\(query)", port: port))
            do { _ = try await waiting.value; XCTFail("accepted \(query)") } catch { XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .invalidCallback, query) }
        }
    }

    func testLoopbackReceiverSurfacesAccessDenied() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        let waiting = Task { try await receiver.callback() }
        let response = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?error=access_denied&state=expected-state", port: port))
        XCTAssertTrue(response.contains("You can return to Plainpost"), response)
        XCTAssertFalse(response.contains("access_denied"), response)
        do { _ = try await waiting.value; XCTFail("denial returned a code") } catch { XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .denied) }
    }

    func testLoopbackReceiverRejectsOtherPathsMethodsHostsAndOversizedRequestsWhileWaiting() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        let waiting = Task { try await receiver.callback() }
        let wrongPath = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/other?state=expected-state&code=x", port: port))
        XCTAssertTrue(wrongPath.hasPrefix("HTTP/1.1 404 "), wrongPath)
        XCTAssertFalse(wrongPath.contains("oauth/other"), wrongPath)
        let favicon = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/favicon.ico", port: port))
        XCTAssertTrue(favicon.hasPrefix("HTTP/1.1 404 "), favicon)
        let post = try await LoopbackHTTP.send(port: port, request: "POST /oauth/calendar/google?state=expected-state&code=x HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405 "), post)
        let foreignHost = try await LoopbackHTTP.send(port: port, request: "GET /oauth/calendar/google?state=expected-state&code=x HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
        XCTAssertTrue(foreignHost.hasPrefix("HTTP/1.1 400 "), foreignHost)
        let oversized = try await LoopbackHTTP.send(port: port, request: "GET /oauth/calendar/google?state=expected-state&code=x HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Padding: \(String(repeating: "p", count: 17 * 1024))\r\n\r\n")
        XCTAssertTrue(oversized.hasPrefix("HTTP/1.1 431 "), oversized)
        let valid = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?state=expected-state&code=real-code", port: port))
        XCTAssertTrue(valid.hasPrefix("HTTP/1.1 200 "), valid)
        let code = try await waiting.value
        XCTAssertEqual(code, "real-code")
    }

    func testLoopbackReceiverTimeoutAndCancelCloseThePort() async throws {
        let timed = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 0.3)
        let timedPort = try await timed.start()
        do { _ = try await timed.callback(); XCTFail("timeout returned a code") } catch { XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .timedOut) }
        try await LoopbackHTTP.waitUntilClosed(port: timedPort)

        let cancelled = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await cancelled.start()
        XCTAssertTrue(LoopbackHTTP.canConnect(port: port))
        let waiting = Task { try await cancelled.callback() }
        cancelled.cancel()
        do { _ = try await waiting.value; XCTFail("cancel returned a code") } catch { XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .cancelled) }
        try await LoopbackHTTP.waitUntilClosed(port: port)
    }

    func testLoopbackReceiverStartTimesOutWhenListenerNeverBecomesReady() async throws {
        // `suppressListenerStartForTesting` creates the underlying NWListener
        // but never calls `start(queue:)` on it, so its stateUpdateHandler
        // never delivers `.ready`, `.failed`, or `.cancelled` — the same
        // terminal-state starvation a listener stuck in Network framework's
        // `.waiting` state produces in practice (for example while a
        // required interface is unavailable). Before the deadline was armed
        // in `begin()` (rather than only in the `.ready` case), this made
        // `start()` hang indefinitely instead of honoring `timeout`.
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 0.3, suppressListenerStartForTesting: true)
        do {
            _ = try await receiver.start()
            XCTFail("a listener that never starts resolved start()")
        } catch {
            XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .timedOut)
        }
    }

    func testLoopbackReceiverClosesIdleConnectionsWhenCallbackCompletes() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        let idle = LoopbackHTTP.openIdle(port: port)
        XCTAssertGreaterThanOrEqual(idle, 0)
        let waiting = Task { try await receiver.callback() }
        _ = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?state=expected-state&code=c", port: port))
        _ = try await waiting.value
        let closed = try await Task.detached { LoopbackHTTP.readsEndOfStream(idle) }.value
        XCTAssertTrue(closed, "an idle preconnect outlived the completed receiver")
    }

    func testLoopbackReceiverListensOnlyOnIPv4Loopback() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "expected-state", timeout: 30)
        let port = try await receiver.start()
        defer { receiver.cancel() }
        XCTAssertTrue(LoopbackHTTP.canConnect(port: port))
        XCTAssertFalse(LoopbackHTTP.canConnect(port: port, address: "::1"), "listener accepted IPv6 loopback")
        let external = LoopbackHTTP.nonLoopbackIPv4Addresses()
        for address in external {
            XCTAssertFalse(LoopbackHTTP.canConnect(port: port, address: address), "listener accepted \(address)")
        }
    }

    // MARK: Authorization session

    func testAuthorizationUsesLoopbackRedirectPKCEAndCalendarScopes() async throws {
        let opened = OpenedURLs()
        let session = CalendarOAuthSession(clientID: "desktop-client.apps.googleusercontent.com", timeout: 30) { url in opened.urls.append(url); return true }
        let authorizing = Task { try await session.authorize() }
        let url = try await waitForOpenedURL { opened.urls.first }
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "accounts.google.com"); XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(items["client_id"], "desktop-client.apps.googleusercontent.com")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        let redirect = try XCTUnwrap(items["redirect_uri"])
        let components = try XCTUnwrap(URLComponents(string: redirect))
        XCTAssertEqual(components.scheme, "http"); XCTAssertEqual(components.host, "127.0.0.1"); XCTAssertEqual(components.path, "/oauth/calendar/google")
        let port = try XCTUnwrap(components.port)
        XCTAssertEqual(redirect, "http://127.0.0.1:\(port)/oauth/calendar/google")
        let state = try XCTUnwrap(items["state"])
        XCTAssertTrue(session.hasPendingAuthorization)
        _ = try await LoopbackHTTP.send(port: UInt16(port), request: LoopbackHTTP.get("/oauth/calendar/google?state=\(state)&code=authorization-code", port: UInt16(port)))
        let configuration = try await authorizing.value
        XCTAssertEqual(configuration.authorizationCode, "authorization-code")
        XCTAssertEqual(configuration.clientID, "desktop-client.apps.googleusercontent.com")
        XCTAssertEqual(configuration.redirectURI, redirect)
        let challenge = Data(SHA256.hash(data: Data(configuration.codeVerifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(items["code_challenge"], challenge)
        XCTAssertGreaterThanOrEqual(configuration.codeVerifier.count, 43)
        XCTAssertFalse(session.hasPendingAuthorization)
        try await LoopbackHTTP.waitUntilClosed(port: UInt16(port))

        opened.urls = []
        let second = Task { try await session.authorize() }
        let secondURL = try await waitForOpenedURL { opened.urls.first }
        let secondItems = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertNotEqual(secondItems["state"], state)
        XCTAssertNotEqual(secondItems["code_challenge"], items["code_challenge"])
        session.cancel()
        do { _ = try await second.value; XCTFail("cancelled authorization returned") } catch { XCTAssertEqual(error as? CalendarOAuthSession.Error, .cancelled) }
    }

    func testAuthorizationSurfacesDenialAndWrongState() async throws {
        for (query, expected) in [("error=access_denied&state=STATE", CalendarOAuthSession.Error.denied), ("state=wrong&code=x", .invalidCallback)] {
            let opened = OpenedURLs()
            let session = CalendarOAuthSession(clientID: "desktop-client", timeout: 30) { url in opened.urls.append(url); return true }
            let authorizing = Task { try await session.authorize() }
            let url = try await waitForOpenedURL { opened.urls.first }
            let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
            let port = UInt16(try XCTUnwrap(URLComponents(string: try XCTUnwrap(items["redirect_uri"]))?.port))
            _ = try await LoopbackHTTP.send(port: port, request: LoopbackHTTP.get("/oauth/calendar/google?" + query.replacingOccurrences(of: "STATE", with: items["state"] ?? ""), port: port))
            do { _ = try await authorizing.value; XCTFail("accepted \(query)") } catch { XCTAssertEqual(error as? CalendarOAuthSession.Error, expected) }
            XCTAssertFalse(session.hasPendingAuthorization)
        }
    }

    func testAuthorizationRefusesInvalidClientAndUnopenableBrowserWithoutLeavingAListener() async throws {
        for client in ["", "bad client", String(repeating: "c", count: 513)] {
            let session = CalendarOAuthSession(clientID: client, timeout: 30) { _ in XCTFail("opened a browser"); return true }
            do { _ = try await session.authorize(); XCTFail("invalid client \(client) started") } catch { XCTAssertEqual(error as? CalendarOAuthSession.Error, .invalidConfiguration) }
        }
        let captured = OpenedURLs()
        let session = CalendarOAuthSession(clientID: "desktop-client", timeout: 30) { url in
            captured.port = URLComponents(string: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value ?? "")?.port.map(UInt16.init)
            return false
        }
        do { _ = try await session.authorize(); XCTFail("unopenable browser started") } catch { XCTAssertEqual(error as? CalendarOAuthSession.Error, .cannotStart) }
        try await LoopbackHTTP.waitUntilClosed(port: try XCTUnwrap(captured.port))
    }

    func testAuthorizationCancelledByTaskCancellationClosesThePort() async throws {
        let opened = OpenedURLs()
        let session = CalendarOAuthSession(clientID: "desktop-client", timeout: 30) { url in opened.urls.append(url); return true }
        let authorizing = Task { try await session.authorize() }
        let url = try await waitForOpenedURL { opened.urls.first }
        let port = UInt16(try XCTUnwrap(URLComponents(string: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value ?? "")?.port))
        authorizing.cancel()
        do { _ = try await authorizing.value; XCTFail("cancelled task returned") } catch { XCTAssertEqual(error as? CalendarOAuthSession.Error, .cancelled) }
        try await LoopbackHTTP.waitUntilClosed(port: port)
    }

    private func waitForOpenedURL(_ read: @MainActor () -> URL?) async throws -> URL {
        for _ in 0..<200 {
            if let url = read() { return url }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("browser was never opened")
        throw URLError(.timedOut)
    }

    func testAuthorityRejectsLateResponseAndRevokedRequests() async throws {
        let sender = CalendarAuthorityGateSender()
        let authority = PlainpostCalendarAuthority(client: NodeCalendarClient(sender: sender), accountID: "account-a")
        let pending = Task { try await authority.capabilities() }
        await sender.waitForRequest()
        await authority.invalidate()
        await sender.finish()
        do { _ = try await pending.value; XCTFail("late result escaped") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await authority.capabilities(); XCTFail("revoked request escaped") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await sender.count
        XCTAssertEqual(count, 1)
    }
}

private actor CalendarAuthorityGateSender: NodeSessionRequestSending {
    var count = 0
    var continuation: CheckedContinuation<NodeHTTPResponse, Error>?
    var observer: CheckedContinuation<Void, Never>?
    func waitForRequest() async { if count == 0 { await withCheckedContinuation { observer = $0 } } }
    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        count += 1; observer?.resume(); observer = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(statusCode: 200, url: URL(string: "https://node.example")!, headers: [:], body: Data(#"{"enabled":true,"google":{"clientID":null,"configured":false},"kind":"node-calendar.capabilities.v1","providers":["google","caldav"],"version":1}"#.utf8)))
        continuation = nil
    }
}

@MainActor private final class OpenedURLs {
    var urls: [URL] = []
    var port: UInt16?
}

/// Raw loopback HTTP over POSIX sockets, so tests control every request byte.
enum LoopbackHTTP {
    static func get(_ target: String, port: UInt16) -> String { "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: PlainpostTests\r\n\r\n" }

    static func send(port: UInt16, request: String) async throws -> String {
        try await Task.detached { try sendBlocking(port: port, request: Data(request.utf8)) }.value
    }

    static func canConnect(port: UInt16) -> Bool {
        let fd = connectSocket(port: port)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openIdle(port: UInt16) -> Int32 { connectSocket(port: port) }

    /// Reads from an idle connection until the peer closes it (or 5 s pass).
    static func readsEndOfStream(_ fd: Int32) -> Bool {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(fd, &buffer, buffer.count)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
    }

    static func canConnect(port: UInt16, address: String) -> Bool {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &result) == 0, let info = result else { return false }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
    }

    static func nonLoopbackIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET), (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return addresses
    }

    static func waitUntilClosed(port: UInt16) async throws {
        for _ in 0..<200 {
            if !canConnect(port: port) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("loopback port \(port) still accepts connections")
    }

    private static func connectSocket(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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

    private static func sendBlocking(port: UInt16, request: Data) throws -> String {
        let fd = connectSocket(port: port)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        var offset = 0
        while offset < request.count {
            let written = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, request.count - offset) }
            if written <= 0 { break }
            offset += written
        }
        shutdown(fd, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        return String(decoding: response, as: UTF8.self)
    }
}
