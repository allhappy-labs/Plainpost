import Foundation
import XCTest
import PlainpostAccounts
import PlainpostCore

final class GoogleOAuthTokenClientTests: XCTestCase {
    func testIOSPublicClientOmitsSecretAndBindsExactCallbackOnExchangeAndRefresh() async throws {
        let id = "123-abc.apps.googleusercontent.com"
        let scheme = "com.googleusercontent.apps.123-abc"
        let publicClient = try XCTUnwrap(GoogleOAuthPublicClient(clientID: id, registeredSchemes: [scheme]))
        XCTAssertEqual(publicClient.redirectURI, "\(scheme):/oauth2redirect")
        let checker = FormCheckingHTTP(expected: [
            "client_id": id,
            "code": "4/code",
            "code_verifier": String(repeating: "v", count: 43),
            "grant_type": "authorization_code",
            "redirect_uri": publicClient.redirectURI,
        ], responses: [
            (200, tokenResponse(access: "access", refresh: "refresh", scope: "https://mail.google.com/")),
        ])
        let client = GoogleOAuthTokenClient(client: publicClient, http: checker)
        _ = try await client.exchange(GmailAuthorizationCode(
            code: "4/code", verifier: String(repeating: "v", count: 43), redirectURI: publicClient.redirectURI))
        let exchangeMismatches = await checker.mismatches
        XCTAssertEqual(exchangeMismatches, [])
        await XCTAssertThrowsAsync(try await client.exchange(GmailAuthorizationCode(
            code: "4/code", verifier: String(repeating: "v", count: 43), redirectURI: "other:/oauth2redirect"))) {
            XCTAssertEqual($0 as? GoogleOAuthError, .invalidResponse)
        }

        let refresh = FormCheckingHTTP(expected: [
            "client_id": id,
            "grant_type": "refresh_token",
            "refresh_token": "refresh",
        ], responses: [(200, tokenResponse(access: "access-2", refresh: "refresh-2"))])
        let rotated = try await GoogleOAuthTokenClient(client: publicClient, http: refresh).refresh(refreshToken: "refresh")
        XCTAssertEqual(rotated.rotatedRefreshToken, "refresh-2")
        let refreshMismatches = await refresh.mismatches
        XCTAssertEqual(refreshMismatches, [])
    }

