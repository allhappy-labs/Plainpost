import CryptoKit
import Darwin
import Foundation
import PlainpostAccountProtocol
import PlainpostAccountRuntime
import PlainpostCore
import PlainpostNodeTransport

public struct NotificationAccountContext: Sendable {
    public let credentials: AccountSessionCredentials
    public let device: AccountDeviceIdentity
}

#if DEBUG
// Internal synchronization seam used by the deterministic fence regressions.
// It is inert unless a test installs a callback and carries no runtime state.
enum NotificationRefreshLockTestHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var acquireStart: (@Sendable () -> Void)?

    static func setAcquireStart(_ callback: (@Sendable () -> Void)?) {
        lock.lock()
        acquireStart = callback
        lock.unlock()
    }

    static func recordAcquireStart() {
        lock.lock()
        let callback = acquireStart
        lock.unlock()
        callback?()
    }
}
#endif

/// A lock that spans both the app and the service.  Keychain CAS protects the
/// record after a refresh, but is too late if two processes present the same
/// one-time refresh credential to Central.  The lock is deliberately a file
/// in the shared account-support directory so the kernel serializes the
/// network operation as well as the subsequent CAS.
private final class NotificationRefreshLock: @unchecked Sendable {
    // The process-local semaphore and cross-process flock are both acquired
    // from a utility queue.  They must never block a cooperative executor
    // thread while an async caller is waiting for another refresh to finish.
    private static let processLock = DispatchSemaphore(value: 1)
    private let lockURL: URL
    private let descriptorStateLock = NSLock()
    private var ownedDescriptor: Int32?

    init(url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        let directory = standardizedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        lockURL = standardizedURL
    }

    deinit { release() }

    func acquire() async throws {
        let state = LockAcquisitionState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    self.acquireOnUtilityQueue(state: state)
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }

    private func openValidatedDescriptor() throws -> Int32 {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NotificationRuntimeError.unavailable }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              (status.st_mode & S_IFMT) == S_IFREG,
              (status.st_mode & 0o777) == 0o600,
              status.st_nlink == 1 else {
            close(descriptor)
            throw NotificationRuntimeError.unavailable
        }
        return descriptor
    }

    private func acquireOnUtilityQueue(state: LockAcquisitionState) {
        var processHeld = false
        var fileHeld = false
        var descriptor: Int32?
#if DEBUG
        NotificationRefreshLockTestHooks.recordAcquireStart()
#endif
        defer {
            if let descriptor {
                if fileHeld {
                    unlockFile(descriptor)
                }
                close(descriptor)
            }
            if processHeld {
                Self.processLock.signal()
            }
        }

        while !state.isCancelled {
            if Self.processLock.wait(timeout: .now() + .milliseconds(25)) == .success {
                processHeld = true
                break
            }
        }
        guard processHeld else {
            state.failCancellation()
            return
        }
        do {
            descriptor = try openValidatedDescriptor()
        } catch {
            state.fail(NotificationRuntimeError.unavailable)
            return
        }
        while !state.isCancelled {
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            if fcntl(descriptor!, F_SETLK, &lock) == 0 {
                fileHeld = true
                break
            }
            guard errno == EACCES || errno == EAGAIN || errno == EINTR else {
                state.fail(NotificationRuntimeError.unavailable)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard fileHeld else {
            state.failCancellation()
            return
        }
        guard installOwnedDescriptor(descriptor!) else {
            state.fail(NotificationRuntimeError.unavailable)
            return
        }
        descriptor = nil
        guard state.succeed() else {
            release()
            fileHeld = false
            processHeld = false
            return
        }
        fileHeld = false
        processHeld = false
    }

    func release() {
        guard let descriptor = takeOwnedDescriptor() else { return }
        unlockFile(descriptor)
        close(descriptor)
        Self.processLock.signal()
    }

    private func installOwnedDescriptor(_ descriptor: Int32) -> Bool {
        descriptorStateLock.lock()
        defer { descriptorStateLock.unlock() }
        guard ownedDescriptor == nil else { return false }
        ownedDescriptor = descriptor
        return true
    }

    private func takeOwnedDescriptor() -> Int32? {
        descriptorStateLock.lock()
        defer { descriptorStateLock.unlock() }
        let descriptor = ownedDescriptor
        ownedDescriptor = nil
        return descriptor
    }

    private func unlockFile(_ descriptor: Int32) {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = fcntl(descriptor, F_SETLK, &lock)
    }

    private final class LockAcquisitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var completed = false
        private var continuation: CheckedContinuation<Void, Error>?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            cancelled = true
            if completed {
                continuation = nil
            } else {
                completed = true
                continuation = self.continuation
                self.continuation = nil
            }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }

        func succeed() -> Bool {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard !cancelled, !completed else {
                lock.unlock()
                return false
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
            return true
        }

        func fail(_ error: Error) {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: error)
        }

        func failCancellation() {
            fail(CancellationError())
        }
    }
}

/// Resolves the current Keychain session for every operation. Refresh is
/// compare-and-swap so an app and service racing to rotate access tokens do
/// not overwrite one another.
public final class NotificationAccountSession: @unchecked Sendable {
    public let api: AccountAPIClient
    public let store: AccountCredentialStore
    private let refreshLockURL: URL
    private let clock: @Sendable () -> Date

    public init(api: AccountAPIClient, store: AccountCredentialStore, refreshLockURL: URL? = nil, clock: @escaping @Sendable () -> Date) {
        self.api = api
        self.store = store
        self.refreshLockURL = refreshLockURL ?? Self.defaultRefreshLockURL()
        self.clock = clock
    }

    public convenience init(api: AccountAPIClient, store: AccountCredentialStore, refreshLockURL: URL? = nil) {
        self.init(api: api, store: store, refreshLockURL: refreshLockURL, clock: Date.init)
    }

    public func current(now: Date = Date()) async throws -> NotificationAccountContext {
        try await current(initialNow: now)
    }

    public func current() async throws -> NotificationAccountContext {
        try await current(initialNow: clock())
    }

    private func current(initialNow: Date) async throws -> NotificationAccountContext {
        try Task.checkCancellation()
        guard let session = try store.loadSession(), session.state == .active, let credentials = session.credentials else { throw NotificationRuntimeError.unavailable }
        let device = try store.loadOrCreateDeviceIdentity()
        guard credentials.accessExpiresAt.timeIntervalSince(initialNow) <= 30 else {
            return NotificationAccountContext(credentials: credentials, device: device)
        }

        // Re-read after acquiring the cross-process fence.  The winning app or
        // service may already have rotated the one-time credential while this
        // caller was waiting, in which case no second Central request is made.
        let refreshLock = try NotificationRefreshLock(url: refreshLockURL)
        try await refreshLock.acquire()
        defer { refreshLock.release() }
        // Re-sample after ownership so DPoP timestamps and refresh expiry
        // checks cannot use a value captured before a contended wait.
        let ownershipNow = clock()
        guard let latestSession = try store.loadSession(), latestSession.state == .active,
              let latestCredentials = latestSession.credentials else { throw NotificationRuntimeError.unavailable }
        if latestCredentials.accessExpiresAt.timeIntervalSince(ownershipNow) > 30 {
            return NotificationAccountContext(credentials: latestCredentials, device: device)
        }
        do {
            let replacement = try await api.refreshSession(latestCredentials, device: device, now: ownershipNow)
            _ = try store.replaceSession(ifCurrent: latestCredentials, with: replacement)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A Keychain implementation can still report a CAS conflict after
            // a crash/recovery boundary. Always use the durable winner if one
            // is now present; otherwise preserve the original error.
            try Task.checkCancellation()
            if let latest = try store.loadSession()?.credentials, latest != latestCredentials {
                return NotificationAccountContext(credentials: latest, device: device)
            }
            throw error
        }
        guard let latest = try store.loadSession(), let current = latest.credentials else { throw NotificationRuntimeError.unavailable }
        return NotificationAccountContext(credentials: current, device: device)
    }

    func snapshot() throws -> NotificationAccountContext { try currentSync() }
    private func currentSync() throws -> NotificationAccountContext {
        guard let session = try store.loadSession(), session.state == .active, let credentials = session.credentials else { throw NotificationRuntimeError.unavailable }
        return NotificationAccountContext(credentials: credentials, device: try store.loadOrCreateDeviceIdentity())
    }

    private static func defaultRefreshLockURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("com.marynavdovenko.Plainpost.AccountOperationLocks", isDirectory: true)
            .appendingPathComponent("notification-session-refresh.lock")
    }
}

public struct DirectNotificationPolicySnapshot: Sendable, Equatable {
    public let defaultPolicy: DirectNotificationPolicyState
    public let mailboxPolicies: [NodeSyncNotificationPolicy]
    /// Central rows, including inactive inherited tombstones. The active
    /// `mailboxPolicies` projection intentionally excludes those rows.
    public let mailboxStates: [DirectNotificationPolicyMailboxState]

