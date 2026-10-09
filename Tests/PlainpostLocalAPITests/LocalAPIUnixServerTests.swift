import Darwin
import Foundation
import XCTest
import PlainpostCore
import PlainpostLocalAPI
import PlainpostOperations
@testable import PlainpostLocalServer

final class LocalAPIUnixServerTests: XCTestCase {
    func testLifecycleLockContentionIsRetryableOwnershipContention() {
        XCTAssertTrue(
            LocalAPIUnixServerError(
                operation: "acquire lifecycle lock",
                code: EAGAIN
            ).isLifecycleLockContention
        )
        XCTAssertTrue(
            LocalAPIUnixServerError(
                operation: "acquire lifecycle lock",
                code: EACCES
            ).isLifecycleLockContention
        )
    }

    func testOtherLocalAPIErrorsAreNotOwnershipContention() {
        XCTAssertFalse(
            LocalAPIUnixServerError(
                operation: "bind socket",
                code: EADDRINUSE
            ).isLifecycleLockContention
        )
        XCTAssertFalse(
            LocalAPIUnixServerError(
                operation: "acquire lifecycle lock",
                code: EINVAL
            ).isLifecycleLockContention
        )
    }

    func testFrameCodecUsesFourByteBigEndianLength() throws {
        XCTAssertEqual(
            try LocalAPIFrameCodec.encode(Data([0x7b, 0x7d])),
            Data([0x00, 0x00, 0x00, 0x02, 0x7b, 0x7d])
        )
    }

    func testFrameCodecRejectsEmptyAndOversizePayloads() {
        XCTAssertThrowsError(try LocalAPIFrameCodec.encode(Data()))
        XCTAssertThrowsError(
            try LocalAPIFrameCodec.encode(
                Data(repeating: 0, count: LocalAPIProtocol.maximumFrameSize + 1)
            )
        )
    }

    func testFrameCodecRejectsZeroAndOversizeDeclaredLengths() {
        XCTAssertThrowsError(try LocalAPIFrameCodec.decodeLength(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try LocalAPIFrameCodec.decodeLength(Data([0, 0x10, 0, 1])))
    }

    func testServerCreatesPrivateDirectoryAndSocketAndRoundTripsStatus() async throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer()
        try server.start()
        defer { server.stop() }

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.directory.path
        )
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        let socketAttributes = try FileManager.default.attributesOfItem(
            atPath: server.socketURL.path
        )
        XCTAssertEqual(
            (socketAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        let response = try await TestLocalAPIUnixClient(socketURL: server.socketURL)
            .request(statusRequest())
        let decoded = try JSONDecoder().decode(
            LocalAPISuccess<LocalAPISessionStatus>.self,
            from: response
        )
        XCTAssertTrue(decoded.ok)
        XCTAssertTrue(decoded.result.ready)
    }

    func testServerAcceptsPartialFrameReadsAndWritesFramedResponse() async throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer()
        try server.start()
        defer { server.stop() }

        let response = try await TestLocalAPIUnixClient(socketURL: server.socketURL)
            .request(statusRequest(), writeChunkSize: 1, readChunkSize: 1)

        XCTAssertTrue(
            try JSONDecoder().decode(
                LocalAPISuccess<LocalAPISessionStatus>.self,
                from: response
            ).ok
        )
    }

    func testIdleAcceptedConnectionTimesOutWithinInboundFrameDeadline() throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer(inboundFrameTimeout: 0.1)
        try server.start()
        defer { server.stop() }
        let connection = try RawUnixConnection(socketURL: fixture.socketURL)

