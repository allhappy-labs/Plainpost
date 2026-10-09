import Foundation
import PlainpostCore

/// Plainpost's Google "Desktop app" OAuth client.
///
/// Google requires the client secret at the token endpoint for Desktop
/// clients. The secret is not confidential in that model, but it is injected at
/// packaging time, never committed, and redacted from every rendering.
public struct GoogleOAuthDesktopClient: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public static let clientIDInfoKey = "PlainpostGoogleOAuthClientID"
    public static let clientSecretInfoKey = "PlainpostGoogleOAuthClientSecret"

    public let clientID: String
    public let clientSecret: String

    public init?(clientID: String, clientSecret: String) {
        guard Self.isUsable(clientID), Self.isUsable(clientSecret) else { return nil }
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Reads the keys from `bundle`, or — for
    /// `Contents/Library/Helpers/PlainpostService.app` — from the containing
    /// Plainpost.app. A missing, empty or unexpanded build-setting value
    /// yields `nil`, which makes Google OAuth accounts `oauthNotConfigured`.
    public static func resolve(from bundle: Bundle) -> GoogleOAuthDesktopClient? {
        if let client = client(in: bundle.infoDictionary) {
            return client
        }
        let helpers = bundle.bundleURL.deletingLastPathComponent()
        let library = helpers.deletingLastPathComponent()
        let contents = library.deletingLastPathComponent()
        let container = contents.deletingLastPathComponent()
        guard bundle.bundleURL.pathExtension == "app",
              helpers.lastPathComponent == "Helpers",
              library.lastPathComponent == "Library",
              contents.lastPathComponent == "Contents",
              container.pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return client(in: info)
    }

    public var description: String {
        "GoogleOAuthDesktopClient(clientID: \(clientID), clientSecret: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["clientID": clientID, "clientSecret": "<redacted>"], displayStyle: .struct)
    }

    private static func client(in info: [String: Any]?) -> GoogleOAuthDesktopClient? {
        guard let id = info?[clientIDInfoKey] as? String, let secret = info?[clientSecretInfoKey] as? String else {
            return nil
        }
        return GoogleOAuthDesktopClient(clientID: id, clientSecret: secret)
    }

    private static func isUsable(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("$(")
            && !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
    }
}

/// A Google iOS public client. The reversed client ID is both the callback
/// scheme registered in Info.plist and the scheme Google redirects to.
/// Native clients never include a client secret in a token request.
public struct GoogleOAuthPublicClient: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public static let clientIDInfoKey = "PlainpostGoogleIOSOAuthClientID"
    public let clientID: String
    public let callbackScheme: String
    public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    public init?(clientID: String, registeredSchemes: [String]) {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.utf8.count <= 512,
              !clientID.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { return nil }
        let prefix = String(clientID.dropLast(suffix.count))
        guard !prefix.isEmpty,
              prefix.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) })
        else { return nil }
        let scheme = "com.googleusercontent.apps.\(prefix)"
        guard registeredSchemes.contains(scheme) else { return nil }
        self.clientID = clientID
        self.callbackScheme = scheme
    }

    public static func resolve(from bundle: Bundle) -> GoogleOAuthPublicClient? {
        guard let info = bundle.infoDictionary,
              let clientID = info[clientIDInfoKey] as? String,
              let types = info["CFBundleURLTypes"] as? [[String: Any]]
        else { return nil }
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return GoogleOAuthPublicClient(clientID: clientID, registeredSchemes: schemes)
    }

    public var description: String { "GoogleOAuthPublicClient(clientID: \(clientID), callbackScheme: \(callbackScheme))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["clientID": clientID, "callbackScheme": callbackScheme], displayStyle: .struct)
    }
}

/// The HTTP seam for Google's token and Gmail profile endpoints. Tests inject a
/// fake; nothing in the test suite reaches Google.
public protocol GoogleOAuthHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGoogleOAuthHTTP: GoogleOAuthHTTP {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleOAuthError.invalidResponse }
        return (data, http)
    }
}

