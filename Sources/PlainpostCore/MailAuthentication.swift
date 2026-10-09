import Foundation

/// The credential a mail transport presents to an IMAP or SMTP server.
///
/// Both cases carry secrets, so every textual rendering is redacted.
public enum MailAuthentication: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(String)
    /// A short-lived OAuth 2.0 bearer access token presented through SASL XOAUTH2.
    case xoauth2(accessToken: String)

    public var description: String {
        switch self {
        case .password: "MailAuthentication.password(<redacted>)"
        case .xoauth2: "MailAuthentication.xoauth2(<redacted>)"
        }
    }

    public var debugDescription: String { description }
}

extension MailAuthentication: CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

public enum MailAuthenticationError: Error, Equatable, Sendable {
    /// The server did not advertise XOAUTH2. No token was sent.
    case mechanismUnavailable
    /// The server refused the credential. Drives token refresh and, after a
    /// refreshed token is also refused, reauthorization.
    case rejected
    /// The server refused sign-in for a temporary reason (for example SMTP
    /// `454 4.7.0` or another 4xx reply). Not a credential refusal: it never
    /// drives token refresh or reauthorization.
    case temporarilyRefused
    /// The username or token contains characters that cannot be framed safely.
    case invalidCredentialCharacters
}

public enum XOAUTH2 {
    /// Builds the SASL XOAUTH2 initial client response:
    /// `base64("user=" + username + "\u{1}auth=Bearer " + token + "\u{1}\u{1}")`.
    ///
    /// Empty values and control characters (including the `\u{1}` separator,
    /// CR, LF and NUL) are refused so a value can never inject SASL fields or
    /// protocol lines.
    public static func initialClientResponse(username: String, accessToken: String) throws -> String {
        guard isFramable(username), isFramable(accessToken),
              !accessToken.unicodeScalars.contains(" ")
        else { throw MailAuthenticationError.invalidCredentialCharacters }
        return Data("user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }

    private static func isFramable(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
