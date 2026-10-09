import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

public struct AccountSetupRequest: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let displayName: String
    public let email: EmailAddress
    public let imapHost: String
    public let imapPort: UInt16
    public let smtpHost: String
    public let smtpPort: Int
    public let username: String
    public let sentMailbox: String
    public let imapPassword: String
    public let smtpPassword: String

    public init(
        displayName: String,
        email: EmailAddress,
        imapHost: String,
        imapPort: UInt16,
        smtpHost: String,
        smtpPort: Int,
        username: String? = nil,
        sentMailbox: String? = nil,
        imapPassword: String,
        smtpPassword: String
    ) {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedSentMailbox = sentMailbox?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = displayName
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.username = trimmedUsername.isEmpty ? email.rawValue : trimmedUsername
        self.sentMailbox = trimmedSentMailbox.isEmpty ? "Sent" : trimmedSentMailbox
        self.imapPassword = imapPassword
        self.smtpPassword = smtpPassword
    }

    public var description: String {
        "AccountSetupRequest(email: \(email.rawValue), credentials: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "displayName": displayName,
                "email": email.rawValue,
                "imapHost": imapHost,
                "imapPort": imapPort,
                "smtpHost": smtpHost,
                "smtpPort": smtpPort,
                "username": username,
                "sentMailbox": sentMailbox,
                "credentials": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

public struct AccountSetupResult: Equatable, Sendable {
    public let account: Account
    public let imapVerified: Bool
    public let smtpVerified: Bool
    public let syncedMessageCount: Int

    public init(
        account: Account,
        imapVerified: Bool,
        smtpVerified: Bool,
        syncedMessageCount: Int = 0
    ) {
        self.account = account
        self.imapVerified = imapVerified
        self.smtpVerified = smtpVerified
        self.syncedMessageCount = syncedMessageCount
    }
}

public struct AccountConnectionTestResult: Equatable, Sendable {
    public let imapVerified: Bool
    public let smtpVerified: Bool

    public init(imapVerified: Bool, smtpVerified: Bool) {
        self.imapVerified = imapVerified
        self.smtpVerified = smtpVerified
    }
}

public enum AccountSetupProgress: Equatable, Sendable {
    case verifyingIMAP
    case verifyingSMTP
    case syncingInbox(IMAPSyncProgress)
}

public enum AccountInboxSyncReason: Equatable, Sendable {
    case accountSetup
    case manual
    case background
}

public protocol AccountInboxSyncOrchestrating: Sendable {
    func syncInbox(for account: Account, reason: AccountInboxSyncReason) async throws -> IMAPSyncResult
}

public typealias AccountSetupIMAPClientFactory = @Sendable (String, UInt16) -> IMAPClientProtocol
public typealias AccountSetupSMTPClientFactory = @Sendable (String, Int) -> SMTPClientProtocol

public final class AccountSetupService: @unchecked Sendable {
    private let store: SQLiteMailStore
    private let credentials: any CredentialVault
    private let inboxSyncOrchestrator: (any AccountInboxSyncOrchestrating)?
    private let imapClientFactory: AccountSetupIMAPClientFactory
    private let smtpClientFactory: AccountSetupSMTPClientFactory
    private let verificationCleanup: AccountVerificationCleanup
    let googleOAuthTokens: GoogleOAuthTokenClient?
    let microsoftOAuth: MicrosoftMailOAuthProvider?
    private let credentialResolver: MailCredentialResolver
    private let publishDirectMailSource: Bool

    /// `googleOAuthTokens` verifies Google grants during Gmail setup and
    /// reauthorization (Task 11). `credentialResolver` authenticates existing
    /// accounts; the service passes its single resolver, and other callers get
    /// one without Google OAuth, which fails Google accounts with
    /// `MailCredentialError.oauthNotConfigured`.
    public init(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        inboxSyncOrchestrator: (any AccountInboxSyncOrchestrating)? = nil,
        imapClientFactory: @escaping AccountSetupIMAPClientFactory = {
            MailTransportClientFactory.imapClient(host: $0, port: $1)
        },
        smtpClientFactory: @escaping AccountSetupSMTPClientFactory = {
            MailTransportClientFactory.smtpClient(host: $0, port: $1)
        },
        verificationCleanup: AccountVerificationCleanup = AccountVerificationCleanup(),
        googleOAuthTokens: GoogleOAuthTokenClient? = nil,
        microsoftOAuth: MicrosoftMailOAuthProvider? = nil,
        credentialResolver: MailCredentialResolver? = nil,
        publishDirectMailSource: Bool = false
    ) {
        self.store = store
        self.credentials = credentials
        self.inboxSyncOrchestrator = inboxSyncOrchestrator
        self.imapClientFactory = imapClientFactory
        self.smtpClientFactory = smtpClientFactory
        self.verificationCleanup = verificationCleanup
        self.googleOAuthTokens = googleOAuthTokens
        self.microsoftOAuth = microsoftOAuth
        self.publishDirectMailSource = publishDirectMailSource
        self.credentialResolver = credentialResolver
            ?? .withoutGoogleOAuth(store: store, credentials: credentials)
    }

    public func addAccount(_ request: AccountSetupRequest) async throws -> AccountSetupResult {
        try await addAccount(request, progress: { _ in })
    }

    public func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        await progress(.verifyingIMAP)
        let verificationSession = try await verifyIMAP(request)
        let verificationMessage = AccountVerificationMessage(accountEmail: request.email)
        do {
            await progress(.verifyingSMTP)
            try await verifySMTP(request, message: verificationMessage)
            await verificationCleanup.delete(
                message: verificationMessage,
                newerThan: verificationSession.baselineUID,
                using: verificationSession.client
            )
            await verificationSession.client.disconnect()
        } catch {
            await verificationSession.client.disconnect()
            throw error
        }

        try store.migrate()
        let account = Account(
            id: AccountID.stableAccountID(email: request.email),
            displayName: request.displayName,
            email: request.email,
            username: request.username,
            sentMailbox: request.sentMailbox,
            imapHost: request.imapHost,
            imapPort: request.imapPort,
            smtpHost: request.smtpHost,
            smtpPort: request.smtpPort
        )
        if publishDirectMailSource,
           store.accounts.contains(where: { $0.id == account.id }) {
            throw PlainpostError.validationFailed(
                "This account is already connected; sign in again from account settings."
            )
        }
        let imapKey = Self.imapPasswordKey(for: account.id)
        let smtpKey = Self.smtpPasswordKey(for: account.id)
        let refreshTokenKey = MailCredentialKeys.googleRefreshToken(account.id)
        let previousIMAP = try await credentials.load(imapKey)
        let previousSMTP = try await credentials.load(smtpKey)
        let previousRefreshToken = try await credentials.load(refreshTokenKey)
        do {
            try await credentials.store(Data(request.imapPassword.utf8), for: imapKey)
            try await credentials.store(Data(request.smtpPassword.utf8), for: smtpKey)
            if publishDirectMailSource {
                // A fresh direct account is a password account by default.
                // Clear any stale Google grant before publishing its metadata:
                // after cacheVerifiedAccountSetup commits, the account and
                // Direct source must be ready for the first sync together.
                if previousRefreshToken != nil {
                    try await credentials.remove(refreshTokenKey)
                }
            }
            try cacheVerifiedAccountSetup(
                account: account,
                inbox: Mailbox(
                    id: MailboxID("mbx_\(account.id.rawValue)_inbox"),
                    accountID: account.id,
                    name: "INBOX",
                    path: "INBOX",
                    specialUse: "\\Inbox"
                )
            )
            if !publishDirectMailSource {
                // Preserve the existing Mac account replacement path.
                try store.setAccountAuthentication(accountID: account.id, method: .password, state: .ready)
                if previousRefreshToken != nil {
                    try await credentials.remove(refreshTokenKey)
                }
            }
        } catch {
            try await restore(previousIMAP, for: imapKey)
            try await restore(previousSMTP, for: smtpKey)
            try await restore(previousRefreshToken, for: refreshTokenKey)
            throw error
        }

        let syncResult: IMAPSyncResult
        do {
            syncResult = try await syncInbox(for: account, reason: .accountSetup) { syncProgress in
                await progress(.syncingInbox(syncProgress))
            }
        } catch {
            if publishDirectMailSource {
                // A new iOS account is not connected until its first inbox
                // pass succeeds. This also removes credentials and any
                // partially cached rows from an interrupted first sync.
                try await store.deleteAccountData(accountID: account.id, credentials: credentials)
            }
            throw error
        }

        return AccountSetupResult(
            account: account,
            imapVerified: true,
            smtpVerified: true,
            syncedMessageCount: syncResult.syncedMessageCount
        )
    }

    public func testAccount(_ request: AccountSetupRequest) async throws
        -> AccountConnectionTestResult
    {
        let verificationSession = try await verifyIMAP(request)
        let verificationMessage = AccountVerificationMessage(accountEmail: request.email)
        do {
            try await verifySMTP(request, message: verificationMessage)
            await verificationCleanup.delete(
                message: verificationMessage, newerThan: verificationSession.baselineUID,
                using: verificationSession.client)
            await verificationSession.client.disconnect()
        } catch {
            await verificationSession.client.disconnect()
            throw error
        }
        return AccountConnectionTestResult(imapVerified: true, smtpVerified: true)
    }

    public func replaceCredentials(accountID: AccountID, imapPassword: String, smtpPassword: String)
        async throws
    {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        guard try store.accountAuthentication(accountID: accountID).method == .password else {
            throw PlainpostError.validationFailed(
                "This account signs in with Google. Use Sign in again instead of a password."
            )
        }
        let replacement: (imap: String, smtp: String)
        if MailProviderProfile.gmail.matches(account) {
            let imap = MailProviderProfile.gmail.normalizedAppPassword(imapPassword)
            let smtp = MailProviderProfile.gmail.normalizedAppPassword(smtpPassword)
            guard imap.count == 16, smtp.count == 16, imap == smtp else {
                throw PlainpostError.validationFailed(
                    "Enter the same 16-character Google App Password for incoming and outgoing mail."
                )
            }
            replacement = (imap, imap)
        } else if MailProviderProfile.icloud.matches(account) {
            let imap = MailProviderProfile.icloud.normalizedAppPassword(imapPassword)
            let smtp = MailProviderProfile.icloud.normalizedAppPassword(smtpPassword)
            guard !imap.isEmpty, imap == smtp else {
                throw PlainpostError.validationFailed(
                    "Enter the same Apple app-specific password for incoming and outgoing mail."
                )
            }
            replacement = (imap, imap)
        } else {
            replacement = (imapPassword, smtpPassword)
        }
        let imapKey = Self.imapPasswordKey(for: accountID)
        let smtpKey = Self.smtpPasswordKey(for: accountID)
        let previousIMAP = try await credentials.load(imapKey)
        let previousSMTP = try await credentials.load(smtpKey)
        do {
            try await credentials.store(Data(replacement.imap.utf8), for: imapKey)
            try await credentials.store(Data(replacement.smtp.utf8), for: smtpKey)
        } catch {
            try await restore(previousIMAP, for: imapKey)
            try await restore(previousSMTP, for: smtpKey)
            throw error
        }
        // A password account asked to sign in again (its saved sign-in was
        // set aside by "Start Over with Saved Sign-ins") is ready once more.
        if try store.accountAuthentication(accountID: accountID).state == .reauthorizationRequired {
            try store.setAccountAuthentication(accountID: accountID, method: .password, state: .ready)
        }
    }

    public func deleteAccount(accountID: AccountID) async throws {
        // Outdate in-flight refreshes first so none of them caches an access
        // token for the account. A refresh that already reached Google may
        // still persist its rotated refresh token after this and before the
        // deletion runs; that write is harmless because the deletion removes
        // the refresh-token record unconditionally. Forget again afterwards to
        // drop any token cached meanwhile.
        await credentialResolver.forgetAccessTokens(for: accountID)
        do {
            try await store.deleteAccountData(
                accountID: accountID,
                credentials: credentials
            )
        } catch {
            await credentialResolver.forgetAccessTokens(for: accountID)
            throw error
        }
        await credentialResolver.forgetAccessTokens(for: accountID)
    }

    public func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void = { _ in }
    ) async throws -> IMAPSyncResult {
        try await syncInbox(for: account, reason: .manual, progress: progress)
    }

    private func syncInbox(
        for account: Account,
        reason: AccountInboxSyncReason,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        if publishDirectMailSource {
            try store.requireDirectSyncSource(accountID: account.id)
        } else if try skipsDirectSync(account) {
            return IMAPSyncResult(syncedMessageCount: 0)
        }
        if let inboxSyncOrchestrator {
            await progress(.connecting)
            let result = try await inboxSyncOrchestrator.syncInbox(for: account, reason: reason)
            await progress(.downloading(
                completed: result.syncedMessageCount,
                total: result.syncedMessageCount
            ))
            return result
        }

        do {
            return try await credentialResolver.withIMAPAuthentication(for: account) { authentication in
                let client = self.imapClientFactory(account.imapHost, account.imapPort)
                let sync = IMAPSyncService(client: client, cache: self.store)
                return try await sync.syncInbox(
                    credentials: IMAPAccountCredentials(
                        accountID: account.id,
                        email: account.email,
                        username: account.username,
                        authentication: authentication
                    ),
                    progress: progress
                )
            }
        } catch MailCredentialError.unavailable {
            throw PlainpostError.validationFailed("IMAP credentials are not available.")
        }
    }

    /// Re-adding (or re-verifying) an account the Sync Node already handles
    /// must not start a direct initial sync: its mail comes from the Node
    /// mirror. A source read error propagates so setup fails and can be
    /// retried, rather than syncing a Node-mode account directly.
    func skipsDirectSync(_ account: Account) throws -> Bool {
        !(try store.mailSource(accountID: account.id).runsDirectSync)
    }

    private func restore(_ value: Data?, for key: CredentialRecordKey) async throws {
        if let value {
            try await credentials.store(value, for: key)
        } else {
            try await credentials.remove(key)
        }
    }

    private static func imapPasswordKey(for accountID: AccountID) -> CredentialRecordKey {
        MailCredentialKeys.imapPassword(accountID)
    }

    private static func smtpPasswordKey(for accountID: AccountID) -> CredentialRecordKey {
        MailCredentialKeys.smtpPassword(accountID)
    }

    private func verifyIMAP(_ request: AccountSetupRequest) async throws -> VerifiedIMAPSession {
        let client = imapClientFactory(request.imapHost, request.imapPort)
        try await client.login(username: request.username, password: request.imapPassword)
        _ = try await client.listMailboxes()
        _ = try await client.selectMailbox("INBOX")
        let baselineUID = try await client.allMessageUIDs().max()
        return VerifiedIMAPSession(client: client, baselineUID: baselineUID)
    }

    private func verifySMTP(
        _ request: AccountSetupRequest,
        message: AccountVerificationMessage
    ) async throws {
        let client = smtpClientFactory(request.smtpHost, request.smtpPort)
        try await client.send(
            username: request.username,
            password: request.smtpPassword,
            from: request.email,
            to: [request.email],
            data: message.smtpData
        )
    }

    private func cacheVerifiedAccountSetup(
        account: Account, inbox: Mailbox,
        authentication: AccountAuthenticationMethod? = nil
    ) throws {
        guard publishDirectMailSource else {
            try store.cacheAccountSetup(account: account, inbox: inbox)
            return
        }
        guard !store.accounts.contains(where: { $0.id == account.id }) else {
            throw PlainpostError.validationFailed("This account is already connected; sign in again from account settings.")
        }
        let direct = try AccountMailSource(
            accountID: account.id, kind: .direct, mode: nil, nodeID: nil,
            logicalMailboxID: nil, providerIdentity: nil, generation: 1
        )
        if let authentication {
            try store.cacheOAuthAccountSetup(
                account: account, inbox: inbox, source: direct, authentication: authentication)
        } else {
            try store.cacheAccountSetup(account: account, inbox: inbox, source: direct)
        }
    }
}

