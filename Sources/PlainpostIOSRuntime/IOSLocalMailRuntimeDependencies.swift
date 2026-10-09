import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostUI

/// Device-local dependencies for a Direct mail account. The same vault owns
/// setup, sync, sending and semantic account deletion.
public struct IOSLocalMailRuntimeDependencies: PlainpostAppRuntimeDependencyProviding {
    private let credentials: any CredentialVault
    private let googleClient: GoogleOAuthPublicClient?
    private let googleTokens: GoogleOAuthTokenClient?
    private let microsoftClient: MicrosoftOAuthPublicClient?
    private let microsoftTokens: MicrosoftMailOAuthProvider?
    private let googleResolvers: IOSGoogleCredentialResolvers
    private let imapClientFactory: @Sendable (String, UInt16) -> IMAPClientProtocol
    private let smtpClientFactory: @Sendable (String, Int) -> SMTPClientProtocol
    public let deviceNodeMail: (any DeviceNodeMailBridging)?

    public init(credentials: IOSDeviceCredentialVault, googleClient: GoogleOAuthPublicClient? = nil,
                microsoftClient: MicrosoftOAuthPublicClient? = nil,
                deviceNodeMail: (any DeviceNodeMailBridging)? = nil) {
        self.init(credentials: credentials as any CredentialVault, googleClient: googleClient,
                  microsoftClient: microsoftClient, deviceNodeMail: deviceNodeMail)
    }