    public init(defaultPolicy: DirectNotificationPolicyState, mailboxPolicies: [NodeSyncNotificationPolicy], mailboxStates: [DirectNotificationPolicyMailboxState] = []) {
        self.defaultPolicy = defaultPolicy
        self.mailboxPolicies = mailboxPolicies
        self.mailboxStates = mailboxStates
    }
}

/// Central Direct wire/state representation. It deliberately does not use
/// NodeSyncNotificationPolicy because Central may retain version-zero
/// inherited tombstones and defaults with scopeVersion zero.
public struct DirectNotificationPolicyMailboxState: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID
    public let mode: NodeSyncNotificationPolicyMode
    public let version: String
    public let scopeVersion: String
    public let override: Bool

    public init(logicalMailboxID: LogicalMailboxID, mode: NodeSyncNotificationPolicyMode, version: String, scopeVersion: String, override: Bool) throws {
        _ = try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: mode, version: version, scopeVersion: scopeVersion, override: override)
        self.logicalMailboxID = logicalMailboxID
        self.mode = mode
        self.version = version
        self.scopeVersion = scopeVersion
        self.override = override
    }
}

/// The Direct reconciliation value keeps the effective policy coordinate
/// independent from the mailbox scope high-water mark. Unlike the Node DTO,
/// Direct must represent inherited/default rows with scope version zero.
public struct DirectNotificationPolicyReconciliationValue: Sendable, Equatable {
    public let logicalMailboxID: LogicalMailboxID
    public let mode: NodeSyncNotificationPolicyMode
    public let effectiveVersion: Int64
    public let scopeVersion: Int64
    public let override: Bool

    public init(
        logicalMailboxID: LogicalMailboxID,
        mode: NodeSyncNotificationPolicyMode,
        effectiveVersion: Int64,
        scopeVersion: Int64,
        override: Bool
    ) throws {
        guard logicalMailboxID.rawValue.count == 32,
              logicalMailboxID.rawValue.contains(where: { $0 != 0 }),
              effectiveVersion > 0, effectiveVersion <= Int64(UInt16.max),
              scopeVersion >= 0, scopeVersion <= Int64(UInt16.max),
              (!override || (scopeVersion > 0 && effectiveVersion == scopeVersion)) else {
            throw NotificationPolicyRemoteError.invalidResponse
        }
        self.logicalMailboxID = logicalMailboxID
        self.mode = mode
        self.effectiveVersion = effectiveVersion
        self.scopeVersion = scopeVersion
        self.override = override
    }
}

/// Authenticated Central policy transport for Direct Mode. Central is the
/// authority only for the currently selected Mac producer; this client does
/// not carry provider identity, credentials, or mailbox paths.
public final class AuthenticatedDirectNotificationPolicyClient: DirectNotificationPolicyAccess, @unchecked Sendable {
    private let api: AccountAPIClient
    private let sessions: NotificationAccountSession

    public init(api: AccountAPIClient, credentialStore: AccountCredentialStore, refreshLockURL: URL? = nil) {
        self.api = api
        self.sessions = NotificationAccountSession(api: api, store: credentialStore, refreshLockURL: refreshLockURL)
    }

