import Foundation
import PlainpostCore
import PlainpostDB
import PlainpostSecrets

/// Whether this device holds an account's own provider sign-in: the stored credential its
/// authentication method needs, in a usable state. A locked vault reads as no sign-in.
public enum MailProviderSignIn {
    public static func isStored(
        accountID: AccountID, store: SQLiteMailStore, credentials: any CredentialVault
    ) async -> Bool {
        // An account made from a Sync Node's catalog knows no server until it signs in here.
        guard let account = store.accounts.first(where: { $0.id == accountID }), !account.imapHost.isEmpty,
              let authentication = try? store.accountAuthentication(accountID: accountID) else { return false }
        let keys: [CredentialRecordKey]
        switch authentication.method {
        case .password:
            keys = [MailCredentialKeys.imapPassword(accountID), MailCredentialKeys.smtpPassword(accountID)]
        case .googleOAuth:
            keys = [MailCredentialKeys.googleRefreshToken(accountID)]
        case .microsoftOAuth:
            keys = [MailCredentialKeys.microsoftRefreshToken(accountID)]
        }
        guard authentication.method == .password || authentication.state == .ready else { return false }
        for key in keys {
            guard let secret = try? await credentials.load(key), !secret.isEmpty else { return false }
        }
        return true
    }
}