private struct VerifiedIMAPSession {
    let client: IMAPClientProtocol
    let baselineUID: Int?
}

extension AccountID {
    public static func stableAccountID(email: EmailAddress) -> AccountID {
        let normalized = email.rawValue
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        return AccountID("acc_\(String(normalized))")
    }
}

// MARK: - Google sign-in (Gmail)

/// A Gmail account setup after Google sign-in. Only the grant crosses from the
/// app; the code and PKCE verifier never do.
public struct GoogleAccountSetupRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let displayName: String
    public let email: EmailAddress
    public let grant: GoogleTokenGrant

    public init(displayName: String, email: EmailAddress, grant: GoogleTokenGrant) {
        self.displayName = displayName
        self.email = email
        self.grant = grant
    }

    public var description: String {
        "GoogleAccountSetupRequest(email: \(email.rawValue), grant: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["displayName": displayName, "email": email.rawValue, "grant": "<redacted>"],
               displayStyle: .struct)
    }
}

public enum GoogleAccountSetupError: Error, Equatable, Sendable {
    /// The Google identity the service verified is not the account address.
    case identityMismatch(expected: String)
    case notGmailAccount
    /// The app's pre-check: Google signed in `signedIn`, but setup is for `expected`.
    case signedInAsDifferentAccount(signedIn: String, expected: String)
    /// Direct setup was interrupted after publication and account cleanup
    /// could not be confirmed. The UI must reload durable accounts.
    case cleanupFailed(accountID: AccountID)
}

