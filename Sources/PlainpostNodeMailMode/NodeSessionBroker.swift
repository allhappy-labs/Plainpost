import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostNodeTransport
import PlainpostServiceIPC

public enum NodeSessionBrokerError: Error, Equatable, Sendable {
    /// No active account session or no existing device identity is readable.
    case noActiveSession
    /// The account trusts no Sync Node, or this Mac holds no private session for it.
    case noEnrolledNode
    /// The app asked for a route only the service may use.
    case pathNotAllowed
    /// The session could not be resolved, or was invalidated under a caller.
    case unavailable
    /// The session exists but is not admitted: its access token expired and
    /// no verified offline lease covers now, Central refused it, the account
    /// is suspended, or it is being deleted.
    case notAdmitted
    /// Lease-only admission is read-only; this request would change state.
    case readOnly
}

public enum NodeSessionCaller: Sendable {
    case app
    case service
}

/// The only process-wide owner of the Mac's `NodeSessionTransport`.
///
/// The transport keeps one pending reservation per endpoint reference and
/// keeps generic replay bodies in process memory, so two owners (the app and
/// the service, or two service components) could strand or duplicate a
/// sequence. Every send, from service components through `client()` and from
/// the app through `proxy(_:caller:)`, runs in this broker's single lane.
///
/// Every lane operation first re-reads the local session check: the
/// admission (read-write, read-only lease, or refused) and the trusted-Node
/// binding. A changed binding re-resolves the transport, so a Node replaced
/// from another device or an activation resumed by the app never keeps the
/// old session alive, whether or not the app invalidated the broker.
public actor NodeSessionBroker {
    public typealias SenderResolver = @Sendable () async throws -> (nodeID: String, sender: any NodeSessionRequestSending & NodePendingRequestReconciling)
    /// A local, synchronous Keychain check. It is synchronous so mutation
    /// signing, which cannot await, sees the current admission and binding.
    public typealias SessionCheck = @Sendable () throws -> NodeSessionCheck
    public typealias IdentityReadinessProvider = @Sendable () async -> PlainpostNodeSessionIdentityReadiness

    private struct AppRoute {
        let method: String?
        let path: String
        let isFamilyPrefix: Bool
    }

    /// Method-and-route rules for app traffic. Mail writes, provider
    /// credential imports and mirror traffic originate only in the service.
    private static let appRoutes: [AppRoute] = [
        AppRoute(method: "GET", path: "/v1/status", isFamilyPrefix: false),
        AppRoute(method: "GET", path: "/v1/mail/capabilities", isFamilyPrefix: false),
        AppRoute(method: "GET", path: "/v1/mail/accounts", isFamilyPrefix: false),
        AppRoute(method: "GET", path: "/v1/mailboxes/assignments", isFamilyPrefix: false),
        AppRoute(method: nil, path: "/v1/calendar/", isFamilyPrefix: true),
        AppRoute(method: "POST", path: "/v1/operations/backup", isFamilyPrefix: false),
        AppRoute(method: "POST", path: "/v1/operations/erase", isFamilyPrefix: false),
        AppRoute(method: "POST", path: "/v1/notifications/policy/read", isFamilyPrefix: false),
        AppRoute(method: "PUT", path: "/v1/notifications/policy", isFamilyPrefix: false),
    ]

    /// The app allowlist's routes (exact, except the `/v1/calendar/` family).
    public static let appAllowedPaths: [String] = appRoutes.map(\.path)

    private struct Resolved {
        let nodeID: String
        let sender: any NodeSessionRequestSending & NodePendingRequestReconciling
        let generation: UInt64
        let binding: String?
    }

    private let resolveSender: SenderResolver
    nonisolated let check: SessionCheck

    /// The admission from the local session check (no Node request), or nil
    /// when the check fails (no session, not admitted).
    public nonisolated func currentAdmissionHint() -> NodeSessionAdmission? {
        try? check().admission
    }
    private let readiness: IdentityReadinessProvider
    /// When the lane was acquired and when the Node last answered.
    public nonisolated let activity = NodeLaneActivity()
    private lazy var lane = BrokerLane(activity: activity)
    nonisolated let generation = BrokerGeneration()
    private var resolved: Resolved?

    public init(resolveSender: @escaping SenderResolver) {
        self.init(resolveSender: resolveSender, identityReadiness: { .ready })
    }

    public init(resolveSender: @escaping SenderResolver, identityReadiness: @escaping IdentityReadinessProvider) {
        self.init(resolveSender: resolveSender, check: { NodeSessionCheck(admission: .readWrite, binding: nil) }, identityReadiness: identityReadiness)
    }

    public init(resolveSender: @escaping SenderResolver, check: @escaping SessionCheck) {
        self.init(resolveSender: resolveSender, check: check, identityReadiness: { .ready })
    }

    public init(resolveSender: @escaping SenderResolver, check: @escaping SessionCheck, identityReadiness: @escaping IdentityReadinessProvider) {
        self.resolveSender = resolveSender
        self.check = check
        self.readiness = identityReadiness
    }

    /// A Node sync client for service components (mirror, router,
    /// supervisor). Every request it makes runs in the broker's lane and is
    /// admitted again. After `invalidate()` or a binding change the returned
    /// client fails closed; call again.
    public func client() async throws -> (nodeID: String, client: NodeSyncClient) {
        let session = try await sessionSender()
        return (session.nodeID, NodeSyncClient(sender: session.sender))
    }

    /// iOS uses a brokered client for optional Node mail attachment.
    public func nodeClient() async throws -> (nodeID: String, client: NodeSyncClient) {
        try await client()
    }

    /// A current presentation hint; each request still checks admission.
    public func currentAdmission() throws -> NodeSessionAdmission {
        try check().admission
    }

    /// The lane-bound sender behind `client()`.
    func sessionSender() async throws -> (nodeID: String, sender: any NodeSessionRequestSending & NodeMutationOperationSigning) {
        let current = try await lane.run { () -> Resolved in
            let check = try await self.admitLocked()
            return try await self.resolveLocked(check)
        }
        return (current.nodeID, BrokeredSessionSender(broker: self, sender: current.sender, generation: current.generation, binding: current.binding))
    }

    /// Sends one Node session request and relays the Node's response bytes.
    /// App requests are limited to `appAllowedPaths`, and to GET while the
    /// session is admitted only by its offline lease. A retained ambiguous
    /// request is settled before the new request reserves a sequence.
    public func proxy(_ request: PlainpostNodeSessionRequest, caller: NodeSessionCaller) async throws -> PlainpostNodeSessionResponse {
        if caller == .app {
            guard Self.appAllows(method: request.method, path: request.path) else { throw NodeSessionBrokerError.pathNotAllowed }
        }
        let response = try await lane.run { () -> NodeHTTPResponse in
            let check = try await self.admitLocked()
            if case .readOnly = check.admission {
                let permitted = caller == .app
                    ? request.method == "GET"
                    : NodeSessionAdmissionPolicy.permitsReadOnly(method: request.method, path: request.path)
                guard permitted else { throw NodeSessionBrokerError.readOnly }
            }
            let current = try await self.resolveLocked(check)
            let generation = self.generation
            return try await self.dropOnRejection(current.generation) {
                _ = try await current.sender.reconcilePendingRequest()
                // The reconcile await may have raced an invalidation; never
                // send on a session that is no longer current.
                guard generation.value == current.generation else { throw NodeSessionBrokerError.unavailable }
                let afterReconciliation = try self.check()
                guard afterReconciliation.binding == check.binding else { throw NodeSessionBrokerError.unavailable }
                if case .readOnly = afterReconciliation.admission {
                    let permitted = caller == .app
                        ? request.method == "GET"
                        : NodeSessionAdmissionPolicy.permitsReadOnly(method: request.method, path: request.path)
                    guard permitted else { throw NodeSessionBrokerError.readOnly }
                }
                do {
                    return try await current.sender.send(
                        method: request.method,
                        path: request.path,
                        body: request.body,
                        maximumResponseBytes: NodeTLSClient.maximumBufferedResponseBytes(method: request.method, path: request.path)
                    )
                } catch let error as NodeSessionError where error == .transportFailureAfterDispatch {
                    // The retained request is this caller's own (same lane
                    // slot): replay it now and return its real result.
                    return try await Self.replayOwnRequest(current.sender, path: request.path, fallback: error)
                }
            }
        }
        return try Self.relay(response)
    }

    /// Drops the resolved session. The next request resolves again from the
    /// shared Keychain group; clients handed out earlier fail closed.
    public func invalidate() {
        resolved = nil
        generation.advance()
    }

    public func identityReadiness() async -> PlainpostNodeSessionIdentityReadiness {
        await readiness()
    }

    /// The typed XPC failure for an error thrown by this broker or its transport.
    public nonisolated static func failure(for error: Error) -> PlainpostNodeSessionFailure {
        switch error {
        case let error as NodeSessionBrokerError:
            switch error {
            case .noActiveSession: return .noActiveSession
            case .noEnrolledNode: return .noEnrolledNode
            case .pathNotAllowed: return .pathNotAllowed
            case .unavailable: return .unavailable
            case .notAdmitted: return .notAdmitted
            case .readOnly: return .readOnly
            }
        case let error as NodeSessionError:
            switch error {
            case .invalidValue: return .invalidValue
            case .authenticationRejected: return .authenticationRejected
            case .transportFailure: return .transportFailure
            case .transportFailureAfterDispatch: return .transportFailureAfterDispatch
            case .transportCancellationAfterDispatch: return .transportCancellationAfterDispatch
            case .applicationResultUncertain: return .applicationResultUncertain
            }
        default:
            return .unavailable
        }
    }

    static func appAllows(method: String, path: String) -> Bool {
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        guard route.hasPrefix("/"), !route.contains("%") else { return false }
        let segments = route.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.dropLast().contains(where: { $0.isEmpty }), !segments.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return appRoutes.contains { rule in
            if let required = rule.method, required != method { return false }
            if rule.isFamilyPrefix { return route.hasPrefix(rule.path) && route.count > rule.path.count && !route.hasSuffix("/") }
            return route == rule.path
        }
    }

    // MARK: - Lane-internal operations

    fileprivate func serializedSend(generation expected: UInt64, method: String, path: String, reconcile: @escaping @Sendable () async throws -> Void, _ operation: @escaping @Sendable () async throws -> NodeHTTPResponse) async throws -> NodeHTTPResponse {
        let activity = self.activity
        return try await lane.run {
            try await self.admitCurrent(expected, method: method, path: path)
            try await self.dropOnRejection(expected, reconcile)
            try await self.admitCurrent(expected, method: method, path: path)
            let response = try await self.dropOnRejection(expected, operation)
            try await self.admitCurrent(expected, method: method, path: path)
            activity.recordResponse(statusCode: response.statusCode)
            return response
        }
    }

    fileprivate func serializedStream(generation expected: UInt64, method: String, path: String, reconcile: @escaping @Sendable () async throws -> Void, _ operation: @escaping @Sendable () async throws -> NodeHTTPStreamResponse) async throws -> NodeHTTPStreamResponse {
        let activity = self.activity
        return try await lane.run {
            try await self.admitCurrent(expected, method: method, path: path)
            try await self.dropOnRejection(expected, reconcile)
            try await self.admitCurrent(expected, method: method, path: path)
            let response = try await self.dropOnRejection(expected, operation)
            try await self.admitCurrent(expected, method: method, path: path)
            activity.recordResponse(statusCode: response.statusCode)
            return response
        }
    }

    /// Replays only the exact request already retained, so a read-only
    /// session may still settle it.
    fileprivate func serializedReconcile(generation expected: UInt64, _ operation: @escaping @Sendable () async throws -> NodeHTTPResponse?) async throws -> NodeHTTPResponse? {
        try await lane.run {
            try await self.admitCurrent(expected, method: nil, path: nil)
            let response = try await self.dropOnRejection(expected, operation)
            try await self.admitCurrent(expected, method: nil, path: nil)
            return response
        }
    }

    /// Admits a handed-out client's request: the session must still be
    /// admitted, bound to the same Node, and read-write unless the route reads.
    private func admitCurrent(_ expected: UInt64, method: String?, path: String?) async throws {
        let check = try await admitLocked()
        guard generation.value == expected else { throw NodeSessionBrokerError.unavailable }
        if let resolved, resolved.generation == expected, resolved.binding != check.binding {
            invalidate()
            throw NodeSessionBrokerError.unavailable
        }
        if case .readOnly = check.admission, let method, let path,
           !NodeSessionAdmissionPolicy.permitsReadOnly(method: method, path: path) {
            throw NodeSessionBrokerError.readOnly
        }
    }

    private func admitLocked() async throws -> NodeSessionCheck {
        do {
            return try check()
        } catch {
            switch error {
            case let error as NodeSessionBrokerError: throw error
            case is CancellationError: throw CancellationError()
            default: throw NodeSessionBrokerError.notAdmitted
            }
        }
    }

    private func resolveLocked(_ check: NodeSessionCheck) async throws -> Resolved {
        if let resolved, resolved.generation == generation.value {
            if resolved.binding == check.binding { return resolved }
            // Another trusted Node, epoch or account session: the cached
            // transport belongs to the old binding.
            invalidate()
        }
        let expected = generation.value
        let value: (nodeID: String, sender: any NodeSessionRequestSending & NodePendingRequestReconciling)
        do {
            value = try await resolveSender()
        } catch let error as NodeSessionBrokerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NodeSessionBrokerError.unavailable
        }
        guard generation.value == expected, !value.nodeID.isEmpty else { throw NodeSessionBrokerError.unavailable }
        guard check.binding == (try await admitLocked()).binding else { throw NodeSessionBrokerError.unavailable }
        let current = Resolved(nodeID: value.nodeID, sender: value.sender, generation: expected, binding: check.binding)
        resolved = current
        return current
    }

    /// A Node that rejects the session's signature has moved to another
    /// trust epoch (or forgot this device): drop the transport so the next
    /// request resolves the current one.
    private func dropOnRejection<T: Sendable>(_ expected: UInt64, _ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as NodeSessionError where error == .authenticationRejected {
            if generation.value == expected { invalidate() }
            throw error
        }
    }

    private static func replayOwnRequest(_ sender: any NodePendingRequestReconciling, path: String, fallback: NodeSessionError) async throws -> NodeHTTPResponse {
        do {
            // Only this caller's own request may answer it; anything else
            // retained on the session is settled but never returned.
            if let replayed = try await sender.reconcilePendingRequest(), replayed.url.path == route(path) { return replayed }
        } catch let error as NodeSessionError where error == .authenticationRejected {
            throw error
        } catch is CancellationError {
            throw NodeSessionError.transportCancellationAfterDispatch
        } catch {}
        throw fallback
    }

    private static func route(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
    }

    private static func relay(_ response: NodeHTTPResponse) throws -> PlainpostNodeSessionResponse {
        var headers: [String: String] = [:]
        for key in response.headers.keys.sorted() where headers.count < PlainpostNodeSessionLimits.maximumResponseHeaderCount {
            guard let value = response.headers[key],
                  !key.isEmpty,
                  key.utf8.count <= PlainpostNodeSessionLimits.maximumResponseHeaderFieldBytes,
                  value.utf8.count <= PlainpostNodeSessionLimits.maximumResponseHeaderFieldBytes else { continue }
            headers[key] = value
        }
        do {
            return try PlainpostNodeSessionResponse(statusCode: response.statusCode, headers: headers, body: response.body)
        } catch {
            throw NodeSessionError.transportFailureAfterDispatch
        }
    }
}

