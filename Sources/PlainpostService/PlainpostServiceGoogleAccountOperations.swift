import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostServiceIPC

/// Handlers for the Google sign-in foreground operations. The grant arrives
/// from the app over the validated XPC connection; the service re-verifies
/// the Google identity itself and is the only writer of the refresh token.
extension PlainpostServiceOperations {
    static func performGoogleAccountAdd(
        _ input: PlainpostGoogleAccountSetupPayload,
        runtime: AccountSetupService
    ) async throws -> PlainpostForegroundOperationResult {
        let request = GoogleAccountSetupRequest(
            displayName: input.displayName,
            email: EmailAddress(input.email),
            grant: GoogleTokenGrant(
                accessToken: input.accessToken,
                refreshToken: input.refreshToken,
                expiresAt: Date(timeIntervalSince1970: input.accessTokenExpiresAt)
            )
        )
        let result = try await runtime.addGoogleAccount(
            request, identity: input.identity, progress: { _ in })
        return .googleAccountAdd(
            PlainpostAccountSetupSemanticResult(
                accountID: result.account.id.rawValue, email: result.account.email.rawValue,
                isIMAPVerified: result.imapVerified, isSMTPVerified: result.smtpVerified,
                syncedMessageCount: result.syncedMessageCount))
    }

    static func performReplaceGoogleAccountCredential(
        _ input: PlainpostGoogleCredentialReplacementPayload,
        runtime: AccountSetupService
    ) async throws -> PlainpostForegroundOperationResult {
        try await runtime.replaceGoogleCredential(
            accountID: AccountID(input.accountID),
            grant: GoogleTokenGrant(
                accessToken: input.accessToken,
                refreshToken: input.refreshToken,
                expiresAt: Date(timeIntervalSince1970: input.accessTokenExpiresAt)
            ),
            identity: input.identity
        )
        return .replaceGoogleAccountCredential
    }
}
