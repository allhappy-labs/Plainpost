import Foundation
import PlainpostCore

struct PlainpostServiceClientTimeouts: Sendable {
    let control: TimeInterval
    let interactive: TimeInterval
    let semantic: TimeInterval

    init(
        control: TimeInterval = 5,
        interactive: TimeInterval = 120,
        semantic: TimeInterval = 300
    ) {
        self.control = control
        self.interactive = interactive
        self.semantic = semantic
    }
}

protocol PlainpostServiceClientTimeoutTask: AnyObject, Sendable {
    func cancel()
}

protocol PlainpostServiceClientTimeoutScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any PlainpostServiceClientTimeoutTask
}

protocol PlainpostServiceClientConnection: AnyObject, Sendable {
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    var invalidationHandler: (@Sendable () -> Void)? { get set }
    func activate()
    func invalidate()
    func remoteService(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> PlainpostServiceXPCProtocol?
}

public final class PlainpostServiceClient:
    PlainpostServiceClientProtocol,
    @unchecked Sendable
{
    public static let machServiceName = "com.marynavdovenko.Plainpost.Service"

    enum Deadline: Sendable {
        case control
        case interactive
        case semantic
    }

    private struct PendingRPC: @unchecked Sendable {
        let fail: @Sendable () -> Void
    }

    private let factory: @Sendable () -> PlainpostServiceClientConnection
    private let timeouts: PlainpostServiceClientTimeouts
    private let timeoutScheduler: any PlainpostServiceClientTimeoutScheduling
    private let checkoutBarrier: @Sendable () -> Void
    private let capability: PlainpostClientCapability
    private let stateLock = NSCondition()
    private var connection: PlainpostServiceClientConnection
    private var connectionIsInvalid = false
    private var connectionIsConfiguring = false
    private var pending: [
        ObjectIdentifier: [UUID: PendingRPC]
    ] = [:]

    public convenience init() {
        self.init(capability: .app)
    }

    public convenience init(capability: PlainpostClientCapability) {
        self.init(
            connectionFactory: {
                NSXPCClientConnection(
                    machServiceName: Self.machServiceName
                )
            },
            capability: capability
        )
    }

    init(
        connectionFactory: @escaping @Sendable () ->
            PlainpostServiceClientConnection,
        capability: PlainpostClientCapability = .app
    ) {
        self.factory = connectionFactory
        timeouts = PlainpostServiceClientTimeouts()
        timeoutScheduler = DispatchTimeoutScheduler()
        checkoutBarrier = {}
        self.capability = capability
        connection = connectionFactory()
        configure(connection)
    }

    init(
        connectionFactory: @escaping @Sendable () ->
            PlainpostServiceClientConnection,
        timeouts: PlainpostServiceClientTimeouts,
        timeoutScheduler: any PlainpostServiceClientTimeoutScheduling,
        checkoutBarrier: @escaping @Sendable () -> Void = {},
        capability: PlainpostClientCapability = .app
    ) {
        self.factory = connectionFactory
        self.timeouts = timeouts
        self.timeoutScheduler = timeoutScheduler
        self.checkoutBarrier = checkoutBarrier
        self.capability = capability
        connection = connectionFactory()
        configure(connection)
    }

    deinit {
        currentConnection().invalidate()
    }

    public func status() async throws -> PlainpostVaultStatus {
        let result: Result<PlainpostVaultStatus, any Error> =
            await invoke(.control, cancelsLocalWait: true) { service, complete in
                service.status { status, error in
                    guard let status, error == nil else {
                        if let error, status == nil {
                            complete(.failure(
                                PlainpostServiceClientError(dto: error)
                            ))
                        } else {
                            complete(.failure(.serviceUnavailable))
                        }
                        return
                    }
                    do {
                        complete(.success(
                            try PlainpostVaultStatus(dto: status)
                        ))
                    } catch {
                        complete(.failure(.serviceUnavailable))
                    }
                }
            }
        return try result.get()
    }

    public func unlock(reason: String) async throws {
        let result: Result<Void, any Error> =
            await invoke(.interactive) { service, complete in
                service.unlock(reason: reason) { error in
                    if let error {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.success(()))
                    }
                }
            }
        _ = try result.get()
    }

