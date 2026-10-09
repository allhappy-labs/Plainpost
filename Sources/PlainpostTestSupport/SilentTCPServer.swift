import Darwin
import Foundation

/// A loopback TCP listener that never speaks: it holds each accepted
/// connection open without sending a byte (a server that accepts and then
/// stalls), or closes it at once (a server that drops the connection before
/// its greeting). Tests use it to prove clients time out or fail instead of
/// hanging.
public final class SilentTCPServer: @unchecked Sendable {
    public enum Behavior: Sendable {
        case holdOpen
        case closeOnAccept
    }

    public let port: UInt16
    private let listener: Int32
    private let behavior: Behavior
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var stopped = false

    public init(behavior: Behavior = .holdOpen) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: assigned.sin_port)
        self.behavior = behavior
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            let keep = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                if behavior == .holdOpen { accepted.append(connection) }
                return behavior == .holdOpen
            }
            if !keep { Darwin.close(connection) }
        }
    }

    public func stop() {
        let connections = lock.withLock { () -> [Int32]? in
            guard !stopped else { return nil }
            stopped = true
            defer { accepted.removeAll() }
            return accepted
        }
        guard let connections else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        for connection in connections {
            Darwin.shutdown(connection, SHUT_RDWR)
            Darwin.close(connection)
        }
    }
}
