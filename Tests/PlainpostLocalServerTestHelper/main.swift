import Darwin
import Foundation

private enum HelperError: Error, CustomStringConvertible {
    case invalidArguments
    case posix(String, Int32)

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: PlainpostLocalServerTestHelper <hold-bound|wait-bind|try-lock> <socket> <lock>"
        case .posix(let operation, let code):
            return "\(operation) failed (errno \(code))"
        }
    }
}

private func fileLock(type: Int32) -> flock {
    var lock = flock()
    lock.l_start = 0
    lock.l_len = 0
    lock.l_pid = 0
    lock.l_type = Int16(type)
    lock.l_whence = Int16(SEEK_SET)
    return lock
}

private func openLock(path: String, create: Bool) throws -> Int32 {
    let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
    let descriptor = Darwin.open(path, flags, 0o600)
    guard descriptor >= 0 else { throw HelperError.posix("open lock", errno) }
    return descriptor
}

private func acquireLock(_ descriptor: Int32, blocking: Bool) throws {
    var lock = fileLock(type: F_WRLCK)
    let command = blocking ? F_OFD_SETLKW : F_OFD_SETLK
    guard Darwin.fcntl(descriptor, command, &lock) == 0 else {
        throw HelperError.posix("acquire lock", errno)
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw HelperError.posix("validate socket path", ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
    }
    return address
}

private func bindSocket(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HelperError.posix("create socket", errno) }
    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw HelperError.posix("bind socket", code)
    }
    return descriptor
}

private func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

private func run() throws {
    guard CommandLine.arguments.count == 4 else { throw HelperError.invalidArguments }
    let mode = CommandLine.arguments[1]
    let socketPath = CommandLine.arguments[2]
    let lockPath = CommandLine.arguments[3]

    switch mode {
    case "hold-bound":
        let lock = try openLock(path: lockPath, create: true)
        guard Darwin.fchmod(lock, 0o600) == 0 else {
            throw HelperError.posix("secure lock", errno)
        }
        try acquireLock(lock, blocking: false)
        _ = try bindSocket(path: socketPath)
        emit("READY")
        _ = Darwin.pause()
    case "wait-bind":
        let lock = try openLock(path: lockPath, create: true)
        do {
            try acquireLock(lock, blocking: false)
            emit("UNEXPECTEDLY_ACQUIRED")
            exit(3)
        } catch HelperError.posix(_, let code) where code == EACCES || code == EAGAIN {
            emit("BLOCKED")
        }
        try acquireLock(lock, blocking: true)
        var status = stat()
        if Darwin.lstat(socketPath, &status) == 0 {
            emit("DIRTY")
            exit(2)
        }
        guard errno == ENOENT else { throw HelperError.posix("inspect socket", errno) }
        _ = try bindSocket(path: socketPath)
        emit("BOUND")
        _ = Darwin.pause()
    case "try-lock":
        let lock = try openLock(path: lockPath, create: false)
        do {
            try acquireLock(lock, blocking: false)
            emit("ACQUIRED")
        } catch HelperError.posix(_, let code) where code == EACCES || code == EAGAIN {
            emit("LOCKED")
        }
    default:
        throw HelperError.invalidArguments
    }
}

do {
    try run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