extension NodeSessionBroker {
    /// The production broker. It reads the account session, the existing
    /// device identity and the trust state from the shared Keychain group,
    /// never creates an identity and never refreshes Central credentials.
    public static func production(
        credentials: AccountCredentialStore,
        configurationStore: KeychainCentralServerConfigurationStore,
        endpointStore: SyncNodeEndpointStore
    ) -> NodeSessionBroker {
        production(
            credentials: credentials,
            endpointStore: endpointStore,
            leaseVerifier: NodeSessionAdmissionPolicy.persistedLeaseVerifier(),
            remote: { boundEndpointRemote(credentials: credentials, configurationStore: configurationStore) },
            clock: Date.init
        )
    }

    static func production(
        credentials: AccountCredentialStore,
        endpointStore: SyncNodeEndpointStore,
        leaseVerifier: @escaping NodeSessionAdmissionPolicy.LeaseVerifier,
        remote: @escaping @Sendable () -> (any SyncNodeEndpointMetadataRemote)?,
        clock: @escaping @Sendable () -> Date
    ) -> NodeSessionBroker {
        let refusals = NodeSessionRefusals()
        let check: SessionCheck = {
            try productionCheck(credentials: credentials, leaseVerifier: leaseVerifier, refusals: refusals, now: clock())
        }
        return NodeSessionBroker(
            resolveSender: {
                let admission = try productionCheck(credentials: credentials, leaseVerifier: leaseVerifier, refusals: refusals, now: clock()).admission
                return try await resolveProductionSender(credentials: credentials, admission: admission, remote: remote(), endpointStore: endpointStore, refusals: refusals)
            },
            check: check,
            identityReadiness: {
                productionIdentityReadiness(credentials: credentials)
            }
        )
    }

