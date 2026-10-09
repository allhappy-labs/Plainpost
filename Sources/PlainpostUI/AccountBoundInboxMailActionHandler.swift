import PlainpostCore
import PlainpostDB

/// Applies a selected-account boundary to injected action handlers as well as
/// the production Direct handler. The Direct service repeats this check after
/// resolving the exact membership it will mutate.
public struct AccountBoundInboxMailActionHandler: InboxMailActionHandling {
    private let store: SQLiteMailStore
    private let selectedAccountID: AccountID
    private let underlying: any InboxMailActionHandling

    public init(
        store: SQLiteMailStore,
        selectedAccountID: AccountID,
        underlying: any InboxMailActionHandling
    ) {
        self.store = store
        self.selectedAccountID = selectedAccountID
        self.underlying = underlying
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        try await perform(action, messageID: messageID, shownIn: nil)
    }

    public func perform(
        _ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?
    ) async throws -> InboxMailActionResult {
        let membership = try store.membership(for: messageID)
        guard membership.accountID == selectedAccountID else {
            throw PlainpostError.permissionDenied("The message does not belong to the selected account.")
        }
        return try await underlying.perform(action, messageID: messageID, shownIn: mailboxPath)
    }
}
