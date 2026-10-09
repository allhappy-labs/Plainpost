import Foundation

public protocol MicrosoftOAuthHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionMicrosoftOAuthHTTP: MicrosoftOAuthHTTP {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MicrosoftOAuthError.invalidResponse }
        return (data, http)
    }
}

public struct MicrosoftAccessToken: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let value: String
    public let expiresAt: Date
    public let rotatedRefreshToken: String?

    public init(value: String, expiresAt: Date, rotatedRefreshToken: String?) {
        self.value = value
        self.expiresAt = expiresAt
        self.rotatedRefreshToken = rotatedRefreshToken
    }

    public var description: String {
        "MicrosoftAccessToken(expiresAt: \(expiresAt), rotated: \(rotatedRefreshToken != nil), credentials: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt, "credentials": "<redacted>"], displayStyle: .struct)
    }
}

struct MicrosoftMailOAuthTokenClient: Sendable {
    static let tokenEndpoint = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    static let profileEndpoint = URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName")!
    private static let maximumResponseBytes = 64 * 1024
    private static let maximumTokenBytes = 16 * 1024

    private let client: MicrosoftOAuthPublicClient
    private let http: any MicrosoftOAuthHTTP
    private let now: @Sendable () -> Date

    init(client: MicrosoftOAuthPublicClient, http: any MicrosoftOAuthHTTP, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.http = http
        self.now = now
    }

    func exchangeCode(_ code: MicrosoftAuthorizationCode) async throws -> ExchangeGrant {
        guard code.redirectURI == client.redirectURI,
              Self.isFramable(code.code), code.verifier.utf8.count >= 43,
              code.verifier.utf8.count <= 128,
              code.verifier.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                      .contains($0)
              })
        else { throw MicrosoftOAuthError.invalidResponse }
        let response = try await token(form: [
            ("client_id", client.clientID),
            ("grant_type", "authorization_code"),
            ("code", code.code),
            ("code_verifier", code.verifier),
            ("redirect_uri", client.redirectURI),
            ("scope", MicrosoftMailOAuthProvider.exchangeScope),
        ], resource: .exchange)
        guard let refresh = response.refreshToken, Self.isFramable(refresh) else {
            throw MicrosoftOAuthError.invalidResponse
        }
        return ExchangeGrant(value: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn), refreshToken: refresh)
    }

    func refreshExchangeToken(refreshToken: String) async throws -> MicrosoftAccessToken {
        guard Self.isFramable(refreshToken) else { throw MicrosoftOAuthError.invalidGrant }
        let response = try await token(form: [
            ("client_id", client.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", MicrosoftMailOAuthProvider.exchangeScope),
        ], resource: .exchange)
        return try accessToken(from: response, previousRefresh: refreshToken)
    }

    func refreshGraphToken(refreshToken: String) async throws -> MicrosoftAccessToken {
        guard Self.isFramable(refreshToken) else { throw MicrosoftOAuthError.invalidGrant }
        let response = try await token(form: [
            ("client_id", client.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", MicrosoftMailOAuthProvider.graphScope),
        ], resource: .graph)
        return try accessToken(from: response, previousRefresh: refreshToken)
    }

    func graphIdentity(accessToken: String) async throws -> String {
        guard Self.isFramable(accessToken) else { throw MicrosoftOAuthError.invalidGrant }
        var request = URLRequest(url: Self.profileEndpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 401: throw MicrosoftOAuthError.invalidGrant
        case 403: throw MicrosoftOAuthError.scopeMissing
        case 408, 429, 500...599: throw MicrosoftOAuthError.unavailable
        default: throw MicrosoftOAuthError.invalidResponse
        }
        guard let profile = try? JSONDecoder().decode(GraphProfile.self, from: data),
              let candidate = [profile.mail, profile.userPrincipalName].compactMap({ $0 }).first(where: Self.isEmail)
        else { throw MicrosoftOAuthError.invalidResponse }
        return candidate.lowercased()
    }

    private func accessToken(from response: TokenResponse, previousRefresh: String) throws -> MicrosoftAccessToken {
        let rotated = response.refreshToken.flatMap { $0 == previousRefresh ? nil : $0 }
        if let rotated, !Self.isFramable(rotated) { throw MicrosoftOAuthError.invalidResponse }
        return MicrosoftAccessToken(
            value: response.accessToken,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            rotatedRefreshToken: rotated
        )
    }

    private enum Resource { case exchange, graph }

    private func token(form: [(String, String)], resource: Resource) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 400, 401:
            let code = (try? JSONDecoder().decode(TokenFailure.self, from: data))?.error
            switch code {
            case "invalid_grant", "interaction_required": throw MicrosoftOAuthError.invalidGrant
            case "invalid_client", "unauthorized_client": throw MicrosoftOAuthError.notConfigured
            case "invalid_scope", "consent_required": throw MicrosoftOAuthError.scopeMissing
            default: throw MicrosoftOAuthError.invalidResponse
            }
        case 408, 429, 500...599: throw MicrosoftOAuthError.unavailable
        default: throw MicrosoftOAuthError.invalidResponse
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              Self.isFramable(token.accessToken),
              token.expiresIn > 0, token.expiresIn <= 86_400,
              token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame
        else { throw MicrosoftOAuthError.invalidResponse }
        // Microsoft access tokens belong to the resource API and can be
        // encrypted or opaque, especially for consumer accounts. Bind the
        // request to one resource and check the token endpoint's scope
        // metadata when it supplies it; Graph and Exchange then verify tokens
        // against their own resources. Never parse JWT claims here.
        let requiredResponseScopes: Set<String>
        let otherResourcePrefix: String
        switch resource {
        case .exchange:
            requiredResponseScopes = Set(MicrosoftMailOAuthProvider.exchangeScope.split(separator: " ").map(String.init))
            otherResourcePrefix = "https://graph.microsoft.com/"
        case .graph:
            requiredResponseScopes = [MicrosoftMailOAuthProvider.graphScope]
            otherResourcePrefix = "https://outlook.office.com/"
        }
        if let scope = token.scope {
            let returnedScopes = Set(scope.split(separator: " ").map(String.init))
            if returnedScopes.contains(where: { $0.hasPrefix(otherResourcePrefix) }) {
                throw MicrosoftOAuthError.wrongAudience
            }
            guard requiredResponseScopes.isSubset(of: returnedScopes) else {
                throw MicrosoftOAuthError.scopeMissing
            }
        }
        return token
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do { result = try await http.send(request) }
        catch let error as MicrosoftOAuthError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MicrosoftOAuthError.unavailable }
        guard result.0.count <= Self.maximumResponseBytes else { throw MicrosoftOAuthError.invalidResponse }
        return result
    }

    private static func isFramable(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumTokenBytes
            && !value.unicodeScalars.contains {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            }
    }

    private static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return value.utf8.count <= 320 && parts.count == 2
            && !parts[0].isEmpty && !parts[1].isEmpty
            && !value.unicodeScalars.contains {
                $0.properties.isWhitespace || $0.properties.generalCategory == .control
            }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    struct ExchangeGrant {
        let value: String
        let expiresAt: Date
        let refreshToken: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let scope: String?
        let tokenType: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
            case scope, tokenType = "token_type"
        }
    }
    private struct TokenFailure: Decodable { let error: String }
    private struct GraphProfile: Decodable { let mail: String?; let userPrincipalName: String? }
}
