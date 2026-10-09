import Foundation
import PlainpostAI
import PlainpostCore
import PlainpostDB
import PlainpostOperations

public protocol OperationWorkerSignaling: Sendable {
    func signalWork() async throws
}

public struct NoopOperationWorkerSignal: OperationWorkerSignaling {
    public init() {}
    public func signalWork() async throws {}
}

private actor IncrementalSmartInboxJobRunner {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancelling = false

    func start(jobID: String, runtime: LocalOperationRuntime) {
        guard !isCancelling, tasks[jobID] == nil else { return }
        tasks[jobID] = Task { [weak self] in
            var currentJobID: String? = jobID
            while let runningJobID = currentJobID, !Task.isCancelled {
                _ = try? await runtime.runUntilTerminalReleasingLeaseOnCancellation(
                    jobID: runningJobID
                )
                currentJobID = try? runtime.store.terminalSmartInboxSuccessor(after: runningJobID)
            }
            await self?.finish(jobID: jobID)
        }
    }

    func cancelAllAndWait() async -> [String] {
        isCancelling = true
        let interruptedJobIDs = Array(tasks.keys)
        while !tasks.isEmpty {
            let activeTasks = Array(tasks.values)
            activeTasks.forEach { $0.cancel() }
            for task in activeTasks {
                await task.value
            }
        }
        isCancelling = false
        resumeIdleWaiters()
        return interruptedJobIDs
    }

    func waitForIdle() async {
        guard !tasks.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finish(jobID: String) {
        tasks[jobID] = nil
        if tasks.isEmpty {
            resumeIdleWaiters()
        }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Enqueues durable operations and waits for a separate worker process to
/// claim them. Unlike `LocalOperationClient`, this type never executes a job in
/// the caller process.
public final class QueuedOperationClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let workerSignal: any OperationWorkerSignaling
    private let pollInterval: Duration
    private let aiProviderResolver: @Sendable (PlainpostAIOperationInput) throws -> any AIProvider

    public init(
        store: SQLiteMailStore,
        workerSignal: any OperationWorkerSignaling,
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.store = store
        self.workerSignal = workerSignal
        self.pollInterval = pollInterval
        aiProviderResolver = { input in
            try defaultAIProvider(for: input)
        }
    }

    init(
        store: SQLiteMailStore,
        workerSignal: any OperationWorkerSignaling,
        pollInterval: Duration = .milliseconds(100),
        aiProviderResolver: @escaping @Sendable (PlainpostAIOperationInput) throws -> any AIProvider
    ) {
        self.store = store
        self.workerSignal = workerSignal
        self.pollInterval = pollInterval
        self.aiProviderResolver = aiProviderResolver
    }

    public func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        let job = try enqueueInboxSyncJob(input, store: store)
        let completed = try await awaitTerminal(jobID: job.id)
        guard let artifactID = completed.resultArtifactID else {
            throw PlainpostError.validationFailed("Inbox sync result is unavailable.")
        }
        return try decodeArtifact(PlainpostInboxSyncResult.self, id: artifactID)
    }

    public func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        if input.operation == .recategorizeInbox {
            switch try enqueueValidatedSmartInboxJob(
                input: input,
                store: store,
                resolveProvider: aiProviderResolver
            ) {
            case .upToDate:
                return try smartInboxUpToDateResult(input: input, store: store)
            case .job(let job):
                let isAcknowledgedManualPause = job.state == .paused
                    && (job.pauseReason == PlainpostBackgroundAgentJobPolicy.userRequestedPauseReason
                        || job.pauseReason == PlainpostBackgroundAgentJobPolicy.lowPowerPauseReason)
                let completed = try await awaitTerminal(
                    jobID: job.id,
                    signalWorker: !isAcknowledgedManualPause
                )
                guard let artifactID = completed.resultArtifactID else {
                    throw PlainpostError.validationFailed("AI operation result is unavailable.")
                }
                return PlainpostAIOperationResult(
                    operation: input.operation,
                    recordID: input.recordID,
                    artifactID: artifactID,
                    jobID: job.id
                )
            }
        }
        let policy = try aiJobPolicy(input: input, store: store)
        let job = try enqueue(
            kind: input.operation == .rebuildIndex ? .searchRebuild : .aiOperation,
            input: input,
            priority: input.operation.priority,
            idempotencyKey: policy.idempotencyKey,
            replaceTerminalDuplicate: policy.replaceTerminalDuplicate
        )
        let completed = try await awaitTerminal(
            jobID: job.id,
            cancelOnCallerCancellation: policy.cancelOnCallerCancellation
        )
        guard let artifactID = completed.resultArtifactID else {
            throw PlainpostError.validationFailed("AI operation result is unavailable.")
        }
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: artifactID,
            jobID: job.id
        )
    }

    public func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        guard input.operation == .recategorizeInbox, input.smartInboxRunMode == .incremental else {
            throw PlainpostError.validationFailed("Only incremental Smart Inbox work can be enqueued.")
        }
        if case .job = try enqueueValidatedSmartInboxJob(
            input: input,
            store: store,
            resolveProvider: aiProviderResolver
        ) {
            try await workerSignal.signalWork()
        }
    }

    public func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: approvedBy)
        let job = try enqueue(
            kind: .approvedDelivery,
            input: input,
            priority: 100,
            maxAttempts: 1,
            idempotencyKey: "approved-delivery:\(requestID.rawValue)"
        )
        _ = try await awaitTerminal(jobID: job.id)
    }

    public func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: deniedBy)
        let job = try enqueue(
            kind: .denySend,
            input: input,
            priority: 100,
            maxAttempts: 1,
            idempotencyKey: "deny-send:\(requestID.rawValue)"
        )
        _ = try await awaitTerminal(jobID: job.id)
    }

    private func awaitTerminal(
        jobID: String,
        cancelOnCallerCancellation: Bool = false,
        signalWorker: Bool = true
    ) async throws -> PlainpostDurableJob {
        if signalWorker {
            try await workerSignal.signalWork()
        }
        if cancelOnCallerCancellation {
            return try await withTaskCancellationHandler {
                try await awaitTerminalLoop(jobID: jobID)
            } onCancel: { [store] in
                try? store.requestJobCancellation(id: jobID)
            }
        }
        return try await awaitTerminalLoop(jobID: jobID)
    }

    private func awaitTerminalLoop(jobID: String) async throws -> PlainpostDurableJob {
        while true {
            try Task.checkCancellation()
            let job = try store.job(id: jobID)
            switch job.state {
            case .completed:
                return job
            case .failed, .cancelled, .deliveryUncertain:
                throw PlainpostError.validationFailed(job.errorMessage ?? "The background operation did not complete.")
            case .paused where job.pauseReason == LocalOperationRuntime.credentialsUnavailablePauseReason:
                throw PlainpostError.validationFailed(
                    "Mail credentials are unavailable. Unlock the Keychain and retry the sync."
                )
            case .queued, .running, .paused:
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    private func enqueue<T: Encodable>(
        kind: PlainpostOperationKind,
        input: T,
        priority: Int,
        maxAttempts: Int = 5,
        idempotencyKey: String,
        replaceTerminalDuplicate: Bool = false
    ) throws -> PlainpostDurableJob {
        let data = try JSONEncoder().encode(input)
        return try store.enqueueJob(
            PlainpostJobRequest(
                kind: kind,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: priority,
                maxAttempts: maxAttempts,
                idempotencyKey: idempotencyKey,
                replaceTerminalDuplicate: replaceTerminalDuplicate
            )
        )
    }

    private func decodeArtifact<T: Decodable>(_ type: T.Type, id: String) throws -> T {
        let artifact = try store.durableOperationArtifact(id: id)
        return try JSONDecoder().decode(type, from: Data(artifact.payloadJSON.utf8))
    }
}

public final class LocalOperationClient: PlainpostOperationClientProtocol, @unchecked Sendable {
    private let runtime: LocalOperationRuntime
    private let store: SQLiteMailStore
    private let incrementalRunner = IncrementalSmartInboxJobRunner()

    public init(runtime: LocalOperationRuntime) {
        self.runtime = runtime
        self.store = runtime.store
    }

    public func requestForegroundInboxRefresh(
        _ input: PlainpostInboxSyncInput
    ) throws -> PlainpostForegroundInboxRefreshRequest {
        try store.requestForegroundInboxRefresh(input)
    }

    public func foregroundInboxRefreshReceipt(
        _ request: PlainpostForegroundInboxRefreshRequest
    ) throws -> PlainpostForegroundInboxRefreshReceipt? {
        try store.foregroundInboxRefreshReceipt(request)
    }

    /// Called by the runtime's retained owner, never by a view's waiter.
    /// Cancelling this owner on runtime shutdown releases its execution lease.
    public func driveForegroundInboxRefreshJob(
        _ request: PlainpostForegroundInboxRefreshRequest
    ) async -> (result: Result<PlainpostInboxSyncResult, Error>, ownsTerminalEffects: Bool) {
        await driveInboxSyncJobWithTerminalOwnership(jobID: request.jobID)
    }

    /// The concrete local adapter needs execution ownership as well as the
    /// unchanged terminal result. Service/Queued clients keep their protocol.
    public func executeInboxSyncWithTerminalOwnership(
        _ input: PlainpostInboxSyncInput
    ) async -> (result: Result<PlainpostInboxSyncResult, Error>, ownsTerminalEffects: Bool) {
        do {
            let job = try enqueueInboxSyncJob(input, store: store)
            return await driveInboxSyncJobWithTerminalOwnership(jobID: job.id)
        } catch {
            return (.failure(error), false)
        }
    }

    private func driveInboxSyncJobWithTerminalOwnership(
        jobID: String
    ) async -> (result: Result<PlainpostInboxSyncResult, Error>, ownsTerminalEffects: Bool) {
        let completion = ForegroundOwnedCompletion()
        let result: Result<PlainpostInboxSyncResult, Error>
        do {
            let completed = try await runtime.runUntilTerminalReleasingLeaseOnCancellation(
                jobID: jobID,
                didFinishOwnedJob: { id, succeeded in
                    if id == jobID { completion.record(succeeded: succeeded) }
                }
            )
            guard let artifactID = completed.resultArtifactID else {
                throw PlainpostError.validationFailed("Inbox sync result is unavailable.")
            }
            result = .success(try decodeArtifact(PlainpostInboxSyncResult.self, id: artifactID))
        } catch {
            result = .failure(error)
        }
        // Only a successful owned persistence transition can grant effects.
        // A prior pause/failure cannot own another driver's later success, and
        // refunded/reused attempt numbers are deliberately not authority.
        switch result {
        case .success: return (result, completion.succeeded)
        case .failure: return (result, completion.failed)
        }
    }

    public func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        let job = try enqueueInboxSyncJob(input, store: store)
        // A cancelled foreground/scene task relinquishes its sync lease so
        // the same durable job can be claimed by an immediate manual retry.
        let completed = try await runtime.runUntilTerminalReleasingLeaseOnCancellation(jobID: job.id)
        guard let artifactID = completed.resultArtifactID else {
            throw PlainpostError.validationFailed("Inbox sync result is unavailable.")
        }
        return try decodeArtifact(PlainpostInboxSyncResult.self, id: artifactID)
    }

    public func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        if input.operation == .recategorizeInbox {
            switch try enqueueValidatedSmartInboxJob(
                input: input,
                store: store,
                resolveProvider: { [runtime] input in
                    try runtime.resolveAIProvider(
                        input,
                        smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
                    )
                }
            ) {
            case .upToDate:
                return try smartInboxUpToDateResult(input: input, store: store)
            case .job(let job):
                let completed = try await runtime.runUntilTerminal(jobID: job.id)
                guard let artifactID = completed.resultArtifactID else {
                    throw PlainpostError.validationFailed("AI operation result is unavailable.")
                }
                return PlainpostAIOperationResult(
                    operation: input.operation,
                    recordID: input.recordID,
                    artifactID: artifactID,
                    jobID: job.id
                )
            }
        }
        let policy = try aiJobPolicy(input: input, store: store)
        let job = try enqueue(
            kind: input.operation == .rebuildIndex ? .searchRebuild : .aiOperation,
            input: input,
            priority: input.operation.priority,
            idempotencyKey: policy.idempotencyKey,
            replaceTerminalDuplicate: policy.replaceTerminalDuplicate
        )
        let completed: PlainpostDurableJob
        if policy.cancelOnCallerCancellation {
            completed = try await withTaskCancellationHandler {
                try await runtime.runOwnJobUntilTerminal(jobID: job.id)
            } onCancel: { [store] in
                try? store.requestJobCancellation(id: job.id)
            }
        } else {
            completed = try await runtime.runUntilTerminal(jobID: job.id)
        }
        guard let artifactID = completed.resultArtifactID else {
            throw PlainpostError.validationFailed("AI operation result is unavailable.")
        }
        return PlainpostAIOperationResult(
            operation: input.operation,
            recordID: input.recordID,
            artifactID: artifactID,
            jobID: job.id
        )
    }

    public func enqueueIncrementalSmartInbox(_ input: PlainpostAIOperationInput) async throws {
        guard input.operation == .recategorizeInbox, input.smartInboxRunMode == .incremental else {
            throw PlainpostError.validationFailed("Only incremental Smart Inbox work can be enqueued.")
        }
        if case .job(let job) = try enqueueValidatedSmartInboxJob(
            input: input,
            store: store,
            resolveProvider: { [runtime] input in
                try runtime.resolveAIProvider(
                    input,
                    smartInboxClassifierIdentity: input.resolvedSmartInboxClassifierIdentity
                )
            }
        ) {
            await incrementalRunner.start(jobID: job.id, runtime: runtime)
        }
    }

    public func waitForIncrementalSmartInboxIdle() async {
        await incrementalRunner.waitForIdle()
    }

    public func cancelAndWaitForIncrementalSmartInbox() async -> [String] {
        await incrementalRunner.cancelAllAndWait()
    }

    public func resumeIncrementalSmartInbox(jobIDs: [String]) async {
        for jobID in jobIDs {
            await incrementalRunner.start(jobID: jobID, runtime: runtime)
        }
    }

    deinit {
        let runner = incrementalRunner
        Task { _ = await runner.cancelAllAndWait() }
    }

    public func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: approvedBy)
        let job = try enqueue(
            kind: .approvedDelivery,
            input: input,
            priority: 100,
            maxAttempts: 1,
            idempotencyKey: "approved-delivery:\(requestID.rawValue)"
        )
        _ = try await runtime.runUntilTerminal(jobID: job.id)
    }

    public func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        let input = PlainpostApprovalDecisionInput(requestID: requestID, actorID: deniedBy)
        let job = try enqueue(
            kind: .denySend,
            input: input,
            priority: 100,
            maxAttempts: 1,
            idempotencyKey: "deny-send:\(requestID.rawValue)"
        )
        _ = try await runtime.runUntilTerminal(jobID: job.id)
    }

    private func enqueue<T: Encodable>(
        kind: PlainpostOperationKind,
        input: T,
        priority: Int,
        maxAttempts: Int = 5,
        idempotencyKey: String,
        replaceTerminalDuplicate: Bool = false
    ) throws -> PlainpostDurableJob {
        let data = try JSONEncoder().encode(input)
        return try store.enqueueJob(
            PlainpostJobRequest(
                kind: kind,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: priority,
                maxAttempts: maxAttempts,
                idempotencyKey: idempotencyKey,
                replaceTerminalDuplicate: replaceTerminalDuplicate
            )
        )
    }

    private func decodeArtifact<T: Decodable>(_ type: T.Type, id: String) throws -> T {
        let artifact = try store.durableOperationArtifact(id: id)
        return try JSONDecoder().decode(type, from: Data(artifact.payloadJSON.utf8))
    }
}

