import Foundation
import PlainpostAccountProtocol

/// The production transport blocks redirects. Account bootstrap messages are
/// signed for their exact authority and must never be replayed to a redirect.
public final class URLSessionAccountHTTPTransport: NSObject, AccountHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        session = Self.makeSession(configuration: configuration)
        super.init()
    }
    init(configuration: URLSessionConfiguration) {
        session = Self.makeSession(configuration: configuration)
        super.init()
    }
    private static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: AccountRedirectBlocker.shared, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> AccountHTTPResponse {
        try await send(request, maximumResponseBytes: AccountAPIClient.maximumTransportResponseBytes)
    }
    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> AccountHTTPResponse {
        guard maximumResponseBytes > 0, maximumResponseBytes <= AccountAPIClient.maximumTransportResponseBytes else { throw AccountRuntimeError.transportFailure }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AccountRuntimeError.transportFailure }
            var body = Data()
            body.reserveCapacity(min(maximumResponseBytes, 4 * 1024))
            for try await byte in bytes {
                guard body.count < maximumResponseBytes else { throw AccountRuntimeError.transportFailure }
                body.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { if let key = key as? String, let value = value as? String { headers[key] = value } }
            return AccountHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
        } catch is CancellationError { throw CancellationError() }
        catch { throw AccountRuntimeError.transportFailure }
    }
}

private final class AccountRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AccountRedirectBlocker()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