public extension AccountSetupService {
    /// `identity` is the app's expected value (what the app verified after exchange). The service itself calls
    /// `googleOAuthTokens.verifiedIdentity(accessToken: request.grant.accessToken)`; a result different from `identity` or from
    /// `request.email` throws `identityMismatch`, and `googleOAuthTokens == nil` throws `GoogleOAuthError.notConfigured`.
    /// Then verifies IMAP and SMTP with XOAUTH2 (SMTP verification message as today), stores the refresh token, writes the
    /// Gmail Account (MailProviderProfile.gmail hosts) and account_authentication(google_oauth, ready).
    func addGoogleAccount(
        _ request: GoogleAccountSetupRequest,
        identity: String,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let account = MailProviderProfile.gmail.makeGoogleAccount(
            displayName: request.displayName, email: request.email)
        if publishDirectMailSource, store.accounts.contains(where: { $0.id == account.id }) {
            throw PlainpostError.validationFailed(
                "This account is already connected; sign in again from account settings.")
        }
        try await verifyGoogleIdentity(grant: request.grant, claimed: identity, expected: account.email.rawValue)
        try Task.checkCancellation()
        let authentication = MailAuthentication.xoauth2(accessToken: request.grant.accessToken)

        await progress(.verifyingIMAP)
        let verificationSession = try await verifyIMAP(account: account, authentication: authentication)
        let verificationMessage = AccountVerificationMessage(accountEmail: account.email)
        do {
            await progress(.verifyingSMTP)
            try await smtpClientFactory(account.smtpHost, account.smtpPort).send(
                username: account.username,
                authentication: authentication,
                from: account.email,
                to: [account.email],
                data: verificationMessage.smtpData
            )
            await verificationCleanup.delete(
                message: verificationMessage,
                newerThan: verificationSession.baselineUID,
                using: verificationSession.client
            )
            await verificationSession.client.disconnect()
        } catch {
            await verificationSession.client.disconnect()
            throw error
        }

        try Task.checkCancellation()
        try store.migrate()
        let publication = AccountSetupPublicationMarker()
        let syncResult: IMAPSyncResult
        do {
            try await installGoogleGrant(request.grant, for: account.id) {
                try self.cacheVerifiedAccountSetup(
                    account: account,
                    inbox: Mailbox(
                        id: MailboxID("mbx_\(account.id.rawValue)_inbox"),
                        accountID: account.id,
                        name: "INBOX",
                        path: "INBOX",
                        specialUse: "\\Inbox"
                    ),
                    authentication: self.publishDirectMailSource ? .googleOAuth : nil
                )
                publication.markPublished()
            }
            try Task.checkCancellation()

            if !publishDirectMailSource, try skipsDirectSync(account) {
                syncResult = IMAPSyncResult(syncedMessageCount: 0)
            } else if let inboxSyncOrchestrator {
                await progress(.syncingInbox(.connecting))
                syncResult = try await inboxSyncOrchestrator.syncInbox(for: account, reason: .accountSetup)
            } else {
                // The setup grant's fresh access token also performs the first sync.
                let client = imapClientFactory(account.imapHost, account.imapPort)
                do {
                    syncResult = try await IMAPSyncService(client: client, cache: store).syncInbox(
                        credentials: IMAPAccountCredentials(
                            accountID: account.id, email: account.email, username: account.username,
                            authentication: authentication),
                        progress: { syncProgress in await progress(.syncingInbox(syncProgress)) }
                    )
                    await client.disconnect()
                } catch {
                    await client.disconnect()
                    throw error
                }
            }
            try Task.checkCancellation()
        } catch {
            if publishDirectMailSource, publication.isPublished {
                do {
                    // Cancellation must not cancel the compensating deletion.
                    // Keep it awaited so callers cannot observe a half-published account.
                    try await Task.detached {
                        [store = self.store, credentials = self.credentials,
                         credentialResolver = self.credentialResolver, accountID = account.id] in
                        await credentialResolver.forgetAccessTokens(for: accountID)
                        try await store.deleteAccountData(accountID: accountID, credentials: credentials)
                    }.value
                } catch {
                    throw GoogleAccountSetupError.cleanupFailed(accountID: account.id)
                }
            }
            throw error
        }
        return AccountSetupResult(
            account: account, imapVerified: true, smtpVerified: true,
            syncedMessageCount: syncResult.syncedMessageCount)
    }

