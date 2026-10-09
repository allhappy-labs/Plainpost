import Foundation

/// Public native client configuration. `supportsPersonalAccounts` records the
/// reviewed Entra registration audience; the registration itself is external.
public struct MicrosoftOAuthPublicClient: Equatable, Sendable {
    public static let clientIDInfoKey = "PlainpostMicrosoftIOSOAuthClientID"
    public static let redirectURIInfoKey = "PlainpostMicrosoftIOSOAuthRedirectURI"
    public static let personalAudienceInfoKey = "PlainpostMicrosoftIOSOAuthPersonalAudience"
    public let clientID: String
    public let redirectURI: String

    public var callbackScheme: String { URLComponents(string: redirectURI)!.scheme! }

    public static func resolve(from bundle: Bundle) -> MicrosoftOAuthPublicClient? {
        guard let info = bundle.infoDictionary,
              let clientID = info[clientIDInfoKey] as? String,
              let redirectURI = info[redirectURIInfoKey] as? String,
              let audience = info[personalAudienceInfoKey] as? String,
              let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return nil }
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return MicrosoftOAuthPublicClient(
            clientID: clientID, redirectURI: redirectURI, registeredSchemes: schemes,
            supportsPersonalAccounts: audience == "YES")
    }

    public init?(
        clientID: String,
        redirectURI: String,
        registeredSchemes: [String],
        supportsPersonalAccounts: Bool
    ) {
        guard UUID(uuidString: clientID) != nil,
              supportsPersonalAccounts,
              let components = URLComponents(string: redirectURI),
              let scheme = components.scheme,
              registeredSchemes.contains(scheme),
              components.host == nil,
              components.path == "/oauth/microsoft",
              components.query == nil,
              components.fragment == nil,
              redirectURI.utf8.count <= 512
        else { return nil }
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
}

public struct MicrosoftAuthorizationCode: Sendable, CustomStringConvertible,
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

    public var description: String { "MicrosoftAuthorizationCode(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["authorization": "<redacted>"], displayStyle: .struct)
    }
}

public struct MicrosoftMailGrant: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let email: String
    public let exchangeAccessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(email: String, exchangeAccessToken: String, refreshToken: String, expiresAt: Date) {
        self.email = email
        self.exchangeAccessToken = exchangeAccessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var description: String { "MicrosoftMailGrant(email: \(email), credentials: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["email": email, "credentials": "<redacted>"], displayStyle: .struct)
    }
}

public enum MicrosoftOAuthError: Error, Equatable, Sendable {
    case notConfigured
    case invalidGrant
    case identityMismatch
    case scopeMissing
    case wrongAudience
    case invalidResponse
    case unavailable
}

public struct MicrosoftMailOAuthProvider: Sendable {
    public static let exchangeScope =
        "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
    public static let graphScope = "https://graph.microsoft.com/User.Read"
    public static let consentScope = "offline_access \(graphScope) \(exchangeScope)"
    public static let authorizationEndpoint = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!

    private let client: MicrosoftOAuthPublicClient
    private let tokens: MicrosoftMailOAuthTokenClient

    public init(
        client: MicrosoftOAuthPublicClient,
        http: any MicrosoftOAuthHTTP,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.tokens = MicrosoftMailOAuthTokenClient(client: client, http: http, now: now)
    }

    public func authorizationURL(state: String, codeChallenge: String, loginHint: String) throws -> URL {
        guard Self.isSafeParameter(state, maximum: 512),
              codeChallenge.utf8.count == 43,
              codeChallenge.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
                      .contains($0)
              }),
              Self.isSafeParameter(loginHint, maximum: 320)
        else { throw MicrosoftOAuthError.invalidResponse }
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: client.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: Self.consentScope),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "login_hint", value: loginHint),
        ]
        guard let url = components.url else { throw MicrosoftOAuthError.invalidResponse }
        return url
    }

    /// No credential is stored here. The caller commits `refreshToken` only
    /// after the shared setup service verifies IMAP and SMTP and publishes the
    /// matching account. Graph access is used only for identity lookup.
    public func exchangeAndVerify(
        _ code: MicrosoftAuthorizationCode,
        expectedEmail: String
    ) async throws -> MicrosoftMailGrant {
        let exchange = try await tokens.exchangeCode(code)
        let graph = try await tokens.refreshGraphToken(refreshToken: exchange.refreshToken)
        let identity = try await tokens.graphIdentity(accessToken: graph.value)
        guard identity.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw MicrosoftOAuthError.identityMismatch
        }
        return MicrosoftMailGrant(
            email: identity,
            exchangeAccessToken: exchange.value,
            refreshToken: graph.rotatedRefreshToken ?? exchange.refreshToken,
            expiresAt: exchange.expiresAt
        )
    }

    public func refreshExchangeToken(refreshToken: String) async throws -> MicrosoftAccessToken {
        try await tokens.refreshExchangeToken(refreshToken: refreshToken)
    }

    private static func isSafeParameter(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            }
    }
}
