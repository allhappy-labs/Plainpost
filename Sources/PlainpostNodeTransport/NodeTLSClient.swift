import Foundation
import PlainpostAccountProtocol

public struct NodeHTTPRequest: Sendable {
    public let endpoint: NodeEndpointURL
    public let method, path: String
    public let body: Data
    public let additionalHeaders: [String: String]
    public init(endpoint: NodeEndpointURL, method: String, path: String, body: Data, additionalHeaders: [String: String] = [:]) {
        self.endpoint = endpoint; self.method = method; self.path = path; self.body = body; self.additionalHeaders = additionalHeaders
    }
}

public struct NodeHTTPResponse: Sendable {
    public let statusCode: Int
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    public init(statusCode: Int, url: URL, headers: [String: String], body: Data) { self.statusCode = statusCode; self.url = url; self.headers = headers; self.body = body }
}

public struct NodeHTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let url: URL
    public let headers: [String: String]
    public let bytes: PlainpostByteStream

    public init(statusCode: Int, url: URL, headers: [String: String], bytes: PlainpostByteStream) {
        self.statusCode = statusCode
        self.url = url
        self.headers = headers
        self.bytes = bytes
    }
}

/// Owns cancellation for one request and completes only after the transport
/// has released that request's resources. The token is deliberately scoped to
/// one operation; it cannot cancel other requests using the same client.
public final class NodeHTTPTransportRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelActions: [@Sendable () -> Void] = []
    private var cancelled = false
    private var cancelActionsInvoked = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func cancelAndWait() async {
        let (actions, alreadyCompleted) = lock.withLock {
            cancelled = true
            let actions: [@Sendable () -> Void]
            if cancelActionsInvoked {
                actions = []
            } else {
                cancelActionsInvoked = true
                actions = cancelActions
            }
            return (actions, completed)
        }
        actions.forEach { $0() }
        if alreadyCompleted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                guard !completed else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
            }
        }
    }

    /// Creates a cancellation boundary for one transport attempt while the
    /// receiver remains the cancellation/completion boundary for the whole
    /// request, including retries.
    func makeChild() -> NodeHTTPTransportRequestCancellation? {
        let child = NodeHTTPTransportRequestCancellation()
        let shouldCancel = lock.withLock {
            guard !cancelled else { return true }
            cancelActions.append { child.cancel() }
            return false
        }
        return shouldCancel ? nil : child
    }

    public func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        cancelActions.append(action)
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { action() }
    }

    private func cancel() {
        let actions: [@Sendable () -> Void] = lock.withLock {
            cancelled = true
            guard !cancelActionsInvoked else { return [] }
            cancelActionsInvoked = true
            return cancelActions
        }
        actions.forEach { $0() }
    }

    func throwIfCancelled() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    var isCancellationRequested: Bool { lock.withLock { cancelled } }

    public func markCompleted() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}

public protocol NodeHTTPTransport: Sendable { func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse }
public protocol NodeHTTPTransportRequestScoped: NodeHTTPTransport {
    func send(_ request: URLRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse
}
public protocol NodeHTTPStreamingTransport: NodeHTTPTransport {
    func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse
}

public final class NodeTLSClient: @unchecked Sendable {
    public static let maximumResponseBytes = 1_048_576
    public static let maximumAttachmentResponseBytes = 50 * 1_048_576
    /// The authenticated request class authorizes the buffered response ceiling.
    /// Keep this shared with retained replay; request body caps are independent.
    public static func maximumBufferedResponseBytes(method: String, path: String) -> Int {
        method == "POST" && path == "/v1/calendar/window" ? 8 * 1_048_576 : maximumResponseBytes
    }
    private let transport: any NodeHTTPTransport
    public init(transport: any NodeHTTPTransport = URLSessionNodeHTTPTransport()) { self.transport = transport }

    public func send(_ request: NodeHTTPRequest, maximumResponseBytes: Int = NodeTLSClient.maximumResponseBytes, onDispatch: @escaping @Sendable () -> Void = {}, cancellation: NodeHTTPTransportRequestCancellation? = nil) async throws -> NodeHTTPResponse {
        guard maximumResponseBytes > 0, maximumResponseBytes <= Self.maximumBufferedResponseBytes(method: request.method, path: request.path) else { throw NodeSessionError.invalidValue }
        let wire = try wireRequest(request)
        onDispatch()
        let response: NodeHTTPResponse
        if let cancellation, let scoped = transport as? any NodeHTTPTransportRequestScoped {
            response = try await scoped.send(wire, maximumResponseBytes: maximumResponseBytes, cancellation: cancellation)
            try cancellation.throwIfCancelled()
        } else {
            defer { cancellation?.markCompleted() }
            response = try await transport.send(wire, maximumResponseBytes: maximumResponseBytes)
        }
        guard response.body.count <= maximumResponseBytes, response.url.scheme == "https", response.url.host == request.endpoint.url.host, response.url.port == request.endpoint.url.port, !(300...399).contains(response.statusCode) else { throw NodeSessionError.invalidValue }
        return response
    }