    static func productionIdentityReadiness(credentials: AccountCredentialStore) -> PlainpostNodeSessionIdentityReadiness {
        do {
            guard let session = try credentials.loadSession(),
                  session.state == .active,
                  session.credentials != nil,
                  try credentials.loadExistingDeviceIdentity() != nil else { return .noSession }
            return .ready
        } catch {
            return .noSession
        }
    }

    /// The per-operation local check: no deletion in progress, an active
    /// session admitted by token or verified lease, and the trusted-Node
    /// binding from the persisted trust head.
    static func productionCheck(
        credentials: AccountCredentialStore,
        leaseVerifier: NodeSessionAdmissionPolicy.LeaseVerifier,
        refusals: NodeSessionRefusals,
        now: Date
    ) throws -> NodeSessionCheck {
        let current: AccountSessionCredentials
        do {
            guard try credentials.loadCompletedDeletionReceipt() == nil,
                  try credentials.loadLocalDeletion() == nil else { throw NodeSessionBrokerError.notAdmitted }
            guard let session = try credentials.loadSession(),
                  session.state == .active,
                  let sessionCredentials = session.credentials else { throw NodeSessionBrokerError.noActiveSession }
            current = sessionCredentials
        } catch let error as NodeSessionBrokerError {
            throw error
        } catch {
            throw NodeSessionBrokerError.noActiveSession
        }
        let admission = try NodeSessionAdmissionPolicy.admission(for: current, now: now, suspended: refusals.contains(current), leaseVerifier: leaseVerifier)
        let commit = try? credentials.loadCurrentTrustCommit(for: current.accountID)
        let node = commit?.state.members.first(where: { $0.platform == .syncNode })
        let binding = [
            current.accountID.rawValue, current.deviceID.rawValue,
            node?.deviceID.rawValue ?? "-", commit.map { $0.state.epoch.wireValue } ?? "-",
        ].joined(separator: "/")
        return NodeSessionCheck(admission: admission, binding: binding)
    }

