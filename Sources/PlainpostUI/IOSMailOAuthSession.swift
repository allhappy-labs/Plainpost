#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import PlainpostAccounts
import PlainpostCore
import UIKit

/// Owns one native OAuth browser attempt. Only the returned code and its PKCE
/// verifier leave this type; the callback is never handled by a global URL
/// opener and cannot install a mail credential by itself.
@MainActor
public final class IOSMailOAuthSession {
    public enum Failure: Error, Equatable, Sendable {
        case invalidConfiguration, busy, cancelled, denied, invalidCallback, cannotStart
    }

    public typealias Browser = @MainActor (URL, String) async throws -> URL
    private let browser: Browser
    private var active = false

    public init(browser: Browser? = nil) {
        self.browser = browser ?? Self.openSystemSession
    }

    public func authorize(client: GoogleOAuthPublicClient, loginHint: String) async throws -> GmailAuthorizationCode {
        guard !active else { throw Failure.busy }
        guard loginHint.utf8.count <= 320,
              !loginHint.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.properties.generalCategory == .control
              }) else { throw Failure.invalidConfiguration }
        active = true
        defer { active = false }
        let state = Self.randomURLSafe(), verifier = Self.randomURLSafe()
        let challenge = Self.urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: client.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://mail.google.com/"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if !loginHint.isEmpty {
            components.queryItems?.append(.init(name: "login_hint", value: loginHint))
        }
        guard let url = components.url else { throw Failure.invalidConfiguration }
        let callback: URL
        do { callback = try await browser(url, client.callbackScheme) }
        catch let failure as Failure { throw failure }
        catch is CancellationError { throw Failure.cancelled }
        catch let error where (error as NSError).domain == ASWebAuthenticationSessionErrorDomain
            && (error as NSError).code == 1 {
            throw Failure.cancelled
        }
        catch { throw Failure.cannotStart }
        try Task.checkCancellation()
        let code = try Self.validate(callback: callback, redirectURI: client.redirectURI, expectedState: state)
        return GmailAuthorizationCode(code: code, verifier: verifier, redirectURI: client.redirectURI)
    }

    public func authorize(
        client: MicrosoftOAuthPublicClient, loginHint: String
    ) async throws -> MicrosoftAuthorizationCode {
        guard !active else { throw Failure.busy }
        active = true
        defer { active = false }
        let state = Self.randomURLSafe(), verifier = Self.randomURLSafe()
        let challenge = Self.urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
        let provider = MicrosoftMailOAuthProvider(client: client, http: URLSessionMicrosoftOAuthHTTP())
        let url: URL
        do { url = try provider.authorizationURL(state: state, codeChallenge: challenge, loginHint: loginHint) }
        catch { throw Failure.invalidConfiguration }
        let callback: URL
        do { callback = try await browser(url, client.callbackScheme) }
        catch let failure as Failure { throw failure }
        catch is CancellationError { throw Failure.cancelled }
        catch let error where (error as NSError).domain == ASWebAuthenticationSessionErrorDomain
            && (error as NSError).code == 1 { throw Failure.cancelled }
        catch { throw Failure.cannotStart }
        try Task.checkCancellation()
        let code = try Self.validate(callback: callback, redirectURI: client.redirectURI, expectedState: state)
        return MicrosoftAuthorizationCode(code: code, verifier: verifier, redirectURI: client.redirectURI)
    }

    public static func validate(callback: URL, redirectURI: String, expectedState: String) throws -> String {
        guard let expected = URLComponents(string: redirectURI),
              let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              returned.scheme == expected.scheme, returned.host == expected.host,
              returned.path == expected.path, returned.port == nil,
              returned.user == nil, returned.password == nil, returned.fragment == nil,
              let items = returned.queryItems, items.count <= 16,
              items.reduce(0, { $0 + $1.name.utf8.count + ($1.value?.utf8.count ?? 0) }) <= 16 * 1024
        else { throw Failure.invalidCallback }
        let state = items.filter { $0.name == "state" }
        guard state.count == 1, let receivedState = state.first?.value,
              Self.constantTimeEqual(receivedState, expectedState) else { throw Failure.invalidCallback }
        let errors = items.filter { $0.name == "error" }
        guard errors.count <= 1 else { throw Failure.invalidCallback }
        if let error = errors.first {
            guard error.value == "access_denied", items.filter({ $0.name == "code" }).isEmpty
            else { throw Failure.invalidCallback }
            throw Failure.denied
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value,
              !code.isEmpty, code.utf8.count <= 16 * 1024,
              !code.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.properties.generalCategory == .control
              })
        else { throw Failure.invalidCallback }
        return code
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var different: UInt8 = 0
        for index in left.indices { different |= left[index] ^ right[index] }
        return different == 0
    }

    private static func randomURLSafe() -> String {
        urlSafe(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func openSystemSession(url: URL, scheme: String) async throws -> URL {
        let context = IOSMailOAuthPresentationContext()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            context.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                Task { @MainActor in
                    if let callback { context.finish(.success(callback)) }
                    else { context.finish(.failure(error ?? Failure.invalidCallback)) }
                }
            }
            session.presentationContextProvider = context
            context.session = session
            guard session.start() else {
                context.finish(.failure(Failure.cannotStart))
                return
            }
          }
        } onCancel: {
            Task { @MainActor in
                context.session?.cancel()
                context.finish(.failure(Failure.cancelled))
            }
        }
    }
}

@MainActor
private final class IOSMailOAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    var session: ASWebAuthenticationSession?
    var continuation: CheckedContinuation<URL, Error>?

    func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
}
#endif
