import Darwin
import Foundation
import XCTest
@testable import PlainpostBrowserIntegration
import PlainpostLocalAPI

final class BrowserBridgeProcessTests: XCTestCase {
    func testUnavailableResponseIsSafeAndCorrelated() throws {
        let request = Data(#"{"apiVersion":1,"requestID":"req-7","method":"session.status","parameters":{}}"#.utf8)

        let data = BrowserBridgeResponse.unavailable(for: request)
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.requestID, "req-7")
        XCTAssertEqual(failure.error.code, .unavailable)
        XCTAssertEqual(failure.error.message, "Plainpost is unavailable.")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("errno"))
    }

    func testUnavailableResponseCorrelatesBoundaryAndUUIDRequestIDs() throws {
        XCTAssertEqual(BrowserBridgeResponse.maximumRequestIDUTF8Bytes, 128)
        let identifiers = [
            UUID().uuidString,
            String(repeating: "é", count: 64),
        ]

        for requestID in identifiers {
            let request = Data(#"{"apiVersion":1,"requestID":"\#(requestID)"}"#.utf8)
            let data = BrowserBridgeResponse.unavailable(for: request)
            let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

            XCTAssertEqual(failure.requestID, requestID)
            XCTAssertLessThanOrEqual(data.count, LocalAPIProtocol.maximumFrameSize)
        }
    }

    func testUnavailableResponseDropsOversizeRequestIDAndRemainsEncodable() throws {
        let requestID = String(repeating: "x", count: 129)
        let request = Data(#"{"apiVersion":1,"requestID":"\#(requestID)"}"#.utf8)

        let data = BrowserBridgeResponse.unavailable(for: request)
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: data)

        XCTAssertNil(failure.requestID)
        XCTAssertEqual(failure.error.code, .unavailable)
        XCTAssertLessThanOrEqual(data.count, LocalAPIProtocol.maximumFrameSize)
    }

    func testRuntimeRejectsOversizeRequestIDBeforeUnixForwarding() throws {
        let fixture = try ProcessFixture()
        let server = try EchoUnixServer(socketURL: fixture.socketURL, requestCount: 0)
        let requestID = String(repeating: "x", count: 129)
        let request = Data(#"{"apiVersion":1,"requestID":"\#(requestID)"}"#.utf8)

        let result = try runUnlockedRuntime(
            homeURL: fixture.homeURL,
            input: try NativeMessagingFrameCodec.encode(request)
        )

        XCTAssertEqual(result.status, 0, result.output)
        var output = result.data
        let response = try XCTUnwrap(NativeMessagingFrameCodec.readFrame { count in
            let chunk = output.prefix(count)
            output.removeFirst(chunk.count)
            return Data(chunk)
        })
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: response)
        XCTAssertNil(failure.requestID)
        XCTAssertEqual(failure.error.code, .invalidRequest)
        XCTAssertEqual(server.requestCount, 0)
    }

    func testProcessCannotUseInheritedEnvironmentToBypassVaultGate()
        throws
    {
        let fixture = try ProcessFixture()
        let request = try bridgeRequest(
            requestID: "environment-bypass",
            method: .sessionStatus
        )
        let server = try EchoUnixServer(
            socketURL: fixture.socketURL,
            requestCount: 1
        )

        let result = try runBridge(
            arguments: [BrowserCallerValidator.chromiumOrigin],
            homeURL: fixture.homeURL,
            input: try NativeMessagingFrameCodec.encode(request),
            environment: [
                "PLAINPOST_BROWSER_BRIDGE_TEST_VAULT": "unlocked",
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let responses = try decodeNativeFrames(result.data)
        let failure = try JSONDecoder().decode(
            LocalAPIFailure.self,
            from: try XCTUnwrap(responses.first)
        )
        XCTAssertEqual(failure.requestID, "environment-bypass")
        XCTAssertEqual(failure.error.code, .unavailable)
        XCTAssertEqual(server.requestCount, 0)
    }

    func testInvalidCallerExitsBeforeReadingStandardInput() throws {
        let process = Process()
        process.executableURL = try bridgeExecutableURL()
        process.arguments = ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        XCTAssertTrue(waitForExit(process, timeout: 1))
        XCTAssertNotEqual(process.terminationStatus, 0)
        try input.fileHandleForWriting.close()
    }

    func testInstallModeWritesUserLevelManifests() throws {
        let fixture = try ProcessFixture()
        let executable = try bridgeExecutableURL()

        let result = try runBridge(
            arguments: ["--install-hosts", "--executable", executable.path],
            homeURL: fixture.homeURL
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeURL
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeURL
            .appendingPathComponent("Library/Application Support/zen/NativeMessagingHosts/com.marynavdovenko.plainpost.browser.json").path))
    }

    func testRuntimeForwardsMultipleNativeRequestsOverBigEndianUnixFrames() throws {
        let fixture = try ProcessFixture()
        let first = try bridgeRequest(requestID: "one", method: .sessionStatus)
        let second = try bridgeRequest(requestID: "two", method: .mailUnreadList)
        let server = try EchoUnixServer(socketURL: fixture.socketURL, requestCount: 2)
        var input = try NativeMessagingFrameCodec.encode(first)
        input.append(try NativeMessagingFrameCodec.encode(second))

        let result = try runUnlockedRuntime(
            homeURL: fixture.homeURL,
            input: input
        )

        XCTAssertEqual(result.status, 0, result.output)
        var outputData = result.data
        let receivedFirst = try NativeMessagingFrameCodec.readFrame { count in
            let chunk = outputData.prefix(count)
            outputData.removeFirst(chunk.count)
            return Data(chunk)
        }
        let receivedSecond = try NativeMessagingFrameCodec.readFrame { count in
            let chunk = outputData.prefix(count)
            outputData.removeFirst(chunk.count)
            return Data(chunk)
        }
        XCTAssertEqual(
            Set(try [XCTUnwrap(receivedFirst), XCTUnwrap(receivedSecond)]),
            Set([first, second])
        )
        XCTAssertTrue(outputData.isEmpty)
        XCTAssertEqual(server.requestCount, 2)
    }

    func testRuntimeCompletesQuickOpenBeforeDelayedSyncWithCorrelatedSerializedFrames() throws {
        let fixture = try ProcessFixture()
        let slow = try bridgeRequest(requestID: "slow-sync", method: .syncIncrementalAll)
        let quick = try bridgeRequest(requestID: "quick-open", method: .mailOpen)
        let server = try ConcurrentEchoUnixServer(
            socketURL: fixture.socketURL,
            expectedRequestCount: 2,
            delaysByRequestID: ["slow-sync": 0.3, "quick-open": 0.01]
        )
        var input = try NativeMessagingFrameCodec.encode(slow)
        input.append(try NativeMessagingFrameCodec.encode(quick))

        let result = try runUnlockedRuntime(
            homeURL: fixture.homeURL,
            input: input
        )

        XCTAssertEqual(result.status, 0, result.output)
        let responses = try decodeNativeFrames(result.data)
        XCTAssertEqual(responses, [quick, slow])
        XCTAssertEqual(server.maximumConcurrentRequestCount, 2)
    }

    func testRuntimeBoundsInFlightWorkAndWaitsForAllAdmittedRequestsAtEOF() throws {
        XCTAssertEqual(BrowserBridgeRuntime.maximumInFlightRequestCount, 8)
        let fixture = try ProcessFixture()
        let requests = try (0..<12).map {
            try bridgeRequest(requestID: "req-\($0)", method: .sessionStatus)
        }
        let server = try ConcurrentEchoUnixServer(
            socketURL: fixture.socketURL,
            expectedRequestCount: requests.count,
            delaysByRequestID: Dictionary(
                uniqueKeysWithValues: requests.indices.map { ("req-\($0)", 0.08) }
            )
        )
        let input = try requests.reduce(into: Data()) { frames, request in
            frames.append(try NativeMessagingFrameCodec.encode(request))
        }

        let result = try runUnlockedRuntime(
            homeURL: fixture.homeURL,
            input: input
        )

        XCTAssertEqual(result.status, 0, result.output)
        let responses = try decodeNativeFrames(result.data)
        XCTAssertEqual(Set(responses), Set(requests))
        XCTAssertEqual(responses.count, requests.count)
        XCTAssertGreaterThan(server.maximumConcurrentRequestCount, 1)
        XCTAssertLessThanOrEqual(
            server.maximumConcurrentRequestCount,
            BrowserBridgeRuntime.maximumInFlightRequestCount
        )
    }

    func testRuntimeMalformedTrailingFrameFailsAfterAdmittedWorkFinishes() throws {
        let fixture = try ProcessFixture()
        let request = try bridgeRequest(requestID: "admitted", method: .sessionStatus)
        let server = try ConcurrentEchoUnixServer(
            socketURL: fixture.socketURL,
            expectedRequestCount: 1,
            delaysByRequestID: ["admitted": 0.1]
        )
        var input = try NativeMessagingFrameCodec.encode(request)
        input.append(Data([10, 0, 0, 0, 0x7B]))

        let result = try runUnlockedRuntime(
            homeURL: fixture.homeURL,
            input: input
        )

        XCTAssertEqual(result.status, EX_DATAERR, result.output)
        XCTAssertEqual(try decodeNativeFrames(result.data), [request])
        XCTAssertEqual(server.requestCount, 1)
    }

    func testOutputFailureStopsQueuedRequestsBeforeForwarding() throws {
        let requests = (0..<12).map { Data([UInt8($0)]) }
        var remaining = requests
        let forwarded = LockedBytes()
        let releaseWorkers = DispatchSemaphore(value: 0)

        XCTAssertThrowsError(
            try BrowserBridgeRuntime.run(
                readFrame: {
                    remaining.isEmpty ? nil : remaining.removeFirst()
                },
                vaultIsUnlocked: { true },
                lockedResponse: {
                    BrowserBridgeResponse.unavailable(for: $0)
                },
                forward: { request in
                    let identifier = request[0]
                    forwarded.append(identifier)
                    if identifier != 0 {
                        releaseWorkers.wait()
                    }
                    return request
                },
                writeFrame: { _ in
                    throw ProcessTestError(code: EPIPE)
                },
                onOutputFailure: {
                    for _ in 0..<BrowserBridgeRuntime.maximumInFlightRequestCount {
                        releaseWorkers.signal()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is BrowserBridgeRuntimeError)
        }

        XCTAssertTrue(forwarded.values.contains(0))
        XCTAssertTrue(forwarded.values.allSatisfy {
            $0 < UInt8(BrowserBridgeRuntime.maximumInFlightRequestCount)
        })
        XCTAssertFalse(forwarded.values.contains(8))
    }

    func testLockedVaultReturnsQuietFailureWithoutForwarding() throws {
        let request = Data(
            #"{"apiVersion":1,"requestID":"locked","method":"reply.send","parameters":{}}"#.utf8
        )
        var remaining = [request]
        let forwarded = LockedBytes()
        let responses = LockedFrames()

        try BrowserBridgeRuntime.run(
            readFrame: {
                remaining.isEmpty ? nil : remaining.removeFirst()
            },
            vaultIsUnlocked: { false },
            lockedResponse: { BrowserBridgeResponse.unavailable(for: $0) },
            forward: {
                forwarded.append(1)
                return $0
            },
            writeFrame: { responses.append($0) }
        )

        XCTAssertEqual(forwarded.values, [])
        let failure = try JSONDecoder().decode(
            LocalAPIFailure.self,
            from: try XCTUnwrap(responses.values.first)
        )
        XCTAssertEqual(failure.requestID, "locked")
        XCTAssertEqual(failure.error.code, .unavailable)
    }

    private func bridgeExecutableURL() throws -> URL {
        let candidate = Bundle(for: BrowserBridgeProcessTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PlainpostBrowserBridge")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw ProcessTestError(code: ENOENT)
        }
        return candidate
    }

    private func runBridge(
        arguments: [String],
        homeURL: URL,
        input: Data? = nil,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, data: Data, output: String) {
        let process = Process()
        process.executableURL = try bridgeExecutableURL()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["HOME": homeURL.path]) { _, new in new }
            .merging(environment) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        XCTAssertTrue(waitForExit(process, timeout: 5))
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            data,
            String(decoding: data + errorData, as: UTF8.self)
        )
    }

    private func runUnlockedRuntime(
        homeURL: URL,
        input: Data
    ) throws -> (status: Int32, data: Data, output: String) {
        var remaining = input
        let output = LockedData()
        let client = LocalAPIUnixClient(
            socketURL: homeURL.appendingPathComponent(
                "Library/Application Support/Plainpost/LocalAPI-v1.sock"
            )
        )
        do {
            try BrowserBridgeRuntime.run(
                readFrame: {
                    try NativeMessagingFrameCodec.readFrame { count in
                        let chunk = remaining.prefix(count)
                        remaining.removeFirst(chunk.count)
                        return Data(chunk)
                    }
                },
                vaultIsUnlocked: { true },
                lockedResponse: {
                    BrowserBridgeResponse.unavailable(for: $0)
                },
                forward: { request in
                    guard BrowserBridgeResponse
                        .isRequestAllowedForForwarding(request)
                    else {
                        return BrowserBridgeResponse.invalidRequest()
                    }
                    do {
                        return try client.request(request)
                    } catch {
                        return BrowserBridgeResponse.unavailable(for: request)
                    }
                },
                writeFrame: {
                    output.append(
                        try NativeMessagingFrameCodec.encode($0)
                    )
                }
            )
            return (0, output.value, String(decoding: output.value, as: UTF8.self))
        } catch {
            return (
                EX_DATAERR,
                output.value,
                String(describing: error)
            )
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return false
        }
        return true
    }
}

private func bridgeRequest(
    requestID: String,
    method: LocalAPIMethod
) throws -> Data {
    try JSONEncoder().encode(
        LocalAPIRequest(
            requestID: requestID,
            method: method,
            parameters: LocalAPIEmptyParameters()
        )
    )
}

private func decodeNativeFrames(_ data: Data) throws -> [Data] {
    var remaining = data
    var frames: [Data] = []
    while !remaining.isEmpty {
        let frame = try XCTUnwrap(NativeMessagingFrameCodec.readFrame { count in
            let chunk = remaining.prefix(count)
            remaining.removeFirst(chunk.count)
            return Data(chunk)
        })
        frames.append(frame)
    }
    return frames
}

private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var values: [UInt8] { lock.withLock { storage } }

    func append(_ value: UInt8) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class ProcessFixture {
    let rootURL: URL
    let homeURL: URL
    let socketURL: URL

    init() throws {
        rootURL = URL(fileURLWithPath: "/tmp/ebp-\(UUID().uuidString.prefix(8))")
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        socketURL = homeURL.appendingPathComponent(
            "Library/Application Support/Plainpost/LocalAPI-v1.sock"
        )
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class EchoUnixServer: @unchecked Sendable {
    let socketURL: URL
    private let expectedRequestCount: Int
    private let queue = DispatchQueue(label: "com.marynavdovenko.plainpost.browser-process-test")
    private let lock = NSLock()
    private var descriptor: Int32
    private var capturedRequestCount = 0

    var requestCount: Int { lock.withLock { capturedRequestCount } }

    init(socketURL: URL, requestCount: Int) throws {
        self.socketURL = socketURL
        expectedRequestCount = requestCount
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProcessTestError(code: errno) }
        do {
            var address = try Self.unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, Darwin.listen(descriptor, 2) == 0 else {
                throw ProcessTestError(code: errno)
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
    }

    private func serve() {
        for _ in 0..<expectedRequestCount {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            guard let header = try? Self.readExactly(4, from: connection) else { return }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let payload = try? Self.readExactly(Int(length), from: connection) else { return }
            lock.withLock { capturedRequestCount += 1 }
            var responseLength = UInt32(payload.count).bigEndian
            var response = withUnsafeBytes(of: &responseLength) { Data($0) }
            response.append(payload)
            try? Self.writeAll(response, to: connection)
        }
    }

    fileprivate static func unixAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ProcessTestError(code: ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.memcpy(destination, source, bytes.count)
            }
        }
        return address
    }

    fileprivate static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, bytes.baseAddress?.advanced(by: offset), count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ProcessTestError(code: result == 0 ? EPIPE : errno) }
                offset += result
            }
        }
        return data
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ProcessTestError(code: errno) }
                offset += result
            }
        }
    }
}

