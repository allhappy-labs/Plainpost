import CryptoKit
import Foundation
import PlainpostCore

/// Google sign-in for Gmail on the Mac: Desktop-app client, PKCE S256 and an
/// RFC 8252 loopback redirect on `http://127.0.0.1:<port>/oauth/mail/google`.
///
/// The consent page opens in the user's default browser (Google refuses
/// embedded web views for loopback clients). The authorizer only captures the
/// authorization code; it never exchanges it and never sees the client secret.
@MainActor
public final class GmailOAuthAuthorizer {
    public static let scope = "https://mail.google.com/"

    public enum Error: Swift.Error, Equatable { case invalidConfiguration, invalidCallback, denied, cancelled, cannotStart, timedOut }

    public static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(CalendarLoopbackReceiver.mailCallbackPath)"
    }

    private let clientID: String
    private let timeout: TimeInterval
    private let openBrowser: @MainActor (URL) -> Bool
    private var receiver: CalendarLoopbackReceiver?
    public var hasPendingAuthorization: Bool { receiver != nil }

    public init(clientID: String, timeout: TimeInterval = CalendarLoopbackReceiver.defaultTimeout, openBrowser: @escaping @MainActor (URL) -> Bool) {
        self.clientID = clientID
        self.timeout = timeout
        self.openBrowser = openBrowser
    }

    /// Opens Google consent for `loginHint` and returns the captured code.
    /// Starting a new authorization cancels any pending one.
    public func authorize(loginHint: String) async throws -> GmailAuthorizationCode {
        cancel()
        guard Self.validClientID(clientID), Self.validLoginHint(loginHint) else { throw Error.invalidConfiguration }
        let state = Self.random(), verifier = Self.random()
        let receiver = CalendarLoopbackReceiver(
            expectedState: state, callbackPath: CalendarLoopbackReceiver.mailCallbackPath, timeout: timeout)
        self.receiver = receiver
        defer {
            receiver.cancel()
            if self.receiver === receiver { self.receiver = nil }
        }
        return try await withTaskCancellationHandler {
            do {
                let port = try await receiver.start()
                try Task.checkCancellation()
                let redirectURI = Self.redirectURI(port: port)
                let url = Self.authorizationURL(
                    clientID: clientID, redirectURI: redirectURI, state: state, verifier: verifier, loginHint: loginHint)
                guard openBrowser(url) else { throw Error.cannotStart }
                let code = try await receiver.callback()
                return GmailAuthorizationCode(code: code, verifier: verifier, redirectURI: redirectURI)
            } catch let failure as CalendarLoopbackReceiver.Failure {
                throw Self.map(failure)
            } catch is CancellationError {
                throw Error.cancelled
            }
        } onCancel: {
            receiver.cancel()
        }
    }

    /// Stops a pending authorization; its `authorize` call throws `cancelled`.
    public func cancel() {
        receiver?.cancel()
        receiver = nil
    }

    static func authorizationURL(clientID: String, redirectURI: String, state: String, verifier: String, loginHint: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "login_hint", value: loginHint), .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))),
        ]
        // URLComponents leaves "+" unescaped in queries, which a form decoder
        // would read as a space (for example in a plus-addressed login hint).
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }

    static func validClientID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
    }

    static func validLoginHint(_ hint: String) -> Bool {
        !hint.isEmpty && hint.utf8.count <= 320 && !hint.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
    }

    private static func map(_ failure: CalendarLoopbackReceiver.Failure) -> Error {
        switch failure {
        case .cannotStart: .cannotStart
        case .invalidCallback: .invalidCallback
        case .denied: .denied
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }

    private static func random() -> String { urlSafe(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