    /// Reauthorize: the service verifies the grant's identity itself (as above); it must equal `identity` and the account
    /// address. Replaces the refresh token, sets state ready, converts a Gmail App Password account to google_oauth and
    /// removes its password records.
    func replaceGoogleCredential(accountID: AccountID, grant: GoogleTokenGrant, identity: String) async throws {
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        guard MailProviderProfile.gmail.matches(account) else {
            throw GoogleAccountSetupError.notGmailAccount
        }
        // A Sync Node account signs in on this device as the mailbox its Node serves.
        if let source = try? store.explicitMailSource(accountID: account.id), source.kind == .nodeBacked,
           source.providerIdentity?.lowercased() != account.email.rawValue.lowercased() {
            throw GoogleAccountSetupError.identityMismatch(expected: source.providerIdentity?.lowercased() ?? "")
        }
        try await verifyGoogleIdentity(grant: grant, claimed: identity, expected: account.email.rawValue.lowercased())
        // Prove the new grant opens Gmail before any stored credential changes.
        let client = imapClientFactory(account.imapHost, account.imapPort)
        do {
            try await client.authenticate(
                username: account.username, authentication: .xoauth2(accessToken: grant.accessToken))
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
        try await installGoogleGrant(grant, for: account.id) {}
    }
}

private final class AccountSetupPublicationMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var published = false