    func testIOSPublicClientRequiresRegisteredSchemeAndRedactsNoSecret() throws {
        XCTAssertNil(GoogleOAuthPublicClient(clientID: "123-abc.apps.googleusercontent.com", registeredSchemes: []))
        XCTAssertNil(GoogleOAuthPublicClient(clientID: "$(CLIENT_ID)", registeredSchemes: ["com.googleusercontent.apps.123-abc"]))
        let client = try XCTUnwrap(GoogleOAuthPublicClient(
            clientID: "123-abc.apps.googleusercontent.com", registeredSchemes: ["com.googleusercontent.apps.123-abc"]))
        XCTAssertFalse(String(reflecting: client).contains("secret"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-ios-oauth-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.marynavdovenko.Plainpost.iOS.fixture",
            "CFBundlePackageType": "APPL",
            GoogleOAuthPublicClient.clientIDInfoKey: client.clientID,
            "CFBundleURLTypes": [["CFBundleURLSchemes": [client.callbackScheme]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        XCTAssertEqual(GoogleOAuthPublicClient.resolve(from: try XCTUnwrap(Bundle(url: root))), client)
    }

    func testExchangeSendsDesktopClientPKCEFieldsAndRequiresRefreshTokenAndGrantedMailScope() async throws {
        let code = GmailAuthorizationCode(
            code: "4/code", verifier: String(repeating: "v", count: 43),
            redirectURI: "http://127.0.0.1:53123/oauth/mail/google")
        let checker = FormCheckingHTTP(
            expected: [
                "client_id": "123-desktop.apps.googleusercontent.com", "client_secret": "fixture-secret",
                "code": "4/code", "code_verifier": String(repeating: "v", count: 43),
                "grant_type": "authorization_code", "redirect_uri": "http://127.0.0.1:53123/oauth/mail/google",
            ],
            responses: [
                (200, tokenResponse(access: "access-1", expiresIn: 3599, refresh: "1//refresh",
                                    scope: "https://www.googleapis.com/auth/userinfo.email https://mail.google.com/")),
                (200, tokenResponse(access: "access-1")),
                (200, #"{"access_token":"access-1","expires_in":3599,"refresh_token":"1//refresh","token_type":"Bearer"}"#),
                (200, tokenResponse(access: "access-1", refresh: "1//refresh", scope: "https://www.googleapis.com/auth/gmail.readonly")),
            ])
        let clock = MutableClock()
        let client = GoogleOAuthTokenClient(client: fixtureDesktopClient, http: checker, now: { clock.now })

        let grant = try await client.exchange(code)
        XCTAssertEqual(grant, GoogleTokenGrant(accessToken: "access-1", refreshToken: "1//refresh", expiresAt: clock.now.addingTimeInterval(3599)))
        await XCTAssertThrowsAsync(try await client.exchange(code)) {
            XCTAssertEqual($0 as? GoogleOAuthError, .invalidResponse)
        }
        let unchangedScopeGrant = try await client.exchange(code)
        XCTAssertEqual(unchangedScopeGrant.refreshToken, "1//refresh",
                       "OAuth permits an omitted scope when it matches the requested scope; Gmail profile verification follows exchange")
        await XCTAssertThrowsAsync(try await client.exchange(code)) {
            XCTAssertEqual($0 as? GoogleOAuthError, .scopeMissing)
        }
        let mismatches = await checker.mismatches
        XCTAssertEqual(mismatches, [])
    }

    func testRefreshMapsGoogleErrorsWithoutReadingDescriptions() async throws {
        let http = ScriptedGoogleOAuthHTTP(scripted: [
            .response(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#),
            .response(401, #"{"error":"invalid_client"}"#),
            .response(429, "{}"),
            .response(200, "not json"),
            .transportFailure,
            .response(200, tokenResponse(access: "access-2", refresh: "1//refresh")),
        ])
        let client = GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http)
        let expected: [GoogleOAuthError] = [.invalidGrant, .notConfigured, .unavailable, .invalidResponse, .unavailable]
        for error in expected {
            await XCTAssertThrowsAsync(try await client.refresh(refreshToken: "1//refresh")) {
                XCTAssertEqual($0 as? GoogleOAuthError, error)
            }
        }
        let unrotated = try await client.refresh(refreshToken: "1//refresh")
        XCTAssertEqual(unrotated.value, "access-2")
        XCTAssertNil(unrotated.rotatedRefreshToken, "an echoed refresh token is not a rotation")
    }

    func testVerifiedIdentityReadsGmailProfileAndLowercases() async throws {
        let http = ProfileHTTP(status: 200, body: #"{"emailAddress":"Ada@Example.test","historyId":"1","messagesTotal":0,"threadsTotal":0}"#)
        let client = GoogleOAuthTokenClient(client: fixtureDesktopClient, http: http)

        let identity = try await client.verifiedIdentity(accessToken: "access-1")

        XCTAssertEqual(identity, "ada@example.test")
        let seen = await http.seen
        XCTAssertEqual(seen, ["GET https://gmail.googleapis.com/gmail/v1/users/me/profile bearer=true"])
        let unauthorized = GoogleOAuthTokenClient(client: fixtureDesktopClient, http: ProfileHTTP(status: 401, body: "{}"))
        await XCTAssertThrowsAsync(try await unauthorized.verifiedIdentity(accessToken: "access-1")) {
            XCTAssertEqual($0 as? GoogleOAuthError, .invalidGrant)
        }
    }

    func testGmailProfile403DistinguishesDisabledAPIFromMissingScopeAndPolicy() async throws {
        let cases: [(String, GoogleOAuthError)] = [
            (#"{"error":{"errors":[{"reason":"accessNotConfigured"}]}}"#, .gmailAPIUnavailable),
            (#"{"error":{"details":[{"reason":"SERVICE_DISABLED"}]}}"#, .gmailAPIUnavailable),
            (#"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#, .scopeMissing),
            (#"{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}"#, .unavailable),
            (#"{"error":{"errors":[{"reason":"domainPolicy"}]}}"#, .gmailAccessDenied),
            ("{}", .gmailAccessDenied),
        ]
        for (body, expected) in cases {
            let client = GoogleOAuthTokenClient(
                client: fixtureDesktopClient, http: ProfileHTTP(status: 403, body: body))
            await XCTAssertThrowsAsync(try await client.verifiedIdentity(accessToken: "access-1")) {
                XCTAssertEqual($0 as? GoogleOAuthError, expected)
            }
        }
    }

    func testCredentialTypesRedactSecrets() throws {
        let rendered = [
            String(describing: fixtureDesktopClient), String(reflecting: fixtureDesktopClient),
            String(describing: GoogleTokenGrant(accessToken: "ya29.secret", refreshToken: "1//secret", expiresAt: Date())),
            String(reflecting: GoogleTokenGrant(accessToken: "ya29.secret", refreshToken: "1//secret", expiresAt: Date())),
            String(describing: GoogleAccessToken(value: "ya29.secret", expiresAt: Date(), rotatedRefreshToken: "1//secret")),
            String(describing: GmailAuthorizationCode(code: "4/secret", verifier: "secret-verifier", redirectURI: "http://127.0.0.1:1/oauth/mail/google")),
        ]
        var dumped = ""
        dump(GoogleTokenGrant(accessToken: "ya29.secret", refreshToken: "1//secret", expiresAt: Date()), to: &dumped)
        dump(GmailAuthorizationCode(code: "4/secret", verifier: "secret-verifier", redirectURI: "r"), to: &dumped)
        dump(fixtureDesktopClient, to: &dumped)
        for text in rendered + [dumped] {
            XCTAssertFalse(text.contains("secret"), text)
        }
    }

    func testDesktopClientRejectsPlaceholdersAndResolvesFromContainingAppForHelper() throws {
        XCTAssertNil(GoogleOAuthDesktopClient(clientID: "", clientSecret: "s"))
        XCTAssertNil(GoogleOAuthDesktopClient(clientID: "$(PLAINPOST_GOOGLE_OAUTH_CLIENT_ID)", clientSecret: "s"))
        XCTAssertNil(GoogleOAuthDesktopClient(clientID: "id", clientSecret: "has space"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainpost-oauth-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Plainpost.app")
        let helper = app.appendingPathComponent("Contents/Library/Helpers/PlainpostService.app")
        try writeInfo(at: app, values: [
            GoogleOAuthDesktopClient.clientIDInfoKey: "123-desktop.apps.googleusercontent.com",
            GoogleOAuthDesktopClient.clientSecretInfoKey: "fixture-secret",
        ])
        try writeInfo(at: helper, values: [:])
        let loose = root.appendingPathComponent("Elsewhere/Library/Helpers/PlainpostService.app")
        try writeInfo(at: loose, values: [:])

        XCTAssertEqual(GoogleOAuthDesktopClient.resolve(from: try XCTUnwrap(Bundle(url: helper))), fixtureDesktopClient)
        XCTAssertEqual(GoogleOAuthDesktopClient.resolve(from: try XCTUnwrap(Bundle(url: app))), fixtureDesktopClient)
        XCTAssertNil(GoogleOAuthDesktopClient.resolve(from: try XCTUnwrap(Bundle(url: loose))))
    }

    private func writeInfo(at bundleURL: URL, values: [String: String]) throws {
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: String] = ["CFBundleIdentifier": "com.olhapi.fixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        info.merge(values) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

/// Checks form fields as they arrive and keeps only the names of mismatched
/// fields, never values.
private actor FormCheckingHTTP: GoogleOAuthHTTP {
    private let expected: [String: String]
    private var responses: [(Int, String)]
    private(set) var mismatches: [String] = []

    init(expected: [String: String], responses: [(Int, String)]) {
        self.expected = expected
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        for name in Set(expected.keys).union(fields.keys) where expected[name] != fields[name] {
            mismatches.append(name)
        }
        if request.url?.absoluteString != "https://oauth2.googleapis.com/token" { mismatches.append("url") }
        if request.value(forHTTPHeaderField: "Content-Type") != "application/x-www-form-urlencoded" { mismatches.append("content-type") }
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor ProfileHTTP: GoogleOAuthHTTP {
    private let status: Int
    private let body: String
    private(set) var seen: [String] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        seen.append("\(request.httpMethod ?? "") \(request.url?.absoluteString ?? "") bearer=\(bearer)")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
