import Darwin
import Dispatch
import Foundation
import PlainpostLocalAPI

public struct LocalAPIUnixServerError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public var isLifecycleLockContention: Bool {
        operation == "acquire lifecycle lock"
            && (code == EAGAIN || code == EACCES)
    }

    public var description: String {
        "Local API \(operation) failed (errno \(code))."
    }

    init(operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }
}

public final class LocalAPIUnixServer: @unchecked Sendable {
    public let socketURL: URL
    public let lockURL: URL

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let router: LocalAPIRouter
    private let acceptQueue: DispatchQueue
    private let inboundFrameTimeout: TimeInterval
    private let stateLock = NSLock()
    private var listeningDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var ownedSocketIdentity: SocketIdentity?
    private var lifecycleID: UUID?
    private var acceptedConnections: [UUID: ManagedLocalAPIConnection] = [:]

    public init(
        socketURL: URL,
        router: LocalAPIRouter,
        inboundFrameTimeout: TimeInterval = 5
    ) throws {
        guard socketURL.isFileURL else {
            throw LocalAPIUnixServerError(operation: "validate socket URL", code: EINVAL)
        }
        let filesystemSocketURL = URL(fileURLWithPath: socketURL.path)
        _ = try Self.unixAddress(path: filesystemSocketURL.path)
        self.socketURL = filesystemSocketURL
        self.lockURL = filesystemSocketURL
            .deletingPathExtension()
            .appendingPathExtension("lock")
        self.router = router
        self.inboundFrameTimeout = max(0.001, inboundFrameTimeout)
        self.acceptQueue = DispatchQueue(
            label: "com.marynavdovenko.Plainpost.local-api.accept.\(UUID().uuidString)"
        )
    }

    deinit {
        stop()
    }

