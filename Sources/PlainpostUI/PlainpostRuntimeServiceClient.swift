import PlainpostCore
import PlainpostServiceIPC

final class PlainpostRuntimeServiceFailureMonitor: @unchecked Sendable {
    private let continuation: AsyncStream<PlainpostServiceClientError>.Continuation
    let failures: AsyncStream<PlainpostServiceClientError>

    init() {
        let stream = AsyncStream.makeStream(
            of: PlainpostServiceClientError.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        failures = stream.stream
        continuation = stream.continuation
    }

    deinit {
        continuation.finish()
    }

    func report(_ error: PlainpostServiceClientError) {
        guard PlainpostVaultReadinessGate.runtimeFailureState(for: error) != nil else {
            return
        }
        continuation.yield(error)
    }

    func nextFailure() async -> PlainpostServiceClientError? {
        for await error in failures {
            return error
        }
        return nil
    }
}

final class PlainpostRuntimeServiceClient: PlainpostServiceClientProtocol, @unchecked Sendable {
    private let base: any PlainpostServiceClientProtocol
    private let failureMonitor: PlainpostRuntimeServiceFailureMonitor

    init(
        base: any PlainpostServiceClientProtocol,
        failureMonitor: PlainpostRuntimeServiceFailureMonitor
    ) {
        self.base = base
        self.failureMonitor = failureMonitor
    }

    func status() async throws -> PlainpostVaultStatus {
        try await base.status()
    }

    func unlock(reason: String) async throws {
        try await base.unlock(reason: reason)
    }

    func startOverAfterVaultKeyLoss(reason: String) async throws {
        try await base.startOverAfterVaultKeyLoss(reason: reason)
    }

    func lock() async throws {
        try await base.lock()
    }

    func nodeMailModeStatus() async throws -> PlainpostNodeMailModeStatus {
        try await base.nodeMailModeStatus()
    }

    func serviceIdentity() async throws -> PlainpostServiceBuildIdentity? {
        try await base.serviceIdentity()
    }

    func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    {
        do {
            return try await base.perform(operation)
        } catch let error as PlainpostServiceClientError {
            failureMonitor.report(error)
            throw error
        }
    }
}
