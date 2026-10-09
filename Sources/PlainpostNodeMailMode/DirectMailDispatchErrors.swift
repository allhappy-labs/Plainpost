import Foundation
import PlainpostAccounts
import PlainpostCore
import PlainpostDB
import PlainpostSecrets
import PlainpostServiceIPC

/// How a direct dispatch's error reads to the router, on the Mac and the iPhone alike.
public enum DirectMailDispatchErrors {
    /// A passing, provably pre-effect reason not to dispatch now: the
    /// intent returns to `pending` instead of failing.
    public static func deferral(for error: any Error) -> DirectMailDispatchDeferral? {
        switch error {
        case let deferral as DirectMailDispatchDeferral:
            return deferral
        case CredentialVaultError.locked:
            return DirectMailDispatchDeferral(reason: "Plainpost is locked.")
        // Transient and before any provider effect: the mail server or
        // Google could not be reached, or refused sign-in for now. The router
        // retries them with back-off and fails them after a bound.
        case SMTPClientError.unreachableBeforeData:
            return DirectMailDispatchDeferral(transient: .mailServerUnreachable)
        // IMAP: connecting, the greeting or sign-in failed before any
        // STORE, MOVE, COPY or EXPUNGE was sent. A failure after one of
        // them stays ambiguous (`refusal(for:)` returns nil).
        case IMAPClientError.unreachableBeforeCommand:
            return DirectMailDispatchDeferral(transient: .mailServerUnreachable)
        case MailAuthenticationError.temporarilyRefused:
            return DirectMailDispatchDeferral(transient: .signInRefusedForNow)
        case GoogleOAuthError.unavailable, GoogleOAuthError.invalidResponse:
            return DirectMailDispatchDeferral(transient: .googleUnreachable)
        default:
            return nil
        }
    }

    public static let networkMessage = DirectDeferralReason.mailServerUnreachable.message

    /// Only failures that provably happened before the provider acted
    /// become refusals (the intent may be recorded `failed`); every other
    /// error is ambiguous and leaves the intent `dispatching(direct)`.
    public static func refusal(for error: any Error) -> DirectMailDispatchRefusal? {
        switch error {
        case let refusal as DirectMailDispatchRefusal:
            return refusal
        case let error as PlainpostError:
            switch error {
            case let .validationFailed(message), let .notFound(message), let .permissionDenied(message):
                return DirectMailDispatchRefusal(message: message)
            }
        case is PlainpostServiceClientError, is CredentialVaultError, is MailCredentialError, is DraftOptimisticUpdateError:
            return DirectMailDispatchRefusal(message: "Plainpost couldn't reach your mail provider for this change.")
        // Definite sign-in failures, all before any SMTP or IMAP command
        // that could act on the message (the transient ones are deferrals).
        // (`deferral(for:)` runs first, so the transient cases below are
        // only reached by a caller asking `refusal(for:)` alone; they are
        // still never ambiguous.)
        case let error as MailAuthenticationError:
            switch error {
            case .rejected, .mechanismUnavailable, .invalidCredentialCharacters:
                return DirectMailDispatchRefusal(message: "Your mail server refused this account's sign-in. Nothing was sent.")
            case .temporarilyRefused:
                return DirectMailDispatchRefusal(message: "Your mail server refused sign-in for now. Nothing was sent.")
            }
        case let error as GoogleOAuthError:
            switch error {
            case .notConfigured, .invalidGrant, .identityMismatch, .scopeMissing, .gmailAccessDenied:
                return DirectMailDispatchRefusal(message: "Google sign-in for this account needs attention. Nothing was sent.")
            case .gmailAPIUnavailable:
                return DirectMailDispatchRefusal(message: "Gmail API is unavailable for Plainpost's Google Cloud project. Nothing was sent.")
            case .unavailable, .invalidResponse:
                return DirectMailDispatchRefusal(message: "Plainpost couldn't reach Google to sign in. Nothing was sent.")
            }
        case let error as SMTPClientError:
            // The one delivery-ambiguity rule (PlainpostCore): a failure
            // before the message content was on the wire is a refusal.
            if SMTPDeliveryAmbiguity.isAmbiguous(error) { return nil }
            switch error {
            case .unreachableBeforeData:
                return DirectMailDispatchRefusal(message: networkMessage + " Nothing was sent.")
            case .tlsFailed:
                return DirectMailDispatchRefusal(message: "Plainpost couldn't establish a secure connection to your mail server. Nothing was sent.")
            case .authenticationFailed:
                return DirectMailDispatchRefusal(message: "Your mail server didn't accept the sign-in. Nothing was sent.")
            default:
                return DirectMailDispatchRefusal(message: "Your mail provider refused this message.")
            }
        case let error as IMAPClientError:
            switch error {
            case .authenticationFailed, .tlsFailed, .connectionLimit, .throttled:
                return DirectMailDispatchRefusal(message: "Your mail provider refused this change.")
            default:
                // A connection lost or stalled once a command may have been
                // sent, and anything not known to be pre-command: ambiguous.
                return nil
            }
        default:
            return nil
        }
    }
}
