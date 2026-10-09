import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations

/// Abstracts runtime components that production UI does not construct itself.
/// Tests can provide local in-memory implementations without exposing
/// secret-storage types through the production UI surface.
public protocol PlainpostAppRuntimeDependencyProviding: Sendable {
    /// Produces the sole source-neutral mail authority for a Node account.
    /// Returning nil is reserved for local development fixtures; production
    /// Node accounts must not silently fall back to provider credentials.
    func makeMailAuthority(
        accountID: AccountID,
        access: PlainpostRuntimeAccountAccess
    ) throws -> (any PlainpostMailAuthority)?

    func makeDirectComposerSender(
        store: SQLiteMailStore
    ) throws -> any DirectComposerSending

    func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>
    ) -> LocalOperationRuntime

    func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>,
        selectedDirectAccountID: AccountID?,
        expectedDirectSourceGeneration: Int64?
    ) -> LocalOperationRuntime

    func makeAccountSetupHandler(
        store: SQLiteMailStore,
        inboxSyncOrchestrator: any AccountInboxSyncOrchestrating
    ) -> any AccountSetupHandling

    /// Optional native Google authorization for a Direct account. The
    /// default keeps fixture and Node runtimes independent of browser login.
    @MainActor func makeGoogleAuthorization() -> (@MainActor @Sendable (String) async throws -> GmailAuthorizationCode)?
    @MainActor func makeMicrosoftAuthorization() -> (@MainActor @Sendable (String) async throws -> MicrosoftAuthorizationCode)?

    func saveAccountCredentials(
        accountID: AccountID,
        imapPassword: String,
        smtpPassword: String
    ) async throws

    func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling
    ) -> any InboxMailActionHandling

    func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling,
        selectedAccountID: AccountID
    ) -> any InboxMailActionHandling

    func deleteLocalAccount(accountID: AccountID, store: SQLiteMailStore) async throws

    func recoverPendingLocalAccountDeletions(store: SQLiteMailStore) async throws

    /// The device's Sync Node mail, when it has a Sync Node: the device-wide runtime
    /// sends a Node account's changes, drafts and sends through it.
    var deviceNodeMail: (any DeviceNodeMailBridging)? { get }

    /// Whether this device holds the account's own provider sign-in.
    func hasProviderSignIn(accountID: AccountID, store: SQLiteMailStore) async -> Bool
}

public extension PlainpostAppRuntimeDependencyProviding {
    func hasProviderSignIn(accountID: AccountID, store: SQLiteMailStore) async -> Bool { false }

    func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling,
        selectedAccountID: AccountID
    ) -> any InboxMailActionHandling {
        AccountBoundInboxMailActionHandler(
            store: store, selectedAccountID: selectedAccountID,
            underlying: makeInboxMailActionHandler(store: store, mailboxFlagScheduler: mailboxFlagScheduler)
        )
    }
    @MainActor func makeGoogleAuthorization() -> (@MainActor @Sendable (String) async throws -> GmailAuthorizationCode)? {
        nil
    }
    @MainActor func makeMicrosoftAuthorization() -> (@MainActor @Sendable (String) async throws -> MicrosoftAuthorizationCode)? {
        nil
    }
    func makeMailAuthority(
        accountID: AccountID,
        access: PlainpostRuntimeAccountAccess
    ) throws -> (any PlainpostMailAuthority)? {
        nil
    }

    func deleteLocalAccount(accountID: AccountID, store: SQLiteMailStore) async throws {
        throw PlainpostError.permissionDenied("Local account deletion is unavailable for this runtime.")
    }

    func recoverPendingLocalAccountDeletions(store: SQLiteMailStore) async throws {}

    var deviceNodeMail: (any DeviceNodeMailBridging)? { nil }
}
