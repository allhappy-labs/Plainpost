import Foundation
import PlainpostNodeTransport

public protocol CalendarServing: Sendable {
    func capabilities() async throws -> NodeCalendarCapabilities
    func connections() async throws -> [NodeCalendarConnection]
    func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult
    func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult
    func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot
    func event(id: String) async throws -> NodeCalendarEvent
    func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation]
    func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt
    func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt]
    /// Durable receipts observed by any surface of the same account authority.
    func receiptUpdates() async -> AsyncStream<NodeCalendarReceipt>
}

extension CalendarServing {
    public func receiptUpdates() async -> AsyncStream<NodeCalendarReceipt> { AsyncStream { $0.finish() } }
}

extension NodeCalendarClient: CalendarServing {}

public struct CalendarSendingMailbox: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One account binding per lifetime. Invalidated authorities can never be rebound.
public actor PlainpostCalendarAuthority: CalendarServing {
    public nonisolated let accountID: String
    public nonisolated let sendingMailboxes: [CalendarSendingMailbox]
    private let client: NodeCalendarClient
    private var generation: UInt64 = 0
    private var valid = true
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<NodeCalendarReceipt>.Continuation] = [:]
    private var observedReceipts: [String: NodeCalendarReceipt] = [:]
    public init(client: NodeCalendarClient, accountID: String, sendingMailboxes: [CalendarSendingMailbox] = []) { self.client = client; self.accountID = accountID; self.sendingMailboxes = sendingMailboxes }
    public func invalidate() {
        valid = false; generation &+= 1
        let finished = observers.values; observers = [:]; observedReceipts = [:]
        finished.forEach { $0.finish() }
    }
    /// Thread cards and the week view share one receipt truth: every changed
    /// durable receipt read or admitted through this account is published once.
    public func receiptUpdates() -> AsyncStream<NodeCalendarReceipt> {
        let (stream, continuation) = AsyncStream<NodeCalendarReceipt>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard valid else { continuation.finish(); return stream }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    public func capabilities() async throws -> NodeCalendarCapabilities {
        try await fenced { try await $0.capabilities() }
    }
    public func connections() async throws -> [NodeCalendarConnection] {
        try await fenced { try await $0.connections() }
    }
    public func configure(_ command: NodeCalendarConnectionCommand) async throws -> NodeCalendarConnectionResult {
        try await fenced { try await $0.configure(command) }
    }
    public func disconnect(_ command: NodeCalendarDisconnectCommand) async throws -> NodeCalendarConnectionResult {
        try await fenced { try await $0.disconnect(command) }
    }
    public func window(_ request: NodeCalendarWindowRequest) async throws -> NodeCalendarWindowSnapshot {
        try await fenced { try await $0.window(request) }
    }
    public func event(id: String) async throws -> NodeCalendarEvent {
        try await fenced { try await $0.event(id: id) }
    }
    public func invitations(messageIDs: [String]) async throws -> [NodeCalendarInvitation] {
        try await fenced { try await $0.invitations(messageIDs: messageIDs) }
    }
    public func submit(_ command: NodeCalendarCommand) async throws -> NodeCalendarReceipt {
        let receipt = try await fenced { try await $0.submit(command) }
        publish([receipt])
        return receipt
    }
    public func receipts(operationIDs: [String]) async throws -> [NodeCalendarReceipt] {
        let receipts = try await fenced { try await $0.receipts(operationIDs: operationIDs) }
        publish(receipts)
        return receipts
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ receipts: [NodeCalendarReceipt]) {
        guard valid else { return }
        for receipt in receipts where observedReceipts[receipt.operationID] != receipt {
            if observedReceipts.count >= 1_024 { observedReceipts = [:] }
            observedReceipts[receipt.operationID] = receipt
            observers.values.forEach { $0.yield(receipt) }
        }
    }
    private func fenced<T: Sendable>(_ action: @Sendable (NodeCalendarClient) async throws -> T) async throws -> T {
        let started = generation
        guard valid else { throw CancellationError() }
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        guard valid, generation == started else { throw CancellationError() }
        let result = try await action(client)
        try Task.checkCancellation()
        guard valid, generation == started else { throw CancellationError() }
        return result
    }
}
