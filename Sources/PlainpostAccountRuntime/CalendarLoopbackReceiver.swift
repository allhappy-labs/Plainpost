import Foundation
import Network

/// One-shot RFC 8252 loopback receiver for Google consent (Calendar and Gmail).
///
/// It listens only on `127.0.0.1` at an OS-assigned port and completes on the
/// first `GET` of its configured callback path (`/oauth/calendar/google` by
/// default, `/oauth/mail/google` for Gmail) whose `Host` names that exact origin.
/// Other paths, methods, hosts and oversized requests are answered with a
/// static error and the receiver keeps waiting. Every response body is static:
/// nothing from a request is reflected. The receiver closes its port when it
/// completes, times out or is cancelled.
public final class CalendarLoopbackReceiver: @unchecked Sendable {
    public static let callbackPath = "/oauth/calendar/google"
    public static let mailCallbackPath = "/oauth/mail/google"
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumCodeBytes = 4096
    public static let defaultTimeout: TimeInterval = 300
    static let maximumConnections = 16

    public enum Failure: Error, Equatable, Sendable {
        case cannotStart, invalidCallback, denied, timedOut, cancelled
    }

    /// The only path this receiver completes on; every other path is a 404.
    public let callbackPath: String
    private let expectedState: [UInt8]
    private let timeout: TimeInterval
    private let suppressListenerStartForTesting: Bool
    private let queue = DispatchQueue(label: "app.plainpost.calendar-oauth-loopback")

    // Confined to `queue`.
    private var listener: NWListener?
    private var port: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<String, Failure>?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var callbackWaiters: [CheckedContinuation<String, Error>] = []
    private var deadline: DispatchWorkItem?

    public convenience init(
        expectedState: String,
        callbackPath: String = CalendarLoopbackReceiver.callbackPath,
        timeout: TimeInterval = CalendarLoopbackReceiver.defaultTimeout
    ) {
        self.init(
            expectedState: expectedState, callbackPath: callbackPath, timeout: timeout,
            suppressListenerStartForTesting: false
        )
    }

    /// Test-only seam: when `true`, the underlying `NWListener` is created
    /// but never told to start, so its `stateUpdateHandler` never delivers
    /// `.ready`, `.failed`, or `.cancelled` — the same terminal-state
    /// starvation a listener stuck in Network framework's `.waiting` state
    /// produces in practice (for example while a required interface is
    /// unavailable). This exercises the deadline-arming fix deterministically
    /// without depending on real network conditions. Production always passes
    /// `false`.
    init(
        expectedState: String,
        callbackPath: String = CalendarLoopbackReceiver.callbackPath,
        timeout: TimeInterval,
        suppressListenerStartForTesting: Bool
    ) {
        self.callbackPath = callbackPath
        self.expectedState = Array(expectedState.utf8)
        self.timeout = timeout
        self.suppressListenerStartForTesting = suppressListenerStartForTesting
    }

    deinit { listener?.cancel() }