    var activeConnectionCount: Int {
        stateLock.withLock { acceptedConnections.count }
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listeningDescriptor < 0 else { return }

        let parentURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try Self.secureDirectory(at: parentURL)
        let lifecycleLock = try Self.acquireLifecycleLock(at: lockURL)
        var shouldReleaseLifecycleLock = true
        defer {
            if shouldReleaseLifecycleLock {
                Self.releaseLifecycleLock(lifecycleLock)
            }
        }
        try Self.removeStaleSocketIfSafe(at: socketURL)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalAPIUnixServerError(operation: "create socket")
        }

        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }

        var noSigPipe: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw LocalAPIUnixServerError(operation: "configure socket")
        }

        var address = try Self.unixAddress(path: socketURL.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw LocalAPIUnixServerError(operation: "bind socket")
        }

        let identity = try Self.socketIdentity(at: socketURL)
        guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
            Self.unlinkSocket(at: socketURL, ifIdentityMatches: identity)
            throw LocalAPIUnixServerError(operation: "secure socket")
        }
        guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            Self.unlinkSocket(at: socketURL, ifIdentityMatches: identity)
            throw LocalAPIUnixServerError(operation: "listen")
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Self.unlinkSocket(at: socketURL, ifIdentityMatches: identity)
            throw LocalAPIUnixServerError(operation: "configure listener")
        }

        let startedLifecycleID = UUID()
        listeningDescriptor = descriptor
        lockDescriptor = lifecycleLock
        ownedSocketIdentity = identity
        lifecycleID = startedLifecycleID
        shouldClose = false
        shouldReleaseLifecycleLock = false
        startAcceptLoop(descriptor: descriptor, lifecycleID: startedLifecycleID)
    }

    public func stop() {
        let descriptor: Int32
        let lifecycleLock: Int32
        let identity: SocketIdentity?
        let connections: [ManagedLocalAPIConnection]
        stateLock.lock()
        descriptor = listeningDescriptor
        lifecycleLock = lockDescriptor
        identity = ownedSocketIdentity
        listeningDescriptor = -1
        lockDescriptor = -1
        ownedSocketIdentity = nil
        lifecycleID = nil
        connections = Array(acceptedConnections.values)
        acceptedConnections.removeAll()
        stateLock.unlock()

        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        for connection in connections {
            connection.cancelAndClose()
        }
        for connection in connections {
            connection.waitForTaskCompletion()
        }
        if let identity {
            Self.unlinkSocket(at: socketURL, ifIdentityMatches: identity)
        }
        if lifecycleLock >= 0 {
            Self.releaseLifecycleLock(lifecycleLock)
        }
    }

    private func startAcceptLoop(descriptor: Int32, lifecycleID: UUID) {
        let isActive: @Sendable () -> Bool = { [weak self] in
            self?.isActive(descriptor: descriptor, lifecycleID: lifecycleID) ?? false
        }
        let acceptIfActive: @Sendable () -> Int32? = { [weak self] in
            self?.acceptIfActive(descriptor: descriptor, lifecycleID: lifecycleID)
        }
        let admit: @Sendable (Int32) -> Void = { [weak self] acceptedDescriptor in
            guard let self else {
                Darwin.close(acceptedDescriptor)
                return
            }
            self.admit(
                acceptedDescriptor,
                listenerDescriptor: descriptor,
                lifecycleID: lifecycleID
            )
        }
        acceptQueue.async {
            Self.runAcceptLoop(
                descriptor: descriptor,
                isActive: isActive,
                acceptIfActive: acceptIfActive,
                admit: admit
            )
        }
    }

    private static func runAcceptLoop(
        descriptor: Int32,
        isActive: @Sendable () -> Bool,
        acceptIfActive: @Sendable () -> Int32?,
        admit: @Sendable (Int32) -> Void
    ) {
        while isActive() {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = Darwin.poll(&pollDescriptor, 1, 100)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { return }
            guard result > 0 else { continue }
            guard let acceptedDescriptor = acceptIfActive() else { continue }
            admit(acceptedDescriptor)
        }
    }

    private func isActive(descriptor: Int32, lifecycleID: UUID) -> Bool {
        stateLock.withLock {
            listeningDescriptor == descriptor && self.lifecycleID == lifecycleID
        }
    }

    private func acceptIfActive(
        descriptor: Int32,
        lifecycleID: UUID
    ) -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listeningDescriptor == descriptor, self.lifecycleID == lifecycleID else {
            return nil
        }
        let acceptedDescriptor = Darwin.accept(descriptor, nil, nil)
        if acceptedDescriptor < 0 {
            return nil
        }
        return acceptedDescriptor
    }

    private func admit(
        _ descriptor: Int32,
        listenerDescriptor: Int32,
        lifecycleID: UUID
    ) {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return
        }
        let connection = ManagedLocalAPIConnection(descriptor: descriptor)
        let connectionID = UUID()
        let admitted = stateLock.withLock { () -> Bool in
            guard listeningDescriptor == listenerDescriptor,
                  self.lifecycleID == lifecycleID else { return false }
            acceptedConnections[connectionID] = connection
            return true
        }
        guard admitted else {
            connection.close()
            return
        }
        let router = self.router
        let timeout = inboundFrameTimeout
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.handleConnection(connection, router: router, timeout: timeout)
            self?.finishConnection(connectionID, connection: connection)
            connection.clearTask()
        }
        connection.install(task: task)
    }

    private func finishConnection(
        _ connectionID: UUID,
        connection: ManagedLocalAPIConnection
    ) {
        stateLock.withLock {
            guard acceptedConnections[connectionID] === connection else { return }
            acceptedConnections.removeValue(forKey: connectionID)
        }
    }

    private static func handleConnection(
        _ connection: ManagedLocalAPIConnection,
        router: LocalAPIRouter,
        timeout: TimeInterval
    ) async {
        defer { connection.close() }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard (try? connection.withDescriptor { descriptor in
            getpeereid(descriptor, &peerUID, &peerGID)
        }) == 0,
              peerUID == geteuid() else {
            return
        }

        do {
            let payload = try connection.readFrame(timeout: timeout)
            try Task.checkCancellation()
            let response = await router.handle(payload, caller: .browserExtension)
            try Task.checkCancellation()
            try connection.writeFrame(response, timeout: timeout)
        } catch {
            return
        }
    }

    private static func removeStaleSocketIfSafe(at socketURL: URL) throws {
        var status = stat()
        guard Darwin.lstat(socketURL.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw LocalAPIUnixServerError(operation: "inspect socket path")
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw LocalAPIUnixServerError(operation: "refuse non-socket path", code: EEXIST)
        }
        try requireOwnedStaleSocket(ownerUID: status.st_uid)
        let staleIdentity = SocketIdentity(device: status.st_dev, inode: status.st_ino)

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            throw LocalAPIUnixServerError(operation: "probe socket")
        }
        defer { Darwin.close(probe) }
        var address = try unixAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    probe,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            throw LocalAPIUnixServerError(operation: "socket already active", code: EADDRINUSE)
        }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw LocalAPIUnixServerError(operation: "probe existing socket")
        }
        guard (try? socketIdentity(at: socketURL)) == staleIdentity,
              Darwin.unlink(socketURL.path) == 0 else {
            throw LocalAPIUnixServerError(operation: "remove stale socket")
        }
    }

    private static func acquireLifecycleLock(at lockURL: URL) throws -> Int32 {
        var descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        let created: Bool
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw LocalAPIUnixServerError(operation: "open existing lifecycle lock")
            }
            created = false
        } else {
            throw LocalAPIUnixServerError(operation: "create lifecycle lock")
        }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }
        if created, Darwin.fchmod(descriptor, 0o600) != 0 {
            throw LocalAPIUnixServerError(operation: "secure lifecycle lock")
        }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw LocalAPIUnixServerError(operation: "inspect lifecycle lock")
        }
        try requireSafeLifecycleLock(
            ownerUID: descriptorStatus.st_uid,
            mode: descriptorStatus.st_mode
        )
        var lock = lifecycleFileLock(type: F_WRLCK)
        guard Darwin.fcntl(descriptor, F_OFD_SETLK, &lock) == 0 else {
            let code = errno
            throw LocalAPIUnixServerError(operation: "acquire lifecycle lock", code: code)
        }
        var pathStatus = stat()
        guard Darwin.lstat(lockURL.path, &pathStatus) == 0 else {
            throw LocalAPIUnixServerError(operation: "verify lifecycle lock path")
        }
        try requireSafeLifecycleLock(ownerUID: pathStatus.st_uid, mode: pathStatus.st_mode)
        guard pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino else {
            throw LocalAPIUnixServerError(operation: "verify lifecycle lock identity", code: ESTALE)
        }
        shouldClose = false
        return descriptor
    }

    private static func releaseLifecycleLock(_ descriptor: Int32) {
        var lock = lifecycleFileLock(type: F_UNLCK)
        _ = Darwin.fcntl(descriptor, F_OFD_SETLK, &lock)
        Darwin.close(descriptor)
    }

    private static func lifecycleFileLock(type: Int32) -> flock {
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        return lock
    }

    static func requireSafeLifecycleLock(ownerUID: uid_t, mode: mode_t) throws {
        guard mode & S_IFMT == S_IFREG else {
            throw LocalAPIUnixServerError(operation: "refuse non-file lifecycle lock", code: EINVAL)
        }
        guard ownerUID == geteuid() else {
            throw LocalAPIUnixServerError(operation: "refuse foreign lifecycle lock", code: EPERM)
        }
        guard mode & 0o7777 == 0o600 else {
            throw LocalAPIUnixServerError(operation: "refuse unsafe lifecycle lock mode", code: EPERM)
        }
    }

    private static func secureDirectory(at directoryURL: URL) throws {
        var status = stat()
        guard Darwin.lstat(directoryURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw LocalAPIUnixServerError(operation: "inspect socket directory")
        }
        guard status.st_mode & 0o777 != 0o700 else { return }
        guard Darwin.chmod(directoryURL.path, 0o700) == 0 else {
            throw LocalAPIUnixServerError(operation: "secure socket directory")
        }
    }

    static func requireOwnedStaleSocket(ownerUID: uid_t) throws {
        guard ownerUID == geteuid() else {
            throw LocalAPIUnixServerError(operation: "refuse foreign socket", code: EPERM)
        }
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalAPIUnixServerError(operation: "validate socket path", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    private static func socketIdentity(at socketURL: URL) throws -> SocketIdentity {
        var status = stat()
        guard Darwin.lstat(socketURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFSOCK else {
            throw LocalAPIUnixServerError(operation: "identify socket")
        }
        return SocketIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func unlinkSocket(
        at socketURL: URL,
        ifIdentityMatches identity: SocketIdentity
    ) {
        guard (try? socketIdentity(at: socketURL)) == identity else { return }
        _ = Darwin.unlink(socketURL.path)
    }
}

private final class ManagedLocalAPIConnection: @unchecked Sendable {
    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private let taskCompletion = DispatchGroup()
    private var descriptor: Int32
    private var task: Task<Void, Never>?
    private var closing = false
    private var finished = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        taskCompletion.enter()
    }

    func install(task: Task<Void, Never>) {
        let shouldCancel = stateLock.withLock { () -> Bool in
            if closing || finished { return true }
            self.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func clearTask() {
        let shouldLeave = stateLock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            task = nil
            return true
        }
        if shouldLeave { taskCompletion.leave() }
    }

    func waitForTaskCompletion() {
        taskCompletion.wait()
    }

    func cancelAndClose() {
        close(cancelTask: true)
    }

    func close() {
        close(cancelTask: false)
    }

    func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        let openDescriptor = stateLock.withLock {
            closing ? Int32(-1) : descriptor
        }
        guard openDescriptor >= 0 else {
            throw LocalAPIUnixServerError(operation: "use closed connection", code: EBADF)
        }
        return try body(openDescriptor)
    }

    func readFrame(timeout: TimeInterval) throws -> Data {
        try withDescriptor { descriptor in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let header = try Self.readExactly(
                count: LocalAPIFrameCodec.headerSize,
                from: descriptor,
                deadline: deadline
            )
            let length = try LocalAPIFrameCodec.decodeLength(header)
            return try Self.readExactly(
                count: length,
                from: descriptor,
                deadline: deadline
            )
        }
    }

    func writeFrame(_ payload: Data, timeout: TimeInterval) throws {
        let frame = try LocalAPIFrameCodec.encode(payload)
        try withDescriptor { descriptor in
            try Self.writeAll(
                frame,
                to: descriptor,
                deadline: ProcessInfo.processInfo.systemUptime + timeout
            )
        }
    }

    private func close(cancelTask: Bool) {
        let closingState = stateLock.withLock { () -> (Int32, Task<Void, Never>?)? in
            guard !closing else { return nil }
            closing = true
            return (descriptor, cancelTask ? task : nil)
        }
        guard let (ownedDescriptor, taskToCancel) = closingState else { return }
        taskToCancel?.cancel()
        if ownedDescriptor >= 0 {
            Darwin.shutdown(ownedDescriptor, SHUT_RDWR)
        }

        operationLock.lock()
        let descriptorToClose = stateLock.withLock { () -> Int32 in
            guard descriptor == ownedDescriptor else { return -1 }
            descriptor = -1
            return ownedDescriptor
        }
        if descriptorToClose >= 0 { Darwin.close(descriptorToClose) }
        operationLock.unlock()
    }

    private static func readExactly(
        count: Int,
        from descriptor: Int32,
        deadline: TimeInterval
    ) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                try requireTimeRemaining(until: deadline)
                let received = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if received < 0, errno == EINTR { continue }
                if received < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForReadiness(
                        descriptor: descriptor,
                        events: Int16(POLLIN),
                        deadline: deadline
                    )
                    continue
                }
                guard received > 0 else {
                    throw LocalAPIUnixServerError(
                        operation: "read frame",
                        code: received == 0 ? ECONNRESET : errno
                    )
                }
                offset += received
            }
        }
        return data
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: TimeInterval
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try requireTimeRemaining(until: deadline)
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForReadiness(
                        descriptor: descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline
                    )
                    continue
                }
                guard written > 0 else {
                    throw LocalAPIUnixServerError(operation: "write frame")
                }
                offset += written
            }
        }
    }

    private static func requireTimeRemaining(until deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw LocalAPIUnixServerError(operation: "frame deadline", code: ETIMEDOUT)
        }
    }

    private static func waitForReadiness(
        descriptor: Int32,
        events: Int16,
        deadline: TimeInterval
    ) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw LocalAPIUnixServerError(operation: "frame deadline", code: ETIMEDOUT)
            }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                Int32(min(Double(Int32.max), max(1, ceil(remaining * 1_000))))
            )
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else {
                throw LocalAPIUnixServerError(operation: "poll connection")
            }
            guard result > 0 else {
                throw LocalAPIUnixServerError(operation: "frame deadline", code: ETIMEDOUT)
            }
            guard pollDescriptor.revents & Int16(POLLNVAL) == 0 else {
                throw LocalAPIUnixServerError(operation: "poll connection", code: EBADF)
            }
            return
        }
    }
}