    private static func resolveProductionSender(
        credentials: AccountCredentialStore,
        admission: NodeSessionAdmission,
        remote: (any SyncNodeEndpointMetadataRemote)?,
        endpointStore: SyncNodeEndpointStore,
        refusals: NodeSessionRefusals
    ) async throws -> (nodeID: String, sender: any NodeSessionRequestSending & NodePendingRequestReconciling) {
        let current: AccountSessionCredentials
        let identity: AccountDeviceIdentity
        do {
            guard let session = try credentials.loadSession(),
                  session.state == .active,
                  let sessionCredentials = session.credentials,
                  let existing = try credentials.loadExistingDeviceIdentity() else { throw NodeSessionBrokerError.noActiveSession }
            current = sessionCredentials
            identity = existing
        } catch let error as NodeSessionBrokerError {
            throw error
        } catch {
            throw NodeSessionBrokerError.noActiveSession
        }
        let trust = try credentials.makeTrustCoordinator(accountID: current.accountID, deviceID: current.deviceID, platform: .macos, identity: identity)
        guard let commit = try await trust.currentTrustCommit(),
              commit.state.accountID == current.accountID,
              let node = commit.state.members.first(where: { $0.platform == .syncNode }) else {
            throw NodeSessionBrokerError.noEnrolledNode
        }
        var discover: (@Sendable () async throws -> NodeSessionTransport?)?
        if let remote {
            discover = { try await SyncNodeSessionLocator.discover(remote: remote, trust: trust, credentials: current, device: identity, store: endpointStore) }
        }
        let sender = try await endpointSender(
            admission: admission,
            discover: discover,
            restoreCached: {
                try SyncNodeSessionLocator.restoreCachedConnection(credentials: current, nodeID: node.deviceID, trustEpoch: commit.state.epoch, device: identity, store: endpointStore).transport
            },
            onRefused: { refusals.mark(current) }
        )
        return (node.deviceID.rawValue, sender)
    }

