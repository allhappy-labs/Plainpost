import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import PlainpostUI

/// Keeps the existing account setup service as the one publication path for
/// password and Gmail accounts. The code exchange occurs on this device and
/// the service independently validates the granted Gmail profile identity.
struct IOSDirectGoogleAccountSetupHandler: AccountSetupHandling {
    let service: AccountSetupService
    let tokens: GoogleOAuthTokenClient?

    func addAccount(
        _ request: AccountSetupRequest,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        try await service.addAccount(request, progress: progress)
    }

    func syncInbox(
        for account: Account,
        progress: @escaping @Sendable (IMAPSyncProgress) async -> Void
    ) async throws -> IMAPSyncResult {
        try await service.syncInbox(for: account, progress: progress)
    }

    func addGoogleAccount(
        displayName: String,
        email: EmailAddress,
        authorization: GmailAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        let (grant, identity) = try await verifiedGrant(authorization, email: email)
        // The iPhone's one-tap flow has no prefilled account fields. The
        // verified Gmail profile, rather than a typed address, owns identity.
        let resolvedEmail = EmailAddress(identity)
        let resolvedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountName = resolvedName.isEmpty ? Self.defaultDisplayName(for: identity) : resolvedName
        return try await service.addGoogleAccount(
            GoogleAccountSetupRequest(displayName: accountName, email: resolvedEmail, grant: grant),
            identity: identity, progress: progress)
    }

    func reauthorizeGoogleAccount(
        accountID: AccountID,
        email: EmailAddress,
        authorization: GmailAuthorizationCode
    ) async throws {
        let (grant, identity) = try await verifiedGrant(authorization, email: email)
        try await service.replaceGoogleCredential(accountID: accountID, grant: grant, identity: identity)
    }

    func discardAddedGoogleAccount(accountID: AccountID) async throws {
        try await service.deleteAccount(accountID: accountID)
    }

    func addMicrosoftAccount(
        displayName: String, email: EmailAddress, authorization: MicrosoftAuthorizationCode,
        progress: @escaping @Sendable (AccountSetupProgress) async -> Void
    ) async throws -> AccountSetupResult {
        try await service.addMicrosoftAccount(
            displayName: displayName, email: email, authorization: authorization, progress: progress)
    }

    func discardAddedMicrosoftAccount(accountID: AccountID) async throws {
        try await service.deleteAccount(accountID: accountID)
    }

    func reauthorizeMicrosoftAccount(
        accountID: AccountID, email: EmailAddress, authorization: MicrosoftAuthorizationCode
    ) async throws {
        try await service.replaceMicrosoftCredential(accountID: accountID, authorization: authorization)
    }

    private func verifiedGrant(
        _ authorization: GmailAuthorizationCode, email: EmailAddress
    ) async throws -> (GoogleTokenGrant, String) {
        guard let tokens else { throw GoogleOAuthError.notConfigured }
        let grant = try await tokens.exchange(authorization)
        let identity = try await tokens.verifiedIdentity(accessToken: grant.accessToken)
        let expected = email.rawValue.lowercased()
        guard expected.isEmpty || identity == expected else {
            throw GoogleAccountSetupError.signedInAsDifferentAccount(signedIn: identity, expected: expected)
        }
        return (grant, identity)
    }

    private static func defaultDisplayName(for identity: String) -> String {
        let localPart = identity.split(separator: "@", maxSplits: 1).first.map(String.init) ?? identity
        let readable = localPart.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((readable.isEmpty ? identity : readable).prefix(80))
    }
}

/// All local runtime components for a SQLiteMailStore share one Google token
/// actor. Each runtime assembly owns one registry; replacing a store releases
/// its old resolver when a test or launch assembly switches databases.
final class IOSGoogleCredentialResolvers: @unchecked Sendable {
    private struct Entry {
        let store: SQLiteMailStore
        let resolver: MailCredentialResolver
    }
    private let lock = NSLock()
    private var entry: Entry?

    func resolver(
        store: SQLiteMailStore,
        credentials: any CredentialVault,
        tokens: GoogleOAuthTokenClient?,
        microsoftTokens: MicrosoftMailOAuthProvider?
    ) -> MailCredentialResolver {
        lock.lock()
        defer { lock.unlock() }
        if let entry, entry.store === store { return entry.resolver }
        let resolver = MailCredentialResolver(
            store: store, credentials: credentials,
            googleTokens: GoogleAccessTokenProvider(store: store, credentials: credentials, tokens: tokens),
            microsoftTokens: MicrosoftAccessTokenProvider(store: store, credentials: credentials, tokens: microsoftTokens))
        entry = Entry(store: store, resolver: resolver)
        return resolver
    }
}