    public func stream(_ request: NodeHTTPRequest, maximumResponseBytes: Int = NodeTLSClient.maximumAttachmentResponseBytes, onDispatch: @escaping @Sendable () -> Void = {}) async throws -> NodeHTTPStreamResponse {
        guard maximumResponseBytes > 0, maximumResponseBytes <= Self.maximumAttachmentResponseBytes else { throw NodeSessionError.invalidValue }
        guard let streamingTransport = transport as? any NodeHTTPStreamingTransport else { throw NodeSessionError.transportFailure }
        let wire = try wireRequest(request)
        onDispatch()
        let response = try await streamingTransport.stream(wire, maximumResponseBytes: maximumResponseBytes)
        guard response.url.scheme == "https", response.url.host == request.endpoint.url.host, response.url.port == request.endpoint.url.port, !(300...399).contains(response.statusCode) else {
            response.bytes.cancel()
            throw NodeSessionError.invalidValue
        }
        return response
    }

    private func wireRequest(_ request: NodeHTTPRequest) throws -> URLRequest {
        guard ["GET", "POST", "PUT", "DELETE"].contains(request.method), request.path.hasPrefix("/"), !request.path.contains("#"), request.body.count <= NodeSessionLimits.maximumRequestBodyBytes else { throw NodeSessionError.invalidValue }
        guard var components = URLComponents(url: request.endpoint.url, resolvingAgainstBaseURL: false) else { throw NodeSessionError.invalidValue }
        let originForm = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = String(originForm[0])
        components.percentEncodedQuery = originForm.count == 2 ? String(originForm[1]) : nil
        guard let url = components.url, url.scheme == "https", url.host == request.endpoint.url.host, url.port == request.endpoint.url.port else { throw NodeSessionError.invalidValue }
        var wire = URLRequest(url: url); wire.httpMethod = request.method; wire.httpBody = request.body
        wire.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in request.additionalHeaders { wire.setValue(value, forHTTPHeaderField: name) }
        return wire
    }
}

public final class URLSessionNodeHTTPTransport: NSObject, NodeHTTPStreamingTransport, NodeHTTPTransportRequestScoped, @unchecked Sendable {
    private let session: URLSession
    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: NodeRedirectBlocker.shared, delegateQueue: nil)
        super.init()
    }
    public init(configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration, delegate: NodeRedirectBlocker.shared, delegateQueue: nil)
        super.init()
    }
    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        let operation = URLSessionDataTaskRequest(session: session, request: request, maximumResponseBytes: maximumResponseBytes)
        cancellation.install { operation.cancel() }
        defer { cancellation.markCompleted() }
        return try await operation.run()
    }

    public func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let url = http.url else { throw NodeSessionError.invalidValue }
            var body = Data(); body.reserveCapacity(min(maximumResponseBytes, 4096))
            for try await byte in bytes { guard body.count < maximumResponseBytes else { throw NodeSessionError.invalidValue }; body.append(byte) }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { if let key = key as? String, let value = value as? String { headers[key] = value } }
            return NodeHTTPResponse(statusCode: http.statusCode, url: url, headers: headers, body: body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NodeSessionError { throw error }
        catch { throw NodeSessionError.transportFailure }
    }

    public func stream(_ request: URLRequest, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        let bridge = URLSessionStreamBridge()
        let bytes = bridge.start(session: session, request: request, maximumResponseBytes: maximumResponseBytes)
        let metadata = try await bridge.waitForMetadata()
        return NodeHTTPStreamResponse(statusCode: metadata.statusCode, url: metadata.url, headers: metadata.headers, bytes: bytes)
    }
}