/// The result of an authorization-code exchange. Crosses app → service XPC
/// once during setup; always redacted.
public struct GoogleTokenGrant: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var description: String {
        "GoogleTokenGrant(expiresAt: \(expiresAt), accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt, "tokens": "<redacted>"], displayStyle: .struct)
    }
}

public struct GoogleAccessToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let value: String
    public let expiresAt: Date
    /// Present only when Google rotated the refresh token.
    public let rotatedRefreshToken: String?

    public init(value: String, expiresAt: Date, rotatedRefreshToken: String?) {
        self.value = value
        self.expiresAt = expiresAt
        self.rotatedRefreshToken = rotatedRefreshToken
    }

    public var description: String {
        "GoogleAccessToken(expiresAt: \(expiresAt), rotated: \(rotatedRefreshToken != nil), value: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt, "tokens": "<redacted>"], displayStyle: .struct)
    }
}

public enum GoogleOAuthError: Error, Equatable, Sendable {
    /// No usable Desktop client is packaged, or Google refused the client.
    case notConfigured
    /// The grant was revoked, expired or never valid; the user must sign in again.
    case invalidGrant
    case identityMismatch
    /// The grant does not include `https://mail.google.com/`.
    case scopeMissing
    /// Google refused the Gmail profile because this Cloud project has not enabled the Gmail API.
    case gmailAPIUnavailable
    /// Gmail refused profile access for a policy or permission reason other than a missing scope.
    case gmailAccessDenied
    case invalidResponse
    /// Transport failure, throttling or a Google server error; retry later.
    case unavailable
}

public struct GoogleOAuthTokenClient: Sendable {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let profileEndpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
    static let maximumTokenBytes = 16 * 1024
    static let maximumResponseBytes = 64 * 1024

    private enum Client: Sendable {
        case desktop(GoogleOAuthDesktopClient)
        case ios(GoogleOAuthPublicClient)

        var clientID: String {
            switch self {
            case .desktop(let client): client.clientID
            case .ios(let client): client.clientID
            }
        }
        var clientSecret: String? {
            if case .desktop(let client) = self { return client.clientSecret }
            return nil
        }
    }

    private let client: Client
    private let http: any GoogleOAuthHTTP
    private let now: @Sendable () -> Date

    public init(client: GoogleOAuthDesktopClient, http: any GoogleOAuthHTTP, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = .desktop(client)
        self.http = http
        self.now = now
    }

    public init(client: GoogleOAuthPublicClient, http: any GoogleOAuthHTTP, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = .ios(client)
        self.http = http
        self.now = now
    }