    var isPublished: Bool { lock.withLock { published } }
    func markPublished() { lock.withLock { published = true } }
}

extension AccountSetupService {
    private func verifyGoogleIdentity(grant: GoogleTokenGrant, claimed: String, expected: String) async throws {
        guard let googleOAuthTokens else { throw GoogleOAuthError.notConfigured }
        let expected = expected.lowercased()
        let verified = try await googleOAuthTokens.verifiedIdentity(accessToken: grant.accessToken)
        guard verified == expected, claimed.lowercased() == expected else {
            throw GoogleAccountSetupError.identityMismatch(expected: expected)
        }
    }

    /// Stores the refresh token, marks the account `google_oauth`/`ready`
    /// and erases any App Password records (Amendment 9). Every stored
    /// credential is restored if a step fails.
    private func installGoogleGrant(
        _ grant: GoogleTokenGrant,
        for accountID: AccountID,
        writeAccount: @escaping @Sendable () throws -> Void
    ) async throws {
        let refreshKey = MailCredentialKeys.googleRefreshToken(accountID)
        let imapKey = MailCredentialKeys.imapPassword(accountID)
        let smtpKey = MailCredentialKeys.smtpPassword(accountID)
        let credentials = self.credentials
        let store = self.store
        try await credentialResolver.installGoogleGrant(
            accessToken: grant.accessToken, expiresAt: grant.expiresAt, for: accountID
        ) { [self] in
            let previousRefresh = try await credentials.load(refreshKey)
            let previousIMAP = try await credentials.load(imapKey)
            let previousSMTP = try await credentials.load(smtpKey)
            let previousAuthentication = store.accounts.contains(where: { $0.id == accountID })
                ? try store.accountAuthentication(accountID: accountID)
                : nil
            do {
                try await credentials.store(Data(grant.refreshToken.utf8), for: refreshKey)
                try writeAccount()
                try store.setAccountAuthentication(accountID: accountID, method: .googleOAuth, state: .ready)
                if previousIMAP != nil { try await credentials.remove(imapKey) }
                if previousSMTP != nil { try await credentials.remove(smtpKey) }
            } catch {
                try await restore(previousRefresh, for: refreshKey)
                try await restore(previousIMAP, for: imapKey)
                try await restore(previousSMTP, for: smtpKey)
                if let previousAuthentication, store.accounts.contains(where: { $0.id == accountID }) {
                    try? store.setAccountAuthentication(
                        accountID: accountID, method: previousAuthentication.method, state: previousAuthentication.state)
                }
                throw error
            }
        }
    }

