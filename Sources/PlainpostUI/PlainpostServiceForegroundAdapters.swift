import Foundation
#if os(macOS)
import AppKit
#endif
import PlainpostAccountRuntime
import PlainpostAccounts
import PlainpostCore
import PlainpostLocalServer
import PlainpostOperations
import PlainpostServiceIPC

public final class PlainpostServiceAccountSetupAdapter: AccountSetupHandling, @unchecked Sendable {
    private let serviceClient: any PlainpostServiceClientProtocol
    private let operations: PlainpostServiceOperationAdapter
    private let googleOAuthTokens: GoogleOAuthTokenClient?

    /// `googleOAuthTokens` performs the app's transient Google setup work:
    /// the authorization-code exchange and the identity check. The resulting
    /// grant goes to the service; the app never stores or refreshes tokens.
    public init(
        serviceClient: any PlainpostServiceClientProtocol,
        googleOAuthTokens: GoogleOAuthTokenClient? = nil
    ) {
        self.serviceClient = serviceClient
        self.operations = PlainpostServiceOperationAdapter(serviceClient: serviceClient)
        self.googleOAuthTokens = googleOAuthTokens
    }

    public func addGoogleAccount(
        displayName: String,
        email: EmailAddress,
        authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let (grant, identity) = try await verifiedGrant(authorization, expectedEmail: email)
        await progress(.verifyingIMAP)
        await progress(.verifyingSMTP)
        await progress(.syncingInbox(.connecting))
        guard
            case .googleAccountAdd(let result) = try await serviceClient.perform(
                .googleAccountAdd(
                    PlainpostGoogleAccountSetupPayload(
                        displayName: displayName, email: email.rawValue, identity: identity,
                        accessToken: grant.accessToken, refreshToken: grant.refreshToken,
                        accessTokenExpiresAt: grant.expiresAt.timeIntervalSince1970)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: displayName, email: EmailAddress(result.email))
        await progress(
            .syncingInbox(
                .downloading(completed: result.syncedMessageCount, total: result.syncedMessageCount)))
        return AccountSetupResult(
            account: Account(
                id: AccountID(result.accountID), displayName: account.displayName, email: account.email,
                username: account.username, sentMailbox: account.sentMailbox, imapHost: account.imapHost,
                imapPort: account.imapPort, smtpHost: account.smtpHost, smtpPort: account.smtpPort),
            imapVerified: result.isIMAPVerified, smtpVerified: result.isSMTPVerified,
            syncedMessageCount: result.syncedMessageCount)
    }

    public func reauthorizeGoogleAccount(
        accountID: AccountID,
        email: EmailAddress,
        authorization: GmailAuthorizationCode
    ) async throws {
        let (grant, identity) = try await verifiedGrant(authorization, expectedEmail: email)
        guard
            case .replaceGoogleAccountCredential = try await serviceClient.perform(
                .replaceGoogleAccountCredential(
                    PlainpostGoogleCredentialReplacementPayload(
                        accountID: accountID.rawValue, identity: identity,
                        accessToken: grant.accessToken, refreshToken: grant.refreshToken,
                        accessTokenExpiresAt: grant.expiresAt.timeIntervalSince1970)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }

    /// Exchanges the code and refuses a grant for a different Google account
    /// before anything reaches the service, which checks again itself.
    private func verifiedGrant(
        _ authorization: GmailAuthorizationCode,
        expectedEmail: EmailAddress
    ) async throws -> (GoogleTokenGrant, String) {
        guard let googleOAuthTokens else { throw GoogleOAuthError.notConfigured }
        let grant = try await googleOAuthTokens.exchange(authorization)
        let identity = try await googleOAuthTokens.verifiedIdentity(accessToken: grant.accessToken)
        let expected = expectedEmail.rawValue.lowercased()
        guard identity == expected else {
            throw GoogleAccountSetupError.signedInAsDifferentAccount(signedIn: identity, expected: expected)
        }
        return (grant, identity)
    }

    public func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        await progress(.verifyingIMAP)
        await progress(.verifyingSMTP)
        await progress(.syncingInbox(.connecting))
        guard
            case .accountAdd(let result) = try await serviceClient.perform(
                .accountAdd(Self.payload(request)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
        let account = Account(
            id: AccountID(result.accountID), displayName: request.displayName,
            email: EmailAddress(result.email), username: request.username,
            sentMailbox: request.sentMailbox, imapHost: request.imapHost,
            imapPort: request.imapPort, smtpHost: request.smtpHost, smtpPort: request.smtpPort)
        await progress(
            .syncingInbox(
                .downloading(completed: result.syncedMessageCount, total: result.syncedMessageCount)
            ))
        return AccountSetupResult(
            account: account, imapVerified: result.isIMAPVerified,
            smtpVerified: result.isSMTPVerified, syncedMessageCount: result.syncedMessageCount)
    }

    public func testAccount(_ request: AccountSetupRequest) async throws
        -> PlainpostAccountTestSemanticResult
    {
        guard
            case .accountTest(let result) = try await serviceClient.perform(
                .accountTest(Self.payload(request)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
        return result
    }

    public func syncInbox(
        for account: Account, progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        await progress(.connecting)
        let result = try await operations.executeInboxSync(
            PlainpostInboxSyncInput(accountID: account.id, trigger: .manual, scope: .recent))
        await progress(
            .downloading(completed: result.syncedMessageCount, total: result.syncedMessageCount))
        return IMAPSyncResult(syncedMessageCount: result.syncedMessageCount)
    }

    private static func payload(_ request: AccountSetupRequest) -> PlainpostAccountSetupPayload {
        PlainpostAccountSetupPayload(
            displayName: request.displayName, email: request.email.rawValue,
            imapHost: request.imapHost, imapPort: request.imapPort, smtpHost: request.smtpHost,
            smtpPort: request.smtpPort, username: request.username,
            sentMailbox: request.sentMailbox, imapPassword: request.imapPassword,
            smtpPassword: request.smtpPassword)
    }
}

/// The app's Google sign-in for guided Gmail setup: the packaged Desktop
/// client, the browser-based loopback authorizer and the transient token
/// client used for the code exchange and identity check.
public struct PlainpostGoogleSignIn: Sendable {
    public let tokens: GoogleOAuthTokenClient
    public let authorize: @MainActor @Sendable (String) async throws -> GmailAuthorizationCode

    /// `nil` when this build carries no Google Desktop OAuth client.
    @MainActor
    public static func production(bundle: Bundle = .main) -> PlainpostGoogleSignIn? {
        #if os(macOS)
        guard let client = GoogleOAuthDesktopClient.resolve(from: bundle) else { return nil }
        let authorizer = GmailOAuthAuthorizer(clientID: client.clientID) { url in
            NSWorkspace.shared.open(url)
        }
        return PlainpostGoogleSignIn(
            tokens: GoogleOAuthTokenClient(client: client, http: URLSessionGoogleOAuthHTTP()),
            authorize: { loginHint in try await authorizer.authorize(loginHint: loginHint) }
        )
        #else
        return nil
        #endif
    }
}

public func plainpostServiceAccountCredentialSaver(
    serviceClient: any PlainpostServiceClientProtocol
) -> @Sendable (AccountID, String, String) async throws -> Void {
    { accountID, imapPassword, smtpPassword in
        guard
            case .replaceAccountCredentials = try await serviceClient.perform(
                .replaceAccountCredentials(
                    PlainpostAccountCredentialReplacementPayload(
                        accountID: accountID.rawValue, imapPassword: imapPassword,
                        smtpPassword: smtpPassword)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }
}

public func plainpostServiceAccountDeleter(
    serviceClient: any PlainpostServiceClientProtocol
) -> @Sendable (AccountID) async throws -> Void {
    { accountID in
        guard
            case .deleteAccount = try await serviceClient.perform(
                .deleteAccount(
                    PlainpostAccountDeletionPayload(
                        accountID: accountID.rawValue
                    )
                )
            )
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }
}

public final class PlainpostServiceDirectComposerSender: DirectComposerSending, @unchecked Sendable
{
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func send(draft: Draft) async throws -> DirectComposerSendResult {
        guard
            case .deliverDirectDraft(let result) = try await serviceClient.perform(
                .deliverDirectDraft(
                    PlainpostDirectDraftDeliveryPayload(
                        draftID: draft.id.rawValue, expectedHash: draft.contentHash,
                        actorID: draft.createdBy)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
        return DirectComposerSendResult(
            messageID: result.messageID, remoteSentCopyAppended: result.remoteSentCopyAppended,
            isQueuedForSyncNode: result.waitingForNode)
    }
}

public final class PlainpostServiceBrowserReplyDeliveryAdapter: BrowserReplyDelivering,
    @unchecked Sendable
{
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func send(draftID: String, expectedHash: String, idempotencyKey: String) async throws
        -> LocalAPIDeliveryResult
    {
        guard
            case .deliverBrowserReply(let result) = try await serviceClient.perform(
                .deliverBrowserReply(
                    PlainpostBrowserReplyDeliveryPayload(
                        draftID: draftID, expectedHash: expectedHash, idempotencyKey: idempotencyKey
                    ))), let state = LocalAPIDeliveryState(rawValue: result.state)
        else { throw PlainpostForegroundOperationError.unexpectedResult }
        // The browser extension knows sent, failed and deliveryUncertain.
        // A reply queued for the Sync Node is shown as "may have been sent"
        // (the extension locks the reply and never resends it) until the
        // extension learns the queued state.
        return LocalAPIDeliveryResult(
            requestID: result.requestID, jobID: result.jobID,
            state: state == .waitingForNode ? .deliveryUncertain : state)
    }
}

public final class PlainpostServiceInboxMailActionAdapter: InboxMailActionHandling,
    @unchecked Sendable
{
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID) async throws
        -> InboxMailActionResult
    {
        try await perform(action, messageID: messageID, shownIn: nil)
    }

    public func perform(_ action: InboxMailAction, messageID: MessageID, shownIn mailboxPath: String?) async throws
        -> InboxMailActionResult
    {
        let payload = PlainpostMailActionPayload(messageID: messageID.rawValue)
        let operation: PlainpostForegroundOperation
        switch action {
        case .archive:
            operation = .archive(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: mailboxPath))
        case .delete:
            operation = .delete(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: mailboxPath))
        case .deletePermanently:
            operation = .delete(PlainpostMailActionPayload(
                messageID: messageID.rawValue, permanent: true, sourceMailbox: mailboxPath
            ))
        case .markRead: operation = .markRead(payload)
        case .markUnread: operation = .markUnread(payload)
        case .flag: operation = .flag(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: mailboxPath))
        case .unflag: operation = .unflag(PlainpostMailActionPayload(messageID: messageID.rawValue, sourceMailbox: mailboxPath))
        case .move(let destination):
            operation = .move(PlainpostMailActionPayload(
                messageID: messageID.rawValue, archiveMailbox: destination, sourceMailbox: mailboxPath
            ))
        }
        let semantic: PlainpostForegroundOperationResult
        do {
            semantic = try await serviceClient.perform(operation)
        } catch PlainpostServiceClientError.mailActionRefused(let refusal) {
            // Shown to the user as the reason, like a refusal on iPhone.
            throw PlainpostError.validationFailed(refusal.message)
        }
        let result: PlainpostMailActionSemanticResult
        switch semantic {
        case .archive(let value), .delete(let value), .markRead(let value), .markUnread(let value),
            .flag(let value), .unflag(let value), .move(let value):
            result = value
        default: throw PlainpostForegroundOperationError.unexpectedResult
        }
        return InboxMailActionResult(
            messageID: MessageID(result.messageID), action: action, seen: result.seen,
            mailboxPath: result.mailboxPath, deleted: result.isDeleted, deleteOutcome: result.deleteOutcome)
    }
}

public final class PlainpostServiceMessageLabelMutationAdapter: @unchecked Sendable {
    private let serviceClient: any PlainpostServiceClientProtocol

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.serviceClient = serviceClient
    }

    public func add(labelID: String, messageID: MessageID) async throws {
        guard
            case .addLabel = try await serviceClient.perform(
                .addLabel(
                    PlainpostLabelMutationPayload(
                        labelID: labelID, messageID: messageID.rawValue, selected: true)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }

    public func remove(labelID: String, messageID: MessageID) async throws {
        guard
            case .removeLabel = try await serviceClient.perform(
                .removeLabel(
                    PlainpostLabelMutationPayload(
                        labelID: labelID, messageID: messageID.rawValue, selected: false)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }

    public func command(labelID: String, messageID: MessageID, selected: Bool) async throws {
        guard
            case .labelCommand = try await serviceClient.perform(
                .labelCommand(
                    PlainpostLabelMutationPayload(
                        labelID: labelID, messageID: messageID.rawValue, selected: selected)))
        else { throw PlainpostForegroundOperationError.unexpectedResult }
    }
}