private final class ConcurrentEchoUnixServer: @unchecked Sendable {
    let socketURL: URL
    private let expectedRequestCount: Int
    private let delaysByRequestID: [String: TimeInterval]
    private let acceptQueue = DispatchQueue(label: "com.marynavdovenko.plainpost.browser-process-concurrent-accept")
    private let workerQueue = DispatchQueue(
        label: "com.marynavdovenko.plainpost.browser-process-concurrent-worker",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var descriptor: Int32
    private var capturedRequestCount = 0
    private var activeRequestCount = 0
    private var capturedMaximumConcurrentRequestCount = 0

    var requestCount: Int { lock.withLock { capturedRequestCount } }
    var maximumConcurrentRequestCount: Int {
        lock.withLock { capturedMaximumConcurrentRequestCount }
    }

    init(
        socketURL: URL,
        expectedRequestCount: Int,
        delaysByRequestID: [String: TimeInterval]
    ) throws {
        self.socketURL = socketURL
        self.expectedRequestCount = expectedRequestCount
        self.delaysByRequestID = delaysByRequestID
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProcessTestError(code: errno) }
        do {
            var address = try EchoUnixServer.unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, Darwin.listen(descriptor, 16) == 0 else {
                throw ProcessTestError(code: errno)
            }
            acceptQueue.async { [self] in acceptRequests() }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit {
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        Darwin.unlink(socketURL.path)
    }

    private func acceptRequests() {
        for _ in 0..<expectedRequestCount {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            workerQueue.async { [self] in handle(connection) }
        }
    }

    private func handle(_ connection: Int32) {
        defer { Darwin.close(connection) }
        guard let header = try? EchoUnixServer.readExactly(4, from: connection)
        else { return }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let payload = try? EchoUnixServer.readExactly(
            Int(length),
            from: connection
        ) else { return }
        let requestID = (try? JSONDecoder().decode(LocalAPIRequestHeader.self, from: payload))?.requestID
        lock.withLock {
            capturedRequestCount += 1
            activeRequestCount += 1
            capturedMaximumConcurrentRequestCount = max(
                capturedMaximumConcurrentRequestCount,
                activeRequestCount
            )
        }
        defer { lock.withLock { activeRequestCount -= 1 } }
        Thread.sleep(forTimeInterval: requestID.flatMap { delaysByRequestID[$0] } ?? 0)
        var responseLength = UInt32(payload.count).bigEndian
        var response = withUnsafeBytes(of: &responseLength) { Data($0) }
        response.append(payload)
        try? EchoUnixServer.writeAll(response, to: connection)
    }
}

private struct ProcessTestError: Error {
    let code: Int32
}
