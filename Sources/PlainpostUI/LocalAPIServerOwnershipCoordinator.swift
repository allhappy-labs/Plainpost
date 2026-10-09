import Foundation
import OSLog
import PlainpostLocalServer

protocol LocalAPIServerLifecycle: Sendable {
    func start() throws
    func stop()
}

extension LocalAPIUnixServer: LocalAPIServerLifecycle {}

final class LocalAPIServerOwnershipCoordinator: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case inactive
        case passive
        case owner
        case stopped
    }

    private static let logger = Logger(
        subsystem: "com.marynavdovenko.Plainpost",
        category: "LocalAPIOwnership"
    )

    private let server: any LocalAPIServerLifecycle
    private let suspendBeforeRetry: @Sendable () async throws -> Void
    private let stateLock = NSLock()
    private var storedState: State = .inactive

    init(
        server: any LocalAPIServerLifecycle,
        suspendBeforeRetry: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) {
        self.server = server
        self.suspendBeforeRetry = suspendBeforeRetry
    }

    var state: State {
        stateLock.withLock { storedState }
    }

    func activate() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard storedState == .inactive else { return }
        do {
            try server.start()
            storedState = .owner
        } catch let error as LocalAPIUnixServerError
            where error.isLifecycleLockContention
        {
            storedState = .passive
        }
    }

    func maintainOwnership() async {
        while state == .passive && !Task.isCancelled {
            do {
                try await suspendBeforeRetry()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                if try retryOnce() { return }
            } catch let error as LocalAPIUnixServerError {
                Self.logger.error(
                    "Local API ownership retry stopped at \(error.operation, privacy: .public) (errno \(error.code, privacy: .public))."
                )
                return
            } catch {
                Self.logger.error("Local API ownership retry stopped after an unexpected error.")
                return
            }
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        let owned = storedState == .owner
        storedState = .stopped
        if owned {
            server.stop()
        }
    }

    private func retryOnce() throws -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard storedState == .passive else { return true }
        do {
            try server.start()
            storedState = .owner
            return true
        } catch let error as LocalAPIUnixServerError
            where error.isLifecycleLockContention
        {
            return false
        } catch {
            storedState = .inactive
            throw error
        }
    }
}
