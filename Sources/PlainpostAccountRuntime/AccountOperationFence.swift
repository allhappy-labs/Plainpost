import Darwin
import Foundation
import PlainpostAccountProtocol

public protocol AccountOperationFencing: Sendable {
    func withLock<T>(accountID: PlainpostAccountID, _ operation: () throws -> T) throws -> T
}

/// A crash-safe account-scoped advisory fence. The lock file contains no
/// secret data; the kernel releases the POSIX `fcntl` record lock when a
/// process exits.
public final class FileAccountOperationFence: AccountOperationFencing, @unchecked Sendable {
    private final class ProcessLock: @unchecked Sendable {
        let value = NSRecursiveLock()
    }

    private final class WeakProcessLock: @unchecked Sendable {
        weak var value: ProcessLock?
        init(_ value: ProcessLock) { self.value = value }
    }

    private nonisolated(unsafe) static var processLocks: [String: WeakProcessLock] = [:]
    private static let processLocksGuard = NSLock()

    private let lockRoot: URL
    private let directoryDescriptor: Int32
    private let processNamespace: String

    public init(lockRoot: URL) throws {
        let standardized = lockRoot.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else { throw AccountRuntimeError.secretUnavailable }
        self.lockRoot = standardized
        let descriptor = try Self.prepareAndOpenDirectory(standardized.path)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw AccountRuntimeError.secretUnavailable
        }
        directoryDescriptor = descriptor
        processNamespace = "\(status.st_dev):\(status.st_ino)"
    }

    deinit { close(directoryDescriptor) }

    public static func production() -> any AccountOperationFencing {
        do {
            guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw AccountRuntimeError.secretUnavailable
            }
            return try FileAccountOperationFence(
                lockRoot: applicationSupport.appendingPathComponent("com.marynavdovenko.Plainpost.AccountOperationLocks", isDirectory: true)
            )
        } catch {
            return UnavailableAccountOperationFence()
        }
    }

    public func withLock<T>(accountID: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        let name = accountID.rawValue + ".lock"
        let namespace = processNamespace + "\u{0}" + name
        let processLock = Self.processLock(for: namespace)
        processLock.value.lock()
        defer { processLock.value.unlock() }

        let depthKey = "com.marynavdovenko.Plainpost.AccountOperationFence." + Data(namespace.utf8).base64EncodedString()
        let dictionary = Thread.current.threadDictionary
        let depth = dictionary[depthKey] as? Int ?? 0
        if depth > 0 {
            dictionary[depthKey] = depth + 1
            defer { dictionary[depthKey] = depth }
            return try operation()
        }

        dictionary[depthKey] = 1
        defer { dictionary.removeObject(forKey: depthKey) }
        let descriptor = try Self.openValidatedLock(directory: directoryDescriptor, name: name)
        defer { close(descriptor) }
        var advisoryLock = flock()
        advisoryLock.l_type = Int16(F_WRLCK)
        advisoryLock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_SETLKW, &advisoryLock) == 0 else { throw AccountRuntimeError.secretUnavailable }
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = fcntl(descriptor, F_SETLK, &unlock)
        }
        return try operation()
    }

    private static func processLock(for namespace: String) -> ProcessLock {
        processLocksGuard.lock()
        defer { processLocksGuard.unlock() }
        processLocks = processLocks.filter { $0.value.value != nil }
        if let existing = processLocks[namespace]?.value { return existing }
        let created = ProcessLock()
        processLocks[namespace] = WeakProcessLock(created)
        return created
    }

    static func pruneProcessLocksForTesting() {
        processLocksGuard.lock()
        processLocks = processLocks.filter { $0.value.value != nil }
        processLocksGuard.unlock()
    }

    static var processLockCountForTesting: Int {
        processLocksGuard.lock()
        defer { processLocksGuard.unlock() }
        return processLocks.count
    }

    private static func prepareAndOpenDirectory(_ path: String) throws -> Int32 {
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw AccountRuntimeError.secretUnavailable }
        return try openValidatedDirectory(path)
    }

    private static func openValidatedDirectory(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AccountRuntimeError.secretUnavailable }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_uid == geteuid(),
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  (status.st_mode & 0o777) == 0o700
            else { throw AccountRuntimeError.secretUnavailable }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openValidatedLock(directory: Int32, name: String) throws -> Int32 {
        var descriptor = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0, errno == EEXIST {
            descriptor = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw AccountRuntimeError.secretUnavailable }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_uid == geteuid(),
                  (status.st_mode & S_IFMT) == S_IFREG,
                  (status.st_mode & 0o777) == 0o600,
                  status.st_nlink == 1
            else { throw AccountRuntimeError.secretUnavailable }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}

private struct UnavailableAccountOperationFence: AccountOperationFencing {
    func withLock<T>(accountID _: PlainpostAccountID, _ operation: () throws -> T) throws -> T {
        _ = operation
        throw AccountRuntimeError.secretUnavailable
    }
}
