import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostSecrets
import PlainpostUI

/// Device-local composition for the shared account-owned action service.
public struct IOSDirectInboxActionHandler: InboxMailActionHandling {
    private let actions: DirectMailboxActionService

    public init(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling,
        credentials: any CredentialVault,
        credentialResolver: MailCredentialResolver? = nil,
        selectedAccountID: AccountID? = nil,
        imapClientFactory: @escaping @Sendable (String, UInt16) -> IMAPClientProtocol = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        }
    ) {
        actions = DirectMailboxActionService(
            store: store,
            credentials: credentialResolver ?? .withoutGoogleOAuth(store: store, credentials: credentials),
            requireExplicitDirectSource: true,
            selectedAccountID: selectedAccountID,
            imapClientFactory: imapClientFactory,
            signalFlagWork: { try await mailboxFlagScheduler.signalWork() }
        )
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws -> InboxMailActionResult {
        try await perform(action, messageID: messageID, shownIn: nil)
    }

    public func perform(
        _ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?
    ) async throws -> InboxMailActionResult {
        let directAction: DirectMailboxAction
        switch action {
        case .markRead: directAction = .markRead
        case .markUnread: directAction = .markUnread
        case .archive: directAction = .archive
        case .delete: directAction = .delete
        case .deletePermanently: directAction = .deletePermanently
        case .flag: directAction = .flag
        case .unflag: directAction = .unflag
        case .move(let destination): directAction = .move(to: destination)
        }
        let result = try await actions.perform(directAction, messageID: messageID, shownIn: mailboxPath)
        let message = result.message
        let moves = if case .move = action { true } else { false }
        return InboxMailActionResult(
            messageID: message.id,
            action: action,
            seen: action == .markRead || action == .markUnread ? message.isSeen : nil,
            // A Delete that left the message in Trash reports where it is.
            mailboxPath: action == .archive || moves || (action == .delete && !message.isDeleted) ? message.mailboxPath : nil,
            deleted: message.isDeleted,
            deleteOutcome: result.deleteOutcome,
            alreadyArchived: result.alreadyArchived
        )
    }
}
