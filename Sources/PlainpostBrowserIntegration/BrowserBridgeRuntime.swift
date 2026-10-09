import Dispatch
import Foundation

public enum BrowserBridgeRuntimeError: Error {
    case outputWriteFailed
}

public enum BrowserBridgeRuntime {
    public static let maximumInFlightRequestCount = 8

    public static func run(
        readFrame: () throws -> Data?,
        vaultIsUnlocked: @escaping @Sendable () -> Bool,
        lockedResponse: @escaping @Sendable (Data) -> Data,
        forward: @escaping @Sendable (Data) -> Data,
        writeFrame: @escaping @Sendable (Data) throws -> Void,
        onOutputFailure: @escaping @Sendable () -> Void = {}
    ) throws {
        let admission = DispatchSemaphore(value: maximumInFlightRequestCount)
        let admittedWork = DispatchGroup()
        let workers = DispatchQueue(
            label: "com.marynavdovenko.plainpost.browser-bridge.forward",
            attributes: .concurrent
        )
        let output = DispatchQueue(label: "com.marynavdovenko.plainpost.browser-bridge.stdout")
        let outputState = OutputState()
        var inputError: Error?

        while true {
            admission.wait()
            guard !outputState.hasFailed else {
                admission.signal()
                break
            }
            let request: Data
            do {
                guard let next = try readFrame() else {
                    admission.signal()
                    break
                }
                request = next
            } catch {
                admission.signal()
                inputError = error
                break
            }

            admittedWork.enter()
            workers.async {
                defer {
                    admission.signal()
                    admittedWork.leave()
                }
                guard !outputState.hasFailed else { return }
                let response = vaultIsUnlocked()
                    ? forward(request)
                    : lockedResponse(request)
                output.sync {
                    guard !outputState.hasFailed else { return }
                    do {
                        try writeFrame(response)
                    } catch {
                        if outputState.markFailed() {
                            onOutputFailure()
                        }
                    }
                }
            }
        }

        admittedWork.wait()
        if let inputError { throw inputError }
        if outputState.hasFailed { throw BrowserBridgeRuntimeError.outputWriteFailed }
    }
}

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var hasFailed: Bool { lock.withLock { failed } }

    func markFailed() -> Bool {
        lock.withLock {
            guard !failed else { return false }
            failed = true
            return true
        }
    }
}
