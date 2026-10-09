import Darwin
import Foundation
import XCTest
@testable import PlainpostBrowserIntegration
import PlainpostLocalAPI

final class LocalAPIUnixClientTests: XCTestCase {
    func testRequestUsesBigEndianSocketFrames() throws {
        let response = Data(#"{"ok":true}"#.utf8)
        let server = try OneShotUnixServer(responsePayload: response)
        let request = try localAPIRequest(method: .sessionStatus, requestID: "req-status")

        let received = try LocalAPIUnixClient(socketURL: server.socketURL)
            .request(request)

        XCTAssertEqual(received, response)
        var expectedLength = UInt32(request.count).bigEndian
        XCTAssertEqual(
            server.requestHeader,
            withUnsafeBytes(of: &expectedLength) { Data($0) }
        )
    }

    func testRequestRejectsZeroAndOversizeResponseLengthsBeforeReadingPayload() throws {
        for length in [0, LocalAPIProtocol.maximumFrameSize + 1] {
            let server = try OneShotUnixServer(responseLength: length)

            XCTAssertThrowsError(
                try LocalAPIUnixClient(socketURL: server.socketURL)
                    .request(try localAPIRequest(method: .sessionStatus, requestID: "req-length"))
            ) { error in
                XCTAssertEqual(
                    error as? LocalAPIUnixClientError,
                    .invalidFrameLength(length)
                )
            }
        }
    }

    func testMissingAppFailsUnavailableWithoutSleeping() throws {
        let socketURL = missingSocketURL()
        var launchCount = 0
        var sleepCount = 0

        XCTAssertThrowsError(
            try LocalAPIUnixClient(socketURL: socketURL)
                .requestLaunchingApplicationIfNeeded(
                    try localAPIRequest(method: .sessionStatus, requestID: "req-missing"),
                    launchApplication: {
                        launchCount += 1
                        return false
                    },
                    now: { 0 },
                    sleep: { _ in sleepCount += 1 }
                )
        ) { error in
            XCTAssertEqual(error as? LocalAPIUnixClientError, .applicationUnavailable)
        }
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(sleepCount, 0)
    }

    func testStartupRetryIsBoundedToOneHundredMillisecondsForFiveSeconds() throws {
        let socketURL = missingSocketURL()
        var elapsed: TimeInterval = 0
        var delays: [TimeInterval] = []

        XCTAssertThrowsError(
            try LocalAPIUnixClient(socketURL: socketURL)
                .requestLaunchingApplicationIfNeeded(
                    try localAPIRequest(method: .sessionStatus, requestID: "req-startup"),
                    launchApplication: { true },
                    now: { elapsed },
                    sleep: { delay in
                        delays.append(delay)
                        elapsed += delay
                    }
                )
        ) { error in
            XCTAssertEqual(error as? LocalAPIUnixClientError, .applicationUnavailable)
        }
        XCTAssertEqual(delays.count, 50)
        XCTAssertTrue(delays.allSatisfy { abs($0 - 0.1) < 0.000_001 })
        XCTAssertEqual(elapsed, 5, accuracy: 0.000_001)
    }

    func testStartupRetryRechecksDeadlineAfterOversleepBeforeAnotherAttempt() throws {
        let socketURL = missingSocketURL()
        var elapsed: TimeInterval = 0
        var delays: [TimeInterval] = []
        defer { try? FileManager.default.removeItem(at: socketURL) }

        XCTAssertThrowsError(
            try LocalAPIUnixClient(
                socketURL: socketURL,
                startupTimeout: 0.1,
                retryInterval: 0.1
            ).requestLaunchingApplicationIfNeeded(
                try localAPIRequest(method: .sessionStatus, requestID: "req-oversleep"),
                launchApplication: { true },
                now: { elapsed },
                sleep: { delay in
                    delays.append(delay)
                    elapsed += delay + 0.05
                    XCTAssertTrue(
                        FileManager.default.createFile(
                            atPath: socketURL.path,
                            contents: Data("not-a-socket".utf8)
                        )
                    )
                }
            )
        ) { error in
            XCTAssertEqual(error as? LocalAPIUnixClientError, .applicationUnavailable)
        }
        XCTAssertEqual(delays, [0.1])
        XCTAssertEqual(elapsed, 0.15, accuracy: 0.000_001)
    }

    func testAcceptedSocketThatNeverRepliesTimesOutWithinConfiguredBudget() throws {
        let server = try OneShotUnixServer()
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(
            try LocalAPIUnixClient(
                socketURL: server.socketURL,
                startupTimeout: 0.2,
                retryInterval: 0.05,
                operationTimeout: 0.2
            ).requestLaunchingApplicationIfNeeded(
                try localAPIRequest(method: .sessionStatus, requestID: "req-no-response"),
                launchApplication: {
                    XCTFail("Connected sockets must not launch the app")
                    return true
                }
            )
        ) { error in
            XCTAssertEqual(error as? LocalAPIUnixClientError, .deadlineExceeded)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertTrue(server.didAcceptConnection)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1)
    }

    func testNonStartupSocketErrorDoesNotLaunchApplication() throws {
        let tooLongPath = "/tmp/" + String(repeating: "x", count: 200)
        var launchCount = 0

        XCTAssertThrowsError(
            try LocalAPIUnixClient(socketURL: URL(fileURLWithPath: tooLongPath))
                .requestLaunchingApplicationIfNeeded(
                    try localAPIRequest(method: .sessionStatus, requestID: "req-path"),
                    launchApplication: {
                        launchCount += 1
                        return true
                    }
                )
        )
        XCTAssertEqual(launchCount, 0)
    }

    func testStartupBudgetAndSlowOperationBudgetAreIndependent() throws {
        let clock = LockedTestClock()
        let socketURL = missingSocketURL()
        var server: OneShotUnixServer?
        defer { server = nil }
        let request = try localAPIRequest(method: .syncIncrementalAll, requestID: "req-sync")

        let response = try LocalAPIUnixClient(
            socketURL: socketURL,
            startupTimeout: 0.5,
            retryInterval: 0.49,
            operationTimeout: 0.8
        ).requestLaunchingApplicationIfNeeded(
            request,
            launchApplication: { true },
            now: { clock.now },
            sleep: { delay in
                clock.advance(by: delay)
                server = try? OneShotUnixServer(
                    socketURL: socketURL,
                    responsePayload: request,
                    beforeResponse: { clock.advance(by: 0.51) }
                )
            }
        )

        XCTAssertEqual(response, request)
        XCTAssertNotNil(server)
        XCTAssertEqual(clock.now, 1, accuracy: 0.000_001)
    }

    func testMethodOperationDeadlineExpiresWithoutAutomaticDirectSendRetry() throws {
        let server = try OneShotUnixServer()
        let request = Data(
            #"{"apiVersion":1,"requestID":"req-send","method":"reply.send","parameters":{"draftID":"draft-1","expectedHash":"hash-1","idempotencyKey":"attempt-1"}}"#.utf8
        )
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(
            try LocalAPIUnixClient(
                socketURL: server.socketURL,
                startupTimeout: 0.05,
                operationTimeout: 0.15
            ).requestLaunchingApplicationIfNeeded(
                request,
                launchApplication: {
                    XCTFail("An accepted direct-send request must not launch or retry")
                    return true
                }
            )
        ) { error in
            XCTAssertEqual(error as? LocalAPIUnixClientError, .deadlineExceeded)
        }

        XCTAssertEqual(server.requestPayloads, [request])
        let safeFailure = try JSONDecoder().decode(
            LocalAPIFailure.self,
            from: BrowserBridgeResponse.unavailable(for: request)
        )
        XCTAssertEqual(safeFailure.requestID, "req-send")
        XCTAssertEqual(safeFailure.error.code, .unavailable)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 0.1)
        XCTAssertLessThan(elapsed, 1)
    }

