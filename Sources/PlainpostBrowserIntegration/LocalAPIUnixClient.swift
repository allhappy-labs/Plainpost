import Darwin
import Foundation
import PlainpostLocalAPI

public enum LocalAPIUnixClientError: Error, Equatable {
    case invalidSocketURL
    case invalidFrameLength(Int)
    case posix(Int32)
    case truncatedFrame
    case deadlineExceeded
    case applicationUnavailable
    case invalidRequest

    fileprivate var isStartupConnectionFailure: Bool {
        switch self {
        case .posix(ENOENT), .posix(ECONNREFUSED):
            return true
        default:
            return false
        }
    }
}

public struct LocalAPIUnixClient: Sendable {
    public static let retryInterval: TimeInterval = 0.1
    public static let startupTimeout: TimeInterval = 5

    public let socketURL: URL
    private let configuredStartupTimeout: TimeInterval
    private let configuredRetryInterval: TimeInterval
    private let configuredOperationTimeout: TimeInterval?

    public init(
        socketURL: URL,
        startupTimeout: TimeInterval = Self.startupTimeout,
        retryInterval: TimeInterval = Self.retryInterval,
        operationTimeout: TimeInterval? = nil
    ) {
        self.socketURL = socketURL
        self.configuredStartupTimeout = max(0, startupTimeout)
        self.configuredRetryInterval = max(0.001, retryInterval)
        self.configuredOperationTimeout = operationTimeout.map { max(0.001, $0) }
    }

    public func request(_ payload: Data) throws -> Data {
        let now = { ProcessInfo.processInfo.systemUptime }
        let method = try Self.validatedMethod(in: payload)
        let descriptor = try connect(
            deadline: now() + configuredStartupTimeout,
            now: now
        )
        defer { Darwin.close(descriptor) }
        return try performRequest(
            payload,
            method: method,
            descriptor: descriptor,
            now: now
        )
    }

