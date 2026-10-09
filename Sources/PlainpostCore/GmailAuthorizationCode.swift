import Foundation

/// A Google authorization code captured on the RFC 8252 loopback redirect,
/// with the PKCE verifier and the exact redirect URI it was issued for.
///
/// The code and verifier are single-use secrets: they are exchanged once in
/// the app process and never cross XPC or reach logs, so every textual
/// rendering is redacted.
public struct GmailAuthorizationCode: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let code: String
    public let verifier: String
    public let redirectURI: String

    public init(code: String, verifier: String, redirectURI: String) {
        self.code = code
        self.verifier = verifier
        self.redirectURI = redirectURI
    }

    public var description: String {
        "GmailAuthorizationCode(redirectURI: \(redirectURI), code: <redacted>, verifier: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["redirectURI": redirectURI, "code": "<redacted>", "verifier": "<redacted>"],
               displayStyle: .struct)
    }
}