    /// Exchanges an authorization code. Requires a refresh token and rejects
    /// an explicit grant that omits Gmail. OAuth permits the token response to
    /// omit `scope` when it matches the request; callers verify Gmail access
    /// with the profile endpoint before persisting the grant.
    public func exchange(_ code: GmailAuthorizationCode) async throws -> GoogleTokenGrant {
        guard Self.isFramable(code.code), Self.isFramable(code.verifier), !code.redirectURI.isEmpty else {
            throw GoogleOAuthError.invalidResponse
        }
        if case .ios(let publicClient) = client, code.redirectURI != publicClient.redirectURI {
            throw GoogleOAuthError.invalidResponse
        }
        var form = [
            ("client_id", client.clientID),
            ("code", code.code),
            ("code_verifier", code.verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", code.redirectURI),
        ]
        if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        let response = try await token(form: form)
        guard let refreshToken = response.refreshToken, Self.isFramable(refreshToken) else {
            throw GoogleOAuthError.invalidResponse
        }
        if let scope = response.scope, !Self.includesMailScope(scope) {
            throw GoogleOAuthError.scopeMissing
        }
        return GoogleTokenGrant(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(response.expiresIn)
        )
    }

    /// Refreshes an access token. HTTP 400 `{"error":"invalid_grant"}` → `.invalidGrant`.
    public func refresh(refreshToken: String) async throws -> GoogleAccessToken {
        guard Self.isFramable(refreshToken) else { throw GoogleOAuthError.invalidGrant }
        var form = [
            ("client_id", client.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        if let secret = client.clientSecret { form.append(("client_secret", secret)) }
        let response = try await token(form: form)
        if let scope = response.scope, !Self.includesMailScope(scope) {
            throw GoogleOAuthError.scopeMissing
        }
        let rotated = response.refreshToken.flatMap { $0 == refreshToken ? nil : $0 }
        if let rotated, !Self.isFramable(rotated) { throw GoogleOAuthError.invalidResponse }
        return GoogleAccessToken(
            value: response.accessToken,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            rotatedRefreshToken: rotated
        )
    }

    /// Reads the Gmail profile with the access token and returns its
    /// lower-cased `emailAddress`: the identity Google actually granted.
    public func verifiedIdentity(accessToken: String) async throws -> String {
        guard Self.isFramable(accessToken) else { throw GoogleOAuthError.invalidGrant }
        var request = URLRequest(url: Self.profileEndpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 401:
            throw GoogleOAuthError.invalidGrant
        case 403:
            throw Self.gmailProfileForbidden(data)
        case 408, 429, 500...599:
            throw GoogleOAuthError.unavailable
        default:
            throw GoogleOAuthError.invalidResponse
        }
        guard let profile = try? JSONDecoder().decode(GmailProfile.self, from: data) else {
            throw GoogleOAuthError.invalidResponse
        }
        let identity = profile.emailAddress.lowercased()
        guard !identity.isEmpty, identity.utf8.count <= 320, identity.contains("@"),
              !identity.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { throw GoogleOAuthError.invalidResponse }
        return identity
    }

    static func includesMailScope(_ scope: String) -> Bool {
        scope.split(separator: " ").contains { $0 == "https://mail.google.com/" }
    }

    private func token(form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            break
        case 400, 401:
            // Only the OAuth error code is read; descriptions are never surfaced.
            let error = (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))?.error
            switch error {
            case "invalid_grant": throw GoogleOAuthError.invalidGrant
            case "invalid_client", "unauthorized_client": throw GoogleOAuthError.notConfigured
            case "invalid_scope": throw GoogleOAuthError.scopeMissing
            default: throw GoogleOAuthError.invalidResponse
            }
        case 408, 429, 500...599:
            throw GoogleOAuthError.unavailable
        default:
            throw GoogleOAuthError.invalidResponse
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              Self.isFramable(decoded.accessToken),
              decoded.expiresIn > 0, decoded.expiresIn <= 86_400
        else { throw GoogleOAuthError.invalidResponse }
        if let tokenType = decoded.tokenType, tokenType.caseInsensitiveCompare("Bearer") != .orderedSame {
            throw GoogleOAuthError.invalidResponse
        }
        return decoded
    }

    /// Gmail uses HTTP 403 for missing scopes, disabled APIs, quota, and
    /// Workspace policy. Read only documented machine reasons; never surface
    /// Google's free-form response text or token-bearing request details.
    private static func gmailProfileForbidden(_ data: Data) -> GoogleOAuthError {
        guard data.count <= maximumResponseBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return .gmailAccessDenied }
        let legacy = (error["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        let details = (error["details"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        let reasons = Set(legacy + details)
        if !reasons.isDisjoint(with: ["accessNotConfigured", "SERVICE_DISABLED"]) {
            return .gmailAPIUnavailable
        }
        if reasons.contains("insufficientPermissions") { return .scopeMissing }
        if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"]) {
            return .unavailable
        }
        return .gmailAccessDenied
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await http.send(request)
        } catch let error as GoogleOAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoogleOAuthError.unavailable
        }
        guard result.0.count <= Self.maximumResponseBytes else { throw GoogleOAuthError.invalidResponse }
        return result
    }

    static func isFramable(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumTokenBytes
            && !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
    }

    private struct GmailProfile: Decodable {
        let emailAddress: String
    }
}