    public func startOverAfterVaultKeyLoss(reason: String) async throws {
        guard PlainpostClientValidator.permits(.startOverAfterVaultKeyLoss, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<Void, any Error> =
            await invoke(.interactive) { service, complete in
                service.startOverAfterVaultKeyLoss(reason: reason) { error in
                    if let error {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.success(()))
                    }
                }
            }
        _ = try result.get()
    }

    public func lock() async throws {
        let result: Result<Void, any Error> =
            await invoke(.control) { service, complete in
                service.lock { error in
                    if let error {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.success(()))
                    }
                }
            }
        _ = try result.get()
    }

    public func processBackgroundJobs() async throws
        -> PlainpostBackgroundJobResult
    {
        guard capability == .agent else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<
            PlainpostBackgroundJobResult,
            any Error
        > = await invoke(.semantic) { service, complete in
            service.processBackgroundJobs { response, error in
                guard let response, error == nil else {
                    if let error, response == nil {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.failure(.serviceUnavailable))
                    }
                    return
                }
                do {
                    complete(.success(
                        try PlainpostBackgroundJobResult(dto: response)
                    ))
                } catch {
                    complete(.failure(.serviceUnavailable))
                }
            }
        }
        return try result.get()
    }

    public func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        guard capability == .cli else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let requestDTO = try request.dto()
        let result: Result<
            PlainpostSmartInboxBatchResult,
            any Error
        > = await invoke(.semantic) { service, complete in
            service.performSmartInboxBatch(requestDTO) {
                response,
                error in
                guard let response, error == nil else {
                    if let error, response == nil {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.failure(.serviceUnavailable))
                    }
                    return
                }
                do {
                    let decoded = try PlainpostSmartInboxBatchResult(
                        dto: response
                    )
                    guard decoded.accountID == request.accountID,
                          decoded.category == request.category,
                          decoded.action == request.action,
                          ArchiveMailbox.answers(decoded.archiveMailbox, requested: request.archiveMailbox)
                    else {
                        complete(.failure(.serviceUnavailable))
                        return
                    }
                    complete(.success(decoded))
                } catch {
                    complete(.failure(.serviceUnavailable))
                }
            }
        }
        return try result.get()
    }

    public func sendBrowserApprovedReply(
        jobID: String
    ) async throws -> PlainpostBrowserApprovedReplyResult {
        guard capability == .browserHost else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        guard let request = PlainpostBrowserApprovedReplyRequestDTO(
            schemaVersion: 1,
            jobID: jobID
        ) else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let result: Result<
            PlainpostBrowserApprovedReplyResult,
            any Error
        > = await invoke(.semantic) { service, complete in
            service.sendBrowserApprovedReply(request) { response, error in
                guard let response, error == nil else {
                    if let error, response == nil {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.failure(.serviceUnavailable))
                    }
                    return
                }
                do {
                    let decoded = try PlainpostBrowserApprovedReplyResult(
                        dto: response
                    )
                    guard decoded.jobID == jobID else {
                        complete(.failure(.serviceUnavailable))
                        return
                    }
                    complete(.success(decoded))
                } catch {
                    complete(.failure(.serviceUnavailable))
                }
            }
        }
        return try result.get()
    }

    public func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult {
        guard capability == .cli else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        guard let request = PlainpostDraftSyncRequestDTO(
            schemaVersion: 1,
            draftID: draftID,
            mailbox: mailbox
        ) else {
            throw PlainpostServiceClientError.invalidRequest
        }
        let result: Result<
            PlainpostDraftSyncResult,
            any Error
        > = await invoke(.semantic) { service, complete in
            service.syncDraftToServer(request) { response, error in
                guard let response, error == nil else {
                    if let error, response == nil {
                        complete(.failure(
                            PlainpostServiceClientError(dto: error)
                        ))
                    } else {
                        complete(.failure(.serviceUnavailable))
                    }
                    return
                }
                do {
                    let decoded = try PlainpostDraftSyncResult(
                        dto: response
                    )
                    guard decoded.draftID == draftID,
                          decoded.mailbox == mailbox
                    else {
                        complete(.failure(.serviceUnavailable))
                        return
                    }
                    complete(.success(decoded))
                } catch {
                    complete(.failure(.serviceUnavailable))
                }
            }
        }
        return try result.get()
    }

    public func perform(_ operation: PlainpostForegroundOperation) async throws
        -> PlainpostForegroundOperationResult
    {
        guard Self.allows(operation.kind, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let request: PlainpostForegroundOperationRequestDTO
        do {
            try operation.validate()
            request = try operation.requestDTO()
        } catch { throw PlainpostServiceClientError.invalidRequest }
        let result: Result<PlainpostForegroundOperationResult, any Error> =
            await invoke(.semantic) { service, complete in
                service.performForegroundOperation(request) { response, error in
                    guard let response, error == nil else {
                        if let error, response == nil {
                            complete(.failure(PlainpostServiceClientError(dto: error)))
                        } else {
                            complete(.failure(.serviceUnavailable))
                        }
                        return
                    }
                    do {
                        let decoded = try PlainpostForegroundOperationResult(responseDTO: response)
                        guard decoded.isSemanticallyCorrelated(
                            with: operation
                        ) else {
                            complete(.failure(.serviceUnavailable))
                            return
                        }
                        complete(.success(decoded))
                    } catch { complete(.failure(.serviceUnavailable)) }
                }
            }
        return try result.get()
    }

    public func performNodeSessionRequest(
        _ request: PlainpostNodeSessionRequest
    ) async throws -> PlainpostNodeSessionResponse {
        guard PlainpostClientValidator.permits(.performNodeSessionRequest, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let requestDTO = try request.dto()
        let result: Result<PlainpostNodeSessionResponse, any Error> =
            await invoke(.semantic) { service, complete in
                service.performNodeSessionRequest(requestDTO) { response, error in
                    guard let response, error == nil else {
                        if let error, response == nil {
                            complete(.failure(PlainpostServiceClientError(dto: error)))
                        } else {
                            complete(.failure(.serviceUnavailable))
                        }
                        return
                    }
                    do {
                        complete(.success(try PlainpostNodeSessionResponse(dto: response)))
                    } catch {
                        complete(.failure(.serviceUnavailable))
                    }
                }
            }
        return try result.get()
    }

    public func invalidateNodeSession() async throws {
        guard PlainpostClientValidator.permits(.invalidateNodeSession, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<Void, any Error> =
            await invoke(.control) { service, complete in
                service.invalidateNodeSession { error in
                    if let error {
                        complete(.failure(PlainpostServiceClientError(dto: error)))
                    } else {
                        complete(.success(()))
                    }
                }
            }
        _ = try result.get()
    }

    public func nodeSessionIdentityReadiness() async throws
        -> PlainpostNodeSessionIdentityReadiness
    {
        guard PlainpostClientValidator.permits(.nodeSessionIdentityReadiness, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<PlainpostNodeSessionIdentityReadiness, any Error> =
            await invoke(.control, cancelsLocalWait: true) { service, complete in
                service.nodeSessionIdentityReadiness { readiness, error in
                    guard let readiness, error == nil else {
                        if let error, readiness == nil {
                            complete(.failure(PlainpostServiceClientError(dto: error)))
                        } else {
                            complete(.failure(.serviceUnavailable))
                        }
                        return
                    }
                    do {
                        complete(.success(try PlainpostNodeSessionIdentityReadiness(dtoString: readiness)))
                    } catch {
                        complete(.failure(.operationFailed))
                    }
                }
            }
        return try result.get()
    }

    public func nodeMailModeStatus() async throws -> PlainpostNodeMailModeStatus {
        guard PlainpostClientValidator.permits(.nodeMailModeStatus, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<PlainpostNodeMailModeStatus, any Error> =
            await invoke(.control, cancelsLocalWait: true) { service, complete in
                service.nodeMailModeStatus { status, error in
                    guard let status, error == nil else {
                        if let error, status == nil {
                            complete(.failure(PlainpostServiceClientError(dto: error)))
                        } else {
                            complete(.failure(.serviceUnavailable))
                        }
                        return
                    }
                    do {
                        complete(.success(try PlainpostNodeMailModeStatus(dto: status)))
                    } catch {
                        complete(.failure(.operationFailed))
                    }
                }
            }
        return try result.get()
    }

    public func serviceIdentity() async throws -> PlainpostServiceBuildIdentity? {
        guard PlainpostClientValidator.permits(.serviceIdentity, for: capability) else {
            throw PlainpostServiceClientError.clientUnauthorized
        }
        let result: Result<PlainpostServiceBuildIdentity?, any Error> =
            await invoke(.control, cancelsLocalWait: true) { service, complete in
                service.serviceIdentity { bundlePath, buildStamp, error in
                    if let error {
                        complete(.failure(PlainpostServiceClientError(dto: error)))
                        return
                    }
                    guard let bundlePath, let buildStamp,
                          !bundlePath.isEmpty, !buildStamp.isEmpty,
                          bundlePath.utf8.count <= 4096, buildStamp.utf8.count <= 512
                    else {
                        complete(.success(nil))
                        return
                    }
                    complete(.success(PlainpostServiceBuildIdentity(
                        bundlePath: bundlePath,
                        buildStamp: buildStamp
                    )))
                }
            }
        return try result.get()
    }

    private static func allows(
        _ kind: PlainpostForegroundOperationKind,
        for capability: PlainpostClientCapability
    ) -> Bool {
        if capability == .app {
            return true
        }
        guard capability == .cli else {
            return false
        }
        switch kind {
        case .inboxSync, .historicalSync,
             .accountAdd, .accountTest, .replaceAccountCredentials,
             .archive, .delete, .markRead, .markUnread, .flag, .unflag, .move,
             .addLabel, .removeLabel, .labelCommand:
            return true
        case .AI, .translateMessage, .approveSend, .denySend,
             .deliverDirectDraft, .deliverBrowserReply, .deleteAccount,
             .googleAccountAdd, .replaceGoogleAccountCredential:
            return false
        @unknown default:
            return false
        }
    }

    func invoke<Value: Sendable>(
        _ deadline: Deadline,
        cancelsLocalWait: Bool = false,
        send: @escaping @Sendable (
            PlainpostServiceXPCProtocol,
            @escaping @Sendable (
                Result<Value, PlainpostServiceClientError>
            ) -> Void
        ) -> Void
    ) async -> Result<Value, any Error> {
        let cancellation = cancelsLocalWait ? RPCWaitCancellation() : nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let identifier = UUID()
                let completion = RPCCompletion<Result<Value, any Error>>(
                    reply: { continuation.resume(returning: $0) },
                    onFinish: { [weak self] in
                        cancellation?.clear()
                        self?.unregister(identifier)
                    }
                )
                cancellation?.install {
                    completion.complete(.failure(CancellationError()))
                }
                guard let current = checkoutAndRegister(
                    identifier,
                    isCompleted: { completion.isCompleted },
                    failure: {
                        completion.complete(.failure(PlainpostServiceClientError.serviceUnavailable))
                    }
                ) else { return }
                checkoutBarrier()
                guard !completion.isCompleted else { return }

                guard let service = current.remoteService(
                    errorHandler: { [weak self, weak current] _ in
                        guard let self, let current else {
                            completion.complete(.failure(PlainpostServiceClientError.serviceUnavailable))
                            return
                        }
                        self.failConnection(current)
                    }
                ) else {
                    failConnection(current)
                    return
                }

                completion.arm(
                    timeoutScheduler.schedule(after: timeout(for: deadline)) { [weak self, weak current] in
                        guard let self, let current else {
                            completion.complete(.failure(PlainpostServiceClientError.timedOut))
                            return
                        }
                        self.timeout(identifier, on: current) {
                            completion.claim(.failure(PlainpostServiceClientError.timedOut))
                        }
                    }
                )
                // Cancellation after this admission may still send service-owned work.
                // Never call the proxy under a client/completion lock: it can reply inline.
                guard completion.admitSend() else { return }
                send(service) { completion.complete($0.mapError { $0 as any Error }) }
            }
        } onCancel: {
            cancellation?.cancel()
        }
    }

    private func timeout(for deadline: Deadline) -> TimeInterval {
        switch deadline {
        case .control:
            return timeouts.control
        case .interactive:
            return timeouts.interactive
        case .semantic:
            return timeouts.semantic
        }
    }

    private func currentConnection() -> PlainpostServiceClientConnection {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        return connection
    }

    private func checkoutAndRegister(
        _ identifier: UUID,
        isCompleted: () -> Bool,
        failure: @escaping @Sendable () -> Void
    ) -> PlainpostServiceClientConnection? {
        stateLock.lock()
        while connectionIsConfiguring && !isCompleted() {
            stateLock.wait()
        }
        // stateLock → completion lock. A racing cancellation unregisters only
        // after this insertion unlocks, or prevents registration entirely.
        guard !isCompleted() else {
            stateLock.unlock()
            return nil
        }
        let needsConfiguration: Bool
        if connectionIsInvalid {
            connection = factory()
            connectionIsInvalid = false
            connectionIsConfiguring = true
            needsConfiguration = true
        } else {
            needsConfiguration = false
        }
        let current = connection
        let key = ObjectIdentifier(current)
        pending[key, default: [:]][identifier] = PendingRPC(fail: failure)
        stateLock.unlock()

        if needsConfiguration {
            configure(current)
            stateLock.lock()
            if connection === current {
                connectionIsConfiguring = false
            }
            stateLock.broadcast()
            stateLock.unlock()
        }
        return current
    }

    private func unregister(_ identifier: UUID) {
        stateLock.lock()
        let keys = Array(pending.keys)
        for key in keys {
            pending[key]?.removeValue(forKey: identifier)
            if pending[key]?.isEmpty == true {
                pending.removeValue(forKey: key)
            }
        }
        // Cancellation can win before registration while another caller configures.
        // Wake that condition waiter without cancelling the shared activation.
        stateLock.broadcast()
        stateLock.unlock()
    }

    private func configure(
        _ connection: PlainpostServiceClientConnection
    ) {
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else {
                return
            }
            self?.failConnection(connection)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else {
                return
            }
            self?.failConnection(connection)
        }
        connection.activate()
    }

    private func failConnection(
        _ expected: PlainpostServiceClientConnection
    ) {
        let failures: [@Sendable () -> Void]
        let shouldInvalidate: Bool

        stateLock.lock()
        let key = ObjectIdentifier(expected)
        failures = pending.removeValue(forKey: key)?.values.map(\.fail) ?? []
        if connection === expected {
            shouldInvalidate = !connectionIsInvalid
            connectionIsInvalid = true
        } else {
            shouldInvalidate = false
        }
        stateLock.unlock()

        if shouldInvalidate {
            expected.invalidate()
        }
        for failure in failures {
            failure()
        }
    }

    private func timeout(
        _ identifier: UUID,
        on expected: PlainpostServiceClientConnection,
        claimCompletion: () -> (@Sendable () -> Void)?
    ) {
        let failures: [@Sendable () -> Void]
        let shouldInvalidate: Bool

        stateLock.lock()
        let key = ObjectIdentifier(expected)
        // Membership and once-completion must be won together. Cancelling a
        // Dispatch task cannot stop a timer action that has already started.
        guard pending[key]?[identifier] != nil, let finish = claimCompletion() else {
            stateLock.unlock()
            return
        }
        pending[key]?.removeValue(forKey: identifier)
        failures = pending.removeValue(forKey: key)?.values.map(\.fail) ?? []
        if connection === expected {
            shouldInvalidate = !connectionIsInvalid
            connectionIsInvalid = true
        } else {
            shouldInvalidate = false
        }
        stateLock.unlock()

        if shouldInvalidate {
            expected.invalidate()
        }
        for failure in failures {
            failure()
        }
        finish()
    }
}

private final class RPCCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var sendAdmitted = false
    private var timeoutTask: (
        (any PlainpostServiceClientTimeoutTask)?
    )
    private var reply: (@Sendable (Value) -> Void)?
    private var onFinish: (@Sendable () -> Void)?

    init(
        reply: @escaping @Sendable (Value) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.reply = reply
        self.onFinish = onFinish
    }

    func arm(_ task: any PlainpostServiceClientTimeoutTask) {
        lock.lock()
        let shouldCancel = completed
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    var isCompleted: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return completed
    }

    func admitSend() -> Bool {
        lock.withLock {
            guard !completed, !sendAdmitted else { return false }
            sendAdmitted = true
            return true
        }
    }

    func complete(_ value: Value) { claim(value)?() }

    // Claim while locked, but detach all effects so stateLock may safely call
    // this method. The returned finalizer must run after stateLock is released.
    func claim(_ value: Value) -> (@Sendable () -> Void)? {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return nil
        }
        completed = true
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        let reply = reply
        self.reply = nil
        let onFinish = onFinish
        self.onFinish = nil
        lock.unlock()

        return {
            timeoutTask?.cancel()
            onFinish?()
            reply?(value)
        }
    }
}

