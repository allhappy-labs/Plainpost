import Foundation
import XCTest
@testable import PlainpostAccounts

final class MicrosoftMailOAuthProviderTests: XCTestCase {
    private let clientID = "00000000-1111-4222-8333-444444444444"
    private let redirectURI = "com.plainpost.mail:/oauth/microsoft"

    func testAuthorizationRequestsPKCEGraphAndExchangeConsentWithoutAClientSecret() throws {
        let client = try XCTUnwrap(MicrosoftOAuthPublicClient(
            clientID: clientID, redirectURI: redirectURI,
            registeredSchemes: ["com.plainpost.mail"], supportsPersonalAccounts: true
        ))
        let provider = MicrosoftMailOAuthProvider(client: client, http: MicrosoftScriptedHTTP([]))
        let challenge = String(repeating: "C", count: 43)
        let url = try provider.authorizationURL(
            state: "opaque-state", codeChallenge: challenge, loginHint: "person@outlook.com"
        )
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(url.path, "/common/oauth2/v2.0/authorize")
        XCTAssertEqual(fields["client_id"], clientID)
        XCTAssertEqual(fields["redirect_uri"], redirectURI)
        XCTAssertEqual(fields["response_type"], "code")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["code_challenge"], challenge)
        XCTAssertEqual(fields["state"], "opaque-state")
        XCTAssertEqual(fields["login_hint"], "person@outlook.com")
        XCTAssertEqual(Set(fields["scope"]!.split(separator: " ").map(String.init)), Set([
            "offline_access", "https://graph.microsoft.com/User.Read",
            "https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send",
        ]))
        XCTAssertNil(fields["client_secret"])
        XCTAssertNil(MicrosoftOAuthPublicClient(
            clientID: clientID, redirectURI: redirectURI,
            registeredSchemes: ["com.plainpost.mail"], supportsPersonalAccounts: false
        ))
    }

    func testExchangeCodeAndGraphRefreshProduceSeparateTokensAndVerifiedIdentity() async throws {
        let http = MicrosoftScriptedHTTP([
            .token(200, tokenJSON(
                value: "exchange-access",
                returnedScopes: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
                refresh: "refresh-exchange"
            )),
            .token(200, tokenJSON(
                value: "graph-access",
                returnedScopes: "https://graph.microsoft.com/User.Read", refresh: "refresh-graph"
            )),
            .profile(200, #"{"mail":"Person@Outlook.com","userPrincipalName":"different@example.com"}"#),
        ])
        let provider = MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)

        let grant = try await provider.exchangeAndVerify(
            MicrosoftAuthorizationCode(code: "auth-code", verifier: String(repeating: "v", count: 43), redirectURI: redirectURI),
            expectedEmail: "person@outlook.com"
        )

        XCTAssertEqual(grant.email, "person@outlook.com")
        XCTAssertEqual(grant.exchangeAccessToken, "exchange-access")
        XCTAssertEqual(grant.refreshToken, "refresh-graph")
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.url), [
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName",
        ])
        XCTAssertEqual(requests[0].form["grant_type"], "authorization_code")
        XCTAssertEqual(requests[0].form["code"], "auth-code")
        XCTAssertEqual(requests[0].form["code_verifier"], String(repeating: "v", count: 43))
        XCTAssertEqual(requests[0].form["redirect_uri"], redirectURI)
        XCTAssertEqual(requests[0].form["scope"], MicrosoftMailOAuthProvider.exchangeScope)
        XCTAssertEqual(requests[1].form["grant_type"], "refresh_token")
        XCTAssertEqual(requests[1].form["refresh_token"], "refresh-exchange")
        XCTAssertEqual(requests[1].form["scope"], MicrosoftMailOAuthProvider.graphScope)
        XCTAssertEqual(requests[2].authorization, "Bearer graph-access")
        XCTAssertTrue(requests.allSatisfy { $0.form["client_secret"] == nil })
        XCTAssertFalse(String(describing: grant).contains("refresh-graph"))
        XCTAssertFalse(String(reflecting: grant).contains("exchange-access"))
    }

    func testWrongAudienceOrMissingExchangeScopeIsRejectedBeforeGraphRequest() async throws {
        for (returnedScopes, expectedError) in [
            ("https://graph.microsoft.com/User.Read", MicrosoftOAuthError.wrongAudience),
            ("https://outlook.office.com/IMAP.AccessAsUser.All", MicrosoftOAuthError.scopeMissing),
        ] {
            let http = MicrosoftScriptedHTTP([.token(200, tokenJSON(
                value: "opaque-exchange-token", returnedScopes: returnedScopes,
                refresh: "refresh"
            ))])
            let provider = MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)
            do {
                _ = try await provider.exchangeAndVerify(
                    MicrosoftAuthorizationCode(code: "auth-code", verifier: String(repeating: "v", count: 43), redirectURI: redirectURI),
                    expectedEmail: "person@outlook.com"
                )
                XCTFail("Expected invalid resource token")
            } catch {
                XCTAssertEqual(error as? MicrosoftOAuthError, expectedError)
            }
            let seen = await http.requests
            XCTAssertEqual(seen.count, 1)
        }
    }

    func testGraphIdentityMismatchAndGraphAudienceFailureRejectGrant() async throws {
        let exchange = tokenJSON(
            value: "opaque-exchange-token",
            returnedScopes: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
            refresh: "refresh-exchange"
        )
        for (graphScope, profile, expectedError) in [
            ("https://outlook.office.com/SMTP.Send", #"{"mail":"person@outlook.com"}"#, MicrosoftOAuthError.wrongAudience),
            ("https://graph.microsoft.com/User.Read", #"{"mail":"someone@example.com"}"#, MicrosoftOAuthError.identityMismatch),
        ] {
            let http = MicrosoftScriptedHTTP([
                .token(200, exchange),
                .token(200, tokenJSON(
                    value: "opaque-graph-token", returnedScopes: graphScope, refresh: nil
                )),
                .profile(200, profile),
            ])
            do {
                _ = try await MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)
                    .exchangeAndVerify(
                        MicrosoftAuthorizationCode(code: "auth-code", verifier: String(repeating: "v", count: 43), redirectURI: redirectURI),
                        expectedEmail: "person@outlook.com"
                    )
                XCTFail("Expected identity or audience failure")
            } catch {
                XCTAssertEqual(error as? MicrosoftOAuthError, expectedError)
            }
        }
    }

    func testRefreshRotatesExchangeCredentialAndMapsPermanentErrorsSafely() async throws {
        let http = MicrosoftScriptedHTTP([
            .token(200, tokenJSON(
                value: "exchange-access",
                returnedScopes: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
                refresh: "rotated-refresh"
            )),
            .token(400, #"{"error":"invalid_grant","error_description":"sensitive provider detail"}"#),
        ])
        let provider = MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)
        let token = try await provider.refreshExchangeToken(refreshToken: "old-refresh")
        XCTAssertEqual(token.value, "exchange-access")
        XCTAssertEqual(token.rotatedRefreshToken, "rotated-refresh")
        do {
            _ = try await provider.refreshExchangeToken(refreshToken: "revoked-refresh")
            XCTFail("Expected revoked grant")
        } catch {
            XCTAssertEqual(error as? MicrosoftOAuthError, .invalidGrant)
            XCTAssertFalse(String(describing: error).contains("sensitive provider detail"))
        }
    }

    func testCodeIsBoundToRegisteredRedirectAndRequiresRefreshToken() async throws {
        let http = MicrosoftScriptedHTTP([.token(200, tokenJSON(
            value: "opaque-exchange-token",
            returnedScopes: MicrosoftMailOAuthProvider.exchangeScope,
            refresh: nil
        ))])
        let provider = MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)
        do {
            _ = try await provider.exchangeAndVerify(
                MicrosoftAuthorizationCode(code: "auth-code", verifier: String(repeating: "v", count: 43), redirectURI: "other:/oauth/microsoft"),
                expectedEmail: "person@outlook.com"
            )
            XCTFail("Expected callback mismatch")
        } catch { XCTAssertEqual(error as? MicrosoftOAuthError, .invalidResponse) }
        let before = await http.requests
        XCTAssertTrue(before.isEmpty)
        do {
            _ = try await provider.exchangeAndVerify(
                MicrosoftAuthorizationCode(code: "auth-code", verifier: String(repeating: "v", count: 43), redirectURI: redirectURI),
                expectedEmail: "person@outlook.com"
            )
            XCTFail("Expected missing refresh token")
        } catch { XCTAssertEqual(error as? MicrosoftOAuthError, .invalidResponse) }
    }

    func testMalformedOversizedAndCancelledTokenResponseDoNotExposeCredentials() async throws {
        let http = MicrosoftScriptedHTTP([
            .token(200, "not-json"),
            .token(200, String(repeating: "x", count: 65 * 1024)),
            .cancelled,
        ])
        let provider = MicrosoftMailOAuthProvider(client: try configuredClient(), http: http)
        for _ in 0..<2 {
            do {
                _ = try await provider.refreshExchangeToken(refreshToken: "sensitive-refresh")
                XCTFail("Expected invalid token response")
            } catch { XCTAssertEqual(error as? MicrosoftOAuthError, .invalidResponse) }
        }
        do {
            _ = try await provider.refreshExchangeToken(refreshToken: "sensitive-refresh")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Keep cancellation distinct from provider failures.
        }
    }

    private func configuredClient() throws -> MicrosoftOAuthPublicClient {
        try XCTUnwrap(MicrosoftOAuthPublicClient(
            clientID: clientID, redirectURI: redirectURI,
            registeredSchemes: ["com.plainpost.mail"], supportsPersonalAccounts: true
        ))
    }
}

private func tokenJSON(value: String, returnedScopes: String, refresh: String?) -> String {
    var fields: [String: Any] = ["access_token": value, "expires_in": 3600,
                                 "token_type": "Bearer", "scope": returnedScopes]
    if let refresh { fields["refresh_token"] = refresh }
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return String(decoding: data, as: UTF8.self)
}

private actor MicrosoftScriptedHTTP: MicrosoftOAuthHTTP {
    enum Step: Sendable { case token(Int, String), profile(Int, String), cancelled }
    struct Seen: Sendable {
        let url: String
        let form: [String: String]
        let authorization: String?
    }
    private var steps: [Step]
    private(set) var requests: [Seen] = []
    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        requests.append(Seen(
            url: request.url!.absoluteString,
            form: Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { old, _ in old }),
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let step = steps.removeFirst()
        let result: (Int, String)
        switch step {
        case .token(let status, let body), .profile(let status, let body): result = (status, body)
        case .cancelled: throw CancellationError()
        }
        return (Data(result.1.utf8), HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!)
    }
}