    /// Binds the loopback listener and returns its OS-assigned port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.begin(continuation) }
        }
    }

    /// Waits for the authorization code of the single accepted callback.
    public func callback() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome.mapError { $0 as Error })
                    } else {
                        self.callbackWaiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Stops listening; a pending or later `callback()` reports `cancelled`.
    public func cancel() {
        queue.async { self.finish(.failure(.cancelled)) }
    }

    // MARK: Listener lifecycle (queue)

    private func begin(_ continuation: CheckedContinuation<UInt16, Error>) {
        guard listener == nil, outcome == nil, !expectedState.isEmpty,
              [Self.callbackPath, Self.mailCallbackPath].contains(callbackPath) else {
            continuation.resume(throwing: outcome.map { _ in Failure.cancelled } ?? Failure.cannotStart)
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false
        let created: NWListener
        do { created = try NWListener(using: parameters) } catch {
            continuation.resume(throwing: Failure.cannotStart)
            return
        }
        listener = created
        startWaiter = continuation
        // Armed here, not in `.ready`, so a listener that never leaves
        // Network framework's `.waiting` state (for example while a required
        // interface is unavailable) still times out instead of leaving
        // `start()` waiting forever.
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        created.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = created.port?.rawValue, port >= 1024 else { self.finish(.failure(.cannotStart)); return }
                self.port = port
                self.startWaiter?.resume(returning: port)
                self.startWaiter = nil
            case .failed, .cancelled:
                self.finish(.failure(self.port == nil ? .cannotStart : .cancelled))
            default:
                break
            }
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        if !suppressListenerStartForTesting { created.start(queue: queue) }
    }

    private func finish(_ result: Result<String, Failure>) {
        guard outcome == nil else { return }
        outcome = result
        deadline?.cancel(); deadline = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        // Idle or partial connections (browser preconnects) close with the
        // listener; a connection still sending its response closes itself.
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let startWaiter {
            self.startWaiter = nil
            startWaiter.resume(throwing: result.failureValue ?? .cancelled)
        }
        let waiters = callbackWaiters
        callbackWaiters = []
        for waiter in waiters { waiter.resume(with: result.mapError { $0 as Error }) }
    }

    // MARK: Connections (queue)

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < Self.maximumConnections else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard self.outcome == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)), end.upperBound - buffer.startIndex <= Self.maximumRequestBytes {
                self.handle(head: buffer[buffer.startIndex..<end.lowerBound], on: connection)
            } else if buffer.count > Self.maximumRequestBytes {
                self.respond(connection, status: "431 Request Header Fields Too Large", body: Self.errorPage, drain: true)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        guard let text = String(data: head, encoding: .utf8), text.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) || $0 == 13 || $0 == 10 }) else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0", requestLine[1].hasPrefix("/") else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage); return
        }
        var hosts: [Substring] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(connection, status: "400 Bad Request", body: Self.errorPage); return }
            if line[..<colon].lowercased() == "host" { hosts.append(line[line.index(after: colon)...].drop(while: { $0 == " " || $0 == "\t" })) }
        }
        guard let port, hosts.count == 1, hosts[0].trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else {
            respond(connection, status: "400 Bad Request", body: Self.errorPage); return
        }
        let target = requestLine[1]
        let path = target.prefix { $0 != "?" && $0 != "#" }
        guard path == callbackPath else { respond(connection, status: "404 Not Found", body: Self.errorPage); return }
        guard requestLine[0] == "GET" else { respond(connection, status: "405 Method Not Allowed", body: Self.errorPage); return }
        // The single matching request completes the receiver whatever it carries.
        let result = evaluate(target: String(target))
        respond(connection, status: "200 OK", body: Self.returnPage)
        finish(result)
    }

    private func evaluate(target: String) -> Result<String, Failure> {
        guard !target.contains("#"), let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == callbackPath, let items = components.queryItems,
              Set(items.map(\.name)).count == items.count,
              let state = items.first(where: { $0.name == "state" })?.value,
              Self.constantTimeEqual(Array(state.utf8), expectedState) else { return .failure(.invalidCallback) }
        if items.contains(where: { $0.name == "error" }) { return .failure(.denied) }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= Self.maximumCodeBytes,
              !code.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return .failure(.invalidCallback) }
        return .success(code)
    }

    private func respond(_ connection: NWConnection, status: String, body: String, drain: Bool = false) {
        connections[ObjectIdentifier(connection)] = nil
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard drain, let self else { connection.cancel(); return }
            // Discard the unread remainder briefly so the client receives the
            // status instead of a reset; then close regardless.
            self.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            self.discard(connection, remaining: 1 << 20)
        })
    }

    private func discard(_ connection: NWConnection, remaining: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            let left = remaining - (data?.count ?? 0)
            if isComplete || error != nil || left <= 0 { connection.cancel() } else { self?.discard(connection, remaining: left) }
        }
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    static let returnPage = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Plainpost</title></head><body><p>You can return to Plainpost.</p></body></html>"
    static let errorPage = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Plainpost</title></head><body><p>This page is not available.</p></body></html>"
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