private final class RPCWaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        let cancelNow = lock.withLock {
            if cancelled { return true }
            self.action = action
            return false
        }
        if cancelNow { action() }
    }

    func cancel() {
        let action = lock.withLock {
            cancelled = true
            let action = self.action
            self.action = nil
            return action
        }
        action?()
    }

    func clear() { lock.withLock { action = nil } }
}

private struct DispatchTimeoutScheduler:
    PlainpostServiceClientTimeoutScheduling
{
    func schedule(
        after delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any PlainpostServiceClientTimeoutTask {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
        return DispatchTimeoutTask(item: item)
    }
}

private final class DispatchTimeoutTask:
    PlainpostServiceClientTimeoutTask,
    @unchecked Sendable
{
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

#if os(macOS)
private final class NSXPCClientConnection:
    NSObject,
    PlainpostServiceClientConnection,
    @unchecked Sendable
{
    private let connection: NSXPCConnection

    var interruptionHandler: (@Sendable () -> Void)? {
        didSet {
            connection.interruptionHandler = interruptionHandler
        }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        didSet {
            connection.invalidationHandler = invalidationHandler
        }
    }

    init(machServiceName: String) {
        connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: []
        )
        connection.remoteObjectInterface = PlainpostServiceXPCInterface.make()
    }

    func activate() {
        connection.activate()
    }

    func invalidate() {
        connection.invalidate()
    }

    func remoteService(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> PlainpostServiceXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler(
            errorHandler
        ) as? PlainpostServiceXPCProtocol
    }
}
#else
private final class NSXPCClientConnection: PlainpostServiceClientConnection, @unchecked Sendable {
    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?

    init(machServiceName _: String) {}
    func activate() {}
    func invalidate() {}
    func remoteService(errorHandler: @escaping @Sendable (Error) -> Void) -> PlainpostServiceXPCProtocol? {
        errorHandler(PlainpostServiceClientError.serviceUnavailable)
        return nil
    }
}
#endif
