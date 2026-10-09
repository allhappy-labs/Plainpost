import Foundation
import PlainpostAccountProtocol

public enum AccountSessionRefreshFailure: Error, Sendable {
    case network
    case rejected
    case suspended
}

/// Why the last `prepare` could not reach an active session when the cause
/// may clear by itself: a retry can succeed without the user.
public enum AccountSessionTransientFailure: Equatable, Sendable {
    /// Central was unreachable.
    case network
    /// The session could not be read, as with a locked login keychain.
    case credentialsUnavailable
}

public protocol AccountSessionRefreshing: Sendable {
    func refresh(_ credentials: AccountSessionCredentials, identity: AccountDeviceIdentity) async throws -> AccountSessionCredentials
}

/// Owns the small state machine between device-only session storage and the
/// refresh transport. Offline reading is deliberately possible only when an
/// injected cryptographic verifier confirms an already-issued lease.
public actor AccountSessionController {
    public typealias OfflineLeaseVerifier = @Sendable (_ lease: String, _ now: Date) -> Date?
    public typealias PendingAdmissionCompleter = @Sendable (_ activation: AccountActivation, _ refreshedCredentials: AccountSessionCredentials, _ identity: AccountDeviceIdentity) async throws -> Void

    private let credentials: any AccountCredentialStoring
    private let refresher: any AccountSessionRefreshing
    private let leaseVerifier: OfflineLeaseVerifier
    private let pendingAdmissionCompleter: PendingAdmissionCompleter?
    private let jitter: @Sendable (ClosedRange<Double>) -> Double
    private let clock: @Sendable () -> Date
    public private(set) var nextRefreshAt: Date?
    private var inFlight: (generation: UInt64, task: Task<RefreshOutcome, Never>)?
    private var generation: UInt64 = 0
    private var appliedGeneration: UInt64 = 0
    private var scheduledRefresh: Task<Void, Never>?
    private var scheduledRefreshID: UUID?
    public private(set) var lastTransientFailure: AccountSessionTransientFailure?
    /// Receives the result of each scheduled background refresh, which no
    /// caller awaits.
    public typealias StateObserver = @Sendable (AccountSessionState, AccountSessionTransientFailure?) async -> Void
    private var stateObserver: StateObserver?

    public init(
        credentials: any AccountCredentialStoring,
        refresher: any AccountSessionRefreshing,
        leaseVerifier: @escaping OfflineLeaseVerifier,
        pendingAdmissionCompleter: PendingAdmissionCompleter? = nil,
        jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = { range in Double.random(in: range) },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials; self.refresher = refresher; self.leaseVerifier = leaseVerifier; self.pendingAdmissionCompleter = pendingAdmissionCompleter; self.jitter = jitter; self.clock = clock
    }

    /// A suspended session never comes back by itself: another device recovered or
    /// suspended this account. Starting over clears the stored session, after Central
    /// confirms the suspension, so the device signs in again like a new one and needs a
    /// trusted device's approval or recovery. Any other state is returned unchanged.
    public func discardSuspendedSession(now: Date) async -> AccountSessionState {
        let state = await prepare(now: now)
        guard state == .suspended else { return state }
        guard let current = (try? credentials.loadSession())??.credentials,
              (try? credentials.clearSession(ifCurrent: current)) == true else { return state }
        nextRefreshAt = nil
        return .signInRequired
    }

    public func setStateObserver(_ observer: StateObserver?) {
        stateObserver = observer
    }

    public func prepare(now: Date) async -> AccountSessionState {
        lastTransientFailure = nil
        do {
            if try credentials.loadCompletedDeletionReceipt() != nil {
                nextRefreshAt = nil
                scheduledRefresh?.cancel(); scheduledRefresh = nil
                return .deleted
            }
            if try credentials.loadLocalDeletion() != nil {
                nextRefreshAt = nil
                scheduledRefresh?.cancel(); scheduledRefresh = nil
                return .cleanupRequired
            }
        } catch {
            nextRefreshAt = nil
            return .cleanupRequired
        }
        let loadedSession: AccountSession?
        do { loadedSession = try credentials.loadSession() }
        catch {
            nextRefreshAt = nil
            lastTransientFailure = .credentialsUnavailable
            return .expired
        }
        guard let session = loadedSession else { nextRefreshAt = nil; return .signInRequired }
        if case .provisional(let activation) = session.state {
            nextRefreshAt = nil
            guard activation.mode == .pending else { return .expired }
            guard let provisionalCredentials = session.credentials else { return .provisional(activation) }
            do {
                let identity = try credentials.loadOrCreateDeviceIdentity()
                let refreshed = try await refresher.refresh(provisionalCredentials, identity: identity)
                guard let pendingAdmissionCompleter else { return .provisional(activation) }
                try await pendingAdmissionCompleter(activation, refreshed, identity)
                return .active
            } catch let failure as AccountSessionRefreshFailure {
                switch failure {
                case .suspended: return .suspended
                case .network:
                    lastTransientFailure = .network
                    return .provisional(activation)
                case .rejected: return .provisional(activation)
                }
            } catch is CancellationError {
                return .expired
            } catch {
                return .provisional(activation)
            }
        }
        guard let current = session.credentials else {
            nextRefreshAt = nil
            return .signInRequired
        }
        let deadline = refreshDeadline(for: current, now: now)
        nextRefreshAt = deadline
        if now < deadline { scheduleRefresh(at: deadline); return .active }
        if Task.isCancelled { return .expired }
        let refresh: (UInt64, Task<RefreshOutcome, Never>)
        if let existing = inFlight { refresh = (existing.generation, existing.task) }
        else {
            generation &+= 1
            let currentGeneration = generation
            let store = credentials, refresher = refresher
            let task = Task<RefreshOutcome, Never> {
                do {
                    let identity = try store.loadOrCreateDeviceIdentity(), refreshed = try await refresher.refresh(current, identity: identity)
                    guard try store.replaceSession(ifCurrent: current, with: refreshed) else { return .superseded }
                    return .success(refreshed)
                }
                catch is CancellationError { return .cancelled }
                catch let failure as AccountSessionRefreshFailure { return .failure(failure) }
                catch { return .invalid }
            }
            inFlight = (currentGeneration, task); refresh = (currentGeneration, task)
        }
        let outcome = await refresh.1.value
        if Task.isCancelled { return .expired }
        if inFlight?.generation == refresh.0 { inFlight = nil }
        if refresh.0 <= appliedGeneration { return stateForCurrentSession(now: now) }
        appliedGeneration = refresh.0
        switch outcome {
        case .success(let refreshed):
            let next = refreshDeadline(for: refreshed, now: now); nextRefreshAt = next; scheduleRefresh(at: next)
            return .active
        case .failure(let failure):
            switch failure {
            case .network:
                lastTransientFailure = .network
                guard let expiry = leaseVerifier(current.offlineLease, now), expiry > now else { nextRefreshAt = nil; return .expired }
                return .offlineLease(expiresAt: expiry)
            case .suspended:
                nextRefreshAt = nil
                return .suspended
            case .rejected:
                guard (try? credentials.clearSession(ifCurrent: current)) == true else { return stateForCurrentSession(now: now) }
                nextRefreshAt = nil; return .signInRequired
            }
        case .superseded: return stateForCurrentSession(now: now)
        case .cancelled, .invalid:
            nextRefreshAt = nil
            return .expired
        }
    }

    private func refreshDeadline(for credentials: AccountSessionCredentials, now: Date) -> Date {
        let jitterFraction = min(1, max(0, jitter(0 ... 1)))
        let lead = 30 + (60 * jitterFraction)
        let deadline = credentials.accessExpiresAt.addingTimeInterval(-lead)
        return deadline > now ? deadline : now
    }

    private func stateForCurrentSession(now: Date) -> AccountSessionState {
        guard let current = (try? credentials.loadSession())?.credentials else { return .signInRequired }
        if current.accessExpiresAt > now { return .active }
        return .expired
    }

    private func scheduleRefresh(at deadline: Date) {
        scheduledRefresh?.cancel()
        let delay = max(0, deadline.timeIntervalSince(clock()))
        let id = UUID()
        scheduledRefreshID = id
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.runScheduledRefresh(id: id)
        }
    }

    /// Runs a due refresh and hands its result to the observer, so a
    /// refresh that fails in the background (offline, suspended, signed
    /// out) reaches the view model instead of being dropped.
    private func runScheduledRefresh(id: UUID) async {
        guard scheduledRefreshID == id else { return }
        // Detach this task first: a successful refresh schedules the next
        // one, which must not cancel the refresh that is still reporting.
        scheduledRefresh = nil
        scheduledRefreshID = nil
        let state = await prepare(now: clock())
        guard !Task.isCancelled else { return }
        await stateObserver?(state, lastTransientFailure)
    }
}