    private func connect(
        deadline: TimeInterval,
        now: () -> TimeInterval
    ) throws -> Int32 {
        try Self.requireTimeRemaining(until: deadline, now: now)
        var address = try Self.unixAddress(url: socketURL)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalAPIUnixClientError.posix(errno) }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }

        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw LocalAPIUnixClientError.posix(errno)
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalAPIUnixClientError.posix(errno)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connectResult != 0 {
            let connectError = errno
            guard connectError == EINPROGRESS || connectError == EALREADY else {
                throw LocalAPIUnixClientError.posix(connectError)
            }
            try Self.waitForReadiness(
                descriptor: descriptor,
                events: Int16(POLLOUT),
                deadline: deadline,
                now: now
            )
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0 else {
                throw LocalAPIUnixClientError.posix(errno)
            }
            guard socketError == 0 else {
                throw LocalAPIUnixClientError.posix(socketError)
            }
        }
        try Self.requireTimeRemaining(until: deadline, now: now)
        shouldClose = false
        return descriptor
    }

    private func performRequest(
        _ payload: Data,
        method: LocalAPIMethod,
        descriptor: Int32,
        now: () -> TimeInterval
    ) throws -> Data {
        let deadline = now() + (
            configuredOperationTimeout ?? Self.operationTimeout(for: method)
        )
        var requestLength = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &requestLength) { Data($0) }
        frame.append(payload)
        try Self.writeAll(
            frame,
            to: descriptor,
            deadline: deadline,
            now: now
        )

        let header = try Self.readExactly(
            4,
            from: descriptor,
            deadline: deadline,
            now: now
        )
        let responseLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let length = Int(responseLength)
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(length) else {
            throw LocalAPIUnixClientError.invalidFrameLength(length)
        }
        return try Self.readExactly(
            length,
            from: descriptor,
            deadline: deadline,
            now: now
        )
    }

    public func requestLaunchingApplicationIfNeeded(
        _ payload: Data,
        launchApplication: () -> Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Data {
        let method = try Self.validatedMethod(in: payload)
        let deadline = now() + configuredStartupTimeout
        let initialDescriptor: Int32
        do {
            initialDescriptor = try connect(deadline: deadline, now: now)
        } catch LocalAPIUnixClientError.deadlineExceeded {
            throw LocalAPIUnixClientError.applicationUnavailable
        } catch let error as LocalAPIUnixClientError where error.isStartupConnectionFailure {
            guard now() < deadline else {
                throw LocalAPIUnixClientError.applicationUnavailable
            }
            guard launchApplication() else {
                throw LocalAPIUnixClientError.applicationUnavailable
            }
            guard now() < deadline else {
                throw LocalAPIUnixClientError.applicationUnavailable
            }
            return try retryAfterLaunch(
                payload,
                method: method,
                deadline: deadline,
                now: now,
                sleep: sleep
            )
        }

        defer { Darwin.close(initialDescriptor) }
        return try performRequest(
            payload,
            method: method,
            descriptor: initialDescriptor,
            now: now
        )
    }

    private func retryAfterLaunch(
        _ payload: Data,
        method: LocalAPIMethod,
        deadline: TimeInterval,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void
    ) throws -> Data {
        let maximumRetryCount = Int(
            ceil(configuredStartupTimeout / configuredRetryInterval)
        )
        for _ in 0..<maximumRetryCount {
            guard now() < deadline else { break }
            let delay = min(configuredRetryInterval, deadline - now())
            sleep(delay)
            guard now() < deadline else { break }
            let descriptor: Int32
            do {
                descriptor = try connect(deadline: deadline, now: now)
            } catch LocalAPIUnixClientError.deadlineExceeded {
                throw LocalAPIUnixClientError.applicationUnavailable
            } catch let error as LocalAPIUnixClientError where error.isStartupConnectionFailure {
                continue
            } catch {
                throw error
            }
            defer { Darwin.close(descriptor) }
            return try performRequest(
                payload,
                method: method,
                descriptor: descriptor,
                now: now
            )
        }
        throw LocalAPIUnixClientError.applicationUnavailable
    }

    public static func operationTimeout(for method: LocalAPIMethod) -> TimeInterval {
        switch method {
        case .sessionStatus:
            5
        case .mailUnreadList, .mailOpen, .draftRead:
            10
        case .replyBegin, .draftUpdate:
            15
        case .replySend:
            90
        case .syncIncrementalAll, .aiSummarize, .aiDraftReply:
            120
        }
    }

    private static func validatedMethod(in payload: Data) throws -> LocalAPIMethod {
        guard (1...LocalAPIProtocol.maximumFrameSize).contains(payload.count) else {
            throw LocalAPIUnixClientError.invalidFrameLength(payload.count)
        }
        guard let header = try? JSONDecoder().decode(LocalAPIRequestHeader.self, from: payload),
              !header.requestID.isEmpty else {
            throw LocalAPIUnixClientError.invalidRequest
        }
        return header.method
    }

    private static func unixAddress(url: URL) throws -> sockaddr_un {
        guard url.isFileURL,
              NSString(string: url.path).isAbsolutePath else {
            throw LocalAPIUnixClientError.invalidSocketURL
        }
        let bytes = Array(url.path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalAPIUnixClientError.invalidSocketURL
        }
        address.sun_family = sa_family_t(AF_UNIX)
        url.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.memcpy(destination, source, bytes.count)
            }
        }
        return address
    }

    private static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: TimeInterval,
        now: () -> TimeInterval
    ) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try requireTimeRemaining(until: deadline, now: now)
                let received = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if received < 0, errno == EINTR { continue }
                if received < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForReadiness(
                        descriptor: descriptor,
                        events: Int16(POLLIN),
                        deadline: deadline,
                        now: now
                    )
                    continue
                }
                guard received > 0 else {
                    if received == 0 { throw LocalAPIUnixClientError.truncatedFrame }
                    throw LocalAPIUnixClientError.posix(errno)
                }
                offset += received
            }
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: TimeInterval,
        now: () -> TimeInterval
    ) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try requireTimeRemaining(until: deadline, now: now)
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForReadiness(
                        descriptor: descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        now: now
                    )
                    continue
                }
                guard written > 0 else {
                    throw LocalAPIUnixClientError.posix(written == 0 ? EPIPE : errno)
                }
                offset += written
            }
        }
    }

    private static func requireTimeRemaining(
        until deadline: TimeInterval,
        now: () -> TimeInterval
    ) throws {
        guard now() < deadline else {
            throw LocalAPIUnixClientError.deadlineExceeded
        }
    }

    private static func waitForReadiness(
        descriptor: Int32,
        events: Int16,
        deadline: TimeInterval,
        now: () -> TimeInterval
    ) throws {
        while true {
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw LocalAPIUnixClientError.deadlineExceeded
            }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(
                min(Double(Int32.max), max(1, ceil(remaining * 1_000)))
            )
            let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw LocalAPIUnixClientError.posix(errno) }
            guard result > 0 else { throw LocalAPIUnixClientError.deadlineExceeded }
            guard pollDescriptor.revents & Int16(POLLNVAL) == 0 else {
                throw LocalAPIUnixClientError.posix(EBADF)
            }
            return
        }
    }
}

public enum BrowserBridgeResponse {
    public static let maximumRequestIDUTF8Bytes = 128

    public static func isRequestIDAllowedForForwarding(in request: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let requestID = object["requestID"] as? String else {
            return true
        }
        return requestID.utf8.count <= maximumRequestIDUTF8Bytes
    }

    public static func isRequestAllowedForForwarding(_ request: Data) -> Bool {
        guard let header = try? JSONDecoder().decode(LocalAPIRequestHeader.self, from: request)
        else { return false }
        return !header.requestID.isEmpty
            && header.requestID.utf8.count <= maximumRequestIDUTF8Bytes
    }

    public static func unavailable(for request: Data) -> Data {
        failure(
            requestID: boundedRequestID(in: request),
            code: .unavailable,
            message: "Plainpost is unavailable."
        )
    }

    public static func invalidRequest() -> Data {
        failure(
            requestID: nil,
            code: .invalidRequest,
            message: "The request is invalid."
        )
    }

    private static func boundedRequestID(in request: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let requestID = object["requestID"] as? String,
              requestID.utf8.count <= maximumRequestIDUTF8Bytes else {
            return nil
        }
        return requestID
    }

    private static func failure(
        requestID: String?,
        code: LocalAPIErrorCode,
        message: String
    ) -> Data {
        let object: [String: Any] = [
            "apiVersion": LocalAPIProtocol.version,
            "requestID": requestID ?? NSNull(),
            "ok": false,
            "error": [
                "code": code.rawValue,
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"apiVersion":1,"requestID":null,"ok":false,"error":{"code":"UNAVAILABLE","message":"Plainpost is unavailable."}}"#.utf8)
    }
}