    public func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        let snapshot = try await snapshot()
        guard let logicalMailboxID,
              let policy = snapshot.mailboxPolicies.first(where: { $0.logicalMailboxID == logicalMailboxID }) else {
            // A Direct default and inherited mailbox are not Node states:
            // Node's public DTO requires a positive mailbox scope version,
            // so never fabricate one merely to satisfy the legacy adapter.
            throw NotificationPolicyRemoteError.invalidResponse
        }
        return policy
    }

    public func directDefaultPolicy() async throws -> DirectNotificationPolicyState {
        let value = try await snapshot()
        return value.defaultPolicy
    }

    public func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState {
        let value = try await snapshot()
        if let row = value.mailboxStates.first(where: { $0.logicalMailboxID == logicalMailboxID }) {
            if row.override {
                return try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: row.mode, version: row.version, scopeVersion: row.scopeVersion, override: true)
            }
            // Inherited rows expose the effective default but retain the
            // mailbox scope high-water mark for the next mailbox CAS.
            return try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: value.defaultPolicy.mode, version: value.defaultPolicy.version, scopeVersion: row.scopeVersion, override: false)
        }
        return try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: value.defaultPolicy.mode, version: value.defaultPolicy.version, scopeVersion: "0", override: false)
    }

    public func snapshot() async throws -> DirectNotificationPolicySnapshot {
        let context = try await currentContext()
        let response = try await api.sendAccountRequestResult(
            method: "GET", path: "/v1/notifications/direct-policies", body: nil,
            credentials: context.credentials, device: context.device,
            maximumRequestBytes: 256 * 1024, maximumResponseBytes: 256 * 1024
        )
        let body = try responseBody(response)
        guard StrictJSONKeyScanner(data: body).isValid else { throw NotificationPolicyRemoteError.invalidResponse }
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(root.keys) == Set(["kind", "default", "mailboxes"]),
              root["kind"] as? String == "notification.direct-policy-snapshot.v1",
              let defaultObject = root["default"] as? [String: Any],
              let mailboxObjects = root["mailboxes"] as? [[String: Any]], mailboxObjects.count <= 100
        else { throw NotificationPolicyRemoteError.invalidResponse }
        let defaultPolicy = try decodeDefaultState(defaultObject)
        var mailboxIDs = Set<LogicalMailboxID>()
        var mailboxPolicies: [NodeSyncNotificationPolicy] = []
        var mailboxStates: [DirectNotificationPolicyMailboxState] = []
        for object in mailboxObjects {
            guard let mailboxString = object["logicalMailboxID"] as? String,
                  let bytes = try? AccountWireCodec.decodeBase64URL(mailboxString, exactBytes: 32),
                  let mailbox = LogicalMailboxID(rawValue: bytes) else {
                throw NotificationPolicyRemoteError.invalidResponse
            }
            guard mailboxIDs.insert(mailbox).inserted else { throw NotificationPolicyRemoteError.invalidResponse }
            let state = try decodeCentralState(object)
            mailboxStates.append(try DirectNotificationPolicyMailboxState(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: state.override))
            if !state.override {
                guard state.version == defaultPolicy.version,
                      // A zero scope version is an ordinary inherited row;
                      // a positive scope version is an inactive tombstone
                      // retaining the mailbox high-water mark. Both must
                      // carry the current effective default.
                      state.mode == defaultPolicy.mode else { throw NotificationPolicyRemoteError.invalidResponse }
                continue
            }
            guard state.version != "0", state.version == state.scopeVersion else { throw NotificationPolicyRemoteError.invalidResponse }
            mailboxPolicies.append(try NodeSyncNotificationPolicy(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: true))
        }
        return DirectNotificationPolicySnapshot(defaultPolicy: defaultPolicy, mailboxPolicies: mailboxPolicies, mailboxStates: mailboxStates)
    }

    public func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        guard request.expectedVersion != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        let directRequest = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: request.logicalMailboxID, mode: request.mode, clear: request.clear, expectedVersion: request.expectedVersion, idempotencyKey: request.idempotencyKey)
        let state = try await updateDirectNotificationPolicy(directRequest)
        guard state.version != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        guard let mailbox = state.logicalMailboxID, state.scopeVersion != "0" else {
            // Central default scopeVersion is zero and therefore cannot be
            // represented by the positive-scope Node DTO.
            throw NotificationPolicyRemoteError.invalidResponse
        }
        return try NodeSyncNotificationPolicy(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: state.override)
    }

    public func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState {
        guard let expected = UInt64(request.expectedVersion), expected < 65_535 else { throw NotificationPolicyRemoteError.conflict }
        let expectedNext = String(expected + 1)
        let context = try await currentContext()
        let nonce = Data(SHA256.hash(data: Data(request.idempotencyKey.utf8)))
        let mutation = DirectPolicyRequestFields(
            accountID: context.credentials.accountID,
            actorDeviceID: context.credentials.deviceID,
            logicalMailboxID: request.logicalMailboxID,
            mode: request.clear ? "" : directPolicyMode(request.mode),
            clear: request.clear,
            expectedVersion: request.expectedVersion,
            nonce: nonce
        )
        let digest = directPolicyDigest(mutation)
        var body: [String: Any] = [
            "kind": request.clear ? "notification.direct-policy-clear.v1" : "notification.direct-policy-update.v1",
            "expectedVersion": request.expectedVersion,
            "requestNonce": AccountWireCodec.encodeBase64URL(nonce),
            "requestDigest": AccountWireCodec.encodeBase64URL(digest)
        ]
        if !request.clear { body["policy"] = directPolicyMode(request.mode) }
        let encodedBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let path: String
        if let logicalMailboxID = request.logicalMailboxID {
            path = "/v1/notifications/direct-policies/mailboxes/" + AccountWireCodec.encodeBase64URL(logicalMailboxID.rawValue)
        } else {
            path = "/v1/notifications/direct-policies/default"
        }
        let response = try await api.sendAccountRequestResult(
            method: request.clear ? "DELETE" : "PUT", path: path, body: encodedBody,
            credentials: context.credentials, device: context.device,
            maximumRequestBytes: 16 * 1024, maximumResponseBytes: 16 * 1024
        )
        let resultBody = try responseBody(response)
        guard StrictJSONKeyScanner(data: resultBody).isValid else { throw NotificationPolicyRemoteError.invalidResponse }
        guard let object = try JSONSerialization.jsonObject(with: resultBody) as? [String: Any],
              Set(object.keys) == Set(["kind", "logicalMailboxID", "policy", "version", "scopeVersion", "override"])
                || Set(object.keys) == Set(["kind", "policy", "version", "scopeVersion", "override"]),
              object["kind"] as? String == "notification.direct-policy-result.v1"
        else { throw NotificationPolicyRemoteError.invalidResponse }
        var stateObject = object
        stateObject.removeValue(forKey: "kind")
        let state = try decodeCentralState(stateObject)
        if let mailbox = request.logicalMailboxID {
            guard stateObject["logicalMailboxID"] as? String == AccountWireCodec.encodeBase64URL(mailbox.rawValue),
                  state.scopeVersion != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
            if request.clear {
                // A clear returns the inherited effective policy. With no
                // persisted default, its effective version is legitimately
                // zero while the mailbox scope retains a positive high-water.
                guard !state.override else { throw NotificationPolicyRemoteError.invalidResponse }
                guard state.scopeVersion == expectedNext else { throw NotificationPolicyRemoteError.conflict }
                if state.version == "0" {
                    guard state.mode == .richPreview else { throw NotificationPolicyRemoteError.invalidResponse }
                    return try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: false)
                }
                return try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: false)
            }
            guard state.override, state.version == expectedNext, state.scopeVersion == expectedNext,
                  state.mode == request.mode else { throw NotificationPolicyRemoteError.conflict }
            return try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: true)
        } else {
            guard stateObject["logicalMailboxID"] == nil, !request.clear,
                  state.scopeVersion == "0", !state.override, state.version == expectedNext,
                  state.mode == request.mode else { throw NotificationPolicyRemoteError.conflict }
            return try DirectNotificationPolicyState(logicalMailboxID: nil, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: false)
        }
    }

    private func currentContext() async throws -> NotificationAccountContext {
        do { return try await sessions.current() }
        catch is CancellationError { throw CancellationError() }
        catch {
            // A superseded operation must not publish an unavailable state
            // merely because its synchronous session lookup failed while the
            // task was already cancelled.
            try Task.checkCancellation()
            throw NotificationPolicyRemoteError.unavailable
        }
    }

    private func responseBody(_ response: AccountAPIRequestResult) throws -> Data {
        switch response {
        case .success(let body): return body
        case .httpFailure(let statusCode):
            switch statusCode {
            case 401, 403: throw NotificationPolicyRemoteError.unauthorized
            case 409: throw NotificationPolicyRemoteError.conflict
            case 503, 500 ... 599: throw NotificationPolicyRemoteError.unavailable
            default: throw NotificationPolicyRemoteError.invalidResponse
            }
        }
    }

    private func decodeDefaultState(_ object: [String: Any]) throws -> DirectNotificationPolicyState {
        let state = try decodeCentralState(object)
        guard !state.override, state.scopeVersion == "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        if state.version == "0" {
            guard state.mode == .richPreview else { throw NotificationPolicyRemoteError.invalidResponse }
            return try DirectNotificationPolicyState(logicalMailboxID: nil, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: false)
        }
        return try DirectNotificationPolicyState(logicalMailboxID: nil, mode: state.mode, version: state.version, scopeVersion: state.scopeVersion, override: false)
    }

    private func decodeCentralState(_ object: [String: Any]) throws -> (mode: NodeSyncNotificationPolicyMode, version: String, scopeVersion: String, override: Bool) {
        guard Set(object.keys) == ["logicalMailboxID", "policy", "version", "scopeVersion", "override"]
                || Set(object.keys) == ["policy", "version", "scopeVersion", "override"],
              let policy = object["policy"] as? String,
              let mode = nodeMode(policy),
              let version = object["version"] as? String,
              let scopeVersion = object["scopeVersion"] as? String,
              let versionValue = directPolicyVersion(version),
              let scopeValue = directPolicyVersion(scopeVersion),
              let override = strictJSONBool(object["override"]) else {
            throw NotificationPolicyRemoteError.invalidResponse
        }
        if versionValue == 0 && (mode != .richPreview || override) { throw NotificationPolicyRemoteError.invalidResponse }
        if override && (versionValue == 0 || scopeValue == 0 || versionValue != scopeValue) { throw NotificationPolicyRemoteError.invalidResponse }
        return (mode, version, scopeVersion, override)
    }

    private func nodeMode(_ value: String) -> NodeSyncNotificationPolicyMode? {
        switch value {
        case "rich": .richPreview
        case "sender_subject": .senderSubject
        case "generic": .generic
        case "off": .off
        default: nil
        }
    }

    private func directPolicyMode(_ mode: NodeSyncNotificationPolicyMode) -> String {
        switch mode {
        case .richPreview: "rich"
        case .senderSubject: "sender_subject"
        case .generic: "generic"
        case .off: "off"
        }
    }

    private func directPolicyVersion(_ value: String) -> UInt16? {
        guard !value.isEmpty, (value == "0" || !value.hasPrefix("0")), let parsed = UInt64(value), parsed <= 65_535 else { return nil }
        return UInt16(parsed)
    }
}

/// Re-resolves the account-owner producer assignment for every policy
/// operation. A mailbox never falls back to an unrelated assignment, and a
/// producer change between the read and write side of a CAS operation is a
/// conflict rather than an opportunity to reuse a stale remote.
public final class NotificationAssignmentPolicyRemote: NotificationPolicyRemote, NotificationPolicyAssignmentAccess, @unchecked Sendable {
    private let assignments: @Sendable () async throws -> [NotificationProducerAssignment]
    private let direct: any NotificationPolicyRemote
    private let syncNode: any NotificationPolicyRemote

    public init(
        assignments: @escaping @Sendable () async throws -> [NotificationProducerAssignment],
        direct: any NotificationPolicyRemote,
        syncNode: any NotificationPolicyRemote
    ) {
        self.assignments = assignments; self.direct = direct; self.syncNode = syncNode
    }

    public func notificationPolicy(for logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        let resolved = try await resolve(logicalMailboxID: logicalMailboxID)
        return try await nodeRead(resolved.remote, logicalMailboxID: logicalMailboxID)
    }

    public func notificationPolicyPresentation(for logicalMailboxID: LogicalMailboxID) async throws -> NotificationPolicyPresentationState {
        let resolved = try await resolve(logicalMailboxID: logicalMailboxID)
        return try await presentation(for: resolved, logicalMailboxID: logicalMailboxID)
    }

    public func updateNotificationPolicyPresentation(
        for logicalMailboxID: LogicalMailboxID,
        mode: NodeSyncNotificationPolicyMode,
        clear: Bool,
        idempotencyKey: String
    ) async throws -> NotificationPolicyPresentationState {
        let first = try await resolve(logicalMailboxID: logicalMailboxID)
        let current = try await presentation(for: first, logicalMailboxID: logicalMailboxID)
        let second = try await resolve(logicalMailboxID: logicalMailboxID)
        guard first.assignment == second.assignment else { throw NotificationPolicyRemoteError.conflict }
        try Task.checkCancellation()

        switch second.assignment.kind {
        case .mac:
            guard let directRemote = second.remote as? any DirectNotificationPolicyAccess else {
                throw NotificationPolicyRemoteError.conflict
            }
            let request = try DirectNotificationPolicyUpdateRequest(
                logicalMailboxID: logicalMailboxID,
                mode: clear ? current.mode : mode,
                clear: clear,
                expectedVersion: current.scopeVersion,
                idempotencyKey: idempotencyKey
            )
            return NotificationPolicyPresentationState(directState: try await directRemote.updateDirectNotificationPolicy(request))
        case .syncNode:
            let request = try NodeSyncNotificationPolicyUpdateRequest(
                logicalMailboxID: logicalMailboxID,
                mode: clear ? nil : mode,
                clear: clear,
                expectedVersion: current.version,
                idempotencyKey: idempotencyKey
            )
            return try NotificationPolicyPresentationState(nodePolicy: await nodeUpdate(second.remote, request: request))
        }
    }