    func testProductionOperationDeadlinesAreMethodSpecificAndBounded() {
        let status = LocalAPIUnixClient.operationTimeout(for: .sessionStatus)
        let sync = LocalAPIUnixClient.operationTimeout(for: .syncIncrementalAll)
        let ai = LocalAPIUnixClient.operationTimeout(for: .aiDraftReply)
        let send = LocalAPIUnixClient.operationTimeout(for: .replySend)

        XCTAssertGreaterThan(sync, LocalAPIUnixClient.startupTimeout)
        XCTAssertGreaterThan(ai, LocalAPIUnixClient.startupTimeout)
        XCTAssertGreaterThan(send, LocalAPIUnixClient.startupTimeout)
        XCTAssertLessThan(status, sync)
        XCTAssertTrue([status, sync, ai, send].allSatisfy { $0.isFinite && $0 > 0 })
    }

    private func missingSocketURL() -> URL {
        URL(fileURLWithPath: "/tmp/ebu-missing-\(UUID().uuidString.prefix(8)).sock")
    }
}

private final class OneShotUnixServer: @unchecked Sendable {
    let socketURL: URL
    private let directoryURL: URL
    private let responseFrame: Data?
    private let beforeResponse: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.marynavdovenko.plainpost.browser-client-test")
    private let lock = NSLock()
    private var descriptor: Int32
    private var capturedRequestHeader: Data?
    private var capturedRequestPayloads: [Data] = []
    private var acceptedConnection = false