    private func verifyIMAP(account: Account, authentication: MailAuthentication) async throws -> VerifiedIMAPSession {
        let client = imapClientFactory(account.imapHost, account.imapPort)
        do {
            try await client.authenticate(username: account.username, authentication: authentication)
            _ = try await client.listMailboxes()
            _ = try await client.selectMailbox("INBOX")
            let baselineUID = try await client.allMessageUIDs().max()
            return VerifiedIMAPSession(client: client, baselineUID: baselineUID)
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

public enum MicrosoftAccountSetupError: Error, Equatable, Sendable {
    case notConfigured
    case incompatibleMailbox(service: String)
    case cleanupFailed(accountID: AccountID)
}

extension MicrosoftAccountSetupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Microsoft mail sign-in is not configured in this app."
        case .incompatibleMailbox(let service):
            "Exchange refused \(service) sign-in. Check that IMAP and Authenticated SMTP are enabled for this mailbox, then try again."
        case .cleanupFailed:
            "Account setup stopped, but local cleanup could not finish. Reopen account settings to review the connected account."
        }
    }
}

public extension AccountSetupService {
    /// Graph proves the address, then both Exchange protocols must accept the
    /// opaque Exchange token before the account and credential are published.
    func addMicrosoftAccount(
        displayName: String, email: EmailAddress, authorization: MicrosoftAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        guard publishDirectMailSource else { throw MicrosoftAccountSetupError.notConfigured }
        guard let microsoftOAuth else { throw MicrosoftAccountSetupError.notConfigured }
        let account = MailProviderProfile.microsoft.makeOAuthAccount(displayName: displayName, email: email)
        guard !store.accounts.contains(where: { $0.id == account.id }) else {
            throw PlainpostError.validationFailed("This account is already connected; sign in again from account settings.")
        }
        let grant = try await microsoftOAuth.exchangeAndVerify(authorization, expectedEmail: account.email.rawValue)
        try Task.checkCancellation()
        let authentication = MailAuthentication.xoauth2(accessToken: grant.exchangeAccessToken)

        await progress(.verifyingIMAP)
        let session: VerifiedIMAPSession
        do {
            session = try await verifyIMAP(account: account, authentication: authentication)
        } catch MailAuthenticationError.mechanismUnavailable {
            throw MicrosoftAccountSetupError.incompatibleMailbox(service: "IMAP")
        } catch MailAuthenticationError.rejected {
            throw MicrosoftAccountSetupError.incompatibleMailbox(service: "IMAP")
        }
        let message = AccountVerificationMessage(accountEmail: account.email)
        do {
            await progress(.verifyingSMTP)
            do {
                try await smtpClientFactory(account.smtpHost, account.smtpPort).send(
                    username: account.username, authentication: authentication,
                    from: account.email, to: [account.email], data: message.smtpData)
            } catch MailAuthenticationError.mechanismUnavailable {
                throw MicrosoftAccountSetupError.incompatibleMailbox(service: "SMTP AUTH")
            } catch MailAuthenticationError.rejected {
                throw MicrosoftAccountSetupError.incompatibleMailbox(service: "SMTP AUTH")
            }
            await verificationCleanup.delete(message: message, newerThan: session.baselineUID, using: session.client)
            await session.client.disconnect()
        } catch {
            await session.client.disconnect()
            throw error
        }

        try Task.checkCancellation()
        try store.migrate()
        let publication = AccountSetupPublicationMarker()
        let syncResult: IMAPSyncResult
        do {
            try await installMicrosoftGrant(grant, for: account.id) {
                try self.cacheVerifiedAccountSetup(
                    account: account,
                    inbox: Mailbox(id: MailboxID("mbx_\(account.id.rawValue)_inbox"),
                                   accountID: account.id, name: "INBOX", path: "INBOX", specialUse: "\\Inbox"),
                    authentication: .microsoftOAuth)
                publication.markPublished()
            }
            try Task.checkCancellation()
            if let inboxSyncOrchestrator {
                await progress(.syncingInbox(.connecting))
                syncResult = try await inboxSyncOrchestrator.syncInbox(for: account, reason: .accountSetup)
            } else {
                let client = imapClientFactory(account.imapHost, account.imapPort)
                do {
                    syncResult = try await IMAPSyncService(client: client, cache: store).syncInbox(
                        credentials: IMAPAccountCredentials(accountID: account.id, email: account.email,
                            username: account.username, authentication: authentication),
                        progress: { await progress(.syncingInbox($0)) })
                    await client.disconnect()
                } catch {
                    await client.disconnect()
                    throw error
                }
            }
            try Task.checkCancellation()
        } catch {
            if publication.isPublished {
                await credentialResolver.forgetAccessTokens(for: account.id)
                do { try await store.deleteAccountData(accountID: account.id, credentials: credentials) }
                catch { throw MicrosoftAccountSetupError.cleanupFailed(accountID: account.id) }
            }
            throw error
        }
        return AccountSetupResult(account: account, imapVerified: true, smtpVerified: true,
                                  syncedMessageCount: syncResult.syncedMessageCount)
    }

