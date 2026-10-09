import Foundation
import PlainpostOperationRuntime

enum PackagedOperationWorkerError: Error {
    case helperUnavailable
}

/// Starts the bundled, background-only helper as a child process. The helper
/// has its own process and consumes the shared durable-operation queue.
public final class PackagedOperationWorkerSignal: OperationWorkerSignaling, @unchecked Sendable {
    typealias Launcher = @Sendable (URL, @escaping @Sendable () -> Void) throws -> Void

    #if os(macOS)
    private static let processRegistry = ActiveProcessRegistry()
    #endif

    private let helperExecutableURL: URL
    private let launcher: Launcher
    private let stateLock = NSLock()
    private var helperIsRunning = false

    public convenience init?(appBundleURL: URL = Bundle.main.bundleURL) {
        #if os(macOS)
        self.init(appBundleURL: appBundleURL, launcher: Self.launch)
        #else
        self.init(appBundleURL: appBundleURL, launcher: Self.unavailable)
        #endif
    }

    init?(
        appBundleURL: URL,
        launcher: @escaping Launcher
    ) {
        let candidate = appBundleURL
            .appendingPathComponent("Contents/Library/Helpers", isDirectory: true)
            .appendingPathComponent("PlainpostBackgroundAgent.app", isDirectory: true)
        let executableURL = candidate
            .appendingPathComponent("Contents/MacOS/PlainpostBackgroundAgent")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        self.helperExecutableURL = executableURL
        self.launcher = launcher
    }

    public func signalWork() async throws {
        guard claimWorkerLaunch() else { return }
        do {
            try launcher(helperExecutableURL) { [weak self] in
                self?.markWorkerFinished()
            }
        } catch {
            markWorkerFinished()
            throw error
        }
    }

    private func claimWorkerLaunch() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !helperIsRunning else { return false }
        helperIsRunning = true
        return true
    }

    private func markWorkerFinished() {
        stateLock.lock()
        helperIsRunning = false
        stateLock.unlock()
    }

    private static func launch(
        executableURL: URL,
        didTerminate: @escaping @Sendable () -> Void
    ) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = executableURL
        let identifier = ObjectIdentifier(process)
        process.terminationHandler = { _ in
            processRegistry.remove(identifier)
            didTerminate()
        }
        processRegistry.insert(process, identifier: identifier)
        do {
            try process.run()
        } catch {
            processRegistry.remove(identifier)
            throw error
        }
        #else
        throw PackagedOperationWorkerError.helperUnavailable
        #endif
    }

    private static func unavailable(
        executableURL: URL,
        didTerminate: @escaping @Sendable () -> Void
    ) throws {
        throw PackagedOperationWorkerError.helperUnavailable
    }
}

#if os(macOS)
private final class ActiveProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func insert(_ process: Process, identifier: ObjectIdentifier) {
        lock.lock()
        processes[identifier] = process
        lock.unlock()
    }

    func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        processes.removeValue(forKey: identifier)
        lock.unlock()
    }
}
#endif