    public func directDefaultPolicy() async throws -> DirectNotificationPolicyState {
        let values = try await assignments()
        guard values.contains(where: { $0.kind == .mac }) else { throw NotificationPolicyRemoteError.conflict }
        if let remote = direct as? any DirectNotificationPolicyAccess {
            return try await remote.directDefaultPolicy()
        }
        let policy = try await nodeRead(direct, logicalMailboxID: nil)
        return try DirectNotificationPolicyState(logicalMailboxID: nil, mode: policy.mode, version: policy.version, scopeVersion: "0", override: false)
    }

    public func directPolicy(for logicalMailboxID: LogicalMailboxID) async throws -> DirectNotificationPolicyState {
        let resolved = try await resolve(logicalMailboxID: logicalMailboxID)
        guard resolved.assignment.kind == .mac else { throw NotificationPolicyRemoteError.conflict }
        if let remote = resolved.remote as? any DirectNotificationPolicyAccess {
            return try await remote.directPolicy(for: logicalMailboxID)
        }
        let policy = try await nodeRead(resolved.remote, logicalMailboxID: logicalMailboxID)
        return try DirectNotificationPolicyState(logicalMailboxID: logicalMailboxID, mode: policy.mode, version: policy.version, scopeVersion: policy.scopeVersion, override: policy.override)
    }

    public func updateDirectNotificationPolicy(_ request: DirectNotificationPolicyUpdateRequest) async throws -> DirectNotificationPolicyState {
        guard let mailbox = request.logicalMailboxID else {
            let first = try await assignments()
            guard let firstMac = first.first(where: { $0.kind == .mac }) else { throw NotificationPolicyRemoteError.conflict }
            let second = try await assignments()
            guard let secondMac = second.first(where: { $0.kind == .mac }), firstMac == secondMac else {
                throw NotificationPolicyRemoteError.conflict
            }
            if let remote = direct as? any DirectNotificationPolicyAccess {
                return try await remote.updateDirectNotificationPolicy(request)
            }
            guard request.expectedVersion != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
            let nodeRequest = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: nil, mode: request.mode, expectedVersion: request.expectedVersion, idempotencyKey: request.idempotencyKey)
            let policy = try await nodeUpdate(direct, request: nodeRequest)
            return try DirectNotificationPolicyState(logicalMailboxID: nil, mode: policy.mode, version: policy.version, scopeVersion: "0", override: false)
        }
        let first = try await resolve(logicalMailboxID: mailbox)
        let second = try await resolve(logicalMailboxID: mailbox)
        guard first.assignment == second.assignment, second.assignment.kind == .mac else { throw NotificationPolicyRemoteError.conflict }
        if let remote = second.remote as? any DirectNotificationPolicyAccess {
            return try await remote.updateDirectNotificationPolicy(request)
        }
        guard request.expectedVersion != "0" else { throw NotificationPolicyRemoteError.invalidResponse }
        let nodeRequest = try NodeSyncNotificationPolicyUpdateRequest(
            logicalMailboxID: mailbox,
            mode: request.clear ? nil : request.mode,
            clear: request.clear,
            expectedVersion: request.expectedVersion,
            idempotencyKey: request.idempotencyKey
        )
        let policy = try await nodeUpdate(second.remote, request: nodeRequest)
        return try DirectNotificationPolicyState(logicalMailboxID: mailbox, mode: policy.mode, version: policy.version, scopeVersion: policy.scopeVersion, override: policy.override)
    }

    /// Materializes the shared default independently in every authoritative
    /// producer present in the current assignment set. This is what makes a
    /// mixed Mac/Sync Node account deterministic: a successful registration
    /// cannot be obtained by reading or writing whichever assignment happened
    /// to be returned first.
    public func persistDefaultPolicy(mode: NodeSyncNotificationPolicyMode) async throws {
        let initial = try await authorityRemotes()
        for authority in initial {
            try Task.checkCancellation()
            let currentMode: NodeSyncNotificationPolicyMode
            let currentVersion: String
            if authority.assignment.kind == .mac, let directRemote = authority.remote as? any DirectNotificationPolicyAccess {
                let current = try await directRemote.directDefaultPolicy()
                currentMode = current.mode
                currentVersion = current.version
            } else {
                let current = try await nodeRead(authority.remote, logicalMailboxID: nil)
                currentMode = current.mode
                currentVersion = current.version
            }
            guard currentMode != mode || currentVersion == "0" else { continue }
            let beforeMutation = try await authorityRemotes()
            guard beforeMutation.map(\.assignment) == initial.map(\.assignment) else { throw NotificationPolicyRemoteError.conflict }
            if authority.assignment.kind == .mac, let directRemote = authority.remote as? any DirectNotificationPolicyAccess {
                let request = try DirectNotificationPolicyUpdateRequest(logicalMailboxID: nil, mode: mode, expectedVersion: currentVersion, idempotencyKey: UUID().uuidString.lowercased())
                _ = try await directRemote.updateDirectNotificationPolicy(request)
            } else {
                let request = try NodeSyncNotificationPolicyUpdateRequest(logicalMailboxID: nil, mode: mode, expectedVersion: currentVersion, idempotencyKey: UUID().uuidString.lowercased())
                _ = try await nodeUpdate(authority.remote, request: request)
            }
        }
        let final = try await authorityRemotes()
        guard final.map(\.assignment) == initial.map(\.assignment) else { throw NotificationPolicyRemoteError.conflict }
        for authority in final {
            if authority.assignment.kind == .mac, let directRemote = authority.remote as? any DirectNotificationPolicyAccess {
                let policy = try await directRemote.directDefaultPolicy()
                guard policy.mode == mode, policy.version != "0" else { throw NotificationPolicyRemoteError.conflict }
            } else {
                let policy = try await nodeRead(authority.remote, logicalMailboxID: nil)
                guard policy.mode == mode, policy.version != "0" else { throw NotificationPolicyRemoteError.conflict }
            }
        }
    }

    public func updateNotificationPolicy(_ request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        let first = try await resolve(logicalMailboxID: request.logicalMailboxID)
        let second = try await resolve(logicalMailboxID: request.logicalMailboxID)
        guard first.assignment == second.assignment else { throw NotificationPolicyRemoteError.conflict }
        try Task.checkCancellation()
        return try await nodeUpdate(second.remote, request: request)
    }

    private func presentation(
        for resolved: (assignment: NotificationProducerAssignment, remote: any NotificationPolicyRemote),
        logicalMailboxID: LogicalMailboxID
    ) async throws -> NotificationPolicyPresentationState {
        switch resolved.assignment.kind {
        case .mac:
            guard let directRemote = resolved.remote as? any DirectNotificationPolicyAccess else {
                throw NotificationPolicyRemoteError.conflict
            }
            return NotificationPolicyPresentationState(directState: try await directRemote.directPolicy(for: logicalMailboxID))
        case .syncNode:
            return try NotificationPolicyPresentationState(nodePolicy: await nodeRead(resolved.remote, logicalMailboxID: logicalMailboxID))
        }
    }

    private func nodeRead(_ remote: any NotificationPolicyRemote, logicalMailboxID: LogicalMailboxID?) async throws -> NodeSyncNotificationPolicy {
        do {
            return try await remote.notificationPolicy(for: logicalMailboxID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSyncClientError {
            switch error {
            case .conflict, .problem(.conflict): throw NotificationPolicyRemoteError.conflict
            case .cancelled, .cancelledAfterDispatch: throw CancellationError()
            default: throw error
            }
        }
    }

    private func nodeUpdate(_ remote: any NotificationPolicyRemote, request: NodeSyncNotificationPolicyUpdateRequest) async throws -> NodeSyncNotificationPolicy {
        do {
            return try await remote.updateNotificationPolicy(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NodeSyncClientError {
            switch error {
            case .conflict, .problem(.conflict): throw NotificationPolicyRemoteError.conflict
            case .cancelled, .cancelledAfterDispatch: throw CancellationError()
            default: throw error
            }
        }
    }

    private func resolve(logicalMailboxID: LogicalMailboxID?) async throws -> (assignment: NotificationProducerAssignment, remote: any NotificationPolicyRemote) {
        try Task.checkCancellation()
        let values = try await assignments()
        let assignment: NotificationProducerAssignment
        if let logicalMailboxID {
            guard let exact = values.first(where: { $0.logicalMailboxID == logicalMailboxID.rawValue }) else { throw NotificationPolicyRemoteError.conflict }
            assignment = exact
        } else {
            guard let mac = values.first(where: { $0.kind == .mac })
                    ?? values.first(where: { $0.kind == .syncNode }) else {
                throw NotificationPolicyRemoteError.conflict
            }
            assignment = mac
        }
        return (assignment, assignment.kind == .mac ? direct : syncNode)
    }

    private func authorityRemotes() async throws -> [(assignment: NotificationProducerAssignment, remote: any NotificationPolicyRemote)] {
        try Task.checkCancellation()
        let values = try await assignments()
        guard !values.isEmpty else { throw NotificationPolicyRemoteError.conflict }
        var result: [(assignment: NotificationProducerAssignment, remote: any NotificationPolicyRemote)] = []
        if let mac = values.first(where: { $0.kind == .mac }) { result.append((mac, direct)) }
        if let syncAssignment = values.first(where: { $0.kind == .syncNode }) { result.append((syncAssignment, syncNode)) }
        return result
    }
}

private func strictJSONBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
    return number.boolValue
}

/// JSONSerialization intentionally accepts duplicate object names and loses
/// the original spelling. Scan the bounded response first so Central state
/// cannot be changed by a last-key-wins ambiguity.
private struct StrictJSONKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    var isValid: Bool {
        var scanner = self
        do {
            try scanner.value(depth: 0)
            scanner.whitespace()
            return scanner.index == scanner.bytes.count
        } catch { return false }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw ScanError.invalid }
        whitespace()
        guard let byte = peek else { throw ScanError.invalid }
        switch byte {
        case 0x7B: try object(depth: depth + 1)
        case 0x5B: try array(depth: depth + 1)
        case 0x22: _ = try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        case 0x2D, 0x30 ... 0x39: try number()
        default: throw ScanError.invalid
        }
    }

    private mutating func object(depth: Int) throws {
        try consume(0x7B)
        whitespace()
        var keys = Set<String>()
        if peek == 0x7D { index += 1; return }
        while true {
            guard peek == 0x22 else { throw ScanError.invalid }
            let key = try string()
            guard keys.insert(key).inserted else { throw ScanError.duplicate }
            whitespace(); try consume(0x3A); try value(depth: depth)
            whitespace()
            if peek == 0x7D { index += 1; return }
            try consume(0x2C); whitespace()
        }
    }

    private mutating func array(depth: Int) throws {
        try consume(0x5B)
        whitespace()
        if peek == 0x5D { index += 1; return }
        while true {
            try value(depth: depth)
            whitespace()
            if peek == 0x5D { index += 1; return }
            try consume(0x2C); whitespace()
        }
    }

    private mutating func string() throws -> String {
        let start = index
        try consume(0x22)
        while let byte = peek {
            index += 1
            if byte == 0x22 {
                let token = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else { throw ScanError.invalid }
                return value
            }
            if byte == 0x5C {
                guard let escaped = peek else { throw ScanError.invalid }
                index += 1
                if escaped == 0x75 {
                    guard index + 4 <= bytes.count, bytes[index..<index + 4].allSatisfy(Self.isHex) else { throw ScanError.invalid }
                    index += 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw ScanError.invalid
                }
            } else if byte < 0x20 { throw ScanError.invalid }
        }
        throw ScanError.invalid
    }

    private mutating func number() throws {
        let start = index
        while let byte = peek, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(byte) { index += 1 }
        guard start < index, let token = String(bytes: bytes[start..<index], encoding: .utf8),
              let data = token.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { throw ScanError.invalid }
    }

    private mutating func literal(_ literal: String) throws {
        let end = index + literal.utf8.count
        guard end <= bytes.count, bytes[index..<end].elementsEqual(literal.utf8) else { throw ScanError.invalid }
        index = end
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek == expected else { throw ScanError.invalid }
        index += 1
    }

    private mutating func whitespace() {
        while let byte = peek, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
    }

    private enum ScanError: Error { case invalid, duplicate }
}

