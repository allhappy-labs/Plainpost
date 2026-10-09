import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

/// The one place direct IMAP and SMTP access obtains credentials.
///
/// Password accounts read their vault passwords; OAuth accounts get a
/// short-lived access token from their provider-specific refresh owner.
/// Vault errors such as `CredentialVaultError.locked` pass through unchanged.
public struct MailCredentialResolver: Sendable {
    private let store: SQLiteMailStore
    private let credentials: any CredentialVault
    private let googleTokens: GoogleAccessTokenProvider
    private let microsoftTokens: MicrosoftAccessTokenProvider?

    public init(store: SQLiteMailStore, credentials: any CredentialVault, googleTokens: GoogleAccessTokenProvider,
                microsoftTokens: MicrosoftAccessTokenProvider? = nil) {
        self.store = store
        self.credentials = credentials
        self.googleTokens = googleTokens
        self.microsoftTokens = microsoftTokens
    }

    /// A resolver without configured OAuth clients. Password accounts behave
    /// as before; OAuth accounts fail closed without reading passwords.
    public static func withoutGoogleOAuth(store: SQLiteMailStore, credentials: any CredentialVault) -> MailCredentialResolver {
        MailCredentialResolver(
            store: store,
            credentials: credentials,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: credentials, tokens: nil)
        )
    }

    public func imapAuthentication(for account: Account) async throws -> MailAuthentication {
        try await resolve(account, passwordKey: MailCredentialKeys.imapPassword(account.id)).authentication
    }

    public func smtpAuthentication(for account: Account) async throws -> MailAuthentication {
        try await resolve(account, passwordKey: MailCredentialKeys.smtpPassword(account.id)).authentication
    }

    /// Runs `body`; on `.rejected` for OAuth invalidates, refreshes once and retries; never retries passwords.
    /// A refreshed token that is also rejected marks the account `reauthorization_required`, unless a newer
    /// grant was installed meanwhile, in which case `.rejected` is rethrown.
    public func withIMAPAuthentication<T: Sendable>(
        for account: Account,
        _ body: @Sendable (MailAuthentication) async throws -> T
    ) async throws -> T {
        let passwordKey = MailCredentialKeys.imapPassword(account.id)
        let first = try await resolve(account, passwordKey: passwordKey)
        return try await retryingRejectedToken(for: account, passwordKey: passwordKey, first: first.authentication, body)
    }

    /// An SMTP client for `account` that recovers from a refused OAuth access
    /// token. `send(authentication:)` first uses the credential it is given;
    /// when the server refuses that token (`MailAuthenticationError.rejected`,
    /// which SMTP reports only before `MAIL FROM`), it drops the token,
    /// refreshes once and sends again on a new connection from `makeClient`.
    /// A refreshed token that is also refused marks the account
    /// `reauthorization_required`. Any other failure, including every failure
    /// after `MAIL FROM`, is never retried, and passwords are never retried.
    public func tokenRefreshingSMTPClient(
        for account: Account,
        makeClient: @escaping @Sendable () -> any SMTPClientProtocol
    ) -> any SMTPClientProtocol {
        TokenRefreshingSMTPClient(resolver: self, account: account, makeClient: makeClient)
    }

    /// Installs a verified Google grant through the service's token provider:
    /// `apply` writes the refresh token and account state while refresh
    /// outcomes for the account are held back, and `accessToken` then replaces
    /// any cached token of the previous grant.
    public func installGoogleGrant(
        accessToken: String,
        expiresAt: Date,
        for accountID: AccountID,
        apply: @Sendable () async throws -> Void
    ) async throws {
        try await googleTokens.installGrant(accessToken: accessToken, expiresAt: expiresAt, accountID: accountID, apply: apply)
    }

    public func installMicrosoftGrant(
        accessToken: String, expiresAt: Date, for accountID: AccountID,
        apply: @Sendable () async throws -> Void
    ) async throws {
        guard let microsoftTokens else { throw MailCredentialError.oauthNotConfigured }
        try await microsoftTokens.installGrant(accessToken: accessToken, expiresAt: expiresAt,
                                               accountID: accountID, apply: apply)
    }

    /// Forgets the account's cached access token and outdates in-flight refreshes (account deletion).
    public func forgetAccessTokens(for accountID: AccountID) async {
        await googleTokens.forget(accountID: accountID)
        await microsoftTokens?.forget(accountID: accountID)
    }

    /// Forgets every cached access token and outdates in-flight refreshes (vault lockdown).
    public func forgetAllAccessTokens() async {
        await googleTokens.forgetAll()
        await microsoftTokens?.forgetAll()
    }

    func retryingRejectedToken<T: Sendable>(
        for account: Account,
        passwordKey: CredentialRecordKey,
        first: MailAuthentication,
        _ body: @Sendable (MailAuthentication) async throws -> T
    ) async throws -> T {
        do {
            return try await body(first)
        } catch MailAuthenticationError.rejected {
            guard case .xoauth2(let rejectedToken) = first else { throw MailAuthenticationError.rejected }
            switch try store.accountAuthentication(accountID: account.id).method {
            case .password: throw MailAuthenticationError.rejected
            case .googleOAuth: await googleTokens.invalidate(accountID: account.id, rejectedAccessToken: rejectedToken)
            case .microsoftOAuth: await microsoftTokens?.invalidate(accountID: account.id, rejectedAccessToken: rejectedToken)
            }
        }
        let refreshed = try await resolve(account, passwordKey: passwordKey)
        do {
            return try await body(refreshed.authentication)
        } catch MailAuthenticationError.rejected {
            guard let generation = refreshed.generation else { throw MailAuthenticationError.rejected }
            let marked: Bool
            guard try store.accountAuthentication(accountID: account.id).method == refreshed.method else {
                throw MailAuthenticationError.rejected
            }
            switch refreshed.method {
            case .password: marked = false
            case .googleOAuth:
                marked = try await googleTokens.markReauthorizationRequired(accountID: account.id, generation: generation)
            case .microsoftOAuth:
                marked = try await microsoftTokens?.markReauthorizationRequired(accountID: account.id, generation: generation) ?? false
            }
            guard marked else { throw MailAuthenticationError.rejected }
            throw MailCredentialError.reauthorizationRequired
        }
    }

    private struct Resolved: Sendable {
        let authentication: MailAuthentication
        let method: AccountAuthenticationMethod
        /// The selected provider grant generation; nil for passwords.
        let generation: UInt64?
    }

    private func resolve(_ account: Account, passwordKey: CredentialRecordKey) async throws -> Resolved {
        switch try store.accountAuthentication(accountID: account.id).method {
        case .password:
            guard let data = try await credentials.load(passwordKey) else {
                throw MailCredentialError.unavailable
            }
            guard let password = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.ciphertextInvalid
            }
            return Resolved(authentication: .password(password), method: .password, generation: nil)
        case .googleOAuth:
            try validateOAuthEndpoint(account, profile: .gmail)
            let lease = try await googleTokens.lease(for: account.id)
            return Resolved(authentication: .xoauth2(accessToken: lease.accessToken), method: .googleOAuth, generation: lease.generation)
        case .microsoftOAuth:
            try validateOAuthEndpoint(account, profile: .microsoft)
            guard let microsoftTokens else { throw MailCredentialError.oauthNotConfigured }
            let lease = try await microsoftTokens.lease(for: account.id)
            return Resolved(authentication: .xoauth2(accessToken: lease.accessToken), method: .microsoftOAuth, generation: lease.generation)
        }
    }

    /// OAuth bearer tokens are valid for a provider, not an arbitrary server
    /// chosen in account settings. Check both the requested and persisted
    /// transport profile before releasing a token to an IMAP or SMTP client.
    private func validateOAuthEndpoint(_ account: Account, profile: MailProviderProfile) throws {
        let allowedSMTPPorts = profile.kind == .gmail ? [465, 587] : [profile.smtpPort]
        guard let persisted = store.accounts.first(where: { $0.id == account.id }),
              persisted.email == account.email,
              persisted.username == account.username,
              persisted.imapHost == account.imapHost,
              persisted.imapPort == account.imapPort,
              persisted.smtpHost == account.smtpHost,
              persisted.smtpPort == account.smtpPort,
              profile.matches(account),
              account.imapPort == profile.imapPort,
              allowedSMTPPorts.contains(account.smtpPort),
              account.id == AccountID.stableAccountID(email: account.email),
              account.username.caseInsensitiveCompare(account.email.rawValue) == .orderedSame
        else {
            throw PlainpostError.validationFailed("OAuth account server or identity settings changed. Reconnect the provider before sending mail.")
        }
    }
}

private struct TokenRefreshingSMTPClient: SMTPClientProtocol {
    let resolver: MailCredentialResolver
    let account: Account
    let makeClient: @Sendable () -> any SMTPClientProtocol

    func send(username: String, password: String, from: EmailAddress, to recipients: [EmailAddress], data: String) async throws {
        try await makeClient().send(username: username, password: password, from: from, to: recipients, data: data)
    }

    func send(
        username: String,
        authentication: MailAuthentication,
        from: EmailAddress,
        to recipients: [EmailAddress],
        data: String
    ) async throws {
        try await resolver.retryingRejectedToken(
            for: account, passwordKey: MailCredentialKeys.smtpPassword(account.id), first: authentication
        ) { authentication in
            try await makeClient().send(
                username: username, authentication: authentication, from: from, to: recipients, data: data)
        }
    }
}