private final class ForegroundOwnedCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didSucceed = false
    private var didFail = false
    var succeeded: Bool { lock.withLock { didSucceed } }
    var failed: Bool { lock.withLock { didFail } }
    func record(succeeded: Bool) {
        lock.withLock {
            if succeeded { didSucceed = true } else { didFail = true }
        }
    }
}

func enqueueInboxSyncJob(
    _ input: PlainpostInboxSyncInput,
    store: SQLiteMailStore,
    priority: Int? = nil
) throws -> PlainpostDurableJob {
    try store.enqueueCoalescedInboxSyncJob(
        input,
        priority: priority ?? input.schedulingPriority
    )
}

private func defaultAIProvider(
    for input: PlainpostAIOperationInput,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> any AIProvider {
    let classifierIdentity = input.operation == .recategorizeInbox
        ? input.resolvedSmartInboxClassifierIdentity
        : nil
    return try LocalAIProviderResolver.resolve(
        LocalAIProviderSelection(
            providerID: input.providerID,
            ollamaBaseURL: environment["PLAINPOST_OLLAMA_URL"].flatMap(URL.init(string:)),
            ollamaChatModelID: classifierIdentity?.modelID
                ?? environment["PLAINPOST_OLLAMA_CHAT_MODEL"]
                ?? "qwen3:8b",
            ollamaEmbeddingModelID: environment["PLAINPOST_OLLAMA_EMBEDDING_MODEL"]
                ?? "mxbai-embed-large"
        )
    )
}

private func enqueueValidatedSmartInboxJob(
    input: PlainpostAIOperationInput,
    store: SQLiteMailStore,
    resolveProvider: @Sendable (PlainpostAIOperationInput) throws -> any AIProvider
) throws -> PlainpostSmartInboxJobEnqueueResult {
    let provider = try resolveProvider(input)
    guard provider.isPermittedMailProcessor else {
        throw AIProviderError.unavailable
    }
    let durableInput = try store.resolvedSmartInboxInput(input)
    let catalogSnapshot = try store.smartInboxLabelCatalogSnapshot()
    let classificationInputs = try store.smartInboxClassificationInputs(
        scope: durableInput.smartInboxRunRequest.scope
    )
    return try store.enqueueSmartInboxJob(
        input: durableInput,
        classificationInputs: classificationInputs,
        catalogSnapshot: catalogSnapshot
    )
}

private struct AIJobPolicy {
    let idempotencyKey: String
    let cancelOnCallerCancellation: Bool
    let replaceTerminalDuplicate: Bool
}

private func aiJobPolicy(
    input: PlainpostAIOperationInput,
    store: SQLiteMailStore
) throws -> AIJobPolicy {
    if input.operation == .recategorizeInbox {
        return AIJobPolicy(
            idempotencyKey: try smartInboxJobIdentity(input: input, store: store),
            cancelOnCallerCancellation: false,
            replaceTerminalDuplicate: input.smartInboxRunMode == .rerunAll
        )
    }
    return AIJobPolicy(
        idempotencyKey: "ai:\(input.operation.rawValue):\(input.recordID):\(UUID().uuidString.lowercased())",
        cancelOnCallerCancellation: input.operation.serviceClass == .interactive,
        replaceTerminalDuplicate: false
    )
}

func smartInboxJobIdentity(
    input: PlainpostAIOperationInput,
    store: SQLiteMailStore
) throws -> String {
    let classifierDiscriminator = input.resolvedSmartInboxClassifierIdentity.discriminator
    let catalog = try store.smartInboxLabelCatalogSnapshot()
    let cache = try store.smartInboxClassificationCache()
    let classificationInputs = try store.smartInboxClassificationInputs(
        scope: input.smartInboxRunRequest.scope
    )
    let eligibleInputs = classificationInputs.filter { classificationInput in
        if input.smartInboxRunMode == .rerunAll { return true }
        return cache[classificationInput.message.id]?.sourceFingerprint
            != SmartInboxClassificationFingerprint.message(
                classificationInput,
                classifierDiscriminator: classifierDiscriminator
            )
    }
    let discriminator: String
    switch input.smartInboxRunMode {
    case .incremental:
        discriminator = "incremental:\(input.smartInboxRunRequest.scope.identityValue)"
    case .rerunAll:
        guard input.smartInboxRequestID?.isEmpty == false else {
            throw PlainpostError.validationFailed("A full Smart Inbox rerun requires a request ID.")
        }
        discriminator = "rerun-current-workset:\(input.smartInboxRunRequest.scope.identityValue)"
    }
    let fingerprint = SmartInboxClassificationFingerprint.workSet(
        inputs: eligibleInputs,
        discriminator: discriminator,
        classifierDiscriminator: classifierDiscriminator,
        catalogFingerprint: catalog.fingerprint
    )
    return "ai:recategorizeInbox:v3:\(fingerprint)"
}

private func smartInboxUpToDateResult(
    input: PlainpostAIOperationInput,
    store: SQLiteMailStore
) throws -> PlainpostAIOperationResult {
    let artifactID = "artifact_smart_inbox_up_to_date_\(UUID().uuidString.lowercased())"
    let payload = PlainpostLocalAIArtifactPayload(
        modelID: input.resolvedSmartInboxClassifierIdentity.modelID,
        categorizedMessageCount: 0,
        unchangedMessageCount: 0,
        failedMessageCount: 0
    )
    let data = try JSONEncoder().encode(payload)
    try store.saveTypedAIOperationArtifact(
        DurableOperationArtifact(
            id: artifactID,
            kind: input.operation.rawValue,
            recordID: input.recordID,
            payloadJSON: String(decoding: data, as: UTF8.self)
        ),
        input: input
    )
    return PlainpostAIOperationResult(
        operation: input.operation,
        recordID: input.recordID,
        artifactID: artifactID,
        jobID: "smart-inbox-up-to-date"
    )
}
