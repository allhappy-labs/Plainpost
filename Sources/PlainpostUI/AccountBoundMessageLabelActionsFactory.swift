import PlainpostCore
import PlainpostDB

/// Label menu reads and writes for a selected device-local Direct account.
/// The account is checked again at mutation time because an old menu can stay
/// open after the selected mailbox or source ownership changes.
@MainActor
enum AccountBoundMessageLabelActionsFactory {
    static func make(
        store: SQLiteMailStore,
        selectedAccountID: AccountID,
        sourceGeneration: Int64
    ) -> MessageLabelActions {
        let snapshots = AccountBoundLabelSnapshots(
            store: store,
            selectedAccountID: selectedAccountID,
            sourceGeneration: sourceGeneration
        )
        let actor = Actor(id: "local-user", kind: .user,
                          displayName: "Local User", permissions: .guiUser)
        return MessageLabelActions(snapshots: snapshots) { labelID, messageID, selected in
            try requireCapturedDirectSource(
                store: store, accountID: selectedAccountID, generation: sourceGeneration
            )
            _ = try store.operationAccountID(
                forMessageID: messageID, explicitAccountID: selectedAccountID
            )
            if selected {
                try store.establishUserLabel(
                    labelID: labelID, on: messageID, actor: actor,
                    selectedDirectSource: (selectedAccountID, sourceGeneration)
                )
            } else {
                try store.removeUserOrSmartInboxLabel(
                    labelID: labelID, from: messageID, actor: actor,
                    selectedDirectSource: (selectedAccountID, sourceGeneration)
                )
            }
        }
    }
}

private final class AccountBoundLabelSnapshots: MessageLabelActionSnapshotRepository, @unchecked Sendable {
    private let store: SQLiteMailStore
    private let selectedAccountID: AccountID
    private let sourceGeneration: Int64

    init(store: SQLiteMailStore, selectedAccountID: AccountID, sourceGeneration: Int64) {
        self.store = store
        self.selectedAccountID = selectedAccountID
        self.sourceGeneration = sourceGeneration
    }

    func messageLabelActionSnapshot(for messageID: MessageID) async throws -> MessageLabelActionSnapshot {
        try requireCapturedDirectSource(
            store: store, accountID: selectedAccountID, generation: sourceGeneration
        )
        let snapshot = try await store.messageLabelActionSnapshot(for: messageID)
        // The read itself suspends; reject a source handover that completed while
        // the database snapshot was being assembled.
        try requireCapturedDirectSource(
            store: store, accountID: selectedAccountID, generation: sourceGeneration
        )
        guard snapshot.accountID == selectedAccountID else {
            throw PlainpostError.permissionDenied("The message does not belong to the selected account.")
        }
        return snapshot
    }
}

private func requireCapturedDirectSource(
    store: SQLiteMailStore,
    accountID: AccountID,
    generation: Int64
) throws {
    try store.requireDirectMailSource(accountID: accountID)
    guard try store.mailSource(accountID: accountID).generation == generation else {
        throw NodeMailModeStoreError.generationConflict
    }
}