private enum RefreshOutcome: Sendable { case success(AccountSessionCredentials); case failure(AccountSessionRefreshFailure); case superseded; case cancelled; case invalid }

public enum AccountSessionRuntimeAssembly {
    /// Production composition root. A controller is never exposed until the
    /// authenticated session-key manifest has been refreshed successfully.
    public static func production(
        credentials: any AccountCredentialStoring,
        bootstrapManifest: BootstrapKeyManifestStore,
        bundledSessionManifest: Data,
        offlineRootKeyID: String,
        offlineRootPublicKey: Data,
        sessionManifestSecretStore: any AccountSecretStoring = KeychainAccountSecretStore(),
        transport: any AccountHTTPTransport = URLSessionAccountHTTPTransport(),
        baseURL: URL
    ) async throws -> AccountSessionController {
        let session = try credentials.loadSession()?.credentials
        let manifests = try SessionKeyManifestStore(bundledDocument: bundledSessionManifest, offlineRootKeyID: offlineRootKeyID, offlineRootPublicKey: offlineRootPublicKey, secretStore: sessionManifestSecretStore)
        do { try await manifests.fetch(using: transport, baseURL: baseURL) }
        catch AccountRuntimeError.transportFailure { _ = try manifests.verifier() }
        let client = try AccountAPIClient(transport: transport, credentialStore: credentials, manifestStore: bootstrapManifest, baseURL: baseURL)
        let verifier = try manifests.verifier()
        let leaseVerifier: AccountSessionController.OfflineLeaseVerifier = { lease, now in
            guard let session else { return nil }
            return verifier.offlineLeaseVerifier(accountID: session.accountID, deviceID: session.deviceID)(lease, now)
        }
        return AccountSessionController(
            credentials: credentials,
            refresher: client,
            leaseVerifier: leaseVerifier,
            pendingAdmissionCompleter: pendingCompleter(credentials: credentials, client: client)
        )
    }

