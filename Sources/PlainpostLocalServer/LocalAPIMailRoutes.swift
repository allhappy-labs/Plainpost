import Foundation
import PlainpostCore
import PlainpostLocalAPI
import PlainpostOperations

public struct SessionStatusRoute: LocalAPIRoute {
    public let method = LocalAPIMethod.sessionStatus

    public init() {}

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let _: LocalAPIRequest<LocalAPIEmptyParameters> = try decodeRequest(requestData)
        return try encodeSuccess(
            requestID: requestID,
            result: LocalAPISessionStatus(ready: true)
        )
    }
}

public final class UnreadListRoute<Store: MessageRepository>: LocalAPIRoute, @unchecked Sendable {
    public let method = LocalAPIMethod.mailUnreadList

    private let store: Store
    private let lastSync: @Sendable () -> Date?

    public init(store: Store, lastSync: @escaping @Sendable () -> Date?) {
        self.store = store
        self.lastSync = lastSync
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIUnreadListParameters> = try decodeRequest(requestData)
        let limit = min(max(request.parameters.limit, 1), 10)
        let messages = store.messages
            .filter { !$0.isSeen && !$0.isDeleted }
            .sorted(by: newestFirst)
            .prefix(limit)
            .map {
                LocalAPIUnreadMessage(
                    id: $0.id.rawValue,
                    sender: $0.from.rawValue,
                    senderName: $0.fromDisplayName,
                    subject: $0.subject,
                    preview: $0.preview,
                    sentAt: $0.sentAt
                )
            }
        return try encodeSuccess(
            requestID: requestID,
            result: LocalAPIUnreadListResult(
                messages: messages,
                lastSuccessfulSyncAt: lastSync()
            )
        )
    }
}

public struct OpenMessageRoute<Store: HumanMessageOpeningStore>: LocalAPIRoute {
    public let method = LocalAPIMethod.mailOpen

    private let opening: MessageOpeningService<Store>

    public init(opening: MessageOpeningService<Store>) {
        self.opening = opening
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let request: LocalAPIRequest<LocalAPIOpenMessageParameters> = try decodeRequest(requestData)
        let message: MessageSummary
        do {
            message = try await opening.open(MessageID(request.parameters.messageID))
        } catch let error as PlainpostError {
            throw routeError(for: error)
        }
        return try encodeSuccess(
            requestID: requestID,
            result: LocalAPIMessageDetail(
                id: message.id.rawValue,
                threadID: message.threadID?.rawValue,
                sender: message.from.rawValue,
                senderName: message.fromDisplayName,
                subject: message.subject,
                bodyPlain: truncateUTF8(
                    message.body,
                    maximumBytes: LocalAPIProtocol.maximumMessageBodyBytes
                ),
                isSeen: message.isSeen
            )
        )
    }
}

public struct IncrementalSyncAllRoute: LocalAPIRoute {
    public let method = LocalAPIMethod.syncIncrementalAll

    private let accountIDs: @Sendable () -> [AccountID]
    private let syncer: any PlainpostOperationClientProtocol
    private let coordinator = IncrementalSyncCoordinator()

    public init(
        accountIDs: @escaping @Sendable () -> [AccountID],
        syncer: any PlainpostOperationClientProtocol
    ) {
        self.accountIDs = accountIDs
        self.syncer = syncer
    }

