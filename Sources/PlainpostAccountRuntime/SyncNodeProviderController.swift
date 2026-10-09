import CryptoKit
import Foundation
import PlainpostAccountProtocol
import PlainpostNodeTransport
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public struct SyncNodeProviderMailbox: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID?
    public let displayName: String
    public let mailboxHandle: String
    public let role: String

    public init(displayName: String, mailboxHandle: String, role: String, logicalMailboxID: LogicalMailboxID? = nil) {
        self.logicalMailboxID = logicalMailboxID
        self.displayName = displayName
        self.mailboxHandle = mailboxHandle
        self.role = role
    }
}

/// Stable AccountRuntime diagnostics vocabulary. Transport DTOs are decoded
/// and mapped inside the Node adapter; callers never depend on the wire model.
public struct SyncNodeStatus: Equatable, Sendable {
    public let revision: String
    public let state: String
    public let version: String
    public let reachability: String
    public let syncLag: String
    public let storage: String
    public let providerIdentity: String?
    public let assignments: [SyncNodeProviderMailbox]
    public let backup: String
    public let endpoint: String
    public let updateStatus: String
    public let completedAt: String?

    public init(revision: String = "0", state: String = "unavailable", version: String, reachability: String, syncLag: String, storage: String, providerIdentity: String?, assignments: [SyncNodeProviderMailbox], backup: String, endpoint: String, updateStatus: String, completedAt: String? = nil) {
        self.revision = revision; self.state = state; self.version = version; self.reachability = reachability; self.syncLag = syncLag; self.storage = storage; self.providerIdentity = providerIdentity; self.assignments = assignments; self.backup = backup; self.endpoint = endpoint; self.updateStatus = updateStatus; self.completedAt = completedAt
    }
}

/// AccountRuntime's mailbox-selection vocabulary. Protocol logical IDs and
/// transport DTOs stay inside the provider controller.
public struct SyncNodeMailboxSelection: Equatable, Sendable {
    public let logicalMailboxID: LogicalMailboxID?
    public let displayName: String
    public let mailboxHandle: String
    public let role: String

    public init(displayName: String, mailboxHandle: String, role: String, logicalMailboxID: LogicalMailboxID? = nil) {
        self.logicalMailboxID = logicalMailboxID
        self.displayName = displayName
        self.mailboxHandle = mailboxHandle
        self.role = role
    }
}

public struct SyncNodeProviderResult: Equatable, Sendable {
    public let providerIdentity: String
    public let discoveredMailboxes: [SyncNodeProviderMailbox]

    public init(providerIdentity: String, discoveredMailboxes: [SyncNodeProviderMailbox]) {
        self.providerIdentity = providerIdentity
        self.discoveredMailboxes = discoveredMailboxes
    }
}

public protocol SyncNodeProviderClient: Sendable {
    func status() async throws -> SyncNodeStatus
    func configureGoogle(
        authorizationCode: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> SyncNodeProviderResult
    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws
}

/// A provider client that owns cancellable status I/O must actively close
/// that I/O when a readiness wait expires. Task cancellation alone cannot
/// terminate an arbitrary implementation that ignores cooperative checks.
public protocol SyncNodeProviderStatusCancelling: Sendable {
    func cancelStatusRequests() async
}

/// A cancellation scope owned by one readiness wait. Implementations may
/// create a fresh transport token for each status poll while retaining the
/// scope's cancellation request.
public protocol SyncNodeProviderStatusCancellation: Sendable {
    func cancelAndWait() async
}

public protocol SyncNodeProviderScopedStatusClient: Sendable {
    func makeStatusCancellation() -> any SyncNodeProviderStatusCancellation
    func status(using cancellation: any SyncNodeProviderStatusCancellation) async throws -> SyncNodeStatus
}

public extension SyncNodeProviderClient {
    func status() async throws -> SyncNodeStatus { throw SyncNodeProviderController.Error.providerUnavailable }
    func assignGoogleMailboxes(_: [SyncNodeMailboxSelection]) async throws {
        throw SyncNodeProviderController.Error.providerUnavailable
    }
}

public struct SyncNodeGoogleAuthorizationRequest: Equatable, Sendable {
    public let authorizationURL: URL
    public let clientID: String
    public let redirectURI: String
    public let codeVerifier: String
    public let state: String
    public let authorizationCode: String?