private struct DirectPolicyRequestFields {
    let accountID: PlainpostAccountID
    let actorDeviceID: AccountDeviceID
    let logicalMailboxID: LogicalMailboxID?
    let mode: String
    let clear: Bool
    let expectedVersion: String
    let nonce: Data
}

private func directPolicyDigest(_ fields: DirectPolicyRequestFields) -> Data {
    var transcript = Data()
    func append(_ value: Data) {
        var length = UInt32(value.count).bigEndian
        transcript.append(Data(bytes: &length, count: 4)); transcript.append(value)
    }
    append(Data("Plainpost.DirectNotificationPolicyRequest.v1".utf8))
    append(uuidBytes(fields.accountID.rawValue)); append(uuidBytes(fields.actorDeviceID.rawValue))
    append(Data(fields.logicalMailboxID == nil ? "default".utf8 : "mailbox".utf8))
    append(fields.logicalMailboxID?.rawValue ?? Data())
    append(Data((fields.clear ? "clear" : "set").utf8)); append(Data(fields.mode.utf8))
    var expected = UInt16(fields.expectedVersion) ?? 0
    expected = expected.bigEndian
    append(Data(bytes: &expected, count: 2)); append(fields.nonce)
    return Data(SHA256.hash(data: transcript))
}

private func uuidBytes(_ value: String) -> Data {
    guard var uuid = UUID(uuidString: value)?.uuid else { return Data(value.utf8) }
    return withUnsafeBytes(of: &uuid) { Data($0) }
}

/// Authenticated Central adapters for the Mac producer. All requests go
/// through AccountAPIClient, which supplies the account Bearer credential and
/// DPoP proof bound to the exact method, path and body digest.
public final class AuthenticatedNotificationCoordinationClient: CoordinationClient, RecipientAssignmentVerifying, @unchecked Sendable {
    private let sessions: NotificationAccountSession

    public init(api: AccountAPIClient, credentialStore: AccountCredentialStore, refreshLockURL: URL? = nil) {
        self.sessions = NotificationAccountSession(api: api, store: credentialStore, refreshLockURL: refreshLockURL)
    }

    public func recipientAssignment(for source: NotificationPublicationSource, claim: NotificationPublicationClaim) async throws -> NotificationRecipientAssignment {
        let context = try await sessions.current()
        let credentials = context.credentials
        let device = context.device
        guard source.plainpostAccountID.rawValue == credentials.accountID.rawValue,
              claim.producerDeviceID == credentials.deviceID.rawValue,
              claim.producerKind == "mac",
              source.logicalMailboxIDBytes.count == 32,
              source.logicalMailboxIDBytes.contains(where: { $0 != 0 }),
              claim.producerGeneration > 0,
              claim.policyVersion > 0 else { throw NotificationRuntimeError.staleAssignment }
        guard let commit = try sessions.store.loadCurrentTrustCommit(for: credentials.accountID) else {
            throw NotificationRuntimeError.unavailable
        }
        let head = AccountTranscript.trustCommitDigest(commit)
        let body: [String: Any] = [
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(source.logicalMailboxIDBytes),
            "producerDeviceID": credentials.deviceID.rawValue,
            "producerKind": "mac",
            "generation": claim.producerGeneration,
            "trustEpoch": commit.state.epoch.value,
            "trustRevision": commit.state.revision.value,
            "trustHead": AccountWireCodec.encodeBase64URL(head),
        ]
        let request = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let response = try await sessions.api.sendAccountRequest(
            method: "POST", path: "/v1/notifications/producers/recipients/query", body: request,
            credentials: credentials, device: device, maximumRequestBytes: 16 * 1024,
            maximumResponseBytes: 512 * 1024
        )
        let records = try parseRecords(response, source: source, claim: claim, commit: commit, head: head)
        guard !records.isEmpty else { throw NotificationRuntimeError.staleAssignment }
        var snapshots: [NotificationRecipientSnapshot] = []
        var signed = Data()
        var seen = Set<String>()
        for record in records {
            try verify(record: record, source: source, claim: claim, commit: commit, head: head)
            guard seen.insert(record.recipientID).inserted else { throw NotificationRuntimeError.invalidAssignment }
            signed.append(record.raw)
            snapshots.append(NotificationRecipientSnapshot(
                recipientID: record.recipientID,
                routingHandle: record.routingHandle,
                agreementPublicKey: record.agreementPublicKey,
                producerDeviceID: credentials.deviceID.rawValue,
                producerGeneration: claim.producerGeneration,
                policyVersion: claim.policyVersion
            ))
        }
        return NotificationRecipientAssignment(
            recipients: snapshots,
            signedBytes: signed,
            signature: Data(SHA256.hash(data: signed)),
            signerDeviceID: credentials.deviceID.rawValue,
            configVersion: claim.configVersion,
            producerGeneration: claim.producerGeneration,
            policyVersion: claim.policyVersion
        )
    }

