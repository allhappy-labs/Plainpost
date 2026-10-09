import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperationRuntime

/// The iPhone's direct route for a Sync Node account in fallback: the journal's change goes
/// to the provider with the phone's own sign-in for the account, as a Direct account's would.
/// Flag and move wait for the Node, as on the Mac; a draft stays on the phone until it is sent.
public struct DeviceDirectMailDispatcher: DirectMailDispatching {
    private let store: SQLiteMailStore
    private let perform: @Sendable (DirectMailboxAction, MessageID, String?) async throws -> Void
    private let deliver: @Sendable (DraftID, String) async throws -> Void
    private static let backToNode = "This account's mail is handled by the Sync Node again."

    /// - Parameters:
    ///   - perform: the device's Direct action, as `DirectMailboxActionService.perform`.
    ///     Read state is durable once written: its flag job reaches the provider before the
    ///     account can leave fallback.
    ///   - deliver: the journaled fallback send, as
    ///     `LocalDraftDeliveryService.deliverRoutedFallback`; it re-checks the approved hash.
    public init(
        store: SQLiteMailStore,
        perform: @escaping @Sendable (DirectMailboxAction, MessageID, String?) async throws -> Void,
        deliver: @escaping @Sendable (DraftID, String) async throws -> Void
    ) {
        self.store = store
        self.perform = perform
        self.deliver = deliver
    }

    public init(store: SQLiteMailStore, actions: DirectMailboxActionService, delivery: LocalDraftDeliveryService) {
        let actor = Actor(id: "local-user", kind: .user, displayName: "Local User", permissions: .guiUser)
        self.init(
            store: store,
            perform: { action, messageID, archiveMailbox in
                _ = try await actions.perform(action, messageID: messageID, archiveMailbox: archiveMailbox)
            },
            deliver: { draftID, hash in
                _ = try await delivery.deliverRoutedFallback(draftID: draftID, expectedHash: hash, actor: actor)
            }
        )
    }

    public func perform(_ action: MailIntentKind, messageID: MessageID, archiveMailbox: String?) async throws {
        guard let accountID = store.accountID(forMessageID: messageID) else {
            throw DirectMailDispatchRefusal(message: "Message not found.")
        }
        let direct: DirectMailboxAction
        switch action {
        case .markRead: direct = .markRead
        case .markUnread: direct = .markUnread
        case .archive: direct = .archive
        case .delete: direct = .delete
        case .flag, .unflag, .move:
            throw DirectMailDispatchDeferral(reason: "This change waits for your Sync Node.")
        case .saveDraft, .send, .credentialPush:
            throw DirectMailDispatchRefusal(message: "This change can't be sent directly.")
        }
        try await dispatch(accountID: accountID) {
            try await perform(direct, messageID, action == .archive ? archiveMailbox : nil)
        }
    }

    public func saveDraft(_ draft: Draft) async throws {
        throw DirectMailDispatchDeferral(reason: "This draft stays on this iPhone until it is sent.")
    }

    public func send(_ draft: Draft, approvedContentHash: String) async throws {
        try await dispatch(accountID: draft.accountID) {
            try await deliver(draft.id, approvedContentHash)
        }
    }

    /// Runs `body` while the account is still in fallback. A failure before any provider
    /// effect becomes a refusal, or a deferral when its reason passes (locked, unreachable,
    /// or the account went back to its Node meanwhile); anything else stays ambiguous.
    private func dispatch(accountID: AccountID, _ body: () async throws -> Void) async throws {
        do {
            guard try store.mailSource(accountID: accountID).runsDirectSync else {
                throw DirectMailDispatchDeferral(reason: Self.backToNode)
            }
            try await body()
        } catch {
            if let deferral = DirectMailDispatchErrors.deferral(for: error) { throw deferral }
            if let refusal = DirectMailDispatchErrors.refusal(for: error) {
                if let source = try? store.mailSource(accountID: accountID), !source.runsDirectSync {
                    throw DirectMailDispatchDeferral(reason: Self.backToNode)
                }
                throw refusal
            }
            throw error
        }
    }
}