    /// Chooses the endpoint the way the app's admission allows:
    /// - read-write (unexpired token): discover through Central. A definite
    ///   Central refusal (401/403) or suspension (423) is not admitted and
    ///   never falls back; only a reachability failure uses the cached endpoint.
    /// - read-only (lease): Central would refuse the expired token, so use the
    ///   cached endpoint sealed by an earlier authenticated discovery.
    static func endpointSender<Sender: Sendable>(
        admission: NodeSessionAdmission,
        discover: (@Sendable () async throws -> Sender?)?,
        restoreCached: @Sendable () throws -> Sender,
        onRefused: @Sendable () -> Void
    ) async throws -> Sender {
        if admission == .readWrite, let discover {
            do {
                if let discovered = try await discover() { return discovered }
                throw NodeSessionBrokerError.noEnrolledNode
            } catch let error as NodeSessionBrokerError {
                throw error
            } catch is NodeSessionCentralRefusal {
                // Like the app, which clears a rejected session and suspends
                // a suspended one: remember the refusal so the lease cannot
                // readmit these credentials once the token expires.
                onRefused()
                throw NodeSessionBrokerError.notAdmitted
            } catch is CancellationError {
                throw CancellationError()
            } catch AccountRuntimeError.transportFailure {
                // Central unreachable: fall through to the cached endpoint.
            } catch {
                throw NodeSessionBrokerError.unavailable
            }
        }
        do {
            return try restoreCached()
        } catch {
            throw NodeSessionBrokerError.noEnrolledNode
        }
    }

