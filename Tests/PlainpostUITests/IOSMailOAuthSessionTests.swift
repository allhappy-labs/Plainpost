#if os(iOS)
import CryptoKit
import Foundation
import PlainpostAccounts
import PlainpostUI
import XCTest

@MainActor
final class IOSMailOAuthSessionTests: XCTestCase {
    private let client = GoogleOAuthPublicClient(
        clientID: "123-abc.apps.googleusercontent.com",
        registeredSchemes: ["com.googleusercontent.apps.123-abc"])!

    func testAuthorizationUsesFreshPKCEAndValidatesCallback() async throws {
        var attempts: [(String, String)] = []
        let session = IOSMailOAuthSession { url, scheme in
            XCTAssertEqual(scheme, self.client.callbackScheme)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
            XCTAssertEqual(value("client_id"), self.client.clientID)
            XCTAssertEqual(value("redirect_uri"), self.client.redirectURI)
            XCTAssertEqual(value("scope"), "https://mail.google.com/")
            XCTAssertEqual(value("code_challenge_method"), "S256")
            XCTAssertNil(value("client_secret"))
            let state = try XCTUnwrap(value("state"))
            let challenge = try XCTUnwrap(value("code_challenge"))
            XCTAssertGreaterThanOrEqual(state.count, 43)
            attempts.append((state, challenge))
            return URL(string: "\(self.client.redirectURI)?state=\(state)&code=4%2Fcode")!
        }
        let first = try await session.authorize(client: client, loginHint: "ada+mail@example.test")
        let expectedChallenge = Data(SHA256.hash(data: Data(first.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(attempts[0].1, expectedChallenge)
        XCTAssertEqual(first.code, "4/code")
        _ = try await session.authorize(client: client, loginHint: "ada@example.test")
        XCTAssertNotEqual(attempts[0].0, attempts[1].0)
        XCTAssertFalse(String(reflecting: first).contains("4/code"))
    }

    func testOneTapGmailSignInShowsAccountChooserWithoutLoginHint() async throws {
        let session = IOSMailOAuthSession { url, _ in
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertFalse(query.contains(where: { $0.name == "login_hint" }))
            let state = try XCTUnwrap(query.first(where: { $0.name == "state" })?.value)
            return URL(string: "\(self.client.redirectURI)?state=\(state)&code=4%2Fcode")!
        }

        let result = try await session.authorize(client: client, loginHint: "")
        XCTAssertEqual(result.code, "4/code")
    }

    func testCallbackRejectsMismatchDuplicatesAndReplayState() throws {
        let redirect = client.redirectURI, state = String(repeating: "s", count: 43)
        let invalid = [
            "other:/oauth2redirect?state=\(state)&code=x",
            "\(redirect)/other?state=\(state)&code=x",
            "\(redirect)?state=other&code=x",
            "\(redirect)?state=\(state)&state=\(state)&code=x",
            "\(redirect)?state=\(state)&code=x&code=y",
            "\(redirect)?state=\(state)",
            "\(redirect)?state=\(state)&code=x#fragment",
        ]
        for text in invalid {
            XCTAssertThrowsError(try IOSMailOAuthSession.validate(
                callback: URL(string: text)!, redirectURI: redirect, expectedState: state), text)
        }
        XCTAssertThrowsError(try IOSMailOAuthSession.validate(
            callback: URL(string: "\(redirect)?state=\(state)&error=access_denied")!,
            redirectURI: redirect, expectedState: state)) {
                XCTAssertEqual($0 as? IOSMailOAuthSession.Failure, .denied)
            }
    }

    func testGoogleCallbackAcceptsAdditionalResponseParameters() throws {
        let state = String(repeating: "s", count: 43)
        let callback = URL(string: "\(client.redirectURI)?state=\(state)&code=4%2Fcode&scope=https%3A%2F%2Fmail.google.com%2F&authuser=0&prompt=consent")!
        XCTAssertEqual(try IOSMailOAuthSession.validate(
            callback: callback, redirectURI: client.redirectURI, expectedState: state), "4/code")
        let unknown = URL(string: "\(client.redirectURI)?state=\(state)&code=4%2Fcode&extra=ignored")!
        XCTAssertEqual(try IOSMailOAuthSession.validate(
            callback: unknown, redirectURI: client.redirectURI, expectedState: state), "4/code")
        let duplicateState = URL(string: "\(client.redirectURI)?state=\(state)&state=\(state)&code=x&scope=a")!
        XCTAssertThrowsError(try IOSMailOAuthSession.validate(
            callback: duplicateState, redirectURI: client.redirectURI, expectedState: state))
    }

    func testMicrosoftAuthorizationUsesExactRegisteredRedirectAndDistinctExchangeScopes() async throws {
        let microsoft = try XCTUnwrap(MicrosoftOAuthPublicClient(
            clientID: "00000000-1111-4222-8333-444444444444",
            redirectURI: "com.plainpost.mail:/oauth/microsoft",
            registeredSchemes: ["com.plainpost.mail"], supportsPersonalAccounts: true))
        let session = IOSMailOAuthSession { url, scheme in
            XCTAssertEqual(scheme, microsoft.callbackScheme)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
            XCTAssertEqual(value("redirect_uri"), microsoft.redirectURI)
            XCTAssertEqual(value("code_challenge_method"), "S256")
            XCTAssertEqual(value("scope"), MicrosoftMailOAuthProvider.consentScope)
            XCTAssertNil(value("client_secret"))
            let state = try XCTUnwrap(value("state"))
            return URL(string: "\(microsoft.redirectURI)?state=\(state)&code=opaque-code")!
        }
        let result = try await session.authorize(client: microsoft, loginHint: "ada@outlook.com")
        XCTAssertEqual(result.code, "opaque-code")
        XCTAssertEqual(result.redirectURI, microsoft.redirectURI)
        XCTAssertFalse(String(reflecting: result).contains("opaque-code"))
    }
}
#endif
