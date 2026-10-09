import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime
import PlainpostOperations

public protocol MailboxFlagScheduling: Sendable {
    func schedule(_ input: PlainpostMailboxFlagInput) throws
    func signalWork() async throws
}

public protocol HumanMessageOpeningStore {
    func openMessageForHuman(
        _ messageID: MessageID,
        actor: Actor,
        scheduler: any MailboxFlagScheduling
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool)
}

public final class DurableMailboxFlagScheduler: MailboxFlagScheduling, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let workerSignal: any OperationWorkerSignaling

    public init(
        store: SQLiteMailStore,
        workerSignal: any OperationWorkerSignaling = NoopOperationWorkerSignal()
    ) {
        self.store = store
        self.workerSignal = workerSignal
    }

    public func schedule(_ input: PlainpostMailboxFlagInput) throws {
        let data = try JSONEncoder().encode(input)
        _ = try store.enqueueJob(
            PlainpostJobRequest(
                kind: .mailboxFlag,
                payloadJSON: String(decoding: data, as: UTF8.self),
                priority: 100,
                idempotencyKey: "mailbox-flag:\(input.accountID?.rawValue ?? "missing-account"):\(input.mailboxPath ?? "missing-mailbox"):\(input.uidValidity.map(String.init) ?? "missing-validity"):\(input.uid.map(String.init) ?? "missing-uid"):\(input.messageID.rawValue):\(input.desiredSeen)",
                replaceTerminalDuplicate: true
            )
        )
    }

    public func signalWork() async throws {
        try await workerSignal.signalWork()
    }
}

extension SQLiteMailStore: HumanMessageOpeningStore {
    public func openMessageForHuman(
        _ messageID: MessageID,
        actor: Actor,
        scheduler: any MailboxFlagScheduling
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool) {
        try openMessageForHumanResult(messageID, actor: actor)
    }
}

extension InMemoryMailStore: HumanMessageOpeningStore {
    public func openMessageForHuman(
        _ messageID: MessageID,
        actor: Actor,
        scheduler: any MailboxFlagScheduling
    ) throws -> (message: MessageSummary, scheduledRemoteFlag: Bool) {
        guard let message = messages.first(where: { $0.id == messageID && !$0.isDeleted }) else {
            throw PlainpostError.notFound("Message not found.")
        }
        guard !message.isSeen else { return (message, false) }
        let membership = try membership(for: messageID)
        let updated = try markSeen(messageID, seen: true, actor: actor)
        do {
            try scheduler.schedule(PlainpostMailboxFlagInput(
                messageID: messageID,
                accountID: membership.accountID,
                mailboxPath: membership.mailboxPath,
                uidValidity: membership.uidValidity,
                uid: membership.uid,
                desiredSeen: true
            ))
        } catch {
            let schedulingError = error
            _ = try markSeen(messageID, seen: false, actor: actor)
            throw schedulingError
        }
        return (updated, true)
    }
}

public final class MessageOpeningService<Store: HumanMessageOpeningStore>: @unchecked Sendable {
    private let store: Store
    private let scheduler: any MailboxFlagScheduling
    private let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)

    public init(store: Store, scheduler: any MailboxFlagScheduling) {
        self.store = store
        self.scheduler = scheduler
    }

    public func open(_ messageID: MessageID) async throws -> MessageSummary {
        let result = try store.openMessageForHuman(messageID, actor: actor, scheduler: scheduler)
        if result.scheduledRemoteFlag {
            try? await scheduler.signalWork()
        }
        return result.message
    }
}
