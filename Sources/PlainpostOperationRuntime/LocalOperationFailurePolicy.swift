import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostSecrets

struct LocalOperationFailureDisposition: Equatable {
    let code: String
    let message: String
    let retryAt: Date?
}

enum LocalOperationFailurePolicy {
    static func disposition(
        error: Error,
        job: PlainpostDurableJob,
        now: Date = Date()
    ) -> LocalOperationFailureDisposition {
        let permanentCredentialFailure: Bool
        switch error {
        case CredentialVaultError.ciphertextInvalid,
             CredentialVaultError.unsupportedVersion,
             CredentialVaultError.invalidKeyLength,
             CredentialVaultError.keyAmbiguous,
             CredentialVaultError.clientUnauthorized,
             MailCredentialError.oauthNotConfigured:
            permanentCredentialFailure = true
        default:
            permanentCredentialFailure = false
        }
        let permanent = error is PlainpostError || permanentCredentialFailure
        let retryAt = !permanent && job.attempt < job.maxAttempts
            ? now.addingTimeInterval(retryDelay(attempt: job.attempt, jobID: job.id))
            : nil
        if error is SQLiteMailStoreError {
            return .init(
                code: "DATABASE_BUSY",
                message: "The local mail database is busy. Plainpost will retry automatically.",
                retryAt: retryAt
            )
        }
        let code: String
        let message: String
        switch error {
        case PlainpostError.notFound(let value),
             PlainpostError.permissionDenied(let value),
             PlainpostError.validationFailed(let value):
            code = "VALIDATION_FAILED"
            message = value
        case let error as IMAPClientError:
            switch error {
            case .authenticationFailed:
                code = "IMAP_AUTHENTICATION_REJECTED"
                message = "The mail server rejected the saved account credentials."
            case .connectionLimit:
                code = "IMAP_CONNECTION_LIMIT"
                message = "The mail server has too many simultaneous connections. Plainpost will retry."
            case .throttled:
                code = "IMAP_THROTTLED"
                message = "The mail server temporarily limited synchronization. Plainpost will retry."
            case .tlsFailed:
                code = "IMAP_TLS_FAILED"
                message = "Plainpost could not establish a trusted secure connection to the mail server."
            case .timedOut:
                code = "IMAP_NETWORK_UNAVAILABLE"
                message = "The mail server did not respond in time. Plainpost will retry."
            case .connectionFailed, .unreachableBeforeCommand:
                code = "IMAP_NETWORK_UNAVAILABLE"
                message = "Plainpost could not reach the mail server. Plainpost will retry."
            case .resourceLimit:
                code = "IMAP_RESOURCE_LIMIT"
                message = "The mail server response exceeded Plainpost's safety limit."
            case .protocolError:
                code = "IMAP_PROTOCOL_ERROR"
                message = "The mail server returned an unsupported response."
            }
        case MailAuthenticationError.rejected:
            // Reached only after the one in-place retry with a refreshed token
            // was refused too while a newer grant was installed meanwhile.
            code = "MAIL_AUTHENTICATION_REJECTED"
            message = "The mail server rejected the account's sign-in, including a refreshed token."
        case MailAuthenticationError.temporarilyRefused:
            code = "MAIL_AUTHENTICATION_THROTTLED"
            message = "The mail server temporarily refused the account's sign-in. Try again later."
        case MailAuthenticationError.mechanismUnavailable:
            code = "MAIL_AUTHENTICATION_UNAVAILABLE"
            message = "The mail server does not offer Google sign-in for this account."
        case MailCredentialError.reauthorizationRequired:
            code = "MAIL_REAUTHORIZATION_REQUIRED"
            message = "Google sign-in for this account has expired. Choose Sign in again in Settings."
        case MailCredentialError.oauthNotConfigured:
            code = "GOOGLE_OAUTH_NOT_CONFIGURED"
            message = "Google sign-in isn't available in this build."
        case MailCredentialError.unavailable:
            code = "MAIL_CREDENTIALS_UNAVAILABLE"
            message = "Saved mail credentials are not available for this account."
        case GoogleOAuthError.unavailable, GoogleOAuthError.invalidResponse:
            code = "GOOGLE_OAUTH_UNAVAILABLE"
            message = "Plainpost could not reach Google to refresh the account's sign-in. Plainpost will retry."
        case SMTPClientError.refusedBeforeData:
            code = "SMTP_REFUSED"
            message = "The mail server refused the message before it was sent. Nothing was delivered."
        case SMTPClientError.unreachableBeforeData:
            code = "SMTP_NETWORK_UNAVAILABLE"
            message = "Plainpost could not reach the mail server. Nothing was sent."
        case is SMTPClientError:
            code = "SMTP_UNAVAILABLE"
            message = "The delivery operation failed. Review its status before retrying."
        case CredentialVaultError.ciphertextInvalid,
             CredentialVaultError.unsupportedVersion,
             CredentialVaultError.invalidKeyLength:
            code = "CREDENTIAL_CORRUPT"
            message = "Saved mail credentials could not be decrypted. Replace the affected credentials."
        case CredentialVaultError.keyAmbiguous,
             CredentialVaultError.clientUnauthorized:
            code = "CREDENTIAL_ACCESS_DENIED"
            message = "Saved mail credentials are unavailable until the vault is repaired."
        default:
            code = "OPERATION_FAILED"
            message = "The local operation failed and will be retried when safe."
        }
        return .init(code: code, message: message, retryAt: retryAt)
    }

    static func retryDelay(attempt: Int, jobID: String) -> TimeInterval {
        let base = min(300, pow(2, Double(max(0, attempt))) * 2)
        let seed = jobID.utf8.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let fraction = Double(seed % 1_001) / 1_000
        return min(300, base * (0.9 + 0.2 * fraction))
    }
}