    /// Allows the assembly contract to be exercised without a live Keychain
    /// or network transport.
    public init(
        credentials: any CredentialVault,
        googleClient: GoogleOAuthPublicClient? = nil,
        microsoftClient: MicrosoftOAuthPublicClient? = nil,
        googleHTTP: any GoogleOAuthHTTP = URLSessionGoogleOAuthHTTP(),
        microsoftHTTP: any MicrosoftOAuthHTTP = URLSessionMicrosoftOAuthHTTP(),
        imapClientFactory: @escaping @Sendable (String, UInt16) -> IMAPClientProtocol = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        },
        smtpClientFactory: @escaping @Sendable (String, Int) -> SMTPClientProtocol = {
            MailTransportClientFactory.smtpClient(host: $0, port: $1)
        },
        deviceNodeMail: (any DeviceNodeMailBridging)? = nil
    ) {
        self.deviceNodeMail = deviceNodeMail
        self.credentials = credentials
        self.googleClient = googleClient
        self.googleTokens = googleClient.map { GoogleOAuthTokenClient(client: $0, http: googleHTTP) }
        self.microsoftClient = microsoftClient
        self.microsoftTokens = microsoftClient.map { MicrosoftMailOAuthProvider(client: $0, http: microsoftHTTP) }
        self.googleResolvers = IOSGoogleCredentialResolvers()
        self.imapClientFactory = imapClientFactory
        self.smtpClientFactory = smtpClientFactory
    }

    public func makeMailAuthority(
        accountID: AccountID,
        access: PlainpostRuntimeAccountAccess
    ) throws -> (any PlainpostMailAuthority)? {
        nil
    }

    public func makeDirectComposerSender(store: SQLiteMailStore) throws -> any DirectComposerSending {
        IOSDirectComposerSender(
            store: store, credentials: credentials, credentialResolver: resolver(store: store),
            smtpClientFactory: smtpClientFactory)
    }

    public func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>
    ) -> LocalOperationRuntime {
        LocalOperationRuntime(
            store: store, credentials: credentials,
            allowedJobKinds: allowedJobKinds.subtracting([.approvedDelivery]),
            requireExplicitDirectSource: true,
            requireSelectedDirectClaimScope: true,
            inboxSyncClientFactory: imapClientFactory,
            credentialResolver: resolver(store: store)
        )
    }

    public func makeOperationRuntime(
        store: SQLiteMailStore,
        allowedJobKinds: Set<PlainpostOperationKind>,
        selectedDirectAccountID: AccountID?,
        expectedDirectSourceGeneration: Int64?
    ) -> LocalOperationRuntime {
        LocalOperationRuntime(
            store: store, credentials: credentials,
            allowedJobKinds: allowedJobKinds.subtracting([.approvedDelivery]),
            requireExplicitDirectSource: true,
            selectedDirectAccountID: selectedDirectAccountID,
            expectedDirectSourceGeneration: expectedDirectSourceGeneration,
            requireSelectedDirectClaimScope: true,
            inboxSyncClientFactory: imapClientFactory,
            credentialResolver: resolver(store: store)
        )
    }

    public func makeAccountSetupHandler(
        store: SQLiteMailStore,
        inboxSyncOrchestrator: any AccountInboxSyncOrchestrating
    ) -> any AccountSetupHandling {
        let service = AccountSetupService(
            store: store, credentials: credentials,
            inboxSyncOrchestrator: inboxSyncOrchestrator,
            imapClientFactory: imapClientFactory,
            smtpClientFactory: smtpClientFactory,
            googleOAuthTokens: googleTokens,
            microsoftOAuth: microsoftTokens,
            credentialResolver: resolver(store: store),
            publishDirectMailSource: true
        )
        return IOSDirectGoogleAccountSetupHandler(service: service, tokens: googleTokens)
    }

    @MainActor public func makeGoogleAuthorization() -> (@MainActor @Sendable (String) async throws -> GmailAuthorizationCode)? {
#if os(iOS)
        guard let googleClient else { return nil }
        return { loginHint in
            try await IOSMailOAuthSession().authorize(client: googleClient, loginHint: loginHint)
        }
#else
        return nil
#endif
    }

    @MainActor public func makeMicrosoftAuthorization() -> (@MainActor @Sendable (String) async throws -> MicrosoftAuthorizationCode)? {
#if os(iOS)
        guard let microsoftClient else { return nil }
        return { loginHint in
            try await IOSMailOAuthSession().authorize(client: microsoftClient, loginHint: loginHint)
        }
#else
        return nil
#endif
    }

    public func saveAccountCredentials(
        accountID: AccountID,
        imapPassword: String,
        smtpPassword: String
    ) async throws {
        let imapKey = MailCredentialKeys.imapPassword(accountID)
        let smtpKey = MailCredentialKeys.smtpPassword(accountID)
        let previousIMAP = try await credentials.load(imapKey)
        let previousSMTP = try await credentials.load(smtpKey)
        do {
            try await credentials.store(Data(imapPassword.utf8), for: imapKey)
            try await credentials.store(Data(smtpPassword.utf8), for: smtpKey)
        } catch {
            try await restore(previousIMAP, for: imapKey)
            try await restore(previousSMTP, for: smtpKey)
            throw error
        }
    }

    private func restore(_ value: Data?, for key: CredentialRecordKey) async throws {
        if let value {
            try await credentials.store(value, for: key)
        } else {
            try await credentials.remove(key)
        }
    }

    public func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling
    ) -> any InboxMailActionHandling {
        IOSDirectInboxActionHandler(
            store: store, mailboxFlagScheduler: mailboxFlagScheduler,
            credentials: credentials, credentialResolver: resolver(store: store),
            imapClientFactory: imapClientFactory
        )
    }

    public func makeInboxMailActionHandler(
        store: SQLiteMailStore,
        mailboxFlagScheduler: any MailboxFlagScheduling,
        selectedAccountID: AccountID
    ) -> any InboxMailActionHandling {
        AccountBoundInboxMailActionHandler(
            store: store, selectedAccountID: selectedAccountID,
            underlying: IOSDirectInboxActionHandler(
                store: store, mailboxFlagScheduler: mailboxFlagScheduler,
                credentials: credentials, credentialResolver: resolver(store: store),
                selectedAccountID: selectedAccountID,
                imapClientFactory: imapClientFactory
            )
        )
    }

    public func deleteLocalAccount(accountID: AccountID, store: SQLiteMailStore) async throws {
        let source = try store.mailSource(accountID: accountID)
        if source.kind == .nodeBacked {
            // Only this device's mirror goes; the account stays on the Sync Node.
            try await store.deleteNodeBackedAccountData(
                accountID: accountID, expectedSourceGeneration: source.generation, credentials: credentials
            )
            return
        }
        try store.requireDirectMailSource(accountID: accountID)
        let generation = try store.mailSource(accountID: accountID).generation
        try await store.deleteDirectAccountData(
            accountID: accountID, expectedSourceGeneration: generation,
            credentials: credentials
        )
    }

    public func recoverPendingLocalAccountDeletions(store: SQLiteMailStore) async throws {
        try await store.recoverPendingDirectAccountDeletions(credentials: credentials)
    }

    public func hasProviderSignIn(accountID: AccountID, store: SQLiteMailStore) async -> Bool {
        await MailProviderSignIn.isStored(accountID: accountID, store: store, credentials: credentials)
    }

    /// The phone's own provider route for a Sync Node account in fallback (the Direct
    /// action service and the journaled fallback send), and whether an account's provider
    /// sign-in is on the phone.
    public func makeDeviceDirectMail(store: SQLiteMailStore) -> IOSDeviceDirectMail {
        let actions = DirectMailboxActionService(
            store: store, credentials: resolver(store: store), requireExplicitDirectSource: true,
            imapClientFactory: imapClientFactory,
            // The device's operation worker claims the read-state job on its next pass.
            signalFlagWork: {}
        )
        let delivery = LocalDraftDeliveryService(
            store: store, credentials: credentials, credentialResolver: resolver(store: store),
            smtpClientFactory: smtpClientFactory
        )
        let credentials = credentials
        return IOSDeviceDirectMail(
            actions: actions, delivery: delivery,
            hasProviderSignIn: { accountID in
                await MailProviderSignIn.isStored(accountID: accountID, store: store, credentials: credentials)
            }
        )
    }

    private func resolver(store: SQLiteMailStore) -> MailCredentialResolver {
        googleResolvers.resolver(store: store, credentials: credentials, tokens: googleTokens,
                                 microsoftTokens: microsoftTokens)
    }
}

/// See `IOSLocalMailRuntimeDependencies.makeDeviceDirectMail(store:)`.
public struct IOSDeviceDirectMail: Sendable {
    public let actions: DirectMailboxActionService
    public let delivery: LocalDraftDeliveryService
    public let hasProviderSignIn: @Sendable (AccountID) async -> Bool
}