/// Callback-backed request used for request-scoped status I/O. Unlike the
/// async URLSession convenience APIs, this retains the exact data task that
/// owns the request and does not resume its caller until URLSession reports
/// that task's terminal callback.
private final class URLSessionDataTaskRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private let request: URLRequest
    private let maximumResponseBytes: Int
    private lazy var task: URLSessionDataTask = session.dataTask(with: request) { [weak self] data, response, error in
        self?.finish(data: data, response: response, error: error)
    }
    private var started = false
    private var cancelled = false
    private var terminalResult: Result<NodeHTTPResponse, Swift.Error>?
    private var continuation: CheckedContinuation<NodeHTTPResponse, Error>?

    init(session: URLSession, request: URLRequest, maximumResponseBytes: Int) {
        self.session = session
        self.request = request
        self.maximumResponseBytes = maximumResponseBytes
    }

    func run() async throws -> NodeHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<NodeHTTPResponse, Swift.Error>? = lock.withLock {
                    self.continuation = continuation
                    if let terminalResult {
                        self.continuation = nil
                        return terminalResult
                    }
                    if !cancelled {
                        started = true
                        task.resume()
                    }
                    return nil
                }
                result.map { continuation.resume(with: $0) }
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldResume = !started
        if shouldResume {
            completeLocked(.failure(CancellationError()))
        }
        lock.unlock()
        if !shouldResume { task.cancel() }
    }

    private func finish(data: Data?, response: URLResponse?, error: Swift.Error?) {
        lock.lock()
        let result: Result<NodeHTTPResponse, Swift.Error>
        if cancelled || (error as NSError?)?.code == NSURLErrorCancelled {
            result = .failure(CancellationError())
        } else if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, let url = http.url, let data {
            guard data.count <= maximumResponseBytes else {
                result = .failure(NodeSessionError.invalidValue)
                completeLocked(result)
                lock.unlock()
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            result = .success(NodeHTTPResponse(statusCode: http.statusCode, url: url, headers: headers, body: data))
        } else {
            result = .failure(NodeSessionError.invalidValue)
        }
        completeLocked(result)
        lock.unlock()
    }

    private func completeLocked(_ result: Result<NodeHTTPResponse, Swift.Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        if let continuation { continuation.resume(with: result) }
    }
}

private final class URLSessionStreamBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var metadataResult: Result<(statusCode: Int, url: URL, headers: [String: String]), Error>?
    private var metadataWaiter: CheckedContinuation<(statusCode: Int, url: URL, headers: [String: String]), Error>?
    private var output: PlainpostByteStream.Producer?

    func start(session: URLSession, request: URLRequest, maximumResponseBytes: Int) -> PlainpostByteStream {
        let stream = PlainpostByteStream(capacity: 2, onCancellation: { [weak self] in self?.cancel() })
        lock.lock()
        output = stream.producer
        let producer = Task { [self] in
            await self.produce(session: session, request: request, maximumResponseBytes: maximumResponseBytes)
        }
        task = producer
        lock.unlock()
        return stream
    }

    func waitForMetadata() async throws -> (statusCode: Int, url: URL, headers: [String: String]) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    cancel()
                    continuation.resume(throwing: CancellationError())
                } else if let metadataResult {
                    lock.unlock()
                    continuation.resume(with: metadataResult)
                } else {
                    metadataWaiter = continuation
                    lock.unlock()
                }
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }

    func cancel() {
        lock.lock()
        let task = task
        let waiter = metadataWaiter
        let output = output
        metadataWaiter = nil
        lock.unlock()
        task?.cancel()
        waiter?.resume(throwing: CancellationError())
        output?.fail(CancellationError())
    }

    private func produce(session: URLSession, request: URLRequest, maximumResponseBytes: Int) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let url = http.url else { throw NodeSessionError.invalidValue }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            finishMetadata(.success((http.statusCode, url, headers)))
            var count = 0
            var chunk = Data()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < maximumResponseBytes else { throw NodeSessionError.invalidValue }
                count += 1
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    guard let output = currentOutput() else { throw CancellationError() }
                    try await output.send(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                guard let output = currentOutput() else { throw CancellationError() }
                try await output.send(chunk)
            }
            finishStream()
        } catch is CancellationError {
            finishMetadata(.failure(CancellationError()))
            finishStream(throwing: CancellationError())
        } catch let error as NodeSessionError {
            finishMetadata(.failure(error))
            finishStream(throwing: error)
        } catch {
            finishMetadata(.failure(NodeSessionError.transportFailure))
            finishStream(throwing: NodeSessionError.transportFailure)
        }
    }

    private func currentOutput() -> PlainpostByteStream.Producer? {
        lock.lock()
        let output = output
        lock.unlock()
        return output
    }

    private func finishStream(throwing error: Error? = nil) {
        lock.lock()
        let output = output
        lock.unlock()
        if let error { output?.fail(error) } else { output?.finish() }
    }

    private func finishMetadata(_ result: Result<(statusCode: Int, url: URL, headers: [String: String]), Error>) {
        lock.lock()
        metadataResult = result
        let waiter = metadataWaiter
        metadataWaiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }
}

private final class NodeRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NodeRedirectBlocker()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
