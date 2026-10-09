import PlainpostCore
import PlainpostDB

/// Label menu reads and writes for the device-wide runtime: each message's labels change
/// through its own account, while that account is still Direct at the generation the list
/// showing it was read with. Checked again at mutation time, because a menu can stay open
/// across a source change.
@MainActor
enum OwnerBoundMessageLabelActionsFactory {
    static func make(
        store: SQLiteMailStore,
        readGeneration: @escaping @Sendable (MessageID, AccountID) -> Int64?
    ) -> MessageLabelActions {
        let snapshots = OwnerBoundLabelSnapshots(store: store, readGeneration: readGeneration)
        let actor = Actor(id: "local-user", kind: .user,
                          displayName: "Local User", permissions: .guiUser)
        return MessageLabelActions(snapshots: snapshots) { labelID, messageID, selected in
            guard let owner = store.accountID(forMessageID: messageID) else {
                throw PlainpostError.notFound("The message's account was not found.")
            }
            let generation = try requireReadOwner(owner, of: messageID, store: store, readGeneration: readGeneration)
            _ = try store.operationAccountID(forMessageID: messageID, explicitAccountID: owner)
            if selected {
                try store.establishUserLabel(
                    labelID: labelID, on: messageID, actor: actor,
                    selectedDirectSource: (owner, generation)
                )
            } else {
                try store.removeUserOrSmartInboxLabel(
                    labelID: labelID, from: messageID, actor: actor,
                    selectedDirectSource: (owner, generation)
                )
            }
        }
    }
}

private final class OwnerBoundLabelSnapshots: MessageLabelActionSnapshotRepository, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let readGeneration: @Sendable (MessageID, AccountID) -> Int64?

    init(store: SQLiteMailStore, readGeneration: @escaping @Sendable (MessageID, AccountID) -> Int64?) {
        self.store = store
        self.readGeneration = readGeneration
    }

    func messageLabelActionSnapshot(for messageID: MessageID) async throws -> MessageLabelActionSnapshot {
        let snapshot = try await store.messageLabelActionSnapshot(for: messageID)
        guard let owner = snapshot.accountID else {
            throw PlainpostError.notFound("The message's account was not found.")
        }
        // The read suspends; the owner's source must still be the one the list was read with.
        try requireReadOwner(owner, of: messageID, store: store, readGeneration: readGeneration)
        return snapshot
    }
}

/// `owner`'s generation, while it is still Direct at the generation the list was read with.
@discardableResult
private func requireReadOwner(
    _ owner: AccountID,
    of messageID: MessageID,
    store: SQLiteMailStore,
    readGeneration: @Sendable (MessageID, AccountID) -> Int64?
) throws -> Int64 {
    guard let expected = readGeneration(messageID, owner) else { throw NodeMailModeStoreError.generationConflict }
    return try DeviceMailScope.requireCurrentOwner(owner, expected: expected, in: store)
}