    init(authorizationURL: URL, clientID: String, redirectURI: String, codeVerifier: String, state: String) {
        self.authorizationURL = authorizationURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
        self.state = state
        authorizationCode = nil
    }
}

/// Owns only the OAuth ceremony. The authorization code crosses this boundary
/// once, directly into the Node client; it is never persisted or returned in
/// a settings/view model.
public final class SyncNodeProviderController: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRequest
        case staleCallback
        case providerUnavailable
        /// The transport crossed its request-dispatch boundary; assignment
        /// outcome must be reconciled before sender capabilities are reused.
        case assignmentOutcomeAmbiguous
        case assignmentCancellationAfterDispatch
        /// Google configure and mailbox assignment act on the Node's primary
        /// account (`/v1/status`, `/v1/mailboxes/assignments`); a controller
        /// owned by a non-primary account's authority refuses them.
        case googleOnboardingRequiresPrimaryAccount
    }

    private let client: any SyncNodeProviderClient
    private let authorizationHost = "https://accounts.google.com/o/oauth2/v2/auth"
    private let pendingRequestLock = NSLock()
    private var pendingRequest: SyncNodeGoogleAuthorizationRequest?
    private let assignmentState = AssignmentBatchState()
    private let callbackLock = NSLock()
    private let providerIdentityLock = NSLock()
    private var trustedProviderIdentity: String?
    private var googleOnboardingAllowed = true
    private var statusRefreshCallback: (@Sendable (SyncNodeStatus) -> Void)?
    private var assignmentOutcomeAmbiguousCallback: (@Sendable () -> Void)?
    /// Installed by the owning authority to rebuild its sender/settings
    /// projection after a durable assignment commit.
    public var onStatusRefresh: (@Sendable (SyncNodeStatus) -> Void)? {
        get {
            callbackLock.lock(); defer { callbackLock.unlock() }
            return statusRefreshCallback
        }
        set {
            callbackLock.lock(); statusRefreshCallback = newValue; callbackLock.unlock()
        }
    }
    /// Called before an assignment result is trusted again. A retained mail
    /// authority must invalidate mutation/sender capabilities while a commit
    /// outcome is ambiguous.
    public var onAssignmentOutcomeAmbiguous: (@Sendable () -> Void)? {
        get {
            callbackLock.lock(); defer { callbackLock.unlock() }
            return assignmentOutcomeAmbiguousCallback
        }
        set {
            callbackLock.lock(); assignmentOutcomeAmbiguousCallback = newValue; callbackLock.unlock()
        }
    }

    public init(client: any SyncNodeProviderClient, trustedProviderIdentity: String? = nil) {
        self.client = client
        if let trustedProviderIdentity, !trustedProviderIdentity.isEmpty {
            self.trustedProviderIdentity = trustedProviderIdentity
        }
    }

    public convenience init(client: NodeSyncClient, trustedProviderIdentity: String? = nil) {
        self.init(client: NodeSyncProviderClientAdapter(client: client), trustedProviderIdentity: trustedProviderIdentity)
    }

    /// False when the owning mail authority is scoped to a non-primary
    /// account of a multi-account Node. Google authorization, configure,
    /// mailbox assignment and the trusted-status wait then throw
    /// `googleOnboardingRequiresPrimaryAccount` before any request, so they
    /// can neither change the primary account nor invalidate this authority.
    public var allowsGoogleOnboarding: Bool {
        providerIdentityLock.lock(); defer { providerIdentityLock.unlock() }
        return googleOnboardingAllowed
    }

    func setGoogleOnboardingAllowed(_ allowed: Bool) {
        providerIdentityLock.lock(); googleOnboardingAllowed = allowed; providerIdentityLock.unlock()
    }

    private func requireGoogleOnboardingAllowed() throws {
        guard allowsGoogleOnboarding else { throw Error.googleOnboardingRequiresPrimaryAccount }
    }

    public func makeGoogleAuthorizationRequest(
        clientID: String,
        redirectURI: String
    ) throws -> SyncNodeGoogleAuthorizationRequest {
        try requireGoogleOnboardingAllowed()
        guard !clientID.isEmpty,
              let redirectURL = URL(string: redirectURI),
              let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              redirectComponents.scheme == "https",
              let host = redirectComponents.host,
              !host.isEmpty,
              redirectComponents.user == nil,
              redirectComponents.queryItems?.isEmpty != false,
              redirectComponents.fragment == nil,
              redirectURI == redirectURL.absoluteString
        else { throw Error.invalidRequest }
        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let state = Self.randomURLSafeString(byteCount: 32)
        guard var components = URLComponents(string: authorizationHost) else { throw Error.invalidRequest }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://mail.google.com/"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components.url else { throw Error.invalidRequest }
        let request = SyncNodeGoogleAuthorizationRequest(
            authorizationURL: authorizationURL,
            clientID: clientID,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier,
            state: state
        )
        pendingRequestLock.lock()
        pendingRequest = request
        pendingRequestLock.unlock()
        return request
    }

    public func completeGoogleAuthorization(callbackURL: URL) async throws -> SyncNodeProviderResult {
        try requireGoogleOnboardingAllowed()
        let pendingRequest = pendingRequestSnapshot()

        guard let pendingRequest,
              let redirectURL = URL(string: pendingRequest.redirectURI),
              let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callbackComponents.scheme == redirectComponents.scheme,
              callbackComponents.host == redirectComponents.host,
              callbackComponents.port == redirectComponents.port,
              callbackComponents.path == redirectComponents.path
        else { throw Error.staleCallback }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let state = queryItems.first(where: { $0.name == "state" })?.value,
              state == pendingRequest.state,
              let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else { throw Error.staleCallback }

        // Claim only after all callback validation has succeeded. The lock
        // makes this check-and-clear atomic, so concurrent callbacks cannot
        // hand a single-use OAuth code to the Node twice.
        guard claimPending(pendingRequest) else { throw Error.staleCallback }
        do {
            let result = try await client.configureGoogle(
                authorizationCode: code,
                clientID: pendingRequest.clientID,
                codeVerifier: pendingRequest.codeVerifier,
                redirectURI: pendingRequest.redirectURI
            )
            guard !result.providerIdentity.isEmpty else { throw Error.providerUnavailable }
            // The authenticated configure response establishes the provider
            // identity for the rest of this controller session. Subsequent
            // status/assignment reconciliation must remain on this identity.
            guard bindTrustedProviderIdentity(result.providerIdentity) else { throw Error.providerUnavailable }
            if let status = try? await client.status() {
                try publishTrustedStatus(status)
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.providerUnavailable
        }
    }

    private func assignGoogleMailboxesAfterValidation(_ selections: [SyncNodeMailboxSelection]) async throws -> SyncNodeProviderResult {
        let batch: StableAssignmentBatch
        do { batch = try await assignmentState.prepare(selections) }
        catch { throw Error.invalidRequest }
        // Capture provider identity before the assignment mutation boundary.
        // If the PUT commits but its response is lost, this authenticated
        // onboarding/status projection remains the trusted reconciliation key.
        let trustedProviderIdentity: String
        let retainedProviderIdentity = trustedProviderIdentitySnapshot()
        do {
            guard let status = try await statusAfterPendingReconciliation() else {
                await assignmentState.complete(batch, succeeded: false)
                throw Error.providerUnavailable
            }
            guard Self.isTrustedProviderStatus(status),
                  let providerIdentity = status.providerIdentity,
                  retainedProviderIdentity == nil || retainedProviderIdentity == providerIdentity else {
                await assignmentState.complete(batch, succeeded: false)
                throw Error.providerUnavailable
            }
            guard bindTrustedProviderIdentity(providerIdentity) else {
                await assignmentState.complete(batch, succeeded: false)
                throw Error.providerUnavailable
            }
            trustedProviderIdentity = providerIdentity
        } catch is CancellationError {
            await assignmentState.complete(batch, succeeded: false)
            throw CancellationError()
        } catch let error as Error {
            await assignmentState.complete(batch, succeeded: false)
            throw error
        } catch {
            await assignmentState.complete(batch, succeeded: false)
            throw Error.providerUnavailable
        }
        do {
            _ = try await client.assignGoogleMailboxes(batch.selections)
            // Assignment changes the sender identity and logical mailbox
            // capabilities. Refresh the status projection before publishing
            // the result so every surface observes one coherent authority.
            guard let status = try? await client.status(),
                  Self.status(status, matches: batch.selections, providerIdentity: trustedProviderIdentity) else {
                // The mutation may have committed, but without the refreshed
                // authority projection it is unsafe to expose a stale sender
                // or mailbox capability to retained UI surfaces.
                throw Error.providerUnavailable
            }
            try publishTrustedStatus(status)
            let result = try Self.result(from: status)
            await assignmentState.complete(batch, succeeded: true)
            return result
        }
        catch is CancellationError {
            await assignmentState.complete(batch, succeeded: false)
            throw CancellationError()
        }
        catch let error as Error where error == .assignmentOutcomeAmbiguous {
            notifyAssignmentOutcomeAmbiguous()
            do {
                if let status = try await statusAfterPendingReconciliation(),
                   Self.status(status, matches: batch.selections, providerIdentity: trustedProviderIdentity) {
                    try publishTrustedStatus(status)
                    let result = try Self.result(from: status)
                    await assignmentState.complete(batch, succeeded: true)
                    return result
                }
            } catch is CancellationError {
                await assignmentState.complete(batch, succeeded: false)
                throw CancellationError()
            } catch {
                // A non-cancellation reconciliation failure is deliberately
                // mapped below; it cannot re-enable the provider capability.
            }
            await assignmentState.complete(batch, succeeded: false)
            throw Error.providerUnavailable
        }
        catch let error as Error where error == .assignmentCancellationAfterDispatch {
            notifyAssignmentOutcomeAmbiguous()
            await assignmentState.complete(batch, succeeded: false)
            throw CancellationError()
        }
        catch {
            // A successful commit can lose either its response or the
            // immediate status acknowledgement. Reconcile only from an
            // authenticated status projection that contains this exact batch;
            // otherwise retain the stable intent for a safe retry.
            notifyAssignmentOutcomeAmbiguous()
            do {
                if let status = try await statusAfterPendingReconciliation(),
                   Self.status(status, matches: batch.selections, providerIdentity: trustedProviderIdentity) {
                    try publishTrustedStatus(status)
                    let result = try Self.result(from: status)
                    await assignmentState.complete(batch, succeeded: true)
                    return result
                }
            } catch is CancellationError {
                await assignmentState.complete(batch, succeeded: false)
                throw CancellationError()
            } catch {
                // A non-cancellation reconciliation failure is deliberately
                // mapped below; it cannot re-enable the provider capability.
            }
            await assignmentState.complete(batch, succeeded: false)
            throw Error.providerUnavailable
        }
    }

    /// Waits for an authenticated provider status to become trustworthy before
    /// a caller starts a provider mutation. Sync workers can briefly publish a
    /// degraded/unreachable status while completing a baseline; treating that
    /// transient state as a permanent provider failure would race a valid
    /// assignment. The deadline remains caller-controlled and cancellation is
    /// preserved.
    public func waitForTrustedProviderStatus(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(250),
        expectedProviderIdentity: String? = nil,
        matching: (@Sendable (SyncNodeStatus) -> Bool)? = nil
    ) async throws -> SyncNodeStatus {
        try requireGoogleOnboardingAllowed()
        guard timeout > .zero, pollInterval > .zero else { throw Error.providerUnavailable }
        let retainedIdentity = trustedProviderIdentitySnapshot()
        if let expectedProviderIdentity, let retainedIdentity, expectedProviderIdentity != retainedIdentity {
            throw Error.providerUnavailable
        }
        let requiredIdentity = retainedIdentity ?? expectedProviderIdentity
        let status = try await TrustedProviderStatusWait(
            client: client,
            timeout: timeout,
            pollInterval: pollInterval,
            expectedProviderIdentity: requiredIdentity,
            matching: matching,
            isTrusted: Self.isTrustedProviderStatus
        ).run()
        try publishTrustedStatus(status)
        return status
    }

    /// Validates a status before an owning mail authority publishes it. A
    /// status without an identity is only valid for an explicitly unavailable
    /// node; an identified status must match the identity already bound to
    /// this authenticated controller.
    func validateStatusForPublication(_ status: SyncNodeStatus) throws {
        try validateTrustedStatus(status)
    }

    /// Atomically validates and publishes a status projection. Every status
    /// that reaches an owning authority callback passes through this single
    /// identity fence, so a provider response cannot rebind the sender.
    func publishTrustedStatus(_ status: SyncNodeStatus) throws {
        try validateTrustedStatus(status)
        publishStatus(status)
    }

    private func validateTrustedStatus(_ status: SyncNodeStatus) throws {
        if status.state == "unavailable", status.providerIdentity == nil { return }
        guard let providerIdentity = status.providerIdentity,
              bindTrustedProviderIdentity(providerIdentity) else {
            throw Error.providerUnavailable
        }
    }

    /// A strict session may first need to replay an assignment whose response
    /// was ambiguous. The replay consumes the retained sequence and can
    /// therefore report an expected sequence-consumed conflict; one immediate
    /// second status read observes the durable assignment without issuing a
    /// duplicate PUT.
    private func statusAfterPendingReconciliation() async throws -> SyncNodeStatus? {
        for attempt in 0..<2 {
            do { return try await client.status() }
            catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    public func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws -> SyncNodeProviderResult {
        try requireGoogleOnboardingAllowed()
        guard !selections.isEmpty else { throw Error.invalidRequest }
        return try await assignGoogleMailboxesAfterValidation(selections)
    }

    private static func result(from status: SyncNodeStatus) throws -> SyncNodeProviderResult {
        guard let providerIdentity = status.providerIdentity, !providerIdentity.isEmpty else {
            throw Error.providerUnavailable
        }
        return SyncNodeProviderResult(
            providerIdentity: providerIdentity,
            discoveredMailboxes: status.assignments.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }
        )
    }

    private static func status(_ status: SyncNodeStatus, matches selections: [SyncNodeMailboxSelection], providerIdentity: String) -> Bool {
        guard isTrustedProviderStatus(status),
              status.providerIdentity == providerIdentity,
              status.assignments.count == selections.count else { return false }
        let expected = Set(selections.map(StableAssignmentFingerprint.init))
        let actual = Set(status.assignments.map(StableAssignmentFingerprint.init))
        return expected.count == selections.count && actual.count == status.assignments.count && actual == expected
    }

    private static func isTrustedProviderStatus(_ status: SyncNodeStatus) -> Bool {
        status.state == "ready" && status.reachability == "reachable" &&
            status.providerIdentity?.isEmpty == false
    }

    private static func providerIdentity(from status: SyncNodeStatus) throws -> String {
        guard let providerIdentity = status.providerIdentity, !providerIdentity.isEmpty else {
            throw Error.providerUnavailable
        }
        return providerIdentity
    }

    private func trustedProviderIdentitySnapshot() -> String? {
        providerIdentityLock.lock(); defer { providerIdentityLock.unlock() }
        return trustedProviderIdentity
    }

    @discardableResult
    private func bindTrustedProviderIdentity(_ providerIdentity: String) -> Bool {
        guard !providerIdentity.isEmpty else { return false }
        providerIdentityLock.lock(); defer { providerIdentityLock.unlock() }
        if let trustedProviderIdentity {
            return trustedProviderIdentity == providerIdentity
        }
        trustedProviderIdentity = providerIdentity
        return true
    }

    private func pendingRequestSnapshot() -> SyncNodeGoogleAuthorizationRequest? {
        pendingRequestLock.lock(); defer { pendingRequestLock.unlock() }
        return pendingRequest
    }

    private func publishStatus(_ status: SyncNodeStatus) {
        onStatusRefresh?(status)
    }

    private func notifyAssignmentOutcomeAmbiguous() {
        onAssignmentOutcomeAmbiguous?()
    }

    private func claimPending(_ request: SyncNodeGoogleAuthorizationRequest) -> Bool {
        pendingRequestLock.lock(); defer { pendingRequestLock.unlock() }
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        return true
    }

#if canImport(AuthenticationServices)
    /// Creates the platform system-authentication session. The completion
    /// callback receives only the redirect URL; callers must immediately pass
    /// it to `completeGoogleAuthorization`, which consumes the code once.
    @MainActor
    public func makeGoogleAuthenticationSession(
        request: SyncNodeGoogleAuthorizationRequest,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding,
        completion: @escaping (URL?, Swift.Error?) -> Void
    ) throws -> ASWebAuthenticationSession {
        guard let redirectURL = URL(string: request.redirectURI),
              let components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              !components.path.isEmpty, components.queryItems?.isEmpty != false,
              components.fragment == nil else { throw Error.invalidRequest }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(
                url: request.authorizationURL,
                callback: .https(host: host, path: components.path),
                completionHandler: completion
            )
        } else {
            throw Error.invalidRequest
        }
        session.presentationContextProvider = presentationContextProvider
        return session
    }
#endif

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class TrustedProviderStatusWait: @unchecked Sendable {
    private let timeout: Duration
    private let pollInterval: Duration
    private let expectedProviderIdentity: String?
    private let matching: (@Sendable (SyncNodeStatus) -> Bool)?
    private let isTrusted: @Sendable (SyncNodeStatus) -> Bool

    init(
        client: any SyncNodeProviderClient,
        timeout: Duration,
        pollInterval: Duration,
        expectedProviderIdentity: String?,
        matching: (@Sendable (SyncNodeStatus) -> Bool)?,
        isTrusted: @escaping @Sendable (SyncNodeStatus) -> Bool
    ) {
        self.client = client
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.expectedProviderIdentity = expectedProviderIdentity
        self.matching = matching
        self.isTrusted = isTrusted
    }

    private let client: any SyncNodeProviderClient

    func run() async throws -> SyncNodeStatus {
        let state = State()
        let scopedClient = client as? any SyncNodeProviderScopedStatusClient
        let statusCancellation = scopedClient?.makeStatusCancellation()
        let cancelStatus: @Sendable () async -> Void = {
            if let statusCancellation {
                await statusCancellation.cancelAndWait()
            } else {
                await (self.client as? any SyncNodeProviderStatusCancelling)?.cancelStatusRequests()
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await state.start(
                client: client,
                timeout: timeout,
                pollInterval: pollInterval,
                expectedProviderIdentity: expectedProviderIdentity,
                matching: matching,
                isTrusted: isTrusted,
                cancelStatus: cancelStatus,
                statusCancellation: statusCancellation
            )
        }, onCancel: {
            state.cancel()
        })
    }

    private final class State: @unchecked Sendable {
        private enum Outcome {
            case success(SyncNodeStatus)
            case failure(Swift.Error)
        }

        private let lock = NSLock()
        private var outcome: Outcome?
        private var continuation: CheckedContinuation<SyncNodeStatus, Swift.Error>?
        private var pollingTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var cancelStatus: (@Sendable () async -> Void)?
        private var cancellationCleanupStarted = false

        deinit {
            pollingTask?.cancel()
            timeoutTask?.cancel()
        }

        func start(
            client: any SyncNodeProviderClient,
            timeout: Duration,
            pollInterval: Duration,
            expectedProviderIdentity: String?,
            matching: (@Sendable (SyncNodeStatus) -> Bool)?,
            isTrusted: @escaping @Sendable (SyncNodeStatus) -> Bool,
            cancelStatus: @escaping @Sendable () async -> Void,
            statusCancellation: (any SyncNodeProviderStatusCancellation)?
        ) async throws -> SyncNodeStatus {
            try await withCheckedThrowingContinuation { continuation in
                install(
                    continuation,
                    client: client,
                    timeout: timeout,
                    pollInterval: pollInterval,
                    expectedProviderIdentity: expectedProviderIdentity,
                    matching: matching,
                    isTrusted: isTrusted,
                    cancelStatus: cancelStatus,
                    statusCancellation: statusCancellation
                )
            }
        }

        private func install(
            _ continuation: CheckedContinuation<SyncNodeStatus, Swift.Error>,
            client: any SyncNodeProviderClient,
            timeout: Duration,
            pollInterval: Duration,
            expectedProviderIdentity: String?,
            matching: (@Sendable (SyncNodeStatus) -> Bool)?,
            isTrusted: @escaping @Sendable (SyncNodeStatus) -> Bool,
            cancelStatus: @escaping @Sendable () async -> Void,
            statusCancellation: (any SyncNodeProviderStatusCancellation)?
        ) {
            lock.lock()
            if let outcome {
                lock.unlock()
                resume(continuation, with: outcome)
                return
            }
            self.continuation = continuation
            self.cancelStatus = cancelStatus
            lock.unlock()

            if Task.isCancelled {
                cancel()
                return
            }

            let succeed: @Sendable (SyncNodeStatus) -> Void = { [weak self] status in
                self?.finish(.success(status))
            }
            let fail: @Sendable () -> Void = { [weak self] in
                self?.finish(.failure(SyncNodeProviderController.Error.providerUnavailable))
            }
            let pollingTask = Task { [client, expectedProviderIdentity, matching, isTrusted, statusCancellation] in
                await Self.poll(
                    client: client,
                    timeout: timeout,
                    pollInterval: pollInterval,
                    expectedProviderIdentity: expectedProviderIdentity,
                    matching: matching,
                    isTrusted: isTrusted,
                    statusCancellation: statusCancellation,
                    succeed: succeed,
                    fail: fail
                )
            }
            let timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                guard let self else { return }
                self.finish(.failure(SyncNodeProviderController.Error.providerUnavailable))
                self.beginCancellationCleanup()
            }

            lock.lock()
            if outcome != nil {
                lock.unlock()
                pollingTask.cancel()
                timeoutTask.cancel()
            } else {
                self.pollingTask = pollingTask
                self.timeoutTask = timeoutTask
                lock.unlock()
            }
        }

        private static func poll(
            client: any SyncNodeProviderClient,
            timeout: Duration,
            pollInterval: Duration,
            expectedProviderIdentity: String?,
            matching: (@Sendable (SyncNodeStatus) -> Bool)?,
            isTrusted: @escaping @Sendable (SyncNodeStatus) -> Bool,
            statusCancellation: (any SyncNodeProviderStatusCancellation)?,
            succeed: @escaping @Sendable (SyncNodeStatus) -> Void,
            fail: @escaping @Sendable () -> Void
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline && !Task.isCancelled {
                do {
                    let status: SyncNodeStatus
                    if let scopedClient = client as? any SyncNodeProviderScopedStatusClient,
                       let statusCancellation {
                        status = try await scopedClient.status(using: statusCancellation)
                    } else {
                        status = try await client.status()
                    }
                    let identityMatches = expectedProviderIdentity.map { status.providerIdentity == $0 } ?? true
                    if isTrusted(status), identityMatches, matching?(status) ?? true {
                        succeed(status)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Transient transport/provider failures are retried until the
                    // independent timeout task closes the wait.
                }
                let remaining = deadline - clock.now
                guard remaining > .zero else { break }
                do { try await Task.sleep(for: min(pollInterval, remaining)) }
                catch { return }
            }
            if !Task.isCancelled { fail() }
        }

        func cancel() {
            finish(.failure(CancellationError()))
            beginCancellationCleanup()
        }

        private func beginCancellationCleanup() {
            let cancelStatus = lock.withLock { () -> (@Sendable () async -> Void)? in
                guard !cancellationCleanupStarted, let cancelStatus = self.cancelStatus else { return nil }
                cancellationCleanupStarted = true
                return cancelStatus
            }
            guard let cancelStatus else { return }
            // Cleanup must continue after the caller has received its terminal
            // outcome. The task captures only the cancellation operation, so
            // releasing this wait state cannot cancel or leak the request drain.
            Task { await cancelStatus() }
        }

        private func finish(_ result: Outcome) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let continuation = self.continuation
            self.continuation = nil
            let pollingTask = self.pollingTask
            let timeoutTask = self.timeoutTask
            lock.unlock()

            pollingTask?.cancel()
            timeoutTask?.cancel()
            if let continuation { resume(continuation, with: result) }
        }

        private func resume(_ continuation: CheckedContinuation<SyncNodeStatus, Swift.Error>, with outcome: Outcome) {
            switch outcome {
            case let .success(status): continuation.resume(returning: status)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
    }
}


private struct StableAssignmentFingerprint: Codable, Hashable, Sendable {
    let displayName: String
    let mailboxHandle: String
    let role: String
    let logicalMailboxID: String

    init(_ selection: SyncNodeMailboxSelection) {
        displayName = selection.displayName
        mailboxHandle = selection.mailboxHandle
        role = selection.role
        logicalMailboxID = selection.logicalMailboxID.map { $0.rawValue.base64EncodedString() } ?? ""
    }

    init(_ mailbox: SyncNodeProviderMailbox) {
        displayName = mailbox.displayName
        mailboxHandle = mailbox.mailboxHandle
        role = mailbox.role
        logicalMailboxID = mailbox.logicalMailboxID.map { $0.rawValue.base64EncodedString() } ?? ""
    }
}

private struct StableAssignmentBatch: Sendable {
    let selections: [SyncNodeMailboxSelection]
    let fingerprint: String
}

private actor AssignmentBatchState {
    private var pending: StableAssignmentBatch?
    private var inFlight = false

    func prepare(_ selections: [SyncNodeMailboxSelection]) throws -> StableAssignmentBatch {
        guard !selections.isEmpty else { throw SyncNodeProviderController.Error.invalidRequest }
        let supplied = Set(selections.compactMap(\.logicalMailboxID))
        guard supplied.count <= 1, !inFlight else { throw SyncNodeProviderController.Error.invalidRequest }
        let logical: LogicalMailboxID
        if let supplied = supplied.first {
            if let pendingLogical = pending?.selections.first?.logicalMailboxID, pendingLogical != supplied {
                throw SyncNodeProviderController.Error.invalidRequest
            }
            logical = supplied
        } else if let pendingLogical = pending?.selections.first?.logicalMailboxID {
            logical = pendingLogical
        } else {
            var generator = SystemRandomNumberGenerator()
            guard let generated = LogicalMailboxID(rawValue: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })) else {
                throw SyncNodeProviderController.Error.invalidRequest
            }
            logical = generated
        }
        let stable = selections.map {
            SyncNodeMailboxSelection(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: logical)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = String(
            data: try encoder.encode(stable.map(StableAssignmentFingerprint.init)),
            encoding: .utf8
        )!
        let batch = StableAssignmentBatch(selections: stable, fingerprint: fingerprint)
        if let pending, pending.fingerprint != fingerprint {
            throw SyncNodeProviderController.Error.invalidRequest
        }
        if pending == nil { self.pending = batch }
        inFlight = true
        return batch
    }

    func complete(_ batch: StableAssignmentBatch, succeeded: Bool) {
        guard pending?.fingerprint == batch.fingerprint else { return }
        inFlight = false
        if succeeded { pending = nil }
    }
}

final class NodeSyncProviderClientAdapter: SyncNodeProviderClient, SyncNodeProviderScopedStatusClient, @unchecked Sendable {
    let client: NodeSyncClient

    init(client: NodeSyncClient) { self.client = client }

    func makeStatusCancellation() -> any SyncNodeProviderStatusCancellation {
        StatusCancellationScope()
    }

    func status() async throws -> SyncNodeStatus {
        try await status(using: StatusCancellationScope())
    }

    func status(using cancellation: any SyncNodeProviderStatusCancellation) async throws -> SyncNodeStatus {
        guard let scope = cancellation as? StatusCancellationScope else {
            throw SyncNodeProviderController.Error.providerUnavailable
        }
        let transportCancellation = NodeHTTPTransportRequestCancellation()
        let shouldCancel = scope.install(transportCancellation)
        defer {
            scope.clear(transportCancellation)
        }
        if shouldCancel { throw CancellationError() }
        let worker = Task { try await client.status(cancellation: transportCancellation) }
        // Cancel the worker as well as the transport token. This closes a
        // status that is still waiting for the serialized session lane and
        // therefore has not installed a URLSession task yet.
        transportCancellation.install { worker.cancel() }
        let status = try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
        return status.syncNodeStatus()
    }

    func configureGoogle(
        authorizationCode: String,
        clientID: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> SyncNodeProviderResult {
        let result = try await client.configureGoogle(
            authorizationCode: authorizationCode,
            clientID: clientID,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
        return SyncNodeProviderResult(
            providerIdentity: result.providerIdentity,
            discoveredMailboxes: result.discoveredMailboxes.map {
                SyncNodeProviderMailbox(displayName: $0.displayName, mailboxHandle: $0.mailboxHandle, role: $0.role, logicalMailboxID: $0.logicalMailboxID)
            }
        )
    }

    func assignGoogleMailboxes(_ selections: [SyncNodeMailboxSelection]) async throws {
        guard !selections.isEmpty,
              selections.allSatisfy({ $0.logicalMailboxID != nil })
        else { throw SyncNodeProviderController.Error.invalidRequest }
        let assignments = try selections.map { selection in
            guard let logical = selection.logicalMailboxID else { throw SyncNodeProviderController.Error.invalidRequest }
            return try NodeSyncMailboxAssignment(logicalMailboxID: logical, mailboxHandle: selection.mailboxHandle)
        }
        do {
            _ = try await client.assignMailbox(try NodeSyncMailboxAssignmentsRequest(assignments: assignments))
        } catch let error as NodeSyncClientError where error == .transportAfterDispatch {
            throw SyncNodeProviderController.Error.assignmentOutcomeAmbiguous
        } catch let error as NodeSyncClientError where error == .cancelledAfterDispatch {
            throw SyncNodeProviderController.Error.assignmentCancellationAfterDispatch
        }
    }
}

final class StatusCancellationScope: SyncNodeProviderStatusCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NodeHTTPTransportRequestCancellation?
    private var cancelled = false

    func install(_ cancellation: NodeHTTPTransportRequestCancellation) -> Bool {
        lock.withLock {
            guard !cancelled else { return true }
            current = cancellation
            return false
        }
    }

    var hasInstalledCancellation: Bool { lock.withLock { current != nil } }

    func clear(_ cancellation: NodeHTTPTransportRequestCancellation) {
        lock.withLock {
            if current === cancellation { current = nil }
        }
    }

    func cancelAndWait() async {
        let cancellation = lock.withLock {
            cancelled = true
            return current
        }
        await cancellation?.cancelAndWait()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}