        XCTAssertTrue(waitUntil(timeout: 1) { server.activeConnectionCount == 1 })
        XCTAssertTrue(try connection.waitForPeerClose(timeout: 1))
        XCTAssertTrue(waitUntil(timeout: 1) { server.activeConnectionCount == 0 })
    }

    func testStopShutsDownEveryAcceptedConnection() throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer(inboundFrameTimeout: 5)
        try server.start()
        let first = try RawUnixConnection(socketURL: fixture.socketURL)
        let second = try RawUnixConnection(socketURL: fixture.socketURL)
        XCTAssertTrue(waitUntil(timeout: 1) { server.activeConnectionCount == 2 })

        server.stop()

        XCTAssertTrue(try first.waitForPeerClose(timeout: 1))
        XCTAssertTrue(try second.waitForPeerClose(timeout: 1))
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testStopCancelsAndWaitsForAdmittedRouteTask() async throws {
        let fixture = try ServerFixture()
        let route = CancellationObservedRoute()
        let server = try LocalAPIUnixServer(
            socketURL: fixture.socketURL,
            router: LocalAPIRouter(routes: [route]),
            inboundFrameTimeout: 1
        )
        try server.start()
        let connection = try RawUnixConnection(socketURL: fixture.socketURL)
        let requestTask = Task.detached {
            try? connection.request(statusRequest())
        }
        XCTAssertEqual(route.started.wait(timeout: .now() + 1), .success)
        let started = ProcessInfo.processInfo.systemUptime

        server.stop()

        XCTAssertEqual(route.cancelled.wait(timeout: .now() + 1), .success)
        _ = await requestTask.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testStopReturnsPromptlyWhileCoalescedSyncContinuesAfterRequestCancellation() async throws {
        let fixture = try ServerFixture()
        let syncer = SuspendedServerSyncer()
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("account-a")] },
            syncer: syncer
        )
        let server = try LocalAPIUnixServer(
            socketURL: fixture.socketURL,
            router: LocalAPIRouter(routes: [route]),
            inboundFrameTimeout: 1
        )
        try server.start()
        let connection = try RawUnixConnection(socketURL: fixture.socketURL)
        let requestTask = Task.detached {
            try? connection.request(incrementalSyncRequest())
        }
        await syncer.waitForCallCount(1)
        let stopReturned = DispatchSemaphore(value: 0)
        let stopTask = Task.detached {
            server.stop()
            stopReturned.signal()
        }

        let stoppedPromptly = await Task.detached {
            waitForSignal(stopReturned, timeout: 1)
        }.value
        let completionCountBeforeRelease = await syncer.completionCount
        await syncer.release()
        await syncer.waitForCompletionCount(1)
        _ = await stopTask.value
        _ = await requestTask.value
        let finalCallCount = await syncer.callCount
        let finalCompletionCount = await syncer.completionCount

        XCTAssertTrue(stoppedPromptly)
        XCTAssertEqual(completionCountBeforeRelease, 0)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(finalCompletionCount, 1)
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testStoppedServerCannotCloseReplacementServersAcceptedDescriptor() throws {
        let fixture = try ServerFixture()
        let firstServer = try fixture.makeServer(inboundFrameTimeout: 0.15)
        try firstServer.start()
        let firstConnection = try RawUnixConnection(socketURL: fixture.socketURL)
        XCTAssertTrue(waitUntil(timeout: 1) { firstServer.activeConnectionCount == 1 })

        firstServer.stop()
        XCTAssertTrue(try firstConnection.waitForPeerClose(timeout: 1))

        let replacementServer = try fixture.makeServer(inboundFrameTimeout: 1)
        try replacementServer.start()
        defer { replacementServer.stop() }
        let replacementConnection = try RawUnixConnection(socketURL: fixture.socketURL)
        XCTAssertTrue(waitUntil(timeout: 1) { replacementServer.activeConnectionCount == 1 })
        Thread.sleep(forTimeInterval: 0.25)

        let response = try replacementConnection.request(statusRequest())

        XCTAssertTrue(
            try JSONDecoder().decode(
                LocalAPISuccess<LocalAPISessionStatus>.self,
                from: response
            ).ok
        )
    }

    func testServerRemovesStaleSocketBeforeBinding() async throws {
        let fixture = try ServerFixture()
        try makeStaleSocket(at: fixture.socketURL)

        let server = try fixture.makeServer()
        try server.start()
        defer { server.stop() }

        let response = try await TestLocalAPIUnixClient(socketURL: server.socketURL)
            .request(statusRequest())
        XCTAssertFalse(response.isEmpty)
    }

    func testStaleSocketCleanupRequiresEffectiveUserOwnership() {
        XCTAssertNoThrow(
            try LocalAPIUnixServer.requireOwnedStaleSocket(ownerUID: geteuid())
        )
        let foreignUID = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        XCTAssertThrowsError(
            try LocalAPIUnixServer.requireOwnedStaleSocket(ownerUID: foreignUID)
        )
    }

    func testServerRefusesToReplaceNonSocketPath() throws {
        let fixture = try ServerFixture()
        try Data("not a socket".utf8).write(to: fixture.socketURL)
        let server = try fixture.makeServer()

        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(
            try Data(contentsOf: fixture.socketURL),
            Data("not a socket".utf8)
        )
        let lockProbe = try CrossProcessSocketLockHelper(
            script: .tryLock,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { lockProbe.stop() }
        XCTAssertEqual(try lockProbe.readLine(), "ACQUIRED")
    }

    func testFailedSecondServerNeverUnlinksFirstServersSocket() async throws {
        let fixture = try ServerFixture()
        let first = try fixture.makeServer()
        try first.start()
        defer { first.stop() }

        var second: LocalAPIUnixServer? = try fixture.makeServer()
        XCTAssertThrowsError(try second?.start())
        second?.stop()
        second = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        let lockProbe = try CrossProcessSocketLockHelper(
            script: .tryLock,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { lockProbe.stop() }
        XCTAssertEqual(try lockProbe.readLine(), "LOCKED")
        let response = try await TestLocalAPIUnixClient(socketURL: fixture.socketURL)
            .request(statusRequest())
        XCTAssertFalse(response.isEmpty)
    }

    func testIntermediateSymlinkAliasCannotReleaseActiveLifecycleLock() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ela-alias-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let realRootURL = rootURL.appendingPathComponent("real", isDirectory: true)
        let realDirectoryURL = realRootURL.appendingPathComponent("nested", isDirectory: true)
        let aliasRootURL = rootURL.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasRootURL,
            withDestinationURL: realRootURL
        )
        let realSocketURL = realDirectoryURL.appendingPathComponent("api.sock")
        let aliasSocketURL = aliasRootURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("api.sock")
        let first = try LocalAPIUnixServer(
            socketURL: realSocketURL,
            router: LocalAPIRouter(routes: [SessionStatusRoute()])
        )
        try first.start()
        defer { first.stop() }
        let second = try LocalAPIUnixServer(
            socketURL: aliasSocketURL,
            router: LocalAPIRouter(routes: [SessionStatusRoute()])
        )

        XCTAssertThrowsError(try second.start())

        let lockProbe = try CrossProcessSocketLockHelper(
            script: .tryLock,
            socketURL: realSocketURL,
            lockURL: realDirectoryURL.appendingPathComponent("api.lock")
        )
        defer { lockProbe.stop() }
        XCTAssertEqual(try lockProbe.readLine(), "LOCKED")
    }

    func testEncodedSocketURLAliasUsesSameLifecycleLockBeforeStaleInspection() throws {
        let fixture = try ServerFixture()
        let encodedURLString = fixture.socketURL.absoluteString.replacingOccurrences(
            of: "api.sock",
            with: "api%2Esock"
        )
        let encodedSocketURL = try XCTUnwrap(URL(string: encodedURLString))
        XCTAssertNotEqual(encodedSocketURL.absoluteString, fixture.socketURL.absoluteString)
        XCTAssertEqual(encodedSocketURL.path, fixture.socketURL.path)
        let holder = try CrossProcessSocketLockHelper(
            script: .holdLockAndBoundSocket,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { holder.stop() }
        XCTAssertEqual(try holder.readLine(), "READY")
        let originalIdentity = try socketIdentity(at: fixture.socketURL)
        let server = try LocalAPIUnixServer(
            socketURL: encodedSocketURL,
            router: LocalAPIRouter(routes: [SessionStatusRoute()])
        )
        defer { server.stop() }

        XCTAssertEqual(server.lockURL.path, fixture.lockURL.path)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try socketIdentity(at: fixture.socketURL), originalIdentity)

        let lockProbe = try CrossProcessSocketLockHelper(
            script: .tryLock,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { lockProbe.stop() }
        XCTAssertEqual(try lockProbe.readLine(), "LOCKED")
    }

    func testCrossProcessLockPreventsUnlinkDuringBindBeforeListenWindow() throws {
        let fixture = try ServerFixture()
        let holder = try CrossProcessSocketLockHelper(
            script: .holdLockAndBoundSocket,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { holder.stop() }
        XCTAssertEqual(try holder.readLine(), "READY")
        let originalIdentity = try socketIdentity(at: fixture.socketURL)
        let server = try fixture.makeServer()
        defer { server.stop() }

        XCTAssertThrowsError(try server.start())

        XCTAssertEqual(try socketIdentity(at: fixture.socketURL), originalIdentity)
    }

    func testCrossProcessWaiterBindsOnlyAfterStopCleanupCompletes() throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer()
        try server.start()
        let waiter = try CrossProcessSocketLockHelper(
            script: .waitForLockThenBind,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer {
            waiter.stop()
            server.stop()
        }
        XCTAssertEqual(try waiter.readLine(), "BLOCKED")

        server.stop()

        XCTAssertEqual(try waiter.readLine(), "BOUND")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testCrossProcessCrashReleasesLockAndStaleSocketIsRecovered() throws {
        let fixture = try ServerFixture()
        let holder = try CrossProcessSocketLockHelper(
            script: .holdLockAndBoundSocket,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        XCTAssertEqual(try holder.readLine(), "READY")
        holder.stop(signal: SIGKILL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        let server = try fixture.makeServer()
        try server.start()
        defer { server.stop() }

        let probe = try CrossProcessSocketLockHelper(
            script: .tryLock,
            socketURL: fixture.socketURL,
            lockURL: fixture.lockURL
        )
        defer { probe.stop() }
        XCTAssertEqual(try probe.readLine(), "LOCKED")
    }

    func testServerRejectsLifecycleLockWithUnsafeMode() throws {
        let fixture = try ServerFixture()
        try Data().write(to: fixture.lockURL)
        XCTAssertEqual(Darwin.chmod(fixture.lockURL.path, 0o644), 0)
        let server = try fixture.makeServer()

        XCTAssertThrowsError(try server.start())

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testServerRejectsDirectoryAtLifecycleLockPath() throws {
        let fixture = try ServerFixture()
        try FileManager.default.createDirectory(at: fixture.lockURL, withIntermediateDirectories: false)
        let server = try fixture.makeServer()

        XCTAssertThrowsError(try server.start())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.lockURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testServerRejectsSymlinkAtLifecycleLockPathWithoutFollowing() throws {
        let fixture = try ServerFixture()
        let targetURL = fixture.directory.appendingPathComponent("lock-target")
        try Data("unchanged".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.lockURL,
            withDestinationURL: targetURL
        )
        let server = try fixture.makeServer()

        XCTAssertThrowsError(try server.start())

        XCTAssertEqual(try Data(contentsOf: targetURL), Data("unchanged".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testLifecycleLockMetadataRequiresEffectiveUserOwner() {
        let safeMode = mode_t(S_IFREG | 0o600)
        XCTAssertNoThrow(
            try LocalAPIUnixServer.requireSafeLifecycleLock(
                ownerUID: geteuid(),
                mode: safeMode
            )
        )
        let foreignUID = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        XCTAssertThrowsError(
            try LocalAPIUnixServer.requireSafeLifecycleLock(
                ownerUID: foreignUID,
                mode: safeMode
            )
        )
    }

    func testStopIsIdempotentAndRemovesOwnedSocket() throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer()
        try server.start()

        server.stop()
        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testStopDoesNotUnlinkReplacementSocket() throws {
        let fixture = try ServerFixture()
        let server = try fixture.makeServer()
        try server.start()
        XCTAssertEqual(Darwin.unlink(fixture.socketURL.path), 0)
        try makeStaleSocket(at: fixture.socketURL)

        server.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        XCTAssertEqual(Darwin.unlink(fixture.socketURL.path), 0)
    }

    func testDeinitStopsServerAndRemovesOwnedSocket() throws {
        let fixture = try ServerFixture()
        var server: LocalAPIUnixServer? = try fixture.makeServer()
        try server?.start()
        let connection = try RawUnixConnection(socketURL: fixture.socketURL)
        _ = try connection.request(statusRequest())
        XCTAssertTrue(waitUntil(timeout: 1) { server?.activeConnectionCount == 0 })

        server = nil

        XCTAssertTrue(waitUntil(timeout: 1) {
            !FileManager.default.fileExists(atPath: fixture.socketURL.path)
        })
    }
}

private final class ServerFixture {
    let directory: URL
    let socketURL: URL
    let lockURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ela-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socketURL = directory.appendingPathComponent("api.sock")
        lockURL = directory.appendingPathComponent("api.lock")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeServer(inboundFrameTimeout: TimeInterval = 5) throws -> LocalAPIUnixServer {
        try LocalAPIUnixServer(
            socketURL: socketURL,
            router: LocalAPIRouter(routes: [SessionStatusRoute()]),
            inboundFrameTimeout: inboundFrameTimeout
        )
    }
}

private final class RawUnixConnection: @unchecked Sendable {
    private var descriptor: Int32

    init(socketURL: URL) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXTestError(function: "socket") }
        do {
            var address = try unixAddress(path: socketURL.path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard connected == 0 else { throw POSIXTestError(function: "connect") }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func waitForPeerClose(timeout: TimeInterval) throws -> Bool {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let result = Darwin.poll(
            &pollDescriptor,
            1,
            Int32(ceil(timeout * 1_000))
        )
        guard result >= 0 else { throw POSIXTestError(function: "poll") }
        guard result > 0 else { return false }
        var byte: UInt8 = 0
        let received = Darwin.read(descriptor, &byte, 1)
        if received < 0, errno == ECONNRESET { return true }
        return received == 0
    }

    func request(_ payload: Data) throws -> Data {
        try writeAll(
            try LocalAPIFrameCodec.encode(payload),
            descriptor: descriptor,
            maximumChunkSize: .max
        )
        let header = try readExactly(
            count: LocalAPIFrameCodec.headerSize,
            descriptor: descriptor,
            maximumChunkSize: .max
        )
        return try readExactly(
            count: LocalAPIFrameCodec.decodeLength(header),
            descriptor: descriptor,
            maximumChunkSize: .max
        )
    }
}

private struct CancellationObservedRoute: LocalAPIRoute {
    let method = LocalAPIMethod.sessionStatus
    let started = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)

    func handle(requestData: Data, requestID: String) async throws -> Data {
        started.signal()
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(10))
            return Data()
        } onCancel: {
            cancelled.signal()
        }
    }
}

private actor SuspendedServerSyncer: PlainpostOperationClientProtocol {
    private var callCountValue = 0
    private var completionCountValue = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var callCount: Int { callCountValue }
    var completionCount: Int { completionCountValue }

    func waitForCallCount(_ expected: Int) async {
        while callCountValue < expected {
            await Task.yield()
        }
    }

    func waitForCompletionCount(_ expected: Int) async {
        while completionCountValue < expected {
            await Task.yield()
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        callCountValue += 1
        await withCheckedContinuation { releaseContinuation = $0 }
        completionCountValue += 1
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: 1,
            newlyDiscoveredMessageCount: 1,
            jobID: "job-\(input.accountID.rawValue)"
        )
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw ServerSyncTestError.unavailable
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw ServerSyncTestError.unavailable
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw ServerSyncTestError.unavailable
    }
}

private enum ServerSyncTestError: Error {
    case unavailable
}

private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private final class CrossProcessSocketLockHelper {
    enum Script {
        case holdLockAndBoundSocket
        case waitForLockThenBind
        case tryLock

        var argument: String {
            switch self {
            case .holdLockAndBoundSocket:
                return "hold-bound"
            case .waitForLockThenBind:
                return "wait-bind"
            case .tryLock:
                return "try-lock"
            }
        }
    }

    private let process = Process()
    private let output = Pipe()

    init(script: Script, socketURL: URL, lockURL: URL) throws {
        process.executableURL = try Self.helperExecutableURL()
        process.arguments = [script.argument, socketURL.path, lockURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    private static func helperExecutableURL() throws -> URL {
        let candidate = Bundle(for: LocalAPIUnixServerTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PlainpostLocalServerTestHelper")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw POSIXTestError(function: "locate Swift test helper", code: ENOENT)
        }
        return candidate
    }

    deinit {
        stop()
    }

    func readLine(timeout: TimeInterval = 5) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw POSIXTestError(function: "read child output", code: ETIMEDOUT)
            }
            var pollDescriptor = pollfd(
                fd: output.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let timeoutMilliseconds = Int32(
                min(ceil(remaining * 1_000), Double(Int32.max))
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                throw POSIXTestError(
                    function: "poll child output",
                    code: pollResult == 0 ? ETIMEDOUT : errno
                )
            }
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else {
                throw POSIXTestError(function: "read child output", code: EPIPE)
            }
            if byte == Data([0x0A]) {
                return String(decoding: data, as: UTF8.self)
            }
            data.append(byte)
        }
    }

    func stop(signal: Int32 = SIGTERM) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, signal)
        if !waitForExit(timeout: signal == SIGKILL ? 2 : 0.5) {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(timeout: 2)
        }
    }

    private func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline {
            Darwin.usleep(10_000)
        }
        return !process.isRunning
    }
}

private struct TestLocalAPIUnixClient: Sendable {
    let socketURL: URL

    func request(
        _ payload: Data,
        writeChunkSize: Int = .max,
        readChunkSize: Int = .max
    ) async throws -> Data {
        try await Task.detached {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXTestError(function: "socket") }
            defer { Darwin.close(descriptor) }

            var address = try unixAddress(path: socketURL.path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard connected == 0 else { throw POSIXTestError(function: "connect") }

            try writeAll(
                try LocalAPIFrameCodec.encode(payload),
                descriptor: descriptor,
                maximumChunkSize: writeChunkSize
            )
            let header = try readExactly(
                count: 4,
                descriptor: descriptor,
                maximumChunkSize: readChunkSize
            )
            let length = try LocalAPIFrameCodec.decodeLength(header)
            return try readExactly(
                count: length,
                descriptor: descriptor,
                maximumChunkSize: readChunkSize
            )
        }.value
    }
}

private struct POSIXTestError: Error {
    let function: String
    let code: Int32

    init(function: String, code: Int32 = errno) {
        self.function = function
        self.code = code
    }
}

private func statusRequest() throws -> Data {
    try JSONEncoder().encode(
        LocalAPIRequest(
            requestID: "req-status",
            method: .sessionStatus,
            parameters: LocalAPIEmptyParameters()
        )
    )
}

private func incrementalSyncRequest() throws -> Data {
    try JSONEncoder().encode(
        LocalAPIRequest(
            requestID: "req-sync",
            method: .syncIncrementalAll,
            parameters: LocalAPIEmptyParameters()
        )
    )
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXTestError(function: "unixAddress", code: ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
    }
    return address
}

private func makeStaleSocket(at socketURL: URL) throws {
    try FileManager.default.createDirectory(
        at: socketURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXTestError(function: "socket") }
    defer { Darwin.close(descriptor) }
    var address = try unixAddress(path: socketURL.path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw POSIXTestError(function: "bind") }
}

private func socketIdentity(at socketURL: URL) throws -> String {
    var status = stat()
    guard Darwin.lstat(socketURL.path, &status) == 0 else {
        throw POSIXTestError(function: "lstat")
    }
    return "\(status.st_dev):\(status.st_ino)"
}

private func writeAll(
    _ data: Data,
    descriptor: Int32,
    maximumChunkSize: Int
) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = min(bytes.count - offset, maximumChunkSize)
            let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), count)
            guard written > 0 else { throw POSIXTestError(function: "write") }
            offset += written
        }
    }
}

private func readExactly(
    count: Int,
    descriptor: Int32,
    maximumChunkSize: Int
) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < count {
            let chunkSize = min(count - offset, maximumChunkSize)
            let received = Darwin.read(
                descriptor,
                baseAddress.advanced(by: offset),
                chunkSize
            )
            guard received > 0 else { throw POSIXTestError(function: "read") }
            offset += received
        }
    }
    return data
}