    /// Replaces a revoked Microsoft grant only after the same mailbox proves
    /// its identity and both Exchange mail protocols accept the new token.
    func replaceMicrosoftCredential(
        accountID: AccountID, authorization: MicrosoftAuthorizationCode
    ) async throws {
        guard let microsoftOAuth else { throw MicrosoftAccountSetupError.notConfigured }
        guard let account = store.accounts.first(where: { $0.id == accountID }) else {
            throw PlainpostError.notFound("Account not found.")
        }
        guard MailProviderProfile.microsoft.matches(account),
              try store.accountAuthentication(accountID: accountID).method == .microsoftOAuth,
              try store.explicitMailSource(accountID: accountID)?.kind == .direct
        else {
            throw PlainpostError.validationFailed("This account does not use Microsoft sign-in.")
        }
        let grant = try await microsoftOAuth.exchangeAndVerify(
            authorization, expectedEmail: account.email.rawValue)
        try Task.checkCancellation()
        let authentication = MailAuthentication.xoauth2(accessToken: grant.exchangeAccessToken)
        let session: VerifiedIMAPSession
        do {
            session = try await verifyIMAP(account: account, authentication: authentication)
        } catch MailAuthenticationError.mechanismUnavailable, MailAuthenticationError.rejected {
            throw MicrosoftAccountSetupError.incompatibleMailbox(service: "IMAP")
        }
        let message = AccountVerificationMessage(accountEmail: account.email)
        do {
            do {
                try await smtpClientFactory(account.smtpHost, account.smtpPort).send(
                    username: account.username, authentication: authentication,
                    from: account.email, to: [account.email], data: message.smtpData)
            } catch MailAuthenticationError.mechanismUnavailable, MailAuthenticationError.rejected {
                throw MicrosoftAccountSetupError.incompatibleMailbox(service: "SMTP AUTH")
            }
            await verificationCleanup.delete(message: message, newerThan: session.baselineUID, using: session.client)
            await session.client.disconnect()
        } catch {
            await session.client.disconnect()
            throw error
        }
        try Task.checkCancellation()
        try await installMicrosoftGrant(grant, for: accountID) {
            guard self.store.accounts.first(where: { $0.id == accountID }) == account,
                  try self.store.accountAuthentication(accountID: accountID).method == .microsoftOAuth,
                  try self.store.explicitMailSource(accountID: accountID)?.kind == .direct
            else {
                throw PlainpostError.validationFailed("The Microsoft account changed during sign-in. Try again.")
            }
            try self.store.setAccountAuthentication(accountID: accountID,
                                                    method: .microsoftOAuth, state: .ready)
        }
    }
}

extension AccountSetupService {
    private func installMicrosoftGrant(
        _ grant: MicrosoftMailGrant, for accountID: AccountID,
        writeAccount: @escaping @Sendable () throws -> Void
    ) async throws {
        let refreshKey = MailCredentialKeys.microsoftRefreshToken(accountID)
        try await credentialResolver.installMicrosoftGrant(
            accessToken: grant.exchangeAccessToken, expiresAt: grant.expiresAt, for: accountID
        ) {
            let previousRefresh = try await self.credentials.load(refreshKey)
            do {
                try await self.credentials.store(Data(grant.refreshToken.utf8), for: refreshKey)
                try writeAccount()
            } catch {
                try await self.restore(previousRefresh, for: refreshKey)
                throw error
            }
        }
    }
}