    /// Synchronous app composition uses the root-authenticated bundled public
    /// manifest. Network refresh remains an independent runtime operation; a
    /// fresh install is therefore constructible without weakening lease checks.
    public static func bundledController(
        credentials: any AccountCredentialStoring,
        bootstrapManifest: BootstrapKeyManifestStore,
        sessionManifestSecretStore: any AccountSecretStoring = KeychainAccountSecretStore(),
        transport: any AccountHTTPTransport = URLSessionAccountHTTPTransport(),
        baseURL: URL
    ) throws -> AccountSessionController {
        // Reading public bundled authority must not touch Keychain: otherwise
        // a fresh install cannot even render its sign-in root. The injected
        // store is retained for the asynchronous refresh composition above.
        _ = sessionManifestSecretStore
        let verifier = try SessionKeyManifestVerifier(
            document: SessionKeyManifestStore.bundledManifest,
            offlineRootKeyID: SessionKeyManifestStore.bundledOfflineRootKeyID,
            offlineRootPublicKey: SessionKeyManifestStore.bundledOfflineRootPublicKey
        )
        let client = try AccountAPIClient(transport: transport, credentialStore: credentials, manifestStore: bootstrapManifest, baseURL: baseURL)
        return AccountSessionController(
            credentials: credentials,
            refresher: client,
            leaseVerifier: { lease, now in
                guard let session = try? credentials.loadSession()?.credentials else { return nil }
                return verifier.offlineLeaseVerifier(accountID: session.accountID, deviceID: session.deviceID)(lease, now)
            },
            pendingAdmissionCompleter: pendingCompleter(credentials: credentials, client: client)
        )
    }

    private static func pendingCompleter(credentials: any AccountCredentialStoring, client: AccountAPIClient) -> AccountSessionController.PendingAdmissionCompleter {
        { activation, refreshed, identity in
            guard let store = credentials as? AccountCredentialStore else { throw AccountRuntimeError.secretUnavailable }
            #if os(iOS)
            let platform = AccountPlatform.ios
            #else
            let platform = AccountPlatform.macos
            #endif
            let temporaryTrustStore = AccountTrustStore(secretStore: InMemoryAccountSecretStore())
            let coordinator = try AccountTrustCoordinator(accountID: activation.accountID, deviceID: activation.deviceID, platform: platform, deviceIdentity: identity, trustStore: temporaryTrustStore)
            guard let accepted = try await client.synchronizeTrustHistory(credentials: refreshed, device: identity, applying: coordinator),
                  accepted.state.members.contains(where: { $0.deviceID == activation.deviceID && $0.publicBundle == identity.publicBundle })
            else { throw AccountRuntimeError.untrustedResponse }
            let prepared = try await coordinator.preparedTrustActivation()
            try store.commitPendingTrustActivation(activation, credentials: refreshed, prepared: prepared)
        }
    }
}