    private static func boundEndpointRemote(credentials: AccountCredentialStore, configurationStore: KeychainCentralServerConfigurationStore) -> (any SyncNodeEndpointMetadataRemote)? {
        guard case .configured(let server) = CentralServerConfigurationResolver(store: configurationStore).resolve(credentials: credentials),
              let api = try? AccountAPIClient(
                  transport: URLSessionAccountHTTPTransport(),
                  credentialStore: credentials,
                  manifestStore: BootstrapKeyManifestStore(),
                  baseURL: server.origin
              ) else { return nil }
        return StatusClassifyingEndpointRemote(api: api)
    }
}

/// Session credentials Central refused while their access token was valid:
/// 401/403 (the app clears such a session and asks for sign-in) and 423 (a
/// suspended account). They stay refused, token or lease, until the app
/// stores different credentials.
final class NodeSessionRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var refused: [AccountSessionCredentials] = []
    func mark(_ credentials: AccountSessionCredentials) {
        lock.withLock {
            guard !refused.contains(credentials) else { return }
            refused.append(credentials)
            if refused.count > 8 { refused.removeFirst() }
        }
    }
    func contains(_ credentials: AccountSessionCredentials) -> Bool { lock.withLock { refused.contains(credentials) } }
}

/// The session sender handed to service components. It forwards to the
/// broker's resolved transport through the broker's lane and fails closed
/// once that session was invalidated.
private final class BrokeredSessionSender:
    NodeSessionRequestScopedSending,
    NodeSessionStreamingRequestSending,
    NodePendingRequestReconciling,
    NodePendingMutationReconciling,
    NodeMutationOperationSigning,
    NodeAuthorityEpochUpdating,
    @unchecked Sendable
{
    private let broker: NodeSessionBroker
    private let sender: any NodeSessionRequestSending & NodePendingRequestReconciling
    private let generation: UInt64
    private let binding: String?

    init(broker: NodeSessionBroker, sender: any NodeSessionRequestSending & NodePendingRequestReconciling, generation: UInt64, binding: String?) {
        self.broker = broker; self.sender = sender; self.generation = generation; self.binding = binding
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPResponse {
        let sender = self.sender
        return try await broker.serializedSend(generation: generation, method: method, path: path, reconcile: {
            _ = try await sender.reconcilePendingRequest()
        }) {
            try await sender.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
        }
    }

    func send(method: String, path: String, body: Data, maximumResponseBytes: Int, cancellation: NodeHTTPTransportRequestCancellation) async throws -> NodeHTTPResponse {
        let sender = self.sender
        return try await broker.serializedSend(generation: generation, method: method, path: path, reconcile: {
            _ = try await sender.reconcilePendingRequest()
        }) {
            if let scoped = sender as? any NodeSessionRequestScopedSending {
                return try await scoped.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes, cancellation: cancellation)
            }
            return try await sender.send(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
        }
    }

    func stream(method: String, path: String, body: Data, maximumResponseBytes: Int) async throws -> NodeHTTPStreamResponse {
        let sender = self.sender
        guard let streaming = sender as? any NodeSessionStreamingRequestSending else { throw NodeSessionError.transportFailure }
        return try await broker.serializedStream(generation: generation, method: method, path: path, reconcile: {
            _ = try await sender.reconcilePendingRequest()
        }) {
            try await streaming.stream(method: method, path: path, body: body, maximumResponseBytes: maximumResponseBytes)
        }
    }

    func reconcilePendingRequest() async throws -> NodeHTTPResponse? {
        let sender = self.sender
        return try await broker.serializedReconcile(generation: generation) {
            try await sender.reconcilePendingRequest()
        }
    }

    func reconcilePendingMutation() async throws -> NodeHTTPResponse? {
        guard let reconciler = sender as? any NodePendingMutationReconciling else { return nil }
        return try await broker.serializedReconcile(generation: generation) {
            try await reconciler.reconcilePendingMutation()
        }
    }

    func signMutation(variant: NodeSyncOperationVariant, logicalMailboxID: LogicalMailboxID, idempotencyKey: String, issuedAt: String) throws -> Data {
        // Signing checks the session now, not the last lane operation: a
        // lease-only session is read-only, and a changed trusted Node or
        // account makes this sender's session stale.
        let current: NodeSessionCheck
        do { current = try broker.check() } catch let error as NodeSessionBrokerError { throw error } catch { throw NodeSessionBrokerError.notAdmitted }
        guard current.admission == .readWrite else { throw NodeSessionBrokerError.readOnly }
        guard current.binding == binding else { throw NodeSessionBrokerError.unavailable }
        guard broker.generation.value == generation, let signer = sender as? any NodeMutationOperationSigning else { throw NodeSessionBrokerError.unavailable }
        return try signer.signMutation(variant: variant, logicalMailboxID: logicalMailboxID, idempotencyKey: idempotencyKey, issuedAt: issuedAt)
    }

    func setAuthorityEpoch(_ epoch: String, for logicalMailboxID: LogicalMailboxID) throws {
        let current = try broker.check()
        guard current.binding == binding, broker.generation.value == generation,
              let updater = sender as? any NodeAuthorityEpochUpdating else { throw NodeSessionBrokerError.unavailable }
        try updater.setAuthorityEpoch(epoch, for: logicalMailboxID)
    }
}

/// The session generation, readable synchronously by handed-out senders.
final class BrokerGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    var value: UInt64 { lock.withLock { current } }
    func advance() { lock.withLock { current &+= 1 } }
}

/// A FIFO async lane. It never holds a lock across a suspension, and a
/// cancelled waiter leaves the queue without taking the lane.
private actor BrokerLane {
    private let activity: NodeLaneActivity
    private var occupied = false

    init(activity: NodeLaneActivity) { self.activity = activity }
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        activity.acquired()
        do {
            let value = try await operation()
            activity.released()
            release()
            return value
        } catch {
            activity.released()
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    order.append(id)
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
    }

    private func release() {
        while let id = order.first {
            order.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()
                return
            }
        }
        occupied = false
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }
}