    public func handle(requestData: Data, requestID: String) async throws -> Data {
        let _: LocalAPIRequest<LocalAPIEmptyParameters> = try decodeRequest(requestData)
        var seenAccountIDs = Set<AccountID>()
        let orderedAccountIDs = accountIDs().filter { seenAccountIDs.insert($0).inserted }
        let outcomes = await withTaskGroup(of: IncrementalSyncOutcome.self) { group in
            for (index, accountID) in orderedAccountIDs.enumerated() {
                let input = PlainpostInboxSyncInput(
                    accountID: accountID,
                    trigger: .manual,
                    scope: .incremental
                )
                group.addTask { [coordinator, syncer] in
                    do {
                        let result = try await coordinator.execute(input) {
                            try await syncer.executeInboxSync(input)
                        }
                        return .completed(
                            index: index,
                            accountID: accountID.rawValue,
                            newMessageCount: result.newlyDiscoveredMessageCount
                        )
                    } catch {
                        return .failed(index: index, accountID: accountID.rawValue)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let orderedOutcomes = outcomes.sorted { $0.index < $1.index }
        let completedAccountIDs = orderedOutcomes.compactMap(\.completedAccountID)
        let failedAccountIDs = orderedOutcomes.compactMap(\.failedAccountID)
        let newMessageCount = orderedOutcomes.reduce(0) { $0 + $1.newMessageCount }

        return try encodeSuccess(
            requestID: requestID,
            result: LocalAPISyncResult(
                completedAccountIDs: completedAccountIDs,
                failedAccountIDs: failedAccountIDs,
                newMessageCount: newMessageCount
            )
        )
    }
}

actor IncrementalSyncCoordinator {
    private struct Key: Hashable {
        let accountID: String
        let scope: PlainpostSyncScope
    }

    private struct Waiter {
        let continuation: CheckedContinuation<PlainpostInboxSyncResult, Error>
        let cancellation: IncrementalSyncWaiterCancellation
    }

    private struct InFlight {
        let token: UUID
        var waiters: [UUID: Waiter]
    }

    private var inFlight: [Key: InFlight] = [:]

    var activeWaiterCount: Int {
        inFlight.values.reduce(0) { $0 + $1.waiters.count }
    }

    var activeOperationCount: Int { inFlight.count }

    func execute(
        _ input: PlainpostInboxSyncInput,
        operation: @escaping @Sendable () async throws -> PlainpostInboxSyncResult
    ) async throws -> PlainpostInboxSyncResult {
        let key = Key(accountID: input.accountID.rawValue, scope: input.scope)
        let waiterID = UUID()
        let cancellation = IncrementalSyncWaiterCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                register(
                    continuation,
                    cancellation: cancellation,
                    waiterID: waiterID,
                    key: key,
                    operation: operation
                )
            }
        } onCancel: {
            cancellation.cancel()
            Task { [self] in
                await cancelWaiter(waiterID, key: key)
            }
        }
    }

    private func register(
        _ continuation: CheckedContinuation<PlainpostInboxSyncResult, Error>,
        cancellation: IncrementalSyncWaiterCancellation,
        waiterID: UUID,
        key: Key,
        operation: @escaping @Sendable () async throws -> PlainpostInboxSyncResult
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let waiter = Waiter(continuation: continuation, cancellation: cancellation)
        if var existing = inFlight[key] {
            existing.waiters[waiterID] = waiter
            inFlight[key] = existing
            return
        }

        let token = UUID()
        inFlight[key] = InFlight(token: token, waiters: [waiterID: waiter])
        Task.detached { [self] in
            let result: Result<PlainpostInboxSyncResult, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            await finish(key: key, token: token, result: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, key: Key) {
        guard var existing = inFlight[key],
              let waiter = existing.waiters.removeValue(forKey: waiterID) else { return }
        inFlight[key] = existing
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finish(
        key: Key,
        token: UUID,
        result: Result<PlainpostInboxSyncResult, Error>
    ) {
        guard let existing = inFlight[key], existing.token == token else { return }
        inFlight.removeValue(forKey: key)
        for waiter in existing.waiters.values {
            if waiter.cancellation.isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume(with: result)
            }
        }
    }
}

private final class IncrementalSyncWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

private enum IncrementalSyncOutcome: Sendable {
    case completed(index: Int, accountID: String, newMessageCount: Int)
    case failed(index: Int, accountID: String)

    var index: Int {
        switch self {
        case .completed(let index, _, _), .failed(let index, _): index
        }
    }

    var completedAccountID: String? {
        guard case .completed(_, let accountID, _) = self else { return nil }
        return accountID
    }

    var failedAccountID: String? {
        guard case .failed(_, let accountID) = self else { return nil }
        return accountID
    }

    var newMessageCount: Int {
        guard case .completed(_, _, let count) = self else { return 0 }
        return count
    }
}

func decodeRequest<Parameters: Codable & Sendable>(
    _ data: Data
) throws -> LocalAPIRequest<Parameters> {
    do {
        return try JSONDecoder().decode(LocalAPIRequest<Parameters>.self, from: data)
    } catch {
        throw LocalAPIRouteError(
            code: .invalidRequest,
            safeMessage: "The request parameters are invalid."
        )
    }
}

func encodeSuccess<Result: Codable & Sendable>(
    requestID: String,
    result: Result
) throws -> Data {
    try LocalAPIJSON.makeEncoder().encode(LocalAPISuccess(requestID: requestID, result: result))
}

private func newestFirst(_ lhs: MessageSummary, _ rhs: MessageSummary) -> Bool {
    switch (lhs.sentAt, rhs.sentAt) {
    case let (left?, right?) where left != right:
        return left > right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id.rawValue > rhs.id.rawValue
    }
}

private func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var bytes = Data(value.utf8.prefix(maximumBytes))
    while !bytes.isEmpty {
        if let result = String(data: bytes, encoding: .utf8) {
            return result
        }
        bytes.removeLast()
    }
    return ""
}

func routeError(for error: PlainpostError) -> LocalAPIRouteError {
    switch error {
    case .notFound(let message):
        return LocalAPIRouteError(code: .notFound, safeMessage: message)
    case .permissionDenied(let message):
        return LocalAPIRouteError(code: .permissionDenied, safeMessage: message)
    case .validationFailed(let message):
        return LocalAPIRouteError(code: .invalidRequest, safeMessage: message)
    }
}
