import CryptoKit
import Foundation
import PlainpostNodeTransport

/// Calendar authorization is independent of Gmail and never exchanges a code
/// locally. It uses the Sync Node's Google "Desktop app" client with an RFC 8252
/// loopback redirect: the consent page opens in the user's default browser and
/// a one-shot `127.0.0.1` receiver collects the code. The code, PKCE verifier
/// and exact redirect URI go to the Node, which holds the client secret.
@MainActor
public final class CalendarOAuthSession {
    public static let scopes = "https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events"

    public enum Error: Swift.Error, Equatable { case invalidConfiguration, invalidCallback, denied, cancelled, cannotStart, timedOut }

    /// The only redirect shape the Node accepts for calendar consent.
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(CalendarLoopbackReceiver.callbackPath)" }

    private let clientID: String
    private let timeout: TimeInterval
    private let openBrowser: @MainActor (URL) -> Bool
    private var receiver: CalendarLoopbackReceiver?
    public var hasPendingAuthorization: Bool { receiver != nil }

    /// `openBrowser` opens the authorization URL outside the app (the default
    /// browser); Google refuses embedded web views for loopback clients.
    public init(clientID: String, timeout: TimeInterval = CalendarLoopbackReceiver.defaultTimeout, openBrowser: @escaping @MainActor (URL) -> Bool) {
        self.clientID = clientID
        self.timeout = timeout
        self.openBrowser = openBrowser
    }

    public func authorize() async throws -> NodeCalendarGoogleConfiguration {
        cancel()
        guard Self.validClientID(clientID) else { throw Error.invalidConfiguration }
        let state = Self.random(), verifier = Self.random()
        let receiver = CalendarLoopbackReceiver(expectedState: state, timeout: timeout)
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
                guard openBrowser(Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state, verifier: verifier)) else { throw Error.cannotStart }
                let code = try await receiver.callback()
                return .init(authorizationCode: code, codeVerifier: verifier, clientID: clientID, redirectURI: redirectURI)
            } catch let failure as CalendarLoopbackReceiver.Failure {
                throw Self.map(failure)
            } catch is CancellationError {
                throw Error.cancelled
            }
        } onCancel: {
            receiver.cancel()
        }
    }

    public func cancel() {
        receiver?.cancel()
        receiver = nil
    }

    static func authorizationURL(clientID: String, redirectURI: String, state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: urlSafe(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        return url.url!
    }

    static func validClientID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
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
    private static func urlSafe(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
