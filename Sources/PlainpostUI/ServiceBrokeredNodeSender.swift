import Foundation
import PlainpostAccountRuntime
import PlainpostNodeTransport
import PlainpostServiceIPC

/// The Mac app's Node session sender after activation. It never holds the
/// session transport, the device key or the Node endpoint: each request goes
/// to `PlainpostService`, whose `NodeSessionBroker` signs, sequences and sends
/// it, and only the Node's response bytes come back.
public struct ServiceBrokeredNodeSender: NodeSessionRequestSending, NodePendingRequestReconciling {
    /// Stands in for the Node URL, which stays inside the service.
    static let responseURL = URL(string: "plainpost-service-broker:/")!

    private let serviceClient: any PlainpostServiceClientProtocol
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(serviceClient: any PlainpostServiceClientProtocol) {
        self.init(serviceClient: serviceClient, sleep: { try await Task.sleep(for: $0) })
    }

    init(serviceClient: any PlainpostServiceClientProtocol, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.serviceClient = serviceClient
        self.sleep = sleep
    }

    public func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let request: PlainpostNodeSessionRequest
        do {
            request = try PlainpostNodeSessionRequest(method: method, path: path, body: body)
        } catch {
            throw NodeSessionError.invalidValue
        }
        let response: PlainpostNodeSessionResponse
        do {
            response = try await serviceClient.performNodeSessionRequest(request)
        } catch let error as PlainpostServiceClientError {
            throw Self.sessionError(for: error, method: method)
        }
        guard response.body.count <= maximumResponseBytes else { throw NodeSessionError.invalidValue }
        return NodeHTTPResponse(statusCode: response.statusCode, url: Self.responseURL, headers: response.headers, body: response.body)
    }

    /// The service broker settles a retained ambiguous request before its next
    /// send and never hands another caller's replay to the app, so there is
    /// nothing for the app to reconcile.
    public func reconcilePendingRequest() async throws -> NodeHTTPResponse? { nil }

    /// Confirms that the service reaches the Node with an authenticated read.
    /// A Node that was just activated may take a moment to start answering;
    /// transport failures are retried, a missing session is not.
    public func verifyConnection(maximumAttempts: Int = 20, delay: Duration = .milliseconds(250)) async throws {
        var lastError: Error = NodeSessionError.transportFailure
        for attempt in 0 ..< max(1, maximumAttempts) {
            do {
                let response = try await send(method: "GET", path: "/v1/status", body: Data(), maximumResponseBytes: NodeTLSClient.maximumResponseBytes)
                guard (200...299).contains(response.statusCode) else { throw NodeSessionError.transportFailure }
                _ = try NodeSyncCodec.decodeStatusResult(response.body)
                return
            } catch let error as PlainpostServiceClientError {
                throw error
            } catch {
                lastError = error
            }
            if attempt + 1 < maximumAttempts { try await sleep(delay) }
        }
        throw lastError
    }

    static func sessionError(for error: PlainpostServiceClientError, method: String) -> Error {
        switch error {
        case .nodeSession(let failure):
            switch failure {
            case .invalidValue: return NodeSessionError.invalidValue
            case .authenticationRejected: return NodeSessionError.authenticationRejected
            case .transportFailure: return NodeSessionError.transportFailure
            case .transportFailureAfterDispatch: return NodeSessionError.transportFailureAfterDispatch
            case .transportCancellationAfterDispatch: return NodeSessionError.transportCancellationAfterDispatch
            case .applicationResultUncertain: return NodeSessionError.applicationResultUncertain
            case .noActiveSession, .noEnrolledNode, .pathNotAllowed, .unavailable, .notAdmitted, .readOnly: return error
            }
        case .timedOut, .serviceUnavailable:
            // The service may already have sent the request. Only a
            // body-free read can be treated as not sent.
            return method == "GET" ? NodeSessionError.transportFailure : NodeSessionError.transportFailureAfterDispatch
        case .invalidRequest:
            return NodeSessionError.invalidValue
        default:
            return NodeSessionError.transportFailure
        }
    }
}
