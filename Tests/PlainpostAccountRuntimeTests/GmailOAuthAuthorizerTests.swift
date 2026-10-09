import CryptoKit
import XCTest
import PlainpostCore
@testable import PlainpostAccountRuntime

@MainActor
final class GmailOAuthAuthorizerTests: XCTestCase {
    func testAuthorizationURLRequestsOnlyMailScopeWithPKCEAndMailLoopbackPath() throws {
        let url = GmailOAuthAuthorizer.authorizationURL(clientID: "123-desktop.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:53123/oauth/mail/google", state: "s", verifier: String(repeating: "v", count: 43), loginHint: "ada@example.test")
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["scope"], "https://mail.google.com/")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:53123/oauth/mail/google")
        XCTAssertNil(items["client_secret"])
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertEqual(items["login_hint"], "ada@example.test")
        XCTAssertEqual(items["state"], "s")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
    }

    func testPlusAddressedLoginHintIsPercentEncoded() throws {
        let url = GmailOAuthAuthorizer.authorizationURL(clientID: "id", redirectURI: "http://127.0.0.1:1/oauth/mail/google",
                                                        state: "s", verifier: "v", loginHint: "ada+mail@example.test")
        XCTAssertTrue(url.absoluteString.contains("login_hint=ada%2Bmail@example.test"), url.absoluteString)
    }

    func testMailReceiverRejectsCalendarPath() async throws {
        let receiver = CalendarLoopbackReceiver(expectedState: "state-1", callbackPath: CalendarLoopbackReceiver.mailCallbackPath, timeout: 5)
        let port = try await receiver.start()
        let (_, calendar) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth/calendar/google?state=state-1&code=c")))
        XCTAssertEqual((calendar as? HTTPURLResponse)?.statusCode, 404)
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth/mail/google?state=state-1&code=abc")))
        let code = try await receiver.callback()
        XCTAssertEqual(code, "abc")
    }

    func testCalendarReceiverStillRejectsMailPathAndUnknownPathsCannotStart() async throws {
        let calendar = CalendarLoopbackReceiver(expectedState: "state-1", timeout: 5)
        XCTAssertEqual(calendar.callbackPath, "/oauth/calendar/google")
        let port = try await calendar.start()
        let (_, mail) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/oauth/mail/google?state=state-1&code=c")))
        XCTAssertEqual((mail as? HTTPURLResponse)?.statusCode, 404)
        calendar.cancel()

        let arbitrary = CalendarLoopbackReceiver(expectedState: "state-1", callbackPath: "/anything", timeout: 5)
        do { _ = try await arbitrary.start(); XCTFail("arbitrary callback path started") } catch {
            XCTAssertEqual(error as? CalendarLoopbackReceiver.Failure, .cannotStart)
        }
    }

    func testAuthorizeReturnsRedactedCodeWithVerifierAndExactRedirect() async throws {
        let opened = OpenedMailURLs()
        let authorizer = GmailOAuthAuthorizer(clientID: "123-desktop.apps.googleusercontent.com", timeout: 30) { url in
            opened.urls.append(url); return true
        }
        let authorizing = Task { try await authorizer.authorize(loginHint: "ada@example.test") }
        let url = try await waitForOpenedURL { opened.urls.first }
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        let redirect = try XCTUnwrap(items["redirect_uri"])
        let port = try XCTUnwrap(URLComponents(string: redirect)?.port)
        XCTAssertEqual(redirect, "http://127.0.0.1:\(port)/oauth/mail/google")
        XCTAssertTrue(authorizer.hasPendingAuthorization)
        let state = try XCTUnwrap(items["state"])
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "\(redirect)?state=\(state)&code=4%2Fmail-code")))

        let code = try await authorizing.value

        XCTAssertEqual(code.code, "4/mail-code")
        XCTAssertEqual(code.redirectURI, redirect)
        let challenge = Data(SHA256.hash(data: Data(code.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(items["code_challenge"], challenge)
        XCTAssertGreaterThanOrEqual(code.verifier.count, 43)
        XCTAssertFalse(String(describing: code).contains("mail-code"))
        XCTAssertFalse(String(describing: code).contains(code.verifier))
        XCTAssertFalse(authorizer.hasPendingAuthorization)
    }

    func testDenialTimeoutCancelAndInvalidConfiguration() async throws {
        let opened = OpenedMailURLs()
        let denied = GmailOAuthAuthorizer(clientID: "desktop-client", timeout: 30) { url in opened.urls.append(url); return true }
        let denying = Task { try await denied.authorize(loginHint: "ada@example.test") }
        let url = try await waitForOpenedURL { opened.urls.first }
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        let redirect = try XCTUnwrap(items["redirect_uri"])
        _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "\(redirect)?error=access_denied&state=\(items["state"] ?? "")")))
        do { _ = try await denying.value; XCTFail("denial returned") } catch { XCTAssertEqual(error as? GmailOAuthAuthorizer.Error, .denied) }

        let timed = GmailOAuthAuthorizer(clientID: "desktop-client", timeout: 0.3) { _ in true }
        do { _ = try await timed.authorize(loginHint: "ada@example.test"); XCTFail("timeout returned") } catch {
            XCTAssertEqual(error as? GmailOAuthAuthorizer.Error, .timedOut)
        }

        opened.urls = []
        let cancelled = GmailOAuthAuthorizer(clientID: "desktop-client", timeout: 30) { url in opened.urls.append(url); return true }
        let cancelling = Task { try await cancelled.authorize(loginHint: "ada@example.test") }
        _ = try await waitForOpenedURL { opened.urls.first }
        cancelled.cancel()
        do { _ = try await cancelling.value; XCTFail("cancel returned") } catch { XCTAssertEqual(error as? GmailOAuthAuthorizer.Error, .cancelled) }

        for (client, hint) in [("", "ada@example.test"), ("bad client", "ada@example.test"), ("desktop-client", ""), ("desktop-client", "a b")] {
            let invalid = GmailOAuthAuthorizer(clientID: client, timeout: 30) { _ in XCTFail("opened a browser"); return true }
            do { _ = try await invalid.authorize(loginHint: hint); XCTFail("invalid configuration started") } catch {
                XCTAssertEqual(error as? GmailOAuthAuthorizer.Error, .invalidConfiguration)
            }
        }
        let unopenable = GmailOAuthAuthorizer(clientID: "desktop-client", timeout: 30) { _ in false }
        do { _ = try await unopenable.authorize(loginHint: "ada@example.test"); XCTFail("unopenable browser started") } catch {
            XCTAssertEqual(error as? GmailOAuthAuthorizer.Error, .cannotStart)
        }
    }

    private func waitForOpenedURL(_ read: @MainActor () -> URL?) async throws -> URL {
        for _ in 0..<300 {
            if let url = read() { return url }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("browser was never opened")
        throw URLError(.timedOut)
    }
}

@MainActor private final class OpenedMailURLs {
    var urls: [URL] = []
}