    public func verify(assignment: NotificationRecipientAssignment, source: NotificationPublicationSource) throws {
        let context = try sessions.snapshot()
        let credentials = context.credentials
        guard source.plainpostAccountID.rawValue == credentials.accountID.rawValue,
              assignment.signerDeviceID == credentials.deviceID.rawValue,
              assignment.signature == Data(SHA256.hash(data: assignment.signedBytes)),
              !assignment.recipients.isEmpty else { throw NotificationRuntimeError.invalidAssignment }
        guard let commit = try sessions.store.loadCurrentTrustCommit(for: credentials.accountID) else {
            throw NotificationRuntimeError.unavailable
        }
        let head = AccountTranscript.trustCommitDigest(commit)
        var offset = 0
        var seen = Set<String>()
        for recipient in assignment.recipients {
            guard seen.insert(recipient.recipientID).inserted,
                  offset + PPR2Record.byteCount <= assignment.signedBytes.count else { throw NotificationRuntimeError.invalidAssignment }
            let end = offset + PPR2Record.byteCount
            let record = try PPR2Record(raw: Data(assignment.signedBytes[offset..<end]))
            guard record.recipientID == recipient.recipientID,
                  record.routingHandle == recipient.routingHandle,
                  record.agreementPublicKey == recipient.agreementPublicKey else { throw NotificationRuntimeError.invalidAssignment }
            try verify(record: record, source: source, claim: nil, commit: commit, head: head)
            offset = end
        }
        guard offset == assignment.signedBytes.count else { throw NotificationRuntimeError.invalidAssignment }
    }

    private func verify(record: PPR2Record, source: NotificationPublicationSource, claim: NotificationPublicationClaim?, commit: AccountTrustStateCommit, head: Data) throws {
        let credentials = try sessions.snapshot().credentials
        guard record.accountID == credentials.accountID,
              record.epoch == commit.state.epoch.value,
              record.revision == commit.state.revision.value,
              record.trustHead == head,
              let member = commit.state.members.first(where: { $0.deviceID.rawValue == record.recipientID }) else {
            throw NotificationRuntimeError.staleAssignment
        }
        if let claim {
            guard record.assignmentGeneration == UInt64(claim.producerGeneration) else { throw NotificationRuntimeError.staleAssignment }
        }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: member.publicBundle.signingKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: record.signature),
              publicKey.isValidSignature(signature, for: record.transcript) else {
            throw NotificationRuntimeError.invalidAssignment
        }
    }

    private struct PPR2Record {
        static let byteCount = 285
        let raw: Data
        let accountID: PlainpostAccountID
        let recipientDeviceID: AccountDeviceID
        let logicalMailboxID: Data
        let assignmentGeneration: UInt64
        let epoch: UInt64
        let revision: UInt64
        let trustHead: Data
        let routingHandle: Data
        let agreementPublicKey: Data
        let signature: Data

        init(raw: Data, assignmentGeneration: UInt64? = nil) throws {
            guard raw.count == Self.byteCount, raw.prefix(4) == Data("PPR2".utf8) else { throw NotificationRuntimeError.invalidAssignment }
            let accountBytes = Data(raw[4..<20])
            let recipientBytes = Data(raw[20..<36])
            let accountUUID = UUID(uuid: accountBytes.uuidTuple)
            let recipientUUID = UUID(uuid: recipientBytes.uuidTuple)
            self.raw = raw
            self.accountID = try PlainpostAccountID(accountUUID.uuidString.lowercased())
            self.recipientDeviceID = try AccountDeviceID(recipientUUID.uuidString.lowercased())
            self.logicalMailboxID = Data(raw[36..<68])
            self.assignmentGeneration = raw.u64(at: 68)
            self.epoch = raw.u64(at: 76)
            self.revision = raw.u64(at: 84)
            self.trustHead = Data(raw[92..<124])
            self.routingHandle = Data(raw[124..<156])
            self.agreementPublicKey = Data(raw[156..<221])
            self.signature = Data(raw[221..<285])
            guard logicalMailboxID.contains(where: { $0 != 0 }), self.assignmentGeneration > 0,
                  assignmentGeneration.map({ $0 == self.assignmentGeneration }) ?? true else {
                throw NotificationRuntimeError.invalidAssignment
            }
        }

        var recipientID: String { recipientDeviceID.rawValue }

        var transcript: Data {
            NotificationRecipientRegistration.signingTranscript(
                accountID: accountID, deviceID: recipientDeviceID,
                logicalMailboxID: logicalMailboxID, assignmentGeneration: assignmentGeneration,
                epoch: epoch, revision: revision, trustHead: trustHead,
                routingHandle: routingHandle, agreementPublicKey: agreementPublicKey
            )
        }
    }

    private func parseRecords(_ data: Data, source: NotificationPublicationSource, claim: NotificationPublicationClaim, commit: AccountTrustStateCommit, head: Data) throws -> [PPR2Record] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys) == Set(["kind", "records"]),
              envelope["kind"] as? String == "notification.producer-recipients.v2",
              let root = envelope["records"] as? [[String: Any]], !root.isEmpty else { throw NotificationRuntimeError.invalidAssignment }
        return try root.map { object in
            guard Set(object.keys) == Set(["logicalMailboxID", "recipientDeviceID", "assignmentGeneration", "trustEpoch", "trustRevision", "trustHead", "signedRecord"]) else { throw NotificationRuntimeError.invalidAssignment }
            guard let signed = object["signedRecord"], let generation = (object["assignmentGeneration"] as? NSNumber)?.uint64Value,
                  let trustEpoch = (object["trustEpoch"] as? NSNumber)?.uint64Value,
                  let trustRevision = (object["trustRevision"] as? NSNumber)?.uint64Value,
                  let recipient = object["recipientDeviceID"] as? String,
                  let recipientID = try? AccountDeviceID(recipient).rawValue,
                  let decodedMailbox = try? AccountWireCodec.decodeBase64URL(object["logicalMailboxID"] as? String ?? "", exactBytes: 32),
                  let decodedHead = try? AccountWireCodec.decodeBase64URL(object["trustHead"] as? String ?? "", exactBytes: 32) else { throw NotificationRuntimeError.invalidAssignment }
            guard generation == UInt64(claim.producerGeneration),
                  decodedMailbox == source.logicalMailboxIDBytes,
                  decodedHead == head, trustEpoch == commit.state.epoch.value, trustRevision == commit.state.revision.value else { throw NotificationRuntimeError.staleAssignment }
            let record = try PPR2Record(raw: decodeBytes(signed), assignmentGeneration: generation)
            guard record.recipientID == recipientID,
                  record.logicalMailboxID == source.logicalMailboxIDBytes,
                  record.assignmentGeneration == generation else { throw NotificationRuntimeError.invalidAssignment }
            return record
        }
    }

    private func decodeBytes(_ value: Any?) throws -> Data {
        guard let value else { throw NotificationRuntimeError.invalidAssignment }
        if let string = value as? String, let data = try? AccountWireCodec.decodeBase64URL(string) { return data }
        if let values = value as? [NSNumber] { return Data(values.map { UInt8(truncating: $0) }) }
        throw NotificationRuntimeError.invalidAssignment
    }

}

public final class AuthenticatedNotificationRelayClient: RelayClient, @unchecked Sendable {
    private let sessions: NotificationAccountSession
    private let clock: @Sendable () -> Date

    public init(api: AccountAPIClient, credentialStore: AccountCredentialStore, refreshLockURL: URL? = nil, clock: @escaping @Sendable () -> Date = Date.init) {
        self.sessions = NotificationAccountSession(api: api, store: credentialStore, refreshLockURL: refreshLockURL); self.clock = clock
    }