    var requestHeader: Data? {
        lock.withLock { capturedRequestHeader }
    }

    var didAcceptConnection: Bool {
        lock.withLock { acceptedConnection }
    }

    var requestPayloads: [Data] {
        lock.withLock { capturedRequestPayloads }
    }

    convenience init() throws {
        try self.init(responseFrame: nil, beforeResponse: {})
    }

    convenience init(responsePayload: Data) throws {
        var length = UInt32(responsePayload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(responsePayload)
        try self.init(responseFrame: frame, beforeResponse: {})
    }

    convenience init(
        socketURL: URL,
        responsePayload: Data,
        beforeResponse: @escaping @Sendable () -> Void
    ) throws {
        var length = UInt32(responsePayload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(responsePayload)
        try self.init(
            socketURL: socketURL,
            responseFrame: frame,
            beforeResponse: beforeResponse
        )
    }

    convenience init(responseLength: Int) throws {
        var length = UInt32(responseLength).bigEndian
        try self.init(
            responseFrame: withUnsafeBytes(of: &length) { Data($0) },
            beforeResponse: {}
        )
    }

    private convenience init(
        responseFrame: Data?,
        beforeResponse: @escaping @Sendable () -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ebu-\(UUID().uuidString.prefix(8))")
        try self.init(
            socketURL: directoryURL.appendingPathComponent("api.sock"),
            responseFrame: responseFrame,
            beforeResponse: beforeResponse
        )
    }

    private init(
        socketURL: URL,
        responseFrame: Data?,
        beforeResponse: @escaping @Sendable () -> Void
    ) throws {
        directoryURL = socketURL.deletingLastPathComponent()
        self.socketURL = socketURL
        self.responseFrame = responseFrame
        self.beforeResponse = beforeResponse
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXTestError(code: errno) }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var address = try Self.unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, Darwin.listen(descriptor, 1) == 0 else {
                throw POSIXTestError(code: errno)
            }
            queue.async { [self] in serve() }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        Darwin.unlink(socketURL.path)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func serve() {
        let connection = Darwin.accept(descriptor, nil, nil)
        guard connection >= 0 else { return }
        lock.withLock { acceptedConnection = true }
        defer { Darwin.close(connection) }
        guard let header = try? Self.readExactly(4, from: connection) else { return }
        lock.withLock { capturedRequestHeader = header }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let payload = try? Self.readExactly(Int(length), from: connection) else { return }
        lock.withLock { capturedRequestPayloads.append(payload) }
        if let responseFrame {
            beforeResponse()
            try? Self.writeAll(responseFrame, to: connection)
        } else {
            var byte: UInt8 = 0
            _ = Darwin.read(connection, &byte, 1)
        }
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXTestError(code: ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.memcpy(destination, source, bytes.count)
            }
        }
        return address
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXTestError(code: result == 0 ? EPIPE : errno) }
                offset += result
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXTestError(code: errno) }
                offset += result
            }
        }
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

private func localAPIRequest(
    method: LocalAPIMethod,
    requestID: String
) throws -> Data {
    try JSONEncoder().encode(
        LocalAPIRequest(
            requestID: requestID,
            method: method,
            parameters: LocalAPIEmptyParameters()
        )
    )
}

private struct POSIXTestError: Error {
    let code: Int32
}