    public func deliver(_ delivery: NotificationDeliveryClaim) async throws -> NotificationRelayResult {
        let context = try await sessions.current()
        let credentials = context.credentials
        let device = context.device
        guard delivery.envelopeBytes.count <= 4096,
              delivery.envelopeBytes.first == 0x50,
              let producer = delivery.producerDeviceID,
              producer == credentials.deviceID.rawValue else { throw NotificationRuntimeError.invalidEnvelope }
        let body = try JSONSerialization.data(withJSONObject: [
            "kind": "producer.notification.submit.v2",
            "envelope": AccountWireCodec.encodeBase64URL(delivery.envelopeBytes)
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        do {
            let responseResult = try await sessions.api.sendAccountRequestResult(
                method: "POST", path: "/v1/notifications", body: body,
                credentials: credentials, device: device, maximumRequestBytes: 8 * 1024,
                maximumResponseBytes: 8 * 1024
            )
            let response: Data
            switch responseResult {
            case .success(let data):
                response = data
            case .httpFailure(let statusCode):
                return Self.classifyHTTPFailure(statusCode: statusCode, retryAt: clock().addingTimeInterval(30))
            }
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object.keys.count == 2,
                  object["kind"] as? String == "producer.notification.submit-response.v2",
                  let raw = object["outcome"] as? String,
                  let outcome = NotificationDeliveryOutcome(rawValue: raw) else {
                throw NotificationRuntimeError.invalidAssignment
            }
            return NotificationRelayResult(outcome: outcome)
        } catch let error as NotificationRuntimeError { throw error }
        catch {
            // Network and local transport failures are uncertain. The durable
            // drain replays the same frozen bytes after the bounded backoff.
            return NotificationRelayResult(outcome: .retryable, nextAttemptAt: clock().addingTimeInterval(30))
        }
    }

    static func classifyHTTPFailure(statusCode: Int, retryAt: Date) -> NotificationRelayResult {
        if statusCode == 401 || statusCode == 403 { return NotificationRelayResult(outcome: .revoked) }
        if statusCode == 400 || statusCode == 422 { return NotificationRelayResult(outcome: .malformed) }
        if statusCode == 404 { return NotificationRelayResult(outcome: .revoked) }
        if statusCode == 409 { return NotificationRelayResult(outcome: .rejected) }
        if statusCode == 429 || (500 ... 599).contains(statusCode) {
            return NotificationRelayResult(outcome: .retryable, nextAttemptAt: retryAt)
        }
        return NotificationRelayResult(outcome: .rejected)
    }
}

public enum NotificationProducerSelectionState: Sendable, Equatable {
    case selected(generation: UInt64)
    case conflict
    case unavailable
}

/// The only producer kinds Central may select. The platform binding prevents
/// an iOS actor from accidentally presenting itself as the Mac producer (or
/// sending a Mac credential when selecting a Sync Node).
public enum NotificationProducerKind: String, Sendable, Equatable {
    case mac
    case syncNode = "sync_node"

    public var platform: AccountPlatform {
        switch self {
        case .mac: .macos
        case .syncNode: .syncNode
        }
    }
}

public struct NotificationProducerTarget: Sendable, Equatable, Identifiable {
    public let deviceID: AccountDeviceID
    public let kind: NotificationProducerKind
    /// Last server generation known by the caller. Zero is the initial CAS
    /// generation; a successful selection returns the durable successor.
    public let expectedGeneration: UInt64

    public var id: String { deviceID.rawValue }

    public init(deviceID: AccountDeviceID, kind: NotificationProducerKind, expectedGeneration: UInt64 = 0) {
        self.deviceID = deviceID; self.kind = kind; self.expectedGeneration = expectedGeneration
    }
}

/// Account-owner assignment coordinates used by the iOS selector. This is
/// deliberately separate from recipient records, which remain producer-only.
public struct NotificationProducerAssignment: Sendable, Equatable {
    public let logicalMailboxID: Data
    public let producerDeviceID: AccountDeviceID
    public let kind: NotificationProducerKind
    public let generation: UInt64
    public let trustEpoch: UInt64
    public let trustRevision: UInt64
    public let trustHead: Data
    public let producerSigningPublicKey: Data?

    public init(logicalMailboxID: Data, producerDeviceID: AccountDeviceID, kind: NotificationProducerKind, generation: UInt64, trustEpoch: UInt64, trustRevision: UInt64, trustHead: Data, producerSigningPublicKey: Data? = nil) {
        self.logicalMailboxID = logicalMailboxID; self.producerDeviceID = producerDeviceID; self.kind = kind
        self.generation = generation; self.trustEpoch = trustEpoch; self.trustRevision = trustRevision; self.trustHead = trustHead; self.producerSigningPublicKey = producerSigningPublicKey
    }
}

/// Performs the purpose-specific step-up and CAS selection used by the Mac
/// settings flow. The returned state is suitable for rendering immediately;
/// no local mailbox path is treated as an authority coordinate.
public final class AuthenticatedNotificationProducerSelector: @unchecked Sendable {
    private let sessions: NotificationAccountSession
    private let random: @Sendable (Int) throws -> Data
    private let clock: @Sendable () -> Date

    public init(api: AccountAPIClient, credentialStore: AccountCredentialStore, refreshLockURL: URL? = nil, random: @escaping @Sendable (Int) throws -> Data = { count in
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }, clock: @escaping @Sendable () -> Date = Date.init) {
        self.sessions = NotificationAccountSession(api: api, store: credentialStore, refreshLockURL: refreshLockURL, clock: clock); self.random = random; self.clock = clock
    }

    /// Converts the status-only CAS result into the state the settings flow
    /// renders. Rejected response bodies never reach this boundary.
    static func selectionState(for result: AccountAPIRequestResult) -> NotificationProducerSelectionState {
        switch result {
        case .httpFailure(let statusCode):
            return statusCode == 409 ? .conflict : .unavailable
        case .success(let body):
            guard let result = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  result["kind"] as? String == "notification.producer-selection.v2",
                  let generation = (result["generation"] as? NSNumber)?.uint64Value,
                  generation > 0 else { return .conflict }
            return .selected(generation: generation)
        }
    }

    public func trustedProducerTargets() async throws -> [NotificationProducerTarget] {
        let context = try await sessions.current()
        guard let commit = try sessions.store.loadCurrentTrustCommit(for: context.credentials.accountID) else {
            throw NotificationRuntimeError.unavailable
        }
        return commit.state.members.compactMap { member in
            switch member.platform {
            case .macos: return NotificationProducerTarget(deviceID: member.deviceID, kind: .mac)
            case .syncNode: return NotificationProducerTarget(deviceID: member.deviceID, kind: .syncNode)
            case .ios: return nil
            }
        }
    }

    /// Loads the account-owner assignment snapshot. The endpoint contains no
    /// recipient key/route material and therefore remains usable by an iOS
    /// actor even when no Sync Node is connected.
    public func currentProducerAssignments() async throws -> [NotificationProducerAssignment] {
        let context = try await sessions.current()
        guard let commit = try sessions.store.loadCurrentTrustCommit(for: context.credentials.accountID) else {
            throw NotificationRuntimeError.unavailable
        }
        let head = AccountTranscript.trustCommitDigest(commit)
        let body = Data("{}".utf8)
        let response = try await sessions.api.sendAccountRequest(
            method: "POST", path: "/v1/notifications/assignments/query", body: body,
            credentials: context.credentials, device: context.device,
            maximumRequestBytes: 1024, maximumResponseBytes: 64 * 1024
        )
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              Set(root.keys) == Set(["kind", "assignments"]),
              root["kind"] as? String == "notification.account-assignments.v2",
              let assignments = root["assignments"] as? [[String: Any]], assignments.count <= 100 else {
            throw NotificationRuntimeError.unavailable
        }
        return try assignments.map { object in
            guard Set(object.keys).isSubset(of: Set(["logicalMailboxID", "producerDeviceID", "producerKind", "generation", "trustEpoch", "trustRevision", "trustHead", "producerSigningPublicKey"])),
                  Set(object.keys).isSuperset(of: Set(["logicalMailboxID", "producerDeviceID", "producerKind", "generation", "trustEpoch", "trustRevision", "trustHead"])),
                  let mailboxString = object["logicalMailboxID"] as? String,
                  let mailbox = try? AccountWireCodec.decodeBase64URL(mailboxString, exactBytes: 32),
                  mailbox.contains(where: { $0 != 0 }),
                  let producerString = object["producerDeviceID"] as? String,
                  let producer = try? AccountDeviceID(producerString),
                  let kindString = object["producerKind"] as? String,
                  let kind = NotificationProducerKind(rawValue: kindString),
                  let generation = (object["generation"] as? NSNumber)?.uint64Value, generation > 0,
                  let epoch = (object["trustEpoch"] as? NSNumber)?.uint64Value, epoch > 0,
                  let revision = (object["trustRevision"] as? NSNumber)?.uint64Value, revision > 0,
                  let headString = object["trustHead"] as? String,
                  let assignmentHead = try? AccountWireCodec.decodeBase64URL(headString, exactBytes: 32),
                  assignmentHead == head else { throw NotificationRuntimeError.staleAssignment }
            let signingKey = (object["producerSigningPublicKey"] as? String).flatMap { try? AccountWireCodec.decodeBase64URL($0, exactBytes: 65) }
            let authoritativeKey = signingKey ?? commit.state.members.first(where: { $0.deviceID == producer })?.publicBundle.signingKey
            return NotificationProducerAssignment(logicalMailboxID: mailbox, producerDeviceID: producer, kind: kind, generation: generation, trustEpoch: epoch, trustRevision: revision, trustHead: assignmentHead, producerSigningPublicKey: authoritativeKey)
        }
    }

    public func selectProducer(target: NotificationProducerTarget, logicalMailboxID: Data, expectedGeneration: UInt64, identityToken: String, appleNonce: Data, now: Date = Date()) async -> NotificationProducerSelectionState {
        do {
            let context = try await sessions.current(now: now)
            let operationNow = clock()
            let credentials = context.credentials
            let device = context.device
            guard logicalMailboxID.count == 32, logicalMailboxID.contains(where: { $0 != 0 }), appleNonce.count == 32,
                  let commit = try sessions.store.loadCurrentTrustCommit(for: credentials.accountID),
                  let member = commit.state.members.first(where: { $0.deviceID == target.deviceID }),
                  member.platform == target.kind.platform,
                  expectedGeneration == target.expectedGeneration else { return .conflict }
            // Recipient retrieval is intentionally producer-only, so an iOS
            // account owner cannot use that route to learn a Mac/Node's CAS
            // generation.  Ask the owner-scoped state route instead.  The
            // response is bounded to opaque mailbox/producer coordinates and
            // trust coordinates; no recipient material is exposed here.
            let currentGeneration = try await selectionGeneration(
                target: target, logicalMailboxID: logicalMailboxID, commit: commit,
                credentials: credentials, device: device, now: operationNow
            )
            guard currentGeneration == expectedGeneration else { return .conflict }
            return try await selectProducer(
                target: target, actor: credentials, device: device, commit: commit,
                logicalMailboxID: logicalMailboxID, expectedGeneration: expectedGeneration,
                identityToken: identityToken, appleNonce: appleNonce, now: operationNow
            )
        } catch {
            return .unavailable
        }
    }

    public func selectMacProducer(logicalMailboxID: Data, expectedGeneration: UInt64, identityToken: String, appleNonce: Data, now: Date = Date()) async -> NotificationProducerSelectionState {
        do {
            let context = try await sessions.current(now: now)
            let operationNow = clock()
            let credentials = context.credentials
            let device = context.device
            guard logicalMailboxID.count == 32, logicalMailboxID.contains(where: { $0 != 0 }), appleNonce.count == 32,
                  let commit = try sessions.store.loadCurrentTrustCommit(for: credentials.accountID),
                  let member = commit.state.members.first(where: { $0.deviceID == credentials.deviceID && $0.platform == .macos }) else { return .unavailable }
            return try await selectProducer(target: NotificationProducerTarget(deviceID: member.deviceID, kind: .mac), actor: credentials, device: device, commit: commit, logicalMailboxID: logicalMailboxID, expectedGeneration: expectedGeneration, identityToken: identityToken, appleNonce: appleNonce, now: operationNow)
        } catch {
            return .unavailable
        }
    }

    private func selectProducer(target: NotificationProducerTarget, actor credentials: AccountSessionCredentials, device: AccountDeviceIdentity, commit: AccountTrustStateCommit, logicalMailboxID: Data, expectedGeneration: UInt64, identityToken: String, appleNonce: Data, now: Date) async throws -> NotificationProducerSelectionState {
            try AppleIdentityTokenAudience.requireIssued(to: AppleIdentityTokenAudience.runningApp, identityToken: identityToken)
            let nonce = try random(32)
            guard nonce.count == 32 else { return .unavailable }
            let stepUpBody = try JSONSerialization.data(withJSONObject: [
                "logicalMailboxID": AccountWireCodec.encodeBase64URL(logicalMailboxID),
                "targetProducerID": target.deviceID.rawValue,
                "expectedGeneration": expectedGeneration,
                "requestNonce": AccountWireCodec.encodeBase64URL(nonce),
                "currentCommitDigest": AccountWireCodec.encodeBase64URL(AccountTranscript.trustCommitDigest(commit)),
                "appleNonce": AccountWireCodec.encodeBase64URL(appleNonce),
                "identityToken": identityToken,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            let stepUpResponse = try await sessions.api.sendAccountRequest(method: "POST", path: "/v1/notifications/producers/step-up", body: stepUpBody, credentials: credentials, device: device, now: now, maximumRequestBytes: 32 * 1024, maximumResponseBytes: 32 * 1024)
            guard let response = try JSONSerialization.jsonObject(with: stepUpResponse) as? [String: Any],
                  response.keys.count == 3,
                  response["kind"] as? String == "notification.producer-step-up.v2",
                  let encodedAuthorization = response["authorization"] as? String,
                  let authorization = try? AccountWireCodec.decodeBase64URL(encodedAuthorization), authorization.count > 0,
                  let requestDigestString = response["requestDigest"] as? String,
                  let requestDigest = try? AccountWireCodec.decodeBase64URL(requestDigestString, exactBytes: 32) else { return .unavailable }
            let authDigest = Data(SHA256.hash(data: authorization))
            let selectionBody = try JSONSerialization.data(withJSONObject: [
                "logicalMailboxID": AccountWireCodec.encodeBase64URL(logicalMailboxID),
                "producerDeviceID": target.deviceID.rawValue,
                "producerKind": target.kind.rawValue,
                "expectedGeneration": expectedGeneration,
                "generation": 0,
                "trustEpoch": commit.state.epoch.value,
                "trustRevision": commit.state.revision.value,
                "trustHead": AccountWireCodec.encodeBase64URL(AccountTranscript.trustCommitDigest(commit)),
                "authorizationDigest": AccountWireCodec.encodeBase64URL(authDigest),
                "requestNonce": AccountWireCodec.encodeBase64URL(nonce),
                "requestDigest": AccountWireCodec.encodeBase64URL(requestDigest),
                "clear": false,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            let selected = try await sessions.api.sendAccountRequestResult(method: "PUT", path: "/v1/notifications/producers", body: selectionBody, credentials: credentials, device: device, now: now, maximumRequestBytes: 16 * 1024, maximumResponseBytes: 8 * 1024)
            return Self.selectionState(for: selected)
    }

    private func selectionGeneration(
        target: NotificationProducerTarget,
        logicalMailboxID: Data,
        commit: AccountTrustStateCommit,
        credentials: AccountSessionCredentials,
        device: AccountDeviceIdentity,
        now: Date
    ) async throws -> UInt64 {
        let body = try JSONSerialization.data(withJSONObject: [
            "logicalMailboxID": AccountWireCodec.encodeBase64URL(logicalMailboxID),
            "producerDeviceID": target.deviceID.rawValue,
            "producerKind": target.kind.rawValue,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let result = try await sessions.api.sendAccountRequestResult(
            method: "POST", path: "/v1/notifications/producers/owner-query", body: body,
            credentials: credentials, device: device, now: now,
            maximumRequestBytes: 8 * 1024, maximumResponseBytes: 16 * 1024
        )
        return try Self.ownerQueryPredecessor(
            result: result, logicalMailboxID: logicalMailboxID
        )
    }

    static func ownerQueryPredecessor(
        result: AccountAPIRequestResult,
        logicalMailboxID: Data
    ) throws -> UInt64 {
        if case .httpFailure(statusCode: 409) = result {
            // Central uses conflict for the bounded owner query's explicit
            // "no active assignment" result. Zero is the only valid CAS
            // predecessor for the first selection; the subsequent PUT still
            // decides whether another actor won concurrently.
            return 0
        }
        guard case .success(let response) = result else {
            throw NotificationRuntimeError.staleAssignment
        }
        return try ownerQueryGeneration(response: response, logicalMailboxID: logicalMailboxID)
    }

    /// The owner query is a CAS predecessor lookup, not an assertion that the
    /// proposed producer already owns the mailbox. Its trust coordinates may
    /// belong to the predecessor commit when a trust rotation happened between
    /// the query and the authorized PUT; that PUT validates the new commit.
    static func ownerQueryGeneration(response: Data, logicalMailboxID: Data) throws -> UInt64 {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              Set(object.keys) == Set(["kind", "logicalMailboxID", "producerDeviceID", "producerKind", "generation", "trustEpoch", "trustRevision", "trustHead"]),
              object["kind"] as? String == "notification.producer-selection-state.v2",
              object["logicalMailboxID"] as? String == AccountWireCodec.encodeBase64URL(logicalMailboxID),
              let generation = (object["generation"] as? NSNumber)?.uint64Value,
              generation > 0,
              let producer = object["producerDeviceID"] as? String,
              (try? AccountDeviceID(producer)) != nil,
              let kind = object["producerKind"] as? String,
              NotificationProducerKind(rawValue: kind) != nil,
              let epoch = (object["trustEpoch"] as? NSNumber)?.uint64Value,
              epoch > 0,
              let revision = (object["trustRevision"] as? NSNumber)?.uint64Value,
              revision > 0,
              let head = object["trustHead"] as? String,
              (try? AccountWireCodec.decodeBase64URL(head, exactBytes: 32)) != nil else {
            throw NotificationRuntimeError.staleAssignment
        }
        return generation
    }
}

private extension Data {
    var uuidTuple: uuid_t {
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { destination in
                for (index, byte) in prefix(16).enumerated() { destination[index] = byte }
            }
        }
        return tuple
    }

    func u64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] { value = (value << 8) | UInt64(byte) }
        return value
    }
}
